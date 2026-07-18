import { serviceClient, type NormalizedReview } from "./supabase";
import { fetchAppStoreReviews } from "./appstore";
import { fetchGooglePlayReviews } from "./googleplay";
import { notifyLowRating } from "./notify";

/**
 * 全登録アプリを巡回してレビューを取得・upsertし、新規の低評価を通知する。
 * cron(毎時)から呼ぶ。service_roleでRLSをバイパス。
 */
export async function pollAllApps(): Promise<{ inserted: number; apps: number }> {
  const db = serviceClient();
  const { data: apps, error } = await db
    .from("apps")
    .select("id, owner, store, store_app_id, name, profiles(line_user_id)");
  if (error) throw error;

  let inserted = 0;
  for (const app of apps ?? []) {
    const { data: state } = await db
      .from("poll_state")
      .select("last_seen_external_id")
      .eq("app_id", app.id)
      .maybeSingle();

    let reviews: NormalizedReview[] = [];
    try {
      reviews =
        app.store === "appstore"
          ? await fetchAppStoreReviews(app.store_app_id, state?.last_seen_external_id)
          : await fetchGooglePlayReviews(app.store_app_id);
    } catch (e) {
      console.error(`poll failed app=${app.id}`, e);
      continue; // 1アプリの失敗で全体を止めない
    }
    if (reviews.length === 0) continue;

    const rows = reviews.map((r) => ({ ...r, app_id: app.id }));
    const { data: upserted, error: upErr } = await db
      .from("reviews")
      .upsert(rows, { onConflict: "store,external_id", ignoreDuplicates: true })
      .select("id, rating, body, external_id");
    if (upErr) {
      console.error(upErr);
      continue;
    }

    // 新規に入った★1〜2を通知
    const lineUserId = (app as any).profiles?.line_user_id ?? null;
    for (const row of upserted ?? []) {
      if (row.rating <= 2) {
        await notifyLowRating({
          appName: app.name,
          rating: row.rating,
          body: row.body,
          lineUserId,
        });
      }
    }
    inserted += upserted?.length ?? 0;

    // チェックポイント更新（最新レビューID）
    await db.from("poll_state").upsert({
      app_id: app.id,
      last_seen_external_id: reviews[0].external_id,
      last_polled_at: new Date().toISOString(),
    });
  }

  return { inserted, apps: apps?.length ?? 0 };
}
