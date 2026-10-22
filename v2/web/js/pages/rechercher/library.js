// Rechercher · library of the screen: ready-made views and delivered local queries (one catalog, favourites, source, type,
// cost and LDAP filter of each one, run on the OU of the tree or explicitly on the whole domain), personal views (save
// what shapes the list, open without any read, remove with « Annuler ») and the help on the syntax of the bar.
// Domenia 1 RCH-100 to RCH-122, RCH-132 to RCH-137.
import { glyph } from '../../kit/glyphs.js';
import { openDrawer } from '../../kit/drawer.js';
import { openDialog } from '../../kit/dialog.js';
import { pill } from '../../kit/status.js';
import { highlight, debounce, readLayout } from '../../kit/util.js';
import { toast, announce, errorText } from '../../ui.js';
import { esc, fold, int, count, quote, COLON, NBSP, typeLabel, dateText, leafOf } from './text.js';

/**
 * Catalog drawer of the views and local queries.
 * @param {any} ctx
 * @param {{ ou: () => ({dn: string, name: string, subtree: boolean}|null), onRun: (entry: any, o: {wholeDomain: boolean, verdict: string}) => void }} o
 */
export async function openCatalog(ctx, o) {
  let catalog;
  const drawer = openDrawer({
    title: 'Requêtes prêtes', subtitle: 'Annuaire et base locale · rien ne part avant votre clic', icon: 'database', width: 620, key: 'rechercher.requetes',
    body: `<div data-page="rechercher" class="rch-cat" aria-busy="true">${'<span class="skeleton sk sk-line w85"></span>'.repeat(8)}</div>`,
  });
  try {
    catalog = await ctx.call('search.catalog');
  } catch (err) {
    drawer.body.innerHTML = `<p data-page="rechercher" class="rch-prev-err">${glyph('alert')}${esc(errorText(err))}</p>`;
    return;
  }
  const st = { text: '', favorites: false, selected: null, whole: false, verdict: 'match' };
  const ou = o.ou();
  drawer.body.innerHTML = `<div data-page="rechercher" class="rch-cat">
    <div class="rch-cat-tools">
      <label class="rch-cat-search">${glyph('search')}<span class="visually-hidden">Filtrer les requêtes</span><input type="search" maxlength="80" autocomplete="off" placeholder="Filtrer par nom, catégorie ou description…"></label>
      <label class="rch-cat-fav"><input class="switch" type="checkbox" role="switch"><span>Favoris</span></label>
    </div>
    <p class="rch-cat-note">${glyph('info')}${esc(catalog.note)}</p>
    <div class="rch-cat-list" role="listbox" aria-label="Requêtes"></div>
    <section class="rch-cat-detail" hidden></section>
  </div>`;
  const listEl = drawer.body.querySelector('.rch-cat-list');
  const detail = drawer.body.querySelector('.rch-cat-detail');

  function paintList() {
    const needle = fold(st.text);
    const entries = catalog.entries.filter((e) => (!st.favorites || e.favorite) && (!needle || fold(`${e.name} ${e.category} ${e.description} ${e.source}`).includes(needle)));
    const groups = new Map();
    for (const e of entries) { if (!groups.has(e.category)) groups.set(e.category, []); groups.get(e.category).push(e); }
    let n = 0;
    listEl.innerHTML = entries.length ? [...groups].map(([cat, items]) => `<h4 class="rch-cat-group">${esc(cat)}<span>${int(items.length)}</span></h4>${items.map((e) => `
      <div class="rch-cat-item${st.selected?.id === e.id ? ' on' : ''}" role="option" aria-selected="${st.selected?.id === e.id}" data-id="${esc(e.id)}" data-j="${Math.min(n++, 20)}" tabindex="0">
        <span class="rch-cat-ico ${e.local ? 'local' : 'ad'}">${glyph(e.local ? 'disk' : e.typeLabel === 'Postes' ? 'monitor' : e.typeLabel === 'Personnes' ? 'user' : 'layers')}</span>
        <span class="rch-cat-main"><b>${highlight(e.name, needle)}</b><small>${esc(e.local ? 'Base locale' : e.source)} · ${esc(e.typeLabel)}</small></span>
        <button class="rch-star${e.favorite ? ' on' : ''}" type="button" data-star="${esc(e.id)}" aria-pressed="${e.favorite}" aria-label="${e.favorite ? 'Retirer des favoris' : 'Épingler en favori'} ${esc(e.name)}" data-tip="${e.favorite ? 'Retirer des favoris' : 'Épingler en favori'}">${glyph('star')}</button>
      </div>`).join('')}`).join('')
      : `<p class="rch-cat-none">${st.favorites ? 'Aucun favori : épinglez une requête avec l’étoile.' : 'Aucune requête ne correspond à ce filtre.'}</p>`;
    listEl.querySelectorAll('[data-j]').forEach((x) => x.style.setProperty('--j', x.dataset.j));
  }

  function paintDetail() {
    const e = st.selected;
    detail.hidden = !e;
    if (!e) return;
    const scopeOu = ou ? `${quote(ou.name)}${ou.subtree ? ', sous-OU incluses' : ', enfants directs'}` : 'aucune OU choisie dans l’arbre';
    detail.innerHTML = `<header><span class="rch-cat-ico ${e.local ? 'local' : 'ad'}">${glyph(e.local ? 'disk' : 'database')}</span><div><h3>${esc(e.name)}</h3><p>${pill(e.local ? 'info' : 'accent', e.local ? 'Base locale et relevés datés' : e.source, { size: 'sm' })} ${pill('off', e.typeLabel, { size: 'sm' })}</p></div></header>
      <p class="rch-cat-desc">${esc(e.description)}</p>
      <dl class="rch-cat-facts"><dt>Source</dt><dd>${esc(e.local ? 'Base locale et relevés datés : aucune lecture de l’annuaire ni des postes' : `${e.source} : lecture de l’annuaire sur votre clic`)}</dd>
        <dt>Périmètre</dt><dd>${esc(ou ? `${ou.name}${ou.subtree ? ', sous-OU incluses' : ', enfants directs'}` : 'aucune OU choisie : tout le domaine seulement sur choix explicite')}</dd>
        <dt>Coût</dt><dd>${esc(e.cost)}</dd>${e.ldapFilter ? `<dt>Filtre LDAP</dt><dd><code>${esc(e.ldapFilter)}</code></dd>` : ''}
        ${e.local ? '<dt>Couverture</dt><dd>Dite avec le résultat : date de la dernière lecture complète qui couvre le périmètre, ou nombre de postes sans aucun relevé récent.</dd>' : ''}</dl>
      <fieldset class="rch-cat-scope"><legend>Périmètre</legend>
        <label><input type="radio" name="rch-cat-scope" value="ou"${st.whole ? '' : ' checked'}${ou ? '' : ' disabled'}><span>Sur l’OU de l’arbre${COLON}${esc(scopeOu)}</span></label>
        <label><input type="radio" name="rch-cat-scope" value="domain"${st.whole || !ou ? ' checked' : ''}><span>Sur tout le domaine${NBSP}— choix secondaire, aucun relevé des postes ne sera proposé sur cette liste</span></label>
      </fieldset>
      ${e.local ? `<fieldset class="rch-cat-verdict"><legend>Résultat affiché</legend>${[['match', 'Correspondants'], ['unknown', 'Inconnus'], ['noMatch', 'Non correspondants'], ['all', 'Tous']].map(([v, l]) => `<label><input type="radio" name="rch-cat-verdict" value="${v}"${st.verdict === v ? ' checked' : ''}><span>${l}</span></label>`).join('')}</fieldset>` : ''}
      <div class="rch-cat-go"><button class="btn primary" type="button" data-run>${glyph('play')}Exécuter${e.local ? '' : '<span class="rch-net-dot" aria-hidden="true"></span>'}</button></div>`;
    detail.classList.remove('in');
    void detail.offsetWidth;
    detail.classList.add('in');
  }

  drawer.body.querySelector('.rch-cat-search input').addEventListener('input', debounce((e) => { st.text = e.target.value; paintList(); }, 150));
  drawer.body.querySelector('.rch-cat-fav input').addEventListener('change', (e) => { st.favorites = e.target.checked; paintList(); });
  listEl.addEventListener('click', async (e) => {
    const t = e.target instanceof Element ? e.target : null;
    const star = t?.closest('[data-star]');
    if (star) {
      e.stopPropagation();
      const entry = catalog.entries.find((x) => x.id === star.dataset.star);
      try {
        const state = await ctx.call('search.query.favorite', { id: entry.id, favorite: !entry.favorite });
        entry.favorite = !entry.favorite;
        announce(entry.favorite ? `${entry.name} épinglée en favori.` : `${entry.name} retirée des favoris.`);
        if (state.warning) toast(state.warning, { tone: 'warn' });
        paintList();
      } catch (err) {
        toast(`Favori non enregistré${COLON}${errorText(err)}`, { tone: 'warn' });
      }
      return;
    }
    const item = t?.closest('.rch-cat-item');
    if (item) { st.selected = catalog.entries.find((x) => x.id === item.dataset.id); paintList(); paintDetail(); }
  });
  listEl.addEventListener('keydown', (e) => {
    const item = e.target instanceof Element ? e.target.closest('.rch-cat-item') : null;
    if (!item) return;
    if (e.key === 'Enter') { st.selected = catalog.entries.find((x) => x.id === item.dataset.id); paintList(); paintDetail(); detail.querySelector('[data-run]')?.focus(); }
    if (e.key === 'ArrowDown') { e.preventDefault(); const all = [...listEl.querySelectorAll('.rch-cat-item')]; all[all.indexOf(item) + 1]?.focus(); }
    if (e.key === 'ArrowUp') { e.preventDefault(); const all = [...listEl.querySelectorAll('.rch-cat-item')]; all[all.indexOf(item) - 1]?.focus(); }
  });
  detail.addEventListener('change', (e) => {
    const t = e.target;
    if (t.name === 'rch-cat-scope') st.whole = t.value === 'domain';
    if (t.name === 'rch-cat-verdict') st.verdict = t.value;
  });
  detail.addEventListener('click', (e) => {
    if (!(e.target instanceof Element) || !e.target.closest('[data-run]') || !st.selected) return;
    drawer.close();
    o.onRun(st.selected, { wholeDomain: st.whole || !ou, verdict: st.verdict });
  });
  paintList();
}

/**
 * Personal views: save what shapes the list, open it without any read, remove with « Annuler ».
 * @param {any} ctx
 * @param {{ memory: () => any, current: () => any, proposed: () => string, onSaved: (state: any) => void, onOpen: (view: any, refresh: boolean) => void }} o
 */
export function openViews(ctx, o) {
  const draft = o.current();
  const drawer = openDrawer({ title: 'Vues personnelles', subtitle: 'Mémorisées sur ce poste, par domaine · ni résultat ni compte', icon: 'tag', width: 560, key: 'rechercher.vues', body: '<div data-page="rechercher" class="rch-views"></div>' });
  const host = drawer.body.querySelector('.rch-views');

  function paint() {
    const mem = o.memory();
    const views = mem?.workspaces ?? [];
    host.innerHTML = `
      <form class="rch-view-save" novalidate>
        <h3>${glyph('plus')}Enregistrer la vue actuelle</h3>
        ${draft ? `<label class="field"><span>Nom</span><input class="input" name="name" maxlength="80" required value="${esc(o.proposed())}"></label>
          <dl class="rch-view-what">
            <dt>OU</dt><dd>${esc(draft.ouLabel)}</dd><dt>Profondeur</dt><dd>${draft.subtree ? 'Sous-OU incluses' : 'Enfants directs'}</dd>
            <dt>Type</dt><dd>${esc(typeLabel(draft.type))}</dd><dt>Présence</dt><dd>${esc(draft.presenceLabel)}</dd>
            <dt>Filtre de la liste</dt><dd>${draft.filter ? esc(draft.filter) : '—'}</dd><dt>Limite</dt><dd>${int(draft.limit)} lignes</dd>
            <dt>Colonnes</dt><dd>${esc(draft.columnSetLabel)}${draft.layout ? `, ${count(draft.layout.order.length - draft.layout.hidden.length, 'colonne affichée', 'colonnes affichées')}${draft.layout.sort.length ? ', tri mémorisé' : ''}` : ''}</dd>
          </dl>
          ${draft.note ? `<p class="rch-dlg-note">${glyph('info')}${esc(draft.note)}</p>` : ''}
          <div class="rch-view-acts"><button class="btn primary" type="submit">${glyph('check')}Enregistrer</button></div>`
          : `<p class="rch-cat-none">Une vue mémorise une OU${COLON}choisissez d’abord une OU dans l’arbre (ou listez son contenu).</p>`}
      </form>
      <h3 class="rch-views-title">${glyph('tag')}Vues enregistrées <span>${int(views.length)} / ${int(mem?.maxWorkspaces ?? 100)}</span></h3>
      ${mem?.undo ? `<p class="rch-view-undo">${glyph('undo')}Vue ${quote(mem.undo.name)} retirée.<button class="btn sm" type="button" data-undo>Annuler le retrait</button></p>` : ''}
      <ul class="rch-view-list">${views.map((v, n) => `<li class="rch-view" data-id="${esc(v.id)}" data-j="${Math.min(n, 20)}">
        <span class="rch-view-ico">${glyph('tag')}</span><span class="rch-view-main"><b>${esc(v.name)}</b><small>${esc(v.label)}</small><small class="faint">Enregistrée le ${esc(dateText(v.savedAt, false))}</small></span>
        <button class="btn sm subtle" type="button" data-open="${esc(v.id)}" data-tip="Prépare l’OU, les filtres, les colonnes et le tri sans rien lire">${glyph('folder')}Ouvrir</button>
        <button class="btn sm" type="button" data-refresh="${esc(v.id)}" data-tip="Ouvre la vue puis lit le contenu de son OU">${glyph('refresh')}Ouvrir et lire</button>
        <button class="btn ghost icon sm" type="button" data-remove="${esc(v.id)}" aria-label="Retirer la vue ${esc(v.name)}" data-tip="Retirer (annulable)">${glyph('trash')}</button>
      </li>`).join('') || `<li class="rch-cat-none">Aucune vue enregistrée dans ce domaine.</li>`}</ul>`;
    host.querySelectorAll('[data-j]').forEach((x) => x.style.setProperty('--j', x.dataset.j));
  }

  host.addEventListener('submit', async (e) => {
    e.preventDefault();
    const name = host.querySelector('input[name="name"]').value.trim();
    if (!name) { toast('Donnez un nom à la vue.', { tone: 'warn' }); return; }
    try {
      const state = await ctx.call('search.workspace.save', { ...draft.args, name });
      o.onSaved(state);
      toast(`Vue ${quote(name)} enregistrée.`, { tone: 'ok' });
      if (state.warning) toast(state.warning, { tone: 'warn' });
      paint();
    } catch (err) {
      toast(errorText(err), { tone: 'warn' });
    }
  });
  host.addEventListener('click', async (e) => {
    const t = e.target instanceof Element ? e.target : null;
    if (!t) return;
    const views = o.memory()?.workspaces ?? [];
    const open = t.closest('[data-open]') ?? t.closest('[data-refresh]');
    if (open) { const v = views.find((x) => x.id === (open.dataset.open ?? open.dataset.refresh)); if (v) { drawer.close(); o.onOpen(v, !!open.dataset.refresh); } return; }
    const remove = t.closest('[data-remove]');
    if (remove) {
      try { o.onSaved(await ctx.call('search.workspace.remove', { id: remove.dataset.remove })); paint(); announce('Vue retirée ; « Annuler le retrait » la rétablit.'); } catch (err) { toast(errorText(err), { tone: 'warn' }); }
      return;
    }
    if (t.closest('[data-undo]')) {
      try { o.onSaved(await ctx.call('search.workspace.undo')); paint(); announce('Retrait annulé.'); } catch (err) { toast(errorText(err), { tone: 'warn' }); }
    }
  });
  paint();
}

/** Help on the syntax of the bar (Domenia 1 D033, D036, R40, CO-34). */
export function openSyntaxHelp(onExample) {
  const rows = [
    ['Un nom, un compte', 'martin', 'Chaque mot doit figurer au début d’un nom, d’un compte, d’un nom affiché, d’un courriel ou d’un nom DNS (accents et casse ignorés).'],
    ['Plusieurs mots', 'camille ber', 'Tous les mots doivent correspondre, dans n’importe quel attribut.'],
    ['Un compte', 'utilisateur: martin', 'Préfixes utilisateur:, user:, u:. Valeur entre guillemets possible.'],
    ['Un poste', 'poste: PC-PAR-01', 'Préfixes poste:, pc:, machine:, ordinateur:.'],
    ['Un groupe', 'groupe: GG-Support', 'Préfixes groupe:, group:, g:.'],
    ['Un courriel', 'mail: camille', 'Préfixes mail:, email:, courriel:.'],
    ['Joker', 'PC-*-0042', 'Une étoile tapée reste un joker ; en tête, recherche sans index, plus lente. Une étoile seule est refusée.'],
    ['Identifiant collé', 'S-1-5-21-…', 'GUID, SID et nom distinctif deviennent une recherche exacte ; DOMAINE\\compte, adresse et nom DNS sont reconnus et expliqués.'],
    ['Adresse IP ou MAC', '10.10.1.20', 'Recherche dans les relevés locaux, sans scan réseau ; une adresse IPv4 inconnue propose une résolution DNS sur clic.'],
  ];
  const dlg = openDialog({
    title: 'Syntaxe de la recherche', subtitle: 'Facultative : un texte simple suffit', icon: 'sparkles', size: 'lg',
    body: `<div data-page="rechercher" class="rch-help"><table class="table"><thead><tr><th>Pour chercher</th><th>Saisissez</th><th>Ce qui est cherché</th></tr></thead><tbody>
      ${rows.map(([what, ex, how], n) => `<tr data-j="${n}"><td><b>${esc(what)}</b></td><td><button class="chip rch-help-ex" type="button" data-ex="${esc(ex.replace('…', ''))}"${ex.includes('…') ? ' disabled' : ''}><code>${esc(ex)}</code></button></td><td>${esc(how)}</td></tr>`).join('')}
    </tbody></table>
    <p class="rch-dlg-note">${glyph('info')}<span>Deux caractères au moins. Taper ne lit jamais l’annuaire : seule Entrée ou « Rechercher » l’interroge. Dans les suggestions, <kbd>Ctrl</kbd> <kbd>Entrée</kbd> ouvre directement la fiche.</span></p></div>`,
    actions: [{ id: 'close', label: 'Fermer', safe: true, primary: true }],
  });
  dlg.body.querySelectorAll('[data-j]').forEach((x) => x.style.setProperty('--j', x.dataset.j));
  dlg.body.addEventListener('click', (e) => {
    const b = e.target instanceof Element ? e.target.closest('[data-ex]') : null;
    if (b && !b.disabled) { dlg.close('close'); onExample(b.dataset.ex); }
  });
}

/** Layout of the grid of a column set, as the kit keeps it (column keys and sizes only), bounded for the engine. */
export function layoutOf(set) {
  const saved = readLayout(`grid:rechercher.${set}`);
  if (!saved || saved.v !== 1) return null;
  const key = (x) => typeof x === 'string' && /^[A-Za-z][A-Za-z0-9_]{0,79}$/.test(x);
  const widths = {};
  for (const [k, w] of Object.entries(saved.widths ?? {})) if (key(k) && Number.isInteger(w) && w >= 40 && w <= 1600 && Object.keys(widths).length < 100) widths[k] = w;
  return {
    order: (saved.order ?? []).filter(key).slice(0, 100),
    hidden: (saved.hidden ?? []).filter(key).slice(0, 100),
    widths,
    sort: (saved.sort ?? []).filter((s) => s && key(s.id) && (s.dir === 1 || s.dir === -1)).slice(0, 4).map((s) => ({ id: s.id, dir: s.dir })),
    density: ['compact', 'normal', 'comfortable'].includes(saved.density) ? saved.density : 'normal',
  };
}

export { leafOf };
