import { serviceClient } from "./supabase";
import { AI_UNITS, aiQuotaReachedMessage, limitsForPlan } from "./plan";

/**
 * AI原価とリクエスト頻度の上限。
 *
 * 【なぜテーブルで数えるのか】
 * 以前は replies の行数を数えて月次上限にしていたが、これは二重に破れていた:
 *   1. replies はユーザーが削除できたため、消してから再生成すれば無限に使えた。
 *   2. 「カウント → 生成 → 挿入」の間に競合があり、並列で投げると全リクエストが
 *      同じ「使用0件」を読んで上限チェックを通過した（TOCTOU）。
 * そのため生成の“前に”原子的に予約する方式に変える。予約に失敗したら生成しない。
 */

/** 上限超過。呼び出し側はこのstatusでそのまま応答してよい。 */
export class QuotaError extends Error {
  readonly status: number;
  constructor(message: string, status = 429) {
    super(message);
    this.status = status;
  }
}

/**
 * AI枠を予約する。足りなければ QuotaError を投げる（＝生成は行われない）。
 * @param units 消費する units（AI_UNITS.reply / AI_UNITS.classify の倍数）
 */
export async function reserveAiUnits(
  userId: string,
  plan: string | null | undefined,
  units: number
): Promise<void> {
  if (units <= 0) return;
  const limit = limitsForPlan(plan).aiUnitsPerMonth;
  const db = serviceClient();
  const { data, error } = await db.rpc("consume_ai_units", {
    p_user: userId,
    p_units: units,
    p_limit: limit,
  });

  if (error) {
    // 原価の制御機構なので、動かないときは「通す」のではなく「止める」。
    console.error("[quota] consume_ai_units failed", error);
    throw new QuotaError(
      "利用量の確認に失敗したため、AI機能を一時的に停止しています。時間をおいて再度お試しください。",
      503
    );
  }
  if (typeof data !== "number" || data < 0) {
    throw new QuotaError(aiQuotaReachedMessage(plan, limit), 403);
  }
}

/** 予約済みの枠を戻す（生成や投稿が失敗したとき）。失敗しても呼び出し側は続行してよい。 */
export async function refundAiUnits(userId: string, units: number): Promise<void> {
  if (units <= 0) return;
  try {
    await serviceClient().rpc("refund_ai_units", { p_user: userId, p_units: units });
  } catch (e) {
    console.error("[quota] refund_ai_units failed", e);
  }
}

/**
 * 今月の使用済み units。表示用。
 * ここは残数を出すだけの補助情報なので、取れなくても画面全体を巻き込まない。
 */
export async function aiUnitsUsed(userId: string): Promise<number> {
  try {
    const ym = new Date().toISOString().slice(0, 7); // UTC 'YYYY-MM'
    const { data } = await serviceClient()
      .from("ai_usage")
      .select("units")
      .eq("user_id", userId)
      .eq("ym", ym)
      .maybeSingle();
    return (data?.units as number | undefined) ?? 0;
  } catch (e) {
    console.error("[quota] aiUnitsUsed failed", e);
    return 0;
  }
}

/** 一括処理で「あと何件生成できるか」。予約はしないので、実行時は必ず reserveAiUnits を通すこと。 */
export async function remainingReplies(
  userId: string,
  plan: string | null | undefined
): Promise<number> {
  const limit = limitsForPlan(plan).aiUnitsPerMonth;
  const used = await aiUnitsUsed(userId);
  return Math.max(0, Math.floor((limit - used) / AI_UNITS.reply));
}

/**
 * 固定窓のレート制限。true なら実行してよい。
 * 外部サービス(Upstash等)を足さずに済むよう、Postgres の関数で原子的に処理する。
 * @param bucket 用途ごとの識別子（'poll' / 'bulk' など）
 */
export async function takeRateToken(
  userId: string,
  bucket: string,
  windowSeconds: number,
  max: number
): Promise<boolean> {
  const { data, error } = await serviceClient().rpc("take_rate_token", {
    p_user: userId,
    p_bucket: bucket,
    p_window_seconds: windowSeconds,
    p_max: max,
  });
  if (error) {
    // レート制限が壊れているときは通す（機能停止よりは軽い被害）。
    // AI枠と違い、ここを通しても直接の金銭被害は出ない。
    console.error("[quota] take_rate_token failed", error);
    return true;
  }
  return data === true;
}
