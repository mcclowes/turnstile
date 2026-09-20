---
title: Memory pressure
description: What turnstile does when memory gets tight.
slug: /pressure
---

# Memory pressure

Admission keeps most trouble out, but jobs grow. turnstile responds in three steps.

## Watch swap, not just free memory

Free memory on macOS is `kern.memorystatus_level`, and the kernel holds it up by compressing and paging out. Once that starts, the level measures the stand-off rather than the room a new job has: a machine can sit at 30% free while it writes gigabytes to swap.

So turnstile also watches how fast swap is growing. If it grows by more than 256 MB in 20 seconds, the machine counts as swapping, and four times that, or a critical `kern.memorystatus_vm_pressure_level`, counts as critical. While either holds, nothing new starts, parallelism drops to its lowest setting, and jobs pause. Nothing is admitted until swap has been quiet for the rest of the window.

How much swap is *in use* is not a signal. A machine that has been busy sits on gigabytes of cold swap and reads "warn" all day with plenty of room; only growth means pages are going out right now.

An idle machine is the exception: the head of the queue always starts, since waiting can't free memory that nothing is holding.

## Lower parallelism

When memory runs low, turnstile lowers each tool's parallelism by injecting `--jobs`, `--maxWorkers`, `CARGO_BUILD_JOBS`, and Node's heap cap. Anything you pass yourself wins.

By default it leaves parallelism alone until free memory drops under 25%, then halves it, and quarters it under 15%. Node's heap is capped at 2 GB under 15% free. See [`throttle`](../reference/configuration.md#commands-scripts-and-throttling) to change this.

## Pause the newest agent job

If free memory drops below `pauseBelow` (8% by default), or the machine is swapping whatever the level says, the newest agent job is paused with SIGSTOP. It resumes once free memory is back above `resumeAbove` (20%) and swap is quiet again. Your own jobs are never paused, and a project can opt out with `"throttle": {"pause": false}`.

One job always keeps running, so work still progresses and the pauses can't deadlock.

## Kill runaways

A job that runs far past its usual peak is killed, with the reason printed. By default that's three times its usual peak (at least 2 GB), or 75% of RAM with no history. `maxMemory` sets a hard ceiling.
