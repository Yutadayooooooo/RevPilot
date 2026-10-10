import { createSupabaseServer, getCurrentUser } from "./supabase/server";
import { connectedStores } from "./credentials";
import { aiUnitsUsed } from "./quota";
import { limitsForPlan, repliesFromUnits } from "./plan";

export interface AppRow {
  id: string;
  store: "appstore" | "googleplay";
  store_app_id: string;
  name: string;
  description: string | null;
  reply_tone: "polite" | "casual" | "apologetic";
  /** 取得の健康状態。連携が壊れていることを利用者自身が気づけるようにする。 */
  last_polled_at: string | null;
  last_error: string | null;
}

export interface NotifyPrefs {
  notify_webhook_url: string | null;
  email: string | null;
  plan: string;
}

/** 今月のAI利用状況（設定画面で残数を見せる）。 */
export interface UsageInfo {
  usedReplies: number;
  limitReplies: number;
}

const SAMPLE_APPS: AppRow[] = [
  { id: "a1", store: "appstore", store_app_id: "1234567890", name: "MyHabit", description: "習慣化トラッカー", reply_tone: "polite", last_polled_at: null, last_error: null },
  { id: "a2", store: "googleplay", store_app_id: "com.example.focus", name: "Focus Timer", description: "集中タイマー", reply_tone: "casual", last_polled_at: null, last_error: null },
];

/** 設定画面の初期表示。未ログインのときだけサンプル。 */
export async function getSettings(): Promise<{
  apps: AppRow[];
  prefs: NotifyPrefs;
  connected: string[];
  usage: UsageInfo | null;
  usingSample: boolean;
  error: string | null;
}> {
  const user = await getCurrentUser();
  const fallback: NotifyPrefs = { notify_webhook_url: null, email: null, plan: "free" };
  if (!user) {
    return {
      apps: SAMPLE_APPS,
      // 未ログインのプレビューに実在のメールアドレスを出さない（以前は開発者本人の
      // 個人アドレスがハードコードされていた）。
      prefs: { ...fallback, email: "you@example.com" },
      connected: ["appstore"], // サンプル表示用
      usage: null,
      usingSample: true,
      error: null,
    };
  }

  try {
    const db = await createSupabaseServer();
    const [{ data: apps }, { data: profile }, connected] = await Promise.all([
      db
        .from("apps")
        .select("id, store, store_app_id, name, description, reply_tone, last_polled_at, last_error")
        .order("created_at"),
      db.from("profiles").select("notify_webhook_url, email, plan").eq("id", user.id).maybeSingle(),
      connectedStores(user.id),
    ]);

    const plan = profile?.plan ?? "free";
    const used = await aiUnitsUsed(user.id);

    return {
      apps: (apps as AppRow[]) ?? [],
      prefs: {
        notify_webhook_url: profile?.notify_webhook_url ?? null,
        email: user.email ?? profile?.email ?? null,
        plan,
      },
      connected,
      usage: {
        usedReplies: repliesFromUnits(used),
        limitReplies: repliesFromUnits(limitsForPlan(plan).aiUnitsPerMonth),
      },
      usingSample: false,
      error: null,
    };
  } catch (e) {
    console.error("[settings-data] failed", e);
    // ログイン済みユーザーにサンプル（架空のアプリ）を見せない。
    return {
      apps: [],
      prefs: { ...fallback, email: user.email ?? null },
      connected: [],
      usage: null,
      usingSample: false,
      error: "設定を読み込めませんでした。時間をおいて再読み込みしてください。",
    };
  }
}
