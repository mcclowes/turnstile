---
title: Worktrees and agent orchestrators
description: Conductor, Claude Squad, Vibe Kanban, Crystal, and plain git worktrees, next to turnstile.
slug: /alternatives/orchestrators
sidebar_label: Worktrees and orchestrators
---

# Worktrees and agent orchestrators

Tools like Conductor, Claude Squad, Vibe Kanban, and Crystal give each agent its own workspace, usually a `git worktree`, and wrap it in task management, diffs, and a review flow. Plenty of people do the same by hand with `git worktree add`.

## What they solve

- Two agents editing the same file, or fighting over the index and git locks.
- Branch juggling, and keeping one agent's half-finished work out of another's context.
- Seeing what each agent did, and turning it into a pull request.

This is the right answer to file contention, and turnstile doesn't attempt any of it.

## What they leave

Separate worktrees are still one kernel, one page cache, and one pool of memory. Isolation is what makes it reasonable to run five agents instead of one, so the tool that removed the conflicts is also what raises the number of builds starting at once. The failure mode moves from merge conflicts to swap.

None of these tools sets out to manage machine resources, and it isn't an oversight. An orchestrator can see its own workspaces. It can't see the `xcodebuild` you started in a terminal, the agent you're running under a different tool, or the Gradle daemon left over from an hour ago.

## Using both

turnstile sits underneath. It doesn't care which tool started the shell, so agents in any orchestrator, agents in a bare terminal, and commands you type yourself all queue against the same slots and the same memory. There's nothing to configure per workspace, and no adapter per tool.

Two things worth checking:

- **PATH.** `turnstile init` edits your shell's startup file. A tool that spawns agents without a login shell may not pick up the shims. Run `turnstile doctor` from inside an agent's shell to confirm, and see [install](../start/install.md) for setting PATH yourself.
- **Agent detection.** turnstile recognizes the common harnesses by environment variable and puts their commands behind yours. If a tool isn't recognized, set `TURNSTILE_AGENT=1` in the environment it launches agents with. See [agents and people](../start/agents.md).
