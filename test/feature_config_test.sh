#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if ! grep -q "https://cf.motv.200996.xyz" \
  "$repo_root/lib/services/user_data_service.dart"; then
  echo "default server URL is not configured"
  exit 1
fi

if grep -q "服务器地址" "$repo_root/lib/screens/login_screen.dart"; then
  echo "login screen must not show a server URL field"
  exit 1
fi

if grep -q "setPreferredOrientations" "$repo_root/lib/screens/player_screen.dart"; then
  echo "player screen must not force an orientation on entry"
  exit 1
fi

if ! grep -q "Platform.isAndroid || Platform.isIOS" \
  "$repo_root/lib/widgets/mobile_player_controls.dart"; then
  echo "mobile player must expose Picture in Picture on Android and iOS"
  exit 1
fi

if ! grep -q "DanmakuOverlay" "$repo_root/lib/widgets/video_player_widget.dart"; then
  echo "video player must include the danmaku overlay"
  exit 1
fi

workflow="$repo_root/.github/workflows/ios-unsigned.yml"
if ! grep -q "flutter build ios --release --no-codesign" "$workflow"; then
  echo "iOS workflow must build without code signing"
  exit 1
fi

if ! grep -q "actions/upload-artifact@v4" "$workflow"; then
  echo "iOS workflow must upload the app artifact"
  exit 1
fi

if ! grep -q "Selene-iOS-unsigned.app.zip" "$workflow"; then
  echo "iOS workflow must preserve the app bundle in a zip archive"
  exit 1
fi
