/**
 * サイト全体で使う事業者情報・URL の一元管理。
 * 法務ページ（利用規約 / プライバシー / 特商法）とストア掲載メタはここを参照する。
 * 変更が必要なときはこのファイルだけを直せばよい。
 */

/** 事業者情報（個人事業主）。特商法・規約・プライバシーの主体表記に使用。 */
export const BUSINESS = {
  /** 個人事業主の氏名（特商法で表示必須）。 */
  operator: "戸松 祐太",
  /** 屋号（登録不要。サービス名としても使用）。 */
  tradeName: "RevPilot",
  /** 事業者名の表示（屋号＋氏名）。規約・プライバシーの「当方」。 */
  displayName: "RevPilot（戸松 祐太）",
  /** 問い合わせ・法務ページの連絡先。 */
  email: "revpilot.hq@gmail.com",
  /** 住所（個人事業主のため請求時開示方式）。 */
  addressDisclosure: "請求があったら遅滞なく開示します",
  /** 電話番号（同上）。 */
  phoneDisclosure: "請求があったら遅滞なく開示します",
  /** 合意管轄（住所を書かずに済む一般表記）。 */
  court: "事業者の住所地を管轄する地方裁判所",
} as const;

/**
 * 本番サイトURL。デプロイ時に NEXT_PUBLIC_SITE_URL で上書きする。
 * 既定は Vercel の無料ドメイン想定。実際のサブドメインが異なる場合は環境変数で設定すること。
 */
export const SITE_URL = (process.env.NEXT_PUBLIC_SITE_URL || "https://revpilot.vercel.app").replace(/\/$/, "");
