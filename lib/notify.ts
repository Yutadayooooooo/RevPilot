/** 新着レビューの通知（Slack / Discord Webhook・メール）。未設定のチャネルは黙ってスキップ。 */

/**
 * 通知先として許可するWebhookのホスト。
 *
 * URLは利用者が入力する値で、それをサーバーがfetchする＝SSRFの入口になる。
 * 任意のURLを許すと社内ネットワークやクラウドのメタデータエンドポイントを
 * 叩かせられるため、既知のサービスだけに限定する。
 */
const ALLOWED_WEBHOOK_HOSTS = [
  "hooks.slack.com",
  "discord.com",
  "discordapp.com",
  "ptb.discord.com",
  "canary.discord.com",
];

/** 入力されたWebhook URLが通知先として使えるか検証する。使えないなら理由を返す。 */
export function validateWebhookUrl(raw: string): { ok: true; url: string } | { ok: false; error: string } {
  let u: URL;
  try {
    u = new URL(raw.trim());
  } catch {
    return { ok: false, error: "URLの形式が正しくありません。" };
  }
  if (u.protocol !== "https:") {
    return { ok: false, error: "Webhook URLは https で始まる必要があります。" };
  }
  if (!ALLOWED_WEBHOOK_HOSTS.includes(u.hostname)) {
    return {
      ok: false,
      error: "対応しているのは Slack（hooks.slack.com）と Discord のWebhookのみです。",
    };
  }
  return { ok: true, url: u.toString() };
}

export interface NewReviewNotice {
  appName: string;
  rating: number;
  body: string | null;
  /** 利用者のSlack/Discord Webhook URL */
  webhookUrl?: string | null;
  /** 利用者のメールアドレス（profiles.email ではなく auth のアドレス） */
  email?: string | null;
}

/**
 * 新着レビューを利用者本人に通知する。
 *
 * 【以前の不具合】メール通知の宛先が環境変数 NOTIFY_EMAIL_TO（＝運営のアドレス）
 * 固定だったため、全利用者の低評価通知が運営の受信箱に届き、
 * 肝心の利用者には一通も届いていなかった。宛先は必ず当該利用者にする。
 */
export async function notifyNewReview(params: NewReviewNotice): Promise<void> {
  const stars = "★".repeat(params.rating) + "☆".repeat(5 - params.rating);
  const excerpt = (params.body ?? "(本文なし)").slice(0, 200);
  const text = `${stars}（★${params.rating}）新しいレビュー\nアプリ: ${params.appName}\n${excerpt}`;

  await Promise.allSettled([
    sendWebhook(text, params.webhookUrl),
    params.email
      ? sendEmailTo(
          params.email,
          `${params.rating <= 2 ? "⚠️ 低評価" : "🆕 新着"}レビュー — ${params.appName}`,
          text
        )
      : Promise.resolve(false),
  ]);
}

/** Slack / Discord の Incoming Webhook に投げる。 */
async function sendWebhook(text: string, url?: string | null): Promise<void> {
  if (!url) return;
  const check = validateWebhookUrl(url);
  if (!check.ok) return;

  const host = new URL(check.url).hostname;
  // Slack は { text }、Discord は { content } を要求する。
  const payload = host.includes("slack") ? { text } : { content: text };

  try {
    await fetch(check.url, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload),
      signal: AbortSignal.timeout(8_000),
    });
  } catch (e) {
    console.error("[notify] webhook failed", e);
  }
}

/**
 * 任意の宛先にメール送信（新着通知・週次サマリー等で使用）。
 * RESEND_API_KEY未設定なら黙ってスキップ。
 *
 * 【RESEND_FROM について】
 * 既定値は置かない。Resend は認証済みの自分のドメインからしか送れず、
 * 未認証のうちは onboarding@resend.dev から「Resendアカウント自身のアドレス」宛にしか
 * 送れない（他人宛は 403 "You can only send testing emails to your own email address"）。
 * ここで適当なドメインを既定値にすると、設定し忘れたときに 403 を握り潰して
 * 「なぜかメールだけ来ない」という最も気づきにくい壊れ方をする。
 * 以前は alerts@revpilot.app を既定にしていたが、このドメインは自社では取得していない。
 */
export async function sendEmailTo(
  to: string,
  subject: string,
  text: string,
  html?: string
): Promise<boolean> {
  const key = process.env.RESEND_API_KEY;
  if (!key || !to) return false;
  const from = process.env.RESEND_FROM;
  if (!from) {
    console.error(
      "[notify] RESEND_API_KEY はあるが RESEND_FROM が未設定のためメールを送れません。" +
        "独自ドメインを認証したうえで RESEND_FROM にそのドメインのアドレスを設定してください" +
        "（ドメイン未認証なら onboarding@resend.dev が使えますが、" +
        "宛先は Resend アカウント自身のアドレスに限られます）。"
    );
    return false;
  }
  try {
    const res = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: { Authorization: `Bearer ${key}`, "Content-Type": "application/json" },
      body: JSON.stringify(html ? { from, to, subject, text, html } : { from, to, subject, text }),
      signal: AbortSignal.timeout(10_000),
    });
    return res.ok;
  } catch (e) {
    console.error("[notify] email failed", e);
    return false;
  }
}
