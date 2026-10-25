#!/usr/bin/env bash
# Requires macOS and Xcode 26+. Produces a genuine device app in an unsigned
# Payload IPA container. MUST be signed before installation on an iPhone.
set -euo pipefail
cd "$(dirname "$0")/.."
command -v xcodebuild >/dev/null || { echo '需要 macOS + Xcode 26+' >&2; exit 1; }
BUILD_DIR=build
ARCHIVE="$BUILD_DIR/SPlayerRemote.xcarchive"
mkdir -p "$BUILD_DIR"
xcodebuild -project SPlayerRemote.xcodeproj -scheme SPlayerRemote \
  -configuration Release -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY='' archive
APP="$ARCHIVE/Products/Applications/SPlayerRemote.app"
test -d "$APP"
# 必须包含嵌入的 Live Activity 扩展（PlugIns/*.appex）。
APPEX="$(find "$APP/PlugIns" -maxdepth 1 -name '*.appex' 2>/dev/null | head -1)"
if [ -z "$APPEX" ]; then
  echo '缺少嵌入的 Live Activity 扩展 (.appex)' >&2
  exit 1
fi
echo "已嵌入扩展：$APPEX"
rm -rf "$BUILD_DIR/Payload"
mkdir -p "$BUILD_DIR/Payload"
cp -R "$APP" "$BUILD_DIR/Payload/"
rm -f "$BUILD_DIR/SPlayerRemote-unsigned.ipa"
(cd "$BUILD_DIR" && zip -qry SPlayerRemote-unsigned.ipa Payload)
echo '已生成 build/SPlayerRemote-unsigned.ipa：未签名，必须另行签名，不能直接安装。'
echo '注意：安装到真机时 App 与其内嵌的 Live Activity 扩展都必须使用有效签名。'
