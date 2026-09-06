import type { PlanKey } from "./stripe";

/**
 * プラン別の機能制限を一元管理する。
 * 課金(profiles.plan)の値に応じて、アプリ数・AI返信数・自動取得の間隔を制御。
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
  /**
   * cronによる自動取得の間隔（時間）。null = 自動取得なし。
   * 全プラン毎時。取得そのものにAI原価がかからない（分類は topicAnalysis で別管理）ため、
   * 「気づくのが遅い無料版」で第一印象を損なうより、取得は全員に開放する。
   * 将来コストが問題になったらこの値だけ上げれば間隔を落とせる。
   */
  pollIntervalHours: number | null;
  /**
   * 新着レビューのAIトピック分類（分析タブの要望ランキング）。
   * レビュー件数に比例して原価がかかるため、無課金では走らせない。
   */
  topicAnalysis: boolean;
  /** 週次サマリーメールを配信するか（Pro以上） */
  weeklySummary: boolean;
}

/*
 * 上限の根拠（2026-09 時点）:
 *   原価  AI返信1件 ≈ $0.006 ≈ ¥1.0（claude-sonnet-5 / 入力約500tok・出力約300tok、再生成込みの安全側）
 *         トピック分類1件 ≈ $0.001 ≈ ¥0.16（レビュー取得件数に比例）
 *   純収入 ストア手数料15%（Small Business Program）を引いた額 … Pro ¥1,258 / Max ¥2,533
 *   方針  「上限に張り付いたユーザーでも黒字」を絶対条件にし、原価率は上限時で40%以下に置く。
 *         Pro 500件→原価¥500(40%) / Max 1,000件→原価¥1,000(39%)。
 *         旧値(Pro 1,000 / Max 5,000)はMaxが原価率197%で赤字だったため引き下げた。
 *   需要  個人開発アプリのレビューは多くて月100件程度。Pro=5アプリ×100件、Max=10アプリ×100件を
 *         カバーできるため、通常利用で上限に当たることはまずない。
 */
export const PLAN_LIMITS: Record<PlanKey, PlanLimits> = {
  free: { maxApps: 1, aiRepliesPerMonth: 5, bulkReplyLimit: 1, pollIntervalHours: 1, topicAnalysis: false, weeklySummary: false },
  pro: { maxApps: 5, aiRepliesPerMonth: 500, bulkReplyLimit: 20, pollIntervalHours: 1, topicAnalysis: true, weeklySummary: true },
  max: { maxApps: null, aiRepliesPerMonth: 1000, bulkReplyLimit: null, pollIntervalHours: 1, topicAnalysis: true, weeklySummary: true },
  // Team は現在非公開（共有・権限機能が未実装のため販売停止）。既存の plan 値のために定義は残す。
  team: { maxApps: null, aiRepliesPerMonth: 2000, bulkReplyLimit: null, pollIntervalHours: 1, topicAnalysis: true, weeklySummary: true },
};

/** plan文字列（不正値含む）から制限を取得。未知の値はFree扱い。 */
export function limitsForPlan(plan: string | null | undefined): PlanLimits {
  if (plan === "pro" || plan === "max" || plan === "team") return PLAN_LIMITS[plan];
  return PLAN_LIMITS.free;
}

/** 有料プランかどうか。 */
function isPaidPlan(plan: string | null | undefined): boolean {
  return plan === "pro" || plan === "max" || plan === "team";
}

/**
 * 月次AI返信の上限に達したときのユーザー向けメッセージ。
 * - Free: アップグレードを促す
 * - 有料: 翌月リセットと問い合わせ導線を案内
 */
export function aiQuotaReachedMessage(plan: string | null | undefined, limit: number): string {
  if (isPaidPlan(plan)) {
    return `今月のAI返信が上限（${limit.toLocaleString("en-US")}件）に達しました。翌月1日にリセットされます。継続的に上限の緩和が必要な場合はお問い合わせください。`;
  }
  return `今月のAI返信の上限（${limit}件）に達しました。Proにアップグレードすると月500件まで生成できます。`;
}

/** 今月(UTC)の開始時刻をISO文字列で返す。月次上限のカウント境界に使う。 */
export function monthStartISO(now = new Date()): string {
  return new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), 1)).toISOString();
}
