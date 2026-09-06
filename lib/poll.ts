import { serviceClient, type NormalizedReview } from "./supabase";
import { fetchAppStoreReviews } from "./appstore";
import { fetchGooglePlayReviews } from "./googleplay";
import { notifyLowRating } from "./notify";
import { limitsForPlan } from "./plan";
import { loadCredentials, type AppStoreCreds, type GooglePlayCreds } from "./credentials";
import { classifyTopics } from "./ai";

const APP_SELECT = "id, owner, store, store_app_id, name, profiles(line_user_id, plan)";

/**
 * 1回のcronで同時に巡回するアプリ数。
 * 直列だとアプリ数に比例して所要時間が伸び、maxDuration(60秒)を超えて取りこぼす。
 * ストア側のレート上限（ASC 7,200/時/アプリ, Google Play GET 200/時）に対して
 * 十分に余裕のある値にしておく。
 */
const POLL_CONCURRENCY = 6;

/**
 * 1回のcronに割り当てる時間予算(ms)。maxDuration(60秒)より手前で打ち切り、
 * 残りは次回に回す（last_polled_at の古い順に処理するので順番に消化される）。
 */
const POLL_BUDGET_MS = 50_000;

/** 新着レビューのトピック分類の同時実行数。1アプリに大量の新着が来ても詰まらせない。 */
const CLASSIFY_CONCURRENCY = 4;

/**
 * 配列を同時実行数を絞って処理する簡易ワーカープール。
 * deadline(epoch ms)を渡すとその時刻で新規の取り出しをやめる。
 * @returns 実際に処理した件数（残りは呼び出し側で次回に回す）
 */
async function runPool<T>(
  items: T[],
  concurrency: number,
  worker: (item: T) => Promise<void>,
  deadline?: number | null
): Promise<number> {
  let cursor = 0;
  let processed = 0;
  const runners = Array.from({ length: Math.min(concurrency, items.length) }, async () => {
    while (cursor < items.length) {
      if (deadline && Date.now() >= deadline) return;
      const item = items[cursor++];
      processed++;
      await worker(item);
    }
  });
  await Promise.all(runners);
  return processed;
}

/**
 * cron(毎時)から呼ぶ自動取得。現在は全プラン毎時だが、プランごとの間隔
 * (pollIntervalHours)で間引ける構造にしてある（原価が問題になったら値を上げるだけ）。
 * service_roleでRLSをバイパス。
 */
export async function pollAllApps(): Promise<PollResult> {
  const db = serviceClient();
  const { data: apps, error } = await db.from("apps").select(APP_SELECT);
  if (error) throw error;

  // 最終取得時刻をまとめて引き、プランの間隔に満たないアプリは今回スキップする。
  const { data: states } = await db.from("poll_state").select("app_id, last_polled_at");
  const lastPolled = new Map<string, string | null>(
    (states ?? []).map((s: any) => [s.app_id, s.last_polled_at])
  );

  const now = Date.now();
  const at = (id: string) => {
    const v = lastPolled.get(id);
    return v ? new Date(v).getTime() : 0; // 未取得は最優先
  };

  const eligible = (apps ?? [])
    .filter((a: any) => {
      const hours = limitsForPlan(a.profiles?.plan).pollIntervalHours;
      if (hours === null) return false;
      const last = lastPolled.get(a.id);
      if (!last) return true; // 未取得のアプリは即回す
      // cronの起動ゆらぎで1周期まるごと飛ばさないよう5分の猶予を持たせる。
      return now - new Date(last).getTime() >= hours * 3_600_000 - 300_000;
    })
    // 最後に取得したのが古い順。時間予算で打ち切っても特定アプリが飢えない。
    .sort((a: any, b: any) => at(a.id) - at(b.id));

  return pollApps(db, eligible, { budgetMs: POLL_BUDGET_MS });
}

/**
 * 特定オーナーのアプリだけを取得する（ユーザーによる手動更新）。
 * プランに関わらず本人が明示的に叩くので許可する。
 * 手動更新もルートの maxDuration に縛られるため同じ時間予算をかける。
 */
export async function pollOwnerApps(ownerId: string): Promise<PollResult> {
  const db = serviceClient();
  const { data: apps, error } = await db.from("apps").select(APP_SELECT).eq("owner", ownerId);
  if (error) throw error;
  return pollApps(db, apps ?? [], { budgetMs: POLL_BUDGET_MS });
}

export interface PollResult {
  /** 新規に取り込んだレビュー件数 */
  inserted: number;
  /** 実際に巡回したアプリ数 */
  apps: number;
  /** 時間予算切れで次回に回したアプリ数（0でなければ処理能力が足りていない） */
  skipped: number;
}

/**
 * 渡されたアプリ群を巡回してレビューをupsertし、新規の低評価を通知する共通処理。
 * POLL_CONCURRENCY 本のワーカーで並行処理し、budgetMs を超えたら残りは次回に回す。
 */
async function pollApps(
  db: ReturnType<typeof serviceClient>,
  apps: any[],
  opts: { budgetMs?: number } = {}
): Promise<PollResult> {
  const deadline = opts.budgetMs ? Date.now() + opts.budgetMs : null;
  let inserted = 0;

  // 同一オーナーの認証情報は使い回す。解決前のPromiseをキャッシュすることで、
  // 並行実行でも同じ認証情報を二重に読まない。
  const credCache = new Map<string, Promise<AppStoreCreds | GooglePlayCreds | null>>();
  const credsFor = (owner: string, store: "appstore" | "googleplay") => {
    const cacheKey = `${owner}:${store}`;
    if (!credCache.has(cacheKey)) credCache.set(cacheKey, loadCredentials(db, owner, store));
    return credCache.get(cacheKey)!;
  };

  const pollOne = async (app: any) => {
    const { data: state } = await db
      .from("poll_state")
      .select("last_seen_external_id")
      .eq("app_id", app.id)
      .maybeSingle();

    let reviews: NormalizedReview[] = [];
    try {
      reviews =
        app.store === "appstore"
          ? await fetchAppStoreReviews(
              app.store_app_id,
              state?.last_seen_external_id,
              5,
              ((await credsFor(app.owner, "appstore")) ?? undefined) as AppStoreCreds | undefined
            )
          : await fetchGooglePlayReviews(
              app.store_app_id,
              100,
              ((await credsFor(app.owner, "googleplay")) ?? undefined) as
                | GooglePlayCreds
                | undefined
            );
    } catch (e) {
      console.error(`poll failed app=${app.id}`, e);
      return; // 1アプリの失敗で全体を止めない
    }
    if (reviews.length === 0) return;
    inserted += await ingestReviews(db, app, reviews);
  };

  // 時間予算を超えた時点で残りは次回のcronに回す（古い順に並んでいるので飢えない）。
  const processed = await runPool(apps, POLL_CONCURRENCY, pollOne, deadline);

  return { inserted, apps: processed, skipped: apps.length - processed };
}

/**
 * 取得済みレビュー配列を1アプリぶん取り込む共通処理（取得元に依存しない）。
 * upsert(重複排除) → 新規の★1〜2を通知 → AIトピック分類(Pro以上) → チェックポイント更新。
 * pollApps（実運用）と検証用エンドポイントの両方から呼ぶことで、
 * “取得後の配管”を本番コードそのままで検証できる。
 * @returns 実際に新規挿入された件数（重複は0）
 */
export async function ingestReviews(
  db: ReturnType<typeof serviceClient>,
  app: { id: string; name: string; profiles?: any },
  reviews: NormalizedReview[],
  opts: { skipAi?: boolean } = {}
): Promise<number> {
  if (reviews.length === 0) return 0;

  const rows = reviews.map((r) => ({ ...r, app_id: app.id }));
  // onConflict + ignoreDuplicates: 既知の(store,external_id)は挿入されず select にも出ない。
  // → 二重取得しても新規分だけが返り、通知も新規にしか飛ばない（漏れ/重複を防ぐ肝）。
  const { data: upserted, error: upErr } = await db
    .from("reviews")
    .upsert(rows, { onConflict: "store,external_id", ignoreDuplicates: true })
    .select("id, rating, body, external_id");
  if (upErr) {
    console.error(upErr);
    return 0;
  }

  // 新規に入った★1〜2を通知
  const lineUserId = app.profiles?.line_user_id ?? null;
  for (const row of upserted ?? []) {
    if (row.rating <= 2) {
      await notifyLowRating({
        appName: app.name,
        rating: row.rating,
        body: row.body,
        lineUserId,
      });
    }
  }

  // 新規レビューをAIでトピック分類 → review_topics に保存（分析画面の要望ランキング用）。
  // レビュー件数に比例して原価がかかるので、トピック分析があるプランだけ走らせる。
  const canClassify = limitsForPlan(app.profiles?.plan).topicAnalysis;
  if (!opts.skipAi && canClassify) await classifyNewReviews(db, upserted ?? []);

  // チェックポイント更新（最新レビューID）
  await db.from("poll_state").upsert({
    app_id: app.id,
    last_seen_external_id: reviews[0].external_id,
    last_polled_at: new Date().toISOString(),
  });

  return upserted?.length ?? 0;
}

/**
 * 新規レビューをAIでトピック分類し review_topics に保存する。
 * ANTHROPIC_API_KEY未設定なら何もしない。1件の失敗で全体は止めない。
 */
async function classifyNewReviews(
  db: ReturnType<typeof serviceClient>,
  rows: { id: string; rating: number; body: string | null }[]
): Promise<void> {
  if (!process.env.ANTHROPIC_API_KEY) return;
  const targets = rows.filter((r) => r.body); // 本文が無ければ分類しない
  await runPool(targets, CLASSIFY_CONCURRENCY, async (r) => {
    try {
      const topics = await classifyTopics({ rating: r.rating, body: r.body });
      if (topics.length === 0) return;
      await db
        .from("review_topics")
        .upsert(
          topics.map((topic) => ({ review_id: r.id, topic })),
          { onConflict: "review_id,topic", ignoreDuplicates: true }
        );
    } catch (e) {
      console.error(`classify failed review=${r.id}`, e);
    }
  });
}
