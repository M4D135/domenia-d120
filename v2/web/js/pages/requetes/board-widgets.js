// Widgets of saved queries on a board (REQ-039, PST-113; Domenia 1 widgets of the general board and of the workstation board):
//   import { mountQueryWidgets } from './requetes/board-widgets.js';
//   const widgets = mountQueryWidgets(host, ctx, { board: 'fleet' });                  // Accueil
//   const widgets = mountQueryWidgets(host, ctx, { board: 'computer', computer: guid }); // Poste (verdict of this workstation)
//   widgets.refresh(); widgets.destroy();
// Each widget is evaluated locally on the revision it is bound to (requetes.widget.evaluate): no network read. A newer revision
// of its query is never applied silently: the card says « confirmez la mise à jour » and opens the workshop. The block stays
// empty and hidden when no widget belongs to the board (or when the operations are not served, in the preview).
import { call } from '../../bridge.js';
import { glyph } from '../../kit/glyphs.js';
import { esc, NBSP } from '../../kit/util.js';
import { applyVars } from '../../ui.js';

const STYLE_HREF = 'css/pages/requetes-widgets.css';
const VERDICTS = {
  match: { tone: 'ok', label: 'Correspond' },
  noMatch: { tone: 'off', label: 'Ne correspond pas' },
  unknown: { tone: 'warn', label: 'Inconnu (valeur absente)' },
  outside: { tone: 'off', label: 'Hors population de la requête' },
};

function ensureStyles() {
  if (document.querySelector('link[data-query-widgets]')) return;
  const link = document.createElement('link');
  link.rel = 'stylesheet';
  link.href = STYLE_HREF;
  link.dataset.queryWidgets = '';
  document.head.appendChild(link);
}

const pct = (share) => `${Math.round(Math.max(0, Math.min(1, Number(share) || 0)) * 100)}${NBSP}%`;

function chart(e) {
  const items = e.groups?.items ?? [];
  if (!items.length || e.visual === 'kpi' || e.visual === 'text') return '';
  const max = Math.max(1, ...items.map((i) => i.count));
  return `<ol class="qw-bars" aria-label="${esc(`Répartition par ${e.groups.fieldName ?? e.groups.field}`)}">${items.map((i, n) => `
    <li data-i="${n}"><span class="qw-bar-label" data-tip="${esc(i.label)}">${esc(i.label)}</span>
      <span class="qw-bar-track" aria-hidden="true"><span class="qw-bar-fill" data-p="${(i.count / max).toFixed(3)}"></span></span>
      <span class="qw-bar-value mono">${esc(String(i.count))} · ${esc(pct(i.share))}</span></li>`).join('')}</ol>`;
}

function card(w, e, board) {
  if (!e) {
    return `<article class="qw-card" data-tone="warn"><header><span class="qw-ico">${glyph('alert')}</span><h3>${esc(w.title)}</h3></header>
      <p class="qw-text">${esc(w.state)}</p></article>`;
  }
  const verdict = board === 'computer' && e.computer ? VERDICTS[e.computer.verdict] ?? VERDICTS.unknown : null;
  const big = e.visual === 'kpi' ? `<p class="qw-kpi"><b>${esc(String(e.counts.matched))}</b><span>sur ${esc(String(e.counts.population))}</span></p>` : '';
  return `<article class="qw-card" data-tone="${verdict ? verdict.tone : e.needsConfirmation ? 'warn' : 'info'}">
    <header><span class="qw-ico">${glyph(verdict ? 'monitor' : 'filter')}</span><h3>${esc(e.title)}</h3>
      <span class="qw-rev faint" data-tip="${esc(`Requête ${e.recipeName} · révision ${e.boundRevision}`)}">r${esc(String(e.boundRevision))}</span></header>
    ${verdict ? `<p class="qw-verdict" data-tone="${verdict.tone}"><b>${esc(verdict.label)}</b>${e.computer.explanation ? `<span>${esc(e.computer.explanation)}</span>` : ''}</p>` : ''}
    ${big}
    <p class="qw-text">${esc(e.text)}</p>
    ${chart(e)}
    <footer class="faint">${esc(e.scope)}${e.needsConfirmation ? `${NBSP}· <button class="btn xs subtle" type="button" data-qw-open="${esc(w.recipeId)}">${glyph('refresh')}Confirmer la mise à jour</button>` : ''}</footer>
  </article>`;
}

/**
 * Mounts the widgets of one board in host. o.board: 'fleet' (Accueil) or 'computer' (Poste, with o.computer = GUID).
 * @returns {{ refresh: () => Promise<void>, destroy: () => void }}
 */
export function mountQueryWidgets(host, ctx, o = {}) {
  ensureStyles();
  const board = o.board === 'computer' ? 'computer' : 'fleet';
  let alive = true;
  const root = document.createElement('section');
  root.className = 'qw-board';
  root.dataset.page = 'requetes-widgets';
  root.hidden = true;
  root.setAttribute('aria-label', board === 'computer' ? 'Widgets de requêtes du poste' : 'Widgets de requêtes');
  host.appendChild(root);

  root.addEventListener('click', (e) => {
    const b = e.target instanceof Element ? e.target.closest('[data-qw-open]') : null;
    if (b) ctx.navigate('requetes', { recette: b.dataset.qwOpen, onglet: 'enregistrer' });
  });

  async function refresh() {
    let list = [];
    try { list = await call('requetes.widget.list'); } catch { list = []; }
    if (!alive) return;
    const mine = (list ?? []).filter((w) => w.board === board && w.displayable);
    if (!mine.length || (board === 'computer' && !o.computer)) { root.hidden = true; root.innerHTML = ''; return; }
    const evaluated = await Promise.all(mine.map((w) => call('requetes.widget.evaluate', board === 'computer' ? { id: w.id, computer: o.computer } : { id: w.id }).catch(() => null)));
    if (!alive) return;
    root.innerHTML = `<header class="qw-head"><h2>${glyph('filter')}${board === 'computer' ? 'Requêtes enregistrées sur ce poste' : 'Widgets de requêtes'}</h2>
        <button class="btn xs ghost" type="button" data-qw-workshop>${glyph('external')}Atelier de requêtes</button></header>
      <div class="qw-grid">${mine.map((w, n) => card(w, evaluated[n], board)).join('')}</div>`;
    applyVars(root);
    root.querySelector('[data-qw-workshop]')?.addEventListener('click', () => ctx.navigate('requetes', { onglet: 'bibliotheque' }));
    root.hidden = false;
  }

  refresh();
  return {
    refresh,
    destroy() { alive = false; root.remove(); },
  };
}
