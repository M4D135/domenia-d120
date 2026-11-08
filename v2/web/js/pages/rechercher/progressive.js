// Local-only preview. Network reads finish in their own operation, never in a rendering tick.
// The virtual grid publishes the full list once; do not walk/sort growing prefixes or add
// a delay proportional to the fleet size just to count rows that are already received.
export function progressiveRows(rows, { pulse, current = () => true, append, signal }) {
  if (signal?.aborted) return Promise.resolve(false);
  if (!Array.isArray(rows)) return Promise.reject(new Error('Liste de résultats invalide.'));
  return new Promise((resolve, reject) => {
    let previewed = false, stopped = false;
    const finish = (value) => { if (stopped) return; stopped = true; release(); signal?.removeEventListener('abort', abort); resolve(value); };
    const abort = () => finish(false);
    const release = pulse.every('search.render', 20, () => {
      if (!current()) { finish(false); return; }
      if (previewed) { finish(true); return; }
      const batch = rows.slice(0, 400);
      // Mark accepted only after the consumer returns. A failed preview is retried,
      // never silently treated as a complete list. Its replacement is idempotent.
      append(batch, batch.length, rows.length);
      previewed = true;
      if (batch.length === rows.length) finish(true);
      // One shared tick lets the bounded preview paint before the complete grid is published.
    }, { firstDelay: 0, maxFailures: 3, onError: (error, failures) => {
      if (failures === 3) { stopped = true; release(); signal?.removeEventListener('abort', abort); reject(error); }
    } });
    signal?.addEventListener('abort', abort, { once: true });
  });
}

// Coalesce visual follow-up; immediate selection/authorization and explicit actions stay in their event handlers.
export function selectionPaint(pulse, paint) {
  let latest, release = null;
  return {
    request(value) {
      latest = value;
      if (release) return;
      release = pulse.every('search.selection-paint', 200, () => {
        const value = latest;
        if (value !== undefined) paint(value);
        if (latest === value) latest = undefined;
        if (latest === undefined) { release?.(); release = null; }
      }, { maxFailures: 3, onError: (_, failures) => { if (failures === 3) { release?.(); release = null; } } });
    },
    cancel() { latest = undefined; release?.(); release = null; },
  };
}
