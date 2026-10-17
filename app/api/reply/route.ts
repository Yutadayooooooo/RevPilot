import { NextRequest, NextResponse } from "next/server";
import { resolveApiAuth } from "@/lib/supabase/api-auth";
import { draftReply } from "@/lib/ai";
import { GOOGLE_PLAY_REPLY_MAX, replyToGooglePlayReview } from "@/lib/googleplay";
import { replyToAppStoreReview } from "@/lib/appstore";
import { AI_UNITS } from "@/lib/plan";
import { QuotaError, refundAiUnits, reserveAiUnits, takeRateToken } from "@/lib/quota";
import { loadCredentials, type GooglePlayCreds, type AppStoreCreds } from "@/lib/credentials";

export const dynamic = "force-dynamic";
export const maxDuration = 120;

/*
 * Google Play の返信の上限（GOOGLE_PLAY_REPLY_MAX = 350）は投稿の前にここで確かめる。
 * lib/googleplay.ts も超えた本文は投げて断るが、ここで先に断れば AI の生成文を下書きとして
 * 残したうえで、短くするよう案内できる。
 * 数え方は UTF-16 の長さ（String.length）。アプリの文字数表示も同じ数え方。
 */

/**
 * POST /api/reply
 * body: { reviewId, action: "draft" | "post", text? }
 * - draft: AI返信文を生成して replies に保存（iOS/Android共通）
 * - post : ストアへ投稿（textを渡せばAIを使わずその本文を投稿）
 * 認証はWebのcookieセッション / モバイルの Authorization: Bearer <jwt> の両対応。
 * すべて RLS で自分のアプリのレビューに限定される。
 */
export async function POST(req: NextRequest) {
  const auth = await resolveApiAuth(req);
  if (!auth) return NextResponse.json({ error: "unauthorized" }, { status: 401 });
  const { user, db } = auth;

  const { reviewId, action = "draft", text } = await req.json();
  if (!reviewId) return NextResponse.json({ error: "レビューが指定されていません。" }, { status: 400 });

  const { data: review, error } = await db
    .from("reviews")
    .select("id, store, external_id, rating, title, body, territory, apps!inner(*)")
    .eq("id", reviewId)
    .single();
  if (error || !review) {
    return NextResponse.json(
      { error: "レビューが見つかりませんでした。画面を更新してから再度お試しください。" },
      { status: 404 }
    );
  }

  const app = (review as any).apps;
  const { data: profile } = await db.from("profiles").select("plan").eq("id", user.id).maybeSingle();
  const plan = profile?.plan as string | undefined;

  /**
   * AI枠を予約してから生成する。予約→生成→（失敗なら払い戻し）の順にすることで、
   * 並列リクエストが同じ残数を読んで上限をすり抜けるのを防ぐ。
   */
  async function generate(): Promise<string> {
    if (!process.env.ANTHROPIC_API_KEY) {
      throw new QuotaError("AI返信は現在ご利用いただけません（サーバー側のAI設定が未完了です）。", 501);
    }
    if (!(await takeRateToken(user.id, "reply", 60, 20))) {
      throw new QuotaError("リクエストが多すぎます。少し時間をおいて再度お試しください。", 429);
    }
    await reserveAiUnits(user.id, plan, AI_UNITS.reply);
    try {
      return await draftReply(
        { rating: review!.rating, title: review!.title, body: review!.body, territory: review!.territory },
        app.name,
        app.description,
        app.reply_tone,
        { opening: app.reply_opening, closing: app.reply_closing, rules: app.reply_rules }
      );
    } catch (e) {
      await refundAiUnits(user.id, AI_UNITS.reply); // 生成できなかったぶんは枠を返す
      throw e;
    }
  }

  if (action === "draft") {
    let body: string;
    try {
      body = await generate();
    } catch (e: any) {
      const status = e instanceof QuotaError ? e.status : 500;
      return NextResponse.json({ error: String(e?.message ?? e) }, { status });
    }
    const { data: saved } = await db
      .from("replies")
      .insert({ review_id: reviewId, body, status: "draft", source: "ai" })
      .select()
      .single();
    return NextResponse.json({ ok: true, reply: saved });
  }

  if (action === "post") {
    let body = text as string | undefined;
    let usedAi = false;
    if (!body) {
      // 本文が渡されていない＝ここでAI生成するので枠を消費する
      try {
        body = await generate();
        usedAi = true;
      } catch (e: any) {
        const status = e instanceof QuotaError ? e.status : 500;
        return NextResponse.json({ error: String(e?.message ?? e) }, { status });
      }
    }

    if (review.store === "googleplay" && body.length > GOOGLE_PLAY_REPLY_MAX) {
      // 渡された本文は利用者の手元に残っている。生成した本文だけは下書きとして残す（AI枠を無駄にしない）。
      if (usedAi) {
        await db.from("replies").insert({ review_id: reviewId, body, status: "draft", source: "ai" });
      }
      return NextResponse.json(
        {
          error: `Google Playの返信は${GOOGLE_PLAY_REPLY_MAX}文字までです（現在${body.length}文字）。短くしてから投稿してください。`,
        },
        { status: 400 }
      );
    }

    try {
      if (review.store === "googleplay") {
        const gpCreds =
          (await loadCredentials<GooglePlayCreds>(user.id, "googleplay")) ?? undefined;
        await replyToGooglePlayReview(app.store_app_id, review.external_id, body!, gpCreds);
      } else {
        // App Store: Customer Review Responses で投稿。失敗時はコピー運用へ誘導。
        const ascCreds =
          (await loadCredentials<AppStoreCreds>(user.id, "appstore")) ?? undefined;
        await replyToAppStoreReview(review.external_id, body!, ascCreds);
      }
    } catch (e: any) {
      // 投稿に失敗しても生成済みの本文は無駄にしない（下書きとして保存して返す）。
      const { data: saved } = await db
        .from("replies")
        .insert({ review_id: reviewId, body: body!, status: "draft", source: usedAi ? "ai" : "manual" })
        .select()
        .single();
      return NextResponse.json(
        {
          ok: false,
          reply: saved,
          error:
            review.store === "appstore"
              ? `App Storeへの自動投稿に失敗しました。下書きとして保存したので、文面をコピーしてApp Store Connectに貼り付けてください。（${String(e?.message ?? e)}）`
              : `ストアへの投稿に失敗しました。下書きとして保存しました。（${String(e?.message ?? e)}）`,
        },
        { status: 502 }
      );
    }

    await db.from("replies").insert({
      review_id: reviewId,
      body,
      status: "posted",
      source: usedAi ? "ai" : "manual",
      posted_at: new Date().toISOString(),
    });
    return NextResponse.json({ ok: true, posted: true });
  }

  return NextResponse.json({ error: "この操作には対応していません。" }, { status: 400 });
}
