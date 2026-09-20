# Changelog

Notable changes to turnstile. Versions follow [semantic versioning](https://semver.org/).

## Unreleased

### Added

- Small jobs can start ahead of a job that's waiting for memory, for its first 2 minutes of waiting.
- Jobs that should finish before a memory-blocked job could start go ahead of it, using learned run times.
- The daemon learns each command's run time (the median of its last five successful runs, not counting time paused), and waits say roughly when a job should start.
- `scripts/bench.sh` and `scripts/history-report.sh`, for measuring turnstile's effect on a machine.
- A docs site at [turnstile.marginalutility.dev](https://turnstile.marginalutility.dev).

### Changed

- turnstile now needs macOS 26 or later.
- Agent tests and browser runs get the utility clamp rather than background priority, which could starve them into timeouts.
- A command's first run in a project starts from its median peak in other projects, and release and debug builds keep separate histories.
- Installing the menu bar app means naming the formula alongside the cask, so Homebrew trusts the tap.

## 0.3.1

### Changed

- Releases are published to [mcclowes/homebrew-turnstile](https://github.com/mcclowes/homebrew-turnstile), with a formula for the CLI and a cask for the signed, notarized menu bar app.

## 0.3.0

The first release.

- Shims for `swift`, `xcodebuild`, `cargo`, `go`, `gradle`, `make`, `npm`, `pnpm`, `yarn`, `bun`, `npx`, `vitest`, `jest`, `playwright`, and `tsc` that queue heavy commands for a slot and free memory, and pass everything else straight through.
- A daemon that starts on demand, learns each command's memory peak, lowers parallelism under memory pressure, pauses agent jobs when memory is critical, and kills runaways.
- `status`, `top`, `bump`, `kill`, `pause`, `resume`, `hold`, `release`, `doctor`, `config`, `classify`, `run`, `disable`, and `enable`.
- A menu bar app.
- JSON schemas for `config.json` and `.turnstilerc`.
