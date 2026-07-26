#!/usr/bin/env bash
# 設定ファイルを注入してRevPilot Mobileを起動する。
#
# ワイヤレスiOS実機は検出に時間がかかるため --device-timeout を延長し、
# 実機が複数見えても迷わないよう iOS実機を自動選択して -d を付ける。
# デバイスを明示したい場合は `./run.sh -d <id>` のように渡せば自動選択は無効になる。
set -e
cd "$(dirname "$0")"
export PATH="$PATH:/Users/yutatomatsu/Documents/sdk/flutter/bin"
# CocoaPods(Ruby 3.4系)がUTF-8ロケールを要求するため保険で設定
export LANG=${LANG:-en_US.UTF-8}
export LC_ALL=${LC_ALL:-en_US.UTF-8}

TIMEOUT=30

# 引数に -d / --device-id が無ければ iOS実機を自動選択
if [[ "$*" != *"-d"* && "$*" != *"--device-id"* ]]; then
  DEVICE_ID=$(flutter devices --machine --device-timeout "$TIMEOUT" 2>/dev/null | python3 -c '
import sys, json
try:
    ds = json.load(sys.stdin)
except Exception:
    ds = []
ios = [d for d in ds if str(d.get("targetPlatform", "")).startswith("ios") and not d.get("emulator", False)]
print(ios[0]["id"] if ios else "")
' 2>/dev/null)
  if [[ -n "$DEVICE_ID" ]]; then
    echo "▶ iOS実機を自動選択: $DEVICE_ID"
    set -- -d "$DEVICE_ID" "$@"
  else
    echo "⚠ iOS実機が見つかりませんでした（iPhoneのロック解除・同一Wi-Fi・開発者モードを確認）。"
  fi
fi

# 開発サーバーのURLを現在のLAN IPへ自動更新（DHCPでIPが変わっても実機から到達可能に）。
IP=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || true)
if [[ -n "$IP" ]]; then
  python3 - "$IP" <<'PY'
import json, sys
p = "config/app_config.json"
d = json.load(open(p))
url = f"http://{sys.argv[1]}:3000"
if d.get("API_BASE_URL") != url:
    d["API_BASE_URL"] = url
    json.dump(d, open(p, "w"), ensure_ascii=False, indent=2)
    print(f"▶ API_BASE_URL を {url} に更新しました")
PY
fi

exec flutter run --device-timeout "$TIMEOUT" --dart-define-from-file=config/app_config.json "$@"
