import { NextRequest, NextResponse } from "next/server";
import { recordTrial } from "@/lib/trial-status";
import { serviceClient } from "@/lib/supabase";
import {
  getGoogleSubscriptionState,
  googleIapConfigured,
  parseRtdnMessage,
} from "@/lib/iap-google";

export const dynamic = "force-dynamic";
export const runtime = "nodejs";

/**
 * Google Play のリアルタイム開発者通知（RTDN）の受け口。
 * Play Console > 収益化のセットアップ > リアルタイム デベロッパー通知 に
 * Pub/Sub トピックを設定し、そのトピックの push サブスクリプションを
 * このURLに向ける。
 *
 * 【これが無いと何が起きるか】
 * 利用者が Google Play で解約・返金しても、こちらの plan が有料のまま残る。
 *
 * 【セキュリティ】
 * 通知の中身は一切信用せず、purchaseToken を取り出して Google に問い合わせ直す。
 * したがって偽の通知を投げられても「Googleに聞き直す」以上のことは起きない。
 * それでも無制限に叩かれないよう、URLに共有シークレットを付ける運用にする
 * （Pub/Sub の push エンドポイントにクエリを付けられる。Google推奨の方式のひとつ）:
 *   https://<host>/api/billing/iap/google/notifications?secret=<GOOGLE_RTDN_SECRET>
 */
export async function POST(req: NextRequest) {
  const expected = process.env.GOOGLE_RTDN_SECRET;
  if (expected) {
    const given = req.nextUrl.searchParams.get("secret");
    if (given !== expected) {
      return NextResponse.json({ error: "unauthorized" }, { status: 401 });
    }
  }

  if (!googleIapConfigured()) {
    return NextResponse.json({ error: "Android課金は未設定" }, { status: 501 });
  }

  const body = await req.json().catch(() => null);
  const notice = parseRtdnMessage(body);

  // Pub/Sub は 2xx を返さないと再送し続ける。解釈できない通知は握って200を返す
  // （testNotification や voidedPurchase など、購読以外の通知も届く）。
  if (!notice) {
    return NextResponse.json({ ok: true, ignored: true });
  }

  const db = serviceClient();
  const { data: profile } = await db
    .from("profiles")
    .select("id")
    .eq("google_purchase_token", notice.purchaseToken)
    .maybeSingle();

  if (!profile) {
    // まだ購入確定APIを通っていない、または別環境の通知。無視してよい。
    return NextResponse.json({ ok: true, matched: false });
  }

  try {
    const state = await getGoogleSubscriptionState(notice.purchaseToken);
    await db
      .from("profiles")
      .update({
        plan: state.active && state.plan ? state.plan : "free",
        plan_status: state.active ? "iap_active" : "iap_expired",
        google_expires_at: state.expiresAt?.toISOString() ?? null,
        current_period_end: state.expiresAt?.toISOString() ?? null,
      })
      .eq("id", profile.id);
    await recordTrial(db, profile.id, state.inTrial);
  } catch (e: any) {
    console.error("[iap-google] failed to refresh subscription state", e);
    // 500 を返すと Pub/Sub が再送してくれる
    return NextResponse.json({ error: String(e?.message ?? e) }, { status: 500 });
  }

  return NextResponse.json({ ok: true });
}
