#!/bin/bash
# Builds Sense as a universal (Apple Silicon + Intel) app and packages it as dist/Sense-<version>.dmg
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${1:-1.3}"
MIN_MACOS="13.0"
APP="dist/Sense.app"
STAGE="dist/dmg-stage"
DMG="dist/Sense-$VERSION.dmg"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

rm -rf dist && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "▸ Compiling (arm64 + x86_64)"
for arch in arm64 x86_64; do
  swiftc -O -target "$arch-apple-macos$MIN_MACOS" src/*.swift -o "$WORK/Sense-$arch"
done
lipo -create "$WORK/Sense-arm64" "$WORK/Sense-x86_64" -output "$APP/Contents/MacOS/Sense"

echo "▸ Icon"
swiftc -O src/SenseMark.swift tools/make_icon.swift -o "$WORK/make_icon"
"$WORK/make_icon" "$WORK/icon.png"
ICONSET="$WORK/AppIcon.iconset"; mkdir "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s "$WORK/icon.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) "$WORK/icon.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Sense</string>
<key>CFBundleDisplayName</key><string>Sense</string>
<key>CFBundleIdentifier</key><string>com.sense.menubar</string>
<key>CFBundleExecutable</key><string>Sense</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>$VERSION</string>
<key>LSMinimumSystemVersion</key><string>$MIN_MACOS</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSHumanReadableCopyright</key><string>© Sense</string>
</dict></plist>
PLIST

echo "▸ Memory widget"
EXT="$APP/Contents/PlugIns/SenseMemoryWidget.appex"
xcodebuild -quiet -project widget/SenseWidget.xcodeproj -target SenseMemoryWidget -configuration Release SYMROOT="$WORK/widget-build" build CODE_SIGNING_ALLOWED=NO
mkdir -p "$APP/Contents/PlugIns"
ditto "$WORK/widget-build/Release/SenseMemoryWidget.appex" "$EXT"
codesign --force --sign - --entitlements widget/Widget.entitlements "$EXT"

echo "▸ Signing (ad-hoc)"
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"

echo "▸ Building DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/Read Me First.txt" <<'TXT'
Sense — install
1. Drag Sense into the Applications folder.
2. Open it from Applications. The first time, macOS may say it can't verify the developer:
   right-click (or Control-click) Sense → Open → Open.
   If macOS says the app is "damaged", open Terminal and run:
   xattr -dr com.apple.quarantine /Applications/Sense.app
3. Look for the logo in your menu bar and click it.
TXT
hdiutil create -volname "Sense" -srcfolder "$STAGE" -ov -format UDZO -fs HFS+ "$DMG" >/dev/null
rm -rf "$STAGE"
echo "✓ $DMG"
