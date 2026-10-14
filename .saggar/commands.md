# Commands

The commands this repo already uses, from CONTRIBUTING.md, the CI workflows, and the headers in `scripts/`. CI runs lint, license checks, coverage, e2e, a release build, and a dev app package; `swift test` and `./scripts/e2e.sh` must pass before a PR. Builds and tests here go through turnstile itself, so they can queue behind other agents.

Effects describe the listed invocations with their default environment. Safe commands may write build output and caches. Global installation, process controls, and stress workloads require explicit execution intent. Interactive commands need a terminal; long-running commands stay open until stopped.

- Build: `swift build` #safe #quick
- Tests: `swift test` — unit tests #safe #monitor
- Fingerprint timing: `./scripts/fingerprint-timing.sh` — disposable 60k-file repository in four states #safe #monitor
- E2E: `./scripts/e2e.sh` — isolated state, file-gated pressure/restart fixtures, and run-scoped escaped-server cleanup #safe #monitor
- Coverage: `./scripts/coverage.sh` — unit tests with a per-file report, writes .build/coverage.lcov #safe #monitor
- Lint: `swift format lint --strict --recursive --parallel Sources Tests Package.swift` #safe #quick
- License check: `node --test scripts/license-check-tests.mjs && node scripts/license-check.mjs` — ThirdParty/ records for every dependency #safe #quick
- Release helper arguments: `node --test scripts/release-args-tests.mjs` — reject invalid inputs before invoking build or publishing tools #safe #quick
- History report inputs: `node --test scripts/history-report-tests.mjs` — argument rejection and read-only reports with isolated SQLite data #safe #quick
- E2E server isolation: `node --test scripts/e2e-server-tests.mjs` — concurrent process fixtures cannot match or stop each other #safe #quick
- E2E top driver: `/usr/bin/python3 scripts/e2e-top-tests.py` — PTY handshakes and delayed terminal restoration with a fake CLI #safe #quick
- CI checks: `swift format lint --strict --recursive --parallel Sources Tests Package.swift && node --test scripts/license-check-tests.mjs && node scripts/license-check.mjs && node --test scripts/release-args-tests.mjs && node --test scripts/history-report-tests.mjs && node --test scripts/e2e-server-tests.mjs && /usr/bin/python3 scripts/e2e-top-tests.py && ./scripts/coverage.sh && ./scripts/e2e.sh && swift build -c release && ./scripts/package.sh --dev` — the lint and test jobs from ci.yml, in order #safe #monitor #ci
- Release build: `swift build -c release` #safe #quick
- Menu bar app (dev): `./scripts/package.sh --dev` — ad-hoc signed Turnstile.app, not notarized #safe #quick
- Try local build: `.build/debug/turnstile init` — changes real shims, shell startup files, and installed binary #destructive #quick
- Doctor: `turnstile doctor` — checks the install; may start the daemon and write its cache/history #safe #quick
- Status: `turnstile status --watch` — running and queued jobs, memory, recent runs #safe #long-running #monitor
- Queue: `turnstile top` — controls real jobs, including kill #destructive #interactive #companion
- Restart daemon: `turnstile restart` — replaces the live daemon; queued and running jobs reconnect #destructive #quick
- History report: `./scripts/history-report.sh --days 7` — read-only SQLite queries and log summaries #safe #quick
- Benchmark: `./scripts/bench.sh` — memory stress with simulated agents, results in .build/bench/ #destructive #monitor
- Pressure soak: `./scripts/pressure-soak.sh` — real toolchains under faked memory pressure #destructive #monitor
- Demo start: `./scripts/demo.sh start` — replaces the real menu bar app with a demo and launches fake traffic #destructive #quick
- Demo shell: `./scripts/demo.sh shell` — interactive shell with unrestricted user commands #destructive #interactive #companion
- Demo pressure: `./scripts/demo.sh pressure` — pauses jobs in the isolated demo #safe #quick
- Demo calm: `./scripts/demo.sh calm` — resumes jobs in the isolated demo #safe #quick
- Demo stop: `./scripts/demo.sh stop` — kills demo processes, removes its tree, and reopens the real app #destructive #quick
- Record demo: `./scripts/record-demo.sh` — regenerates website/static/img/demo.svg #writes #quick
- App icon: `./scripts/icon.sh` — regenerates tracked app icons, needs rsvg-convert #writes #quick
- Docs site: `cd website && npm start` — Docusaurus dev server #safe #long-running #monitor #browser
- Docs checks: `cd website && npm run typecheck && npm test && npm run spell-check && npm run build` — what website.yml runs, minus the link check #safe #monitor
- Publish check: `./scripts/publish.sh --check` — read-only GitHub release checks and changelog inspection #safe #quick

## Layout

An agent in the main pane, with the live queue docked beside it.

- Claude: `claude` — interactive agent with external service access #destructive #interactive #primary
- Status: `turnstile status --watch` #safe #long-running #monitor
