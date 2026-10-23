// One timer for owned periodic work. It never overlaps a subscriber or retries a failed subscriber indefinitely.
export function createPulse({ now = () => performance.now(), setTimer = setTimeout, clearTimer = clearTimeout } = {}) {
  const entries = new Set();
  let timer = null;
  let state = { visible: true, active: false, writing: false };
  const allowed = (entry) => state.visible && (!entry.background || (state.active && !state.writing));
  function arm() {
    if (timer !== null) { clearTimer(timer); timer = null; }
    const ready = [...entries].filter((entry) => !entry.busy && allowed(entry));
    if (!ready.length) return;
    const delay = Math.max(0, Math.min(...ready.map((entry) => entry.due)) - now());
    timer = setTimer(tick, delay);
  }
  function tick() {
    timer = null;
    for (const entry of entries) {
      if (entry.busy || !allowed(entry) || entry.due > now()) continue;
      entry.busy = true;
      Promise.resolve().then(() => entries.has(entry) && allowed(entry) ? entry.run({ due: entry.due, now: now() }) : undefined).then(() => {
        entry.failures = 0;
      }, (error) => {
        entry.failures++;
        if (entry.failures >= 3) entries.delete(entry);
        // The handler is diagnostic only; its own failure cannot break the shared timer.
        try { entry.onError?.(error, entry.failures); } catch { console.warn(`Suivi ${entry.owner} : diagnostic non publié.`); }
      }).finally(() => {
        entry.busy = false;
        entry.due = now() + entry.interval;
        arm();
      });
    }
    arm();
  }
  return {
    every(owner, interval, run, { background = false, firstDelay = interval, onError = () => console.warn(`Suivi ${owner} en échec.`) } = {}) {
      if (typeof owner !== 'string' || !owner || typeof run !== 'function' || !Number.isFinite(interval) || interval < 100 || interval > 3600000
          || !Number.isFinite(firstDelay) || firstDelay < 0 || firstDelay > interval) throw new Error('Abonnement périodique invalide.');
      const entry = { owner, interval, run, background, onError, due: now() + firstDelay, busy: false, failures: 0 };
      entries.add(entry); arm();
      return () => { entries.delete(entry); arm(); };
    },
    setState(next) {
      const before = new Map([...entries].map((entry) => [entry, allowed(entry)]));
      state = { ...state, ...next };
      for (const entry of entries) {
        if (!before.get(entry) && allowed(entry)) {
          // Showing a view may catch up once. Activating a window never starts a network collection by itself.
          entry.due = now() + (entry.background ? entry.interval : 0);
        }
      }
      arm();
    },
    forget(owner) { for (const entry of entries) if (entry.owner === owner) entries.delete(entry); arm(); },
    dispose() { entries.clear(); if (timer !== null) clearTimer(timer); timer = null; },
    get count() { return entries.size; },
  };
}

export const pulse = createPulse();
