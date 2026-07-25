import { NextRequest, NextResponse } from "next/server";
import { resolveApiAuth } from "@/lib/supabase/api-auth";
import { draftReply } from "@/lib/ai";
import { replyToGooglePlayReview } from "@/lib/googleplay";
import { replyToAppStoreReview } from "@/lib/appstore";
import { limitsForPlan, monthStartISO, aiQuotaReachedMessage } from "@/lib/plan";
import {
  loadCredentials,
  type GooglePlayCreds,
  type AppStoreCreds,
} from "@/lib/credentials";

export const dynamic = "force-dynamic";
export const maxDuration = 60;

/**
 * POST /api/reply/bulk
 * body: { reviewIds: string[], action: "draft" | "post" }
 * 複数レビューへ AI返信をまとめて生成（＋投稿）する。
 * プラン別の一括上限（bulkReplyLimit）と月間AI上限を尊重する。
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
  const limits = limitsForPlan(profile?.plan);

  // 一括可否・上限のゲート
  if (limits.bulkReplyLimit === 1) {
    return NextResponse.json(
      { error: "一括返信はProプラン以上でご利用いただけます。" },
      { status: 403 }
    );
  }
  if (limits.bulkReplyLimit !== null && reviewIds.length > limits.bulkReplyLimit) {
    return NextResponse.json(
      {
        error: `一括返信は一度に${limits.bulkReplyLimit}件までです。全件まとめて返信するにはMaxプランにアップグレードしてください。`,
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

  // 月間AI上限の残数
  let remaining = Number.POSITIVE_INFINITY;
  if (limits.aiRepliesPerMonth !== null) {
    const { count } = await db
      .from("replies")
      .select("id", { count: "exact", head: true })
      .eq("source", "ai")
      .gte("created_at", monthStartISO());
    remaining = Math.max(0, limits.aiRepliesPerMonth - (count ?? 0));
    if (remaining <= 0) {
      return NextResponse.json(
        { error: aiQuotaReachedMessage(profile?.plan, limits.aiRepliesPerMonth) },
        { status: 403 }
      );
    }
  }

  const { data: reviews } = await db
    .from("reviews")
    .select(
      "id, store, external_id, rating, title, body, territory, apps!inner(name, description, store_app_id, reply_tone)"
    )
    .in("id", reviewIds);

  // 認証情報はストアごとに一度だけ読み込む
  let gpCreds: GooglePlayCreds | undefined;
  let ascCreds: AppStoreCreds | undefined;
  let gpLoaded = false;
  let ascLoaded = false;

  const results: Array<{ reviewId: string; ok: boolean; status?: string; error?: string }> = [];
  let generated = 0;
  let posted = 0;

  for (const review of reviews ?? []) {
    if (generated >= remaining) {
      results.push({ reviewId: review.id, ok: false, error: "月間AI上限に達しました" });
      continue;
    }
    const app = (review as any).apps;
    try {
      const body = await draftReply(
        { rating: review.rating, title: review.title, body: review.body, territory: review.territory },
        app.name,
        app.description,
        app.reply_tone
      );
      generated++;

      let status = "draft";
      if (action === "post") {
        if (review.store === "googleplay") {
          if (!gpLoaded) {
            gpCreds = (await loadCredentials<GooglePlayCreds>(db, user.id, "googleplay")) ?? undefined;
            gpLoaded = true;
          }
          await replyToGooglePlayReview(app.store_app_id, review.external_id, body, gpCreds);
        } else {
          if (!ascLoaded) {
            ascCreds = (await loadCredentials<AppStoreCreds>(db, user.id, "appstore")) ?? undefined;
            ascLoaded = true;
          }
          await replyToAppStoreReview(review.external_id, body, ascCreds);
        }
        status = "posted";
        posted++;
      }

      await db.from("replies").insert({
        review_id: review.id,
        body,
        status,
        source: "ai",
        posted_at: status === "posted" ? new Date().toISOString() : null,
      });
      results.push({ reviewId: review.id, ok: true, status });
    } catch (e: any) {
      results.push({ reviewId: review.id, ok: false, error: String(e?.message ?? e) });
    }
  }

  return NextResponse.json({ ok: true, generated, posted, results });
}
