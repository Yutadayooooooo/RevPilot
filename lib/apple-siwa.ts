import jwt from "jsonwebtoken";

/**
 * Sign in with Apple の REST API（トークンの取得と取り消し）。
 *
 * App Store は「Sign in with Apple を使うアプリは、アカウント削除時に Apple 側の
 * トークンも取り消すこと」を求めている（審査ガイドライン 5.1.1(v)）。
 * そのため、ログイン時に端末から受け取った認可コードをリフレッシュトークンに交換して
 * 暗号化して保存し、アカウント削除時にそれを revoke する。
 *
 * 必要な環境変数（未設定なら何もしない＝ログイン自体は成立する）:
 *   APPLE_TEAM_ID / APPLE_SIWA_KEY_ID / APPLE_SIWA_PRIVATE_KEY（.p8 の中身）
 *   APPLE_SIWA_CLIENT_ID（省略時は APPLE_IAP_BUNDLE_ID → jp.revpilot.app）
 */
const APPLE = "https://appleid.apple.com";

function clientId(): string {
  return process.env.APPLE_SIWA_CLIENT_ID || process.env.APPLE_IAP_BUNDLE_ID || "jp.revpilot.app";
}

export function siwaConfigured(): boolean {
  return Boolean(
    process.env.APPLE_TEAM_ID && process.env.APPLE_SIWA_KEY_ID && process.env.APPLE_SIWA_PRIVATE_KEY
  );
}

/** client_secret は ES256 で署名した JWT（最大6か月有効。ここでは都度5分で作る）。 */
function clientSecret(): string {
  const now = Math.floor(Date.now() / 1000);
  const key = (process.env.APPLE_SIWA_PRIVATE_KEY ?? "").replace(/\\n/g, "\n");
  return jwt.sign(
    { iss: process.env.APPLE_TEAM_ID, iat: now, exp: now + 300, aud: APPLE, sub: clientId() },
    key,
    { algorithm: "ES256", header: { alg: "ES256", kid: process.env.APPLE_SIWA_KEY_ID! } }
  );
}

async function post(path: string, params: Record<string, string>): Promise<Response> {
  return fetch(`${APPLE}${path}`, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ client_id: clientId(), client_secret: clientSecret(), ...params }),
  });
}

/** 認可コード（5分で失効）をリフレッシュトークンに交換する。 */
export async function exchangeAuthCode(code: string): Promise<string | null> {
  const res = await post("/auth/token", { code, grant_type: "authorization_code" });
  if (!res.ok) {
    console.error("[siwa] token exchange failed", res.status, await res.text().catch(() => ""));
    return null;
  }
  const json = (await res.json()) as { refresh_token?: string };
  return json.refresh_token ?? null;
}

/** リフレッシュトークンを取り消す（アカウント削除時）。 */
export async function revokeRefreshToken(token: string): Promise<boolean> {
  const res = await post("/auth/revoke", { token, token_type_hint: "refresh_token" });
  if (!res.ok) console.error("[siwa] revoke failed", res.status);
  return res.ok;
}
