# turnstile

A machine-wide, memory-aware gate for builds and tests on macOS.

Run three coding agents across a few worktrees and they'll happily start three `swift test`s, two `npm run build`s, and a Playwright suite at once. Each agent's limits are sensible on their own. Together they swap your Mac into the ground.

turnstile sits underneath the shell, so it works the same for Claude Code, Codex, any other agent, and you. Heavy commands queue for a slot and for free memory, then run in place with the same output, exit code, working directory, environment, and Ctrl-C. Everything else passes straight through.

```
$ swift test
turnstile: waiting for memory, needs ~4 GB, ~1.2 GB spare (running: api swift test, ~3 GB; web npm run build, ~2 GB)
turnstile: starting after 41s
...
```

## Install

Requires macOS 26 or later.

```sh
brew install mcclowes/turnstile/turnstile                                # CLI only
brew install mcclowes/turnstile/turnstile mcclowes/turnstile/turnstile-app  # CLI + menu bar app
turnstile init
```

Name the formula alongside the app: Homebrew only trusts third-party formulae you name, so `brew install --cask mcclowes/turnstile/turnstile-app` on its own refuses to load the CLI it depends on, unless you've run `brew trust mcclowes/turnstile`.

Or download the universal binary from [releases](https://github.com/mcclowes/homebrew-turnstile/releases) and run `./turnstile init`. To build from source, you'll need Xcode 26 or later:

```sh
git clone https://github.com/mcclowes/turnstile && cd turnstile
swift build -c release
.build/release/turnstile init
```

`init` installs the binary in `~/.turnstile/bin` (linked, for Homebrew, so `brew upgrade` carries over), creates the shims, and adds them to the front of PATH in your shell's startup files (zsh, bash, or fish). Open a new shell, then check everything's wired up:

```sh
turnstile doctor
```

There's no project setup. Every repo, agent, and terminal on the machine is covered from here on.

If you'd rather manage PATH yourself, use `turnstile init --no-rc` and put `eval "$(turnstile env)"` wherever suits. Terminal managers can do the same for the shells they spawn.

## How it works

- **Shims.** `~/.turnstile/shims` holds symlinks named `swift`, `cargo`, `npm`, and so on, all pointing at one binary. Each works out whether the command is heavy. Quick ones (`swift --version`, `npm install`, `cargo fmt`) `exec` the real tool in a few milliseconds without touching the daemon.
- **The daemon** starts on the first gated command, listens on a Unix socket in `~/.turnstile`, and exits after 30 idle minutes. There's nothing to launch or keep running.
- **Admission** is per class (compile, test, and browser each get their own slots) and by memory. A job starts when its class has a free slot and its expected peak fits in free memory, minus a reserve for everything else. Expected peaks are learned from each command's last few runs in that project, with release and debug builds kept apart. A command new to a project starts from its median peak in other projects. Run times are learned too, as the median of the last five successful runs, not counting time paused. A job waiting for memory holds up the queue behind it, except for jobs that fit and should finish before it could start, going by run times. When run times aren't known, only small jobs (up to 5% of RAM, at least 512 MB) that fit can go ahead, and only during its first 2 minutes of waiting. Waits say roughly when the job should start, when that's known.
- **Waiting is visible.** A queued job prints why it's waiting and repeats itself every 30 seconds, so an agent never mistakes a queue for a hang.
- **People go first.** Commands from an agent run at lower priority and queue behind commands you type. Compiles run at background priority (`taskpolicy -b`); tests and browser runs get the gentler utility clamp (`taskpolicy -c utility`), since background priority can starve them into timeouts. `turnstile bump <job>` moves anything to the front.
- **Duplicate runs merge.** The same command on identical working-tree contents joins the run in progress and gets its output and exit code. A newer request from the same worktree replaces its queued older one.
- **Nested calls pass through.** `swift test` calling `swift build` doesn't wait on itself.
- **Pressure relief.** When memory runs low, turnstile lowers each tool's parallelism (`--jobs`, `--maxWorkers`, `CARGO_BUILD_JOBS`, Node's heap cap). If it gets critical, the newest agent job is paused with SIGSTOP and resumed once memory recovers. A job that runs far past its usual peak is killed, with the reason printed.
- **It fails open.** If the daemon is missing or broken, commands run ungated rather than failing. If it crashes, running jobs re-register with a fresh one and waiting jobs requeue, so limits still hold, and anything it had paused carries on.

Gated by default: `swift`, `xcodebuild`, `cargo`, `go`, `gradle`, `make`, `npm`, `pnpm`, `yarn`, `bun`, `npx`, `vitest`, `jest`, `playwright`, and `tsc`. Package scripts are classified by name: `test`, `test:unit`, and `ci` are tests; `e2e` and `playwright` are browser runs; `build`, `lint`, and `typecheck` are compiles; `dev`, `start`, and `watch` pass through. Run `turnstile classify <command>` to see what any command would do.

## Commands

| Command | What it does |
| --- | --- |
| `turnstile status [--json] [--watch]` | Running and queued jobs, memory, and recent runs. `--watch` redraws every second |
| `turnstile top` | Interactive view of the queue. Select a job with ↑↓ or `j`/`k`, then `b` bump, `p` pause/resume, `h` hold/release, `x` kill, `q` quit |
| `turnstile bump <job>` | Move a job (by number, pid, or name) to the front, or raise a running compile to normal priority |
| `turnstile kill <job>` | Drop a queued job, or stop a running one (SIGTERM, then SIGKILL after 5s). Anyone who joined the run is stopped too |
| `turnstile pause <job>` / `resume <job>` | Stop a running job's processes with SIGSTOP, and carry on. A job you paused stays paused until you resume it |
| `turnstile hold <job>` / `release <job>` | Keep a queued job from starting, and let it go |
| `turnstile doctor` | Check the install, PATH order, config, and daemon, with a fix for anything wrong |
| `turnstile config` | Show the settings in effect here, and where each came from |
| `turnstile config check` | Validate the config files, catching typos |
| `turnstile config edit [--project]` | Open the global config (or this project's) in `$EDITOR`, then validate it |
| `turnstile classify <command>` | Show how a command would be gated |
| `turnstile run [--class compile\|test\|browser] -- <command>` | Gate any command, shimmed or not |
| `turnstile disable` / `enable` | Turn gating off and on for every shell, without uninstalling |
| `turnstile stop` | Stop the daemon; waiting jobs run ungated |
| `turnstile uninstall` | Remove the shims and PATH setup. History is kept |

## Menu bar app

turnstile works in the background, so there's also a menu bar app for when no terminal is open on it. The icon shows how many jobs are queued, and turns into a warning when memory is low or a job has been paused for it. Each job in the menu has bump, pause or hold, and kill. You get a notification when a job is paused for memory or killed as a runaway.

```sh
brew install mcclowes/turnstile/turnstile mcclowes/turnstile/turnstile-app
```

The cask depends on the `turnstile` formula rather than bundling its own CLI, so uninstalling the app leaves the CLI in place. To build it from source instead, run `./scripts/package.sh --dev && open .build/Turnstile.app`.

It only watches the daemon, polling every 2 seconds, and never starts it or keeps it alive. When the daemon is idle the menu says so, and picks it up again when it starts. Open it once and turn on "Launch at login" from its menu.

## Configuration

Everything is optional and the defaults are meant to be left alone. There are two files, both JSON:

- `~/.config/turnstile/config.json` for the machine: limits, memory reserve, and extra shims.
- `.turnstilerc` in any project (found by walking up from the working directory) for that project's commands and throttling. A project can't raise machine limits.

`turnstile config init` writes a starter file, and `turnstile config check` catches mistakes like `"concurency"` with a suggestion. Keys starting with `//` are comments.

For autocomplete and inline errors as you type, both files have a JSON schema in [`schema/`](schema), and `config init` adds the `$schema` key for you. `.turnstilerc` has no `.json` extension, so tell VS Code what it is in your settings:

```json
"files.associations": { ".turnstilerc": "json" }
```

### Machine settings (global file only)

```json
{
  "concurrency": { "compile": 2, "test": 2, "browser": 1 },
  "reserve": "3GB",
  "pauseBelow": 8,
  "resumeAbove": 20,
  "shims": { "add": ["bazel"], "remove": ["make"] },
  "agentEnv": ["MY_AGENT_SESSION"]
}
```

| Key | Default | Meaning |
| --- | --- | --- |
| `concurrency` | a quarter of your cores, 1 to 4, for compile and test; 1 for browser | Max jobs per class at once |
| `reserve` | `"2GB"` | Memory to keep free for everything else |
| `pauseBelow` | `8` | Pause the newest agent job when free memory drops below this percent |
| `resumeAbove` | `20` | Resume paused jobs once free memory is back above this percent |
| `shims.add` / `shims.remove` | | Extra tools to gate, or built-in ones to drop. Run `turnstile shims` after changing |
| `agentEnv` | | Extra environment variables that mark a shell as an agent's |

### Commands, scripts, and throttling (either file)

```json
{
  "commands": {
    "swift test": { "class": "test", "memory": "6GB" },
    "make docs": "pass"
  },
  "scripts": {
    "verify": "test",
    "storybook:build": { "class": "compile", "memory": "4GB" }
  },
  "throttle": {
    "jobs": 4,
    "nodeHeap": "4GB",
    "maxMemory": "12GB",
    "killMultiplier": 3,
    "inject": true,
    "pause": true
  }
}
```

`commands` keys are command prefixes, and the longest match wins, with project rules checked before global ones. A rule is a class (`compile`, `test`, or `browser`), `"pass"` to never gate, or an object with a `class` and a `memory` estimate. `scripts` does the same for package.json script names run through npm, pnpm, yarn, or bun.

| `throttle` key | Default | Meaning |
| --- | --- | --- |
| `inject` | `true` | Add parallelism and heap limits to commands. Anything you pass yourself wins |
| `jobs` | auto | Parallelism to inject. Auto leaves it alone until memory is tight (under 25% free), then halves it, and quarters it under 15% |
| `nodeHeap` | auto | Node's `--max-old-space-size`. Auto caps it at 2 GB under 15% free |
| `maxMemory` | none | Hard ceiling; a job tree above it is killed |
| `killMultiplier` | `3` | Kill a job that passes this multiple of its usual peak (at least 2 GB). With no history, the ceiling is 75% of RAM |
| `pause` | `true` | Allow this project's agent jobs to be paused under pressure |

Sizes take `"512MB"`, `"4GB"`, `"1.5 GB"`, or a bare number of megabytes.

The daemon rereads the global file within a few seconds of a change. Project files are read on every command.

### Environment variables

| Variable | Effect |
| --- | --- |
| `TURNSTILE_DISABLE=1` | Commands in this shell pass straight through |
| `TURNSTILE_AGENT=1` / `0` | Force whether this shell counts as an agent. Otherwise, known agent variables or no terminal at all mean an agent |
| `TURNSTILE_HOME` | Where shims, the socket, and history live. Default `~/.turnstile` |
| `TURNSTILE_CONFIG_DIR` | Directory holding `config.json`. Default `~/.config/turnstile` |

## Troubleshooting

Start with `turnstile doctor`. It checks each link from your shell to the daemon and prints a fix for anything broken.

- **Commands aren't being gated.** Usually something reordered PATH after turnstile's block, such as a version manager initialized late in `.zshrc`. `doctor` names the tools that resolve around the shims. Rerun `turnstile init`, which moves its block to the end of your startup files.
- **A job is waiting longer than expected.** `turnstile status` shows what's running and why each job waits. `turnstile bump <job>` moves one to the front.
- **Something's wrong and you need to work now.** `turnstile disable` turns gating off everywhere at once; `turnstile enable` turns it back on.
- **Logs.** The daemon logs to `~/.turnstile/daemon.log`. Output from runs without a terminal is kept in `~/.turnstile/logs` for a day.

Exit codes are the tool's own. turnstile adds `125` when someone ran `turnstile kill` on the job (it prints `cancelled by you, don't retry`, so agents don't mistake it for a flaky failure), `126` when the tool couldn't start, and `127` when it isn't installed. If a run you joined is cancelled, your command runs on its own instead.

## Limits

- macOS only. Memory readings come from `kern.memorystatus_level` and per-process footprints.
- Calls by absolute path, such as `/usr/bin/make`, go around the shims.
- npm puts `node_modules/.bin` first on PATH inside scripts, so turnstile gates the `npm run` itself rather than the `vitest` it calls.
- Build servers (Gradle, Kotlin) that detach to launchd still count against the job that started them, while it runs, as long as whatever started them lived for at least a second. A server reused by a later job counts against neither.

## Development

```sh
swift test             # unit tests
./scripts/e2e.sh       # end-to-end, with fake tools in a throwaway turnstile home
```

The docs site lives in [`website/`](website) (Docusaurus). Run `npm install && npm start` there to preview it.

To release, bump `Turnstile.version` in `Sources/TurnstileCore/Paths.swift`, commit, and run `./scripts/release.sh` on a Mac with the Developer ID certificate and the `kiln-notary` notarytool profile. It tests, builds the universal CLI tarball and the notarized `Turnstile.app`, tags this repo, publishes both to a release on [mcclowes/homebrew-turnstile](https://github.com/mcclowes/homebrew-turnstile), and updates the tap's formula and cask. Releases are manual while CI is down.
