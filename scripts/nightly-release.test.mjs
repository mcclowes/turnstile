import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync, rmSync, mkdirSync, cpSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { execFileSync } from 'node:child_process';
import { fingerprint, lastDelivered, nightlyRecipe, deliver, publishHomebrew } from './nightly-release.mjs';

test('deployable inputs change the fingerprint; documentation-only commits do not', () => {
  const root = mkdtempSync(join(tmpdir(), 'nightly-inputs-'));
  const git = (...args) => execFileSync('git', args, { cwd: root, encoding: 'utf8' });
  try {
    git('init', '-q');
    git('config', 'user.name', 'Nightly test');
    git('config', 'user.email', 'nightly@example.invalid');
    mkdirSync(join(root, 'Sources'));
    writeFileSync(join(root, 'Sources/app.swift'), 'version one');
    writeFileSync(join(root, 'README.md'), 'documentation');
    git('add', '.'); git('commit', '-qm', 'Initial');
    const first = fingerprint(root, ['Sources']);
    writeFileSync(join(root, 'README.md'), 'new documentation');
    git('add', '.'); git('commit', '-qm', 'Docs');
    assert.equal(fingerprint(root, ['Sources']), first);
    writeFileSync(join(root, 'Sources/app.swift'), 'version two');
    git('add', '.'); git('commit', '-qm', 'Code');
    assert.notEqual(fingerprint(root, ['Sources']), first);
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test('a failed publish never records delivery; a successful publish records the exact candidate last', async () => {
  const events = [];
  const request = async (path, options) => {
    events.push([path, options]);
    return { id: 42 };
  };
  const candidate = { sha: 'a'.repeat(40), fingerprint: 'b'.repeat(64), tag: 'nightly-123' };
  await assert.rejects(deliver(request, 'o/app', 'homebrew', candidate, async () => { throw new Error('tap rejected push'); }), /tap rejected/);
  assert.equal(events.length, 0);
  await deliver(request, 'o/app', 'homebrew', candidate, async () => { events.push(['publish']); return 'https://github.com/o/tap/releases/tag/nightly-123'; });
  assert.equal(events[0][0], 'publish');
  assert.equal(events[1][1].body.ref, candidate.sha);
  assert.equal(events[1][1].body.payload.nightlyFingerprint, candidate.fingerprint);
  assert.equal(events[2][1].body.state, 'success');
});

test('nightly recipes use immutable downloads and cannot replace stable package entries', () => {
  const source = 'cask "demo" do\n  version "1.2.3"\n  sha256 "old"\n  url "https://old.invalid/demo.zip"\n  app "Demo.app"\nend\n';
  const recipe = nightlyRecipe(source, { kind: 'cask', stable: 'demo', nightly: 'demo@nightly' }, {
    version: '1.2.3', revision: 123, url: 'https://github.com/o/tap/releases/download/nightly-123/Demo.zip', sha256: 'a'.repeat(64),
  });
  assert.match(recipe, /cask "demo@nightly"/);
  assert.match(recipe, /conflicts_with cask: "demo"/);
  assert.match(recipe, /version "1.2.3,123"/);
  assert.match(recipe, /download\/nightly-123\/Demo.zip/);
  assert.throws(() => nightlyRecipe(source, { kind: 'cask', stable: 'demo', nightly: 'demo' }, {}), /distinct/);
});

for (const fixture of [
  { name: 'license and dependency', license: '  license "MIT"\n', dependencies: '  depends_on macos: :tahoe\n', dependencyStanzas: ['depends_on'] },
  { name: 'multiline license and platform dependencies', license: '  license any_of: [\n    "MIT",\n    "Apache-2.0",\n  ]\n', dependencies: '  on_macos do\n    depends_on "demo-data"\n  end\n', dependencyStanzas: ['on_macos'] },
  { name: 'optional license and dependencies omitted', license: '', dependencies: '', dependencyStanzas: [] },
]) {
  test(`nightly formula stanza order preserves ${fixture.name}`, () => {
    const body = '  resource "demo-data" do\n    url "https://example.invalid/data.tar.gz"\n    sha256 "resource-checksum"\n  end\n\n  def install\n    bin.install "demo"\n  end\n\n  test do\n    assert_equal version.to_s, shell_output("#{bin}/demo --version").strip\n  end\nend\n';
    const source = `class Demo < Formula\n  desc "Demo"\n  homepage "https://example.invalid/demo"\n  url "https://example.invalid/stable.tar.gz"\n  version "0.9.0"\n  sha256 "stable-checksum"\n${fixture.license}  revision 2\n\n${fixture.dependencies}\n${body}`;
    const artifact = { version: '1.2.3', revision: 123, url: 'https://example.invalid/nightly-123/demo.tar.gz', sha256: 'a'.repeat(64) };
    const rendered = nightlyRecipe(source, { kind: 'formula', stable: 'demo', nightly: 'demo-nightly' }, artifact);
    const declarations = [...rendered.matchAll(/^  ([a-z_][a-z_0-9]*)(?:\s|$)/gm)].map((match) => match[1]).filter((name) => name !== 'end');
    assert.deepEqual(declarations, ['desc', 'homepage', 'url', 'version', 'sha256', ...(fixture.license ? ['license'] : []), 'revision', ...fixture.dependencyStanzas, 'conflicts_with', 'resource', 'def', 'test']);
    assert.match(rendered, /^class DemoNightly < Formula\n/);
    assert.ok(rendered.includes(`  url "${artifact.url}"\n`));
    assert.ok(rendered.includes(`  version "${artifact.version}"\n`));
    assert.ok(rendered.includes(`  sha256 "${artifact.sha256}"\n`));
    assert.ok(rendered.includes(`  revision ${artifact.revision}\n`));
    assert.ok(rendered.includes('  conflicts_with "demo"\n'));
    assert.ok(rendered.includes(fixture.license));
    assert.ok(rendered.includes(fixture.dependencies));
    assert.ok(rendered.endsWith(body));
  });
}

test('only a successful deployment advances the nightly baseline, including across pages', async () => {
  const calls = [];
  const request = async (path) => {
    calls.push(path);
    if (path.includes('/1/statuses')) return [{ state: 'failure' }];
    if (path.includes('/2/statuses')) return [{ state: 'success' }];
    if (path.includes('page=2')) return [{ id: 2, payload: { nightlyFingerprint: 'delivered' } }];
    return Array.from({ length: 100 }, () => ({ id: 1, payload: { nightlyFingerprint: 'failed' } }));
  };
  assert.equal(await lastDelivered(request, 'owner/app', 'homebrew'), 'delivered');
  assert.ok(calls.some((path) => path.includes('page=2')));
  await assert.rejects(lastDelivered(async () => { throw new Error('API unavailable'); }, 'owner/app', 'homebrew'), /API unavailable/);
});

test('Homebrew publication verifies the remote artifact before pushing only the nightly recipe', async () => {
  const root = mkdtempSync(join(tmpdir(), 'nightly-publish-'));
  const tap = join(root, 'tap');
  const origin = join(root, 'remote.git');
  const real = (program, args, options = {}) => execFileSync(program, args, { encoding: 'utf8', ...options });
  try {
    real('git', ['init', '--bare', '-q', origin]);
    real('git', ['init', '-q', '-b', 'main', tap]);
    const git = (...args) => real('git', ['-C', tap, ...args]);
    git('config', 'user.name', 'Nightly test'); git('config', 'user.email', 'nightly@example.invalid');
    mkdirSync(join(tap, 'Formula'));
    const stable = 'class Demo < Formula\n  url "https://old.invalid/demo.tar.gz"\n  sha256 "old"\nend\n';
    writeFileSync(join(tap, 'Formula/demo.rb'), stable);
    git('add', '.'); git('commit', '-qm', 'Stable'); git('remote', 'add', 'origin', origin); git('push', '-q', 'origin', 'main');
    const artifact = join(root, 'demo.tar.gz'); writeFileSync(artifact, 'a packaged CLI');
    writeFileSync(join(root, 'package.json'), '{"version":"1.2.3"}');
    const config = { versionFile: join(root, 'package.json'), recipes: [{ kind: 'formula', stable: 'demo', nightly: 'demo-nightly', nightlyAlias: 'demo@nightly', artifact }] };
    const candidate = { tag: 'nightly-homebrew-123-1' };
    let corrupt = true;
    const run = (program, args, options) => {
      if (program === 'gh') {
        if (args[1] === 'download') {
          const directory = args[args.indexOf('--dir') + 1];
          if (corrupt) writeFileSync(join(directory, 'demo.tar.gz'), 'corrupt download');
          else cpSync(artifact, join(directory, 'demo.tar.gz'));
        }
        return '';
      }
      return real(program, args, options);
    };
    const env = { ...process.env, NIGHTLY_TAP_PATH: tap, GITHUB_REPOSITORY: 'o/app', GITHUB_TOKEN: 'test' };
    await assert.rejects(publishHomebrew(config, candidate, { run, env }), /checksum mismatch/);
    assert.doesNotMatch(real('git', ['--git-dir', origin, 'ls-tree', '-r', 'main']), /demo-nightly/);
    // A fresh runner retries from the still-published tap, not the failed local commit.
    const retryTap = join(root, 'retry');
    real('git', ['clone', '-q', '-b', 'main', origin, retryTap]);
    corrupt = false;
    await publishHomebrew(config, candidate, { run, env: { ...env, NIGHTLY_TAP_PATH: retryTap } });
    assert.match(real('git', ['--git-dir', origin, 'show', 'main:Formula/demo-nightly.rb']), /class DemoNightly/);
    assert.equal(real('git', ['--git-dir', origin, 'show', 'main:Aliases/demo@nightly']), '../Formula/demo-nightly.rb');
    assert.match(real('git', ['--git-dir', origin, 'ls-tree', 'main', 'Aliases/demo@nightly']), /^120000 blob/);
    assert.equal(real('git', ['--git-dir', origin, 'show', 'main:Formula/demo.rb']), stable);
  } finally { rmSync(root, { recursive: true, force: true }); }
});
