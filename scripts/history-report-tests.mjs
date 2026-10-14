import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const report = fileURLToPath(new URL("./history-report.sh", import.meta.url));

function runReport(context, args, { historyExists = true } = {}) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "turnstile-history-report-"));
  context.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const calls = path.join(root, "calls");
  const database = path.join(root, "state.sqlite");
  if (historyExists) fs.writeFileSync(database, "untouched history");
  fs.mkdirSync(path.join(root, "bin"));
  fs.writeFileSync(path.join(root, "bin", "sqlite3"),
    '#!/bin/bash\nprintf "%s\\n" "$@" >> "$REPORT_CALLS"\nprintf "0\\n"\n', { mode: 0o755 });
  const result = spawnSync("/bin/bash", [report, ...args], {
    env: { ...process.env, TURNSTILE_HOME: root, PATH: `${root}/bin:/usr/bin:/bin`, REPORT_CALLS: calls, BASH_ENV: "/dev/null" },
    encoding: "utf8",
    timeout: 5000,
  });
  assert.equal(result.error, undefined);
  if (historyExists) assert.equal(fs.readFileSync(database, "utf8"), "untouched history");
  return { ...result, calls: fs.existsSync(calls) ? fs.readFileSync(calls, "utf8") : "" };
}

test("rejects SQL in the day count before invoking SQLite", (context) => {
  const result = runReport(context, ["--days", "1; SELECT 'injected'"]);
  assert.equal(result.status, 2);
  assert.match(result.stderr, /usage: scripts\/history-report\.sh/);
  assert.equal(result.calls, "");
});

for (const args of [
  ["--days"], ["--days", ""], ["--days", "0"], ["--days", "000"],
  ["--days", "-1"], ["--days", "+1"], ["--days", "1.5"], ["--days", "1e2"],
  ["--days", "seven"], ["--days", " 7"], ["--days", "7 "],
  ["--days", "7\nSELECT 1"], ["--days", "7", "extra"],
  ["--days", "7", "--days", "1"], ["--day", "7"], ["7"], [""], ["--help"],
]) {
  test(`rejects ${JSON.stringify(args)} before reading history`, (context) => {
    const result = runReport(context, args);
    assert.equal(result.status, 2);
    assert.match(result.stderr, /usage: scripts\/history-report\.sh/);
    assert.equal(result.stdout, "");
    assert.equal(result.calls, "");
  });
}

test("rejects unsupported arguments before checking whether history exists", (context) => {
  const result = runReport(context, ["--days", "invalid"], { historyExists: false });
  assert.equal(result.status, 2);
  assert.match(result.stderr, /usage:/);
  assert.doesNotMatch(result.stderr, /no history/);
  assert.equal(result.calls, "");
});

for (const [args, days] of [[[], "30"], [["--days", "1"], "1"], [["--days", "7"], "7"], [["--days", "007"], "007"]]) {
  test(`accepts ${JSON.stringify(args)} with read-only queries`, (context) => {
    const result = runReport(context, args);
    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, new RegExp(`last ${days} days`));
    assert.match(result.calls, /file:.*\/state\.sqlite\?mode=ro/);
    assert.ok(result.calls.includes(`- ${days} * 86400`));
  });
}

test("retains the missing-history error for valid arguments", (context) => {
  const result = runReport(context, ["--days", "7"], { historyExists: false });
  assert.equal(result.status, 1);
  assert.match(result.stderr, /no history at/);
  assert.equal(result.calls, "");
});

for (const [args, expectedJobs] of [[[], 2], [["--days", "7"], 1], [["--days", "007"], 1]]) {
  test(`reports the requested period from real isolated SQLite for ${JSON.stringify(args)}`, (context) => {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), "turnstile-history-sqlite-"));
    context.after(() => fs.rmSync(root, { recursive: true, force: true }));
    const database = path.join(root, "state.sqlite");
    const seed = spawnSync("/usr/bin/sqlite3", [database, `
      CREATE TABLE jobs (key TEXT, root TEXT, agent INTEGER, queued_at REAL, started_at REAL,
        finished_at REAL, outcome TEXT, peak REAL);
      INSERT INTO jobs VALUES ('swift build', '/fixture/recent', 1,
        strftime('%s', 'now') - 3 * 86400, strftime('%s', 'now') - 3 * 86400 + 5,
        strftime('%s', 'now') - 3 * 86400 + 15, 'ok', 1048576);
      INSERT INTO jobs VALUES ('swift test', '/fixture/older', 1,
        strftime('%s', 'now') - 12 * 86400, strftime('%s', 'now') - 12 * 86400 + 5,
        strftime('%s', 'now') - 12 * 86400 + 15, 'failed', 2097152);
    `], { encoding: "utf8", timeout: 5000 });
    assert.equal(seed.status, 0, seed.stderr);
    const before = fs.readFileSync(database);
    const result = spawnSync("/bin/bash", [report, ...args], {
      env: { ...process.env, TURNSTILE_HOME: root, PATH: "/usr/bin:/bin", BASH_ENV: "/dev/null" },
      encoding: "utf8", timeout: 5000,
    });
    assert.equal(result.error, undefined);
    assert.equal(result.status, 0, result.stderr);
    assert.equal(result.stderr, "");
    assert.ok(result.stdout.includes(`Jobs: ${expectedJobs}, across ${expectedJobs} projects`));
    assert.ok(result.stdout.includes("| swift build | 1 | 1 MB |"));
    assert.equal(result.stdout.includes("| swift test |"), expectedJobs === 2);
    assert.deepEqual(fs.readFileSync(database), before);
  });
}
