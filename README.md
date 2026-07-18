# RevPilot — アプリレビュー監視・AI返信・分析ツール（MVP雛形）

個人開発者向け。自分のアプリ（iOS/Android）のレビューを自動収集し、低評価を即通知、AIが返信ドラフトを生成する。

> このリポジトリは **Claude Code にそのまま渡して育てる前提** のスキャフォールド。
> コア（DBスキーマ / 両ストアAPIクライアント / AI返信 / 定期取得）が入っている。UI(Next.jsページ)は骨組みのみ。

---

## アーキテクチャ

```
[Vercel/Next.js App Router]
   ├─ app/api/cron/poll        … 1時間毎ポーリング（Vercel Cron）
   ├─ app/api/reviews          … 一覧取得
   ├─ app/api/reply            … AI返信生成 / Android自動返信
   └─ app/(dashboard)          … 画面(骨組み)
        │
   [lib]
     ├─ appstore.ts   … App Store Connect API（JWT生成 + レビュー取得）
     ├─ googleplay.ts … Google Play Developer API（取得 + 返信）
     ├─ ai.ts         … Claude API（返信ドラフト / トピック分類）
     ├─ notify.ts     … LINE / メール通知
     └─ supabase.ts   … DBクライアント
        │
   [Supabase Postgres]  apps / reviews / replies / profiles
```

### 設計上の重要な制約（必読）
- **公式APIで扱えるのは自分が権限を持つアプリのみ**（他人のアプリのレビューは公式に取得不可）。
- **Apple の返信API は 2026年6月時点で不具合あり** → iOSは「AI返信文を生成してユーザーが App Store Connect に貼り付け」運用。Androidは `reviews.reply` で自動返信可。
- **Google Play の `reviews.list` は直近7日・本文ありのみ・ページングなし** → 毎時ポーリングして自前DBに蓄積することで履歴を作る（これ自体が価値）。
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

---

## Claude Code に渡すときの進め方（推奨プロンプト）
1. 「`lib/appstore.ts` を使って、自分のアプリ1本のレビューを取得しDBにupsertするE2Eを通して」
2. 「取得したレビューのうち★1〜2をLINE通知する処理を `notify.ts` で実装して」
3. 「`app/(dashboard)` に統合インボックス画面を shadcn/ui で作って」
4. 「Stripeでサブスク(Free/Pro)を追加して」

## MVPスコープ
- [x] DBスキーマ
- [x] Apple/Google レビュー取得
- [x] AI返信ドラフト生成
- [x] 定期ポーリング + 低評価通知の骨組み
- [ ] ダッシュボードUI（Claude Codeで肉付け）
- [ ] Stripe課金（Claude Codeで追加）

---

Made as a starting scaffold — iterate freely.
