---
title: Memory pressure
description: What turnstile does when memory gets tight.
slug: /pressure
---

# Memory pressure

Admission keeps most trouble out, but jobs grow. turnstile responds in three steps.

## Lower parallelism

When memory runs low, turnstile lowers each tool's parallelism by injecting `--jobs`, `--maxWorkers`, `CARGO_BUILD_JOBS`, and Node's heap cap. Anything you pass yourself wins.

By default it leaves parallelism alone until free memory drops under 25%, then halves it, and quarters it under 15%. Node's heap is capped at 2 GB under 15% free. See [`throttle`](../reference/configuration.md#commands-scripts-and-throttling) to change this.

## Pause the newest agent job

If free memory drops below `pauseBelow` (8% by default), the newest agent job is paused with SIGSTOP. It resumes once free memory is back above `resumeAbove` (20%). Your own jobs are never paused, and a project can opt out with `"throttle": {"pause": false}`.

## Kill runaways

A job that runs far past its usual peak is killed, with the reason printed. By default that's three times its usual peak (at least 2 GB), or 75% of RAM with no history. `maxMemory` sets a hard ceiling.
