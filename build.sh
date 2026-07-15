#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h}"
BUILD="$ROOT/build"
APP="$BUILD/Release/Codex 用量.app"
EXT="$APP/Contents/PlugIns/CodexUsageWidgetExtension.appex"
DIST="$ROOT/dist"

DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" \
  xcodebuild \
    -project "$ROOT/CodexUsageWidget.xcodeproj" \
    -target "Codex Usage" \
    -configuration Release \
    SYMROOT="$BUILD" \
    OBJROOT="$BUILD/obj" \
    CODE_SIGNING_ALLOWED=NO \
    build

codesign --force --sign - --entitlements "$ROOT/CodexUsageWidget.entitlements" "$EXT"
codesign --force --sign - --entitlements "$ROOT/CodexUsage.entitlements" "$APP"
codesign --verify --deep --strict "$APP"

mkdir -p "$DIST"
ditto -c -k --norsrc --keepParent "$APP" "$DIST/Codex-Usage-macOS.zip"
echo "$DIST/Codex-Usage-macOS.zip"
