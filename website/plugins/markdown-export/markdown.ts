import path from 'node:path';
import {markdownPathFor} from './paths';

export {markdownPathFor};

export type Frontmatter = Record<string, string>;

export interface DocSource {
  id: string;
  filePath: string;
  raw: string;
}

export interface ExportedDoc {
  id: string;
  route: string;
  title: string;
  description?: string;
  body: string;
}

export function parseFrontmatter(raw: string): {data: Frontmatter; content: string} {
  const match = raw.match(/^---\n([\s\S]*?)\n---\n?/);
  if (!match) return {data: {}, content: raw};
  const data: Frontmatter = {};
  for (const line of match[1].split('\n')) {
    const m = line.match(/^([A-Za-z0-9_-]+):\s*(.*)$/);
    if (!m) continue;
    data[m[1]] = m[2].trim().replace(/^(['"])(.*)\1$/, '$2');
  }
  return {data, content: raw.slice(match[0].length)};
}

export function routeFor(id: string, slug?: string): string {
  if (slug?.startsWith('/')) return slug;
  return '/' + id.replace(/(^|\/)index$/, '');
}

// MDX-only lines (imports and bare components) mean nothing outside the site.
export function stripMdx(content: string): string {
  return content
    .split('\n')
    .filter((line) => !/^(import|export)\s/.test(line) && !/^<[A-Z][\w.]*[^>]*\/>\s*$/.test(line))
    .join('\n')
    .replace(/\n{3,}/g, '\n\n');
}

const MARKDOWN_LINK = /\]\(([^)\s]+)(\s+"[^"]*")?\)/g;

// Relative links to other docs become absolute links to their exported .md, so agents can follow them.
export function rewriteLinks(content: string, fromId: string, routesById: Map<string, string>): string {
  return content.replace(MARKDOWN_LINK, (match, target: string, title = '') => {
    if (/^(?:[a-z][a-z0-9+.-]*:|#|\/)/i.test(target)) return match;
    const [pathPart, anchor = ''] = target.split(/(?=#)/);
    if (!/\.mdx?$/.test(pathPart)) return match;
    const id = path.posix.join(path.posix.dirname(fromId), pathPart).replace(/\.mdx?$/, '');
    const route = routesById.get(id);
    return route ? `](${markdownPathFor(route)}${anchor}${title})` : match;
  });
}

export function exportDocs(sources: DocSource[]): ExportedDoc[] {
  const parsed = sources.map((source) => ({source, ...parseFrontmatter(source.raw)}));
  const routesById = new Map(parsed.map(({source, data}) => [source.id, routeFor(source.id, data.slug)]));
  return parsed.map(({source, data, content}) => {
    const title = data.title ?? data.sidebar_label ?? source.id;
    let body = rewriteLinks(stripMdx(content), source.id, routesById).trim();
    if (!body.startsWith('# ')) body = `# ${title}\n\n${body}`;
    return {id: source.id, route: routesById.get(source.id)!, title, description: data.description, body: body + '\n'};
  });
}

export function llmsIndex(
  site: {title: string; tagline: string; url: string},
  docs: ExportedDoc[],
): string {
  const lines = docs.map((doc) => {
    const link = `- [${doc.title}](${site.url}${markdownPathFor(doc.route)})`;
    return doc.description ? `${link}: ${doc.description}` : link;
  });
  return `# ${site.title}\n\n> ${site.tagline}\n\n## Docs\n\n${lines.join('\n')}\n`;
}

export function llmsFull(docs: ExportedDoc[]): string {
  return docs.map((doc) => doc.body).join('\n---\n\n');
}

export function sidebarOrder(items: unknown): string[] {
  if (typeof items === 'string') return [items];
  if (Array.isArray(items)) return items.flatMap(sidebarOrder);
  if (items && typeof items === 'object') {
    const item = items as {type?: string; id?: string; items?: unknown};
    if (item.type === 'doc' && item.id) return [item.id];
    if (item.items) return sidebarOrder(item.items);
    return Object.values(items).flatMap(sidebarOrder);
  }
  return [];
}

export function sortBy<T extends {id: string}>(docs: T[], order: string[]): T[] {
  const rank = (id: string) => (order.includes(id) ? order.indexOf(id) : order.length);
  return [...docs].sort((a, b) => rank(a.id) - rank(b.id) || a.id.localeCompare(b.id));
}
