import type { SupabaseClient } from "@supabase/supabase-js";

/**
 * 週次サマリー：直近7日 vs その前7日を、レビュー件数・平均評価・低評価・要望トピックで比較する。
 * cronから service_role で呼ぶ想定なので owner を明示的に絞る。
 */

export interface WeeklySummary {
  totalThisWeek: number;
  totalLastWeek: number;
  avgThisWeek: number | null;
  avgLastWeek: number | null;
  low: { rating: number; body: string | null; app: string }[];
  topTopics: { topic: string; count: number }[];
  hasActivity: boolean;
}

const DAY = 24 * 60 * 60 * 1000;
const TOPIC_JP: Record<string, string> = {
  bug: "バグ",
  feature_request: "機能要望",
  ux: "UX",
  price: "価格",
  praise: "称賛",
  other: "その他",
};

function avg(nums: number[]): number | null {
  return nums.length ? nums.reduce((s, n) => s + n, 0) / nums.length : null;
}

export async function buildWeeklySummary(
  db: SupabaseClient,
  owner: string,
  now = new Date()
): Promise<WeeklySummary> {
  const twoWeeksAgo = new Date(now.getTime() - 14 * DAY).toISOString();
  const oneWeekAgo = new Date(now.getTime() - 7 * DAY).toISOString();

  const { data } = await db
    .from("reviews")
    .select("rating, body, reviewed_at, review_topics(topic), apps!inner(name, owner)")
    .eq("apps.owner", owner)
    .gte("reviewed_at", twoWeeksAgo)
    .order("reviewed_at", { ascending: false });

  const rows = (data ?? []) as any[];
  const thisWeek = rows.filter((r) => r.reviewed_at && r.reviewed_at >= oneWeekAgo);
  const lastWeek = rows.filter((r) => r.reviewed_at && r.reviewed_at < oneWeekAgo);

  const low = thisWeek
    .filter((r) => r.rating <= 2)
    .slice(0, 3)
    .map((r) => ({ rating: r.rating, body: r.body, app: r.apps?.name ?? "-" }));

  const topicCount = new Map<string, number>();
  for (const r of thisWeek) {
    for (const t of r.review_topics ?? []) {
      if (t.topic === "praise") continue; // 要望ランキングなので称賛は除外
      topicCount.set(t.topic, (topicCount.get(t.topic) ?? 0) + 1);
    }
  }
  const topTopics = [...topicCount.entries()]
    .sort((a, b) => b[1] - a[1])
    .slice(0, 3)
    .map(([topic, count]) => ({ topic, count }));

  return {
    totalThisWeek: thisWeek.length,
    totalLastWeek: lastWeek.length,
    avgThisWeek: avg(thisWeek.map((r) => r.rating)),
    avgLastWeek: avg(lastWeek.map((r) => r.rating)),
    low,
    topTopics,
    hasActivity: thisWeek.length > 0,
  };
}

function fmtAvg(v: number | null): string {
  return v === null ? "—" : v.toFixed(2);
}

function deltaLabel(s: WeeklySummary): string {
  if (s.avgThisWeek === null || s.avgLastWeek === null) return "";
  const d = s.avgThisWeek - s.avgLastWeek;
  const arrow = d > 0.05 ? "↑" : d < -0.05 ? "↓" : "→";
  return `${arrow} ${d >= 0 ? "+" : ""}${d.toFixed(2)}`;
}

export function renderSummaryText(s: WeeklySummary): string {
  const lines = [
    "RevPilot 週次サマリー",
    "",
    `今週のレビュー: ${s.totalThisWeek}件（先週 ${s.totalLastWeek}件）`,
    `平均評価: ${fmtAvg(s.avgThisWeek)}（先週 ${fmtAvg(s.avgLastWeek)}） ${deltaLabel(s)}`,
    "",
  ];
  if (s.low.length) {
    lines.push("要対応の低評価:");
    for (const l of s.low) lines.push(`  ★${l.rating} [${l.app}] ${(l.body ?? "").slice(0, 60)}`);
    lines.push("");
  }
  if (s.topTopics.length) {
    lines.push("要望トップ:");
    for (const t of s.topTopics) lines.push(`  ${TOPIC_JP[t.topic] ?? t.topic}: ${t.count}件`);
  }
  return lines.join("\n");
}

export function renderSummaryHtml(s: WeeklySummary): string {
  const lowHtml = s.low.length
    ? `<h3 style="margin:16px 0 8px">要対応の低評価</h3><ul style="padding-left:18px;margin:0">${s.low
        .map((l) => `<li>★${l.rating} <b>${l.app}</b> — ${escapeHtml((l.body ?? "").slice(0, 80))}</li>`)
        .join("")}</ul>`
    : "";
  const topicsHtml = s.topTopics.length
    ? `<h3 style="margin:16px 0 8px">要望トップ</h3><ul style="padding-left:18px;margin:0">${s.topTopics
        .map((t) => `<li>${TOPIC_JP[t.topic] ?? t.topic}: ${t.count}件</li>`)
        .join("")}</ul>`
    : "";
  return `<div style="font-family:system-ui,sans-serif;max-width:520px;color:#111">
    <h2 style="margin:0 0 4px">RevPilot 週次サマリー</h2>
    <p style="color:#666;margin:0 0 16px">今週のあなたのアプリの動きです。</p>
    <table style="border-collapse:collapse;width:100%">
      <tr><td style="padding:6px 0">今週のレビュー</td><td style="text-align:right"><b>${s.totalThisWeek}</b> 件（先週 ${s.totalLastWeek}）</td></tr>
      <tr><td style="padding:6px 0">平均評価</td><td style="text-align:right"><b>${fmtAvg(s.avgThisWeek)}</b>（先週 ${fmtAvg(s.avgLastWeek)}） ${deltaLabel(s)}</td></tr>
    </table>
    ${lowHtml}
    ${topicsHtml}
  </div>`;
}

function escapeHtml(s: string): string {
  return s.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c] as string));
}
