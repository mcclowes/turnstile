import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { appendFileSync, globSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { basename, dirname, join, resolve } from 'node:path';
import { tmpdir } from 'node:os';
import { pathToFileURL } from 'node:url';

export function fingerprint(root, paths) {
  if (!Array.isArray(paths) || paths.length === 0) throw new Error('Nightly input paths are required');
  const tree = execFileSync('git', ['ls-tree', '-r', '-z', 'HEAD', '--', ...paths], { cwd: root });
  if (tree.length === 0) throw new Error('No tracked nightly inputs matched');
  return createHash('sha256').update(tree).digest('hex');
}

export async function lastDelivered(request, repository, channel) {
  for (let page = 1; ; page++) {
    const deployments = await request(`/repos/${repository}/deployments?environment=nightly-${channel}&per_page=100&page=${page}`);
    for (const deployment of deployments) {
      const statuses = await request(`/repos/${repository}/deployments/${deployment.id}/statuses?per_page=1`);
      if (statuses[0]?.state === 'success' && deployment.payload?.nightlyFingerprint) {
        return deployment.payload.nightlyFingerprint;
      }
    }
    if (deployments.length < 100) return null;
  }
}

export function nightlyRecipe(source, recipe, artifact) {
  if (!recipe.nightly || recipe.nightly === recipe.stable) throw new Error('Nightly package must be distinct from stable');
  if (!/^[a-z0-9@-]+$/.test(recipe.nightly) || !/^[a-z0-9-]+$/.test(recipe.stable)) throw new Error('Invalid package token');
  if (!/^[0-9a-f]{64}$/.test(artifact.sha256)) throw new Error('Artifact checksum is required');
  const replace = (pattern, replacement) => {
    if (!pattern.test(source)) throw new Error(`Unsupported stable recipe: ${pattern}`);
    source = source.replace(pattern, replacement);
  };
  if (recipe.kind === 'cask') {
    replace(/^cask "[^"]+" do/m, `cask "${recipe.nightly}" do`);
    replace(/^  version .+$/m, `  version "${artifact.version},${artifact.revision}"`);
    source = source.replace(/^  auto_updates true\n/m, '');
    source = source.replace(/^(  app .+)$/m, `  conflicts_with cask: "${recipe.stable}"\n\n$1`);
  } else {
    const className = recipe.nightly.split('-').map((part) => part[0].toUpperCase() + part.slice(1)).join('');
    replace(/^class \w+ < Formula/m, `class ${className} < Formula`);
    source = source.replace(/^  (version|revision) .+\n/gm, '');
    source = source.replace(/^(  sha256 .+)$/m, `$1\n  version "${artifact.version}"\n  revision ${artifact.revision}\n  conflicts_with "${recipe.stable}"`);
  }
  replace(/^  url .+$/m, `  url "${artifact.url}"`);
  replace(/^  sha256 .+$/m, `  sha256 "${artifact.sha256}"`);
  if (recipe.nightlyDependency) {
    source = source.replace(/^  depends_on formula: .+$/m, `  depends_on formula: "${recipe.nightlyDependency}"`);
  }
  return source;
}

export async function deliver(request, repository, channel, candidate, publish) {
  const url = await publish();
  const deployment = await request(`/repos/${repository}/deployments`, {
    method: 'POST', body: { ref: candidate.sha, environment: `nightly-${channel}`, auto_merge: false,
      required_contexts: [], production_environment: false,
      payload: { nightlyFingerprint: candidate.fingerprint, tag: candidate.tag } },
  });
  if (!deployment.id) throw new Error('GitHub did not create a deployment');
  await request(`/repos/${repository}/deployments/${deployment.id}/statuses`, {
    method: 'POST', body: { state: 'success', environment_url: url, auto_inactive: false },
  });
}

const command = (program, args, options = {}) => execFileSync(program, args, {
  encoding: 'utf8', timeout: 300_000, stdio: ['ignore', 'pipe', 'pipe'], ...options,
});
const digest = (file) => createHash('sha256').update(readFileSync(file)).digest('hex');

export function githubRequest(token) {
  if (!token) throw new Error('GITHUB_TOKEN is required');
  return async (path, { method = 'GET', body } = {}) => {
    const response = await fetch(`https://api.github.com${path}`, {
      method, headers: { Authorization: `Bearer ${token}`, Accept: 'application/vnd.github+json',
        'X-GitHub-Api-Version': '2022-11-28', ...(body ? { 'Content-Type': 'application/json' } : {}) },
      body: body ? JSON.stringify(body) : undefined, signal: AbortSignal.timeout(30_000),
    });
    if (!response.ok) throw new Error(`GitHub ${method} ${path}: HTTP ${response.status}`);
    return response.status === 204 ? null : response.json();
  };
}

export function artifactVersion(config, env = process.env) {
  const text = config.managedVersion ? '' : readFileSync(config.versionFile, 'utf8');
  const version = config.managedVersion ? env.NIGHTLY_VERSION : config.versionPattern ? text.match(new RegExp(config.versionPattern))?.[1]
    : JSON.parse(text).version;
  if (!/^\d+\.\d+\.\d+(?:[-+][\w.-]+)?$/.test(version ?? '')) throw new Error('Cannot determine the packaged version');
  return version;
}

export async function publishHomebrew(config, candidate, { run = command, env = process.env } = {}) {
  const tap = resolve(env.NIGHTLY_TAP_PATH ?? 'nightly-tap');
  const git = (...args) => run('git', ['-C', tap, ...args]);
  if (git('status', '--porcelain').trim()) throw new Error('Nightly tap checkout must be clean');
  const artifactRepository = config.artifactRepository ?? env.GITHUB_REPOSITORY;
  const version = artifactVersion(config, env);
  const revision = Math.floor(Date.now() / 1000);
  const files = [];
  const paths = [];
  const checksums = new Map();
  for (const recipe of config.recipes) {
    const matches = env.NIGHTLY_ARTIFACT ? [env.NIGHTLY_ARTIFACT] : globSync(recipe.artifact);
    if (matches.length !== 1) throw new Error(`Expected one artifact for ${recipe.stable}, found ${matches.length}`);
    const artifact = resolve(matches[0]);
    if (recipe.kind === 'cask') {
      const unpacked = mkdtempSync(join(tmpdir(), 'nightly-app-'));
      try {
        run('ditto', ['-x', '-k', artifact, unpacked]);
        const apps = globSync('*.app', { cwd: unpacked });
        if (apps.length !== 1) throw new Error('Expected one app in the nightly archive');
        run('codesign', ['--verify', '--deep', '--strict', join(unpacked, apps[0])]);
        run('xcrun', ['stapler', 'validate', join(unpacked, apps[0])]);
      } finally { rmSync(unpacked, { recursive: true, force: true }); }
    }
    const sha256 = digest(artifact);
    checksums.set(basename(artifact), sha256);
    files.push(artifact);
    const directory = recipe.kind === 'cask' ? 'Casks' : 'Formula';
    const source = readFileSync(join(tap, directory, `${recipe.stable}.rb`), 'utf8');
    const content = nightlyRecipe(source, recipe, { version, revision, sha256,
      url: `https://github.com/${artifactRepository}/releases/download/${candidate.tag}/${basename(artifact)}` });
    const path = `${directory}/${recipe.nightly}.rb`;
    mkdirSync(dirname(join(tap, path)), { recursive: true });
    writeFileSync(join(tap, path), content);
    run('ruby', ['-c', join(tap, path)]);
    paths.push(path);
  }
  git('config', 'user.name', 'github-actions[bot]');
  git('config', 'user.email', '41898282+github-actions[bot]@users.noreply.github.com');
  git('add', '--', ...paths);
  git('commit', '--only', '-m', `Chore: update nightly packages to ${candidate.tag}`, '--', ...paths);
  const ghEnv = { ...env, GH_TOKEN: artifactRepository === env.GITHUB_REPOSITORY ? env.GITHUB_TOKEN : env.TAP_GH_TOKEN };
  if (!ghEnv.GH_TOKEN) throw new Error('Artifact repository publication token is required');
  run('gh', ['release', 'create', candidate.tag, ...new Set(files), '--repo', artifactRepository,
    ...(artifactRepository === env.GITHUB_REPOSITORY ? ['--target', candidate.sha] : []),
    '--title', `Nightly ${candidate.tag}`, '--notes', 'Internal testing build. Install the explicitly named nightly package. This is not a stable release.',
    '--prerelease', '--latest=false'], { env: ghEnv });
  const downloaded = mkdtempSync(join(tmpdir(), 'nightly-download-'));
  try {
    run('gh', ['release', 'download', candidate.tag, '--repo', artifactRepository, '--dir', downloaded], { env: ghEnv });
    for (const [name, sha256] of checksums) {
      if (digest(join(downloaded, name)) !== sha256) throw new Error(`Published checksum mismatch: ${name}`);
    }
  } finally { rmSync(downloaded, { recursive: true, force: true }); }
  git('push', 'origin', 'HEAD');
  return `https://github.com/${artifactRepository}/releases/tag/${candidate.tag}`;
}

async function main() {
  const config = JSON.parse(readFileSync('.github/nightly.json', 'utf8'));
  const request = githubRequest(process.env.GITHUB_TOKEN);
  const repository = process.env.GITHUB_REPOSITORY;
  if (!/^[\w.-]+\/[\w.-]+$/.test(repository ?? '')) throw new Error('GITHUB_REPOSITORY is required');
  if (process.argv[2] === 'plan') {
    const sha = command('git', ['rev-parse', 'HEAD']).trim();
    const inputs = fingerprint(process.cwd(), config.inputs);
    const previous = await lastDelivered(request, repository, config.channel);
    const changed = inputs !== previous;
    const tag = `nightly-${config.channel}-${process.env.GITHUB_RUN_ID}-${process.env.GITHUB_RUN_ATTEMPT}`;
    const values = { changed, sha, fingerprint: inputs, tag, version: `${process.env.GITHUB_RUN_NUMBER}.0.0` };
    if (process.env.GITHUB_OUTPUT) for (const [key, value] of Object.entries(values)) appendFileSync(process.env.GITHUB_OUTPUT, `${key}=${value}\n`);
    console.log(changed ? `Nightly candidate ${sha.slice(0, 8)} has deployable changes` : 'No changes since the last delivered nightly');
    if (process.env.GITHUB_STEP_SUMMARY) appendFileSync(process.env.GITHUB_STEP_SUMMARY,
      `### Nightly ${config.channel}\n${changed ? 'New deployable inputs; running the release gate.' : 'Skipped: no deployable changes.'}\n`);
  } else if (process.argv[2] === 'publish') {
    const candidate = { sha: process.env.NIGHTLY_SHA, fingerprint: process.env.NIGHTLY_FINGERPRINT, tag: process.env.NIGHTLY_TAG };
    if (!/^[0-9a-f]{40}$/.test(candidate.sha ?? '') || !/^[0-9a-f]{64}$/.test(candidate.fingerprint ?? '') ||
      !/^nightly-[\w-]+$/.test(candidate.tag ?? '')) throw new Error('Validated nightly candidate is required');
    if (command('git', ['rev-parse', 'HEAD']).trim() !== candidate.sha || fingerprint(process.cwd(), config.inputs) !== candidate.fingerprint) {
      throw new Error('Packaged checkout does not match the planned candidate');
    }
    command('git', ['diff', '--exit-code', 'HEAD', '--', ...config.inputs]);
    await deliver(request, repository, config.channel, candidate, () => publishHomebrew(config, candidate));
    if (process.env.GITHUB_STEP_SUMMARY) appendFileSync(process.env.GITHUB_STEP_SUMMARY, `Delivered ${candidate.tag}.\n`);
  } else throw new Error('Usage: node scripts/nightly-release.mjs [plan|publish]');
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  main().catch((error) => { console.error(error.message); process.exitCode = 1; });
}
