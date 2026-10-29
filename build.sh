#!/bin/sh
# FinderSwipe.app を組み立てる
# 使い方: sh build.sh
set -e
cd "$(dirname "$0")"

APP="FinderSwipe.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# アイコン生成（make_icon.swift → iconset → icns）
swiftc make_icon.swift -o /tmp/finderswipe_make_icon
ICONSET="$(mktemp -d)/AppIcon.iconset"
/tmp/finderswipe_make_icon "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

# 本体（Apple Silicon / Intel 両対応のユニバーサルバイナリ）
swiftc -O -framework Cocoa -framework ApplicationServices \
    -target arm64-apple-macos13.0 main.swift -o /tmp/FinderSwipe-arm64
swiftc -O -framework Cocoa -framework ApplicationServices \
    -target x86_64-apple-macos13.0 main.swift -o /tmp/FinderSwipe-x86_64
lipo -create /tmp/FinderSwipe-arm64 /tmp/FinderSwipe-x86_64 -output "$APP/Contents/MacOS/FinderSwipe"
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --deep --sign - "$APP"
echo "できた: $APP"
