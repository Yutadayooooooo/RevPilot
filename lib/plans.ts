/**
 * プランのカタログ（表示用の定義）。
 *
 * ここは Stripe SDK に依存させない。クライアントコンポーネントから読むため、
 * lib/stripe.ts に置くと Node向けの Stripe SDK がブラウザのバンドルに巻き込まれる。
 *
 * 数値は lib/plan.ts の PLAN_LIMITS と必ず一致させること。
 */

export type PlanKey = "free" | "pro" | "max" | "team";

export interface PlanDef {
  key: PlanKey;
  name: string;
  /** 表示用の価格ラベル */
  price: string;
  /** カード上部に置く一言。「誰向けか」を先に示す。 */
  tagline: string;
  features: string[];
  /** 中央（センターステージ）に置く推し。3層GBBの中間を最有力にする。 */
  popular?: boolean;
  /** 販売停止中（UIに出さない）。既存契約のために定義だけ残すプラン。 */
  hidden?: boolean;
  /** Stripe の price ID を入れた環境変数名（現在Web決済は無効。将来用に定義だけ残す） */
  priceEnv?: "STRIPE_PRICE_PRO" | "STRIPE_PRICE_MAX" | "STRIPE_PRICE_TEAM";
}

/**
 * 個人開発者向けの Good-Better-Best 3層。
 *
 * 【2026-09 の階層見直し】
 * 旧設計は課金の壁を「アプリ数」に置いていたが、これはターゲットに刺さらなかった:
 *   - 個人開発者は小さいアプリを3〜10本持っている。ここを絞ると「じゃあいいや」になり、
 *     増やすほど惰性で残る（＝解約されにくい）。壁ではなく撤去すべき軸だった。
 *   - 1アプリ・月数件のレビューという典型的な利用者は、Freeで永久に足りてしまい、
 *     AI件数・一括件数・アプリ数のどの上限にも一生到達しない。
 *
 * 新しい壁は「レビュー履歴の保存期間」。
 * Google Play の API は直近7日ぶんしか返さず、それ以前は取得できない。
 * RevPilot が定期取得して蓄積することで履歴が残る、というのが本サービス唯一の
 * 代替不能な価値なので、そこを直接プランの軸にする。
 *   - Free でも30日は見える（Google Play の7日より価値がある＝無料でも役に立つ）
 *   - 31日目に「先月のレビューが見られない」で初めて壁に当たる
 *   - 原価ゼロで効く壁（データは消さずに見せないだけ。課金すれば即座に全部見える）
 */
export const PLANS: PlanDef[] = [
  {
    key: "free",
    name: "Free",
    price: "¥0",
    tagline: "まず1本のアプリで試す",
    features: [
      "1アプリ",
      "レビュー履歴 30日",
      "AI返信 月3件",
      "自動取得 毎時・新着通知",
    ],
  },
  {
    key: "pro",
    name: "Pro",
    price: "¥1,480/月",
    tagline: "個人開発者の標準",
    popular: true,
    features: [
      "アプリ数 無制限",
      "レビュー履歴 無期限",
      "AI返信 月300件",
      "一括返信 最大20件",
      "トピック分析",
      "週次サマリー",
    ],
    priceEnv: "STRIPE_PRICE_PRO",
  },
  {
    key: "max",
    name: "Max",
    price: "¥2,980/月",
    tagline: "レビューが多い・返信量が多い方へ",
    features: [
      "Pro のすべて",
      "AI返信 月1,000件",
      "一括返信 最大50件",
      "優先サポート",
    ],
    priceEnv: "STRIPE_PRICE_MAX",
  },
  // 販売停止中。共有・権限・まとめて請求が未実装のため公開しない（未実装機能の販売は
  // 景表法／ストア審査の両面でリスク）。実装が入るまで hidden のままにする。
  {
    key: "team",
    name: "Team",
    price: "¥5,800/月",
    tagline: "チームで運用する",
    hidden: true,
    features: ["Maxの全機能", "複数メンバーで共有", "メンバー別の権限・履歴", "まとめて請求"],
    priceEnv: "STRIPE_PRICE_TEAM",
  },
];

/** 公開中（購入可能）のプランのみ。UIはこちらを使う。 */
export const PUBLIC_PLANS: PlanDef[] = PLANS.filter((p) => !p.hidden);
