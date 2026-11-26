#!/bin/bash
# Builds a universal macOS app and packages it as a disk image.
set -euo pipefail
cd "$(dirname "$0")"

RELEASE=false
if [[ "${1:-}" == "--release" ]]; then
  RELEASE=true
  shift
fi
VERSION="${1:-1.3}"
if [[ $# -gt 1 || ! "$VERSION" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then
  echo "Usage: $0 [--release] [version]" >&2
  exit 2
fi
MIN_MACOS="13.0"
OUTPUT_DIR="dist"
SIGN_OPTIONS=(--sign -)
if [[ "$RELEASE" == true ]]; then
  : "${SENSE_DEVELOPER_ID:?Set SENSE_DEVELOPER_ID to the full Developer ID Application identity.}"
  : "${SENSE_NOTARY_PROFILE:?Set SENSE_NOTARY_PROFILE to the notarytool keychain profile name.}"
  if [[ "$SENSE_DEVELOPER_ID" != "Developer ID Application: "* ]] ||
     ! security find-identity -v -p codesigning |
       awk -F '"' -v identity="$SENSE_DEVELOPER_ID" '$2 == identity { found = 1 } END { exit !found }'; then
    echo "The specified Developer ID Application identity is unavailable in the code-signing keychain." >&2
    exit 1
  fi
  SIGN_OPTIONS=(--sign "$SENSE_DEVELOPER_ID" --options runtime --timestamp)
  OUTPUT_DIR="dist/release"
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
APP="$WORK/Sense.app"
STAGE="$WORK/dmg-stage"
DMG_NAME="Sense-$VERSION.dmg"
DMG="$WORK/$DMG_NAME"

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

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
cp assets/GitHubMark.svg "$APP/Contents/Resources/"

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
WIDGET_PLIST="$WORK/widget-Info.plist"
cp widget/Info.plist "$WIDGET_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$WIDGET_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$WIDGET_PLIST"
xcodebuild -quiet -project widget/SenseWidget.xcodeproj -target SenseMemoryWidget -configuration Release \
  SYMROOT="$WORK/widget-build" INFOPLIST_FILE="$WIDGET_PLIST" CODE_SIGNING_ALLOWED=NO build
mkdir -p "$APP/Contents/PlugIns"
ditto "$WORK/widget-build/Release/SenseMemoryWidget.appex" "$EXT"

echo "▸ Signing the widget and app"
codesign --force "${SIGN_OPTIONS[@]}" --entitlements widget/Widget.entitlements "$EXT"
codesign --force "${SIGN_OPTIONS[@]}" "$APP"
codesign --verify --deep --strict "$APP"

echo "▸ Building DMG"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Sense.app"
ln -s /Applications "$STAGE/Applications"
{
  if [[ "$RELEASE" == false ]]; then
    printf '%s\n\n' "Local development build. For public downloads, use the notarized release."
  fi
  cat <<'TXT'
Sense — install
1. Drag Sense into the Applications folder.
2. Open Sense from Applications.
3. Look for the logo in your menu bar and click it.
TXT
} > "$STAGE/Read Me First.txt"
hdiutil create -volname "Sense" -srcfolder "$STAGE" -format UDZO -fs HFS+ "$DMG" >/dev/null

if [[ "$RELEASE" == true ]]; then
  echo "▸ Signing and notarizing the disk image"
  codesign --sign "$SENSE_DEVELOPER_ID" --timestamp "$DMG"
  codesign --verify "$DMG"
  xcrun notarytool submit "$DMG" --keychain-profile "$SENSE_NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
  spctl --assess --type open --context context:primary-signature "$DMG"
fi
hdiutil verify "$DMG" >/dev/null

mkdir -p "$OUTPUT_DIR"
if [[ "$RELEASE" == false ]]; then
  LOCAL_APP="$OUTPUT_DIR/Sense.app"
  if [[ -e "$LOCAL_APP" || -L "$LOCAL_APP" ]]; then
    mv "$LOCAL_APP" "$WORK/previous.app"
  fi
  if ! mv "$APP" "$LOCAL_APP"; then
    if [[ -e "$WORK/previous.app" || -L "$WORK/previous.app" ]]; then
      mv "$WORK/previous.app" "$LOCAL_APP"
    fi
    exit 1
  fi
fi
mv -f "$DMG" "$OUTPUT_DIR/$DMG_NAME"
echo "✓ $OUTPUT_DIR/$DMG_NAME"
