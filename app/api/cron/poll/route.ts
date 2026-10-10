import { NextRequest, NextResponse } from "next/server";
import { listDueAppIds, pollOneApp } from "@/lib/poll";
import { reportCronResult } from "@/lib/alerts";
import { sweepExpiredSubscriptions } from "@/lib/subscription-sweep";

export const dynamic = "force-dynamic";
export const runtime = "nodejs";

/**
 * 定期ポーリング。**1リクエストで1アプリだけ**処理する。
 *
 * 【なぜ1アプリずつか】
 * Cloudflare Workers の無料プランは「1リクエストあたり外部サブリクエスト50回」
 * 「CPU 10ms」。全アプリを1リクエストで回す作りだと、監視アプリが10本を超えた
 * 時点で上限に当たって取得が黙って止まる。リクエストあたりの仕事量を
 * アプリ数と無関係に固定するため、呼び出し側（GitHub Actions）が
 *   1. 本エンドポイントを body 無しで叩いて「今回対象のアプリID一覧」を得る
 *   2. IDごとに {"appId": "..."} を付けて叩く
 * の2段で回す。
 *
 * Workers Paid（$5/月）に上げるとサブリクエストは10,000回になるので、
 * 1リクエストに戻したければ pollAllApps() を呼ぶ版に差し替えればよい。
 *
 * 認証は Authorization: Bearer <CRON_SECRET>（x-cron-secret でも可）。
 */
export async function POST(req: NextRequest) {
  if (!isAuthorized(req)) return NextResponse.json({ error: "unauthorized" }, { status: 401 });

  const appId = await readAppId(req);

  // --- 2段目: 指定された1アプリだけ巡回する ---
  if (appId) {
    try {
      const result = await pollOneApp(appId);
      return NextResponse.json({ ok: true, appId, ...result });
    } catch (e: any) {
      const message = String(e?.message ?? e);
      await reportCronResult("poll", { ok: false, error: `app=${appId}: ${message}` });
      return NextResponse.json({ ok: false, appId, error: message }, { status: 500 });
    }
  }

  // --- 1段目: 期限切れサブスクの反映 + 今回の対象一覧を返す ---
  // 期限切れの反映は取得より先に済ませる（有料機能を1周期ぶん余計に使わせない）。
  // Apple/Google のサーバー通知が落ちたときの最後の砦。
  let downgraded = 0;
  try {
    downgraded = await sweepExpiredSubscriptions();
  } catch (e) {
    console.error("[cron] subscription sweep failed", e);
  }

  try {
    const appIds = await listDueAppIds();
    return NextResponse.json({ ok: true, downgraded, appIds, count: appIds.length });
  } catch (e: any) {
    const message = String(e?.message ?? e);
    await reportCronResult("poll", { ok: false, error: message });
    return NextResponse.json({ ok: false, error: message }, { status: 500 });
  }
}

// Vercel CronはGETで叩く（1段目だけが走る）
export async function GET(req: NextRequest) {
  return POST(req);
}

/** body が無い・壊れている場合は null（＝1段目として扱う）。 */
async function readAppId(req: NextRequest): Promise<string | null> {
  if (req.method !== "POST") return null;
  try {
    const body = await req.json();
    const id = body?.appId;
    return typeof id === "string" && id.length > 0 ? id : null;
  } catch {
    return null;
  }
}

function isAuthorized(req: NextRequest): boolean {
  const secret = process.env.CRON_SECRET;
  if (!secret) return false;
  const header = req.headers.get("authorization");
  const alt = req.headers.get("x-cron-secret");
  return header === `Bearer ${secret}` || alt === secret;
}
