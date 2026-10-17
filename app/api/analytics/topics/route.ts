import { NextRequest, NextResponse } from "next/server";
import { resolveApiAuth } from "@/lib/supabase/api-auth";
import { limitsForPlan } from "@/lib/plan";
import { takeRateToken } from "@/lib/quota";
import { backfillTopics } from "@/lib/topics";

export const dynamic = "force-dynamic";
export const maxDuration = 120;

/**
 * POST /api/analytics/topics
 * 保存済みレビューのうち未分類のものをAIで分類し、review_topics に保存する。
 *
 * 分類は取り込み(cron)のときにしか走らないので、Free で使っていた人が Pro / Max を
 * 契約しても、手元のレビューは1件も分類されていない。アプリは分析タブを開いたときに
 * ここを呼び、契約直後からトピック傾向が出るようにする。
 *
 * 認証はWebのcookieセッション / モバイルの Authorization: Bearer <jwt> の両対応。
 * 対象は RLS で自分のアプリのレビューに限られる。
 * 分類1件ぶんのAI枠を消費するので、頻度と件数の両方に上限を置く。
 */
export async function POST(req: NextRequest) {
  const auth = await resolveApiAuth(req);
  if (!auth) return NextResponse.json({ error: "unauthorized" }, { status: 401 });
  const { user, db } = auth;

  const { data: profile } = await db.from("profiles").select("plan").eq("id", user.id).maybeSingle();
  const plan = profile?.plan as string | undefined;
  if (!limitsForPlan(plan).topicAnalysis) {
    return NextResponse.json(
      { error: "トピック分析はProプラン以上でご利用いただけます。" },
      { status: 403 }
    );
  }

  if (!(await takeRateToken(user.id, "topics", 60, 4))) {
    return NextResponse.json(
      { error: "分類の依頼が多すぎます。少し時間をおいて再度お試しください。" },
      { status: 429 }
    );
  }

  try {
    const result = await backfillTopics(db, user.id, plan);
    return NextResponse.json({ ok: true, ...result });
  } catch (e: any) {
    console.error("[topics] backfill failed", e);
    return NextResponse.json(
      { ok: false, error: "レビューの分類に失敗しました。時間をおいて再度お試しください。" },
      { status: 500 }
    );
  }
}
