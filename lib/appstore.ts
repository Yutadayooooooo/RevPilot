import jwt from "jsonwebtoken";
import type { NormalizedReview } from "./supabase";
import type { AppStoreCreds } from "./credentials";

/**
 * App Store Connect API クライアント。
 * - 自分が権限を持つアプリのレビューのみ取得可能。
 * - レート上限: 7,200 req/時/アプリ。429時は Retry-After を必ず尊重する。
 * - 返信API(Customer Review Responses)は2026年時点で不具合報告あり → 本MVPでは"生成して貼り付け"運用。
 */

const BASE = "https://api.appstoreconnect.apple.com/v1";

/**
 * .p8秘密鍵から短命JWT(<=20分)を生成。
 * credsが渡されればそれを使い、無ければ環境変数にフォールバック（開発/単一テナント）。
 */
export function makeAscToken(creds?: AppStoreCreds): string {
  const issuerId = creds?.issuerId ?? process.env.ASC_ISSUER_ID!;
  const keyId = creds?.keyId ?? process.env.ASC_KEY_ID!;
  const privateKey = (creds?.privateKey ?? process.env.ASC_PRIVATE_KEY ?? "").replace(/\\n/g, "\n");
  if (!issuerId || !keyId || !privateKey) throw new Error("ASC credentials missing");

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
 * App Store のレビューへ返信を投稿する（Customer Review Responses）。
 * @param reviewExternalId reviews.external_id（= ASCのcustomerReview id）
 * 注意: Apple側の返信APIは信頼性に懸念があるとの報告があるため、
 * 失敗時は呼び出し側でコピー運用へフォールバックできるよう例外を投げる。
 */
export async function replyToAppStoreReview(
  reviewExternalId: string,
  responseBody: string,
  creds?: AppStoreCreds
): Promise<void> {
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
 */
export async function fetchAppStoreReviews(
  appId: string,
  stopAtExternalId?: string | null,
  maxPages = 5,
  creds?: AppStoreCreds
): Promise<NormalizedReview[]> {
  const token = makeAscToken(creds);
  const out: NormalizedReview[] = [];
  let url = `/apps/${appId}/customerReviews?sort=-createdDate&limit=200`;

  for (let page = 0; page < maxPages; page++) {
    const json = await ascGet(url, token);
    for (const item of json.data ?? []) {
      const a = item.attributes ?? {};
      const ext = item.id as string;
      if (stopAtExternalId && ext === stopAtExternalId) return out; // 既知に到達
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
