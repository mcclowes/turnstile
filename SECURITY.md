# Security

turnstile puts shims first on your PATH, runs a daemon on a Unix socket, and can pause and kill processes. Bugs there can matter, so please report them privately.

## Reporting a vulnerability

Use [GitHub's private vulnerability reporting](https://github.com/mcclowes/turnstile/security/advisories/new). Don't open a public issue.

Include what you found, how to reproduce it, and the output of `turnstile --version`. You'll get a reply within a week, and a fix or a plan soon after. Once a fix ships, you'll be credited in the advisory unless you'd rather not be.

## Supported versions

Only the latest release gets fixes.

## What's in scope

- Anything that lets another user or process run commands as you, through the socket, the shims, or files in `~/.turnstile`.
- Pausing, killing, or reprioritizing processes turnstile didn't start.
- Changes to shell startup files beyond turnstile's own marked block.
- Tampering with release artifacts, the Homebrew tap, or `init`'s install path.
