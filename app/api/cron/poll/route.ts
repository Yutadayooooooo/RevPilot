import { NextRequest, NextResponse } from "next/server";
import { pollAllApps } from "@/lib/poll";

export const dynamic = "force-dynamic";
export const maxDuration = 60;

/**
 * 毎時ポーリング。
 * Vercel Cronは Authorization: Bearer <CRON_SECRET> を送る。手動実行は x-cron-secret でも可。
 */
export async function POST(req: NextRequest) {
  if (!isAuthorized(req)) return NextResponse.json({ error: "unauthorized" }, { status: 401 });
  try {
    const result = await pollAllApps();
    return NextResponse.json({ ok: true, ...result });
  } catch (e: any) {
    return NextResponse.json({ ok: false, error: String(e?.message ?? e) }, { status: 500 });
  }
}

// Vercel CronはGETで叩く設定にもできる
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
