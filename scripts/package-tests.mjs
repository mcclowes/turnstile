import assert from "node:assert/strict";
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
  for (const directory of ["scripts", "tools", "build output", "assets", "Sources/TurnstileCore", ".build/Turnstile.app"]) {
    fs.mkdirSync(path.join(root, directory), { recursive: true });
  }
  fs.copyFileSync(new URL("./package.sh", import.meta.url), path.join(root, "scripts/package.sh"));
  fs.writeFileSync(path.join(root, "Sources/TurnstileCore/Paths.swift"), 'public static let version = "9.8.7"\n');
  fs.writeFileSync(path.join(app, "old"), "previous app");
  fs.writeFileSync(zip, "previous release");
  fs.writeFileSync(path.join(root, "build output/TurnstileBar"), "fixture executable", { mode: 0o755 });
  fs.writeFileSync(path.join(root, "assets/AppIcon.icns"), "fixture icon");
  const stub = `#!/bin/bash
set -eu
tool=$(basename "$0")
printf '%s\\n' "$tool $*" >> "$FIXTURE_ROOT/calls"
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
esac
exit 0
`;
  for (const tool of ["git", "swift", "codesign", "ditto", "xcrun", "spctl"]) {
    fs.writeFileSync(path.join(root, "tools", tool), stub, { mode: 0o755 });
  }
  return {
    root, app, zip,
    run(mode = "success", dev = false) {
      const result = spawnSync("/bin/bash", [path.join(root, "scripts/package.sh"), ...(dev ? ["--dev"] : [])], {
        cwd: root,
        env: { PATH: `${path.join(root, "tools")}:/usr/bin:/bin`, FIXTURE_ROOT: root, MODE: mode,
          CODESIGN_IDENTITY: "fixture identity", NOTARY_PROFILE: "fixture-profile", BASH_ENV: "/dev/null" },
        encoding: "utf8", timeout: 5000,
      });
      assert.equal(result.error, undefined);
      return result;
    },
  };
}

function assertCleanup(current) {
  assert.deepEqual(fs.readdirSync(path.join(current.root, ".build")).filter((name) => name.startsWith(".turnstile-package.")), []);
}

function assertPrevious(current) {
  assert.equal(fs.readFileSync(path.join(current.app, "old"), "utf8"), "previous app");
  assert.deepEqual(fs.readdirSync(current.app), ["old"]);
  assert.equal(fs.readFileSync(current.zip, "utf8"), "previous release");
  assertCleanup(current);
}

test("dev packaging preserves the previous release archive", (context) => {
  const current = fixture(context);
  const result = current.run("success", true);
  assert.equal(result.status, 0, result.stderr);
  assert.equal(fs.readFileSync(current.zip, "utf8"), "previous release");
  assert.equal(fs.existsSync(path.join(current.app, "old")), false);
  const calls = fs.readFileSync(path.join(current.root, "calls"), "utf8");
  assert.doesNotMatch(calls, /git |xcrun |spctl |ditto /);
  assert.match(calls, /codesign --force --sign - /);
  assertCleanup(current);
});

for (const [mode, expected] of [
  ["dirty", 1], ["build-failure", 41], ["path-failure", 42], ["missing-executable", 1],
  ["missing-icon", 1], ["sign-failure", 44], ["verify-failure", 45], ["archive-failure", 46],
  ["notary-failure", 1], ["rejected", 1], ["staple-failure", 48], ["assess-failure", 49],
  ["final-archive-failure", 46],
]) {
  test(`release ${mode} preserves previous app and ZIP`, (context) => {
    const current = fixture(context);
    if (mode === "missing-executable") fs.unlinkSync(path.join(current.root, "build output/TurnstileBar"));
    if (mode === "missing-icon") fs.unlinkSync(path.join(current.root, "assets/AppIcon.icns"));
    const result = current.run(mode);
    assert.equal(result.status, expected, result.stdout + result.stderr);
    assertPrevious(current);
    if (mode === "rejected") assert.match(fs.readFileSync(path.join(current.root, "calls"), "utf8"), /notarytool log fixture-id/);
    if (mode === "dirty") assert.doesNotMatch(fs.readFileSync(path.join(current.root, "calls"), "utf8"), /swift /);
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
  assert.equal(fs.readFileSync(path.join(current.app, "Contents/MacOS/TurnstileBar"), "utf8"), "fixture executable");
  assert.ok(fs.statSync(path.join(current.app, "Contents/MacOS/TurnstileBar")).mode & 0o111);
  assert.equal(fs.readFileSync(current.zip, "utf8"), "fixture archive 2");
  const calls = fs.readFileSync(path.join(current.root, "calls"), "utf8");
  assert.match(calls, /swift build -c release --product TurnstileBar --arch arm64 --arch x86_64/);
  assert.match(calls, /codesign --force --options runtime --timestamp --sign fixture identity /);
  assert.match(calls, /codesign --verify --strict --deep --verbose=2 /);
  assert.match(calls, /--keychain-profile fixture-profile --wait/);
  assert.match(calls, /xcrun stapler staple /);
  assert.match(calls, /spctl --assess --type execute --verbose=2 /);
  const plist = fs.readFileSync(path.join(current.app, "Contents/Info.plist"), "utf8");
  assert.match(plist, /<key>CFBundleVersion<\/key><string>9\.8\.7<\/string>/);
  assert.match(plist, /<key>CFBundleIdentifier<\/key><string>com\.mcclowes\.turnstile<\/string>/);
  assertCleanup(current);
  fs.writeFileSync(path.join(current.app, "obsolete"), "old resource");
  result = current.run();
  assert.equal(result.status, 0, result.stdout + result.stderr);
  assert.equal(fs.existsSync(path.join(current.app, "obsolete")), false);
  assert.equal(fs.readFileSync(current.zip, "utf8"), "fixture archive 4");
  assertCleanup(current);
});
