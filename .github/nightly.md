# Nightly releases

GitHub Actions checks the default branch nightly and supports manual dispatch from that branch. `.github/nightly.json` lists deployable inputs. The Linux planner compares their Git tree fingerprint with the last successful `nightly-homebrew` deployment, before allocating the build runner. Documentation outside those inputs doesn't trigger a release. Failed builds and partial publications never become the comparison baseline.

The nightly reuses the tagged release's checks and packaging. It publishes an immutable `nightly-homebrew-<run>-<attempt>` prerelease with `latest=false`, verifies the uploaded bytes, and updates only the explicitly named nightly tap entry. Published Mac apps must pass code-signature and stapled-notarization validation. Stable tags, npm publishing, release emails, and stable casks/formulae are excluded. Previous nightlies remain downloadable. Normal stable-release cleanup must preserve prereleases.

Opt in:

```sh
brew install mcclowes/turnstile/turnstile-nightly
```

The nightly conflicts with the stable package because they install the same app or executable. Uninstall the stable package before switching, and uninstall the nightly before switching back. They share the existing app identity, preferences, and data. These are public, opt-in downloads, not access-controlled internal distribution. Homebrew updates the nightly when you run `brew update` and `brew upgrade`; installing it doesn't enable background upgrades.

The existing signing, notarization, and tap credentials used by `release.yml` are also required by the nightly. The nightly app depends on `turnstile-nightly`, so its CLI and app are updated in one tap commit. Missing credentials, failed checks, an unavailable runner, or rejected tap writes fail the run. They do not advance the delivery baseline. Cross-repository publication uses the existing token or tap deploy key; the source `GITHUB_TOKEN` needs deployments write permission. Concurrent stable and nightly packaging is serialized.

Validate the automation with `node --test scripts/nightly-release.test.mjs` and `actionlint .github/workflows/nightly.yml .github/workflows/release.yml`. Signing and delivery still need a live run with configured credentials. Rollout tracking: mcclowes/workspace#10.
