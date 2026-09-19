---
title: Install
description: Install turnstile with Homebrew, a release binary, or from source.
slug: /install
---

# Install

Requires macOS 26 or later.

## Homebrew

```sh
brew install mcclowes/turnstile/turnstile                                   # CLI only
brew install mcclowes/turnstile/turnstile mcclowes/turnstile/turnstile-app  # CLI and menu bar app
turnstile init
```

Name the formula alongside the app. Homebrew only trusts third-party formulae you name, so `brew install --cask mcclowes/turnstile/turnstile-app` on its own refuses to load the CLI it depends on, unless you've run `brew trust mcclowes/turnstile`.

## Release binary

Download the universal binary from [releases](https://github.com/mcclowes/homebrew-turnstile/releases), then run:

```sh
./turnstile init
```

## From source

You'll need Xcode 26 or later:

```sh
git clone https://github.com/mcclowes/turnstile && cd turnstile
swift build -c release
.build/release/turnstile init
```

## What `init` does

`init` installs the binary in `~/.turnstile/bin` (linked, for Homebrew, so `brew upgrade` carries over), creates the shims, and adds them to the front of PATH in your shell's startup files (zsh, bash, or fish).

Open a new shell, then check everything's wired up:

```sh
turnstile doctor
```

### Managing PATH yourself

Use `turnstile init --no-rc` and put this wherever suits:

```sh
eval "$(turnstile env)"
```

Terminal managers can do the same for the shells they spawn.

## Uninstall

`turnstile uninstall` removes the shims and PATH setup. History is kept. To turn gating off without uninstalling, use `turnstile disable`.
