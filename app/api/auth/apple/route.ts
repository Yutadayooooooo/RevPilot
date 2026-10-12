import { NextRequest, NextResponse } from "next/server";
import { resolveApiAuth } from "@/lib/supabase/api-auth";
import { serviceClient } from "@/lib/supabase";
import { encrypt, cryptoConfigured } from "@/lib/crypto";
import { exchangeAuthCode, siwaConfigured } from "@/lib/apple-siwa";

export const dynamic = "force-dynamic";
export const runtime = "nodejs";

/**
 * Sign in with Apple の直後に端末から認可コードを受け取り、
 * リフレッシュトークンに交換して暗号化保存する（アカウント削除時の取り消し用）。
 * 設定が揃っていなければ 204 で何もしない（ログインは成立させる）。
 */
export async function POST(req: NextRequest) {
  const auth = await resolveApiAuth(req);
  if (!auth) return NextResponse.json({ error: "unauthorized" }, { status: 401 });
  if (!siwaConfigured() || !cryptoConfigured()) return new NextResponse(null, { status: 204 });

  const { authorizationCode } = (await req.json().catch(() => ({}))) as { authorizationCode?: string };
  if (!authorizationCode) return NextResponse.json({ error: "authorizationCode required" }, { status: 400 });

  const refresh = await exchangeAuthCode(authorizationCode);
  if (!refresh) return NextResponse.json({ error: "exchange failed" }, { status: 502 });

  // profiles はクライアントから書けない（RLS）ので service_role で書く。
  const { error } = await serviceClient()
    .from("profiles")
    .update({ apple_siwa_refresh_token: encrypt(refresh) })
    .eq("id", auth.user.id);
  if (error) return NextResponse.json({ error: error.message }, { status: 500 });
  return NextResponse.json({ ok: true });
}
