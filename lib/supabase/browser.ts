import { createBrowserClient } from "@supabase/ssr";

/** クライアントコンポーネント用の Supabase クライアント（ログインフォーム等）。 */
export function createSupabaseBrowser() {
  return createBrowserClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!
  );
}
