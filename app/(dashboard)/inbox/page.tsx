import { getReviews } from "@/lib/reviews-data";
import { Badge } from "@/components/ui/badge";
import { ReviewInbox } from "@/components/review-inbox";
import { RefreshButton } from "@/components/refresh-button";

export const dynamic = "force-dynamic";

export default async function InboxPage() {
  const { rows, usingSample, error } = await getReviews();
  return (
    <div className="mx-auto max-w-4xl space-y-5">
      <div className="flex items-center justify-between">
        <h1 className="text-2xl font-semibold">統合インボックス</h1>
        {usingSample ? <Badge tone="muted">サンプルデータ表示中</Badge> : <RefreshButton />}
      </div>
      <p className="text-sm text-muted-foreground">全アプリ・両ストアのレビュー。★でフィルタし、AI返信を生成できます。</p>
      {error && (
        <div className="rounded-md border border-red-200 bg-red-50 p-3 text-sm text-red-800">{error}</div>
      )}
      <ReviewInbox reviews={rows} />
    </div>
  );
}
