import catalog from "@/shared/plans.json";
import type { PlanKey } from "./plans";

/**
 * プラン別の機能制限を一元管理する。
 * 課金(profiles.plan)の値に応じて、履歴期間・AI使用量・アプリ数を制御。
 */
export interface PlanLimits {
  /** 連携アプリの上限（null = 無制限）。DB側 enforce_app_limit() と一致させること。 */
  maxApps: number | null;
  /**
   * さかのぼって閲覧できるレビューの日数（null = 無期限）。
   * これが本サービスの主要な課金の壁。DB側の reviews のRLSポリシーと一致させること
   * （クライアントは Supabase に直接クエリするので、UI側のフィルタだけでは守れない）。
   */
  historyDays: number | null;
  /**
   * 月あたりのAI使用量の上限（units）。返信生成もトピック分類もここから引く。
   * 「返信N件」と「分類M件」で別々に上限を持たない理由は AI_UNITS のコメント参照。
   */
  aiUnitsPerMonth: number;
  /**
   * 一括返信で1回に処理できるレビュー件数の上限。
   * 1 = 一括不可（1件ずつのみ）。
   * null にはしない：無制限にすると1リクエストが関数の実行時間上限を超えて
   * 中途半端に打ち切られ、課金だけ発生して結果が返らない事故になる。
   */
  bulkReplyLimit: number;
  /** cronによる自動取得の間隔（時間）。null = 自動取得なし。全プラン毎時。 */
  pollIntervalHours: number | null;
  /**
   * 新着レビューのAIトピック分類（分析タブの要望ランキング）。
   * 原価は aiUnitsPerMonth から引かれるので、上限が青天井になることはない。
   */
  topicAnalysis: boolean;
  /** 週次サマリーメールを配信するか（Pro以上） */
  weeklySummary: boolean;
}

/**
 * AI操作1回あたりの課金単位。
 *
 * 「返信は月N件まで」「分類は無制限」という設計にはしない。分類はレビュー取得件数に
 * 比例して発生し、Pro/Maxはアプリ数が無制限なので、分類を計測しないと1ユーザーの原価が
 * 青天井になるため。両方を同じ units プールから引くことで、プランの原価上限が
 * aiUnitsPerMonth ひとつで決まる（＝アプリ数を無制限にしても赤字にならない）。
 *
 * 1 unit ≈ ¥0.14。supabase/schema.sql の consume_ai_units のコメントと一致させること。
 */
export const AI_UNITS = {
  /** 返信ドラフト生成1件 ≈ ¥1.4 */
  reply: 10,
  /** トピック分類1件 ≈ ¥0.3 */
  classify: 2,
} as const;

/*
 * 上限の根拠（2026-09 改訂）:
 *
 *   原価
 *     claude-sonnet-5 は $3/MTok(in) / $15/MTok(out)。
 *     lib/ai.ts の draftReply は max_tokens=400、プロンプトは「350文字以内」。
 *     日本語は1文字 ≈ 1.5〜2トークンなので出力は上限の400に張り付く。
 *     入力もシステムプロンプト(約300tok)＋レビュー本文(切り詰め後 最大約800tok)で1,000tok級。
 *       → 1,000 × $3/M + 400 × $15/M = $0.009 ≈ ¥1.4
 *     分類は入力約360tok・出力60tokで $0.002 ≈ ¥0.3。
 *
 *   純収入（ストア手数料15% = Apple Small Business / Google の定期購入料率）
 *     Pro ¥1,258 / Max ¥2,533
 *
 *   「上限に張り付いたユーザーでも黒字」を満たす値:
 *     Free 30 units    = 返信3件    = ¥4.2（獲得コストとして許容）
 *     Pro  3,000 units = 返信300件  = ¥420   → 粗利 ¥838（原価率33%）
 *     Max  10,000 units= 返信1,000件= ¥1,400 → 粗利 ¥1,133（原価率55%）
 *
 *   年額（2026-10 追加）でも上限に張り付いたユーザーで黒字を保つ:
 *     Pro ¥14,800/年 → 純収入 月あたり ¥1,048 → 粗利 ¥628（原価率40%）
 *     Max ¥29,800/年 → 純収入 月あたり ¥2,111 → 粗利 ¥711（原価率66%）
 *   無料トライアル（Pro 14日）の原価は最大でも返信300件ぶん ¥420。
 *
 *   なぜアプリ数の上限を外したか
 *     アプリ数は原価にほぼ影響しない（取得はAI原価ゼロ）。分類の原価はAI枠で頭打ちに
 *     なるので、アプリ数を無制限にしても損失は増えない。一方でアプリ数の制限は
 *     ターゲット（小さいアプリを複数持つ個人開発者）の離脱要因そのものだった。
 *
 *   なぜ「無制限」表記をやめたか
 *     注記付きの「無制限」は打消し表示として景表法上のリスクを負うだけで、
 *     実額を書くのに比べて得るものがない。AI件数は実数を出す。
 */
// 数値の実体は shared/plans.json（Flutter 側と共有）。上の根拠を変えたらJSONを更新する。
// Team は現在非公開（共有・権限機能が未実装のため販売停止）。既存の plan 値のために定義は残す。
export const PLAN_LIMITS = Object.fromEntries(
  catalog.plans.map((p) => [p.key, p.limits as PlanLimits])
) as Record<PlanKey, PlanLimits>;

/** plan文字列（不正値含む）から制限を取得。未知の値はFree扱い。 */
export function limitsForPlan(plan: string | null | undefined): PlanLimits {
  if (plan === "pro" || plan === "max" || plan === "team") return PLAN_LIMITS[plan];
  return PLAN_LIMITS.free;
}

/** 有料プランかどうか。 */
export function isPaidPlan(plan: string | null | undefined): boolean {
  return plan === "pro" || plan === "max" || plan === "team";
}

/** units を「AI返信◯件ぶん」に直した表示用の値。 */
export function repliesFromUnits(units: number): number {
  return Math.floor(units / AI_UNITS.reply);
}

/**
 * 月次AI枠を使い切ったときのユーザー向けメッセージ。
 * - Free: アップグレードを促す
 * - 有料: 翌月リセットと問い合わせ導線を案内
 */
export function aiQuotaReachedMessage(plan: string | null | undefined, units: number): string {
  const replies = repliesFromUnits(units).toLocaleString("en-US");
  if (isPaidPlan(plan)) {
    return `今月のAI利用枠（AI返信 ${replies}件ぶん）を使い切りました。翌月1日にリセットされます。枠の追加が必要な場合はお問い合わせください。`;
  }
  const proReplies = repliesFromUnits(PLAN_LIMITS.pro.aiUnitsPerMonth).toLocaleString("en-US");
  return `今月のAI返信の上限（${replies}件）に達しました。Proにアップグレードすると月${proReplies}件まで生成できます。`;
}

/** 履歴の閲覧範囲を超えたときの案内文（アップセル）。 */
export function historyLimitMessage(days: number): string {
  return `Freeプランでは直近${days}日ぶんのレビューを表示します。それ以前のレビューも保存されているので、Proにアップグレードするとすぐに全期間を閲覧できます。`;
}

/** 今月(UTC)の開始時刻をISO文字列で返す。ai_usage の ym と同じ境界。 */
export function monthStartISO(now = new Date()): string {
  return new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), 1)).toISOString();
}
