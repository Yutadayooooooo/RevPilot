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

// 有料プランは表向き「無制限」だが、原価保護のための"フェアユース上限"を内部的に設ける。
// 通常利用（月〜数百件）ではまず到達しない高い水準。到達時も翌月リセットで穏やかに縮退。
// 参考原価: AI返信1件 ≈ $0.005。Pro(¥1,480≈$10)で1,000件でも原価$5に収まる。
export const PLAN_LIMITS: Record<PlanKey, PlanLimits> = {
  free: { maxApps: 1, aiRepliesPerMonth: 10, bulkReplyLimit: 1, autoPolling: false, weeklySummary: false },
  pro: { maxApps: 5, aiRepliesPerMonth: 1000, bulkReplyLimit: 20, autoPolling: true, weeklySummary: true },
  max: { maxApps: null, aiRepliesPerMonth: 5000, bulkReplyLimit: null, autoPolling: true, weeklySummary: true },
  // Team は複数メンバーで共有するため、フェアユース上限も高めに設定。
  team: { maxApps: null, aiRepliesPerMonth: 20000, bulkReplyLimit: null, autoPolling: true, weeklySummary: true },
};

/** plan文字列（不正値含む）から制限を取得。未知の値はFree扱い。 */
export function limitsForPlan(plan: string | null | undefined): PlanLimits {
  if (plan === "pro" || plan === "max" || plan === "team") return PLAN_LIMITS[plan];
  return PLAN_LIMITS.free;
}

/** 有料プラン（フェアユース上限を持つ）かどうか。 */
function isPaidPlan(plan: string | null | undefined): boolean {
  return plan === "pro" || plan === "max" || plan === "team";
}

/**
 * 月次AI返信の上限に達したときのユーザー向けメッセージ。
 * - Free: アップグレードを促す
 * - 有料（フェアユース上限）: 翌月リセットと問い合わせ導線を案内（“無制限”の体験を壊さない）
 */
export function aiQuotaReachedMessage(plan: string | null | undefined, limit: number): string {
  if (isPaidPlan(plan)) {
    return `今月のAI返信が公正利用の上限（${limit.toLocaleString("en-US")}件）に達しました。翌月1日にリセットされます。継続的に上限の緩和が必要な場合はお問い合わせください。`;
  }
  return `今月のAI返信の上限（${limit}件）に達しました。Pro以上のプランで大幅に拡大できます。`;
}

/** 今月(UTC)の開始時刻をISO文字列で返す。月次上限のカウント境界に使う。 */
export function monthStartISO(now = new Date()): string {
  return new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), 1)).toISOString();
}
