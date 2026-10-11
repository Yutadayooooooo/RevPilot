import { NextRequest, NextResponse } from "next/server";
import { resolveApiAuth } from "@/lib/supabase/api-auth";
import { serviceClient } from "@/lib/supabase";
import {
  GoogleIapError,
  acknowledgeGooglePurchase,
  getGoogleSubscriptionState,
  googleIapConfigured,
} from "@/lib/iap-google";

export const dynamic = "force-dynamic";
export const runtime = "nodejs";

/**
 * Android のアプリ内課金（Google Play Billing）の購入/復元をサーバーで確定する。
 * Apple 側（/api/billing/iap/apple）と対になる処理。
 *
 * body: { purchaseToken, productId }
 *   purchaseToken … in_app_purchase の serverVerificationData
 *
 * クライアントの申告は使わず、purchaseToken で Google に問い合わせて確定する。
 */
export async function POST(req: NextRequest) {
  const auth = await resolveApiAuth(req);
  if (!auth) return NextResponse.json({ error: "unauthorized" }, { status: 401 });
  const { user } = auth;

  if (!googleIapConfigured()) {
    return NextResponse.json(
      { error: "Android課金は現在ご利用いただけません（サーバー設定が未完了です）。" },
      { status: 501 }
    );
  }

  const body = (await req.json().catch(() => ({}))) as {
    purchaseToken?: string;
    productId?: string;
  };
  if (!body.purchaseToken) {
    return NextResponse.json({ error: "purchaseToken は必須です" }, { status: 400 });
  }

  let state;
  try {
    state = await getGoogleSubscriptionState(body.purchaseToken);
  } catch (err) {
    if (err instanceof GoogleIapError) {
      return NextResponse.json({ error: err.message }, { status: err.status });
    }
    return NextResponse.json({ error: (err as Error).message }, { status: 500 });
  }

  if (!state.active || !state.plan) {
    return NextResponse.json(
      { error: "この購入は現在有効ではありません（期限切れ・返金済みの可能性があります）。" },
      { status: 403 }
    );
  }

  const db = serviceClient();

  // 同じ購入が別アカウントに紐づいていないか確認する。
  // これが無いと、1件のサブスクを復元して回るだけで複数アカウントを有料化できる。
  const { data: existing } = await db
    .from("profiles")
    .select("id")
    .eq("google_purchase_token", state.purchaseToken)
    .maybeSingle();
  if (existing && existing.id !== user.id) {
    return NextResponse.json(
      { error: "この購入は別のアカウントで利用中です。購入時のGoogleアカウントに紐づくアカウントでログインしてください。" },
      { status: 409 }
    );
  }

  // 3日以内に確認しないとGoogleが自動返金する。クライアント側の確認を取りこぼしても
  // ここで確実に確認しておく。
  if (state.needsAcknowledgement && state.productId) {
    await acknowledgeGooglePurchase(state.purchaseToken, state.productId);
  }

  const { error } = await db
    .from("profiles")
    .update({
      plan: state.plan,
      plan_status: "iap_active",
      google_purchase_token: state.purchaseToken,
      google_expires_at: state.expiresAt?.toISOString() ?? null,
      current_period_end: state.expiresAt?.toISOString() ?? null,
    })
    .eq("id", user.id);
  if (error) {
    return NextResponse.json({ error: error.message }, { status: 500 });
  }

  return NextResponse.json({
    ok: true,
    plan: state.plan,
    method: "google-play-developer-api",
    expiresAt: state.expiresAt?.toISOString() ?? null,
    inTrial: state.inTrial,
  });
}
