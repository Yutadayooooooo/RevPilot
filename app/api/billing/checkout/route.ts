import { NextRequest, NextResponse } from "next/server";
import { resolveApiAuth } from "@/lib/supabase/api-auth";
import { getStripe, priceIdForPlan, siteUrl, type PlanKey } from "@/lib/stripe";

export const dynamic = "force-dynamic";

/**
 * サブスク購入用の Stripe Checkout セッションを作成し、リダイレクト先URLを返す。
 * Web cookie / モバイル Bearer 両対応。body: { plan: "pro" | "max" }
 */
export async function POST(req: NextRequest) {
  const stripe = getStripe();
  if (!stripe) return NextResponse.json({ error: "課金は未設定です（STRIPE_SECRET_KEY）" }, { status: 501 });

  const auth = await resolveApiAuth(req);
  if (!auth) return NextResponse.json({ error: "unauthorized" }, { status: 401 });
  const { user, db } = auth;

  const { plan } = (await req.json()) as { plan?: PlanKey };
  if (plan !== "pro" && plan !== "max" && plan !== "team") {
    return NextResponse.json({ error: "plan は pro / max / team のいずれか" }, { status: 400 });
  }

  const priceId = priceIdForPlan(plan);
  if (!priceId) {
    return NextResponse.json({ error: `${plan} の price ID が未設定です` }, { status: 501 });
  }

  const { data: profile } = await db
    .from("profiles")
    .select("stripe_customer_id, email")
    .eq("id", user.id)
    .maybeSingle();

  // 既存の Stripe 顧客が無ければ作成し、profiles に保存
  let customerId = profile?.stripe_customer_id as string | null | undefined;
  if (!customerId) {
    const customer = await stripe.customers.create({
      email: user.email ?? profile?.email ?? undefined,
      metadata: { userId: user.id },
    });
    customerId = customer.id;
    await db.from("profiles").upsert(
      { id: user.id, email: user.email ?? null, stripe_customer_id: customerId },
      { onConflict: "id" }
    );
  }

  const base = siteUrl(req);
  const session = await stripe.checkout.sessions.create({
    mode: "subscription",
    customer: customerId,
    client_reference_id: user.id,
    line_items: [{ price: priceId, quantity: 1 }],
    allow_promotion_codes: true,
    subscription_data: { metadata: { userId: user.id } },
    success_url: `${base}/settings?billing=success`,
    cancel_url: `${base}/settings?billing=cancel`,
  });

  return NextResponse.json({ url: session.url });
}
