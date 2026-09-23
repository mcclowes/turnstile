---
title: Your Mac as a CI runner
description: Run CI on the machine you work on, without it fighting your agents or you.
slug: /local-ci
---

# Your Mac as a CI runner

A self-hosted runner on your own Mac is free, fast, and has everything a hosted runner doesn't: Xcode, simulators, signing identities, and warm caches. The reason people don't do it is that CI has no idea anything else is running. A push kicks off a full build and test suite while three agents are compiling, and the machine you're working on swaps to a halt.

turnstile makes that setup safe. CI jobs queue for the same slots and the same memory as everything else, so a push waits its turn instead of piling on.

## What CI gets

- **Its place in the queue.** A runner's commands have no terminal, so turnstile treats them like an agent's: they run at lower priority and queue behind anything you type.
- **Memory-aware admission.** A CI build starts when there's room for it, using the peak turnstile has learned from its recent runs in that checkout.
- **Pressure relief.** Under critical memory pressure, a CI compile is paused before any of your own jobs are touched. Tests aren't paused, since their timeouts keep counting.
- **Visible waits.** A queued job prints why it's waiting every 30 seconds, so the CI log shows a queue, not a hang.
- **Nothing to break.** If the daemon isn't there, commands run ungated. CI never fails because of turnstile.

## Set up a GitHub Actions runner

A runner started as a service doesn't read your shell's startup files, so it won't see the shims until you put them on its PATH. The runner reads its PATH from the `.path` file in its install directory. Put the shims first:

```sh
cd ~/actions-runner
echo "$HOME/.turnstile/shims:$(cat .path)" > .path
./svc.sh stop && ./svc.sh start
```

To do it per workflow instead, add a step before the build:

```yaml
- run: echo "$HOME/.turnstile/shims" >> "$GITHUB_PATH"
```

Setup actions such as `actions/setup-node` also prepend to PATH, so a toolchain they install can land in front of the shims. Run the setup step first and the shims step after it, or call the heavy steps through `turnstile run`:

```yaml
- run: turnstile run -- npm test
```

Other runners (GitLab, Buildkite, Jenkins agents) work the same way: get `~/.turnstile/shims` to the front of the job's PATH, or use `turnstile run`.

## Check it's gated

Push something, then watch the queue while it runs:

```sh
turnstile status --watch
```

CI jobs show up alongside your agents' with their runner checkout as the project. `turnstile logs <job>` shows a job's output, and `turnstile bump <job>` moves it to the front when you're waiting on a green build.

## Limits

- **Containers.** Jobs that run inside a container (`container:` in GitHub Actions, or `act`) don't go through the host's shims. Only the container runtime's footprint is counted. See [limits](../concepts/limits.md).
- **Your jobs first.** CI is treated as background work. To give a runner equal footing with you, set `TURNSTILE_AGENT=0` in the runner's `.env` file.
