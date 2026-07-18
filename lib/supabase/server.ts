import { createServerClient, type CookieOptions } from "@supabase/ssr";
import { cookies } from "next/headers";

type CookieToSet = { name: string; value: string; options: CookieOptions };

/**
 * サーバーコンポーネント / ルートハンドラ用の Supabase クライアント。
 * ログインユーザーのセッション(cookie)に基づき、RLSが自動でデータをスコープする。
 */
export function createSupabaseServer() {
  const cookieStore = cookies();
  return createServerClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
    {
      cookies: {
        getAll() {
          return cookieStore.getAll();
        },
        setAll(list: CookieToSet[]) {
          try {
            list.forEach(({ name, value, options }) => cookieStore.set(name, value, options));
          } catch {
            // Server Component から呼ばれた場合は setAll 不可。middlewareがセッション更新を担うのでOK。
          }
        },
      },
    }
  );
}

/** 環境変数が揃っていて認証が使えるか */
export function authConfigured(): boolean {
  return Boolean(process.env.NEXT_PUBLIC_SUPABASE_URL && process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY);
}

/** 現在のログインユーザー（未ログイン/未設定なら null） */
export async function getCurrentUser() {
  if (!authConfigured()) return null;
  const supabase = createSupabaseServer();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  return user;
}
