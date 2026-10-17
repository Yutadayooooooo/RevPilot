import Link from "next/link";
import type { Metadata } from "next";
import { ConfirmedMessage } from "./message";

export const metadata: Metadata = {
  title: "メールアドレスの確認 — RevPilot",
  // 確認メールのリンクからだけ来るページ。検索結果には出さない。
  robots: { index: false, follow: false },
};

/**
 * メールアドレス確認のリンクを開いたあとの着地点（公開ページ）。
 *
 * 確認そのものは、メールのリンク先（Supabase の /verify）で済んでいる。
 * ここへは ?code=…（PKCE）付きで戻ってくるが、code はアプリの端末にある
 * code_verifier が無いと交換できないので、Web では使わない。
 * このページは「確認できたこと」と「アプリに戻ってログインすること」だけを伝える。
 * 以前はサイトのトップに着き、確認が済んだことも次にすべきことも分からなかった。
 *
 * - アプリの signUp / 確認メールの再送が emailRedirectTo にこのURLを渡す
 *   （mobile/lib/screens/login_screen.dart）。
 * - Supabase の Authentication > URL Configuration > Redirect URLs への登録が必要
 *   （docs/release-setup.md の 2-1）。登録が無いと Site URL（トップ）に戻される。
 * - middleware の matcher に入っていないので、静的ページとして配信される（Workerを起動しない）。
 *   ENABLE_WEB_APP が無効な本番でも開ける。
 *
 * 見た目は法務・ヘルプのページ（app/(legal)/layout.tsx）にそろえる。
 */
export default function EmailConfirmedPage() {
  return (
    <div className="min-h-screen bg-slate-50">
      <header className="border-b border-slate-200 bg-white">
        <div className="mx-auto flex max-w-3xl items-center gap-2 px-5 py-4">
          <Link href="/" className="text-base font-bold text-indigo-600">
            RevPilot
          </Link>
        </div>
      </header>

      <main className="mx-auto max-w-3xl px-5 py-10">
        <article className="rounded-2xl border border-slate-200 bg-white p-6 sm:p-10">
          <ConfirmedMessage />
        </article>
      </main>

      <footer className="mx-auto max-w-3xl px-5 pb-12 text-xs text-slate-400">
        © {new Date().getFullYear()} RevPilot
      </footer>
    </div>
  );
}
