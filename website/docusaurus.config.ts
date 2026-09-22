import type {Config} from '@docusaurus/types';
import type {Options, ThemeConfig} from '@docusaurus/preset-classic';
import {themes as prismThemes} from 'prism-react-renderer';
import markdownExport from './plugins/markdown-export';
import sidebars from './sidebars';

const github = 'https://github.com/mcclowes/turnstile';

const config: Config = {
  title: 'turnstile',
  tagline: 'A machine-wide, memory-aware gate for builds and tests on macOS.',
  favicon: 'img/icon.svg',
  url: 'https://turnstile.marginalutility.dev',
  baseUrl: '/',
  trailingSlash: false,
  onBrokenLinks: 'throw',
  onBrokenAnchors: 'throw',
  onDuplicateRoutes: 'throw',
  markdown: {mermaid: true, hooks: {onBrokenMarkdownLinks: 'throw'}},
  themes: ['@docusaurus/theme-mermaid'],
  plugins: ['plugin-image-zoom', [markdownExport, {docsDir: 'docs', sidebars}]],
  organizationName: 'mcclowes',
  projectName: 'turnstile',
  headTags: [{tagName: 'link', attributes: {rel: 'apple-touch-icon', href: '/img/apple-touch-icon.png'}}],
  presets: [
    [
      'classic',
      {
        docs: {
          routeBasePath: '/',
          sidebarPath: './sidebars.ts',
          editUrl: `${github}/edit/main/website/`,
          showLastUpdateTime: true,
        },
        blog: false,
        sitemap: {lastmod: 'date'},
        theme: {customCss: './src/css/custom.css'},
      } satisfies Options,
    ],
  ],
  themeConfig: {
    colorMode: {respectPrefersColorScheme: true},
    tableOfContents: {minHeadingLevel: 2, maxHeadingLevel: 3},
    mermaid: {theme: {light: 'neutral', dark: 'dark'}},
    zoomSelector: '.markdown img',
    navbar: {
      title: 'turnstile',
      logo: {alt: '', src: 'img/icon.svg'},
      items: [
        {type: 'docSidebar', sidebarId: 'docs', label: 'Docs', position: 'left'},
        {href: `${github}/releases`, label: 'Releases', position: 'right'},
        {href: github, label: 'GitHub', position: 'right'},
      ],
    },
    footer: {
      style: 'light',
      links: [
        {
          title: 'Start',
          items: [
            {label: 'Install', to: '/install'},
            {label: 'How it works', to: '/how-it-works'},
            {label: 'Alternatives', to: '/alternatives'},
          ],
        },
        {
          title: 'Reference',
          items: [
            {label: 'Commands', to: '/commands'},
            {label: 'Configuration', to: '/configuration'},
            {label: 'Troubleshooting', to: '/troubleshooting'},
          ],
        },
        {
          title: 'Project',
          items: [
            {label: 'GitHub', href: github},
            {label: 'Homebrew tap', href: 'https://github.com/mcclowes/homebrew-turnstile'},
            {label: 'llms.txt', href: 'pathname:///llms.txt'},
          ],
        },
      ],
    },
    prism: {
      theme: prismThemes.github,
      darkTheme: prismThemes.dracula,
      additionalLanguages: ['bash', 'json'],
    },
  } satisfies ThemeConfig,
};

export default config;
