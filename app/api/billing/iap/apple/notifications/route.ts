import { NextRequest, NextResponse } from "next/server";
import { recordTrial } from "@/lib/trial-status";
import { serviceClient } from "@/lib/supabase";
import {
  appleIapConfigured,
  decodeJwsPayload,
  getAppleSubscriptionState,
} from "@/lib/iap-apple";

export const dynamic = "force-dynamic";
export const runtime = "nodejs";

/**
 * App Store Server Notifications V2 の受け口。
 * App Store Connect > App情報 > App Store Server Notifications にこのURLを登録する。
 *
 * 【これが無いと何が起きるか】
 * IAPで契約したユーザーがAppleで解約・返金しても、こちらのplanが有料のまま残る。
 * 以前は購入時に plan を書き込むだけで、失効を反映する経路がどこにも無かった。
 *
 * 【セキュリティ】
 * 通知の署名を自前で検証（x5c チェーンの検証）はしない。代わりに、
 * 通知からは originalTransactionId だけを取り出し、状態は必ず
 * App Store Server API に問い合わせて確定する。
 * したがって偽の通知を投げられても「Appleに聞き直す」以上のことは起きない。
 */
export async function POST(req: NextRequest) {
  if (!appleIapConfigured()) {
    return NextResponse.json({ error: "IAP未設定" }, { status: 501 });
  }

  const body = (await req.json().catch(() => ({}))) as { signedPayload?: string };
  if (!body.signedPayload) {
    return NextResponse.json({ error: "signedPayload required" }, { status: 400 });
  }

  // 通知本体 → data.signedTransactionInfo から originalTransactionId を取り出す
  const payload = decodeJwsPayload<any>(body.signedPayload);
  const signedTx = payload?.data?.signedTransactionInfo as string | undefined;
  const tx = signedTx ? decodeJwsPayload<any>(signedTx) : null;
  const originalTransactionId: string | undefined =
    tx?.originalTransactionId ?? payload?.data?.originalTransactionId;

  if (!originalTransactionId) {
    // 解釈できない通知でも 200 を返す（Appleに何度も再送させない）。
    console.warn("[iap] notification without originalTransactionId", payload?.notificationType);
    return NextResponse.json({ ok: true, ignored: true });
  }

  const db = serviceClient();
  const { data: profile } = await db
    .from("profiles")
    .select("id")
    .eq("apple_original_transaction_id", originalTransactionId)
    .maybeSingle();

  if (!profile) {
    // まだ購入確定APIを通っていない、または別環境の通知。無視してよい。
    return NextResponse.json({ ok: true, matched: false });
  }

  try {
    const state = await getAppleSubscriptionState(originalTransactionId);
    await db
      .from("profiles")
      .update({
        plan: state.active && state.plan ? state.plan : "free",
        plan_status: state.active ? "iap_active" : "iap_expired",
        apple_expires_at: state.expiresAt?.toISOString() ?? null,
        current_period_end: state.expiresAt?.toISOString() ?? null,
      })
      .eq("id", profile.id);
    await recordTrial(db, profile.id, state.inTrial);
  } catch (e: any) {
    console.error("[iap] failed to refresh subscription state", e);
    // 500 を返すと Apple が再送してくれる
    return NextResponse.json({ error: String(e?.message ?? e) }, { status: 500 });
  }

  return NextResponse.json({ ok: true });
}
