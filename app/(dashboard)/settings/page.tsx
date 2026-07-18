import { Badge } from "@/components/ui/badge";
import { SettingsForm } from "@/components/settings-form";
import { getSettings } from "@/lib/settings-data";

export const dynamic = "force-dynamic";

export default async function SettingsPage() {
  const { apps, prefs, usingSample } = await getSettings();
  return (
    <div className="mx-auto max-w-3xl space-y-6">
      <div className="flex items-center justify-between">
        <h1 className="text-2xl font-semibold">設定</h1>
        {usingSample && <Badge tone="muted">サンプルデータ表示中</Badge>}
      </div>
      <SettingsForm initialApps={apps} initialPrefs={prefs} />
    </div>
  );
}
