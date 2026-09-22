import React, {useEffect, useRef, useState} from 'react';
import {useLocation} from '@docusaurus/router';
import useDocusaurusContext from '@docusaurus/useDocusaurusContext';
import {markdownPathFor} from '@site/plugins/markdown-export/paths';
import styles from './styles.module.css';

export default function AiTools(): React.JSX.Element {
  const {siteConfig} = useDocusaurusContext();
  const {pathname} = useLocation();
  const containerRef = useRef<HTMLDivElement>(null);
  const [open, setOpen] = useState(false);
  const [copied, setCopied] = useState(false);

  const markdownUrl = markdownPathFor(pathname);
  const prompt = encodeURIComponent(`Read ${siteConfig.url}${markdownUrl} and answer my questions using it as context.`);

  useEffect(() => {
    if (!open) return;
    const close = (event: MouseEvent | KeyboardEvent) => {
      if (event instanceof KeyboardEvent ? event.key === 'Escape' : !containerRef.current?.contains(event.target as Node)) {
        setOpen(false);
      }
    };
    document.addEventListener('mousedown', close);
    document.addEventListener('keydown', close);
    return () => {
      document.removeEventListener('mousedown', close);
      document.removeEventListener('keydown', close);
    };
  }, [open]);

  const copy = async () => {
    setOpen(false);
    try {
      const response = await fetch(markdownUrl);
      if (!response.ok) throw new Error(String(response.status));
      await navigator.clipboard.writeText(await response.text());
      setCopied(true);
      setTimeout(() => setCopied(false), 2000);
    } catch {
      window.open(markdownUrl, '_blank', 'noopener,noreferrer');
    }
  };

  const link = (href: string, label: string, hint: string) => (
    <a role="menuitem" className={styles.item} href={href} target="_blank" rel="noopener noreferrer" onClick={() => setOpen(false)}>
      <span className={styles.label}>{label}</span>
      <span className={styles.hint}>{hint}</span>
    </a>
  );

  return (
    <div className={styles.container} ref={containerRef}>
      <button type="button" className={styles.trigger} aria-haspopup="menu" aria-expanded={open} onClick={() => setOpen((value) => !value)}>
        {copied ? 'Copied' : 'Open with AI'}
        <span aria-hidden="true">▾</span>
      </button>
      {open && (
        <div className={styles.menu} role="menu">
          <button type="button" role="menuitem" className={styles.item} onClick={copy}>
            <span className={styles.label}>Copy as Markdown</span>
            <span className={styles.hint}>Paste into any AI chat as context</span>
          </button>
          {link(markdownUrl, 'View as Markdown', 'Open the raw .md source')}
          {link(`https://claude.ai/new?q=${prompt}`, 'Open in Claude', 'Start a chat with this page')}
          {link(`https://chatgpt.com/?q=${prompt}`, 'Open in ChatGPT', 'Start a chat with this page')}
        </div>
      )}
    </div>
  );
}
