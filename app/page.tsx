import Link from "next/link";
import { PUBLIC_PLANS } from "@/lib/plans";
import { PlanExtras } from "@/components/plan-extras";
import { BUSINESS } from "@/lib/site";

export const metadata = {
  title: "RevPilot — アプリレビューの監視・AI返信・分析",
  description:
    "App Store と Google Play のレビューを1か所に集約。毎時自動で取得し、新着を通知。AIが返信文案を作り、評価の推移を可視化します。個人開発者向け。",
};

/**
 * 公開ランディングページ。
 *
 * RevPilot は iOS / Android アプリとして提供し、Web版のダッシュボードは公開しない。
 * このページはストア掲載のマーケティングURL・サポートURL、および
 * 特定商取引法に基づく表記からの参照先として機能する
 * （以前は `/` を含む全ページが認証必須で、検討段階の人が何のサービスか
 *   確認する手段がなかった）。
 */
export default function LandingPage() {
  const appStoreUrl = process.env.NEXT_PUBLIC_APP_STORE_URL;
  const playStoreUrl = process.env.NEXT_PUBLIC_PLAY_STORE_URL;
  const released = Boolean(appStoreUrl || playStoreUrl);

  return (
    <div className="min-h-screen bg-white text-slate-800">
      <header className="border-b border-slate-200">
        <div className="mx-auto flex max-w-5xl items-center justify-between px-5 py-4">
          <span className="text-base font-bold text-indigo-600">RevPilot</span>
          <nav className="flex gap-4 text-sm">
            <Link href="/pricing" className="text-slate-600 hover:text-indigo-600">
              料金
            </Link>
            <a href={`mailto:${BUSINESS.email}`} className="text-slate-600 hover:text-indigo-600">
              お問い合わせ
            </a>
          </nav>
        </div>
      </header>

      <main>
        {/* ヒーロー */}
        <section className="mx-auto max-w-3xl px-5 py-16 text-center sm:py-24">
          <h1 className="text-3xl font-bold leading-tight text-slate-900 sm:text-4xl">
            アプリのレビューを、
            <br className="sm:hidden" />
            見逃さず、すぐ返す。
          </h1>
          <p className="mx-auto mt-5 max-w-xl leading-8 text-slate-600">
            App Store と Google Play のレビューを1か所に集約。毎時自動で取得して新着をお知らせし、
            AIが返信文案を用意します。個人開発者のための、レビュー管理ツールです。
          </p>

          <div className="mt-8 flex flex-wrap items-center justify-center gap-3">
            {appStoreUrl && (
              <a
                href={appStoreUrl}
                className="rounded-lg bg-slate-900 px-5 py-2.5 text-sm font-semibold text-white hover:bg-slate-700"
              >
                App Store で入手
              </a>
            )}
            {playStoreUrl && (
              <a
                href={playStoreUrl}
                className="rounded-lg bg-slate-900 px-5 py-2.5 text-sm font-semibold text-white hover:bg-slate-700"
              >
                Google Play で入手
              </a>
            )}
            {!released && (
              <span className="rounded-lg border border-slate-300 px-5 py-2.5 text-sm text-slate-500">
                iOS / Android アプリを準備中です
              </span>
            )}
            <Link
              href="/pricing"
              className="rounded-lg border border-indigo-300 px-5 py-2.5 text-sm font-semibold text-indigo-700 hover:bg-indigo-50"
            >
              料金を見る
            </Link>
          </div>
        </section>

        {/* 主な機能 */}
        <section className="border-y border-slate-200 bg-slate-50">
          <div className="mx-auto grid max-w-5xl gap-8 px-5 py-14 sm:grid-cols-2 lg:grid-cols-4">
            <Feature
              title="消えるレビューを履歴に"
              body="Google Play のAPIは直近7日ぶんしか返しません。RevPilot は毎時取得して蓄積するので、7日を過ぎたレビューもあとから読み返せます。"
            />
            <Feature
              title="新着をすぐ通知"
              body="アプリを開いていなくても端末に通知が届きます。★1〜2だけに絞ることも可能。メールと Slack / Discord にも配信できます。"
            />
            <Feature
              title="AIが返信を下書き"
              body="レビューの内容と、アプリごとに設定したトーンに合わせて返信文案を生成。Google Play へはアプリから直接投稿できます。"
            />
            <Feature
              title="評価の推移を可視化"
              body="星の分布、平均評価の推移、よく出るトピックをアプリ別・ストア別に確認できます。"
            />
          </div>
        </section>

        {/* 料金サマリ */}
        <section className="mx-auto max-w-5xl px-5 py-14">
          <h2 className="mb-2 text-center text-xl font-bold text-slate-900">料金</h2>
          <p className="mb-8 text-center text-sm text-slate-600">
            無料ではじめられます。価格はすべて税込です。
          </p>
          <div className="grid gap-4 sm:grid-cols-3">
            {PUBLIC_PLANS.map((p) => (
              <div
                key={p.key}
                className={`rounded-xl border p-5 ${
                  p.popular ? "border-indigo-400 ring-1 ring-indigo-200" : "border-slate-200"
                }`}
              >
                <div className="flex items-center gap-2">
                  <span className="font-bold text-slate-900">{p.name}</span>
                  {p.popular && (
                    <span className="rounded-full bg-indigo-600 px-2 py-0.5 text-[11px] font-bold text-white">
                      おすすめ
                    </span>
                  )}
                </div>
                <div className="my-1.5 text-lg font-semibold text-indigo-600">{p.price}</div>
                <PlanExtras plan={p} />
                <p className="mb-3 text-xs text-slate-500">{p.tagline}</p>
                <ul className="space-y-1 text-sm text-slate-600">
                  {p.features.map((f) => (
                    <li key={f} className="flex items-start gap-1.5">
                      <span className="mt-0.5 text-indigo-500">✓</span>
                      <span>{f}</span>
                    </li>
                  ))}
                </ul>
              </div>
            ))}
          </div>
          <p className="mt-5 text-center text-sm">
            <Link href="/pricing" className="text-indigo-600 underline">
              料金の詳細とよくある質問 →
            </Link>
          </p>
        </section>

        {/* 前提条件を隠さない */}
        <section className="border-t border-slate-200 bg-slate-50">
          <div className="mx-auto max-w-3xl px-5 py-12">
            <h2 className="mb-3 text-lg font-bold text-slate-900">ご利用にあたって</h2>
            <ul className="space-y-2 text-sm leading-7 text-slate-600">
              <li>
                ・レビューの取得には、ご自身が権限をお持ちの App Store Connect API キー、または
                Google Play Console で権限を付与したサービスアカウントの登録が必要です。
                他社のアプリのレビューは取得できません。
              </li>
              <li>
                ・App Store への返信の自動投稿は、Apple 側APIの状況により失敗することがあります。
                その場合は生成した文面をコピーして App Store Connect に貼り付けてご利用ください。
              </li>
              <li>
                ・レビューの取得は毎時のため、ストアに投稿されてから通知が届くまで最大1時間ほどかかります。
                リアルタイムではありません。
              </li>
            </ul>
          </div>
        </section>
      </main>

      <footer className="border-t border-slate-200">
        <div className="mx-auto max-w-5xl px-5 py-8 text-xs text-slate-500">
          <div className="mb-3 flex flex-wrap gap-x-4 gap-y-2">
            <Link href="/pricing" className="hover:text-indigo-600">料金プラン</Link>
            <Link href="/terms" className="hover:text-indigo-600">利用規約</Link>
            <Link href="/privacy" className="hover:text-indigo-600">プライバシーポリシー</Link>
            <Link href="/tokushoho" className="hover:text-indigo-600">特定商取引法に基づく表記</Link>
            <a href={`mailto:${BUSINESS.email}`} className="hover:text-indigo-600">お問い合わせ</a>
          </div>
          <div>© {new Date().getFullYear()} {BUSINESS.displayName}</div>
        </div>
      </footer>
    </div>
  );
}

function Feature({ title, body }: { title: string; body: string }) {
  return (
    <div>
      <h3 className="mb-1.5 font-semibold text-slate-900">{title}</h3>
      <p className="text-sm leading-6 text-slate-600">{body}</p>
    </div>
  );
}
