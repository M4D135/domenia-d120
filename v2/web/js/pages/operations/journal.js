// Tab « Journal » (Domenia 1 OPE-014): the operations journal of the session (what the engine did for the operator, in memory)
// and the journal kept by the source (the local base, or the fictitious journal of the simulation), newest first, grouped by
// day, filtered by tone and origin. A local read; nothing is replayed from a line.
import { errorText, toast } from '../../ui.js';
import { createFilterBar, timeline, bindTimeline, glyph, writeClipboard, NBSP } from '../../kit/index.js';
import { count, errorBox, emptyState, maskSecrets } from './common.js';

const TONE_ICONS = { ok: 'check', warn: 'alert', alert: 'alert', info: 'info', off: 'pause' };
const FACETS = [
  { id: 'session', label: 'Cette session', tone: 'info' },
  { id: 'source', label: 'Journal de la source', tone: 'off' },
  { id: 'alert', label: 'Alertes', tone: 'alert' },
  { id: 'warn', label: 'À surveiller', tone: 'warn' },
];

/**
 * @param {HTMLElement} host
 * @param {{ ctx: any, demo: boolean }} env
 */
export function createJournal(host, env) {
  const { ctx } = env;
  let alive = true;
  let view = null;
  let pressed = new Set();

  host.innerHTML = `<div class="op-journal">
    <div class="op-jr-bar"><div class="op-jr-filters"></div>
      <div class="op-jr-tools"><button class="btn sm subtle" type="button" data-jr="refresh">${glyph('refresh')}Actualiser</button>
        <button class="btn sm subtle" type="button" data-jr="copy">${glyph('copy')}Copier</button>
        <button class="btn sm subtle" type="button" data-jr="export">${glyph('csv')}Exporter en CSV</button></div></div>
    <section class="card op-jr-card"><div class="op-jr-body" aria-busy="true">${Array.from({ length: 6 }, () => '<span class="skeleton op-sk-line w85"></span>').join('')}</div></section>
    <p class="op-note op-jr-note"></p>
  </div>`;
  const body = host.querySelector('.op-jr-body');
  const note = host.querySelector('.op-jr-note');
  const filters = createFilterBar(host.querySelector('.op-jr-filters'), {
    label: 'Filtres du journal',
    facets: FACETS.map((f) => ({ ...f, count: 0 })),
    onToggle: (id, on) => { if (on) pressed.add(id); else pressed.delete(id); paint(); },
    onClear: () => { pressed = new Set(); paint(); },
  });

  host.querySelector('.op-jr-tools').addEventListener('click', (e) => {
    const b = e.target instanceof Element ? e.target.closest('[data-jr]') : null;
    if (!b) return;
    if (b.dataset.jr === 'refresh') load();
    else if (b.dataset.jr === 'copy') copy();
    else exportCsv();
  });

  function lines() {
    const all = view?.lines ?? [];
    return all.filter((l) => {
      const origin = l.origin === 'session' ? 'session' : 'source';
      const originOk = !pressed.has('session') && !pressed.has('source') ? true : pressed.has(origin);
      const toneOk = !pressed.has('alert') && !pressed.has('warn') ? true : pressed.has(l.tone);
      return originOk && toneOk;
    });
  }

  function paint() {
    if (!view) return;
    const all = view.lines;
    filters.setFacets(FACETS.map((f) => ({
      ...f,
      pressed: pressed.has(f.id),
      count: all.filter((l) => (f.id === 'session' ? l.origin === 'session' : f.id === 'source' ? l.origin !== 'session' : l.tone === f.id)).length,
    })));
    const shown = lines();
    filters.setSummary(`${count(shown.length, 'ligne', 'lignes')} sur ${all.length}`);
    if (!shown.length) {
      body.innerHTML = emptyState('history', all.length ? 'Aucune ligne pour ces filtres' : 'Journal vide', all.length ? 'Retirez un filtre pour revoir les lignes.' : 'Les opérations de la session s’inscriront ici.');
      return;
    }
    body.innerHTML = timeline(shown.map((l) => ({
      when: l.at,
      title: l.label,
      tone: l.tone,
      icon: TONE_ICONS[l.tone] ?? 'info',
      meta: l.origin === 'session' ? 'Cette session' : l.origin === 'simulation' ? 'Journal fictif (simulation)' : 'Base locale',
    })), { label: 'Journal des opérations' });
    bindTimeline(body);
  }

  function load() {
    body.setAttribute('aria-busy', 'true');
    return ctx.call('operations.journal').then((next) => {
      if (!alive) return;
      view = next;
      body.removeAttribute('aria-busy');
      note.textContent = next.note;
      paint();
    }).catch((err) => {
      console.error(err);
      if (!alive) return;
      body.removeAttribute('aria-busy');
      body.innerHTML = errorBox(errorText(err, 'Journal illisible.'), 'journal');
      body.querySelector('[data-retry]')?.addEventListener('click', load);
    });
  }

  function text() {
    return lines().map((l) => `${l.at}\t${l.tone}\t${l.origin}\t${l.label}`).join('\r\n');
  }

  function copy() {
    writeClipboard(maskSecrets(text())).then((ok) => toast(ok ? `Journal copié${NBSP}: ${count(lines().length, 'ligne', 'lignes')}.` : `Copie impossible${NBSP}: le presse-papiers est indisponible.`, { tone: ok ? 'ok' : 'warn' }));
  }

  function exportCsv() {
    const cell = (v) => {
      let t = String(v ?? '');
      if (/^[=+\-@]/.test(t)) t = `'${t}`;
      return /[;"\r\n]/.test(t) ? `"${t.replace(/"/g, '""')}"` : t;
    };
    const csv = ['Date;Ton;Origine;Libellé', ...lines().map((l) => [l.at, l.tone, l.origin, l.label].map(cell).join(';'))].join('\r\n') + '\r\n';
    if (env.demo) { writeClipboard(csv).then(() => toast(`Exemple local${NBSP}: CSV copié, rien n’est enregistré.`, { tone: 'info' })); return; }
    ctx.call('operations.export.save', { subject: 'journal', csv }).then((r) => toast(r.saved ? `Journal exporté${NBSP}: ${r.name}` : r.message, { tone: r.saved ? 'ok' : 'info', life: 6000 }))
      .catch((err) => toast(`Export impossible${NBSP}: ${errorText(err)}`, { tone: 'alert' }));
  }

  load();
  return {
    refresh: load,
    destroy() { alive = false; filters.destroy?.(); },
  };
}

