// Empty fiche (FIC-032): without a subject the screen stays open with a search field, local suggestions, the last fiches of
// the local memory and quick accesses (the session account, the working OU). Nothing is read on the network before Entrée:
// an exact match of the local base opens its fiche, otherwise the global search opens.
import { glyph, debounce, pill } from '../../kit/index.js';
import { esc, errorText, toast, applyVars, reveal } from '../../ui.js';
import { avatar, kindOf, stamp } from './common.js';

/**
 * @param {HTMLElement} main
 * @param {any} ctx
 */
// What the search field accepts, with examples of the fictitious directory (a click only fills the field).
const GUIDE = [
  { icon: 'user', title: 'Identifiant ou nom', text: 'Compte, poste, groupe ou contact de la base locale.', examples: ['c.bernard', 'PC-LYO-0002', 'GG-Support-N2'] },
  { icon: 'key', title: 'DOMAINE\\compte ou UPN', text: 'Le domaine doit être celui de la session.', examples: ['EXAMPLE\\j.martin', 'j.martin@example.local'] },
  { icon: 'hash', title: 'DN, GUID ou SID', text: 'Désignation exacte, jamais une recherche approchée.', examples: ['OU=Distribution,OU=Groupes,DC=example,DC=local'] },
];

export function renderEmpty(main, ctx) {
  let alive = true;
  let token = 0;
  let suggestions = [];
  let active = -1;
  main.innerHTML = `<div class="page fi-page fi-empty-page" data-kind="empty">
    <section class="fi-hero fi-search-hero reveal">
      <span class="glow-ring fi-ring" aria-hidden="true"></span>
      <div class="orbs" aria-hidden="true"><span class="orb a"></span><span class="orb b"></span><span class="orb c"></span></div>
      <div class="fi-search-inner">
        <p class="fi-eyebrow"><span class="fi-kind">${glyph('object')}Fiche d’objet</span></p>
        <h1 class="gradient-text">Ouvrir une fiche</h1>
        <p class="fi-subtitle">Utilisateur, poste, groupe, unité d’organisation ou contact : identité, compte, groupes, relations, droits, attributs, historique et fiche d’appel.</p>
        <form class="fi-search-form" role="search" novalidate>
          <label class="fi-search-field">${glyph('search')}<span class="visually-hidden">Nom, identifiant, DOMAINE\\compte, UPN ou DN</span>
            <input class="fi-search-input" type="search" maxlength="256" autocomplete="off" spellcheck="false" placeholder="Nom, identifiant, DOMAINE\\compte, UPN ou DN" aria-controls="fi-suggest" aria-autocomplete="list">
            <kbd>Entrée</kbd></label>
          <div class="fi-suggest" id="fi-suggest" role="listbox" aria-label="Correspondances de la base locale"></div>
        </form>
        <p class="fi-search-note">${glyph('shield')}Rien n’est lu sur le réseau avant Entrée : une correspondance exacte de la base locale ouvre sa fiche, sinon la recherche globale s’ouvre.</p>
      </div>
    </section>
    <div class="grid fi-empty-grid">
      <section class="card fi-card span-8 reveal fi-recent-card"><div class="card-head"><span class="card-icon">${glyph('history')}</span>
          <div class="fi-card-titles"><h3>Dernières fiches</h3><p class="fi-card-sub">Mémoire locale de Domenia (préférences)</p></div>
          <span class="meta"><button class="btn ghost xs" type="button" data-clear hidden>${glyph('trash')}Effacer la liste</button></span></div>
        <div class="fi-recent" aria-busy="true">${Array.from({ length: 6 }, () => '<span class="skeleton fi-sk-recent"></span>').join('')}</div></section>
      <section class="card fi-card span-4 reveal fi-quick-card"><div class="card-head"><span class="card-icon">${glyph('zap')}</span>
          <div class="fi-card-titles"><h3>Accès rapides</h3><p class="fi-card-sub">Depuis la session, sans lecture réseau</p></div></div>
        <div class="fi-quick" aria-busy="true"><span class="skeleton fi-sk-line w85"></span><span class="skeleton fi-sk-line w70"></span></div></section>
    </div>
  </div>`;
  const page = main.querySelector('.fi-page');
  const input = /** @type {HTMLInputElement} */ (main.querySelector('.fi-search-input'));
  const suggest = /** @type {HTMLElement} */ (main.querySelector('.fi-suggest'));
  const recentHost = /** @type {HTMLElement} */ (main.querySelector('.fi-recent'));
  const quickHost = /** @type {HTMLElement} */ (main.querySelector('.fi-quick'));
  const clearBtn = /** @type {HTMLElement} */ (main.querySelector('[data-clear]'));
  const stopReveal = reveal(page);

  const row = (item, n, extra = '') => {
    const k = kindOf(item.kind);
    return `<button type="button" class="fi-recent-item spot" data-dn="${esc(item.dn)}" data-j="${n}"${item.exists === false ? ' data-gone="true"' : ''} data-tip="${esc(item.dn)}">
      ${avatar(item.kind, initials(item.name), 'md')}
      <span class="fi-recent-body"><span class="fi-recent-name">${esc(item.name)}</span><span class="fi-recent-sub">${esc(item.detail ?? k.label)}</span></span>
      <span class="fi-recent-side">${extra}${item.exists === false ? pill('warn', 'Introuvable', { size: 'sm' }) : ''}</span></button>`;
  };

  function paintRecent(items) {
    recentHost.removeAttribute('aria-busy');
    clearBtn.hidden = !items.length;
    recentHost.innerHTML = items.length
      ? items.map((it, n) => row(it, n, it.at ? `<time datetime="${esc(it.at)}">${esc(stamp(it.at))}</time>` : '')).join('')
      : `<div class="fi-empty"><span class="fi-empty-art">${glyph('history')}</span><div class="fi-empty-text"><strong>Aucune fiche récente</strong><p>Les fiches ouvertes s’ajoutent ici, dans la mémoire locale de Domenia.</p></div></div>
        <div class="fi-guide" role="list" aria-label="Ce que le champ de recherche accepte">${GUIDE.map((g, n) => `<div class="fi-guide-row" role="listitem" data-j="${n}"><span class="fi-guide-ico">${glyph(g.icon)}</span>
          <span class="fi-guide-text"><b>${esc(g.title)}</b><span>${esc(g.text)}</span></span>
          <span class="fi-guide-ex">${g.examples.map((x) => `<button type="button" class="chip mono" data-example="${esc(x)}" data-tip="Placer dans le champ (rien n’est lu avant Entrée)">${esc(x)}</button>`).join('')}</span></div>`).join('')}</div>`;
    applyVars(recentHost);
  }

  async function loadRecent() {
    try {
      const items = await ctx.call('fiche.recent');
      if (alive) paintRecent(Array.isArray(items) ? items : []);
    } catch (err) {
      if (!alive) return;
      recentHost.removeAttribute('aria-busy');
      recentHost.innerHTML = `<p class="fi-faint">${esc(errorText(err))}</p>`;
    }
  }

  async function loadQuick() {
    try {
      const s = await ctx.call('session.info');
      if (!alive) return;
      const items = [];
      if (s?.account?.dn) items.push({ dn: s.account.dn, name: s.account.displayName ?? s.account.login, kind: 'user', detail: `Compte de session · ${s.account.login}` });
      if (s?.scope?.dn) items.push({ dn: s.scope.dn, name: s.scope.label, kind: 'ou', detail: 'OU de travail' });
      if (s?.domain?.rootDn) items.push({ dn: s.domain.rootDn, name: s.domain.dnsName ?? s.domain.rootDn, kind: 'container', detail: 'Racine du domaine (lecture seule)' });
      quickHost.removeAttribute('aria-busy');
      quickHost.innerHTML = items.length ? items.map((it, n) => row(it, n)).join('') : '<p class="fi-faint">Aucun accès rapide.</p>';
      applyVars(quickHost);
    } catch (err) {
      if (!alive) return;
      quickHost.removeAttribute('aria-busy');
      quickHost.innerHTML = `<p class="fi-faint">${esc(errorText(err))}</p>`;
    }
  }

  function paintSuggest() {
    if (!suggestions.length) { suggest.innerHTML = ''; suggest.classList.remove('open'); return; }
    suggest.classList.add('open');
    suggest.innerHTML = suggestions.map((s, n) => {
      const k = kindOf(s.kind);
      return `<button type="button" role="option" class="fi-sugg${n === active ? ' active' : ''}" aria-selected="${n === active}" data-dn="${esc(s.dn)}" data-j="${n}">
        <span class="fi-pick-ico" data-kind="${esc(s.kind)}">${glyph(k.icon)}</span><span class="fi-pick-body"><span class="fi-pick-name">${esc(s.name)}${s.sam ? `<span class="fi-pick-sam mono">${esc(s.sam)}</span>` : ''}</span>
        <span class="fi-pick-sub">${esc(s.detail ?? k.label)}</span></span>${s.disabled ? '<span class="fi-pick-off">Désactivé</span>' : ''}</button>`;
    }).join('');
    applyVars(suggest);
  }

  // Local suggestions only (fiche.pick reads the local index, never the network).
  const lookup = debounce(async () => {
    const text = input.value.trim();
    const my = ++token;
    if (text.length < 2 || text.includes('=')) { suggestions = []; active = -1; paintSuggest(); return; }
    try {
      const found = await ctx.call('fiche.pick', { text });
      if (my !== token || !alive) return;
      suggestions = (Array.isArray(found) ? found : []).slice(0, 8);
      active = -1;
      paintSuggest();
    } catch (err) {
      console.error(err);
    }
  }, 200);

  async function submit() {
    const text = input.value.trim();
    if (!text) { input.focus(); return; }
    if (active >= 0 && suggestions[active]) { ctx.navigate('fiche', { dn: suggestions[active].dn }); return; }
    try {
      const found = await ctx.call('fiche.resolve', { text });
      ctx.navigate('fiche', { dn: found.dn });
    } catch (err) {
      if (err?.code === 'fiche.notFound' || err?.code === 'fiche.ambiguous') {
        toast(`${errorText(err)}`, { tone: 'info' });
        ctx.navigate('rechercher', { q: text });
      } else {
        toast(errorText(err), { tone: 'warn' });
      }
    }
  }

  main.querySelector('.fi-search-form').addEventListener('submit', (e) => { e.preventDefault(); submit(); });
  input.addEventListener('input', lookup);
  input.addEventListener('keydown', (e) => {
    if (!suggestions.length) return;
    if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
      e.preventDefault();
      if (e.key === 'ArrowDown') active = active + 1 >= suggestions.length ? -1 : active + 1;
      else active = active - 1 < -1 ? suggestions.length - 1 : active - 1;
      paintSuggest();
    } else if (e.key === 'Escape') {
      suggestions = [];
      paintSuggest();
    }
  });
  main.addEventListener('click', async (e) => {
    const t = e.target instanceof Element ? e.target : null;
    const example = t?.closest('[data-example]');
    if (example) { input.value = example.dataset.example; input.focus(); lookup(); return; }
    const item = t?.closest('[data-dn]');
    if (item) { ctx.navigate('fiche', { dn: item.dataset.dn }); return; }
    if (t?.closest('[data-clear]')) {
      try { paintRecent(await ctx.call('fiche.recent.clear')); } catch (err) { toast(errorText(err), { tone: 'warn' }); }
    }
  });

  loadRecent();
  loadQuick();
  input.focus({ preventScroll: true });
  return () => { alive = false; stopReveal(); };
}

function initials(name) {
  const words = String(name ?? '').split(/[\s,.\-_]+/).filter((w) => /[\p{L}\p{N}]/u.test(w));
  if (words.length >= 2) return (words[0][0] + words[1][0]).toUpperCase();
  return words[0] ? words[0].slice(0, 2) : '?';
}
