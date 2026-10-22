// History tab: dated facts of the object (creation, change, password, lockout, logon, expiry), replication metadata, the
// receipts of Domenia on this object (opened in place) and the group changes seen during the session.
import { timeline, bindTimeline, glyph, int } from '../../kit/index.js';
import { esc, applyVars } from '../../ui.js';
import { openReceipt } from '../../write-flow.js';
import { failure, skeleton } from './common.js';

const KINDS = [
  { id: 'all', label: 'Tout', icon: 'history' },
  { id: 'directory', label: 'Annuaire', icon: 'database' },
  { id: 'metadata', label: 'Réplication', icon: 'sync' },
  { id: 'receipt', label: 'Reçus Domenia', icon: 'shield' },
  { id: 'session', label: 'Session', icon: 'clock' },
];

/**
 * @param {HTMLElement} panel
 * @param {any} S
 */
export function mountHistory(panel, S) {
  let data = null;
  let kind = 'all';
  let token = 0;
  let unbind = () => {};

  function render() {
    if (!data) return;
    const counts = Object.fromEntries(KINDS.map((k) => [k.id, k.id === 'all' ? data.events.length : data.events.filter((e) => e.kind === k.id).length]));
    const events = data.events.filter((e) => kind === 'all' || e.kind === kind).map((e) => ({
      when: e.when, title: e.title, text: e.text ?? undefined, tone: e.tone, icon: e.icon, actor: e.actor ?? undefined, meta: e.meta ?? undefined,
      html: e.receiptId ? `<button class="btn xs" type="button" data-receipt="${esc(e.receiptId)}">${glyph('shield')}Voir le reçu</button>` : undefined,
    }));
    unbind();
    panel.innerHTML = `<div class="fi-history">
      <div class="fi-history-bar">
        <div class="fi-history-kinds" role="group" aria-label="Filtrer l’historique">${KINDS.map((k) => `<button type="button" class="fi-type-chip${kind === k.id ? ' on' : ''}" data-kind="${k.id}" aria-pressed="${kind === k.id}"${counts[k.id] ? '' : ' disabled'}>
          ${glyph(k.icon)}<b>${int(counts[k.id])}</b><span>${esc(k.label)}</span></button>`).join('')}</div>
        ${data.pending ? `<span class="fi-count-chip warn">${glyph('eye')}<b>${int(data.pending)}</b> reçu${data.pending > 1 ? 's' : ''} à vérifier</span>` : ''}
      </div>
      <section class="card fi-card fi-history-card fi-enter">${timeline(events, { label: `Historique de ${S.sheet.identity.name}`, empty: 'Aucun événement dans cette catégorie.' })}</section>
      <p class="fi-note">${glyph('info')}${esc(data.note)}</p></div>`;
    unbind = bindTimeline(panel) ?? (() => {});
    applyVars(panel);
  }

  async function load() {
    const my = ++token;
    panel.innerHTML = `<section class="card fi-card">${skeleton(7)}</section>`;
    try {
      data = await S.ctx.call('fiche.history', { dn: S.sheet.identity.dn });
      if (my !== token || !S.alive) return;
      render();
    } catch (err) {
      if (my !== token) return;
      panel.innerHTML = `<section class="card fi-card">${failure(err)}</section>`;
    }
  }

  // The page itself carries data-kind (« user », « computer »…): only the filter chips of this tab are filters. The receipt and
  // « Réessayer » come first, so a click anywhere else in the tab never repaints an empty filter.
  const onClick = (e) => {
    const t = e.target instanceof Element ? e.target : null;
    const r = t?.closest('[data-receipt]');
    if (r) { openReceipt(S.ctx, r.dataset.receipt, { onChange: () => load() }); return; }
    if (t?.closest('[data-retry]')) { load(); return; }
    const k = t?.closest('.fi-history-kinds [data-kind]');
    if (k && !k.disabled) { kind = k.dataset.kind; render(); }
  };
  panel.addEventListener('click', onClick);
  load();
  return { update() {}, refresh: load, destroy() { unbind(); panel.removeEventListener('click', onClick); } };
}
