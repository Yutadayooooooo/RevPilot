import { NextRequest } from "next/server";
import { createClient, type SupabaseClient, type User } from "@supabase/supabase-js";
import { createSupabaseServer, getCurrentUser } from "./server";

/**
 * Bearerトークン（モバイルアプリ）で認証されたSupabaseクライアントを作る。
 * Authorizationヘッダをそのまま流すことで、以降のクエリはRLS上そのユーザーとして動く。
 */
function createSupabaseFromToken(token: string): SupabaseClient {
  return createClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
    {
      global: { headers: { Authorization: `Bearer ${token}` } },
      auth: { persistSession: false, autoRefreshToken: false },
    }
  );
}

export interface ApiAuth {
  user: User;
  db: SupabaseClient;
}

/**
 * APIルートの認証を解決する。
 * - Authorization: Bearer <jwt> があればモバイル扱いでトークン認証
 * - なければWebのcookieセッションで認証
 * 認証できなければ null。
 */
export async function resolveApiAuth(req: NextRequest): Promise<ApiAuth | null> {
  const authz = req.headers.get("authorization") ?? "";
  if (authz.startsWith("Bearer ")) {
    const token = authz.slice(7).trim();
    if (!token) return null;
    const db = createSupabaseFromToken(token);
    const {
      data: { user },
    } = await db.auth.getUser(token);
    if (!user) return null;
    return { user, db };
  }

  // Webのcookieセッション
  const user = await getCurrentUser();
  if (!user) return null;
  return { user, db: createSupabaseServer() };
}
