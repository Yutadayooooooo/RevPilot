import { redirect } from "next/navigation";
import { createSupabaseServer, getCurrentUser } from "@/lib/supabase/server";
import { connectedStores } from "@/lib/credentials";
import { cryptoConfigured } from "@/lib/crypto";
import { OnboardingWizard } from "@/components/onboarding-wizard";

export const dynamic = "force-dynamic";

export default async function OnboardingPage() {
  const user = await getCurrentUser();
  // 未ログイン/未設定ならダッシュボード（サンプル表示）へ
  if (!user) redirect("/");

  const db = createSupabaseServer();
  const [connected, { count: appCount }] = await Promise.all([
    connectedStores(db, user.id),
    db.from("apps").select("id", { count: "exact", head: true }),
  ]);

  return (
    <div className="mx-auto flex min-h-screen max-w-2xl flex-col justify-center p-4">
      <OnboardingWizard
        email={user.email ?? ""}
        initialConnected={connected}
        hasApps={(appCount ?? 0) > 0}
        cryptoEnabled={cryptoConfigured()}
      />
    </div>
  );
}
