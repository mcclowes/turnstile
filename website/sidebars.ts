import type {SidebarsConfig} from '@docusaurus/plugin-content-docs';

const sidebars: SidebarsConfig = {
  docs: [
    'intro',
    {
      type: 'category',
      label: 'Start here',
      collapsed: false,
      items: ['start/install', 'start/agents', 'start/local-ci'],
    },
    {
      type: 'category',
      label: 'Understand turnstile',
      collapsed: false,
      items: ['concepts/how-it-works', 'concepts/scheduling', 'concepts/pressure', 'concepts/limits'],
    },
    {
      type: 'category',
      label: 'Alternatives',
      collapsed: false,
      items: [
        'compare/overview',
        'compare/orchestrators',
        'compare/containers',
        'compare/cloud',
        'compare/shell-tools',
        'compare/build-tools',
      ],
    },
    {
      type: 'category',
      label: 'Reference',
      collapsed: false,
      items: [
        'reference/commands',
        'reference/configuration',
        'reference/environment',
        'reference/exit-codes',
        'reference/menu-bar-app',
      ],
    },
    'troubleshooting',
    'development',
  ],
};

export default sidebars;
