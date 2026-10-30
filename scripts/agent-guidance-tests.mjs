import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';

const read = (path) => readFileSync(new URL(`../${path}`, import.meta.url), 'utf8');
// Read the literal printed by `turnstile agents` without compiling for a prose change.
const source = read('Sources/TurnstileCore/AgentInstructions.swift');
const snippet = source.match(/public static let snippet = """\n([\s\S]*?)\n\s*"""/)[1]
  .split('\n').map((line) => line.replace(/^ {8}/, '')).join('\n');

test('published agent guidance covers admission ownership and its limits', () => {
  assert.match(read('Sources/turnstile/CLI.swift'), /case "agents":\s*print\(AgentInstructions.snippet\)/);
  for (const text of [snippet, read('website/docs/start/agents.md')]) {
    for (const concept of [/queued.*paused/s, /Saggar/, /failed.open/i, /doctor --shells/,
      /ownership/, /concurren/, /SourceKit/, /exclusive/, /benchmark/i, /assertions/]) {
      assert.match(text, concept);
    }
  }
  assert.match(snippet, /turnstile run --class test -- node node_modules\/vitest\/vitest.mjs run/);
  assert.match(snippet, /125/);
  assert.ok(!snippet.endsWith('\n'));
});

test('agent documentation links resolve locally', () => {
  const docs = new URL('../website/docs/', import.meta.url);
  for (const file of ['start/agents.md', 'concepts/scheduling.md']) {
    const text = read(`website/docs/${file}`);
    for (const [, target] of text.matchAll(/\]\(([^)]+)\)/g)) {
      if (/^https?:/.test(target)) continue;
      const [path, anchor] = target.split('#');
      const destination = new URL(path || file.split('/').at(-1), new URL(file, docs));
      const linked = readFileSync(destination, 'utf8');
      if (anchor) {
        const headings = [...linked.matchAll(/^#+ (.+)$/gm)].map((match) =>
          match[1].toLowerCase().replace(/[^a-z0-9 -]/g, '').replace(/ /g, '-'));
        assert.ok(headings.includes(anchor), `${file}: missing ${target}`);
      }
    }
  }
});
