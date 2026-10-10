import { sendEmailTo } from "./notify";

/**
 * 運営（＝開発者本人）向けの障害通知。
 *
 * 個人開発で監視SaaSを別途契約するのは現実的でないので、
 * 「cronが失敗し続けても誰も気づかない」という最悪のケースだけは
 * メール1通で拾えるようにしておく。宛先は OPERATOR_ALERT_EMAIL。
 */

const OPERATOR_EMAIL = () => process.env.OPERATOR_ALERT_EMAIL || "";

/** 運営に通知する。宛先未設定なら何もしない（ログには残す）。 */
export async function alertOperator(subject: string, detail: string): Promise<void> {
  const body = `${detail}\n\n--\nRevPilot 自動通知 / ${new Date().toISOString()}`;
  console.error(`[alert] ${subject}\n${body}`);
  const to = OPERATOR_EMAIL();
  if (!to) return;
  try {
    await sendEmailTo(to, `[RevPilot] ${subject}`, body);
  } catch (e) {
    console.error("[alert] failed to send", e);
  }
}

/**
 * cronの実行結果を評価して、異常なら通知する。
 * 「毎回通知」だと慣れて読まなくなるので、明確な異常だけに絞る。
 */
export async function reportCronResult(
  job: string,
  result: { ok: boolean; error?: string; apps?: number; skipped?: number; failed?: number }
): Promise<void> {
  if (!result.ok) {
    await alertOperator(`cron/${job} が失敗しました`, result.error ?? "(詳細不明)");
    return;
  }
  // 時間予算切れが起きている = 処理能力が足りていない（放置すると末尾のアプリが取り込まれない）
  if ((result.skipped ?? 0) > 0) {
    await alertOperator(
      `cron/${job} が時間内に終わりませんでした`,
      `${result.skipped} 件のアプリを次回に繰り越しました（処理: ${result.apps ?? 0} 件）。\n` +
        `恒常的に発生する場合は POLL_CONCURRENCY / 実行間隔 / maxDuration を見直してください。`
    );
  }
  // 取得エラーが多発している = 資格情報の失効やストア側の障害
  if ((result.failed ?? 0) > 0 && (result.failed ?? 0) >= (result.apps ?? 0)) {
    await alertOperator(
      `cron/${job} で全アプリの取得に失敗しました`,
      `${result.failed} 件すべてでストアAPI呼び出しが失敗しています。資格情報の失効やストア障害の可能性があります。`
    );
  }
}
