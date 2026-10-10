import { NextRequest, NextResponse } from "next/server";
import { resolveApiAuth } from "@/lib/supabase/api-auth";
import { serviceClient } from "@/lib/supabase";
import { pushConfigured, sendPushToUser } from "@/lib/push";

export const dynamic = "force-dynamic";

/**
 * 自分の端末にテスト通知を送る。
 *
 * リモートpushは「実際に届くか」を確認する手段が無いと設定ミスに気づけない
 * （鍵の登録漏れ・APNs環境の取り違え・通知許可の拒否は、どれも無言で失敗する）。
 * 送り先は必ず認証済みユーザー自身の端末に限定する。
 */
export async function POST(req: NextRequest) {
  const auth = await resolveApiAuth(req);
  if (!auth) return NextResponse.json({ error: "unauthorized" }, { status: 401 });

  if (!pushConfigured()) {
    return NextResponse.json(
      { error: "プッシュ通知はまだ設定されていません。" },
      { status: 501 }
    );
  }

  const db = serviceClient();
  const { count } = await db
    .from("device_tokens")
    .select("token", { count: "exact", head: true })
    .eq("user_id", auth.user.id);

  if (!count) {
    return NextResponse.json(
      { error: "この端末が通知先として登録されていません。通知の許可を確認してください。" },
      { status: 400 }
    );
  }

  const sent = await sendPushToUser(
    auth.user.id,
    {
      title: "RevPilot のテスト通知",
      body: "この通知が届いていれば、アプリを終了していても新着レビューをお知らせできます。",
      data: { type: "test" },
    },
    db
  );

  if (sent === 0) {
    return NextResponse.json(
      { error: "送信できませんでした。通知の許可設定をご確認ください。" },
      { status: 502 }
    );
  }
  return NextResponse.json({ ok: true, sent });
}
