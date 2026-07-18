import { createSupabaseServer, getCurrentUser } from "./supabase/server";
import { SAMPLE_REVIEWS, type ReviewRow } from "./sample";

/**
 * ログインユーザーのレビューを返す（RLSで自動スコープ）。
 * 未設定 or 未ログインならサンプル（ローカルプレビュー用）。
 */
export async function getReviews(opts: { store?: string; maxRating?: number } = {}): Promise<{
  rows: ReviewRow[];
  usingSample: boolean;
}> {
  const user = await getCurrentUser();
  if (!user) return { rows: filterSample(opts), usingSample: true };

  try {
    const db = createSupabaseServer();
    let q = db
      .from("reviews")
      .select("id, store, rating, title, body, author, reviewed_at, review_topics(topic), apps!inner(name, owner)")
      .order("reviewed_at", { ascending: false })
      .limit(100);
    if (opts.store) q = q.eq("store", opts.store);
    if (opts.maxRating) q = q.lte("rating", opts.maxRating);
    const { data, error } = await q;
    if (error) throw error;
    const rows: ReviewRow[] = (data ?? []).map((r: any) => ({
      id: r.id, store: r.store, rating: r.rating, title: r.title, body: r.body,
      author: r.author, app_name: r.apps?.name ?? "-", reviewed_at: r.reviewed_at,
      topics: (r.review_topics ?? []).map((t: any) => t.topic),
    }));
    return { rows, usingSample: false };
  } catch {
    return { rows: filterSample(opts), usingSample: true };
  }
}

function filterSample(opts: { store?: string; maxRating?: number }): ReviewRow[] {
  return SAMPLE_REVIEWS.filter(
    (r) => (!opts.store || r.store === opts.store) && (!opts.maxRating || r.rating <= opts.maxRating)
  );
}
