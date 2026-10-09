#!/bin/bash
# Packages build/PDF Editor.app into a compressed disk image with an
# Applications shortcut. Run scripts/build-app.sh first.
# Usage: scripts/make-dmg.sh [output.dmg]
set -euo pipefail

cd "$(dirname "$0")/.."
APP="build/PDF Editor.app"
VERSION="${VERSION:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")}"
OUTPUT="${1:-build/PDF-Editor-$VERSION.dmg}"

[ -d "$APP" ] || { echo "Missing $APP; run scripts/build-app.sh first" >&2; exit 1; }

STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

rm -f "$OUTPUT"
hdiutil create -volname "PDF Editor" -srcfolder "$STAGING" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$OUTPUT"
codesign --force --sign - "$OUTPUT"
echo "Built $OUTPUT"
