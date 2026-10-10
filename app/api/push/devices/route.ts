import { NextRequest, NextResponse } from "next/server";
import { resolveApiAuth } from "@/lib/supabase/api-auth";
import { serviceClient } from "@/lib/supabase";

export const dynamic = "force-dynamic";

/**
 * リモートpushの宛先（端末トークン）の登録・解除。
 *
 * 【service_role を通す理由】同じ端末で別アカウントにログインし直すと、
 * 同じ token の行が前の利用者の user_id で残っている。
 * RLS 越しの upsert ではその行が「見えない」ため一意制約違反になり、
 * 所有者を付け替えられない。後から登録した方を正とするには
 * サーバー側で書き換える必要がある。
 *
 * 解除も同様で、ログアウト後（＝認証が切れた後）ではなく、
 * 認証が生きているうちに本人の端末として消す。
 */
export async function POST(req: NextRequest) {
  const auth = await resolveApiAuth(req);
  if (!auth) return NextResponse.json({ error: "unauthorized" }, { status: 401 });

  const body = (await req.json().catch(() => ({}))) as Record<string, unknown>;
  const token = typeof body.token === "string" ? body.token.trim() : "";
  if (!token || token.length > 4096) {
    return NextResponse.json({ error: "token が不正です。" }, { status: 400 });
  }

  const db = serviceClient();

  // 解除: 自分が所有している行だけ消す（他人の端末を黙らせられないように）。
  if (body.remove === true) {
    const { error } = await db
      .from("device_tokens")
      .delete()
      .eq("token", token)
      .eq("user_id", auth.user.id);
    if (error) return NextResponse.json({ error: error.message }, { status: 500 });
    return NextResponse.json({ ok: true, removed: true });
  }

  const platform = body.platform === "ios" ? "ios" : body.platform === "android" ? "android" : null;
  if (!platform) {
    return NextResponse.json({ error: "platform が不正です。" }, { status: 400 });
  }

  const { error } = await db.from("device_tokens").upsert(
    {
      token,
      user_id: auth.user.id,
      platform,
      updated_at: new Date().toISOString(),
    },
    { onConflict: "token" }
  );
  if (error) return NextResponse.json({ error: error.message }, { status: 500 });
  return NextResponse.json({ ok: true });
}
