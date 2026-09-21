#!/bin/bash
# Build UsageBar.app and UsageBar.dmg.
#
#   ./build.sh                # ad-hoc signed (users must right-click → Open once)
#   SIGN_ID="Developer ID Application: Name (TEAMID)" NOTARY_PROFILE=notary ./build.sh
#
# NOTARY_PROFILE is a keychain profile created with:
#   xcrun notarytool store-credentials notary --apple-id ... --team-id ... --password <app-specific>
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${VERSION:-$(git describe --tags --always 2>/dev/null || echo 0.0.0)}"
VERSION="${VERSION#v}"
APP=build/UsageBar.app
DMG=build/UsageBar-$VERSION.dmg

rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "▸ compiling"
swiftc -O -target arm64-apple-macos13.0 -o build/UsageBar-arm64 UsageBar.swift
swiftc -O -target x86_64-apple-macos13.0 -o build/UsageBar-x86_64 UsageBar.swift
lipo -create build/UsageBar-arm64 build/UsageBar-x86_64 -output "$APP/Contents/MacOS/UsageBar"
rm build/UsageBar-arm64 build/UsageBar-x86_64

echo "▸ icon"
ICONSET=build/icon.iconset && mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s usagebar_icon_1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) usagebar_icon_1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.sudipta.usagebar</string>
<key>CFBundleName</key><string>UsageBar</string>
<key>CFBundleDisplayName</key><string>UsageBar</string>
<key>CFBundleExecutable</key><string>UsageBar</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>$VERSION</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSHumanReadableCopyright</key><string>MIT License</string>
</dict></plist>
PLIST

echo "▸ signing"
if [ -n "${SIGN_ID:-}" ]; then
  codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$APP"
else
  codesign --force --sign - "$APP"
fi

echo "▸ dmg"
STAGE=build/dmg && mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname UsageBar -srcfolder "$STAGE" -ov -format UDZO "$DMG"

if [ -n "${SIGN_ID:-}" ] && [ -n "${NOTARY_PROFILE:-}" ]; then
  echo "▸ notarizing"
  codesign --force --sign "$SIGN_ID" --timestamp "$DMG"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
fi

rm -rf "$STAGE" "$ICONSET"
echo "✓ $DMG"
