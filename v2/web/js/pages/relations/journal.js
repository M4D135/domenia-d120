// Utilisateurs et postes · « Journal »: the local journal of the associations (Domenia 1 REL-010: additions, removals,
// restorations, updates), and every removal that can still be restored (improvement of REL-009: the whole list, not only
// the last one). Restoring is a plan of the write circuit, one association per click.
import { glyph } from '../../kit/glyphs.js';
import { timeline, bindTimeline } from '../../kit/timeline.js';
import { applyVars, reveal, formatDateTime } from '../../ui.js';
import { badge, esc, int, nouns, NBSP, errText, empty, sk } from './model.js';

const ICONS = { added: 'plus', removed: 'trash', restored: 'undo', refreshed: 'refresh', conflict: 'alert' };
const BADGE_OF_KIND = { assignment: 'declared', console: 'observed', remoteSession: 'observed', history: 'history', imported: 'imported', hint: 'hint', unknown: 'toCheck' };
const FILTERS = [
  { id: 'all', label: 'Tout' },
  { id: 'added', label: 'Ajouts' },
  { id: 'removed', label: 'Retraits' },
  { id: 'restored', label: 'Restaurations' },
];

/**
 * Creates the « Journal » tab in panel.
 * @param {HTMLElement} panel
 * @param {object} app  Controller of the screen (restore(entryId)).
 */
export function createJournalTab(panel, app) {
  let data = null;
  let filter = 'all';
  const stops = [];
  panel.innerHTML = `<div class="rel-jrn">
    <section class="card rel-jrn-main reveal" aria-label="Journal local">
      <div class="card-head"><span class="card-icon">${glyph('history')}</span><div class="head-titles"><h3>Journal local des associations</h3>
        <span class="head-sub rel-jrn-sub">${sk('w40')}</span></div>
        <div class="meta"><div class="rel-jrn-filters" role="group" aria-label="Filtrer le journal">${FILTERS.map((f) => `<button class="k-facet" type="button" data-filter="${f.id}" aria-pressed="${f.id === filter}"><span class="k-facet-check" aria-hidden="true">${glyph('check')}</span>${esc(f.label)}</button>`).join('')}</div></div></div>
      <div class="rel-jrn-list" aria-busy="true">${sk('w70')}${sk('w85')}${sk('w55')}${sk('w70')}</div>
    </section>
    <aside class="card rel-jrn-restore reveal" aria-label="Suppressions restaurables">
      <div class="card-head"><span class="card-icon">${glyph('undo')}</span><div class="head-titles"><h3>Restaurables</h3><span class="head-sub">Une association par clic, depuis le journal</span></div></div>
      <div class="rel-jrn-rest">${sk('w85')}${sk('w70')}</div>
    </aside>
  </div>`;
  stops.push(reveal(panel));
  panel.querySelector('.rel-jrn-filters').addEventListener('click', (e) => {
    const b = e.target instanceof Element ? e.target.closest('[data-filter]') : null;
    if (!b) return;
    filter = b.dataset.filter;
    panel.querySelectorAll('[data-filter]').forEach((x) => x.setAttribute('aria-pressed', String(x.dataset.filter === filter)));
    paint();
  });

  function paint() {
    if (!data) return;
    const listHost = panel.querySelector('.rel-jrn-list');
    listHost.removeAttribute('aria-busy');
    const entries = data.entries.filter((e) => filter === 'all' || e.action === filter);
    listHost.innerHTML = entries.length ? timeline(entries.map((e) => ({
      when: e.at,
      title: `${e.actionLabel} · ${e.userLogin} → ${e.computer}`,
      text: e.note ?? '',
      tone: e.tone,
      icon: ICONS[e.action] ?? 'dot',
      actor: e.declarant ?? undefined,
      meta: e.source,
      html: `<div class="rel-jrn-tags">${badge(BADGE_OF_KIND[e.kind] ?? 'toCheck', { size: 'sm', label: e.badgeLabel })}${e.restorable ? `<button class="btn xs" type="button" data-restore="${esc(e.id)}">${glyph('undo')}Restaurer</button>` : ''}${e.restoredBy ? `<span class="rel-tag ok">${glyph('check')}Restaurée</span>` : ''}</div>`,
    })), { label: 'Journal des associations' }) : empty('history', 'Rien à afficher', 'Aucune ligne du journal ne correspond à ce filtre.');
    bindTimeline(listHost);
    const rest = panel.querySelector('.rel-jrn-rest');
    rest.innerHTML = data.restorable.length
      ? `<ul class="rel-rest-list">${data.restorable.map((r, j) => `<li data-j="${j}"><span class="rel-rest-ico">${glyph('trash')}</span>
          <div><b>${esc(r.userLogin)} → ${esc(r.computer)}</b><time datetime="${esc(r.removedAt)}">${esc(`Retirée le ${formatDateTime(r.removedAt) ?? ''}`)}</time></div>
          <button class="btn sm" type="button" data-restore="${esc(r.entryId)}" data-tip="${esc(r.tip)}">${glyph('undo')}Restaurer</button></li>`).join('')}</ul>`
      : `<p class="rel-quiet">${glyph('check')}Aucune suppression locale à restaurer.</p>`;
    rest.insertAdjacentHTML('beforeend', `<p class="rel-jrn-note">${glyph('info')}${esc(data.note)}</p>`);
    applyVars(panel);
  }

  panel.addEventListener('click', (e) => {
    const b = e.target instanceof Element ? e.target.closest('[data-restore]') : null;
    if (b) app.restore(b.dataset.restore);
  });

  return {
    show(journal) {
      data = journal;
      panel.querySelector('.rel-jrn-sub').textContent = `${nouns(journal.total, 'ligne', 'lignes')} · ${nouns(journal.restorable.length, 'suppression restaurable', 'suppressions restaurables')}`;
      paint();
    },
    failed(err) {
      const listHost = panel.querySelector('.rel-jrn-list');
      listHost.removeAttribute('aria-busy');
      listHost.innerHTML = `<p class="rel-note warn" role="alert">${glyph('alert')}${esc(errText(err))}</p>`;
      panel.querySelector('.rel-jrn-rest').innerHTML = '';
      panel.querySelector('.rel-jrn-sub').textContent = `Journal non lu${NBSP}: réessayez.`;
      void int;
    },
    destroy() { stops.forEach((fn) => fn()); },
  };
}
