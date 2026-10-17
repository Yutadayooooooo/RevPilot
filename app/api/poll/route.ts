import { NextRequest, NextResponse } from "next/server";
import { resolveApiAuth } from "@/lib/supabase/api-auth";
import { pollOwnerApps } from "@/lib/poll";
import { takeRateToken } from "@/lib/quota";

export const dynamic = "force-dynamic";
export const maxDuration = 120;

/**
 * ログインユーザーによる手動更新。自分のアプリだけを今すぐ取得する。
 * Web cookie / モバイル Bearer 両対応。
 *
 * 1回で最大60秒かかる処理なので、頻度を絞る。制限しないと、ログイン済みなら
 * 誰でもループで叩けてしまい、関数の実行時間を一方的に消費させられる。
 */
export async function POST(req: NextRequest) {
  const auth = await resolveApiAuth(req);
  if (!auth) return NextResponse.json({ error: "unauthorized" }, { status: 401 });

  if (!(await takeRateToken(auth.user.id, "poll", 60, 2))) {
    return NextResponse.json(
      { error: "更新は1分に2回までです。自動取得は毎時走っているので、少し待ってからお試しください。" },
      { status: 429 }
    );
  }

  try {
    const result = await pollOwnerApps(auth.user.id);
    return NextResponse.json({
      ok: true,
      inserted: result.inserted,
      apps: result.apps,
      skipped: result.skipped,
      failed: result.failed,
      // 失敗の理由はユーザーが対処すべき情報（鍵の失効など）なので、どのアプリかと合わせて返す。
      // message は apps.last_error と同じ短い日本語（ストアの生の応答はログにだけ残る）。
      errors: result.errors.map((e) => ({ appId: e.appId, appName: e.appName, message: e.message })),
    });
  } catch (e: any) {
    console.error("[poll] manual poll failed", e);
    return NextResponse.json(
      { ok: false, error: "レビューの取得に失敗しました。時間をおいて再度お試しください。" },
      { status: 500 }
    );
  }
}
