# RevPilot — アプリレビュー監視・AI返信・分析ツール（MVP雛形）

個人開発者向け。自分のアプリ（iOS/Android）のレビューを自動収集し、低評価を即通知、AIが返信ドラフトを生成する。

> このリポジトリは **Claude Code にそのまま渡して育てる前提** のスキャフォールド。
> コア（DBスキーマ / 両ストアAPIクライアント / AI返信 / 定期取得）が入っている。UI(Next.jsページ)は骨組みのみ。

---

## アーキテクチャ

```
[Vercel/Next.js App Router]
   ├─ app/api/cron/poll        … 定期ポーリング（GitHub Actions=毎時 / Vercel Cron=日次の保険）
   ├─ app/api/reviews          … 一覧取得
   ├─ app/api/reply            … AI返信生成 / Android自動返信
   └─ app/(dashboard)          … 画面(骨組み)
        │
   [lib]
     ├─ appstore.ts   … App Store Connect API（JWT生成 + レビュー取得）
     ├─ googleplay.ts … Google Play Developer API（取得 + 返信）
     ├─ ai.ts         … Claude API（返信ドラフト / トピック分類）
     ├─ notify.ts     … メール / Slack・Discord Webhook 通知
     ├─ quota.ts      … AI使用量の予約とレート制限（原価の上限）
     └─ supabase.ts   … DBクライアント
        │
   [Supabase Postgres]  apps / reviews / replies / profiles
```

### 設計上の重要な制約（必読）
- **公式APIで扱えるのは自分が権限を持つアプリのみ**（他人のアプリのレビューは公式に取得不可）。
- **Apple の返信API は 2026年6月時点で不具合あり** → iOSは「AI返信文を生成してユーザーが App Store Connect に貼り付け」運用（自動投稿も試みるが失敗しうる。掲載文でも断定しないこと）。Androidは `reviews.reply` で自動返信可。
- **Google Play の `reviews.list` は直近7日・本文ありのみ** → 毎時ポーリングして自前DBに蓄積することで履歴を作る（これ自体が価値）。ページングは `token` で辿る。
- Apple レート上限：7,200 req/時/アプリ。Google：GET 200/時、返信POST 2,000/日。

---

## セットアップ

### 1. 依存インストール
```bash
npm install
```

### 2. 環境変数（.env.local）
`.env.example` をコピーして埋める。
```bash
cp .env.example .env.local
```

### 3. Supabase
- Supabaseプロジェクトを作成し、`supabase/schema.sql` をSQL Editorで実行。
- `SUPABASE_URL` と `SUPABASE_SERVICE_ROLE_KEY` を .env.local に設定。

### 4. ストア認証情報の取得
- **Apple**: App Store Connect → Users and Access → Integrations → App Store Connect API → キー(.p8)を発行。`Issuer ID`, `Key ID`, `.p8の中身` を控える。
- **Google**: Google Cloud でサービスアカウント作成 → JSONキー発行 → Play Console の「APIアクセス」でそのサービスアカウントに「返信」権限を付与。

### 5. 起動
```bash
npm run dev
```

### 6. 動作確認（ポーリングを手動実行）
```bash
curl -X POST http://localhost:3000/api/cron/poll -H "x-cron-secret: $CRON_SECRET"
```

### 7. 型チェック・配管テスト
```bash
npm run typecheck && npm run test:pipeline
```

---

## 運用（デプロイ時に必要なこと）

### 定期取得のスケジュール — Vercel Cron だけでは足りない

**Vercel の Hobby プランは cron を1日1回しか実行できず**、`vercel.json` に
`"0 * * * *"` のような式を書くと**デプロイ自体が失敗する**
（`Hobby accounts are limited to daily cron jobs`）。

料金表で「自動取得 毎時」と謳っている以上、日次では表示と実装が食い違う。
そのため構成をこう分けてある:

| 経路 | 役割 |
|---|---|
| `vercel.json` の cron（日次） | 保険。Hobby でもデプロイが通る安全な設定 |
| `.github/workflows/poll.yml`（毎時） | 本線。GitHub Actions から `/api/cron/poll` を叩く（無料） |

GitHub のリポジトリシークレットに以下を設定する:
- `REVPILOT_CRON_URL` … `https://<本番ドメイン>/api/cron/poll`
- `REVPILOT_CRON_SECRET` … Vercel の `CRON_SECRET` と同じ値

Vercel Pro（$20/月）に上げる場合は `vercel.json` を `"0 * * * *"` に戻し、
ワークフローを無効化すればよい（どちらも同じエンドポイントを叩くだけ）。

> なお関数の実行時間上限は Hobby / Pro とも 300 秒。取得・一括返信は
> その手前（250秒）で必ず打ち切り、残りを次回に回す作りにしてある。

### 障害に気づくために

`OPERATOR_ALERT_EMAIL`（＋`RESEND_API_KEY`）を設定すると、
cron の失敗・時間予算切れ・全アプリの取得失敗をメールで受け取れる。
未設定だと、cron が壊れ続けても Vercel のログを見に行くまで気づけない。

### 課金の反映

決済は **iOS / Android のアプリ内課金のみ**。Web での外部決済は提供しない
（アプリから外部決済に誘導すると Apple 3.1.1 / Play の課金ポリシー違反になるため）。

| 経路 | 反映の仕組み |
|---|---|
| Apple IAP（iOS） | 購入時 `/api/billing/iap/apple` で App Store Server API に問い合わせて確定。<br>失効は `/api/billing/iap/apple/notifications`（ASSN v2）と cron の期限チェックの二重で反映 |
| Google Play Billing（Android） | 購入時 `/api/billing/iap/google` で `purchases.subscriptionsv2.get` に問い合わせて確定。<br>失効は `/api/billing/iap/google/notifications`（RTDN）と cron の期限チェックの二重で反映。<br>3日以内の acknowledge をサーバー側でも実施（未確認だとGoogleが自動返金する） |

どちらも「クライアントの申告は信用せず、ストアに聞き直す」方式。
サーバー通知も内容は使わず、購入識別子を取り出して再問い合わせするトリガとしてのみ扱う。

`profiles.plan` はクライアントから書き換えられない（RLSは select のみ）。
プランを変えるのは常にサーバー（service_role）側の処理だけ。

### プランの壁

主要な課金の壁は「レビュー履歴の閲覧期間」。Free は直近30日ぶんだけ見える。
**行は削除せず、RLSで見せないだけ**なので、アップグレードした瞬間に全期間が見える。
Google Play の API が直近7日ぶんしか返さない以上、履歴の蓄積が本サービス唯一の
代替不能な価値であり、そこを直接プランの軸にしている。

アプリ数はFreeのみ1件で、有料は無制限。アプリ数は原価にほぼ影響せず
（取得にAI原価はかからない）、制限しても離脱を招くだけだったため。

### AI原価の上限

AI の利用量は `ai_usage` テーブルで units 単位に計測し、
生成の**前に** `consume_ai_units()` で原子的に予約する。予約できなければ生成しない。
返信 = 10 units、トピック分類 = 2 units。プランごとの上限は `lib/plan.ts` の
`PLAN_LIMITS.aiUnitsPerMonth` を参照。

---

## 提供形態

**iOS / Android アプリとして提供する。Web版のダッシュボードは公開しない。**

Web（Next.js）が担うのは次の3つ:
1. モバイルアプリが叩く API（`app/api/**`）
2. 公開ページ … ランディング `/`、料金 `/pricing`、法務3種
3. 定期実行（cron）

ダッシュボード画面（`/dashboard` `/inbox` `/analytics` `/settings` `/onboarding`）は
コードとして残してあるが、`ENABLE_WEB_APP=true` を設定しない限り **404** になる。
開発時のデバッグにだけ使う。

## スコープ
- [x] DBスキーマ / RLS（プラン昇格・使用量・履歴期間の抜け道を塞いだ状態）
- [x] Apple/Google レビュー取得（保存前に資格情報を疎通確認）
- [x] AI返信ドラフト生成（月次の使用量上限つき）
- [x] 定期ポーリング + 新着通知（プッシュ / メール / Slack / Discord）
- [x] Apple IAP（検証・失効反映つき）
- [x] Google Play Billing（検証・acknowledge・RTDN）
- [x] 公開ランディング / 料金ページ / 法務3種
- [x] リモートpush（FCM）— アプリ終了中でも届く。`FIREBASE_*` 未設定なら自動で無効
- [ ] Team プラン（共有・権限）— 未実装のため販売停止中

---

Made as a starting scaffold — iterate freely.
