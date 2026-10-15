import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";

function runHelper(context, helper, args, { changelog = "## 0.9.0\n\nRelease notes.\n", toolScripts = {} } = {}) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "turnstile-release-args-"));
  context.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const tools = path.join(root, "tools");
  const calls = path.join(root, "calls.log");
  const notes = path.join(root, "notes.txt");
  fs.mkdirSync(tools);
  fs.mkdirSync(path.join(root, "scripts"));
  fs.mkdirSync(path.join(root, "Sources", "TurnstileCore"), { recursive: true });
  fs.mkdirSync(path.join(root, ".build", "dist"), { recursive: true });
  fs.mkdirSync(path.join(root, ".build", "Turnstile.app"));
  fs.writeFileSync(path.join(root, "Sources", "TurnstileCore", "Paths.swift"),
    'public static let version = "0.9.0"\n');
  fs.writeFileSync(path.join(root, "CHANGELOG.md"), changelog);
  const artifacts = [
    ".build/Turnstile.app/marker",
    ".build/Turnstile-0.9.0.zip",
    ".build/dist/turnstile-0.9.0-macos.tar.gz",
    ".build/dist/Turnstile-0.9.0.zip",
    ".build/dist/SHA256SUMS",
  ];
  for (const file of artifacts) fs.writeFileSync(path.join(root, file), "existing artifact\n");
  for (const name of ["package", "dist", "release", "publish"]) {
    fs.copyFileSync(new URL(`./${name}.sh`, import.meta.url), path.join(root, "scripts", `${name}.sh`));
  }
  for (const name of ["swift", "git", "gh", "node", "lipo", "codesign", "ditto", "xcrun", "spctl", "rm", "cp", "tar"]) {
    fs.writeFileSync(path.join(tools, name),
      toolScripts[name] ?? '#!/bin/bash\nprintf "%s\\n" "$0 $*" >> "$RELEASE_ARGS_CALLS"\nexit 97\n', { mode: 0o755 });
  }
  const result = spawnSync("/bin/bash", [path.join(root, "scripts", `${helper}.sh`), ...args], {
    cwd: root,
    env: { PATH: `${tools}:/usr/bin:/bin`, RELEASE_ARGS_CALLS: calls, RELEASE_ARGS_NOTES: notes },
    encoding: "utf8",
    timeout: 5000,
  });
  assert.equal(result.error, undefined);
  for (const file of artifacts) {
    assert.equal(fs.readFileSync(path.join(root, file), "utf8"), "existing artifact\n");
  }
  return {
    ...result,
    calls: fs.existsSync(calls) ? fs.readFileSync(calls, "utf8") : "",
    notes: fs.existsSync(notes) ? fs.readFileSync(notes, "utf8") : undefined,
  };
}

test("publish check rejects whitespace-only release notes before calling tools", (context) => {
  const result = runHelper(context, "publish", ["--check"], { changelog: "## 0.9.0\n \t \n\n" });
  assert.equal(result.status, 1);
  assert.match(result.stderr, /CHANGELOG\.md.*release notes/);
  assert.equal(result.calls, "");
});

for (const [name, changelog] of [
  ["missing version", "## Unreleased\n\nOther notes.\n"],
  ["heading only", "## 0.9.0"],
  ["blank lines", "## 0.9.0\n\n\n"],
  ["whitespace before another version", "## 0.9.0\n \t\n\n## 0.8.2\nPrevious notes.\n"],
  ["mixed whitespace", "## 0.9.0\n\t \r\v\f\n"],
]) {
  for (const args of [[], ["--check"]]) {
    test(`publish rejects ${name} notes with ${JSON.stringify(args)} before calling tools`, (context) => {
      const result = runHelper(context, "publish", args, { changelog });
      assert.equal(result.status, 1);
      assert.match(result.stderr, /CHANGELOG\.md.*release notes/);
      assert.equal(result.calls, "");
      assert.equal(result.notes, undefined);
    });
  }
}

test("publish passes valid notes unchanged to the recording publisher", (context) => {
  const notes = '### Fixed\n\n- Keep `quoted` text, "$variables", and Unicode ✓.\n \t';
  const result = runHelper(context, "publish", [], {
    changelog: `## Unreleased\n\nOther notes.\n\n## 0.9.0\n\n${notes}\n\n## 0.8.2\nPrevious notes.\n`,
    toolScripts: {
      git: [
        "#!/bin/bash",
        'printf "%s\\n" "$0 $*" >> "$RELEASE_ARGS_CALLS"',
        'if [ "$1" = ls-remote ]; then exit 0; fi',
        'if [ "$1" = describe ]; then printf "v0.8.2\\n"; exit 0; fi',
        "exit 97",
      ].join("\n"),
      gh: [
        "#!/bin/bash",
        'printf "%s\\n" "$0 $*" >> "$RELEASE_ARGS_CALLS"',
        'if [ "$1 $2" = "release view" ]; then exit 1; fi',
        'if [ "$1 $2" = "release create" ]; then',
        '  while [ "$#" -gt 0 ]; do',
        '    if [ "$1" = --notes ]; then printf "%s" "$2" > "$RELEASE_ARGS_NOTES"; exit 97; fi',
        "    shift",
        "  done",
        "fi",
        "exit 97",
      ].join("\n"),
    },
  });
  assert.equal(result.status, 97);
  assert.match(result.calls, /\/gh release create v0\.9\.0/);
  assert.doesNotMatch(result.calls, /\/gh repo clone|\/git .*push/);
  assert.equal(result.notes, [
    notes,
    "",
    "Changes: https://github.com/mcclowes/turnstile/compare/v0.8.2...v0.9.0",
    "",
    "```sh",
    "brew install mcclowes/turnstile/turnstile                                # CLI only",
    "brew install mcclowes/turnstile/turnstile mcclowes/turnstile/turnstile-app  # CLI + menu bar app",
    "```",
  ].join("\n"));
});

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
      assert.match(result.stderr, new RegExp(`usage: scripts/${helper}\\.sh`, "i"));
      assert.equal(result.calls, "");
    });
  }
}

for (const [helper, args] of [
  ["package", []], ["package", ["--dev"]],
  ["publish", []], ["publish", ["--check"]],
  ["dist", []], ["release", []],
]) {
  test(`${helper} accepts ${JSON.stringify(args)} and reaches its blocked pipeline`, (context) => {
    const result = runHelper(context, helper, args);
    assert.notEqual(result.status, 2);
    assert.doesNotMatch(result.stderr, /usage: scripts\//i);
    assert.notEqual(result.calls, "");
    if (helper === "package" && args.includes("--dev")) {
      assert.doesNotMatch(result.calls, /\/git /);
    }
    if (helper === "publish" && args.includes("--check")) {
      assert.equal(result.status, 0);
      assert.equal(result.calls.trim().split("\n").length, 2);
      assert.match(result.calls, /\/gh release view /);
    }
  });
}
