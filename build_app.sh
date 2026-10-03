#!/bin/bash
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
NAME="Floating Terminal"
APP="$DIR/$NAME.app"

echo "🔨 ビルド中..."
cd "$DIR"
# ビルド中間物は Documents の外に置く（.build/build.db が disk I/O error になったため）
BUILD_DIR="$HOME/Library/Caches/FloatingTerminal-build"
swift build -c release --scratch-path "$BUILD_DIR"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILD_DIR/release/FloatingTerminal" "$APP/Contents/MacOS/FloatingTerminal"
cp "$DIR/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>FloatingTerminal</string>
  <key>CFBundleIdentifier</key>
  <string>com.brightflowingspace.floatingterminal</string>
  <key>CFBundleName</key>
  <string>Floating Terminal</string>
  <key>CFBundleDisplayName</key>
  <string>Floating Terminal</string>
  <key>CFBundleVersion</key>
  <string>1.0</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0.0</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>NSAppleEventsUsageDescription</key>
  <string>ターミナルの設定画面を開くために使います。</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"

echo "✅ 完了: $APP"
echo "起動: open '$APP'"
