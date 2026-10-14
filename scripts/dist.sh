#!/bin/bash
# Builds a release's artifacts into .build/dist: the universal CLI tarball, the notarized Turnstile.app zip, and
# SHA256SUMS. Used by scripts/release.sh and .github/workflows/release.yml.
#
# Usage: scripts/dist.sh
#
# Env: as for scripts/package.sh (CODESIGN_IDENTITY, NOTARY_PROFILE).
set -euo pipefail
if [ "$#" -ne 0 ]; then
  echo "Usage: scripts/dist.sh" >&2
  exit 2
fi
cd "$(dirname "$0")/.."

VERSION="$(sed -n 's/.*public static let version = "\(.*\)"/\1/p' Sources/TurnstileCore/Paths.swift)"
DIST=.build/dist
ZIP=".build/Turnstile-$VERSION.zip"

fail() { echo "dist.sh: $*" >&2; exit 1; }

arch=(--arch arm64 --arch x86_64)
swift build -c release --product turnstile "${arch[@]}"
bin="$(swift build -c release --product turnstile "${arch[@]}" --show-bin-path)"
archs="$(lipo -archs "$bin/turnstile")"
[[ "$archs" == *arm64* && "$archs" == *x86_64* ]] || fail "the CLI isn't universal: $archs"
[ "$("$bin/turnstile" --version)" = "$VERSION" ] || fail "the built CLI doesn't report $VERSION"
mkdir -p .build
dist_stage=$(mktemp -d .build/.turnstile-dist.XXXXXX)
trap 'rm -rf "$dist_stage"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
TARBALL="$dist_stage/turnstile-$VERSION-macos.tar.gz"
tar -czf "$TARBALL" -C "$bin" turnstile

./scripts/package.sh
cp "$ZIP" "$dist_stage/"
(cd "$dist_stage" && shasum -a 256 -- *.tar.gz *.zip > SHA256SUMS)
rm -rf "$DIST"
mv "$dist_stage" "$DIST"
cat "$DIST/SHA256SUMS"
