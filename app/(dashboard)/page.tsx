import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Badge } from "@/components/ui/badge";
import { RatingStars } from "@/components/rating-stars";
import { getReviews } from "@/lib/reviews-data";
import Link from "next/link";

export const dynamic = "force-dynamic";

export default async function OverviewPage() {
  const { rows, usingSample } = await getReviews();
  const total = rows.length;
  const avg = total ? rows.reduce((s, r) => s + r.rating, 0) / total : 0;
  const low = rows.filter((r) => r.rating <= 2);
  const requests = rows.filter((r) => r.topics?.includes("feature_request"));

  return (
    <div className="mx-auto max-w-5xl space-y-6">
      <div className="flex items-center justify-between">
        <h1 className="text-2xl font-semibold">概要</h1>
        {usingSample && <Badge tone="muted">サンプルデータ表示中</Badge>}
      </div>

      <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
        <Stat title="平均評価" value={avg.toFixed(1)} sub="全アプリ" />
        <Stat title="取得レビュー" value={String(total)} sub="直近" />
        <Stat title="要対応（★1-2）" value={String(low.length)} sub="未返信が多いと危険" danger />
        <Stat title="機能要望" value={String(requests.length)} sub="改善のヒント" />
      </div>

      <Card>
        <CardHeader className="flex flex-row items-center justify-between">
          <CardTitle>要対応の低評価</CardTitle>
          <Link href="/inbox" className="text-xs text-primary hover:underline">
            インボックスへ →
          </Link>
        </CardHeader>
        <CardContent className="space-y-3">
          {low.length === 0 && <p className="text-sm text-muted-foreground">低評価はありません 🎉</p>}
          {low.map((r) => (
            <div key={r.id} className="flex items-start gap-3 rounded-md border p-3">
              <RatingStars rating={r.rating} />
              <div className="min-w-0">
                <div className="text-xs text-muted-foreground">
                  {r.app_name} · {r.store}
                </div>
                <p className="truncate text-sm">{r.body}</p>
              </div>
            </div>
          ))}
        </CardContent>
      </Card>
    </div>
  );
}

function Stat({ title, value, sub, danger }: { title: string; value: string; sub: string; danger?: boolean }) {
  return (
    <Card>
      <CardHeader>
        <CardTitle>{title}</CardTitle>
      </CardHeader>
      <CardContent>
        <div className={danger && value !== "0" ? "text-3xl font-semibold text-red-600" : "text-3xl font-semibold"}>
          {value}
        </div>
        <div className="mt-1 text-xs text-muted-foreground">{sub}</div>
      </CardContent>
    </Card>
  );
}
