import { P, LegalFooter } from "../_ui";
import { BUSINESS, SITE_URL } from "@/lib/site";
import { PUBLIC_PLANS } from "@/lib/plans";
import type { ReactNode } from "react";

export const metadata = { title: "特定商取引法に基づく表記 — RevPilot" };

function Row({ label, children }: { label: string; children: ReactNode }) {
  return (
    <div className="grid grid-cols-1 gap-1 border-b border-slate-100 py-4 sm:grid-cols-[10rem_1fr] sm:gap-4">
      <dt className="text-sm font-semibold text-slate-500">{label}</dt>
      <dd className="leading-7 text-slate-800">{children}</dd>
    </div>
  );
}

export default function TokushohoPage() {
  return (
    <>
      <h1 className="mb-2 text-2xl font-bold text-slate-900">
        特定商取引法に基づく表記
      </h1>

      <dl>
        <Row label="販売事業者">{BUSINESS.displayName}</Row>
        <Row label="運営統括責任者">{BUSINESS.operator}</Row>
        <Row label="所在地">{BUSINESS.addressDisclosure}</Row>
        <Row label="電話番号">{BUSINESS.phoneDisclosure}</Row>
        <Row label="メールアドレス">{BUSINESS.email}</Row>
        <Row label="販売URL">{SITE_URL}</Row>
        <Row label="販売価格">
          <div className="space-y-1">
            {PUBLIC_PLANS.map((p) => (
              <div key={p.key}>
                {p.name}：{p.prices?.monthly ? `月額 ${p.price.replace("/月", "")}（税込）` : "¥0"}
                {p.yearlyPrice && ` / 年額 ${p.yearlyPrice.replace("/年", "")}（税込）`}
                {p.trialLabel && `　※初回${p.trialLabel}無料（お一人様1回限り）`}
              </div>
            ))}
            <div className="text-sm text-slate-500">
              ※各プランの内容・最新価格は
              <a href="/pricing" className="underline">料金プラン</a>
              および本サービス内のプラン画面に表示します。
            </div>
          </div>
        </Row>
        <Row label="商品代金以外の必要料金">
          インターネット接続に必要な通信料等は利用者の負担となります。
        </Row>
        <Row label="支払方法">
          App Store（iOS）または Google Play（Android）のアプリ内課金。
          お支払いは Apple ID / Google アカウントに登録された支払い方法に請求されます。
        </Row>
        <Row label="支払時期">
          サブスクリプションのお申し込み時に初回課金し、以後は解約されない限り各期間（1か月または1年）の満了時に自動更新・課金します。
          無料トライアルの対象となる場合は、無料期間の終了時に初回課金します（無料期間中に解約した場合は課金されません）。
        </Row>
        <Row label="サービスの提供時期">
          決済完了後、速やかに有料機能をご利用いただけます。
        </Row>
        {/*
          2022年施行の改正特定商取引法により、継続的なサブスクリプションでは
          「解約の方法」を具体的に表示する必要がある。
          「いつでも解約できます」だけでは不十分なので、経路ごとに手順を明記する。
        */}
        <Row label="解約の方法">
          <div className="space-y-2">
            <div>
              <strong>iOS（App Store）でご契約の場合</strong>
              <br />
              iPhone / iPad の「設定 &gt; ご自身の名前（Apple ID） &gt; サブスクリプション &gt; RevPilot」から
              「サブスクリプションをキャンセル」を選択してください。
              アプリ内の「設定 &gt; プラン」からもこの画面を開けます。
            </div>
            <div>
              <strong>Android（Google Play）でご契約の場合</strong>
              <br />
              Google Play ストアアプリの「お支払いと定期購入 &gt; 定期購入 &gt; RevPilot」から
              「定期購入を解約」を選択してください。
              アプリ内の「設定 &gt; プラン」からもこの画面を開けます。
            </div>
            <div className="text-sm text-slate-500">
              アプリ内課金の仕様上、解約手続きは Apple / Google の画面でのみ行えます。
              当方が代行することはできません。
            </div>
            <div className="text-sm text-slate-500">
              いずれの場合も、解約手続きは次回更新日の24時間前までに完了する必要があります。
              手続きが分からない場合は {BUSINESS.email} までご連絡ください。
            </div>
          </div>
        </Row>
        <Row label="返品・キャンセルについて">
          <P>
            サービスの性質上、提供済みの期間分の返金は原則として行いません。解約後は当該課金期間の終了まで
            有料機能をご利用いただけます。アプリ内課金でご購入いただいた分の返金は、Apple / Google の
            各社の返金ポリシーに従います。
          </P>
        </Row>
        <Row label="動作環境">
          iOS / Android の対応バージョン。詳細は各ストアの掲載情報をご確認ください。
        </Row>
        <Row label="サービスの利用に必要な条件">
          レビューの取得には、利用者ご自身が権限を有する App Store Connect API キー、または
          Google Play Console で権限を付与したサービスアカウントの登録が必要です。
        </Row>
      </dl>

      <LegalFooter updated="2026年10月11日" />
    </>
  );
}
