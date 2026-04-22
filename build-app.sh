#!/bin/zsh
# Builds MouseHelper as a proper macOS .app bundle.
#
# The .app bundle gives a stable identity for Accessibility permissions,
# so you only need to grant access once (survives rebuilds thanks to
# ad-hoc code signing with a stable bundle identifier).
#
# Usage:
#   chmod +x build-app.sh
#   ./build-app.sh
#
# The resulting app is placed at: ./build/MouseHelper.app

set -euo pipefail

APP_NAME="MouseHelper"
BUILD_DIR="build"
APP_BUNDLE="${BUILD_DIR}/${APP_NAME}.app"
CONTENTS_DIR="${APP_BUNDLE}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"

echo "🔨 Building ${APP_NAME}..."
swift build -c release

echo "📦 Creating app bundle..."
rm -rf "${APP_BUNDLE}"
mkdir -p "${MACOS_DIR}"

# Copy binary
cp ".build/release/${APP_NAME}" "${MACOS_DIR}/${APP_NAME}"

# Copy Info.plist
cp Info.plist "${CONTENTS_DIR}/Info.plist"

# Ad-hoc code sign — gives the app a stable identity tied to its
# bundle identifier (com.mousehelper.app). macOS will remember
# Accessibility permissions across rebuilds as long as the identifier
# and signature remain consistent.
echo "🔏 Code signing..."
codesign --force --sign - --identifier com.mousehelper.app "${APP_BUNDLE}"

echo ""
echo "✅ Built: ${APP_BUNDLE}"
echo ""
echo "To install, copy to Applications:"
echo "  cp -r ${APP_BUNDLE} /Applications/"
echo ""
echo "Then open it:"
echo "  open /Applications/${APP_NAME}.app"
echo ""
echo "On first launch, macOS will prompt for Accessibility access."
echo "Grant it once — it persists across rebuilds."
