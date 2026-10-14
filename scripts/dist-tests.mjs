import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";

function fixture(context) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "turnstile dist "));
  context.after(() => fs.rmSync(root, { recursive: true, force: true }));
  for (const directory of ["scripts", "tools", "build output", "Sources/TurnstileCore", ".build/dist"]) {
    fs.mkdirSync(path.join(root, directory), { recursive: true });
  }
  fs.copyFileSync(new URL("./dist.sh", import.meta.url), path.join(root, "scripts/dist.sh"));
  fs.writeFileSync(path.join(root, "Sources/TurnstileCore/Paths.swift"), 'public static let version = "9.8.7"\n');
  fs.writeFileSync(path.join(root, ".build/dist/previous"), "previous distribution");
  fs.writeFileSync(path.join(root, "build output/turnstile"), `#!/bin/bash
if [ "$MODE" = version-failure ]; then echo 0.0.0; else echo 9.8.7; fi
`, { mode: 0o755 });
  fs.writeFileSync(path.join(root, "scripts/package.sh"), `#!/bin/bash
printf 'package\\n' >> "$FIXTURE_ROOT/calls"
[ "$MODE" != package-failure ] || exit 51
if [ "$MODE" = missing-zip ]; then exit 0; fi
printf 'fixture app archive' > "$FIXTURE_ROOT/.build/Turnstile-9.8.7.zip"
`, { mode: 0o755 });
  const stub = `#!/bin/bash
set -eu
tool=$(basename "$0")
printf '%s\\n' "$tool $*" >> "$FIXTURE_ROOT/calls"
case "$tool" in
  swift)
    for argument in "$@"; do
      if [ "$argument" = --show-bin-path ]; then
        [ "$MODE" != path-failure ] || exit 42
        printf '%s\\n' "$FIXTURE_ROOT/build output"
        exit 0
      fi
    done
    [ "$MODE" != build-failure ] || exit 41 ;;
  lipo)
    [ "$MODE" != lipo-failure ] || exit 43
    if [ "$MODE" = architecture-failure ]; then echo arm64; else echo 'arm64 x86_64'; fi ;;
  tar)
    if [ "$MODE" = archive-failure ]; then printf 'partial' > "$2"; exit 44; fi
    exec /usr/bin/tar "$@" ;;
  cp)
    if [ "$MODE" = copy-failure ]; then
      for destination in "$@"; do :; done
      printf 'partial' > "$destination/partial"
      exit 45
    fi
    exec /bin/cp "$@" ;;
  shasum)
    if [ "$MODE" = checksum-failure ]; then printf 'partial checksum'; exit 46; fi
    exec /usr/bin/shasum "$@" ;;
esac
exit 0
`;
  for (const tool of ["swift", "lipo", "tar", "cp", "shasum"]) fs.writeFileSync(path.join(root, "tools", tool), stub, { mode: 0o755 });
  return {
    root,
    run(mode = "success") {
      const result = spawnSync("/bin/bash", [path.join(root, "scripts/dist.sh")], {
        cwd: root, env: { PATH: `${path.join(root, "tools")}:/usr/bin:/bin`, FIXTURE_ROOT: root, MODE: mode, BASH_ENV: "/dev/null" },
        encoding: "utf8", timeout: 5000,
      });
      assert.equal(result.error, undefined);
      return result;
    },
  };
}

function assertCleanup(current) {
  assert.deepEqual(fs.readdirSync(path.join(current.root, ".build")).filter((name) => name.startsWith(".turnstile-dist.")), []);
}

test("failed app packaging keeps the previous distribution", (context) => {
  const current = fixture(context);
  const result = current.run("package-failure");
  assert.equal(result.status, 51);
  assert.equal(fs.readFileSync(path.join(current.root, ".build/dist/previous"), "utf8"), "previous distribution");
  assertCleanup(current);
});

for (const [mode, expected] of [
  ["build-failure", 41], ["path-failure", 42], ["lipo-failure", 43], ["architecture-failure", 1],
  ["version-failure", 1], ["archive-failure", 44], ["missing-zip", 1], ["copy-failure", 45], ["checksum-failure", 46],
]) {
  test(`${mode} preserves the previous complete distribution`, (context) => {
    const current = fixture(context);
    const result = current.run(mode);
    assert.equal(result.status, expected, result.stdout + result.stderr);
    const dist = path.join(current.root, ".build/dist");
    assert.equal(fs.readFileSync(path.join(dist, "previous"), "utf8"), "previous distribution");
    assert.deepEqual(fs.readdirSync(dist), ["previous"]);
    assertCleanup(current);
    if (["build-failure", "path-failure", "lipo-failure", "architecture-failure", "version-failure", "archive-failure"].includes(mode)) {
      assert.doesNotMatch(fs.readFileSync(path.join(current.root, "calls"), "utf8"), /package/);
    }
  });
}

test("successful repeated distribution publishes complete artifacts with valid checksums", (context) => {
  const current = fixture(context);
  const dist = path.join(current.root, ".build/dist");
  for (let run = 0; run < 2; run++) {
    const result = current.run();
    assert.equal(result.status, 0, result.stdout + result.stderr);
    assert.deepEqual(fs.readdirSync(dist).sort(), ["SHA256SUMS", "Turnstile-9.8.7.zip", "turnstile-9.8.7-macos.tar.gz"]);
    assert.equal(fs.readFileSync(path.join(dist, "Turnstile-9.8.7.zip"), "utf8"), "fixture app archive");
    const checksum = spawnSync("/usr/bin/shasum", ["-a", "256", "-c", "SHA256SUMS"], { cwd: dist, encoding: "utf8" });
    assert.equal(checksum.status, 0, checksum.stderr);
    const archive = spawnSync("/usr/bin/tar", ["-xOf", path.join(dist, "turnstile-9.8.7-macos.tar.gz"), "turnstile"], { encoding: "utf8" });
    assert.equal(archive.status, 0, archive.stderr);
    assert.equal(archive.stdout, fs.readFileSync(path.join(current.root, "build output/turnstile"), "utf8"));
    assertCleanup(current);
    if (run === 0) fs.writeFileSync(path.join(dist, "obsolete"), "old resource");
  }
  assert.match(fs.readFileSync(path.join(current.root, "calls"), "utf8"), /swift build -c release --product turnstile --arch arm64 --arch x86_64/);
});
