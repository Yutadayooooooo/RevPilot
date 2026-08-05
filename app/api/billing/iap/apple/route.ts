import { NextRequest, NextResponse } from "next/server";
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
 *   - productId: 購入した商品ID（プランに対応）
 *   - verificationData: in_app_purchase の serverVerificationData（本番検証で使用）
 *
 * 検証は lib/iap-apple.ts に集約。鍵未設定の本番では 501（穏やかに縮退）。
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

  // 検証済みプランを反映。RLSでの自己更新は不正操作の余地があるため service_role で確定する。
  const db = serviceClient();
  const { error } = await db
    .from("profiles")
    .update({ plan: result.plan, plan_status: "iap_active" })
    .eq("id", user.id);
  if (error) {
    return NextResponse.json({ error: error.message }, { status: 500 });
  }

  return NextResponse.json({ ok: true, plan: result.plan, method: result.method });
}
