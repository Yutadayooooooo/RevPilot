import Stripe from "stripe";

/**
 * Stripe（サブスク課金）クライアントと設定。
 * STRIPE_SECRET_KEY が無い環境（ローカルのサンプル表示など）では null を返し、
 * UI/API は「課金未設定」として穏やかに縮退する。
 */

export type PlanKey = "free" | "pro" | "team";

export interface PlanDef {
  key: PlanKey;
  name: string;
  /** 表示用の価格ラベル */
  price: string;
  features: string[];
  /** Stripe の price ID を入れた環境変数名（free は課金なし） */
  priceEnv?: "STRIPE_PRICE_PRO" | "STRIPE_PRICE_TEAM";
}

export const PLANS: PlanDef[] = [
  { key: "free", name: "Free", price: "¥0", features: ["1アプリ", "手動更新", "AI返信 月10件"] },
  {
    key: "pro",
    name: "Pro",
    price: "¥1,480/月",
    features: ["全アプリ", "自動取得", "AI返信 無制限", "週次サマリー"],
    priceEnv: "STRIPE_PRICE_PRO",
  },
  {
    key: "team",
    name: "Team",
    price: "¥2,980/月",
    features: ["複数メンバー", "Slack連携", "競合監視"],
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
