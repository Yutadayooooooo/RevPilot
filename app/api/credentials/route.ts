import { NextRequest, NextResponse } from "next/server";
import { resolveApiAuth } from "@/lib/supabase/api-auth";
import {
  saveCredentials,
  connectedStores,
  deleteCredentials,
  type StoreCreds,
} from "@/lib/credentials";
import { cryptoConfigured } from "@/lib/crypto";

export const dynamic = "force-dynamic";
export const runtime = "nodejs";
/** 保存前にストアAPIへ疎通確認するので、単純な保存より時間がかかる。 */
export const maxDuration = 60;

/** 連携済みストアの一覧を返す（Web cookie / モバイル Bearer 両対応）。 */
export async function GET(req: NextRequest) {
  const auth = await resolveApiAuth(req);
  if (!auth) return NextResponse.json({ error: "unauthorized" }, { status: 401 });
  const stores = await connectedStores(auth.user.id);
  return NextResponse.json({ connected: stores });
}

/**
 * ストア認証情報を検証してから暗号化保存。
 * body(App Store):    { store: "appstore", issuerId, keyId, privateKey }
 * body(Google Play):  { store: "googleplay", serviceAccountJson }
 *
 * 検証に失敗した場合は保存しない。「保存できたのに動かない」状態を作らないため。
 */
export async function POST(req: NextRequest) {
  if (!cryptoConfigured()) {
    return NextResponse.json(
      { error: "暗号鍵(APP_ENCRYPTION_KEY)が未設定のため認証情報を保存できません" },
      { status: 501 }
    );
  }
  const auth = await resolveApiAuth(req);
  if (!auth) return NextResponse.json({ error: "unauthorized" }, { status: 401 });
  const { user } = auth;

  const body = await req.json();
  const store = body?.store;

  let creds: StoreCreds;
  if (store === "appstore") {
    const { issuerId, keyId, privateKey } = body ?? {};
    if (!issuerId || !keyId || !privateKey) {
      return NextResponse.json({ error: "Issuer ID・Key ID・秘密鍵は必須です" }, { status: 400 });
    }
    creds = { issuerId: String(issuerId).trim(), keyId: String(keyId).trim(), privateKey };
  } else if (store === "googleplay") {
    const { serviceAccountJson } = body ?? {};
    if (!serviceAccountJson) {
      return NextResponse.json({ error: "サービスアカウントJSONは必須です" }, { status: 400 });
    }
    try {
      const parsed = JSON.parse(serviceAccountJson);
      if (!parsed?.client_email || !parsed?.private_key) {
        return NextResponse.json(
          { error: "サービスアカウントJSONに client_email / private_key がありません。JSONキー全体を貼り付けてください。" },
          { status: 400 }
        );
      }
    } catch {
      return NextResponse.json(
        { error: "サービスアカウントJSONが有効なJSONではありません。ファイルの中身を丸ごと貼り付けてください。" },
        { status: 400 }
      );
    }
    creds = { serviceAccountJson };
  } else {
    return NextResponse.json({ error: "store は appstore / googleplay のいずれか" }, { status: 400 });
  }

  try {
    await saveCredentials(user.id, store, creds);
  } catch (e: any) {
    // 検証エラーは利用者が対処すべき内容なのでそのまま見せる（422で「入力の問題」と示す）
    return NextResponse.json({ error: String(e?.message ?? "保存に失敗しました") }, { status: 422 });
  }
  return NextResponse.json({ ok: true, store });
}

/** 連携を解除する。 */
export async function DELETE(req: NextRequest) {
  const auth = await resolveApiAuth(req);
  if (!auth) return NextResponse.json({ error: "unauthorized" }, { status: 401 });

  const { store } = await req.json().catch(() => ({}));
  if (store !== "appstore" && store !== "googleplay") {
    return NextResponse.json({ error: "store は appstore / googleplay のいずれか" }, { status: 400 });
  }
  try {
    await deleteCredentials(auth.user.id, store);
  } catch (e: any) {
    return NextResponse.json({ error: String(e?.message ?? e) }, { status: 500 });
  }
  return NextResponse.json({ ok: true });
}
