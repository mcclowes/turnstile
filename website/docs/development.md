---
title: Development
description: Build, test, and release turnstile.
slug: /development
---

# Development

```sh
swift test             # unit tests
./scripts/e2e.sh       # end-to-end, with fake tools in a throwaway turnstile home
```

## Docs

This site lives in `website/`:

```sh
cd website
npm install
npm start
```

## Releasing

Bump `Turnstile.version` in `Sources/TurnstileCore/Paths.swift`, rename "Unreleased" in `CHANGELOG.md` to the new version, commit, and run `./scripts/release.sh` on a Mac with the Developer ID certificate and the `kiln-notary` notarytool profile.

It tests, builds the universal CLI tarball and the notarized `Turnstile.app`, tags this repo, publishes both to a release here and on [mcclowes/homebrew-turnstile](https://github.com/mcclowes/homebrew-turnstile), with notes from the changelog, and updates the tap's formula and cask.
