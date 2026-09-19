---
title: Limits
description: What turnstile can't see or gate.
slug: /limits
---

# Limits

- **macOS only.** Memory readings come from `kern.memorystatus_level` and per-process footprints.
- **Absolute paths.** Calls such as `/usr/bin/make` go around the shims.
- **npm scripts.** npm puts `node_modules/.bin` first on PATH inside scripts, so turnstile gates the `npm run` itself rather than the `vitest` it calls.
- **Build servers.** Build servers (Gradle, Kotlin) that detach to launchd still count against the job that started them, while it runs, as long as whatever started them lived for at least a second. A server reused by a later job counts against neither.
