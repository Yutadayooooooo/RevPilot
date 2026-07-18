import type { SupabaseClient } from "@supabase/supabase-js";
import { encrypt, decrypt } from "./crypto";

/** App Store Connect API の認証情報（.p8 秘密鍵など） */
export interface AppStoreCreds {
  issuerId: string;
  keyId: string;
  privateKey: string; // -----BEGIN PRIVATE KEY----- ... 改行込み
}

/** Google Play Developer API の認証情報 */
export interface GooglePlayCreds {
  serviceAccountJson: string; // サービスアカウントJSON全体（文字列）
}

export type StoreCreds = AppStoreCreds | GooglePlayCreds;

/** 認証情報を暗号化して保存（upsert）。RLSで owner にスコープされる。 */
export async function saveCredentials(
  db: SupabaseClient,
  owner: string,
  store: "appstore" | "googleplay",
  creds: StoreCreds
): Promise<void> {
  const data_encrypted = encrypt(JSON.stringify(creds));
  const { error } = await db
    .from("store_credentials")
    .upsert(
      { owner, store, data_encrypted, updated_at: new Date().toISOString() },
      { onConflict: "owner,store" }
    );
  if (error) throw error;
}

/** 復号して認証情報を取得（無ければ null）。service_role想定（cron/返信）。 */
export async function loadCredentials<T extends StoreCreds = StoreCreds>(
  db: SupabaseClient,
  owner: string,
  store: "appstore" | "googleplay"
): Promise<T | null> {
  const { data } = await db
    .from("store_credentials")
    .select("data_encrypted")
    .eq("owner", owner)
    .eq("store", store)
    .maybeSingle();
  if (!data?.data_encrypted) return null;
  try {
    return JSON.parse(decrypt(data.data_encrypted)) as T;
  } catch {
    return null; // 鍵不一致・改ざんなど
  }
}

/** 連携済みストアの一覧（オンボーディングの状態表示用）。 */
export async function connectedStores(db: SupabaseClient, owner: string): Promise<string[]> {
  const { data } = await db.from("store_credentials").select("store").eq("owner", owner);
  return (data ?? []).map((r: any) => r.store);
}
