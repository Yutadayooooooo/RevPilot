import { NextRequest, NextResponse } from "next/server";
import { serviceClient } from "@/lib/supabase";
import { limitsForPlan } from "@/lib/plan";
import { buildWeeklySummary, renderSummaryText, renderSummaryHtml } from "@/lib/summary";
import { sendEmailTo } from "@/lib/notify";

export const dynamic = "force-dynamic";
export const maxDuration = 60;

/**
 * 週次サマリーメールの配信。週1回のcronから叩く。
 * 週次サマリーが有効なプラン(Pro/Team)かつメール登録済みのユーザーに送る。
 */
export async function POST(req: NextRequest) {
  if (!isAuthorized(req)) return NextResponse.json({ error: "unauthorized" }, { status: 401 });

  const db = serviceClient();
  const { data: profiles, error } = await db.from("profiles").select("id, email, plan");
  if (error) return NextResponse.json({ ok: false, error: error.message }, { status: 500 });

  let sent = 0;
  let skipped = 0;
  for (const p of profiles ?? []) {
    if (!limitsForPlan(p.plan).weeklySummary || !p.email) {
      skipped++;
      continue;
    }
    try {
      const summary = await buildWeeklySummary(db, p.id);
      if (!summary.hasActivity) {
        skipped++;
        continue; // 今週動きが無い人には送らない
      }
      const ok = await sendEmailTo(
        p.email,
        "📊 RevPilot 週次サマリー",
        renderSummaryText(summary),
        renderSummaryHtml(summary)
      );
      ok ? sent++ : skipped++;
    } catch (e) {
      console.error(`weekly summary failed user=${p.id}`, e);
      skipped++;
    }
  }

  return NextResponse.json({ ok: true, sent, skipped });
}

export async function GET(req: NextRequest) {
  return POST(req);
}

function isAuthorized(req: NextRequest): boolean {
  const secret = process.env.CRON_SECRET;
  if (!secret) return false;
  const header = req.headers.get("authorization");
  const alt = req.headers.get("x-cron-secret");
  return header === `Bearer ${secret}` || alt === secret;
}
