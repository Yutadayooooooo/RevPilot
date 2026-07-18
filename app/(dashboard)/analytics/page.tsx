import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Badge } from "@/components/ui/badge";
import { TrendChart } from "@/components/trend-chart";
import { getReviews } from "@/lib/reviews-data";
import { SAMPLE_TREND, type ReviewRow } from "@/lib/sample";

export const dynamic = "force-dynamic";

const TOPIC_LABELS: Record<string, string> = {
  bug: "バグ", feature_request: "機能要望", ux: "UX", price: "価格", praise: "称賛", other: "その他",
};

/** レビューを日付ごとに集計して平均評価の推移を作る（新しい順の入力を時系列に並べ替え）。 */
function buildTrend(rows: ReviewRow[]): { date: string; avg: number }[] {
  const byDay = new Map<string, { sum: number; n: number; key: number }>();
  for (const r of rows) {
    if (!r.reviewed_at) continue;
    const d = new Date(r.reviewed_at);
    if (isNaN(d.getTime())) continue;
    const key = Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate());
    const label = `${d.getUTCMonth() + 1}/${d.getUTCDate()}`;
    const cur = byDay.get(label) ?? { sum: 0, n: 0, key };
    cur.sum += r.rating;
    cur.n += 1;
    byDay.set(label, cur);
  }
  return [...byDay.entries()]
    .sort((a, b) => a[1].key - b[1].key)
    .slice(-14) // 直近14日分
    .map(([date, v]) => ({ date, avg: Number((v.sum / v.n).toFixed(2)) }));
}

export default async function AnalyticsPage() {
  const { rows, usingSample } = await getReviews();

  // トピック集計（サンプル/実データ共通）
  const counts: Record<string, number> = {};
  for (const r of rows) for (const t of r.topics ?? []) counts[t] = (counts[t] ?? 0) + 1;
  const ranking = Object.entries(counts).sort((a, b) => b[1] - a[1]);
  const max = ranking[0]?.[1] ?? 1;

  // 推移：実データがあれば実データ、無ければサンプル
  const realTrend = buildTrend(rows);
  const trend = usingSample || realTrend.length < 2 ? SAMPLE_TREND : realTrend;

  return (
    <div className="mx-auto max-w-4xl space-y-6">
      <div className="flex items-center justify-between">
        <h1 className="text-2xl font-semibold">分析</h1>
        {usingSample && <Badge tone="muted">サンプルデータ表示中</Badge>}
      </div>

      <Card>
        <CardHeader>
          <CardTitle>平均評価の推移</CardTitle>
        </CardHeader>
        <CardContent>
          <TrendChart data={trend} />
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle>要望・トピックランキング</CardTitle>
        </CardHeader>
        <CardContent className="space-y-3">
          {ranking.length === 0 && <p className="text-sm text-muted-foreground">データがありません</p>}
          {ranking.map(([topic, count]) => (
            <div key={topic}>
              <div className="mb-1 flex justify-between text-sm">
                <span>{TOPIC_LABELS[topic] ?? topic}</span>
                <span className="text-muted-foreground">{count}</span>
              </div>
              <div className="h-2 w-full rounded-full bg-muted">
                <div
                  className="h-2 rounded-full bg-primary"
                  style={{ width: `${(count / max) * 100}%` }}
                />
              </div>
            </div>
          ))}
        </CardContent>
      </Card>
    </div>
  );
}
