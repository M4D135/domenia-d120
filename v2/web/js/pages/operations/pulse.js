// Heartbeat of the interface (Domenia 1 OPE-030, OPE-031, OPE-034 and OPE-035): one beat a second measures how late the loop
// of the page runs (240 last samples, median and 95th percentile), for the whole interface and continuously once started — it is
// not stopped when Opérations is left. A beat late by 400 ms or more is explained by the tracked work of the interface that
// overlapped it (display of a screen, of a tab, refresh, list, panel), at most one explanation every 5 s; without overlap the cause
// is said unattributed, never guessed (a long task seen by the browser is counted, not taken for a cause). The tracked work and
// the stalls are reported to the engine every 5 s (operations.interface.report: closed codes and numbers only), which keeps the
// « Traitement des résultats dans l’interface » category, the slowness of the interface and one line of the technical journal per
// stall. Local measure of the page, not a test of the network.
//
// The shell starts it with the common scheduler; later startPulse() calls return that same instance.
import { call as bridgeCall } from '../../bridge.js';

const BEAT_MS = 1000;
const KEEP = 240;
const STALL_MS = 400;
const EXPLAIN_EVERY_MS = 5000;
const REPORT_EVERY_MS = 5000;
const WORK_KEEP = 32;
const WORK_MIN_MS = 30;
const MAX_REPORT = 64;

/** French labels of the closed codes of the tracked work (same list as the engine, ActivityRules.InterfaceWorkLabel). */
export const WORK_LABELS = {
  ecran: 'Affichage d’un écran',
  onglet: 'Affichage d’un onglet d’Opérations',
  actualisation: 'Actualisation d’Opérations',
  liste: 'Rendu d’une liste',
  panneau: 'Ouverture d’un panneau',
};

let instance = null;

/** The heartbeat of the interface, started once for the session. */
export function startPulse(scheduler) {
  if (!instance) instance = createPulse(scheduler);
  return instance;
}

function createPulse(scheduler) {
  if (!scheduler?.every) throw new Error('Battement commun non initialisé par la coque.');
  const samples = [];
  const work = [];
  const longTasks = [];
  const stalls = [];
  const listeners = new Set();
  const pendingRenders = [];
  let pendingStall = null;
  let lastExplained = 0;
  let longTaskCount = 0;
  let reporting = true;
  let observer = null;

  try {
    if ('PerformanceObserver' in window && PerformanceObserver.supportedEntryTypes?.includes('longtask')) {
      observer = new PerformanceObserver((list) => {
        for (const entry of list.getEntries()) {
          longTaskCount += 1;
          longTasks.push({ start: entry.startTime, end: entry.startTime + entry.duration });
          while (longTasks.length > WORK_KEEP) longTasks.shift();
        }
      });
      observer.observe({ type: 'longtask', buffered: false });
    }
  } catch {
    observer = null;
  }

  function note(code, start, end) {
    const ms = Math.max(0, end - start);
    if (pendingRenders.length < MAX_REPORT) pendingRenders.push({ work: code, ms: Math.round(ms * 10) / 10 });
    if (ms >= WORK_MIN_MS) {
      work.push({ code, start, end });
      while (work.length > WORK_KEEP) work.shift();
    }
  }

  // Display of a screen: from the change of address to the first frame after the content of the screen changed.
  let screenStart = null;
  window.addEventListener('hashchange', () => { screenStart = performance.now(); });
  const main = document.getElementById('main');
  if (main && 'MutationObserver' in window) {
    new MutationObserver(() => {
      if (screenStart === null) return;
      const start = screenStart;
      screenStart = null;
      requestAnimationFrame(() => requestAnimationFrame(() => note('ecran', start, performance.now())));
    }).observe(main, { childList: true });
  }

  scheduler.every('shell.interface-measure', BEAT_MS, ({ due, now }) => {
    const late = Math.max(0, now - due);
    samples.push(late);
    while (samples.length > KEEP) samples.shift();
    if (late >= STALL_MS && now - lastExplained >= EXPLAIN_EVERY_MS) {
      lastExplained = now;
      const from = now - late;
      const overlap = (w) => Math.min(w.end, now) - Math.max(w.start, from);
      const culprits = work.map((w) => ({ ...w, overlap: overlap(w) })).filter((w) => w.overlap > 0).sort((a, b) => b.overlap - a.overlap).slice(0, 3);
      const browser = longTasks.filter((t) => overlap(t) > 0).reduce((sum, t) => sum + (t.end - t.start), 0);
      const stall = {
        at: Date.now(), late, attributed: culprits.length > 0,
        culprits: culprits.map((c) => ({ code: c.code, name: WORK_LABELS[c.code] ?? c.code, ms: c.end - c.start })),
        longTaskMs: browser > 0 ? browser : null,
      };
      stalls.unshift(stall);
      while (stalls.length > 8) stalls.pop();
      pendingStall = stall;
    }
    const current = state();
    listeners.forEach((fn) => { try { fn(current); } catch (err) { console.error(err); } });
  });

  // Reports to the engine, silently (no busy line, no readiness signal held), only when there is something new.
  scheduler.every('shell.interface-report', REPORT_EVERY_MS, async () => {
    if (!reporting || (!pendingRenders.length && !pendingStall) || document.hidden) return;
    const renders = pendingRenders.splice(0, MAX_REPORT);
    const s = pendingStall;
    pendingStall = null;
    const stall = s ? {
      lateMs: Math.round(s.late),
      work: s.culprits[0]?.code ?? null,
      workMs: s.culprits[0] ? Math.round(s.culprits[0].ms) : null,
      longTaskMs: s.longTaskMs != null ? Math.round(s.longTaskMs) : null,
    } : null;
    await bridgeCall('operations.interface.report', { renders, stall }).catch((err) => {
      // An engine without this operation (older build, browser preview without it): the measure stays local, said once.
      if (err?.code === 'operation.unknown' || err?.code === 'arguments.invalid') { reporting = false; console.warn('Mesures de l’interface gardées dans la page', err?.code); }
      throw err;
    });
  });

  function percentile(sorted, p) {
    if (!sorted.length) return null;
    return sorted[Math.min(sorted.length - 1, Math.max(0, Math.ceil(p * sorted.length) - 1))];
  }

  function state() {
    const sorted = [...samples].sort((a, b) => a - b);
    return {
      count: samples.length,
      p50: percentile(sorted, 0.5),
      p95: sorted.length >= 20 ? percentile(sorted, 0.95) : null,
      max: sorted.length ? sorted[sorted.length - 1] : null,
      samples: [...samples],
      stalls: [...stalls],
      longTasks: longTaskCount,
      threshold: STALL_MS,
      keep: KEEP,
    };
  }

  return {
    /**
     * Records a piece of work of the interface (closed code of WORK_LABELS), so that a late beat can be explained by it and the
     * engine keeps its duration. Returns the result of fn.
     */
    measure(code, fn) {
      const start = performance.now();
      try { return fn(); } finally { note(WORK_LABELS[code] ? code : 'liste', start, performance.now()); }
    },
    /** Calls fn with the state at each beat; returns the function that stops calling it (the beat itself goes on). */
    subscribe(fn) {
      listeners.add(fn);
      return () => listeners.delete(fn);
    },
    state,
  };
}
