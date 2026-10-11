import Link from "next/link";
import { PUBLIC_PLANS } from "@/lib/plans";
import { PlanExtras } from "@/components/plan-extras";
import { BUSINESS } from "@/lib/site";
import { LegalFooter } from "../_ui";

export const metadata = {
  title: "料金プラン — RevPilot",
  description: "App Store / Google Play のレビュー監視・AI返信・分析ツール RevPilot の料金プラン。",
};

/**
 * 公開の料金ページ。
 *
 * これまで `/` を含む全ページが認証必須で、料金を知るには先にアカウントを作る
 * 必要があった（＝検討段階の人が価格を確認できない）。
 * 特商法表記からも参照される公開ページとして用意する。
 */
const PRO = PUBLIC_PLANS.find((p) => p.key === "pro");

export default function PricingPage() {
  return (
    <>
      <h1 className="mb-2 text-2xl font-bold text-slate-900">料金プラン</h1>
      <p className="mb-8 leading-7 text-slate-700">
        RevPilot は、App Store と Google Play のレビューを1か所に集約し、AIが返信文案を作り、
        評価の推移を可視化する iOS / Android アプリです。まずは無料でお試しいただけます。
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
              <span className="text-lg font-bold text-slate-900">{p.name}</span>
              {p.popular && (
                <span className="rounded-full bg-indigo-600 px-2 py-0.5 text-[11px] font-bold text-white">
                  おすすめ
                </span>
              )}
            </div>
            <div className="my-1.5 text-xl font-semibold text-indigo-600">{p.price}</div>
            <PlanExtras plan={p} />
            <p className="mb-3 text-xs text-slate-500">{p.tagline}</p>
            <ul className="space-y-1.5 text-sm text-slate-600">
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

      <p className="mt-4 text-xs text-slate-500">
        価格はすべて税込です。サブスクリプションは月額または年額で、解約しない限り選んだ周期ごとに自動更新され、更新日に課金されます。
      </p>

      <div className="mt-8">
        <Link
          href="/"
          className="inline-block rounded-lg bg-indigo-600 px-5 py-2.5 text-sm font-semibold text-white hover:bg-indigo-700"
        >
          アプリについて見る
        </Link>
      </div>

      <h2 className="mb-3 mt-12 text-lg font-bold text-slate-900">よくある質問</h2>
      <dl className="space-y-5">
        <Faq q="解約はどうすればいいですか？">
          iOS は iPhone の「設定 &gt; Apple ID &gt; サブスクリプション」から、
          Android は Google Play ストアの「お支払いと定期購入 &gt; 定期購入」から、いつでも解約できます
          （アプリ内の「設定 &gt; プラン」からもこの画面を開けます）。
          解約後も、その課金期間の終了までは有料機能をご利用いただけます。
        </Faq>
        {PRO?.trialDays && (
        <Faq q="無料トライアルはありますか？">
          Pro は初回のみ{PRO.trialDays}日間無料でお試しいただけます（月額・年額とも）。
          無料期間が終わると選んだプランの料金で自動的に開始されますが、
          終了の2日前にアプリからお知らせし、無料期間中に解約すれば料金は一切かかりません。
          トライアルは App Store / Google Play のアカウントごとに1回限りです。
        </Faq>
        )}
        <Faq q="月額と年額の違いは？">
          機能は同じです。年額は月額の約10か月分の料金で1年間ご利用いただけます。
          途中で月額から年額へ（またはその逆へ）切り替えることもできます。
        </Faq>
        <Faq q="Free の「レビュー履歴 30日」とは？">
          Free プランでは、直近30日ぶんのレビューを表示します。
          それ以前のレビューも<strong>削除せず保存しています</strong>ので、
          Pro にアップグレードすれば、すぐに全期間を閲覧できます。
        </Faq>
        <Faq q="なぜ履歴が価値になるのですか？">
          Google Play の API は「直近7日ぶんのレビュー」しか返さず、それ以前は取得できません。
          RevPilot が毎時取得して蓄積することで、Google Play からは消えたレビューも
          あとから読み返せるようになります。
        </Faq>
        <Faq q="「AI返信 月◯件」とは何ですか？">
          AIが返信文案を生成できる回数です。トピック分析（レビューの自動分類）も同じ枠から消費し、
          分析1件は返信0.2件ぶんに相当します。枠は毎月1日（UTC）にリセットされます。
        </Faq>
        <Faq q="レビューはどのくらいの頻度で取得されますか？">
          全プランで毎時取得します。アプリからの手動での即時取得もいつでも可能です。
        </Faq>
        <Faq q="連携に必要なものは？">
          App Store は App Store Connect API のキー（Issuer ID / Key ID / .p8 ファイル）、
          Google Play は Play Console で権限を付与したサービスアカウントのJSONキーです。
          いずれもご自身が権限をお持ちのアプリのみが対象で、他社のアプリのレビューは取得できません。
          登録時にその場で疎通確認を行い、失敗した場合は保存されません。
        </Faq>
        <Faq q="通知はどのように届きますか？">
          アプリを開いていなくても端末にプッシュ通知が届きます（通知を許可した場合）。
          メールと、設定した Slack / Discord の Webhook にも配信できます。
          通知の対象は「すべて」と「★1〜2のみ」から選べます。
          なおレビューの取得は毎時のため、届くまで最大1時間ほどかかります。
        </Faq>
        <Faq q="お問い合わせ先は？">
          {BUSINESS.email} までご連絡ください。
        </Faq>
      </dl>

      <LegalFooter updated="2026年10月11日" />
    </>
  );
}

function Faq({ q, children }: { q: string; children: React.ReactNode }) {
  return (
    <div>
      <dt className="font-semibold text-slate-900">{q}</dt>
      <dd className="mt-1 leading-7 text-slate-700">{children}</dd>
    </div>
  );
}
