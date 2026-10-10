import { encrypt, decrypt } from "./crypto";
import { serviceClient } from "./supabase";
import { verifyAppStoreCreds } from "./appstore";
import { verifyGooglePlayCreds } from "./googleplay";

/**
 * ストア資格情報の保管。
 *
 * store_credentials はクライアントから一切読めない（RLSポリシーを作っていない）ので、
 * ここでは常に service_role クライアントを使う。owner は必ず「認証済みの呼び出し元の
 * ユーザーID」を渡すこと。呼び出し側でリクエストボディ由来のIDを渡してはいけない。
 */

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

/**
 * 認証情報が実際にストアAPIで使えるかを確認する。
 *
 * これを保存前に必ず通す。検証しないと、鍵を1文字打ち間違えても
 * 「連携しました」と表示され、その後レビューが永久に0件のまま、
 * どこにもエラーが出ないという最悪の体験になる（実際そうなっていた）。
 * @throws 人が読んで対処できるメッセージ
 */
export async function verifyCredentials(
  store: "appstore" | "googleplay",
  creds: StoreCreds
): Promise<void> {
  if (store === "appstore") {
    await verifyAppStoreCreds(creds as AppStoreCreds);
  } else {
    await verifyGooglePlayCreds(creds as GooglePlayCreds);
  }
}

/** 認証情報を検証し、暗号化して保存（upsert）。 */
export async function saveCredentials(
  owner: string,
  store: "appstore" | "googleplay",
  creds: StoreCreds
): Promise<void> {
  await verifyCredentials(store, creds);
  const data_encrypted = encrypt(JSON.stringify(creds));
  const { error } = await serviceClient()
    .from("store_credentials")
    .upsert(
      { owner, store, data_encrypted, updated_at: new Date().toISOString() },
      { onConflict: "owner,store" }
    );
  if (error) throw error;
}

/** 復号して認証情報を取得（無ければ null）。 */
export async function loadCredentials<T extends StoreCreds = StoreCreds>(
  owner: string,
  store: "appstore" | "googleplay"
): Promise<T | null> {
  const { data } = await serviceClient()
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
export async function connectedStores(owner: string): Promise<string[]> {
  const { data } = await serviceClient()
    .from("store_credentials")
    .select("store")
    .eq("owner", owner);
  return (data ?? []).map((r: any) => r.store);
}

/** 連携を解除する（アプリはそのまま残る）。 */
export async function deleteCredentials(
  owner: string,
  store: "appstore" | "googleplay"
): Promise<void> {
  const { error } = await serviceClient()
    .from("store_credentials")
    .delete()
    .eq("owner", owner)
    .eq("store", store);
  if (error) throw error;
}
