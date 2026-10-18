# Commands

The commands this repo already uses, from CONTRIBUTING.md, the CI workflows, and the headers in `scripts/`. CI runs lint, license checks, coverage, e2e, a release build, and a dev app package; `swift test` and `./scripts/e2e.sh` must pass before a PR. Builds and tests here go through turnstile itself, so they can queue behind other agents.

- Build: `swift build` #quick #safe
- Tests: `swift test` — unit tests #monitor #safe
- E2E: `./scripts/e2e.sh` — the real binary with fake tools in a throwaway turnstile home, never touches ~/.turnstile #monitor #destructive
- Coverage: `./scripts/coverage.sh` — unit tests with a per-file report, writes .build/coverage.lcov #monitor #safe
- Lint: `swift format lint --recursive --parallel Sources Tests Package.swift` #quick #safe
- License check: `node --test scripts/license-check-tests.mjs && node scripts/license-check.mjs` — ThirdParty/ records for every dependency #quick #safe
- Release helper arguments: `node --test scripts/release-args-tests.mjs` — argument guards with temporary repositories and blocked external tools #quick #safe
- Release note checks: `node --test scripts/release-notes-tests.mjs` — publication helper with temporary repositories and recording tools #quick #safe
- CI checks: `swift format lint --recursive --parallel Sources Tests Package.swift && node --test scripts/license-check-tests.mjs && node scripts/license-check.mjs && node --test scripts/release-args-tests.mjs && node --test scripts/release-notes-tests.mjs && ./scripts/coverage.sh && ./scripts/e2e.sh && swift build -c release && ./scripts/package.sh --dev` — the lint and test jobs from ci.yml, in order #monitor #ci #destructive
- Release build: `swift build -c release` #quick #safe
- Menu bar app (dev): `./scripts/package.sh --dev` — ad-hoc signed Turnstile.app, not notarized #quick #safe
- Try local build: `.build/debug/turnstile init` — installs this build for real; `turnstile uninstall` when done #quick #destructive
- Doctor: `turnstile doctor` — check the install and daemon #quick #safe
- Status: `turnstile status --watch` — running and queued jobs, memory, recent runs #monitor #safe #long-running
- Queue: `turnstile top` — bump, pause, hold, or kill a job #companion #destructive #interactive
- Restart daemon: `turnstile restart` — queued and running jobs reconnect #quick #destructive
- History report: `./scripts/history-report.sh --days 7` — waits, merges, pauses, and peaks from real use #quick #safe
- Benchmark: `./scripts/bench.sh` — three simulated agents through turnstile, results in .build/bench/ #monitor #destructive
- Pressure soak: `./scripts/pressure-soak.sh` — real toolchains under faked memory pressure #monitor #destructive
- Demo start: `./scripts/demo.sh start` — sandboxed daemon, menu bar app, and fake agent traffic #quick #destructive
- Demo shell: `./scripts/demo.sh shell` — a shell wired to the demo, as "you" #companion #destructive #interactive
- Demo pressure: `./scripts/demo.sh pressure` — the newest agent job is paused #quick #safe
- Demo calm: `./scripts/demo.sh calm` — the paused job resumes #quick #safe
- Demo stop: `./scripts/demo.sh stop` #quick #destructive
- Record demo: `./scripts/record-demo.sh` — regenerates website/static/img/demo.svg #quick #writes
- App icon: `./scripts/icon.sh` — regenerates the icon from assets/app-icon.svg, needs rsvg-convert #quick #writes
- Docs site: `cd website && npm start` — Docusaurus dev server #monitor #browser #safe #long-running
- Docs checks: `cd website && npm run typecheck && npm test && npm run spell-check && npm run build` — what website.yml runs, minus the link check #monitor #safe
- Publish check: `./scripts/publish.sh --check` — neither repo has this version's release and CHANGELOG.md has notes #quick #safe

## Layout

An agent in the main pane, with the live queue docked beside it.

- Claude: `claude` #primary #destructive #interactive
- Status: `turnstile status --watch` #monitor #safe #long-running
