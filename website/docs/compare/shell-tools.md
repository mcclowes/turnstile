---
title: Shell tools
description: sem, niceload, flock, nice, taskpolicy, and make -l, next to turnstile.
slug: /alternatives/shell-tools
sidebar_label: Shell tools
---

# Shell tools

The Unix answer to "don't run all of this at once" has existed for decades, it's already installed or one `brew install` away, and for a single known command it works.

| Tool | What it does |
| --- | --- |
| `sem -j 2 -- swift test` | GNU parallel's counting semaphore. Blocks until fewer than `-j` wrapped commands are running. |
| `flock /tmp/build.lock swift test` | Mutual exclusion on a lock file. One at a time, no counting. |
| `niceload swift build` | Slows a running program while the load average is above a limit. |
| `nice`, `taskpolicy -b` | Lowers scheduling priority. |
| `make -l 8`, `ninja -l 8` | Holds off starting more jobs while the load average is above a threshold. |

If you have one repo, one heavy command, and one shell, an alias around `sem` is less software than a daemon, and you should use it.

## Where they run out

**Someone has to wrap the command.** This is the big one. An agent that decides to run `swift test` types `swift test`. It doesn't know about your semaphore, it won't read a convention you wrote down, and an agent that has to opt in is one that eventually doesn't. turnstile intercepts at PATH, so the plain command is already gated.

**Load average isn't memory.** Load counts runnable threads. Two 6 GB link steps show a modest load right up to the moment they don't fit, and a Mac deep into swap can look calm. turnstile admits on free memory, read from `kern.memorystatus_level`, and on what the command actually used last time.

**A slot count is a guess.** `-j 2` is the same number whether the two jobs are a `tsc` and a `swift test`. turnstile expects a peak per command per project, [learned from recent runs](../concepts/scheduling.md), and asks whether that fits right now.

**One semaphore, one kind of load.** turnstile gives `compile`, `test`, and `browser` [separate slots](../concepts/how-it-works.md#what-gets-gated), so a Playwright suite doesn't hold up a type check.

**Nothing happens after the start.** A semaphore's job is done once it lets you through. Jobs grow after that, and turnstile keeps going: [lower parallelism, pause the newest agent job, kill a runaway](../concepts/pressure.md).

**No ordering.** `sem` is first come, first served, which means the agent that woke up first is ahead of you. turnstile puts [your commands first](../start/agents.md), and `turnstile bump` moves anything to the front.

## Not a rejection

turnstile uses these ideas rather than replacing them. Priority is `taskpolicy`, the same call `nice` is reaching for. What it adds is the part that's tedious to build out of shell: interception, per-command memory history, classes, and the response to pressure once things are already running.
