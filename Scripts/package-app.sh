#!/bin/bash
# Assemble dist/SwiftGoat.app from a release build. A real bundle is what
# makes UserNotifications work (permission-request notifications); plain
# `swift run` stays fine for everything else and just skips notifications.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

APP="dist/SwiftGoat.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/SwiftGoat "$APP/Contents/MacOS/SwiftGoat"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key><string>SwiftGoat</string>
	<key>CFBundleIdentifier</key><string>com.jhgaylor.swift-goat</string>
	<key>CFBundleName</key><string>SwiftGoat</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>0.1.0</string>
	<key>CFBundleVersion</key><string>1</string>
	<key>LSMinimumSystemVersion</key><string>14.0</string>
	<key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Ad-hoc signature: enough for local notifications; replace with a real
# identity to distribute.
codesign --force --sign - "$APP"

echo "Built $APP"
echo "Run it with: open $APP"
