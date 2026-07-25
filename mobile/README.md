# RevPilot Mobile (Flutter)

RevPilotのスマホ版（iOS / Android）。バックエンドはWeb版と同じSupabaseプロジェクトを共有します。
認証・DB・RLSはWebと共通なので、Web／モバイルどちらで登録しても相互にログインできます。

## セットアップ

1. 設定ファイルを用意（anonキーはクライアント公開前提なので埋め込みOK）:
   ```
   cp config/app_config.example.json config/app_config.json
   ```
   `config/app_config.json` にSupabaseのURLとanonキーを記入。
   （このリポジトリではWeb版の `.env.local` の値で自動生成済み。`config/app_config.json` はgitignore対象）

2. 依存取得:
   ```
   flutter pub get
   ```

3. 実行（設定ファイルを注入して起動）:
   ```
   flutter run --dart-define-from-file=config/app_config.json
   ```
   または同梱スクリプト:
   ```
   ./run.sh              # 接続中のデバイスで起動
   ./run.sh -d <id>      # デバイス指定
   ```

## 実装範囲（スマホだけで完結）

サーバー秘密鍵が必要な処理だけAPIを叩き、それ以外は直接Supabaseで完結する。

**サーバー接続なしで動く（直接Supabase / RLS）**
- ✅ ログイン／新規登録（Supabase Auth共有）
- ✅ レビュー一覧（星・アプリ・未返信フィルタ、Pull-to-refresh）
- ✅ レビュー詳細（メタ・AIトピック・返信下書き保存・コピー）
- ✅ 分析（平均・星分布・トピック傾向）
- ✅ **アプリの追加・編集・削除**（プラン別上限チェック込み）
- ✅ ストア連携状態の表示

**サーバー接続（`API_BASE_URL`）が必要**
- 🔌 AI返信の自動生成（`/api/reply`）
- 🔌 Google Playへの返信投稿（`/api/reply` action=post）
- 🔌 ストアから最新レビューを取得（`/api/poll`）
- 🔌 ストア認証情報の登録（`/api/credentials`・サーバー側でAES暗号化）
- 🔌 プラン変更・解約（`/api/billing/*`・Stripeを外部ブラウザで開く）

`API_BASE_URL` は `config/app_config.json` に設定する（本番はVercelのURL、
ローカル検証時はMacのLAN IP 例 `http://192.168.x.x:3000`）。

## 課金についての注意

iOS/Androidアプリ内でサブスクリプションを販売する場合、Apple/Googleのポリシーにより
**アプリ内課金（IAP）の利用が必要**になるケースがあります（Stripeの直接決済は原則不可）。
モバイルの課金は RevenueCat 等のIAP、もしくはWebでの申込に誘導する設計を後で検討します。
