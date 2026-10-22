// Rechercher · OU panel on the left: pinned OU favourites above a lazy tree (one level read per opening, F5 to read a
// branch again), containers of the root with the system containers folded apart, local filter of the branches already
// read, search of an OU by name in the directory on request, depth switch, tree menu, memory of the tree per domain and a
// rail mode that gives its width to the list. The domain root only serves to navigate: listing the whole domain is an
// explicit choice of the menu. The restoration of the remembered branches stops at the first gesture of the operator,
// and an OU absent from its parent read again is never confused with a read that failed (RCH-003 to RCH-021).
import { glyph } from '../../kit/glyphs.js';
import { openMenu } from '../../kit/menu.js';
import { openDialog } from '../../kit/dialog.js';
import { createTree } from '../../kit/tree.js';
import { readLayout, writeLayout, writeClipboard, debounce, highlight } from '../../kit/util.js';
import { announce, toast, errorText } from '../../ui.js';
import { esc, fold, int, count, quote, COLON, NBSP, splitDn, leafOf, pathOf, parentDn, sameDn } from './text.js';

const MEMORY_MAX = 128;
const SYSTEM_ID = '#system';

/**
 * @param {HTMLElement} host
 * @param {any} ctx
 * @param {{ root: string, dns: string, onSelect: (node: any, how: string) => void, onBrowse: (dn: string, name: string, subtree: boolean) => void,
 *   onFavorite: (fav: any) => void, onPin: (node: any, pinned: boolean) => void, onUnpin: (dn: string) => void, onMove: (dn: string, index: number) => void,
 *   isPinned: (dn: string) => boolean, onNavigate: (route: string, params: object) => void, readOnly: () => boolean,
 *   onRestoreIssue: (issue: {kind: 'absent'|'failed', dn: string, name: string, parent: string, parentName: string, message: string}) => void,
 *   onFold: (folded: boolean) => void }} o
 */
export function createSide(host, ctx, o) {
  const memoryKey = `rechercher.tree.${o.root.toLowerCase()}`;
  const memory = readLayout(memoryKey) ?? {};
  const ui = readLayout('rechercher.tree.ui') ?? {};
  const st = {
    subtree: memory.subtree !== false,
    selected: null,
    favorites: [],
    loaded: new Set(Array.isArray(memory.expanded) ? memory.expanded.filter((d) => typeof d === 'string').slice(0, MEMORY_MAX) : []),
    restoring: false,
    abort: false,
    folded: ui.folded === true,
    auto: typeof ui.folded !== 'boolean',
    remembered: typeof memory.selected === 'string' ? memory.selected : null,
  };
  // Outcome of each branch read in this session: 'ok', or the error of a read that did not succeed (never an absence).
  const reads = new Map();

  host.innerHTML = `<div class="rch-side-in">
    <header class="rch-panel-head">
      <button class="btn ghost icon sm rch-side-fold" type="button" aria-expanded="${!st.folded}" aria-label="${st.folded ? 'Déplier l’arborescence' : 'Replier l’arborescence'}" data-tip="${st.folded ? 'Déplier l’arborescence' : 'Replier l’arborescence en rail'}">${glyph('tree')}</button>
      <h2 class="rch-panel-title">Arborescence</h2>
      <button class="btn ghost icon sm rch-pin" type="button" aria-pressed="false" aria-label="Épingler cette OU" data-tip="Épingler l’OU choisie" disabled>${glyph('star')}</button>
      <button class="btn ghost icon sm rch-side-menu" type="button" aria-haspopup="menu" aria-expanded="false" aria-label="Menu de l’arborescence" data-tip="Profondeur, domaine entier, chemin, actualiser">${glyph('more')}</button>
    </header>
    <div class="rch-rail" aria-hidden="true"><span class="rch-rail-t">Arborescence</span><span class="rch-rail-n" data-tip="OU favorites">${glyph('star')}<b class="rch-rail-favs">0</b></span></div>
    <section class="rch-favs" aria-label="OU favorites">
      <button class="rch-favs-head" type="button" aria-expanded="true"><span>${glyph('star')}Favoris</span><span class="rch-favs-n">0</span>${glyph('chevronDown', 'rch-favs-chev')}</button>
      <ol class="rch-favs-list" role="list"></ol>
      <p class="rch-favs-empty">Épinglez une OU (${glyph('star')}) pour la retrouver ici en un clic.</p>
    </section>
    <div class="rch-ousearch" hidden>
      <label class="rch-ousearch-field">${glyph('search')}<span class="visually-hidden">Chercher une OU par son nom dans l’annuaire</span>
        <input type="search" maxlength="100" autocomplete="off" spellcheck="false" placeholder="Nom ou chemin d’une OU…"></label>
      <button class="btn ghost icon sm rch-ousearch-x" type="button" aria-label="Fermer la recherche d’OU">${glyph('x')}</button>
      <ul class="rch-ousearch-list" role="listbox" aria-label="OU trouvées"></ul>
      <p class="rch-ousearch-note">Saisissez un nom puis Entrée${COLON}la recherche lit l’annuaire seulement sur ce geste.</p>
    </div>
    <div class="rch-tree"></div>
    <footer class="rch-side-foot">
      <label class="rch-depth" data-tip="Sous-arbre ou enfants directs, pour la liste de l’OU"><input class="switch" type="checkbox" role="switch"${st.subtree ? ' checked' : ''}><span>Inclure les sous-OU</span></label>
      <button class="btn sm rch-browse" type="button" disabled>${glyph('rows')}<span class="rch-browse-t"><span>Afficher le contenu</span><small></small></span><span class="rch-net-dot" aria-hidden="true"></span></button>
    </footer>
  </div>`;

  const foldBtn = host.querySelector('.rch-side-fold');
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
  const containerNode = (c) => ({
    id: c.dn, label: c.name, icon: 'folder', hint: c.objects >= 0 ? int(c.objects) : '', leaf: true,
    data: { kind: 'container', dn: c.dn, name: c.name, path: pathOf(c.dn, o.dns) },
  });

  async function load(node) {
    const kind = node.data?.kind;
    try {
      if (kind === 'root') {
        // Containers come without their counts: counting them would read each one in directory mode (one more request each).
        const [ous, containers] = await Promise.all([
          ctx.call('directory.ou.children', { dn: null }),
          ctx.call('search.containers', {}).catch((err) => { console.error(err); return []; }),
        ]);
        const system = containers.filter((c) => c.system);
        const group = system.length ? [{
          id: SYSTEM_ID, label: 'Conteneurs système', icon: 'layers', hint: int(system.length), selectable: false,
          data: { kind: 'system' }, children: system.map(containerNode),
        }] : [];
        reads.set(node.id, 'ok');
        remember(node.id);
        return [...ous.children.map(ouNode), ...containers.filter((c) => !c.system).map(containerNode), ...group];
      }
      if (kind === 'ou') {
        const res = await ctx.call('directory.ou.children', { dn: node.id });
        reads.set(node.id, 'ok');
        remember(node.id);
        return res.children.map(ouNode);
      }
      return [];
    } catch (err) {
      reads.set(node.id, errorText(err));
      throw err;
    }
  }

  function remember(dn) {
    if (st.restoring || dn === o.root) return;
    st.loaded.add(dn);
    if (st.loaded.size > MEMORY_MAX) st.loaded.delete(st.loaded.values().next().value);
    save();
  }

  const save = debounce(() => writeLayout(memoryKey, { v: 1, selected: st.selected?.data?.dn ?? st.remembered ?? null, expanded: [...st.loaded], subtree: st.subtree }), 300);

  const tree = createTree(host.querySelector('.rch-tree'), {
    label: 'Unités d’organisation du domaine',
    // The domain only serves to navigate (kit rule): « Lister tout le domaine » stays an explicit choice of the menu.
    roots: [{ id: o.root, label: o.dns, icon: 'domain', hint: '', selectable: false, data: { kind: 'root', dn: o.root, name: o.dns, path: o.dns } }],
    load,
    height: 'fill',
    searchPlaceholder: 'Filtrer les branches lues…',
    onSelect: (node, how) => {
      st.selected = node;
      st.remembered = node?.data?.dn ?? st.remembered;
      paint();
      save();
      o.onSelect(node, how);
    },
    onActivate: (node) => { if (node.data?.dn && node.data.kind !== 'root') o.onBrowse(node.data.dn, node.data.name, st.subtree); },
    contextMenu: (node) => treeMenu(node),
  });

  // ---------- Rail ----------

  function setFolded(on, user = true, persist = true) {
    st.folded = on;
    if (persist) { writeLayout('rechercher.tree.ui', { folded: on }); st.auto = false; }
    host.classList.toggle('railed', on);
    foldBtn.setAttribute('aria-expanded', String(!on));
    const t = on ? 'Déplier l’arborescence' : 'Replier l’arborescence en rail';
    foldBtn.setAttribute('aria-label', on ? 'Déplier l’arborescence' : 'Replier l’arborescence');
    foldBtn.dataset.tip = t;
    o.onFold(on);
    if (user) announce(on ? 'Arborescence repliée : la liste prend sa largeur.' : 'Arborescence dépliée.');
  }
  foldBtn.addEventListener('click', () => setFolded(!st.folded));
  host.querySelector('.rch-rail').addEventListener('click', () => setFolded(false));

  // ---------- Favourites ----------

  function paintFavorites() {
    host.querySelector('.rch-favs-n').textContent = int(st.favorites.length);
    host.querySelector('.rch-rail-favs').textContent = int(st.favorites.length);
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

  const usable = (node) => node?.data && ['ou', 'container'].includes(node.data.kind);

  function paint() {
    const node = st.selected;
    const dn = node?.data?.dn;
    const pinnable = node?.data?.kind === 'ou';
    const pinned = pinnable && o.isPinned(dn);
    pinBtn.disabled = !pinnable;
    pinBtn.setAttribute('aria-pressed', String(!!pinned));
    pinBtn.setAttribute('aria-label', pinned ? 'Retirer cette OU des favoris' : 'Épingler cette OU');
    pinBtn.dataset.tip = !pinnable ? 'Choisissez une OU pour l’épingler' : pinned ? 'Retirer des favoris' : `Épingler ${quote(node.data.name)}`;
    // Without a choice in the tree, the working OU is the default (RCH-005, decision of 21/10: default of the sections without a
    // choice of their own, as Domenia 1): « Afficher le contenu » lists it.
    const fallback = !usable(node) ? o.defaultOu?.() ?? null : null;
    browseBtn.disabled = !usable(node) && !fallback;
    // Two lines: the action, then the OU and its depth (the full name always shows, it wraps instead of being cut).
    browseBtn.querySelector('.rch-browse-t small').textContent = usable(node) ? `${quote(node.data.name)} · ${st.subtree ? 'sous-OU incluses' : 'enfants directs'}`
      : fallback ? `OU de travail${COLON}${quote(fallback.name)} · ${st.subtree ? 'sous-OU incluses' : 'enfants directs'}` : 'Choisissez une OU dans l’arbre';
    browseBtn.dataset.tip = usable(node) ? `Lit le contenu de ${quote(node.data.name)} dans l’annuaire (geste explicite)`
      : fallback ? `Lit le contenu de l’OU de travail ${quote(fallback.name)} dans l’annuaire (geste explicite)` : '';
  }

  pinBtn.addEventListener('click', () => { if (st.selected?.data?.kind === 'ou') o.onPin(st.selected, !o.isPinned(st.selected.data.dn)); });
  browseBtn.addEventListener('click', () => {
    const d = usable(st.selected) ? st.selected.data : null;
    const target = d ?? o.defaultOu?.() ?? null;
    if (target?.dn) o.onBrowse(target.dn, target.name, st.subtree);
  });
  depth.addEventListener('change', () => {
    st.subtree = depth.checked;
    save();
    paint();
    announce(st.subtree ? 'Liste de l’OU : sous-OU incluses.' : 'Liste de l’OU : enfants directs seulement.');
  });

  /** Copies a DN; when the clipboard refuses, the DN is shown selected in a dialog to copy by hand (RCH-013). */
  function copyDn(dn, readable) {
    const text = readable ? pathOf(dn, o.dns) : dn;
    writeClipboard(text).then((ok) => {
      if (ok) { toast(`${readable ? 'Chemin lisible' : 'Chemin LDAP (DN)'} copié.`, { tone: 'ok', life: 2600 }); return; }
      const dlg = openDialog({
        title: 'Copie impossible', subtitle: 'Le presse-papiers est indisponible', icon: 'copy', size: 'md',
        body: `<div data-page="rechercher" class="rch-manual"><p>Sélectionnez le chemin puis copiez-le avec <kbd>Ctrl</kbd> <kbd>C</kbd>.</p><textarea class="input mono" readonly rows="3" aria-label="Chemin à copier"></textarea></div>`,
        actions: [{ id: 'close', label: 'Fermer', safe: true, primary: true }],
      });
      const area = dlg.body.querySelector('textarea');
      area.value = text;
      requestAnimationFrame(() => { area.focus(); area.select(); });
    });
  }

  function treeMenu(node) {
    const d = node?.data ?? {};
    const isOu = d.kind === 'ou';
    const has = !!d.dn && d.kind !== 'root';
    const pinned = isOu && o.isPinned(d.dn);
    return [
      { heading: d.name ?? 'Branche' },
      { label: 'Afficher le contenu de cette branche', icon: 'rows', kbd: 'Entrée', kind: 'network', hint: 'annuaire', disabled: !has, reason: d.kind === 'root' ? 'Le domaine se liste par « Lister tout le domaine ».' : 'Choisissez une OU ou un conteneur.', run: () => o.onBrowse(d.dn, d.name, st.subtree) },
      { label: 'Actualiser cette branche', icon: 'refresh', kbd: 'F5', run: () => refreshTree(node) },
      '-',
      { label: pinned ? 'Retirer des favoris' : 'Épingler cette OU', icon: 'star', disabled: !isOu, reason: 'Seule une OU s’épingle.', run: () => o.onPin(node, !pinned) },
      { label: 'Copier le chemin (DN)', icon: 'copy', disabled: !d.dn, reason: 'Aucun chemin.', run: () => copyDn(d.dn, false) },
      { label: 'Copier le chemin lisible', icon: 'copy', disabled: !d.dn, reason: 'Aucun chemin.', run: () => copyDn(d.dn, true) },
      '-',
      { label: 'Analyser les droits sur cette branche', icon: 'shield', disabled: !has, reason: 'Choisissez une OU.', run: () => o.onNavigate('fiche', { dn: d.dn, open: 'rights' }) },
      { label: 'Nouvelle unité d’organisation…', icon: 'ou', kind: 'write', hint: 'écriture', disabled: !(isOu || d.kind === 'root') || o.readOnly(), reason: o.readOnly() ? 'Lecture seule.' : 'Choisissez une OU.',
        run: () => o.onNavigate('fiche', { dn: d.dn, open: 'createOu' }) },
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
      { label: 'Inclure les sous-OU', radio: 'depth', checked: st.subtree, run: () => { st.subtree = true; depth.checked = true; save(); paint(); } },
      { label: 'Enfants directs seulement', radio: 'depth', checked: !st.subtree, run: () => { st.subtree = false; depth.checked = false; save(); paint(); } },
      '-',
      { label: 'Lister tout le domaine…', icon: 'domain', kind: 'network', hint: 'annuaire', run: () => o.onBrowse(o.root, o.dns, true) },
      { label: 'Chercher une OU dans l’annuaire…', icon: 'search', run: () => openOuSearch() },
      { label: d.kind === 'ou' && o.isPinned(d.dn) ? 'Retirer des favoris' : 'Épingler l’OU choisie', icon: 'star', disabled: d.kind !== 'ou', reason: 'Choisissez une OU.', run: () => o.onPin(node, !o.isPinned(d.dn)) },
      { label: 'Copier le chemin (DN)', icon: 'copy', disabled: !d.dn, reason: 'Choisissez une OU.', run: () => copyDn(d.dn, false) },
      '-',
      { label: 'Actualiser l’arborescence', icon: 'refresh', kbd: 'F5', run: () => refreshTree(node ?? { id: o.root, data: { kind: 'root' } }) },
    ], { label: 'Menu de l’arborescence', placement: 'bottom-end' });
  });

  // ---------- Search of an OU in the directory (explicit read, directory.ou.search) ----------

  function openOuSearch() {
    if (st.folded) setFolded(false, false);
    ouSearch.hidden = false;
    ouSearch.classList.remove('in');
    void ouSearch.offsetWidth;
    ouSearch.classList.add('in');
    ouInput.focus();
  }
  // Typing never reads the directory (Domenia 1 RCH-009, explicit read): Entrée starts the search (directory.ou.search,
  // NetworkRead in directory mode); the filter of the branches already read stays local, as you type.
  const runOuSearch = async () => {
    const text = ouInput.value.trim();
    if (text.length < 2) { ouList.innerHTML = ''; ouNote.textContent = `Deux caractères au moins, puis Entrée${COLON}la recherche lit l’annuaire seulement sur ce geste.`; return; }
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
  };
  ouInput.addEventListener('input', () => {
    const text = ouInput.value.trim();
    ouList.innerHTML = '';
    ouNote.textContent = text.length < 2 ? `Deux caractères au moins, puis Entrée${COLON}la recherche lit l’annuaire seulement sur ce geste.` : 'Entrée lance la recherche dans l’annuaire.';
  });
  ouInput.addEventListener('keydown', (e) => {
    if (e.key === 'Enter') { e.preventDefault(); runOuSearch(); return; }
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

  /**
   * Opens the tree step by step down to an OU (each missing branch is read once) and selects it. The outcome tells an OU
   * absent from its parent read again (« absent ») from a read that did not succeed (« failed »: delay, refusal, branch
   * not read): Domenia 1 RCH-015, a failed read is never an absence.
   * @returns {Promise<{ok: boolean, kind?: 'absent'|'failed', parent?: string, message?: string}>}
   */
  async function locate(dn, aborted = () => st.restoring && st.abort, stopped = 'restauration interrompue par votre geste') {
    if (!dn) return { ok: false, kind: 'absent', parent: o.root };
    if (sameDn(dn, o.root)) return { ok: true };
    const chain = chainOf(dn);
    for (let n = 0; n < chain.length - 1; n++) {
      const id = chain[n];
      if (!tree.pathOf(id).length) return { ok: false, kind: 'absent', parent: n > 0 ? chain[n - 1] : o.root };
      if (aborted()) return { ok: false, kind: 'stopped', parent: id, message: stopped };
      await tree.expand(id);
      const outcome = reads.get(id);
      if (outcome && outcome !== 'ok') return { ok: false, kind: 'failed', parent: id, message: outcome };
      if (!outcome && id !== o.root && !tree.pathOf(id).length) return { ok: false, kind: 'failed', parent: id, message: 'branche non lue' };
    }
    if (!tree.pathOf(dn).length) return { ok: false, kind: 'absent', parent: chain.at(-2) ?? o.root };
    return { ok: tree.select(dn) };
  }

  /**
   * Reveals an OU in the tree (favourite, personal view, « OU parente », search of an OU). Each call has its own stop flag,
   * armed by the gestures of the operator while it opens the branches (RCH-020): a click or a key elsewhere stops this reveal
   * only, never the next ones. Without notify, the page is told (onReveal) so its chosen OU follows the tree, without a read.
   */
  async function reveal(dn, notify = false) {
    const call = { aborted: false };
    const stop = (e) => { if (!(e instanceof KeyboardEvent) || !['Shift', 'Control', 'Alt', 'Meta'].includes(e.key)) call.aborted = true; };
    // The gesture that asked for the reveal is over before it starts: only the next ones stop it.
    const arm = setTimeout(() => { document.addEventListener('pointerdown', stop, true); document.addEventListener('keydown', stop, true); }, 0);
    let res;
    try {
      res = await locate(dn, () => call.aborted, 'révélation interrompue par votre geste').catch((err) => { console.error(err); return { ok: false, kind: 'failed', parent: parentDn(dn), message: errorText(err) }; });
    } finally {
      clearTimeout(arm);
      document.removeEventListener('pointerdown', stop, true);
      document.removeEventListener('keydown', stop, true);
    }
    if (res.ok) {
      st.selected = tree.getSelected();
      paint();
      save();
      if (notify && st.selected) o.onSelect(st.selected, 'pointer');
      else if (st.selected) o.onReveal?.(st.selected);
      // A branch hidden by the filter of the tree is said (RCH-011): the OU is selected, the filter decides what is shown.
      const filter = host.querySelector('.k-tree-search input')?.value?.trim();
      if (filter && st.selected && !fold(st.selected.label ?? '').includes(fold(filter))) {
        toast(`OU ${quote(leafOf(dn))} sélectionnée, mais masquée par le filtre de l’arbre (${quote(filter)})${COLON}effacez le filtre pour la voir.`, { tone: 'info', life: 5200 });
      }
    } else if (res.kind === 'stopped') {
      announce(`Révélation de ${leafOf(dn)} interrompue par votre geste${NBSP}: rien d’autre n’est lu.`);
    } else if (notify) {
      toast(res.kind === 'absent'
        ? `OU ${quote(leafOf(dn))} absente de ${quote(leafOf(res.parent ?? o.root))} relue${COLON}elle a pu être déplacée ou supprimée.`
        : `OU ${quote(leafOf(dn))} non vérifiée${COLON}la lecture de ${quote(leafOf(res.parent ?? o.root))} n’a pas abouti (${res.message ?? 'délai ou refus'}). Ce n’est pas une absence.`, { tone: 'warn' });
    }
    return res.ok;
  }

  /** Restoration of the remembered OU (once per call): selects it without any list read, or reports why it could not. */
  async function restoreSelected() {
    const dn = st.remembered;
    if (!dn || !dn.toLowerCase().endsWith(o.root.toLowerCase())) return;
    const res = await locate(dn).catch((err) => ({ ok: false, kind: 'failed', parent: parentDn(dn), message: errorText(err) }));
    if (res.ok) {
      st.selected = tree.getSelected();
      paint();
      if (st.selected) o.onSelect(st.selected, 'restore');
      return;
    }
    if (res.kind === 'stopped') return;
    const parent = res.parent ?? o.root;
    o.onRestoreIssue({ kind: res.kind ?? 'failed', dn, name: leafOf(dn), parent, parentName: sameDn(parent, o.root) ? o.dns : leafOf(parent), message: res.message ?? '' });
  }

  async function start() {
    await tree.expand(o.root);
    // Restores the remembered branches and OU (Domenia 1 RCH-019); nothing is listed before the operator asks. The first
    // click or key press of the operator stops the restoration: he never waits for up to 128 branch reads.
    st.restoring = true;
    st.abort = false;
    const stop = (e) => { if (!(e instanceof KeyboardEvent) || !['Shift', 'Control', 'Alt', 'Meta'].includes(e.key)) st.abort = true; };
    document.addEventListener('pointerdown', stop, true);
    document.addEventListener('keydown', stop, true);
    try {
      for (const dn of [...st.loaded].sort((a, b) => splitDn(a).length - splitDn(b).length)) {
        if (st.abort) break;
        if (!dn.toLowerCase().endsWith(o.root.toLowerCase()) || !tree.pathOf(dn).length) continue;
        await tree.expand(dn);
      }
      if (!st.abort) await restoreSelected();
      else if (st.remembered) announce('Restauration de l’arborescence interrompue : rien n’est lu sans votre geste.');
    } finally {
      st.restoring = false;
      // The stop of the restoration belongs to it: later reveals (favourite, view, OU parente) are never refused because of it.
      st.abort = false;
      document.removeEventListener('pointerdown', stop, true);
      document.removeEventListener('keydown', stop, true);
    }
  }

  host.classList.toggle('railed', st.folded);
  paint();
  const ready = start().catch((err) => console.error(err));

  return {
    tree,
    ready,
    reveal,
    get subtree() { return st.subtree; },
    get folded() { return st.folded; },
    /** True while the operator never chose to fold or unfold the tree: a narrow screen may fold it for him. */
    get auto() { return st.auto; },
    setFolded,
    selected: () => st.selected,
    /** Restoration of the remembered OU again, once (« Réessayer » of the notice). */
    retryRestore: () => { st.abort = false; return restoreSelected(); },
    /** Forgets the remembered OU (« Ignorer » of the notice); the branches and the list stay as they are. */
    forgetRestore: () => { st.remembered = null; save(); save.flush(); },
    /** Branches read in this session (the ones a history step reopens without any read). */
    expandedSnapshot: () => [...reads].filter(([, v]) => v === 'ok').map(([k]) => k),
    /**
     * Reopens the branches of a history step that are already read, folds those opened since, selects its OU (RCH-045).
     * Returns the number of branches not read or no longer under their parent.
     */
    applyExpanded(list, selectDn) {
      const want = new Set(list ?? []);
      let missing = 0;
      for (const id of want) {
        if (tree.pathOf(id).length && reads.get(id) === 'ok') tree.expand(id);
        else missing++;
      }
      for (const [id, v] of reads) if (v === 'ok' && !want.has(id) && id !== o.root) tree.collapse(id);
      if (selectDn && tree.pathOf(selectDn).length) { tree.select(selectDn); st.selected = tree.getSelected(); paint(); }
      return missing;
    },
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
