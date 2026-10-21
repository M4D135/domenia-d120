// Bridge client: request/response over the WebView2 message channel, with events per request.
const pending = new Map();
const listeners = new Map();
let counter = 0;

// Same limit as BridgeDispatcher.MaxMessageLength: a larger message would be refused without its id.
const MAX_MESSAGE_LENGTH = 1_048_576;

function channel() {
  return window.chrome && window.chrome.webview ? window.chrome.webview : null;
}

function bridgeError(code, message) {
  return Object.assign(new Error(message), { code });
}

export function onEvent(name, handler) {
  if (!listeners.has(name)) listeners.set(name, new Set());
  listeners.get(name).add(handler);
  return () => listeners.get(name).delete(handler);
}

export function call(op, args = {}) {
  const webview = channel();
  // Browser preview: no WebView2 host, the built-in mock answers with the same shapes.
  if (!webview) return import('./mock.js').then((m) => m.mockCall(op, args));
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
    pending.set(id, { resolve, reject });
    try {
      webview.postMessage(message);
    } catch (err) {
      pending.delete(id);
      console.error(err);
      reject(bridgeError('message.json', 'Message de l’interface illisible.'));
    }
  });
}

const webview = channel();
if (webview) {
  webview.addEventListener('message', (e) => {
    const m = e.data;
    if (!m || typeof m !== 'object') return;
    if (m.kind === 'event') {
      (listeners.get(m.op) || []).forEach((h) => h(m.data, m.id));
      return;
    }
    const failure = () => bridgeError(m.error && m.error.code, m.error ? m.error.message : 'Erreur du pont sans message.');
    const p = m.id == null ? null : pending.get(m.id);
    if (!p) {
      if (m.kind !== 'error') return;
      console.error('Erreur du pont sans requête correspondante', m);
      // Without an id the failed request cannot be identified: settle every waiting request rather than leave
      // one hanging forever (busy line and skeletons would never stop). Callers show the error and can retry.
      if (m.id == null) {
        const waiting = [...pending.values()];
        pending.clear();
        waiting.forEach((w) => w.reject(failure()));
      }
      return;
    }
    pending.delete(m.id);
    if (m.kind === 'result') p.resolve(m.data);
    else p.reject(failure());
  });
}
