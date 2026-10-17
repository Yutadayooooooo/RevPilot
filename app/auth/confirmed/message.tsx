"use client";

import { useEffect, useState } from "react";
import { MailCheck, AlertCircle } from "lucide-react";
import { P } from "../../(legal)/_ui";

/**
 * リンクの期限切れ・使用済みなら、Supabase はこのページに error / error_code を付けて戻す
 * （PKCE は ?error=…、implicit は #error=…）。
 * ページは静的に配信したいので、表示したあとにブラウザ側でURLから読む。
 */
function hasLinkError(): boolean {
  const read = (s: string) => new URLSearchParams(s.replace(/^[?#]/, ""));
  const query = read(window.location.search);
  const hash = read(window.location.hash);
  return Boolean(
    query.get("error_code") ?? hash.get("error_code") ?? query.get("error") ?? hash.get("error")
  );
}

function Note({ children }: { children: React.ReactNode }) {
  return (
    <div className="mt-6 rounded-lg border border-indigo-100 bg-indigo-50 p-4 text-sm leading-6 text-indigo-900">
      {children}
    </div>
  );
}

const b = (s: string) => <strong className="font-semibold text-slate-900">{s}</strong>;

/** 確認の結果。ほとんどは成功なので、成功の案内を既定で出しておく。 */
export function ConfirmedMessage() {
  const [failed, setFailed] = useState(false);

  useEffect(() => {
    try {
      setFailed(hasLinkError());
    } catch {
      // URLを読めなければ成功の案内のままにする。
    }
  }, []);

  if (failed) {
    return (
      <>
        <div className="mb-4 flex items-center gap-2 text-amber-700">
          <AlertCircle className="h-6 w-6" aria-hidden />
          <h1 className="text-2xl font-bold text-slate-900">リンクの有効期限が切れています</h1>
        </div>
        <P>
          {"確認のリンクは一度しか使えず、有効期限もあります。" +
            "すでに確認が済んでいることもあるので、まずは RevPilot アプリでログインをお試しください。"}
        </P>
        <P>
          アプリに「メールアドレスの確認が済んでいません」と表示された場合は、その下の
          {b("「確認メールを再送」")}から新しいリンクを受け取れます。
        </P>
      </>
    );
  }

  return (
    <>
      <div className="mb-4 flex items-center gap-2 text-emerald-700">
        <MailCheck className="h-6 w-6" aria-hidden />
        <h1 className="text-2xl font-bold text-slate-900">メールアドレスを確認しました</h1>
      </div>
      <P>
        これで登録は完了です。RevPilot アプリに戻り、登録したメールアドレスとパスワードで
        {b("「ログイン」")}を押してください。
      </P>
      <Note>
        このページは閉じて構いません。アプリが新規登録の画面になっている場合は、
        {b("「アカウントをお持ちの方はログイン」")}を押すとログインの画面に切り替わります。
      </Note>
    </>
  );
}
