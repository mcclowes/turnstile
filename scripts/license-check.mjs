#!/usr/bin/env node
// Holds Package.swift and Package.resolved to the reviewed inventory in ThirdParty/licenses.json.

import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const inventoryPath = path.join("ThirdParty", "licenses.json");
const noticesDirectory = path.join("ThirdParty", "Notices");

function readJSON(file) {
  return JSON.parse(fs.readFileSync(file, "utf8"));
}

function sha256(contents) {
  return crypto.createHash("sha256").update(contents).digest("hex");
}

function normalizedLocation(location) {
  return location.replace(/\.git$/, "").toLowerCase();
}

function matches(text, pattern) {
  return [...text.matchAll(pattern)].map((match) => match[1]);
}

function resolvedPins(root) {
  const file = path.join(root, "Package.resolved");
  if (!fs.existsSync(file)) return new Map();
  return new Map(readJSON(file).pins
    .filter((pin) => pin.kind === "remoteSourceControl")
    .map((pin) => [pin.identity, pin]));
}

function checkDependency(root, dependency, pin, failures) {
  const { identity } = dependency;
  if (!dependency.reviewed) failures.push(`${identity}: license record isn't approved`);
  if (normalizedLocation(dependency.location) !== normalizedLocation(pin.location)) {
    failures.push(`${identity}: source location changed`);
  }
  if (dependency.revision !== pin.state.revision) failures.push(`${identity}: revision changed`);
  if ((dependency.version ?? null) !== (pin.state.version ?? null)) failures.push(`${identity}: version changed`);
  if (!Array.isArray(dependency.licenses) || dependency.licenses.length === 0) {
    failures.push(`${identity}: no SPDX license identifiers recorded`);
  }
  if (!Array.isArray(dependency.notices) || dependency.notices.length === 0) {
    failures.push(`${identity}: no license or notice files recorded`);
    return;
  }
  for (const notice of dependency.notices) {
    const noticePath = path.join(root, noticesDirectory, notice.file);
    if (!fs.existsSync(noticePath)) {
      failures.push(`${identity}: missing ${notice.file}`);
    } else if (sha256(fs.readFileSync(noticePath)) !== notice.sha256) {
      failures.push(`${identity}: ${notice.file} differs from the reviewed copy`);
    }
  }
}

export function validateRepository(root) {
  const failures = [];
  const inventory = readJSON(path.join(root, inventoryPath));
  const manifest = fs.readFileSync(path.join(root, "Package.swift"), "utf8");
  const pins = resolvedPins(root);

  if (inventory.schemaVersion !== 1) failures.push(`${inventoryPath}: unsupported schemaVersion`);

  const dependencies = inventory.dependencies ?? [];
  const approved = new Map(dependencies.map((dependency) => [dependency.identity, dependency]));
  const approvedLocations = new Set(dependencies.map((dependency) => normalizedLocation(dependency.location)));

  for (const url of matches(manifest, /\.package\s*\([^)]*?url:\s*"([^"]+)"/g)) {
    if (!approvedLocations.has(normalizedLocation(url))) {
      failures.push(`${url}: declared package has no reviewed license record`);
    }
  }

  const internalPaths = new Set((inventory.internalDependencies ?? []).map((dependency) => dependency.path));
  for (const localPath of matches(manifest, /\.package\s*\([^)]*?path:\s*"([^"]+)"/g)) {
    if (!internalPaths.has(localPath)) {
      failures.push(`${localPath}: local package isn't listed as an internal dependency`);
    }
  }

  for (const [identity, pin] of pins) {
    const dependency = approved.get(identity);
    if (dependency) checkDependency(root, dependency, pin, failures);
    else failures.push(`${identity}: resolved dependency has no reviewed license record`);
  }

  for (const identity of approved.keys()) {
    if (!pins.has(identity)) failures.push(`${identity}: reviewed dependency is no longer resolved`);
  }

  const linked = new Set(matches(manifest, /\.linkedLibrary\s*\(\s*"([^"]+)"/g));
  const systemLibraries = new Set((inventory.systemLibraries ?? []).map((library) => library.name));
  for (const library of linked) {
    if (!systemLibraries.has(library)) failures.push(`${library}: linked library has no reviewed license record`);
  }
  for (const library of systemLibraries) {
    if (!linked.has(library)) failures.push(`${library}: reviewed system library is no longer linked`);
  }

  return { failures };
}

function main() {
  const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
  const { failures } = validateRepository(root);
  if (failures.length > 0) {
    console.error(failures.join("\n"));
    process.exit(1);
  }
  const inventory = readJSON(path.join(root, inventoryPath));
  const count = (inventory.dependencies?.length ?? 0) + (inventory.systemLibraries?.length ?? 0);
  console.log(`Checked ${count} dependency license records.`);
}

if (process.argv[1] === fileURLToPath(import.meta.url)) main();
