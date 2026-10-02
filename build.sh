#!/bin/bash
# Builds NetSpeed.app (universal: Apple Silicon + Intel). Needs: xcode-select --install
set -euo pipefail
cd "$(dirname "$0")"

APP="NetSpeed.app"
rm -rf build "$APP"
mkdir -p build "$APP/Contents/MacOS"

echo "Compiling…"
swiftc -O -target arm64-apple-macos12  main.swift -o build/NetSpeed-arm64  -framework Cocoa -framework ServiceManagement
swiftc -O -target x86_64-apple-macos12 main.swift -o build/NetSpeed-x86_64 -framework Cocoa -framework ServiceManagement
lipo -create build/NetSpeed-arm64 build/NetSpeed-x86_64 -output "$APP/Contents/MacOS/NetSpeed"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>               <string>NetSpeed</string>
    <key>CFBundleDisplayName</key>        <string>NetSpeed</string>
    <key>CFBundleIdentifier</key>         <string>com.local.netspeed</string>
    <key>CFBundleExecutable</key>         <string>NetSpeed</string>
    <key>CFBundlePackageType</key>        <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>1.0</string>
    <key>CFBundleVersion</key>            <string>1</string>
    <key>LSMinimumSystemVersion</key>     <string>12.0</string>
    <key>LSUIElement</key>                <true/>
    <key>NSHighResolutionCapable</key>    <true/>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP"
rm -rf build
echo "Built $APP — run: open $APP   (or move it to /Applications)"
