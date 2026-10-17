import { classifyTopics } from "./ai";
import { serviceClient } from "./supabase";
import { AI_UNITS, limitsForPlan } from "./plan";
import { QuotaError, refundAiUnits, reserveAiUnits } from "./quota";
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
 * 分類1件 = AI_UNITS.classify を消費するので、1回の呼び出しで分類する件数と
 * さかのぼる範囲の両方に上限を置く。足りなければ呼び出し側が続きを頼む。
 */

/** 1回の呼び出しで分類する最大件数（AI枠の消費と実行時間の上限）。 */
const MAX_PER_CALL = 60;

/** 未分類を探す範囲（新しい順）。分析で見るのは直近の傾向なので、古い方は切る。 */
const SCAN_LIMIT = 300;

/** 同時に投げる分類の数。lib/poll.ts の CLASSIFY_CONCURRENCY と同じ考え方。 */
const CONCURRENCY = 4;

export interface BackfillResult {
  /** 今回 review_topics を書けた件数。 */
  classified: number;
  /** まだ分類できていない件数（範囲内）。 */
  remaining: number;
  /** 今月のAI枠を使い切って打ち切ったか。 */
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

  // 埋め込みの review_topics が空の行＝未分類。
  // id を集めて in(...) で引くとURLが長くなりすぎるので、1クエリで済ませる。
  const { data, error } = await db
    .from("reviews")
    .select("id, rating, body, review_topics(topic)")
    .not("body", "is", null)
    .order("reviewed_at", { ascending: false, nullsFirst: false })
    .limit(SCAN_LIMIT);
  if (error) {
    console.error("[topics] 未分類レビューの取得に失敗", error);
    return none;
  }

  const pending = (data ?? []).filter(
    (r: any) => r.body && (r.review_topics?.length ?? 0) === 0
  );
  const targets = pending.slice(0, MAX_PER_CALL);
  if (targets.length === 0) return none;

  const writer = serviceClient();
  let classified = 0;
  let quotaExhausted = false;
  await runPool(targets, CONCURRENCY, async (r: any) => {
    if (quotaExhausted) return;
    try {
      await reserveAiUnits(userId, plan, AI_UNITS.classify);
    } catch (e) {
      // 枠切れは異常ではない。以降をやめて、分類できたぶんだけ返す。
      if (e instanceof QuotaError) quotaExhausted = true;
      return;
    }
    try {
      const topics = await classifyTopics({ rating: r.rating, body: r.body });
      if (topics.length === 0) {
        await refundAiUnits(userId, AI_UNITS.classify);
        return;
      }
      const { error: insertError } = await writer
        .from("review_topics")
        .upsert(
          topics.map((topic) => ({ review_id: r.id, topic })),
          { onConflict: "review_id,topic", ignoreDuplicates: true }
        );
      if (insertError) throw insertError;
      classified++;
    } catch (e) {
      await refundAiUnits(userId, AI_UNITS.classify);
      console.error(`[topics] 分類に失敗 review=${r.id}`, e);
    }
  });

  return { classified, remaining: pending.length - classified, quotaExhausted };
}
