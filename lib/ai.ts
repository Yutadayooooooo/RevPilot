import Anthropic from "@anthropic-ai/sdk";

const client = new Anthropic({ apiKey: process.env.ANTHROPIC_API_KEY });
const MODEL = process.env.ANTHROPIC_MODEL || "claude-sonnet-5";

type Tone = "polite" | "casual" | "apologetic";

const TONE_JP: Record<Tone, string> = {
  polite: "丁寧で誠実なビジネス敬語",
  casual: "親しみやすく砕けた、でも失礼のないトーン",
  apologetic: "問題を真摯に受け止め謝罪を軸にしたトーン",
};

export interface ReviewForAI {
  rating: number;
  title?: string | null;
  body?: string | null;
  territory?: string | null;
}

/** レビューへの返信ドラフトを生成（レビューと同じ言語で返す） */
export async function draftReply(
  review: ReviewForAI,
  appName: string,
  appDescription: string | null,
  tone: Tone = "polite"
): Promise<string> {
  const msg = await client.messages.create({
    model: MODEL,
    max_tokens: 400,
    system:
      `あなたはアプリ「${appName}」の開発者としてストアレビューに返信します。` +
      `アプリ概要: ${appDescription ?? "(なし)"}。` +
      `${TONE_JP[tone]}で、レビューと同じ言語で、350文字以内で返信してください。` +
      `低評価には具体的な次アクション（修正予定/問い合わせ導線）を1つ含め、定型文っぽさを避けます。` +
      `返信本文のみを出力し、前置きや説明は書かないこと。`,
    messages: [
      {
        role: "user",
        content:
          `★${review.rating}\n` +
          `タイトル: ${review.title ?? ""}\n` +
          `本文: ${review.body ?? ""}\n` +
          `地域: ${review.territory ?? ""}`,
      },
    ],
  });
  const block = msg.content.find((b) => b.type === "text");
  return block && block.type === "text" ? block.text.trim() : "";
}

const TOPICS = ["bug", "feature_request", "ux", "price", "praise", "other"] as const;
export type Topic = (typeof TOPICS)[number];

/** レビューをトピック分類（複数可）。分析画面の要望ランキング用。 */
export async function classifyTopics(review: ReviewForAI): Promise<Topic[]> {
  const msg = await client.messages.create({
    model: MODEL,
    max_tokens: 60,
    system:
      `レビューを次のトピックに分類し、該当するものをカンマ区切りで返す。` +
      `候補: ${TOPICS.join(", ")}。該当ラベルのみ出力し他の語は書かない。`,
    messages: [
      { role: "user", content: `★${review.rating}\n${review.title ?? ""}\n${review.body ?? ""}` },
    ],
  });
  const block = msg.content.find((b) => b.type === "text");
  const text = block && block.type === "text" ? block.text : "";
  return text
    .split(/[,\s]+/)
    .map((s) => s.trim().toLowerCase())
    .filter((s): s is Topic => (TOPICS as readonly string[]).includes(s));
}
