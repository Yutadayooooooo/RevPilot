"use client";

import { useState } from "react";
import Link from "next/link";
import { Apple, Play, Trash2, Plus, Check, Loader2, Plug, ArrowRight, AlertTriangle } from "lucide-react";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import { Input, Label, Select } from "@/components/ui/input";
import { Badge } from "@/components/ui/badge";
import type { AppRow, NotifyPrefs, UsageInfo } from "@/lib/settings-data";
import { PUBLIC_PLANS } from "@/lib/plans";
import { PlanExtras } from "@/components/plan-extras";

const TONES = [
  { value: "polite", label: "丁寧（敬語）" },
  { value: "casual", label: "カジュアル" },
  { value: "apologetic", label: "謝罪重視" },
];

export function SettingsForm({
  initialApps,
  initialPrefs,
  connected,
  billingEnabled,
  usage,
}: {
  initialApps: AppRow[];
  initialPrefs: NotifyPrefs;
  connected: string[];
  billingEnabled: boolean;
  usage: UsageInfo | null;
}) {
  const [apps, setApps] = useState<AppRow[]>(initialApps);
  const [prefs, setPrefs] = useState<NotifyPrefs>(initialPrefs);

  return (
    <div className="space-y-6">
      <StoreConnections connected={connected} />
      <ConnectedApps apps={apps} setApps={setApps} />
      <Notifications prefs={prefs} setPrefs={setPrefs} />
      <PlanCard plan={prefs.plan} billingEnabled={billingEnabled} usage={usage} />
    </div>
  );
}

/* ---------------- 連携ストアの状態 ---------------- */
const STORES = [
  { key: "appstore", label: "App Store (iOS)", Icon: Apple },
  { key: "googleplay", label: "Google Play (Android)", Icon: Play },
] as const;

function StoreConnections({ connected }: { connected: string[] }) {
  const allConnected = STORES.every((s) => connected.includes(s.key));
  return (
    <Card>
      <CardHeader className="flex flex-row items-center justify-between">
        <CardTitle>連携ストア</CardTitle>
        <Link href="/onboarding">
          <Button size="sm" variant="outline">
            <Plug className="h-3.5 w-3.5" />
            {allConnected ? "連携を管理" : "ストアを連携"}
            <ArrowRight className="h-3.5 w-3.5" />
          </Button>
        </Link>
      </CardHeader>
      <CardContent className="space-y-2">
        {STORES.map(({ key, label, Icon }) => {
          const on = connected.includes(key);
          return (
            <div key={key} className="flex items-center justify-between rounded-md border p-3">
              <div className="flex items-center gap-3">
                <Icon className="h-4 w-4" />
                <span className="text-sm">{label}</span>
              </div>
              {on ? (
                <Badge tone="success">
                  <Check className="h-3 w-3" /> 連携済み
                </Badge>
              ) : (
                <Badge tone="muted">未連携</Badge>
              )}
            </div>
          );
        })}
        <p className="text-xs text-muted-foreground">
          API認証情報を登録したストアが「連携済み」になります。認証情報は暗号化して保存されます。
        </p>
      </CardContent>
    </Card>
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
          <div
            key={a.id}
            className={`rounded-md border p-3 ${a.last_error ? "border-amber-300 bg-amber-50" : ""}`}
          >
            <div className="flex items-center justify-between">
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
            {/* 取得の健康状態。連携が壊れていることに気づけないのが最大の離脱要因だった。 */}
            <div className="mt-2 flex items-start gap-1.5 text-xs">
              {a.last_error ? (
                <>
                  <AlertTriangle className="mt-0.5 h-3.5 w-3.5 shrink-0 text-amber-600" />
                  <span className="text-amber-800">取得エラー: {a.last_error}</span>
                </>
              ) : (
                <span className="text-muted-foreground">
                  最終取得: {a.last_polled_at ? formatWhen(a.last_polled_at) : "まだ取得していません"}
                </span>
              )}
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
/**
 * 通知先の設定。
 *
 * LINE通知は廃止した。運営のBotから push する仕組みだったが、
 * 利用者が自分の LINE userId を知る手段が無く（webhookでしか取得できない）、
 * 運営の公式アカウントを友だち追加する導線も無かったため、
 * 実際には誰も使えない入力欄になっていた。
 * 代わりに Slack / Discord の Incoming Webhook（URLを貼るだけ）に置き換える。
 *
 * 通知メールの宛先はログイン中のアドレス固定。以前は任意のアドレスを保存でき、
 * 他人のアドレスを入れると運営のドメインからその人にメールが飛ぶ状態だった。
 */
function Notifications({ prefs, setPrefs }: { prefs: NotifyPrefs; setPrefs: (p: NotifyPrefs) => void }) {
  const [busy, setBusy] = useState(false);
  const [saved, setSaved] = useState(false);
  const [err, setErr] = useState<string | null>(null);

  async function save() {
    setBusy(true);
    setSaved(false);
    setErr(null);
    try {
      const res = await fetch("/api/settings", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ notify_webhook_url: prefs.notify_webhook_url ?? "" }),
      });
      const json = await res.json();
      if (!res.ok) throw new Error(json.error ?? "保存に失敗しました");
      setSaved(true);
      setTimeout(() => setSaved(false), 2000);
    } catch (e: any) {
      setErr(e.message);
    } finally {
      setBusy(false);
    }
  }

  return (
    <Card>
      <CardHeader>
        <CardTitle>新着レビューの通知先</CardTitle>
      </CardHeader>
      <CardContent className="space-y-4">
        <div>
          <Label>通知メール</Label>
          <Input type="email" value={prefs.email ?? ""} readOnly disabled />
          <p className="mt-1 text-xs text-muted-foreground">
            ログイン中のメールアドレスに送信します。変更するにはアカウントのメールアドレスを変更してください。
          </p>
        </div>
        <div>
          <Label>Slack / Discord の Webhook URL（任意）</Label>
          <Input
            value={prefs.notify_webhook_url ?? ""}
            onChange={(e) => setPrefs({ ...prefs, notify_webhook_url: e.target.value })}
            placeholder="https://hooks.slack.com/services/..."
          />
          <p className="mt-1 text-xs text-muted-foreground">
            Slack は「Incoming Webhooks」、Discord はチャンネル設定の「連携サービス &gt; ウェブフック」で発行できます。
          </p>
        </div>
        {err && <p className="text-sm text-red-600">{err}</p>}
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
/**
 * プラン表示は lib/plans.ts の PUBLIC_PLANS だけを出典にする。
 *
 * 【購入導線は置かない】
 * RevPilot の決済は iOS / Android のアプリ内課金のみ。
 * Web からの Stripe 決済は提供しないため、ここでは現在のプランと
 * 今月の利用状況を表示するだけにする（Web版のダッシュボードは
 * そもそも本番では無効。middleware.ts の ENABLE_WEB_APP を参照）。
 */
function PlanCard({
  plan,
  billingEnabled: _billingEnabled,
  usage,
}: {
  plan: string;
  billingEnabled: boolean;
  usage: UsageInfo | null;
}) {
  return (
    <Card>
      <CardHeader>
        <CardTitle>課金プラン</CardTitle>
      </CardHeader>
      <CardContent className="space-y-3">
        {usage && (
          <div className="rounded-md border bg-muted/40 p-3">
            <div className="flex justify-between text-sm">
              <span>今月のAI利用</span>
              <span className="font-medium">
                AI返信 {usage.usedReplies} / {usage.limitReplies} 件ぶん
              </span>
            </div>
            <div className="mt-2 h-2 w-full rounded-full bg-muted">
              <div
                className="h-2 rounded-full bg-primary"
                style={{
                  width: `${Math.min(100, usage.limitReplies ? (usage.usedReplies / usage.limitReplies) * 100 : 0)}%`,
                }}
              />
            </div>
            <p className="mt-1.5 text-xs text-muted-foreground">
              トピック分析も同じ枠から消費します（分析1件＝返信0.2件ぶん）。毎月1日にリセットされます。
            </p>
          </div>
        )}

        <div className="grid gap-3 sm:grid-cols-3">
          {PUBLIC_PLANS.map((p) => {
            const current = p.key === plan;
            return (
              <div
                key={p.key}
                className={`rounded-lg border p-4 ${current ? "border-primary ring-1 ring-primary" : ""}`}
              >
                <div className="flex items-center justify-between">
                  <span className="font-medium">{p.name}</span>
                  {current ? <Badge>現在</Badge> : p.popular ? <Badge tone="muted">おすすめ</Badge> : null}
                </div>
                <div className="my-2 text-lg font-semibold">{p.price}</div>
                <PlanExtras plan={p} className="text-xs text-muted-foreground" />
                <p className="mb-2 text-xs text-muted-foreground">{p.tagline}</p>
                <ul className="space-y-1 text-xs text-muted-foreground">
                  {p.features.map((f) => (
                    <li key={f} className="flex items-start gap-1">
                      <Check className="mt-0.5 h-3 w-3 shrink-0 text-primary" /> {f}
                    </li>
                  ))}
                </ul>
              </div>
            );
          })}
        </div>

        <p className="text-xs text-muted-foreground">
          プランの変更・解約は iOS / Android アプリの「設定 &gt; プラン」から行えます。
          サブスクは解約しない限り、選んだ周期（月額・年額）ごとに自動更新されます。詳細は
          <Link href="/terms" className="underline">利用規約</Link>と
          <Link href="/tokushoho" className="underline">特定商取引法に基づく表記</Link>
          をご確認ください。
        </p>
      </CardContent>
    </Card>
  );
}

/** 「3分前」「2時間前」のような相対表記。取得が生きているかを一目で分かるようにする。 */
function formatWhen(iso: string): string {
  const diff = Date.now() - new Date(iso).getTime();
  const min = Math.floor(diff / 60_000);
  if (min < 1) return "たった今";
  if (min < 60) return `${min}分前`;
  const hour = Math.floor(min / 60);
  if (hour < 24) return `${hour}時間前`;
  return `${Math.floor(hour / 24)}日前`;
}
