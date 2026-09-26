You are reviewing how Max actually uses turnstile on this Mac, to find product improvements. Work from evidence in the history, not from the code's intentions.

## Data (read-only)

- `turnstile history` and `turnstile history --here`: summary of estimates, peaks, waits.
- `sqlite3 -readonly ~/.turnstile/state.sqlite`: tables `jobs` (state, class, key, root, cwd, argv, agent, estimate, peak, exit_code, signal, outcome, joined_to, queued_at, started_at, finished_at, ran_for, min_level, max_pressure, paused_for, would_pause), `escapes` (commands that ran outside the gate), `daemon_runs`.
- `~/.turnstile/daemon.log`, `~/.turnstile/ungated.log`, `~/.turnstile/logs/` (per-run output; skim failures only).
- Previous reports in `~/.turnstile/reviews/`. Read the latest one first and focus on what changed since.

Never write to `~/.turnstile` except the new report file. Never stop, pause, or modify the daemon or jobs.

## Look for

- Long queue waits (queued_at → started_at), and whether the gating was worth it (estimate vs actual peak, memory pressure while waiting).
- Estimates that are badly wrong, or commands that never get an estimate.
- Escapes: what runs ungated and why; shims or wrappers that are missing.
- Jobs killed, paused, or failed by turnstile itself, and joins (`joined_to`) that did or didn't save work.
- Friction signals: repeated re-runs, cancelled jobs, bursts of agents all queued behind one build.
- Daemon restarts or errors in `daemon.log`.

Compare with the current code and open issues (`gh issue list --state all --limit 200`) so you don't re-report known or fixed things.

## Output

1. Write a private report to `~/.turnstile/reviews/YYYY-MM-DD.md`: headline numbers, then ranked findings with the evidence (queries and figures) behind each. For each finding, note whether an existing issue covers it.
2. Print a one-paragraph summary with the report path.

Don't open or comment on issues, edit code, commit, or push. Be direct and sparing; a run with no new findings should say so.
