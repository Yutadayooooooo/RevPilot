import { NextRequest, NextResponse } from "next/server";
import { resolveApiAuth } from "@/lib/supabase/api-auth";
import { serviceClient } from "@/lib/supabase";
import { getStripe } from "@/lib/stripe";
import { decrypt } from "@/lib/crypto";
import { revokeRefreshToken, siwaConfigured } from "@/lib/apple-siwa";

export const dynamic = "force-dynamic";
export const runtime = "nodejs";

/**
 * アカウントの完全削除（退会）。App Store のガイドライン 5.1.1(v) で、
 * アカウント作成があるアプリはアプリ内からのアカウント削除が必須。
 *
 * - Web cookie / モバイル Bearer 両対応（resolveApiAuth）。
 * - 進行中の Stripe サブスクがあればベストエフォートで解約（請求が残らないように）。
 * - auth.users を削除すると profiles / apps / reviews / replies / review_topics /
 *   store_credentials / ai_usage / rate_limits / poll_state は
 *   スキーマの on delete cascade で連鎖削除される（supabase/schema.sql 参照）。
 *
 * 【Apple IAP について】
 * App内課金のサブスクリプションは Apple の管理下にあり、サーバーからは解約できない。
 * 利用者には「設定 > 一番上のお名前 > サブスクリプション」から解約するようUI側で案内している
 * （mobile/lib/screens/settings_screen.dart, components/danger-zone.tsx）。
 */
export async function DELETE(req: NextRequest) {
  const auth = await resolveApiAuth(req);
  if (!auth) return NextResponse.json({ error: "unauthorized" }, { status: 401 });
  const { user, db } = auth;

  // 進行中サブスクを解約（失敗しても削除は続行）。
  try {
    const stripe = getStripe();
    if (stripe) {
      const { data: profile } = await db
        .from("profiles")
        .select("stripe_subscription_id")
        .eq("id", user.id)
        .maybeSingle();
      const subId = profile?.stripe_subscription_id as string | null | undefined;
      if (subId) {
        await stripe.subscriptions.cancel(subId);
      }
    }
  } catch (err) {
    // 解約失敗はログに留め、アカウント削除自体は進める。
    console.error("[account:delete] stripe cancel failed", err);
  }

  // Sign in with Apple で登録した人は、Apple 側のトークンも取り消す（App Store の要件）。
  // 失敗しても削除は続行する（Apple 側は利用者が設定アプリからも解除できる）。
  try {
    if (siwaConfigured()) {
      const { data: p } = await serviceClient()
        .from("profiles")
        .select("apple_siwa_refresh_token")
        .eq("id", user.id)
        .maybeSingle();
      const enc = p?.apple_siwa_refresh_token as string | null | undefined;
      if (enc) await revokeRefreshToken(decrypt(enc));
    }
  } catch (err) {
    console.error("[account:delete] siwa revoke failed", err);
  }

  // service_role で auth ユーザーを削除（= 関連データはcascadeで消える）。
  const admin = serviceClient();
  const { error } = await admin.auth.admin.deleteUser(user.id);
  if (error) {
    return NextResponse.json({ error: error.message }, { status: 500 });
  }

  return NextResponse.json({ ok: true });
}
