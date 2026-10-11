import type { PlanDef } from "@/lib/plans";

/**
 * 料金カードの価格の下に出す補足（年額と無料トライアル）。
 * 料金ページ・トップ・設定画面で同じ表記にするため共通化している。
 */
export function PlanExtras({ plan, className = "text-xs text-slate-500" }: { plan: PlanDef; className?: string }) {
  if (!plan.yearlyPrice && !plan.trialDays) return null;
  return (
    <div className={`-mt-1 mb-2 space-y-0.5 ${className}`}>
      {plan.yearlyPrice && (
        <div>
          年額 {plan.yearlyPrice}
          {plan.yearlyDiscountPct ? `（月額より${plan.yearlyDiscountPct}%お得）` : ""}
        </div>
      )}
      {plan.trialDays && <div className="font-semibold text-emerald-600">初回{plan.trialDays}日間無料</div>}
    </div>
  );
}
