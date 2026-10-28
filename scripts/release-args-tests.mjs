import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";

function runHelper(context, helper, args, metadata = true, gitStatus = {}) {
  const root = fs.mkdtempSync(
    path.join(os.tmpdir(), "turnstile-release-args-"),
  );
  context.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const tools = path.join(root, "tools");
  const calls = path.join(root, "calls.log");
  fs.mkdirSync(tools);
  fs.mkdirSync(path.join(root, "home"));
  fs.mkdirSync(path.join(root, "tmp"));
  fs.mkdirSync(path.join(root, "scripts"));
  fs.mkdirSync(path.join(root, "Sources", "TurnstileCore"), {
    recursive: true,
  });
  fs.mkdirSync(path.join(root, ".build", "dist"), { recursive: true });
  fs.mkdirSync(path.join(root, ".build", "Turnstile.app"));
  if (metadata) {
    fs.writeFileSync(
      path.join(root, "Sources", "TurnstileCore", "Paths.swift"),
      'public static let version = "0.9.0"\n',
    );
    fs.writeFileSync(
      path.join(root, "CHANGELOG.md"),
      "## 0.9.0\n\nRelease notes.\n",
    );
  }
  const artifacts = [
    ".build/Turnstile.app/marker",
    ".build/Turnstile-0.9.0.zip",
    ".build/dist/turnstile-0.9.0-macos.tar.gz",
    ".build/dist/Turnstile-0.9.0.zip",
    ".build/dist/SHA256SUMS",
  ];
  for (const file of artifacts)
    fs.writeFileSync(path.join(root, file), "existing artifact\n");
  for (const name of ["package", "dist", "release", "publish"]) {
    fs.copyFileSync(
      new URL(`./${name}.sh`, import.meta.url),
      path.join(root, "scripts", `${name}.sh`),
    );
  }
  for (const name of [
    "swift",
    "git",
    "gh",
    "node",
    "lipo",
    "codesign",
    "ditto",
    "xcrun",
    "spctl",
    "rm",
    "cp",
    "tar",
  ]) {
    fs.writeFileSync(
      path.join(tools, name),
      '#!/bin/bash\nprintf "%s\\n" "$0 $*" >> "$RELEASE_ARGS_CALLS"\nif [ "${0##*/}" = git ] && [ "${1:-}" = status ]; then\n  printf "%s" "${RELEASE_ARGS_GIT_OUTPUT:-}"\n  exit "${RELEASE_ARGS_GIT_STATUS:-0}"\nfi\nexit 97\n',
      { mode: 0o755 },
    );
  }
  const env = {
    PATH: `${tools}:/usr/bin:/bin`,
    HOME: path.join(root, "home"),
    TMPDIR: path.join(root, "tmp"),
    RELEASE_ARGS_CALLS: calls,
    RELEASE_ARGS_GIT_STATUS: String(gitStatus.code ?? 0),
    RELEASE_ARGS_GIT_OUTPUT: gitStatus.output ?? "",
    GIT_CONFIG_NOSYSTEM: "1",
    GIT_CONFIG_GLOBAL: "/dev/null",
  };
  const initialized = spawnSync(
    "/usr/bin/git",
    ["-c", "init.templateDir=", "init", "--quiet", root],
    {
      env,
      encoding: "utf8",
      timeout: 5000,
    },
  );
  assert.equal(initialized.status, 0, initialized.stderr);
  function snapshot() {
    return fs
      .readdirSync(root, { recursive: true })
      .filter(
        (name) =>
          name !== "calls.log" && fs.lstatSync(path.join(root, name)).isFile(),
      )
      .sort()
      .map((name) => ({
        name,
        mode: fs.statSync(path.join(root, name)).mode,
        bytes: fs.readFileSync(path.join(root, name)).toString("base64"),
      }));
  }
  const before = snapshot();
  const result = spawnSync(
    "/bin/bash",
    [path.join(root, "scripts", `${helper}.sh`), ...args],
    {
      cwd: root,
      env,
      encoding: "utf8",
      timeout: 5000,
    },
  );
  assert.equal(result.error, undefined);
  assert.equal(result.signal, null);
  assert.deepEqual(
    snapshot(),
    before,
    "helper must preserve fixture files, modes, and artifacts",
  );
  for (const file of artifacts) {
    assert.equal(
      fs.readFileSync(path.join(root, file), "utf8"),
      "existing artifact\n",
    );
  }
  return {
    ...result,
    calls: fs.existsSync(calls)
      ? fs.readFileSync(calls, "utf8").replaceAll(`${tools}/`, "")
      : "",
  };
}

for (const output of ["", " M fixture\n"]) {
  test(`release stops after failed Git inspection with output ${JSON.stringify(output)}`, (context) => {
    const result = runHelper(context, "release", [], true, {
      code: 128,
      output,
    });
    assert.equal(result.status, 1, result.stderr);
    assert.equal(result.stdout, "");
    assert.match(
      result.stderr,
      /release\.sh: cannot inspect the Git working tree/,
    );
    assert.equal(result.calls, "git status --porcelain\n");
  });
}

test("package rejects a misspelled dev option before invoking external tools", (context) => {
  const result = runHelper(context, "package", ["--development"]);
  assert.equal(result.status, 2);
  assert.match(result.stderr, /usage: scripts\/package\.sh \[--dev\]/i);
  assert.equal(result.calls, "");
});

test("publish rejects a misspelled check option before invoking external tools", (context) => {
  const result = runHelper(context, "publish", ["--chec"]);
  assert.equal(result.status, 2);
  assert.match(result.stderr, /usage: scripts\/publish\.sh \[--check\]/i);
  assert.equal(result.calls, "");
});

test("dist rejects unsupported operands before invoking external tools", (context) => {
  const result = runHelper(context, "dist", ["--dev"]);
  assert.equal(result.status, 2);
  assert.match(result.stderr, /usage: scripts\/dist\.sh/i);
  assert.equal(result.calls, "");
});

test("release rejects unsupported operands before invoking external tools", (context) => {
  const result = runHelper(context, "release", ["--dev"]);
  assert.equal(result.status, 2);
  assert.match(result.stderr, /usage: scripts\/release\.sh/i);
  assert.equal(result.calls, "");
});

for (const helper of ["package", "publish", "dist", "release"]) {
  const option = helper === "package" ? "--dev" : "--check";
  for (const args of [[""], [option, "extra"], [option, option]]) {
    test(`${helper} rejects ${JSON.stringify(args)} without touching artifacts or invoking tools`, (context) => {
      const result = runHelper(context, helper, args);
      assert.equal(result.status, 2);
      assert.match(
        result.stderr,
        new RegExp(`usage: scripts/${helper}\\.sh`, "i"),
      );
      assert.equal(result.calls, "");
    });
  }
  test(`${helper} rejects invalid arguments before reading release metadata`, (context) => {
    const result = runHelper(context, helper, ["--invalid"], false);
    assert.equal(result.status, 2);
    assert.match(
      result.stderr,
      new RegExp(`^Usage: scripts/${helper}\\.sh`, "m"),
    );
    assert.doesNotMatch(result.stderr, /No such file|cannot open/i);
    assert.equal(result.calls, "");
  });
}

const barBuild =
  "swift build -c release --product TurnstileBar --arch arm64 --arch x86_64";
const cliBuild =
  "swift build -c release --product turnstile --arch arm64 --arch x86_64";
const releaseViews = [
  "gh release view v0.9.0 --repo mcclowes/homebrew-turnstile",
  "gh release view v0.9.0 --repo mcclowes/turnstile",
];
for (const [helper, args, status, expected] of [
  [
    "package",
    [],
    97,
    ["git status --porcelain --untracked-files=no", barBuild],
  ],
  ["package", ["--dev"], 97, [barBuild]],
  [
    "publish",
    [],
    1,
    [
      ...releaseViews,
      "git ls-remote --exit-code --tags origin refs/tags/v0.9.0",
    ],
  ],
  ["publish", ["--check"], 0, releaseViews],
  ["dist", [], 97, [cliBuild]],
  [
    "release",
    [],
    97,
    [
      "git status --porcelain",
      "git rev-parse -q --verify refs/tags/v0.9.0",
      ...releaseViews,
      "node scripts/license-check.mjs",
    ],
  ],
]) {
  test(`${helper} accepts ${JSON.stringify(args)} and reaches its blocked pipeline`, (context) => {
    const result = runHelper(context, helper, args);
    assert.notEqual(result.status, 2);
    assert.doesNotMatch(result.stderr, /usage: scripts\//i);
    assert.notEqual(result.calls, "");
    assert.deepEqual(result.calls.trim().split("\n"), expected);
    assert.equal(result.status, status);
    if (helper === "package" && args.includes("--dev")) {
      assert.doesNotMatch(result.calls, /^git /m);
    }
    if (helper === "publish" && args.includes("--check")) {
      assert.equal(result.status, 0);
      assert.equal(result.calls.trim().split("\n").length, 2);
      assert.match(result.calls, /^gh release view /m);
    }
  });
}
