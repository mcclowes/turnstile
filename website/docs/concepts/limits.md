---
title: Limits
description: What turnstile can't see or gate.
slug: /limits
---

# Limits

- **macOS only.** Memory readings come from `kern.memorystatus_level` and per-process footprints.
- **Absolute paths.** Calls such as `/usr/bin/make` go around the shims.
- **Xcode.** Builds started in Xcode never go through a shell, so nothing can gate them. They still lower free memory, so admission control accounts for them.
- **npm scripts.** npm puts `node_modules/.bin` first on PATH inside scripts, so turnstile gates the `npm run` itself rather than the `vitest` it calls.
- **Build servers.** Build servers (Gradle, Kotlin) that detach to launchd still count against the job that started them, while it runs, as long as whatever started them lived for at least a second. A server reused by a later job counts against neither.

## Seeing what escaped

While the daemon is awake it watches for heavy processes that belong to no job: compilers started by absolute path or by Xcode, `node_modules/.bin` test runners, and tools that aren't shimmed. It records what ran, what started it, and where. `turnstile doctor` and `turnstile top` show the last day's and the last hour's:

```
note  ungated   ran outside turnstile in the last day: 14 × swift-frontend under Xcode in ~/app, 3 × node vitest under zsh in ~/web
```

A tool that itself spawned one of these counts once, not once per compiler process.
