#!/bin/bash
# 使用独立签名宿主验证书签；参数原样传给 swift test。
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/xnook-bookmark-regression.XXXXXX")"
trap 'rm -rf -- "$WORK_DIR"' EXIT

APP_BUNDLE="$WORK_DIR/BookmarkRegression.app"
CONTENTS="$APP_BUNDLE/Contents"
HELPER="$CONTENTS/MacOS/BookmarkRegression"
mkdir -p "$CONTENTS/MacOS"

cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>com.meteorkid.xnook.bookmark-regression</string>
    <key>CFBundleExecutable</key><string>BookmarkRegression</string>
    <key>CFBundleName</key><string>BookmarkRegression</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

cd "$REPO_ROOT"
xcrun swiftc -swift-version 5 -O \
    -sdk "$(xcrun --show-sdk-path)" -target "$(uname -m)-apple-macosx14.0" \
    -module-name BookmarkRegression \
    Sources/XNook/Features/GifResource.swift \
    Sources/XNook/Localization/L10n.swift \
    Sources/XNook/Localization/L10n+Gif.swift \
    Tests/BookmarkRegression/main.swift \
    -o "$HELPER"

# 只签名本脚本创建的 app；两个测试进程复用同一份二进制和签名。
codesign --force --sign - --options runtime --entitlements XNook.entitlements "$APP_BUNDLE"
codesign --verify --strict --verbose=2 "$APP_BUNDLE"
export XNOOK_BOOKMARK_HELPER="$HELPER"
swift test "$@"
