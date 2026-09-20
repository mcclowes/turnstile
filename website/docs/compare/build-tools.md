---
title: Build tool limits
description: Job flags, worker counts, and Bazel's resource model, next to turnstile.
slug: /alternatives/build-tools
sidebar_label: Build tool limits
---

# Build tool limits

Every build tool ships a way to cap itself.

| Tool | Flag |
| --- | --- |
| swift, make, cargo | `-j`, `--jobs`, `CARGO_BUILD_JOBS` |
| xcodebuild | `-jobs` |
| vitest, jest | `--maxWorkers` |
| playwright | `--workers` |
| turbo, nx | `--concurrency`, `--parallel` |
| gradle | `--max-workers` |
| bazel | `--jobs`, `--local_ram_resources` |

Set inside one repo, for one tool, these work. Bazel goes furthest: it models local RAM and CPU as resources and schedules its actions against them, which is the same idea turnstile applies, one level up.

## Where they run out

**Each tool assumes it's alone.** The defaults come from your core count, so on a 12-core Mac every tool on the machine independently concludes it may have twelve. Three agents running three tools is three reasonable defaults and one unreasonable machine.

**The ceiling is inside one process tree.** Bazel's resource model covers Bazel's actions in Bazel's server. It has no opinion about the Playwright suite in the next worktree, and nothing to tell it one is starting.

**Turning them down globally costs you the quiet times.** You can put `-j 4` in every config and cap the workers everywhere, and you'll pay for it on the mornings when nothing else is running. The number that survives four concurrent agents is much too low for one.

## Using both

Keep your flags. turnstile leaves parallelism alone while there's memory to spare, and only lowers it when free memory gets tight, by injecting `--jobs`, `--maxWorkers`, `CARGO_BUILD_JOBS`, and Node's heap cap. Anything you pass yourself wins, so an explicit `-j 4` stays `-j 4`. See [memory pressure](../concepts/pressure.md) for the thresholds, and [`throttle`](../reference/configuration.md#commands-scripts-and-throttling) to change them.

The division is roughly: your flags decide how a tool behaves when it has the machine, and turnstile decides when it does.
