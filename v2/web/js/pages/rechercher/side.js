// Rechercher · OU panel on the left: pinned OU favourites above a lazy tree (one level read per opening, F5 to read a
// branch again), containers of the root with the system containers folded apart, local filter of the branches already
// read, search of an OU by name in the directory on request, depth switch, tree menu and memory of the tree per domain.
// Domenia 1 RCH-003 to RCH-021.
import { glyph } from '../../kit/glyphs.js';
import { openMenu } from '../../kit/menu.js';
import { createTree } from '../../kit/tree.js';
import { readLayout, writeLayout, writeClipboard, debounce, highlight } from '../../kit/util.js';
import { announce, toast, errorText } from '../../ui.js';
import { esc, fold, int, count, quote, COLON, splitDn, leafOf, pathOf, sameDn } from './text.js';

const MEMORY_MAX = 128;
const SYSTEM_ID = '#system';

/**
 * @param {HTMLElement} host
 * @param {any} ctx
 * @param {{ root: string, dns: string, onSelect: (node: any, how: string) => void, onBrowse: (dn: string, name: string, subtree: boolean) => void,
 *   onFavorite: (fav: any) => void, onPin: (node: any, pinned: boolean) => void, onUnpin: (dn: string) => void, onMove: (dn: string, index: number) => void,
 *   isPinned: (dn: string) => boolean, onNavigate: (route: string, params: object) => void, readOnly: () => boolean }} o
 */
export function createSide(host, ctx, o) {
  const memoryKey = `rechercher.tree.${o.root.toLowerCase()}`;
  const memory = readLayout(memoryKey) ?? {};
  const st = {
    subtree: memory.subtree !== false,
    selected: null,
    favorites: [],
    loaded: new Set(Array.isArray(memory.expanded) ? memory.expanded.filter((d) => typeof d === 'string').slice(0, MEMORY_MAX) : []),
    restoring: false,
  };

  host.innerHTML = `<div class="rch-side-in">
    <header class="rch-panel-head">
      <span class="rch-panel-ico">${glyph('tree')}</span>
      <h2 class="rch-panel-title">Arborescence</h2>
      <button class="btn ghost icon sm rch-pin" type="button" aria-pressed="false" aria-label="Épingler cette OU" data-tip="Épingler l’OU choisie" disabled>${glyph('star')}</button>
      <button class="btn ghost icon sm rch-side-menu" type="button" aria-haspopup="menu" aria-expanded="false" aria-label="Menu de l’arborescence" data-tip="Profondeur, domaine entier, chemin, actualiser">${glyph('more')}</button>
    </header>
    <section class="rch-favs" aria-label="OU favorites">
      <button class="rch-favs-head" type="button" aria-expanded="true"><span>${glyph('star')}Favoris</span><span class="rch-favs-n">0</span>${glyph('chevronDown', 'rch-favs-chev')}</button>
      <ol class="rch-favs-list" role="list"></ol>
      <p class="rch-favs-empty">Épinglez une OU (${glyph('star')}) pour la retrouver ici en un clic.</p>
    </section>
    <div class="rch-ousearch" hidden>
      <label class="rch-ousearch-field">${glyph('search')}<span class="visually-hidden">Chercher une OU par son nom dans l’annuaire</span>
        <input type="search" maxlength="100" autocomplete="off" spellcheck="false" placeholder="Nom ou chemin d’une OU, dans l’annuaire…"></label>
      <button class="btn ghost icon sm rch-ousearch-x" type="button" aria-label="Fermer la recherche d’OU">${glyph('x')}</button>
      <ul class="rch-ousearch-list" role="listbox" aria-label="OU trouvées"></ul>
      <p class="rch-ousearch-note"></p>
    </div>
    <div class="rch-tree"></div>
    <footer class="rch-side-foot">
      <label class="rch-depth" data-tip="Sous-arbre ou enfants directs, pour la liste de l’OU"><input class="switch" type="checkbox" role="switch"${st.subtree ? ' checked' : ''}><span>Inclure les sous-OU</span></label>
      <button class="btn sm rch-browse" type="button" disabled>${glyph('rows')}<span>Afficher le contenu</span></button>
    </footer>
  </div>`;

  const pinBtn = host.querySelector('.rch-pin');
  const menuBtn = host.querySelector('.rch-side-menu');
  const favs = host.querySelector('.rch-favs');
  const favList = host.querySelector('.rch-favs-list');
  const favHead = host.querySelector('.rch-favs-head');
  const browseBtn = host.querySelector('.rch-browse');
  const depth = /** @type {HTMLInputElement} */ (host.querySelector('.rch-depth input'));
  const ouSearch = host.querySelector('.rch-ousearch');
  const ouInput = /** @type {HTMLInputElement} */ (ouSearch.querySelector('input'));
  const ouList = ouSearch.querySelector('.rch-ousearch-list');
  const ouNote = ouSearch.querySelector('.rch-ousearch-note');

  // The number of objects of the branch (sub-OUs included), its main kind first: workstations, accounts, then groups.
  const hintOf = (c) => {
    if (!c) return '';
    if (c.computers > 0) return int(c.computers);
    if (c.users > 0) return int(c.users);
    if (c.groups > 0) return int(c.groups);
    return '';
  };
  const starred = new Set();
  const star = (dn) => { if (o.isPinned(dn)) { starred.add(dn); return '★ '; } return ''; };
  const ouNode = (e) => ({
    id: e.dn, label: e.name, icon: 'ou', hint: `${star(e.dn)}${hintOf(e.counts)}`, leaf: !e.hasChildren,
    data: { kind: 'ou', dn: e.dn, name: e.name, path: e.path, counts: e.counts },
  });

  async function load(node) {
    const kind = node.data?.kind;
    if (kind === 'root') {
      const [ous, containers] = await Promise.all([
        ctx.call('directory.ou.children', { dn: null }),
        ctx.call('search.containers').catch((err) => { console.error(err); return []; }),
      ]);
      const visible = containers.filter((c) => !c.system).map((c) => ({
        id: c.dn, label: c.name, icon: 'folder', hint: int(c.objects), leaf: true,
        data: { kind: 'container', dn: c.dn, name: c.name, path: pathOf(c.dn, o.dns) },
      }));
      const system = containers.filter((c) => c.system);
      const group = system.length ? [{
        id: SYSTEM_ID, label: 'Conteneurs système', icon: 'layers', hint: int(system.length), selectable: false,
        data: { kind: 'system' },
        children: system.map((c) => ({ id: c.dn, label: c.name, icon: 'folder', hint: int(c.objects), leaf: true, data: { kind: 'container', dn: c.dn, name: c.name, path: pathOf(c.dn, o.dns) } })),
      }] : [];
      remember(node.id);
      return [...ous.children.map(ouNode), ...visible, ...group];
    }
    if (kind === 'ou') {
      const res = await ctx.call('directory.ou.children', { dn: node.id });
      remember(node.id);
      return res.children.map(ouNode);
    }
    return [];
  }

  function remember(dn) {
    if (st.restoring || dn === o.root) return;
    st.loaded.add(dn);
    if (st.loaded.size > MEMORY_MAX) st.loaded.delete(st.loaded.values().next().value);
    save();
  }

  const save = debounce(() => writeLayout(memoryKey, { v: 1, selected: st.selected?.data?.dn ?? null, expanded: [...st.loaded], subtree: st.subtree }), 300);

  const tree = createTree(host.querySelector('.rch-tree'), {
    label: 'Unités d’organisation du domaine',
    roots: [{ id: o.root, label: o.dns, icon: 'domain', hint: '', data: { kind: 'root', dn: o.root, name: o.dns, path: o.dns } }],
    load,
    height: 'fill',
    searchPlaceholder: 'Filtrer les branches déjà lues…',
    onSelect: (node, how) => {
      st.selected = node;
      paint();
      save();
      o.onSelect(node, how);
    },
    onActivate: (node) => { if (node.data?.dn) o.onBrowse(node.data.dn, node.data.name, st.subtree); },
    contextMenu: (node) => treeMenu(node),
  });

  // ---------- Favourites ----------

  function paintFavorites() {
    host.querySelector('.rch-favs-n').textContent = int(st.favorites.length);
    favs.classList.toggle('none', st.favorites.length === 0);
    favList.innerHTML = st.favorites.map((f, n) => `<li class="rch-fav" data-dn="${esc(f.dn)}" data-j="${Math.min(n, 12)}" draggable="true">
      <button class="rch-fav-main" type="button" data-open="${n}" data-tip="${esc(f.path)}${f.subtree ? '' : ' · enfants directs'}${f.type !== 'all' ? ` · ${esc(f.type)}` : ''}">
        <span class="rch-fav-star">${glyph('star')}</span><span class="rch-fav-label">${esc(f.label)}</span>${f.term ? `<span class="rch-fav-term">${esc(f.term)}</span>` : ''}</button>
      <button class="rch-fav-x" type="button" data-unpin="${esc(f.dn)}" aria-label="Retirer ${esc(f.label)} des favoris" data-tip="Retirer des favoris">${glyph('x')}</button>
    </li>`).join('');
    favList.querySelectorAll('[data-j]').forEach((li) => li.style.setProperty('--j', li.dataset.j));
  }

  favHead.addEventListener('click', () => {
    const open = favHead.getAttribute('aria-expanded') !== 'true';
    favHead.setAttribute('aria-expanded', String(open));
    favs.classList.toggle('folded', !open);
  });
  favList.addEventListener('click', (e) => {
    const t = e.target instanceof Element ? e.target : null;
    const x = t?.closest('[data-unpin]');
    if (x) { o.onUnpin(x.dataset.unpin); return; }
    const open = t?.closest('[data-open]');
    if (open) o.onFavorite(st.favorites[Number(open.dataset.open)]);
  });
  // Keyboard reordering: Alt ↑ / Alt ↓ on a favourite moves it (improvement of FO-04).
  favList.addEventListener('keydown', (e) => {
    const li = e.target instanceof Element ? e.target.closest('.rch-fav') : null;
    if (!li || !e.altKey || (e.key !== 'ArrowUp' && e.key !== 'ArrowDown')) return;
    e.preventDefault();
    const at = st.favorites.findIndex((f) => f.dn === li.dataset.dn);
    const to = e.key === 'ArrowUp' ? at - 1 : at + 1;
    if (at < 0 || to < 0 || to >= st.favorites.length) return;
    o.onMove(li.dataset.dn, to);
  });
  let dragged = null;
  favList.addEventListener('dragstart', (e) => {
    const li = e.target instanceof Element ? e.target.closest('.rch-fav') : null;
    if (!li) return;
    dragged = li.dataset.dn;
    li.classList.add('dragging');
    e.dataTransfer?.setData('text/plain', 'favori');
  });
  favList.addEventListener('dragover', (e) => { if (dragged) e.preventDefault(); });
  favList.addEventListener('drop', (e) => {
    e.preventDefault();
    const li = e.target instanceof Element ? e.target.closest('.rch-fav') : null;
    if (dragged && li && li.dataset.dn !== dragged) o.onMove(dragged, st.favorites.findIndex((f) => f.dn === li.dataset.dn));
  });
  favList.addEventListener('dragend', () => { dragged = null; favList.querySelectorAll('.dragging').forEach((x) => x.classList.remove('dragging')); });

  // ---------- Selection, depth, menu ----------

  const usable = (node) => node?.data && ['ou', 'container', 'root'].includes(node.data.kind);

  function paint() {
    const node = st.selected;
    const dn = node?.data?.dn;
    const pinnable = node?.data?.kind === 'ou';
    const pinned = pinnable && o.isPinned(dn);
    pinBtn.disabled = !pinnable;
    pinBtn.setAttribute('aria-pressed', String(!!pinned));
    pinBtn.setAttribute('aria-label', pinned ? 'Retirer cette OU des favoris' : 'Épingler cette OU');
    pinBtn.dataset.tip = !pinnable ? 'Choisissez une OU pour l’épingler' : pinned ? 'Retirer des favoris' : `Épingler ${quote(node.data.name)}`;
    browseBtn.disabled = !usable(node);
    browseBtn.querySelector('span').textContent = usable(node)
      ? `Afficher le contenu de ${node.data.kind === 'root' ? 'tout le domaine' : quote(node.data.name)}` : 'Afficher le contenu';
  }

  pinBtn.addEventListener('click', () => { if (st.selected?.data?.kind === 'ou') o.onPin(st.selected, !o.isPinned(st.selected.data.dn)); });
  browseBtn.addEventListener('click', () => { const d = st.selected?.data; if (d?.dn) o.onBrowse(d.dn, d.name, st.subtree); });
  depth.addEventListener('change', () => {
    st.subtree = depth.checked;
    save();
    announce(st.subtree ? 'Liste de l’OU : sous-OU incluses.' : 'Liste de l’OU : enfants directs seulement.');
  });

  function copyDn(dn, readable) {
    const text = readable ? pathOf(dn, o.dns) : dn;
    writeClipboard(text).then((ok) => toast(ok ? `${readable ? 'Chemin lisible' : 'Chemin LDAP (DN)'} copié.` : `Copie impossible${COLON}sélectionnez le chemin à la main.`, { tone: ok ? 'ok' : 'warn', life: 2600 }));
  }

  function treeMenu(node) {
    const d = node?.data ?? {};
    const isOu = d.kind === 'ou';
    const has = !!d.dn;
    const pinned = isOu && o.isPinned(d.dn);
    return [
      { heading: d.name ?? 'Branche' },
      { label: 'Afficher le contenu de cette branche', icon: 'rows', kbd: 'Entrée', disabled: !has, reason: 'Choisissez une OU ou un conteneur.', run: () => o.onBrowse(d.dn, d.name, st.subtree) },
      { label: 'Actualiser l’arborescence', icon: 'refresh', kbd: 'F5', run: () => refreshTree(node) },
      '-',
      { label: pinned ? 'Retirer des favoris' : 'Épingler cette OU', icon: 'star', disabled: !isOu, reason: 'Seule une OU s’épingle.', run: () => o.onPin(node, !pinned) },
      { label: 'Copier le chemin (DN)', icon: 'copy', disabled: !has, reason: 'Aucun chemin.', run: () => copyDn(d.dn, false) },
      { label: 'Copier le chemin lisible', icon: 'copy', disabled: !has, reason: 'Aucun chemin.', run: () => copyDn(d.dn, true) },
      '-',
      { label: 'Nouveau dans cette branche', icon: 'plus', items: [
        { label: 'Unité d’organisation…', icon: 'ou', kind: 'write', disabled: !isOu && d.kind !== 'root' || o.readOnly(), reason: o.readOnly() ? 'Lecture seule.' : 'Choisissez une OU.',
          run: () => o.onNavigate('fiche', { dn: d.dn, open: 'createOu' }) },
      ] },
      { label: 'Analyser les droits sur cette branche', icon: 'shield', disabled: !has, reason: 'Choisissez une OU.', run: () => o.onNavigate('fiche', { dn: d.dn, open: 'rights' }) },
    ];
  }

  async function refreshTree(node) {
    try {
      if (node?.data?.kind === 'ou' || node?.data?.kind === 'root') await tree.reload(node.id);
      else await tree.reload(o.root);
      announce('Arborescence relue.');
    } catch (err) {
      toast(`Arborescence non relue${COLON}${errorText(err)}`, { tone: 'warn' });
    }
  }

  menuBtn.addEventListener('click', () => {
    const node = st.selected;
    const d = node?.data ?? {};
    openMenu(menuBtn, [
      { heading: 'Profondeur de la liste' },
      { label: 'Inclure les sous-OU', radio: 'depth', checked: st.subtree, run: () => { st.subtree = true; depth.checked = true; save(); } },
      { label: 'Enfants directs seulement', radio: 'depth', checked: !st.subtree, run: () => { st.subtree = false; depth.checked = false; save(); } },
      '-',
      { label: 'Lister tout le domaine', icon: 'domain', run: () => o.onBrowse(o.root, o.dns, true) },
      { label: 'Chercher une OU dans l’annuaire…', icon: 'search', run: () => openOuSearch() },
      { label: d.kind === 'ou' && o.isPinned(d.dn) ? 'Retirer des favoris' : 'Épingler l’OU choisie', icon: 'star', disabled: d.kind !== 'ou', reason: 'Choisissez une OU.', run: () => o.onPin(node, !o.isPinned(d.dn)) },
      { label: 'Copier le chemin (DN)', icon: 'copy', disabled: !d.dn, reason: 'Choisissez une OU.', run: () => copyDn(d.dn, false) },
      '-',
      { label: 'Actualiser l’arborescence', icon: 'refresh', kbd: 'F5', run: () => refreshTree(node) },
    ], { label: 'Menu de l’arborescence', placement: 'bottom-end' });
  });

  // ---------- Search of an OU in the directory (explicit read, directory.ou.search) ----------

  function openOuSearch() {
    ouSearch.hidden = false;
    ouSearch.classList.remove('in');
    void ouSearch.offsetWidth;
    ouSearch.classList.add('in');
    ouInput.focus();
  }
  const runOuSearch = debounce(async () => {
    const text = ouInput.value.trim();
    if (text.length < 2) { ouList.innerHTML = ''; ouNote.textContent = 'Deux caractères au moins. La recherche lit l’annuaire à chaque pause de la saisie.'; return; }
    ouSearch.setAttribute('aria-busy', 'true');
    try {
      const found = await ctx.call('directory.ou.search', { text });
      if (ouInput.value.trim() !== text) return;
      const needle = fold(text);
      ouList.innerHTML = found.map((e, n) => `<li role="option" class="rch-ou-hit" data-dn="${esc(e.dn)}" data-j="${Math.min(n, 12)}" tabindex="0">${glyph('ou')}<span><b>${highlight(e.name, needle)}</b><small>${highlight(e.path, needle)}</small></span></li>`).join('');
      ouList.querySelectorAll('[data-j]').forEach((li) => li.style.setProperty('--j', li.dataset.j));
      ouNote.textContent = found.length >= 50 ? 'Cinquante OU au plus : d’autres peuvent correspondre, affinez la recherche.'
        : found.length ? `${count(found.length, 'OU trouvée', 'OU trouvées')}. Un clic la révèle dans l’arbre.` : 'Aucune OU ne porte ce nom ou ce chemin dans le domaine.';
    } catch (err) {
      ouNote.textContent = `Recherche impossible${COLON}${errorText(err)}`;
    } finally {
      ouSearch.removeAttribute('aria-busy');
    }
  }, 320);
  ouInput.addEventListener('input', runOuSearch);
  ouInput.addEventListener('keydown', (e) => {
    if (e.key === 'Escape') { e.preventDefault(); e.stopPropagation(); ouSearch.hidden = true; tree.focus(); }
    if (e.key === 'ArrowDown') { e.preventDefault(); ouList.querySelector('li')?.focus(); }
  });
  ouSearch.querySelector('.rch-ousearch-x').addEventListener('click', () => { ouSearch.hidden = true; tree.focus(); });
  const pickHit = (li) => { ouSearch.hidden = true; reveal(li.dataset.dn, true); };
  ouList.addEventListener('click', (e) => { const li = e.target instanceof Element ? e.target.closest('.rch-ou-hit') : null; if (li) pickHit(li); });
  ouList.addEventListener('keydown', (e) => {
    const li = e.target instanceof Element ? e.target.closest('.rch-ou-hit') : null;
    if (!li) return;
    if (e.key === 'Enter') { e.preventDefault(); pickHit(li); }
    if (e.key === 'ArrowDown') { e.preventDefault(); li.nextElementSibling?.focus(); }
    if (e.key === 'ArrowUp') { e.preventDefault(); (li.previousElementSibling ?? ouInput).focus(); }
  });

  // ---------- Reveal and memory ----------

  /** DNs from the root down to dn (RDN boundaries, escapes kept). */
  function chainOf(dn) {
    const parts = splitDn(dn);
    const rootLen = splitDn(o.root).length;
    const chain = [o.root];
    for (let k = parts.length - rootLen - 1; k >= 0; k--) chain.push(parts.slice(k).join(','));
    return chain;
  }

  /** Opens the tree step by step down to an OU (each missing branch is read once) and selects it. */
  async function reveal(dn, notify = false) {
    if (!dn) return false;
    if (sameDn(dn, o.root)) { tree.select(o.root); return true; }
    const ok = await tree.reveal(chainOf(dn)).catch((err) => { console.error(err); return false; });
    if (ok) {
      st.selected = tree.getSelected();
      paint();
      if (notify && st.selected) o.onSelect(st.selected, 'pointer');
    } else if (notify) {
      toast(`OU ${quote(leafOf(dn))} introuvable dans l’arbre${COLON}elle a pu être déplacée ou supprimée, ou une branche n’a pas pu être lue.`, { tone: 'warn' });
    }
    return ok;
  }

  async function start() {
    await tree.expand(o.root);
    // Restores the remembered branches and OU (Domenia 1 RCH-019); nothing is listed before the operator asks.
    st.restoring = true;
    try {
      for (const dn of [...st.loaded].sort((a, b) => splitDn(a).length - splitDn(b).length)) {
        if (!dn.toLowerCase().endsWith(o.root.toLowerCase())) continue;
        await tree.expand(dn).catch(() => {});
      }
      if (memory.selected && typeof memory.selected === 'string' && memory.selected.toLowerCase().endsWith(o.root.toLowerCase())) {
        const ok = await reveal(memory.selected);
        if (ok && st.selected) o.onSelect(st.selected, 'restore');
        else if (!ok) o.onSelect(null, 'missing');
      }
    } finally {
      st.restoring = false;
    }
  }

  paint();
  const ready = start().catch((err) => console.error(err));

  return {
    tree,
    ready,
    reveal,
    get subtree() { return st.subtree; },
    selected: () => st.selected,
    /** Favourites of the domain (search.memory), with their distinct labels. */
    setFavorites(list) {
      st.favorites = Array.isArray(list) ? list : [];
      paintFavorites();
      paint();
    },
    /** Paints the stars of the pinned OUs in the branches already read. */
    refreshStars() {
      // The kit tree keeps the node objects it was given: their hint is updated in place, then the tree repaints.
      const dns = new Set([...starred, ...st.favorites.map((f) => f.dn)]);
      starred.clear();
      for (const dn of dns) {
        const node = tree.pathOf(dn).at(-1);
        if (node?.data?.kind === 'ou') node.hint = `${star(dn)}${hintOf(node.data.counts)}`;
      }
      tree.setFilter(host.querySelector('.k-tree-search input')?.value ?? '');
      paint();
    },
    destroy() { save.flush(); runOuSearch.cancel(); tree.destroy(); host.replaceChildren(); },
  };
}
