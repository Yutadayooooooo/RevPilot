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
  const key = process.env.RESEND_API_KEY;
  const to = process.env.NOTIFY_EMAIL_TO;
  if (!key || !to) return;
  await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: { Authorization: `Bearer ${key}`, "Content-Type": "application/json" },
    body: JSON.stringify({
      from: "RevPilot <alerts@revpilot.app>",
      to,
      subject: "⚠️ 低評価レビュー通知",
      text,
    }),
  });
}
