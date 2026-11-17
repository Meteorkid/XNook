#!/bin/bash
# Build script for X Nook app bundle

set -e

APP_NAME="X Nook"
BUILD_DIR="${XNOOK_BUILD_DIR:-.build}"
APP_BUNDLE="${BUILD_DIR}/${APP_NAME}.app"
CONTENTS="${APP_BUNDLE}/Contents"
MACOS="${CONTENTS}/MacOS"
RESOURCES="${CONTENTS}/Resources"

# 从 VERSION 文件读取版本号（单一版本源）
VERSION=$(cat "$(dirname "$0")/VERSION" | tr -d '[:space:]')

echo "Building ${APP_NAME} v${VERSION}..."

# Build the executable
swift build --scratch-path "${BUILD_DIR}" -c release "$@" 2>&1

# Create app bundle structure
mkdir -p "${MACOS}"
mkdir -p "${RESOURCES}"
cp "scripts/claude-stop-hook.py" "${RESOURCES}/claude-stop-hook.py"

# Copy executable
cp "${BUILD_DIR}/release/XNook" "${MACOS}/${APP_NAME}"

# MediaRemote 桥接：由 /usr/bin/perl 加载的动态库与脚本。
# ad-hoc 签名的 app 进程读取 MediaRemote 会被系统返回空，
# Apple 平台签名的 perl 具备访问权，故经此桥接读写系统播放中心。
MR_HELPER="${RESOURCES}/MediaRemoteBridge"
mkdir -p "${MR_HELPER}"
MR_DYLIB="${BUILD_DIR}/release/libCMediaRemote.dylib"
if [[ ! -f "${MR_DYLIB}" ]]; then
    echo "ERROR: libCMediaRemote.dylib not found at ${MR_DYLIB}" >&2
    exit 1
fi
cp "${MR_DYLIB}" "${MR_HELPER}/libCMediaRemote.dylib"
cp "Sources/XNook/Resources/MediaRemoteBridge/run.pl" "${MR_HELPER}/run.pl"
chmod +x "${MR_HELPER}/run.pl"

# Copy and process Info.plist (replace placeholders)
sed -e "s/\$(EXECUTABLE_NAME)/${APP_NAME}/g" \
    -e "s/\$(PRODUCT_BUNDLE_IDENTIFIER)/com.meteorkid.xnook/g" \
    -e "s/\$(MACOSX_DEPLOYMENT_TARGET)/14.0/g" \
    -e "s/\$(MARKETING_VERSION)/${VERSION}/g" \
    "Info.plist" > "${CONTENTS}/Info.plist"

# 公钥随构建注入；私钥仅由网站签发服务持有。
python3 - "${CONTENTS}/Info.plist" <<'PY'
import base64
import os
import plistlib
import sys

public_key = os.environ.get("SOFTWARE_LICENSE_PUBLIC_KEY", "").strip()
if public_key:
    try:
        raw = base64.b64decode(public_key, validate=True)
    except ValueError as error:
        raise SystemExit("SOFTWARE_LICENSE_PUBLIC_KEY must be raw Ed25519 public key in Base64") from error
    if len(raw) != 32 or not any(raw):
        raise SystemExit("SOFTWARE_LICENSE_PUBLIC_KEY must contain a non-placeholder 32-byte public key")
elif os.environ.get("XNOOK_BUILD_DMG", "0") == "1":
    raise SystemExit("Cannot package a paid release without SOFTWARE_LICENSE_PUBLIC_KEY")
with open(sys.argv[1], "rb") as stream:
    info = plistlib.load(stream)
info["SoftwareLicenseAPIBaseURL"] = "https://www.imagentx.top"
if public_key:
    info["SoftwareLicensePublicKey"] = public_key
with open(sys.argv[1], "wb") as stream:
    plistlib.dump(info, stream)
PY

# Copy icon if exists
if [ -f "Resources/AppIcon.icns" ]; then
    cp "Resources/AppIcon.icns" "${RESOURCES}/AppIcon.icns"
fi

ENTITLEMENTS="$(dirname "$0")/XNook.entitlements"

# 稳定签名身份。ad-hoc 签名（-s -）的 designated requirement 是 cdhash，
# 每次重建都会变，macOS 会把新二进制当成另一个应用，已授权的 TCC 记录随即失效
# （系统设置里的开关仍然是打开的，但应用读不到权限）。
# 有本地自签名身份时优先用它，requirement 变成 certificate leaf，跨更新稳定。
SIGN_KEYCHAIN="${XNOOK_SIGN_KEYCHAIN:-$HOME/Library/Keychains/xnook-signing.keychain-db}"
SIGN_PASSWORD_FILE="${XNOOK_SIGN_PASSWORD_FILE:-$HOME/.xnook-signing/password}"
SIGN_IDENTITY=""
if [[ "${XNOOK_SIGN_ADHOC:-0}" != "1" && -f "${SIGN_KEYCHAIN}" ]]; then
    if [[ -f "${SIGN_PASSWORD_FILE}" ]]; then
        security unlock-keychain -p "$(cat "${SIGN_PASSWORD_FILE}")" "${SIGN_KEYCHAIN}" >/dev/null 2>&1 || true
    fi
    SIGN_IDENTITY="$(security find-identity -p codesigning "${SIGN_KEYCHAIN}" 2>/dev/null \
        | sed -n 's/.*"\(.*\)".*/\1/p' | head -1)"
fi

SIGN_ARGS=(--force --deep --entitlements "${ENTITLEMENTS}")
if [[ "${XNOOK_ENABLE_HARDENED_RUNTIME:-0}" == "1" ]]; then
    # Opt-in switch to validate the bundle behaves under Hardened Runtime.
    SIGN_ARGS+=(--options runtime)
fi

if [[ -n "${SIGN_IDENTITY}" ]]; then
    echo "Signing with stable identity: ${SIGN_IDENTITY}"
    ORIGINAL_KEYCHAINS="$(security list-keychains -d user | tr -d ' "')"
    # codesign 只在搜索列表里找身份，构建结束后立刻恢复，不改动用户的长期配置。
    security list-keychains -d user -s "${SIGN_KEYCHAIN}" ${ORIGINAL_KEYCHAINS}
    codesign "${SIGN_ARGS[@]}" --sign "${SIGN_IDENTITY}" --keychain "${SIGN_KEYCHAIN}" "${APP_BUNDLE}"
    security list-keychains -d user -s ${ORIGINAL_KEYCHAINS}
else
    echo "Signing ad-hoc. TCC 授权会在下次重建后失效；运行 scripts/setup-signing-identity.sh 可固定身份。"
    codesign "${SIGN_ARGS[@]}" --sign - "${APP_BUNDLE}"
fi

python3 "$(dirname "$0")/scripts/verify-app-permissions.py" "${APP_BUNDLE}"

echo "App bundle created at: ${APP_BUNDLE}"
echo "To run: open '${APP_BUNDLE}'"
echo "If /Applications/X Nook.app is already running, use: open -n '${APP_BUNDLE}'"

# 打包 DMG（可选，用于发布）
if [[ "${XNOOK_BUILD_DMG:-0}" == "1" ]]; then
    echo ""
    echo "==> Packaging DMG..."

    # 规范化版本号：去掉预发布后缀（如 -beta, -rc1）用于 DMG 文件名
    NORMALIZED_VERSION=$(echo "$VERSION" | sed -E 's/-[a-zA-Z0-9.]+$//')
    DMG_FILENAME="XNook-${NORMALIZED_VERSION}.dmg"
    DMG_PATH="${BUILD_DIR}/${DMG_FILENAME}"
    TEMP_DMG_DIR="${BUILD_DIR}/dmg-staging"

    # 清理临时目录
    rm -rf "${TEMP_DMG_DIR}" "${DMG_PATH}"
    mkdir -p "${TEMP_DMG_DIR}"

    # 复制 app 到临时目录
    cp -R "${APP_BUNDLE}" "${TEMP_DMG_DIR}/"

    # 创建 DMG
    hdiutil create -volname "X Nook" \
        -srcfolder "${TEMP_DMG_DIR}" \
        -ov -format UDZO \
        "${DMG_PATH}"

    # 清理临时目录
    rm -rf "${TEMP_DMG_DIR}"

    # 计算 SHA256
    SHA256=$(shasum -a 256 "${DMG_PATH}" | awk '{print $1}')

    echo ""
    echo "DMG created:"
    echo "  File:   ${DMG_PATH}"
    echo "  Size:   $(du -h "${DMG_PATH}" | cut -f1)"
    echo "  SHA256: ${SHA256}"
    echo ""
    echo "To upload to GitHub release:"
    echo "  gh release upload v${VERSION} ${DMG_PATH}"
fi
