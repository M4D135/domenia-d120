// Kit shared helpers: ids, timing, French text, focus management, modal stack and floating placement.
// Every kit module builds on these; nothing here touches the bridge, the network or the disk.
import { esc, fold, formatNumber, motionReduced, announce, copyText, toast } from '../ui.js';

export { esc, fold, formatNumber, motionReduced, announce, toast };

/** No-break space (U+00A0): before « : », « ; », « ! », « ? », « % » and inside « ». */
export const NBSP = ' ';
/** Narrow no-break space (U+202F): thousands separator. */
export const NNBSP = ' ';
/** Minus sign (U+2212). */
export const MINUS = '−';

let sequence = 0;

/**
 * Unique DOM id for this page session.
 * @param {string} [prefix]
 * @returns {string}
 */
export function uid(prefix = 'k') {
  sequence += 1;
  return `${prefix}-${sequence.toString(36)}`;
}

/**
 * Clamps a number; a non-finite value falls back to the lower bound.
 * @param {number} n @param {number} lo @param {number} hi
 */
export function clamp(n, lo, hi) {
  return Math.min(hi, Math.max(lo, Number.isFinite(n) ? n : lo));
}

/**
 * Debounced function with cancel() and flush().
 * @template {(...args: any[]) => void} F
 * @param {F} fn @param {number} ms
 * @returns {F & { cancel(): void, flush(): void }}
 */
export function debounce(fn, ms) {
  let timer = 0;
  let last = null;
  const run = () => { timer = 0; const args = last; last = null; if (args) fn(...args); };
  const d = (...args) => { last = args; clearTimeout(timer); timer = setTimeout(run, ms); };
  d.cancel = () => { clearTimeout(timer); timer = 0; last = null; };
  d.flush = () => { if (timer) { clearTimeout(timer); run(); } };
  return /** @type {any} */ (d);
}

/**
 * Runs fn at most once per animation frame (last arguments win).
 * @template {(...args: any[]) => void} F
 * @param {F} fn
 * @returns {F & { cancel(): void }}
 */
export function rafThrottle(fn) {
  let frame = 0;
  let last = [];
  const t = (...args) => {
    last = args;
    if (!frame) frame = requestAnimationFrame(() => { frame = 0; fn(...last); });
  };
  t.cancel = () => { cancelAnimationFrame(frame); frame = 0; };
  return /** @type {any} */ (t);
}

/** Sets CSS custom properties through the CSSOM (CSP forbids style attributes in markup). */
export function setVars(el, vars) {
  for (const [name, value] of Object.entries(vars)) el.style.setProperty(name, String(value));
}

// ---------- French text (same rules as Domenia.Core FrenchText) ----------

/** Integer with U+202F thousands and U+2212 minus: « 1 234 », « −3 ». */
export function int(n) {
  if (!Number.isFinite(Number(n))) return '—';
  return formatNumber(Math.trunc(Number(n))).replace(/[  ]/g, NNBSP).replace(/-/g, MINUS);
}

/** Decimal number with a comma: « 3,1 ». */
export function dec(n, decimals = 1) {
  if (!Number.isFinite(Number(n))) return '—';
  return formatNumber(Number(n), decimals).replace(/[  ]/g, NNBSP).replace(/-/g, MINUS);
}

/** Number and noun with the French plural rule (0 and 1 take the singular). */
export function count(n, singular, plural) {
  return `${int(n)} ${Math.abs(Number(n)) >= 2 ? plural : singular}`;
}

/** Text between French quotes with no-break spaces: « texte ». */
export function quote(text) {
  return `«${NBSP}${text}${NBSP}»`;
}

// ---------- Elements ----------

/**
 * Parses trusted markup into a single element (the first element of the string).
 * @param {string} html
 * @returns {HTMLElement}
 */
export function el(html) {
  const t = document.createElement('template');
  t.innerHTML = html.trim();
  return /** @type {HTMLElement} */ (t.content.firstElementChild);
}

/**
 * Puts content into a host: a Node is appended, a string is trusted markup (escape data with esc()).
 * @param {HTMLElement} host @param {Node|string|null|undefined} content
 */
export function fill(host, content) {
  if (content == null) return;
  if (content instanceof Node) host.appendChild(content);
  else host.insertAdjacentHTML('beforeend', String(content));
}

/** True when the element takes text input (shortcuts must leave its keys alone). */
export function isTextEntry(node) {
  if (!(node instanceof HTMLElement)) return false;
  if (node.isContentEditable) return true;
  if (node instanceof HTMLTextAreaElement || node instanceof HTMLSelectElement) return true;
  if (node instanceof HTMLInputElement) return !['checkbox', 'radio', 'button', 'submit', 'reset', 'range', 'color', 'file'].includes(node.type);
  return false;
}

const FOCUSABLE = 'a[href], button:not([disabled]), input:not([disabled]):not([type="hidden"]), select:not([disabled]), '
  + 'textarea:not([disabled]), [tabindex]:not([tabindex="-1"]), [contenteditable="true"]';

/** Visible, enabled focusable elements of a scope, in document order. */
export function focusables(scope) {
  return [...scope.querySelectorAll(FOCUSABLE)].filter((n) => !n.closest('[hidden], [inert]') && n.getClientRects().length > 0);
}

// ---------- Clipboard (the bridge will take over later) ----------

let clipboardWriter = copyText;

/**
 * Replaces the clipboard writer (e.g. a bridge operation once it exists). The writer resolves to true on success.
 * @param {(text: string) => Promise<boolean>} writer
 */
export function setClipboardWriter(writer) {
  clipboardWriter = typeof writer === 'function' ? writer : copyText;
}

/** Writes text to the clipboard through the current writer. */
export function writeClipboard(text) {
  return Promise.resolve(clipboardWriter(String(text ?? ''))).catch((err) => { console.error(err); return false; });
}

// ---------- Modal stack (dialogs, drawers) ----------

const modals = [];
let shellWasInert = false;
let guardOn = false;

// Shortcuts of the page below (palette, menu, screens) would act behind the modal surface: they are stopped before
// app.js sees them. Keys inside the surface (Tab, Escape, arrows, Ctrl C…) are untouched.
function guardShortcuts(e) {
  if (!modals.length) return;
  const mod = e.ctrlKey || e.metaKey;
  const key = e.key.toLowerCase();
  const app = (mod && !e.altKey && (key === 'k' || key === 'p' || key === 'b')) || (e.altKey && !mod && /^Digit[0-9]$/.test(e.code));
  if (!app) return;
  e.preventDefault();
  e.stopPropagation();
}

const shellEl = () => document.querySelector('.shell');

/**
 * Registers a modal surface: the shell below becomes inert while at least one is open.
 * @param {HTMLElement} surface
 */
export function pushModal(surface) {
  if (!guardOn) {
    window.addEventListener('keydown', guardShortcuts, true);
    guardOn = true;
  }
  const shell = shellEl();
  if (!modals.length && shell) shellWasInert = shell.inert;
  modals.push(surface);
  if (shell) shell.inert = true;
  modals.forEach((m, n) => { m.inert = n !== modals.length - 1; });
}

/** Unregisters a modal surface; the previous one (or the shell) becomes interactive again. */
export function popModal(surface) {
  const at = modals.indexOf(surface);
  if (at >= 0) modals.splice(at, 1);
  surface.inert = false;
  modals.forEach((m, n) => { m.inert = n !== modals.length - 1; });
  const shell = shellEl();
  if (!modals.length && shell) shell.inert = shellWasInert;
}

/** True while a dialog or a modal drawer is open. */
export function modalOpen() {
  return modals.length > 0;
}

/**
 * Keeps the keyboard focus inside a container (Tab and Shift+Tab wrap). Focus that escapes to the page is brought
 * back, except into floating menus and popovers, which sit above every surface.
 * @param {HTMLElement} container
 * @returns {() => void} release
 */
export function trapFocus(container) {
  const onKey = (e) => {
    if (e.key !== 'Tab') return;
    const list = focusables(container);
    if (!list.length) { e.preventDefault(); container.focus({ preventScroll: true }); return; }
    const first = list[0];
    const last = list[list.length - 1];
    const active = document.activeElement;
    if (e.shiftKey && (active === first || active === container)) { e.preventDefault(); last.focus(); }
    else if (!e.shiftKey && active === last) { e.preventDefault(); first.focus(); }
  };
  const onFocus = (e) => {
    const t = e.target;
    if (!(t instanceof Element) || container.contains(t) || t.closest('.k-menu, .k-pop')) return;
    if (modals.length && modals[modals.length - 1] !== container.closest('.k-surface')) return;
    (focusables(container)[0] ?? container).focus({ preventScroll: true });
  };
  container.addEventListener('keydown', onKey);
  document.addEventListener('focusin', onFocus);
  return () => {
    container.removeEventListener('keydown', onKey);
    document.removeEventListener('focusin', onFocus);
  };
}

// ---------- Floating placement ----------

/**
 * Places a fixed-position element next to an anchor (element or rectangle) or at a point, flipped and clamped to
 * stay inside the window. Sets --fx / --fy (translate) and data-side for the entrance direction.
 * @param {HTMLElement} floating
 * @param {Element | DOMRect | { x: number, y: number }} target
 * @param {{ placement?: 'bottom-start'|'bottom-end'|'top-start'|'right-start', gap?: number }} [opts]
 */
export function placeFloating(floating, target, { placement = 'bottom-start', gap = 6 } = {}) {
  const w = floating.offsetWidth;
  const h = floating.offsetHeight;
  const vw = innerWidth;
  const vh = innerHeight;
  let rect;
  if (target instanceof Element) rect = target.getBoundingClientRect();
  else if ('width' in target) rect = target;
  else rect = { left: target.x, right: target.x, top: target.y, bottom: target.y, width: 0, height: 0 };
  let x;
  let y;
  let side;
  if (placement === 'right-start') {
    x = rect.right + gap - 2;
    y = rect.top - 6;
    if (x + w > vw - 8) x = rect.left - w - gap + 2;
    side = 'right';
  } else {
    x = placement.endsWith('end') ? rect.right - w : rect.left;
    const below = rect.bottom + gap;
    const above = rect.top - gap - h;
    const wantTop = placement.startsWith('top');
    if (wantTop) y = above >= 8 || below + h > vh - 8 ? above : below;
    else y = below + h <= vh - 8 || above < 8 ? below : above;
    side = y < rect.top ? 'top' : 'bottom';
  }
  x = clamp(x, 8, Math.max(8, vw - w - 8));
  y = clamp(y, 8, Math.max(8, vh - h - 8));
  setVars(floating, { '--fx': `${Math.round(x)}px`, '--fy': `${Math.round(y)}px` });
  floating.dataset.side = side;
}

/**
 * Plays a leaving animation (class `leaving`) then resolves; immediate when motion is reduced.
 * @param {HTMLElement} node @param {number} [maxMs]
 * @returns {Promise<void>}
 */
export function leave(node, maxMs = 420) {
  return new Promise((resolve) => {
    if (motionReduced() || !node.isConnected) { resolve(); return; }
    let done = false;
    const finish = () => { if (!done) { done = true; resolve(); } };
    node.classList.add('leaving');
    node.addEventListener('animationend', (e) => { if (e.target === node) finish(); });
    setTimeout(finish, maxMs);
  });
}

// ---------- Memory of layouts (per key, local preferences) ----------

const STORE_PREFIX = 'domenia.kit.v1:';
let storeAdapter = null;

/**
 * Replaces the layout store (e.g. the application preferences through the bridge, LocalWrite class).
 * Without an adapter, layouts go to localStorage; no row of data and no secret is ever stored.
 * @param {{ read(key: string): any, write(key: string, value: any): void } | null} adapter
 */
export function setLayoutStore(adapter) {
  storeAdapter = adapter && typeof adapter.read === 'function' && typeof adapter.write === 'function' ? adapter : null;
}

/** Reads a stored layout (null when absent or unreadable). */
export function readLayout(key) {
  if (!key) return null;
  try {
    if (storeAdapter) return storeAdapter.read(key) ?? null;
    const raw = localStorage.getItem(STORE_PREFIX + key);
    return raw ? JSON.parse(raw) : null;
  } catch (err) {
    console.warn('Disposition illisible, valeurs par défaut', key, err);
    return null;
  }
}

/** Stores a layout (null removes it). Failures are logged, never thrown. */
export function writeLayout(key, value) {
  if (!key) return;
  try {
    if (storeAdapter) { storeAdapter.write(key, value); return; }
    if (value == null) localStorage.removeItem(STORE_PREFIX + key);
    else localStorage.setItem(STORE_PREFIX + key, JSON.stringify(value));
  } catch (err) {
    console.warn('Disposition non enregistrée', key, err);
  }
}

/** Highlights the first accent- and case-insensitive occurrence of query in text (escaped output). */
export function highlight(text, query) {
  const raw = String(text ?? '');
  if (!query) return esc(raw);
  const chars = [...raw];
  const folded = chars.map((c) => fold(c));
  const at = folded.join('').indexOf(query);
  if (at < 0) return esc(raw);
  let pos = 0;
  let start = -1;
  let end = -1;
  folded.forEach((f, n) => {
    if (start < 0 && pos + f.length > at) start = n;
    if (end < 0 && pos + f.length >= at + query.length) end = n + 1;
    pos += f.length;
  });
  if (start < 0 || end < 0) return esc(raw);
  return `${esc(chars.slice(0, start).join(''))}<mark>${esc(chars.slice(start, end).join(''))}</mark>${esc(chars.slice(end).join(''))}`;
}
