import type {Config} from '@docusaurus/types';
import type {Options, ThemeConfig} from '@docusaurus/preset-classic';
import {themes as prismThemes} from 'prism-react-renderer';

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
  markdown: {hooks: {onBrokenMarkdownLinks: 'throw'}},
  organizationName: 'mcclowes',
  projectName: 'turnstile',
  presets: [
    [
      'classic',
      {
        docs: {
          routeBasePath: '/',
          sidebarPath: './sidebars.ts',
          editUrl: `${github}/edit/main/website/`,
        },
        blog: false,
        theme: {customCss: './src/css/custom.css'},
      } satisfies Options,
    ],
  ],
  themeConfig: {
    colorMode: {respectPrefersColorScheme: true},
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
