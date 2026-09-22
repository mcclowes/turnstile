import fs from 'node:fs';
import path from 'node:path';
import type {LoadContext, Plugin} from '@docusaurus/types';
import {exportDocs, llmsFull, llmsIndex, markdownPathFor, sidebarOrder, sortBy, type DocSource} from './markdown';

export interface Options {
  docsDir: string;
  sidebars: unknown;
}

function readDocs(docsDir: string): DocSource[] {
  return fs
    .readdirSync(docsDir, {recursive: true, encoding: 'utf8'})
    .filter((file) => /\.mdx?$/.test(file) && !file.split(path.sep).some((part) => part.startsWith('_')))
    .map((file) => ({
      id: file.split(path.sep).join('/').replace(/\.mdx?$/, ''),
      filePath: path.join(docsDir, file),
      raw: fs.readFileSync(path.join(docsDir, file), 'utf8'),
    }));
}

// Emits each doc as raw Markdown at <route>.md, plus llms.txt and llms-full.txt, for agents and the "Open with AI" menu.
export default function markdownExport(context: LoadContext, options: Options): Plugin {
  return {
    name: 'markdown-export',
    async postBuild({outDir, siteConfig}) {
      const docsDir = path.resolve(context.siteDir, options.docsDir);
      const docs = sortBy(exportDocs(readDocs(docsDir)), sidebarOrder(options.sidebars));
      for (const doc of docs) {
        const file = path.join(outDir, markdownPathFor(doc.route));
        fs.mkdirSync(path.dirname(file), {recursive: true});
        fs.writeFileSync(file, doc.body);
      }
      const site = {title: siteConfig.title, tagline: siteConfig.tagline, url: siteConfig.url};
      fs.writeFileSync(path.join(outDir, 'llms.txt'), llmsIndex(site, docs));
      fs.writeFileSync(path.join(outDir, 'llms-full.txt'), llmsFull(docs));
    },
  };
}
