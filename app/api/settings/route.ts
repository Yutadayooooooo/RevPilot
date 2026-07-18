import { NextRequest, NextResponse } from "next/server";
import { createSupabaseServer, getCurrentUser } from "@/lib/supabase/server";

export const dynamic = "force-dynamic";

/** 通知先などプロフィール設定の保存。auth.uid() でスコープ。 */
export async function POST(req: NextRequest) {
  const user = await getCurrentUser();
  if (!user) return NextResponse.json({ error: "unauthorized" }, { status: 401 });

  const body = await req.json();
  const { line_user_id, email } = body ?? {};

  const db = createSupabaseServer();
  // profiles行が無い場合も想定して upsert
  const { error } = await db.from("profiles").upsert(
    { id: user.id, line_user_id: line_user_id ?? null, email: email ?? user.email ?? null },
    { onConflict: "id" }
  );
  if (error) return NextResponse.json({ error: error.message }, { status: 500 });
  return NextResponse.json({ ok: true });
}
