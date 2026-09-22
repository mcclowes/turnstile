import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

import { validateRepository } from "./license-check.mjs";

const projectRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const exampleLicense = "MIT text\n";
const exampleLicenseHash = "41883f836aa33dbbfa0e644ea4ac8a12ba116a59d046f45ae70a2259872f4f8f";

function repository(context) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "turnstile-license-check-"));
  context.after(() => fs.rmSync(root, { recursive: true, force: true }));
  fs.mkdirSync(path.join(root, "ThirdParty", "Notices"), { recursive: true });

  fs.writeFileSync(path.join(root, "Package.swift"), `
    dependencies: [.package(url: "https://github.com/example/example.git", from: "1.0.0")],
    linkerSettings: [.linkedLibrary("sqlite3")]
  `);
  fs.writeFileSync(path.join(root, "Package.resolved"), JSON.stringify({
    pins: [{
      identity: "example",
      kind: "remoteSourceControl",
      location: "https://github.com/example/example.git",
      state: { revision: "abc123", version: "1.0.0" },
    }],
  }));
  fs.writeFileSync(path.join(root, "ThirdParty", "Notices", "example-LICENSE.txt"), exampleLicense);
  writeInventory(root, {
    schemaVersion: 1,
    dependencies: [{
      identity: "example",
      name: "Example",
      location: "https://github.com/example/example.git",
      revision: "abc123",
      version: "1.0.0",
      licenses: ["MIT"],
      reviewed: true,
      notices: [{ upstreamPath: "LICENSE", file: "example-LICENSE.txt", sha256: exampleLicenseHash }],
    }],
    systemLibraries: [{ name: "sqlite3", licenses: ["blessing"] }],
  });

  return root;
}

function writeInventory(root, inventory) {
  fs.writeFileSync(path.join(root, "ThirdParty", "licenses.json"), JSON.stringify(inventory));
}

function editInventory(root, edit) {
  const file = path.join(root, "ThirdParty", "licenses.json");
  const inventory = JSON.parse(fs.readFileSync(file, "utf8"));
  edit(inventory);
  writeInventory(root, inventory);
}

function appendToManifest(root, text) {
  fs.appendFileSync(path.join(root, "Package.swift"), text);
}

test("a reviewed inventory matching the package graph passes", (context) => {
  assert.deepEqual(validateRepository(repository(context)).failures, []);
});

test("a package declared without a record fails", (context) => {
  const root = repository(context);
  appendToManifest(root, `.package(url: "https://github.com/example/new-package", from: "2.0.0")`);

  assert.deepEqual(validateRepository(root).failures, [
    "https://github.com/example/new-package: declared package has no reviewed license record",
  ]);
});

test("a resolved dependency without a record fails", (context) => {
  const root = repository(context);
  const resolvedPath = path.join(root, "Package.resolved");
  const resolved = JSON.parse(fs.readFileSync(resolvedPath, "utf8"));
  resolved.pins.push({
    identity: "transitive",
    kind: "remoteSourceControl",
    location: "https://github.com/example/transitive.git",
    state: { revision: "def456", version: "2.0.0" },
  });
  fs.writeFileSync(resolvedPath, JSON.stringify(resolved));

  assert.deepEqual(validateRepository(root).failures, [
    "transitive: resolved dependency has no reviewed license record",
  ]);
});

test("a bumped revision needs a fresh review", (context) => {
  const root = repository(context);
  editInventory(root, (inventory) => { inventory.dependencies[0].revision = "old000"; });

  assert.deepEqual(validateRepository(root).failures, ["example: revision changed"]);
});

test("an unreviewed record fails", (context) => {
  const root = repository(context);
  editInventory(root, (inventory) => { inventory.dependencies[0].reviewed = false; });

  assert.deepEqual(validateRepository(root).failures, ["example: license record isn't approved"]);
});

test("an edited notice fails", (context) => {
  const root = repository(context);
  fs.writeFileSync(path.join(root, "ThirdParty", "Notices", "example-LICENSE.txt"), "Changed\n");

  assert.deepEqual(validateRepository(root).failures, [
    "example: example-LICENSE.txt differs from the reviewed copy",
  ]);
});

test("a removed dependency leaves a stale record", (context) => {
  const root = repository(context);
  fs.rmSync(path.join(root, "Package.resolved"));

  assert.deepEqual(validateRepository(root).failures, [
    "example: reviewed dependency is no longer resolved",
  ]);
});

test("a local package must be listed as internal", (context) => {
  const root = repository(context);
  appendToManifest(root, `.package(path: "../shared")`);
  assert.deepEqual(validateRepository(root).failures, [
    "../shared: local package isn't listed as an internal dependency",
  ]);

  editInventory(root, (inventory) => { inventory.internalDependencies = [{ path: "../shared" }]; });
  assert.deepEqual(validateRepository(root).failures, []);
});

test("a newly linked library needs a record", (context) => {
  const root = repository(context);
  appendToManifest(root, `.linkedLibrary("z")`);

  assert.deepEqual(validateRepository(root).failures, ["z: linked library has no reviewed license record"]);
});

test("an unlinked system library leaves a stale record", (context) => {
  const root = repository(context);
  editInventory(root, (inventory) => { inventory.systemLibraries.push({ name: "z", licenses: ["Zlib"] }); });

  assert.deepEqual(validateRepository(root).failures, ["z: reviewed system library is no longer linked"]);
});

test("the repository's own inventory passes", () => {
  assert.deepEqual(validateRepository(projectRoot).failures, []);
});
