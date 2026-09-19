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

![turnstile status with two running jobs and recent runs](/img/screenshots/status.webp)

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
| `turnstile config` | Show the settings in effect here, and where each came from |
| `turnstile config init` | Write a starter config file |
| `turnstile config check` | Validate the config files, catching typos |
| `turnstile config edit [--project]` | Open the global config (or this project's) in `$EDITOR`, then validate it |
| `turnstile uninstall` | Remove the shims and PATH setup. History is kept |
