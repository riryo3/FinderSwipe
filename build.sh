#!/bin/sh
# FinderSwipe.app を組み立てる
# 使い方: sh build.sh
set -e
cd "$(dirname "$0")"

APP="FinderSwipe.app"
# ソースのビルド番号を表示する(どの版を作っているか一目で分かるように)
BUILD_TAG=$(grep -o '"Build [0-9-]*"' main.swift | head -1 | tr -d '"')
echo "ビルド番号: $BUILD_TAG"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# アイコン生成（make_icon.swift → iconset → icns）
swiftc make_icon.swift -o /tmp/finderswipe_make_icon
ICONSET="$(mktemp -d)/AppIcon.iconset"
/tmp/finderswipe_make_icon "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

# 本体（Apple Silicon / Intel 両対応のユニバーサルバイナリ）
swiftc -O -framework Cocoa -framework ApplicationServices -framework IOKit \
    -target arm64-apple-macos13.0 main.swift -o /tmp/FinderSwipe-arm64
swiftc -O -framework Cocoa -framework ApplicationServices -framework IOKit \
    -target x86_64-apple-macos13.0 main.swift -o /tmp/FinderSwipe-x86_64
lipo -create /tmp/FinderSwipe-arm64 /tmp/FinderSwipe-x86_64 -output "$APP/Contents/MacOS/FinderSwipe"
cp Info.plist "$APP/Contents/Info.plist"
# 署名: Apple Development の証明書があればそれを使う(作り直しても同一アプリとして扱われ、
# 許可まわりや Gatekeeper の判定が安定する)。無い場合だけ場当たり署名にする
SIGN_ID=$(security find-identity -v -p codesigning 2>/dev/null | grep "Apple Development" | head -1 | sed -E 's/.*"(.*)"/\1/')
if [ -n "$SIGN_ID" ]; then
    echo "署名: $SIGN_ID"
    codesign --force --deep --sign "$SIGN_ID" "$APP"
else
    echo "署名: 場当たり（Apple Development 証明書が見つかりませんでした）"
    codesign --force --deep --sign - "$APP"
fi
echo "できた: $APP（$BUILD_TAG）"
