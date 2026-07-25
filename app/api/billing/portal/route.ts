import { NextRequest, NextResponse } from "next/server";
import { resolveApiAuth } from "@/lib/supabase/api-auth";
import { getStripe, siteUrl } from "@/lib/stripe";

export const dynamic = "force-dynamic";

/**
 * Stripe カスタマーポータルのセッションを作成し、URLを返す。
 * Web cookie / モバイル Bearer 両対応。
 * プラン変更・解約・支払い方法の管理をユーザー自身が行える。
 */
export async function POST(req: NextRequest) {
  const stripe = getStripe();
  if (!stripe) return NextResponse.json({ error: "課金は未設定です（STRIPE_SECRET_KEY）" }, { status: 501 });

  const auth = await resolveApiAuth(req);
  if (!auth) return NextResponse.json({ error: "unauthorized" }, { status: 401 });
  const { user, db } = auth;

  const { data: profile } = await db
    .from("profiles")
    .select("stripe_customer_id")
    .eq("id", user.id)
    .maybeSingle();

  const customerId = profile?.stripe_customer_id as string | null | undefined;
  if (!customerId) {
    return NextResponse.json({ error: "Stripe 顧客が未作成です（先にプランを購入してください）" }, { status: 400 });
  }

  // 明示的な構成があれば使う（新規アカウントで既定構成が無い場合の対策）。
  const configuration = process.env.STRIPE_PORTAL_CONFIGURATION_ID || undefined;
  const session = await stripe.billingPortal.sessions.create({
    customer: customerId,
    return_url: `${siteUrl(req)}/settings`,
    ...(configuration ? { configuration } : {}),
  });

  return NextResponse.json({ url: session.url });
}
