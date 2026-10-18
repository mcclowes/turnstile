import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";

function fixture(context) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "turnstile package "));
  context.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const app = path.join(root, ".build/Turnstile.app");
  const zip = path.join(root, ".build/Turnstile-9.8.7.zip");
  for (const directory of [
    "scripts",
    "tools",
    "home",
    "tmp",
    "build output",
    "assets",
    "Sources/TurnstileCore",
    ".build/Turnstile.app",
  ]) {
    fs.mkdirSync(path.join(root, directory), { recursive: true });
  }
  fs.copyFileSync(
    new URL("./package.sh", import.meta.url),
    path.join(root, "scripts/package.sh"),
  );
  fs.writeFileSync(
    path.join(root, "Sources/TurnstileCore/Paths.swift"),
    'public static let version = "9.8.7"\n',
  );
  fs.writeFileSync(path.join(app, "old"), "previous app");
  fs.writeFileSync(zip, "previous release");
  fs.chmodSync(app, 0o750);
  fs.chmodSync(zip, 0o640);
  fs.mkdirSync(path.join(root, ".build/.turnstile-package.unrelated"));
  fs.writeFileSync(
    path.join(root, ".build/.turnstile-package.unrelated/keep"),
    "preserve neighbor",
  );
  fs.writeFileSync(
    path.join(root, "build output/TurnstileBar"),
    "fixture executable",
    { mode: 0o755 },
  );
  fs.writeFileSync(path.join(root, "assets/AppIcon.icns"), "fixture icon");
  const stub = `#!/bin/bash
set -eu
tool=$(basename "$0")
printf '%s\\n' "$tool $*" >> "$FIXTURE_ROOT/calls"
printf '%s\\0' "$tool" "$#" "$@" >> "$FIXTURE_ROOT/arguments"
case "$tool" in
  git) [ "$MODE" != dirty ] || printf ' M fixture\\n' ;;
  swift)
    for argument in "$@"; do
      if [ "$argument" = --show-bin-path ]; then
        [ "$MODE" != path-failure ] || exit 42
        printf '%s\\n' "$FIXTURE_ROOT/build output"
        exit 0
      fi
    done
    [ "$MODE" != build-failure ] || exit 41 ;;
  codesign)
    for argument in "$@"; do
      if [ "$argument" = --verify ]; then
        [ "$MODE" != verify-failure ] || exit 45
        exit 0
      fi
    done
    if [ "$MODE" = sign-failure ]; then
      for destination in "$@"; do :; done
      printf 'incomplete' > "$destination/signature"
      exit 44
    fi ;;
  ditto)
    count=0
    [ ! -f "$FIXTURE_ROOT/archives" ] || count=$(cat "$FIXTURE_ROOT/archives")
    count=$((count + 1))
    printf '%s' "$count" > "$FIXTURE_ROOT/archives"
    if [ "$MODE" = archive-failure ] || { [ "$MODE" = final-archive-failure ] && [ "$count" -eq 2 ]; }; then exit 46; fi
    for destination in "$@"; do :; done
    printf 'fixture archive %s' "$count" > "$destination" ;;
  xcrun)
    if [ "$1" = notarytool ] && [ "$2" = submit ]; then
      if [ "$MODE" = notary-failure ]; then printf 'id: fixture-id\\n'; exit 50; fi
      if [ "$MODE" = rejected ]; then printf 'id: fixture-id\\nstatus: Invalid\\n'; else printf 'status: Accepted\\n'; fi
    fi
    if [ "$1" = stapler ] && [ "$MODE" = staple-failure ]; then exit 48; fi ;;
  spctl) [ "$MODE" != assess-failure ] || exit 49 ;;
  shasum)
    [ "$MODE" != checksum-failure ] || { echo 'fixture checksum failure' >&2; exit 56; }
    exec /usr/bin/shasum "$@" ;;
  mv)
    if [ "$MODE" = app-backup-failure ] && [ "$1" = .build/Turnstile.app ]; then exit 52; fi
    if [ "$MODE" = zip-backup-failure ] && [ "$1" = .build/Turnstile-9.8.7.zip ]; then exit 53; fi
    if [[ "$1" == .build/.turnstile-package.*/Turnstile.app ]] && [ "$2" = .build/Turnstile.app ]; then
      if [ "$MODE" = app-promotion-failure ]; then echo 'fixture app promotion failure' >&2; exit 54; fi
      if [ "$MODE" = interrupt-app ] || [ "$MODE" = interrupt-app-int ]; then
        /bin/mv "$@"
        if [ "$MODE" = interrupt-app-int ]; then kill -INT "$PPID"; else kill -TERM "$PPID"; fi
        exit 0
      fi
    fi
    if [[ "$1" == .build/.turnstile-package.*/Turnstile-9.8.7.zip ]] && [ "$2" = .build/Turnstile-9.8.7.zip ]; then
      if [ "$MODE" = zip-promotion-failure ] || [ "$MODE" = rollback-app ] || [ "$MODE" = rollback-zip ]; then echo 'fixture ZIP promotion failure' >&2; exit 55; fi
      if [ "$MODE" = interrupt-zip ] || [ "$MODE" = interrupt-zip-int ]; then
        /bin/mv "$@"
        if [ "$MODE" = interrupt-zip-int ]; then kill -INT "$PPID"; else kill -TERM "$PPID"; fi
        exit 0
      fi
    fi
    if [ "$MODE" = rollback-app ] && [[ "$1" == */previous-app ]]; then echo 'fixture app restoration failure' >&2; exit 57; fi
    if [ "$MODE" = rollback-zip ] && [[ "$1" == */previous.zip ]]; then echo 'fixture ZIP restoration failure' >&2; exit 58; fi
    exec /bin/mv "$@" ;;
esac
exit 0
`;
  for (const tool of [
    "git",
    "swift",
    "codesign",
    "ditto",
    "xcrun",
    "spctl",
    "shasum",
    "mv",
  ]) {
    fs.writeFileSync(path.join(root, "tools", tool), stub, { mode: 0o755 });
  }
  return {
    root,
    app,
    zip,
    run(mode = "success", dev = false) {
      const result = spawnSync(
        "/bin/bash",
        [path.join(root, "scripts/package.sh"), ...(dev ? ["--dev"] : [])],
        {
          cwd: root,
          env: {
            PATH: `${path.join(root, "tools")}:/usr/bin:/bin`,
            FIXTURE_ROOT: root,
            MODE: mode,
            HOME: path.join(root, "home"),
            TMPDIR: path.join(root, "tmp"),
            CODESIGN_IDENTITY: "fixture identity",
            NOTARY_PROFILE: "fixture-profile",
            BASH_ENV: "/dev/null",
          },
          encoding: "utf8",
          timeout: 5000,
        },
      );
      assert.equal(result.error, undefined);
      assert.equal(result.signal, null);
      return result;
    },
  };
}

function recordedCommands(current) {
  const fields = fs
    .readFileSync(path.join(current.root, "arguments"), "utf8")
    .split("\0");
  assert.equal(fields.pop(), "");
  const commands = [];
  for (let cursor = 0; cursor < fields.length;) {
    const tool = fields[cursor++];
    const count = Number(fields[cursor++]);
    assert.ok(
      Number.isInteger(count) && count >= 0 && cursor + count <= fields.length,
    );
    commands.push([tool, ...fields.slice(cursor, cursor + count)]);
    cursor += count;
  }
  return commands.filter(([tool]) => tool !== "mv");
}

function assertCleanup(current) {
  assert.deepEqual(
    fs
      .readdirSync(path.join(current.root, ".build"))
      .filter(
        (name) =>
          name !== ".turnstile-package.unrelated" &&
          name.startsWith(".turnstile-package."),
      ),
    [],
  );
  assert.equal(
    fs.readFileSync(
      path.join(current.root, ".build/.turnstile-package.unrelated/keep"),
      "utf8",
    ),
    "preserve neighbor",
  );
}

function assertPrevious(current) {
  assert.equal(
    fs.readFileSync(path.join(current.app, "old"), "utf8"),
    "previous app",
  );
  assert.deepEqual(fs.readdirSync(current.app), ["old"]);
  assert.equal(fs.readFileSync(current.zip, "utf8"), "previous release");
  assert.equal(fs.statSync(current.app).mode & 0o777, 0o750);
  assert.equal(fs.statSync(current.zip).mode & 0o777, 0o640);
  assertCleanup(current);
}

test("dev packaging preserves the previous release archive", (context) => {
  const current = fixture(context);
  const result = current.run("success", true);
  assert.equal(result.status, 0, result.stderr);
  assert.equal(fs.readFileSync(current.zip, "utf8"), "previous release");
  assert.equal(fs.statSync(current.zip).mode & 0o777, 0o640);
  assert.equal(fs.existsSync(path.join(current.app, "old")), false);
  const calls = fs.readFileSync(path.join(current.root, "calls"), "utf8");
  assert.doesNotMatch(calls, /git |xcrun |spctl |ditto /);
  assert.match(calls, /codesign --force --sign - /);
  const commands = recordedCommands(current);
  const stagedApp = commands.at(-1).at(-1);
  assert.match(
    stagedApp,
    /^\.build\/\.turnstile-package\.[^/]+\/Turnstile\.app$/,
  );
  assert.deepEqual(commands, [
    [
      "swift",
      "build",
      "-c",
      "release",
      "--product",
      "TurnstileBar",
      "--arch",
      "arm64",
      "--arch",
      "x86_64",
    ],
    [
      "swift",
      "build",
      "-c",
      "release",
      "--product",
      "TurnstileBar",
      "--arch",
      "arm64",
      "--arch",
      "x86_64",
      "--show-bin-path",
    ],
    ["codesign", "--force", "--sign", "-", stagedApp],
  ]);
  assertCleanup(current);
});

for (const [mode, expected] of [
  ["dirty", 1],
  ["build-failure", 41],
  ["path-failure", 42],
  ["missing-executable", 1],
  ["missing-icon", 1],
  ["sign-failure", 44],
  ["verify-failure", 45],
  ["archive-failure", 46],
  ["notary-failure", 1],
  ["rejected", 1],
  ["staple-failure", 48],
  ["assess-failure", 49],
  ["final-archive-failure", 46],
]) {
  test(`release ${mode} preserves previous app and ZIP`, (context) => {
    const current = fixture(context);
    if (mode === "missing-executable")
      fs.unlinkSync(path.join(current.root, "build output/TurnstileBar"));
    if (mode === "missing-icon")
      fs.unlinkSync(path.join(current.root, "assets/AppIcon.icns"));
    const result = current.run(mode);
    assert.equal(result.status, expected, result.stdout + result.stderr);
    assertPrevious(current);
    if (mode === "rejected")
      assert.match(
        fs.readFileSync(path.join(current.root, "calls"), "utf8"),
        /notarytool log fixture-id/,
      );
    if (mode === "dirty")
      assert.doesNotMatch(
        fs.readFileSync(path.join(current.root, "calls"), "utf8"),
        /swift /,
      );
  });
}

test("failed dev signing keeps both previous artifacts", (context) => {
  const current = fixture(context);
  const result = current.run("sign-failure", true);
  assert.equal(result.status, 44);
  assertPrevious(current);
});

test("successful release publishes only the final app and archive", (context) => {
  const current = fixture(context);
  let result = current.run();
  assert.equal(result.status, 0, result.stdout + result.stderr);
  assert.equal(fs.existsSync(path.join(current.app, "old")), false);
  assert.equal(
    fs.readFileSync(
      path.join(current.app, "Contents/MacOS/TurnstileBar"),
      "utf8",
    ),
    "fixture executable",
  );
  assert.ok(
    fs.statSync(path.join(current.app, "Contents/MacOS/TurnstileBar")).mode &
      0o111,
  );
  assert.equal(fs.readFileSync(current.zip, "utf8"), "fixture archive 2");
  const digest = createHash("sha256")
    .update(fs.readFileSync(current.zip))
    .digest("hex");
  assert.ok(result.stdout.endsWith(`${digest}  .build/Turnstile-9.8.7.zip\n`));
  const calls = fs.readFileSync(path.join(current.root, "calls"), "utf8");
  assert.match(
    calls,
    /swift build -c release --product TurnstileBar --arch arm64 --arch x86_64/,
  );
  assert.match(
    calls,
    /codesign --force --options runtime --timestamp --sign fixture identity /,
  );
  assert.match(calls, /codesign --verify --strict --deep --verbose=2 /);
  assert.match(calls, /--keychain-profile fixture-profile --wait/);
  assert.match(calls, /xcrun stapler staple /);
  assert.match(calls, /spctl --assess --type execute --verbose=2 /);
  const commands = recordedCommands(current);
  const stagedApp = commands.find(([tool]) => tool === "codesign").at(-1);
  const stagedZip = commands.find(([tool]) => tool === "ditto").at(-1);
  assert.match(
    stagedApp,
    /^\.build\/\.turnstile-package\.[^/]+\/Turnstile\.app$/,
  );
  assert.equal(path.dirname(stagedZip), path.dirname(stagedApp));
  assert.equal(path.basename(stagedZip), "Turnstile-9.8.7.zip");
  assert.deepEqual(commands, [
    ["git", "status", "--porcelain", "--untracked-files=no"],
    [
      "swift",
      "build",
      "-c",
      "release",
      "--product",
      "TurnstileBar",
      "--arch",
      "arm64",
      "--arch",
      "x86_64",
    ],
    [
      "swift",
      "build",
      "-c",
      "release",
      "--product",
      "TurnstileBar",
      "--arch",
      "arm64",
      "--arch",
      "x86_64",
      "--show-bin-path",
    ],
    [
      "codesign",
      "--force",
      "--options",
      "runtime",
      "--timestamp",
      "--sign",
      "fixture identity",
      stagedApp,
    ],
    ["codesign", "--verify", "--strict", "--deep", "--verbose=2", stagedApp],
    ["ditto", "-c", "-k", "--keepParent", stagedApp, stagedZip],
    [
      "xcrun",
      "notarytool",
      "submit",
      stagedZip,
      "--keychain-profile",
      "fixture-profile",
      "--wait",
    ],
    ["xcrun", "stapler", "staple", stagedApp],
    ["spctl", "--assess", "--type", "execute", "--verbose=2", stagedApp],
    ["ditto", "-c", "-k", "--keepParent", stagedApp, stagedZip],
    ["shasum", "-a", "256", stagedZip],
  ]);
  const plist = fs.readFileSync(
    path.join(current.app, "Contents/Info.plist"),
    "utf8",
  );
  assert.match(plist, /<key>CFBundleVersion<\/key><string>9\.8\.7<\/string>/);
  assert.match(
    plist,
    /<key>CFBundleIdentifier<\/key><string>com\.mcclowes\.turnstile<\/string>/,
  );
  assertCleanup(current);
  fs.writeFileSync(path.join(current.app, "obsolete"), "old resource");
  result = current.run();
  assert.equal(result.status, 0, result.stdout + result.stderr);
  assert.equal(fs.existsSync(path.join(current.app, "obsolete")), false);
  assert.equal(fs.readFileSync(current.zip, "utf8"), "fixture archive 4");
  assertCleanup(current);
});

for (const [mode, expected] of [
  ["app-backup-failure", 52],
  ["app-promotion-failure", 54],
  ["interrupt-app", 143],
]) {
  test(`dev ${mode} restores the previous app and preserves the release ZIP`, (context) => {
    const current = fixture(context);
    const result = current.run(mode, true);
    assert.equal(result.status, expected, result.stdout + result.stderr);
    assertPrevious(current);
  });
}

for (const [mode, expected] of [
  ["app-promotion-failure", 54],
  ["interrupt-app", 143],
]) {
  test(`first-time dev ${mode} leaves no app and preserves the release ZIP`, (context) => {
    const current = fixture(context);
    fs.rmSync(current.app, { recursive: true });
    const result = current.run(mode, true);
    assert.equal(result.status, expected, result.stdout + result.stderr);
    assert.equal(fs.existsSync(current.app), false);
    assert.equal(fs.readFileSync(current.zip, "utf8"), "previous release");
    assert.equal(fs.statSync(current.zip).mode & 0o777, 0o640);
    assertCleanup(current);
  });
}

for (const [mode, expected] of [
  ["app-backup-failure", 52],
  ["zip-backup-failure", 53],
  ["app-promotion-failure", 54],
  ["zip-promotion-failure", 55],
  ["checksum-failure", 56],
  ["interrupt-app", 143],
  ["interrupt-zip", 143],
]) {
  test(`release ${mode} restores both previous artifacts`, (context) => {
    const current = fixture(context);
    const result = current.run(mode);
    assert.equal(result.status, expected, result.stdout + result.stderr);
    assertPrevious(current);
  });
}

for (const [mode, expected] of [
  ["app-promotion-failure", 54],
  ["zip-promotion-failure", 55],
  ["interrupt-app", 143],
  ["interrupt-zip", 143],
]) {
  test(`first-time release ${mode} leaves neither published artifact`, (context) => {
    const current = fixture(context);
    fs.rmSync(current.app, { recursive: true });
    fs.unlinkSync(current.zip);
    const result = current.run(mode);
    assert.equal(result.status, expected, result.stdout + result.stderr);
    assert.equal(fs.existsSync(current.app), false);
    assert.equal(fs.existsSync(current.zip), false);
    assertCleanup(current);
  });
}

for (const mode of ["interrupt-app-int", "interrupt-zip-int"]) {
  test(`release ${mode} restores both artifacts and returns 130`, (context) => {
    const current = fixture(context);
    const result = current.run(mode);
    assert.equal(result.status, 130, result.stdout + result.stderr);
    assertPrevious(current);
  });
}

for (const [mode, backup, restored, failure] of [
  ["rollback-app", "previous-app", "zip", /fixture app restoration failure/],
  ["rollback-zip", "previous.zip", "app", /fixture ZIP restoration failure/],
]) {
  test(`${mode} retains recovery data and restores the other artifact`, (context) => {
    const current = fixture(context);
    const result = current.run(mode);
    assert.equal(result.status, 55);
    assert.match(result.stderr, /fixture ZIP promotion failure/);
    assert.match(result.stderr, failure);
    const build = path.join(current.root, ".build");
    const retained = fs
      .readdirSync(build)
      .filter(
        (name) =>
          name !== ".turnstile-package.unrelated" &&
          name.startsWith(".turnstile-package."),
      );
    assert.equal(retained.length, 1);
    assert.ok(result.stderr.includes(retained[0]));
    const old = path.join(build, retained[0], backup);
    if (restored === "zip") {
      assert.equal(
        fs.readFileSync(path.join(old, "old"), "utf8"),
        "previous app",
      );
      assert.equal(fs.statSync(old).mode & 0o777, 0o750);
      assert.equal(fs.readFileSync(current.zip, "utf8"), "previous release");
    } else {
      assert.equal(fs.readFileSync(old, "utf8"), "previous release");
      assert.equal(fs.statSync(old).mode & 0o777, 0o640);
      assert.equal(
        fs.readFileSync(path.join(current.app, "old"), "utf8"),
        "previous app",
      );
    }
    assert.equal(
      fs.readFileSync(
        path.join(build, ".turnstile-package.unrelated/keep"),
        "utf8",
      ),
      "preserve neighbor",
    );
  });
}
