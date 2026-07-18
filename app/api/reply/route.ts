import { NextRequest, NextResponse } from "next/server";
import type { SupabaseClient } from "@supabase/supabase-js";
import { createSupabaseServer, getCurrentUser } from "@/lib/supabase/server";
import { draftReply } from "@/lib/ai";
import { replyToGooglePlayReview } from "@/lib/googleplay";
import { limitsForPlan, monthStartISO } from "@/lib/plan";
import { loadCredentials, type GooglePlayCreds } from "@/lib/credentials";

export const dynamic = "force-dynamic";

/**
 * 今月のAI返信生成数がプラン上限に達していれば理由文を返す（未達ならnull）。
 * repliesはRLSで自分のレビュー分のみカウントされる。
 */
async function aiQuotaError(db: SupabaseClient, userId: string): Promise<string | null> {
  const { data: profile } = await db.from("profiles").select("plan").eq("id", userId).maybeSingle();
  const limit = limitsForPlan(profile?.plan).aiRepliesPerMonth;
  if (limit === null) return null;
  const { count } = await db
    .from("replies")
    .select("id", { count: "exact", head: true })
    .eq("source", "ai")
    .gte("created_at", monthStartISO());
  if ((count ?? 0) >= limit) {
    return `今月のAI返信の上限（${limit}件）に達しました。Proにアップグレードすると無制限に生成できます。`;
  }
  return null;
}

/**
 * POST /api/reply
 * body: { reviewId, action: "draft" | "post", text? }
 * - draft: AI返信文を生成して replies に保存（iOS/Android共通）
 * - post : Androidのみ reviews.reply で自動投稿
 * すべて RLS で自分のアプリのレビューに限定される。
 */
export async function POST(req: NextRequest) {
  const user = await getCurrentUser();
  if (!user) return NextResponse.json({ error: "unauthorized" }, { status: 401 });

  const db = createSupabaseServer();
  const { reviewId, action = "draft", text } = await req.json();
  if (!reviewId) return NextResponse.json({ error: "reviewId required" }, { status: 400 });

  const { data: review, error } = await db
    .from("reviews")
    .select("id, store, external_id, rating, title, body, territory, apps!inner(name, description, store_app_id, reply_tone)")
    .eq("id", reviewId)
    .single();
  if (error || !review) return NextResponse.json({ error: "review not found" }, { status: 404 });

  const app = (review as any).apps;

  if (action === "draft") {
    const quotaErr = await aiQuotaError(db, user.id);
    if (quotaErr) return NextResponse.json({ error: quotaErr }, { status: 403 });
    const body = await draftReply(
      { rating: review.rating, title: review.title, body: review.body, territory: review.territory },
      app.name,
      app.description,
      app.reply_tone
    );
    const { data: saved } = await db
      .from("replies")
      .insert({ review_id: reviewId, body, status: "draft", source: "ai" })
      .select()
      .single();
    return NextResponse.json({ ok: true, reply: saved });
  }

  if (action === "post") {
    if (review.store !== "googleplay") {
      return NextResponse.json(
        { ok: false, error: "iOSは自動投稿不可。文面をコピーしてApp Store Connectに貼り付けてください。" },
        { status: 422 }
      );
    }
    let body = text;
    if (!body) {
      // 本文が渡されていない＝ここでAI生成するので上限をチェック
      const quotaErr = await aiQuotaError(db, user.id);
      if (quotaErr) return NextResponse.json({ error: quotaErr }, { status: 403 });
      body = await draftReply(
        { rating: review.rating, title: review.title, body: review.body },
        app.name,
        app.description,
        app.reply_tone
      );
    }
    const gpCreds = (await loadCredentials<GooglePlayCreds>(db, user.id, "googleplay")) ?? undefined;
    await replyToGooglePlayReview(app.store_app_id, review.external_id, body, gpCreds);
    await db.from("replies").insert({
      review_id: reviewId,
      body,
      status: "posted",
      source: "ai",
      posted_at: new Date().toISOString(),
    });
    return NextResponse.json({ ok: true, posted: true });
  }

  return NextResponse.json({ error: "unknown action" }, { status: 400 });
}
