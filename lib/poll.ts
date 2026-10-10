import { serviceClient, type NormalizedReview } from "./supabase";
import { fetchAppStoreReviews } from "./appstore";
import { fetchGooglePlayReviews } from "./googleplay";
import { notifyNewReview } from "./notify";
import { pushConfigured, pushScopeAllows, sendPushToUser } from "./push";
import { AI_UNITS, limitsForPlan } from "./plan";
import { loadCredentials, type AppStoreCreds, type GooglePlayCreds } from "./credentials";
import { classifyTopics } from "./ai";
import { QuotaError, refundAiUnits, reserveAiUnits } from "./quota";
import { runPool } from "./pool";

const APP_SELECT =
  "id, owner, store, store_app_id, name, created_at, last_polled_at, profiles(notify_webhook_url, email, plan, push_scope)";

/**
 * 1回のcronで同時に巡回するアプリ数。
 * 直列だとアプリ数に比例して所要時間が伸び、maxDurationを超えて取りこぼす。
 * ストア側のレート上限（ASC 7,200/時/アプリ, Google Play GET 200/時）に対して
 * 十分に余裕のある値にしておく。
 */
const POLL_CONCURRENCY = 6;

/**
 * 1回のcronに割り当てる時間予算(ms)。maxDuration(300秒)より手前で打ち切り、
 * 残りは次回に回す（last_polled_at の古い順に処理するので順番に消化される）。
 */
const POLL_BUDGET_MS = 250_000;

/** 新着レビューのトピック分類の同時実行数。1アプリに大量の新着が来ても詰まらせない。 */
const CLASSIFY_CONCURRENCY = 4;

/** 1回の取り込みで通知する上限。大量に入ったときに通知で埋め尽くさない。 */
const NOTIFY_LIMIT = 5;

/**
 * 1リクエストで分類にかけるレビュー数の上限。
 *
 * Cloudflare Workers の無料プランは「1リクエストあたり外部サブリクエスト50回」。
 * 1件の分類で reserveAiUnits / Anthropic / upsert の3回を使うので、
 * ここを青天井にすると取得本体ぶん(約19回)と合わせて即座に上限を超える。
 * 8件 × 3回 = 24回 + 19回 = 43回 に収まる。
 *
 * 超過ぶんは「分類されない」。トピック分析の網羅性だけが落ち、
 * レビューの取り込み・通知・課金には影響しない。
 * Workers Paid（$5/月）にすると上限が10,000回になるのでこの制限は不要になる。
 */
const MAX_CLASSIFY_PER_RUN = 8;

/**
 * 手動更新（POST /api/poll）で1回に巡回するアプリ数の上限。
 * 1アプリあたり最大19回の外部呼び出しを使うので、2本で約38回。
 * 分類ぶん(最大24回)と合わせても、どちらか一方が重くなる程度なら50回に収まる。
 */
const MANUAL_POLL_BATCH = 2;

/**
 * cron(毎時)から呼ぶ自動取得。プランごとの間隔(pollIntervalHours)で間引ける。
 * service_roleでRLSをバイパスする。
 */
export async function pollAllApps(): Promise<PollResult> {
  const db = serviceClient();
  const eligible = await selectDueApps(db);
  return pollApps(db, eligible, { budgetMs: POLL_BUDGET_MS });
}

/**
 * 今回巡回すべきアプリのIDだけを返す。
 *
 * Cloudflare Workers の無料プランは「1リクエスト10ms CPU・外部50回」なので、
 * 全アプリを1リクエストで回す pollAllApps() はそもそも入らない。
 * cron は「due一覧を取る」→「1アプリずつ叩く」の2段構えにし、
 * 1リクエストあたりの仕事量をアプリ数と無関係に固定する。
 */
export async function listDueAppIds(): Promise<string[]> {
  const db = serviceClient();
  const eligible = await selectDueApps(db);
  return eligible.map((a: any) => a.id as string);
}

/**
 * アプリ1本だけを巡回する。cron から1リクエスト＝1アプリで呼ばれる。
 * 存在しないIDは「対象0件」として静かに成功させる（削除との競合で落とさない）。
 */
export async function pollOneApp(appId: string): Promise<PollResult> {
  const db = serviceClient();
  const { data: app, error } = await db.from("apps").select(APP_SELECT).eq("id", appId).maybeSingle();
  if (error) throw error;
  if (!app) return { inserted: 0, apps: 0, skipped: 0, failed: 0, errors: [] };
  return pollApps(db, [app], { budgetMs: 60_000 });
}

/** 巡回対象の抽出（pollAllApps と listDueAppIds の共通部分）。 */
async function selectDueApps(db: ReturnType<typeof serviceClient>): Promise<any[]> {
  const { data: apps, error } = await db.from("apps").select(APP_SELECT);
  if (error) throw error;

  const now = Date.now();
  // 最終取得時刻は apps.last_polled_at を正とする。
  // （以前は poll_state を見ていたが、poll_state は「新着があった時」しか
  //   更新されなかったため、新着が無いアプリが永久に先頭へ居座り、
  //   時間予算で切られる末尾のアプリが毎回同じ顔ぶれで飢えていた。）
  const at = (a: any) => (a.last_polled_at ? new Date(a.last_polled_at).getTime() : 0);

  const eligible = withinPlanAppLimit(apps ?? [])
    .filter((a: any) => {
      const hours = limitsForPlan(a.profiles?.plan).pollIntervalHours;
      if (hours === null) return false;
      if (!a.last_polled_at) return true; // 未取得のアプリは即回す
      // cronの起動ゆらぎで1周期まるごと飛ばさないよう5分の猶予を持たせる。
      return now - at(a) >= hours * 3_600_000 - 300_000;
    })
    // 最後に取得したのが古い順。時間予算で打ち切っても特定アプリが飢えない。
    .sort((a: any, b: any) => at(a) - at(b));

  return eligible;
}

/**
 * プランのアプリ数上限を超えているぶんを自動取得の対象から外す。
 *
 * アプリ追加時のトリガは INSERT しか見ないので、Proで10本追加してから解約すると
 * Freeのまま10本が回り続ける。データは消さない（再課金で即復帰できるように）が、
 * 定期取得の対象は古い順に上限までとする。
 */
function withinPlanAppLimit(apps: any[]): any[] {
  const byOwner = new Map<string, any[]>();
  for (const a of apps) {
    const list = byOwner.get(a.owner) ?? [];
    list.push(a);
    byOwner.set(a.owner, list);
  }
  const out: any[] = [];
  for (const list of byOwner.values()) {
    const max = limitsForPlan(list[0]?.profiles?.plan).maxApps;
    if (max === null || list.length <= max) {
      out.push(...list);
      continue;
    }
    // 古く登録したものを優先して残す（利用者の体感が安定する）
    list.sort(
      (a, b) => new Date(a.created_at ?? 0).getTime() - new Date(b.created_at ?? 0).getTime()
    );
    out.push(...list.slice(0, max));
  }
  return out;
}

/**
 * 特定オーナーのアプリだけを取得する（ユーザーによる手動更新）。
 * プランに関わらず本人が明示的に叩くので許可する。
 */
export async function pollOwnerApps(ownerId: string): Promise<PollResult> {
  const db = serviceClient();
  const { data: apps, error } = await db.from("apps").select(APP_SELECT).eq("owner", ownerId);
  if (error) throw error;

  // Cloudflare Workers 無料プランの「1リクエストあたり外部サブリクエスト50回」に
  // 収めるため、1回の手動更新で巡回する本数を区切る。
  // 取得が古い順に回すので、連打すれば全部が順に更新される。
  // 残りは返り値の skipped に出て、画面に「残りは自動取得で順次更新」と出せる。
  const at = (a: any) => (a.last_polled_at ? new Date(a.last_polled_at).getTime() : 0);
  const ordered = (apps ?? []).sort((a: any, b: any) => at(a) - at(b));
  const batch = ordered.slice(0, MANUAL_POLL_BATCH);

  const result = await pollApps(db, batch, { budgetMs: 60_000 });
  return { ...result, skipped: result.skipped + (ordered.length - batch.length) };
}

export interface PollResult {
  /** 新規に取り込んだレビュー件数 */
  inserted: number;
  /** 実際に巡回したアプリ数 */
  apps: number;
  /** 時間予算切れで次回に回したアプリ数（0でなければ処理能力が足りていない） */
  skipped: number;
  /** ストアAPIの呼び出しに失敗したアプリ数（資格情報の失効など） */
  failed: number;
  /** 失敗の内訳（運営向け。ユーザーには apps.last_error として見える） */
  errors: { appId: string; message: string }[];
}

/**
 * 取得の結果をアプリ行に記録する。成功・失敗にかかわらず必ず呼ぶ。
 *
 * これを「新着があったときだけ」にしていると、
 *   - ユーザーは連携が壊れていることに気づけない
 *   - スケジューラは「一度も取得していないアプリ」と区別できない
 * の両方が起きる。
 */
async function markPolled(
  db: ReturnType<typeof serviceClient>,
  appId: string,
  error: string | null
): Promise<void> {
  const now = new Date().toISOString();
  await db
    .from("apps")
    .update({
      last_polled_at: now,
      last_error: error,
      last_error_at: error ? now : null,
    })
    .eq("id", appId);
  await db.from("poll_state").upsert({ app_id: appId, last_polled_at: now });
}

/**
 * 渡されたアプリ群を巡回してレビューをupsertし、新着を通知する共通処理。
 * POLL_CONCURRENCY 本のワーカーで並行処理し、budgetMs を超えたら残りは次回に回す。
 */
async function pollApps(
  db: ReturnType<typeof serviceClient>,
  apps: any[],
  opts: { budgetMs?: number } = {}
): Promise<PollResult> {
  const deadline = opts.budgetMs ? Date.now() + opts.budgetMs : null;
  let inserted = 0;
  const errors: { appId: string; message: string }[] = [];

  // 同一オーナーの認証情報は使い回す。解決前のPromiseをキャッシュすることで、
  // 並行実行でも同じ認証情報を二重に読まない。
  const credCache = new Map<string, Promise<AppStoreCreds | GooglePlayCreds | null>>();
  const credsFor = (owner: string, store: "appstore" | "googleplay") => {
    const cacheKey = `${owner}:${store}`;
    if (!credCache.has(cacheKey)) credCache.set(cacheKey, loadCredentials(owner, store));
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
      if (app.store === "appstore") {
        const creds = ((await credsFor(app.owner, "appstore")) ?? undefined) as
          | AppStoreCreds
          | undefined;
        reviews = await fetchAppStoreReviews(
          app.store_app_id,
          state?.last_seen_external_id,
          5,
          creds,
          // チェックポイントのレビューがAppleに削除されると終端を見失うので、
          // 前回取得時刻より古いところでも打ち切る（少し重複して取るが漏らさない）。
          app.last_polled_at ? new Date(new Date(app.last_polled_at).getTime() - 86_400_000) : null
        );
      } else {
        const creds = ((await credsFor(app.owner, "googleplay")) ?? undefined) as
          | GooglePlayCreds
          | undefined;
        reviews = await fetchGooglePlayReviews(app.store_app_id, 100, creds);
      }
    } catch (e: any) {
      const message = String(e?.message ?? e);
      console.error(`poll failed app=${app.id}`, e);
      errors.push({ appId: app.id, message });
      await markPolled(db, app.id, message); // 失敗も記録して画面に出す
      return; // 1アプリの失敗で全体を止めない
    }

    try {
      inserted += await ingestReviews(db, app, reviews);
      await markPolled(db, app.id, null);
    } catch (e: any) {
      const message = String(e?.message ?? e);
      console.error(`ingest failed app=${app.id}`, e);
      errors.push({ appId: app.id, message });
      await markPolled(db, app.id, message);
    }
  };

  // 時間予算を超えた時点で残りは次回のcronに回す（古い順に並んでいるので飢えない）。
  const processed = await runPool(apps, POLL_CONCURRENCY, pollOne, deadline);

  return {
    inserted,
    apps: processed,
    skipped: apps.length - processed,
    failed: errors.length,
    errors,
  };
}

/**
 * 取得済みレビュー配列を1アプリぶん取り込む共通処理（取得元に依存しない）。
 * upsert(重複排除) → 新規を通知 → AIトピック分類(Pro以上) → チェックポイント更新。
 * @returns 実際に新規挿入された件数（重複は0）
 */
export async function ingestReviews(
  db: ReturnType<typeof serviceClient>,
  app: { id: string; name: string; owner?: string; profiles?: any },
  reviews: NormalizedReview[],
  opts: { skipAi?: boolean } = {}
): Promise<number> {
  if (reviews.length === 0) return 0;

  const rows = reviews.map((r) => ({ ...r, app_id: app.id }));
  // onConflict + ignoreDuplicates: 既知の(app_id,store,external_id)は挿入されず select にも出ない。
  // → 二重取得しても新規分だけが返り、通知も新規にしか飛ばない（漏れ/重複を防ぐ肝）。
  // 一意キーに app_id を含めるのが重要。含めないと、同じアプリを2アカウントが
  // 監視したときに後発の取り込みが恒久的に0件になる。
  const { data: upserted, error: upErr } = await db
    .from("reviews")
    .upsert(rows, { onConflict: "app_id,store,external_id", ignoreDuplicates: true })
    .select("id, rating, body, title, external_id");
  if (upErr) {
    console.error(upErr);
    throw new Error(`レビューの保存に失敗しました: ${upErr.message}`);
  }

  const fresh = upserted ?? [];

  // 新規レビューを通知する。低評価を優先し、件数を絞って送る。
  // 逐次awaitだと100件の新着で通知だけに時間予算を使い切るので並列で投げる。
  const webhook = app.profiles?.notify_webhook_url ?? null;
  const email = app.profiles?.email ?? null;
  const notifyTargets = [...fresh].sort((a, b) => a.rating - b.rating).slice(0, NOTIFY_LIMIT);
  await Promise.allSettled([
    ...notifyTargets.map((row) =>
      notifyNewReview({
        appName: app.name,
        rating: row.rating,
        body: row.body,
        webhookUrl: webhook,
        email,
      })
    ),
    pushNewReviews(app, fresh),
  ]);

  // 新規レビューをAIでトピック分類 → review_topics に保存（分析画面の要望ランキング用）。
  const canClassify = limitsForPlan(app.profiles?.plan).topicAnalysis;
  if (!opts.skipAi && canClassify && app.owner) {
    await classifyNewReviews(db, fresh, app.owner, app.profiles?.plan);
  }

  // チェックポイント更新（最新レビューID）
  await db.from("poll_state").upsert({
    app_id: app.id,
    last_seen_external_id: reviews[0].external_id,
    last_polled_at: new Date().toISOString(),
  });

  return fresh.length;
}

/**
 * 新着レビューを端末へプッシュ通知する（アプリを終了していても届く経路）。
 *
 * 【まとめて1通にする理由】1回の取り込みで新着が20件入ることは普通にある。
 * 1件ずつ送るとロック画面が埋まり、通知そのものを切られる。
 * 1件なら本文入り、複数件なら件数のサマリーにする。
 *
 * 通知対象（すべて / ★1〜2のみ / 送らない）は端末の設定を profiles.push_scope に
 * 同期してあるので、サーバー側でもそれに従う。
 */
async function pushNewReviews(
  app: any,
  fresh: { rating: number; body: string | null; title: string | null }[]
): Promise<void> {
  if (!pushConfigured() || !app.owner || fresh.length === 0) return;

  const scope = app.profiles?.push_scope ?? "all";
  const targets = fresh.filter((r) => pushScopeAllows(scope, r.rating));
  if (targets.length === 0) return;

  const storeLabel = app.store === "appstore" ? "App Store" : "Google Play";
  const appName = app.name ? `・${app.name}` : "";

  let title: string;
  let body: string;
  if (targets.length === 1) {
    const r = targets[0];
    const text = (r.body?.trim() || r.title?.trim() || "(本文なし)").slice(0, 160);
    title = `新しいレビュー ★${r.rating}${appName}`;
    body = `${storeLabel}｜${text}`;
  } else {
    const worst = Math.min(...targets.map((r) => r.rating));
    title = `新しいレビューが${targets.length}件${appName}`;
    body = `${storeLabel}｜最低評価 ★${worst}`;
  }

  try {
    await sendPushToUser(app.owner, {
      title,
      body,
      data: { type: "reviews", app_id: String(app.id) },
    });
  } catch (e) {
    // pushが落ちても取り込みは止めない（メール/Webhookには届いている）。
    console.error("[poll] push failed", e);
  }
}

/**
 * 新規レビューをAIでトピック分類し review_topics に保存する。
 *
 * 分類にも AI枠(units)を消費させるのが重要。分類は取得件数に比例して発生し、
 * Maxはアプリ数が無制限なので、計測しないと1ユーザーの原価が青天井になる。
 */
async function classifyNewReviews(
  db: ReturnType<typeof serviceClient>,
  rows: { id: string; rating: number; body: string | null }[],
  ownerId: string,
  plan: string | null | undefined
): Promise<void> {
  if (!process.env.ANTHROPIC_API_KEY) return;
  const withBody = rows.filter((r) => r.body); // 本文が無ければ分類しない
  const targets = withBody.slice(0, MAX_CLASSIFY_PER_RUN);
  if (withBody.length > targets.length) {
    // 握りつぶさずログに残す。頻発するなら Workers Paid に上げる判断材料になる。
    console.warn(
      `[poll] 分類の上限(${MAX_CLASSIFY_PER_RUN}件)を超えたため ${withBody.length - targets.length}件は分類しませんでした`
    );
  }
  let quotaExhausted = false;

  await runPool(targets, CLASSIFY_CONCURRENCY, async (r) => {
    if (quotaExhausted) return;
    try {
      await reserveAiUnits(ownerId, plan, AI_UNITS.classify);
    } catch (e) {
      // 枠切れは異常ではない。以降の分類をやめるだけで、取り込み自体は成功させる。
      if (e instanceof QuotaError) quotaExhausted = true;
      return;
    }
    try {
      const topics = await classifyTopics({ rating: r.rating, body: r.body });
      if (topics.length === 0) {
        await refundAiUnits(ownerId, AI_UNITS.classify);
        return;
      }
      await db
        .from("review_topics")
        .upsert(
          topics.map((topic) => ({ review_id: r.id, topic })),
          { onConflict: "review_id,topic", ignoreDuplicates: true }
        );
    } catch (e) {
      await refundAiUnits(ownerId, AI_UNITS.classify);
      console.error(`classify failed review=${r.id}`, e);
    }
  });
}
