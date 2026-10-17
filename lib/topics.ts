import { classifyTopics } from "./ai";
import { serviceClient } from "./supabase";
import { AI_UNITS, limitsForPlan } from "./plan";
import { aiUnitsUsed, QuotaError, refundAiUnits, reserveAiUnits } from "./quota";
import { runPool } from "./pool";
import type { SupabaseClient } from "@supabase/supabase-js";

/**
 * 保存済みレビューのトピック分類の埋め戻し。
 *
 * 【なぜ必要か】
 * 分類は取り込み(lib/poll.ts)のときにしか走らず、そのときのプランが
 * topicAnalysis を持っていなければ行わない。そのため Free で使っていた人が
 * Pro / Max を契約しても、手元のレビューには review_topics が1件も無く、
 * 分析タブのトピック傾向が「まだ分類されたレビューがありません」のままになる
 * （2026-10-17 実機で、Max を契約した直後に発生）。
 * 契約した直後に「何も出ない」のは、課金した機能が壊れているのと見分けがつかない。
 *
 * 【サブリクエストの予算】
 * Cloudflare Workers の無料プランは「1リクエストあたり外部サブリクエスト50回」。
 * lib/poll.ts が1件につき reserveAiUnits / Anthropic / upsert の3回を使っているのを
 * そのまま真似ると、30件で90回になり上限を大きく超える（超えた時点で fetch が落ち、
 * 予約済みのAI枠を払い戻せないまま残る）。
 * そこで枠の予約・払い戻し・review_topics の書き込みはまとめて1回ずつにし、
 * 1件あたりの外部呼び出しを Anthropic の1回だけにする。
 *   認証1 + profiles1 + レート制限1 + 使用量1 + 一覧1 + 本文1 + 予約1
 *   + 分類30 + 書き込み1 + 払い戻し1 = 39回。
 * Workers Paid（$5/月）にすると上限が10,000回になるのでこの制限は不要になる。
 */

/** 1回の呼び出しで分類する最大件数（上記の予算と、AI枠の消費量から決めた値）。 */
const MAX_PER_CALL = 30;

/** 未分類を探す範囲（新しい順）。分析で見るのは直近の傾向なので、古い方は切る。 */
const SCAN_LIMIT = 300;

/** 同時に投げる分類の数。無料プランの「同時外部接続6本」に収める。 */
const CONCURRENCY = 4;

export interface BackfillResult {
  /** 今回 review_topics を書けた件数。 */
  classified: number;
  /** まだ手をつけていない未分類の件数（範囲内）。呼び出し側は続きを頼める。 */
  remaining: number;
  /** 今月のAI枠が足りず、分類を始められなかった（または途中で足りなくなった）。 */
  quotaExhausted: boolean;
}

/**
 * 未分類の保存済みレビューを分類して review_topics に保存する。
 *
 * @param db     利用者としてのクライアント（RLSで自分のレビューだけが見える）。
 *               プランごとの閲覧範囲も RLS が決めるので、見えないレビューは対象にならない。
 *               書き込みだけは service_role で行う（review_topics は取り込み処理だけが
 *               書けるよう authenticated から insert を revoke してある）。
 * @param userId AI枠の持ち主。
 * @param plan   profiles.plan。topicAnalysis が無いプランでは何もしない。
 */
export async function backfillTopics(
  db: SupabaseClient,
  userId: string,
  plan: string | null | undefined
): Promise<BackfillResult> {
  const none: BackfillResult = { classified: 0, remaining: 0, quotaExhausted: false };
  if (!limitsForPlan(plan).topicAnalysis) return none;
  if (!process.env.ANTHROPIC_API_KEY) return none;

  // まず id と分類の有無だけを引く。本文まで300件ぶん受け取ると、
  // 無料プランの「1リクエスト10ms CPU」に対してJSONの解析だけで重くなる。
  const { data: scanned, error: scanError } = await db
    .from("reviews")
    .select("id, review_topics(topic)")
    .not("body", "is", null)
    .order("reviewed_at", { ascending: false, nullsFirst: false })
    .limit(SCAN_LIMIT);
  if (scanError) {
    console.error("[topics] 未分類レビューの一覧に失敗", scanError);
    return none;
  }

  const pendingIds = (scanned ?? [])
    .filter((r: any) => (r.review_topics?.length ?? 0) === 0)
    .map((r: any) => r.id as string);
  if (pendingIds.length === 0) return none;

  // 今月の残りで足りるぶんだけを対象にする。
  // まとめて予約するので、残量を見ずに投げると「1件も分類できない」で終わってしまう。
  const limit = limitsForPlan(plan).aiUnitsPerMonth;
  const affordable = Math.floor(Math.max(0, limit - (await aiUnitsUsed(userId))) / AI_UNITS.classify);
  const count = Math.min(pendingIds.length, MAX_PER_CALL, affordable);
  if (count === 0) {
    return { classified: 0, remaining: pendingIds.length, quotaExhausted: true };
  }

  const targetIds = pendingIds.slice(0, count);
  // 手をつけなかったぶん。呼び出し側はこれを見て続きを頼む
  // （分類したのにトピックが付かなかったレビューは、ここに数えない。
  //   数えると毎回同じレビューを送り直して永久に終わらない）。
  const remaining = pendingIds.length - targetIds.length;

  const { data: targets, error: bodyError } = await db
    .from("reviews")
    .select("id, rating, body")
    .in("id", targetIds);
  if (bodyError || !targets || targets.length === 0) {
    if (bodyError) console.error("[topics] 本文の取得に失敗", bodyError);
    return { classified: 0, remaining: pendingIds.length, quotaExhausted: false };
  }

  // 枠は1回でまとめて予約する（1件ずつだと件数ぶんのサブリクエストを使う）。
  // 足りなければ何も分類しない。中途半端に課金だけするより分かりやすい。
  try {
    await reserveAiUnits(userId, plan, AI_UNITS.classify * targets.length);
  } catch (e) {
    if (e instanceof QuotaError) {
      return { classified: 0, remaining: pendingIds.length, quotaExhausted: true };
    }
    throw e;
  }

  const rows: { review_id: string; topic: string }[] = [];
  let succeeded = 0;
  await runPool(targets, CONCURRENCY, async (r: any) => {
    try {
      const topics = await classifyTopics({ rating: r.rating, body: r.body });
      if (topics.length === 0) return; // 該当なし。予約ぶんは最後に払い戻す
      for (const topic of topics) rows.push({ review_id: r.id, topic });
      succeeded++;
    } catch (e) {
      console.error(`[topics] 分類に失敗 review=${r.id}`, e);
    }
  });

  let classified = succeeded;
  if (rows.length > 0) {
    const { error: insertError } = await serviceClient()
      .from("review_topics")
      .upsert(rows, { onConflict: "review_id,topic", ignoreDuplicates: true });
    if (insertError) {
      // 保存できなければ「分類できていない」のと同じ。全額払い戻す。
      console.error("[topics] review_topics の保存に失敗", insertError);
      classified = 0;
    }
  }

  // 分類できなかったぶん（該当なし・失敗・保存失敗）の枠を返す。
  const unused = targets.length - classified;
  if (unused > 0) await refundAiUnits(userId, AI_UNITS.classify * unused);

  return { classified, remaining, quotaExhausted: false };
}
