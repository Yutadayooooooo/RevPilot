"use client";

import { useState } from "react";
import { Loader2, AlertTriangle } from "lucide-react";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";

/**
 * アカウント削除（退会）。
 * モバイル側には既にあったが、Web側には導線が無かった。
 * 課金しているサービスで「Webからは退会できない」のは避ける。
 */
export function DangerZone() {
  const [open, setOpen] = useState(false);
  const [confirm, setConfirm] = useState("");
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);

  async function destroy() {
    setBusy(true);
    setErr(null);
    try {
      const res = await fetch("/api/account", { method: "DELETE" });
      const json = await res.json().catch(() => ({}));
      if (!res.ok) throw new Error(json.error ?? "削除に失敗しました");
      window.location.href = "/login";
    } catch (e: any) {
      setErr(e.message);
      setBusy(false);
    }
  }

  return (
    <Card className="border-red-200">
      <CardHeader>
        <CardTitle className="text-red-700">アカウントの削除</CardTitle>
      </CardHeader>
      <CardContent className="space-y-3">
        <p className="text-sm text-muted-foreground">
          アカウントと、連携アプリ・取得したレビュー・返信・ストア連携情報がすべて削除されます。
          この操作は取り消せません。有効なサブスクリプションがある場合は解約されます。
        </p>
        <p className="flex items-start gap-1.5 text-xs text-muted-foreground">
          <AlertTriangle className="mt-0.5 h-3.5 w-3.5 shrink-0 text-amber-600" />
          App Store のアプリ内課金でご契約中の場合は、Appleのサブスクリプションも
          「設定 &gt; Apple ID &gt; サブスクリプション」から解約してください。
        </p>

        {!open ? (
          <Button variant="outline" onClick={() => setOpen(true)}>
            アカウントを削除する
          </Button>
        ) : (
          <div className="space-y-3 rounded-md border border-red-200 bg-red-50 p-3">
            <p className="text-sm text-red-800">
              続けるには <code className="font-mono font-bold">削除</code> と入力してください。
            </p>
            <Input value={confirm} onChange={(e) => setConfirm(e.target.value)} placeholder="削除" />
            {err && <p className="text-sm text-red-700">{err}</p>}
            <div className="flex gap-2">
              <Button
                variant="outline"
                className="border-red-300 text-red-700 hover:bg-red-100"
                onClick={destroy}
                disabled={busy || confirm !== "削除"}
              >
                {busy && <Loader2 className="h-4 w-4 animate-spin" />} 完全に削除する
              </Button>
              <Button variant="ghost" onClick={() => setOpen(false)} disabled={busy}>
                キャンセル
              </Button>
            </div>
          </div>
        )}
      </CardContent>
    </Card>
  );
}
