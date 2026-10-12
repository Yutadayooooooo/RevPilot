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
> App Store と Google Play のレビューを一箇所で監視。毎時チェックして新着をプッシュ通知し、AIが返信文案を提案。評価の推移も可視化して、個人開発でもレビュー対応を後回しにしない。

### 概要（本文）
```
RevPilot は、個人開発者のためのアプリレビュー管理ツールです。

■ レビューをまとめて監視
App Store と Google Play のレビューを一つの受信箱に集約。毎時自動で取得し、
新着があればプッシュ通知でお知らせします（Slack・Discordにも配信できます）。

■ Google Play の消えるレビューを履歴に
Google Play のAPIは直近7日ぶんのレビューしか返しません。RevPilot は定期取得して
蓄積するので、7日を過ぎたレビューもあとから読み返せます。

■ AIが返信を下書き
レビューの内容とトーンに合わせて、AIが返信文案を生成します。
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
　APIキーの登録が必要です。
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

### Apple — App Privacy（収集データの申告）
| データ種別 | 収集 | 用途 | 個人と紐付け |
|---|---|---|---|
| メールアドレス | あり | アプリ機能 / アカウント | あり |
| ユーザーコンテンツ（レビュー・返信文） | あり | アプリ機能 | あり |
| 購入・課金情報 | あり（App Store / Google Play） | アプリ機能 | あり |
| 診断・利用状況 | あり | 分析 / 品質改善 | 任意 |
| デバイスID（通知トークン） | あり | アプリ機能（プッシュ通知） | あり |

- トラッキング（ATT）: **なし**（広告目的の追跡はしていない）
- アカウント削除: アプリ内「設定 > アカウントを削除」から実行可（5.1.1(v) 対応済み）

### Google Play — データセーフティ
- 収集: メールアドレス、アプリ内アクティビティ、アプリの操作情報、デバイスID（通知トークン）
- 目的: アプリの機能、アカウント管理、分析
- 送信時の暗号化: あり（HTTPS）
- 保存データの扱い: ストア資格情報は AES-256-GCM で暗号化して保管
- ユーザーによる削除リクエスト: 可（アプリ内から退会 → 関連データはcascade削除）

> 第三者処理者として Supabase / Anthropic(Claude) / Resend / Apple / Google（Firebase Cloud Messaging を含む） /
> （利用者が設定した場合のみ）Slack・Discord を利用し、
> 一部は国外移転を伴う旨をプライバシーポリシーに記載済み。
> Stripe は使用していない（決済はアプリ内課金のみ）。

---

## 5. 必要なビジュアル素材

- [ ] App Store: 6.7" / 6.5" スクリーンショット（各必須サイズ）
- [ ] App Store: 1024×1024 アイコン（生成済み: `mobile/assets/branding/`）
- [ ] Google Play: スマホ用スクショ最低2枚、7"/10" タブレット（任意）
- [ ] Google Play: フィーチャーグラフィック 1024×500
- [ ] Google Play: 512×512 アイコン
- 推奨スクショ画面: 受信箱 / レビュー詳細＋AI返信 / 分析 / プラン（ダークモード版も1枚あると良い）

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
- [ ] Apple: App Privacy 申告 / Google: データセーフティ申告
- [ ] テストアカウント（審査員用）の用意と備考欄への記載
      ※ストア連携なしでも画面が確認できるよう、レビュー投入済みのアカウントを用意する
