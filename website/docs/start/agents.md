---
title: Agents and people
description: How turnstile tells an agent's shell from yours, and what changes when it does.
slug: /agents
---

# Agents and people

turnstile treats commands from coding agents differently from commands you type. Agent commands run at lower priority and queue behind yours. Under memory pressure, agent compiles can be paused; test and browser jobs normally keep running.

## How a shell is identified

In order:

1. `TURNSTILE_AGENT=1` or `TURNSTILE_AGENT=0` forces the answer.
2. Any known agent variable in the environment marks it as an agent: `CLAUDECODE`, `CLAUDE_CODE_ENTRYPOINT`, `CODEX_SANDBOX`, `CODEX_MANAGED_BY_NPM`, `CODEX_THREAD_ID`, `GEMINI_CLI`, `CURSOR_AGENT`, `AIDER_MODEL`, `OPENCODE`, and `AMP_THREAD_ID`.
3. Otherwise, a command with no terminal at all counts as an agent's.

To teach turnstile about another harness, add its variable to [`agentEnv`](../reference/configuration.md#machine-settings) in the global config.

## What changes for an agent

- **Priority.** Compiles run at background priority (`taskpolicy -b`). Tests and browser runs get the gentler utility clamp (`taskpolicy -c utility`), since background priority can starve them into timeouts.
- **Queue order.** Agent jobs queue behind commands you type.
- **Pausing.** Under critical memory pressure, the newest agent compile is paused. Agent tests and browser runs aren't, unless [`throttle.pause`](../reference/configuration.md#commands-scripts-and-throttling) is `true`, and your own jobs never are.
- **Visible waits.** A queued job prints why it's waiting and repeats itself every 30 seconds, so an agent never mistakes a queue for a hang.
- **Clear cancellation.** A job killed with `turnstile kill` exits `125` and prints `cancelled by you, don't retry`, so an agent doesn't treat it as a flaky failure.

`turnstile bump <job>` moves any job to the front, or raises a running compile to normal priority.

## Telling agents how to start builds

Shims only gate what PATH resolves, so an agent that runs `./node_modules/.bin/vitest` or `/usr/bin/swift build` goes around turnstile. `turnstile agents` prints guidance for a project's `AGENTS.md` or `CLAUDE.md` that says to use the tool's usual name, or `turnstile run` for anything else heavy:

```sh
turnstile agents >> AGENTS.md
```

`turnstile doctor` reports what ran outside turnstile anyway.

## Let Turnstile own admission

Submit finite heavy work using the supported gated invocations below. Wait for visible queued or paused work; don't retry outside the gate, disable gating, or negotiate machine-wide heavy-work hold/release broadcasts through Saggar. Turnstile owns admission across the machine. Genuine code/worktree ownership coordination remains appropriate, including agreeing who edits shared files or owns a checkout.

If admission is inaccessible or a command emits a failed-open warning, diagnose and report it rather than bypassing the gate. Run `turnstile doctor --shells` and `turnstile status --json` inside the actual harness. Verify a queued/running job or completed history row; exit zero alone doesn't prove admission. Report the harness, exact socket path, and connection error. A denied observation doesn't establish that the daemon is absent, and unknown memory reads don't establish healthy memory. See [troubleshooting](../troubleshooting.md) for the diagnostic limits and the socket requirements below for external configuration.

## Concurrency and test expectations

Default scheduling permits concurrency: three jobs per class, subject to available memory. Test/browser jobs aren't normally auto-paused because their timeouts keep counting during a pause. SourceKit/IDE work can remain unmanaged, and children of an admitted job share its slot. Admission doesn't promise an exclusive performance-test window or establish why a timing assertion failed.

Prefer deterministic, bounded functional tests: synchronize on observable readiness, use finite deadlines, and retain failure diagnostics. Don't weaken assertions, inflate timeouts indiscriminately, or change Ambient's tests to accommodate shared load. Keep regression diagnosis independent of scheduler pressure unless evidence connects them.

Benchmarks need deliberate methodology. Record competing load and pressure, build mode, warmup, repetitions, and variance; compare equivalent conditions and report interference as a limitation. Explicit machine-exclusive scheduling is a future product decision, not an agent-maintained lock or an existing admission guarantee.

## Codex command and socket integration

Codex can invoke Node by absolute path with a JavaScript entry point, bypassing PATH shims. For finite heavy commands, use the existing explicit wrapper with the appropriate class:

```sh
turnstile run --class test -- node node_modules/vitest/vitest.mjs run
turnstile run --class compile -- /absolute/path/to/node node_modules/typescript/bin/tsc
turnstile run --class browser -- node node_modules/@playwright/test/cli.js test
```

The wrapper preserves arguments, exit status, and nested-job protection. Children of an admitted job share its slot. `run` explicitly gates the requested command, even if normal classification would pass it through, so don't wrap interactive tools, dev servers, or watch commands. Node itself isn't shimmed. SourceKit and IDE compilers remain unmanaged load.

Routing and socket permission are separate requirements. A socket-denied Codex sandbox still runs these wrappers **ungated**, with a warning, under turnstile's deliberate fail-open policy. Adding a writable directory or wrapping the command does not grant socket access.

Codex CLI 0.166.0 exposes an exact socket grant for its standalone sandbox command:

```sh
codex sandbox --allow-unix-socket /Users/YOU/.turnstile/turnstiled.sock \
  turnstile run --class test -- node node_modules/vitest/vitest.mjs run
```

The isolated invocation fixtures verify this path with general networking disabled. This standalone command doesn't configure the sandbox of an already-running agent session. Check `codex help sandbox` for availability in your version.

For a harness that supports Codex permission profiles and Unix socket allowlisting, retain its existing filesystem restrictions and add only turnstile's exact socket path to the active profile. For example, merge this into an existing profile named `project-edit`, substituting your absolute home path:

```toml
[permissions.project-edit.network.unix_sockets]
"/Users/YOU/.turnstile/turnstiled.sock" = "allow"
```

This is a configuration fragment, not a complete profile. The profile must be selected by the harness. Codex's [permissions documentation](https://learn.chatgpt.com/docs/permissions#unix-sockets) describes socket allowlisting and the required network proxy setup. Use the managed proxy with its existing domain policy; don't enable unrestricted network access, allow all Unix sockets, or disable the sandbox to make turnstile work. A socket grant exposes turnstile's local daemon protocol, including job controls, not just admission. Review that capability with the harness owner.

The socket path is printed by `turnstile doctor`; a custom, deeply nested `TURNSTILE_HOME` can use a short `/tmp/turnstile-…sock` path instead. Start the daemon from an ordinary terminal. turnstile won't start one inside a sandbox. To retain captured output, grant write access only to the selected turnstile home's `logs` directory. Without that access, admission can still work, but output isn't retained there.

Restart the harness after an approved configuration change, then run `turnstile doctor --shells` **inside that harness**. Verify admission with a finite command and its queued/running job or completed history row. An exit code of zero alone doesn't prove admission. Install bash startup blocks separately if `$SHELL` selected zsh; see [checking other shells](../troubleshooting.md#checking-other-shells).

Some managed harnesses don't expose the socket permission or don't honor local Codex settings. In that case the integration is unavailable in that sandbox. Report the harness, exact socket path, and connection error to its owner. Don't claim coverage, silently broaden permissions, or treat an unreachable socket as proof the daemon is absent. An explicitly approved execution outside the sandbox can request admission, but that verifies only that approved execution path.
