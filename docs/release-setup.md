# リリース手順書（RevPilot）

**上から順にそのまま実行するための手順書です。** 判断が必要なところは「こうする」と1つに決めてあります。
値はすべてこのリポジトリのコードから拾った実物なので、コピーして貼れば動きます。

> **確認状況について**
> Apple（developer.apple.com / App Store Connect）・Firebase・Supabase の画面は
> 2026-09-07 に実際に開いて確認・設定した内容です。
> Google Play Console は未登録・未確認のため、
> 画面の文言が更新で変わっている可能性があります。項目名が見つからない場合は近い語を探してください。

> **私（AI）が代行できない操作**
> アカウント作成・本人確認・銀行口座や税務情報の入力・契約への署名・秘密鍵のダウンロード・
> 外部サービスへの秘密鍵やAPIキーの貼り付けは、すべてご本人が行う必要があります。
> それ以外は機械的な作業です。

> **秘密鍵の置き場所**
> ダウンロードした `.p8` と Firebase のサービスアカウントJSONは、リポジトリ直下の
> **`secrets/`**（`.gitignore` 済み・コミットされません）に置いてあります。
> `docs/` に置くとサービスアカウントJSONは `.gitignore` に引っかからず**コミットされます**。

---

## 0. 最初に読む：待ち時間が長いもの

以下は「申し込んでから使えるようになるまで日数がかかる」ものです。**今日中に着手してください。**
これらを待つ間に、他の章を進められます。

| 項目 | かかる時間 | 章 |
|---|---|---|
| **Apple 有料アプリ契約**（銀行・税務情報の審査） | 数時間〜数日 | 3-1 |
| **Google Play Console の登録**（$25・本人確認） | 数時間〜数日 | 6-1 |
| **Google Play のクローズドテスト**（12人×14日連続） | **最短14日** | 6-9 |
| Apple Small Business Program の適用 | 申請月の翌月から | 3-11 |

**Google Play のクローズドテストが全体の最長経路です。** アプリが完成していなくても、
テスト版さえ上げれば14日のカウントは始まります。6-1〜6-9 を最優先で進めてください。

---

## 1. この手順で使う値（先に控える）

| 項目 | 値 |
|---|---|
| Bundle ID（iOS） | `jp.revpilot.app` |
| Application ID（Android） | `jp.revpilot.app` |
| サブスク商品ID（Pro） | `jp.revpilot.app.pro.monthly` |
| サブスク商品ID（Max） | `jp.revpilot.app.max.monthly` |
| **本番ドメイン** | `https://app.revpilot-jp.workers.dev` |
| Apple Team ID | `F77Y83KNC7` |
| Apple Developer 登録タイプ | 個人（Individual）／更新日 2027-09-07 |
| iOS 最低対応バージョン | 15.0（Firebase が要求） |
| Android minSdk | Flutter 既定（`flutter.minSdkVersion`） |
| ストアでのアプリ名 | `RevPilot - アプリレビュー管理` |
| 端末のホーム画面での名前 | `RevPilot`（`android:label` / `CFBundleDisplayName`） |
| 価格 | Pro ¥1,480／月・Max ¥2,980／月（いずれも税込） |
| 連絡先 | `revpilot.hq@gmail.com` |
| バージョン | `mobile/pubspec.yaml` の `version: 1.0.0+1` |

> **アプリ名について**: App Store のアプリ名は**全世界で一意**である必要があり、
> 「RevPilot」は既に別のアプリ（OBD-II 車両診断アプリ / `com.felipespada.revpilot`）が使っています。
> そのため**ストア上の名前だけ**を `RevPilot - アプリレビュー管理` にします。
> 端末のホーム画面に出る名前は `RevPilot` のままです（別のフィールドなので影響しません）。
> ストア上の表示名は公開後もいつでも変更できます。

> ⚠️ **Application ID は Play Console に一度アップロードすると永久に変更できません。**
> 初回アップロード前に `mobile/android/app/build.gradle.kts` の `applicationId` が
> `jp.revpilot.app` であることを必ず確認してください。

商品IDを変えるときは**4か所すべて**を直します（1か所でもズレると購入が反映されません）:
`mobile/lib/iap.dart` / `lib/iap-apple.ts` / `lib/iap-google.ts` / `mobile/ios/Runner/RevPilot.storekit`

---

## 2. サーバー（最初にやる）

**なぜ最初か**: 本番ドメインが決まらないと、Apple のサーバー通知URL・Google の RTDN URL・
法務ページのURL・アプリの `API_BASE_URL` が全部決められないからです。

### 2-1. Supabase【完了済み】

> ✅ **2026-09-07 に完了済み**（プロジェクト `cpyadwzsntcpianligej` / PostgreSQL 17.6）。
>
> - `supabase/schema.sql` を**全文適用済み**。適用前は `device_tokens` / `ai_usage` テーブルと
>   `profiles.push_scope` / `notify_webhook_url` / `apple_*` / `google_*` 列がすべて欠けていました
>   （＝プッシュ通知も課金の反映も動かない状態でした）。
> - 適用後に確認: `device_tokens` は anon から `42501 permission denied`、
>   `store_credentials` / `poll_state` も同様。`profiles.push_scope` の既定値は `all`。
> - **Authentication > URL Configuration** も設定済み
>   （Site URL = `https://app.revpilot-jp.workers.dev` /
>   Redirect URLs に `https://app.revpilot-jp.workers.dev/reset-password`）。
>   ローカル開発でパスワード再設定を試すときは `http://localhost:3000/reset-password` も追加してください。
>
> 以下は記録として残します。**スキーマを変更したら 2 を再実行してください（何度でも安全です）。**

1. https://supabase.com でプロジェクトを作成（リージョンは Tokyo (ap-northeast-1)）
2. **SQL Editor** を開き、`supabase/schema.sql` の中身を**全文貼り付けて実行**
   （何度実行しても安全な作りになっています）
3. 実行後、エラーが出ていないことを確認
4. **Project Settings > API** で次の3つを控える
   - Project URL
   - `anon` / `public` キー（新しいUIでは *Publishable key*）
   - `service_role` キー（新しいUIでは *Secret key*）※**秘密**。クライアントに入れない
5. **Authentication > URL Configuration** で以下を設定
   - Site URL: `https://<本番ドメイン>`
   - Redirect URLs に追加: `https://<本番ドメイン>/reset-password`
     （パスワード再設定メールのリンク先。未設定だと再設定が完了できません）

### 2-2. ホスティング（Cloudflare Workers）【完了済み】

> ✅ **2026-10-09 に移行・デプロイ完了。** 本番URLは **https://app.revpilot-jp.workers.dev**
>
> | 項目 | 値 |
> |---|---|
> | Cloudflareアカウント | `pkmn6106@gmail.com`（GitHub連携でサインアップ） |
> | アカウントID | `cb776633070c000a6710b714983166cf` |
> | workers.dev サブドメイン | `revpilot-jp`（`revpilot` は他アカウントが取得済みだった） |
> | Worker名 | `app` → `app.revpilot-jp.workers.dev` |
> | プラン | Workers Free（**下の「CPU時間の注意」を必ず読むこと**） |
>
> **なぜ Vercel をやめたか**: Vercel の Hobby（無料）は
> 「the Hobby plan restricts users to non-commercial, personal use only」と公式に明記されており、
> サブスクを売る RevPilot は規約違反になる。Pro は $20/月。
> Cloudflare Workers は無料枠でも商用利用が可能で、有料でも $5/月。

#### 構成

| ファイル | 役割 |
|---|---|
| `wrangler.jsonc` | Worker名・互換フラグ・公開可の環境変数 |
| `open-next.config.ts` | OpenNext のビルド設定（ISRを使わないので incrementalCache なし） |
| `next.config.ts` | `initOpenNextCloudflareForDev()` の呼び出し |
| `public/_headers` | 静的アセットの長期キャッシュ |
| `scripts/cf-secrets.sh` | `.env.local` の秘密値を Workers のシークレットへ投入 |

**`nodejs_compat` は必須。** `lib/crypto.ts` の AES-256-GCM、`jsonwebtoken` の ES256 署名
（Apple課金検証）、`google-auth-library`（FCM送信）がすべて `node:crypto` を使う。
2026-10-09 に wrangler 上で4つとも実動作を確認済み。

#### デプロイ手順

```bash
cd /Users/yutatomatsu/Documents/revpilot && npx wrangler login
```

```bash
cd /Users/yutatomatsu/Documents/revpilot && npm run deploy
```

`npm run deploy` は `opennextjs-cloudflare build && opennextjs-cloudflare deploy` です。
**`NEXT_PUBLIC_*` はビルド時に埋め込まれる**ので、URLやSupabaseのURLを変えたら必ず再ビルドすること
（`.env.local` が無い環境でビルドすると空のまま焼き込まれる）。

シークレットを入れ直すとき:

```bash
cd /Users/yutatomatsu/Documents/revpilot && bash scripts/cf-secrets.sh
```

現在入っているシークレット（10件）: `SUPABASE_SERVICE_ROLE_KEY` / `NEXT_PUBLIC_SUPABASE_ANON_KEY` /
`ANTHROPIC_API_KEY` / `APP_ENCRYPTION_KEY` / `CRON_SECRET` / `APPLE_IAP_ISSUER_ID` /
`APPLE_IAP_KEY_ID` / `APPLE_IAP_PRIVATE_KEY` / `FIREBASE_SERVICE_ACCOUNT_JSON` / `GOOGLE_RTDN_SECRET`。
公開可の値は `wrangler.jsonc` の `vars` にある。

**入れていないもの**: `STRIPE_*`（Web決済は提供しない）、`IAP_DEV_TRUST_CLIENT`（本番で true にすると
課金を踏み倒せる）、`ASC_*` / `GOOGLE_SERVICE_ACCOUNT_JSON` / `LINE_*`（廃止済み）、
`RESEND_API_KEY` / `RESEND_FROM`（**未取得。通知メールを出すなら resend.com で発行して追加**）。

#### ⚠️ CPU時間の注意（無料プラン最大の論点）

Cloudflare の無料プランは **1リクエストあたりCPU 10ms**。公式ドキュメントはこう書いている:

> Each isolate has some built-in flexibility to allow for cases where your Worker **infrequently**
> runs over the configured limit. **If your Worker starts hitting the limit consistently, its
> execution will be terminated** according to the limit configured.（Error 1102 / `exceededCpu`）

**2026-10-09 の実測値（217リクエスト、うち200件は連続負荷）**:

| 指標 | 実測 |
|---|---|
| CPU 中央値(P50) | **21.3 ms** |
| CPU P90 | 210.4 ms |
| CPU P99 | 404.3 ms |
| `exceededCpu` エラー | **0件** |

つまり **規定の10msは常時超えているが、現時点で打ち切られていない**。
Next.js の SSR は本質的にCPUを食う（公式も「SSRを伴う処理は10〜20ms」と書いている）ので、
コード最適化でこれを10ms未満にするのは現実的でない。

**判断**: 現状は動く。ただし Cloudflare が規定どおり打ち切りを始めると、
**App Store に登録したプライバシーポリシーURLが Error 1102 を返す**。
アクセスが増え始めたら（あるいは審査提出前に安全を取るなら）
**Workers Paid（$5/月）に上げること**。CPU上限が30秒になり、この論点は消える。
Vercel Pro $20 に対して $5 なので、移行で得た節約の大半は残る。

Workers & Pages > Plans から切り替え、`wrangler.jsonc` に以下を足すと上限を明示できる:

```jsonc
"limits": { "cpu_ms": 30000 }
```

#### 無料枠に合わせた設計変更（Paidに上げたら戻してよい）

無料プランは **1リクエストあたり外部サブリクエスト50回 / 同時外部接続6本**。
これに合わせて次を変更した。Paid（10,000回）に上げれば制限は不要になる。

| 箇所 | 変更 | 元の挙動 |
|---|---|---|
| `app/api/cron/poll/route.ts` | **1リクエスト＝1アプリ**。body無しで叩くと対象ID一覧を返す | 1回で全アプリを巡回（アプリ10本超で破綻） |
| `.github/workflows/poll.yml` | 一覧を取ってからIDごとに叩く2段構え | 1回叩くだけ |
| `lib/poll.ts` `MAX_CLASSIFY_PER_RUN` | 1リクエスト8件までAI分類。超過分は分類されず警告ログ | 新着すべてを分類 |
| `lib/poll.ts` `MANUAL_POLL_BATCH` | 手動更新は1回2アプリまで。残りは `skipped` に出る | 自分の全アプリ |
| `app/api/cron/weekly/route.ts` | 1リクエスト8人まで（`BATCH`） | 500人 |
| `.github/workflows/weekly.yml` | **新規**。`maybeMore` が false になるまで繰り返す | vercel.json の cron（移行で失効） |

#### 残りの手動作業

1. **GitHub のリポジトリシークレット**（`Yutadayooooooo/RevPilot` > Settings > Secrets and variables > Actions）
   - `REVPILOT_CRON_URL` = `https://app.revpilot-jp.workers.dev/api/cron/poll`
   - `REVPILOT_WEEKLY_URL` = `https://app.revpilot-jp.workers.dev/api/cron/weekly`
   - `REVPILOT_CRON_SECRET` = `.env.local` の `CRON_SECRET` と同じ値
2. **Vercel の `revpilot-app` プロジェクト**は不要になったので削除してよい（残しても課金は無い）

### 2-3. 毎時のレビュー取得・週次サマリー（GitHub Actions）

ホストが Cloudflare Workers（無料）なので、cron の「束ねる側」は GitHub Actions が担当します。
Workers の Cron Triggers でも起動はできますが、無料プランの
「1リクエストあたり外部サブリクエスト50回」に収めるには**アプリ1本ごとに別リクエスト**へ
分ける必要があり、その繰り返しを無料で回せるのが GitHub Actions です
（パブリックリポジトリは実行時間が無料）。

| ワークフロー | 実行 | 中身 |
|---|---|---|
| `.github/workflows/poll.yml` | 毎時5分 | 対象ID一覧を取得 → IDごとに `/api/cron/poll` を叩く |
| `.github/workflows/weekly.yml` | 毎週月曜 09:00 JST | `maybeMore` が false になるまで `/api/cron/weekly` を繰り返す |

1. GitHub リポジトリ > **Settings > Secrets and variables > Actions > New repository secret**
   - `REVPILOT_CRON_URL` = `https://app.revpilot-jp.workers.dev/api/cron/poll`
   - `REVPILOT_WEEKLY_URL` = `https://app.revpilot-jp.workers.dev/api/cron/weekly`
   - `REVPILOT_CRON_SECRET` = `.env.local` の `CRON_SECRET` と**同じ値**
2. **Actions** タブ > `Poll store reviews` > **Run workflow** で手動実行
3. ログに各アプリの `HTTP 200` が出れば成功

> **注意**: パブリックリポジトリの Actions は60日間コミットが無いと自動で無効化されます。
> 長期間放置する場合は Actions 画面から再有効化してください。

### 2-4. ホストを変えるときに直す場所

ホストを移すと **URLが8か所に散っている**ので、次を全部直す。

| 場所 | 値 |
|---|---|
| `lib/site.ts` の `SITE_URL` 既定値 | 本番URL |
| `.env.local` / Workers の `NEXT_PUBLIC_SITE_URL` | 本番URL（**ビルド時に埋め込まれる**） |
| `mobile/config/app_config.prod.json` | `API_BASE_URL` と `WEB_URL` |
| `mobile/config/app_config.json` | `WEB_URL` |
| App Store Connect | プライバシーポリシーURL / サポートURL / マーケティングURL / サーバ通知URL（本番・Sandbox） |
| Supabase | Authentication > URL Configuration の Site URL と Redirect URLs |
| GitHub Actions シークレット | `REVPILOT_CRON_URL` / `REVPILOT_WEEKLY_URL` |
| `docs/store-listing.md` | 掲載用URL |

> **独自ドメイン（年約¥1,500）を取れば、次に移るときこの作業が丸ごと不要になります。**
> 今回は無料優先で `workers.dev` を使っているため、ホストを変えるたびにこの表を回ることになります。

---

## 3. Apple（App Store）

### 3-0. 現在の状態（2026-09-07 に確認済み）

| 項目 | 状態 |
|---|---|
| Apple Developer Program | 有効（個人 / 更新日 2027-09-07） |
| Team ID | `F77Y83KNC7` |
| Program License Agreement | 同意済み |
| 有料アプリ契約 | **有効** |
| 銀行口座 / 納税フォーム（W-8BEN） | **有効** |
| DSA（アカウント／アプリ 共通の申告） | トレーダーとして申告・連絡先入力まで完了。**`revpilot.hq@gmail.com` 宛の6桁コード入力だけ残り**（3-2） |
| App ID `jp.revpilot.app` | 登録済み（Push Notifications 有効） |
| App Store Connect の App | 作成済み（Apple ID `6809338462`） |
| サブスク2商品 | 作成済み・価格/ローカライズ済み（**審査用スクリーンショットのみ未登録**） |
| 掲載文・サポート/マーケティングURL | 登録済み |
| プライバシーポリシーURL | 登録済み（**「公開」ボタンは未クリック**） |
| App Storeサーバ通知URL | 本番・Sandbox とも登録済み |
| App Store Server API キー | **作成済み**（`RevPilot IAP` / キーID `82HBBH52GZ`）。`.env.local` に設定済み・疎通確認済み |
| APNs 認証キー | **作成済み**（`RevPilot APNs` / キーID `7946K3ULZ2`）。Firebase に登録済み |
| Small Business Program | **申請済み**（2026-09-07 送信。結果はメールで通知） |

### 3-1. 有料アプリ契約に署名する【完了済み】

> ✅ **2026-09-07 に完了済み**（契約・銀行口座・W-8BEN すべて「有効」）。以下は記録として残します。

**この契約が有効になるまで、サブスクリプション商品は1つも作れません。**

1. https://appstoreconnect.apple.com/business を開く
2. 上部に出ている「アプリまたは他のアプリ内購入を提供する場合、**有料アプリ契約に署名する前に法人情報を更新する必要があります**」の
   **「法人を編集」** から、法人情報を入力
   - 個人事業主なので「個人」で、氏名・住所・電話番号をそのまま入力します
3. 「契約」表の **有料アプリ契約** の行で契約を締結する
4. 続けて以下を登録（Account Holder 本人のみ）
   - **銀行口座**（日本の口座。支店コード・口座種別・名義がカナで必要）
   - **税務情報**
     - 米国税務フォーム（**W-8BEN**：日本居住の個人として提出。日米租税条約で源泉税が軽減されます）
     - 日本の税務情報
5. ステータスが「**有効**」に変わるまで待つ（数時間〜数日）

### 3-2. DSA トレーダーステータス（**あと1項目・電話番号の入力だけ**）

**方針: A（トレーダーとして申告）** に決定しました（2026-09-07）。

サブスクリプションを販売する以上、EU法上は「トレーダー」に該当します。
申告しないままだと **EU の App Store からアプリが削除されます**（配信対象は現在175の国または地域）。

#### 分かったこと

- アプリ情報の「デジタルサービス法」欄にある **「開始する」** は `/business` に飛びます。
  つまり **アプリ単位で切り替える画面は無く**、ビジネス設定側の1回の申告がアプリに反映されます。
- ビジネス > コンプライアンス > デジタルサービス法 の行は「有効」と表示されますが、
  中身は **`ノントレーダー` が選択された状態** でした（申告済み＝トレーダー、ではありません）。
- 申告フォームの必須項目は **住所・国・都道府県・郵便番号・国番号・電話番号・メール** です。
  **電話番号を空にすると「次へ」が押せません**（実際に確認）。
  Apple の法人情報レコードには電話番号が保存されていなかったため、ここだけ埋められませんでした。

#### やること（3分）

1. https://appstoreconnect.apple.com/business を開く
2. **コンプライアンス > デジタルサービス法** の行をクリック
3. **「DSAに基づくトレーダーです」** を選んで **次へ**
4. 「連絡先情報の確認」に以下を入力（**電話番号以外は入力済みの状態でブラウザに残してあります**）

   | 欄 | 値 |
   |---|---|
   | 住所1 | `7-61 Toriimatsucho` |
   | 市区町村 | `Kasugai-shi` |
   | 州または都道府県 | `愛知県` |
   | 国または地域 | `日本` |
   | 郵便番号 | `486-0844` |
   | 国際電話国番号 | `+81 (日本)` |
   | **連絡先電話番号** | **ご自身の番号（先頭の0を除いた形。例: 090-1234-5678 → `9012345678`）** |
   | 連絡先メールアドレス | `revpilot.hq@gmail.com` |

5. 次へ進み、Apple の確認（メール／SMSの認証）を完了する

> ⚠️ **この住所・電話・メールは EU の App Store のプロダクトページに公開されます。**
> `lib/site.ts` の法務ページは「住所・電話は請求時開示」方式なので、**方針が食い違います**。
> 公開したくない場合の唯一の代替は
> 「価格および配信状況 > アプリの配信状況 > 管理」で**EU加盟国を配信対象から外す**ことです。

### 3-3. App ID を登録する

> この画面は英語のみです。

1. https://developer.apple.com/account/resources/identifiers/list を開く
2. **青い ⊕（＋）** をクリック
3. **App IDs** を選択 → **Continue**
4. 種類は **App** を選択 → **Continue**
5. フォームを次のとおり埋めます

| 項目 | 入力する値 |
|---|---|
| Platform | `iOS, iPadOS, macOS, tvOS, watchOS, visionOS`（選択肢はこれのみ） |
| App ID Prefix | `F77Y83KNC7 (Team ID)`（固定・変更不可） |
| Description | `RevPilot`（`@ & * "` は使えません） |
| Bundle ID | **Explicit** を選び、右の欄に `jp.revpilot.app` |

6. **Capabilities** タブ（既定で開いています）で、**チェックするのは1つだけ**です

| Capability | 操作 | 理由 |
|---|---|---|
| **Push Notifications** | **チェックを入れる** | 新着レビューのプッシュ通知に必須。**入れ忘れると、Firebase を正しく設定してもエラーも出ずに通知だけ届きません** |
| ↳ Broadcast Capability | **チェックしない** | 一斉配信用。RevPilot は個別配信 |
| ↳ （もし入れてしまったら） | **そのままでよい** | 無効化は「元に戻せない」警告が出る。有効でも実害はないので触らない |
| In-App Purchase | **触らない**（最初からチェック済みでグレーアウト） | すべての App ID で自動的に有効 |
| **上記以外すべて** | **チェックしない** | 使っていない機能を有効にすると審査で理由を聞かれることがあります |

   - **App Services** タブ（MusicKit / ShazamKit / WeatherKit）は**すべてチェックしない**
   - **Capability Requests** タブは何もしない

7. **Continue** → 内容を確認 → **Register**

### 3-4. App Store Connect にアプリを作成する

1. https://appstoreconnect.apple.com/apps を開く
2. **⊕ > 新規App**
3. ダイアログを次のとおり埋めます

| 項目 | 入力する値 |
|---|---|
| プラットフォーム | **iOS のみチェック**（macOS / tvOS / visionOS は外す） |
| 名前 | `RevPilot - アプリレビュー管理`（30文字以内）<br>※単なる `RevPilot` は既存アプリが使用中で登録できません |
| プライマリ言語 | 日本語 |
| バンドルID | ドロップダウンから `jp.revpilot.app`（3-3 が済んでいれば出ます） |
| SKU | `revpilot-ios-001`（社内管理用の任意の文字列。公開されません） |
| ユーザアクセス | **アクセス制限なし** |

4. **作成**

### 3-5. アプリの基本情報を埋める

作成したアプリの中で、次を先に埋めておきます（後の提出でどのみち必要になります）。

- **一般 > App情報**
  - サブタイトル: `アプリレビュー監視・AI返信・分析`
  - カテゴリ: プライマリ **ビジネス**／セカンダリ **仕事効率化**
  - コンテンツ配信権: 「第三者のコンテンツを含まない」を選択
    （表示するレビューは利用者自身のアプリのものです）
  - 年齢制限指定: すべて「なし」で **4+**
- **価格および配信状況**
  - 価格: **無料**（課金はアプリ内課金で行うため、本体は無料）
  - 配信可否: 日本を含む全世界（EU を外す場合は 3-2 参照）
- **App のプライバシー**
  - プライバシーポリシーURL: ✅ 登録済み（`https://app.revpilot-jp.workers.dev/privacy`）
  - ⚠️ **右上の「公開」ボタンは未クリックです。**申告内容はご本人の法的な表明なので、
    内容を確認したうえでご自身で押してください（未公開だと審査に提出できません）
  - 収集データの申告は `docs/store-listing.md` の「4. データ安全性の申告」の表をそのまま入力
  - トラッキング（ATT）: **なし**

### 3-6. サブスクリプショングループと商品を作る

> **3-1 の有料アプリ契約が「有効」になっていないと、この画面は操作できません。**

1. アプリ > **収益化 > サブスクリプション**（旧称: 機能 > App内課金）
2. **サブスクリプショングループ**を1つ作成
   - 参照名: `RevPilot Subscriptions`
   - グループの**ローカリゼーション**（日本語）: 表示名 `RevPilot`
   - ※ グループを1つにするのが重要です。同じグループ内なら Pro ⇄ Max のプラン変更が
     Apple 側で自動的に処理されます（別グループにすると二重課金になります）
3. グループの中に**2つ**作成

| 参照名 | 製品ID | 期間 | 価格（日本） |
|---|---|---|---|
| RevPilot Pro | `jp.revpilot.app.pro.monthly` | 1か月 | ¥1,480 |
| RevPilot Max | `jp.revpilot.app.max.monthly` | 1か月 | ¥2,980 |

4. **各商品で必ず設定するもの**（1つでも欠けると「提出準備完了」になりません）
   - **サブスクリプション期間**: 1か月
   - **サブスクリプション価格**: 上表（日本を基準に、他国は自動換算のままでよい）
   - **App Store 用ローカリゼーション（日本語）**
     - Pro … 表示名: `RevPilot Pro` ／ 説明: `アプリ数無制限・レビュー履歴無期限・AI返信 月300件・一括返信20件・トピック分析・週次サマリー`
     - Max … 表示名: `RevPilot Max` ／ 説明: `Proのすべてに加えて AI返信 月1,000件・一括返信50件・優先サポート`
   - **税カテゴリ**: `App内課金`（既定のまま）
   - **審査に関する情報 > スクリーンショット**: **必須**。アプリのプラン画面のスクリーンショットを1枚。
     - 実機で「設定 > プラン」を開いて撮ればOKです
5. **レベルの並び順を必ず確認する（見落としやすい）**
   - グループ画面の「サブスクリプション」表で **レベル1 = RevPilot Max / レベル2 = RevPilot Pro**
   - 直し方: 「編集」→「レベルを編集」→ ドラッグして並べ替え →「保存」
   - **なぜ重要か**: レベルの上下で「アップグレード」と「ダウングレード」が決まる。
     Pro をレベル1にすると **Pro→Max がダウングレード扱い**になり、即時に切り替わらず
     次回更新日まで反映されない（利用者は多く払っているのに機能が変わらない）
   - ドラッグ時の注意: 少ししか動かさないと**同じレベルに統合**されてしまう
     （両方「レベル1」になる）。行の下端よりさらに下までドラッグして別レベルにすること
6. 各商品のステータスが「**提出準備完了**」になっていることを確認

> **これが未完了だと、アプリ側で商品を取得できず購入ボタンが押せません。**
> 実機で「購入ボタンが押せない」ときは、まずここを疑ってください。

### 3-7. Sandbox テスターを作る（購入テスト用）

1. App Store Connect > **ユーザとアクセス > Sandbox > テスター**
2. **⊕** で追加。**実在しないメールアドレスでも構いません**（例: `sandbox-revpilot@example.com`）
   - ただし既存の Apple ID と重複しないアドレスにしてください
3. 実機の「設定 > Developer > Sandbox Apple Account」でこのアカウントにサインインしてから購入テストします
   - **本物の Apple ID でサインインしないでください**（実際に課金されます）

### 3-8. App Store Server API のキーを作る（購入の検証に必須）【完了済み】

> ✅ **2026-09-07 に完了済み**。キー名 `RevPilot IAP`、キーID **`82HBBH52GZ`**、
> Issuer ID **`239674b8-9dc7-4d01-a5cc-a154aa8e4936`**。
> `.p8` は `secrets/SubscriptionKey_82HBBH52GZ.p8`、値は `.env.local` に設定済みです。
>
> **疎通確認済み**: 同じ鍵で署名したJWTを App Store Server API に投げたところ、
> Sandbox は `400 Invalid transaction id`（＝認証は通っている）を返しました。
>
> ⚠️ **本番エンドポイントは現在 401 を返します。**アプリがまだ本番公開されていないためで、
> 鍵の不備ではありません（Sandbox が同じJWTを受理していることが証拠）。
> `lib/iap-apple.ts` は当初この401で即座に500を投げる作りだったため、
> **審査中のサンドボックス購入が必ず失敗する状態でした**。401でもサンドボックスへ
> フォールバックするよう修正済みです。
>
> 以下は記録として残します。

1. App Store Connect > **ユーザとアクセス > 統合 > App Store Connect API**
2. **「App内課金」**のタブを選ぶ（「チームキー」ではありません。
   RevPilot は JWT に `bid`（バンドルID）クレームを載せる方式なので、App内課金用のキーが必要です）
3. **⊕** でキーを生成。名前は `RevPilot IAP` など
4. **`.p8` ファイルをダウンロード**（**一度きり**。無くしたら作り直しです）
5. 同じ画面の **Issuer ID** と、生成したキーの **キーID** を控える
6. 環境変数に設定（`.env.local` に入れて `bash scripts/cf-secrets.sh`）

| 変数 | 値 |
|---|---|
| `APPLE_IAP_ISSUER_ID` | `239674b8-9dc7-4d01-a5cc-a154aa8e4936` |
| `APPLE_IAP_KEY_ID` | `82HBBH52GZ` |
| `APPLE_IAP_PRIVATE_KEY` | `secrets/SubscriptionKey_82HBBH52GZ.p8` の中身（`.env.local` では改行を `\n` に潰して1行にしてあります） |
| `APPLE_IAP_BUNDLE_ID` | `jp.revpilot.app` |

> ⚠️ **キーIDを間違えやすい点**: `AuthKey_7946K3ULZ2.p8` は **APNs 用**（→3-10）で、
> 課金検証には使えません。課金検証は `SubscriptionKey_82HBBH52GZ.p8` の方です。

### 3-9. サーバー通知（App Store Server Notifications V2）

これが無いと、**利用者が Apple 側で解約しても有料プランのまま残ります**。

1. アプリ > **一般 > App情報**（またはアプリ内の「App Store Server Notifications」セクション）
2. バージョンは **V2** を選択
3. 次のURLを、**実稼働（Production）とサンドボックス（Sandbox）の両方**に設定

```
https://<本番ドメイン>/api/billing/iap/apple/notifications
```

4. 保存後、Cloudflare へのデプロイが済んだら疎通を確認

> ✅ **登録済み**（2026-09-07）。本番・Sandbox とも
> `https://app.revpilot-jp.workers.dev/api/billing/iap/apple/notifications` を設定しました。
> 現在の App Store Connect にはV1/V2の選択欄が無く、新規設定は V2 になります
> （`lib/iap-apple.ts` は V2 前提の実装）。

### 3-10. APNs 認証キーを作る（プッシュ通知に必須）【完了済み】

> ✅ **2026-09-07 に完了済み**。キー名 `RevPilot APNs`、キーID **`7946K3ULZ2`**、
> Team Scoped (All topics) / **Sandbox & Production** の両対応。
> `.p8` は `secrets/AuthKey_7946K3ULZ2.p8`。
> **Firebase への登録も完了済み**（開発用・本番環境用の両方に同じ鍵が入っています → 5-3）。
>
> 以下は記録として残します。

1. https://developer.apple.com/account/resources/authkeys/list を開く
2. **⊕** で **Create a key**
3. Key Name: `RevPilot APNs`
4. **Apple Push Notifications service (APNs)** に**チェック**を入れる
   - 環境を選ぶ欄が出た場合は **Sandbox & Production**（両方）を選ぶ
5. **Continue > Register**
6. **`.p8` をダウンロード**（**一度きり**）。**キーID**も控える
7. この鍵は RevPilot のサーバーではなく **Firebase に登録**します（→ 5-3）
   - 必要な3点: **`.p8` ファイル** ／ **キーID** ／ **Team ID `F77Y83KNC7`**

### 3-11. Small Business Program に申請する

手数料が **30% → 15%** になります。`lib/plan.ts` の原価計算は 15% を前提にしているため、
**未申請だと Max の粗利がほぼ消えます。必ず申請してください。**

1. https://developer.apple.com/jp/app-store/small-business-program/ の「今すぐ登録」
2. 前年の売上が100万ドル未満であることを申告（新規なら該当します）
3. **適用は申請した月の翌月1日から**です。今月中に申請してください

---

## 4. iOS のビルドと提出

### 4-1. アプリ設定ファイルを本番向けにする

設定ファイルは**開発用と本番用の2本**に分けてあります（どちらも Git 管理外）。

| ファイル | 用途 | `API_BASE_URL` |
|---|---|---|
| `config/app_config.json` | 開発（`flutter run`） | 開発PCのLAN IP |
| `config/app_config.prod.json` | **リリースビルド** | `https://app.revpilot-jp.workers.dev` |

✅ **どちらも記入済みです**（2026-09-07）。Firebase の6つの値も両方に入っています。
差分は `API_BASE_URL` の1行だけです。手を入れる必要はありません。

> ⚠️ **リリースビルドで `config/app_config.json`（開発用）を使わないこと。**
> `API_BASE_URL` がLAN IPのままだと、アプリ内の規約・プライバシーのリンクが全部切れ、
> 審査で落ちます。本章のビルドコマンドは `app_config.prod.json` を指しています。

### 4-2. バージョンを決める

`mobile/pubspec.yaml`:

```yaml
version: 1.0.0+1
```

- `1.0.0` が表示バージョン、`+1` がビルド番号
- **提出のたびにビルド番号（`+` の後ろ）を必ず1つ上げます**。同じ番号は二度使えません

### 4-3. ビルドしてアップロード

**初回は Xcode から行うのが確実です**（署名の設定を画面で確認できるため）。

1. まず Dart 側をビルドしておきます

```bash
cd mobile && flutter build ios --release --dart-define-from-file=config/app_config.prod.json
```

2. Xcode で `mobile/ios/Runner.xcworkspace` を開く（`.xcodeproj` ではありません）
3. **Xcode > Settings > Accounts** に、Apple Developer Program に登録した Apple ID を追加
4. 左のツリーで **Runner** を選び、**Signing & Capabilities** タブ
   - **Automatically manage signing** にチェック
   - Team: `tomatsu yuta (F77Y83KNC7)`
   - Bundle Identifier: `jp.revpilot.app`
   - **Push Notifications** の Capability が表示されていることを確認
     （`Runner.entitlements` を設定済みなので自動で出ます。エラーが出る場合は 3-3 の
     App ID で Push Notifications にチェックが入っていません）
5. 上部のデバイス選択を **Any iOS Device (arm64)** にする
6. **Product > Archive**
7. Organizer が開いたら **Distribute App > App Store Connect > Upload**
8. App Store Connect の「TestFlight」にビルドが現れるまで数分〜30分待つ

> 2回目以降は `flutter build ipa --release --dart-define-from-file=config/app_config.prod.json` で
> CLI からも作れます（4 の署名設定が済んでいることが前提）。

> **署名で困ったら**: `Runner.entitlements` に `aps-environment` を入れてあるため、
> App ID 側の Push Notifications（3-3）が有効になっていないと署名に失敗します。

### 4-4. 提出

1. アプリ > **App Store** タブ > 新しいバージョン
2. **スクリーンショット**（`docs/store-listing.md` の「5. 必要なビジュアル素材」参照）
   - iPhone 6.7インチ用が必須
3. **プロモーションテキスト・概要・キーワード・サポートURL・マーケティングURL**
   - 文面は `docs/store-listing.md` の「2. 説明文」をそのまま使えます
   - サポートURL / マーケティングURL: `https://<本番ドメイン>/`
4. **App内課金を同梱**: このバージョンの「App内課金」欄で、3-6 で作った2商品を**選択**する
   - **初回リリースでは、アプリ本体と同時に提出しないと商品が承認されません**
5. **審査に関する情報**
   - 連絡先: 氏名・電話・`revpilot.hq@gmail.com`
   - **サインインが必要**: はい → 8章のテストアカウントを記入
   - メモ欄: 8章の文例をそのまま貼る
6. **輸出コンプライアンス**: `Info.plist` に `ITSAppUsesNonExemptEncryption = false` を入れてあるため、
   質問は表示されません（HTTPS のみで独自暗号を実装していないため免除に該当）
7. **審査に提出**

---

## 5. プッシュ通知（Firebase Cloud Messaging）

アプリを終了していても新着レビューを届けるための設定です。
**未設定でもアプリは動きます**（プッシュだけ送られず、メール / Slack / Discord は届きます）。
料金は無料枠（Spark プラン）で足ります。

> ✅ **この章は 2026-09-07 にすべて完了済みです。**確定値:
>
> | 項目 | 値 |
> |---|---|
> | プロジェクトID | `revpilot-bf3b9`（Spark プラン） |
> | 送信者ID / プロジェクト番号 | `853072258337` |
> | iOS アプリ | `RevPilot iOS` / `jp.revpilot.app` / Team `F77Y83KNC7` |
> | Android アプリ | `RevPilot Android` / `jp.revpilot.app` |
> | FCM HTTP v1 API | 有効（レガシーAPIは無効） |
> | APNs 認証キー | 開発用・本番環境用の両方に `7946K3ULZ2` を登録済み |
> | サービスアカウントJSON | `secrets/revpilot-bf3b9-firebase-adminsdk-fbsvc-fadfa28c35.json` / `.env.local` に設定済み |
>
> 6つの `FIREBASE_*` は `mobile/config/app_config.json` と `app_config.prod.json` の両方に記入済みです。
> サーバー側の疎通も確認済み（無効なトークンで送信 → `400 INVALID_ARGUMENT`＝資格情報は通っている）。
>
> 以下は記録として残します。

### 5-1. Firebase プロジェクトを作る

1. https://console.firebase.google.com/ で **プロジェクトを追加**
2. プロジェクト名: `revpilot`
3. **Google アナリティクスは「無効」**（不要です。有効にすると同意事項が増えます）

### 5-2. iOS / Android アプリを登録して値を控える

プロジェクトの設定（⚙️）> **全般 > マイアプリ** から2つ登録します。

**iOS アプリ**
- Apple バンドルID: `jp.revpilot.app`
- アプリのニックネーム: `RevPilot iOS`
- **`GoogleService-Info.plist` のダウンロードは不要**（下記参照）

**Android アプリ**
- Android パッケージ名: `jp.revpilot.app`
- アプリのニックネーム: `RevPilot Android`
- 署名証明書 SHA-1: **空欄のままでOK**（FCM には不要。Google ログインを使う場合のみ必要）
- **`google-services.json` のダウンロードは不要**

> **なぜ設定ファイルが不要か**
> RevPilot は Firebase の値を他の設定と同じ `--dart-define` で渡す方式にしてあります。
> 理由は (1) 設定の受け渡し口を `config/app_config.json` の1つに保つため、
> (2) Firebase 未設定でもビルドが通り、プッシュだけ無効になるようにするためです。

登録後、各アプリの設定画面に出る値を `mobile/config/app_config.json` に書き写します:

| app_config.json のキー | Firebase 上の名称 | 例 |
|---|---|---|
| `FIREBASE_PROJECT_ID` | プロジェクトID | `revpilot-1a2b3` |
| `FIREBASE_SENDER_ID` | プロジェクト番号 / 送信者ID | `123456789012` |
| `FIREBASE_API_KEY_IOS` | iOSアプリの「ウェブAPIキー」 | `AIza...` |
| `FIREBASE_APP_ID_IOS` | iOSアプリのアプリID | `1:1234...:ios:abcd...` |
| `FIREBASE_API_KEY_ANDROID` | Androidアプリの「ウェブAPIキー」 | `AIza...` |
| `FIREBASE_APP_ID_ANDROID` | Androidアプリのアプリ ID | `1:1234...:android:abcd...` |

> これらは秘密鍵ではなく、クライアントに埋め込む前提の識別子です。
> API キーは Firebase コンソールの各アプリのカードに表示されます。

**確定値（記入済み）**

| キー | 値 |
|---|---|
| `FIREBASE_PROJECT_ID` | `revpilot-bf3b9` |
| `FIREBASE_SENDER_ID` | `853072258337` |
| `FIREBASE_API_KEY_IOS` | `AIzaSyAViXWSSbw0vlCltrO153PKT8o0jqiRFec` |
| `FIREBASE_APP_ID_IOS` | `1:853072258337:ios:d720551169304951144a60` |
| `FIREBASE_API_KEY_ANDROID` | `AIzaSyDUPVmZSbPvqZIu98Nom1WNYl6TiXzSuVY` |
| `FIREBASE_APP_ID_ANDROID` | `1:853072258337:android:20490166e0a01cc3144a60` |

### 5-3. APNs 認証キーを登録する（iOS のみ・必須）【完了済み】

> ✅ **登録済み**（2026-09-07 確認）。「Apple アプリの構成」に
> **開発用 APNs 認証キー** と **本番環境用 APNs 認証キー** の2行が並び、
> どちらもキーID `7946K3ULZ2` / チームID `F77Y83KNC7` になっています。

1. プロジェクトの設定 > **Cloud Messaging** タブ
2. 「Apple アプリの構成」の該当アプリで **APNs 認証キー > アップロード**
3. 3-10 でダウンロードした `.p8` を選び、以下を入力
   - **キーID**: 3-10 で控えたもの
   - **チームID**: `F77Y83KNC7`

> **ここが空だと iOS には一切通知が届きません。しかもエラーは出ません。**

### 5-4. 送信用サービスアカウント（サーバー側）【完了済み】

> ✅ JSON は取得済みで `.env.local` にも設定済みです
> （`secrets/revpilot-bf3b9-firebase-adminsdk-fbsvc-fadfa28c35.json`）。
> Cloudflare Workers のシークレットにも投入済みです（2026-10-09）。
> `.env.local` では JSON を1行に潰して入れてあり、`scripts/cf-secrets.sh` がそこから流し込みます。

1. プロジェクトの設定 > **サービス アカウント** タブ
2. **新しい秘密鍵の生成** → JSON がダウンロードされる
3. その JSON の**中身を丸ごと** `.env.local` に入れ、`bash scripts/cf-secrets.sh` で投入

| 変数 | 値 |
|---|---|
| `FIREBASE_SERVICE_ACCOUNT_JSON` | ダウンロードしたJSONの中身（改行込みで貼り付け可） |

4. シークレットは即時反映されるが、`NEXT_PUBLIC_*` を変えた場合だけ `npm run deploy` で再ビルドが要る

> ⚠️ これは**秘密鍵**です。リポジトリにコミットしないでください。
> Firebase が付けるファイル名は `<プロジェクト>-firebase-adminsdk-....json` で、
> **`.gitignore` の `service-account*.json` には一致しません**。
> そのため `secrets/`（ディレクトリごと除外）に置いています。

### 5-5. 動作確認

1. 実機にアプリを入れて起動し、**通知を許可**する
2. **設定タブ > 「テスト通知を送る」** をタップ
3. アプリを完全に終了して、もう一度実行 → ロック画面に通知が出れば成功

**届かないときの切り分け**

| 症状 | 疑うところ |
|---|---|
| 「この端末が通知先として登録されていません」 | 通知の許可が拒否されている／`FIREBASE_*` が空／`API_BASE_URL` が誤り |
| 「プッシュ通知はまだ設定されていません」 | Workers の `FIREBASE_SERVICE_ACCOUNT_JSON` が未設定（`npx wrangler secret list` で確認） |
| Android だけ届く | APNs 認証キーの登録漏れ（5-3）／App ID の Push Notifications 未チェック（3-3） |
| 開発中は届くが App Store 版だけ届かない | `Runner.entitlements` の `aps-environment`（配布時は Xcode が production に置き換えます） |

---

## 6. Android（Google Play）

> この章の画面は未確認です（Play Console 未登録のため）。項目名が違う場合は近い語を探してください。

### 6-1. Google Play Console に登録する（$25・買い切り）

1. https://play.google.com/console/signup
2. **個人**アカウントとして登録し、本人確認書類を提出
3. $25 を支払う
4. **販売者アカウント（Payments profile）**も作成する
   - 有料アプリ／アプリ内課金を出すには必須です。銀行口座・税務情報を登録します

### 6-2. 個人開発者の追加要件を確認する

2023年11月13日以降に作成した個人アカウントは、**公開前に12人以上のテスターによる
14日間の連続クローズドテスト**が必要です。

- Play Console の「アプリを公開する準備」または「テストと公開」に、
  あなたのアカウントに適用される条件が表示されます。**必ず自分の画面で確認してください**
- **これが全体の最長経路です。** 6-6 のアップロードを済ませたらすぐテストを開始してください

### 6-3. リリース署名鍵（keystore）を作る

```bash
keytool -genkey -v \
  -keystore ~/revpilot-upload.jks \
  -keyalg RSA -keysize 2048 -validity 10000 \
  -alias revpilot
```

- パスワードを2回聞かれます（ストア用と鍵用）。**同じで構いませんが、必ず控えてください**
- 氏名・組織などは任意（空欄可）

続いて `mobile/android/key.properties` を作成します（Git 管理外です）:

```properties
storePassword=（上で設定したストアのパスワード）
keyPassword=（上で設定した鍵のパスワード）
keyAlias=revpilot
storeFile=/Users/あなたのユーザー名/revpilot-upload.jks
```

> `mobile/android/app/build.gradle.kts` は **`key.properties` があればそれで署名し、
> 無ければデバッグ署名にフォールバック**するようにしてあります。
> ファイルを置くだけで、Gradle の編集は不要です。
>
> **この `.jks` は「アップロード鍵」です。** Play アプリ署名（新規アプリは既定で有効）を使う場合、
> 配信用の署名鍵は Google が保管します。アップロード鍵を紛失しても Google に申請すれば
> 再登録できますが、**手続きに数日かかります**。必ずバックアップしてください。

### 6-4. アプリを作成する

1. Play Console > **アプリを作成**
   - アプリ名: `RevPilot - アプリレビュー管理`（Play は一意性を求めませんが、App Store と揃えます）
   - デフォルトの言語: 日本語
   - アプリ / ゲーム: **アプリ**
   - 無料 / 有料: **無料**（課金はアプリ内課金）
   - 宣言事項にチェック

### 6-5. AAB をビルドする

```bash
cd mobile && flutter build appbundle --release --dart-define-from-file=config/app_config.prod.json
```

生成物: `mobile/build/app/outputs/bundle/release/app-release.aab`

ビルドログに `Signing config: release` 相当が出ない、または警告が出る場合は
`key.properties` のパスを見直してください。

### 6-6. 内部テストにアップロードする

1. **テストとリリース > テスト > 内部テスト > 新しいリリースを作成**
2. **Play アプリ署名**の確認画面が出たら「続行」（Google に署名鍵を管理させます）
3. `app-release.aab` をアップロード
4. リリースノートを書いて「保存 > リリースのレビュー > 公開」

> **定期購入商品は、BILLING 権限を含むビルドを1つ以上アップロードしないと作れません。**
> だから 6-7 より先にここをやります。

### 6-7. 定期購入商品を作る

1. **収益化 > 商品 > 定期購入 > 定期購入を作成**

| 商品ID | 名前 | 説明 |
|---|---|---|
| `jp.revpilot.app.pro.monthly` | RevPilot Pro | アプリ数無制限・レビュー履歴無期限・AI返信 月300件・一括返信20件・トピック分析・週次サマリー |
| `jp.revpilot.app.max.monthly` | RevPilot Max | Proのすべてに加えて AI返信 月1,000件・一括返信50件・優先サポート |

2. 各定期購入に**基本プラン**を追加
   - プランID: `monthly`
   - タイプ: **自動更新**
   - 請求期間: **1か月**
   - 価格: Pro `¥1,480` ／ Max `¥2,980`
   - 対象国: **日本を含める**（全世界でも可）
   - 更新タイプ: 自動更新
3. 基本プランと定期購入の両方を「**有効**」にする

> **有効になっていないと、アプリ側で商品を取得できず購入ボタンが押せません。**

### 6-8. 課金検証用のサービスアカウントを作る

> ⚠️ これは**運営専用**のサービスアカウントです。
> 利用者がレビュー取得のために登録するサービスアカウントとは**別物**なので混同しないでください。

1. Play Console > **設定 > API アクセス** で Google Cloud プロジェクトをリンク（新規作成でよい）
2. 同画面から、または Google Cloud コンソールで**サービスアカウントを作成**
   - 名前: `revpilot-play-billing`
3. そのサービスアカウントの **JSON キーを作成してダウンロード**
4. Play Console > **ユーザーとアクセス > ユーザーを招待** で、サービスアカウントのメールアドレス
   （`...@....iam.gserviceaccount.com`）を招待
5. 権限に以下を付与
   - **財務データ、注文、定期購入の一括レポートを表示**
   - **アプリの情報を表示、一括レポートをダウンロード（読み取り専用）**
6. `.env.local` に入れて `bash scripts/cf-secrets.sh` で投入

| 変数 | 値 |
|---|---|
| `GOOGLE_PLAY_IAP_SERVICE_ACCOUNT_JSON` | ダウンロードしたJSONの中身 |
| `GOOGLE_PLAY_PACKAGE_NAME` | `jp.revpilot.app` |

> 権限が反映されるまで**最大24時間**かかることがあります。すぐ動かなくても慌てないでください。

### 6-9. リアルタイム開発者通知（RTDN）

これが無いと、**利用者が Google 側で解約しても有料プランのまま残ります**。

1. Google Cloud コンソール > **Pub/Sub > トピック** で作成（例: `revpilot-rtdn`）
2. そのトピックの権限で、
   `google-play-developer-notifications@system.gserviceaccount.com` に
   **Pub/Sub パブリッシャー** ロールを付与
3. トピックに **push サブスクリプション**を作成し、エンドポイントを設定

```
https://app.revpilot-jp.workers.dev/api/billing/iap/google/notifications?secret=<GOOGLE_RTDN_SECRET>
```

4. Play Console > **収益化のセットアップ > リアルタイム デベロッパー通知** に
   トピック名 `projects/<プロジェクトID>/topics/revpilot-rtdn` を設定
5. 同画面の **「テスト通知を送信」** を押し、`npx wrangler tail` に 200 が出ることを確認

### 6-10. ストアの掲載情報と申告

**テストとリリース > アプリのコンテンツ** で、以下をすべて完了させます（1つでも残っていると公開できません）。

- **プライバシーポリシー**: `https://<本番ドメイン>/privacy`
- **アプリのアクセス権**: 「すべての機能が制限なく利用可能」ではなく、
  **「ログインが必要」を選び、8章のテストアカウントを記入**
- **広告**: 広告は**含まれていません**
- **コンテンツのレーティング**: アンケートに回答（ビジネスカテゴリ、暴力・性的表現なし → 全年齢）
- **ターゲット層**: 18歳以上
- **ニュースアプリ**: いいえ
- **データセーフティ**: `docs/store-listing.md` の「4. データ安全性の申告」の内容を入力
  - 収集: メールアドレス／アプリ内アクティビティ／**デバイスID（通知トークン）**
  - 送信時の暗号化: **あり**
  - データ削除のリクエスト: **可能**（アプリ内から退会できます）
- **政府アプリ**: いいえ
- **金融商品**: いいえ

**メインのストアの掲載情報**:
- 簡単な説明（80字）・詳しい説明とも `docs/store-listing.md` の「1. 基本情報」「2. 説明文」をそのまま使えます
- アプリのアイコン 512×512、フィーチャーグラフィック 1024×500、スマホ用スクリーンショット最低2枚

### 6-11. サービス手数料

Google Play は定期購入の手数料が**初年度から 15%**（自動適用）です。Apple と違って申請は不要です。

---

## 7. ストア公開後にやること

1. `wrangler.jsonc` の `vars` に以下を追加して `npm run deploy` すると、ランディングに「入手」ボタンが出ます

| 変数 | 値 |
|---|---|
| `NEXT_PUBLIC_APP_STORE_URL` | App Store のアプリURL |
| `NEXT_PUBLIC_PLAY_STORE_URL` | Google Play のアプリURL |

2. 再デプロイ

---

## 8. 審査員用テストアカウント

両ストアとも、審査員がログインできるアカウントが必要です。
審査員はストア連携（APIキー登録）ができないので、**レビューを投入済みのアカウント**を用意します。

```bash
npm run test:pipeline -- --email reviewer@example.com --keep
```

（ローカルで `npm run dev` を起動した状態で実行します）

備考欄に記載する文面:

```
テストアカウント: reviewer@example.com / <パスワード>

このアカウントにはサンプルのレビューデータを投入済みです。
本アプリは、利用者ご自身が権限を持つ App Store Connect / Google Play Console の
APIキーを登録して、自分のアプリのレビューを取得・返信するツールです。
審査用アカウントではストア連携を行えないため、あらかじめデータを用意しています。

サブスクリプションの購入は、iOS では Sandbox アカウント、
Android では内部テスターアカウントでご確認いただけます。
```

---

## 9. リリース前の最終確認

### サーバー
- [x] `supabase/schema.sql` を本番DBで実行した（2026-09-07 完了）
- [x] Supabase の Site URL / Redirect URLs を本番URLにした（2026-10-09 更新）
- [x] 古い `https://revpilot-app.vercel.app/reset-password` をリダイレクト許可リストから削除した（2026-10-10）
- [x] Cloudflare Workers にデプロイした（2026-10-09 / `app.revpilot-jp.workers.dev`）
- [x] シークレット10件を Workers に投入した（2026-10-09）
- [x] `ENABLE_WEB_APP` が**未設定**（`/dashboard` が404になることを本番で確認済み）
- [x] `IAP_DEV_TRUST_CLIENT` が**未設定**（Workers のシークレットにも vars にも無い）
- [x] `/`, `/pricing`, `/terms`, `/privacy`, `/tokushoho` が本番で開ける（2026-10-09 確認）
- [x] GitHub シークレット3件（`REVPILOT_CRON_URL` / `REVPILOT_WEEKLY_URL` / `REVPILOT_CRON_SECRET`）を設定した（2026-10-10）
- [ ] **`.github/workflows/` を develop に push する**（最重要・未着手）
      `poll.yml` / `weekly.yml` はローカルにあるだけでコミットされていない（`git ls-tree -r HEAD` に `.github/` が無い）。
      つまり**毎時ポーリングは現在1度も動いていない**。シークレット3件を入れても、
      ワークフロー本体が GitHub 上に無ければ何も起きない。
      なお GitHub の `schedule:` は**既定ブランチでしか発火しない**。このリポジトリの既定ブランチは `develop` なので、
      develop に push すれば条件を満たす（2026-10-10 に `git remote show origin` で確認）。
- [ ] push 後に GitHub Actions の `Poll store reviews` を手動実行して各アプリ 200 が返った
      （エンドポイント自体は 2026-10-10 に curl で確認済み：認証なし 401 / 認証あり 200・対象7アプリ）
- [ ] `RESEND_API_KEY` / `RESEND_FROM` を取得して投入する（**未取得・リリース阻害**）
      未設定だと `lib/notify.ts:104` が黙って `false` を返し、メールは1通も出ない。
      ところが `docs/store-listing.md:66` は Pro の特典に「週次サマリー」、同:46 は通知先に「メール」と書いている。
      → **有料機能が動かないまま出荷することになる**。

      【2026-10-10 判明：独自ドメインが要る】
      Resend は「送信するには最低1つのドメインを追加・認証する必要がある」としており、
      未認証のうちは `onboarding@resend.dev` から **Resend アカウント自身のメールアドレス宛にしか送れない**
      （他人宛は 403 `You can only send testing emails to your own email address`）。
      RevPilot は `app.revpilot-jp.workers.dev` を使っていて独自ドメインを持っていないため、
      **現状のままでは利用者宛の週次サマリーは送れない**。

      切り分け：
      - **障害通知（`OPERATOR_ALERT_EMAIL=revpilot.hq@gmail.com` 宛）だけ**なら、
        revpilot.hq@gmail.com で Resend に登録し `RESEND_FROM=onboarding@resend.dev` にすれば
        ドメイン無し・無料で動く（宛先が自分自身なので403にならない）。
      - **利用者宛の週次サマリー**は独自ドメインの取得と DNS 認証が必須。
        → ドメインを買う（Cloudflare Registrar 等）か、掲載文から「週次サマリー」「メール」を外すかの判断。

      なお `app/api/cron/weekly/route.ts:83` は送信失敗時に `weekly_summary_sent_at` を更新しないため、
      後から設定すれば取りこぼしは自動で回収される（データ欠損は起きない）。
- [x] 公開ページの死活監視を毎時のワークフローに入れた（`Check public pages`。`/`・法務3種・`/pricing` が 200 以外ならGitHubから通知メールが届く）
- [ ] 通知が来たら Workers Paid（$5/月）に上げる（ダッシュボードのプラン変更のみ。コード・`wrangler.jsonc`・再デプロイは不要。2-2 参照）

### Apple
- [x] **有料アプリ契約のステータスが「有効」になった**（2026-09-07 完了）
- [x] DSA トレーダー申告：トレーダーを選択し、連絡先（住所・+81 8036447313・revpilot.hq@gmail.com）を送信、
      メール確認コードまで通過した（2026-10-10）
- [ ] DSA トレーダー申告の**確認書類をアップロードする**（氏名／住所などを証明するビジネス文書または裁判所文書。
      PDF・JPEG・PNG、10MBまで。書類の言語は「日本語」を選択済み）
      ※ アプリ情報の「App Storeの規制と許可 → デジタルサービス法 → 開始する」は**独立したフォームではない**。
        リンク先は `/business?collectContactInfo=true` で、アカウントレベルの同じ画面に戻るだけ
        （2026-10-10 に実際に遷移して確認）。アプリ側の表示はアカウント側の申告が確定すれば追従するため、
        やることは上の「確認書類のアップロード」だけ。
- [ ] App のプライバシーの「公開」を押す（**押す前に申告内容の精査が必要**）
      現在8種類を申告しているが、`mobile/pubspec.yaml` に Crashlytics / Firebase Analytics / Sentry は無く、
      `mobile/lib/` に該当コードも無い。「クラッシュデータ」「パフォーマンスデータ」「その他の診断データ」
      「その他の使用状況データ（アナリティクス）」の4つは実態より広い申告になっている。
      過大申告は審査では落ちないが、プロダクトページのプライバシー表示が実態より悪く見える。
- [x] App ID の **Push Notifications** にチェックが入っている（2026-09-07 完了）
- [ ] サブスク2商品を「提出準備完了」にする（現在は**提出準備中**）
      `jp.revpilot.app.pro.monthly` / `jp.revpilot.app.max.monthly` とも、価格・表示名と説明・税カテゴリは設定済み。
      **不足しているのは「審査に関する情報」のスクリーンショットだけ**（2026-10-10 確認）。
- [x] `APPLE_IAP_*` を Cloudflare Workers のシークレットに設定した（2026-10-09 完了）
- [x] サーバー通知 V2 のURLを本番・サンドボックスの両方に設定した
      （2026-10-10 に `https://app.revpilot-jp.workers.dev/api/billing/iap/apple/notifications` へ修正。
        それまで両方とも死んだ Vercel の URL を指していた）
- [x] プライバシーポリシーURLを `https://app.revpilot-jp.workers.dev/privacy` にした（2026-10-10。Vercel から修正）
- [x] サポートURL／マーケティングURLを `https://app.revpilot-jp.workers.dev/` にした（2026-10-10。Vercel から修正）
- [x] Small Business Program に申請した（2026-09-07 送信・結果待ち）

### Google
> **Android 対応の下地は済んでいる**（2026-10-10 点検）。iOS を先に出しても出戻りは出ない想定。
> - `applicationId` / `namespace` = `jp.revpilot.app`（iOSのバンドルIDおよび `GOOGLE_PLAY_PACKAGE_NAME` と一致）
> - Firebase は `mobile/lib/push.dart:59` で `FirebaseOptions` を明示して初期化しているので、
>   `google-services.json` は不要（実際に置いていないし、`com.google.gms.google-services` プラグインも入れていない）。
>   Android 用の API キーと App ID は `mobile/config/app_config*.json` に既に入っている。
> - `AndroidManifest.xml` に `POST_NOTIFICATIONS`（Android 13+）と `com.android.vending.BILLING` を宣言済み。
> - リリース署名は `hasReleaseKeystore` で分岐済み（キーストアが無ければ debug 署名にフォールバック）。
> - サーバー側は `lib/iap-google.ts` / `lib/googleplay.ts` と
>   `/api/billing/iap/google`・`/api/billing/iap/google/notifications` が実装済みで、
>   未設定時は 501 と「Android課金は現在ご利用いただけません」を返す（iOSを壊さない作りになっている）。
>
> **唯一の落とし穴**（2026-10-10 に修正済み）: Android課金が読むのは
> `GOOGLE_PLAY_IAP_SERVICE_ACCOUNT_JSON` で、廃止済みの `GOOGLE_SERVICE_ACCOUNT_JSON` とは**別物**。
> 前者が `scripts/cf-secrets.sh` の投入対象から漏れていたため追加した。
> Android に着手するときは `.env.local` に `GOOGLE_PLAY_IAP_SERVICE_ACCOUNT_JSON` を入れてから
> `bash scripts/cf-secrets.sh` を実行すること（空の値はスクリプトが自動で飛ばす）。

- [ ] 定期購入2つと基本プランが「有効」
- [ ] サービスアカウントに「財務データ」権限がある
- [ ] RTDN のテスト通知が届いた
- [ ] クローズドテスト（12人×14日）の要件を確認し、必要なら開始した

### プッシュ通知
- [x] `FIREBASE_SERVICE_ACCOUNT_JSON` を Workers に設定した（`wrangler secret list` で確認済み）
- [x] Firebase Cloud Messaging API (V1) が**有効**／レガシーAPIは無効、送信者ID 853072258337、
      APNs 認証キー 7946K3ULZ2（Team F77Y83KNC7）が開発用・本番用とも登録済み（2026-10-10 確認）
- [x] `mobile/config/app_config.json` に `FIREBASE_*` を6つとも書いた（2026-09-07 完了）
- [x] Firebase に APNs 認証キーを登録した（2026-09-07 完了）
- [ ] **アプリを終了した状態**でテスト通知が iOS / Android の両方に届いた

### アプリ
- [ ] リリースビルドに `config/app_config.prod.json` を指定した（開発用と取り違えていない）
- [ ] `pubspec.yaml` のビルド番号を上げた
- [ ] 実機で「購入 → プランが変わる → ストアで解約 → 数分後にFreeへ戻る」を通した
- [ ] 掲載文と実装が一致している（`docs/store-listing.md` の「書かないこと」を確認）
