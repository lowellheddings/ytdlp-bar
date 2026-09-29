#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product YTDLPBar

if [[ ! -f Support/AppIcon.icns ]]; then
  swift scripts/make-icon.swift Support/AppIcon.iconset/icon_1024x1024.png
  iconset="Support/AppIcon.iconset"
  src="$iconset/icon_1024x1024.png"
  sips -z 16 16 "$src" --out "$iconset/icon_16x16.png" >/dev/null
  sips -z 32 32 "$src" --out "$iconset/icon_16x16@2x.png" >/dev/null
  sips -z 32 32 "$src" --out "$iconset/icon_32x32.png" >/dev/null
  sips -z 64 64 "$src" --out "$iconset/icon_32x32@2x.png" >/dev/null
  sips -z 128 128 "$src" --out "$iconset/icon_128x128.png" >/dev/null
  sips -z 256 256 "$src" --out "$iconset/icon_128x128@2x.png" >/dev/null
  sips -z 256 256 "$src" --out "$iconset/icon_256x256.png" >/dev/null
  sips -z 512 512 "$src" --out "$iconset/icon_256x256@2x.png" >/dev/null
  sips -z 512 512 "$src" --out "$iconset/icon_512x512.png" >/dev/null
  cp "$src" "$iconset/icon_512x512@2x.png"
  iconutil -c icns "$iconset" -o Support/AppIcon.icns
fi

APP="dist/YTDLP Bar.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/YTDLPBar "$APP/Contents/MacOS/YTDLPBar"
cp Support/Info.plist "$APP/Contents/Info.plist"
cp Support/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP" >/dev/null
echo "$PWD/$APP"
