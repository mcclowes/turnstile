---
title: Commands
description: Every turnstile subcommand.
slug: /commands
---

# Commands

Jobs can be named by queue number, pid, or name.

## Watching the queue

| Command | What it does |
| --- | --- |
| `turnstile status [--json] [--watch]` | Running and queued jobs, memory, and recent runs. `--watch` redraws every second |
| `turnstile top` | Interactive view of the queue. Select a job with ↑↓ or `j`/`k`, then `b` bump, `p` pause/resume, `h` hold/release, `x` kill, `q` quit |
| `turnstile history [--days 30] [--here] [--limit 20] [--json]` | What each command costs and how long jobs waited. `--here` narrows it to this project |

![turnstile status with two running jobs and recent runs](/img/screenshots/status.webp)

## History

`turnstile history` reads the same history the scheduler estimates from, so it shows the numbers behind every admission decision. It works with the daemon asleep.

```
$ turnstile history --days 7
history: 214 jobs in 4 projects over 7 days, 188 from agents

commands:
  project  command        runs  estimate  worst peak  usual time
  api      swift test       42    4.4 GB      4.4 GB       2m10s
  web      npm run build    31    2.6 GB      2.6 GB         48s
  web      vitest run       67    1.4 GB      1.4 GB         31s

waits: 209 started, median 0s, p90 41s, longest 3m02s, 4 over 2m
merged: 18 joined a run already going, 4 replaced by a newer request
outcomes: 11 failed, 1 killed
```

`estimate` is what the next run will be admitted against: the worst peak of that command's last five runs in that project, which is the figure the scheduler itself uses. `worst peak` is the worst anywhere in the window, so a gap between the two means a run once cost much more than turnstile now expects. `usual time` is the median of the last five successful runs, and is what backfilling decides on.

Commands are grouped by project and command, the pair the scheduler learns from, and ordered by worst peak — the number that decides how long a job waits for memory. Runs that merged into another are counted under `merged` but left out of the costs, since they never ran on their own.

Waits over two minutes are called out because an agent harness usually gives a command about that long in total, queue time included. If there are many, the machine is oversubscribed: see [scheduling](/scheduling).

History is kept for 30 days in `~/.turnstile/state.sqlite`, on your machine.

## Controlling jobs

| Command | What it does |
| --- | --- |
| `turnstile bump <job>` | Move a job to the front, or raise a running compile to normal priority |
| `turnstile kill <job>` | Drop a queued job, or stop a running one (SIGTERM, then SIGKILL after 5s). Anyone who joined the run is stopped too |
| `turnstile pause <job>` / `resume <job>` | Stop a running job's processes with SIGSTOP, and carry on. A job you paused stays paused until you resume it |
| `turnstile hold <job>` / `release <job>` | Keep a queued job from starting, and let it go |

## Gating

| Command | What it does |
| --- | --- |
| `turnstile classify <command>` | Show how a command would be gated |
| `turnstile run [--class compile\|test\|browser] -- <command>` | Gate any command, shimmed or not |
| `turnstile disable` / `enable` | Turn gating off and on for every shell, without uninstalling |
| `turnstile stop` | Stop the daemon. Waiting jobs run ungated |

## Setup and config

| Command | What it does |
| --- | --- |
| `turnstile init [--no-rc]` | Install the binary and shims, and add them to PATH |
| `turnstile env` | Print the shell setup, for `eval "$(turnstile env)"` |
| `turnstile shims` | Rebuild the shims after changing `shims.add` or `shims.remove` |
| `turnstile doctor` | Check the install, PATH order, config, and daemon, with a fix for anything wrong |
| `turnstile doctor --shells` | Also check the other shells an agent might start, and the newest Claude Code shell snapshot |
| `turnstile agents` | Print a snippet for a project's `AGENTS.md` or `CLAUDE.md`, telling agents how to start builds |
| `turnstile config` | Show the settings in effect here, and where each came from |
| `turnstile config init` | Write a starter config file |
| `turnstile config check` | Validate the config files, catching typos |
| `turnstile config edit [--project]` | Open the global config (or this project's) in `$EDITOR`, then validate it |
| `turnstile uninstall` | Remove the shims and PATH setup. History is kept |
