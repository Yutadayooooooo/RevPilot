/** 低評価レビューの通知（LINE / メール）。未設定のチャネルは黙ってスキップ。 */

export async function notifyLowRating(params: {
  appName: string;
  rating: number;
  body: string | null;
  lineUserId?: string | null;
}): Promise<void> {
  const text =
    `⚠️ 低評価レビュー（★${params.rating}）\n` +
    `アプリ: ${params.appName}\n` +
    `内容: ${(params.body ?? "(本文なし)").slice(0, 200)}`;

  await Promise.allSettled([sendLine(text, params.lineUserId), sendEmail(text)]);
}

async function sendLine(text: string, toUserId?: string | null): Promise<void> {
  const token = process.env.LINE_CHANNEL_ACCESS_TOKEN;
  if (!token || !toUserId) return;
  await fetch("https://api.line.me/v2/bot/message/push", {
    method: "POST",
    headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
    body: JSON.stringify({ to: toUserId, messages: [{ type: "text", text }] }),
  });
}

async function sendEmail(text: string): Promise<void> {
  const to = process.env.NOTIFY_EMAIL_TO;
  if (!to) return;
  await sendEmailTo(to, "⚠️ 低評価レビュー通知", text);
}

/**
 * 任意の宛先にメール送信（週次サマリー等で使用）。RESEND_API_KEY未設定なら黙ってスキップ。
 * htmlを渡せばHTMLメール、無ければtextのみ。
 */
export async function sendEmailTo(
  to: string,
  subject: string,
  text: string,
  html?: string
): Promise<boolean> {
  const key = process.env.RESEND_API_KEY;
  if (!key || !to) return false;
  const from = process.env.RESEND_FROM || "RevPilot <alerts@revpilot.app>";
  const res = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: { Authorization: `Bearer ${key}`, "Content-Type": "application/json" },
    body: JSON.stringify(html ? { from, to, subject, text, html } : { from, to, subject, text }),
  });
  return res.ok;
}
