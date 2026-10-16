# Commands

The commands this repo already uses, from CONTRIBUTING.md, the CI workflows, and the headers in `scripts/`. CI runs lint, license checks, coverage, e2e, a release build, and a dev app package; `swift test` and `./scripts/e2e.sh` must pass before a PR. Builds and tests here go through turnstile itself, so they can queue behind other agents.

- Build: `swift build` #quick #safe
- Tests: `swift test` — unit tests #monitor #safe
- E2E: `./scripts/e2e.sh` — the real binary with fake tools in a temporary home; cleanup can kill another E2E run's escaped server #monitor #destructive
- Coverage: `./scripts/coverage.sh` — unit tests with a per-file report, writes .build/coverage.lcov #monitor #safe
- Lint: `swift format lint --recursive --parallel Sources Tests Package.swift` #quick #safe
- License check: `node --test scripts/license-check-tests.mjs && node scripts/license-check.mjs` — ThirdParty/ records for every dependency #quick #safe
- E2E top driver: `/usr/bin/python3 scripts/e2e-top-tests.py` — PTY handshakes and delayed restoration using a fake CLI, without a daemon #quick #safe #ci
- History report checks: `node --test scripts/history-report-tests.mjs` — argument validation and read-only reports against temporary databases #quick #safe #ci
- CI checks: `swift format lint --recursive --parallel Sources Tests Package.swift && node --test scripts/license-check-tests.mjs && node scripts/license-check.mjs && /usr/bin/python3 scripts/e2e-top-tests.py && node --test scripts/history-report-tests.mjs && ./scripts/coverage.sh && ./scripts/e2e.sh && swift build -c release && ./scripts/package.sh --dev` — the lint and test jobs from ci.yml, including E2E's process-wide cleanup #monitor #ci #destructive
- Release build: `swift build -c release` #quick #safe
- Menu bar app (dev): `./scripts/package.sh --dev` — builds and signs .build/Turnstile.app ad hoc; removes the previous app and release ZIP #quick #safe
- Try local build: `.build/debug/turnstile init` — replaces the installed binary/shims and edits shell startup files; uninstall when done #quick #destructive
- Doctor: `turnstile doctor` — checks install/config and can start the daemon, writing cached history/logs #quick #safe
- Status: `turnstile status --watch` — watches running/queued jobs and memory; can open cached history when the daemon is asleep #monitor #safe #long-running
- Queue: `turnstile top` — interactive controls for live jobs: bump, pause, hold, or kill #companion #destructive #interactive
- Restart daemon: `turnstile restart` — replaces the live daemon; queued and running jobs reconnect #quick #destructive
- History report: `./scripts/history-report.sh --days 7` — reads installed history with SQLite mode=ro; reports waits, merges, pauses, and peaks #quick #safe
- Benchmark: `./scripts/bench.sh` — stresses real machine memory/CPU with isolated jobs; results in .build/bench/ #monitor #destructive
- Pressure soak: `./scripts/pressure-soak.sh` — runs real toolchains under simulated admission pressure; results in .build/soak/ #monitor #destructive
- Demo start: `./scripts/demo.sh start` — starts isolated demo traffic and replaces the running menu bar app #quick #destructive
- Demo shell: `./scripts/demo.sh shell` — an unrestricted interactive shell wired to the demo, as "you" #companion #destructive #interactive
- Demo pressure: `./scripts/demo.sh pressure` — writes the temporary demo pressure level so its newest agent job pauses #quick #safe
- Demo calm: `./scripts/demo.sh calm` — writes the temporary demo pressure level so its paused job resumes #quick #safe
- Demo stop: `./scripts/demo.sh stop` — kills demo processes, removes /tmp/turnstile-demo, and reopens the installed app if needed #quick #destructive
- Record demo: `./scripts/record-demo.sh` — regenerates website/static/img/demo.svg #quick #writes
- App icon: `./scripts/icon.sh` — rewrites assets/AppIcon.icns and website/static/img/apple-touch-icon.png; needs rsvg-convert #quick #writes
- Docs site: `cd website && npm start` — Docusaurus dev server #monitor #browser #safe #long-running
- Docs checks: `cd website && npm run typecheck && npm test && npm run spell-check && npm run build` — what website.yml runs, minus the link check #monitor #safe
- Publish check: `./scripts/publish.sh --check` — reads GitHub release metadata and CHANGELOG.md; exits before publishing or pushing #quick #safe

## Layout

An agent in the main pane, with the live queue docked beside it.

- Claude: `claude` — interactive agent with external services and access to local tools #primary #destructive #interactive
- Status: `turnstile status --watch` — watches running/queued jobs and memory; can open cached history when the daemon is asleep #monitor #safe #long-running
