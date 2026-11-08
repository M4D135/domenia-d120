import { quietCall } from './store.js';
import { notify } from './notify.js';
import { icon } from '../icons.js';
import { pulse } from './pulse.js';

// Memory-only host status, no log contents or remote contact. A healthy writer stays unobtrusive.
export function installJournalHealth(topbar, navigate, {
  call = quietCall, clock = pulse, visible = () => document.visibilityState === 'visible', report = notify,
} = {}) {
  const button = document.createElement('button');
  button.type = 'button'; button.className = 'btn ghost icon'; button.hidden = true;
  button.addEventListener('click', () => navigate('parametres', { section: 'journaux' }));
  topbar.append(button);
  let last = ''; let busy = false; let stopped = false;
  async function read() {
    if (busy || stopped || !visible()) return;
    busy = true;
    try {
      const status = await call('shell.journal.status');
      if (!status || stopped) return;
      const impaired = status.state === 'unavailable' || status.state === 'fallback' || status.dropped > 0;
      const label = status.state === 'unavailable' ? 'Journal indisponible' : status.state === 'fallback' ? 'Journal de secours' : 'Lignes de journal perdues';
      button.hidden = !impaired;
      if (impaired) {
        button.innerHTML = icon('alert');
        button.title = `${status.problem ?? ''} ${status.path ? `Journal : ${status.path}.` : ''} ${status.pending} ligne(s) en attente, ${status.dropped} perdue(s). Ouvrir les journaux.`;
        button.setAttribute('aria-label', `${label} : ouvrir les journaux`);
      }
      const key = `${status.state}|${status.dropped}`;
      if (impaired && key !== last) report(`${label}. ${status.problem ?? ''} ${status.dropped ? `${status.dropped} ligne(s) perdue(s).` : ''}`.trim(), { tone: 'warn', key: 'technical-journal-health' });
      last = key;
    } finally { busy = false; }
  }
  const stop = clock.every('shell.journal-health', 10_000, read, { firstDelay: 1200 });
  const destroy = () => { stopped = true; stop(); button.remove(); window.removeEventListener('pagehide', destroy); };
  window.addEventListener('pagehide', destroy, { once: true });
  return destroy;
}
