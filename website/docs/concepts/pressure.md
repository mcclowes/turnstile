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

## Stop runaways

A job past its ceiling is a runaway *candidate*, not something to kill outright. The ceiling is three times the command's high-water peak in this project — the highest of its last twenty runs in the past month, not its recent average, because a cold compile can be tens of times an incremental one. It never falls below `killFloor` (25% of RAM), and with no history at all it's 75% of RAM.

What happens next depends on the machine, because memory a job isn't taking from anyone costs nothing:

- **Plenty free.** The job keeps running. It's told once that it's using more than usual, and the daemon log records it.
- **Free memory under `pauseBelow`.** The job is paused with SIGSTOP, like any job paused for memory, and resumes once memory recovers.
- **Still under `pauseBelow` 15 seconds later.** Pausing didn't help, so the job is killed: SIGTERM, then SIGKILL after 5 seconds. The reason says it was turnstile's memory guard and that retrying won't help unless the run needs less memory.

`maxMemory` is the exception. It's an explicit limit someone asked for, so a job tree above it is killed straight away, whatever the machine is doing.
