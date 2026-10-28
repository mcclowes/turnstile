import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import test from "node:test";
import { fileURLToPath } from "node:url";

const script = fileURLToPath(new URL("./history-report.sh", import.meta.url));

function fixture(context) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "turnstile-history-test-"));
  context.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const history = path.join(root, "history with spaces");
  const database = path.join(history, "state.sqlite");
  const trace = path.join(root, "sqlite-calls.jsonl");
  const bin = path.join(root, "bin");
  fs.mkdirSync(history);
  fs.mkdirSync(bin);
  fs.writeFileSync(database, "Fixture database for the tracing stub.\n");
  fs.writeFileSync(path.join(bin, "sqlite3"), `#!/usr/bin/env node
const fs = require("node:fs");
fs.appendFileSync(process.env.SQLITE_TRACE, JSON.stringify(process.argv.slice(2)) + "\\n");
if (process.argv.at(-1).includes("SELECT COUNT(*) FROM (")) process.stdout.write("0\\n");
`, { mode: 0o755 });
  const run = (args, { stub = true, home = history } = {}) => spawnSync("/bin/bash", [script, ...args], {
    cwd: root,
    encoding: "utf8",
    timeout: 10000,
    env: {
      ...process.env,
      BASH_ENV: "/dev/null",
      TURNSTILE_HOME: home,
      SQLITE_TRACE: trace,
      PATH: stub ? `${bin}:${process.env.PATH}` : process.env.PATH,
    },
  });
  const calls = () => fs.existsSync(trace)
    ? fs.readFileSync(trace, "utf8").trim().split("\n").map((line) => JSON.parse(line))
    : [];
  return { root, history, database, run, calls };
}

const invalidArguments = [
  [""], ["--help"], ["--day", "7"], ["--days", "7\nSELECT 1"],
  ["--days"], ["--days", ""], ["--days", "0"], ["--days", "000"],
  ["--days", "-7"], ["--days", "1.5"], ["--days", "abc"], ["--days", "1e2"],
  ["--days", "+7"], ["--days", " 7"], ["--days", "7 "], ["--days", "7\n"],
  ["--days", "7 OR 1=1"], ["--days", "7; SELECT 1"], ["--other"], ["7"],
  ["--days", "7", "extra"], ["--days", "7", "--days", "8"], ["--days", "--days"],
];

for (const args of invalidArguments) {
  test(`invalid history arguments ${JSON.stringify(args)} fail before SQLite`, (context) => {
    const { database, run, calls } = fixture(context);
    const before = fs.readFileSync(database);
    const result = run(args);
    assert.equal(result.error, undefined);
    assert.equal(result.status, 2);
    assert.equal(result.stdout, "");
    assert.match(result.stderr, /usage:.*--days.*positive/i);
    assert.deepEqual(calls(), []);
    assert.deepEqual(fs.readFileSync(database), before);
  });
}

test("invalid history arguments fail before checking whether history exists", (context) => {
  const { root, run, calls } = fixture(context);
  const result = run(["--days", "garbage"], { home: path.join(root, "missing-history") });
  assert.equal(result.status, 2);
  assert.match(result.stderr, /usage:.*--days.*positive/i);
  assert.doesNotMatch(result.stderr, /no history/);
  assert.deepEqual(calls(), []);
});

for (const [args, days] of [[[], "30"], [["--days", "7"], "7"], [["--days", "007"], "007"], [["--days", "0001"], "0001"]]) {
  test(`valid history arguments ${JSON.stringify(args)} retain the read-only query and period`, (context) => {
    const { database, run, calls } = fixture(context);
    const result = run(args);
    assert.equal(result.status, 0, result.stderr);
    assert.equal(result.stderr, "");
    assert.ok(result.stdout.startsWith(`# turnstile history, last ${days} days\n`));
    const queries = calls();
    assert.ok(queries.length > 0);
    for (const query of queries) {
      assert.deepEqual(query.slice(0, 3), ["-separator", " | ", `file:${database}?mode=ro`]);
      assert.ok(query.at(-1).includes(`- ${days} * 86400`));
    }
  });
}

test("valid arguments retain the missing-history error", (context) => {
  const { root, run, calls } = fixture(context);
  const missing = path.join(root, "missing-history");
  const result = run(["--days", "7"], { home: missing });
  assert.equal(result.status, 1);
  assert.equal(result.stdout, "");
  assert.equal(result.stderr, `no history at ${missing}/state.sqlite\n`);
  assert.deepEqual(calls(), []);
});

for (const [args, days, jobs] of [[[], "30", 2], [["--days", "7"], "7", 1], [["--days", "007"], "007", 1]]) {
  test(`real SQLite history for ${days} days reports synthetic jobs without changing the database`, (context) => {
    const { history, database, run } = fixture(context);
    fs.unlinkSync(database);
    const seed = spawnSync("sqlite3", [database, `
      CREATE TABLE jobs (key TEXT, root TEXT, queued_at REAL, started_at REAL, finished_at REAL, agent INTEGER, outcome TEXT, peak REAL);
      INSERT INTO jobs VALUES ('swift build', '/fixture/alpha', unixepoch() - 86400, unixepoch() - 86390, unixepoch() - 86370, 1, 'finished', 67108864);
      INSERT INTO jobs VALUES ('npm test', '/fixture/beta', unixepoch() - 864000, unixepoch() - 863970, unixepoch() - 863920, 0, 'joined', 134217728);
      INSERT INTO jobs VALUES ('old command', '/fixture/old', unixepoch() - 3888000, unixepoch() - 3887990, unixepoch() - 3887970, 1, 'finished', 268435456);
    `], { encoding: "utf8", timeout: 10000 });
    assert.equal(seed.status, 0, seed.stderr);
    const before = fs.readFileSync(database);
    const result = run(args, { stub: false });
    assert.equal(result.status, 0, result.stderr);
    assert.equal(result.stderr, "");
    assert.ok(result.stdout.startsWith(`# turnstile history, last ${days} days\n`));
    assert.ok(result.stdout.includes(`Jobs: ${jobs}, across ${jobs} projects`));
    assert.match(result.stdout, /\| swift build \| 1 \| 64 MB \| 64 MB \| 20s \|/);
    assert.equal(result.stdout.includes("| npm test |"), jobs === 2);
    assert.doesNotMatch(result.stdout, /old command/);
    assert.deepEqual(fs.readFileSync(database), before);
    assert.deepEqual(fs.readdirSync(history), ["state.sqlite"]);
  });
}
