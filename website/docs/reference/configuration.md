---
title: Configuration
description: Machine settings, per-project rules, and throttling.
slug: /configuration
---

# Configuration

Everything is optional and the defaults are meant to be left alone. There are two files, both JSON:

- `~/.config/turnstile/config.json` for the machine: limits, memory reserve, and extra shims.
- `.turnstilerc` in any project (found by walking up from the working directory) for that project's commands and throttling. A project can't raise machine limits.

`turnstile config init` writes a starter file, and `turnstile config check` catches mistakes like `"concurency"` with a suggestion. Keys starting with `//` are comments.

The daemon rereads the global file within a few seconds of a change. Project files are read on every command.

## Editor support

Both files have a JSON schema in [`schema/`](https://github.com/mcclowes/turnstile/tree/main/schema), and `config init` adds the `$schema` key for you. `.turnstilerc` has no `.json` extension, so tell VS Code what it is in your settings:

```json
"files.associations": { ".turnstilerc": "json" }
```

## Machine settings

Global file only.

```json
{
  "concurrency": { "compile": 2, "test": 2, "browser": 1 },
  "reserve": "3GB",
  "pauseBelow": 8,
  "resumeAbove": 20,
  "shims": { "add": ["bazel"], "remove": ["make"] },
  "agentEnv": ["MY_AGENT_SESSION"]
}
```

| Key | Default | Meaning |
| --- | --- | --- |
| `concurrency` | a quarter of your cores, 1 to 4, for compile and test; 3 for browser | Max jobs per class at once |
| `reserve` | `"2GB"` | Memory to keep free for everything else |
| `pauseBelow` | `8` | Pause the newest pausable agent job when free memory drops below this percent |
| `resumeAbove` | `20` | Resume paused jobs once free memory is back above this percent |
| `killFloor` | `25` | Floor under the runaway ceiling, as a percent of RAM. Nothing below it is ever a runaway |
| `shims.add` / `shims.remove` | | Extra tools to gate, or built-in ones to drop. Run `turnstile shims` after changing |
| `agentEnv` | | Extra environment variables that mark a shell as an agent's |

## Commands, scripts, and throttling

Either file.

```json
{
  "commands": {
    "swift test": { "class": "test", "memory": "6GB" },
    "make docs": "pass"
  },
  "scripts": {
    "verify": "test",
    "storybook:build": { "class": "compile", "memory": "4GB" }
  },
  "throttle": {
    "jobs": 4,
    "nodeHeap": "4GB",
    "maxMemory": "12GB",
    "killMultiplier": 3,
    "inject": true,
    "pause": true
  }
}
```

`commands` keys are command prefixes, and the longest match wins, with project rules checked before global ones. A rule is a class (`compile`, `test`, or `browser`), `"pass"` to never gate, or an object with a `class` and a `memory` estimate. `scripts` does the same for package.json script names run through npm, pnpm, yarn, or bun.

| `throttle` key | Default | Meaning |
| --- | --- | --- |
| `inject` | `true` | Add parallelism and heap limits to commands. Anything you pass yourself wins |
| `jobs` | auto | Parallelism to inject. Auto leaves it alone until memory is tight (under 25% free), then halves it, and quarters it under 15% |
| `nodeHeap` | auto | Node's `--max-old-space-size`. Auto caps it at 2 GB under 15% free |
| `maxMemory` | none | Hard ceiling. A job tree above it is killed on the spot, whatever the machine is doing |
| `killMultiplier` | `3` | Treat a job as a runaway past this multiple of its high-water peak, never below `killFloor` (25% of RAM). With no history, 75% of RAM. A runaway is left alone while memory is plentiful, paused when it isn't, and killed only if the pause doesn't help |
| `pause` | compile only | Allow this project's agent jobs to be paused under pressure. By default only compiles are, since test and browser runners have deadlines that keep running while paused. `true` lets tests and browser runs be paused too, and `false` never pauses any |

## Sizes

Sizes take `"512MB"`, `"4GB"`, `"1.5 GB"`, or a bare number of megabytes.
