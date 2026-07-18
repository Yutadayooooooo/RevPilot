"use client";

import { useState } from "react";
import { Apple, Play, Trash2, Plus, Check, Loader2 } from "lucide-react";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import { Input, Label, Select } from "@/components/ui/input";
import { Badge } from "@/components/ui/badge";
import type { AppRow, NotifyPrefs } from "@/lib/settings-data";

const TONES = [
  { value: "polite", label: "丁寧（敬語）" },
  { value: "casual", label: "カジュアル" },
  { value: "apologetic", label: "謝罪重視" },
];

export function SettingsForm({
  initialApps,
  initialPrefs,
}: {
  initialApps: AppRow[];
  initialPrefs: NotifyPrefs;
}) {
  const [apps, setApps] = useState<AppRow[]>(initialApps);
  const [prefs, setPrefs] = useState<NotifyPrefs>(initialPrefs);

  return (
    <div className="space-y-6">
      <ConnectedApps apps={apps} setApps={setApps} />
      <Notifications prefs={prefs} setPrefs={setPrefs} />
      <PlanCard plan={prefs.plan} />
    </div>
  );
}

/* ---------------- 連携アプリ ---------------- */
function ConnectedApps({ apps, setApps }: { apps: AppRow[]; setApps: (a: AppRow[]) => void }) {
  const [adding, setAdding] = useState(false);
  const [form, setForm] = useState({
    store: "appstore",
    store_app_id: "",
    name: "",
    description: "",
    reply_tone: "polite",
  });
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);

  async function add() {
    setBusy(true);
    setErr(null);
    try {
      const res = await fetch("/api/apps", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(form),
      });
      const json = await res.json();
      if (!res.ok) throw new Error(json.error ?? "追加に失敗しました");
      setApps([...apps, json.app]);
      setAdding(false);
      setForm({ store: "appstore", store_app_id: "", name: "", description: "", reply_tone: "polite" });
    } catch (e: any) {
      setErr(e.message);
    } finally {
      setBusy(false);
    }
  }

  async function remove(id: string) {
    setApps(apps.filter((a) => a.id !== id));
    await fetch("/api/apps", {
      method: "DELETE",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ id }),
    });
  }

  return (
    <Card>
      <CardHeader className="flex flex-row items-center justify-between">
        <CardTitle>連携アプリ</CardTitle>
        <Button size="sm" variant="outline" onClick={() => setAdding((v) => !v)}>
          <Plus className="h-3.5 w-3.5" /> アプリを追加
        </Button>
      </CardHeader>
      <CardContent className="space-y-3">
        {apps.length === 0 && <p className="text-sm text-muted-foreground">まだ連携アプリがありません。</p>}
        {apps.map((a) => (
          <div key={a.id} className="flex items-center justify-between rounded-md border p-3">
            <div className="flex items-center gap-3">
              {a.store === "appstore" ? <Apple className="h-4 w-4" /> : <Play className="h-4 w-4" />}
              <div>
                <div className="text-sm font-medium">{a.name}</div>
                <div className="text-xs text-muted-foreground">{a.store_app_id}</div>
              </div>
            </div>
            <div className="flex items-center gap-2">
              <Badge tone="muted">{TONES.find((t) => t.value === a.reply_tone)?.label ?? a.reply_tone}</Badge>
              <Button size="icon" variant="ghost" onClick={() => remove(a.id)} aria-label="削除">
                <Trash2 className="h-4 w-4 text-red-500" />
              </Button>
            </div>
          </div>
        ))}

        {adding && (
          <div className="space-y-3 rounded-md border border-dashed p-4">
            <div className="grid gap-3 sm:grid-cols-2">
              <div>
                <Label>ストア</Label>
                <Select value={form.store} onChange={(e) => setForm({ ...form, store: e.target.value })}>
                  <option value="appstore">App Store (iOS)</option>
                  <option value="googleplay">Google Play (Android)</option>
                </Select>
              </div>
              <div>
                <Label>{form.store === "appstore" ? "App ID（数字）" : "パッケージ名"}</Label>
                <Input
                  value={form.store_app_id}
                  onChange={(e) => setForm({ ...form, store_app_id: e.target.value })}
                  placeholder={form.store === "appstore" ? "1234567890" : "com.example.app"}
                />
              </div>
              <div>
                <Label>アプリ名</Label>
                <Input value={form.name} onChange={(e) => setForm({ ...form, name: e.target.value })} placeholder="MyHabit" />
              </div>
              <div>
                <Label>返信トーン</Label>
                <Select value={form.reply_tone} onChange={(e) => setForm({ ...form, reply_tone: e.target.value })}>
                  {TONES.map((t) => (
                    <option key={t.value} value={t.value}>
                      {t.label}
                    </option>
                  ))}
                </Select>
              </div>
            </div>
            <div>
              <Label>アプリ概要（AI返信の文脈に使用）</Label>
              <Input
                value={form.description}
                onChange={(e) => setForm({ ...form, description: e.target.value })}
                placeholder="習慣化トラッカー。無料＋月額プラン。"
              />
            </div>
            {err && <p className="text-sm text-red-600">{err}</p>}
            <div className="flex gap-2">
              <Button onClick={add} disabled={busy || !form.store_app_id || !form.name}>
                {busy ? <Loader2 className="h-4 w-4 animate-spin" /> : <Check className="h-4 w-4" />} 追加
              </Button>
              <Button variant="ghost" onClick={() => setAdding(false)}>
                キャンセル
              </Button>
            </div>
          </div>
        )}
      </CardContent>
    </Card>
  );
}

/* ---------------- 通知先 ---------------- */
function Notifications({ prefs, setPrefs }: { prefs: NotifyPrefs; setPrefs: (p: NotifyPrefs) => void }) {
  const [busy, setBusy] = useState(false);
  const [saved, setSaved] = useState(false);

  async function save() {
    setBusy(true);
    setSaved(false);
    await fetch("/api/settings", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ line_user_id: prefs.line_user_id, email: prefs.email }),
    });
    setBusy(false);
    setSaved(true);
    setTimeout(() => setSaved(false), 2000);
  }

  return (
    <Card>
      <CardHeader>
        <CardTitle>低評価アラートの通知先</CardTitle>
      </CardHeader>
      <CardContent className="space-y-4">
        <div>
          <Label>通知メール</Label>
          <Input
            type="email"
            value={prefs.email ?? ""}
            onChange={(e) => setPrefs({ ...prefs, email: e.target.value })}
            placeholder="you@example.com"
          />
        </div>
        <div>
          <Label>LINE ユーザーID（Messaging API）</Label>
          <Input
            value={prefs.line_user_id ?? ""}
            onChange={(e) => setPrefs({ ...prefs, line_user_id: e.target.value })}
            placeholder="Uxxxxxxxx..."
          />
        </div>
        <div className="flex items-center gap-3">
          <Button onClick={save} disabled={busy}>
            {busy ? <Loader2 className="h-4 w-4 animate-spin" /> : <Check className="h-4 w-4" />} 保存
          </Button>
          {saved && <span className="text-sm text-green-600">保存しました</span>}
        </div>
      </CardContent>
    </Card>
  );
}

/* ---------------- 課金プラン ---------------- */
function PlanCard({ plan }: { plan: string }) {
  const plans = [
    { key: "free", name: "Free", price: "¥0", features: ["1アプリ", "手動更新", "AI返信 月10件"] },
    { key: "pro", name: "Pro", price: "¥1,480/月", features: ["全アプリ", "自動取得", "AI返信 無制限", "週次サマリー"] },
    { key: "team", name: "Team", price: "¥2,980/月", features: ["複数メンバー", "Slack連携", "競合監視"] },
  ];
  return (
    <Card>
      <CardHeader>
        <CardTitle>課金プラン</CardTitle>
      </CardHeader>
      <CardContent className="grid gap-3 sm:grid-cols-3">
        {plans.map((p) => {
          const current = p.key === plan;
          return (
            <div
              key={p.key}
              className={`rounded-lg border p-4 ${current ? "border-primary ring-1 ring-primary" : ""}`}
            >
              <div className="flex items-center justify-between">
                <span className="font-medium">{p.name}</span>
                {current && <Badge>現在</Badge>}
              </div>
              <div className="my-2 text-lg font-semibold">{p.price}</div>
              <ul className="space-y-1 text-xs text-muted-foreground">
                {p.features.map((f) => (
                  <li key={f} className="flex items-center gap-1">
                    <Check className="h-3 w-3 text-primary" /> {f}
                  </li>
                ))}
              </ul>
              {!current && (
                <Button size="sm" className="mt-3 w-full" variant="outline" disabled>
                  {/* Stripe Checkout を後で接続 */}
                  変更
                </Button>
              )}
            </div>
          );
        })}
      </CardContent>
    </Card>
  );
}
