import { NextRequest, NextResponse } from "next/server";
import { serviceClient } from "@/lib/supabase";
import { limitsForPlan } from "@/lib/plan";
import {
  buildWeeklySummary,
  renderSummaryText,
  renderSummaryHtml,
  renderSummaryPush,
} from "@/lib/summary";
import { sendEmailTo } from "@/lib/notify";
import { pushConfigured, sendPushToUser } from "@/lib/push";
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
 * 1人あたり 集計クエリ + 端末トークン取得 + FCM送信 + 既読印 で約5回使うので 8人 ≒ 40回。
 * 残りは weekly_summary_sent_at を見て次のリクエストが続きから処理する
 * （呼び出し側の .github/workflows/weekly.yml が remaining が 0 になるまで繰り返す）。
 */
const BATCH = 8;

/**
 * 週次サマリーの配信。
 *
 * 【配信手段をプッシュ通知にした理由】
 * 元はメールのみだったが、メールには独自ドメインの取得とDNS認証が必要になる。
 * Resend は認証済み自ドメインからしか送れず、未認証のうちは
 * 自分のアカウント宛にしか送れない（他人宛は403）。
 * RevPilot は workers.dev のサブドメインで運用していてドメインを持たないため、
 * メールのままでは Pro の特典として掲げている週次サマリーが
 * 1通も届かないことになる。
 * FCM はドメイン不要で既に動いているので、プッシュを主たる配信手段にした。
 * メールは設定済みのときだけ追加で送る（RESEND_API_KEY が無ければ
 * sendEmailTo は通信せず false を返すので、コストはかからない）。
 *
 * 【以前の不具合】全profilesを逐次処理していたため、利用者が数十人を超えると
 * maxDuration に達して打ち切られ、後ろに並んだ人には永久に届かなかった
 * （再開位置を持っていなかった）。
 * weekly_summary_sent_at を印にして「まだ送っていない人」から再開できるようにし、
 * 打ち切られても次の実行で処理する。
 */
export async function POST(req: NextRequest) {
  if (!isAuthorized(req)) return NextResponse.json({ error: "unauthorized" }, { status: 401 });

  const db = serviceClient();
  const deadline = Date.now() + BUDGET_MS;
  // 6日以上前に送った人（＝今週まだ送っていない人）だけを対象にする。
  const cutoff = new Date(Date.now() - 6 * 86_400_000).toISOString();

  const { data: profiles, error } = await db
    .from("profiles")
    .select("id, email, plan, push_scope, weekly_summary_sent_at")
    .neq("plan", "free")
    .or(`weekly_summary_sent_at.is.null,weekly_summary_sent_at.lt.${cutoff}`)
    .order("weekly_summary_sent_at", { ascending: true, nullsFirst: true })
    .limit(BATCH);

  if (error) {
    await reportCronResult("weekly", { ok: false, error: error.message });
    return NextResponse.json({ ok: false, error: error.message }, { status: 500 });
  }

  // プッシュで送るのでメールアドレスの有無は条件にしない。
  // push_scope が "off"（通知を切っている人）だけ除く。"low" は
  // 「低評価のレビューだけ知らせてほしい」という新着通知側の設定であり、
  // 週1通のサマリーまで止める意図ではないと解釈して送る。
  const targets = (profiles ?? []).filter(
    (p) => limitsForPlan(p.plan).weeklySummary && p.push_scope !== "off"
  );
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
        // FCMの鍵自体が無いのは設定漏れ＝直せば回収できるので、印を付けずに次回へ回す。
        // ここで印を付けてしまうと、設定し直しても その週のぶんは永久に届かない。
        if (!pushConfigured()) {
          skipped++;
          return;
        }

        const { title, body } = renderSummaryPush(summary);
        const delivered = await sendPushToUser(
          p.id,
          { title: `📊 ${title}`, body, data: { type: "weekly_summary" } },
          db
        );

        // メールは設定済みのときだけ追加で送る。未設定なら通信せず false が返る。
        const mailed = p.email
          ? await sendEmailTo(
              p.email,
              "📊 RevPilot 週次サマリー",
              renderSummaryText(summary),
              renderSummaryHtml(summary)
            )
          : false;

        // 端末を1台も登録していない利用者はここで delivered=0 になるが、
        // 印は付ける。付けないと毎回この人を集計し直すことになり、
        // maybeMore が永久に true のままワークフローが空回りする。
        await markSent(db, p.id);
        if (delivered > 0 || mailed) sent++;
        else skipped++;
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
