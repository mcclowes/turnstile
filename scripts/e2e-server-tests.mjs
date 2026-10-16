import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { randomBytes } from "node:crypto";
import { once } from "node:events";
import { spawn, spawnSync } from "node:child_process";
import test from "node:test";
import { fileURLToPath } from "node:url";

const helper = fileURLToPath(new URL("./e2e-server.sh", import.meta.url));
const marker = () => `turnstile-e2e-server-${randomBytes(3).toString("hex")}`;
const control = (args, value, environment = {}) => spawnSync("/bin/bash", [helper, ...args], {
  encoding: "utf8",
  timeout: 5000,
  env: { ...process.env, TURNSTILE_E2E_SERVER_MARKER: value, ...environment },
});

function tracingTools(context) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "turnstile-server-check-"));
  context.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const trace = path.join(root, "calls.jsonl");
  for (const name of ["pgrep", "pkill"]) {
    fs.writeFileSync(path.join(root, name), `#!/usr/bin/env node
const fs = require("node:fs");
fs.appendFileSync(process.env.CONTROL_TRACE, JSON.stringify(process.argv.slice(1)) + "\\n");
process.exit(Number(process.env.CONTROL_EXIT || "0"));
`, { mode: 0o755 });
  }
  return {
    env: { PATH: `${root}:${process.env.PATH}`, CONTROL_TRACE: trace },
    calls: () => fs.existsSync(trace) ? fs.readFileSync(trace, "utf8").trim().split("\n").map(JSON.parse) : [],
  };
}

for (const value of [undefined, "", "turnstile-e2e-server", "turnstile-e2e-server-.*", "other-ABC123", "turnstile-e2e-server-ABC 12"]) {
  test(`reject marker ${JSON.stringify(value)} before process lookup`, (context) => {
    const tools = tracingTools(context);
    for (const action of ["exists", "stop"]) {
      const result = control([action], value, tools.env);
      assert.equal(result.status, 2, result.stderr);
      assert.match(result.stderr, /usage:/i);
      assert.deepEqual(tools.calls(), []);
    }
  });
}

for (const args of [[], ["kill"], ["stop", "extra"]]) {
  test(`reject control arguments ${JSON.stringify(args)} before process lookup`, (context) => {
    const tools = tracingTools(context);
    const result = control(args, marker(), tools.env);
    assert.equal(result.status, 2, result.stderr);
    assert.deepEqual(tools.calls(), []);
  });
}

for (const action of ["exists", "stop"]) {
  test(`${action} uses one exact argv token and preserves process-tool errors`, (context) => {
    const tools = tracingTools(context);
    const value = marker();
    for (const status of [0, 1, 3]) {
      const result = control([action], value, { ...tools.env, CONTROL_EXIT: String(status) });
      assert.equal(result.status, action === "stop" && status === 1 ? 0 : status, result.stderr);
    }
    assert.equal(tools.calls().length, 3);
    for (const [executable, ...args] of tools.calls()) {
      assert.equal(path.basename(executable), action === "exists" ? "pgrep" : "pkill");
      assert.deepEqual(args, ["-f", `(^|[[:space:]])${value}([[:space:]]|$)`]);
    }
  });
}

async function server(context, value) {
  const child = spawn("/usr/bin/python3", ["-c", "import time; time.sleep(60)", value], {
    detached: true,
    stdio: "ignore",
  });
  const exited = once(child, "exit");
  context.after(async () => {
    if (child.exitCode === null && child.signalCode === null) child.kill("SIGTERM");
    await exited;
  });
  await once(child, "spawn");
  return { child, exited };
}

test("process: legacy lookup sees a concurrent server while scoped lookup ignores it", { timeout: 10000 }, async (context) => {
  const other = await server(context, marker());
  const legacy = spawnSync("pgrep", ["-f", "turnstile-e2e-server"], { encoding: "utf8", timeout: 5000 });
  assert.equal(legacy.status, 0, legacy.stderr);
  assert.ok(legacy.stdout.trim().split("\n").includes(String(other.child.pid)));
  const result = control(["exists"], marker());
  assert.equal(result.status, 1, result.stderr);
  assert.equal(other.child.exitCode, null);
  assert.equal(other.child.signalCode, null);
});

test("process: cleanup stops only its server and leaves concurrent/prefix matches alive", { timeout: 10000 }, async (context) => {
  const value = marker();
  const owned = await server(context, value);
  const otherValue = marker();
  const other = await server(context, otherValue);
  const longer = await server(context, `${value}-extra`);
  const prefixed = await server(context, `extra-${value}`);
  assert.equal(control(["exists"], value).status, 0);
  assert.equal(control(["stop"], value).status, 0);
  await owned.exited;
  assert.equal(control(["exists"], value).status, 1);
  assert.equal(control(["exists"], otherValue).status, 0);
  for (const fixture of [other, longer, prefixed]) {
    assert.equal(fixture.child.exitCode, null);
    assert.equal(fixture.child.signalCode, null);
    assert.doesNotThrow(() => process.kill(fixture.child.pid, 0));
  }
});

test("process: cleanup with no owned server is idempotent and preserves another run", { timeout: 10000 }, async (context) => {
  const otherValue = marker();
  const other = await server(context, otherValue);
  const value = marker();
  assert.equal(control(["stop"], value).status, 0);
  assert.equal(control(["stop"], value).status, 0);
  assert.equal(control(["exists"], otherValue).status, 0);
  assert.doesNotThrow(() => process.kill(other.child.pid, 0));
});
