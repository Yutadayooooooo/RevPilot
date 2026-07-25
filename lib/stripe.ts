import Stripe from "stripe";

/**
 * Stripe（サブスク課金）クライアントと設定。
 * STRIPE_SECRET_KEY が無い環境（ローカルのサンプル表示など）では null を返し、
 * UI/API は「課金未設定」として穏やかに縮退する。
 */

export type PlanKey = "free" | "pro" | "max" | "team";

export interface PlanDef {
  key: PlanKey;
  name: string;
  /** 表示用の価格ラベル */
  price: string;
  features: string[];
  /** 中央（センターステージ）に置く推し。3層GBBの中間を最有力にする。 */
  popular?: boolean;
  /** individual=個人向け3層 / team=別セグメント（法人・チーム向け） */
  segment?: "individual" | "team";
  /** Stripe の price ID を入れた環境変数名（free は課金なし） */
  priceEnv?: "STRIPE_PRICE_PRO" | "STRIPE_PRICE_MAX" | "STRIPE_PRICE_TEAM";
}

/**
 * 個人開発者向けの Good-Better-Best 3層。
 * - 競合(Appbot $49~ / AppFollow $99~)より大幅に安価に設定（インディー価格）。
 * - 一括返信を段階的な価値軸に：Free=1件ずつ / Pro=最大20件 / Max=全件一括。
 * - Pro を「おすすめ」にしてセンターステージ効果で中間を最有力に。
 */
export const PLANS: PlanDef[] = [
  {
    key: "free",
    name: "Free",
    price: "¥0",
    features: ["1アプリ", "AI返信 月10件", "返信は1件ずつ", "手動更新"],
  },
  {
    key: "pro",
    name: "Pro",
    price: "¥1,480/月",
    popular: true,
    features: [
      "5アプリまで",
      "AI返信 無制限",
      "一括返信 最大20件",
      "自動取得",
      "週次サマリー",
    ],
    priceEnv: "STRIPE_PRICE_PRO",
  },
  {
    key: "max",
    name: "Max",
    price: "¥2,980/月",
    segment: "individual",
    features: [
      "アプリ無制限",
      "AI返信 無制限",
      "全レビュー 一括返信",
      "自動取得",
      "週次サマリー",
      "優先処理",
    ],
    priceEnv: "STRIPE_PRICE_MAX",
  },
  // 別セグメント：個人向け3層とは分けて提示し、中間(Pro)のセンターステージを保つ。
  {
    key: "team",
    name: "Team",
    price: "¥5,800/月",
    segment: "team",
    features: [
      "Maxの全機能",
      "複数メンバーで共有",
      "メンバー別の権限・履歴",
      "まとめて請求",
    ],
    priceEnv: "STRIPE_PRICE_TEAM",
  },
];

/** 課金が有効か（secret key があるか） */
export function billingConfigured(): boolean {
  return Boolean(process.env.STRIPE_SECRET_KEY);
}

let _stripe: Stripe | null = null;

/** Stripe クライアント。未設定なら null。 */
export function getStripe(): Stripe | null {
  if (!billingConfigured()) return null;
  if (!_stripe) {
    _stripe = new Stripe(process.env.STRIPE_SECRET_KEY!);
  }
  return _stripe;
}

/** プランキー → Stripe price ID（未設定・freeなら null） */
export function priceIdForPlan(plan: PlanKey): string | null {
  const def = PLANS.find((p) => p.key === plan);
  if (!def?.priceEnv) return null;
  return process.env[def.priceEnv] ?? null;
}

/** Stripe price ID → プランキー（webhook で使用） */
export function planForPriceId(priceId: string | null | undefined): PlanKey | null {
  if (!priceId) return null;
  for (const def of PLANS) {
    if (def.priceEnv && process.env[def.priceEnv] === priceId) return def.key;
  }
  return null;
}

/** リクエストから絶対URL（success/cancel/return 用）を組み立てる */
export function siteUrl(req: Request): string {
  const fromEnv = process.env.NEXT_PUBLIC_SITE_URL;
  if (fromEnv) return fromEnv.replace(/\/$/, "");
  return new URL(req.url).origin;
}
