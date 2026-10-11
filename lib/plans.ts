/**
 * プランのカタログ（表示用の定義）。
 *
 * ここは Stripe SDK に依存させない。クライアントコンポーネントから読むため、
 * lib/stripe.ts に置くと Node向けの Stripe SDK がブラウザのバンドルに巻き込まれる。
 *
 * 定義の実体は shared/plans.json。Flutter 側（mobile/lib/plan_catalog.g.dart）も
 * 同じ JSON から生成しているので、プラン名・価格・特徴・上限・商品IDはそちらだけを変更する。
 */
import catalog from "@/shared/plans.json";

export type PlanKey = "free" | "pro" | "max" | "team";
export type BillingPeriod = "monthly" | "yearly";

export interface PlanPrice {
  /** 税込の円。ストア側の価格と一致させる（表示はストアが返す価格を優先）。 */
  yen: number;
  /** App Store / Google Play 共通の商品ID。未販売なら null。 */
  productId: string | null;
}

export interface PlanDef {
  key: PlanKey;
  name: string;
  /** 表示用の価格ラベル（月額） */
  price: string;
  /** 年額の表示ラベル（年額を販売していなければ undefined） */
  yearlyPrice?: string;
  /** 年額を月額12か月と比べたときの割引率（%）。 */
  yearlyDiscountPct?: number;
  /** カード上部に置く一言。「誰向けか」を先に示す。 */
  tagline: string;
  features: string[];
  /** 中央（センターステージ）に置く推し。3層GBBの中間を最有力にする。 */
  popular?: boolean;
  /** 販売停止中（UIに出さない）。既存契約のために定義だけ残すプラン。 */
  hidden?: boolean;
  /** 初回購入時の無料トライアル日数（ストアの導入オファーと一致させる）。 */
  trialDays?: number;
  prices?: Partial<Record<BillingPeriod, PlanPrice>>;
  /** Stripe の price ID を入れた環境変数名（現在Web決済は無効。将来用に定義だけ残す） */
  priceEnv?: "STRIPE_PRICE_PRO" | "STRIPE_PRICE_MAX" | "STRIPE_PRICE_TEAM";
}

interface RawPlan {
  key: string;
  name: string;
  tagline: string;
  features: string[];
  popular?: boolean;
  hidden?: boolean;
  trialDays?: number;
  prices?: Partial<Record<BillingPeriod, PlanPrice>>;
  priceEnv?: string;
}

const yen = (n: number) => `¥${n.toLocaleString("en-US")}`;

function toPlanDef(raw: RawPlan): PlanDef {
  const monthly = raw.prices?.monthly;
  const yearly = raw.prices?.yearly;
  return {
    key: raw.key as PlanKey,
    name: raw.name,
    price: monthly ? `${yen(monthly.yen)}/月` : "¥0",
    yearlyPrice: yearly ? `${yen(yearly.yen)}/年` : undefined,
    yearlyDiscountPct:
      monthly && yearly ? Math.round((1 - yearly.yen / (monthly.yen * 12)) * 100) : undefined,
    tagline: raw.tagline,
    features: raw.features,
    popular: raw.popular,
    hidden: raw.hidden,
    trialDays: raw.trialDays,
    prices: raw.prices,
    priceEnv: raw.priceEnv as PlanDef["priceEnv"],
  };
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
 *
 * 【2026-10 年額・無料トライアルの追加】
 *   - Pro / Max に年額（約2か月分お得）を追加。年額は解約の判断機会が年1回に減るので
 *     継続率が上がり、利用者にとっても安くなる。
 *   - Pro のみ初回14日間無料（ストアの導入オファー）。14日あれば週次サマリーが2回届き、
 *     AI返信・トピック分析を実際に使ってから判断できる。Max は Pro を入口にするため付けない。
 *
 * Team は販売停止中（hidden）。共有・権限・まとめて請求が未実装のため公開しない
 * （未実装機能の販売は景表法／ストア審査の両面でリスク）。実装が入るまで hidden のままにする。
 */
export const PLANS: PlanDef[] = (catalog.plans as RawPlan[]).map(toPlanDef);

/**
 * ストア商品ID → プラン。iOS / Android で同じIDを使う。
 * サーバーの購入検証（lib/iap-apple.ts / lib/iap-google.ts）はここだけを参照する。
 */
export const STORE_PRODUCT_TO_PLAN: Record<string, PlanKey> = Object.fromEntries(
  PLANS.flatMap((p) =>
    Object.values(p.prices ?? {})
      .filter((v): v is PlanPrice => Boolean(v?.productId))
      .map((v) => [v.productId as string, p.key])
  )
);

/** 公開中（購入可能）のプランのみ。UIはこちらを使う。 */
export const PUBLIC_PLANS: PlanDef[] = PLANS.filter((p) => !p.hidden);
