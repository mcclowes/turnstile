import React, {useCallback, useEffect, useRef, useState} from 'react';
import styles from './styles.module.css';

// Mirrors Sources/TurnstileBar (MenuPanel, JobRow, MemoryMeterView) and the scheduler's arithmetic in MemoryMeter.
// Sizes are in MB; one tick is one real second and SIM_STEP simulated seconds.

type ResourceClass = 'compile' | 'test' | 'browser';
type PausedBy = 'memory' | 'user';

type Job = {
  id: number;
  project: string;
  command: string;
  cls: ResourceClass;
  estimate: number;
  footprint: number;
  target: number;
  duration: number;
  elapsed: number;
  state: 'queued' | 'running';
  pausedBy?: PausedBy;
  held?: boolean;
  waited?: number;
  agent: boolean;
  fails: boolean;
};

type RecentRun = {id: number; project: string; command: string; exit?: number; duration: number; peak: number};

type Template = Pick<Job, 'project' | 'command' | 'cls' | 'estimate' | 'duration'>;

const PHYSICAL = 16384;
const RESERVE = 1536;
const SLOT_LIMIT = 3;
const SIM_STEP = 6;
const RECENT_PREVIEW = 2;
const CLASSES: ResourceClass[] = ['compile', 'test', 'browser'];
const HUES = ['#0a84ff', '#ff375f', '#40cbe0', '#bf5af2', '#ac8e68', '#5e5ce6'];

const templates: Template[] = [
  {project: 'atlas-web', command: 'npm run build', cls: 'compile', estimate: 3700, duration: 200},
  {project: 'kiln-desktop', command: 'swift build', cls: 'compile', estimate: 2500, duration: 260},
  {project: 'signal-api', command: 'npm run typecheck', cls: 'compile', estimate: 1000, duration: 60},
  {project: 'fettle', command: 'npm run test', cls: 'test', estimate: 1400, duration: 120},
  {project: 'turnstile', command: 'swift test', cls: 'test', estimate: 1600, duration: 150},
  {project: 'relay', command: 'vitest run', cls: 'test', estimate: 900, duration: 70},
  {project: 'northstar', command: 'playwright test', cls: 'browser', estimate: 1800, duration: 180},
  {project: 'workbench', command: 'npm run test:e2e', cls: 'browser', estimate: 2300, duration: 210},
];

function job(id: number, template: Template, overrides: Partial<Job> = {}): Job {
  return {
    ...template, id, footprint: 0, target: template.estimate * (Math.random() < 0.2 ? 1.5 + Math.random() * 0.4 : 0.75 + Math.random() * 0.35),
    elapsed: 0, state: 'queued', agent: Math.random() < 0.7, fails: Math.random() < 0.15, ...overrides,
  };
}

const initialJobs: Job[] = [
  job(1298, templates[1], {state: 'running', footprint: 1150, target: 2300, elapsed: 333, duration: 420, fails: false}),
  job(1301, templates[4], {state: 'running', footprint: 620, target: 1500, elapsed: 145, duration: 230}),
  job(1305, templates[6], {state: 'running', footprint: 410, target: 1700, elapsed: 64, duration: 240, agent: false}),
  job(1308, templates[0], {elapsed: 93}),
  job(1309, templates[5], {elapsed: 51}),
  job(1310, templates[7], {elapsed: 12}),
];

const initialRecent: RecentRun[] = [
  {id: 1296, project: 'atlas-web', command: 'npm run build', exit: 1, duration: 228, peak: 3800},
  {id: 1294, project: 'signal-api', command: 'npm run typecheck', duration: 42, peak: 1024},
  {id: 1291, project: 'relay', command: 'vitest run', duration: 66, peak: 870},
];

function formatBytes(mb: number) {
  if (mb < 1024) return `${Math.max(1, Math.round(mb))} MB`;
  const gb = mb / 1024;
  if (gb >= 10) return `${Math.round(gb)} GB`;
  const rounded = Math.round(gb * 10) / 10;
  return Number.isInteger(rounded) ? `${rounded} GB` : `${rounded.toFixed(1)} GB`;
}

function formatDuration(seconds: number) {
  const s = Math.round(seconds);
  if (s < 60) return `${s}s`;
  return `${Math.floor(s / 60)}m${String(s % 60).padStart(2, '0')}s`;
}

const pendingGrowth = (j: Job) => Math.max(0, j.estimate - j.footprint);
const byClass = (jobs: Job[], cls: ResourceClass) => jobs.filter(j => j.cls === cls);

function measure(jobs: Job[], other: number) {
  const running = jobs.filter(j => j.state === 'running');
  const queued = jobs.filter(j => j.state === 'queued');
  const inJobs = running.reduce((sum, j) => sum + j.footprint, 0);
  const free = Math.max(0, PHYSICAL - other - inJobs);
  const spare = Math.max(0, free - RESERVE - running.reduce((sum, j) => sum + pendingGrowth(j), 0));
  const head = queued.find(j => !j.held);
  const fits = head ? running.length === 0 || head.estimate <= spare : true;
  const slotFull = head ? byClass(running, head.cls).length >= SLOT_LIMIT : false;
  const blocker: ResourceClass | 'memory' | null = !head ? null : slotFull ? head.cls : fits ? null : 'memory';
  return {running, queued, free, spare, head, fits, blocker, freePercent: Math.round((free / PHYSICAL) * 100)};
}

/** Each job keeps the hue its id picks unless a running job already has it, so colours don't shuffle. */
function assignHues(running: Job[]) {
  const taken = new Set<number>();
  const hues = new Map<number, string>();
  for (const id of running.map(j => j.id).sort((a, b) => a - b)) {
    let hue = id % HUES.length;
    for (let i = 0; i < HUES.length && taken.has(hue); i++) hue = (hue + 1) % HUES.length;
    taken.add(hue);
    hues.set(id, HUES[hue]);
  }
  return hues;
}

type Sim = {jobs: Job[]; recent: RecentRun[]; other: number; notice: string};

function step(sim: Sim, queuePaused: boolean, nextId: () => number, spawn: boolean): Sim {
  const other = Math.min(6200, Math.max(5000, sim.other + (Math.random() - 0.5) * 140));
  const finished: RecentRun[] = [];
  let notice = sim.notice;

  let jobs = sim.jobs.flatMap(j => {
    if (j.state === 'queued') return [{...j, elapsed: j.elapsed + SIM_STEP}];
    if (j.pausedBy) return [{...j, elapsed: j.elapsed + SIM_STEP, duration: j.duration + SIM_STEP}];
    const elapsed = j.elapsed + SIM_STEP;
    const footprint = Math.max(120, j.footprint + (j.target - j.footprint) * 0.18 + (Math.random() - 0.5) * 90);
    if (elapsed < j.duration) return [{...j, elapsed, footprint}];
    finished.push({id: j.id, project: j.project, command: j.command, exit: j.fails ? 1 : undefined, duration: elapsed, peak: Math.max(j.footprint, footprint)});
    return [];
  });
  if (finished.length) notice = `${finished[0].project} ${finished[0].exit ? 'failed' : 'finished'}, and its memory went back to the pool.`;

  let m = measure(jobs, other);
  const active = m.running.filter(j => !j.pausedBy);
  if (m.free < RESERVE * 0.75 && active.length > 1) {
    const newest = active.reduce((a, b) => (a.elapsed < b.elapsed ? a : b));
    jobs = jobs.map(j => (j.id === newest.id ? {...j, pausedBy: 'memory'} : j));
    notice = `Memory ran low, so #${newest.id} ${newest.project} was paused until it recovers.`;
  } else {
    const paused = m.running.filter(j => j.pausedBy === 'memory').sort((a, b) => b.elapsed - a.elapsed)[0];
    if (paused && m.free - RESERVE > pendingGrowth(paused) + 400) {
      jobs = jobs.map(j => (j.id === paused.id ? {...j, pausedBy: undefined} : j));
      notice = `Memory recovered, so #${paused.id} ${paused.project} carried on.`;
    }
  }

  for (let admitted = 0; !queuePaused && admitted < 3; admitted++) {
    m = measure(jobs, other);
    if (!m.head || m.blocker) break;
    const started = m.head.id;
    jobs = jobs.map(j => (j.id === started ? {...j, state: 'running', waited: j.elapsed, elapsed: 0, footprint: j.estimate * 0.12} : j));
    notice = `#${started} ${m.head.project} fit, so it started.`;
  }

  if (spawn && m.queued.length < 4) {
    jobs = [...jobs, job(nextId(), templates[Math.floor(Math.random() * templates.length)])];
  }

  return {jobs, other, notice, recent: finished.length ? [...finished, ...sim.recent].slice(0, 10) : sim.recent};
}

// Icons standing in for the app's SF Symbols.
const Svg = ({children, size = 14}: {children: React.ReactNode; size?: number}) => (
  <svg aria-hidden="true" height={size} viewBox="0 0 16 16" width={size}>{children}</svg>
);
const Hammer = () => <Svg><path d="M6 2.3c1.7-1 3.8-.9 5.3.3l2.5 2.5-1.9 1.9-1-.9-1.3 1.3-1.8-1.8 1.2-1.2C8.2 3.7 7.2 3.2 6 2.3z" fill="currentColor"/><path d="m7.7 6.5 1.8 1.8-5.9 5.9a1.3 1.3 0 0 1-1.8-1.8z" fill="currentColor"/></Svg>;
const Seal = () => <Svg><circle cx="8" cy="8" fill="currentColor" r="6.6"/><path d="m5.2 8.2 1.9 1.9 3.8-4" fill="none" stroke="var(--panel)" strokeLinecap="round" strokeLinejoin="round" strokeWidth="1.7"/></Svg>;
const Globe = () => <Svg><g fill="none" stroke="currentColor" strokeWidth="1.3"><circle cx="8" cy="8" r="6.2"/><ellipse cx="8" cy="8" rx="2.6" ry="6.2"/><path d="M1.8 8h12.4M2.8 4.8h10.4M2.8 11.2h10.4"/></g></Svg>;
const Stack = () => <Svg size={16}><g fill="none" stroke="currentColor" strokeLinejoin="round" strokeWidth="1.3"><path d="m8 2 6 3-6 3-6-3z"/><path d="m2 8 6 3 6-3M2 11l6 3 6-3"/></g></Svg>;
const Warning = () => <Svg size={16}><path d="M8 2 14.5 13.5h-13z" fill="none" stroke="currentColor" strokeLinejoin="round" strokeWidth="1.4"/><path d="M8 6.5v3.2" stroke="currentColor" strokeLinecap="round" strokeWidth="1.4"/><circle cx="8" cy="11.6" fill="currentColor" r=".8"/></Svg>;
const PauseCircle = () => <Svg size={16}><circle cx="8" cy="8" fill="none" r="6.2" stroke="currentColor" strokeWidth="1.3"/><path d="M6.5 5.5v5M9.5 5.5v5" stroke="currentColor" strokeWidth="1.4"/></Svg>;
const Sparkle = () => <Svg size={10}><path d="M8 1v4M8 11v4M1 8h4M11 8h4M3 3l2.5 2.5M10.5 10.5 13 13M13 3l-2.5 2.5M5.5 10.5 3 13" stroke="currentColor" strokeLinecap="round" strokeWidth="1.4"/></Svg>;
const Hourglass = () => <Svg size={10}><path d="M4 2h8M4 14h8M5 2c0 3 6 3 6 6s-6 3-6 6M11 2c0 3-6 3-6 6s6 3 6 6" fill="none" stroke="currentColor" strokeWidth="1.3"/></Svg>;
const CheckCircle = () => <Svg><circle cx="8" cy="8" fill="currentColor" r="6.8"/><path d="m5 8.2 2 2 4-4.2" fill="none" stroke="var(--panel)" strokeLinecap="round" strokeLinejoin="round" strokeWidth="1.7"/></Svg>;
const CrossCircle = () => <Svg><circle cx="8" cy="8" fill="currentColor" r="6.8"/><path d="m5.6 5.6 4.8 4.8m0-4.8-4.8 4.8" stroke="var(--panel)" strokeLinecap="round" strokeWidth="1.7"/></Svg>;
const ToFront = () => <Svg size={11}><path d="M3 2.5h10M8 14V6M4.5 9.5 8 6l3.5 3.5" fill="none" stroke="currentColor" strokeLinecap="round" strokeLinejoin="round" strokeWidth="1.8"/></Svg>;
const PauseGlyph = () => <Svg size={11}><path d="M5 3v10M11 3v10" stroke="currentColor" strokeLinecap="round" strokeWidth="2.4"/></Svg>;
const PlayGlyph = () => <Svg size={11}><path d="M4.5 2.8v10.4l8.5-5.2z" fill="currentColor"/></Svg>;
const Hand = () => <Svg size={11}><path d="M5 8V3.5a1 1 0 0 1 2 0V7m0-4.5a1 1 0 0 1 2 0V7m0-3.5a1 1 0 0 1 2 0V8m0-2a1 1 0 0 1 2 0v3.5c0 2.5-1.8 4.5-4.3 4.5-1.7 0-2.7-.8-3.6-2.1L3 9.5a1 1 0 0 1 1.7-1.1L5 9" fill="none" stroke="currentColor" strokeLinecap="round" strokeLinejoin="round" strokeWidth="1.4"/></Svg>;
const Cross = () => <Svg size={11}><path d="m4 4 8 8m0-8-8 8" stroke="currentColor" strokeLinecap="round" strokeWidth="2"/></Svg>;
const Gear = () => <Svg size={13}><circle cx="8" cy="8" fill="none" r="4.6" stroke="currentColor" strokeDasharray="2.1 1.5" strokeWidth="2.6"/><circle cx="8" cy="8" fill="none" r="2" stroke="currentColor" strokeWidth="1.3"/></Svg>;
const Power = () => <Svg size={13}><path d="M5 4a5.2 5.2 0 1 0 6 0M8 1.8v5.4" fill="none" stroke="currentColor" strokeLinecap="round" strokeWidth="1.4"/></Svg>;

const classIcon = {compile: <Hammer />, test: <Seal />, browser: <Globe />};

function SlotChips({running, blocker}: {running: Job[]; blocker: ResourceClass | 'memory' | null}) {
  return (
    <div className={styles.chips}>
      {CLASSES.map(cls => (
        <span className={`${styles.chip} ${blocker === cls ? styles.blocking : ''}`} key={cls} title={`${cls[0].toUpperCase() + cls.slice(1)} slots: at most ${SLOT_LIMIT} ${cls} jobs run at once, however much memory is spare.`}>
          {classIcon[cls]}{byClass(running, cls).length}/{SLOT_LIMIT}
        </span>
      ))}
    </div>
  );
}

function MemoryMeter({m, other, hues}: {m: ReturnType<typeof measure>; other: number; hues: Map<number, string>}) {
  const widths = m.running.reduce((sum, j) => sum + j.footprint + pendingGrowth(j), 0);
  const span = Math.max(PHYSICAL, other + widths + m.spare + RESERVE);
  const pct = (mb: number) => `${(mb / span) * 100}%`;
  const inJobs = m.running.reduce((sum, j) => sum + j.footprint, 0);
  const verdict = !m.head ? null
    : m.blocker === 'memory' ? `Next needs ~${formatBytes(m.head.estimate)}, only ${formatBytes(m.spare)} spare`
      : m.blocker ? `Next waits for a ${m.blocker} slot, not memory`
        : 'Next fits';
  const ghostStart = other + widths;
  const swatch = m.running.map(j => hues.get(j.id)).join(', ');

  return (
    <div className={styles.meter}>
      <div className={styles.bar}>
        <div className={styles.barFill}>
          <span className={styles.other} style={{width: pct(other)}} />
          {m.running.map(j => (
            <React.Fragment key={j.id}>
              <span style={{width: pct(j.footprint), background: hues.get(j.id), opacity: j.pausedBy ? 0.5 : 1}} title={`#${j.id} ${j.project} ${j.command}: ${formatBytes(j.footprint)} in use`} />
              <span style={{width: pct(pendingGrowth(j)), background: hues.get(j.id), opacity: 0.3}} />
            </React.Fragment>
          ))}
        </div>
        {m.head && (
          <span className={`${styles.ghost} ${m.fits ? styles.ghostFits : ''}`} style={{left: pct(ghostStart), width: `min(${pct(m.head.estimate)}, calc(100% - ${pct(ghostStart)}))`}} />
        )}
        <span className={styles.reserve} style={{left: pct(span - RESERVE)}} title={`Reserve: ${formatBytes(RESERVE)} kept free. New jobs must fit left of this line.`} />
      </div>
      <div className={styles.legend}>
        <span><i className={styles.otherDot} />Other <em>{formatBytes(other)}</em></span>
        {m.running.length > 0 && (
          <span><i style={{background: m.running.length === 1 ? swatch : `conic-gradient(${m.running.map((j, i, all) => `${hues.get(j.id)} ${(i / all.length) * 100}% ${((i + 1) / all.length) * 100}%`).join(', ')})`}} />
            {m.running.length === 1 ? m.running[0].project : `${m.running.length} jobs`} <em>{formatBytes(inJobs)}</em></span>
        )}
        {m.head && <span><i className={`${styles.ghostSwatch} ${m.fits ? styles.ghostFits : ''}`} />Next <em>~{formatBytes(m.head.estimate)}</em></span>}
        <span className={styles.spare}>{formatBytes(m.spare)} spare</span>
      </div>
      {verdict && <p className={`${styles.verdict} ${m.blocker ? styles.warn : ''}`}>{verdict}</p>}
    </div>
  );
}

type RowProps = {job: Job; hue?: string; waiting?: string; canPromote: boolean; send: (id: number, action: string) => void};

function JobRow({job, hue, waiting, canPromote, send}: RowProps) {
  const [confirmingKill, setConfirmingKill] = useState(false);
  const queued = job.state === 'queued';
  const tone = job.held || job.pausedBy === 'memory' ? 'warning' : queued || job.pausedBy ? 'neutral' : 'good';
  const share = queued ? 0 : job.footprint / job.estimate;
  const timing = queued ? formatDuration(job.elapsed) : `${formatBytes(job.footprint)} · ${formatDuration(job.elapsed)}`;

  return (
    <div className={`${styles.row} ${queued ? styles.queuedRow : ''}`} onMouseLeave={() => setConfirmingKill(false)}>
      <span className={`${styles.tile} ${styles[tone]}`}>{classIcon[job.cls]}</span>
      <div className={styles.rowBody}>
        <div className={styles.titleLine}>
          <strong>{job.project}</strong>
          {job.agent && <span className={styles.agent} title="Started by an agent"><Sparkle /></span>}
          {job.held && <span className={`${styles.tag} ${styles.warningTag}`}>Held</span>}
          {job.pausedBy && <span className={`${styles.tag} ${job.pausedBy === 'memory' ? styles.warningTag : ''}`}>{job.pausedBy === 'memory' ? 'Paused for memory' : 'Paused'}</span>}
          <span className={styles.trailing}>
            <span className={styles.timing}>{timing}</span>
            <span className={styles.actions}>
              {queued
                ? <button onClick={() => send(job.id, job.held ? 'unhold' : 'hold')} title={job.held ? 'Release' : 'Hold'} type="button"><Hand /></button>
                : <button onClick={() => send(job.id, job.pausedBy ? 'resume' : 'pause')} title={job.pausedBy ? 'Resume' : 'Pause'} type="button">{job.pausedBy ? <PlayGlyph /> : <PauseGlyph />}</button>}
              <i className={styles.actionDivider} />
              {confirmingKill
                ? <button className={styles.sure} onClick={() => send(job.id, 'kill')} type="button">Sure?</button>
                : <button className={styles.kill} onClick={() => setConfirmingKill(true)} title={queued ? 'Drop from the queue' : 'Kill'} type="button"><Cross /></button>}
            </span>
            {queued && canPromote && <button className={styles.promote} onClick={() => send(job.id, 'bump')} title="Move to front" type="button"><ToFront /></button>}
          </span>
        </div>
        <div className={styles.command}>{job.command}</div>
        {queued ? (
          <div className={styles.waiting}>
            <Hourglass /><span>{waiting}</span><em>~{formatBytes(job.estimate)}</em>
          </div>
        ) : (
          <div className={styles.usage} title="The bar fills toward the estimate. It shows memory, not progress.">
            <i style={{background: hue}} />
            <span className={styles.track}><span className={share >= 1 ? styles.over : ''} style={{width: `${Math.max(1, Math.min(1, share) * 100)}%`}} /></span>
            <span>{Math.round(share * 100)}% of ~{formatBytes(job.estimate)}</span>
          </div>
        )}
      </div>
    </div>
  );
}

function waitingHeadline(job: Job, m: ReturnType<typeof measure>, queuePaused: boolean) {
  if (job.held) return 'Held; waiting until someone releases it';
  if (queuePaused) return 'The queue is paused; resume it from the menu bar';
  if (job !== m.head) return 'Waiting';
  if (m.blocker === 'memory') return 'Waiting for memory';
  if (m.blocker) return `Waiting for a ${m.blocker} slot`;
  return 'Starting';
}

/** The head of the queue's terminal, printing what the daemon tells a waiting command. */
function TerminalBackdrop({m, queuePaused}: {m: ReturnType<typeof measure>; queuePaused: boolean}) {
  const shown = m.head ?? m.running.reduce<Job | undefined>((newest, j) => (!newest || j.elapsed < newest.elapsed ? j : newest), undefined);
  if (!shown) return null;
  const running = m.running.slice(0, 2).map(j => `${j.project} ${j.command}, ~${formatBytes(j.estimate)}`).join('; ')
    + (m.running.length > 2 ? `; +${m.running.length - 2} more` : '');
  const line = shown.state === 'running' ? (shown.waited ? `starting after ${formatDuration(shown.waited)}` : 'starting')
    : queuePaused ? 'the queue is paused; resume it from the menu bar'
      : m.blocker === 'memory' ? `waiting for memory, needs ~${formatBytes(shown.estimate)}, ~${formatBytes(m.spare)} spare (running: ${running})`
        : m.blocker ? `waiting for a ${m.blocker} slot (running: ${running})`
          : 'starting';
  return (
    <div className={styles.terminalBackdrop} aria-hidden="true">
      <span>~/Development/{shown.project}</span><strong>$ {shown.command}</strong><span>turnstile: {line}</span>
    </div>
  );
}

export default function HomepageDemo(): React.JSX.Element {
  const [sim, setSim] = useState<Sim>({jobs: initialJobs, recent: initialRecent, other: 5600, notice: 'Hover a job for its controls, or move a queued one to the front.'});
  const [queuePaused, setQueuePaused] = useState(false);
  const [showAllRecent, setShowAllRecent] = useState(false);
  const nextId = useRef(1311);
  const tick = useRef(0);
  const paused = useRef(queuePaused);
  paused.current = queuePaused;

  useEffect(() => {
    const timer = window.setInterval(() => {
      tick.current += 1;
      setSim(current => step(current, paused.current, () => nextId.current++, tick.current % 7 === 0));
    }, 1000);
    return () => window.clearInterval(timer);
  }, []);

  const send = useCallback((id: number, action: string) => {
    setSim(current => {
      const target = current.jobs.find(j => j.id === id);
      if (!target) return current;
      if (action === 'kill') {
        return {...current, jobs: current.jobs.filter(j => j.id !== id), notice: target.state === 'queued' ? `Dropped #${id} from the queue.` : `Killed #${id} and everything it started.`};
      }
      if (action === 'bump') {
        const rest = current.jobs.filter(j => j.id !== id);
        const firstQueued = rest.findIndex(j => j.state === 'queued');
        rest.splice(firstQueued < 0 ? rest.length : firstQueued, 0, target);
        return {...current, jobs: rest, notice: `#${id} ${target.project} is next.`};
      }
      if (action === 'hold' || action === 'unhold') {
        return {...current, jobs: current.jobs.map(j => (j.id === id ? {...j, held: action === 'hold'} : j)), notice: action === 'hold' ? `Holding #${id} ${target.project} in the queue until you release it.` : `Released #${id} ${target.project}.`};
      }
      const pausedBy: PausedBy | undefined = action === 'pause' ? 'user' : undefined;
      return {...current, jobs: current.jobs.map(j => (j.id === id ? {...j, pausedBy} : j)), notice: `${action === 'pause' ? 'Paused' : 'Resumed'} #${id} ${target.project}.`};
    });
  }, []);

  const m = measure(sim.jobs, sim.other);
  const hues = assignHues(m.running);
  const inFlight = m.running.length + m.queued.length;
  const pressure = m.freePercent < 15 || m.running.some(j => j.pausedBy === 'memory');
  const anyPaused = m.running.some(j => j.pausedBy);
  const memoryTone = m.freePercent < 15 ? styles.danger : m.freePercent < 30 ? styles.warning : '';
  const recent = showAllRecent ? sim.recent : sim.recent.slice(0, RECENT_PREVIEW);

  return (
    <section className={styles.demo} aria-label="Interactive turnstile menu bar demo">
      <div className={styles.desktop}>
        <div className={styles.menuBar}>
          <div className={styles.menuLeft}><span className={styles.apple} aria-hidden="true">●</span><strong>Terminal</strong><span>File</span><span>Edit</span><span>Shell</span></div>
          <div className={styles.menuRight}>
            <span className={`${styles.indicator} ${pressure ? styles.indicatorDanger : anyPaused ? styles.indicatorWarning : ''}`} aria-label={`${inFlight} jobs running or queued`}>
              {pressure ? <Warning /> : anyPaused ? <PauseCircle /> : <Stack />}{inFlight || ''}
            </span>
            <span>Mon 21 Sep&nbsp;&nbsp;10:42</span>
          </div>
        </div>

        <div className={styles.panel}>
          <header className={styles.header}>
            <div className={styles.headerLine}>
              <strong>Memory</strong>
              <span className={memoryTone}>{100 - m.freePercent}% of 16 GB</span>
              <SlotChips blocker={m.blocker} running={m.running} />
            </div>
            <MemoryMeter hues={hues} m={m} other={sim.other} />
          </header>

          <div className={styles.jobList} aria-live="polite">
            {m.running.length === 0 && m.queued.length === 0 && <p className={styles.empty}><CheckCircle />Nothing running or queued</p>}
            {m.running.length > 0 && <>
              <div className={styles.section}><span>Running</span><b>{m.running.length}</b></div>
              {m.running.map(j => <JobRow canPromote hue={hues.get(j.id)} job={j} key={j.id} send={send} />)}
            </>}
            {m.queued.length > 0 && <>
              <div className={styles.section}><span>Queued</span><b>{m.queued.length}</b></div>
              {m.queued.map((j, i) => <JobRow canPromote={i > 0} job={j} key={j.id} send={send} waiting={waitingHeadline(j, m, queuePaused)} />)}
            </>}
          </div>

          {sim.recent.length > 0 && <div className={styles.recent}>
            <div className={styles.section}>
              <span>Recent</span>
              {sim.recent.length > RECENT_PREVIEW && (
                <button onClick={() => setShowAllRecent(v => !v)} type="button">{showAllRecent ? 'Show less' : `Show ${sim.recent.length - RECENT_PREVIEW} more`}</button>
              )}
            </div>
            {recent.map(r => (
              <div className={styles.recentRow} key={r.id}>
                <span className={r.exit ? styles.dangerText : styles.goodText} title={r.exit ? `Failed with exit code ${r.exit}` : 'Finished fine'}>{r.exit ? <CrossCircle /> : <CheckCircle />}</span>
                <strong>{r.project}</strong><span className={styles.recentCommand}>{r.command}</span>
                {r.exit && <span className={styles.exit}>exit {r.exit}</span>}
                <em>{formatDuration(r.duration)}</em><em>{formatBytes(r.peak)}</em>
              </div>
            ))}
          </div>}

          <footer className={styles.footer}>
            <button className={queuePaused ? styles.warning : ''} onClick={() => setQueuePaused(v => !v)} type="button">
              {queuePaused ? <PlayGlyph /> : <PauseGlyph />}{queuePaused ? 'Resume queue' : 'Pause queue'}
            </button>
            <span className={styles.footerSpacer} />
            <span><Gear />Settings</span>
            <span><Power />Quit</span>
          </footer>
        </div>

        <TerminalBackdrop m={m} queuePaused={queuePaused} />
      </div>
      <p className={styles.notice}><span className={styles.pulse} />{sim.notice}</p>
    </section>
  );
}
