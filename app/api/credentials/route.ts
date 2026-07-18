import { NextRequest, NextResponse } from "next/server";
import { createSupabaseServer, getCurrentUser } from "@/lib/supabase/server";
import { saveCredentials, connectedStores, type StoreCreds } from "@/lib/credentials";
import { cryptoConfigured } from "@/lib/crypto";

export const dynamic = "force-dynamic";

/** 連携済みストアの一覧を返す。 */
export async function GET() {
  const user = await getCurrentUser();
  if (!user) return NextResponse.json({ error: "unauthorized" }, { status: 401 });
  const db = createSupabaseServer();
  const stores = await connectedStores(db, user.id);
  return NextResponse.json({ connected: stores });
}

/**
 * ストア認証情報を暗号化保存。
 * body(App Store):    { store: "appstore", issuerId, keyId, privateKey }
 * body(Google Play):  { store: "googleplay", serviceAccountJson }
 */
export async function POST(req: NextRequest) {
  if (!cryptoConfigured()) {
    return NextResponse.json(
      { error: "暗号鍵(APP_ENCRYPTION_KEY)が未設定のため認証情報を保存できません" },
      { status: 501 }
    );
  }
  const user = await getCurrentUser();
  if (!user) return NextResponse.json({ error: "unauthorized" }, { status: 401 });

  const body = await req.json();
  const store = body?.store;

  let creds: StoreCreds;
  if (store === "appstore") {
    const { issuerId, keyId, privateKey } = body ?? {};
    if (!issuerId || !keyId || !privateKey) {
      return NextResponse.json({ error: "issuerId, keyId, privateKey は必須です" }, { status: 400 });
    }
    creds = { issuerId, keyId, privateKey };
  } else if (store === "googleplay") {
    const { serviceAccountJson } = body ?? {};
    if (!serviceAccountJson) {
      return NextResponse.json({ error: "serviceAccountJson は必須です" }, { status: 400 });
    }
    try {
      JSON.parse(serviceAccountJson); // 妥当なJSONか検証
    } catch {
      return NextResponse.json({ error: "serviceAccountJson が有効なJSONではありません" }, { status: 400 });
    }
    creds = { serviceAccountJson };
  } else {
    return NextResponse.json({ error: "store は appstore / googleplay のいずれか" }, { status: 400 });
  }

  const db = createSupabaseServer();
  try {
    await saveCredentials(db, user.id, store, creds);
  } catch (e: any) {
    return NextResponse.json({ error: e.message ?? "保存に失敗しました" }, { status: 500 });
  }
  return NextResponse.json({ ok: true, store });
}
