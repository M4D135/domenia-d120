// Heartbeat of the page (Domenia 1 OPE-030 and OPE-035): a one second beat measures how late the interface loop runs (240 last
// samples, median and 95th percentile), and a beat late by 400 ms or more is explained by the work of the screen that overlapped
// it, at most one explanation every 5 s; without overlap the cause is said unattributed, never guessed. Local measure of this
// page only, while Opérations is shown: not a test of the network, nothing leaves the page.

const BEAT_MS = 1000;
const KEEP = 240;
const STALL_MS = 400;
const EXPLAIN_EVERY_MS = 5000;
const WORK_KEEP = 32;

/**
 * @param {{ onBeat?: (state: any) => void }} [o]
 */
export function createPulse(o = {}) {
  const samples = [];
  const work = [];
  const stalls = [];
  let expected = performance.now() + BEAT_MS;
  let lastExplained = 0;
  let longTasks = 0;
  let observer = null;
  try {
    if ('PerformanceObserver' in window && PerformanceObserver.supportedEntryTypes?.includes('longtask')) {
      observer = new PerformanceObserver((list) => {
        for (const entry of list.getEntries()) {
          longTasks += 1;
          note('Tâche longue du navigateur', entry.startTime, entry.startTime + entry.duration);
        }
      });
      observer.observe({ type: 'longtask', buffered: false });
    }
  } catch {
    observer = null;
  }

  function note(name, start, end) {
    work.push({ name, start, end });
    while (work.length > WORK_KEEP) work.shift();
  }

  const timer = setInterval(() => {
    const now = performance.now();
    const late = Math.max(0, now - expected);
    expected = now + BEAT_MS;
    samples.push(late);
    while (samples.length > KEEP) samples.shift();
    if (late >= STALL_MS && now - lastExplained >= EXPLAIN_EVERY_MS) {
      lastExplained = now;
      const from = now - late;
      const culprits = work
        .map((w) => ({ ...w, overlap: Math.min(w.end, now) - Math.max(w.start, from) }))
        .filter((w) => w.overlap > 0)
        .sort((a, b) => b.overlap - a.overlap)
        .slice(0, 3);
      stalls.unshift({ at: Date.now(), late, attributed: culprits.length > 0, culprits: culprits.map((c) => ({ name: c.name, ms: c.end - c.start })) });
      while (stalls.length > 8) stalls.pop();
    }
    o.onBeat?.(state());
  }, BEAT_MS);

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
      longTasks,
      threshold: STALL_MS,
    };
  }

  return {
    /** Records a piece of work of the screen (rendering, update), so that a late beat can be explained by it. */
    measure(name, fn) {
      const start = performance.now();
      try { return fn(); } finally { note(name, start, performance.now()); }
    },
    state,
    stop() {
      clearInterval(timer);
      observer?.disconnect();
    },
  };
}
