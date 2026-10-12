import { NextRequest, NextResponse } from "next/server";
import { resolveApiAuth } from "@/lib/supabase/api-auth";
import { limitsForPlan } from "@/lib/plan";
import { loadCredentials, type AppStoreCreds, type GooglePlayCreds } from "@/lib/credentials";
import { verifyAppStoreAccess } from "@/lib/appstore";
import { verifyGooglePlayAccess } from "@/lib/googleplay";

export const dynamic = "force-dynamic";

/**
 * 連携アプリの追加 / 削除。Web cookie / モバイル Bearer 両対応。
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
  if (!store || !store_app_id || !name) {
    return NextResponse.json({ error: "store, store_app_id, name は必須です" }, { status: 400 });
  }
  if (store !== "appstore" && store !== "googleplay") {
    return NextResponse.json({ error: "store は appstore / googleplay のいずれか" }, { status: 400 });
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
  const appId = String(store_app_id).trim();
  try {
    if (store === "appstore") {
      const creds = await loadCredentials<AppStoreCreds>(user.id, "appstore");
      if (!creds) {
        return NextResponse.json(
          { error: "先に App Store Connect の連携を済ませてください。" },
          { status: 400 }
        );
      }
      await verifyAppStoreAccess(appId, creds);
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
    return NextResponse.json({ error: String(e?.message ?? e) }, { status: 400 });
  }

  const { data, error } = await db
    .from("apps")
    .insert({
      owner: user.id,
      store,
      store_app_id: appId,
      name,
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
    // DBトリガによる上限超過は 403 として返す（PostgresのSQLSTATE 23514）
    const overLimit = error.code === "23514" || /件までです/.test(error.message);
    return NextResponse.json({ error: error.message }, { status: overLimit ? 403 : 500 });
  }
  return NextResponse.json({ ok: true, app: data });
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
