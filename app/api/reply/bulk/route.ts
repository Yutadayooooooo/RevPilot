import { NextRequest, NextResponse } from "next/server";
import { resolveApiAuth } from "@/lib/supabase/api-auth";
import { draftReply } from "@/lib/ai";
import { GOOGLE_PLAY_REPLY_MAX, replyToGooglePlayReview } from "@/lib/googleplay";
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

/*
 * Google Play の返信の上限（GOOGLE_PLAY_REPLY_MAX = 350）を超えるものは投稿せず、
 * 下書きのまま理由を返す（lib/googleplay.ts も超えた本文は断るが、先に分けて数を数える）。
 * 数え方は UTF-16 の長さ（String.length）にそろえる。
 */

interface BulkItemResult {
  reviewId: string;
  ok: boolean;
  /** draft: 下書きとして残っている / posted: 投稿済み / replied: 返信済みのため対象外 */
  status?: string;
  /** 既存の下書きを使った（AI枠は使っていない） */
  reused?: boolean;
  error?: string;
}

interface ReplyLite {
  body: string | null;
  status: string;
  source: string | null;
  created_at: string;
}

/** 返信の履歴を新しい順に並べる（埋め込みの replies は順序が保証されない）。 */
function newestFirst(replies: ReplyLite[] | null | undefined): ReplyLite[] {
  return [...(replies ?? [])].sort((a, b) => Date.parse(b.created_at) - Date.parse(a.created_at));
}

/** ストアでの返信が済んでいるか（API で投稿した posted か、手動で記録した copied）。 */
function hasReplied(rows: ReplyLite[]): boolean {
  return rows.some((r) => r.status === "posted" || r.status === "copied");
}

/**
 * 使い回せる下書き＝いちばん新しい、本文のある下書き。
 * 利用者が確認・手直しした下書きを差し置いて別のAI文を投稿しないよう、あればこれを使う
 * （アプリの編集欄の初期値と同じ選び方）。
 */
function latestDraft(rows: ReplyLite[]): ReplyLite | null {
  return rows.find((r) => r.status === "draft" && (r.body ?? "").trim() !== "") ?? null;
}

/**
 * ストアへの投稿失敗を、利用者向けの短い日本語にする。
 * ストアの生の応答（'ASC 403: {...}' など）は画面に出さず、ログにだけ残す。
 */
function postFailReason(e: unknown): string {
  const raw = String((e as any)?.message ?? e);
  // lib 側が用意した日本語の案内（「認証情報が未登録です」など）はそのまま使う。
  if (/[\u3040-\u30ff\u3400-\u9fff]/.test(raw)) return raw;
  const status = Number(raw.match(/^(?:ASC|GooglePlay(?: reply)?)\s+(\d{3})\b/)?.[1] ?? 0);
  if (status === 429 || /rate limit/i.test(raw)) {
    return "ストアの回数制限に達しました。少し待ってから再度お試しください。";
  }
  if (status === 401 || status === 403) {
    return "鍵が失効しているか、返信の権限が足りません。ストア連携をご確認ください。";
  }
  if (status === 404) return "ストアでレビューが見つかりませんでした（削除された可能性があります）。";
  if (status >= 500) return "ストア側で一時的な障害が起きています。時間をおいて再度お試しください。";
  return "ストアへの投稿に失敗しました。時間をおいて再度お試しください。";
}

/**
 * POST /api/reply/bulk
 * body: { reviewIds: string[], action: "draft" | "post" }
 * 複数レビューへ AI返信をまとめて生成（＋投稿）する。
 *
 * 下書きがあるレビューは、その最新の下書きを使う（AIで作り直さず、AI枠も使わない）。
 *   - draft: 下書きの無いレビューだけ生成する。下書きのあるものはそのまま残す。
 *   - post : 下書きのあるものはその下書きを、無いものは生成した本文を投稿する。
 * 以前は全件で必ず生成していたため、確認して直した下書きが無視され、
 * 確認していないAI文が公開されていた（AI枠も余計に消費していた）。
 * すでに返信済み（posted / copied）のレビューは対象外にする。一括で上書きすると、
 * ストアで手動入力した返信がAIの文面に置き換わってしまう。
 *
 * 途中で時間切れになっても「何が成功して何が残ったか」を必ず返す。
 * 黙って504になると、クライアントは再送するしかなく、AI課金が二重に発生するため。
 * 応答: { ok, generated, reused, posted, skipped, results[], notice? }
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

  const { data: reviews } = await db
    .from("reviews")
    .select(
      "id, store, external_id, rating, title, body, territory, apps!inner(*), replies(body, status, source, created_at)"
    )
    .in("id", ids);

  const targets = reviews ?? [];
  if (targets.length === 0) {
    return NextResponse.json({ ok: true, generated: 0, reused: 0, posted: 0, skipped: 0, results: [] });
  }

  // AIが要るのは、返信済みでも下書きありでもないレビューだけ。
  const needsAi = targets.some((r: any) => {
    const rows = newestFirst(r.replies);
    return !hasReplied(rows) && !latestDraft(rows);
  });
  if (needsAi && !process.env.ANTHROPIC_API_KEY) {
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

  // 認証情報はストアごとに一度だけ読み込む（並行実行でも二重に読まないようPromiseをキャッシュ）。
  const credCache = new Map<string, Promise<AppStoreCreds | GooglePlayCreds | null>>();
  const credsFor = (store: "appstore" | "googleplay") => {
    if (!credCache.has(store)) credCache.set(store, loadCredentials(user.id, store));
    return credCache.get(store)!;
  };

  const results: BulkItemResult[] = [];
  let generated = 0;
  let reused = 0;
  let posted = 0;
  let quotaExhausted = false;

  const deadline = Date.now() + BULK_BUDGET_MS;

  const processed = await runPool(
    targets,
    BULK_CONCURRENCY,
    async (review: any) => {
      const rows = newestFirst(review.replies);
      if (hasReplied(rows)) {
        results.push({
          reviewId: review.id,
          ok: false,
          status: "replied",
          error: "すでに返信済みのため対象外にしました。",
        });
        return;
      }

      const app = review.apps;
      const draft = latestDraft(rows);
      let body: string;
      let source: string;
      if (draft) {
        // 既存の下書きを使う（AI枠は使わない）。
        reused++;
        body = draft.body!.trim();
        source = draft.source ?? "manual";
        if (action !== "post") {
          results.push({ reviewId: review.id, ok: true, status: "draft", reused: true });
          return;
        }
      } else {
        // 枠が尽きたと分かった時点で、以降は無駄にAPIを叩かない。
        if (quotaExhausted) {
          results.push({ reviewId: review.id, ok: false, error: "今月のAI利用枠を使い切りました。" });
          return;
        }

        try {
          await reserveAiUnits(user.id, plan, AI_UNITS.reply);
        } catch (e: any) {
          if (e instanceof QuotaError && e.status === 403) quotaExhausted = true;
          results.push({ reviewId: review.id, ok: false, error: String(e?.message ?? e) });
          return;
        }

        try {
          body = await draftReply(
            { rating: review.rating, title: review.title, body: review.body, territory: review.territory },
            app.name,
            app.description,
            app.reply_tone,
            { opening: app.reply_opening, closing: app.reply_closing, rules: app.reply_rules }
          );
          generated++;
        } catch (e: any) {
          await refundAiUnits(user.id, AI_UNITS.reply);
          console.error("[reply/bulk] draftReply failed", review.id, e);
          results.push({
            reviewId: review.id,
            ok: false,
            error: "AI返信を作成できませんでした。時間をおいて再度お試しください。",
          });
          return;
        }
        source = "ai";
      }

      // 投稿に失敗しても、生成した本文は下書きとして必ず残す（AI課金を無駄にしない）。
      // 既存の下書きを使った場合は、その下書きがすでに残っているので行を足さない。
      let status = "draft";
      let postError: string | null = null;
      if (action === "post") {
        if (review.store === "googleplay" && body.length > GOOGLE_PLAY_REPLY_MAX) {
          postError = `Google Playの返信は${GOOGLE_PLAY_REPLY_MAX}文字までです（${body.length}文字）。下書きを短くしてから投稿してください。`;
        } else {
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
            console.error("[reply/bulk] post failed", review.id, e);
            postError = postFailReason(e);
          }
        }
      }

      if (status === "posted" || !draft) {
        await db.from("replies").insert({
          review_id: review.id,
          body,
          status,
          source,
          posted_at: status === "posted" ? new Date().toISOString() : null,
        });
      }

      results.push(
        postError
          ? { reviewId: review.id, ok: false, status: "draft", reused: !!draft, error: postError }
          : { reviewId: review.id, ok: true, status, reused: !!draft }
      );
    },
    deadline
  );

  const skipped = targets.length - processed;
  return NextResponse.json({
    ok: true,
    generated,
    reused,
    posted,
    skipped,
    results,
    ...(skipped > 0
      ? { notice: `時間内に処理できなかった ${skipped} 件が残っています。もう一度実行してください。` }
      : {}),
  });
}
