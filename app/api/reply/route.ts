import { NextRequest, NextResponse } from "next/server";
import { createSupabaseServer, getCurrentUser } from "@/lib/supabase/server";
import { draftReply } from "@/lib/ai";
import { replyToGooglePlayReview } from "@/lib/googleplay";

export const dynamic = "force-dynamic";

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
    const body =
      text ??
      (await draftReply(
        { rating: review.rating, title: review.title, body: review.body },
        app.name,
        app.description,
        app.reply_tone
      ));
    await replyToGooglePlayReview(app.store_app_id, review.external_id, body);
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
