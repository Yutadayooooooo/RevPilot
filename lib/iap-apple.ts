import jwt from "jsonwebtoken";
import type { PlanKey } from "@/lib/plans";

/**
 * App内課金（Apple）まわりのサーバー処理。
 *
 * 【検証の方針】
 * クライアントから受け取った JWS を自前で検証（x5c 証明書チェーンの検証）するのではなく、
 * transactionId / originalTransactionId をキーに **App Store Server API へ問い合わせて**
 * Appleが返す内容を正とする。
 *   - 認証済みTLS + APIキー越しにAppleから直接得た値なので、署名検証を自前でやる必要がない
 *   - サーバー通知(ASSN v2)も「再問い合わせのトリガ」としてのみ使うので、
 *     偽の通知を投げられても実害が出ない（Appleに聞き直すだけ）
 *
 * 鍵（APPLE_IAP_*）が未設定の環境では 501 で穏やかに縮退する。
 */

/** ストア商品ID → プラン。iap.dart / RevPilot.storekit と一致させる。 */
const APPLE_PRODUCT_TO_PLAN: Record<string, PlanKey> = {
  "jp.revpilot.app.pro.monthly": "pro",
  "jp.revpilot.app.max.monthly": "max",
};

const PROD_BASE = "https://api.storekit.itunes.apple.com";
const SANDBOX_BASE = "https://api.storekit-sandbox.itunes.apple.com";

/** 商品ID → プラン（不明なら null）。 */
export function planForAppleProduct(productId: string | null | undefined): PlanKey | null {
  if (!productId) return null;
  return APPLE_PRODUCT_TO_PLAN[productId] ?? null;
}

/** App Store Server API での検証に必要な鍵が揃っているか。 */
export function appleIapConfigured(): boolean {
  return Boolean(
    process.env.APPLE_IAP_ISSUER_ID &&
      process.env.APPLE_IAP_KEY_ID &&
      process.env.APPLE_IAP_PRIVATE_KEY &&
      process.env.APPLE_IAP_BUNDLE_ID
  );
}

/** 開発時だけクライアント申告を信用する経路が有効か（本番では常に無効）。 */
export function appleIapDevTrustEnabled(): boolean {
  return process.env.NODE_ENV !== "production" && process.env.IAP_DEV_TRUST_CLIENT === "true";
}

/** HTTPステータス付きのIAPエラー。route側でそのまま応答に使う。 */
export class IapError extends Error {
  readonly status: number;
  constructor(message: string, status = 400) {
    super(message);
    this.status = status;
  }
}

/** App Store Server API 用の短命JWT。 */
function makeAppleApiToken(): string {
  const issuerId = process.env.APPLE_IAP_ISSUER_ID!;
  const keyId = process.env.APPLE_IAP_KEY_ID!;
  const bundleId = process.env.APPLE_IAP_BUNDLE_ID!;
  const privateKey = (process.env.APPLE_IAP_PRIVATE_KEY ?? "").replace(/\\n/g, "\n");
  const now = Math.floor(Date.now() / 1000);
  return jwt.sign(
    { iss: issuerId, iat: now, exp: now + 60 * 30, aud: "appstoreconnect-v1", bid: bundleId },
    privateKey,
    { algorithm: "ES256", header: { alg: "ES256", kid: keyId, typ: "JWT" } }
  );
}

/**
 * 本番→サンドボックスの順に問い合わせる（Apple推奨）。
 * 審査中のビルドはサンドボックスのトランザクションを送ってくるため、両方見る必要がある。
 */
async function appleApiGet(path: string): Promise<any> {
  const token = makeAppleApiToken();
  let sawUnauthorized = false;
  for (const base of [PROD_BASE, SANDBOX_BASE]) {
    const res = await fetch(`${base}${path}`, {
      headers: { Authorization: `Bearer ${token}` },
      signal: AbortSignal.timeout(10_000),
    });
    if (res.status === 404) continue; // 本番に無ければサンドボックスを見る
    // 401は「鍵が悪い」とは限らない。まだ本番に公開していないアプリは、
    // 正しい鍵で署名しても本番エンドポイントが401を返す（2026-09-07に実測）。
    // ここで即エラーにすると、審査・TestFlightのサンドボックス購入が
    // サンドボックスに問い合わせる前に必ず500で落ちる。
    if (res.status === 401) {
      sawUnauthorized = true;
      continue;
    }
    if (!res.ok) throw new IapError(`Appleへの問い合わせに失敗しました（${res.status}）。`, 502);
    return res.json();
  }
  // 両方の環境が401なら、鍵そのものが疑わしい。
  if (sawUnauthorized) {
    throw new IapError("Appleの認証に失敗しました（APPLE_IAP_* を確認）。", 500);
  }
  throw new IapError("該当する購入がAppleで見つかりませんでした。", 404);
}

/**
 * JWSのペイロード部をデコードする（署名検証はしない）。
 * この関数に渡すのはAppleのAPIから認証済みTLSで受け取った値か、
 * 「再問い合わせのキーを取り出すだけ」の用途に限ること。
 */
export function decodeJwsPayload<T = any>(jws: string): T | null {
  try {
    const part = jws.split(".")[1];
    if (!part) return null;
    return JSON.parse(Buffer.from(part, "base64url").toString("utf8")) as T;
  } catch {
    return null;
  }
}

export interface AppleTransaction {
  bundleId?: string;
  productId?: string;
  originalTransactionId?: string;
  transactionId?: string;
  expiresDate?: number; // ms epoch
  revocationDate?: number;
  type?: string;
}

export interface AppleVerifyInput {
  productId: string;
  /** in_app_purchase の serverVerificationData（JWS 署名付きトランザクション）。 */
  verificationData?: string | null;
  transactionId?: string | null;
}

export interface AppleVerifyResult {
  plan: PlanKey;
  /** 検証手段。dev-trust は未検証（開発専用）である印。 */
  method: "app-store-server-api" | "dev-trust";
  transactionId: string | null;
  originalTransactionId: string | null;
  expiresAt: Date | null;
}

/** Appleが返したトランザクションを検証してプランを決める。 */
function assertUsable(tx: AppleTransaction): PlanKey {
  const expectedBundle = process.env.APPLE_IAP_BUNDLE_ID;
  if (expectedBundle && tx.bundleId && tx.bundleId !== expectedBundle) {
    throw new IapError("別アプリの購入です。", 400);
  }
  if (tx.revocationDate) {
    throw new IapError("この購入は返金・取消されています。", 403);
  }
  if (tx.expiresDate && tx.expiresDate <= Date.now()) {
    throw new IapError("サブスクリプションの有効期限が切れています。", 403);
  }
  const plan = planForAppleProduct(tx.productId);
  if (!plan) throw new IapError(`未知の商品IDです: ${tx.productId}`, 400);
  return plan;
}

/**
 * Apple のトランザクションを検証してプランを返す。
 * - 鍵が揃っていれば App Store Server API に問い合わせて確定する。
 * - 揃っていなければ、dev-trust が有効なときだけクライアント申告を信用（開発専用）。
 */
export async function verifyAppleTransaction(
  input: AppleVerifyInput
): Promise<AppleVerifyResult> {
  if (appleIapConfigured()) {
    // クライアントの申告ではなく、JWSから取り出したIDでAppleに問い合わせる。
    const claimed = input.verificationData ? decodeJwsPayload<AppleTransaction>(input.verificationData) : null;
    const txId = claimed?.transactionId ?? input.transactionId;
    if (!txId) {
      throw new IapError("購入情報が不足しています（transactionId）。", 400);
    }

    const json = await appleApiGet(`/inApps/v1/transactions/${encodeURIComponent(txId)}`);
    const tx = decodeJwsPayload<AppleTransaction>(json?.signedTransactionInfo ?? "");
    if (!tx) throw new IapError("Appleの応答を解釈できませんでした。", 502);

    const plan = assertUsable(tx);
    return {
      plan,
      method: "app-store-server-api",
      transactionId: tx.transactionId ?? txId,
      originalTransactionId: tx.originalTransactionId ?? null,
      expiresAt: tx.expiresDate ? new Date(tx.expiresDate) : null,
    };
  }

  if (appleIapDevTrustEnabled()) {
    const plan = planForAppleProduct(input.productId);
    if (!plan) throw new IapError(`未知の商品IDです: ${input.productId}`, 400);
    return {
      plan,
      method: "dev-trust",
      transactionId: input.transactionId ?? null,
      originalTransactionId: null,
      // 開発用途では30日後を仮の期限にしておく（本番では必ずAppleの値を使う）
      expiresAt: new Date(Date.now() + 30 * 86_400_000),
    };
  }

  throw new IapError(
    "IAP検証は未設定です（APPLE_IAP_* の設定、または開発時は IAP_DEV_TRUST_CLIENT=true が必要）。",
    501
  );
}

export interface AppleSubscriptionState {
  active: boolean;
  plan: PlanKey | null;
  expiresAt: Date | null;
  productId: string | null;
}

/**
 * originalTransactionId から現在のサブスク状態を取得する。
 * サーバー通知(ASSN v2)を受けたときと、期限切れの定期チェックで使う。
 *
 * 通知の中身は信用せず、必ずここでAppleに聞き直す。
 */
export async function getAppleSubscriptionState(
  originalTransactionId: string
): Promise<AppleSubscriptionState> {
  const json = await appleApiGet(
    `/inApps/v1/subscriptions/${encodeURIComponent(originalTransactionId)}`
  );

  // data[].lastTransactions[] のうち、最も期限が新しいものを採用する。
  let best: { tx: AppleTransaction; status: number } | null = null;
  for (const group of json?.data ?? []) {
    for (const item of group?.lastTransactions ?? []) {
      const tx = decodeJwsPayload<AppleTransaction>(item?.signedTransactionInfo ?? "");
      if (!tx) continue;
      if (!best || (tx.expiresDate ?? 0) > (best.tx.expiresDate ?? 0)) {
        best = { tx, status: Number(item?.status ?? 0) };
      }
    }
  }
  if (!best) return { active: false, plan: null, expiresAt: null, productId: null };

  // status: 1=Active, 2=Expired, 3=Billing Retry, 4=Grace Period, 5=Revoked
  const active = best.status === 1 || best.status === 4;
  return {
    active: active && !best.tx.revocationDate,
    plan: planForAppleProduct(best.tx.productId),
    expiresAt: best.tx.expiresDate ? new Date(best.tx.expiresDate) : null,
    productId: best.tx.productId ?? null,
  };
}
