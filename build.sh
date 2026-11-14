#!/bin/sh
# build.sh: Screen Copy (Mantra).app. swiftc straight, no Xcode. Run by GitHub Actions only (SIGN=- NO_INSTALL=1).
# VERSION is in app/App.swift (a whole number, written into the bundle).
set -e
cd "$(dirname "$0")"
mkdir -p build
V=$(sed -n 's/^let VERSION = \([0-9]*\)/\1/p' app/App.swift)
APP="build/Screen Copy (Mantra).app"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -swift-version 5 -o "$APP/Contents/MacOS/ScreenCopy" app/*.swift
cp server/scrcpy-server-4.1.jar "$APP/Contents/Resources/scrcpy-server.jar"
# icon: six letters over one picture, drawn in code (modules/six-letter-icon.md)
swiftc -O -o build/make_icon icon/make_icon.swift
rm -rf build/AppIcon.iconset; mkdir build/AppIcon.iconset
./build/make_icon build/AppIcon.iconset
iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Screen Copy (Mantra)</string>
<key>CFBundleDisplayName</key><string>Screen Copy (Mantra)</string>
<key>CFBundleIdentifier</key><string>community.auroville.screencopy</string>
<key>CFBundleExecutable</key><string>ScreenCopy</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$V</string>
<key>CFBundleVersion</key><string>$V</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSLocalNetworkUsageDescription</key><string>Screen Copy talks to your phones over the local network.</string>
<key>NSMicrophoneUsageDescription</key><string>Screen Copy sends the Mac microphone to your phone (TTT dictation) while the phone asks for it.</string>
<key>CFBundleURLTypes</key><array><dict><key>CFBundleURLName</key><string>Screen Copy</string><key>CFBundleURLSchemes</key><array><string>screencopy</string></array></dict></array>
</dict></plist>
PL
codesign --force -s "${SIGN:-Mantra Apps}" "$APP"
echo "built $APP (v$V)"
