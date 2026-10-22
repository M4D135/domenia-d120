// Floating menus: context menu, « Plus » menu, column menus. One menu tree at a time, keyboard first (APG menu).
import { glyph } from './glyphs.js';
import { esc, fold, uid, placeFloating, leave, isTextEntry } from './util.js';

/**
 * @typedef {Object} MenuItem
 * @property {string} [id]
 * @property {string} label                 Visible text (French).
 * @property {string} [icon]                Icon name (glyphs.js or icons.js).
 * @property {string} [kbd]                 Shortcut shown on the right (« Ctrl C »).
 * @property {string} [hint]                Secondary text on the right.
 * @property {boolean} [disabled]
 * @property {string} [reason]              Why it is disabled (tooltip and accessible description).
 * @property {boolean} [danger]             Write or destructive action (red, never the first item).
 * @property {'write'|'network'} [kind]     Marks a write (pencil) or a network read (blue dot), as the command bar does (§ 2.6.6).
 * @property {boolean} [checked]            Makes a checkbox item (menuitemcheckbox).
 * @property {string} [radio]               Radio group name (menuitemradio, uses `checked`).
 * @property {boolean} [keepOpen]           The menu stays open after the action (checkbox lists).
 * @property {(item: MenuItem) => void} [run]
 * @property {Array<MenuItem|'-'|{heading: string}>} [items]  Submenu.
 */

let current = null; // root controller of the open menu tree
// Button whose menu was just closed by a press on that same button: its click must not reopen the menu.
let suppress = null;
const SUPPRESS_MS = 500;
const OPEN_DELAY_MS = 140;

function itemMarkup(item, n) {
  if (item === '-') return '<div class="k-msep" role="separator"></div>';
  if (item && typeof item === 'object' && 'heading' in item) return `<div class="k-mhead" role="presentation">${esc(item.heading)}</div>`;
  const sub = Array.isArray(item.items) && item.items.length > 0;
  let role = 'menuitem';
  if (item.radio) role = 'menuitemradio';
  else if (typeof item.checked === 'boolean') role = 'menuitemcheckbox';
  const checked = role === 'menuitem' ? '' : ` aria-checked="${item.checked ? 'true' : 'false'}"`;
  const disabled = item.disabled ? ' aria-disabled="true"' : '';
  const tip = item.disabled && item.reason ? ` data-tip="${esc(item.reason)}"` : '';
  const desc = item.disabled && item.reason ? `<span class="visually-hidden">, ${esc(item.reason)}</span>` : '';
  const popup = sub ? ' aria-haspopup="menu" aria-expanded="false"' : '';
  const mark = role === 'menuitem' ? (item.icon ? glyph(item.icon, 'k-mi-ico') : '<span class="k-mi-ico" aria-hidden="true"></span>')
    : `<span class="k-mi-check${item.radio ? ' radio' : ''}" aria-hidden="true">${glyph(item.radio ? 'dot' : 'check')}</span>`;
  const kind = item.kind === 'write' ? `<span class="k-mi-kind write" data-tip="Écriture">${glyph('edit')}</span><span class="visually-hidden">, écriture</span>`
    : item.kind === 'network' ? '<span class="k-mi-kind net" data-tip="Lecture sur le réseau"></span><span class="visually-hidden">, lecture sur le réseau</span>' : '';
  const right = sub ? glyph('chevronRight', 'k-mi-sub')
    : `${kind}${item.hint ? `<span class="k-mi-hint">${esc(item.hint)}</span>` : ''}${item.kbd ? `<kbd>${esc(item.kbd)}</kbd>` : ''}`;
  return `<div class="k-mi${item.danger ? ' danger' : ''}" role="${role}" tabindex="-1" data-n="${n}"${checked}${disabled}${popup}${tip}>`
    + `${mark}<span class="k-mi-label">${esc(item.label)}${desc}</span>${right}</div>`;
}

function build(items, label) {
  const menu = document.createElement('div');
  menu.className = 'k-menu';
  menu.id = uid('menu');
  menu.setAttribute('role', 'menu');
  menu.setAttribute('aria-label', label || 'Menu');
  menu.tabIndex = -1;
  menu.innerHTML = items.map(itemMarkup).join('');
  return menu;
}

/**
 * Opens a menu next to an element, at a point (context menu) or at a pointer event.
 * Closes the menu already open. Focus goes to the first item and comes back on close.
 * @param {Element | {x:number,y:number} | MouseEvent} target
 * @param {Array<MenuItem|'-'|{heading:string}>} items
 * @param {{ label?: string, placement?: 'bottom-start'|'bottom-end'|'top-start', onClose?: () => void, restoreFocus?: HTMLElement|null, focusFirst?: boolean }} [opts]
 * A click on the button whose menu is open closes it (the call then returns el: null).
 * @returns {{ close: () => void, el: HTMLElement|null }}
 */
export function openMenu(target, items, opts = {}) {
  if (target instanceof Element && suppress?.anchor === target && performance.now() - suppress.at < SUPPRESS_MS) {
    suppress = null;
    return { close: () => {}, el: null };
  }
  suppress = null;
  closeMenus();
  const point = target instanceof MouseEvent ? { x: target.clientX, y: target.clientY } : target;
  const restore = opts.restoreFocus !== undefined ? opts.restoreFocus
    : (document.activeElement instanceof HTMLElement ? document.activeElement : null);
  const root = createLevel(items, opts.label, null);
  const anchor = point instanceof Element ? point : null;
  if (anchor) anchor.setAttribute('aria-expanded', 'true');

  let closed = false;
  const close = (focusBack = true) => {
    if (closed) return;
    closed = true;
    if (current === ctl) current = null;
    root.closeChild();
    if (anchor) anchor.setAttribute('aria-expanded', 'false');
    document.removeEventListener('pointerdown', onOutside, true);
    window.removeEventListener('blur', onBlur);
    window.removeEventListener('resize', onBlur);
    window.removeEventListener('hashchange', onBlur);
    document.removeEventListener('scroll', onScroll, true);
    const node = root.el;
    const hadFocus = node.contains(document.activeElement) || document.activeElement === document.body;
    leave(node, 260).then(() => node.remove());
    if (focusBack && hadFocus && restore?.isConnected) restore.focus({ preventScroll: true });
    opts.onClose?.();
  };
  const onOutside = (e) => {
    if (e.target instanceof Element && e.target.closest('.k-menu')) return;
    if (anchor && e.target instanceof Node && anchor.contains(e.target)) suppress = { anchor, at: performance.now() };
    close(false);
  };
  const onBlur = () => close(false);
  const onScroll = (e) => {
    if (e.target instanceof Element && e.target.closest('.k-menu')) return;
    close(false);
  };
  const ctl = { close: () => close(true), el: root.el, closeQuiet: () => close(false) };
  root.onCloseAll = (focusBack) => close(focusBack);

  document.body.appendChild(root.el);
  placeFloating(root.el, point, { placement: opts.placement ?? 'bottom-start' });
  root.el.classList.add('in');
  current = ctl;
  setTimeout(() => {
    if (closed) return;
    document.addEventListener('pointerdown', onOutside, true);
    window.addEventListener('blur', onBlur);
    window.addEventListener('resize', onBlur);
    window.addEventListener('hashchange', onBlur);
    document.addEventListener('scroll', onScroll, true);
  }, 0);
  if (opts.focusFirst !== false) root.focusIndex(root.firstEnabled());
  else root.el.focus({ preventScroll: true });
  return ctl;
}

/** Closes the open menu, if any (focus is not moved). */
export function closeMenus() {
  current?.closeQuiet();
  current = null;
}

/** True while a menu is open. */
export function menuOpen() {
  return current !== null;
}

// One level of the tree (the root or a submenu).
function createLevel(items, label, parent) {
  const el = build(items, label);
  const nodes = () => [...el.querySelectorAll(':scope > .k-mi')];
  const entries = items.map((it, n) => ({ it, n })).filter(({ it }) => it !== '-' && !(it && typeof it === 'object' && 'heading' in it));
  let child = null;
  let childOf = -1;
  let hoverTimer = 0;
  let typed = '';
  let typedTimer = 0;

  const level = {
    el,
    parent,
    onCloseAll: parent ? parent.onCloseAll : () => {},
    firstEnabled: () => nodes()[0] ?? null,
    focusIndex(node) {
      if (!node) { el.focus({ preventScroll: true }); return; }
      nodes().forEach((x) => { x.tabIndex = x === node ? 0 : -1; });
      node.focus({ preventScroll: true });
    },
    closeChild() {
      clearTimeout(hoverTimer);
      if (!child) return;
      child.closeChild();
      const node = child.el;
      const owner = nodes().find((x) => Number(x.dataset.n) === childOf);
      owner?.setAttribute('aria-expanded', 'false');
      child = null;
      childOf = -1;
      leave(node, 200).then(() => node.remove());
    },
  };

  const itemOf = (node) => items[Number(node.dataset.n)];

  function openChild(node, focus) {
    const item = itemOf(node);
    if (!item?.items?.length || node.getAttribute('aria-disabled') === 'true') return;
    if (child && childOf === Number(node.dataset.n)) { if (focus) child.focusIndex(child.firstEnabled()); return; }
    level.closeChild();
    child = createLevel(item.items, item.label, level);
    childOf = Number(node.dataset.n);
    node.setAttribute('aria-expanded', 'true');
    document.body.appendChild(child.el);
    placeFloating(child.el, node, { placement: 'right-start' });
    child.el.classList.add('in', 'sub');
    if (focus) child.focusIndex(child.firstEnabled());
  }

  function activate(node) {
    const item = itemOf(node);
    if (!item || node.getAttribute('aria-disabled') === 'true') return;
    if (item.items?.length) { openChild(node, true); return; }
    if (typeof item.checked === 'boolean' && !item.radio) {
      item.checked = !item.checked;
      node.setAttribute('aria-checked', String(item.checked));
    } else if (item.radio) {
      nodes().forEach((x) => {
        const other = itemOf(x);
        if (other?.radio === item.radio) { other.checked = other === item; x.setAttribute('aria-checked', String(other === item)); }
      });
    }
    if (!item.keepOpen) level.onCloseAll(true);
    // The action runs after the menu has handed the focus back (it may open a dialog or move the focus itself).
    if (typeof item.run === 'function') requestAnimationFrame(() => item.run(item));
  }

  function move(delta) {
    const list = nodes();
    if (!list.length) return;
    const at = list.indexOf(/** @type {HTMLElement} */ (document.activeElement));
    const next = at < 0 ? (delta > 0 ? 0 : list.length - 1) : (at + delta + list.length) % list.length;
    level.focusIndex(list[next]);
  }

  el.addEventListener('keydown', (e) => {
    const node = e.target instanceof Element ? e.target.closest('.k-mi') : null;
    if (e.target instanceof Element && e.target.closest('.k-menu') !== el) return;
    switch (e.key) {
      case 'ArrowDown': e.preventDefault(); move(1); break;
      case 'ArrowUp': e.preventDefault(); move(-1); break;
      case 'Home': e.preventDefault(); level.focusIndex(nodes()[0]); break;
      case 'End': e.preventDefault(); level.focusIndex(nodes().at(-1)); break;
      case 'ArrowRight': if (node) { e.preventDefault(); openChild(node, true); } break;
      case 'ArrowLeft':
        if (parent) {
          e.preventDefault();
          const owner = parent.el.querySelector(`:scope > .k-mi[aria-expanded="true"]`);
          parent.closeChild();
          if (owner instanceof HTMLElement) parent.focusIndex(owner);
        }
        break;
      case 'Enter': case ' ':
        if (node) { e.preventDefault(); activate(node); }
        break;
      case 'Escape':
        e.preventDefault();
        e.stopPropagation();
        if (parent) {
          const owner = parent.el.querySelector(`:scope > .k-mi[aria-expanded="true"]`);
          parent.closeChild();
          if (owner instanceof HTMLElement) parent.focusIndex(owner);
        } else {
          level.onCloseAll(true);
        }
        break;
      case 'Tab': e.preventDefault(); level.onCloseAll(true); break;
      default:
        if (e.key.length === 1 && !e.ctrlKey && !e.metaKey && !e.altKey && !isTextEntry(e.target)) {
          clearTimeout(typedTimer);
          typed += fold(e.key);
          typedTimer = setTimeout(() => { typed = ''; }, 600);
          const hit = entries.find(({ it }) => fold(it.label).startsWith(typed));
          const target = hit ? nodes().find((x) => Number(x.dataset.n) === hit.n) : null;
          if (target) level.focusIndex(target);
        }
    }
  });
  el.addEventListener('click', (e) => {
    const node = e.target instanceof Element ? e.target.closest('.k-mi') : null;
    if (node && node.closest('.k-menu') === el) activate(node);
  });
  // Only a real pointer movement moves the focus (a list scrolled under a still pointer does not).
  let lastPoint = '';
  el.addEventListener('pointermove', (e) => {
    const at = `${e.clientX},${e.clientY}`;
    if (at === lastPoint) return;
    lastPoint = at;
    const node = e.target instanceof Element ? e.target.closest('.k-mi') : null;
    if (!node || node.closest('.k-menu') !== el || node === document.activeElement) return;
    level.focusIndex(node);
    clearTimeout(hoverTimer);
    hoverTimer = setTimeout(() => {
      if (itemOf(node)?.items?.length) openChild(node, false);
      else if (child) level.closeChild();
    }, OPEN_DELAY_MS);
  });
  el.addEventListener('contextmenu', (e) => e.preventDefault());
  return level;
}

/**
 * Wires a context menu on an element: right click, Shift+F10 and the Menu key.
 * @param {HTMLElement} target
 * @param {(e: MouseEvent|KeyboardEvent) => (Array<MenuItem|'-'|{heading:string}>|null)} getItems  null: no menu.
 * @param {{ label?: string }} [opts]
 * @returns {() => void} unbind
 */
export function bindContextMenu(target, getItems, opts = {}) {
  const onContext = (e) => {
    const items = getItems(e);
    if (!items?.length) return;
    e.preventDefault();
    openMenu(e, items, { label: opts.label });
  };
  const onKey = (e) => {
    if (!(e.key === 'ContextMenu' || (e.key === 'F10' && e.shiftKey))) return;
    const items = getItems(e);
    if (!items?.length) return;
    e.preventDefault();
    const source = document.activeElement instanceof Element ? document.activeElement : target;
    const r = source.getBoundingClientRect();
    openMenu({ x: r.left + Math.min(24, r.width / 2), y: r.top + Math.min(r.height, 28) }, items, { label: opts.label });
  };
  target.addEventListener('contextmenu', onContext);
  target.addEventListener('keydown', onKey);
  return () => {
    target.removeEventListener('contextmenu', onContext);
    target.removeEventListener('keydown', onKey);
  };
}
