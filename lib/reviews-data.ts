import { createSupabaseServer, getCurrentUser } from "./supabase/server";
import { serviceClient } from "./supabase";
import { SAMPLE_REVIEWS, type ReviewRow } from "./sample";

/**
 * ログインユーザーのレビューを返す（RLSで自動スコープ）。
 *
 * 【重要】ログイン済みユーザーにサンプルデータを見せてはいけない。
 * 以前は例外を握り潰してサンプル（架空アプリ MyHabit / Focus Timer のレビュー）を
 * 返していたため、DBが一時的に落ちただけで、課金ユーザーの画面に
 * 存在しないアプリのレビューが「自分のデータ」として表示されていた。
 * レビュー監視ツールにとってこれは致命的なので、失敗は失敗として返す。
 */
export async function getReviews(opts: { store?: string; maxRating?: number } = {}): Promise<{
  rows: ReviewRow[];
  usingSample: boolean;
  error: string | null;
}> {
  const user = await getCurrentUser();
  // 未ログイン（＝ローカルでのプレビュー）のときだけサンプルを見せる
  if (!user) return { rows: filterSample(opts), usingSample: true, error: null };

  try {
    const db = await createSupabaseServer();
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
    return { rows, usingSample: false, error: null };
  } catch (e: any) {
    console.error("[reviews-data] failed", e);
    return {
      rows: [],
      usingSample: false,
      error: "レビューを読み込めませんでした。時間をおいて再読み込みしてください。",
    };
  }
}

export interface ReviewStats {
  total: number;
  avgRating: number | null;
  lowCount: number;
  requestCount: number;
}

/**
 * 概要カードの数値。集計はDB側で行う。
 *
 * 以前は「直近100件を取得してJS側で平均」していたため、レビューが100件を超えた
 * 時点で「平均評価（全アプリ）」の数字が静かにずれていた。
 */
export async function getReviewStats(): Promise<ReviewStats | null> {
  const user = await getCurrentUser();
  if (!user) return null;
  try {
    const { data, error } = await serviceClient().rpc("review_stats", { p_owner: user.id });
    if (error) throw error;
    const row = Array.isArray(data) ? data[0] : data;
    return {
      total: Number(row?.total ?? 0),
      avgRating: row?.avg_rating === null || row?.avg_rating === undefined ? null : Number(row.avg_rating),
      lowCount: Number(row?.low_count ?? 0),
      requestCount: Number(row?.request_count ?? 0),
    };
  } catch (e) {
    console.error("[reviews-data] stats failed", e);
    return null;
  }
}

/** 平均評価の日次推移（直近30日）。データが無ければ空配列（サンプルは返さない）。 */
export async function getDailyAverages(days = 30): Promise<{ date: string; avg: number }[]> {
  const user = await getCurrentUser();
  if (!user) return [];
  try {
    const { data, error } = await serviceClient().rpc("review_daily_avg", {
      p_owner: user.id,
      p_days: days,
    });
    if (error) throw error;
    return (data ?? []).map((r: any) => {
      const d = new Date(`${r.day}T00:00:00Z`);
      return {
        date: `${d.getUTCMonth() + 1}/${d.getUTCDate()}`,
        avg: Number(r.avg_rating),
      };
    });
  } catch (e) {
    console.error("[reviews-data] daily avg failed", e);
    return [];
  }
}

function filterSample(opts: { store?: string; maxRating?: number }): ReviewRow[] {
  return SAMPLE_REVIEWS.filter(
    (r) => (!opts.store || r.store === opts.store) && (!opts.maxRating || r.rating <= opts.maxRating)
  );
}
