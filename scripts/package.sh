#!/bin/bash
# Builds Turnstile.app, the menu bar app, for both architectures. The CLI ships separately, as the turnstile formula,
# which the app's cask depends on. A release is signed with the Developer ID, notarized, stapled, and zipped for the cask.
#
# Usage: scripts/package.sh          release: needs a clean commit and notarization credentials
#        scripts/package.sh --dev    ad-hoc signed, not notarized, for local use and CI
#
# Env:
#   CODESIGN_IDENTITY   signing identity (default "Developer ID Application")
#   NOTARY_PROFILE      notarytool keychain profile (default kiln-notary, the shared Apple-account profile)
set -euo pipefail
cd "$(dirname "$0")/.."

DEV=false
[ "${1:-}" = "--dev" ] && DEV=true
VERSION="$(sed -n 's/.*public static let version = "\(.*\)"/\1/p' Sources/TurnstileCore/Paths.swift)"
IDENTITY="${CODESIGN_IDENTITY:-Developer ID Application}"
PROFILE="${NOTARY_PROFILE:-kiln-notary}"
APP=.build/Turnstile.app
ZIP=".build/Turnstile-$VERSION.zip"

if [ "$DEV" = false ] && [ -n "$(git status --porcelain --untracked-files=no)" ]; then
  echo "package.sh: a release is packaged from a clean commit; commit first, or pass --dev" >&2
  exit 1
fi

arch=(--arch arm64 --arch x86_64)
swift build -c release --product TurnstileBar "${arch[@]}"
bin="$(swift build -c release --product TurnstileBar "${arch[@]}" --show-bin-path)"

rm -rf "$APP" "$ZIP"
mkdir -p "$APP/Contents/MacOS"
cp "$bin/TurnstileBar" "$APP/Contents/MacOS/"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.mcclowes.turnstile</string>
  <key>CFBundleName</key><string>Turnstile</string>
  <key>CFBundleDisplayName</key><string>Turnstile</string>
  <key>CFBundleExecutable</key><string>TurnstileBar</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
</dict>
</plist>
PLIST

if [ "$DEV" = true ]; then
  codesign --force --sign - "$APP"
  echo "$APP (ad-hoc signed, not notarized)"
  exit 0
fi

# Notarization needs the hardened runtime and a timestamp.
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
codesign --verify --strict --deep --verbose=2 "$APP"

ditto -c -k --keepParent "$APP" "$ZIP"
# `notarytool submit --wait` exits 0 even when rejected, so check the status and fetch the log on failure.
output="$(xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait 2>&1)" || true
echo "$output"
if ! echo "$output" | grep -q "status: Accepted"; then
  id="$(echo "$output" | grep -m1 'id:' | awk '{print $NF}')"
  echo "package.sh: notarization failed; log for $id:" >&2
  [ -n "$id" ] && xcrun notarytool log "$id" --keychain-profile "$PROFILE" >&2
  exit 1
fi
xcrun stapler staple "$APP"
spctl --assess --type execute --verbose=2 "$APP"

# Re-zip so the zip carries the stapled ticket.
rm "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
shasum -a 256 "$ZIP"
