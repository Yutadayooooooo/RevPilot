import { GoogleAuth } from "google-auth-library";
import { serviceClient } from "./supabase";

/**
 * リモートプッシュ通知（Firebase Cloud Messaging HTTP v1）。
 *
 * 【なぜ必要か】これが無いと、アプリを完全に終了している間に来たレビューは
 * 端末に通知されない（flutter_local_notifications は「起動中に検知したもの」しか出せない）。
 * 「レビューを見逃さない」が売りの製品で、そこが穴になっていた。
 *
 * 【なぜ FCM に寄せたか】Android のプッシュは事実上 FCM 以外に選択肢がなく、
 * iOS も APNs 鍵を Firebase に預ければ同じ経路で送れる。
 * iOSだけ直接APNsを叩く構成にすると、サーバーの送信経路が2本になるうえ、
 * Flutter側で firebase_messaging と自前のAPNsトークン取得が
 * AppDelegate の swizzling で衝突する。経路は1本にする。
 *
 * 【未設定でも壊れない】FIREBASE_SERVICE_ACCOUNT_JSON が無ければ黙ってスキップする。
 * 通知はメール / Slack / Discord にも出しているので、push だけが落ちても
 * レビュー取得そのものは止めない。
 */

const SCOPE = "https://www.googleapis.com/auth/firebase.messaging";

/** Androidの通知チャンネルID。mobile/lib/local_notifications.dart の _channelId と一致させること。 */
const ANDROID_CHANNEL_ID = "reviews";

/** 1ユーザーあたりの送信先端末数の上限（異常に増えた場合の保険）。 */
const MAX_TOKENS_PER_USER = 20;

export interface PushMessage {
  title: string;
  body: string;
  /** 端末側でタップ時の遷移に使う付加情報。値は文字列のみ（FCMの仕様）。 */
  data?: Record<string, string>;
}

/** 送信に必要な設定が揃っているか。 */
export function pushConfigured(): boolean {
  return Boolean(process.env.FIREBASE_SERVICE_ACCOUNT_JSON);
}

interface ServiceAccount {
  project_id?: string;
  client_email?: string;
  private_key?: string;
}

function serviceAccount(): ServiceAccount | null {
  const raw = process.env.FIREBASE_SERVICE_ACCOUNT_JSON;
  if (!raw) return null;
  try {
    return JSON.parse(raw) as ServiceAccount;
  } catch {
    console.error("[push] FIREBASE_SERVICE_ACCOUNT_JSON が不正なJSONです");
    return null;
  }
}

// アクセストークンは1時間有効。1回のcronで何十通も送るので都度発行しない。
let cachedToken: { value: string; expiresAt: number } | null = null;

async function accessToken(credentials: ServiceAccount): Promise<string | null> {
  if (cachedToken && cachedToken.expiresAt > Date.now() + 60_000) return cachedToken.value;
  try {
    const client = await new GoogleAuth({ credentials, scopes: [SCOPE] }).getClient();
    const t = await client.getAccessToken();
    if (!t.token) return null;
    // 実際の有効期限は取れないこともあるので、控えめに50分で切る。
    cachedToken = { value: t.token, expiresAt: Date.now() + 50 * 60_000 };
    return t.token;
  } catch (e) {
    console.error("[push] アクセストークンの取得に失敗", e);
    return null;
  }
}

/** 通知対象の設定（profiles.push_scope）がこの評価を通知すべきか。 */
export function pushScopeAllows(scope: string | null | undefined, rating: number): boolean {
  const s = scope ?? "all";
  if (s === "off") return false;
  if (s === "low") return rating <= 2;
  return true;
}

type Db = ReturnType<typeof serviceClient>;

/**
 * 利用者の全端末にプッシュを送る。送れた件数を返す。
 *
 * 無効になったトークン（アンインストール・再インストール）は
 * その場で削除する。放置すると毎回失敗し続け、送信数だけが増えていく。
 */
export async function sendPushToUser(
  userId: string,
  msg: PushMessage,
  db?: Db
): Promise<number> {
  const credentials = serviceAccount();
  if (!credentials?.project_id) return 0;

  const client = db ?? serviceClient();
  const { data: rows, error } = await client
    .from("device_tokens")
    .select("token, platform")
    .eq("user_id", userId)
    .order("updated_at", { ascending: false })
    .limit(MAX_TOKENS_PER_USER);
  if (error || !rows?.length) return 0;

  const token = await accessToken(credentials);
  if (!token) return 0;

  const url = `https://fcm.googleapis.com/v1/projects/${credentials.project_id}/messages:send`;
  const dead: string[] = [];

  const results = await Promise.allSettled(
    rows.map(async (row: { token: string; platform: string }) => {
      const res = await fetch(url, {
        method: "POST",
        headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
        body: JSON.stringify({
          message: {
            token: row.token,
            notification: { title: msg.title, body: msg.body },
            data: msg.data ?? {},
            android: {
              priority: "HIGH",
              notification: { channel_id: ANDROID_CHANNEL_ID },
            },
            apns: {
              headers: { "apns-priority": "10" },
              payload: { aps: { sound: "default" } },
            },
          },
        }),
        signal: AbortSignal.timeout(10_000),
      });

      if (res.ok) return true;

      const text = await res.text().catch(() => "");
      // 404 UNREGISTERED = アンインストール等でトークンが失効。
      // 400 INVALID_ARGUMENT = トークンの形式が不正（別プロジェクトのトークン等）。
      if (res.status === 404 || (res.status === 400 && text.includes("INVALID_ARGUMENT"))) {
        dead.push(row.token);
        return false;
      }
      console.error(`[push] 送信失敗 ${res.status}: ${text.slice(0, 300)}`);
      return false;
    })
  );

  if (dead.length) {
    await client.from("device_tokens").delete().in("token", dead);
  }

  return results.filter((r) => r.status === "fulfilled" && r.value === true).length;
}
