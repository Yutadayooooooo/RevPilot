import { NextRequest, NextResponse } from "next/server";
import { serviceClient, type NormalizedReview } from "@/lib/supabase";
import { ingestReviews } from "@/lib/poll";

export const dynamic = "force-dynamic";
export const runtime = "nodejs";

/**
 * 【開発専用】実ストア連携の前に、“取得後の配管”を合成レビューで検証する内部エンドポイント。
 * lib/poll.ts の本番コード(ingestReviews)をそのまま通すので、テスト＝本番配管の検証になる。
 *
 * 安全策:
 * - NODE_ENV=production では 404（常に無効）。
 * - x-cron-secret: CRON_SECRET が一致しないと 401。
 *
 * body: { ownerEmail, reviews?, appName?, cleanup?, skipAi? }
 * 検証内容: 同じ配列で2回取り込み、1回目=新規挿入 / 2回目=0件（重複排除）を確認できる。
 */
export async function POST(req: NextRequest) {
  if (process.env.NODE_ENV === "production") {
    return NextResponse.json({ error: "disabled in production" }, { status: 404 });
  }
  const secret = process.env.CRON_SECRET;
  if (!secret || req.headers.get("x-cron-secret") !== secret) {
    return NextResponse.json({ error: "unauthorized" }, { status: 401 });
  }

  const body = (await req.json().catch(() => ({}))) as {
    ownerEmail?: string;
    reviews?: NormalizedReview[];
    appName?: string;
    cleanup?: boolean;
    skipAi?: boolean;
  };
  if (!body.ownerEmail) {
    return NextResponse.json({ error: "ownerEmail は必須です" }, { status: 400 });
  }

  const db = serviceClient();

  // メール → ユーザーID（auth.users を正とする。profiles.email 未設定でも解決できる）。
  let owner: string | null = null;
  const allEmails: string[] = [];
  for (let page = 1; page <= 10 && !owner; page++) {
    const { data, error } = await db.auth.admin.listUsers({ page, perPage: 200 });
    if (error) return NextResponse.json({ error: error.message }, { status: 500 });
    for (const u of data.users) if (u.email) allEmails.push(u.email);
    owner = data.users.find((u) => u.email === body.ownerEmail)?.id ?? null;
    if (data.users.length < 200) break;
  }
  if (!owner) {
    // 対象が居ないときは、存在するメール一覧を返して再実行しやすくする（開発専用）。
    return NextResponse.json(
      { error: `ユーザーが見つかりません: ${body.ownerEmail}`, availableEmails: allEmails },
      { status: 404 }
    );
  }

  // テスト用アプリを用意（衝突しない固定 store_app_id で冪等）。
  const testStoreAppId = "pipeline-test";
  // plan も引く: ingestReviews のトピック分類がプラン依存になったため本番と同条件で通す。
  const appSelect = "id, name, profiles(line_user_id, plan)";
  let { data: app } = await db
    .from("apps")
    .select(appSelect)
    .eq("owner", owner)
    .eq("store", "appstore")
    .eq("store_app_id", testStoreAppId)
    .maybeSingle();
  if (!app) {
    const { data: created, error } = await db
      .from("apps")
      .insert({
        owner,
        store: "appstore",
        store_app_id: testStoreAppId,
        name: body.appName ?? "[TEST] Pipeline",
        reply_tone: "polite",
      })
      .select(appSelect)
      .single();
    if (error) return NextResponse.json({ error: error.message }, { status: 500 });
    app = created;
  }

  const reviews = body.reviews ?? [];
  const opts = { skipAi: body.skipAi ?? false };

  // 1回目＝新規取り込み、2回目＝同じ配列で重複排除の確認。処理時間も計測。
  const t0 = Date.now();
  const inserted1 = await ingestReviews(db, app as any, reviews, opts);
  const t1 = Date.now();
  const inserted2 = await ingestReviews(db, app as any, reviews, opts);
  const t2 = Date.now();

  const appId = (app as any).id as string;
  const { data: state } = await db
    .from("poll_state")
    .select("last_seen_external_id, last_polled_at")
    .eq("app_id", appId)
    .maybeSingle();
  const { count } = await db
    .from("reviews")
    .select("id", { count: "exact", head: true })
    .eq("app_id", appId);

  let cleaned = false;
  if (body.cleanup) {
    await db.from("apps").delete().eq("id", appId); // reviews/poll_state は cascade で消える
    cleaned = true;
  }

  return NextResponse.json({
    ok: true,
    appId,
    lowRatingCount: reviews.filter((r) => (r.rating ?? 0) <= 2).length,
    firstRun: { inserted: inserted1, ms: t1 - t0 },
    secondRun: { inserted: inserted2, ms: t2 - t1 },
    reviewCountInDb: count ?? null,
    checkpoint: state ?? null,
    cleaned,
  });
}
