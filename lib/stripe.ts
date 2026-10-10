import Stripe from "stripe";
import { PLANS, PUBLIC_PLANS, type PlanDef, type PlanKey } from "./plans";

/**
 * Stripe（サブスク課金）クライアントと設定。
 * STRIPE_SECRET_KEY が無い環境（ローカルのサンプル表示など）では null を返し、
 * UI/API は「課金未設定」として穏やかに縮退する。
 *
 * 【注意】このモジュールは Stripe の Node SDK を読み込むのでサーバー専用。
 * クライアントコンポーネントからプラン定義を読みたい場合は lib/plans.ts を使うこと。
 */

export type { PlanDef, PlanKey };
export { PLANS, PUBLIC_PLANS };

/** 販売中のプランか（非公開プランの新規購入を止める） */
export function isPurchasablePlan(plan: PlanKey): boolean {
  return PUBLIC_PLANS.some((p) => p.key === plan && p.priceEnv);
}

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
