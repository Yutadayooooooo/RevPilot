import { NextRequest, NextResponse } from "next/server";
import { recordTrial } from "@/lib/trial-status";
import { resolveApiAuth } from "@/lib/supabase/api-auth";
import { serviceClient } from "@/lib/supabase";
import { verifyAppleTransaction, IapError } from "@/lib/iap-apple";

export const dynamic = "force-dynamic";
export const runtime = "nodejs";

/**
 * iOSのApp内課金(IAP)の購入/復元をサーバーで確定し、profiles.plan に反映する。
 * Stripe Webhook と同じ「サーバーが真実」の役割をIAPに対して担う。
 *
 * body: { productId, transactionId?, verificationData? }
 *
 * 検証は lib/iap-apple.ts に集約（App Store Server API に問い合わせて確定する）。
 * 失効はサーバー通知(/api/billing/iap/apple/notifications)と
 * cron の定期チェックの二重で反映する。
 */
export async function POST(req: NextRequest) {
  const auth = await resolveApiAuth(req);
  if (!auth) return NextResponse.json({ error: "unauthorized" }, { status: 401 });
  const { user } = auth;

  const body = (await req.json().catch(() => ({}))) as {
    productId?: string;
    transactionId?: string | null;
    verificationData?: string | null;
  };
  if (!body.productId) {
    return NextResponse.json({ error: "productId は必須です" }, { status: 400 });
  }

  let result;
  try {
    result = await verifyAppleTransaction({
      productId: body.productId,
      transactionId: body.transactionId ?? null,
      verificationData: body.verificationData ?? null,
    });
  } catch (err) {
    if (err instanceof IapError) {
      return NextResponse.json({ error: err.message }, { status: err.status });
    }
    return NextResponse.json({ error: (err as Error).message }, { status: 500 });
  }

  const db = serviceClient();

  // 同じ購入が別アカウントに紐づいていないか確認する。
  // これが無いと、1件のサブスクを復元して回るだけで複数アカウントを有料化できる。
  if (result.originalTransactionId) {
    const { data: existing } = await db
      .from("profiles")
      .select("id")
      .eq("apple_original_transaction_id", result.originalTransactionId)
      .maybeSingle();
    if (existing && existing.id !== user.id) {
      return NextResponse.json(
        { error: "この購入は別のアカウントで利用中です。購入時のApple IDと同じアカウントでログインしてください。" },
        { status: 409 }
      );
    }
  }

  // 検証済みプランを反映。RLSでの自己更新は塞いであるので、必ずここ(service_role)で確定する。
  const { error } = await db
    .from("profiles")
    .update({
      plan: result.plan,
      plan_status: "iap_active",
      apple_original_transaction_id: result.originalTransactionId,
      apple_expires_at: result.expiresAt?.toISOString() ?? null,
      current_period_end: result.expiresAt?.toISOString() ?? null,
    })
    .eq("id", user.id);
  if (error) {
    return NextResponse.json({ error: error.message }, { status: 500 });
  }
  await recordTrial(db, user.id, result.inTrial);

  return NextResponse.json({
    ok: true,
    plan: result.plan,
    method: result.method,
    expiresAt: result.expiresAt?.toISOString() ?? null,
    inTrial: result.inTrial,
  });
}
