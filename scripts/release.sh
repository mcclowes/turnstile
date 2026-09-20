#!/bin/bash
# Releases the version in Sources/TurnstileCore/Paths.swift, by hand, from this Mac: tests, builds the universal CLI
# tarball and the notarized Turnstile.app, tags this repo, publishes both to a release here and on
# mcclowes/homebrew-turnstile, with notes from CHANGELOG.md, and points the tap's formula and cask at them.
#
# Usage: scripts/release.sh    after committing the version bump, with CHANGELOG.md's "Unreleased" renamed to it
#
# Env: as for scripts/package.sh (CODESIGN_IDENTITY, NOTARY_PROFILE).
set -euo pipefail
cd "$(dirname "$0")/.."

REPO=mcclowes/turnstile
TAP=mcclowes/homebrew-turnstile
VERSION="$(sed -n 's/.*public static let version = "\(.*\)"/\1/p' Sources/TurnstileCore/Paths.swift)"
TAG="v$VERSION"
DIST=.build/dist
TARBALL="$DIST/turnstile-$VERSION-macos.tar.gz"
ZIP=".build/Turnstile-$VERSION.zip"

fail() { echo "release.sh: $*" >&2; exit 1; }

[ -z "$(git status --porcelain)" ] || fail "the tree isn't clean; commit or remove changes first"
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && fail "$TAG is already tagged; bump Turnstile.version first"
for repo in "$TAP" "$REPO"; do
  gh release view "$TAG" --repo "$repo" >/dev/null 2>&1 && fail "$repo already has a $TAG release"
done
CHANGES="$(awk -v v="## $VERSION" '$0 == v {on=1; next} /^## / {on=0} on' CHANGELOG.md | sed '/./,$!d')"
[ -n "$CHANGES" ] || fail "CHANGELOG.md has no \"## $VERSION\" section"

swift test
./scripts/e2e.sh

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
cli_sha="$(shasum -a 256 "$TARBALL" | cut -d' ' -f1)"
app_sha="$(shasum -a 256 "$ZIP" | cut -d' ' -f1)"

git tag -a "$TAG" -m "turnstile $VERSION"
git push origin "$TAG"

NOTES="$CHANGES

Changes: https://github.com/$REPO/compare/$(git describe --tags --abbrev=0 "$TAG^" 2>/dev/null || echo main)...$TAG

\`\`\`sh
brew install mcclowes/turnstile/turnstile                                # CLI only
brew install mcclowes/turnstile/turnstile mcclowes/turnstile/turnstile-app  # CLI + menu bar app
\`\`\`"
for repo in "$TAP" "$REPO"; do
  gh release create "$TAG" "$TARBALL" "$DIST/Turnstile-$VERSION.zip" "$DIST/SHA256SUMS" \
    --repo "$repo" --title "turnstile $VERSION" --notes "$NOTES"
done

tap="$(mktemp -d)/homebrew-turnstile"
gh repo clone "$TAP" "$tap" -- --quiet
sed -i '' -E \
  -e "s|releases/download/v[^/]+/turnstile-[^/]+-macos\.tar\.gz|releases/download/$TAG/turnstile-$VERSION-macos.tar.gz|" \
  -e "s|^(  sha256 )\"[0-9a-f]+\"|\1\"$cli_sha\"|" \
  "$tap/Formula/turnstile.rb"
sed -i '' -E \
  -e "s|^(  version )\"[^\"]+\"|\1\"$VERSION\"|" \
  -e "s|^(  sha256 )\"[0-9a-f]+\"|\1\"$app_sha\"|" \
  "$tap/Casks/turnstile-app.rb"
grep -q "$cli_sha" "$tap/Formula/turnstile.rb" || fail "couldn't update the formula's checksum"
grep -q "$app_sha" "$tap/Casks/turnstile-app.rb" || fail "couldn't update the cask's checksum"
git -C "$tap" commit -q -am "turnstile $VERSION"
git -C "$tap" push -q origin HEAD

echo "Released turnstile $VERSION: https://github.com/$TAP/releases/tag/$TAG"
