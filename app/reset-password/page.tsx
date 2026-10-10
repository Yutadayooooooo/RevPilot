"use client";

import { useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import { Plane, Loader2 } from "lucide-react";
import { Card, CardContent } from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import { Input, Label } from "@/components/ui/input";
import { createSupabaseBrowser } from "@/lib/supabase/browser";

/**
 * パスワード再設定の着地点。
 * メールのリンク（/reset-password）を開くと Supabase が復旧セッションを張るので、
 * その状態で updateUser({ password }) を呼ぶ。
 */
export default function ResetPasswordPage() {
  const router = useRouter();
  const [password, setPassword] = useState("");
  const [confirm, setConfirm] = useState("");
  const [ready, setReady] = useState(false);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const [done, setDone] = useState(false);

  useEffect(() => {
    const supabase = createSupabaseBrowser();
    // リカバリーリンクから来た場合はセッションが張られている
    supabase.auth.getSession().then(({ data }) => setReady(Boolean(data.session)));
    const { data: sub } = supabase.auth.onAuthStateChange((_e, session) => {
      if (session) setReady(true);
    });
    return () => sub.subscription.unsubscribe();
  }, []);

  async function submit(e: React.FormEvent) {
    e.preventDefault();
    setErr(null);
    if (password !== confirm) {
      setErr("パスワードが一致しません。");
      return;
    }
    setBusy(true);
    try {
      const supabase = createSupabaseBrowser();
      const { error } = await supabase.auth.updateUser({ password });
      if (error) throw error;
      setDone(true);
      setTimeout(() => router.push("/dashboard"), 1500);
    } catch (e: any) {
      setErr(e.message ?? "変更に失敗しました");
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="flex min-h-screen items-center justify-center p-4">
      <Card className="w-full max-w-sm">
        <CardContent className="p-6">
          <div className="mb-6 flex items-center gap-2">
            <Plane className="h-5 w-5 text-primary" />
            <span className="text-lg font-semibold">パスワードの再設定</span>
          </div>

          {done ? (
            <p className="text-sm text-green-700">
              パスワードを変更しました。ダッシュボードへ移動します…
            </p>
          ) : !ready ? (
            <p className="text-sm text-muted-foreground">
              メールに記載されたリンクからこのページを開いてください。リンクの有効期限が切れている場合は、
              ログイン画面からもう一度再設定メールを送信してください。
            </p>
          ) : (
            <form onSubmit={submit} className="space-y-3">
              <div>
                <Label>新しいパスワード</Label>
                <Input
                  type="password"
                  required
                  minLength={8}
                  value={password}
                  onChange={(e) => setPassword(e.target.value)}
                  placeholder="8文字以上"
                />
              </div>
              <div>
                <Label>もう一度入力</Label>
                <Input
                  type="password"
                  required
                  minLength={8}
                  value={confirm}
                  onChange={(e) => setConfirm(e.target.value)}
                />
              </div>
              {err && <p className="text-sm text-red-600">{err}</p>}
              <Button type="submit" className="w-full" disabled={busy}>
                {busy && <Loader2 className="h-4 w-4 animate-spin" />} パスワードを変更
              </Button>
            </form>
          )}
        </CardContent>
      </Card>
    </div>
  );
}
