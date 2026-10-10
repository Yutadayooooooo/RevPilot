"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { Apple, Play, Check, Loader2, Plane, ArrowRight } from "lucide-react";
import { Card, CardContent } from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import { Input, Label, Select } from "@/components/ui/input";
import { Badge } from "@/components/ui/badge";

type Step = 0 | 1 | 2;

export function OnboardingWizard({
  email,
  initialConnected,
  hasApps,
  cryptoEnabled,
}: {
  email: string;
  initialConnected: string[];
  hasApps: boolean;
  cryptoEnabled: boolean;
}) {
  const router = useRouter();
  const [step, setStep] = useState<Step>(0);
  const [connected, setConnected] = useState<string[]>(initialConnected);
  const [appAdded, setAppAdded] = useState(hasApps);

  function finish() {
    router.push("/dashboard");
    router.refresh();
  }

  return (
    <Card>
      <CardContent className="p-6">
        <div className="mb-6 flex items-center gap-2">
          <Plane className="h-5 w-5 text-primary" />
          <span className="text-lg font-semibold">RevPilot へようこそ</span>
        </div>

        <Steps step={step} />

        {step === 0 && (
          <StoreStep
            connected={connected}
            cryptoEnabled={cryptoEnabled}
            onConnected={(s) => setConnected((c) => (c.includes(s) ? c : [...c, s]))}
            onNext={() => setStep(1)}
          />
        )}
        {step === 1 && (
          <AppStep
            defaultStore={connected[0] === "googleplay" ? "googleplay" : "appstore"}
            onAdded={() => setAppAdded(true)}
            onBack={() => setStep(0)}
            onNext={() => setStep(2)}
            appAdded={appAdded}
          />
        )}
        {step === 2 && <NotifyStep email={email} onBack={() => setStep(1)} onFinish={finish} />}
      </CardContent>
    </Card>
  );
}

function Steps({ step }: { step: Step }) {
  const labels = ["ストア連携", "アプリ追加", "通知設定"];
  return (
    <div className="mb-6 flex items-center gap-2">
      {labels.map((l, i) => (
        <div key={l} className="flex flex-1 items-center gap-2">
          <div
            className={`flex h-6 w-6 shrink-0 items-center justify-center rounded-full text-xs ${
              i <= step ? "bg-primary text-primary-foreground" : "bg-muted text-muted-foreground"
            }`}
          >
            {i < step ? <Check className="h-3.5 w-3.5" /> : i + 1}
          </div>
          <span className={`text-xs ${i === step ? "font-medium" : "text-muted-foreground"}`}>{l}</span>
          {i < labels.length - 1 && <div className="h-px flex-1 bg-border" />}
        </div>
      ))}
    </div>
  );
}

/* -------- Step 1: ストア連携 -------- */
function StoreStep({
  connected,
  cryptoEnabled,
  onConnected,
  onNext,
}: {
  connected: string[];
  cryptoEnabled: boolean;
  onConnected: (store: string) => void;
  onNext: () => void;
}) {
  const [tab, setTab] = useState<"appstore" | "googleplay">("appstore");
  const [asc, setAsc] = useState({ issuerId: "", keyId: "", privateKey: "" });
  const [gp, setGp] = useState({ serviceAccountJson: "" });
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);

  async function save() {
    setBusy(true);
    setErr(null);
    try {
      const body =
        tab === "appstore" ? { store: "appstore", ...asc } : { store: "googleplay", ...gp };
      const res = await fetch("/api/credentials", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(body),
      });
      const json = await res.json();
      if (!res.ok) throw new Error(json.error ?? "保存に失敗しました");
      onConnected(tab);
    } catch (e: any) {
      setErr(e.message);
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="space-y-4">
      <p className="text-sm text-muted-foreground">
        監視したいストアのAPI認証情報を登録します。あなた自身が権限を持つアプリのレビューだけを取得します。認証情報は暗号化して保存されます。
      </p>

      {!cryptoEnabled && (
        <p className="rounded-md bg-amber-50 p-3 text-xs text-amber-700">
          暗号鍵(APP_ENCRYPTION_KEY)が未設定のため保存は無効です。後で環境変数を設定してから登録できます。この手順はスキップ可能です。
        </p>
      )}

      <div className="flex gap-2">
        <Button size="sm" variant={tab === "appstore" ? "default" : "outline"} onClick={() => setTab("appstore")}>
          <Apple className="h-3.5 w-3.5" /> App Store
          {connected.includes("appstore") && <Check className="h-3.5 w-3.5 text-green-500" />}
        </Button>
        <Button size="sm" variant={tab === "googleplay" ? "default" : "outline"} onClick={() => setTab("googleplay")}>
          <Play className="h-3.5 w-3.5" /> Google Play
          {connected.includes("googleplay") && <Check className="h-3.5 w-3.5 text-green-500" />}
        </Button>
      </div>

      {tab === "appstore" ? (
        <div className="space-y-3">
          {/* 鍵の取得は外部サービスでの作業で、ここが最大の詰まりどころ。
              手順とリンクを省略しない。 */}
          <ol className="list-inside list-decimal space-y-1 rounded-md bg-muted/50 p-3 text-xs text-muted-foreground">
            <li>
              <a
                href="https://appstoreconnect.apple.com/access/integrations/api"
                target="_blank"
                rel="noreferrer noopener"
                className="text-primary underline"
              >
                App Store Connect &gt; ユーザーとアクセス &gt; 統合
              </a>
              を開く
            </li>
            <li>「App Store Connect API」タブで鍵を生成（アクセス権は「App Manager」以上）</li>
            <li>生成直後にダウンロードできる <code>.p8</code> ファイルを保存（再ダウンロード不可）</li>
            <li>同じ画面の「Issuer ID」と、鍵一覧の「キーID」を下欄にコピー</li>
          </ol>
          <p className="text-xs text-muted-foreground">
            入力後、その場でAppleへ疎通確認を行います。エラーが出た場合は保存されません。
          </p>
          <div>
            <Label>Issuer ID</Label>
            <Input value={asc.issuerId} onChange={(e) => setAsc({ ...asc, issuerId: e.target.value })} placeholder="57246542-96fe-1a63-..." />
          </div>
          <div>
            <Label>Key ID</Label>
            <Input value={asc.keyId} onChange={(e) => setAsc({ ...asc, keyId: e.target.value })} placeholder="2X9R4HXF34" />
          </div>
          <div>
            <Label>秘密鍵(.p8 の中身)</Label>
            <textarea
              value={asc.privateKey}
              onChange={(e) => setAsc({ ...asc, privateKey: e.target.value })}
              placeholder="-----BEGIN PRIVATE KEY-----&#10;...&#10;-----END PRIVATE KEY-----"
              className="h-28 w-full resize-none rounded-md border p-2 font-mono text-xs focus:outline-none focus:ring-2 focus:ring-primary/30"
            />
          </div>
        </div>
      ) : (
        <div className="space-y-3">
          <ol className="list-inside list-decimal space-y-1 rounded-md bg-muted/50 p-3 text-xs text-muted-foreground">
            <li>
              <a
                href="https://console.cloud.google.com/iam-admin/serviceaccounts"
                target="_blank"
                rel="noreferrer noopener"
                className="text-primary underline"
              >
                Google Cloud
              </a>
              でサービスアカウントを作成し、JSONキーを発行
            </li>
            <li>
              <a
                href="https://play.google.com/console"
                target="_blank"
                rel="noreferrer noopener"
                className="text-primary underline"
              >
                Play Console
              </a>
              &gt; ユーザーと権限 で、そのサービスアカウントのメールアドレスを招待
            </li>
            <li>対象アプリへのアクセスと「レビューの表示・返信」権限を付与</li>
            <li>ダウンロードしたJSONの中身を丸ごと下欄に貼り付け</li>
          </ol>
          <p className="text-xs text-muted-foreground">
            入力後、その場でGoogleへ疎通確認を行います。エラーが出た場合は保存されません。
          </p>
          <div>
            <Label>サービスアカウント JSON</Label>
            <textarea
              value={gp.serviceAccountJson}
              onChange={(e) => setGp({ serviceAccountJson: e.target.value })}
              placeholder='{ "type": "service_account", "project_id": "...", ... }'
              className="h-36 w-full resize-none rounded-md border p-2 font-mono text-xs focus:outline-none focus:ring-2 focus:ring-primary/30"
            />
          </div>
        </div>
      )}

      {err && <p className="text-sm text-red-600">{err}</p>}

      <div className="flex items-center justify-between">
        <Button variant="outline" onClick={save} disabled={busy || !cryptoEnabled}>
          {busy ? <Loader2 className="h-4 w-4 animate-spin" /> : <Check className="h-4 w-4" />} このストアを連携
        </Button>
        <Button onClick={onNext}>
          {connected.length > 0 ? "次へ" : "スキップ"} <ArrowRight className="h-4 w-4" />
        </Button>
      </div>
    </div>
  );
}

/* -------- Step 2: アプリ追加 -------- */
const TONES = [
  { value: "polite", label: "丁寧（敬語）" },
  { value: "casual", label: "カジュアル" },
  { value: "apologetic", label: "謝罪重視" },
];

function AppStep({
  defaultStore,
  appAdded,
  onAdded,
  onBack,
  onNext,
}: {
  defaultStore: "appstore" | "googleplay";
  appAdded: boolean;
  onAdded: () => void;
  onBack: () => void;
  onNext: () => void;
}) {
  const [form, setForm] = useState({
    store: defaultStore,
    store_app_id: "",
    name: "",
    description: "",
    reply_tone: "polite",
  });
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const [done, setDone] = useState(appAdded);

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
      setDone(true);
      onAdded();
    } catch (e: any) {
      setErr(e.message);
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="space-y-4">
      <p className="text-sm text-muted-foreground">監視する最初のアプリを登録します。</p>

      {done ? (
        <div className="flex items-center gap-2 rounded-md border border-green-200 bg-green-50 p-3 text-sm text-green-800">
          <Check className="h-4 w-4" /> アプリを登録しました。
        </div>
      ) : (
        <div className="space-y-3">
          <div className="grid gap-3 sm:grid-cols-2">
            <div>
              <Label>ストア</Label>
              <Select value={form.store} onChange={(e) => setForm({ ...form, store: e.target.value as any })}>
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
          <Button onClick={add} disabled={busy || !form.store_app_id || !form.name}>
            {busy ? <Loader2 className="h-4 w-4 animate-spin" /> : <Check className="h-4 w-4" />} 登録
          </Button>
        </div>
      )}

      <div className="flex items-center justify-between">
        <Button variant="ghost" onClick={onBack}>
          戻る
        </Button>
        <Button onClick={onNext}>
          次へ <ArrowRight className="h-4 w-4" />
        </Button>
      </div>
    </div>
  );
}

/* -------- Step 3: 通知先 -------- */
function NotifyStep({ email, onBack, onFinish }: { email: string; onBack: () => void; onFinish: () => void }) {
  const [webhook, setWebhook] = useState("");
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);

  async function saveAndFinish() {
    setBusy(true);
    setErr(null);
    try {
      const res = await fetch("/api/settings", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ notify_webhook_url: webhook }),
      });
      if (!res.ok) {
        const json = await res.json().catch(() => ({}));
        setErr(json.error ?? "保存に失敗しました");
        return; // 入力を直せるようにここで止める
      }
      onFinish();
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="space-y-4">
      <p className="text-sm text-muted-foreground">
        新しいレビューが届いたらお知らせします。通知メールはログイン中のアドレス（{email}）に届きます。
      </p>
      <div>
        <Label>Slack / Discord の Webhook URL（任意）</Label>
        <Input
          value={webhook}
          onChange={(e) => setWebhook(e.target.value)}
          placeholder="https://hooks.slack.com/services/..."
        />
        <p className="mt-1 text-xs text-muted-foreground">
          Slack は「Incoming Webhooks」、Discord はチャンネル設定の「連携サービス &gt; ウェブフック」で発行できます。あとから設定でも変更できます。
        </p>
      </div>
      {err && <p className="text-sm text-red-600">{err}</p>}
      <div className="flex items-center justify-between">
        <Button variant="ghost" onClick={onBack}>
          戻る
        </Button>
        <Button onClick={saveAndFinish} disabled={busy}>
          {busy ? <Loader2 className="h-4 w-4 animate-spin" /> : <Check className="h-4 w-4" />} 完了してダッシュボードへ
        </Button>
      </div>
    </div>
  );
}
