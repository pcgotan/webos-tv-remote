#!/bin/bash
# Package build/TV Remote.app into build/TV-Remote-<version>.dmg (drag to Applications).
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="$(cat VERSION)"
[ -d "build/TV Remote.app" ] || scripts/build.sh
STAGE="build/dmg"
rm -rf "$STAGE" && mkdir -p "$STAGE"
cp -R "build/TV Remote.app" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
DMG="build/TV-Remote-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -volname "TV Remote $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
shasum -a 256 "$DMG" | tee "$DMG.sha256"
echo "Created $DMG"
