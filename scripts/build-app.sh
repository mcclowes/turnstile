#!/bin/bash
# Builds Turnstile.app, the menu bar app, into .build/Turnstile.app. Pass --universal for arm64 + x86_64.
set -euo pipefail
cd "$(dirname "$0")/.."
arch=()
[ "${1:-}" = "--universal" ] && arch=(--arch arm64 --arch x86_64)
swift build -c release --product TurnstileBar ${arch[@]+"${arch[@]}"}
bin="$(swift build -c release --product TurnstileBar ${arch[@]+"${arch[@]}"} --show-bin-path)"
version="$(sed -n 's/.*version = "\(.*\)"/\1/p' Sources/TurnstileCore/Paths.swift)"

app=.build/Turnstile.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp "$bin/TurnstileBar" "$app/Contents/MacOS/TurnstileBar"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.mcclowes.turnstile.bar</string>
  <key>CFBundleName</key><string>Turnstile</string>
  <key>CFBundleExecutable</key><string>TurnstileBar</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>CFBundleVersion</key><string>$version</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
codesign --force --sign - "$app"
echo "$app"
