import { createCipheriv, createDecipheriv, createHash, randomBytes } from "crypto";

/**
 * ストア認証情報（Appleの.p8秘密鍵・GoogleのサービスアカウントJSON）を
 * DBに保存する前に暗号化する。AES-256-GCM。
 *
 * 鍵は環境変数 APP_ENCRYPTION_KEY（任意の十分長い文字列）を SHA-256 で
 * 32バイトに正規化して使う。未設定なら暗号化機能は無効。
 */

function key(): Buffer {
  const secret = process.env.APP_ENCRYPTION_KEY;
  if (!secret) throw new Error("APP_ENCRYPTION_KEY missing");
  return createHash("sha256").update(secret).digest(); // 32 bytes
}

export function cryptoConfigured(): boolean {
  return Boolean(process.env.APP_ENCRYPTION_KEY);
}

/** 平文 → "iv:tag:ciphertext"（すべてbase64） */
export function encrypt(plain: string): string {
  const iv = randomBytes(12);
  const cipher = createCipheriv("aes-256-gcm", key(), iv);
  const enc = Buffer.concat([cipher.update(plain, "utf8"), cipher.final()]);
  const tag = cipher.getAuthTag();
  return [iv.toString("base64"), tag.toString("base64"), enc.toString("base64")].join(":");
}

/** encrypt() の逆。改ざん・鍵不一致は例外。 */
export function decrypt(payload: string): string {
  const [ivB64, tagB64, dataB64] = payload.split(":");
  if (!ivB64 || !tagB64 || !dataB64) throw new Error("invalid ciphertext format");
  const decipher = createDecipheriv("aes-256-gcm", key(), Buffer.from(ivB64, "base64"));
  decipher.setAuthTag(Buffer.from(tagB64, "base64"));
  return Buffer.concat([decipher.update(Buffer.from(dataB64, "base64")), decipher.final()]).toString("utf8");
}
