# Commands

The commands this repo already uses, from CONTRIBUTING.md, the CI workflows, and the headers in `scripts/`. CI runs lint, license checks, coverage, e2e, a release build, and a dev app package; `swift test` and `./scripts/e2e.sh` must pass before a PR. Builds and tests here go through turnstile itself, so they can queue behind other agents.

- Build: `swift build` #quick
- Tests: `swift test` — unit tests #monitor
- E2E: `./scripts/e2e.sh` — the real binary with fake tools in a throwaway turnstile home, never touches ~/.turnstile #monitor
- Coverage: `./scripts/coverage.sh` — unit tests with a per-file report, writes .build/coverage.lcov #monitor
- Lint: `swift format lint --recursive --parallel Sources Tests Package.swift` #quick
- License check: `node --test scripts/license-check-tests.mjs && node scripts/license-check.mjs` — ThirdParty/ records for every dependency #quick
- CI checks: `swift format lint --recursive --parallel Sources Tests Package.swift && node --test scripts/license-check-tests.mjs && node scripts/license-check.mjs && ./scripts/coverage.sh && ./scripts/e2e.sh && swift build -c release && ./scripts/package.sh --dev` — the lint and test jobs from ci.yml, in order #monitor #ci
- Release build: `swift build -c release` #quick
- Menu bar app (dev): `./scripts/package.sh --dev` — ad-hoc signed Turnstile.app, not notarized #quick
- Try local build: `.build/debug/turnstile init` — installs this build for real; `turnstile uninstall` when done #quick
- Doctor: `turnstile doctor` — check the install and daemon #quick
- Status: `turnstile status --watch` — running and queued jobs, memory, recent runs #monitor
- Queue: `turnstile top` — bump, pause, hold, or kill a job #companion
- Restart daemon: `turnstile restart` — queued and running jobs reconnect #quick
- History report: `./scripts/history-report.sh --days 7` — waits, merges, pauses, and peaks from real use #quick
- Benchmark: `./scripts/bench.sh` — three simulated agents through turnstile, results in .build/bench/ #monitor
- Pressure soak: `./scripts/pressure-soak.sh` — real toolchains under faked memory pressure #monitor
- Demo start: `./scripts/demo.sh start` — sandboxed daemon, menu bar app, and fake agent traffic #quick
- Demo shell: `./scripts/demo.sh shell` — a shell wired to the demo, as "you" #companion
- Demo pressure: `./scripts/demo.sh pressure` — the newest agent job is paused #quick
- Demo calm: `./scripts/demo.sh calm` — the paused job resumes #quick
- Demo stop: `./scripts/demo.sh stop` #quick
- Record demo: `./scripts/record-demo.sh` — regenerates website/static/img/demo.svg #quick
- App icon: `./scripts/icon.sh` — regenerates the icon from assets/app-icon.svg, needs rsvg-convert #quick
- Docs site: `cd website && npm start` — Docusaurus dev server #monitor #browser
- Docs checks: `cd website && npm run typecheck && npm test && npm run spell-check && npm run build` — what website.yml runs, minus the link check #monitor
- Publish check: `./scripts/publish.sh --check` — neither repo has this version's release and CHANGELOG.md has notes #quick

## Layout

An agent in the main pane, with the live queue docked beside it.

- Claude: `claude` #primary
- Status: `turnstile status --watch` #monitor
