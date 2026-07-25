import { H2, P, Fill, DraftNotice, LegalFooter } from "../_ui";
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
      <DraftNotice />

      <dl>
        <Row label="販売事業者">
          <Fill>【事業者名 / 屋号】</Fill>
        </Row>
        <Row label="運営統括責任者">
          <Fill>【氏名】</Fill>
        </Row>
        <Row label="所在地">
          <Fill>【住所】</Fill>
          <P>
            <span className="text-sm text-slate-500">
              ※個人事業主の場合、請求があったときは遅滞なく開示します。この記載で対応する場合は上記を
              「請求があったら遅滞なく開示します」に置き換えてください。
            </span>
          </P>
        </Row>
        <Row label="電話番号">
          <Fill>【電話番号】</Fill>
          <P>
            <span className="text-sm text-slate-500">
              ※同上（請求があったら遅滞なく開示、の運用も可）。
            </span>
          </P>
        </Row>
        <Row label="メールアドレス">
          <Fill>【メールアドレス】</Fill>
        </Row>
        <Row label="販売URL">
          <Fill>【本サービスのURL】</Fill>
        </Row>
        <Row label="販売価格">
          <div className="space-y-1">
            <div>Free：¥0</div>
            <div>Pro：月額 ¥1,480（税込）</div>
            <div>Max：月額 ¥2,980（税込）</div>
            <div>Team：月額 ¥5,800（税込）</div>
            <div className="text-sm text-slate-500">
              ※各プランの内容・最新価格は本サービス内のプラン画面に表示します。
            </div>
          </div>
        </Row>
        <Row label="商品代金以外の必要料金">
          インターネット接続に必要な通信料等は利用者の負担となります。
        </Row>
        <Row label="支払方法">
          クレジットカード（決済事業者：Stripe）
        </Row>
        <Row label="支払時期">
          サブスクリプションのお申し込み時に初回課金し、以後は解約されない限り各期間の満了時に自動更新・課金します。
        </Row>
        <Row label="サービスの提供時期">
          決済完了後、速やかに有料機能をご利用いただけます。
        </Row>
        <Row label="返品・キャンセル（解約）について">
          <P>
            サービスの性質上、提供済みの期間分の返金は原則として行いません。次回更新日の前までにいつでも解約でき、
            解約後は当該課金期間の終了まで有料機能をご利用いただけます。
          </P>
        </Row>
        <Row label="動作環境">
          iOS / Android の対応バージョン、および Web ブラウザ。詳細はストアの掲載情報をご確認ください。
        </Row>
      </dl>

      <LegalFooter updated="2026年7月25日" />
    </>
  );
}
