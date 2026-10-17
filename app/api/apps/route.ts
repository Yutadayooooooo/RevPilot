import { NextRequest, NextResponse, after } from "next/server";
import { resolveApiAuth } from "@/lib/supabase/api-auth";
import { limitsForPlan } from "@/lib/plan";
import { loadCredentials, type AppStoreCreds, type GooglePlayCreds } from "@/lib/credentials";
import { verifyAppStoreAccess } from "@/lib/appstore";
import { verifyGooglePlayAccess } from "@/lib/googleplay";
import { pollOneApp, storeErrorMessage, type PollResult } from "@/lib/poll";
import { takeRateToken } from "@/lib/quota";

export const dynamic = "force-dynamic";

/**
 * 追加の直後の初回取得を、応答を返す前に待つ上限(ms)。
 * たいていは数秒で終わる（App Store でも最大5ページ）。超えたぶんは応答のあとで続ける。
 * アプリ側の追加のタイムアウト(45秒)より十分短くしておく。
 */
const INITIAL_FETCH_WAIT_MS = 15_000;

/**
 * 初回取得の結果（応答の initial_fetch）。
 * - done    : 取り込みまで済んだ（inserted 件）
 * - failed  : 取得に失敗した（error は短い日本語。apps.last_error と同じ文面）
 * - pending : まだ取り込み中（応答のあとで続ける。終われば一覧に出る）
 * - skipped : 短時間に追加が続いたので今回は取得しない（毎時の自動取得で取り込む）
 */
type InitialFetch =
  | { status: "done"; inserted: number }
  | { status: "failed"; inserted: number; error: string }
  | { status: "pending" }
  | { status: "skipped" };

/**
 * 連携アプリの追加 / 削除。Web cookie / モバイル Bearer 両対応。
 *
 * POST body: { store, store_app_id, name?, description?, reply_tone?, reply_opening?, ... }
 * 応答: { ok, app, name（実際に使った名前）, initial_fetch（下の InitialFetch） }
 *
 * 件数上限は DB のトリガ(enforce_app_limit)でも強制している。
 * ここでのチェックは「分かりやすいエラーを返すため」であって、防御の本体ではない
 * （クライアントは PostgREST へ直接 insert できるため、アプリ層だけでは守れない）。
 */
export async function POST(req: NextRequest) {
  const auth = await resolveApiAuth(req);
  if (!auth) return NextResponse.json({ error: "unauthorized" }, { status: 401 });
  const { user, db } = auth;

  const body = await req.json();
  const { store, store_app_id, name, description, reply_tone, reply_opening, reply_closing, reply_rules } = body ?? {};
  const appId = String(store_app_id ?? "").trim();
  // 名前は任意。省略したら App Store はストアに登録されている名前を使う（下の確認で取得する）。
  const givenName = typeof name === "string" ? name.trim() : "";
  if (!store || !appId) {
    return NextResponse.json(
      { error: "ストアと、アプリのID（App Store は Apple ID、Google Play はパッケージ名）を指定してください。" },
      { status: 400 }
    );
  }
  if (store !== "appstore" && store !== "googleplay") {
    return NextResponse.json({ error: "ストアは App Store か Google Play を指定してください。" }, { status: 400 });
  }

  const { data: profile } = await db.from("profiles").select("plan").eq("id", user.id).maybeSingle();
  const limits = limitsForPlan(profile?.plan);
  if (limits.maxApps !== null) {
    const { count } = await db.from("apps").select("id", { count: "exact", head: true });
    if ((count ?? 0) >= limits.maxApps) {
      return NextResponse.json(
        { error: `Freeプランで連携できるアプリは${limits.maxApps}件までです。Proにアップグレードするとアプリ数は無制限になります。` },
        { status: 403 }
      );
    }
  }

  // 追加の時点でストア側のアクセス権を確認する。
  // ここで弾かないと、App IDの打ち間違いや権限不足に気づけるのが
  // 「1時間後もレビューが0件」というタイミングになってしまう。
  let storeName: string | null = null;
  try {
    if (store === "appstore") {
      const creds = await loadCredentials<AppStoreCreds>(user.id, "appstore");
      if (!creds) {
        return NextResponse.json(
          { error: "先に App Store Connect の連携を済ませてください。" },
          { status: 400 }
        );
      }
      storeName = await verifyAppStoreAccess(appId, creds);
    } else {
      const creds = await loadCredentials<GooglePlayCreds>(user.id, "googleplay");
      if (!creds) {
        return NextResponse.json(
          { error: "先に Google Play の連携を済ませてください。" },
          { status: 400 }
        );
      }
      await verifyGooglePlayAccess(appId, creds);
    }
  } catch (e: any) {
    // 確認の案内は日本語。接続の失敗など英語の生の文面は、短い日本語に置き換える。
    console.error("[apps] store access check failed", e);
    return NextResponse.json({ error: storeErrorMessage(store, e) }, { status: 400 });
  }

  // 名前を省略したら、App Store はストアでの名前を使う。
  // Google Play は API から名前を取れないので、パッケージ名にする（あとから編集できる）。
  const appName = givenName || storeName?.trim() || appId;

  const { data, error } = await db
    .from("apps")
    .insert({
      owner: user.id,
      store,
      store_app_id: appId,
      name: appName,
      description: description ?? null,
      reply_tone: reply_tone ?? "polite",
      // 返信スタイルは任意。未指定なら列に触れない（スキーマ未適用のDBでも追加できるように）。
      ...(reply_opening ? { reply_opening } : {}),
      ...(reply_closing ? { reply_closing } : {}),
      ...(reply_rules ? { reply_rules } : {}),
    })
    .select()
    .single();

  if (error) {
    if (error.code === "23505") {
      // unique (owner, store, store_app_id)
      return NextResponse.json({ error: "このアプリはすでに追加されています。" }, { status: 409 });
    }
    // DBトリガによる上限超過は 403 として返す（PostgresのSQLSTATE 23514）。文面はトリガの日本語。
    const overLimit = error.code === "23514" || /件までです/.test(error.message);
    if (!overLimit) console.error("[apps] insert failed", error);
    return NextResponse.json(
      { error: overLimit ? error.message : "アプリを追加できませんでした。時間をおいて再度お試しください。" },
      { status: overLimit ? 403 : 500 }
    );
  }

  const initialFetch = await startInitialFetch(user.id, data.id);
  return NextResponse.json({ ok: true, app: data, name: appName, initial_fetch: initialFetch });
}

/**
 * 追加したアプリのレビューを、その場で取りに行く（ベストエフォート。失敗しても追加は成功のまま）。
 *
 * 以前は追加しても次の毎時の自動取得まで何も入らず、「最長1時間待つもの」と受け取られて
 * 離脱されやすかった。また、鍵にレビューを読む権限が無い（/apps は読めても customerReviews は
 * 403 になる鍵がある）ことにも、その時点では気づけなかった。
 *
 * - 過去分の取り込みでは通知しない（lib/poll.ts の ingestReviews が追加時刻で絞る）。
 * - トピック分類はしない。追加処理ぶんの外部呼び出しを使ったあとなので、
 *   分類まで回すと Workers 無料プランの「1リクエスト50回」を超えうる。
 * - 待ちきれなかった分は after()（Workers では waitUntil）で応答のあとも続ける。
 */
async function startInitialFetch(userId: string, appId: string): Promise<InitialFetch> {
  // 追加と削除を繰り返して取得を連発させない（/api/poll の回数制限とは別枠）。
  // ここで落ちても追加そのものは成功させる（取得は毎時の自動取得で拾われる）。
  try {
    if (!(await takeRateToken(userId, "app_initial_poll", 60, 3))) return { status: "skipped" };
  } catch (e) {
    console.error("[apps] initial fetch skipped", e);
    return { status: "skipped" };
  }

  const settled: Promise<{ result: PollResult } | { error: unknown }> = pollOneApp(appId, {
    skipAi: true,
  }).then(
    (result) => ({ result }),
    (error: unknown) => ({ error })
  );
  try {
    after(settled);
  } catch (e) {
    // リクエストの外では使えない。待ちきれなかった分は毎時の自動取得に任せる。
    console.error("[apps] after() unavailable", e);
  }

  let timer: ReturnType<typeof setTimeout> | undefined;
  const timeout = new Promise<null>((resolve) => {
    timer = setTimeout(() => resolve(null), INITIAL_FETCH_WAIT_MS);
  });
  const outcome = await Promise.race([settled, timeout]);
  clearTimeout(timer);

  if (outcome === null) return { status: "pending" };
  if ("error" in outcome) {
    // pollOneApp が投げるのはDBの失敗など。ストアの失敗は result.errors に入る。
    console.error("[apps] initial fetch failed", outcome.error);
    return {
      status: "failed",
      inserted: 0,
      error: "最初のレビュー取得に失敗しました。毎時の自動取得で取り込みます。",
    };
  }
  const { result } = outcome;
  const failure = result.errors[0];
  if (failure) return { status: "failed", inserted: result.inserted, error: failure.message };
  return { status: "done", inserted: result.inserted };
}

export async function DELETE(req: NextRequest) {
  const auth = await resolveApiAuth(req);
  if (!auth) return NextResponse.json({ error: "unauthorized" }, { status: 401 });

  const { id } = await req.json();
  if (!id) return NextResponse.json({ error: "id required" }, { status: 400 });

  const { error } = await auth.db.from("apps").delete().eq("id", id); // RLSで自分のアプリのみ削除可
  if (error) return NextResponse.json({ error: error.message }, { status: 500 });
  return NextResponse.json({ ok: true });
}
