import { H2, P, LegalFooter } from "../../_ui";

export const metadata = {
  title: "ストア連携の手順 — RevPilot",
  description:
    "RevPilot に App Store Connect と Google Play Console を連携する手順。鍵の発行から貼り付けまで。",
};

/**
 * ストア連携のヘルプ（公開ページ。アプリの連携画面からリンクする）。
 *
 * 連携は登録直後の最大の詰まりどころ。コンソールの画面名をそのまま書き、
 * 手元で迷わず進められるようにする。
 */
function Steps({ items }: { items: React.ReactNode[] }) {
  return (
    <ol className="mb-4 list-decimal space-y-2 pl-6 leading-7 text-slate-700">
      {items.map((it, i) => (
        <li key={i}>{it}</li>
      ))}
    </ol>
  );
}

function Note({ children }: { children: React.ReactNode }) {
  return (
    <div className="mb-4 rounded-lg border border-indigo-100 bg-indigo-50 p-4 text-sm leading-6 text-indigo-900">
      {children}
    </div>
  );
}

const b = (s: string) => <strong className="font-semibold text-slate-900">{s}</strong>;

export default function ConnectHelpPage() {
  return (
    <>
      <h1 className="mb-2 text-2xl font-bold text-slate-900">ストア連携の手順</h1>
      <P>
        RevPilot はストアが公式に用意している API でレビューを取得します。ご自身のアプリの鍵を1回登録すれば、
        以後は毎時自動でレビューを取り込みます。どちらか一方のストアだけでも使えます。
      </P>
      <Note>
        鍵のファイル（.p8 / .json）はパソコンに保存されることが多いです。AirDrop やメモ・クラウドドライブで
        スマホに送り、RevPilot の連携画面の <strong>「ファイルから読み込む」</strong> で選ぶと、中身を手で貼り付けずに登録できます。
      </Note>

      <H2>App Store（App Store Connect API）</H2>
      <P>所要時間: 約5分。App Store Connect の「Admin」権限が必要です。</P>
      <Steps
        items={[
          <>App Store Connect を開き、{b("ユーザーとアクセス")} → {b("統合")} タブ → 左の {b("App Store Connect API")} を選ぶ。</>,
          <>{b("チームキー")} の「＋」から鍵を生成する。名前は「RevPilot」など何でもよく、アクセス権は {b("App Manager")} を選ぶ。</>,
          <>生成された行の {b("APIキーをダウンロード")} から .p8 ファイルを保存する（{b("ダウンロードは1回だけ")}です）。</>,
          <>同じ画面の上部にある {b("Issuer ID")} と、鍵の行の {b("キーID")} をコピーする。</>,
          <>RevPilot の {b("ストア連携 → App Store")} に Issuer ID・キーID・.p8 の中身（-----BEGIN PRIVATE KEY----- から END の行まで全部）を貼り付けて「連携する」。</>,
          <>{b("アプリを追加")} で、App Store Connect の「アプリ情報」にある {b("Apple ID")}（10桁前後の数字）を入力する。</>,
        ]}
      />
      <P>
        保存時に RevPilot が実際に API へ接続して確認します。「権限がありません」と出た場合は、鍵のアクセス権が
        App Manager 以上かを確認してください。
      </P>

      <H2>Google Play（Google Play Developer API）</H2>
      <P>所要時間: 約10分。Google Play Console の管理者権限が必要です。</P>
      <Steps
        items={[
          <>Google Cloud Console で（どのプロジェクトでも可）{b("API とサービス → ライブラリ")} から {b("Google Play Android Developer API")} を有効にする。</>,
          <>{b("IAM と管理 → サービス アカウント")} で {b("サービス アカウントを作成")}。名前は「revpilot」など。ロールは付けなくて構いません。</>,
          <>作成したサービス アカウントを開き、{b("鍵 → 鍵を追加 → 新しい鍵を作成 → JSON")} でファイルを保存する。</>,
          <>Google Play Console の {b("ユーザーと権限 → 新しいユーザーを招待")} で、サービス アカウントのメールアドレス（…@….iam.gserviceaccount.com）を入力する。</>,
          <>{b("アプリの権限")} で対象アプリを追加し、{b("アプリ情報の表示（読み取り専用）")} と {b("レビューへの返信")} にチェックして招待を送る。</>,
          <>RevPilot の {b("ストア連携 → Google Play")} に JSON ファイルの中身を丸ごと貼り付けて「連携する」。</>,
          <>{b("アプリを追加")} で {b("パッケージ名")}（例: com.example.app）を入力する。</>,
        ]}
      />
      <P>
        招待直後は権限の反映に最大で数時間かかることがあります。「権限がありません」と出た場合は、少し時間をおいて
        もう一度お試しください。
      </P>

      <H2>よくある質問</H2>
      <P>
        {b("鍵は安全に保管されますか？")} 鍵はサーバー側で AES-256-GCM で暗号化して保存し、レビューの取得と返信の投稿にだけ使います。
        連携を解除したい場合は、各ストアで鍵（またはユーザー）を削除すれば即座に無効になります。
      </P>
      <P>
        {b("過去のレビューも取り込めますか？")} App Store は過去分も取得できます。Google Play の API は直近7日ぶんしか返さないため、
        連携した時点から蓄積していきます。
      </P>
      <LegalFooter updated="2026年10月12日" />
    </>
  );
}
