import { createServerClient, type CookieOptions } from "@supabase/ssr";
import { NextResponse, type NextRequest } from "next/server";

type CookieToSet = { name: string; value: string; options: CookieOptions };

/**
 * 公開ページ。認証なしで見られる。
 * - `/`        … アプリ紹介のランディング（ストア掲載のマーケティング/サポートURL）
 * - `/pricing` … 検討段階の人がアカウントを作らずに価格を確認できるようにする
 * - 法務3種    … ストア審査と一般の閲覧に必要
 * - `/login`, `/reset-password` … パスワードを忘れた人は当然ログインできない
 */
const PUBLIC_PATHS = [
  "/login",
  "/auth",
  "/reset-password",
  "/terms",
  "/privacy",
  "/tokushoho",
  "/pricing",
  "/help",
  // `/not-found` は下の rewrite 先。Cloudflare Workers では rewrite 先がもう一度
  // middleware を通るため（Vercelは通らない）、ここに入れておかないと
  // 「未ログイン → /login へリダイレクト」に捕まり、/dashboard が 404 ではなく
  // ログイン画面(200)になる。2026-10-09 に wrangler で実測して判明。
  "/not-found",
];

/**
 * Webのダッシュボード画面のパス。
 *
 * RevPilot は iOS / Android アプリとして提供し、Web版は公開しない。
 * これらの画面はコードとしては残してあるが、本番では 404 にする
 * （提供しない画面が本番URLで見えていると、審査時にも利用者にも誤解を招く）。
 * 開発時に使いたい場合は環境変数 ENABLE_WEB_APP=true を設定する。
 */
const WEB_APP_PATHS = ["/dashboard", "/inbox", "/analytics", "/settings", "/onboarding"];

function webAppEnabled(): boolean {
  return process.env.ENABLE_WEB_APP === "true";
}

export async function middleware(req: NextRequest) {
  const path = req.nextUrl.pathname;

  // Webアプリが無効なら、ダッシュボード系は存在しないものとして扱う。
  if (!webAppEnabled() && WEB_APP_PATHS.some((p) => path === p || path.startsWith(`${p}/`))) {
    return NextResponse.rewrite(new URL("/not-found", req.url), { status: 404 });
  }

  const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const anon = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;
  // Supabaseが未設定（NEXT_PUBLIC_*なし）の場合は素通り＝サンプルプレビューが動く
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

  const isPublic = path === "/" || PUBLIC_PATHS.some((p) => path.startsWith(p));
  if (!user && !isPublic) {
    const redirect = req.nextUrl.clone();
    redirect.pathname = "/login";
    return NextResponse.redirect(redirect);
  }
  return res;
}

export const config = {
  /**
   * middleware を動かすのは「Web版ダッシュボードのパス」と、その rewrite 先だけ。
   *
   * 【なぜ全パスに掛けないか】
   * RevPilot は iOS / Android アプリとして提供し、Web版ダッシュボードは公開しない。
   * 残る公開ページ（ランディング・料金・法務3種・ログイン・パスワード再設定）は
   * すべてビルド時に静的生成されており、middleware がやることが何も無い
   * （セッション更新が要るのはWeb版の画面だけで、/login と /reset-password は
   *   クライアント側の Supabase JS がセッションを張る）。
   *
   * 全パスに掛けていると、Cloudflare Workers では**静的ページでも毎回Workerが起動し**、
   * CPU時間を消費する。実測で `/privacy` への30リクエスト中18回がWorker起動だった。
   * ここを絞ると、公開ページは静的アセットとして配信され Worker を起動しない。
   * 無料プランのCPU上限(10ms/リクエスト)に対する露出がそのぶん減る。
   *
   * `/api/*` は元から対象外（各ルートが自前で認証する）。
   */
  matcher: [
    "/dashboard/:path*",
    "/inbox/:path*",
    "/analytics/:path*",
    "/settings/:path*",
    "/onboarding/:path*",
  ],
};
