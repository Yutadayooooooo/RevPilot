import { serviceClient } from "./supabase";
import { appleIapConfigured, getAppleSubscriptionState } from "./iap-apple";
import { getGoogleSubscriptionState, googleIapConfigured } from "./iap-google";

/**
 * 期限切れのアプリ内課金サブスクを free に戻す。
 *
 * サーバー通知（Apple: ASSN v2 / Google: RTDN）が本線だが、通知は落ちることがある。
 * 「解約したのに有料のまま」を防ぐ最後の砦として、期限でも必ず確認する。
 * cron（取得の前）から呼ぶ。
 *
 * @returns free に戻した件数
 */
export async function sweepExpiredSubscriptions(): Promise<number> {
  const db = serviceClient();
  const nowIso = new Date().toISOString();

  const { data: expired } = await db
    .from("profiles")
    .select("id, apple_original_transaction_id, google_purchase_token")
    .neq("plan", "free")
    .eq("plan_status", "iap_active")
    .or(`apple_expires_at.lt.${nowIso},google_expires_at.lt.${nowIso}`)
    .limit(200);

  let downgraded = 0;

  for (const p of expired ?? []) {
    try {
      // 更新済みかもしれないので、まずストアに現在の状態を聞き直す。
      const refreshed = await refreshOne(p);
      if (refreshed === "downgraded") downgraded++;
    } catch (e) {
      console.error(`[sweep] failed user=${p.id}`, e);
    }
  }
  return downgraded;
}

type SweepOutcome = "active" | "downgraded";

async function refreshOne(p: {
  id: string;
  apple_original_transaction_id: string | null;
  google_purchase_token: string | null;
}): Promise<SweepOutcome> {
  const db = serviceClient();

  if (appleIapConfigured() && p.apple_original_transaction_id) {
    const state = await getAppleSubscriptionState(p.apple_original_transaction_id);
    await db
      .from("profiles")
      .update({
        plan: state.active && state.plan ? state.plan : "free",
        plan_status: state.active ? "iap_active" : "iap_expired",
        apple_expires_at: state.expiresAt?.toISOString() ?? null,
        current_period_end: state.expiresAt?.toISOString() ?? null,
      })
      .eq("id", p.id);
    return state.active ? "active" : "downgraded";
  }

  if (googleIapConfigured() && p.google_purchase_token) {
    const state = await getGoogleSubscriptionState(p.google_purchase_token);
    await db
      .from("profiles")
      .update({
        plan: state.active && state.plan ? state.plan : "free",
        plan_status: state.active ? "iap_active" : "iap_expired",
        google_expires_at: state.expiresAt?.toISOString() ?? null,
        current_period_end: state.expiresAt?.toISOString() ?? null,
      })
      .eq("id", p.id);
    return state.active ? "active" : "downgraded";
  }

  // 検証設定が無い環境（開発時の dev-trust など）は、期限で素直に落とす。
  await db.from("profiles").update({ plan: "free", plan_status: "iap_expired" }).eq("id", p.id);
  return "downgraded";
}
