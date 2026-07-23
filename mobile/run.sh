#!/usr/bin/env bash
# 設定ファイルを注入してRevPilot Mobileを起動する。
set -e
cd "$(dirname "$0")"
export PATH="$PATH:/Users/yutatomatsu/Documents/sdk/flutter/bin"
flutter run --dart-define-from-file=config/app_config.json "$@"
