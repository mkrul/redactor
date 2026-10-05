#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --product redactor
BIN="$(swift build -c release --product redactor --show-bin-path)/redactor"
APP="dist/Redactor.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/redactor"
chmod +x "$APP/Contents/MacOS/redactor"
cp packaging/Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable redactor" "$APP/Contents/Info.plist"
cp patterns.json "$APP/Contents/Resources/patterns.json"
ICONSET="dist/AppIcon.iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
sips -z 16 16 packaging/AppIcon.png --out "$ICONSET/icon_16x16.png" >/dev/null
sips -z 32 32 packaging/AppIcon.png --out "$ICONSET/icon_16x16@2x.png" >/dev/null
sips -z 32 32 packaging/AppIcon.png --out "$ICONSET/icon_32x32.png" >/dev/null
sips -z 64 64 packaging/AppIcon.png --out "$ICONSET/icon_32x32@2x.png" >/dev/null
sips -z 128 128 packaging/AppIcon.png --out "$ICONSET/icon_128x128.png" >/dev/null
sips -z 256 256 packaging/AppIcon.png --out "$ICONSET/icon_128x128@2x.png" >/dev/null
sips -z 256 256 packaging/AppIcon.png --out "$ICONSET/icon_256x256.png" >/dev/null
sips -z 512 512 packaging/AppIcon.png --out "$ICONSET/icon_256x256@2x.png" >/dev/null
sips -z 512 512 packaging/AppIcon.png --out "$ICONSET/icon_512x512.png" >/dev/null
sips -z 1024 1024 packaging/AppIcon.png --out "$ICONSET/icon_512x512@2x.png" >/dev/null
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"
codesign --force --sign - "$APP/Contents/MacOS/redactor"
codesign --force --sign - "$APP"
