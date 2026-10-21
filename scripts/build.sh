#!/bin/bash
# Build "TV Remote.app" (universal: Apple silicon + Intel) into build/.
#   scripts/build.sh            build
#   scripts/build.sh --install  build, then copy to /Applications
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="$(cat VERSION)"
APP="build/TV Remote.app"
mkdir -p build
for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 -parse-as-library -target "$arch-apple-macos14" Sources/*.swift -o "build/TVRemote-$arch"
done
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create build/TVRemote-arm64 build/TVRemote-x86_64 -output "$APP/Contents/MacOS/TVRemote"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>TV Remote</string>
  <key>CFBundleDisplayName</key><string>TV Remote</string>
  <key>CFBundleIdentifier</key><string>io.github.pcgotan.tvremote</string>
  <key>CFBundleExecutable</key><string>TVRemote</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHumanReadableCopyright</key><string>MIT License</string>
  <key>NSLocalNetworkUsageDescription</key><string>TV Remote finds and controls your LG TV on your home network.</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
echo "Built $APP ($VERSION)"
if [ "${1:-}" = "--install" ]; then
  rm -rf "/Applications/TV Remote.app" && cp -R "$APP" /Applications/
  echo "Installed to /Applications"
fi
