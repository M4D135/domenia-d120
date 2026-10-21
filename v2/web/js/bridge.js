// Bridge client: request/response over the WebView2 message channel, with events per request.
const pending = new Map();
const listeners = new Map();
let counter = 0;

function channel() {
  return window.chrome && window.chrome.webview ? window.chrome.webview : null;
}

export function onEvent(name, handler) {
  if (!listeners.has(name)) listeners.set(name, new Set());
  listeners.get(name).add(handler);
  return () => listeners.get(name).delete(handler);
}

export function call(op, args = {}) {
  const webview = channel();
  if (!webview) return Promise.reject(new Error('Pont indisponible : ouvrez Domenia depuis son application.'));
  const id = `r${Date.now().toString(36)}${(++counter).toString(36)}`;
  return new Promise((resolve, reject) => {
    pending.set(id, { resolve, reject });
    webview.postMessage({ id, op, args });
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
    const p = pending.get(m.id);
    if (!p) return;
    pending.delete(m.id);
    if (m.kind === 'result') p.resolve(m.data);
    else p.reject(Object.assign(new Error(m.error ? m.error.message : 'Erreur'), { code: m.error && m.error.code }));
  });
}
