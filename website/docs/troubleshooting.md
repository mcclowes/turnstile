---
title: Troubleshooting
description: Fixes for common problems.
slug: /troubleshooting
---

# Troubleshooting

Start with `turnstile doctor`. It checks each link from your shell to the daemon and prints a fix for anything broken.

## Commands aren't being gated

Usually something reordered PATH after turnstile's block, such as a version manager initialized late in `.zshrc`. `doctor` names the tools that resolve around the shims. Rerun `turnstile init`, which moves its block to the end of your startup files.

In zsh and bash, the block also moves the shims back to the front before each prompt, so `nvm use` or `mise activate` can't leave them behind. If your startup files predate that hook, rerun `turnstile init` to get it.

Calls by absolute path, such as `/usr/bin/make`, always go around the shims. See [limits](./concepts/limits.md).

## Commands in a sandboxed agent run ungated

Agent sandboxes, such as Codex's, usually block the daemon's socket, so gated commands there run ungated and print `can't reach the daemon from inside this sandbox`. To gate them, allow the sandbox to connect to `~/.turnstile/turnstiled.sock` (for Codex, that may mean turning on network access in its sandbox settings). turnstile never starts the daemon from inside a sandbox, so it can't pick up the sandbox's limits. Run `turnstile doctor` once from an ordinary shell to start it.

## Checking other shells

`turnstile doctor --shells` runs `zsh -c`, `zsh -lc`, `zsh -ic`, and `bash -lc` from a bare environment and reports any shell where a tool resolves ahead of the shims. It also checks the newest Claude Code shell snapshot: a session that started before `turnstile init` keeps the PATH it had, so its commands run ungated until you start a new one.

## Finding runs that went ungated

When a gated command can't reach the daemon it runs anyway, and records the run in `~/.turnstile/ungated.log`: the time, the cause, the directory, and the command. `turnstile doctor` reports the last day's count and the most recent cause.

## A job is waiting longer than expected

`turnstile status` shows what's running and why each job waits. `turnstile bump <job>` moves one to the front.

## Something's wrong and you need to work now

`turnstile disable` turns gating off everywhere at once. `turnstile enable` turns it back on. For a single shell, set `TURNSTILE_DISABLE=1`.

## Logs

The daemon logs to `~/.turnstile/daemon.log`. Output from runs without a terminal is kept in `~/.turnstile/logs` for a day, or a week if the run failed. Read it with `turnstile logs <job>`, or right-click the job in the menu bar app.
