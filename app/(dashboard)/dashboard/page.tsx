import { redirect } from "next/navigation";
import Link from "next/link";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Badge } from "@/components/ui/badge";
import { RatingStars } from "@/components/rating-stars";
import { getReviews, getReviewStats } from "@/lib/reviews-data";
import { createSupabaseServer, getCurrentUser } from "@/lib/supabase/server";
import { connectedStores } from "@/lib/credentials";

export const dynamic = "force-dynamic";

export default async function OverviewPage() {
  // 新規ユーザー（アプリも連携ストアも無い）はオンボーディングへ誘導
  const user = await getCurrentUser();
  let appIssues: { name: string; last_error: string }[] = [];
  if (user) {
    const db = await createSupabaseServer();
    const [{ count: appCount }, stores, { data: broken }] = await Promise.all([
      db.from("apps").select("id", { count: "exact", head: true }),
      connectedStores(user.id),
      db.from("apps").select("name, last_error").not("last_error", "is", null),
    ]);
    if ((appCount ?? 0) === 0 && stores.length === 0) redirect("/onboarding");
    appIssues = (broken ?? []) as { name: string; last_error: string }[];
  }

  const [{ rows, usingSample, error }, stats] = await Promise.all([
    getReviews(),
    getReviewStats(),
  ]);

  // 集計はDB側の値を優先する。取れなかったときだけ取得済みの行から概算する。
  const total = stats?.total ?? rows.length;
  const avg = stats?.avgRating ?? (rows.length ? rows.reduce((s, r) => s + r.rating, 0) / rows.length : null);
  const lowCount = stats?.lowCount ?? rows.filter((r) => r.rating <= 2).length;
  const requestCount = stats?.requestCount ?? rows.filter((r) => r.topics?.includes("feature_request")).length;
  const low = rows.filter((r) => r.rating <= 2).slice(0, 5);

  return (
    <div className="mx-auto max-w-5xl space-y-6">
      <div className="flex items-center justify-between">
        <h1 className="text-2xl font-semibold">概要</h1>
        {usingSample && <Badge tone="muted">サンプルデータ表示中</Badge>}
      </div>

      {error && (
        <div className="rounded-md border border-red-200 bg-red-50 p-3 text-sm text-red-800">
          {error}
        </div>
      )}

      {/* 取得に失敗しているアプリを最上部で知らせる。
          これが無いと、連携が壊れていても「レビュー0件」としか見えない。 */}
      {appIssues.length > 0 && (
        <div className="rounded-md border border-amber-200 bg-amber-50 p-3 text-sm text-amber-900">
          <div className="font-medium">レビューを取得できていないアプリがあります</div>
          <ul className="mt-1 list-inside list-disc space-y-0.5">
            {appIssues.map((a) => (
              <li key={a.name}>
                <span className="font-medium">{a.name}</span>: {a.last_error}
              </li>
            ))}
          </ul>
          <Link href="/settings" className="mt-2 inline-block text-xs underline">
            設定でストア連携を確認する →
          </Link>
        </div>
      )}

      <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
        <Stat title="平均評価" value={avg === null ? "—" : avg.toFixed(1)} sub="全レビュー" />
        <Stat title="取得レビュー" value={String(total)} sub="累計" />
        <Stat title="要対応（★1-2）" value={String(lowCount)} sub="未返信が多いと危険" danger />
        <Stat title="機能要望" value={String(requestCount)} sub="改善のヒント" />
      </div>

      <Card>
        <CardHeader className="flex flex-row items-center justify-between">
          <CardTitle>要対応の低評価</CardTitle>
          <Link href="/inbox" className="text-xs text-primary hover:underline">
            インボックスへ →
          </Link>
        </CardHeader>
        <CardContent className="space-y-3">
          {low.length === 0 && !error && (
            <p className="text-sm text-muted-foreground">低評価はありません 🎉</p>
          )}
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
