#!/bin/bash
# Builds "PDF Editor.app" from the Swift package and ad-hoc signs it.
# Usage: scripts/build-app.sh [release|debug]
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

# Copy SwiftPM resource bundles, if any target declares resources.
shopt -s nullglob
for bundle in "$BIN_DIR"/*.bundle; do
    cp -R "$bundle" "$APP/Contents/Resources/"
done

codesign --force --deep --sign - "$APP"
echo "Built $APP"
