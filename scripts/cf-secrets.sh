#!/usr/bin/env bash
#
# .env.local の秘密値を Cloudflare Workers のシークレットへ投入する。
#
#   使い方: bash scripts/cf-secrets.sh
#   前提:   npx wrangler login 済み / Worker("app") がデプロイ済み
#
# 【入れないもの】
#   - wrangler.jsonc の "vars" に既にある公開可の値（二重管理を避ける）
#   - STRIPE_*            … Web決済は提供していない
#   - IAP_DEV_TRUST_CLIENT … 開発専用。本番で true にすると課金を踏み倒せる
#   - ASC_* / LINE_* / NOTIFY_EMAIL_TO … 廃止済み
#   - GOOGLE_SERVICE_ACCOUNT_JSON … 廃止済み。Android課金が使うのは
#     GOOGLE_PLAY_IAP_SERVICE_ACCOUNT_JSON（別物・上のKEYSに入れてある）。名前が紛らわしいので注意
#   - 値が空のもの（RESEND_* など未取得のもの）
#
set -euo pipefail
cd "$(dirname "$0")/.."

[ -f .env.local ] || { echo ".env.local がありません" >&2; exit 1; }

KEYS=(
  SUPABASE_SERVICE_ROLE_KEY
  NEXT_PUBLIC_SUPABASE_ANON_KEY
  ANTHROPIC_API_KEY
  APP_ENCRYPTION_KEY
  CRON_SECRET
  APPLE_IAP_ISSUER_ID
  APPLE_IAP_KEY_ID
  APPLE_IAP_PRIVATE_KEY
  FIREBASE_SERVICE_ACCOUNT_JSON
  GOOGLE_RTDN_SECRET
  GOOGLE_PLAY_IAP_SERVICE_ACCOUNT_JSON
  RESEND_API_KEY
  RESEND_FROM
)

# .env.local を Node に解釈させて JSON を作る（引用符や \n を含む値を壊さないため）。
TMP="$(mktemp -t cfsecrets)"
trap 'rm -f "$TMP"' EXIT

node --env-file=.env.local -e '
const keys = process.argv.slice(1);
const out = {};
for (const k of keys) {
  const v = process.env[k];
  if (v !== undefined && v !== "") out[k] = v;
}
process.stdout.write(JSON.stringify(out));
' "${KEYS[@]}" > "$TMP"

echo "投入するシークレット:"
node -e 'const o=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));for(const k of Object.keys(o))console.log("  - "+k+" ("+o[k].length+"文字)");' "$TMP"

npx wrangler secret bulk "$TMP"

echo
echo "完了。確認: npx wrangler secret list"
