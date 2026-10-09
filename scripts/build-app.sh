#!/bin/bash
# Builds "PDF Editor.app" from the Swift package and ad-hoc signs it.
# Usage: scripts/build-app.sh [release|debug]
# Optional environment: VERSION (e.g. 1.0.42) and BUILD_NUMBER (e.g. 42).
set -euo pipefail

cd "$(dirname "$0")/.."
CONFIG="${1:-release}"

swift build -c "$CONFIG" --product PDFEditor
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

APP="build/PDF Editor.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/PDFEditor" "$APP/Contents/MacOS/PDFEditor"
cp Support/Info.plist "$APP/Contents/Info.plist"

# App icon: iconutil turns the asset catalog PNGs into an .icns file.
ICONSET="build/AppIcon.iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
cp Support/Assets.xcassets/AppIcon.appiconset/icon_*.png "$ICONSET/"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

if [ -n "${VERSION:-}" ]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
fi
if [ -n "${BUILD_NUMBER:-}" ]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"
fi

# Copy SwiftPM resource bundles, if any target declares resources.
shopt -s nullglob
for bundle in "$BIN_DIR"/*.bundle; do
    cp -R "$bundle" "$APP/Contents/Resources/"
done

codesign --force --deep --sign - "$APP"
echo "Built $APP"
