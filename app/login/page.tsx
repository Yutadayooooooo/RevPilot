"use client";

import { useState } from "react";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { Plane, Loader2 } from "lucide-react";
import { Card, CardContent } from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import { Input, Label } from "@/components/ui/input";
import { createSupabaseBrowser } from "@/lib/supabase/browser";

type Mode = "signin" | "signup" | "reset";

export default function LoginPage() {
  const router = useRouter();
  const [mode, setMode] = useState<Mode>("signin");
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);

  const configured =
    Boolean(process.env.NEXT_PUBLIC_SUPABASE_URL) &&
    Boolean(process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY);

  async function submit(e: React.FormEvent) {
    e.preventDefault();
    setBusy(true);
    setMsg(null);
    setErr(null);
    try {
      const supabase = createSupabaseBrowser();
      if (mode === "signup") {
        const { error } = await supabase.auth.signUp({ email, password });
        if (error) throw error;
        setMsg("確認メールを送信しました。メール内のリンクを開いてください。");
      } else if (mode === "reset") {
        // パスワード再設定。これが無いと、忘れた利用者は自力で復帰できず
        // 運営が手作業で対応するしかなくなる。
        const { error } = await supabase.auth.resetPasswordForEmail(email, {
          redirectTo: `${window.location.origin}/reset-password`,
        });
        if (error) throw error;
        setMsg("パスワード再設定用のメールを送信しました。受信箱をご確認ください。");
      } else {
        const { error } = await supabase.auth.signInWithPassword({ email, password });
        if (error) throw error;
        router.push("/dashboard");
        router.refresh();
      }
    } catch (e: any) {
      setErr(e.message ?? "エラーが発生しました");
    } finally {
      setBusy(false);
    }
  }

  const title = mode === "signin" ? "ログイン" : mode === "signup" ? "新規登録" : "再設定メールを送る";

  return (
    <div className="flex min-h-screen items-center justify-center p-4">
      <Card className="w-full max-w-sm">
        <CardContent className="p-6">
          <div className="mb-1 flex items-center gap-2">
            <Plane className="h-5 w-5 text-primary" />
            <span className="text-lg font-semibold">RevPilot</span>
          </div>
          <p className="mb-6 text-sm text-muted-foreground">
            App Store と Google Play のレビューを1か所で。
          </p>

          {!configured && (
            <p className="mb-4 rounded-md bg-amber-50 p-3 text-xs text-amber-700">
              Supabaseが未設定です。.env.local に NEXT_PUBLIC_SUPABASE_URL / ANON_KEY を設定するとログインが有効になります。
            </p>
          )}

          <form onSubmit={submit} className="space-y-3">
            <div>
              <Label>メールアドレス</Label>
              <Input type="email" required value={email} onChange={(e) => setEmail(e.target.value)} placeholder="you@example.com" />
            </div>
            {mode !== "reset" && (
              <div>
                <Label>パスワード</Label>
                <Input type="password" required minLength={8} value={password} onChange={(e) => setPassword(e.target.value)} placeholder="8文字以上" />
              </div>
            )}
            <Button type="submit" className="w-full" disabled={busy || !configured}>
              {busy && <Loader2 className="h-4 w-4 animate-spin" />}
              {title}
            </Button>
          </form>

          {msg && <p className="mt-3 text-sm text-green-700">{msg}</p>}
          {err && <p className="mt-3 text-sm text-red-600">{err}</p>}

          <div className="mt-4 flex flex-col gap-1.5 text-xs">
            {mode !== "signup" && (
              <button type="button" onClick={() => switchTo("signup")} className="text-left text-primary hover:underline">
                アカウントを作成
              </button>
            )}
            {mode !== "signin" && (
              <button type="button" onClick={() => switchTo("signin")} className="text-left text-primary hover:underline">
                既存アカウントでログイン
              </button>
            )}
            {mode !== "reset" && (
              <button type="button" onClick={() => switchTo("reset")} className="text-left text-muted-foreground hover:underline">
                パスワードをお忘れですか？
              </button>
            )}
          </div>

          {/* 新規登録時に規約とプライバシーポリシーを明示する（ストア審査でも確認される）。 */}
          <p className="mt-5 border-t pt-4 text-[11px] leading-relaxed text-muted-foreground">
            登録・ログインすることで、
            <Link href="/terms" className="underline">利用規約</Link>と
            <Link href="/privacy" className="underline">プライバシーポリシー</Link>
            に同意したものとみなされます。料金は
            <Link href="/pricing" className="underline">料金プラン</Link>
            をご覧ください。
          </p>
        </CardContent>
      </Card>
    </div>
  );

  function switchTo(next: Mode) {
    setMode(next);
    setMsg(null);
    setErr(null);
  }
}
