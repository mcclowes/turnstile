---
title: turnstile
description: A machine-wide, memory-aware gate for builds and tests on macOS.
slug: /
sidebar_label: Overview
---

import HomepageDemo from '@site/src/components/HomepageDemo';

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

## Turnstile in action

<HomepageDemo />

### From the terminal

![Two agents start builds at once; the second waits for memory until the first finishes, then runs](/img/demo.svg)

![Turnstile status in a terminal with two running jobs and recent command history](/img/screenshots/status.webp)

`turnstile status` gives the same queue a more detailed view, including current memory use, learned estimates, and recent runs.

### Caught in the wild

A real intercept. `npm publish` isn't gated, but its `prepublishOnly` hook runs `npm run build`, which is. That nested build waited for a slot behind two Swift builds, then ran as normal:

```
$ npm publish --access public

> docusaurus-plugin-share-selection@0.1.0 prepublishOnly
> npm run build && npm test && npm run check:exports

turnstile: waiting for a compile slot (running: turnstile swift build -c release, ~865 MB; saggar-desktop-fix546 swift build, ~2.4 GB; +1 more)
turnstile: starting after 27s

> docusaurus-plugin-share-selection@0.1.0 build
> tsup

CLI Building entry: {"index":"src/index.ts"}
...
```

Nobody had to tell the publish script about turnstile. It caught the heavy step wherever it ran.

## Your Mac as CI

The same gate makes it safe to run CI on the machine you work on. A self-hosted runner on your Mac gets Xcode, simulators, and warm caches for free, but on its own it has no idea your agents are compiling. Behind turnstile, a push queues for memory like everything else, runs at background priority, and yields to you. See [your Mac as a CI runner](./start/local-ci.md).

## Where to go next

- [Install](./start/install.md) turnstile and check it's wired up.
- Read [how it works](./concepts/how-it-works.md) to see what gets gated and why.
- Already using worktrees, containers, or cloud agents? See [alternatives](./compare/overview.md).
- Look up a [command](./reference/commands.md) or a [config key](./reference/configuration.md).
- Something off? Start with [troubleshooting](./troubleshooting.md).
