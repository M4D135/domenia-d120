// Bridge client: bounded request/response state over WebView2, with events per request.
const MAX_MESSAGE_LENGTH = 1_048_576;
const MAX_PENDING = 128;
const RESERVED_CONTROLS = 4;
const OPERATION = /^[a-z][A-Za-z0-9]*(?:\.[a-z][A-Za-z0-9]*)+$/;

function bridgeError(code, message, decision = null, requirement = null) {
  return Object.assign(new Error(message), { code, decision, requirement });
}

/** A separate instance owns one channel. Tests use a local transport; production uses only the WebView2 channel. */
export function createBridgeClient(webview, { reportPublication = true } = {}) {
const pending = new Map();
const listeners = new Map();
let counter = 0;
const emit = (name, data, id) => (listeners.get(name) || []).forEach((h) => { try { h(data, id); } catch (error) { console.error(error); } });
const queueChanged = (operation = null) => emit('bridge.queue.changed', { operation });
const taskEnded = (p, id) => { if (p.tracking) emit('bridge.task.ended', { operation: p.op }, id); };

function onEvent(name, handler) {
  if (!listeners.has(name)) listeners.set(name, new Set());
  listeners.get(name).add(handler);
  return () => listeners.get(name).delete(handler);
}

function call(op, args = {}) {
  if (typeof op !== 'string' || op.length > 64 || !OPERATION.test(op)) {
    return Promise.reject(bridgeError('operation.unknown', 'Opération inconnue : rien n’a été envoyé.'));
  }
  const control = op.endsWith('.cancel') || op.endsWith('.stop') || op === 'operations.queue.read';
  if (pending.size >= MAX_PENDING + (control ? RESERVED_CONTROLS : 0)) {
    return Promise.reject(bridgeError('operation.busy', 'Trop de demandes encore sans réponse ; aucun nouvel envoi.'));
  }
  const id = `r${Date.now().toString(36)}${(++counter).toString(36)}`;
  const message = { id, op, args };
  // Refuse locally what the host would refuse without an id (it could not be matched to this request).
  let size;
  try {
    size = JSON.stringify(message).length;
  } catch {
    return Promise.reject(bridgeError('message.json', 'Message de l’interface illisible.'));
  }
  if (size > MAX_MESSAGE_LENGTH) {
    return Promise.reject(bridgeError('message.size', 'Message de l’interface refusé : taille non admise.'));
  }
  return new Promise((resolve, reject) => {
    // Arguments and secrets never enter this registry. No request is retried here.
    pending.set(id, { resolve, reject, op, queued: false, admitted: false });
    try {
      webview.postMessage(message);
    } catch {
      pending.delete(id);
      reject(bridgeError('message.json', 'Message de l’interface illisible.'));
    }
  });
}

  webview.addEventListener('message', (e) => {
    const m = e.data;
    if (!m || typeof m !== 'object') return;
    const p = m.id == null ? null : pending.get(m.id);
    if (m.kind === 'event') {
      if (p && m.op === `${p.op}:queued` && !p.admitted) { p.queued = true; queueChanged(p.op); }
      if (p && m.op === `${p.op}:admitted`) { p.admitted = true; p.queued = false; queueChanged(p.op); }
      if (p && m.op === `${p.op}:tracking` && !p.tracking && typeof m.data?.taskId === 'string'
          && /^[a-f0-9]{32}$/.test(m.data.taskId) && typeof m.data?.label === 'string'
          && ['write', 'explicit', 'selection'].includes(m.data.priority)) {
        p.tracking = true;
        emit('bridge.task.started', { ...m.data, label: m.data.label.slice(0, 80), operation: p.op }, m.id);
      }
      emit(m.op, m.data, m.id);
      return;
    }
    if (m.kind !== 'result' && m.kind !== 'error') return;
    const failure = () => bridgeError(m.error && m.error.code, m.error ? m.error.message : 'Erreur du pont sans message.', m.error?.decision ?? null, m.error?.requirement ?? null);
    if (!p) {
      if (m.kind !== 'error') return;
      // Without an id the failed request cannot be identified: settle every waiting request rather than leave
      // one hanging forever (busy line and skeletons would never stop). Callers show the error and can retry.
      if (m.id == null) {
        const waiting = [...pending.entries()];
        pending.clear();
        waiting.forEach(([id, w]) => { taskEnded(w, id); w.reject(failure()); });
        if (waiting.some(([, w]) => w.queued)) queueChanged();
      }
      return;
    }
    pending.delete(m.id);
    taskEnded(p, m.id);
    if (p.queued) queueChanged(p.op);
    const received = performance.now();
    if (m.kind === 'result') p.resolve(m.data);
    else p.reject(failure());
    // Await continuations run before the next frame. This is an observed publication interval, not CPU rendering cost.
    // Hidden tabs cannot provide a prompt frame; their publication remains unmeasured rather than inventing zero.
    if (reportPublication && !p.op.startsWith('operations.') && document.visibilityState === 'visible') {
      requestAnimationFrame(() => {
        if (document.visibilityState !== 'visible') return;
        const ms = Math.max(0, performance.now() - received);
        if (ms <= 60000) call('operations.publication.report', { id: m.id, ms }).catch(() => {});
      });
    }
  });
  return { call, onEvent };
}

const webview = window.chrome?.webview;
const client = webview ? createBridgeClient(webview) : null;
export function onEvent(name, handler) { return client ? client.onEvent(name, handler) : () => {}; }
export function call(op, args = {}) {
  return client ? client.call(op, args) : import('./mock.js').then((m) => m.mockCall(op, args));
}
