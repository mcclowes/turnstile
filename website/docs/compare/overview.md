---
title: Alternatives
description: How turnstile relates to worktrees, containers, cloud agents, and the job flags you already have.
slug: /alternatives
sidebar_label: Overview
---

# Alternatives

Most ways of running several agents at once solve a different problem from turnstile's. Worktrees keep agents out of each other's files. Containers keep a mistake inside a box. Cloud agents move the work off your Mac. Job flags cap one tool. All of them are useful, and nearly all of them compose with turnstile rather than replace it.

| Approach | What it controls | Scope |
| --- | --- | --- |
| [Worktrees and orchestrators](./orchestrators.md) | Which files an agent can touch | Per agent |
| [Containers and VMs](./containers.md) | What an agent can reach, and its ceiling | Per container |
| [Cloud agents](./cloud.md) | Whose machine the work runs on | Per session |
| [Shell tools](./shell-tools.md) | How many wrapped commands run at once | Per command you remember to wrap |
| [Build tool limits](./build-tools.md) | One tool's internal parallelism | Per invocation |
| turnstile | What starts on the machine, and when | Every shell, repo, and agent |

## The gap they share

Each of these draws its boundary around one agent, one container, or one tool. None of them has a view of the machine.

Three agents, each politely capped at four compile jobs, is twelve compile jobs. Three test runners, each sizing its worker pool from your core count, each believe they have the machine to themselves. Nothing in that picture is misconfigured, and the Mac still swaps.

turnstile draws the boundary around the machine instead. A `swift test` in one worktree knows about the `npm run build` in another, because both went through the same gate.

## When you don't need turnstile

- **One or two agents.** A modern Mac absorbs that. Come back when you're running four.
- **Far more RAM than your builds need.** If your heaviest concurrent load still leaves headroom, gating buys you nothing.
- **Everything heavy runs in the cloud.** See [cloud agents](./cloud.md).
- **One repo, one heavy command.** A `sem` alias is less software to install. See [shell tools](./shell-tools.md).

## What turnstile adds

- Admission by [free memory and learned peaks](../concepts/scheduling.md), not by a job count you guessed.
- [Classes](../concepts/how-it-works.md#what-gets-gated) with separate slots, so a browser suite and a type check aren't the same kind of load.
- [Pressure relief](../concepts/pressure.md) once jobs are already running: lower parallelism, then pause, then kill a runaway.
- [Your commands ahead of agents'](../start/agents.md), and never paused.
- No per-project setup, and [no hard failure](../concepts/how-it-works.md#the-daemon) if the daemon isn't there.

It also has real [limits](../concepts/limits.md), and they're worth reading before you decide.
