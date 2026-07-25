import { createServerClient, type CookieOptions } from "@supabase/ssr";
import { NextResponse, type NextRequest } from "next/server";

type CookieToSet = { name: string; value: string; options: CookieOptions };

/**
 * 各リクエストでセッションを更新し、未ログインなら /login へリダイレクト。
 * Supabaseが未設定（NEXT_PUBLIC_*なし）の場合は素通り＝サンプルプレビューが動く。
 */
export async function middleware(req: NextRequest) {
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const anon = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;
  if (!url || !anon) return NextResponse.next();

  let res = NextResponse.next({ request: req });
  const supabase = createServerClient(url, anon, {
    cookies: {
      getAll() {
        return req.cookies.getAll();
      },
      setAll(list: CookieToSet[]) {
        list.forEach(({ name, value }) => req.cookies.set(name, value));
        res = NextResponse.next({ request: req });
        list.forEach(({ name, value, options }) => res.cookies.set(name, value, options));
      },
    },
  });

  const {
    data: { user },
  } = await supabase.auth.getUser();

  const path = req.nextUrl.pathname;
  // 法務ページ（利用規約・プライバシー・特商法）は公開。ストア審査や一般の閲覧に必要。
  const publicPaths = ["/login", "/auth", "/terms", "/privacy", "/tokushoho"];
  const isPublic = publicPaths.some((p) => path.startsWith(p));
  if (!user && !isPublic) {
    const redirect = req.nextUrl.clone();
    redirect.pathname = "/login";
    return NextResponse.redirect(redirect);
  }
  return res;
}

export const config = {
  // _next 静的ファイルと /api は除外（APIは各自で認証チェック）
  matcher: ["/((?!_next/static|_next/image|favicon.ico|api).*)"],
};
