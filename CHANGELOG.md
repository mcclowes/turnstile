# Changelog

Notable changes to turnstile. Versions follow [semantic versioning](https://semver.org/).

## 0.8.1

### Changed

- Recent jobs in the menu bar show their stats on one line, separated by a middle dot, with the full command in a tooltip.

### Fixed

- The version-skew fix now relinks the installed binary, so it no longer restarts a stale daemon when `~/.turnstile/bin` holds a copy.
- Test jobs use a test tube icon instead of a completion tick.

## 0.8.0

### Added

- The Tools tab shows every supported tool in a table with its live gated status and real binary path.
- Health fixes can be copied or run in Terminal directly from the menu bar app.
- Every docs page is available as raw Markdown, alongside `llms.txt`, `llms-full.txt`, Mermaid diagrams, and an Open with AI menu.

### Changed

- Compile and test jobs get 3 slots by default, matching browser, instead of a quarter of your cores.
- The menu bar ties each running job to its memory-bar segment by color, labels the next job, and puts memory estimates beside job footprints.

### Fixed

- A job paused under memory pressure gets first claim on recovered memory, while small jobs can still pass it briefly when they'll finish before its calm period ends.
- New work waits until memory has stayed calm for 30 seconds, avoiding false recoveries during swap churn.

## 0.7.0

### Added

- A Limits tab in Settings for slots per class, memory to keep free, pausing under memory pressure, runaway limits, and build parallelism. It edits only those keys in the global config, and "Open config file" reaches the rest. Clicking the slot chips in the menu bar opens it.

### Changed

- Browser jobs get 3 slots by default instead of 1, since they're generally light.
- The menu bar count includes running jobs as well as queued ones, so 2 running and 1 waiting reads as 3, not 1.
- The menu bar icon no longer changes when the daemon exits while idle, which looked like a fault.

### Fixed

- Tooltips in the menu bar panel hang below their anchor, so the panel edge no longer clips them.

## 0.6.0

### Added

- Pause the whole queue from the menu bar. Running jobs carry on, nothing new starts, and waiting callers are told why. Resuming takes effect on the daemon's next tick.

### Changed

- The menu bar panel shows less. Memory reads as a share of the machine ("52% of 16 GB"), and a running job's memory as a share of its estimate. The slot counts sit beside the memory figure instead of the version. Running jobs drop their number, and the "Memory vs. estimate" label is gone; hover the bar for the detail.
- A recent run's icon explains how it ended on hover, and opens its log when clicked, replacing the separate log button.
- The gating switch, notification switches, and "Launch at login" have moved from the panel to a new General tab in Settings. While gating is off, the panel shows a banner with a button to turn it back on.

### Fixed

- The Settings button in the menu bar panel brings the Settings window to the front instead of opening it behind other windows.
- The empty state's padding is even, and slot chips explain themselves on hover.

## 0.5.0

### Added

- The menu bar app has a gating switch below the job list, the same flag as `turnstile disable` and `enable`, so it works without a shell or a running daemon. While gating is off the icon turns into a red slashed shield whatever else is going on, and `turnstile doctor` says how long it's been off (#45).
- The menu bar app notifies you when a job you queued (not an agent's) starts after waiting two minutes or more, and when one of your runs fails. Each kind of notification has its own switch under Notifications in the panel footer, with the new "Queue is clear" notice off by default. A job paused for memory can be resumed or killed from its notification, and a clear queue arrives quietly rather than breaking Focus (#48).
- The menu bar app says when nothing is gated, and why: the CLI isn't set up, the shims are missing, no command has gone through the shims yet, the config is invalid, or the daemon and the app are from different releases. The icon turns red or orange, and the menu shows the fix (#47).
- The menu bar app counts down to when a waiting job should start, and its elapsed times tick between polls. Status snapshots carry the expected start as `startsAt`. Right-click a job to open its folder (#44).
- The menu bar panel is wider and easier to scan. Commands get their own line, rows only name a state their section doesn't (paused, held), and waiting reasons get up to three lines. The two most recent runs are always visible, with the rest a click away. Queued jobs show a "Move to front" button, other controls appear in place on hover without shifting the row, and memory bars say they measure memory against the estimate, not progress (#57).
- `turnstile logs <job> [-f]` prints the output captured from a run with no terminal, which is most agent runs. `-f` follows it until the run ends. In the menu bar app, right-click a running job to open or follow its log, or a recent run to open it; failed runs show a log button. Status snapshots carry the path as `log` on running jobs and recent runs, only while the file exists. Logs of failed, signaled, and killed runs are now kept for a week instead of a day (#46).
- `turnstile doctor` says how much of the last day the daemon was up when it reports builds that ran outside turnstile, since it only sees them while awake, and says when it saw nothing. An idle daemon that has seen such a build stays up for 4 hours after the last one instead of 30 minutes (#30).
- `turnstile restart` replaces the daemon without releasing its queued and running jobs. Installing a newer version uses the same recovery path when the existing daemon supports it.
- Releases are built, signed, and notarized by a GitHub Actions workflow when a version is tagged, with build provenance attestations for the CLI and the app. Check one with `gh attestation verify "$(which turnstile)" --repo mcclowes/turnstile` (#24).

### Fixed

- The menu bar app's settings window and active-job list now reserve enough height for their contents.
- A job paused for memory no longer flips between paused and running every few seconds on a machine that stays over-committed. Each pressure pause doubles the calm it waits for before resuming, from 30 seconds up to 8 minutes (#35).
- Admission estimates remember cold builds. They used the worst of the last five runs, so after a few incremental builds a 2.4 GB compile was admitted at about 45 MB and two could start side by side. They now use the worst of the last twenty runs from the past month, the same figure as the runaway ceiling.

## 0.4.0

### Added

- `turnstile history` shows what the scheduler has learned: per project and command, the estimate the next run will be admitted against, the worst peak seen, and the usual run time, plus queue waits, merged runs, and outcomes. Takes `--here`, `--days`, `--limit`, and `--json`, and works with the daemon asleep.
- Small jobs can start ahead of a job that's waiting for memory, for its first 2 minutes of waiting.
- Jobs that should finish before a memory-blocked job could start go ahead of it, using learned run times.
- The daemon learns each command's run time (the median of its last five successful runs, not counting time paused), and waits say roughly when a job should start.
- `scripts/bench.sh` and `scripts/history-report.sh`, for measuring turnstile's effect on a machine.
- A docs site at [turnstile.marginalutility.dev](https://turnstile.marginalutility.dev).
- Menu bar settings for choosing which command shims Turnstile installs.

### Changed

- turnstile now needs macOS 26 or later.
- Agent tests and browser runs get the utility clamp rather than background priority, which could starve them into timeouts.
- Automatic memory pauses apply to compile jobs by default. Test and browser runners keep running because their wall-clock deadlines continue while stopped; projects can still opt in.
- A command's first run in a project starts from its median peak in other projects, and release and debug builds keep separate histories.
- Installing the menu bar app means naming the formula alongside the cask, so Homebrew trusts the tap.
- Swap growth now stops admissions and pauses eligible work even when macOS's free-memory level looks healthy.
- Runaways are left alone while memory is plentiful, then paused before Turnstile kills them under sustained pressure.

### Fixed

- Escaped child processes stay attached to their job after launchd adopts them, so pause and kill still cover the whole process tree.
- Shell setup, sandbox detection, and diagnostics catch more paths that could bypass the shims.

## 0.3.1

### Changed

- Releases are published to [mcclowes/homebrew-turnstile](https://github.com/mcclowes/homebrew-turnstile), with a formula for the CLI and a cask for the signed, notarized menu bar app.

## 0.3.0

The first release.

- Shims for `swift`, `xcodebuild`, `cargo`, `go`, `gradle`, `make`, `npm`, `pnpm`, `yarn`, `bun`, `npx`, `vitest`, `jest`, `playwright`, and `tsc` that queue heavy commands for a slot and free memory, and pass everything else straight through.
- A daemon that starts on demand, learns each command's memory peak, lowers parallelism under memory pressure, pauses agent jobs when memory is critical, and kills runaways.
- `status`, `top`, `bump`, `kill`, `pause`, `resume`, `hold`, `release`, `doctor`, `config`, `classify`, `run`, `disable`, and `enable`.
- A menu bar app.
- JSON schemas for `config.json` and `.turnstilerc`.
