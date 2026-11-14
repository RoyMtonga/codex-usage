#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
APP="Codex Usage.app"
mkdir -p "$APP/Contents/MacOS"
swiftc -parse-as-library -module-cache-path /private/tmp/codex-usage-swift-cache -O CodexUsage.swift -o "$APP/Contents/MacOS/CodexUsage"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>CodexUsage</string>
<key>CFBundleIdentifier</key><string>local.codex.usage.menubar</string>
<key>CFBundleName</key><string>Codex Usage</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP" >/dev/null
printf 'Built %s\n' "$APP"
