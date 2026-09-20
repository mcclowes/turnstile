---
title: turnstile
description: A machine-wide, memory-aware gate for builds and tests on macOS.
slug: /
sidebar_label: Overview
---

# turnstile

A machine-wide, memory-aware gate for builds and tests on macOS.

Run three coding agents across a few worktrees and they'll happily start three `swift test`s, two `npm run build`s, and a Playwright suite at once. Each agent's limits are sensible on their own. Together they swap your Mac into the ground.

turnstile sits underneath the shell, so it works the same for Claude Code, Codex, any other agent, and you. Heavy commands queue for a slot and for free memory, then run in place with the same output, exit code, working directory, environment, and Ctrl-C. Everything else passes straight through.

```
$ swift test
turnstile: waiting for memory, needs ~4 GB, ~1.2 GB spare (running: api swift test, ~3 GB; web npm run build, ~2 GB)
turnstile: starting after 41s
...
```

There's no project setup. Once it's installed, every repo, agent, and terminal on the machine is covered.

## Where to go next

- [Install](./start/install.md) turnstile and check it's wired up.
- Read [how it works](./concepts/how-it-works.md) to see what gets gated and why.
- Already using worktrees, containers, or cloud agents? See [alternatives](./compare/overview.md).
- Look up a [command](./reference/commands.md) or a [config key](./reference/configuration.md).
- Something off? Start with [troubleshooting](./troubleshooting.md).
