import {describe, expect, it} from 'vitest';
import {exportDocs, llmsIndex, markdownPathFor, rewriteLinks, sidebarOrder, sortBy, stripMdx} from './markdown';

const doc = (id: string, frontmatter: string, body: string) => ({id, filePath: `${id}.md`, raw: `---\n${frontmatter}\n---\n\n${body}`});

describe('markdownPathFor', () => {
  it('maps the root to index.md and other routes to <route>.md', () => {
    expect(markdownPathFor('/')).toBe('/index.md');
    expect(markdownPathFor('/how-it-works')).toBe('/how-it-works.md');
  });
});

describe('stripMdx', () => {
  it('drops imports and bare components but keeps prose and code', () => {
    const input = "import Demo from '@site/src/components/Demo';\n\n<Demo />\n\nText\n\n```sh\nturnstile status\n```";
    expect(stripMdx(input).trim()).toBe('Text\n\n```sh\nturnstile status\n```');
  });
});

describe('rewriteLinks', () => {
  const routes = new Map([
    ['concepts/limits', '/limits'],
    ['reference/configuration', '/configuration'],
  ]);

  it('rewrites relative doc links to exported Markdown, keeping anchors', () => {
    expect(rewriteLinks('[a](../reference/configuration.md#machine-settings)', 'concepts/how-it-works', routes)).toBe(
      '[a](/configuration.md#machine-settings)',
    );
    expect(rewriteLinks('[a](limits.md)', 'concepts/how-it-works', routes)).toBe('[a](/limits.md)');
  });

  it('leaves external, anchor, absolute, and unknown links alone', () => {
    for (const link of ['[a](https://x.dev/a.md)', '[a](#here)', '[a](/img/x.webp)', '[a](missing.md)']) {
      expect(rewriteLinks(link, 'concepts/how-it-works', routes)).toBe(link);
    }
  });
});

describe('exportDocs', () => {
  it('uses the slug for the route and adds a heading only when the page lacks one', () => {
    const [intro, limits] = exportDocs([
      doc('intro', 'title: turnstile\nslug: /', 'Overview text'),
      doc('concepts/limits', 'title: Limits\nslug: /limits\ndescription: "Slots"', '# Limits\n\nBody'),
    ]);
    expect(intro).toMatchObject({route: '/', body: '# turnstile\n\nOverview text\n'});
    expect(limits).toMatchObject({route: '/limits', description: 'Slots', body: '# Limits\n\nBody\n'});
  });
});

describe('ordering', () => {
  it('follows the sidebar and puts unlisted docs last', () => {
    const order = sidebarOrder({docs: ['intro', {type: 'category', label: 'X', items: ['b', {type: 'doc', id: 'a'}]}]});
    expect(order).toEqual(['intro', 'b', 'a']);
    expect(sortBy([{id: 'z'}, {id: 'a'}, {id: 'intro'}, {id: 'b'}], order).map((d) => d.id)).toEqual(['intro', 'b', 'a', 'z']);
  });
});

describe('llmsIndex', () => {
  it('lists each page with its absolute Markdown URL and description', () => {
    const text = llmsIndex({title: 't', tagline: 'Gate', url: 'https://t.dev'}, [
      {id: 'l', route: '/limits', title: 'Limits', description: 'Slots', body: ''},
    ]);
    expect(text).toBe('# t\n\n> Gate\n\n## Docs\n\n- [Limits](https://t.dev/limits.md): Slots\n');
  });
});
