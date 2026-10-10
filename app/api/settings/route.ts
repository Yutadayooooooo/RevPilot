import { NextRequest, NextResponse } from "next/server";
import { resolveApiAuth } from "@/lib/supabase/api-auth";
import { serviceClient } from "@/lib/supabase";
import { validateWebhookUrl } from "@/lib/notify";

export const dynamic = "force-dynamic";

/**
 * 通知先の保存。
 *
 * 【重要】profiles への書き込みは必ずここ（service_role）を通す。
 * かつては profiles の RLS が `for all` だったため、クライアントが自分の plan を
 * 直接 'max' に書き換えて課金を回避できた。RLS は select のみに絞り、
 * 書き込み可能な列をこのエンドポイントで明示的に制限する。
 *
 * email は受け付けない。以前は body の email をそのまま保存していたため、
 * 他人のアドレスを入れると週次サマリーが運営のドメインからその人に届いてしまった。
 * 宛先は常に認証済みの auth.users のアドレスを使う。
 */
export async function POST(req: NextRequest) {
  const auth = await resolveApiAuth(req);
  if (!auth) return NextResponse.json({ error: "unauthorized" }, { status: 401 });
  const { user } = auth;

  const body = (await req.json().catch(() => ({}))) as Record<string, unknown>;

  // 書き込める列はここに並べたものだけ。plan / stripe_* は絶対に受け付けない。
  // 部分更新にする。モバイルは push_scope だけを送るので、
  // 「送られなかった列は null で上書き」にすると通知先Webhookが消える。
  const patch: Record<string, unknown> = {
    id: user.id,
    email: user.email ?? null, // 認証済みアドレスのみ
  };

  let webhook: string | null = null;
  if ("notify_webhook_url" in body) {
    const raw = (body.notify_webhook_url ?? "") as string;
    if (typeof raw === "string" && raw.trim() !== "") {
      const check = validateWebhookUrl(raw);
      if (!check.ok) return NextResponse.json({ error: check.error }, { status: 400 });
      webhook = check.url;
    }
    patch.notify_webhook_url = webhook;
  }

  // リモートpushの通知対象。端末の設定と同期させる（サーバーが知らないと
  // 「★1〜2のみ」にしている人にも全部届いてしまう）。
  let scope: string | null = null;
  if ("push_scope" in body) {
    const raw = String(body.push_scope ?? "all");
    if (!["all", "low", "off"].includes(raw)) {
      return NextResponse.json({ error: "push_scope が不正です。" }, { status: 400 });
    }
    scope = raw;
    patch.push_scope = raw;
  }

  const db = serviceClient();
  const { error } = await db.from("profiles").upsert(patch, { onConflict: "id" });
  if (error) return NextResponse.json({ error: error.message }, { status: 500 });
  return NextResponse.json({ ok: true, notify_webhook_url: webhook, push_scope: scope });
}
