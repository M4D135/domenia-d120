import { call, onEvent } from '../bridge.js';
import { pulse } from './pulse.js';

export function installWindowActivity() {
  const native = !!window.chrome?.webview;
  let host = { visible: true, active: !native && document.hasFocus(), writing: false };
  const apply = () => pulse.setState({ ...host, visible: host.visible && !document.hidden });
  const adopt = (value) => {
    if (!value || typeof value.visible !== 'boolean' || typeof value.active !== 'boolean' || typeof value.writing !== 'boolean') return;
    host = value; apply();
  };
  const off = onEvent('shell.window.activity', adopt);
  const focus = () => { if (!native) { host.active = document.hasFocus(); apply(); } };
  document.addEventListener('visibilitychange', apply);
  window.addEventListener('focus', focus); window.addEventListener('blur', focus);
  apply();
  if (native) call('shell.window.activity').then(adopt).catch(() => console.warn('État de fenêtre inconnu : lectures périodiques de fond suspendues.'));
  window.addEventListener('pagehide', () => {
    off(); pulse.dispose(); document.removeEventListener('visibilitychange', apply);
    window.removeEventListener('focus', focus); window.removeEventListener('blur', focus);
  }, { once: true });
}
