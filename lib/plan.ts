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
  /** cronによる自動取得を許可するか（Freeは手動更新のみ） */
  autoPolling: boolean;
}

export const PLAN_LIMITS: Record<PlanKey, PlanLimits> = {
  free: { maxApps: 1, aiRepliesPerMonth: 10, autoPolling: false },
  pro: { maxApps: null, aiRepliesPerMonth: null, autoPolling: true },
  team: { maxApps: null, aiRepliesPerMonth: null, autoPolling: true },
};

/** plan文字列（不正値含む）から制限を取得。未知の値はFree扱い。 */
export function limitsForPlan(plan: string | null | undefined): PlanLimits {
  if (plan === "pro" || plan === "team") return PLAN_LIMITS[plan];
  return PLAN_LIMITS.free;
}

/** 今月(UTC)の開始時刻をISO文字列で返す。月次上限のカウント境界に使う。 */
export function monthStartISO(now = new Date()): string {
  return new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), 1)).toISOString();
}
