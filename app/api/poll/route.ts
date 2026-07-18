import { NextResponse } from "next/server";
import { getCurrentUser } from "@/lib/supabase/server";
import { pollOwnerApps } from "@/lib/poll";

export const dynamic = "force-dynamic";
export const maxDuration = 60;

/**
 * ログインユーザーによる手動更新。自分のアプリだけを今すぐ取得する。
 * Freeプランは自動取得が無い代わりに、この手動更新でレビューを取り込める。
 */
export async function POST() {
  const user = await getCurrentUser();
  if (!user) return NextResponse.json({ error: "unauthorized" }, { status: 401 });
  try {
    const result = await pollOwnerApps(user.id);
    return NextResponse.json({ ok: true, ...result });
  } catch (e: any) {
    return NextResponse.json({ ok: false, error: String(e?.message ?? e) }, { status: 500 });
  }
}
