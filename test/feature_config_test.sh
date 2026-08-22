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

if ! grep -q "worker_proxy_url" \
  "$repo_root/lib/services/user_data_service.dart"; then
  echo "Cloudflare Worker proxy must be a persisted preference"
  exit 1
fi

if ! grep -q "Cloudflare Worker 代理加速" "$repo_root/lib/widgets/user_menu.dart"; then
  echo "settings must expose the Cloudflare Worker proxy input"
  exit 1
fi

# 画中画只能手动触发：自动进入会在播放页留下常驻 AVPlayerLayer，表现为下方黑块。
if grep -q "willResignActiveNotification" \
  "$repo_root/ios/Runner/AppDelegate.swift"; then
  echo "iOS must not auto-enter Picture in Picture"
  exit 1
fi

if ! grep -q "hostLayerSize" "$repo_root/ios/Runner/AppDelegate.swift"; then
  echo "iOS PiP host layer must stay tiny so it cannot cover the Flutter view"
  exit 1
fi

if ! grep -q "DownloadScreen" "$repo_root/lib/screens/home_screen.dart"; then
  echo "bottom navigation must include the local download category"
  exit 1
fi

if ! grep -q "EXT-X-KEY" "$repo_root/lib/services/hls_downloader.dart"; then
  echo "downloader must handle AES-128 encrypted m3u8 playlists"
  exit 1
fi

if ! grep -q "enum DownloadFormat" "$repo_root/lib/services/hls_downloader.dart"; then
  echo "downloads must offer both TS and MP4 output"
  exit 1
fi

# 短剧频道必须走跟电影、剧集相同的采集源，不能只依赖主站 /api/shortdrama/*。
if ! grep -q "ShortDramaSourceService" \
  "$repo_root/lib/screens/short_drama_screen.dart"; then
  echo "short drama channel must read from the shared video sources"
  exit 1
fi

if ! grep -q "ac=videolist" \
  "$repo_root/lib/services/short_drama_source_service.dart"; then
  echo "short drama source service must use the CMS videolist API"
  exit 1
fi

if ! grep -q "rog.v200ddbot.tv" \
  "$repo_root/ios/Runner.xcodeproj/project.pbxproj"; then
  echo "iOS bundle identifier must be rog.v200ddbot.tv"
  exit 1
fi

if ! grep -q "^version: 4\." "$repo_root/pubspec.yaml"; then
  echo "app version must be 4.x"
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

# 全屏只能给一个横屏方向：两个都给的话系统按重力自己挑，挑反了画面就是倒的，
# 而且切换瞬间会多重排一次（用户看到的「闪一下」）。
if ! grep -q "setPreferredOrientations(\[_direction.orientation\])" \
  "$repo_root/lib/utils/orientation_utils.dart"; then
  echo "fullscreen must lock exactly one landscape orientation"
  exit 1
fi

# 方向做成可切换的设置项，方向反了不用重新打包。
if ! grep -q "enum LandscapeDirection" \
  "$repo_root/lib/utils/orientation_utils.dart"; then
  echo "landscape direction must be configurable"
  exit 1
fi

if ! grep -q "saveLandscapeDirection" \
  "$repo_root/lib/widgets/user_menu.dart"; then
  echo "settings must expose the landscape direction switch"
  exit 1
fi

# 观影房服务器在握手时就校验 auth.token，不带 token 会被 emit('error') + 断开，
# 表现就是界面显示已连接但创建房间毫无反应。
if ! grep -q "setAuth({'token': authKey})" \
  "$repo_root/lib/services/watch_room_service.dart"; then
  echo "watch room socket must send the auth token during the handshake"
  exit 1
fi

# 地址和密钥都必须来自主站 /api/watch-room/config，不能写死在 App 里。
if ! grep -q "/api/watch-room/config" \
  "$repo_root/lib/services/watch_room_service.dart"; then
  echo "watch room config must come from the site API"
  exit 1
fi

if grep -q "watch-room-server-production" \
  "$repo_root/lib/screens/watch_room_screen.dart"; then
  echo "watch room server URL must not be hardcoded in the UI"
  exit 1
fi

# 网页版有创建 / 加入 / 房间列表三个页签，App 要对齐。
for tab in '创建房间' '加入房间' '房间列表'; do
  if ! grep -q "$tab" "$repo_root/lib/screens/watch_room_screen.dart"; then
    echo "watch room screen must provide the $tab tab"
    exit 1
  fi
done

# 房主不发心跳的话服务器 30 秒清播放状态、5 分钟删房间。
if ! grep -q "startHeartbeat" \
  "$repo_root/lib/screens/watch_room_screen.dart"; then
  echo "joining a room must start the heartbeat"
  exit 1
fi

# 切到底栏的电影页再播放时，观影房页面不能被 PageView 回收；否则 dispose
# 会断开 socket，房主是最后一名成员时服务器会立即删除房间。
if ! grep -q "AutomaticKeepAliveClientMixin<WatchRoomScreen>" \
  "$repo_root/lib/screens/watch_room_screen.dart"; then
  echo "watch room must stay alive while another bottom navigation page is open"
  exit 1
fi

if ! grep -q "bool get wantKeepAlive => true" \
  "$repo_root/lib/screens/watch_room_screen.dart"; then
  echo "watch room keep-alive must be enabled"
  exit 1
fi

if ! grep -q "super.build(context)" \
  "$repo_root/lib/screens/watch_room_screen.dart"; then
  echo "watch room build must register its keep-alive handle"
  exit 1
fi

# 退出播放页要恢复竖屏，否则回到首页会卡在横屏。
if ! grep -q "OrientationUtils.lockPortrait" \
  "$repo_root/lib/screens/player_screen.dart"; then
  echo "leaving the player must restore portrait"
  exit 1
fi

# 旋转修正必须先读元数据角度，无条件写 video-rotate 会导致开播闪屏。
if ! grep -q "video-params/rotate" \
  "$repo_root/lib/widgets/video_player_widget.dart"; then
  echo "rotation fix must inspect the real metadata angle first"
  exit 1
fi

if ! grep -q "onExitFullscreen" \
  "$repo_root/lib/widgets/video_player_widget.dart"; then
  echo "player must override the media_kit fullscreen orientation defaults"
  exit 1
fi

# 点全屏必须真的转横屏；只放开旋转是不够的，手机竖着拿就不会转。
if ! grep -q "OrientationUtils.forceLandscape" \
  "$repo_root/lib/widgets/video_player_widget.dart"; then
  echo "entering fullscreen must rotate to landscape"
  exit 1
fi

if ! grep -q "static Future<void> forceLandscape" \
  "$repo_root/lib/utils/orientation_utils.dart"; then
  echo "orientation utils must expose a landscape helper"
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
