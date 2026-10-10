import { NextRequest, NextResponse } from "next/server";
import { serviceClient } from "@/lib/supabase";
import { limitsForPlan } from "@/lib/plan";
import { buildWeeklySummary, renderSummaryText, renderSummaryHtml } from "@/lib/summary";
import { sendEmailTo } from "@/lib/notify";
import { reportCronResult } from "@/lib/alerts";
import { runPool } from "@/lib/pool";

export const dynamic = "force-dynamic";
export const runtime = "nodejs";

/** 時間予算(ms)。1リクエストの仕事量を小さく保つ。 */
const BUDGET_MS = 20_000;
/** Cloudflare Workers 無料プランの「同時外部接続6」に収まる値。 */
const CONCURRENCY = 3;
/**
 * 1リクエストで扱う最大人数。
 *
 * Cloudflare Workers の無料プランは「1リクエストあたり外部サブリクエスト50回」。
 * 1人あたり 集計クエリ + メール送信 + 既読印 で約5回使うので 8人 ≒ 40回。
 * 残りは weekly_summary_sent_at を見て次のリクエストが続きから処理する
 * （呼び出し側の .github/workflows/weekly.yml が remaining が 0 になるまで繰り返す）。
 */
const BATCH = 8;

/**
 * 週次サマリーメールの配信。
 *
 * 【以前の不具合】全profilesを逐次処理していたため、利用者が数十人を超えると
 * maxDuration に達して打ち切られ、後ろに並んだ人には永久に届かなかった
 * （再開位置を持っていなかった）。
 * weekly_summary_sent_at を印にして「まだ送っていない人」から再開できるようにし、
 * 打ち切られても次の実行で続きから処理する。
 */
export async function POST(req: NextRequest) {
  if (!isAuthorized(req)) return NextResponse.json({ error: "unauthorized" }, { status: 401 });

  const db = serviceClient();
  const deadline = Date.now() + BUDGET_MS;
  // 6日以上前に送った人（＝今週まだ送っていない人）だけを対象にする。
  const cutoff = new Date(Date.now() - 6 * 86_400_000).toISOString();

  const { data: profiles, error } = await db
    .from("profiles")
    .select("id, email, plan, weekly_summary_sent_at")
    .neq("plan", "free")
    .not("email", "is", null)
    .or(`weekly_summary_sent_at.is.null,weekly_summary_sent_at.lt.${cutoff}`)
    .order("weekly_summary_sent_at", { ascending: true, nullsFirst: true })
    .limit(BATCH);

  if (error) {
    await reportCronResult("weekly", { ok: false, error: error.message });
    return NextResponse.json({ ok: false, error: error.message }, { status: 500 });
  }

  const targets = (profiles ?? []).filter((p) => limitsForPlan(p.plan).weeklySummary && p.email);
  let sent = 0;
  let skipped = 0;
  let failed = 0;

  const processed = await runPool(
    targets,
    CONCURRENCY,
    async (p: any) => {
      try {
        const summary = await buildWeeklySummary(db, p.id);
        if (!summary.hasActivity) {
          // 動きが無い人には送らないが、「今週は処理済み」の印は付ける。
          // 付けないと次の実行でまた同じ人を集計し直すことになる。
          await markSent(db, p.id);
          skipped++;
          return;
        }
        const ok = await sendEmailTo(
          p.email,
          "📊 RevPilot 週次サマリー",
          renderSummaryText(summary),
          renderSummaryHtml(summary)
        );
        if (ok) {
          await markSent(db, p.id);
          sent++;
        } else {
          skipped++; // 送信基盤が未設定など。印は付けず次回に回す。
        }
      } catch (e) {
        console.error(`weekly summary failed user=${p.id}`, e);
        failed++;
      }
    },
    deadline
  );

  // このリクエストで処理しきれなかった人数。呼び出し側はこれと sent/skipped を見て
  // 「まだ続きがあるか」を判断する（対象が BATCH 件ちょうど取れた場合は続きがある）。
  const remaining = targets.length - processed;
  const maybeMore = targets.length >= BATCH;
  await reportCronResult("weekly", { ok: true, apps: processed, skipped: remaining, failed });

  return NextResponse.json({ ok: true, sent, skipped, failed, remaining, maybeMore });
}

export async function GET(req: NextRequest) {
  return POST(req);
}

async function markSent(db: ReturnType<typeof serviceClient>, userId: string): Promise<void> {
  await db
    .from("profiles")
    .update({ weekly_summary_sent_at: new Date().toISOString() })
    .eq("id", userId);
}

function isAuthorized(req: NextRequest): boolean {
  const secret = process.env.CRON_SECRET;
  if (!secret) return false;
  const header = req.headers.get("authorization");
  const alt = req.headers.get("x-cron-secret");
  return header === `Bearer ${secret}` || alt === secret;
}
