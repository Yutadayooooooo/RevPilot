import { NextRequest, NextResponse } from "next/server";
import type Stripe from "stripe";
import { getStripe, planForPriceId } from "@/lib/stripe";
import { serviceClient } from "@/lib/supabase";

export const dynamic = "force-dynamic";
// Stripe の署名検証には生のリクエストボディが必要
export const runtime = "nodejs";

/**
 * Stripe Webhook。署名を検証し、サブスクの状態を profiles.plan に反映する。
 * Stripe ダッシュボードで購読するイベント:
 *   checkout.session.completed / customer.subscription.updated / customer.subscription.deleted
 */
export async function POST(req: NextRequest) {
  const stripe = getStripe();
  const secret = process.env.STRIPE_WEBHOOK_SECRET;
  if (!stripe || !secret) {
    return NextResponse.json({ error: "課金Webhookは未設定です" }, { status: 501 });
  }

  const sig = req.headers.get("stripe-signature");
  if (!sig) return NextResponse.json({ error: "missing signature" }, { status: 400 });

  const raw = await req.text();
  let event: Stripe.Event;
  try {
    event = stripe.webhooks.constructEvent(raw, sig, secret);
  } catch (err: any) {
    return NextResponse.json({ error: `signature verification failed: ${err.message}` }, { status: 400 });
  }

  try {
    switch (event.type) {
      case "checkout.session.completed": {
        const session = event.data.object as Stripe.Checkout.Session;
        if (session.mode === "subscription" && session.subscription) {
          const sub = await stripe.subscriptions.retrieve(session.subscription as string);
          await applySubscription(stripe, sub, session.client_reference_id ?? undefined);
        }
        break;
      }
      case "customer.subscription.created":
      case "customer.subscription.updated": {
        const sub = event.data.object as Stripe.Subscription;
        await applySubscription(stripe, sub);
        break;
      }
      case "customer.subscription.deleted": {
        const sub = event.data.object as Stripe.Subscription;
        await downgradeToFree(sub);
        break;
      }
      default:
        // 未購読イベントは無視（200を返す）
        break;
    }
  } catch (err: any) {
    // 500 を返すと Stripe が自動リトライする
    return NextResponse.json({ error: err.message }, { status: 500 });
  }

  return NextResponse.json({ received: true });
}

/** サブスク内容から plan を決定して profiles に反映 */
async function applySubscription(
  stripe: Stripe,
  sub: Stripe.Subscription,
  clientReferenceId?: string
) {
  const priceId = sub.items.data[0]?.price?.id;
  const plan = planForPriceId(priceId);
  // active / trialing 以外（unpaid, canceled など）は free 扱い
  const active = sub.status === "active" || sub.status === "trialing";
  const resolvedPlan = active && plan ? plan : "free";

  const userId = clientReferenceId ?? (sub.metadata?.userId as string | undefined);
  const customerId = typeof sub.customer === "string" ? sub.customer : sub.customer.id;

  const periodEnd = (sub as any).current_period_end as number | undefined;
  const patch = {
    plan: resolvedPlan,
    plan_status: sub.status,
    stripe_subscription_id: sub.id,
    stripe_customer_id: customerId,
    current_period_end: periodEnd ? new Date(periodEnd * 1000).toISOString() : null,
  };

  const db = serviceClient();
  if (userId) {
    await db.from("profiles").update(patch).eq("id", userId);
  } else {
    await db.from("profiles").update(patch).eq("stripe_customer_id", customerId);
  }
}

/** 解約時は free に戻す */
async function downgradeToFree(sub: Stripe.Subscription) {
  const customerId = typeof sub.customer === "string" ? sub.customer : sub.customer.id;
  const userId = sub.metadata?.userId as string | undefined;
  const patch = {
    plan: "free",
    plan_status: sub.status,
    stripe_subscription_id: null,
    current_period_end: null,
  };
  const db = serviceClient();
  if (userId) {
    await db.from("profiles").update(patch).eq("id", userId);
  } else {
    await db.from("profiles").update(patch).eq("stripe_customer_id", customerId);
  }
}
