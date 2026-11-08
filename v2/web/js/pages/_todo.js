// Generic page for screens not ported yet: title, animated empty state, Domenia 1 functions to carry over.
import { icon } from '../icons.js';
import { esc, errorText, fold, applyVars, reveal, countUp, formatNumber, announce } from '../ui.js';

const MAX_STAGGER = 18;
// A group longer than this spans the width and spreads its list over columns; shorter ones flow side by side.
const WIDE_GROUP = 24;
const NBSP = '\u00A0';

function skeletonGroups() {
  const group = `<section class="card feature-group"><div class="sk-stack">
    <span class="skeleton sk sk-title w55"></span><span class="skeleton sk sk-line w85"></span>
    <span class="skeleton sk sk-line w70"></span><span class="skeleton sk sk-line w85"></span><span class="skeleton sk sk-line w40"></span>
  </div></section>`;
  return group.repeat(3);
}

function layout(page) {
  const section = page.section ? `${page.section} · ` : '';
  return `<div class="page todo-page">
    <header class="page-header reveal">
      <div class="head-row"><span class="page-icon">${icon(page.icon)}</span>
        <div class="titles"><h1 class="gradient-text">${esc(page.label)}</h1>
          <p class="subtitle">${esc(section)}Domenia 2</p></div></div>
      <div class="actions">
        <button class="btn" type="button" data-act="palette">${icon('command')}Palette de commandes</button>
        <button class="btn primary" type="button" data-act="home">${icon('home')}Retour à l’accueil</button>
      </div>
    </header>
    <section class="card todo-hero reveal spot">
      <div class="empty">
        <div class="art">${icon(page.icon)}</div>
        <h2>Écran en cours de portage</h2>
        <p>Cet écran reprendra toutes les fonctions de Domenia 1 listées ci-dessous, puis les améliorations prévues.
          Aucune fonction n’est retirée sans décision écrite.</p>
        <span class="chip info"><span class="dot pulse"></span><b class="num" data-count>…</b>&nbsp;fonctions à reprendre</span>
      </div>
    </section>
    <div class="todo-tools reveal">
      <h2>Fonctions de Domenia 1 à reprendre</h2>
      <input class="input" type="search" placeholder="Filtrer les fonctions…" aria-label="Filtrer les fonctions de Domenia 1" disabled>
    </div>
    <div class="feature-groups" aria-busy="true">${skeletonGroups()}</div>
  </div>`;
}

// m = 1: states and instructions of the screen (status sentences of Domenia 1), kept apart, not counted as functions.
function groupMarkup(group) {
  const title = group.s || 'Écran principal';
  const msg = group.m === 1;
  const rows = group.f.map(([t, d], n) => `<li data-j="${Math.min(n, MAX_STAGGER)}"><span class="mk${msg ? ' msg' : ''}" aria-hidden="true"></span>`
    + `<span><span class="t">${esc(t)}</span>${d ? `<span class="d">${esc(msg ? `Affiché dans${NBSP}: ${d}` : d)}</span>` : ''}</span></li>`).join('');
  const wide = !msg && group.f.length > WIDE_GROUP;
  return `<section class="card feature-group${msg ? ' messages' : ''}${wide ? ' wide' : ''} reveal spot">
    <div class="card-head"><span class="card-icon">${icon(msg ? 'info' : 'folder')}</span><h3>${esc(title)}</h3>
      <span class="meta"><span class="chip" data-n>${formatNumber(group.f.length)}</span></span></div>
    <ul class="feature-list cascade">${rows}</ul>
  </section>`;
}

const plural = (n, one, many) => `${formatNumber(n)} ${n > 1 ? many : one}`;

// The list is not a live region (it would be read in full, then again on each keystroke): only a short count is
// announced, once typing pauses. Returns a stop function for the pending announcement.
function bindFilter(input, holder) {
  const index = [...holder.querySelectorAll('.feature-list li')].map((li) => [li, fold(li.textContent)]);
  let timer = 0;
  input.disabled = false;
  input.addEventListener('input', () => {
    const q = fold(input.value.trim());
    let total = 0;
    index.forEach(([li, text]) => { li.hidden = q !== '' && !text.includes(q); });
    holder.querySelectorAll('.feature-group').forEach((g) => {
      const shown = g.querySelectorAll('li:not([hidden])').length;
      // States and instructions are filtered too, but only functions are counted.
      if (!g.classList.contains('messages')) total += shown;
      g.hidden = shown === 0;
      g.querySelector('[data-n]').textContent = formatNumber(shown);
    });
    clearTimeout(timer);
    timer = setTimeout(() => {
      announce(q ? (total ? `${plural(total, 'fonction correspond', 'fonctions correspondent')} au filtre.` : 'Aucune fonction ne correspond au filtre.')
        : `${plural(total, 'fonction affichée', 'fonctions affichées')}.`);
    }, 450);
  });
  return () => clearTimeout(timer);
}

export function render(main, ctx) {
  const { page } = ctx;
  main.innerHTML = layout(page);
  applyVars(main);
  const stops = [reveal(main)];
  let alive = true;

  main.querySelector('[data-act="home"]').addEventListener('click', () => ctx.go('accueil'));
  main.querySelector('[data-act="palette"]').addEventListener('click', () => ctx.openPalette());

  const holder = main.querySelector('.feature-groups');
  const counter = main.querySelector('[data-count]');
  import('../parite.js').then(({ PARITE }) => {
    if (!alive) return;
    const groups = PARITE[page.id] ?? [];
    const total = groups.filter((g) => g.m !== 1).reduce((s, g) => s + g.f.length, 0);
    if (!groups.length) {
      holder.innerHTML = `<section class="card reveal"><p class="muted">L’inventaire de Domenia 1 ne liste pas de contrôle propre
        à cet écran : ses fonctions viennent des autres vues.</p></section>`;
    } else {
      holder.innerHTML = groups.map(groupMarkup).join('');
      stops.push(bindFilter(main.querySelector('.todo-tools input'), holder));
      announce(`${plural(total, 'fonction de Domenia 1 à reprendre', 'fonctions de Domenia 1 à reprendre')}.`);
    }
    holder.removeAttribute('aria-busy');
    applyVars(holder);
    stops.push(reveal(holder));
    countUp(counter, total, { delay: 200 });
  }).catch((err) => {
    console.error(err);
    if (!alive) return;
    holder.innerHTML = `<section class="card error-card" role="alert"><p class="muted">Liste des fonctions indisponible : ${esc(errorText(err))}</p></section>`;
    holder.removeAttribute('aria-busy');
    counter.textContent = '—';
  });

  return () => { alive = false; stops.forEach((stop) => stop()); };
}
