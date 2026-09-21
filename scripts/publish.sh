#!/bin/bash
# Publishes the artifacts in .build/dist, built by scripts/dist.sh, for a pushed tag: a release here and on
# mcclowes/homebrew-turnstile, with notes from CHANGELOG.md, then points the tap's formula and cask at them.
# Used by scripts/release.sh and .github/workflows/release.yml.
#
# Usage: scripts/publish.sh --check   only check neither repo has this version's release and CHANGELOG.md has notes
#        scripts/publish.sh           publish; the v<version> tag must already be pushed
#
# Env: GH_TOKEN      if gh isn't logged in, with contents write on this repo (and the tap, without TAP_GH_TOKEN)
#      TAP_GH_TOKEN  optional, with contents write on the tap, used for the tap alone
set -euo pipefail
cd "$(dirname "$0")/.."

REPO=mcclowes/turnstile
TAP=mcclowes/homebrew-turnstile
VERSION="$(sed -n 's/.*public static let version = "\(.*\)"/\1/p' Sources/TurnstileCore/Paths.swift)"
TAG="v$VERSION"
DIST=.build/dist
TARBALL="$DIST/turnstile-$VERSION-macos.tar.gz"
ZIP="$DIST/Turnstile-$VERSION.zip"

fail() { echo "publish.sh: $*" >&2; exit 1; }
# Runs a command as the tap's token, when there is one.
as_tap() { if [ -n "${TAP_GH_TOKEN:-}" ]; then GH_TOKEN="$TAP_GH_TOKEN" "$@"; else "$@"; fi; }
for_repo() { if [ "$1" = "$TAP" ]; then shift; as_tap "$@"; else shift; "$@"; fi; }

for repo in "$TAP" "$REPO"; do
  for_repo "$repo" gh release view "$TAG" --repo "$repo" >/dev/null 2>&1 && fail "$repo already has a $TAG release"
done
CHANGES="$(awk -v v="## $VERSION" '$0 == v {on=1; next} /^## / {on=0} on' CHANGELOG.md | sed '/./,$!d')"
[ -n "$CHANGES" ] || fail "CHANGELOG.md has no \"## $VERSION\" section"
[ "${1:-}" = "--check" ] && exit 0

for f in "$TARBALL" "$ZIP" "$DIST/SHA256SUMS"; do
  [ -f "$f" ] || fail "$f is missing; run scripts/dist.sh first"
done
git ls-remote --exit-code --tags origin "refs/tags/$TAG" >/dev/null || fail "$TAG isn't pushed"
cli_sha="$(shasum -a 256 "$TARBALL" | cut -d' ' -f1)"
app_sha="$(shasum -a 256 "$ZIP" | cut -d' ' -f1)"

NOTES="$CHANGES

Changes: https://github.com/$REPO/compare/$(git describe --tags --abbrev=0 "$TAG^" 2>/dev/null || echo main)...$TAG

\`\`\`sh
brew install mcclowes/turnstile/turnstile                                # CLI only
brew install mcclowes/turnstile/turnstile mcclowes/turnstile/turnstile-app  # CLI + menu bar app
\`\`\`"
for repo in "$TAP" "$REPO"; do
  for_repo "$repo" gh release create "$TAG" "$TARBALL" "$ZIP" "$DIST/SHA256SUMS" \
    --repo "$repo" --title "turnstile $VERSION" --notes "$NOTES"
done

tap="$(mktemp -d)/homebrew-turnstile"
as_tap gh repo clone "$TAP" "$tap" -- --quiet
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
as_tap git -C "$tap" push -q origin HEAD

echo "Released turnstile $VERSION: https://github.com/$TAP/releases/tag/$TAG"
