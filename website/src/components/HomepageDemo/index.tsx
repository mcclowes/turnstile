import React, {useCallback, useEffect, useRef, useState} from 'react';
import styles from './styles.module.css';

type JobKind = 'build' | 'test' | 'browser';
type JobState = 'queued' | 'running';

type Job = {
  id: number;
  project: string;
  command: string;
  estimate: number;
  elapsed: number;
  footprint: number;
  kind: JobKind;
  progress: number;
  state: JobState;
};

type RecentJob = Pick<Job, 'id' | 'project' | 'command'> & {duration: number; peak: number};

const templates: Array<Pick<Job, 'project' | 'command' | 'estimate' | 'kind'>> = [
  {project: 'atlas-web', command: 'npm run build', estimate: 2400, kind: 'build'},
  {project: 'fettle', command: 'npm run test', estimate: 1800, kind: 'test'},
  {project: 'northstar', command: 'playwright test', estimate: 2600, kind: 'browser'},
  {project: 'turnstile', command: 'swift test', estimate: 1600, kind: 'test'},
  {project: 'relay', command: 'vitest run', estimate: 900, kind: 'test'},
  {project: 'kiln-desktop', command: 'swift build', estimate: 2100, kind: 'build'},
  {project: 'signal-api', command: 'npm run typecheck', estimate: 700, kind: 'build'},
  {project: 'workbench', command: 'npm run test:e2e', estimate: 2300, kind: 'browser'},
];

const initialJobs: Job[] = [
  {id: 1298, project: 'turnstile', command: 'swift build', estimate: 2000, elapsed: 36, footprint: 1600, kind: 'build', progress: 34, state: 'running'},
  {id: 1305, project: 'kiln-desktop', command: 'swift build', estimate: 1400, elapsed: 19, footprint: 823, kind: 'build', progress: 61, state: 'running'},
  {id: 1308, project: 'fettle', command: 'npm run test:walkthrough', estimate: 2500, elapsed: 12, footprint: 0, kind: 'test', progress: 0, state: 'queued'},
  {id: 1309, project: 'fettle', command: 'npm run test', estimate: 2400, elapsed: 9, footprint: 0, kind: 'test', progress: 0, state: 'queued'},
  {id: 1310, project: 'northstar', command: 'playwright test', estimate: 2300, elapsed: 5, footprint: 0, kind: 'browser', progress: 0, state: 'queued'},
];

function formatMemory(value: number) {
  return value >= 1000 ? `${(value / 1000).toFixed(value >= 2000 ? 1 : 2)} GB` : `${Math.round(value)} MB`;
}

function formatDuration(seconds: number) {
  if (seconds < 60) return `${seconds}s`;
  return `${Math.floor(seconds / 60)}m ${String(seconds % 60).padStart(2, '0')}s`;
}

function JobIcon({kind}: {kind: JobKind}) {
  if (kind === 'test') return <span aria-hidden="true">✓</span>;
  if (kind === 'browser') return <span aria-hidden="true">◎</span>;
  return <span aria-hidden="true">◆</span>;
}

function RunningRow({job}: {job: Job}) {
  return (
    <div className={styles.jobRow}>
      <div className={`${styles.jobIcon} ${styles.runningIcon}`}><JobIcon kind={job.kind} /></div>
      <div className={styles.jobBody}>
        <div className={styles.jobTitle}>
          <strong>{job.project}</strong><span>{job.command}</span>
          <span className={styles.agentMark} title="Started by an agent">✦</span>
        </div>
        <div className={styles.jobMeta}>
          <span className={styles.runningDot} /><span>#{job.id}</span><span>·</span><span>Running</span><span>·</span><span>{formatDuration(job.elapsed)}</span>
        </div>
        <div className={styles.memoryLine}>
          <span className={styles.memoryTrack}><span style={{width: `${Math.min(100, (job.footprint / job.estimate) * 100)}%`}} /></span>
          <span>{formatMemory(job.footprint)}</span>
        </div>
      </div>
    </div>
  );
}

function QueuedRow({job, onPromote, promoted}: {job: Job; onPromote: (id: number) => void; promoted: boolean}) {
  return (
    <button className={`${styles.jobRow} ${styles.queuedRow} ${promoted ? styles.promoted : ''}`} onClick={() => onPromote(job.id)} type="button">
      <div className={`${styles.jobIcon} ${styles.queuedIcon}`}><JobIcon kind={job.kind} /></div>
      <div className={styles.jobBody}>
        <div className={styles.jobTitle}>
          <strong>{job.project}</strong><span>{job.command}</span><span className={styles.bumpIcon} aria-hidden="true">↑</span>
        </div>
        <div className={styles.jobMeta}>
          <span className={styles.queuedDot} /><span>#{job.id}</span><span>·</span><span>Queued</span><span>·</span><span>{formatDuration(job.elapsed)}</span><span>·</span><span>~{formatMemory(job.estimate)} expected</span>
        </div>
      </div>
    </button>
  );
}

export default function HomepageDemo(): React.JSX.Element {
  const [simulation, setSimulation] = useState({
    jobs: initialJobs,
    recent: [] as RecentJob[],
    notice: 'Click a queued job to move it to the front.',
  });
  const [promotedId, setPromotedId] = useState<number | null>(null);
  const nextId = useRef(1311);
  const tick = useRef(0);

  useEffect(() => {
    const timer = window.setInterval(() => {
      tick.current += 1;
      setSimulation(current => {
        const completed: RecentJob[] = [];
        let updated = current.jobs.flatMap(job => {
          if (job.state === 'queued') return [{...job, elapsed: job.elapsed + 3}];
          const progress = job.progress + 9 + Math.random() * 10;
          const footprint = Math.min(job.estimate * 1.08, Math.max(260, job.footprint + (Math.random() - 0.38) * 190));
          if (progress < 100) return [{...job, elapsed: job.elapsed + 3, footprint, progress}];
          completed.push({...job, duration: job.elapsed + 3, peak: Math.max(job.footprint, footprint)});
          return [];
        });

        const runningCount = updated.filter(job => job.state === 'running').length;
        if (runningCount < 2) {
          const firstQueued = updated.findIndex(job => job.state === 'queued');
          if (firstQueued >= 0) {
            const next = updated[firstQueued];
            updated = updated.map((job, index) => index === firstQueued
              ? {...next, state: 'running', progress: 4, elapsed: 1, footprint: next.estimate * 0.28}
              : job);
          }
        }

        if (tick.current % 3 === 0 && updated.filter(job => job.state === 'queued').length < 5) {
          const template = templates[Math.floor(Math.random() * templates.length)];
          updated.push({...template, id: nextId.current++, state: 'queued', elapsed: 0, footprint: 0, progress: 0});
        }

        return {
          jobs: updated,
          recent: completed.length ? [...completed, ...current.recent].slice(0, 3) : current.recent,
          notice: completed.length
            ? `${completed[0].project} finished. The next job started automatically.`
            : current.notice,
        };
      });
    }, 3000);
    return () => window.clearInterval(timer);
  }, []);

  const promote = useCallback((id: number) => {
    setSimulation(current => {
      const job = current.jobs.find(item => item.id === id);
      if (!job || job.state !== 'queued') return current;
      const running = current.jobs.filter(item => item.state === 'running');
      const queued = current.jobs.filter(item => item.state === 'queued');
      return {
        ...current,
        jobs: [...running, job, ...queued.filter(item => item.id !== id)],
        notice: `Job #${id} moved to the front of the queue.`,
      };
    });
    setPromotedId(id);
    window.setTimeout(() => setPromotedId(current => current === id ? null : current), 900);
  }, []);

  const {jobs, recent, notice} = simulation;
  const running = jobs.filter(job => job.state === 'running');
  const queued = jobs.filter(job => job.state === 'queued');
  const usedMemory = running.reduce((sum, job) => sum + job.footprint, 0);
  const freePercent = Math.max(18, Math.round(48 - usedMemory / 210));
  const freeMemory = 16 * freePercent / 100;

  return (
    <section className={styles.demo} aria-label="Interactive turnstile menu bar demo">
      <div className={styles.desktop}>
        <div className={styles.menuBar}>
          <div className={styles.menuLeft}><span className={styles.apple} aria-hidden="true">●</span><strong>Terminal</strong><span>File</span><span>Edit</span><span>Shell</span></div>
          <div className={styles.menuRight}>
            <span className={styles.menuGlyph}>▣</span>
            <span className={styles.turnstileStatus} aria-label={`${queued.length} jobs queued`}><span>▰</span>{queued.length || ''}</span>
            <span className={styles.menuGlyph}>◉</span><span>Mon 21 Sep&nbsp;&nbsp;10:42</span>
          </div>
        </div>

        <div className={styles.panel}>
          <div className={styles.pointer} />
          <header className={styles.memoryHeader}>
            <div className={styles.gauge} style={{'--gauge-value': `${freePercent * 3.6}deg`} as React.CSSProperties}><span>{freePercent}</span></div>
            <div><strong>Memory free</strong><span>{freeMemory.toFixed(1)} GB of 16 GB</span></div>
            <span className={styles.version}>v0.4.0</span>
          </header>
          <div className={styles.divider} />
          <div className={styles.jobList} aria-live="polite">
            {running.length > 0 && <>
              <div className={styles.sectionTitle}><span>Running</span><b>{running.length}</b></div>
              {running.map(job => <RunningRow job={job} key={job.id} />)}
            </>}
            {queued.length > 0 && <>
              <div className={styles.sectionTitle}><span>Queued</span><b>{queued.length}</b><small>Click to promote</small></div>
              {queued.map(job => <QueuedRow job={job} key={job.id} onPromote={promote} promoted={promotedId === job.id} />)}
            </>}
            {recent.length > 0 && <div className={styles.recent}>
              <div className={styles.sectionTitle}><span>Recent</span><b>{recent.length}</b></div>
              {recent.map(job => <div className={styles.recentRow} key={job.id}>
                <span className={styles.completeIcon}>✓</span><strong>{job.project}</strong><span>{job.command}</span>
                <small>{formatDuration(job.duration)} · peak {formatMemory(job.peak)}</small>
              </div>)}
            </div>}
          </div>
          <div className={styles.divider} />
          <div className={styles.footer}><span>✓</span><span>Launch at login</span><span className={styles.footerSpacer} /><span>⚙</span><span>Settings</span><span>⏻</span><span>Quit</span></div>
        </div>

        <div className={styles.terminalBackdrop} aria-hidden="true"><span>~/Development/atlas-web</span><strong>$ npm run build</strong><span>turnstile: waiting for memory…</span></div>
      </div>
      <p className={styles.notice}><span className={styles.pulse} />{notice}</p>
    </section>
  );
}
