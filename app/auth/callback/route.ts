import { NextRequest, NextResponse } from "next/server";
import { createSupabaseServer } from "@/lib/supabase/server";

/**
 * メール確認 / マジックリンクのコールバック。
 * ?code=... をセッションに交換して、Web版が有効なら /dashboard へ戻す。
 *
 * 本番は Web版を公開しない（ENABLE_WEB_APP 未設定。middleware.ts が /dashboard を404にする）ので、
 * 確認済みの案内ページ /auth/confirmed へ送る。以前は本番でも /dashboard に送って404になっていた。
 * アプリから始めた確認（PKCE）は code_verifier が端末にあり、ここでは交換できないが、
 * メールアドレスの確認自体はリンクを開いた時点で済んでいる。
 */
export async function GET(req: NextRequest) {
  const code = req.nextUrl.searchParams.get("code");
  if (code) {
    const supabase = await createSupabaseServer();
    await supabase.auth.exchangeCodeForSession(code);
  }
  const next = process.env.ENABLE_WEB_APP === "true" ? "/dashboard" : "/auth/confirmed";
  return NextResponse.redirect(new URL(next, req.url));
}
