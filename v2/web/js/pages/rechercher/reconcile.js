// Pure rules of the revalidation of a Rechercher list (RCH-048): what a « search.reconcile » answer changes in the rows
// shown, and the pacing that applies it to the grid by small slices. No DOM, no network: tested by tests/web/rechercher.test.mjs.

/** At most this many row events are applied in one tick of the page… */
export const EVENTS_PER_TICK = 8;
/** …and a tick stops once this many milliseconds are spent, so a long revalidation never freezes the list. */
export const TICK_BUDGET_MS = 5;

/** Fields of a row whose change repaints it (name, login, UPN, state, OS, last logon, description, modification, DN). */
function differs(old, fresh) {
  return old.dn !== fresh.dn || old.name !== fresh.name || old.login !== fresh.login || old.upn !== fresh.upn
    || old.state?.key !== fresh.state?.key || old.state?.label !== fresh.state?.label || old.state?.tone !== fresh.state?.tone || old.os !== fresh.os || old.lastLogon !== fresh.lastLogon
    || old.description !== fresh.description || old.changed !== fresh.changed;
}

/**
 * Row events of a revalidation answer, followed by the object GUID: a row read again with a change is repainted, a new
 * object is added (« nouveau »), a moved one keeps its row (repainted with its new DN, then marked), an absent one is
 * marked « à revérifier ». Nothing is ever removed.
 */
export function reconcileEvents(before, res) {
  const known = new Map((before ?? []).map((x) => [x.id, x]));
  const moved = new Set(res?.moved ?? []);
  const events = [];
  for (const fresh of res?.rows ?? []) {
    const old = known.get(fresh.id);
    // The engine may already know an addition that an interrupted UI pass never applied.
    if (!old) events.push({ kind: 'add', row: fresh });
    else if (moved.has(fresh.id) || differs(old, fresh)) events.push({ kind: 'update', row: fresh });
  }
  for (const id of moved) if (known.has(id)) events.push({ kind: 'mark', id, label: 'hors du périmètre relu' });
  for (const id of res?.missing ?? []) if (known.has(id) && !moved.has(id)) events.push({ kind: 'mark', id, label: 'à revérifier' });
  return events;
}

/**
 * Applies at most EVENTS_PER_TICK per tick, yielding as soon as the actual application work reaches TICK_BUDGET_MS.
 * One event is atomic: its handler cannot be preempted, but no further event starts after the budget is spent.
 * `stop()` is checked before every event so a replaced list never receives the rest of an old answer.
 */
export async function applyPaced(events, apply, { next = () => new Promise((done) => setTimeout(done, 0)), now = () => performance.now(), stop = () => false, perTick = EVENTS_PER_TICK, budgetMs = TICK_BUDGET_MS } = {}) {
  if (!Number.isInteger(perTick) || perTick < 1 || !Number.isFinite(budgetMs) || budgetMs <= 0) throw new RangeError('Budget de revérification invalide.');
  let done = 0;
  while (done < events.length) {
    const start = now();
    let count = 0;
    while (done < events.length && count < perTick) {
      if (stop()) return done;
      apply(events[done]);
      done++;
      count++;
      if (now() - start >= budgetMs) break;
    }
    if (done < events.length) await next();
  }
  return done;
}

/**
 * Builds an immutable replacement using one identity index, never mutating a history snapshot.
 * Preparation is paced (512 cheap index/row operations or 5 ms per turn); an abandoned answer publishes nothing.
 * Filtering, sorting and the visible DOM are published once by the result panel after this returns.
 */
export async function prepareReconciliation(before, events, options = {}) {
  const stop = options.stop ?? (() => false);
  const pacing = { ...options, stop, perTick: options.perTick ?? 512 };
  const rows = [], index = new Map(), changed = new Set();
  await applyPaced(before, (row) => { index.set(row.id, rows.length); rows.push(row); }, pacing);
  if (stop()) return null;
  await applyPaced(events, (event) => {
    const id = event.row?.id ?? event.id;
    const at = index.get(id);
    if (event.kind === 'add' && at === undefined) {
      index.set(id, rows.length);
      rows.push({ ...event.row, _new: true });
    } else if (event.kind === 'update' && at !== undefined) {
      rows[at] = { ...event.row, _new: rows[at]._new };
    } else if (event.kind === 'mark' && at !== undefined) {
      const old = rows[at];
      rows[at] = { ...old, state: { ...old.state, label: `${old.state.label.split(' · ')[0]} · ${event.label}`, tone: 'warn' } };
    } else return;
    changed.add(id);
  }, pacing);
  return stop() ? null : { rows, changed };
}
