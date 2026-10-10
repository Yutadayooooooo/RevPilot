import { GoogleAuth } from "google-auth-library";
import type { NormalizedReview } from "./supabase";
import type { GooglePlayCreds } from "./credentials";

/**
 * Google Play Developer API クライアント。
 * 重要な制約:
 * - reviews.list は「直近7日・本文ありのレビューのみ」。ページングは token 方式。
 *   → 毎時ポーリングして自前DBに蓄積し、Googleが消す分を履歴化するのが本アプリの肝。
 * - GET 200/時、返信POST 2,000/日。
 * - 返信は reviews.reply で自動投稿可能（本文350字以内）。
 */

const SCOPE = "https://www.googleapis.com/auth/androidpublisher";
const API = "https://androidpublisher.googleapis.com/androidpublisher/v3/applications";

/**
 * 【重要】環境変数へのフォールバックは廃止した。
 * 運営の GOOGLE_SERVICE_ACCOUNT_JSON を fallback にすると、ユーザーが任意の
 * packageName を登録するだけで運営の権限が及ぶ範囲を読めてしまうため。
 */
function auth(creds: GooglePlayCreds) {
  const raw = creds?.serviceAccountJson;
  if (!raw) {
    throw new Error("Google Play の認証情報が未登録です。設定 > ストア連携から登録してください。");
  }
  let credentials: Record<string, unknown>;
  try {
    credentials = JSON.parse(raw);
  } catch {
    throw new Error("サービスアカウントJSONの形式が正しくありません。");
  }
  return new GoogleAuth({ credentials, scopes: [SCOPE] });
}

async function token(creds: GooglePlayCreds): Promise<string> {
  const client = await auth(creds).getClient();
  const t = await client.getAccessToken();
  if (!t.token) throw new Error("Googleのアクセストークンを取得できませんでした。");
  return t.token;
}

/** レビュー1件ぶんのJSONを正規化する。 */
function normalize(r: any): NormalizedReview {
  const c = r.comments?.[0]?.userComment ?? {};
  const tsSec = c.lastModified?.seconds ? Number(c.lastModified.seconds) : null;
  return {
    store: "googleplay",
    external_id: r.reviewId,
    rating: Number(c.starRating ?? 0),
    title: null,
    body: c.text ?? null,
    author: r.authorName ?? null,
    territory: c.reviewerLanguage ?? null,
    app_version: c.appVersionName ?? null,
    reviewed_at: tsSec ? new Date(tsSec * 1000).toISOString() : null,
    raw: r,
  };
}

/**
 * 認証情報とパッケージへのアクセス権を確認する。保存前に必ず通す。
 * @throws 人が読んで対処できるメッセージ
 */
export async function verifyGooglePlayCreds(creds: GooglePlayCreds): Promise<void> {
  let accessToken: string;
  try {
    accessToken = await token(creds);
  } catch (e: any) {
    throw new Error(
      `サービスアカウントで認証できませんでした。JSONキーが有効かご確認ください。（${e?.message ?? e}）`
    );
  }
  // パッケージ名はこの時点では未指定なので、トークンが取れた時点で「鍵は有効」と判定する。
  // 個別アプリへの権限は addApp / 取得時に verifyGooglePlayAccess で確認する。
  if (!accessToken) throw new Error("サービスアカウントで認証できませんでした。");
}

/** 特定パッケージのレビューを読む権限があるかを確認する（アプリ追加時に使用）。 */
export async function verifyGooglePlayAccess(
  packageName: string,
  creds: GooglePlayCreds
): Promise<void> {
  const accessToken = await token(creds);
  const res = await fetch(`${API}/${encodeURIComponent(packageName)}/reviews?maxResults=1`, {
    headers: { Authorization: `Bearer ${accessToken}` },
  });
  if (res.status === 401 || res.status === 403) {
    throw new Error(
      `このサービスアカウントには「${packageName}」のレビューを読む権限がありません。` +
        `Play Console > ユーザーと権限 で、当該アカウントにアプリへのアクセスと「返信」権限を付与してください。`
    );
  }
  if (res.status === 404) {
    throw new Error(`パッケージ名「${packageName}」が見つかりません。表記をご確認ください。`);
  }
  if (!res.ok) {
    throw new Error(`Google Play への接続に失敗しました（${res.status}）。`);
  }
}

/**
 * @param packageName 例: com.example.app
 * @param maxResults 1ページあたりの件数（APIの上限は100）
 * @param maxPages ページング回数の上限。1時間に100件を超えるレビューが来ると
 *   1ページでは取りこぼすため、token でページを辿る。
 */
export async function fetchGooglePlayReviews(
  packageName: string,
  maxResults = 100,
  creds?: GooglePlayCreds,
  maxPages = 5
): Promise<NormalizedReview[]> {
  if (!creds) {
    throw new Error("Google Play の認証情報が未登録です。設定 > ストア連携から登録してください。");
  }
  const accessToken = await token(creds);
  const out: NormalizedReview[] = [];
  let pageToken: string | undefined;

  for (let page = 0; page < maxPages; page++) {
    const url =
      `${API}/${encodeURIComponent(packageName)}/reviews` +
      `?maxResults=${Math.min(maxResults, 100)}` +
      (pageToken ? `&token=${encodeURIComponent(pageToken)}` : "");

    const res = await fetch(url, { headers: { Authorization: `Bearer ${accessToken}` } });
    if (res.status === 401 || res.status === 403) {
      throw new Error(
        `「${packageName}」のレビューを読む権限がありません。Play Console の「ユーザーと権限」をご確認ください。`
      );
    }
    if (!res.ok) throw new Error(`GooglePlay ${res.status}: ${await res.text()}`);
    const json: any = await res.json();

    for (const r of json.reviews ?? []) out.push(normalize(r));

    pageToken = json.tokenPagination?.nextPageToken;
    if (!pageToken) break;
  }
  return out;
}

/** レビューに自動返信（Androidのみ可）。本文は350字以内。 */
export async function replyToGooglePlayReview(
  packageName: string,
  reviewId: string,
  replyText: string,
  creds?: GooglePlayCreds
): Promise<void> {
  if (!creds) {
    throw new Error("Google Play の認証情報が未登録です。設定 > ストア連携から登録してください。");
  }
  const accessToken = await token(creds);
  const url = `${API}/${encodeURIComponent(packageName)}/reviews/${encodeURIComponent(reviewId)}:reply`;
  const res = await fetch(url, {
    method: "POST",
    headers: { Authorization: `Bearer ${accessToken}`, "Content-Type": "application/json" },
    body: JSON.stringify({ replyText: replyText.slice(0, 350) }),
  });
  if (!res.ok) throw new Error(`GooglePlay reply ${res.status}: ${await res.text()}`);
}
