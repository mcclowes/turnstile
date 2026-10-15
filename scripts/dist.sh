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
dist_backup=''
dist_promoting=false
dist_committed=false
cleanup_distribution() {
  local exit_status=$?
  local retain_recovery=false
  if [ "$dist_committed" = false ]; then
    if [ "$dist_promoting" = true ] && ! rm -rf "$DIST"; then
      retain_recovery=true
    elif [ -n "$dist_backup" ] && { [ -e "$dist_backup/previous" ] || [ -L "$dist_backup/previous" ]; } &&
      ! mv "$dist_backup/previous" "$DIST"; then
      retain_recovery=true
    fi
  fi
  if [ "$retain_recovery" = true ]; then
    echo "dist.sh: rollback failed; recovery directories retained: $dist_stage $dist_backup" >&2
    [ "$exit_status" -ne 0 ] || exit_status=1
  else
    rm -rf "$dist_stage"
    [ -z "$dist_backup" ] || rm -rf "$dist_backup"
  fi
  return "$exit_status"
}
trap cleanup_distribution EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
TARBALL="$dist_stage/turnstile-$VERSION-macos.tar.gz"
tar -czf "$TARBALL" -C "$bin" turnstile

./scripts/package.sh
cp "$ZIP" "$dist_stage/"
(cd "$dist_stage" && shasum -a 256 -- *.tar.gz *.zip > SHA256SUMS)
dist_backup=$(mktemp -d .build/.turnstile-dist-backup.XXXXXX)
if [ -e "$DIST" ] || [ -L "$DIST" ]; then
  mv "$DIST" "$dist_backup/previous"
fi
dist_promoting=true
mv "$dist_stage" "$DIST"
dist_committed=true
cat "$DIST/SHA256SUMS"
