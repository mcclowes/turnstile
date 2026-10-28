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
if [ "$#" -gt 1 ] || { [ "$#" -eq 1 ] && [ "$1" != "--dev" ]; }; then
  echo "Usage: scripts/package.sh [--dev]" >&2
  exit 2
fi
cd "$(dirname "$0")/.."

DEV=false
[ "${1:-}" = "--dev" ] && DEV=true
VERSION="$(sed -n 's/.*public static let version = "\(.*\)"/\1/p' Sources/TurnstileCore/Paths.swift)"
IDENTITY="${CODESIGN_IDENTITY:-Developer ID Application}"
PROFILE="${NOTARY_PROFILE:-kiln-notary}"
FINAL_APP=.build/Turnstile.app
FINAL_ZIP=".build/Turnstile-$VERSION.zip"

if [ "$DEV" = false ]; then
  if ! worktree_status="$(git status --porcelain --untracked-files=no)"; then
    echo "package.sh: cannot inspect the Git working tree" >&2
    exit 1
  fi
  if [ -n "$worktree_status" ]; then
    echo "package.sh: a release is packaged from a clean commit; commit first, or pass --dev" >&2
    exit 1
  fi
fi

arch=(--arch arm64 --arch x86_64)
swift build -c release --product TurnstileBar "${arch[@]}"
bin="$(swift build -c release --product TurnstileBar "${arch[@]}" --show-bin-path)"

mkdir -p .build
package_stage=$(mktemp -d .build/.turnstile-package.XXXXXX)
previous_app="$package_stage/previous-app"
previous_zip="$package_stage/previous.zip"
app_promoting=false
zip_promoting=false
package_committed=false
restore_package_artifact() {
  local backup="$1" final="$2" promoting="$3"
  if [ "$promoting" = true ] && ! rm -rf "$final"; then
    return 1
  fi
  if [ -e "$backup" ] || [ -L "$backup" ]; then
    mv "$backup" "$final" || return 1
  fi
  return 0
}
cleanup_package() {
  local exit_status=$?
  local retain_recovery=false
  if [ "$package_committed" = false ]; then
    if ! restore_package_artifact "$previous_zip" "$FINAL_ZIP" "$zip_promoting"; then
      retain_recovery=true
    fi
    if ! restore_package_artifact "$previous_app" "$FINAL_APP" "$app_promoting"; then
      retain_recovery=true
    fi
  fi
  if [ "$retain_recovery" = true ]; then
    echo "package.sh: rollback failed; recovery files retained in $package_stage" >&2
    [ "$exit_status" -ne 0 ] || exit_status=1
  else
    rm -rf "$package_stage"
  fi
  return "$exit_status"
}
publish_package() {
  if [ -e "$FINAL_APP" ] || [ -L "$FINAL_APP" ]; then
    mv "$FINAL_APP" "$previous_app"
  fi
  if [ "$DEV" = false ] && { [ -e "$FINAL_ZIP" ] || [ -L "$FINAL_ZIP" ]; }; then
    mv "$FINAL_ZIP" "$previous_zip"
  fi
  app_promoting=true
  mv "$APP" "$FINAL_APP"
  if [ "$DEV" = false ]; then
    zip_promoting=true
    mv "$ZIP" "$FINAL_ZIP"
  fi
  package_committed=true
}
trap cleanup_package EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
APP="$package_stage/Turnstile.app"
ZIP="$package_stage/Turnstile-$VERSION.zip"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$bin/TurnstileBar" "$APP/Contents/MacOS/"
cp assets/AppIcon.icns "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.mcclowes.turnstile</string>
  <key>CFBundleName</key><string>Turnstile</string>
  <key>CFBundleDisplayName</key><string>Turnstile</string>
  <key>CFBundleExecutable</key><string>TurnstileBar</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSUIElement</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
</dict>
</plist>
PLIST

if [ "$DEV" = true ]; then
  codesign --force --sign - "$APP"
  publish_package
  echo "$FINAL_APP (ad-hoc signed, not notarized)"
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
checksum="$(shasum -a 256 "$ZIP")"
publish_package
printf '%s  %s\n' "${checksum%% *}" "$FINAL_ZIP"
