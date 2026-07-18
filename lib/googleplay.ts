import { GoogleAuth } from "google-auth-library";
import type { NormalizedReview } from "./supabase";

/**
 * Google Play Developer API クライアント。
 * 重要な制約:
 * - reviews.list は「直近7日・本文ありのレビューのみ」。ページングはstartIndex/maxResults方式。
 *   → 毎時ポーリングして自前DBに蓄積し、Googleが消す分を履歴化するのが本アプリの肝。
 * - GET 200/時、返信POST 2,000/日。
 * - 返信は reviews.reply で自動投稿可能（本文350字以内）。
 */

const SCOPE = "https://www.googleapis.com/auth/androidpublisher";

function auth() {
  const raw = process.env.GOOGLE_SERVICE_ACCOUNT_JSON;
  if (!raw) throw new Error("GOOGLE_SERVICE_ACCOUNT_JSON missing");
  const credentials = JSON.parse(raw);
  return new GoogleAuth({ credentials, scopes: [SCOPE] });
}

async function token(): Promise<string> {
  const client = await auth().getClient();
  const t = await client.getAccessToken();
  if (!t.token) throw new Error("failed to get google access token");
  return t.token;
}

/** @param packageName 例: com.example.app */
export async function fetchGooglePlayReviews(
  packageName: string,
  maxResults = 100
): Promise<NormalizedReview[]> {
  const accessToken = await token();
  const url =
    `https://androidpublisher.googleapis.com/androidpublisher/v3/applications/` +
    `${encodeURIComponent(packageName)}/reviews?maxResults=${maxResults}`;

  const res = await fetch(url, { headers: { Authorization: `Bearer ${accessToken}` } });
  if (!res.ok) throw new Error(`GooglePlay ${res.status}: ${await res.text()}`);
  const json: any = await res.json();

  const out: NormalizedReview[] = [];
  for (const r of json.reviews ?? []) {
    const c = r.comments?.[0]?.userComment ?? {};
    const tsSec = c.lastModified?.seconds ? Number(c.lastModified.seconds) : null;
    out.push({
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
    });
  }
  return out;
}

/** レビューに自動返信（Androidのみ可）。本文は350字以内。 */
export async function replyToGooglePlayReview(
  packageName: string,
  reviewId: string,
  replyText: string
): Promise<void> {
  const accessToken = await token();
  const url =
    `https://androidpublisher.googleapis.com/androidpublisher/v3/applications/` +
    `${encodeURIComponent(packageName)}/reviews/${encodeURIComponent(reviewId)}:reply`;
  const res = await fetch(url, {
    method: "POST",
    headers: { Authorization: `Bearer ${accessToken}`, "Content-Type": "application/json" },
    body: JSON.stringify({ replyText: replyText.slice(0, 350) }),
  });
  if (!res.ok) throw new Error(`GooglePlay reply ${res.status}: ${await res.text()}`);
}
