---
title: Containers and VMs
description: Sculptor, devcontainers, Docker, and OrbStack, next to turnstile.
slug: /alternatives/containers
sidebar_label: Containers and VMs
---

# Containers and VMs

Some tools isolate each agent in a container rather than a worktree. Sculptor works this way, and devcontainers, plain Docker, and OrbStack get you there by hand.

## What they solve

- Blast radius. A bad migration or a rogue `rm` stays inside the box.
- Reproducible toolchains, and a clean environment per agent.
- A hard ceiling. Container runtimes cap memory and CPU per container, and the cap is enforced rather than advisory.

That last one is real resource control, and it's the one thing on this page turnstile can't do: turnstile shapes and defers, it doesn't enforce a ceiling on a process that ignores it.

## What they leave

The ceiling is per container. Four agents capped at 8 GB each is 32 GB, and nothing stops all four from claiming it at once. The limit keeps one agent from eating the machine; it doesn't stop all of them from doing it together.

On macOS there's a second cost. Containers run in a Linux VM with a fixed memory allotment, so you're dividing a smaller pot, and memory the VM has claimed is unavailable to the host whether it's in use or not. Native work on the same Mac, which for most people means Xcode, simulators, and anything on a device, is competing with a block of memory it can't see.

## Using both

turnstile gates on the host. Commands inside a container don't go through the host's shims, so it won't queue them and won't count them. What it does see is the VM's footprint, as one large process, which is what the host actually has to live with.

In practice:

- Size the container runtime's memory deliberately, and treat it as gone.
- Use turnstile for what runs natively: Xcode builds, simulator runs, native test suites, and your own commands.
- If everything heavy is in containers, turnstile has little left to gate. That's a fine reason not to run it.

This is on the [limits](../concepts/limits.md) page too, and it isn't going to change: the shims are per machine, and a container is a different machine as far as PATH is concerned.
