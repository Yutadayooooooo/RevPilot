import { NextRequest, NextResponse } from "next/server";
import { resolveApiAuth } from "@/lib/supabase/api-auth";
import { draftReply } from "@/lib/ai";
import { replyToGooglePlayReview } from "@/lib/googleplay";
import { replyToAppStoreReview } from "@/lib/appstore";
import { AI_UNITS, limitsForPlan } from "@/lib/plan";
import { QuotaError, refundAiUnits, reserveAiUnits, takeRateToken } from "@/lib/quota";
import { runPool } from "@/lib/pool";
import {
  loadCredentials,
  type GooglePlayCreds,
  type AppStoreCreds,
} from "@/lib/credentials";

export const dynamic = "force-dynamic";
/**
 * Vercelの上限は Hobby/Pro とも 300秒（fluid compute 有効時のデフォルトも300秒）。
 * 以前は60秒だったため、Pro上限の20件（1件3〜6秒 × 逐次）が構造的に完走できなかった。
 */
export const maxDuration = 300;

/** 同時に走らせるAI生成の本数。Anthropic側のレート制限に配慮しつつ逐次より十分速くする。 */
const BULK_CONCURRENCY = 4;

/** 打ち切りの時間予算(ms)。maxDurationより手前で必ず結果を返す。 */
const BULK_BUDGET_MS = 250_000;

interface BulkItemResult {
  reviewId: string;
  ok: boolean;
  status?: string;
  error?: string;
}

/**
 * POST /api/reply/bulk
 * body: { reviewIds: string[], action: "draft" | "post" }
 * 複数レビューへ AI返信をまとめて生成（＋投稿）する。
 *
 * 途中で時間切れになっても「何が成功して何が残ったか」を必ず返す。
 * 黙って504になると、クライアントは再送するしかなく、AI課金が二重に発生するため。
 */
export async function POST(req: NextRequest) {
  const auth = await resolveApiAuth(req);
  if (!auth) return NextResponse.json({ error: "unauthorized" }, { status: 401 });
  const { user, db } = auth;

  const { reviewIds, action = "draft" } = (await req.json()) as {
    reviewIds?: string[];
    action?: "draft" | "post";
  };
  if (!Array.isArray(reviewIds) || reviewIds.length === 0) {
    return NextResponse.json({ error: "reviewIds が必要です" }, { status: 400 });
  }

  const { data: profile } = await db
    .from("profiles")
    .select("plan")
    .eq("id", user.id)
    .maybeSingle();
  const plan = profile?.plan as string | undefined;
  const limits = limitsForPlan(plan);

  // 一括可否・上限のゲート
  if (limits.bulkReplyLimit <= 1) {
    return NextResponse.json(
      { error: "一括返信はProプラン以上でご利用いただけます。" },
      { status: 403 }
    );
  }
  const ids = Array.from(new Set(reviewIds));
  if (ids.length > limits.bulkReplyLimit) {
    return NextResponse.json(
      {
        error: `一括返信は一度に${limits.bulkReplyLimit}件までです。分けて実行するか、上位プランをご検討ください。`,
      },
      { status: 403 }
    );
  }

  if (!process.env.ANTHROPIC_API_KEY) {
    return NextResponse.json(
      { error: "AI返信は現在ご利用いただけません（サーバー側のAI設定が未完了です）。" },
      { status: 501 }
    );
  }

  // 一括は重い処理なので、実行そのものの頻度も絞る（5分に3回まで）。
  if (!(await takeRateToken(user.id, "bulk", 300, 3))) {
    return NextResponse.json(
      { error: "一括返信の実行間隔が短すぎます。数分おいて再度お試しください。" },
      { status: 429 }
    );
  }

  const { data: reviews } = await db
    .from("reviews")
    .select(
      "id, store, external_id, rating, title, body, territory, apps!inner(name, description, store_app_id, reply_tone)"
    )
    .in("id", ids);

  const targets = reviews ?? [];
  if (targets.length === 0) {
    return NextResponse.json({ ok: true, generated: 0, posted: 0, skipped: 0, results: [] });
  }

  // 認証情報はストアごとに一度だけ読み込む（並行実行でも二重に読まないようPromiseをキャッシュ）。
  const credCache = new Map<string, Promise<AppStoreCreds | GooglePlayCreds | null>>();
  const credsFor = (store: "appstore" | "googleplay") => {
    if (!credCache.has(store)) credCache.set(store, loadCredentials(user.id, store));
    return credCache.get(store)!;
  };

  const results: BulkItemResult[] = [];
  let generated = 0;
  let posted = 0;
  let quotaExhausted = false;

  const deadline = Date.now() + BULK_BUDGET_MS;

  const processed = await runPool(
    targets,
    BULK_CONCURRENCY,
    async (review: any) => {
      // 枠が尽きたと分かった時点で、以降は無駄にAPIを叩かない。
      if (quotaExhausted) {
        results.push({ reviewId: review.id, ok: false, error: "今月のAI利用枠を使い切りました" });
        return;
      }

      try {
        await reserveAiUnits(user.id, plan, AI_UNITS.reply);
      } catch (e: any) {
        if (e instanceof QuotaError && e.status === 403) quotaExhausted = true;
        results.push({ reviewId: review.id, ok: false, error: String(e?.message ?? e) });
        return;
      }

      const app = review.apps;
      let body: string;
      try {
        body = await draftReply(
          { rating: review.rating, title: review.title, body: review.body, territory: review.territory },
          app.name,
          app.description,
          app.reply_tone
        );
        generated++;
      } catch (e: any) {
        await refundAiUnits(user.id, AI_UNITS.reply);
        results.push({ reviewId: review.id, ok: false, error: String(e?.message ?? e) });
        return;
      }

      // 投稿に失敗しても、生成した本文は下書きとして必ず残す（AI課金を無駄にしない）。
      let status = "draft";
      let postError: string | null = null;
      if (action === "post") {
        try {
          if (review.store === "googleplay") {
            const creds = ((await credsFor("googleplay")) ?? undefined) as GooglePlayCreds | undefined;
            await replyToGooglePlayReview(app.store_app_id, review.external_id, body, creds);
          } else {
            const creds = ((await credsFor("appstore")) ?? undefined) as AppStoreCreds | undefined;
            await replyToAppStoreReview(review.external_id, body, creds);
          }
          status = "posted";
          posted++;
        } catch (e: any) {
          postError = String(e?.message ?? e);
        }
      }

      await db.from("replies").insert({
        review_id: review.id,
        body,
        status,
        source: "ai",
        posted_at: status === "posted" ? new Date().toISOString() : null,
      });

      results.push(
        postError
          ? { reviewId: review.id, ok: false, status: "draft", error: `投稿に失敗（下書きは保存済み）: ${postError}` }
          : { reviewId: review.id, ok: true, status }
      );
    },
    deadline
  );

  const skipped = targets.length - processed;
  return NextResponse.json({
    ok: true,
    generated,
    posted,
    skipped,
    results,
    ...(skipped > 0
      ? { notice: `時間内に処理できなかった ${skipped} 件が残っています。もう一度実行してください。` }
      : {}),
  });
}
