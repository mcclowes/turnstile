import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import { randomBytes } from "node:crypto";
import { once } from "node:events";
import test from "node:test";
import { fileURLToPath } from "node:url";

const helper = fileURLToPath(new URL("./e2e-server.sh", import.meta.url));
const tag = () => `turnstile-e2e-server-${randomBytes(12).toString("hex")}`;

async function server(context, marker) {
  const child = spawn(process.execPath, ["-e", "setInterval(() => {}, 1000)", marker], { stdio: "ignore" });
  const exited = once(child, "exit");
  context.after(async () => {
    if (child.exitCode === null && child.signalCode === null) child.kill();
    await exited;
  });
  await once(child, "spawn");
  return { child, exited };
}

function control(...args) {
  const result = spawnSync("/bin/bash", [helper, ...args], { encoding: "utf8", timeout: 3000 });
  assert.equal(result.error, undefined);
  return result;
}

test("an absent run does not detect another run's server", async (context) => {
  const first = tag();
  const second = tag();
  await server(context, second);
  assert.equal(control("check", second).status, 0);
  assert.equal(control("check", first).status, 1);
});

test("stopping one run leaves another run and a longer matching-prefix marker alive", async (context) => {
  const first = tag();
  const second = tag();
  const longer = `${first}extra`;
  const owned = await server(context, first);
  await server(context, second);
  await server(context, longer);
  assert.equal(control("check", first).status, 0);
  assert.equal(control("stop", first).status, 0);
  await owned.exited;
  assert.equal(control("check", first).status, 1);
  assert.equal(control("check", second).status, 0);
  assert.equal(control("check", longer).status, 0);
});

test("stopping an absent run reports no match", () => {
  assert.equal(control("stop", tag()).status, 1);
});

for (const args of [
  ["stop", ""], ["stop", "turnstile-e2e-server-"],
  ["stop", "turnstile-e2e-server-.*"], ["stop", "another-server"],
  ["stop"], ["stop", "turnstile-e2e-server-abc", "extra"],
  ["unknown", "turnstile-e2e-server-abc"],
]) {
  test(`invalid control ${JSON.stringify(args)} leaves a fixture alive`, async (context) => {
    const marker = tag();
    await server(context, marker);
    const result = control(...args);
    assert.equal(result.status, 2);
    assert.match(result.stderr, /usage:/i);
    assert.equal(control("check", marker).status, 0);
  });
}
