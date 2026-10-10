import jwt from "jsonwebtoken";
import type { NormalizedReview } from "./supabase";
import type { AppStoreCreds } from "./credentials";

/**
 * App Store Connect API クライアント。
 * - 自分が権限を持つアプリのレビューのみ取得可能。
 * - レート上限: 7,200 req/時/アプリ。429時は Retry-After を必ず尊重する。
 * - 返信API(Customer Review Responses)は不具合報告があるため、失敗時は
 *   呼び出し側が「コピーして貼り付け」運用にフォールバックできるよう例外を投げる。
 */

const BASE = "https://api.appstoreconnect.apple.com/v1";

/**
 * .p8秘密鍵から短命JWT(<=20分)を生成。
 *
 * 【重要】環境変数へのフォールバックは廃止した。
 * 運営の ASC_* を fallback にすると、ユーザーが任意の store_app_id を登録するだけで
 * 運営の鍵の権限が及ぶ範囲のレビューを読めてしまい、テナント境界が壊れるため。
 */
export function makeAscToken(creds: AppStoreCreds): string {
  const issuerId = creds?.issuerId;
  const keyId = creds?.keyId;
  const privateKey = (creds?.privateKey ?? "").replace(/\\n/g, "\n");
  if (!issuerId || !keyId || !privateKey) {
    throw new Error("App Store Connect の認証情報が未登録です。設定 > ストア連携から登録してください。");
  }

  const now = Math.floor(Date.now() / 1000);
  return jwt.sign(
    {
      iss: issuerId,
      iat: now,
      exp: now + 60 * 19, // 20分未満
      aud: "appstoreconnect-v1",
    },
    privateKey,
    { algorithm: "ES256", header: { alg: "ES256", kid: keyId, typ: "JWT" } }
  );
}

async function ascGet(path: string, token: string): Promise<any> {
  const res = await fetch(`${BASE}${path}`, {
    headers: { Authorization: `Bearer ${token}` },
  });
  if (res.status === 429) {
    const retry = res.headers.get("Retry-After");
    throw new Error(`ASC rate limited. Retry-After=${retry}`);
  }
  if (!res.ok) throw new Error(`ASC ${res.status}: ${await res.text()}`);
  return res.json();
}

/**
 * 認証情報が実際に使えるかを確認する。保存前に必ず通す。
 * 鍵が間違っていても「連携しました」と表示され、以後レビューが永久に0件のまま
 * 原因も分からない、という状態を防ぐのが目的。
 * @throws 人が読んで対処できるメッセージ
 */
export async function verifyAppStoreCreds(creds: AppStoreCreds): Promise<{ apps: number }> {
  let token: string;
  try {
    token = makeAscToken(creds);
  } catch {
    throw new Error("秘密鍵(.p8)の形式が正しくありません。BEGIN/END の行を含めて全文を貼り付けてください。");
  }
  const res = await fetch(`${BASE}/apps?limit=1`, { headers: { Authorization: `Bearer ${token}` } });
  if (res.status === 401) {
    throw new Error("Appleに拒否されました。Issuer ID / Key ID / 秘密鍵の組み合わせをご確認ください。");
  }
  if (res.status === 403) {
    throw new Error("このAPIキーにはAppを参照する権限がありません。App Store Connect でロール（App Manager 以上）をご確認ください。");
  }
  if (!res.ok) {
    throw new Error(`Appleへの接続に失敗しました（${res.status}）。時間をおいて再度お試しください。`);
  }
  const json: any = await res.json();
  return { apps: json?.data?.length ?? 0 };
}

/** 特定アプリのレビューを読む権限があるかを確認する（アプリ追加時に使用）。 */
export async function verifyAppStoreAccess(appId: string, creds: AppStoreCreds): Promise<string | null> {
  const token = makeAscToken(creds);
  const res = await fetch(`${BASE}/apps/${encodeURIComponent(appId)}`, {
    headers: { Authorization: `Bearer ${token}` },
  });
  if (res.status === 404) {
    throw new Error(
      `App ID「${appId}」が見つかりません。App Store Connect のアプリ情報にある「Apple ID」（数字）をご確認ください。`
    );
  }
  if (res.status === 401 || res.status === 403) {
    throw new Error("このAPIキーには当該アプリへのアクセス権がありません。App Store Connect の権限をご確認ください。");
  }
  if (!res.ok) throw new Error(`Appleへの接続に失敗しました（${res.status}）。`);
  const json: any = await res.json();
  return (json?.data?.attributes?.name as string | undefined) ?? null;
}

/**
 * App Store のレビューへ返信を投稿する（Customer Review Responses）。
 * @param reviewExternalId reviews.external_id（= ASCのcustomerReview id）
 */
export async function replyToAppStoreReview(
  reviewExternalId: string,
  responseBody: string,
  creds?: AppStoreCreds
): Promise<void> {
  if (!creds) {
    throw new Error("App Store Connect の認証情報が未登録です。設定 > ストア連携から登録してください。");
  }
  const token = makeAscToken(creds);
  const res = await fetch(`${BASE}/customerReviewResponses`, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${token}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      data: {
        type: "customerReviewResponses",
        attributes: { responseBody },
        relationships: {
          review: { data: { type: "customerReviews", id: reviewExternalId } },
        },
      },
    }),
  });
  if (res.status === 429) {
    const retry = res.headers.get("Retry-After");
    throw new Error(`ASC rate limited. Retry-After=${retry}`);
  }
  // 201 Created が成功。既に返信済みの場合などは 409。
  if (!res.ok) throw new Error(`ASC ${res.status}: ${await res.text()}`);
}

/**
 * 指定アプリの最新レビューを取得（新しい順）。
 * @param appId Apple の numeric app id
 * @param stopAtExternalId ここまで来たら停止（前回チェックポイント）
 * @param since この時刻より古いレビューに到達したら停止。
 *   stopAtExternalId のレビューがAppleに削除されると終端を見失い、
 *   毎回 maxPages ぶん全件を引き続けてしまうため、時刻でも打ち切る。
 */
export async function fetchAppStoreReviews(
  appId: string,
  stopAtExternalId?: string | null,
  maxPages = 5,
  creds?: AppStoreCreds,
  since?: Date | null
): Promise<NormalizedReview[]> {
  if (!creds) {
    throw new Error("App Store Connect の認証情報が未登録です。設定 > ストア連携から登録してください。");
  }
  const token = makeAscToken(creds);
  const out: NormalizedReview[] = [];
  let url = `/apps/${appId}/customerReviews?sort=-createdDate&limit=200`;
  const sinceMs = since ? since.getTime() : null;

  for (let page = 0; page < maxPages; page++) {
    const json = await ascGet(url, token);
    for (const item of json.data ?? []) {
      const a = item.attributes ?? {};
      const ext = item.id as string;
      if (stopAtExternalId && ext === stopAtExternalId) return out; // 既知に到達
      const created = a.createdDate ? Date.parse(a.createdDate) : NaN;
      if (sinceMs && !Number.isNaN(created) && created < sinceMs) return out; // 前回取得より古い
      out.push({
        store: "appstore",
        external_id: ext,
        rating: Number(a.rating ?? 0),
        title: a.title ?? null,
        body: a.body ?? null,
        author: a.reviewerNickname ?? null,
        territory: a.territory ?? null,
        app_version: null, // ASCのcustomerReviewsはversion文字列を直接返さない
        reviewed_at: a.createdDate ?? null,
        raw: item,
      });
    }
    const next = json.links?.next as string | undefined;
    if (!next) break;
    url = next.replace(BASE, ""); // 絶対URL→相対
  }
  return out;
}
