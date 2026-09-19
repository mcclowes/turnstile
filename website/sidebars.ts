import type {SidebarsConfig} from '@docusaurus/plugin-content-docs';

const sidebars: SidebarsConfig = {
  docs: [
    'intro',
    {
      type: 'category',
      label: 'Start here',
      collapsed: false,
      items: ['start/install', 'start/agents'],
    },
    {
      type: 'category',
      label: 'Understand turnstile',
      collapsed: false,
      items: ['concepts/how-it-works', 'concepts/scheduling', 'concepts/pressure', 'concepts/limits'],
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
