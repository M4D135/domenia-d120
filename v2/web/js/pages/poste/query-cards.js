import { esc, cardHead, errorText } from './common.js';

const LABELS = { match: 'Correspond', noMatch: 'Ne correspond pas', unknown: 'Inconnu · données manquantes', outside: 'Hors population de la requête' };

/** Only explicitly persisted active Query cards are evaluated, one workstation and one pinned revision at a time. */
export function createQueryCards(host, state) {
  let alive = true; let busy = 0; let queue = []; let entries = new Map();
  const slots = (id) => [...host.querySelectorAll('[data-query-card]')].filter((n) => n.dataset.queryCard === id);
  const card = (id, title, visual = 'Verdict') => {
    const entry = entries.get(id); const r = entry?.result;
    const body = r ? `${visual === 'Text' ? `<dl><dt>Résultat</dt><dd>${esc(LABELS[r.verdict] ?? LABELS.unknown)}</dd><dt>Explication</dt><dd>${esc(r.explanation)}</dd></dl>` : `<p class="ps-verdict-line"><b>${esc(LABELS[r.verdict] ?? LABELS.unknown)}</b></p><p>${esc(r.explanation)}</p>`}
      <p class="ps-faint">${esc(r.provenance)}</p><button class="btn sm" type="button" data-query-open="${esc(r.recipeId)}">Ouvrir la recette dans l’atelier</button>`
      : entry?.error ? `<p role="alert">${esc(entry.error)}</p>` : '<p role="status">Calcul local de la révision liée…</p>';
    return `<section class="card ps-card" data-query-card="${esc(id)}" data-query-title="${esc(title)}" data-query-visual="${esc(visual)}">${cardHead('filter', title, 'Requête enregistrée · ce poste seulement')}${body}
      ${r || entry?.error ? `<button class="btn sm" type="button" data-query-retry="${esc(id)}">Recalculer localement</button>` : ''}</section>`;
  };
  function paint(id) { if (alive) for (const slot of slots(id)) slot.outerHTML = card(id, slot.dataset.queryTitle, slot.dataset.queryVisual); }
  function drain() {
    while (alive && busy < 2 && queue.length) {
      const [id, entry] = queue.shift();
      if (entries.get(id) !== entry) continue;
      if (!slots(id).length) { entries.delete(id); continue; }
      busy++;
      Promise.resolve().then(() => {
        if (!alive || entries.get(id) !== entry || !slots(id).length) return null;
        return state.call('poste.layout.query', { dn: state.dn, computer: state.data.computer.guid, item: id });
      }).then((result) => { if (entries.get(id) === entry) entry.result = result; },
        (err) => { if (entries.get(id) === entry) entry.error = errorText(err); })
        .finally(() => { busy--; if (entries.get(id) === entry) paint(id); drain(); });
    }
  }
  const refresh = () => {
    if (!alive) return;
    const active = new Set([...host.querySelectorAll('[data-query-card]')].map((n) => n.dataset.queryCard));
    for (const id of entries.keys()) if (!active.has(id)) entries.delete(id);
    for (const id of active) if (!entries.has(id)) { const e = {}; entries.set(id, e); queue.push([id, e]); }
    drain();
  };
  const click = (event) => {
    const b = event.target instanceof Element ? event.target.closest('[data-query-retry],[data-query-open]') : null;
    if (!b || !host.contains(b) || b.disabled) return;
    if (b.dataset.queryOpen) state.ctx.navigate('requetes', { recette: b.dataset.queryOpen, onglet: 'enregistrer' });
    else { const id = b.dataset.queryRetry; const e = {}; entries.set(id, e); queue.push([id, e]); paint(id); drain(); }
  };
  host.addEventListener('click', click);
  return { render: (item, title) => card(item.id, title, item.visual), refresh,
    invalidate() { entries = new Map(); queue = []; },
    destroy() { alive = false; entries.clear(); queue = []; host.removeEventListener('click', click); } };
}
