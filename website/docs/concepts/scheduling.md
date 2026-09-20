---
title: Scheduling
description: How turnstile decides when a queued job starts.
slug: /scheduling
---

# Scheduling

A job starts when its class has a free slot and its expected peak memory fits in free memory, minus a [reserve](../reference/configuration.md#machine-settings) for everything else. Nothing starts at all while the machine is [swapping](pressure.md), since free memory means nothing in that state.

## Learned peaks

Expected peaks are learned from each command's last few runs in that project, with release and debug builds kept apart. A command new to a project starts from its median peak in other projects.

## Learned run times

Run times are learned too, as the median of the last five successful runs, not counting time paused. Waits say roughly when the job should start, when that's known.

## Backfilling

A job waiting for memory holds up the queue behind it, with two exceptions:

- A job that fits and should finish before the blocked one could start goes ahead, going by run times.
- When run times aren't known, only small jobs (up to 5% of RAM, at least 512 MB) that fit can go ahead, and only during the blocked job's first 2 minutes of waiting.

Neither applies while the machine is swapping; then nothing goes ahead of anything.

## Priority

Commands you type go ahead of agent commands. See [agents and people](../start/agents.md). `turnstile bump <job>` moves anything to the front.
