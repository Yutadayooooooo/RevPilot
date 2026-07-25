import Link from "next/link";
import type { Metadata } from "next";

export const metadata: Metadata = {
  title: "RevPilot — 各種ポリシー",
  robots: { index: true, follow: true },
};

const links = [
  { href: "/terms", label: "利用規約" },
  { href: "/privacy", label: "プライバシーポリシー" },
  { href: "/tokushoho", label: "特定商取引法に基づく表記" },
];

/** 公開の法務ページ用レイアウト（ダッシュボードとは独立）。 */
export default function LegalLayout({
  children,
}: {
  children: React.ReactNode;
}) {
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
        <nav className="mb-8 flex flex-wrap gap-x-4 gap-y-2 text-sm">
          {links.map((l) => (
            <Link
              key={l.href}
              href={l.href}
              className="text-slate-500 hover:text-indigo-600 hover:underline"
            >
              {l.label}
            </Link>
          ))}
        </nav>
        <article className="rounded-2xl border border-slate-200 bg-white p-6 sm:p-10">
          {children}
        </article>
      </main>

      <footer className="mx-auto max-w-3xl px-5 pb-12 text-xs text-slate-400">
        © {new Date().getFullYear()} RevPilot
      </footer>
    </div>
  );
}
