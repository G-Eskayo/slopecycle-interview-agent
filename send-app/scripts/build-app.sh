#!/bin/bash
# Builds "SlopeCycle Send.app" (release, ad-hoc signed) and zips it to dist/SlopeCycle-Send.zip.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
APP_NAME="SlopeCycle Send"
EXECUTABLE="SlopeCycleSend"
VERSION="1.0.0"
DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"

# Universal (Apple silicon + Intel), so it runs on any teammate's Mac with macOS 14+.
swift build -c release --product "$EXECUTABLE" --arch arm64 --arch x86_64
BIN_DIR="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"

rm -rf "$APP" "$DIST/SlopeCycle-Send.zip"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$EXECUTABLE" "$APP/Contents/MacOS/$EXECUTABLE"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleExecutable</key><string>$EXECUTABLE</string>
    <key>CFBundleIdentifier</key><string>com.slopecycle.send</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
plutil -lint "$APP/Contents/Info.plist" >/dev/null
lipo "$APP/Contents/MacOS/$EXECUTABLE" -verify_arch arm64 x86_64

codesign --force --deep -s - "$APP"
codesign --verify --deep --strict "$APP"

ditto -c -k --sequesterRsrc --keepParent "$APP" "$DIST/SlopeCycle-Send.zip"
echo "Built: $APP"
echo "Zip:   $DIST/SlopeCycle-Send.zip"
