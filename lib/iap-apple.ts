import type { PlanKey } from "@/lib/stripe";

/**
 * App内課金（Apple）まわりのサーバー処理。
 *
 * 現状の到達点:
 * - StoreKit のローカルテストで「購入シートが出て購入が成立する」ところまでは無料で確認できる。
 * - ただし “購入が本物か” を確定させる正式な検証（App Store Server API）は
 *   Apple Developer 登録（有料）後に発行される鍵が要る。登録前は検証できない。
 *
 * そこで:
 * - 本番/検証鍵が揃っていれば verifyAppleTransaction() で厳密に確認する（登録後に実装を差し込む）。
 * - 開発時のみ、明示的に IAP_DEV_TRUST_CLIENT=true を設定した場合に限り、
 *   クライアントが申告した productId をそのまま信用してプランを反映する（ローカル一気通貫テスト用）。
 *   本番ビルドでは NODE_ENV=production により無効化され、絶対に有効化されない。
 */

/** ストア商品ID → プラン。iap.dart / RevPilot.storekit と一致させる。 */
const APPLE_PRODUCT_TO_PLAN: Record<string, PlanKey> = {
  "com.yutatomatsu.revpilot.pro.monthly": "pro",
  "com.yutatomatsu.revpilot.max.monthly": "max",
  "com.yutatomatsu.revpilot.team.monthly": "team",
};

/** 商品ID → プラン（不明なら null）。 */
export function planForAppleProduct(productId: string | null | undefined): PlanKey | null {
  if (!productId) return null;
  return APPLE_PRODUCT_TO_PLAN[productId] ?? null;
}

/** App Store Server API での検証に必要な鍵が揃っているか（登録後に設定）。 */
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
  transactionId?: string | null;
}

/**
 * Apple のトランザクションを検証してプランを返す。
 * - 鍵が揃っていれば App Store Server API で JWS を検証（※登録後に実装）。
 * - 揃っていなければ、dev-trust が有効なときだけクライアント申告を信用。
 * - どちらも不可なら例外（呼び出し側が 501 を返す）。
 */
export async function verifyAppleTransaction(
  input: AppleVerifyInput
): Promise<AppleVerifyResult> {
  const plan = planForAppleProduct(input.productId);
  if (!plan) {
    throw new IapError(`未知の商品IDです: ${input.productId}`, 400);
  }

  if (appleIapConfigured()) {
    // TODO(Apple Developer 登録後):
    //   input.verificationData（JWS）を App Store Server API / JWSで検証し、
    //   bundleId・product・購入者・有効期限を確認してから plan を確定する。
    //   参考: GET /inApps/v1/transactions/{transactionId} や署名済みJWSの検証。
    throw new IapError(
      "Apple購入の本番検証は未実装です（Apple Developer 登録後に有効化）。",
      501
    );
  }

  if (appleIapDevTrustEnabled()) {
    return { plan, method: "dev-trust", transactionId: input.transactionId ?? null };
  }

  throw new IapError(
    "IAP検証は未設定です（APPLE_IAP_* の設定、または開発時は IAP_DEV_TRUST_CLIENT=true が必要）。",
    501
  );
}

/** HTTPステータス付きのIAPエラー。route側でそのまま応答に使う。 */
export class IapError extends Error {
  readonly status: number;
  constructor(message: string, status = 400) {
    super(message);
    this.status = status;
  }
}
