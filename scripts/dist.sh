#!/bin/bash
# Builds a release's artifacts into .build/dist: the universal CLI tarball, the notarized Turnstile.app zip, and
# SHA256SUMS. Used by scripts/release.sh and .github/workflows/release.yml.
#
# Usage: scripts/dist.sh
#
# Env: as for scripts/package.sh (CODESIGN_IDENTITY, NOTARY_PROFILE).
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(sed -n 's/.*public static let version = "\(.*\)"/\1/p' Sources/TurnstileCore/Paths.swift)"
DIST=.build/dist
TARBALL="$DIST/turnstile-$VERSION-macos.tar.gz"
ZIP=".build/Turnstile-$VERSION.zip"

fail() { echo "dist.sh: $*" >&2; exit 1; }

arch=(--arch arm64 --arch x86_64)
swift build -c release --product turnstile "${arch[@]}"
bin="$(swift build -c release --product turnstile "${arch[@]}" --show-bin-path)"
archs="$(lipo -archs "$bin/turnstile")"
[[ "$archs" == *arm64* && "$archs" == *x86_64* ]] || fail "the CLI isn't universal: $archs"
[ "$("$bin/turnstile" --version)" = "$VERSION" ] || fail "the built CLI doesn't report $VERSION"
rm -rf "$DIST"
mkdir -p "$DIST"
tar -czf "$TARBALL" -C "$bin" turnstile

./scripts/package.sh
cp "$ZIP" "$DIST/"
(cd "$DIST" && shasum -a 256 -- *.tar.gz *.zip > SHA256SUMS)
cat "$DIST/SHA256SUMS"
