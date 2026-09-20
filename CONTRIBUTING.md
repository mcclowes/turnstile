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
```

The e2e script never touches your real `~/.turnstile`. To try a local build for real, run `.build/debug/turnstile init`, and `turnstile uninstall` when you're done.

The code is split into three targets:

- `TurnstileCore`: classification, config, scheduling, and history. Pure logic lives here, and so do most tests.
- `turnstile`: the CLI, the shim's supervisor, and the daemon.
- `TurnstileBar`: the menu bar app.

The docs site lives in `website/` (`npm install && npm start`).

## Pull requests

- Keep each PR to one change, with tests. A bug fix should come with a test that fails without it.
- Make sure `swift test` and `./scripts/e2e.sh` pass.
- Update the docs in `website/docs/` when behavior changes, and add a line to [CHANGELOG.md](CHANGELOG.md) under "Unreleased".
- Commit messages start with a type: `Feature:`, `Bug:`, `Chore:`, `Refactor:`, or `Dependency:`, then an imperative summary.

By contributing, you agree your work is released under the [MIT license](LICENSE), and to follow the [code of conduct](CODE_OF_CONDUCT.md).
