import type { PlanKey } from "./stripe";

/**
 * プラン別の機能制限を一元管理する。
 * 課金(profiles.plan)の値に応じて、アプリ数・AI返信数・自動取得を制御。
 */
export interface PlanLimits {
  /** 連携アプリの上限（null = 無制限） */
  maxApps: number | null;
  /** 月あたりのAI返信生成の上限（null = 無制限） */
  aiRepliesPerMonth: number | null;
  /**
   * 一括返信で1回に処理できるレビュー件数の上限。
   * 1 = 一括不可（1件ずつのみ）/ null = 無制限（全件一括）。
   */
  bulkReplyLimit: number | null;
  /** cronによる自動取得を許可するか（Freeは手動更新のみ） */
  autoPolling: boolean;
  /** 週次サマリーメールを配信するか（Pro以上） */
  weeklySummary: boolean;
}

export const PLAN_LIMITS: Record<PlanKey, PlanLimits> = {
  free: { maxApps: 1, aiRepliesPerMonth: 10, bulkReplyLimit: 1, autoPolling: false, weeklySummary: false },
  pro: { maxApps: 5, aiRepliesPerMonth: null, bulkReplyLimit: 20, autoPolling: true, weeklySummary: true },
  max: { maxApps: null, aiRepliesPerMonth: null, bulkReplyLimit: null, autoPolling: true, weeklySummary: true },
};

/** plan文字列（不正値含む）から制限を取得。未知の値はFree扱い。 */
export function limitsForPlan(plan: string | null | undefined): PlanLimits {
  if (plan === "pro" || plan === "max") return PLAN_LIMITS[plan];
  return PLAN_LIMITS.free;
}

/** 今月(UTC)の開始時刻をISO文字列で返す。月次上限のカウント境界に使う。 */
export function monthStartISO(now = new Date()): string {
  return new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), 1)).toISOString();
}
