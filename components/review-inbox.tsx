"use client";

import { useMemo, useState } from "react";
import { Apple, Play, Sparkles, Copy, Send, X, Loader2 } from "lucide-react";
import { Card, CardContent } from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import { Badge } from "@/components/ui/badge";
import { RatingStars } from "@/components/rating-stars";
import type { ReviewRow } from "@/lib/sample";
import { cn } from "@/lib/utils";

type Filter = "all" | "low" | "appstore" | "googleplay";

export function ReviewInbox({ reviews }: { reviews: ReviewRow[] }) {
  const [filter, setFilter] = useState<Filter>("all");
  const [active, setActive] = useState<ReviewRow | null>(null);

  const filtered = useMemo(() => {
    return reviews.filter((r) => {
      if (filter === "low") return r.rating <= 2;
      if (filter === "appstore" || filter === "googleplay") return r.store === filter;
      return true;
    });
  }, [reviews, filter]);

  const tabs: { key: Filter; label: string }[] = [
    { key: "all", label: "すべて" },
    { key: "low", label: "★1-2" },
    { key: "appstore", label: "App Store" },
    { key: "googleplay", label: "Google Play" },
  ];

  return (
    <div>
      <div className="mb-4 flex flex-wrap gap-2">
        {tabs.map((t) => (
          <Button
            key={t.key}
            size="sm"
            variant={filter === t.key ? "default" : "outline"}
            onClick={() => setFilter(t.key)}
          >
            {t.label}
          </Button>
        ))}
      </div>

      <div className="space-y-3">
        {filtered.map((r) => (
          <Card
            key={r.id}
            className={cn("border-l-4", r.rating <= 2 ? "border-l-red-500" : "border-l-green-500")}
          >
            <CardContent className="flex items-start justify-between gap-4 p-4">
              <div className="min-w-0">
                <div className="mb-1 flex items-center gap-2 text-xs text-muted-foreground">
                  <StoreIcon store={r.store} />
                  <RatingStars rating={r.rating} />
                  <span>·</span>
                  <span>{r.app_name}</span>
                  <span>·</span>
                  <span>{r.author ?? "匿名"}</span>
                </div>
                {r.title && <div className="text-sm font-medium">{r.title}</div>}
                <p className="text-sm text-foreground/80">{r.body}</p>
                {r.topics && (
                  <div className="mt-2 flex flex-wrap gap-1.5">
                    {r.topics.map((t) => (
                      <Badge key={t} tone={t === "bug" ? "danger" : t === "praise" ? "success" : "muted"}>
                        {t}
                      </Badge>
                    ))}
                  </div>
                )}
              </div>
              <Button size="sm" variant="outline" onClick={() => setActive(r)} className="shrink-0">
                <Sparkles className="h-3.5 w-3.5" /> AI返信
              </Button>
            </CardContent>
          </Card>
        ))}
        {filtered.length === 0 && (
          <p className="py-10 text-center text-sm text-muted-foreground">該当するレビューはありません</p>
        )}
      </div>

      {active && <ReplyDrawer review={active} onClose={() => setActive(null)} />}
    </div>
  );
}

function StoreIcon({ store }: { store: string }) {
  return store === "appstore" ? (
    <span className="inline-flex items-center gap-1">
      <Apple className="h-3.5 w-3.5" /> iOS
    </span>
  ) : (
    <span className="inline-flex items-center gap-1">
      <Play className="h-3.5 w-3.5" /> Android
    </span>
  );
}

function ReplyDrawer({ review, onClose }: { review: ReviewRow; onClose: () => void }) {
  const [draft, setDraft] = useState("");
  const [loading, setLoading] = useState(false);
  const [status, setStatus] = useState<string | null>(null);
  const isAndroid = review.store === "googleplay";

  async function generate() {
    setLoading(true);
    setStatus(null);
    try {
      const res = await fetch("/api/reply", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ reviewId: review.id, action: "draft" }),
      });
      const json = await res.json();
      // 実DB接続時は json.reply.body。サンプルIDでは404になるためフォールバック文を出す。
      setDraft(json?.reply?.body ?? sampleDraft(review));
    } catch {
      setDraft(sampleDraft(review));
    } finally {
      setLoading(false);
    }
  }

  async function post() {
    setLoading(true);
    setStatus(null);
    try {
      const res = await fetch("/api/reply", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ reviewId: review.id, action: "post", text: draft }),
      });
      const json = await res.json();
      setStatus(res.ok ? "✅ 送信しました" : json.error ?? "送信に失敗しました");
    } catch {
      setStatus("送信に失敗しました");
    } finally {
      setLoading(false);
    }
  }

  return (
    <div className="fixed inset-0 z-50 flex justify-end bg-black/30" onClick={onClose}>
      <div
        className="h-full w-full max-w-md overflow-y-auto bg-background p-6 shadow-xl"
        onClick={(e) => e.stopPropagation()}
      >
        <div className="mb-4 flex items-center justify-between">
          <h2 className="text-lg font-semibold">AI返信</h2>
          <Button variant="ghost" size="icon" onClick={onClose}>
            <X className="h-4 w-4" />
          </Button>
        </div>

        <div className="mb-4 rounded-md border bg-muted/40 p-3">
          <div className="mb-1 flex items-center gap-2 text-xs text-muted-foreground">
            <RatingStars rating={review.rating} /> · {review.app_name}
          </div>
          {review.title && <div className="text-sm font-medium">{review.title}</div>}
          <p className="text-sm text-foreground/80">{review.body}</p>
        </div>

        <Button onClick={generate} disabled={loading} className="mb-3 w-full">
          {loading ? <Loader2 className="h-4 w-4 animate-spin" /> : <Sparkles className="h-4 w-4" />}
          返信ドラフトを生成
        </Button>

        <textarea
          value={draft}
          onChange={(e) => setDraft(e.target.value)}
          placeholder="ここにAIの返信案が入ります。編集できます。"
          className="h-40 w-full resize-none rounded-md border p-3 text-sm focus:outline-none focus:ring-2 focus:ring-primary/30"
        />
        <div className="mt-1 text-right text-xs text-muted-foreground">{draft.length} / 350</div>

        <div className="mt-3 flex gap-2">
          <Button
            variant="outline"
            className="flex-1"
            disabled={!draft}
            onClick={() => navigator.clipboard.writeText(draft)}
          >
            <Copy className="h-4 w-4" /> コピー
          </Button>
          {isAndroid ? (
            <Button className="flex-1" disabled={!draft || loading} onClick={post}>
              <Send className="h-4 w-4" /> 自動返信
            </Button>
          ) : (
            <Button className="flex-1" variant="outline" disabled title="iOSは自動投稿不可">
              App Store Connectに貼付
            </Button>
          )}
        </div>

        {!isAndroid && (
          <p className="mt-2 text-xs text-muted-foreground">
            ※ iOSは返信APIが不安定なため、コピーしてApp Store Connectに貼り付けてください。
          </p>
        )}
        {status && <p className="mt-3 text-sm">{status}</p>}
      </div>
    </div>
  );
}

function sampleDraft(r: ReviewRow): string {
  if (r.rating <= 2) {
    return `この度はご不便をおかけし申し訳ありません。「${(r.body ?? "").slice(0, 20)}…」の件、開発チームで確認し次回アップデートで修正対応いたします。差し支えなければサポートまでご連絡いただけますと幸いです。引き続きよろしくお願いいたします。`;
  }
  return `嬉しいレビューをありがとうございます！いただいたご要望は今後の開発の参考にさせていただきます。これからも改善を続けてまいりますので、よろしくお願いいたします。`;
}
