#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if ! grep -q "enable-swift-package-manager: false" "$repo_root/pubspec.yaml"; then
  echo "pubspec.yaml must disable Flutter Swift Package Manager for Apple CI builds"
  exit 1
fi

if ! grep -q "_SILENCE_EXPERIMENTAL_COROUTINE_DEPRECATION_WARNINGS" "$repo_root/windows/CMakeLists.txt"; then
  echo "windows/CMakeLists.txt must suppress MSVC experimental coroutine deprecation errors"
  exit 1
fi

if ! awk '/--apple-only\)/,/shift/' "$repo_root/build.sh" | grep -q "PARALLEL_BUILD=false"; then
  echo "build.sh must run Apple builds sequentially to avoid CocoaPods/header generation races"
  exit 1
fi

android_workflow="$repo_root/.github/workflows/android-release.yml"

if [ ! -f "$android_workflow" ]; then
  echo "Android release workflow is missing"
  exit 1
fi

# APK 必须用固定密钥签名，否则每次构建签名都不同，用户装新版要先卸载旧版。
if ! grep -q "ANDROID_KEYSTORE_BASE64" "$android_workflow"; then
  echo "Android workflow must sign with the stored release keystore"
  exit 1
fi

# 密钥和口令只能来自 Secrets，绝不能写进仓库。
if git -C "$repo_root" ls-files --error-unmatch android/key.properties >/dev/null 2>&1; then
  echo "android/key.properties must never be committed"
  exit 1
fi

if git -C "$repo_root" ls-files | grep -qE '\.(jks|keystore)$'; then
  echo "keystore files must never be committed"
  exit 1
fi

# 发 Release 才有公开直链，Artifact 要登录才能下。
if ! grep -q "action-gh-release" "$android_workflow"; then
  echo "Android workflow must publish APKs to a GitHub Release"
  exit 1
fi
