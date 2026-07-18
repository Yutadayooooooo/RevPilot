import { createClient } from "@supabase/supabase-js";

/**
 * サーバー専用クライアント（service_role）。RLSをバイパスするのでcron/管理処理で使う。
 * クライアント側では絶対に使わないこと。
 */
export function serviceClient() {
  const url = process.env.SUPABASE_URL;
  const key = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!url || !key) throw new Error("SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY missing");
  return createClient(url, key, { auth: { persistSession: false } });
}

export type StoreType = "appstore" | "googleplay";

export interface NormalizedReview {
  store: StoreType;
  external_id: string;
  rating: number;
  title: string | null;
  body: string | null;
  author: string | null;
  territory: string | null;
  app_version: string | null;
  reviewed_at: string | null; // ISO
  raw: unknown;
}
