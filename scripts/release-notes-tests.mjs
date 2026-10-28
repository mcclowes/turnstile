import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const publishScript = fileURLToPath(new URL("./publish.sh", import.meta.url));
const version = "1.2.3";
const tag = `v${version}`;
const publicationStopped = 73;
const commandStub = `#!${process.execPath}
const fs = require("node:fs");
const path = require("node:path");
const tool = path.basename(process.argv[1]);
const args = process.argv.slice(2);
fs.appendFileSync(process.env.PUBLISH_CALLS, JSON.stringify({ tool, args }) + "\\n");
if (tool === "gh" && args[0] === "release" && args[1] === "view") process.exit(1);
if (tool === "gh" && args[0] === "release" && args[1] === "create") process.exit(${publicationStopped});
if (tool === "git" && args[0] === "ls-remote") process.exit(0);
if (tool === "git" && args[0] === "describe") { console.log("v1.2.2"); process.exit(0); }
console.error("Unexpected publication command:", tool, ...args);
process.exit(97);
`;

function fixture(context, changelog) {
  const root = fs.mkdtempSync(
    path.join(os.tmpdir(), "turnstile-release-notes-"),
  );
  context.after(() => fs.rmSync(root, { recursive: true, force: true }));
  for (const dir of [
    "scripts",
    "Sources/TurnstileCore",
    ".build/dist",
    "bin",
    "home",
    "tmp",
  ]) {
    fs.mkdirSync(path.join(root, dir), { recursive: true });
  }
  fs.copyFileSync(publishScript, path.join(root, "scripts/publish.sh"));
  fs.copyFileSync(
    new URL("./version.sh", import.meta.url),
    path.join(root, "scripts/version.sh"),
  );
  fs.writeFileSync(
    path.join(root, "Sources/TurnstileCore/Paths.swift"),
    `public static let version = "${version}"\n`,
  );
  fs.writeFileSync(path.join(root, "CHANGELOG.md"), changelog);
  for (const name of [
    `turnstile-${version}-macos.tar.gz`,
    `Turnstile-${version}.zip`,
    "SHA256SUMS",
  ]) {
    fs.writeFileSync(
      path.join(root, ".build/dist", name),
      `fixture artifact: ${name}\n`,
    );
  }
  for (const tool of [
    "gh",
    "git",
    "swift",
    "xcrun",
    "codesign",
    "security",
    "open",
    "osascript",
    "curl",
    "make",
  ]) {
    fs.writeFileSync(path.join(root, "bin", tool), commandStub, {
      mode: 0o755,
    });
  }
  const env = {
    PATH: `${root}/bin:/usr/bin:/bin`,
    HOME: path.join(root, "home"),
    TMPDIR: path.join(root, "tmp"),
    PUBLISH_CALLS: path.join(root, "calls.jsonl"),
    GIT_CONFIG_NOSYSTEM: "1",
    GIT_CONFIG_GLOBAL: "/dev/null",
  };
  const initialized = spawnSync(
    "/usr/bin/git",
    ["-c", "init.templateDir=", "init", "--quiet", root],
    { env, encoding: "utf8", timeout: 10_000 },
  );
  assert.equal(initialized.status, 0, initialized.stderr);

  function snapshot() {
    const files = fs
      .readdirSync(root, { recursive: true })
      .filter(
        (name) =>
          name !== "calls.jsonl" &&
          fs.lstatSync(path.join(root, name)).isFile(),
      );
    return files.sort().map((name) => ({
      name,
      mode: fs.statSync(path.join(root, name)).mode,
      bytes: fs.readFileSync(path.join(root, name)).toString("base64"),
    }));
  }

  const before = snapshot();
  return {
    run(args) {
      const result = spawnSync(
        "/bin/bash",
        [path.join(root, "scripts/publish.sh"), ...args],
        { env, encoding: "utf8", timeout: 10_000 },
      );
      assert.equal(result.error, undefined);
      assert.equal(result.signal, null);
      assert.deepEqual(
        snapshot(),
        before,
        "publication must preserve fixture files and artifact bytes",
      );
      const calls = fs.existsSync(env.PUBLISH_CALLS)
        ? fs
            .readFileSync(env.PUBLISH_CALLS, "utf8")
            .trim()
            .split("\n")
            .map((line) => JSON.parse(line))
        : [];
      return { ...result, calls };
    },
  };
}

const invalid = [
  ["missing current version", "# Changelog\n\n## 1.2.2\n\n- Earlier notes.\n"],
  ["heading at EOF", "# Changelog\n\n## 1.2.3"],
  ["blank lines", "## 1.2.3\n\n\n\n"],
  ["spaces", "## 1.2.3\n   \n  \n"],
  ["tabs", "## 1.2.3\n\t\t\n\t\n"],
  [
    "mixed whitespace before another version",
    "## 1.2.3\n \t\r\v\f\n## 1.2.2\n- Earlier notes.\n",
  ],
];

for (const [name, changelog] of invalid) {
  for (const args of [["--check"], []]) {
    test(`${name} fails before external calls in ${args.length ? "check" : "publication"} mode`, (context) => {
      const result = fixture(context, changelog).run(args);
      assert.equal(result.status, 1, result.stderr);
      assert.match(result.stderr, /CHANGELOG\.md has no "## 1\.2\.3" section/);
      assert.deepEqual(result.calls, []);
    });
  }
}

const valid = [
  [
    "shell punctuation",
    '### Fixed\n\n- Keep `code`, $HOME, $(exit 99), and "quotes".',
  ],
  [
    "Unicode and indentation",
    " \t\n- Unicode notes: café ☕.\n\n  Keep indentation and trailing spaces.  ",
  ],
];

for (const [name, changes] of valid) {
  const changelog = `# Changelog\n\n## ${version}\n\n${changes}\n\n## 1.2.2\n- Earlier notes.\n`;
  const views = ["mcclowes/homebrew-turnstile", "mcclowes/turnstile"].map(
    (repo) => ({
      tool: "gh",
      args: ["release", "view", tag, "--repo", repo],
    }),
  );
  test(`valid ${name} passes check without publication`, (context) => {
    const result = fixture(context, changelog).run(["--check"]);
    assert.equal(result.status, 0, result.stderr);
    assert.deepEqual(result.calls, views);
  });
  test(`valid ${name} reaches the publication recorder unchanged`, (context) => {
    const result = fixture(context, changelog).run([]);
    assert.equal(result.status, publicationStopped, result.stderr);
    const notes = `${changes}\n\nChanges: https://github.com/mcclowes/turnstile/compare/v1.2.2...${tag}\n\n\`\`\`sh\nbrew install mcclowes/turnstile/turnstile                                # CLI only\nbrew install mcclowes/turnstile/turnstile mcclowes/turnstile/turnstile-app  # CLI + menu bar app\n\`\`\``;
    assert.deepEqual(result.calls, [
      ...views,
      {
        tool: "git",
        args: [
          "ls-remote",
          "--exit-code",
          "--tags",
          "origin",
          `refs/tags/${tag}`,
        ],
      },
      { tool: "git", args: ["describe", "--tags", "--abbrev=0", `${tag}^`] },
      {
        tool: "gh",
        args: [
          "release",
          "create",
          tag,
          `.build/dist/turnstile-${version}-macos.tar.gz`,
          `.build/dist/Turnstile-${version}.zip`,
          ".build/dist/SHA256SUMS",
          "--repo",
          "mcclowes/homebrew-turnstile",
          "--title",
          `turnstile ${version}`,
          "--notes",
          notes,
        ],
      },
    ]);
  });
}
