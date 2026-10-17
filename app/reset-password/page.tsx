"use client";

import { useEffect, useState } from "react";
import { Plane, Loader2, CheckCircle2 } from "lucide-react";
import {
  isAuthRetryableFetchError,
  isAuthSessionMissingError,
  isAuthWeakPasswordError,
} from "@supabase/supabase-js";
import { Card, CardContent } from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import { Input, Label } from "@/components/ui/input";
import { createSupabaseBrowser } from "@/lib/supabase/browser";

/**
 * パスワード再設定の着地点。
 * メールのリンクから復旧セッションを張り、その状態で updateUser({ password }) を呼ぶ。
 *
 * セッションの張り方は2通り:
 * - ?token_hash=…&type=recovery … verifyOtp で張る。アプリから送った再設定はこちら。
 *   アプリ（supabase_flutter）は PKCE で、code_verifier が端末の中にあるため、
 *   標準のメール（?code=…）だと Web では交換できない。Supabase の
 *   「Reset Password」メールのテンプレートを token_hash 形式にしておく必要がある
 *   （docs/release-setup.md の 2-1）。
 * - ?code=… … 同じブラウザ（Web のログイン画面）から送った場合。Supabase JS が自動で交換する。
 *
 * 変更後は移動しない。本番は Web版を公開しておらず /dashboard が404になるので、
 * 「アプリに戻って新しいパスワードでログイン」と案内して終わる。
 */
type Phase = "checking" | "ready" | "invalid" | "done";

/** 開発時の StrictMode で effect が2回走っても、使い捨てのトークンを2回送らない。 */
const verifying = new Map<string, Promise<boolean>>();

function verifyRecovery(tokenHash: string): Promise<boolean> {
  let p = verifying.get(tokenHash);
  if (!p) {
    p = createSupabaseBrowser()
      .auth.verifyOtp({ token_hash: tokenHash, type: "recovery" })
      .then(({ data, error }) => !error && Boolean(data.session))
      .catch(() => false);
    verifying.set(tokenHash, p);
  }
  return p;
}

/** Supabase のエラーを、画面に出す日本語にする（英語の文面は出さない）。 */
function passwordErrorText(e: unknown): string {
  const code = (e as any)?.code ?? "";
  if (code === "same_password") {
    return "以前と同じパスワードは使えません。別のパスワードを入力してください。";
  }
  if (isAuthWeakPasswordError(e) || code === "weak_password") {
    return "このパスワードは使えません。8文字以上で、推測されにくいものにしてください。";
  }
  if (isAuthSessionMissingError(e) || code === "session_not_found" || code === "session_expired") {
    return "再設定の有効期限が切れました。アプリのログイン画面から、もう一度再設定メールを送信してください。";
  }
  if (isAuthRetryableFetchError(e) || e instanceof TypeError) {
    return "通信に失敗しました。通信環境をご確認のうえ、もう一度お試しください。";
  }
  return "パスワードを変更できませんでした。時間をおいて再度お試しください。";
}

export default function ResetPasswordPage() {
  const [password, setPassword] = useState("");
  const [confirm, setConfirm] = useState("");
  const [phase, setPhase] = useState<Phase>("checking");
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);

  useEffect(() => {
    const supabase = createSupabaseBrowser();
    let alive = true;
    const query = new URLSearchParams(window.location.search);
    const hash = new URLSearchParams(window.location.hash.replace(/^#/, ""));
    // 期限切れ・使用済みのリンクは、Supabase が error / error_code を付けて戻す。
    const linkError =
      query.get("error_code") ?? hash.get("error_code") ?? query.get("error") ?? hash.get("error");
    const tokenHash = query.get("token_hash");

    const { data: sub } = supabase.auth.onAuthStateChange((_e, session) => {
      if (alive && session) setPhase((p) => (p === "done" ? p : "ready"));
    });

    (async () => {
      if (linkError) {
        setPhase("invalid");
        return;
      }
      if (tokenHash && (query.get("type") ?? "recovery") === "recovery") {
        const ok = await verifyRecovery(tokenHash);
        if (!alive) return;
        // 使用済みのトークンを再読み込みで送り直さないよう、URLから消す。
        window.history.replaceState(null, "", window.location.pathname);
        setPhase(ok ? "ready" : "invalid");
        return;
      }
      // ?code=… は Supabase JS が初期化の中で交換するので、セッションの有無だけ見る。
      const { data } = await supabase.auth.getSession();
      if (alive) setPhase((p) => (p === "checking" ? (data.session ? "ready" : "invalid") : p));
    })().catch(() => {
      if (alive) setPhase("invalid");
    });

    return () => {
      alive = false;
      sub.subscription.unsubscribe();
    };
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
      setPhase("done");
      // Web版は本番で使わないので、復旧用のセッションをこのブラウザに残さない
      // （scope: local … アプリのログインには影響しない）。
      supabase.auth.signOut({ scope: "local" }).catch(() => {});
    } catch (e: unknown) {
      setErr(passwordErrorText(e));
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

          {phase === "done" ? (
            <div className="space-y-2" role="status">
              <p className="flex items-center gap-2 text-sm font-semibold text-green-700">
                <CheckCircle2 className="h-4 w-4" aria-hidden />
                パスワードを変更しました
              </p>
              <p className="text-sm leading-6 text-muted-foreground">
                RevPilot アプリに戻り、新しいパスワードでログインしてください。このページは閉じて構いません。
              </p>
            </div>
          ) : phase === "checking" ? (
            <p className="flex items-center gap-2 text-sm text-muted-foreground">
              <Loader2 className="h-4 w-4 animate-spin" aria-hidden />
              リンクを確認しています…
            </p>
          ) : phase === "invalid" ? (
            <p className="text-sm leading-6 text-muted-foreground">
              {"再設定のリンクを確認できませんでした。リンクの有効期限が切れているか、すでに使われた可能性があります。" +
                "RevPilot アプリのログイン画面の「パスワードをお忘れですか？」から、もう一度再設定メールを送信してください。"}
            </p>
          ) : (
            <form onSubmit={submit} className="space-y-3">
              <div>
                <Label htmlFor="new-password">新しいパスワード</Label>
                <Input
                  id="new-password"
                  type="password"
                  required
                  minLength={8}
                  autoComplete="new-password"
                  value={password}
                  onChange={(e) => setPassword(e.target.value)}
                  placeholder="8文字以上"
                />
              </div>
              <div>
                <Label htmlFor="confirm-password">もう一度入力</Label>
                <Input
                  id="confirm-password"
                  type="password"
                  required
                  minLength={8}
                  autoComplete="new-password"
                  value={confirm}
                  onChange={(e) => setConfirm(e.target.value)}
                />
              </div>
              {err && (
                <p className="text-sm text-red-600" role="alert">
                  {err}
                </p>
              )}
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
