#!/bin/bash
# Releases the version in Sources/TurnstileCore/Paths.swift, by hand, from this Mac: tests, builds the universal CLI
# tarball and the notarized Turnstile.app, tags this repo, publishes both to a release here and on
# mcclowes/homebrew-turnstile, with notes from CHANGELOG.md, and points the tap's formula and cask at them.
# Pushing a tag runs the same steps in .github/workflows/release.yml; this is the local fallback.
#
# Usage: scripts/release.sh    after committing the version bump, with CHANGELOG.md's "Unreleased" renamed to it
#
# Env: as for scripts/package.sh (CODESIGN_IDENTITY, NOTARY_PROFILE).
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(sed -n 's/.*public static let version = "\(.*\)"/\1/p' Sources/TurnstileCore/Paths.swift)"
TAG="v$VERSION"

fail() { echo "release.sh: $*" >&2; exit 1; }

[ -z "$(git status --porcelain)" ] || fail "the tree isn't clean; commit or remove changes first"
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && fail "$TAG is already tagged; bump Turnstile.version first"
./scripts/publish.sh --check

swift test
./scripts/e2e.sh
./scripts/dist.sh

git tag -a "$TAG" -m "turnstile $VERSION"
git push origin "$TAG"

./scripts/publish.sh
