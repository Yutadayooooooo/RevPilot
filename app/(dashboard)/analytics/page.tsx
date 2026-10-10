import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Badge } from "@/components/ui/badge";
import { TrendChart } from "@/components/trend-chart";
import { getReviews, getDailyAverages } from "@/lib/reviews-data";
import { SAMPLE_TREND } from "@/lib/sample";

export const dynamic = "force-dynamic";

const TOPIC_LABELS: Record<string, string> = {
  bug: "バグ", feature_request: "機能要望", ux: "UX", price: "価格", praise: "称賛", other: "その他",
};

export default async function AnalyticsPage() {
  const [{ rows, usingSample, error }, daily] = await Promise.all([
    getReviews(),
    getDailyAverages(30),
  ]);

  // トピック集計
  const counts: Record<string, number> = {};
  for (const r of rows) for (const t of r.topics ?? []) counts[t] = (counts[t] ?? 0) + 1;
  const ranking = Object.entries(counts).sort((a, b) => b[1] - a[1]);
  const max = ranking[0]?.[1] ?? 1;

  /*
   * 推移グラフ:
   * サンプルを出してよいのは「未ログインのプレビュー」だけ。
   * 以前は実データが2日分未満のときも SAMPLE_TREND を描画していたため、
   * 「サンプルデータ表示中」バッジが出ないまま架空の評価推移が
   * 自分のデータとして表示されていた。実データが足りないときは空状態を出す。
   */
  const trend = usingSample ? SAMPLE_TREND : daily;
  const trendReady = trend.length >= 2;

  return (
    <div className="mx-auto max-w-4xl space-y-6">
      <div className="flex items-center justify-between">
        <h1 className="text-2xl font-semibold">分析</h1>
        {usingSample && <Badge tone="muted">サンプルデータ表示中</Badge>}
      </div>

      {error && (
        <div className="rounded-md border border-red-200 bg-red-50 p-3 text-sm text-red-800">{error}</div>
      )}

      <Card>
        <CardHeader>
          <CardTitle>平均評価の推移</CardTitle>
        </CardHeader>
        <CardContent>
          {trendReady ? (
            <TrendChart data={trend} />
          ) : (
            <div className="flex h-40 flex-col items-center justify-center gap-1 text-center">
              <p className="text-sm text-muted-foreground">推移を出すにはあと少しデータが必要です</p>
              <p className="text-xs text-muted-foreground">
                レビューが2日ぶん集まると、ここに平均評価の推移が表示されます。
              </p>
            </div>
          )}
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle>要望・トピックランキング</CardTitle>
        </CardHeader>
        <CardContent className="space-y-3">
          {ranking.length === 0 && (
            <p className="text-sm text-muted-foreground">
              トピック分析はProプラン以上で、新しく取得したレビューに対して行われます。
            </p>
          )}
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
