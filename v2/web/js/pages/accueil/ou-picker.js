// « Choisir l’OU de travail »: kit drawer (kit/drawer.js) holding the kit lazy tree (kit/tree.js). Branches are read on
// demand with directory.ou.children (a closed branch is never read), the search asks directory.ou.search, favourites
// switch the OU in one click, and « Appliquer » sends session.setScope. Nothing reaches the directory: the choice is
// kept in the preferences of Domenia (OPERATIONS.md § 9-10, docs/ops/accueil.md § 9).
import { openDrawer } from '../../kit/drawer.js';
import { confirmDialog } from '../../kit/dialog.js';
import { createTree } from '../../kit/tree.js';
import { glyph } from '../../kit/glyphs.js';
import { debounce, highlight } from '../../kit/util.js';
import { esc, fold, formatNumber, announce } from '../../ui.js';
import {
  NBSP, isNum, plural, sameDn, dnChain, pathOf, isRootDn, paint, reported, surface, copyWithToast, isSimulated,
} from './shared.js';

// directory.ou.search answers at most this many OU (OPERATIONS.md § 10): a full list may hide more matches.
const OU_SEARCH_LIMIT = 50;
const validOu = (o) => o && typeof o.dn === 'string' && o.dn && typeof o.name === 'string';
const validCounts = (c) => c && isNum(c.users) && isNum(c.computers) && isNum(c.groups);
const countsText = (c) => [plural(c.users, 'utilisateur', 'utilisateurs'), plural(c.computers, 'ordinateur', 'ordinateurs'), plural(c.groups, 'groupe', 'groupes')].join(', ');

function countsMarkup(c) {
  if (!validCounts(c)) return '';
  const item = (n, ic, one, many, cls) => `<span class="ou-cnt ${cls}${n ? '' : ' zero'}" data-tip="${esc(plural(n, one, many))}">${glyph(ic)}${formatNumber(n)}</span>`;
  return `<span class="ou-counts" aria-hidden="true">${item(c.users, 'user', 'utilisateur', 'utilisateurs', 'u')}${item(c.computers, 'monitor', 'ordinateur', 'ordinateurs', 'c')}${item(c.groups, 'group', 'groupe', 'groupes', 'g')}</span>`
    + `<span class="visually-hidden">, ${esc(countsText(c))}</span>`;
}

const idOf = (dn) => String(dn).toLowerCase();

/**
 * @param {{ ctx: any, current: () => { session: any, app: any }, onApplied: (session: any) => Promise<void> | void }} o
 */
export function createOuPicker({ ctx, current, onApplied }) {
  let drawer = null;
  let tree = null;
  let alive = true;

  /** Opens the drawer, optionally on an OU of the path (crumbs of the working OU). */
  function open({ revealDn = null } = {}) {
    if (drawer) return drawer.closed;
    const s = current().session;
    const cur = s?.scope ?? null;
    const sim = isSimulated(s, current().app);
    let selected = cur ? { dn: cur.dn, name: cur.label, path: pathOf(cur.dn, s?.domain?.dnsName), counts: null } : null;
    let subtree = cur ? cur.subtree !== false : true;
    let busy = false;
    let hits = [];
    let searchToken = 0;
    let favorites = { items: [], max: 12 };
    let rootReady;
    const rootLoaded = new Promise((r) => { rootReady = r; });

    const body = surface('acc-ou', `
      <div class="ou-now"></div>
      <section class="ou-favs" aria-label="OU favorites"><div class="ou-favs-head"><span class="ou-k">${glyph('star')}Favorites</span>
        <button class="btn ghost sm" type="button" data-ou-fav-add>${glyph('plus')}Ajouter la sélection</button></div>
        <div class="ou-fav-list" aria-busy="true"><span class="skeleton sk sk-line w55"></span></div>
        <form class="ou-fav-form" hidden><label class="visually-hidden" for="ou-fav-name">Nom de la favorite</label>
          <input id="ou-fav-name" class="input" type="text" maxlength="60" autocomplete="off" spellcheck="false" placeholder="Nom de la favorite">
          <button class="btn sm primary" type="submit">${glyph('check')}Enregistrer</button><button class="btn sm ghost" type="button" data-ou-fav-cancel>Annuler</button></form>
      </section>
      <label class="ou-search">${glyph('search')}<span class="visually-hidden">Rechercher une OU par nom ou par chemin dans tout le domaine</span>
        <input class="ou-input" type="search" placeholder="Rechercher une OU dans tout le domaine" autocomplete="off" spellcheck="false" maxlength="100"><span class="ou-spin" aria-hidden="true"></span></label>
      <div class="ou-tree-host"></div>
      <div class="ou-results" hidden></div>
      <div class="ou-foot">
        <div class="ou-pick"></div>
        <label class="ou-sub"><input class="switch" type="checkbox" data-ou-subtree><span>Inclure les sous-OU</span></label>
        <p class="ou-effect" aria-live="polite"></p>
        <p class="ou-error" role="alert" hidden>${glyph('info')}<span></span></p>
      </div>`);
    const treeHost = body.querySelector('.ou-tree-host');
    const results = body.querySelector('.ou-results');
    const input = body.querySelector('.ou-input');
    const subBox = body.querySelector('[data-ou-subtree]');
    const favList = body.querySelector('.ou-fav-list');
    const favForm = body.querySelector('.ou-fav-form');
    subBox.checked = subtree;

    drawer = openDrawer({
      title: 'Choisir l’OU de travail',
      subtitle: 'Défaut de toutes les sections sans choix propre ; gardé dans les préférences de Domenia, jamais dans l’annuaire.',
      icon: 'ou', side: 'right', key: 'accueil.ou', width: 540, minWidth: 380, body,
      actions: [
        { id: 'cancel', label: 'Annuler', run: (d) => d.close() },
        { id: 'apply', label: 'Appliquer', icon: 'check', primary: true, run: () => apply() },
      ],
      onClose: () => {
        searchToken += 1;
        runSearch.cancel();
        tree?.destroy();
        tree = null;
        drawer = null;
      },
    });
    const applyBtn = () => drawer?.foot?.querySelector('[data-id="apply"]');

    function showError(text, toneName = 'alert') {
      const box = body.querySelector('.ou-error');
      box.dataset.tone = toneName;
      box.querySelector('span').textContent = text;
      box.hidden = false;
      box.classList.remove('shake');
      void box.offsetWidth;
      box.classList.add('shake');
    }
    const hideError = () => { body.querySelector('.ou-error').hidden = true; };

    function nowLine() {
      const ss = current().session;
      const c = ss?.scope;
      body.querySelector('.ou-now').innerHTML = (c
        ? `<span class="ou-k">OU actuelle</span><b>${esc(c.label)}</b><span class="faint">${esc(pathOf(c.dn, ss.domain?.dnsName))} · ${c.subtree ? 'sous-OU comprises' : 'cette OU seulement'}</span>`
        : '<span class="ou-k">OU actuelle</span><b>Aucune</b><span class="faint">la mesure des postes attend une OU</span>')
        + `<button class="btn ghost sm ou-reset" type="button" data-ou-reset data-tip="OU de travail par défaut de la source (OU racine des postes)">${glyph('undo')}Revenir à l’OU par défaut</button>`;
    }

    function updateFoot() {
      const c = current().session?.scope ?? null;
      const pick = body.querySelector('.ou-pick');
      if (selected) {
        const path = selected.path || pathOf(selected.dn, current().session?.domain?.dnsName);
        pick.innerHTML = `<span class="ou-k">Sélection</span>
          <span class="ou-pick-name">${glyph(selected.root ? 'domain' : 'ou')}<b>${esc(selected.root ? `Tout le domaine ${selected.name}` : selected.name)}</b>${countsMarkup(selected.counts)}</span>
          <span class="ou-pick-path"><span class="txt" data-tip="${esc(selected.dn)}">${esc(path)}</span>
          <button class="btn ghost icon sm" type="button" data-ou-copy aria-label="Copier le DN de l’OU sélectionnée" data-tip="Copier le chemin LDAP (DN)">${glyph('copy')}</button></span>`;
      } else {
        pick.innerHTML = '<span class="ou-k">Sélection</span><span class="ou-pick-none">Aucune OU sélectionnée : choisissez-en une dans l’arborescence, par la recherche ou parmi les favorites.</span>';
      }
      paint(pick);
      // Whole domain: always with its sub-OU (session.setScope forces it); the switch says so.
      subBox.disabled = Boolean(selected?.root);
      if (selected?.root) { subtree = true; subBox.checked = true; }
      const same = Boolean(selected && c && sameDn(selected.dn, c.dn) && c.subtree === subtree);
      const b = applyBtn();
      if (b) b.disabled = !selected || same || busy;
      const effect = body.querySelector('.ou-effect');
      if (!selected) effect.textContent = '';
      else if (same) effect.textContent = 'C’est déjà l’OU de travail : rien à changer.';
      else if (selected.root) {
        effect.textContent = `Tout le domaine : l’Accueil se calcule depuis ${sim ? 'l’annuaire fictif en mémoire' : 'la base locale'} pour l’ensemble des postes, mais aucune mesure réseau `
          + '(ping, WMI, BitLocker) ne partira sur tout le domaine : choisissez une OU pour actualiser le parc. Une confirmation est demandée.';
      } else {
        effect.textContent = `Les postes mesurés seront ceux de l’OU ${selected.name}${subtree ? ' et de ses sous-OU' : ' seule, sans ses sous-OU'} ; `
          + `les comptes restent comptés sur tout le domaine. Aucune lecture réseau : l’Accueil se recalcule depuis ${sim ? 'l’annuaire fictif en mémoire' : 'la base locale'}.`;
      }
      effect.classList.remove('flash');
      void effect.offsetWidth;
      effect.classList.add('flash');
    }

    function choose(o, { announceIt = true } = {}) {
      hideError();
      selected = { dn: o.dn, name: o.name, path: o.path ?? '', counts: validCounts(o.counts) ? o.counts : null, root: isRootDn(o.dn) };
      updateFoot();
      if (announceIt) announce(`OU sélectionnée : ${o.name}`);
    }

    // ----- Tree (kit) -----

    const nodeOf = (o, level) => ({
      id: idOf(o.dn),
      label: o.name,
      icon: 'ou',
      leaf: !o.hasChildren,
      hint: validCounts(o.counts) && o.counts.computers > 0 ? `${formatNumber(o.counts.computers)}${NBSP}${o.counts.computers > 1 ? 'postes' : 'poste'}` : undefined,
      data: { dn: o.dn, name: o.name, path: typeof o.path === 'string' ? o.path : '', counts: validCounts(o.counts) ? o.counts : null, level },
    });

    tree = createTree(treeHost, {
      label: 'Arborescence des OU',
      height: 'fill',
      search: false,
      roots: async () => {
        try {
          const r = await ctx.call('directory.ou.children', { dn: null });
          const ss = current().session;
          const p = r?.parent ?? {};
          const dn = typeof p.dn === 'string' && p.dn ? p.dn : ss?.domain?.rootDn ?? 'DC=';
          const name = typeof p.name === 'string' && p.name ? p.name : ss?.domain?.dnsName ?? 'Domaine';
          const kids = (Array.isArray(r?.children) ? r.children : []).filter(validOu).map((o) => nodeOf(o, 1));
          return [{ id: idOf(dn), label: name, icon: 'domain', hint: 'Tout le domaine', children: kids, data: { dn, name, path: name, root: true } }];
        } finally {
          rootReady();
        }
      },
      load: async (node) => {
        const r = await ctx.call('directory.ou.children', { dn: node.data.dn });
        return (Array.isArray(r?.children) ? r.children : []).filter(validOu).map((o) => nodeOf(o, (node.data.level ?? 0) + 1));
      },
      onSelect: (node) => choose(node.data),
      onActivate: (node) => { choose(node.data, { announceIt: false }); apply(); },
    });

    /** Opens the branches down to an OU (parents read one by one, only if needed) and selects it. */
    async function reveal(dn) {
      await rootLoaded;
      await new Promise((r) => requestAnimationFrame(r));
      if (!tree || !dn) return false;
      const c = dnChain(dn, null);
      if (!c) return false;
      const path = [idOf(c.root.dn), ...c.chain.map((x) => idOf(x.dn))];
      try {
        return await tree.reveal(path);
      } catch (err) {
        reported(err);
        return false;
      }
    }

    // ----- Search (whole domain, server side) -----

    function showTree() {
      results.hidden = true;
      results.innerHTML = '';
      treeHost.hidden = false;
      hits = [];
      body.querySelector('.ou-search').classList.remove('searching');
    }

    function renderHits(list, text, truncated) {
      hits = list;
      const wanted = fold(text);
      if (!list.length) {
        results.innerHTML = `<div class="ou-empty">${glyph('search')}<p>Aucune OU ne contient «${NBSP}${esc(text)}${NBSP}».</p></div>`;
        announce('Aucune OU trouvée.');
        return;
      }
      const head = `${plural(list.length, 'OU trouvée', 'OU trouvées')}${truncated ? ' : d’autres peuvent correspondre, précisez la recherche' : ''}`;
      results.innerHTML = `<p class="ou-hits-k">${esc(head)}</p><ul class="ou-hits cascade" aria-label="Résultats de la recherche">${list.map((o, n) => `<li data-j="${Math.min(n, 14)}">`
        + `<button class="ou-hit" type="button" data-n="${n}">${glyph('ou')}<span class="ou-hit-text"><span class="ou-hit-name">${highlight(o.name, wanted)}</span>`
        + `<span class="ou-hit-path">${highlight(o.path ?? '', wanted)}</span></span>${countsMarkup(o.counts)}</button></li>`).join('')}</ul>`;
      paint(results);
      announce(head);
    }

    const runSearch = debounce(async (text) => {
      const my = ++searchToken;
      treeHost.hidden = true;
      results.hidden = false;
      results.setAttribute('aria-busy', 'true');
      results.innerHTML = Array.from({ length: 4 }, (_, k) => `<div class="ou-skel" data-j="${k}"><span class="skeleton sk sk-line ${['w55', 'w40', 'w70', 'w55'][k]}"></span></div>`).join('');
      paint(results);
      body.querySelector('.ou-search').classList.add('searching');
      try {
        const r = await ctx.call('directory.ou.search', { text });
        if (my !== searchToken || !drawer) return;
        const list = (Array.isArray(r) ? r : Array.isArray(r?.results) ? r.results : []).filter(validOu);
        renderHits(list, text, r?.truncated === true || list.length >= OU_SEARCH_LIMIT);
      } catch (err) {
        if (my !== searchToken || !drawer) return;
        results.innerHTML = `<div class="acc-err">${glyph('alert')}<span>${esc(reported(err))}</span><button class="btn sm" type="button" data-ou-retry-search>${glyph('refresh')}Réessayer</button></div>`;
      } finally {
        if (my === searchToken) {
          results.removeAttribute('aria-busy');
          body.querySelector('.ou-search')?.classList.remove('searching');
        }
      }
    }, 220);

    function onInput() {
      const text = input.value.trim();
      if (!text) { runSearch.cancel(); searchToken += 1; showTree(); return; }
      runSearch(text);
    }

    async function chooseHit(o) {
      choose(o, { announceIt: false });
      input.value = '';
      runSearch.cancel();
      searchToken += 1;
      showTree();
      await reveal(o.dn);
      announce(`OU sélectionnée : ${o.name}`);
    }

    // ----- Favourites -----

    function paintFavorites() {
      const items = favorites.items ?? [];
      favList.removeAttribute('aria-busy');
      if (!items.length) {
        favList.innerHTML = '<p class="ou-fav-none">Aucune favorite : sélectionnez une OU puis « Ajouter la sélection » pour y revenir en un clic.</p>';
        return;
      }
      const c = current().session?.scope;
      favList.innerHTML = items.map((f, n) => `<span class="ou-fav${f.exists ? '' : ' missing'}${c && sameDn(c.dn, f.dn) && c.subtree === f.subtree ? ' now' : ''}" data-j="${n}">`
        + `<button class="ou-fav-pick" type="button" data-fav="${esc(f.id)}" data-tip="${esc(`${f.path}${f.subtree ? ' · sous-OU comprises' : ' · cette OU seulement'}${f.exists ? '' : ' · absente de la base locale'}`)}">`
        + `${glyph(f.exists ? 'star' : 'alert')}<span>${esc(f.name)}</span></button>`
        + `<button class="ou-fav-x" type="button" data-fav-drop="${esc(f.id)}" aria-label="Retirer la favorite ${esc(f.name)}" data-tip="Retirer">${glyph('x')}</button></span>`).join('');
      paint(favList);
    }

    async function loadFavorites() {
      try {
        favorites = await ctx.call('accueil.favorites');
      } catch (err) {
        favorites = { items: [], max: 12 };
        favList.removeAttribute('aria-busy');
        favList.innerHTML = `<p class="ou-fav-none">${esc(reported(err))}</p>`;
        return;
      }
      if (drawer) paintFavorites();
    }

    async function saveFavorite(name) {
      if (!selected) return;
      try {
        favorites = await ctx.call('accueil.favorite.save', { name, dn: selected.dn, subtree });
        favForm.hidden = true;
        paintFavorites();
        ctx.toast(`Favorite « ${name} » enregistrée dans les préférences locales.`, { tone: 'ok', life: 2600 });
      } catch (err) {
        showError(reported(err));
      }
    }

    async function dropFavorite(id) {
      const f = favorites.items.find((x) => x.id === id);
      try {
        favorites = await ctx.call('accueil.favorite.drop', { id });
        paintFavorites();
        if (f) ctx.toast(`Favorite « ${f.name} » retirée.`, { tone: 'info', life: 2400 });
      } catch (err) {
        showError(reported(err));
      }
    }

    async function pickFavorite(id) {
      const f = favorites.items.find((x) => x.id === id);
      if (!f) return;
      if (!f.exists) { showError(`L’OU « ${f.name} » est absente de la base locale : elle a peut-être été renommée ou déplacée.`, 'info'); return; }
      subtree = f.subtree;
      subBox.checked = subtree;
      choose({ dn: f.dn, name: f.name, path: f.path });
      await reveal(f.dn);
    }

    // ----- Apply and reset -----

    async function apply() {
      if (!selected || busy || !drawer) return;
      const c = current().session?.scope;
      if (c && sameDn(selected.dn, c.dn) && c.subtree === subtree) return;
      // The whole domain is an explicit choice (Domenia 1, ACC-012): confirmed, and measures stay refused on it.
      if (selected.root) {
        const ok = await confirmDialog({
          title: 'Travailler sur tout le domaine ?', icon: 'domain', confirmLabel: 'Tout le domaine',
          message: `L’Accueil et les sections sans choix propre porteront sur tout le domaine ${selected.name}, calculés depuis la base locale. `
            + 'Aucune mesure réseau des postes (ping, WMI, BitLocker) ne partira sur tout le domaine : il faudra choisir une OU pour actualiser le parc.',
        });
        if (!ok || !drawer) return;
      }
      busy = true;
      hideError();
      drawer.setBusy(true);
      updateFoot();
      try {
        const session = await ctx.call('session.setScope', { dn: selected.dn, subtree });
        if (!alive) return;
        drawer?.close();
        await onApplied(session);
      } catch (err) {
        if (drawer) showError(reported(err)); else ctx.toast(reported(err), { tone: 'alert' });
      } finally {
        busy = false;
        drawer?.setBusy(false);
        if (drawer) updateFoot();
      }
    }

    async function resetScope() {
      if (busy || !drawer) return;
      busy = true;
      drawer.setBusy(true);
      try {
        const session = await ctx.call('accueil.scope.reset');
        if (!alive) return;
        drawer?.close();
        await onApplied(session);
      } catch (err) {
        if (drawer) showError(reported(err)); else ctx.toast(reported(err), { tone: 'alert' });
      } finally {
        busy = false;
        drawer?.setBusy(false);
      }
    }

    // ----- Events -----

    body.addEventListener('click', (e) => {
      const t = e.target instanceof Element ? e.target : null;
      if (!t) return;
      if (t.closest('[data-ou-copy]')) { if (selected) copyWithToast(ctx, selected.dn, 'DN de l’OU copié dans le presse-papiers.'); return; }
      if (t.closest('[data-ou-reset]')) { resetScope(); return; }
      if (t.closest('[data-ou-retry-search]')) { onInput(); return; }
      if (t.closest('[data-ou-fav-add]')) {
        if (!selected) { showError('Sélectionnez d’abord une OU à garder en favorite.', 'info'); return; }
        if ((favorites.items?.length ?? 0) >= (favorites.max ?? 12) && !favorites.items.some((f) => sameDn(f.dn, selected.dn) && f.subtree === subtree)) {
          showError(`Douze favorites au plus : retirez-en une avant d’en ajouter une autre.`, 'info');
          return;
        }
        favForm.hidden = false;
        const field = favForm.querySelector('input');
        field.value = selected.name;
        field.focus();
        field.select();
        return;
      }
      if (t.closest('[data-ou-fav-cancel]')) { favForm.hidden = true; return; }
      const drop = t.closest('[data-fav-drop]');
      if (drop) { dropFavorite(drop.dataset.favDrop); return; }
      const fav = t.closest('[data-fav]');
      if (fav) { pickFavorite(fav.dataset.fav); return; }
      const hit = t.closest('.ou-hit');
      if (hit) { const o = hits[Number(hit.dataset.n)]; if (o) chooseHit(o); }
    });
    favForm.addEventListener('submit', (e) => {
      e.preventDefault();
      const name = favForm.querySelector('input').value.trim();
      if (!name) { showError('Donnez un nom à la favorite (60 caractères au plus).', 'info'); return; }
      saveFavorite(name);
    });
    input.addEventListener('input', onInput);
    // Échap clears the search first; the drawer only closes on an Échap nobody used.
    input.addEventListener('keydown', (e) => {
      if (e.key === 'Escape' && input.value) { e.preventDefault(); e.stopPropagation(); input.value = ''; onInput(); }
      if (e.key === 'ArrowDown') {
        const first = results.hidden ? null : results.querySelector('.ou-hit');
        if (first) { first.focus(); e.preventDefault(); } else if (results.hidden) { tree?.focus(); e.preventDefault(); }
      }
    });
    results.addEventListener('keydown', (e) => {
      const buttons = [...results.querySelectorAll('.ou-hit')];
      const at = buttons.indexOf(document.activeElement);
      if (at < 0) return;
      if (e.key === 'ArrowDown') { buttons[Math.min(buttons.length - 1, at + 1)].focus(); e.preventDefault(); }
      else if (e.key === 'ArrowUp') { (at === 0 ? input : buttons[at - 1]).focus(); e.preventDefault(); }
    });
    subBox.addEventListener('change', () => { subtree = subBox.checked; updateFoot(); });

    nowLine();
    updateFoot();
    loadFavorites();
    reveal(revealDn ?? cur?.dn ?? null).then(() => {
      // The selected OU now carries its counts (read with its level).
      const node = tree?.getSelected();
      if (node?.data && selected && sameDn(node.data.dn, selected.dn) && !selected.counts && node.data.counts) {
        selected.counts = node.data.counts;
        selected.path = node.data.path || selected.path;
        updateFoot();
      }
      if (revealDn && node?.data && !node.data.root && !sameDn(node.data.dn, cur?.dn)) choose(node.data, { announceIt: false });
    });
    return drawer.closed;
  }

  return {
    open,
    isOpen: () => Boolean(drawer),
    destroy() {
      alive = false;
      drawer?.close();
    },
  };
}
