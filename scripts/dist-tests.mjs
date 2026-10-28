import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";

const neighbors = [
  ".turnstile-dist.unrelated",
  ".turnstile-dist-backup.unrelated",
];

function fixture(context) {
  const root = fs.mkdtempSync(
    path.join(os.tmpdir(), "turnstile package dist "),
  );
  context.after(() => fs.rmSync(root, { recursive: true, force: true }));
  for (const directory of [
    "scripts",
    "tools",
    "home",
    "tmp",
    "build output",
    "Sources/TurnstileCore",
    ".build/dist",
  ]) {
    fs.mkdirSync(path.join(root, directory), { recursive: true });
  }
  fs.copyFileSync(
    new URL("./dist.sh", import.meta.url),
    path.join(root, "scripts/dist.sh"),
  );
  fs.copyFileSync(
    new URL("./version.sh", import.meta.url),
    path.join(root, "scripts/version.sh"),
  );
  fs.writeFileSync(
    path.join(root, "Sources/TurnstileCore/Paths.swift"),
    'public static let version = "9.8.7"\n',
  );
  fs.writeFileSync(
    path.join(root, ".build/dist/previous"),
    "previous distribution",
  );
  fs.chmodSync(path.join(root, ".build/dist"), 0o750);
  for (const name of neighbors) {
    const directory = path.join(root, ".build", name);
    fs.mkdirSync(directory, { mode: 0o700 });
    fs.writeFileSync(path.join(directory, "keep"), "preserve neighbor");
  }
  fs.writeFileSync(
    path.join(root, "build output/turnstile"),
    `#!/bin/bash
printf '%s\\0' cli "$#" "$@" >> "$FIXTURE_ROOT/arguments"
if [ "$MODE" = version-failure ]; then echo 0.0.0; else echo 9.8.7; fi
`,
    { mode: 0o755 },
  );
  fs.writeFileSync(
    path.join(root, "scripts/package.sh"),
    `#!/bin/bash
printf '%s\\0' package "$#" "$@" >> "$FIXTURE_ROOT/arguments"
printf 'package\\n' >> "$FIXTURE_ROOT/calls"
[ "$MODE" != package-failure ] || exit 51
if [ "$MODE" = missing-zip ]; then exit 0; fi
printf 'fixture app archive' > "$FIXTURE_ROOT/.build/Turnstile-9.8.7.zip"
`,
    { mode: 0o755 },
  );
  const stub = `#!/bin/bash
set -eu
tool=$(basename "$0")
printf '%s\\n' "$tool $*" >> "$FIXTURE_ROOT/calls"
printf '%s\\0' "$tool" "$#" "$@" >> "$FIXTURE_ROOT/arguments"
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
  mv)
    if [ "$MODE" = backup-failure ] && [ "$1" = .build/dist ]; then echo 'fixture backup failure' >&2; exit 52; fi
    if [[ "$1" == .build/.turnstile-dist.* ]] && [ "$2" = .build/dist ]; then
      case "$MODE" in
        promotion-failure|rollback-failure) echo 'fixture promotion failure' >&2; exit 53 ;;
        interrupt-before) kill -TERM "$PPID"; exit 0 ;;
        interrupt-after) /bin/mv "$@"; kill -TERM "$PPID"; exit 0 ;;
        interrupt-before-int) kill -INT "$PPID"; exit 0 ;;
        interrupt-after-int) /bin/mv "$@"; kill -INT "$PPID"; exit 0 ;;
      esac
    fi
    if [ "$MODE" = rollback-failure ] && [[ "$1" == .build/.turnstile-dist-backup.*/previous ]]; then echo 'fixture rollback failure' >&2; exit 54; fi
    exec /bin/mv "$@" ;;
esac
exit 0
`;
  for (const tool of ["swift", "lipo", "tar", "cp", "shasum", "mv"])
    fs.writeFileSync(path.join(root, "tools", tool), stub, { mode: 0o755 });
  return {
    root,
    run(mode = "success") {
      const result = spawnSync(
        "/bin/bash",
        [path.join(root, "scripts/dist.sh")],
        {
          cwd: root,
          env: {
            PATH: `${path.join(root, "tools")}:/usr/bin:/bin`,
            FIXTURE_ROOT: root,
            MODE: mode,
            BASH_ENV: "/dev/null",
            HOME: path.join(root, "home"),
            TMPDIR: path.join(root, "tmp"),
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

function assertNeighbors(current) {
  for (const name of neighbors) {
    const directory = path.join(current.root, ".build", name);
    assert.deepEqual(fs.readdirSync(directory), ["keep"]);
    assert.equal(
      fs.readFileSync(path.join(directory, "keep"), "utf8"),
      "preserve neighbor",
    );
    assert.equal(fs.statSync(directory).mode & 0o777, 0o700);
  }
}

function assertCleanup(current) {
  assert.deepEqual(
    fs
      .readdirSync(path.join(current.root, ".build"))
      .filter(
        (name) =>
          !neighbors.includes(name) &&
          (name.startsWith(".turnstile-dist.") ||
            name.startsWith(".turnstile-dist-backup.")),
      ),
    [],
  );
  assertNeighbors(current);
}

for (const [mode, expected] of [
  ["backup-failure", 52],
  ["promotion-failure", 53],
  ["interrupt-before", 143],
  ["interrupt-after", 143],
  ["interrupt-before-int", 130],
  ["interrupt-after-int", 130],
]) {
  test(`${mode} restores the previous distribution at publication`, (context) => {
    const current = fixture(context);
    const result = current.run(mode);
    assert.equal(result.status, expected, result.stdout + result.stderr);
    const dist = path.join(current.root, ".build/dist");
    assert.deepEqual(fs.readdirSync(dist), ["previous"]);
    assert.equal(
      fs.readFileSync(path.join(dist, "previous"), "utf8"),
      "previous distribution",
    );
    assert.equal(fs.statSync(dist).mode & 0o777, 0o750);
    assertCleanup(current);
  });
}

for (const [mode, expected] of [
  ["promotion-failure", 53],
  ["interrupt-before", 143],
  ["interrupt-after", 143],
  ["interrupt-before-int", 130],
  ["interrupt-after-int", 130],
]) {
  test(`${mode} preserves absent first-time distribution output`, (context) => {
    const current = fixture(context);
    const dist = path.join(current.root, ".build/dist");
    fs.rmSync(dist, { recursive: true });
    const result = current.run(mode);
    assert.equal(result.status, expected, result.stdout + result.stderr);
    assert.equal(fs.existsSync(dist), false);
    assertCleanup(current);
  });
}

test("failed rollback retains and reports the previous distribution for recovery", (context) => {
  const current = fixture(context);
  const result = current.run("rollback-failure");
  assert.equal(result.status, 53);
  assert.match(result.stderr, /fixture promotion failure/);
  assert.match(result.stderr, /fixture rollback failure/);
  const build = path.join(current.root, ".build");
  const backups = fs
    .readdirSync(build)
    .filter(
      (name) =>
        !neighbors.includes(name) && name.startsWith(".turnstile-dist-backup."),
    );
  assert.equal(backups.length, 1);
  assert.ok(result.stderr.includes(backups[0]));
  const previous = path.join(build, backups[0], "previous");
  assert.deepEqual(fs.readdirSync(previous), ["previous"]);
  assert.equal(
    fs.readFileSync(path.join(previous, "previous"), "utf8"),
    "previous distribution",
  );
  assert.equal(fs.statSync(previous).mode & 0o777, 0o750);
  const stages = fs
    .readdirSync(build)
    .filter(
      (name) =>
        !neighbors.includes(name) && name.startsWith(".turnstile-dist."),
    );
  assert.equal(stages.length, 1);
  assert.ok(result.stderr.includes(stages[0]));
  assert.deepEqual(fs.readdirSync(path.join(build, stages[0])).sort(), [
    "SHA256SUMS",
    "Turnstile-9.8.7.zip",
    "turnstile-9.8.7-macos.tar.gz",
  ]);
  assertNeighbors(current);
});

test("failed app packaging keeps the previous distribution", (context) => {
  const current = fixture(context);
  const result = current.run("package-failure");
  assert.equal(result.status, 51);
  assert.equal(
    fs.readFileSync(path.join(current.root, ".build/dist/previous"), "utf8"),
    "previous distribution",
  );
  assert.equal(
    fs.statSync(path.join(current.root, ".build/dist")).mode & 0o777,
    0o750,
  );
  assertCleanup(current);
});

for (const [mode, expected] of [
  ["build-failure", 41],
  ["path-failure", 42],
  ["lipo-failure", 43],
  ["architecture-failure", 1],
  ["version-failure", 1],
  ["archive-failure", 44],
  ["missing-zip", 1],
  ["copy-failure", 45],
  ["checksum-failure", 46],
]) {
  test(`${mode} preserves the previous complete distribution`, (context) => {
    const current = fixture(context);
    const result = current.run(mode);
    assert.equal(result.status, expected, result.stdout + result.stderr);
    const dist = path.join(current.root, ".build/dist");
    assert.equal(
      fs.readFileSync(path.join(dist, "previous"), "utf8"),
      "previous distribution",
    );
    assert.deepEqual(fs.readdirSync(dist), ["previous"]);
    assert.equal(fs.statSync(dist).mode & 0o777, 0o750);
    assertCleanup(current);
    if (
      [
        "build-failure",
        "path-failure",
        "lipo-failure",
        "architecture-failure",
        "version-failure",
        "archive-failure",
      ].includes(mode)
    ) {
      assert.deepEqual(
        recordedCommands(current).filter(([tool]) => tool === "package"),
        [],
      );
    }
  });
}

test("successful repeated distribution publishes complete artifacts with valid checksums", (context) => {
  const current = fixture(context);
  const dist = path.join(current.root, ".build/dist");
  let commandOffset = 0;
  for (let run = 0; run < 2; run++) {
    const result = current.run();
    assert.equal(result.status, 0, result.stdout + result.stderr);
    assert.equal(
      result.stdout,
      fs.readFileSync(path.join(dist, "SHA256SUMS"), "utf8"),
    );
    const commands = recordedCommands(current).slice(commandOffset);
    commandOffset += commands.length;
    const tarball = commands.find(([tool]) => tool === "tar")[2];
    assert.equal(path.basename(tarball), "turnstile-9.8.7-macos.tar.gz");
    assert.deepEqual(commands, [
      [
        "swift",
        "build",
        "-c",
        "release",
        "--product",
        "turnstile",
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
        "turnstile",
        "--arch",
        "arm64",
        "--arch",
        "x86_64",
        "--show-bin-path",
      ],
      ["lipo", "-archs", path.join(current.root, "build output/turnstile")],
      ["cli", "--version"],
      [
        "tar",
        "-czf",
        tarball,
        "-C",
        path.join(current.root, "build output"),
        "turnstile",
      ],
      ["package"],
      ["cp", ".build/Turnstile-9.8.7.zip", `${path.dirname(tarball)}/`],
      [
        "shasum",
        "-a",
        "256",
        "--",
        "turnstile-9.8.7-macos.tar.gz",
        "Turnstile-9.8.7.zip",
      ],
    ]);
    assert.deepEqual(fs.readdirSync(dist).sort(), [
      "SHA256SUMS",
      "Turnstile-9.8.7.zip",
      "turnstile-9.8.7-macos.tar.gz",
    ]);
    assert.equal(
      fs.readFileSync(path.join(dist, "Turnstile-9.8.7.zip"), "utf8"),
      "fixture app archive",
    );
    const checksum = spawnSync(
      "/usr/bin/shasum",
      ["-a", "256", "-c", "SHA256SUMS"],
      { cwd: dist, encoding: "utf8" },
    );
    assert.equal(checksum.status, 0, checksum.stderr);
    const archive = spawnSync(
      "/usr/bin/tar",
      ["-xOf", path.join(dist, "turnstile-9.8.7-macos.tar.gz"), "turnstile"],
      { encoding: "utf8" },
    );
    assert.equal(archive.status, 0, archive.stderr);
    assert.equal(
      archive.stdout,
      fs.readFileSync(
        path.join(current.root, "build output/turnstile"),
        "utf8",
      ),
    );
    assertCleanup(current);
    if (run === 0)
      fs.writeFileSync(path.join(dist, "obsolete"), "old resource");
  }
  assert.match(
    fs.readFileSync(path.join(current.root, "calls"), "utf8"),
    /swift build -c release --product turnstile --arch arm64 --arch x86_64/,
  );
});
