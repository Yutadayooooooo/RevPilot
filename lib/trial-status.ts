import type { SupabaseClient } from "@supabase/supabase-js";

/**
 * 無料トライアル中かどうかを profiles.in_trial に記録する。
 *
 * 終了前の通知は送らない方針なので、代わりにプラン画面・設定画面で
 * 「Pro 無料トライアル中（M月d日まで）」をいつでも確認できるようにする。
 * 列がまだ無いDB（schema.sql 未適用）でも購入の反映を止めないよう、
 * プランの更新とは別に書き、失敗は無視する。
 */
export async function recordTrial(db: SupabaseClient, profileId: string, inTrial: boolean) {
  try {
    await db.from("profiles").update({ in_trial: inTrial }).eq("id", profileId);
  } catch {
    // 表示用の補助情報なので、失敗しても購入処理は続ける
  }
}
