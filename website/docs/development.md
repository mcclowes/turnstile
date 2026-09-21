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

Bump `Turnstile.version` in `Sources/TurnstileCore/Paths.swift`, rename "Unreleased" in `CHANGELOG.md` to the new version, commit, push, and push a matching tag:

```sh
git tag -a v0.5.0 -m "turnstile 0.5.0"
git push origin v0.5.0
```

The [release workflow](https://github.com/mcclowes/turnstile/actions/workflows/release.yml) tests, builds the universal CLI tarball and the notarized `Turnstile.app`, attests their build provenance, publishes both to a release here and on [mcclowes/homebrew-turnstile](https://github.com/mcclowes/homebrew-turnstile), with notes from the changelog, and updates the tap's formula and cask. Running the workflow by hand builds, signs, and notarizes without publishing, to check the secrets.

To check a download came from this repo's workflow:

```sh
gh attestation verify "$(which turnstile)" --repo mcclowes/turnstile
```

`./scripts/release.sh` does the same from a Mac with the Developer ID certificate and the `kiln-notary` notarytool profile, tagging for you. It stays as a fallback until the workflow has shipped a release.

### Release secrets

The workflow needs these Actions secrets:

| Secret | What it holds |
| --- | --- |
| `DEVELOPER_ID_P12_BASE64` | The Developer ID Application certificate and its private key, exported from Keychain Access as a `.p12`, then `base64 -i cert.p12 \| pbcopy` |
| `DEVELOPER_ID_P12_PASSWORD` | The password set when exporting the `.p12` |
| `NOTARY_API_KEY_P8_BASE64` | An App Store Connect API key (Users and Access → Integrations, Developer access), the `.p8` base64-encoded |
| `NOTARY_API_KEY_ID` | That key's ID |
| `NOTARY_API_ISSUER_ID` | The issuer ID shown above the keys |
| `TAP_GITHUB_TOKEN` | A fine-grained token for `mcclowes/homebrew-turnstile` alone, with Contents read and write, to publish its release and push the formula and cask |

Releases on this repo use the workflow's own token.
