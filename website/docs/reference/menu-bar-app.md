---
title: Menu bar app
description: Watch and control the queue without a terminal.
slug: /menu-bar-app
---

# Menu bar app

![The turnstile menu, showing free memory, two running jobs, and recent runs](/img/screenshots/menu.webp)

turnstile works in the background, so there's also a menu bar app for when no terminal is open on it. The icon shows how many jobs are queued, and turns into a warning when memory is low or a job has been paused for it. Each job in the menu has bump, pause or hold, and kill. You get a notification when a job is paused for memory or killed as a runaway.

```sh
brew install mcclowes/turnstile/turnstile mcclowes/turnstile/turnstile-app
```

The cask depends on the `turnstile` formula rather than bundling its own CLI, so uninstalling the app leaves the CLI in place. To build it from source instead:

```sh
./scripts/package.sh --dev && open .build/Turnstile.app
```

It only watches the daemon, polling every 2 seconds, and never starts it or keeps it alive. When the daemon is idle the menu says so, and picks it up again when it starts.

Open it once and turn on "Launch at login" from its menu.
