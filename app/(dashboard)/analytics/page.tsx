import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { TrendChart } from "@/components/trend-chart";
import { getReviews } from "@/lib/reviews-data";
import { SAMPLE_TREND } from "@/lib/sample";

export const dynamic = "force-dynamic";

const TOPIC_LABELS: Record<string, string> = {
  bug: "バグ", feature_request: "機能要望", ux: "UX", price: "価格", praise: "称賛", other: "その他",
};

export default async function AnalyticsPage() {
  const { rows } = await getReviews();

  // トピック集計（サンプル/実データ共通）
  const counts: Record<string, number> = {};
  for (const r of rows) for (const t of r.topics ?? []) counts[t] = (counts[t] ?? 0) + 1;
  const ranking = Object.entries(counts).sort((a, b) => b[1] - a[1]);
  const max = ranking[0]?.[1] ?? 1;

  return (
    <div className="mx-auto max-w-4xl space-y-6">
      <h1 className="text-2xl font-semibold">分析</h1>

      <Card>
        <CardHeader>
          <CardTitle>平均評価の推移</CardTitle>
        </CardHeader>
        <CardContent>
          <TrendChart data={SAMPLE_TREND} />
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
