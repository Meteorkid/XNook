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
