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

## 現状の実装範囲

- ✅ メール＋パスワードのログイン／新規登録（Supabase Auth共有）
- ✅ レビュー一覧（星・アプリ・未返信フィルタ、Pull-to-refresh）
- ✅ レビュー詳細（メタ情報・AIトピック表示・返信下書き保存・コピー）
- ✅ 分析（平均評価・星分布・トピック傾向）
- ✅ 設定（アカウント・プラン・連携アプリ一覧・ログアウト）

## サーバー接続後に有効化する予定

- AI返信の自動生成（Next.jsの `/api/...` または Supabase Edge Function 経由）
  - `config/app_config.json` の `API_BASE_URL` を設定すると有効化
- 手動更新（ストアからの新着レビュー取得）
- ストア認証情報の登録・アプリ追加（現状はWebダッシュボードで実施）

## 課金についての注意

iOS/Androidアプリ内でサブスクリプションを販売する場合、Apple/Googleのポリシーにより
**アプリ内課金（IAP）の利用が必要**になるケースがあります（Stripeの直接決済は原則不可）。
モバイルの課金は RevenueCat 等のIAP、もしくはWebでの申込に誘導する設計を後で検討します。
