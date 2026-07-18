import { NextRequest, NextResponse } from "next/server";
import { createSupabaseServer, getCurrentUser } from "@/lib/supabase/server";
import { limitsForPlan } from "@/lib/plan";

export const dynamic = "force-dynamic";

/** 連携アプリの追加 / 削除。ログインユーザーの owner でスコープ（RLS）。 */
export async function POST(req: NextRequest) {
  const user = await getCurrentUser();
  if (!user) return NextResponse.json({ error: "unauthorized" }, { status: 401 });

  const body = await req.json();
  const { store, store_app_id, name, description, reply_tone } = body ?? {};
  if (!store || !store_app_id || !name) {
    return NextResponse.json({ error: "store, store_app_id, name は必須です" }, { status: 400 });
  }

  const db = createSupabaseServer();

  // プラン別のアプリ数上限をチェック（RLSで自分のアプリのみカウント）
  const { data: profile } = await db.from("profiles").select("plan").eq("id", user.id).maybeSingle();
  const limits = limitsForPlan(profile?.plan);
  if (limits.maxApps !== null) {
    const { count } = await db.from("apps").select("id", { count: "exact", head: true });
    if ((count ?? 0) >= limits.maxApps) {
      return NextResponse.json(
        { error: `現在のプランでは${limits.maxApps}アプリまでです。Proにアップグレードすると全アプリを連携できます。` },
        { status: 403 }
      );
    }
  }

  const { data, error } = await db
    .from("apps")
    .insert({
      owner: user.id,
      store,
      store_app_id,
      name,
      description: description ?? null,
      reply_tone: reply_tone ?? "polite",
    })
    .select()
    .single();
  if (error) return NextResponse.json({ error: error.message }, { status: 500 });
  return NextResponse.json({ ok: true, app: data });
}

export async function DELETE(req: NextRequest) {
  const user = await getCurrentUser();
  if (!user) return NextResponse.json({ error: "unauthorized" }, { status: 401 });

  const { id } = await req.json();
  if (!id) return NextResponse.json({ error: "id required" }, { status: 400 });

  const db = createSupabaseServer();
  const { error } = await db.from("apps").delete().eq("id", id); // RLSで自分のアプリのみ削除可
  if (error) return NextResponse.json({ error: error.message }, { status: 500 });
  return NextResponse.json({ ok: true });
}
