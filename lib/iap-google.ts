import { GoogleAuth } from "google-auth-library";
import { STORE_PRODUCT_TO_PLAN, type PlanKey } from "@/lib/plans";

/**
 * Google Play Billing（Android のアプリ内課金）のサーバー処理。
 *
 * 【検証の方針】Apple 側（lib/iap-apple.ts）と同じ。
 * クライアントが申告した内容は一切信用せず、purchaseToken を鍵にして
 * Google Play Developer API へ問い合わせ、Googleが返す状態を正とする。
 * リアルタイム開発者通知(RTDN)も「再問い合わせのトリガ」としてのみ使う。
 *
 * 【Apple 側との違い】
 * 課金の検証に使うサービスアカウントは、利用者が登録するストア連携用のもの
 * （store_credentials）とは別物。RevPilot アプリ自身の課金を確認するための、
 * 運営専用のサービスアカウントを環境変数で持つ。混同しないこと。
 */

const SCOPE = "https://www.googleapis.com/auth/androidpublisher";
const API = "https://androidpublisher.googleapis.com/androidpublisher/v3/applications";

/** ストア商品ID → プラン。定義は shared/plans.json（Play Console の商品IDも一致させる）。 */
const GOOGLE_PRODUCT_TO_PLAN = STORE_PRODUCT_TO_PLAN;

/** HTTPステータス付きのIAPエラー。route側でそのまま応答に使う。 */
export class GoogleIapError extends Error {
  readonly status: number;
  constructor(message: string, status = 400) {
    super(message);
    this.status = status;
  }
}

/** 商品ID → プラン（不明なら null）。 */
export function planForGoogleProduct(productId: string | null | undefined): PlanKey | null {
  if (!productId) return null;
  return GOOGLE_PRODUCT_TO_PLAN[productId] ?? null;
}

/** Android課金の検証に必要な設定が揃っているか。 */
export function googleIapConfigured(): boolean {
  return Boolean(
    process.env.GOOGLE_PLAY_IAP_SERVICE_ACCOUNT_JSON && process.env.GOOGLE_PLAY_PACKAGE_NAME
  );
}

function packageName(): string {
  return process.env.GOOGLE_PLAY_PACKAGE_NAME!;
}

async function accessToken(): Promise<string> {
  const raw = process.env.GOOGLE_PLAY_IAP_SERVICE_ACCOUNT_JSON;
  if (!raw) throw new GoogleIapError("Android課金の検証設定がありません。", 501);
  let credentials: Record<string, unknown>;
  try {
    credentials = JSON.parse(raw);
  } catch {
    throw new GoogleIapError("GOOGLE_PLAY_IAP_SERVICE_ACCOUNT_JSON が不正なJSONです。", 500);
  }
  const client = await new GoogleAuth({ credentials, scopes: [SCOPE] }).getClient();
  const t = await client.getAccessToken();
  if (!t.token) throw new GoogleIapError("Googleのアクセストークンを取得できませんでした。", 502);
  return t.token;
}

/**
 * subscriptionsv2 の購読状態。
 * https://developers.google.com/android-publisher/api-ref/rest/v3/purchases.subscriptionsv2
 */
export interface GoogleSubscriptionState {
  active: boolean;
  plan: PlanKey | null;
  productId: string | null;
  expiresAt: Date | null;
  /** 購入の同一性の鍵。トークンは更新のたびに変わることがあるので linkedPurchaseToken も見る。 */
  purchaseToken: string;
  /** 未確認(acknowledge前)の購入か。3日以内に確認しないと自動返金される。 */
  needsAcknowledgement: boolean;
  /** 無料トライアル期間中か（lineItems[].offerPhase.freeTrial）。 */
  inTrial: boolean;
}

/** 有効とみなす購読状態。猶予期間(GRACE_PERIOD)も利用継続を許す。 */
const ACTIVE_STATES = new Set([
  "SUBSCRIPTION_STATE_ACTIVE",
  "SUBSCRIPTION_STATE_IN_GRACE_PERIOD",
  // CANCELED は「更新を止めたが期限まで有効」なので、期限判定と併用して有効扱いにする
  "SUBSCRIPTION_STATE_CANCELED",
]);

/**
 * purchaseToken から現在の購読状態を取得する。
 * 購入時・復元時・RTDN受信時・期限切れの定期チェックのすべてでここを通す。
 */
export async function getGoogleSubscriptionState(
  purchaseToken: string
): Promise<GoogleSubscriptionState> {
  const token = await accessToken();
  const url = `${API}/${encodeURIComponent(packageName())}/purchases/subscriptionsv2/tokens/${encodeURIComponent(purchaseToken)}`;
  const res = await fetch(url, {
    headers: { Authorization: `Bearer ${token}` },
    signal: AbortSignal.timeout(10_000),
  });

  if (res.status === 404 || res.status === 410) {
    throw new GoogleIapError("該当する購入がGoogle Playで見つかりませんでした。", 404);
  }
  if (res.status === 401 || res.status === 403) {
    throw new GoogleIapError(
      "Google Play の課金APIにアクセスできません（サービスアカウントの権限を確認してください）。",
      500
    );
  }
  if (!res.ok) {
    throw new GoogleIapError(`Google Playへの問い合わせに失敗しました（${res.status}）。`, 502);
  }

  const json: any = await res.json();
  const state: string = json?.subscriptionState ?? "";
  const line = (json?.lineItems ?? [])[0] ?? {};
  const productId: string | null = line.productId ?? null;
  const expiryRaw: string | undefined = line.expiryTime;
  const expiresAt = expiryRaw ? new Date(expiryRaw) : null;

  // 取り消し（返金・チャージバック）は無条件で無効。
  const revoked = Boolean(json?.canceledStateContext?.systemInitiatedCancellation) &&
    state === "SUBSCRIPTION_STATE_EXPIRED";

  const withinPeriod = expiresAt ? expiresAt.getTime() > Date.now() : false;
  const active = !revoked && ACTIVE_STATES.has(state) && withinPeriod;

  return {
    active,
    plan: planForGoogleProduct(productId),
    productId,
    expiresAt,
    purchaseToken,
    needsAcknowledgement: json?.acknowledgementState === "ACKNOWLEDGEMENT_STATE_PENDING",
    inTrial: Boolean(line.offerPhase?.freeTrial),
  };
}

/**
 * 購入を確認済みにする（acknowledge）。
 *
 * Google Play は購入から3日以内に確認しないと**自動的に返金**する。
 * クライアント側(in_app_purchase の completePurchase)でも確認されるが、
 * アプリが落ちた場合などに取りこぼすため、サーバー側でも必ず確認する。
 */
export async function acknowledgeGooglePurchase(
  purchaseToken: string,
  subscriptionId: string
): Promise<void> {
  const token = await accessToken();
  const url =
    `${API}/${encodeURIComponent(packageName())}/purchases/subscriptions/` +
    `${encodeURIComponent(subscriptionId)}/tokens/${encodeURIComponent(purchaseToken)}:acknowledge`;
  const res = await fetch(url, {
    method: "POST",
    headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
    body: JSON.stringify({}),
    signal: AbortSignal.timeout(10_000),
  });
  // 既に確認済みなら 400 が返ることがある。これは正常系として扱う。
  if (!res.ok && res.status !== 400) {
    console.error(`[iap-google] acknowledge failed ${res.status}: ${await res.text()}`);
  }
}

/** RTDN（Pub/Sub push）のペイロード。 */
export interface GoogleRtdnNotice {
  purchaseToken: string;
  subscriptionId: string | null;
  notificationType: number | null;
}

/**
 * Pub/Sub push の本文から購読通知を取り出す。
 * 中身は信用せず、purchaseToken を再問い合わせのキーとしてのみ使う。
 */
export function parseRtdnMessage(body: any): GoogleRtdnNotice | null {
  const b64 = body?.message?.data;
  if (typeof b64 !== "string") return null;
  let payload: any;
  try {
    payload = JSON.parse(Buffer.from(b64, "base64").toString("utf8"));
  } catch {
    return null;
  }
  const n = payload?.subscriptionNotification;
  if (!n?.purchaseToken) return null;
  return {
    purchaseToken: n.purchaseToken,
    subscriptionId: n.subscriptionId ?? null,
    notificationType: typeof n.notificationType === "number" ? n.notificationType : null,
  };
}
