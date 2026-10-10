import { Badge } from "@/components/ui/badge";
import { SettingsForm } from "@/components/settings-form";
import { getSettings } from "@/lib/settings-data";
import { billingConfigured } from "@/lib/stripe";
import { DangerZone } from "@/components/danger-zone";

export const dynamic = "force-dynamic";

export default async function SettingsPage({
  searchParams,
}: {
  // Next.js 15 から searchParams は Promise。
  searchParams: Promise<{ billing?: string }>;
}) {
  const { apps, prefs, connected, usage, usingSample, error } = await getSettings();
  const { billing } = await searchParams;

  return (
    <div className="mx-auto max-w-3xl space-y-6">
      <div className="flex items-center justify-between">
        <h1 className="text-2xl font-semibold">設定</h1>
        {usingSample && <Badge tone="muted">サンプルデータ表示中</Badge>}
      </div>

      {error && (
        <div className="rounded-md border border-red-200 bg-red-50 p-3 text-sm text-red-800">{error}</div>
      )}

      {billing === "success" && (
        <div className="rounded-md border border-green-200 bg-green-50 p-3 text-sm text-green-800">
          ご購入ありがとうございます。プランの反映には数秒かかる場合があります。
        </div>
      )}
      {billing === "cancel" && (
        <div className="rounded-md border p-3 text-sm text-muted-foreground">
          決済はキャンセルされました。プランは変更されていません。
        </div>
      )}

      <SettingsForm
        initialApps={apps}
        initialPrefs={prefs}
        connected={connected}
        billingEnabled={billingConfigured()}
        usage={usage}
      />

      {!usingSample && <DangerZone />}
    </div>
  );
}
