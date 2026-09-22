# Third-party licenses

turnstile is MIT licensed (see [LICENSE](../LICENSE)). The files here track the licenses of software it builds against; they don't license turnstile itself.

`licenses.json` is the reviewed inventory, and `scripts/license-check.mjs` holds the build to it:

- Every remote package in `Package.swift` and `Package.resolved` needs a record with its exact source URL, revision, version, SPDX license list, and a SHA-256 for every notice file in `Notices/`.
- Every `.linkedLibrary` in `Package.swift` needs a `systemLibraries` record saying why it doesn't need to ship a notice.

Today turnstile has no package dependencies and links only the system SQLite, so nothing third-party ships in the CLI tarball or `Turnstile.app`.

When a dependency is added or changes:

1. Resolve it and inspect the exact checkout under `.build/checkouts/`.
2. Review its root license, notices, vendored code notices, and any license change from the previous revision. A package's headline license isn't enough when it bundles code under other terms.
3. Copy every required file verbatim into `Notices/`, update `licenses.json`, and keep `reviewed` false until the terms and distribution obligations have been accepted.
4. If it's linked into a shipped binary, its notices must ship too: bundle them into `Turnstile.app` and the CLI tarball and show them from the app. saggar-desktop's generated `ThirdPartyNotices.txt` is the pattern to follow.
5. Run `node --test scripts/license-check-tests.mjs` and `node scripts/license-check.mjs`.
