import { createSupabaseServer, getCurrentUser } from "./supabase/server";

export interface AppRow {
  id: string;
  store: "appstore" | "googleplay";
  store_app_id: string;
  name: string;
  description: string | null;
  reply_tone: "polite" | "casual" | "apologetic";
}

export interface NotifyPrefs {
  line_user_id: string | null;
  email: string | null;
  plan: string;
}

const SAMPLE_APPS: AppRow[] = [
  { id: "a1", store: "appstore", store_app_id: "1234567890", name: "MyHabit", description: "習慣化トラッカー", reply_tone: "polite" },
  { id: "a2", store: "googleplay", store_app_id: "com.example.focus", name: "Focus Timer", description: "集中タイマー", reply_tone: "casual" },
];

/** 設定画面の初期表示。未ログインならサンプル。 */
export async function getSettings(): Promise<{ apps: AppRow[]; prefs: NotifyPrefs; usingSample: boolean }> {
  const user = await getCurrentUser();
  const fallback: NotifyPrefs = { line_user_id: null, email: null, plan: "free" };
  if (!user) return { apps: SAMPLE_APPS, prefs: { ...fallback, email: "businessyuta313@gmail.com" }, usingSample: true };

  try {
    const db = createSupabaseServer();
    const [{ data: apps }, { data: profile }] = await Promise.all([
      db.from("apps").select("id, store, store_app_id, name, description, reply_tone").order("created_at"),
      db.from("profiles").select("line_user_id, email, plan").eq("id", user.id).maybeSingle(),
    ]);
    return {
      apps: (apps as AppRow[]) ?? [],
      prefs: {
        line_user_id: profile?.line_user_id ?? null,
        email: profile?.email ?? user.email ?? null,
        plan: profile?.plan ?? "free",
      },
      usingSample: false,
    };
  } catch {
    return { apps: SAMPLE_APPS, prefs: fallback, usingSample: true };
  }
}
