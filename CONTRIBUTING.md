# Contributing

Thanks for helping. Bug reports, fixes, and ideas are all welcome.

## Before you start

- **Bugs:** open an issue with the output of `turnstile doctor` and `turnstile --version`, your macOS version, and the command that misbehaved. `~/.turnstile/daemon.log` often has the answer.
- **Features and larger changes:** open an issue first, so we can agree on the approach before you write code. turnstile sits in front of every build on the machine, so changes to gating, admission, or the shims get a careful look.
- **Questions:** use [Discussions](https://github.com/mcclowes/turnstile/discussions).

## Development

You'll need macOS 26 or later and Xcode 26 or later.

```sh
swift build
swift test             # unit tests
./scripts/e2e.sh       # end-to-end, with fake tools in a throwaway turnstile home
./scripts/coverage.sh  # unit tests with a coverage report
swift format lint --strict --recursive --parallel Sources Tests Package.swift
node --test scripts/release-args-tests.mjs scripts/package-tests.mjs scripts/dist-tests.mjs # release helpers with isolated tools
node --test scripts/e2e-server-tests.mjs   # run-scoped process detection and cleanup
node --test scripts/history-report-tests.mjs # report arguments and isolated SQLite data
/usr/bin/python3 scripts/e2e-top-tests.py # PTY handshakes and delayed terminal restoration
./scripts/fingerprint-timing.sh # isolated 60k-file fingerprint timings; FILES changes the size
```

`swift format` ships with Xcode and reads `.swift-format`; `swift format --in-place <file>` fixes most of what the lint reports.

`scripts/history-report.sh` reads history with a default 30-day period. It also
accepts exactly `--days <positive-integer>`. Invalid inputs exit 2 before reading
history. Its fixtures use disposable databases and never read your real history.

Packaging stages replacements until signing and release validation succeed.
The release checksum is computed before publication. Backup and promotion
failures or handled interruptions restore the previous app and ZIP. If
restoration fails, the error identifies retained recovery files.
`scripts/package.sh --dev` replaces only the app and preserves the release ZIP. The helper tests use
temporary projects without building, signing, or contacting a notary service.

Distribution assembly also stages the CLI tarball, app ZIP, and checksums before
replacing `.build/dist`. A failed archive, package, copy, or checksum step keeps
the previous distribution. Its fixtures use real archive/checksum tools with
synthetic binaries and a stubbed app packager.

Final publication keeps a backup until the new distribution is in place. A
failed move or handled interruption restores the previous directory. If
restoration fails, the error reports retained recovery directories rather than
discarding the backup.

The e2e script never touches your real `~/.turnstile`. To try a local build for real, run `.build/debug/turnstile init`, and `turnstile uninstall` when you're done.

`./scripts/fingerprint-timing.sh /path/to/repo` measures an existing repository without modifying it. The target is a p95 below 300 ms; the timing test uses a longer deadline so it can measure regressions beyond the production one-second limit.

The code is split into three targets:

- `TurnstileCore`: classification, config, scheduling, and history. Pure logic lives here, and so do most tests.
- `turnstile`: the CLI, the shim's supervisor, and the daemon.
- `TurnstileBar`: the menu bar app.

The docs site lives in `website/` (`npm install && npm start`).

turnstile has no package dependencies. Adding one, or a new `.linkedLibrary`, needs a reviewed license record in `ThirdParty/`; `node scripts/license-check.mjs` fails CI until it has one. [ThirdParty/README.md](ThirdParty/README.md) has the steps.

## Pull requests

- Keep each PR to one change, with tests. A bug fix should come with a test that fails without it.
- Make sure `swift test` and `./scripts/e2e.sh` pass.
- Update the docs in `website/docs/` when behavior changes, and add a line to [CHANGELOG.md](CHANGELOG.md) under "Unreleased".
- Commit messages start with a type: `Feature:`, `Bug:`, `Chore:`, `Refactor:`, or `Dependency:`, then an imperative summary.

By contributing, you agree your work is released under the [MIT license](LICENSE), and to follow the [code of conduct](CODE_OF_CONDUCT.md).
