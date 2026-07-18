import { getReviews } from "@/lib/reviews-data";
import { Badge } from "@/components/ui/badge";
import { ReviewInbox } from "@/components/review-inbox";

export const dynamic = "force-dynamic";

export default async function InboxPage() {
  const { rows, usingSample } = await getReviews();
  return (
    <div className="mx-auto max-w-4xl space-y-5">
      <div className="flex items-center justify-between">
        <h1 className="text-2xl font-semibold">統合インボックス</h1>
        {usingSample && <Badge tone="muted">サンプルデータ表示中</Badge>}
      </div>
      <p className="text-sm text-muted-foreground">全アプリ・両ストアのレビュー。★でフィルタし、AI返信を生成できます。</p>
      <ReviewInbox reviews={rows} />
    </div>
  );
}
