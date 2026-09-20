---
title: Cloud agents
description: Claude Code on the web, Codex Cloud, and hosted runners, next to turnstile.
slug: /alternatives/cloud
sidebar_label: Cloud agents
---

# Cloud agents

Claude Code on the web, Codex Cloud, Cursor's cloud agents, and hosted CI runners all take the same route: the agent and its builds run on someone else's machine, each session in its own VM.

## What they solve

The machine problem, completely. A build that runs in a data center doesn't compete for your memory, and the number of agents you can run stops being a function of your RAM. If your work fits this model, it's the most thorough answer on this page, and turnstile has nothing to add.

## What they leave

- **The local loop.** Reviewing, iterating, and the run you want to watch still happen on your Mac, and they're still the fastest way to work on something you're actively holding in your head.
- **Work that can't leave.** Xcode builds, simulators, physical devices, code your employer won't put on a third-party VM, and anything that needs local state, credentials, or a running service.
- **Cost and quota.** Cloud sessions are metered, by plan or by the minute. Local compute is already paid for.
- **Fixed session size.** Each session gets a set VM, so a build heavier than that VM has nowhere to go, and a build much lighter is paying for the whole thing.

## Using both

Most people who run cloud agents also keep agents on their laptop, and the local ones are the ones that fight. turnstile only gates what runs locally, so the two don't interact: send the long, parallel, low-attention work to the cloud, and let turnstile order what's left.

If the cloud has taken all the heavy work, don't install turnstile. If you've noticed that the local half is still where the machine falls over, that's exactly the half it's for.
