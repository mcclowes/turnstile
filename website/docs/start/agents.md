---
title: Agents and people
description: How turnstile tells an agent's shell from yours, and what changes when it does.
slug: /agents
---

# Agents and people

turnstile treats commands from coding agents differently from commands you type. Agent commands run at lower priority, queue behind yours, and are the first to be paused when memory runs out.

## How a shell is identified

In order:

1. `TURNSTILE_AGENT=1` or `TURNSTILE_AGENT=0` forces the answer.
2. Any known agent variable in the environment marks it as an agent: `CLAUDECODE`, `CLAUDE_CODE_ENTRYPOINT`, `CODEX_SANDBOX`, `CODEX_MANAGED_BY_NPM`, `CODEX_THREAD_ID`, `GEMINI_CLI`, `CURSOR_AGENT`, `AIDER_MODEL`, `OPENCODE`, and `AMP_THREAD_ID`.
3. Otherwise, a command with no terminal at all counts as an agent's.

To teach turnstile about another harness, add its variable to [`agentEnv`](../reference/configuration.md#machine-settings) in the global config.

## What changes for an agent

- **Priority.** Compiles run at background priority (`taskpolicy -b`). Tests and browser runs get the gentler utility clamp (`taskpolicy -c utility`), since background priority can starve them into timeouts.
- **Queue order.** Agent jobs queue behind commands you type.
- **Pausing.** Under critical memory pressure, the newest agent job is paused. Your own jobs never are.
- **Visible waits.** A queued job prints why it's waiting and repeats itself every 30 seconds, so an agent never mistakes a queue for a hang.
- **Clear cancellation.** A job killed with `turnstile kill` exits `125` and prints `cancelled by you, don't retry`, so an agent doesn't treat it as a flaky failure.

`turnstile bump <job>` moves any job to the front, or raises a running compile to normal priority.

## Telling agents how to start builds

Shims only gate what PATH resolves, so an agent that runs `./node_modules/.bin/vitest` or `/usr/bin/swift build` goes around turnstile. `turnstile agents` prints a few lines for a project's `AGENTS.md` or `CLAUDE.md` that say to use the tool's usual name, or `turnstile run` for anything else heavy:

```sh
turnstile agents >> AGENTS.md
```

`turnstile doctor` reports what ran outside turnstile anyway.
