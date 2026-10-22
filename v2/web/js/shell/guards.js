// Safeguards of the interface: requests waiting for an answer block only the writes of their scope (TRV-059; Domenia 1
// Test-DomeniaInlineRequestBlocks), and the global handler of interface faults (TRV-064; Domenia 1
// Register-DomeniaDispatcherExceptionHandler): every fault is counted, reported to the technical journal (kind, screen and
// count only, never a message), and the operator is told once a minute at most per screen.
import { state, quietCall } from './store.js';
import { notify } from './notify.js';
import { confirmDialog, confirmWrite } from '../kit/index.js';

// ---------- Requests waiting for an answer ----------

const requests = new Set();
let seq = 0;

/**
 * Registers a request waiting for the operator (a confirmation, a choice). While it waits, navigation, reads, selection and
 * other targets stay available; only the writes and edits of its scope wait. A request without a scope holds every write
 * (fail closed). Returns `end()` to call once it is answered or withdrawn.
 * @param {{ scope?: string, label?: string }} [o]
 */
export function beginRequest({ scope = '', label = '' } = {}) {
  const r = { id: ++seq, scope: String(scope ?? ''), label: String(label ?? ''), at: Date.now() };
  requests.add(r);
  return { id: r.id, end: () => requests.delete(r) };
}

/** True when a waiting request holds this action (« write » or « edit ») on this scope. */
export function requestBlocks(action, scope = '') {
  if (action !== 'write' && action !== 'edit') return false;
  for (const r of requests) {
    if (!r.scope) return true;
    if (r.scope.toLowerCase() === String(scope ?? '').toLowerCase()) return true;
  }
  return false;
}

export function pendingRequests() { return [...requests]; }

function sessionMark() {
  const s = state.session;
  return `${s?.account?.login ?? ''}|${s?.domain?.dnsName ?? ''}|${s?.domain?.rootDn ?? ''}`;
}

/**
 * Request with one continuation, shown in the page (TRV-058; Domenia 1 Show-DomeniaInlineRequest): title, message
 * (2 000 characters at most), changes before and after, folded technical details, exact typed name when the plan asks for
 * it, optional third answer, danger or normal style. The safe answer has the focus and Échap cancels (kit dialog). While
 * it waits, only the writes of its scope are held (TRV-059). A newer request withdraws the previous one (the kit keeps a
 * single dialog); a request answered after the session changed expires without running anything. The continuation runs
 * once at most.
 * @param {{ scope?: string, title: string, message: string, danger?: boolean, confirmLabel?: string, cancelLabel?: string,
 *   write?: { target: string, targetKind?: string, targetDetail?: string, typed?: boolean, badge?: string },
 *   changes?: Array<{label: string, before?: string, after?: string}>, details?: string, alternate?: { label: string },
 *   onConfirm?: () => unknown, onAlternate?: () => unknown }} o
 * @returns {Promise<'confirm'|'alternate'|null>}
 */
export async function ask(o) {
  const message = String(o.message ?? '').slice(0, 2000);
  const r = beginRequest({ scope: o.scope, label: o.title });
  const mark = sessionMark();
  let answer = null;
  try {
    if (o.write || o.changes?.length || o.details || o.alternate) {
      answer = await confirmWrite({
        title: o.title, message, target: o.write?.target ?? '', targetKind: o.write?.targetKind, targetDetail: o.write?.targetDetail,
        typed: o.write ? o.write.typed !== false : false, badge: o.write?.badge, changes: o.changes, details: o.details,
        confirmLabel: o.confirmLabel, alternate: o.alternate,
      });
    } else {
      answer = (await confirmDialog({ title: o.title, message, danger: !!o.danger, confirmLabel: o.confirmLabel, cancelLabel: o.cancelLabel })) ? 'confirm' : null;
    }
  } finally {
    r.end();
  }
  if (answer && sessionMark() !== mark) {
    notify('Demande expirée : la session a changé pendant l’attente ; rien n’a été exécuté.', { tone: 'warn' });
    return null;
  }
  if (answer === 'confirm') await o.onConfirm?.();
  if (answer === 'alternate') await o.onAlternate?.();
  return answer;
}

// ---------- Faults of the interface ----------

const NOTICE_INTERVAL_MS = 60_000;
const REPORT_DELAY_MS = 1500;
const lastNotice = new Map();
const pending = new Map(); // `${kind}|${route}` → count
let reportTimer = 0;
let total = 0;
let inHandler = false;

export function faultCount() { return total; }

function routeName() {
  const id = state.page?.id;
  return id && /^[a-z][a-z0-9-]{0,29}$/.test(id) ? id : 'demarrage';
}

function record(kind) {
  if (inHandler) return;
  inHandler = true;
  try {
    total += 1;
    const route = routeName();
    const key = `${kind}|${route}`;
    pending.set(key, (pending.get(key) ?? 0) + 1);
    clearTimeout(reportTimer);
    reportTimer = setTimeout(flush, REPORT_DELAY_MS);
    const now = Date.now();
    if (now - (lastNotice.get(route) ?? 0) >= NOTICE_INTERVAL_MS) {
      lastNotice.set(route, now);
      notify('Erreur interne de l’interface sur cet écran : l’action en cours n’a peut-être pas abouti. Le détail technique est dans le journal ; rechargez l’écran (F5) si l’affichage paraît incomplet.', { tone: 'warn', key: `fault|${route}` });
    }
  } catch (err) {
    console.error(err);
  } finally {
    inHandler = false;
  }
}

function flush() {
  for (const [key, count] of pending) {
    const [kind, route] = key.split('|');
    quietCall('shell.fault', { kind, route, count: Math.min(count, 10_000) }).catch((err) => console.warn('Erreur non signalée au journal', err));
  }
  pending.clear();
}

/** Installs the global handlers (after the shell is built; boot.js covers the start). */
export function installFaultHandlers() {
  window.addEventListener('error', (e) => {
    // Resource loading errors (capture phase of boot.js) and errors without a script are not faults of the interface.
    if (!(e instanceof ErrorEvent) || !e.error) return;
    record('error');
  });
  window.addEventListener('unhandledrejection', (e) => {
    const reason = e.reason;
    // A refusal of the bridge is a French message already shown by its screen: not a fault of the interface.
    if (reason && typeof reason === 'object' && reason.code) return;
    record('rejection');
  });
}
