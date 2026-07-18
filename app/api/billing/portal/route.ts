import { NextRequest, NextResponse } from "next/server";
import { createSupabaseServer, getCurrentUser } from "@/lib/supabase/server";
import { getStripe, siteUrl } from "@/lib/stripe";

export const dynamic = "force-dynamic";

/**
 * Stripe カスタマーポータルのセッションを作成し、URLを返す。
 * プラン変更・解約・支払い方法の管理をユーザー自身が行える。
 */
export async function POST(req: NextRequest) {
  const stripe = getStripe();
  if (!stripe) return NextResponse.json({ error: "課金は未設定です（STRIPE_SECRET_KEY）" }, { status: 501 });

  const user = await getCurrentUser();
  if (!user) return NextResponse.json({ error: "unauthorized" }, { status: 401 });

  const db = createSupabaseServer();
  const { data: profile } = await db
    .from("profiles")
    .select("stripe_customer_id")
    .eq("id", user.id)
    .maybeSingle();

  const customerId = profile?.stripe_customer_id as string | null | undefined;
  if (!customerId) {
    return NextResponse.json({ error: "Stripe 顧客が未作成です（先にプランを購入してください）" }, { status: 400 });
  }

  const session = await stripe.billingPortal.sessions.create({
    customer: customerId,
    return_url: `${siteUrl(req)}/settings`,
  });

  return NextResponse.json({ url: session.url });
}
