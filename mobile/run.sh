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

exec flutter run --device-timeout "$TIMEOUT" --dart-define-from-file=config/app_config.json "$@"
