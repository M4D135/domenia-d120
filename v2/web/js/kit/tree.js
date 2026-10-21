// Lazy tree (aria tree): children are read when a branch opens, one read per opening; search through the branches
// already read (never a new read); keyboard of the APG tree pattern; virtualized for very large branches.
import { glyph } from './glyphs.js';
import { openMenu } from './menu.js';
import {
  esc, fold, uid, clamp, debounce, rafThrottle, setVars, highlight, count, announce,
} from './util.js';
import { errorText } from '../ui.js';

/**
 * @typedef {Object} TreeNode
 * @property {string} id                     Stable identity (GUID or DN).
 * @property {string} label
 * @property {string} [icon]                 Default: folder (branch) or object (leaf).
 * @property {string} [hint]                 Secondary text on the right (count, type).
 * @property {boolean} [leaf]                No children: no twisty, no read.
 * @property {TreeNode[]} [children]         Children already known (no read needed).
 * @property {boolean} [selectable=true]     false: the node only serves to navigate (containers).
 * @property {any} [data]                    Free payload for the page.
 */

/**
 * @typedef {Object} TreeOptions
 * @property {string} label                  Accessible name.
 * @property {TreeNode[] | (() => Promise<TreeNode[]>)} roots
 * @property {(node: TreeNode) => Promise<TreeNode[]>} [load]   Reads the children of a branch.
 * @property {(node: TreeNode, how: 'pointer'|'keyboard') => void} [onSelect]  Pointer: at once; keyboard: after 300 ms.
 * @property {(node: TreeNode) => void} [onActivate]           Enter or double click.
 * @property {(node: TreeNode) => any[]} [contextMenu]
 * @property {boolean} [search=true]
 * @property {string} [searchPlaceholder]
 * @property {string} [height]               CSS height (default 420px, 'fill' for a flex parent).
 * @property {'compact'|'normal'} [density='normal']
 */

const ROW = { compact: 28, normal: 34 };
const OVERSCAN = 8;
const KEY_DELAY = 300;

/**
 * Creates a tree in host (its content is replaced).
 * @param {HTMLElement} host
 * @param {TreeOptions} o
 */
export function createTree(host, o) {
  const tid = uid('tree');
  const rh = ROW[o.density] ?? ROW.normal;
  /** @type {Map<string, {node: TreeNode, parent: string|null, level: number, expanded: boolean, loaded: boolean, loading: boolean, error: string|null, kids: string[], gen: number}>} */
  const items = new Map();
  let roots = [];
  let flat = [];
  let activeId = null;
  let selectedId = null;
  let query = '';
  let rootsLoading = false;
  let rootsError = null;
  let alive = true;
  let fresh = new Set();
  const rendered = new Map();

  host.innerHTML = `<div class="k-tree${o.height === 'fill' ? ' fill' : ''}">
    ${o.search === false ? '' : `<label class="k-tree-search">${glyph('search')}<span class="visually-hidden">Rechercher dans les branches déjà lues</span>
      <input type="search" maxlength="120" autocomplete="off" spellcheck="false" placeholder="${esc(o.searchPlaceholder ?? 'Rechercher une branche…')}"></label>
      <p class="k-tree-note" hidden></p>`}
    <div class="k-tree-scroll" role="tree" tabindex="0" aria-label="${esc(o.label)}"><div class="k-tree-body"></div></div>
  </div>`;
  const rootEl = /** @type {HTMLElement} */ (host.querySelector('.k-tree'));
  const scroller = /** @type {HTMLElement} */ (rootEl.querySelector('.k-tree-scroll'));
  const bodyEl = /** @type {HTMLElement} */ (rootEl.querySelector('.k-tree-body'));
  const input = /** @type {HTMLInputElement|null} */ (rootEl.querySelector('.k-tree-search input'));
  const note = rootEl.querySelector('.k-tree-note');
  if (o.height && o.height !== 'fill') setVars(rootEl, { '--k-tree-h': o.height });
  setVars(rootEl, { '--k-trh': `${rh}px` });

  // ---------- Model ----------

  function register(nodes, parent, level) {
    return nodes.map((node) => {
      const id = String(node.id);
      const prev = items.get(id);
      const entry = {
        node,
        parent,
        level,
        expanded: prev?.expanded ?? false,
        loaded: Array.isArray(node.children),
        loading: false,
        error: null,
        kids: [],
        gen: (prev?.gen ?? 0) + 1,
      };
      items.set(id, entry);
      if (Array.isArray(node.children)) entry.kids = register(node.children, id, level + 1);
      return id;
    });
  }

  const isBranch = (e) => !e.node.leaf;

  function matches(id) {
    const e = items.get(id);
    return e ? fold(e.node.label).includes(query) : false;
  }

  // Ids of nodes kept by the search: matches and their ancestors (only branches already read).
  function searchKeep() {
    const keep = new Set();
    for (const [id] of items) {
      if (!matches(id)) continue;
      let cur = id;
      while (cur != null && !keep.has(cur)) { keep.add(cur); cur = items.get(cur)?.parent ?? null; }
    }
    return keep;
  }

  function flatten() {
    const out = [];
    const keep = query ? searchKeep() : null;
    const walk = (ids) => {
      const shown = keep ? ids.filter((id) => keep.has(id)) : ids;
      shown.forEach((id, n) => {
        const e = items.get(id);
        const open = keep ? e.kids.some((k) => keep.has(k)) : e.expanded;
        out.push({ kind: 'node', id, pos: n + 1, size: shown.length, open });
        if (!open) return;
        if (!keep && e.loading) out.push({ kind: 'loading', id, level: e.level + 1 });
        else if (!keep && e.error) out.push({ kind: 'error', id, level: e.level + 1, message: e.error });
        else if (!keep && e.loaded && !e.kids.length) out.push({ kind: 'none', id, level: e.level + 1 });
        else walk(e.kids);
      });
    };
    walk(roots);
    flat = out;
  }

  // ---------- Rendering ----------

  function rowMarkup(k) {
    const r = flat[k];
    if (r.kind !== 'node') {
      const lvl = r.level;
      if (r.kind === 'loading') {
        return `<div class="k-ti k-ti-state" role="none" data-k="${k}" data-lvl="${lvl}"><span class="k-spin" aria-hidden="true"></span><span class="skeleton sk sk-line w40"></span><span class="visually-hidden">Lecture de la branche…</span></div>`;
      }
      if (r.kind === 'none') return `<div class="k-ti k-ti-state muted" role="none" data-k="${k}" data-lvl="${lvl}">Aucune sous-branche</div>`;
      return `<div class="k-ti k-ti-state err" role="none" data-k="${k}" data-lvl="${lvl}">${glyph('alert')}<span class="k-ti-err">${esc(r.message)}</span>`
        + `<button class="btn ghost sm" type="button" data-retry="${esc(r.id)}" tabindex="-1">Réessayer</button></div>`;
    }
    const e = items.get(r.id);
    const branch = isBranch(e);
    const expanded = branch ? r.open : null;
    const sel = selectedId === r.id;
    const label = query ? highlight(e.node.label, query) : esc(e.node.label);
    const ico = e.node.icon ?? (branch ? 'ou' : 'object');
    const twisty = branch
      ? `<span class="k-twisty${expanded ? ' open' : ''}${e.loading ? ' loading' : ''}" aria-hidden="true">${glyph('chevronRight')}</span>`
      : '<span class="k-twisty none" aria-hidden="true"></span>';
    return `<div class="k-ti${sel ? ' is-sel' : ''}${r.id === activeId ? ' is-act' : ''}${e.node.selectable === false ? ' nav-only' : ''}${fresh.has(r.id) ? ' k-enter' : ''}" role="treeitem" id="${tid}-${k}" data-k="${k}" data-id="${esc(r.id)}" data-lvl="${e.level}"`
      + ` aria-level="${e.level + 1}" aria-setsize="${r.size}" aria-posinset="${r.pos}"${branch ? ` aria-expanded="${expanded}"` : ''} aria-selected="${sel}"${e.loading ? ' aria-busy="true"' : ''}>`
      + `${twisty}<span class="k-ti-ico">${glyph(ico)}</span><span class="k-ti-label">${label}</span>`
      + `${e.node.hint ? `<span class="k-ti-hint">${esc(e.node.hint)}</span>` : ''}</div>`;
  }

  function render(force = false) {
    if (!alive) return;
    if (rootsLoading) {
      bodyEl.style.removeProperty('height');
      bodyEl.classList.add('is-loading');
      bodyEl.innerHTML = Array.from({ length: 7 }, (_, n) => `<div class="k-ti k-ti-state" aria-hidden="true" data-lvl="${n % 3}"><span class="skeleton sk sk-line ${['w55', 'w70', 'w40'][n % 3]}"></span></div>`).join('');
      bodyEl.querySelectorAll('[data-lvl]').forEach((n) => n.style.setProperty('--lvl', n.dataset.lvl));
      scroller.setAttribute('aria-busy', 'true');
      rendered.clear();
      return;
    }
    bodyEl.classList.remove('is-loading');
    scroller.removeAttribute('aria-busy');
    if (rootsError) {
      bodyEl.style.removeProperty('height');
      bodyEl.innerHTML = `<div class="k-tree-empty err">${glyph('alert')}<p>${esc(rootsError)}</p><button class="btn sm" type="button" data-retry-roots>Réessayer</button></div>`;
      rendered.clear();
      return;
    }
    if (!flat.length) {
      bodyEl.style.removeProperty('height');
      bodyEl.innerHTML = `<div class="k-tree-empty">${glyph(query ? 'search' : 'ou')}<p>${query ? 'Aucune branche déjà lue ne correspond.' : 'Aucune branche.'}</p></div>`;
      rendered.clear();
      return;
    }
    bodyEl.style.setProperty('height', `${flat.length * rh}px`);
    if (force) { bodyEl.replaceChildren(); rendered.clear(); }
    const top = scroller.scrollTop;
    const first = Math.max(0, Math.floor(top / rh) - OVERSCAN);
    const last = Math.min(flat.length - 1, Math.ceil((top + scroller.clientHeight) / rh) + OVERSCAN);
    const activeK = flat.findIndex((r) => r.kind === 'node' && r.id === activeId);
    for (const [k, node] of rendered) {
      if ((k < first || k > last || k >= flat.length) && k !== activeK) { node.remove(); rendered.delete(k); }
    }
    const wanted = [];
    for (let k = first; k <= last; k++) if (!rendered.has(k)) wanted.push(k);
    if (activeK >= 0 && !rendered.has(activeK) && !wanted.includes(activeK)) wanted.push(activeK);
    if (wanted.length) {
      const t = document.createElement('template');
      t.innerHTML = wanted.map(rowMarkup).join('');
      const nodes = [...t.content.children];
      let j = 0;
      nodes.forEach((n, i) => {
        const k = wanted[i];
        n.style.setProperty('transform', `translateY(${k * rh}px)`);
        n.style.setProperty('--lvl', n.dataset.lvl ?? '0');
        if (n.classList.contains('k-enter')) { n.style.setProperty('--j', String(Math.min(j, 12))); j += 1; }
        rendered.set(k, /** @type {HTMLElement} */ (n));
      });
      bodyEl.append(...nodes);
    }
    fresh = new Set();
    if (activeK >= 0) scroller.setAttribute('aria-activedescendant', `${tid}-${activeK}`);
    else scroller.removeAttribute('aria-activedescendant');
  }

  function refresh() {
    flatten();
    render(true);
  }

  const onScroll = rafThrottle(() => render(false));
  scroller.addEventListener('scroll', onScroll, { passive: true });

  function ensureVisible(k) {
    const y = k * rh;
    if (y < scroller.scrollTop) scroller.scrollTop = y;
    else if (y + rh > scroller.scrollTop + scroller.clientHeight) scroller.scrollTop = y + rh - scroller.clientHeight;
  }

  // ---------- Reads ----------

  async function expand(id, { focusChild = false } = {}) {
    const e = items.get(id);
    if (!e || !isBranch(e)) return;
    if (e.loading) return; // a second opening during the read has no effect
    e.expanded = true;
    if (!e.loaded && typeof o.load === 'function') {
      e.loading = true;
      e.error = null;
      const gen = e.gen;
      refresh();
      try {
        const kids = await o.load(e.node);
        if (!alive || items.get(id) !== e || e.gen !== gen) return; // replaced meanwhile: never attached
        e.kids = register(Array.isArray(kids) ? kids : [], id, e.level + 1);
        e.kids.forEach((k) => fresh.add(k));
        e.loaded = true;
        announce(`${e.node.label} : ${count(e.kids.length, 'sous-branche', 'sous-branches')}.`);
      } catch (err) {
        if (!alive || items.get(id) !== e || e.gen !== gen) return;
        if (!err?.code) console.error(err);
        e.error = errorText(err, 'Lecture de la branche impossible.');
        announce(`Lecture de ${e.node.label} impossible.`, { assertive: true });
      } finally {
        if (items.get(id) === e && e.gen === gen) e.loading = false;
      }
    } else {
      e.kids.forEach((k) => fresh.add(k));
    }
    refresh();
    if (focusChild && e.kids.length) setActive(e.kids[0]);
  }

  function collapse(id) {
    const e = items.get(id);
    if (!e) return;
    e.expanded = false;
    refresh();
  }

  async function loadRoots() {
    if (typeof o.roots !== 'function') {
      roots = register(Array.isArray(o.roots) ? o.roots : [], null, 0);
      return;
    }
    rootsLoading = true;
    rootsError = null;
    render(true);
    try {
      const list = await o.roots();
      if (!alive) return;
      items.clear();
      roots = register(Array.isArray(list) ? list : [], null, 0);
      roots.forEach((r) => fresh.add(r));
    } catch (err) {
      if (!err?.code) console.error(err);
      rootsError = errorText(err, 'Lecture de l’arborescence impossible.');
    } finally {
      rootsLoading = false;
    }
  }

  // ---------- Focus and selection ----------

  const notifySelect = debounce((id) => {
    const e = items.get(id);
    if (e && alive) o.onSelect?.(e.node, 'keyboard');
  }, KEY_DELAY);

  // Active and selected rows change in place: rows under the pointer are never rebuilt between pointerdown and click.
  function paintState() {
    for (const node of rendered.values()) {
      const id = node.dataset.id;
      if (id === undefined) continue;
      node.classList.toggle('is-act', id === activeId);
      node.classList.toggle('is-sel', id === selectedId);
      node.setAttribute('aria-selected', String(id === selectedId));
    }
    const k = flat.findIndex((r) => r.kind === 'node' && r.id === activeId);
    if (k >= 0) scroller.setAttribute('aria-activedescendant', `${tid}-${k}`);
    else scroller.removeAttribute('aria-activedescendant');
  }

  function setActive(id, { scroll = true } = {}) {
    activeId = id;
    const k = flat.findIndex((r) => r.kind === 'node' && r.id === id);
    if (k >= 0 && scroll) ensureVisible(k);
    render(false);
    paintState();
  }

  function select(id, how) {
    const e = items.get(id);
    if (!e || e.node.selectable === false) { setActive(id); return; }
    selectedId = id;
    setActive(id);
    if (how === 'pointer') { notifySelect.cancel(); o.onSelect?.(e.node, 'pointer'); }
    else if (how === 'keyboard') notifySelect(id);
  }

  const nodeRows = () => flat.filter((r) => r.kind === 'node');

  function moveBy(delta) {
    const list = nodeRows();
    if (!list.length) return;
    const at = list.findIndex((r) => r.id === activeId);
    let k;
    if (delta === -Infinity) k = 0;
    else if (delta === Infinity) k = list.length - 1;
    else k = clamp(at < 0 ? 0 : at + delta, 0, list.length - 1);
    select(list[k].id, 'keyboard');
  }

  // ---------- Events ----------

  let typed = '';
  let typedTimer = 0;

  scroller.addEventListener('keydown', (e) => {
    if (e.target !== scroller) return;
    const e0 = activeId ? items.get(activeId) : null;
    const page = Math.max(1, Math.floor(scroller.clientHeight / rh) - 1);
    switch (e.key) {
      case 'ArrowDown': e.preventDefault(); moveBy(1); return;
      case 'ArrowUp': e.preventDefault(); moveBy(-1); return;
      case 'PageDown': e.preventDefault(); moveBy(page); return;
      case 'PageUp': e.preventDefault(); moveBy(-page); return;
      case 'Home': e.preventDefault(); moveBy(-Infinity); return;
      case 'End': e.preventDefault(); moveBy(Infinity); return;
      case 'ArrowRight':
        e.preventDefault();
        if (!e0 || !isBranch(e0)) return;
        if (query) return;
        if (!e0.expanded) expand(activeId);
        else if (e0.kids.length) select(e0.kids[0], 'keyboard');
        return;
      case 'ArrowLeft':
        e.preventDefault();
        if (!e0) return;
        if (!query && isBranch(e0) && e0.expanded) collapse(activeId);
        else if (e0.parent != null) select(e0.parent, 'keyboard');
        return;
      case 'Enter':
        e.preventDefault();
        if (e0) { select(activeId, 'pointer'); o.onActivate?.(e0.node); }
        return;
      case ' ':
        e.preventDefault();
        if (e0) select(activeId, 'pointer');
        return;
      case 'F5':
        e.preventDefault();
        if (e0) api.reload(activeId);
        return;
      case 'ContextMenu': case 'F10': {
        if (e.key === 'F10' && !e.shiftKey) return;
        if (!e0 || typeof o.contextMenu !== 'function') return;
        e.preventDefault();
        const k = flat.findIndex((r) => r.kind === 'node' && r.id === activeId);
        const row = rendered.get(k);
        const r = (row ?? scroller).getBoundingClientRect();
        openMenu({ x: r.left + 32, y: r.bottom - 2 }, o.contextMenu(e0.node), { label: `Actions de ${e0.node.label}`, restoreFocus: scroller });
        return;
      }
      default:
        if (e.key === '*') {
          e.preventDefault();
          const siblings = e0 ? (e0.parent == null ? roots : items.get(e0.parent).kids) : roots;
          siblings.forEach((id) => { const s = items.get(id); if (s && isBranch(s) && !s.expanded) expand(id); });
          return;
        }
        if (e.key.length === 1 && !e.ctrlKey && !e.metaKey && !e.altKey) {
          clearTimeout(typedTimer);
          typed += fold(e.key);
          typedTimer = setTimeout(() => { typed = ''; }, 700);
          const list = nodeRows();
          const at = list.findIndex((r) => r.id === activeId);
          const order = [...list.slice(at + 1), ...list.slice(0, at + 1)];
          const hit = order.find((r) => fold(items.get(r.id).node.label).startsWith(typed));
          if (hit) select(hit.id, 'keyboard');
        }
    }
  });

  bodyEl.addEventListener('click', (e) => {
    const t = e.target instanceof Element ? e.target : null;
    if (!t) return;
    const retry = t.closest('[data-retry]');
    if (retry) { const e1 = items.get(retry.dataset.retry); if (e1) { e1.error = null; e1.expanded = false; expand(retry.dataset.retry); } return; }
    if (t.closest('[data-retry-roots]')) { start(); return; }
    const row = t.closest('.k-ti[data-id]');
    if (!row) return;
    const id = row.dataset.id;
    if (t.closest('.k-twisty') && !query) {
      const e1 = items.get(id);
      if (e1?.expanded) collapse(id); else expand(id);
      setActive(id, { scroll: false });
      return;
    }
    select(id, 'pointer');
  });

  bodyEl.addEventListener('dblclick', (e) => {
    const row = e.target instanceof Element ? e.target.closest('.k-ti[data-id]') : null;
    if (!row || (e.target instanceof Element && e.target.closest('.k-twisty'))) return;
    const e1 = items.get(row.dataset.id);
    if (!e1) return;
    if (typeof o.onActivate === 'function') o.onActivate(e1.node);
    else if (isBranch(e1) && !query) { if (e1.expanded) collapse(row.dataset.id); else expand(row.dataset.id); }
  });

  bodyEl.addEventListener('pointerdown', (e) => {
    if (e.target instanceof Element && e.target.closest('.k-ti') && document.activeElement !== scroller) {
      scroller.focus({ preventScroll: true });
    }
  });

  bodyEl.addEventListener('contextmenu', (e) => {
    const row = e.target instanceof Element ? e.target.closest('.k-ti[data-id]') : null;
    if (!row || typeof o.contextMenu !== 'function') return;
    e.preventDefault();
    const e1 = items.get(row.dataset.id);
    if (!e1) return;
    select(row.dataset.id, 'pointer');
    openMenu(e, o.contextMenu(e1.node), { label: `Actions de ${e1.node.label}`, restoreFocus: scroller });
  });

  scroller.addEventListener('focus', () => {
    if (!activeId) {
      const firstNode = nodeRows()[0];
      if (firstNode) setActive(selectedId ?? firstNode.id);
    }
  });

  const applySearch = debounce(() => {
    query = fold(input?.value.trim() ?? '');
    refresh();
    if (note) {
      if (query) {
        const n = nodeRows().filter((r) => matches(r.id)).length;
        note.hidden = false;
        note.textContent = n ? `${count(n, 'branche trouvée', 'branches trouvées')} parmi les branches déjà lues seulement.`
          : 'Recherche dans les branches déjà lues seulement : aucune ne correspond.';
        announce(note.textContent);
      } else {
        note.hidden = true;
      }
    }
  }, 160);
  input?.addEventListener('input', applySearch);
  input?.addEventListener('keydown', (e) => {
    if (e.key === 'Escape' && input.value) { e.preventDefault(); e.stopPropagation(); input.value = ''; applySearch(); applySearch.flush(); }
    if (e.key === 'ArrowDown') { e.preventDefault(); applySearch.flush(); scroller.focus({ preventScroll: true }); }
  });

  const ro = 'ResizeObserver' in window ? new ResizeObserver(() => render(false)) : null;
  ro?.observe(scroller);

  async function start() {
    await loadRoots();
    if (!alive) return;
    refresh();
  }

  const api = {
    el: rootEl,
    /** Re-reads a branch (or the whole tree without id). Results of an older read are never attached. */
    async reload(id) {
      if (id == null) { items.clear(); roots = []; activeId = null; selectedId = null; await start(); return; }
      const e = items.get(id);
      if (!e || !isBranch(e)) return;
      for (const k of e.kids) dropBranch(k);
      e.kids = [];
      e.loaded = false;
      e.loading = false;
      e.error = null;
      e.gen += 1;
      e.expanded = false;
      await expand(id);
    },
    expand: (id) => expand(String(id)),
    collapse: (id) => collapse(String(id)),
    /** Selects a node already in the tree (no read); false if absent. */
    select(id) {
      const key = String(id);
      if (!items.has(key)) return false;
      let cur = items.get(key).parent;
      while (cur != null) { const p = items.get(cur); p.expanded = true; cur = p.parent; }
      flatten();
      render(true);
      selectedId = key;
      setActive(key);
      return true;
    },
    /** Opens each branch of a path (ids from the root), reading what is missing, then selects the last one. */
    async reveal(path) {
      for (let n = 0; n < path.length - 1; n++) {
        const id = String(path[n]);
        if (!items.has(id)) return false;
        await expand(id);
      }
      return api.select(path[path.length - 1]);
    },
    getSelected: () => (selectedId ? items.get(selectedId)?.node ?? null : null),
    /** Path of labels from the root to a node. */
    pathOf(id) {
      const out = [];
      let cur = String(id);
      while (cur != null && items.has(cur)) { out.unshift(items.get(cur).node); cur = items.get(cur).parent; }
      return out;
    },
    setFilter(text) { if (input) input.value = text ?? ''; applySearch(); applySearch.flush(); },
    /** Number of nodes already read. */
    size: () => items.size,
    focus: () => scroller.focus({ preventScroll: true }),
    destroy() {
      alive = false;
      notifySelect.cancel();
      applySearch.cancel();
      onScroll.cancel();
      ro?.disconnect();
      host.replaceChildren();
    },
  };

  function dropBranch(id) {
    const e = items.get(id);
    if (!e) return;
    e.kids.forEach(dropBranch);
    items.delete(id);
    if (activeId === id) activeId = e.parent;
    if (selectedId === id) selectedId = null;
  }

  start();
  return api;
}

