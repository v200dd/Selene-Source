#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if ! grep -q "https://cf.motv.200996.xyz" \
  "$repo_root/lib/services/user_data_service.dart"; then
  echo "default server URL is not configured"
  exit 1
fi

if ! grep -q "更换地址" "$repo_root/lib/screens/login_screen.dart"; then
  echo "login screen must offer a collapsed server URL switcher"
  exit 1
fi

if ! grep -q "_showServerUrlField" "$repo_root/lib/screens/login_screen.dart"; then
  echo "login screen must keep the server URL field hidden by default"
  exit 1
fi

if grep -q "_serverUrlController.text =\s*$" \
  "$repo_root/lib/screens/login_screen.dart" && \
  grep -q "userData\['serverUrl'\] ?? UserDataService.defaultServerUrl" \
  "$repo_root/lib/screens/login_screen.dart"; then
  echo "login screen must never prefill the built-in default server URL"
  exit 1
fi

if ! grep -q "/api/danmu-external" \
  "$repo_root/lib/services/danmaku_service.dart"; then
  echo "danmaku service must read danmaku from the user's own site endpoint"
  exit 1
fi

if ! grep -q "auto_pip_enabled" \
  "$repo_root/lib/services/user_data_service.dart"; then
  echo "auto Picture in Picture must be a persisted preference"
  exit 1
fi

if ! grep -q "willResignActiveNotification" \
  "$repo_root/ios/Runner/AppDelegate.swift"; then
  echo "iOS must enter Picture in Picture when leaving for the home screen"
  exit 1
fi

if ! grep -q "/api/shortdrama/list" \
  "$repo_root/lib/services/short_drama_service.dart"; then
  echo "short drama service must use the site shortdrama endpoints"
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

if ! grep -q "Selene-iOS-unsigned.ipa" "$workflow"; then
  echo "iOS workflow must package an unsigned IPA"
  exit 1
fi

if ! grep -q "Payload/tv.app/" "$workflow"; then
  echo "iOS workflow must verify the IPA Payload/tv.app structure"
  exit 1
fi

if ! grep -q "softprops/action-gh-release" "$workflow"; then
  echo "iOS workflow must publish the IPA to a GitHub Release"
  exit 1
fi
