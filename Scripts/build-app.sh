#!/bin/bash
# Builds NetworkMonitor.app. Needed for anything `swift run` can't do: hiding the Dock
# icon and registering a login item both require a real bundle.
set -euo pipefail

cd "$(dirname "$0")/.."

APP="NetworkMonitor.app"
VERSION="1.0"

swift build -c release

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/NetworkMonitorApp "$APP/Contents/MacOS/NetworkMonitor"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>Network Monitor</string>
    <key>CFBundleDisplayName</key>       <string>Network Monitor</string>
    <key>CFBundleIdentifier</key>        <string>com.networkmonitor.app</string>
    <key>CFBundleExecutable</key>        <string>NetworkMonitor</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key>           <string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key>    <string>14.0</string>
    <!-- Menu bar only: no Dock icon, no app switcher entry. -->
    <key>LSUIElement</key>               <true/>
</dict>
</plist>
PLIST

# Ad-hoc signing is enough for a local app and gives the login item a stable identity.
codesign --force --sign - "$APP"

echo "Built $APP — open it with: open $APP"
