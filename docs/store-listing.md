# ストア掲載メタデータ & 申請チェックリスト（RevPilot）

このドキュメントは App Store / Google Play への申請素材の下書きです。
事業者情報は `lib/site.ts` に集約済み（法務3ページが参照）。公開前に文言と価格を最終確認してください。

> **掲載文の原則**: 実装されていない機能・検証していない挙動を書かない。
> ストア審査（Apple 2.3.1「説明と実装の不一致」）でも、景表法（優良誤認）でも、
> ここが一番の落とし穴になる。

---

## 1. 基本情報（共通）

| 項目 | 値 |
|---|---|
| ストアでのアプリ名 | RevPilot - アプリレビュー管理 |
| 端末上の名前 | RevPilot |
| サブタイトル（App Store・30字） | アプリレビュー監視・AI返信・分析 |
| 簡単な説明（Google Play・80字） | App Store と Google Play のレビューを監視し、AIが返信文案を提案します。 |
| カテゴリ | ビジネス（第2候補: 仕事効率化） |
| 対応言語 | 日本語 |
| 対象年齢 | 4+ / 全年齢 |
| 料金 | 無料（アプリ内課金あり: Pro/Max サブスク） |
| 料金プラン URL | `https://app.revpilot-jp.workers.dev/pricing` |
| 利用規約 URL | `https://app.revpilot-jp.workers.dev/terms` |
| プライバシーポリシー URL | `https://app.revpilot-jp.workers.dev/privacy` |
| 特商法表記 URL | `https://app.revpilot-jp.workers.dev/tokushoho` |
| サポート URL / 連絡先 | `revpilot.hq@gmail.com` |

> ⚠️ URLは Vercel 無料ドメイン想定（`app.revpilot-jp.workers.dev`）。デプロイ後に実際のサブドメインを確認し、
> 異なる場合は `NEXT_PUBLIC_SITE_URL`、モバイルの `WEB_URL`、本ファイル・各ストアの登録URLを差し替えること。

---

## 2. 説明文（description）

### プロモーション用テキスト（App Store・170字以内）
> Proは初回1か月無料。App Store と Google Play のレビューを一箇所に集めて全期間保存。★1〜2はすぐ通知し、AIがあなたの書き出し・署名に沿って返信を下書きします。Apple・Googleアカウントで1タップ登録。

（審査なしでいつでも差し替え可。トライアルを終了したらこの1文目を外す）

### 概要（本文）
```
RevPilot は、個人開発者のためのアプリレビュー管理ツールです。
Apple または Google のアカウントで、すぐに始められます。

■ レビューをまとめて監視
App Store と Google Play のレビューを一つの受信箱に集約。毎時自動で取得し、
新着があればプッシュ通知でお知らせします（Slack・Discordにも配信できます）。

■ Google Play の消えるレビューを履歴に
Google Play のAPIは直近7日ぶんのレビューしか返しません。RevPilot は定期取得して
蓄積するので、7日を過ぎたレビューもあとから読み返せます（Pro は全期間）。

■ AIが返信を下書き
レビューの内容とトーンに合わせて、AIが返信文案を生成します。
アプリごとに「書き出し・結び/署名・守ってほしいこと」を設定すれば、
どの返信も同じ形にそろいます（全プランで利用可）。
Google Play へはアプリから直接投稿できます。App Store は生成した文面をコピーして
App Store Connect に貼り付けてご利用ください（自動投稿も試みますが、Apple側APIの
状況により失敗することがあります）。

■ 一括返信で時間短縮
たまったレビューにまとめて返信（Pro は一度に20件、Max は50件まで）。

■ 評価を分析
星の分布や推移、よく出るトピックをアプリ別・ストア別に可視化。

■ プラン
・Free … アプリ1件 / レビュー履歴30日 / AI返信 月3件 / 自動取得 毎時
・Pro（月額¥1,480／年額¥14,800・初回1か月無料）… アプリ数無制限 / 履歴無期限 / AI返信 月300件 / 一括返信 最大20件 / トピック分析 / 週次サマリー
・Max（月額¥2,980／年額¥29,800）… Proのすべて / AI返信 月1,000件 / 一括返信 最大50件 / 優先サポート

※価格は税込。サブスクは自動更新されます。解約はいつでも可能です。
※ご利用には、ご自身が権限をお持ちの App Store Connect / Google Play Console の
　APIキーの登録が必要です。手順はアプリ内と下記のヘルプで画面ごとに案内しています。
　https://app.revpilot-jp.workers.dev/help/connect
```

> **書かないこと（実装と一致しない表現）**
> - 「リアルタイム通知」…取得は毎時なので、最大1時間の遅れがある
> - 「そのままストアへ投稿できます」（無条件）…App Store の返信APIは不安定で、
>   Apple Developer 登録前は一度も検証できていない
> - 「AI返信 無制限」…実数の上限がある
> - 「複数メンバーで共有」「Slack連携（双方向）」「競合監視」…未実装

### キーワード（App Store・100字, カンマ区切り）
```
レビュー,アプリレビュー,返信,AI返信,App Store,Google Play,評価,分析,個人開発,インディー,カスタマー,監視
```

---

## 3. 自動更新サブスクの表記（両ストア必須）

課金導線とメタデータに以下を明記すること（Apple は特に厳格）:

- 各プラン名・期間（月額・年額）・価格・無料トライアルの期間と終了後の価格 … `mobile/lib/screens/plan_screen.dart` の `_planCard` に表示
- 「支払いは購入確定時に Apple ID に請求されます」 … `_disclosure()` に記載済み
- 「解約しない限り期間終了時に自動更新されます」 … 同上
- 「更新は現在の期間終了の24時間前までに解約可能」 … 同上
- 利用規約・プライバシーポリシーへの**機能するリンク** … 購入画面下部に設置済み

### iOS の決済方式（対応済み）

- iOS では **App内課金(IAP)のみ** を使う。StoreKit の商品を取得できない場合は
  購入ボタンを無効化し、外部決済へは誘導しない（3.1.1 対策）。
- 解約導線は Apple のサブスクリプション管理
  （`https://apps.apple.com/account/subscriptions`）へ案内する。
  Stripe のカスタマーポータルは iOS では開かない。
- 購入の検証は App Store Server API（`lib/iap-apple.ts`）で行う。
  失効は App Store Server Notifications V2
  （`/api/billing/iap/apple/notifications`）と cron の期限チェックの二重で反映する。
- **申請前に必要**: Apple Developer 登録、`APPLE_IAP_*` 環境変数の設定、
  App Store Connect でのサブスクリプション商品の作成と「送信準備完了」、
  サーバー通知URLの登録。

### Android の決済方式（対応済み）

- Android でも **Google Play Billing のみ**を使う。商品を取得できない場合は
  購入ボタンを無効化し、外部決済へは誘導しない（Play の課金ポリシー対策）。
- 解約導線は Google Play の定期購入管理
  （`https://play.google.com/store/account/subscriptions`）へ案内する。
- 購入の検証は Play Developer API の `purchases.subscriptionsv2.get`（`lib/iap-google.ts`）。
  失効はリアルタイム開発者通知（`/api/billing/iap/google/notifications`）と
  cron の期限チェックの二重で反映する。
- 購入は3日以内に acknowledge しないと Google が自動返金するため、
  クライアント（`completePurchase`）とサーバーの両方で確認している。
- **申請前に必要**: Play Console での定期購入商品の作成と有効化、課金検証用
  サービスアカウントへの「財務データ」権限、RTDN の Pub/Sub 設定。
  手順は `docs/release-setup.md` を参照。

---

## 4. データ安全性の申告

入力の正本は Claude Doc「RevPilot プライバシー申告 回答表」（2026-10-11）。下はそれに
Apple / Google ログイン（2026-10-12 追加）の分を足した最終版。診断・分析は**申告しない**
（Firebase Analytics・Crashlytics・Sentry 等が入っていないため）。

### Apple — App のプライバシー
「データを収集しますか」= はい。以下 **7種類**、すべて 用途「アプリの機能」・ユーザーに紐づけ「はい」・トラッキング「いいえ」。

| カテゴリ | データの種類 | RevPilot での中身 |
|---|---|---|
| 連絡先情報 | メールアドレス | ログイン、通知メール |
| 連絡先情報 | 名前 | Google ログイン時に Google から受け取る氏名（Supabase の認証情報に保存）※追加 |
| 識別子 | ユーザーID | Supabase のアカウントID |
| 識別子 | デバイスID | FCM の通知トークン |
| 購入 | 購入履歴 | プラン、取引ID、有効期限 |
| ユーザーコンテンツ | その他のユーザーコンテンツ | レビュー、返信文、アプリ説明文、返信スタイル |
| その他のデータ | その他のデータタイプ | ストアAPIの認証情報、Apple 連携取り消し用トークン |

- 「ユーザーをトラッキングしますか」= いいえ（ATT ダイアログ不要）。
- パスワードは申告対象の種別に無いので申告不要。
- AI利用回数・連打制限のカウンタは内部の上限管理なので申告しない（2026-10-11 決定）。
- アカウント削除: アプリ内「設定 > アカウントを削除」（5.1.1(v) 対応済み）。

### Google Play — データセーフティ
「共有」はすべて いいえ（委託先と利用者自身の操作による送信は共有に当たらない）。

| 質問 | 回答 |
|---|---|
| 必須のユーザーデータを収集または共有しますか | はい |
| 転送時に暗号化されますか | はい（HTTPS のみ） |
| アカウントの作成方法 | ユーザー名とパスワード ＋ OAuth（Apple / Google でログイン）※追加 |
| アカウント削除のURL | `https://app.revpilot-jp.workers.dev/privacy`（6章に削除手順を追記済み） |
| アカウントを削除せずにデータだけ削除 | いいえ |

| カテゴリ | データの種類 | 収集 | 共有 | 一時的な処理 | 必須/任意 | 目的 |
|---|---|---|---|---|---|---|
| 個人情報 | 名前 | はい | いいえ | いいえ | 任意（Google ログイン時） | アカウント管理 ※追加 |
| 個人情報 | メールアドレス | はい | いいえ | いいえ | 必須 | アプリの機能、アカウント管理 |
| 個人情報 | ユーザーID | はい | いいえ | いいえ | 必須 | アプリの機能、アカウント管理 |
| 金融情報 | 購入履歴 | はい | いいえ | いいえ | 任意 | アプリの機能 |
| アプリのアクティビティ | その他のユーザー作成コンテンツ | はい | いいえ | いいえ | 必須 | アプリの機能 |
| デバイスまたはその他のID | デバイスまたはその他のID | はい | いいえ | いいえ | 任意 | アプリの機能 |

> 第三者処理者として Supabase / Anthropic(Claude) / Resend / Apple / Google（Firebase Cloud Messaging・
> Sign in with Apple・Google ログインを含む） / （利用者が設定した場合のみ）Slack・Discord を利用し、
> 一部は国外移転を伴う旨をプライバシーポリシーに記載済み。Stripe は使用していない。

---

## 5. 必要なビジュアル素材

- [ ] App Store: 6.9" スクリーンショット（1320×2868、必須）。6.5" は 6.9" から自動縮小されるので任意
- [ ] App Store: 1024×1024 アイコン（生成済み: `mobile/assets/branding/`）
- [ ] Google Play: スマホ用スクショ 最低2枚（推奨 1080×1920 以上、最大8枚）
- [ ] Google Play: フィーチャーグラフィック 1024×500
- [ ] Google Play: 512×512 アイコン

スクショの並び（1枚目で価値が伝わる順。各枚に上部キャプションを入れる）:
1. 受信箱 …「App Store と Google Play のレビューを一か所に」
2. レビュー詳細＋AI下書き（返信スタイル適用済み）…「AIが、あなたの言葉づかいで下書き」
3. ★1〜2の通知 …「低評価にすぐ気づける」
4. 保存済みレビューのチラ見せ …「消えるレビューも全期間保存（Pro）」
5. 分析（星の推移・トピック）…「何が評価を下げているか分かる」
6. プラン画面 …「Pro は1か月無料」

---

## 6. 申請前チェックリスト

### コード側（対応済み）
- [x] iOS の外部決済フォールバックを削除（3.1.1）
- [x] 購入画面に規約・プライバシーの機能するリンクを設置（3.1.2）
- [x] 自動更新の開示文を購入画面に表示
- [x] アカウント削除をアプリ内から実行可能（5.1.1(v)）／Web にも導線を追加
- [x] デバッグ用文言をリリースビルドから除外（`kDebugMode` ガード）
- [x] 掲載文と実装の一致（本ファイルの「書かないこと」を参照）
- [x] パスワード再設定の導線（Web / モバイル）
- [x] 公開の料金ページ（`/pricing`）と特商法への解約手順の明記
- [x] Android の Google Play Billing 対応（検証・acknowledge・RTDN）
- [x] iOS/Android のバンドルID・商品IDを `jp.revpilot.app` 系に統一
- [x] Web版ダッシュボードを本番で無効化（`ENABLE_WEB_APP` 未設定で404）
- [x] 公開ランディング（`/`）＝ストアのマーケティング/サポートURL
- [x] リモートpush通知（アプリ終了中でも新着レビューが届く／FCM）
- [x] 通知対象の設定をサーバーと同期（★1〜2のみ、を push でも尊重する）

### 運用側（要作業）
- [ ] `supabase/schema.sql` を本番DBで実行（RLS・AI使用量・レート制限の定義を含む）
- [ ] 法務ページ 3種＋料金ページを本番ドメインで公開・URLをストアに登録
- [ ] `NEXT_PUBLIC_SITE_URL` とモバイルの `WEB_URL` を本番ドメインに設定
- [ ] `OPERATOR_ALERT_EMAIL` / `RESEND_API_KEY` を設定（障害に気づけるようにする）
- [ ] GitHub Actions のシークレット（`REVPILOT_CRON_URL` / `REVPILOT_CRON_SECRET`）を設定
      ※Vercel Hobby はcronが日次までのため、毎時取得はGitHub Actions側で行う
- [ ] Apple Developer 登録 → `APPLE_IAP_*` 設定 → サブスク商品作成 → サーバー通知URL登録
- [ ] Apple Small Business Program に申請（手数料 30%→15%。原価計算の前提）
- [ ] Google Play 登録 → 定期購入商品の作成 → 課金検証用サービスアカウント → RTDN 設定
- [ ] リリース署名（Android keystore）の作成と保管
- [ ] バージョン・ビルド番号の設定（`pubspec.yaml`）
> 詳細な手順は `docs/release-setup.md` を参照。
- [ ] Firebase プロジェクト作成 → APNs認証キーの登録 → `FIREBASE_*` の設定（push通知）
- [ ] Apple: App Privacy 申告 / Google: データセーフティ申告（4章の表で入力）
- [ ] Sign in with Apple: App ID で有効化、SIWA 用キー作成 → `APPLE_SIWA_*` を Cloudflare に設定
- [ ] Google ログイン: Google Cloud で Web / iOS の OAuth クライアント作成 → Supabase の Apple・Google プロバイダ有効化 →
      `GOOGLE_WEB_CLIENT_ID` / `GOOGLE_IOS_CLIENT_ID` をビルド設定へ、iOS は Info.plist に逆順クライアントIDの URL スキーム
- [ ] テストアカウント（審査員用）の用意と備考欄への記載
      ※ストア連携なしでも画面が確認できるよう、レビュー投入済みのアカウントを用意する
