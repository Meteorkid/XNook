#!/bin/bash
# Build script for X Nook app bundle

set -e

APP_NAME="X Nook"
BUILD_DIR=".build"
APP_BUNDLE="${BUILD_DIR}/${APP_NAME}.app"
CONTENTS="${APP_BUNDLE}/Contents"
MACOS="${CONTENTS}/MacOS"
RESOURCES="${CONTENTS}/Resources"

echo "Building ${APP_NAME}..."

# Build the executable
swift build -c release 2>&1

# Create app bundle structure
mkdir -p "${MACOS}"
mkdir -p "${RESOURCES}"

# Copy executable
cp "${BUILD_DIR}/release/XNook" "${MACOS}/${APP_NAME}"

# Copy and process Info.plist (replace placeholders)
sed -e "s/\$(EXECUTABLE_NAME)/${APP_NAME}/g" \
    -e "s/\$(PRODUCT_BUNDLE_IDENTIFIER)/com.meteorkid.xnook/g" \
    -e "s/\$(MACOSX_DEPLOYMENT_TARGET)/14.0/g" \
    "Info.plist" > "${CONTENTS}/Info.plist"

# Copy icon if exists
if [ -f "Resources/AppIcon.icns" ]; then
    cp "Resources/AppIcon.icns" "${RESOURCES}/AppIcon.icns"
fi

# Re-sign the complete bundle after adding Info.plist and resources.
codesign --force --deep --sign - "${APP_BUNDLE}"

echo "App bundle created at: ${APP_BUNDLE}"
echo "To run: open '${APP_BUNDLE}'"

# 打包 DMG（可选，用于发布）
if [[ "${XNOOK_BUILD_DMG:-0}" == "1" ]]; then
    echo ""
    echo "==> Packaging DMG..."

    # 从 Info.plist 读取版本号
    VERSION=$(grep -A1 "CFBundleShortVersionString" "${CONTENTS}/Info.plist" | grep string | sed 's/.*<string>\(.*\)<\/string>.*/\1/')
    DMG_FILENAME="XNook-${VERSION}.dmg"
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
