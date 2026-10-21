// Virtualized data grid: declarative columns, multi-column sort, column and quick filters, column choice, order and
// width, keyboard and pointer selection, active cell, context menu, skeleton, empty states, « n sur m » counter,
// CSV and tab-separated copies, layout memory per key with undo. Smooth with 10 000 rows and more: only the rows in
// view (plus a margin) exist in the page. Local only: filtering and sorting never read the directory.
import { glyph } from './glyphs.js';
import { openMenu } from './menu.js';
import {
  esc, fold, uid, clamp, debounce, rafThrottle, setVars, int, dec, count, quote, NBSP, announce, toast,
  writeClipboard, readLayout, writeLayout, isTextEntry,
} from './util.js';
import { relTime, formatDateTime } from '../ui.js';

/**
 * @typedef {Object} GridColumn
 * @property {string} id                       Stable key (layout memory, CSV, filters).
 * @property {string} label                    Header text (French).
 * @property {'text'|'number'|'date'|'bool'|'enum'} [type='text']
 * @property {(row: any) => any} [get]         Raw value (default: row[id]).
 * @property {(value: any, row: any) => string} [format]  Display text (escaped by the grid).
 * @property {(value: any, row: any) => string} [html]    Trusted cell markup (must escape its own data).
 * @property {(value: any, row: any) => string} [csv]     Text for CSV and copies (default: display text, absolute dates).
 * @property {(value: any, row: any) => any} [sortKey]    Sort key (default by type).
 * @property {Array<{value: any, label: string, tone?: 'ok'|'warn'|'alert'|'info'|'off'}>} [options]  Values of an enum column.
 * @property {number} [width]                  Initial width in px (40 to 1600).
 * @property {number} [minWidth] @property {number} [maxWidth]
 * @property {'start'|'end'|'center'} [align]
 * @property {number} [decimals]               Number columns.
 * @property {'relative'|'datetime'|'date'} [dateStyle='relative']
 * @property {boolean} [sortable=true] @property {boolean} [filterable=true]
 * @property {boolean} [hidden=false]          Hidden by default (can be shown from « Colonnes »).
 * @property {boolean} [required=false]        Can never be hidden (e.g. « Nom »).
 * @property {boolean} [secret=false]          Never copied nor exported.
 * @property {boolean} [mono=false]            Monospace (DN, GUID, SID).
 * @property {string} [tip]                    Header tooltip.
 */

/**
 * @typedef {Object} GridOptions
 * @property {GridColumn[]} columns
 * @property {any[]} [rows]
 * @property {(row: any, index: number) => string} [rowId]   Stable identity (GUID); default row.id ?? row.guid ?? index.
 * @property {string} [key]                    Layout memory key (order, widths, hidden columns, sort, density).
 * @property {string} label                    Accessible name of the grid.
 * @property {'none'|'single'|'multi'} [selection='multi']
 * @property {boolean} [checkboxes]            Selection column (default: true in multi mode).
 * @property {'compact'|'normal'|'comfortable'} [density='normal']
 * @property {string} [height]                 CSS height of the scrolling area (default 520px; 'fill' fills a flex parent).
 * @property {boolean} [toolbar=true]          Quick filter, counter and tools above the grid.
 * @property {boolean} [quickFilter=true]
 * @property {string} [quickPlaceholder]
 * @property {boolean} [loading]               Starts in skeleton state.
 * @property {{icon?: string, title: string, text?: string, action?: {label: string, icon?: string, run: () => void}}} [empty]
 * @property {number} [selectionBarMin=2]      Selected rows from which the selection bar shows.
 * @property {boolean} [autoLoadMore=false]    true only for local reads; network reads keep the explicit button.
 * @property {(row: any) => void} [onActivate]               Double click or Enter.
 * @property {(rows: any[], ids: string[]) => void} [onSelectionChange]
 * @property {(row: any|null) => void} [onActiveChange]
 * @property {(ctx: {rows: any[], row: any, column: GridColumn|null}) => any[]} [contextMenu]  Extra menu items.
 * @property {(rows: any[]) => Array<{label: string, icon?: string, run: (rows: any[]) => void, danger?: boolean, disabled?: boolean, reason?: string}>} [selectionActions]
 * @property {() => void} [onLoadMore]
 * @property {(csv: string, info: {rows: number, columns: number, scope: string}) => void} [onExport]  Replaces the clipboard copy.
 * @property {(info: {quick: string, columns: Object<string,string>, shown: number, total: number}) => void} [onFilterChange]
 */

const DENSITY = { compact: 32, normal: 40, comfortable: 48 };
const DENSITY_LABEL = { compact: 'Compacte', normal: 'Normale', comfortable: 'Confortable' };
const SEL_W = 44;
const OVERSCAN = 6;
const MIN_W = 40;
const MAX_W = 1600;
const MAX_COLUMNS = 100;
const UNDO_MAX = 10;
const QUICK_DELAY = 180;
const COLUMN_DELAY = 260;
const FILTER_MAX = 120;
const DRAG_THRESHOLD = 5;
const LONG_TEXT = 26;
const collator = new Intl.Collator('fr', { numeric: true, sensitivity: 'base' });
const DAY = 86_400_000;
const DATE_PRESETS = [
  { value: '1d', label: 'Dernières 24 h', test: (t, now) => t >= now - DAY },
  { value: '7d', label: '7 derniers jours', test: (t, now) => t >= now - 7 * DAY },
  { value: '30d', label: '30 derniers jours', test: (t, now) => t >= now - 30 * DAY },
  { value: 'old90', label: 'Plus de 90 jours', test: (t, now) => Number.isFinite(t) && t < now - 90 * DAY },
  { value: 'none', label: 'Jamais ou inconnue', test: (t) => !Number.isFinite(t) },
];
const pad2 = (n) => String(n).padStart(2, '0');

function toTime(v) {
  if (v instanceof Date) return v.getTime();
  if (typeof v === 'number') return v;
  const t = Date.parse(v ?? '');
  return Number.isNaN(t) ? NaN : t;
}

function absoluteDate(t, withTime = true) {
  if (!Number.isFinite(t)) return '';
  const d = new Date(t);
  const day = `${pad2(d.getDate())}/${pad2(d.getMonth() + 1)}/${d.getFullYear()}`;
  return withTime ? `${day} ${pad2(d.getHours())}:${pad2(d.getMinutes())}` : day;
}

function normalize(columns) {
  return columns.slice(0, MAX_COLUMNS).map((c) => {
    const type = c.type ?? 'text';
    const minWidth = clamp(c.minWidth ?? 56, MIN_W, MAX_W);
    const maxWidth = clamp(c.maxWidth ?? MAX_W, minWidth, MAX_W);
    const base = c.width ?? (type === 'number' ? 110 : type === 'date' ? 150 : type === 'bool' ? 90 : 170);
    return {
      ...c,
      id: String(c.id),
      label: String(c.label ?? c.id),
      type,
      get: typeof c.get === 'function' ? c.get : (row) => row?.[c.id],
      width: clamp(base, minWidth, maxWidth),
      minWidth,
      maxWidth,
      align: c.align ?? (type === 'number' ? 'end' : 'start'),
      sortable: c.sortable !== false,
      filterable: c.filterable !== false,
      hidden: c.hidden === true,
      required: c.required === true,
      secret: c.secret === true,
      dateStyle: c.dateStyle ?? 'relative',
      options: Array.isArray(c.options) ? c.options : null,
    };
  });
}

// Display text of a value (what the operator reads, what the filters search).
function displayText(col, value, row) {
  if (typeof col.format === 'function') return String(col.format(value, row) ?? '');
  switch (col.type) {
    case 'number': return Number.isFinite(value) ? (col.decimals ? dec(value, col.decimals) : int(value)) : '';
    case 'bool': return value === true ? 'Oui' : value === false ? 'Non' : '';
    case 'enum': return col.options?.find((o) => o.value === value)?.label ?? String(value ?? '');
    case 'date': {
      const t = toTime(value);
      if (!Number.isFinite(t)) return '';
      if (col.dateStyle === 'date') return absoluteDate(t, false);
      if (col.dateStyle === 'datetime') return absoluteDate(t, true);
      return relTime(new Date(t).toISOString()) ?? '';
    }
    default: return value == null ? '' : String(value);
  }
}

// Text for CSV and copies: absolute dates, plain numbers with a decimal comma.
function plainText(col, value, row) {
  if (typeof col.csv === 'function') return String(col.csv(value, row) ?? '');
  if (col.type === 'date') return absoluteDate(toTime(value), col.dateStyle !== 'date');
  if (col.type === 'number') return Number.isFinite(value) ? String(value).replace('.', ',') : '';
  return displayText(col, value, row);
}

function sortKeyOf(col, value, row) {
  if (typeof col.sortKey === 'function') return col.sortKey(value, row);
  switch (col.type) {
    case 'number': return Number.isFinite(value) ? value : null;
    // An unreadable or missing date sorts as the oldest one (Domenia 1, RCH-075).
    case 'date': { const t = toTime(value); return Number.isFinite(t) ? t : -Infinity; }
    case 'bool': return value === true ? 1 : value === false ? 0 : null;
    case 'enum': {
      const at = col.options?.findIndex((o) => o.value === value) ?? -1;
      return at >= 0 ? at : null;
    }
    default: { const s = displayText(col, value, row); return s === '' ? null : s; }
  }
}

function compareKeys(a, b) {
  if (a === b) return 0;
  if (a === null || a === undefined) return 1; // empty values stay at the end in both directions
  if (b === null || b === undefined) return -1;
  if (typeof a === 'number' && typeof b === 'number') return a < b ? -1 : a > b ? 1 : 0;
  return collator.compare(String(a), String(b));
}

// Number filter: « >10 », « <= 5 », « =3 », « 10..20 », or a plain number (equality).
function numberTest(raw) {
  const s = raw.replace(/\s/g, '').replace(',', '.');
  const range = /^(-?\d+(?:\.\d+)?)\.\.(-?\d+(?:\.\d+)?)$/.exec(s);
  if (range) { const lo = Number(range[1]); const hi = Number(range[2]); return (v) => Number.isFinite(v) && v >= lo && v <= hi; }
  const op = /^(>=|<=|>|<|=)?(-?\d+(?:\.\d+)?)$/.exec(s);
  if (!op) return null;
  const n = Number(op[2]);
  switch (op[1]) {
    case '>': return (v) => Number.isFinite(v) && v > n;
    case '>=': return (v) => Number.isFinite(v) && v >= n;
    case '<': return (v) => Number.isFinite(v) && v < n;
    case '<=': return (v) => Number.isFinite(v) && v <= n;
    default: return (v) => Number.isFinite(v) && v === n;
  }
}

/**
 * Creates a data grid in host (its content is replaced).
 * @param {HTMLElement} host
 * @param {GridOptions} options
 */
export function createGrid(host, options) {
  const gid = uid('grid');
  const o = options;
  const selection = o.selection ?? 'multi';
  const lead = selection === 'multi' && o.checkboxes !== false ? 1 : 0;
  const rowIdOf = typeof o.rowId === 'function' ? o.rowId : (row, n) => String(row?.id ?? row?.guid ?? n);

  /** @type {ReturnType<typeof normalize>} */
  let cols = [];
  let colById = new Map();
  let layoutKey = o.key ? `grid:${o.key}` : null;

  const st = {
    rows: [],
    ids: [],
    index: new Map(),
    view: [],
    order: [],
    hidden: new Set(),
    widths: new Map(),
    sort: [],
    density: DENSITY[o.density] ? o.density : 'normal',
    quick: '',
    colFilters: new Map(),
    tests: new Map(),
    sel: new Set(),
    anchor: null,
    active: { pos: 0, col: 0 },
    activeId: null,
    loading: o.loading === true,
    error: null,
    empty: o.empty ?? null,
    hasMore: false,
    loadingMore: false,
    filtersOpen: false,
    enterNext: true,
    undo: [],
    kbd: false,
  };
  const caches = { text: new Map(), key: new Map(), all: null };

  host.innerHTML = `<div class="k-grid" data-density="${st.density}">
    ${o.toolbar === false ? '' : `<div class="k-gbar">
      ${o.quickFilter === false ? '' : `<label class="k-gsearch">${glyph('search')}<span class="visually-hidden">Filtrer les lignes chargées, sans lecture de l’annuaire</span>
        <input class="k-gq" type="search" maxlength="${FILTER_MAX}" autocomplete="off" spellcheck="false" placeholder="${esc(o.quickPlaceholder ?? 'Filtrer les lignes…')}"></label>`}
      <div class="k-gcount"></div>
      <div class="k-gslot"></div>
      <div class="k-gtools">
        <button class="btn ghost icon sm k-gundo" type="button" hidden aria-label="Annuler le dernier changement de disposition">${glyph('undo')}</button>
        <button class="btn ghost icon sm k-gfilters" type="button" aria-pressed="false" aria-label="Filtres par colonne" data-tip="Filtres par colonne">${glyph('filter')}<span class="k-badge" hidden></span></button>
        <button class="btn ghost icon sm k-gcols" type="button" aria-haspopup="menu" aria-expanded="false" aria-label="Colonnes et affichage" data-tip="Colonnes et affichage">${glyph('columns')}</button>
        <button class="btn ghost icon sm k-gexport" type="button" aria-haspopup="menu" aria-expanded="false" aria-label="Copier ou exporter en CSV" data-tip="Copier ou exporter en CSV">${glyph('csv')}</button>
      </div>
    </div>`}
    <div class="k-gframe">
      <div class="k-gscroll" role="grid" tabindex="0" aria-label="${esc(o.label ?? 'Liste')}"${selection === 'multi' ? ' aria-multiselectable="true"' : ''}>
        <div class="k-gtable">
          <div class="k-ghead" role="rowgroup"><div class="k-ghrow" role="row" aria-rowindex="1"></div><div class="k-gfrow" role="row" aria-rowindex="2" hidden></div><span class="k-gdrop" aria-hidden="true"></span></div>
          <div class="k-gbody" role="rowgroup"></div>
          <div class="k-gfoot" role="rowgroup" hidden></div>
        </div>
      </div>
      <div class="k-goverlay" hidden></div>
      <div class="k-gselbar" role="region" aria-label="Sélection" hidden></div>
    </div>
    <p class="visually-hidden k-ghelp" id="${gid}-help">Flèches pour se déplacer, Espace pour sélectionner, Entrée pour ouvrir, Maj F10 pour le menu. En-têtes : Entrée trie, Maj Entrée ajoute au tri, Alt flèches déplace la colonne, Ctrl flèches change sa largeur.</p>
  </div>`;

  const root = /** @type {HTMLElement} */ (host.querySelector('.k-grid'));
  const scroller = /** @type {HTMLElement} */ (root.querySelector('.k-gscroll'));
  const table = /** @type {HTMLElement} */ (root.querySelector('.k-gtable'));
  const head = /** @type {HTMLElement} */ (root.querySelector('.k-ghead'));
  const hrow = /** @type {HTMLElement} */ (root.querySelector('.k-ghrow'));
  const frow = /** @type {HTMLElement} */ (root.querySelector('.k-gfrow'));
  const drop = /** @type {HTMLElement} */ (root.querySelector('.k-gdrop'));
  const body = /** @type {HTMLElement} */ (root.querySelector('.k-gbody'));
  const foot = /** @type {HTMLElement} */ (root.querySelector('.k-gfoot'));
  const overlay = /** @type {HTMLElement} */ (root.querySelector('.k-goverlay'));
  const selbar = /** @type {HTMLElement} */ (root.querySelector('.k-gselbar'));
  const quickInput = /** @type {HTMLInputElement|null} */ (root.querySelector('.k-gq'));
  const countEl = root.querySelector('.k-gcount');
  const undoBtn = root.querySelector('.k-gundo');
  const filtersBtn = root.querySelector('.k-gfilters');
  const colsBtn = root.querySelector('.k-gcols');
  const exportBtn = root.querySelector('.k-gexport');
  scroller.setAttribute('aria-describedby', `${gid}-help`);
  if (o.height === 'fill') root.classList.add('fill');
  else setVars(root, { '--k-grid-h': o.height ?? '520px' });

  const rendered = new Map(); // view position → row element
  let headH = 0;
  let alive = true;

  // ---------- Columns and layout ----------

  function defaults() {
    st.order = cols.map((c) => c.id);
    st.hidden = new Set(cols.filter((c) => c.hidden && !c.required).map((c) => c.id));
    st.widths = new Map(cols.map((c) => [c.id, c.width]));
    st.sort = [];
    st.density = DENSITY[o.density] ? o.density : 'normal';
  }

  // Stored layouts are bounded and filtered: unknown ids are ignored, widths clamped, nothing else is read.
  function applyStored(saved) {
    if (!saved || typeof saved !== 'object' || saved.v !== 1) return;
    if (Array.isArray(saved.order)) {
      const known = saved.order.filter((id) => typeof id === 'string' && colById.has(id));
      const rest = cols.map((c) => c.id).filter((id) => !known.includes(id));
      st.order = [...new Set([...known, ...rest])];
    }
    if (Array.isArray(saved.hidden)) {
      st.hidden = new Set(saved.hidden.filter((id) => colById.has(id) && !colById.get(id).required));
    }
    if (saved.widths && typeof saved.widths === 'object') {
      for (const [id, w] of Object.entries(saved.widths)) {
        const c = colById.get(id);
        if (c && Number.isFinite(w)) st.widths.set(id, clamp(Math.round(w), c.minWidth, c.maxWidth));
      }
    }
    if (Array.isArray(saved.sort)) {
      st.sort = saved.sort.filter((s) => s && colById.get(s.id)?.sortable && (s.dir === 1 || s.dir === -1))
        .slice(0, 4).map((s) => ({ id: s.id, dir: s.dir }));
    }
    if (DENSITY[saved.density]) st.density = saved.density;
  }

  function snapshot() {
    return {
      v: 1,
      order: [...st.order],
      hidden: [...st.hidden],
      widths: Object.fromEntries(st.widths),
      sort: st.sort.map((s) => ({ ...s })),
      density: st.density,
    };
  }

  const persist = debounce(() => { if (layoutKey) writeLayout(layoutKey, snapshot()); }, 300);

  // Every layout change is undoable (10 steps) and remembered under the key; data never is.
  function changeLayout(label, fn, before = snapshot()) {
    fn();
    const after = snapshot();
    if (JSON.stringify(before) === JSON.stringify(after)) return false;
    st.undo.push({ label, state: before });
    if (st.undo.length > UNDO_MAX) st.undo.shift();
    persist();
    paintUndo();
    return true;
  }

  function undo() {
    const step = st.undo.pop();
    if (!step) return;
    const keepSort = JSON.stringify(st.sort);
    defaults();
    applyStored(step.state);
    persist();
    paintUndo();
    rebuildColumns();
    if (JSON.stringify(st.sort) !== keepSort) resort();
    announce(`Annulé${NBSP}: ${step.label}.`);
  }

  function paintUndo() {
    if (!undoBtn) return;
    const last = st.undo.at(-1);
    undoBtn.hidden = !last;
    if (last) undoBtn.dataset.tip = `Annuler${NBSP}: ${last.label} (Ctrl Z)`;
  }

  const visible = () => st.order.map((id) => colById.get(id)).filter((c) => c && !st.hidden.has(c.id));

  function setTemplate() {
    const vis = visible();
    const parts = vis.map((c, n) => {
      const w = st.widths.get(c.id) ?? c.width;
      return n === vis.length - 1 ? `minmax(${w}px, 1fr)` : `${w}px`;
    });
    if (lead) parts.unshift(`${SEL_W}px`);
    const total = vis.reduce((s, c) => s + (st.widths.get(c.id) ?? c.width), lead ? SEL_W : 0);
    setVars(root, { '--k-cols': parts.join(' '), '--k-tw': `${total}px` });
    scroller.setAttribute('aria-colcount', String(vis.length + lead));
  }

  // ---------- Caches (per data version) ----------

  function resetCaches() {
    caches.text.clear();
    caches.key.clear();
    caches.all = null;
  }

  function textOf(col, ri) {
    let arr = caches.text.get(col.id);
    if (!arr) { arr = new Array(st.rows.length); caches.text.set(col.id, arr); }
    let v = arr[ri];
    if (v === undefined) {
      const row = st.rows[ri];
      v = fold(displayText(col, col.get(row), row));
      arr[ri] = v;
    }
    return v;
  }

  function keyOf(col, ri) {
    let arr = caches.key.get(col.id);
    if (!arr) { arr = new Array(st.rows.length); caches.key.set(col.id, arr); }
    let v = arr[ri];
    if (v === undefined) {
      const row = st.rows[ri];
      v = sortKeyOf(col, col.get(row), row);
      if (v === undefined) v = null;
      arr[ri] = v;
    }
    return v;
  }

  // Folded text of the visible, non-secret columns (quick filter).
  function allText(ri) {
    if (!caches.all) caches.all = new Array(st.rows.length);
    let v = caches.all[ri];
    if (v === undefined) {
      v = visible().filter((c) => !c.secret).map((c) => textOf(c, ri)).join('\u0001');
      caches.all[ri] = v;
    }
    return v;
  }

  // ---------- Filter and sort ----------

  function compileFilter(col, raw) {
    const value = raw.trim();
    if (!value) return null;
    if (col.type === 'enum' && col.options) {
      const opt = col.options.find((x) => String(x.value) === value);
      return opt ? (ri) => col.get(st.rows[ri]) === opt.value : null;
    }
    if (col.type === 'bool') return (ri) => String(col.get(st.rows[ri]) === true) === value;
    if (col.type === 'date') {
      const preset = DATE_PRESETS.find((p) => p.value === value);
      if (!preset) return null;
      const now = Date.now();
      return (ri) => preset.test(toTime(col.get(st.rows[ri])), now);
    }
    if (col.type === 'number') {
      const t = numberTest(value);
      if (t) return (ri) => t(col.get(st.rows[ri]));
    }
    const words = fold(value).split(/\s+/).filter(Boolean);
    return (ri) => { const s = textOf(col, ri); return words.every((w) => s.includes(w)); };
  }

  function computeView() {
    const words = fold(st.quick).split(/\s+/).filter(Boolean);
    const tests = [...st.tests.values()];
    const out = [];
    for (let ri = 0; ri < st.rows.length; ri++) {
      if (words.length) {
        const s = allText(ri);
        if (!words.every((w) => s.includes(w))) continue;
      }
      if (tests.length && !tests.every((t) => t(ri))) continue;
      out.push(ri);
    }
    if (st.sort.length) {
      const keys = st.sort.map((s) => ({ col: colById.get(s.id), dir: s.dir })).filter((k) => k.col);
      out.sort((a, b) => {
        for (const k of keys) {
          const ka = keyOf(k.col, a);
          const kb = keyOf(k.col, b);
          if (ka === null || kb === null) { const c = compareKeys(ka, kb); if (c) return c; continue; }
          const c = compareKeys(ka, kb) * k.dir;
          if (c) return c;
        }
        return a - b;
      });
    }
    st.view = out;
  }

  // ---------- Header ----------

  function headerMarkup() {
    const vis = visible();
    const primary = st.sort[0];
    const multi = st.sort.length > 1;
    const sel = lead ? `<div class="k-gh sel" role="columnheader" id="${gid}-h-0" aria-colindex="1"><span class="k-check" aria-hidden="true"></span><span class="visually-hidden">Sélection</span></div>` : '';
    return sel + vis.map((c, n) => {
      const k = n + lead;
      const s = st.sort.findIndex((x) => x.id === c.id);
      const dir = s >= 0 ? st.sort[s].dir : 0;
      const ariaSort = primary?.id === c.id ? ` aria-sort="${dir > 0 ? 'ascending' : 'descending'}"` : (c.sortable ? ' aria-sort="none"' : '');
      const sortMark = s >= 0 ? `<span class="k-gh-sort${dir < 0 ? ' desc' : ''}" aria-hidden="true">${glyph('arrowUp')}${multi ? `<b>${s + 1}</b>` : ''}</span>` : '';
      const tip = c.tip ? ` data-tip="${esc(c.tip)}"` : '';
      const filtered = st.tests.has(c.id) ? ' filtered' : '';
      return `<div class="k-gh${c.sortable ? ' sortable' : ''}${filtered} a-${c.align}" role="columnheader" id="${gid}-h-${k}" aria-colindex="${k + 1}" data-col="${esc(c.id)}" data-c="${k}"${ariaSort}${tip}>`
        + `<span class="k-gh-label">${esc(c.label)}</span>${st.tests.has(c.id) ? `<span class="k-gh-filt" aria-hidden="true">${glyph('filter')}</span>` : ''}${sortMark}`
        + `<button class="k-gh-menu" type="button" tabindex="-1" aria-label="Options de la colonne ${esc(c.label)}">${glyph('chevronDown')}</button>`
        + '<span class="k-gh-resize" aria-hidden="true"></span></div>';
    }).join('');
  }

  function filterMarkup() {
    const vis = visible();
    const blank = lead ? '<div class="k-gf sel" role="gridcell"></div>' : '';
    return blank + vis.map((c) => {
      const raw = st.colFilters.get(c.id) ?? '';
      const label = `Filtrer la colonne ${c.label}`;
      if (!c.filterable || c.secret) return '<div class="k-gf" role="gridcell"></div>';
      let control;
      if ((c.type === 'enum' && c.options) || c.type === 'bool' || c.type === 'date') {
        const opts = c.type === 'bool' ? [{ value: 'true', label: 'Oui' }, { value: 'false', label: 'Non' }]
          : c.type === 'date' ? DATE_PRESETS : c.options.map((x) => ({ value: String(x.value), label: x.label }));
        control = `<span class="k-select sm"><select class="input k-gf-in" data-col="${esc(c.id)}" aria-label="${esc(label)}">`
          + `<option value="">Tous</option>${opts.map((x) => `<option value="${esc(x.value)}"${String(x.value) === raw ? ' selected' : ''}>${esc(x.label)}</option>`).join('')}</select></span>`;
      } else {
        const ph = c.type === 'number' ? '> 10, 5..20' : 'Contient…';
        control = `<input class="input k-gf-in" type="search" data-col="${esc(c.id)}" aria-label="${esc(label)}" placeholder="${ph}" maxlength="${FILTER_MAX}" autocomplete="off" spellcheck="false" value="${esc(raw)}">`;
      }
      return `<div class="k-gf" role="gridcell">${control}</div>`;
    }).join('');
  }

  function paintHeader() {
    hrow.innerHTML = headerMarkup();
    paintHeadCheck();
    if (st.active.pos === -1) markActive();
  }

  function paintFilters() {
    frow.hidden = !st.filtersOpen;
    if (st.filtersOpen) frow.innerHTML = filterMarkup();
    if (filtersBtn) {
      filtersBtn.setAttribute('aria-pressed', String(st.filtersOpen));
      const badge = filtersBtn.querySelector('.k-badge');
      badge.hidden = st.tests.size === 0;
      badge.textContent = String(st.tests.size);
    }
  }

  function rebuildColumns() {
    setTemplate();
    caches.all = null;
    paintHeader();
    paintFilters();
    measureHead();
    st.active.col = clamp(st.active.col, 0, visible().length + lead - 1);
    renderRows(true);
  }

  // ---------- Rows ----------

  const rowH = () => DENSITY[st.density];
  const headRows = () => (st.filtersOpen ? 2 : 1);

  function cellMarkup(col, ri, row, pos, k) {
    const value = col.get(row);
    let inner;
    let tip = '';
    if (typeof col.html === 'function') {
      inner = col.html(value, row) ?? '';
    } else if (col.type === 'enum' && col.options) {
      const opt = col.options.find((x) => x.value === value);
      inner = opt ? `<span class="k-pill sm ${esc(opt.tone ?? 'off')}"><span class="k-pill-dot" aria-hidden="true"></span>${esc(opt.label)}</span>` : esc(value ?? '');
    } else if (col.type === 'date') {
      const t = toTime(value);
      inner = Number.isFinite(t) ? esc(displayText(col, value, row)) : '<span class="k-gnone">—</span>';
      if (Number.isFinite(t) && col.dateStyle === 'relative') tip = ` data-tip="${esc(formatDateTime(new Date(t).toISOString()) ?? '')}"`;
    } else {
      const text = displayText(col, value, row);
      inner = text === '' ? '<span class="k-gnone">—</span>' : esc(text);
      if (text.length > LONG_TEXT) tip = ` data-tip="${esc(text)}"`;
    }
    const cls = `k-gc a-${col.align}${col.mono ? ' mono' : ''}`;
    return `<div class="${cls}" role="gridcell" id="${gid}-${pos}-${k}" aria-colindex="${k + 1}"${tip}>${inner}</div>`;
  }

  function rowMarkup(pos) {
    const ri = st.view[pos];
    const row = st.rows[ri];
    const id = st.ids[ri];
    const sel = st.sel.has(id);
    const vis = visible();
    const selCell = lead ? `<div class="k-gc sel" role="gridcell" id="${gid}-${pos}-0" aria-colindex="1"><span class="k-check" aria-hidden="true"></span></div>` : '';
    const cells = vis.map((c, n) => cellMarkup(c, ri, row, pos, n + lead)).join('');
    const ariaSel = selection === 'none' ? '' : ` aria-selected="${sel}"`;
    const enter = st.enterNext ? ' k-enter' : '';
    return `<div class="k-gr${sel ? ' is-sel' : ''}${pos === st.active.pos ? ' is-cur' : ''}${enter}" role="row" aria-rowindex="${pos + headRows() + 1}" data-pos="${pos}"${ariaSel}>${selCell}${cells}</div>`;
  }

  function skeletonMarkup() {
    const n = clamp(Math.ceil((scroller.clientHeight || 400) / rowH()), 6, 16);
    const vis = visible();
    const widths = ['w70', 'w55', 'w85', 'w40', 'w70', 'w55'];
    let html = '';
    for (let r = 0; r < n; r++) {
      html += `<div class="k-gr k-skel" aria-hidden="true">${lead ? '<div class="k-gc sel"></div>' : ''}`
        + vis.map((c, k) => `<div class="k-gc"><span class="skeleton sk sk-line ${widths[(r + k) % widths.length]}"></span></div>`).join('')
        + '</div>';
    }
    return html;
  }

  function measureHead() {
    headH = head.offsetHeight;
    setVars(root, { '--k-headh': `${headH}px`, '--k-vw': `${scroller.clientWidth}px` });
  }

  // Renders the rows in view (plus OVERSCAN); force rebuilds them all (new data, columns or density).
  function renderRows(force = false) {
    if (!alive) return;
    if (st.loading) {
      body.classList.add('is-loading');
      body.style.removeProperty('height');
      body.innerHTML = skeletonMarkup();
      rendered.clear();
      return;
    }
    body.classList.remove('is-loading');
    const n = st.view.length;
    const rh = rowH();
    body.style.setProperty('height', `${n * rh}px`);
    scroller.setAttribute('aria-rowcount', String(n + headRows()));
    if (force) { body.replaceChildren(); rendered.clear(); }
    if (!n) { paintOverlay(); return; }
    const top = scroller.scrollTop;
    const viewH = Math.max(rh, scroller.clientHeight - headH);
    const first = Math.max(0, Math.floor(top / rh) - OVERSCAN);
    const last = Math.min(n - 1, Math.ceil((top + viewH) / rh) + OVERSCAN);
    for (const [pos, node] of rendered) {
      if ((pos < first || pos > last || pos >= n) && pos !== st.active.pos) { node.remove(); rendered.delete(pos); }
    }
    const wanted = [];
    for (let p = first; p <= last; p++) if (!rendered.has(p)) wanted.push(p);
    if (st.active.pos >= 0 && st.active.pos < n && !rendered.has(st.active.pos) && !wanted.includes(st.active.pos)) wanted.push(st.active.pos);
    if (wanted.length) {
      const t = document.createElement('template');
      t.innerHTML = wanted.map(rowMarkup).join('');
      const nodes = [...t.content.children];
      nodes.forEach((node, k) => {
        const pos = wanted[k];
        node.style.setProperty('transform', `translateY(${pos * rh}px)`);
        if (st.enterNext) node.style.setProperty('--j', String(Math.min(k, 14)));
        rendered.set(pos, /** @type {HTMLElement} */ (node));
      });
      body.append(...nodes);
    }
    st.enterNext = false;
    paintOverlay();
    markActive();
  }

  const onScroll = rafThrottle(() => {
    renderRows(false);
    maybeAutoLoad();
  });

  // ---------- Overlay: errors, empty list, list hidden by filters ----------

  function filtersActive() {
    return st.quick.trim() !== '' || st.tests.size > 0;
  }

  function paintOverlay() {
    let html = '';
    if (st.error) {
      html = `<div class="k-gstate alert" role="alert"><span class="k-gstate-art">${glyph('alert')}</span>
        <h3>Liste indisponible</h3><p>${esc(st.error.message)}</p>
        ${st.error.retry ? `<button class="btn sm" type="button" data-act="retry">${glyph('refresh')}Réessayer</button>` : ''}</div>`;
    } else if (!st.loading && st.rows.length === 0) {
      const e = st.empty ?? { title: 'Aucune ligne', text: 'Rien n’est chargé dans cette liste pour l’instant.' };
      html = `<div class="k-gstate"><span class="k-gstate-art">${glyph(e.icon ?? 'search')}</span><h3>${esc(e.title)}</h3>`
        + `${e.text ? `<p>${esc(e.text)}</p>` : ''}`
        + `${e.action ? `<button class="btn sm" type="button" data-act="empty">${e.action.icon ? glyph(e.action.icon) : ''}${esc(e.action.label)}</button>` : ''}</div>`;
    } else if (!st.loading && st.view.length === 0 && filtersActive()) {
      const which = [st.quick.trim() ? `filtre rapide ${quote(esc(st.quick.trim()))}` : '', st.tests.size ? count(st.tests.size, 'filtre de colonne', 'filtres de colonne') : ''].filter(Boolean).join(' et ');
      html = `<div class="k-gstate"><span class="k-gstate-art">${glyph('filter')}</span><h3>Aucune ligne ne correspond</h3>`
        + `<p>Le ${which} masque ${count(st.rows.length, 'ligne chargée', 'lignes chargées')}. Rien n’a été relu.</p>`
        + `<button class="btn sm" type="button" data-act="clear">${glyph('x')}Effacer les filtres</button></div>`;
    }
    overlay.hidden = html === '';
    if (overlay.innerHTML !== html) overlay.innerHTML = html;
  }

  overlay.addEventListener('click', (e) => {
    const b = e.target instanceof Element ? e.target.closest('[data-act]') : null;
    if (!b) return;
    if (b.dataset.act === 'retry') st.error?.retry?.();
    else if (b.dataset.act === 'empty') st.empty?.action?.run?.();
    else if (b.dataset.act === 'clear') { api.clearFilters(); scroller.focus({ preventScroll: true }); }
  });

  // ---------- Counter, selection bar, load more ----------

  function paintCount() {
    if (!countEl) return;
    if (st.loading) { countEl.innerHTML = '<span class="k-gcount-load">Chargement…</span>'; return; }
    const total = st.rows.length;
    const shown = st.view.length;
    const nSel = st.sel.size;
    const main = shown === total
      ? `<b>${int(total)}</b> ${total >= 2 ? 'lignes' : 'ligne'}`
      : `<b>${int(shown)}</b> sur ${int(total)} ${total >= 2 ? 'lignes' : 'ligne'}`;
    const sel = nSel ? `<span class="k-gcount-sel">${count(nSel, 'sélectionnée', 'sélectionnées')}</span>` : '';
    const more = st.hasMore ? `<span class="k-gcount-more" data-tip="D’autres lignes existent${NBSP}: « Charger la suite » les lit.">liste partielle<span class="visually-hidden">, d’autres lignes existent${NBSP}: « Charger la suite » les lit</span></span>` : '';
    const clear = filtersActive() ? `<button class="k-gclear" type="button" data-tip="Effacer les filtres">${glyph('x')}<span class="visually-hidden">Effacer les filtres</span></button>` : '';
    countEl.innerHTML = `<span class="k-gcount-main">${main}</span>${sel}${more}${clear}`;
  }

  countEl?.addEventListener('click', (e) => {
    if (e.target instanceof Element && e.target.closest('.k-gclear')) api.clearFilters();
  });

  let selActs = [];
  function paintSelbar() {
    const min = o.selectionBarMin ?? 2;
    const n = st.sel.size;
    const show = selection === 'multi' && n >= min;
    if (!show) {
      if (!selbar.hidden) {
        selbar.classList.add('leaving');
        setTimeout(() => { if (st.sel.size < min) { selbar.hidden = true; selbar.classList.remove('leaving'); } }, 220);
      }
      return;
    }
    const rows = api.getSelection();
    const acts = typeof o.selectionActions === 'function' ? (o.selectionActions(rows) ?? []) : [];
    selbar.classList.remove('leaving');
    selbar.hidden = false;
    selbar.innerHTML = `<span class="k-gsel-n"><b>${int(n)}</b> ${n >= 2 ? 'lignes sélectionnées' : 'ligne sélectionnée'}</span>`
      + acts.map((a, k) => `<button class="btn sm${a.danger ? ' danger' : ''}" type="button" data-sel="${k}"${a.disabled ? ` aria-disabled="true" data-tip="${esc(a.reason ?? '')}"` : ''}>${a.icon ? glyph(a.icon) : ''}${esc(a.label)}</button>`).join('')
      + `<button class="btn ghost sm" type="button" data-sel="copy">${glyph('copy')}Copier</button>`
      + `<button class="btn ghost icon sm k-gsel-x" type="button" data-sel="none" aria-label="Tout désélectionner" data-tip="Tout désélectionner (Échap)">${glyph('x')}</button>`;
    selActs = acts;
  }

  selbar.addEventListener('click', (e) => {
    const b = e.target instanceof Element ? e.target.closest('[data-sel]') : null;
    if (!b || b.getAttribute('aria-disabled') === 'true') return;
    const what = b.dataset.sel;
    if (what === 'none') { setSelection([], null); scroller.focus({ preventScroll: true }); return; }
    if (what === 'copy') { copyRows(api.getSelection(), true); return; }
    const act = selActs[Number(what)];
    act?.run?.(api.getSelection());
  });

  function paintFoot() {
    const show = st.hasMore && !st.loading && st.rows.length > 0;
    foot.hidden = !show;
    if (!show) return;
    foot.innerHTML = `<div class="k-gmore" role="row"><div role="gridcell">${st.loadingMore
      ? '<span class="k-spin" aria-hidden="true"></span>Chargement de la suite…'
      : `<button class="btn sm" type="button" data-act="more">${glyph('arrowDown')}Charger la suite</button>`}</div></div>`;
  }

  foot.addEventListener('click', (e) => {
    if (e.target instanceof Element && e.target.closest('[data-act="more"]')) requestMore();
  });

  function requestMore() {
    if (!st.hasMore || st.loadingMore || typeof o.onLoadMore !== 'function') return;
    st.loadingMore = true;
    paintFoot();
    o.onLoadMore();
  }

  function maybeAutoLoad() {
    if (!o.autoLoadMore || !st.hasMore || st.loadingMore) return;
    const rh = rowH();
    if (scroller.scrollTop + scroller.clientHeight >= st.view.length * rh + headH - rh * 5) requestMore();
  }

  // ---------- Selection and active cell ----------

  let notify = 0;
  function emitSelection() {
    cancelAnimationFrame(notify);
    notify = requestAnimationFrame(() => {
      if (!alive) return;
      o.onSelectionChange?.(api.getSelection(), [...st.sel]);
    });
  }

  function paintSelection() {
    for (const [pos, node] of rendered) {
      const ri = st.view[pos];
      if (ri === undefined) continue;
      const sel = st.sel.has(st.ids[ri]);
      node.classList.toggle('is-sel', sel);
      if (selection !== 'none') node.setAttribute('aria-selected', String(sel));
    }
    paintHeadCheck();
    paintCount();
    paintSelbar();
  }

  function paintHeadCheck() {
    if (!lead) return;
    const box = hrow.querySelector('.k-gh.sel .k-check');
    if (!box) return;
    const shownSel = st.view.reduce((s, ri) => s + (st.sel.has(st.ids[ri]) ? 1 : 0), 0);
    box.dataset.state = shownSel === 0 ? 'none' : shownSel === st.view.length ? 'all' : 'some';
  }

  function setSelection(ids, anchor) {
    st.sel = new Set(ids);
    if (anchor !== undefined) st.anchor = anchor;
    paintSelection();
    emitSelection();
  }

  function idAt(pos) {
    const ri = st.view[pos];
    return ri === undefined ? null : st.ids[ri];
  }

  function rangeIds(fromId, toPos) {
    const fromPos = fromId == null ? toPos : st.view.findIndex((ri) => st.ids[ri] === fromId);
    const a = Math.min(fromPos < 0 ? toPos : fromPos, toPos);
    const b = Math.max(fromPos < 0 ? toPos : fromPos, toPos);
    const out = [];
    for (let p = a; p <= b; p++) out.push(idAt(p));
    return out;
  }

  function selectAt(pos, { toggle = false, range = false, keep = false } = {}) {
    const id = idAt(pos);
    if (id == null || selection === 'none') return;
    if (selection === 'single') { setSelection([id], id); return; }
    if (range) {
      const ids = rangeIds(st.anchor, pos);
      setSelection(keep ? [...new Set([...st.sel, ...ids])] : ids, undefined);
      return;
    }
    if (toggle) {
      const next = new Set(st.sel);
      if (next.has(id)) next.delete(id); else next.add(id);
      setSelection([...next], id);
      return;
    }
    setSelection([id], id);
  }

  function cellId(pos, col) {
    return pos === -1 ? `${gid}-h-${col}` : `${gid}-${pos}-${col}`;
  }

  function markActive() {
    scroller.querySelectorAll('.is-act').forEach((n) => n.classList.remove('is-act'));
    scroller.querySelectorAll('.k-gr.is-cur').forEach((n) => n.classList.remove('is-cur'));
    const { pos, col } = st.active;
    if (pos >= 0) rendered.get(pos)?.classList.add('is-cur');
    const cell = document.getElementById(cellId(pos, col));
    if (cell && scroller.contains(cell)) {
      cell.classList.add('is-act');
      scroller.setAttribute('aria-activedescendant', cell.id);
    } else {
      scroller.removeAttribute('aria-activedescendant');
    }
  }

  function ensureVisible(pos, col) {
    const rh = rowH();
    if (pos >= 0) {
      const y = pos * rh;
      const viewH = scroller.clientHeight - headH;
      if (y < scroller.scrollTop) scroller.scrollTop = y;
      else if (y + rh > scroller.scrollTop + viewH) scroller.scrollTop = y + rh - viewH;
    }
    renderRows(false);
    const cell = document.getElementById(cellId(pos, col));
    if (cell && scroller.contains(cell)) {
      const left = cell.offsetLeft;
      const right = left + cell.offsetWidth;
      const stickySel = lead && col > 0 ? SEL_W : 0;
      if (left - stickySel < scroller.scrollLeft) scroller.scrollLeft = Math.max(0, left - stickySel);
      else if (right > scroller.scrollLeft + scroller.clientWidth) scroller.scrollLeft = right - scroller.clientWidth;
    }
  }

  function setActive(pos, col, { scroll = true } = {}) {
    const n = st.view.length;
    const maxCol = visible().length + lead - 1;
    const p = pos === -1 ? -1 : clamp(pos, 0, Math.max(0, n - 1));
    st.active = { pos: n === 0 && p >= 0 ? -1 : p, col: clamp(col, 0, maxCol) };
    const before = st.activeId;
    st.activeId = st.active.pos >= 0 ? idAt(st.active.pos) : null;
    if (scroll) ensureVisible(st.active.pos, st.active.col);
    markActive();
    if (before !== st.activeId) o.onActiveChange?.(st.activeId == null ? null : st.rows[st.index.get(st.activeId)]);
  }

  function restoreActive() {
    if (st.activeId != null) {
      const ri = st.index.get(st.activeId);
      const pos = ri === undefined ? -1 : st.view.indexOf(ri);
      if (pos >= 0) { st.active.pos = pos; return; }
    }
    st.active.pos = st.view.length ? clamp(st.active.pos, 0, st.view.length - 1) : -1;
    st.activeId = st.active.pos >= 0 ? idAt(st.active.pos) : null;
  }

  // ---------- Recompute after data, filter or sort changes ----------

  function refreshView({ keepScroll = true, announceCount = false } = {}) {
    computeView();
    restoreActive();
    if (!keepScroll) scroller.scrollTop = 0;
    renderRows(true);
    paintHeadCheck();
    paintCount();
    paintFoot();
    paintSelbar();
    if (announceCount) announceFilter();
    o.onFilterChange?.({ quick: st.quick, columns: Object.fromEntries(st.colFilters), shown: st.view.length, total: st.rows.length });
  }

  const announceFilter = debounce(() => {
    if (!alive) return;
    const total = st.rows.length;
    const shown = st.view.length;
    announce(filtersActive()
      ? (shown ? `${int(shown)} sur ${count(total, 'ligne', 'lignes')} affichées.` : 'Aucune ligne ne correspond au filtre.')
      : `${count(total, 'ligne affichée', 'lignes affichées')}.`);
  }, 450);

  function resort() {
    paintHeader();
    refreshView();
    if (!st.loading) {
      body.classList.remove('resorted');
      void body.offsetWidth;
      body.classList.add('resorted');
    }
  }

  function sortBy(id, { add = false, dir } = {}) {
    const col = colById.get(id);
    if (!col?.sortable) return;
    changeLayout('Tri', () => {
      const at = st.sort.findIndex((s) => s.id === id);
      if (dir === 0) { if (at >= 0) st.sort.splice(at, 1); return; }
      if (add) {
        if (at >= 0) st.sort[at].dir = dir ?? -st.sort[at].dir;
        else st.sort.push({ id, dir: dir ?? 1 });
        st.sort = st.sort.slice(0, 4);
        return;
      }
      // Plain click: ascending → descending → no sort.
      if (dir) st.sort = [{ id, dir }];
      else if (at === 0 && st.sort.length === 1) st.sort = st.sort[0].dir === 1 ? [{ id, dir: -1 }] : [];
      else st.sort = [{ id, dir: 1 }];
    });
    resort();
    const first = st.sort[0];
    announce(first
      ? `Trié par ${st.sort.map((s) => `${colById.get(s.id).label}, ${s.dir > 0 ? 'croissant' : 'décroissant'}`).join(', puis ')}.`
      : 'Tri retiré : ordre de chargement.');
  }

  const applyQuick = debounce((value) => {
    st.quick = value.slice(0, FILTER_MAX);
    refreshView({ announceCount: true });
  }, QUICK_DELAY);

  const applyColumnFilter = debounce((id, value) => setColumnFilter(id, value), COLUMN_DELAY);

  function setColumnFilter(id, value) {
    const col = colById.get(id);
    if (!col) return;
    const raw = String(value ?? '').slice(0, FILTER_MAX);
    if (raw.trim()) st.colFilters.set(id, raw); else st.colFilters.delete(id);
    const test = raw.trim() ? compileFilter(col, raw) : null;
    if (test) st.tests.set(id, test); else st.tests.delete(id);
    paintHeader();
    if (filtersBtn) {
      const badge = filtersBtn.querySelector('.k-badge');
      badge.hidden = st.tests.size === 0;
      badge.textContent = String(st.tests.size);
    }
    refreshView({ announceCount: true });
  }

  // ---------- Copies and CSV ----------

  const copyColumns = () => visible().filter((c) => !c.secret);

  function plainRow(row) {
    return copyColumns().map((c) => plainText(c, c.get(row), row));
  }

  function copyRows(rows, withHeader) {
    if (!rows.length) return;
    const cols2 = copyColumns();
    const lines = rows.map((r) => plainRow(r).map((v) => v.replace(/[\t\r\n]+/g, ' ')).join('\t'));
    if (withHeader) lines.unshift(cols2.map((c) => c.label).join('\t'));
    writeClipboard(lines.join('\r\n')).then((ok) => {
      toast(ok ? `Copié${NBSP}: ${count(rows.length, 'ligne', 'lignes')}.` : 'Copie impossible : le presse-papiers est indisponible.', { tone: ok ? 'ok' : 'warn', life: 2600 });
    });
  }

  function copyValue(text, what) {
    writeClipboard(text).then((ok) => {
      toast(ok ? `${what} copiée.` : 'Copie impossible : le presse-papiers est indisponible.', { tone: ok ? 'ok' : 'warn', life: 2200 });
    });
  }

  function csvCell(v) {
    let s = String(v ?? '');
    // Formula-looking cells are neutralised (Domenia 1, TRV-054).
    if (/^[=+\-@\t\r]/.test(s)) s = `'${s}`;
    return /[;"\r\n]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
  }

  function toCsv({ scope = 'visible', bom = false } = {}) {
    const rows = scope === 'selected' ? api.getSelection() : api.getVisibleRows();
    const cols2 = copyColumns();
    const lines = [cols2.map((c) => csvCell(c.label)).join(';')];
    for (const row of rows) lines.push(cols2.map((c) => csvCell(plainText(c, c.get(row), row))).join(';'));
    return (bom ? '﻿' : '') + lines.join('\r\n') + '\r\n';
  }

  function exportCsv(scope) {
    const rows = scope === 'selected' ? st.sel.size : st.view.length;
    const csv = toCsv({ scope, bom: typeof o.onExport === 'function' });
    const info = { rows, columns: copyColumns().length, scope };
    if (typeof o.onExport === 'function') { o.onExport(csv, info); return; }
    writeClipboard(csv).then((ok) => {
      toast(ok ? `CSV copié dans le presse-papiers${NBSP}: ${count(rows, 'ligne', 'lignes')}, ${count(info.columns, 'colonne', 'colonnes')}.`
        : 'Copie impossible : le presse-papiers est indisponible.', { tone: ok ? 'ok' : 'warn' });
    });
  }

  // ---------- Menus ----------

  function columnMenuItems(col) {
    const vis = visible();
    const at = vis.indexOf(col);
    const sorted = st.sort.find((s) => s.id === col.id);
    const items = [];
    if (col.sortable) {
      items.push(
        { label: 'Trier par ordre croissant', icon: 'arrowUp', run: () => sortBy(col.id, { dir: 1 }) },
        { label: 'Trier par ordre décroissant', icon: 'arrowDown', run: () => sortBy(col.id, { dir: -1 }) },
      );
      if (st.sort.length && !sorted) items.push({ label: 'Ajouter au tri', icon: 'sort', kbd: 'Maj clic', run: () => sortBy(col.id, { add: true, dir: 1 }) });
      if (sorted) items.push({ label: 'Retirer du tri', icon: 'x', run: () => sortBy(col.id, { dir: 0 }) });
      items.push('-');
    }
    if (col.filterable && !col.secret) {
      items.push({ label: 'Filtrer cette colonne', icon: 'filter', run: () => openFilters(col.id) });
      if (st.tests.has(col.id)) items.push({ label: 'Effacer le filtre de la colonne', icon: 'x', run: () => setColumnFilter(col.id, '') });
    }
    items.push(
      { label: 'Ajuster la largeur', icon: 'columns', run: () => autofit(col.id) },
      { label: 'Masquer la colonne', icon: 'eyeOff', disabled: col.required, reason: col.required ? 'Cette colonne reste toujours affichée.' : '', run: () => toggleColumn(col.id, false) },
      '-',
      { label: 'Déplacer vers la gauche', icon: 'chevronLeft', kbd: 'Alt ←', disabled: at <= 0, run: () => moveColumn(col.id, at - 1) },
      { label: 'Déplacer vers la droite', icon: 'chevronRight', kbd: 'Alt →', disabled: at >= vis.length - 1, run: () => moveColumn(col.id, at + 1) },
      '-',
      { label: 'Colonnes et affichage', icon: 'columns', items: viewMenuItems() },
    );
    return items;
  }

  function viewMenuItems() {
    const list = st.order.map((id) => colById.get(id)).filter(Boolean).map((c) => ({
      label: c.label,
      checked: !st.hidden.has(c.id),
      disabled: c.required,
      reason: c.required ? 'Cette colonne reste toujours affichée.' : '',
      keepOpen: true,
      run: (item) => toggleColumn(c.id, item.checked),
    }));
    return [
      { heading: 'Colonnes affichées' },
      ...list,
      '-',
      { heading: 'Densité' },
      ...Object.keys(DENSITY).map((d) => ({ label: DENSITY_LABEL[d], radio: 'density', checked: st.density === d, run: () => setDensity(d) })),
      '-',
      { label: 'Rétablir la disposition par défaut', icon: 'refresh', run: () => api.resetLayout() },
    ];
  }

  function exportMenuItems() {
    const nSel = st.sel.size;
    const toClipboard = typeof o.onExport !== 'function';
    return [
      { heading: toClipboard ? 'Copier en CSV (point-virgule, en-têtes en français)' : 'Exporter en CSV (point-virgule, en-têtes en français)' },
      { label: `Lignes affichées (${int(st.view.length)})`, icon: 'csv', disabled: st.view.length === 0, reason: 'Aucune ligne affichée.', run: () => exportCsv('visible') },
      { label: `Lignes sélectionnées (${int(nSel)})`, icon: 'csv', disabled: nSel === 0, reason: 'Aucune ligne sélectionnée.', run: () => exportCsv('selected') },
      '-',
      { label: 'Copier les lignes sélectionnées (texte tabulé)', icon: 'copy', kbd: 'Ctrl C', disabled: nSel === 0, reason: 'Aucune ligne sélectionnée.', run: () => copyRows(api.getSelection(), true) },
    ];
  }

  function rowMenuItems(column) {
    const rows = api.getSelection();
    const row = st.activeId == null ? null : st.rows[st.index.get(st.activeId)];
    const extra = typeof o.contextMenu === 'function' ? (o.contextMenu({ rows, row, column }) ?? []) : [];
    const copyCol = column && !column.secret ? column : null;
    const value = copyCol && row ? plainText(copyCol, copyCol.get(row), row) : '';
    const copy = {
      label: 'Copier', icon: 'copy', items: [
        { label: copyCol ? `La cellule ${quote(copyCol.label)}` : 'La cellule', disabled: !value, reason: 'Cellule vide ou protégée.', run: () => copyValue(value, 'Valeur') },
        { label: rows.length >= 2 ? `Les ${int(rows.length)} lignes sélectionnées` : 'La ligne', kbd: 'Ctrl C', disabled: !rows.length, reason: 'Aucune ligne sélectionnée.', run: () => copyRows(rows, rows.length > 1) },
        { label: copyCol ? `La colonne ${quote(copyCol.label)} de la sélection` : 'Une colonne', disabled: !copyCol || !rows.length, reason: 'Choisissez une cellule d’une colonne copiable.', run: () => copyValue(rows.map((r) => plainText(copyCol, copyCol.get(r), r)).join('\r\n'), 'Colonne') },
      ],
    };
    return [...extra, ...(extra.length ? ['-'] : []), copy, { label: 'Exporter en CSV', icon: 'csv', items: exportMenuItems().filter((x) => typeof x !== 'object' || !('heading' in x)) }];
  }

  // ---------- Columns: visibility, order, width, density ----------

  function toggleColumn(id, show) {
    const col = colById.get(id);
    if (!col || (col.required && !show)) return;
    const changed = changeLayout(show ? 'Colonne affichée' : 'Colonne masquée', () => {
      if (show) st.hidden.delete(id); else st.hidden.add(id);
    });
    if (!changed) return;
    if (st.tests.has(id) && !show) { st.colFilters.delete(id); st.tests.delete(id); }
    rebuildColumns();
    // The quick filter searches the visible columns: showing or hiding one can change the rows shown.
    refreshView();
    announce(`Colonne ${col.label} ${show ? 'affichée' : 'masquée'}.`);
  }

  function moveColumn(id, toVisibleIndex) {
    const vis = visible();
    const from = vis.findIndex((c) => c.id === id);
    const to = clamp(toVisibleIndex, 0, vis.length - 1);
    if (from < 0 || from === to) return;
    changeLayout('Ordre des colonnes', () => {
      const ids = vis.map((c) => c.id);
      ids.splice(to, 0, ids.splice(from, 1)[0]);
      const hiddenIds = st.order.filter((x) => st.hidden.has(x));
      st.order = [...ids, ...hiddenIds];
    });
    if (st.active.pos === -1 || st.active.col === from + lead) st.active.col = to + lead;
    rebuildColumns();
    announce(`Colonne ${colById.get(id).label} déplacée en position ${to + 1}.`);
  }

  function setWidth(id, w) {
    const col = colById.get(id);
    if (!col) return;
    st.widths.set(id, clamp(Math.round(w), col.minWidth, col.maxWidth));
    setTemplate();
  }

  function autofit(id) {
    const col = colById.get(id);
    if (!col) return;
    const k = visible().indexOf(col) + lead;
    let w = 0;
    const label = hrow.querySelector(`.k-gh[data-c="${k}"] .k-gh-label`);
    if (label) w = label.scrollWidth + 64;
    for (const node of rendered.values()) {
      const cell = node.children[k];
      if (cell) w = Math.max(w, cell.scrollWidth + 4);
    }
    changeLayout(`Largeur de ${quote(col.label)}`, () => setWidth(id, Math.max(w, col.minWidth)));
    rebuildColumns();
  }

  function setDensity(d) {
    if (!DENSITY[d]) return;
    changeLayout('Densité', () => { st.density = d; });
    root.dataset.density = st.density;
    measureHead();
    renderRows(true);
    ensureVisible(st.active.pos, st.active.col);
  }

  function openFilters(focusId) {
    if (!st.filtersOpen) {
      st.filtersOpen = true;
      paintFilters();
      measureHead();
      renderRows(true);
    }
    if (focusId) {
      const input = frow.querySelector(`[data-col="${CSS.escape(focusId)}"]`);
      if (input instanceof HTMLElement) {
        input.focus({ preventScroll: true });
        const k = visible().findIndex((c) => c.id === focusId) + lead;
        ensureVisible(-1, k);
      }
    }
  }

  function closeFilters() {
    st.filtersOpen = false;
    paintFilters();
    measureHead();
    renderRows(true);
  }

  // ---------- Pointer: header (sort, drag to reorder, resize) ----------

  let drag = null;

  hrow.addEventListener('pointerdown', (e) => {
    if (e.button !== 0 || !(e.target instanceof Element)) return;
    const cell = e.target.closest('.k-gh');
    if (!cell || e.target.closest('.k-gh-menu')) return;
    if (cell.classList.contains('sel')) return;
    const id = cell.dataset.col;
    const col = colById.get(id);
    if (!col) return;
    if (e.target.closest('.k-gh-resize')) {
      e.preventDefault();
      const start = e.clientX;
      const startW = st.widths.get(id) ?? col.width;
      const before = snapshot();
      cell.setPointerCapture(e.pointerId);
      root.classList.add('resizing');
      const resize = rafThrottle((x) => setWidth(id, startW + x - start));
      const move = (ev) => resize(ev.clientX);
      const up = () => {
        resize.cancel();
        cell.removeEventListener('pointermove', move);
        cell.removeEventListener('pointerup', up);
        cell.removeEventListener('pointercancel', up);
        root.classList.remove('resizing');
        changeLayout(`Largeur de ${quote(col.label)}`, () => {}, before);
      };
      cell.addEventListener('pointermove', move);
      cell.addEventListener('pointerup', up);
      cell.addEventListener('pointercancel', up);
      return;
    }
    drag = { id, cell, x: e.clientX, moved: false, shift: e.shiftKey, pointer: e.pointerId, target: -1 };
    cell.setPointerCapture(e.pointerId);
  });

  hrow.addEventListener('pointermove', (e) => {
    if (!drag || e.pointerId !== drag.pointer) return;
    const dx = e.clientX - drag.x;
    if (!drag.moved && Math.abs(dx) < DRAG_THRESHOLD) return;
    if (!drag.moved) { drag.moved = true; drag.cell.classList.add('k-dragging'); root.classList.add('dragging'); }
    drag.cell.style.setProperty('transform', `translateX(${dx}px)`);
    // Offsets ignore transforms: the dragged header keeps its place in the computation.
    const cells = [...hrow.querySelectorAll('.k-gh:not(.sel)')];
    const from = cells.indexOf(drag.cell);
    const x = e.clientX - table.getBoundingClientRect().left;
    let insertAt = cells.length;
    for (let n = 0; n < cells.length; n++) {
      const c = /** @type {HTMLElement} */ (cells[n]);
      if (x < c.offsetLeft + c.offsetWidth / 2) { insertAt = n; break; }
    }
    const lastCell = /** @type {HTMLElement} */ (cells.at(-1));
    const edge = insertAt < cells.length ? /** @type {HTMLElement} */ (cells[insertAt]).offsetLeft : lastCell.offsetLeft + lastCell.offsetWidth;
    drag.target = insertAt > from ? insertAt - 1 : insertAt;
    drop.style.setProperty('transform', `translateX(${Math.round(edge) - 1}px)`);
    drop.classList.add('on');
  });

  const endDrag = (e) => {
    if (!drag || (e && e.pointerId !== drag.pointer)) return;
    const d = drag;
    drag = null;
    d.cell.classList.remove('k-dragging');
    d.cell.style.removeProperty('transform');
    root.classList.remove('dragging');
    drop.classList.remove('on');
    if (e?.type === 'pointercancel') return;
    if (d.moved) {
      if (d.target >= 0) moveColumn(d.id, d.target);
      return;
    }
    // A plain click sorts (Shift adds the column to the sort).
    sortBy(d.id, { add: d.shift });
    const k = visible().findIndex((c) => c.id === d.id) + lead;
    st.active = { pos: -1, col: k };
    scroller.focus({ preventScroll: true });
    markActive();
  };
  hrow.addEventListener('pointerup', endDrag);
  hrow.addEventListener('pointercancel', endDrag);

  hrow.addEventListener('click', (e) => {
    if (!(e.target instanceof Element)) return;
    const menuBtn = e.target.closest('.k-gh-menu');
    if (menuBtn) {
      const col = colById.get(menuBtn.closest('.k-gh')?.dataset.col ?? '');
      if (col) openMenu(menuBtn, columnMenuItems(col), { label: `Colonne ${col.label}`, restoreFocus: scroller });
      return;
    }
    if (e.target.closest('.k-gh.sel')) {
      const allShown = st.view.length > 0 && st.view.every((ri) => st.sel.has(st.ids[ri]));
      setSelection(allShown ? [] : st.view.map((ri) => st.ids[ri]), null);
      announce(allShown ? 'Sélection vidée.' : `${count(st.view.length, 'ligne sélectionnée', 'lignes sélectionnées')}.`);
    }
  });

  hrow.addEventListener('dblclick', (e) => {
    const handle = e.target instanceof Element ? e.target.closest('.k-gh-resize') : null;
    const id = handle?.closest('.k-gh')?.dataset.col;
    if (id) autofit(id);
  });

  hrow.addEventListener('contextmenu', (e) => {
    const cell = e.target instanceof Element ? e.target.closest('.k-gh') : null;
    const col = colById.get(cell?.dataset.col ?? '');
    if (!col) return;
    e.preventDefault();
    openMenu(e, columnMenuItems(col), { label: `Colonne ${col.label}`, restoreFocus: scroller });
  });

  // ---------- Pointer: rows ----------

  const posOf = (node) => Number(node.closest('.k-gr')?.dataset.pos ?? -1);
  const colIndexOf = (node) => {
    const cell = node.closest('.k-gc');
    return cell ? [...cell.parentElement.children].indexOf(cell) : 0;
  };

  body.addEventListener('pointerdown', (e) => {
    root.classList.remove('kbd');
    st.kbd = false;
    if (!(e.target instanceof Element) || e.target.closest('.k-skel')) return;
    const row = e.target.closest('.k-gr');
    if (!row) return;
    if (e.shiftKey) e.preventDefault(); // no text selection on Shift+click
    const pos = posOf(row);
    setActive(pos, colIndexOf(e.target), { scroll: false });
    if (document.activeElement !== scroller) scroller.focus({ preventScroll: true });
  });

  body.addEventListener('click', (e) => {
    if (!(e.target instanceof Element) || e.target.closest('a, button, input, select')) return;
    const row = e.target.closest('.k-gr');
    if (!row || row.classList.contains('k-skel')) return;
    const pos = posOf(row);
    const onCheck = !!e.target.closest('.k-gc.sel');
    selectAt(pos, { toggle: onCheck || e.ctrlKey || e.metaKey, range: e.shiftKey, keep: e.ctrlKey || e.metaKey });
  });

  body.addEventListener('dblclick', (e) => {
    if (!(e.target instanceof Element) || e.target.closest('a, button, input, select, .k-gc.sel')) return;
    const row = e.target.closest('.k-gr');
    if (!row || row.classList.contains('k-skel')) return;
    activate(posOf(row));
  });

  body.addEventListener('contextmenu', (e) => {
    if (!(e.target instanceof Element)) return;
    const row = e.target.closest('.k-gr');
    if (!row || row.classList.contains('k-skel')) return;
    e.preventDefault();
    const pos = posOf(row);
    const id = idAt(pos);
    if (id != null && !st.sel.has(id)) selectAt(pos);
    const k = colIndexOf(e.target);
    setActive(pos, k, { scroll: false });
    const col = k >= lead ? visible()[k - lead] : null;
    openMenu(e, rowMenuItems(col), { label: 'Actions de la ligne', restoreFocus: scroller });
  });

  function activate(pos) {
    const id = idAt(pos);
    if (id == null) return;
    o.onActivate?.(st.rows[st.index.get(id)]);
  }

  // ---------- Keyboard ----------

  scroller.addEventListener('keydown', (e) => {
    if (e.target !== scroller) return; // filter inputs keep their keys
    root.classList.add('kbd');
    st.kbd = true;
    const { pos, col } = st.active;
    const n = st.view.length;
    const maxCol = visible().length + lead - 1;
    const page = Math.max(1, Math.floor((scroller.clientHeight - headH) / rowH()) - 1);
    const mod = e.ctrlKey || e.metaKey;
    const extend = e.shiftKey && selection === 'multi';
    const moveTo = (p, c = col) => {
      if (p < 0 && pos >= 0) { setActive(-1, c); return; }
      setActive(p, c);
      if (p >= 0 && selection !== 'none' && !mod) {
        if (extend) selectAt(st.active.pos, { range: true });
        else selectAt(st.active.pos);
      }
    };

    if (pos === -1) {
      const colObj = col >= lead ? visible()[col - lead] : null;
      switch (e.key) {
        case 'ArrowLeft':
          e.preventDefault();
          if (e.altKey && colObj) moveColumn(colObj.id, col - lead - 1);
          else if (mod && colObj) changeLayout(`Largeur de ${quote(colObj.label)}`, () => setWidth(colObj.id, (st.widths.get(colObj.id) ?? colObj.width) - 16));
          else setActive(-1, col - 1);
          return;
        case 'ArrowRight':
          e.preventDefault();
          if (e.altKey && colObj) moveColumn(colObj.id, col - lead + 1);
          else if (mod && colObj) changeLayout(`Largeur de ${quote(colObj.label)}`, () => setWidth(colObj.id, (st.widths.get(colObj.id) ?? colObj.width) + 16));
          else setActive(-1, col + 1);
          return;
        case 'ArrowDown': e.preventDefault(); if (n) setActive(0, col); return;
        case 'Home': e.preventDefault(); setActive(-1, 0); return;
        case 'End': e.preventDefault(); setActive(-1, maxCol); return;
        case 'Enter': case ' ':
          e.preventDefault();
          if (colObj) sortBy(colObj.id, { add: e.shiftKey });
          else if (lead) hrow.querySelector('.k-gh.sel')?.dispatchEvent(new MouseEvent('click', { bubbles: true }));
          markActive();
          return;
        case 'ContextMenu': case 'F10':
          if (e.key === 'F10' && !e.shiftKey) return;
          e.preventDefault();
          if (colObj) {
            const cell = document.getElementById(cellId(-1, col));
            openMenu(cell ?? scroller, columnMenuItems(colObj), { label: `Colonne ${colObj.label}`, restoreFocus: scroller });
          }
          return;
        default: break;
      }
    } else {
      switch (e.key) {
        case 'ArrowDown': e.preventDefault(); moveTo(Math.min(n - 1, pos + 1)); return;
        case 'ArrowUp': e.preventDefault(); moveTo(pos - 1); return;
        case 'PageDown': e.preventDefault(); moveTo(Math.min(n - 1, pos + page)); return;
        case 'PageUp': e.preventDefault(); moveTo(Math.max(0, pos - page)); return;
        case 'ArrowLeft': e.preventDefault(); setActive(pos, col - 1); return;
        case 'ArrowRight': e.preventDefault(); setActive(pos, col + 1); return;
        case 'Home': e.preventDefault(); if (mod) moveTo(0); else setActive(pos, 0); return;
        case 'End': e.preventDefault(); if (mod) moveTo(n - 1); else setActive(pos, maxCol); return;
        case ' ':
          e.preventDefault();
          if (selection === 'multi') selectAt(pos, { toggle: !e.shiftKey, range: e.shiftKey, keep: true });
          else selectAt(pos);
          return;
        case 'Enter': e.preventDefault(); activate(pos); return;
        case 'Escape':
          if (st.sel.size && selection !== 'none') { e.preventDefault(); e.stopPropagation(); setSelection([], null); announce('Sélection vidée.'); }
          return;
        case 'ContextMenu': case 'F10': {
          if (e.key === 'F10' && !e.shiftKey) return;
          e.preventDefault();
          const id = idAt(pos);
          if (id != null && !st.sel.has(id)) selectAt(pos);
          const cell = document.getElementById(cellId(pos, col));
          const r = (cell ?? scroller).getBoundingClientRect();
          const column = col >= lead ? visible()[col - lead] : null;
          openMenu({ x: r.left + 12, y: r.bottom - 4 }, rowMenuItems(column), { label: 'Actions de la ligne', restoreFocus: scroller });
          return;
        }
        default: break;
      }
    }
    if (mod && !e.altKey) {
      const key = e.key.toLowerCase();
      if (key === 'a' && selection === 'multi') {
        e.preventDefault();
        setSelection(st.view.map((ri) => st.ids[ri]), st.anchor);
        announce(`${count(st.view.length, 'ligne sélectionnée', 'lignes sélectionnées')}.`);
      } else if (key === 'c') {
        e.preventDefault();
        const rows = api.getSelection();
        const active = st.activeId == null ? null : st.rows[st.index.get(st.activeId)];
        copyRows(rows.length ? rows : (active ? [active] : []), rows.length > 1);
      }
    }
  });

  // Ctrl+Z undoes the last layout change, anywhere in the grid except in text fields.
  root.addEventListener('keydown', (e) => {
    if ((e.ctrlKey || e.metaKey) && !e.altKey && e.key.toLowerCase() === 'z' && !isTextEntry(e.target) && st.undo.length) {
      e.preventDefault();
      undo();
    }
  });

  scroller.addEventListener('focus', () => {
    if (st.active.pos >= st.view.length) st.active.pos = st.view.length - 1;
    markActive();
  });

  scroller.addEventListener('scroll', onScroll, { passive: true });

  // ---------- Toolbar ----------

  quickInput?.addEventListener('input', () => applyQuick(quickInput.value));
  quickInput?.addEventListener('keydown', (e) => {
    if (e.key === 'Escape' && quickInput.value) { e.preventDefault(); e.stopPropagation(); quickInput.value = ''; applyQuick(''); applyQuick.flush(); }
    else if (e.key === 'ArrowDown' || e.key === 'Enter') { e.preventDefault(); applyQuick.flush(); scroller.focus({ preventScroll: true }); }
  });
  undoBtn?.addEventListener('click', undo);
  filtersBtn?.addEventListener('click', () => (st.filtersOpen ? closeFilters() : openFilters(visible().find((c) => c.filterable && !c.secret)?.id)));
  colsBtn?.addEventListener('click', () => openMenu(colsBtn, viewMenuItems(), { label: 'Colonnes et affichage', placement: 'bottom-end' }));
  exportBtn?.addEventListener('click', () => openMenu(exportBtn, exportMenuItems(), { label: 'Copier ou exporter', placement: 'bottom-end' }));

  frow.addEventListener('input', (e) => {
    const input = e.target;
    if (input instanceof HTMLInputElement && input.dataset.col) applyColumnFilter(input.dataset.col, input.value);
  });
  frow.addEventListener('change', (e) => {
    const input = e.target;
    if (input instanceof HTMLSelectElement && input.dataset.col) setColumnFilter(input.dataset.col, input.value);
  });
  frow.addEventListener('keydown', (e) => {
    if (e.key === 'Escape' && e.target instanceof HTMLInputElement && e.target.value) {
      e.preventDefault();
      e.stopPropagation();
      e.target.value = '';
      applyColumnFilter.cancel();
      setColumnFilter(e.target.dataset.col ?? '', '');
    }
  });

  const ro = 'ResizeObserver' in window ? new ResizeObserver(() => { measureHead(); renderRows(false); }) : null;
  ro?.observe(scroller);

  // ---------- Public API ----------

  function setColumnsInternal(columns, key) {
    cols = normalize(columns);
    colById = new Map(cols.map((c) => [c.id, c]));
    if (key !== undefined) layoutKey = key ? `grid:${key}` : null;
    defaults();
    applyStored(readLayout(layoutKey));
    root.dataset.density = st.density;
    st.colFilters.clear();
    st.tests.clear();
    st.undo = [];
    paintUndo();
    resetCaches();
  }

  const api = {
    /** The grid root element. */
    el: root,
    /** Slot in the toolbar for page controls (chips, view switch). */
    slot: /** @type {HTMLElement|null} */ (root.querySelector('.k-gslot')),

    /**
     * Replaces the rows. Selection and active row are kept for ids still present (Domenia 1, RCH-060).
     * @param {any[]} rows @param {{ hasMore?: boolean, keepSelection?: boolean, keepScroll?: boolean }} [opts]
     */
    setRows(rows, { hasMore = false, keepSelection = true, keepScroll = false } = {}) {
      const wasLoading = st.loading;
      st.rows = Array.isArray(rows) ? rows : [];
      st.ids = st.rows.map((r, n) => String(rowIdOf(r, n)));
      st.index = new Map(st.ids.map((id, n) => [id, n]));
      st.loading = false;
      st.loadingMore = false;
      st.error = null;
      st.hasMore = hasMore;
      st.enterNext = wasLoading || !keepScroll;
      scroller.removeAttribute('aria-busy');
      resetCaches();
      const before = st.sel.size;
      st.sel = keepSelection ? new Set([...st.sel].filter((id) => st.index.has(id))) : new Set();
      if (st.anchor != null && !st.index.has(st.anchor)) st.anchor = null;
      refreshView({ keepScroll });
      if (st.sel.size !== before) emitSelection();
      // A read that ends: the count is said (the counter itself is readable, not live, to stay quiet while filtering).
      if (wasLoading) announce(`${count(st.rows.length, 'ligne chargée', 'lignes chargées')}${hasMore ? ', liste partielle' : ''}.`);
    },

    /** Appends rows (next page); filters and sort apply to them, the scroll position stays. */
    appendRows(rows, { hasMore = false } = {}) {
      const start = st.rows.length;
      const added = Array.isArray(rows) ? rows : [];
      st.rows = st.rows.concat(added);
      added.forEach((r, k) => {
        const id = String(rowIdOf(r, start + k));
        st.ids.push(id);
        st.index.set(id, start + k);
      });
      st.hasMore = hasMore;
      st.loadingMore = false;
      caches.all = null;
      for (const arr of caches.text.values()) arr.length = st.rows.length;
      for (const arr of caches.key.values()) arr.length = st.rows.length;
      refreshView();
      announce(`${count(added.length, 'ligne ajoutée', 'lignes ajoutées')}.`);
    },

    /** Skeleton state while a read is in progress (aria-busy for the capture readiness signal). */
    setLoading(on = true) {
      st.loading = !!on;
      if (st.loading) { scroller.setAttribute('aria-busy', 'true'); st.error = null; }
      else scroller.removeAttribute('aria-busy');
      renderRows(true);
      paintOverlay();
      paintCount();
      paintFoot();
    },

    /** Shows an error over the list; retry adds a « Réessayer » button. Null clears it. */
    setError(message, { retry } = {}) {
      st.error = message ? { message: String(message), retry } : null;
      if (message) { st.loading = false; scroller.removeAttribute('aria-busy'); }
      renderRows(true);
      paintOverlay();
      paintCount();
    },

    /** Explains an empty list (why, and the next step, run only on click). */
    setEmpty(empty) { st.empty = empty ?? null; paintOverlay(); },

    /** More rows exist (« Charger la suite », or automatic for local reads). */
    setHasMore(on) { st.hasMore = !!on; st.loadingMore = false; paintFoot(); paintCount(); },

    setQuickFilter(text) {
      if (quickInput) quickInput.value = String(text ?? '');
      applyQuick.cancel();
      st.quick = String(text ?? '').slice(0, FILTER_MAX);
      refreshView({ announceCount: true });
    },

    setColumnFilter(id, raw) {
      setColumnFilter(id, raw);
      if (st.filtersOpen) paintFilters();
    },

    /** Clears the quick filter and every column filter, without any read. */
    clearFilters() {
      applyQuick.cancel();
      applyColumnFilter.cancel();
      st.quick = '';
      if (quickInput) quickInput.value = '';
      st.colFilters.clear();
      st.tests.clear();
      paintHeader();
      paintFilters();
      refreshView({ announceCount: true });
    },

    /** Selected rows, in the current order. */
    getSelection() {
      const out = [];
      const seen = new Set();
      for (const ri of st.view) {
        if (st.sel.has(st.ids[ri])) { out.push(st.rows[ri]); seen.add(ri); }
      }
      // Selected rows hidden by a filter stay selected and come last.
      if (out.length < st.sel.size) {
        for (const id of st.sel) {
          const ri = st.index.get(id);
          if (ri !== undefined && !seen.has(ri)) out.push(st.rows[ri]);
        }
      }
      return out;
    },

    getSelectedIds: () => [...st.sel],

    /** Selects rows by id; scroll brings the first one into view. */
    select(ids, { scroll = true } = {}) {
      const list = (Array.isArray(ids) ? ids : [ids]).map(String).filter((id) => st.index.has(id));
      setSelection(selection === 'single' ? list.slice(0, 1) : list, list[0] ?? null);
      if (list.length && scroll) {
        const pos = st.view.indexOf(st.index.get(list[0]));
        if (pos >= 0) setActive(pos, st.active.col);
      }
    },

    /** Rows shown (filtered and sorted). */
    getVisibleRows: () => st.view.map((ri) => st.rows[ri]),

    /** Active row (keyboard or last click), or null. */
    getActiveRow: () => (st.activeId == null ? null : st.rows[st.index.get(st.activeId)] ?? null),

    toCsv,
    exportCsv,

    /** Re-renders the visible cells after an in-place change (positions stay; refresh() re-sorts). */
    updateRow(id) {
      const ri = st.index.get(String(id));
      if (ri === undefined) return;
      for (const arr of caches.text.values()) arr[ri] = undefined;
      for (const arr of caches.key.values()) arr[ri] = undefined;
      if (caches.all) caches.all[ri] = undefined;
      const pos = st.view.indexOf(ri);
      const node = rendered.get(pos);
      if (node) {
        const t = document.createElement('template');
        t.innerHTML = rowMarkup(pos);
        const fresh = /** @type {HTMLElement} */ (t.content.firstElementChild);
        fresh.style.setProperty('transform', node.style.getPropertyValue('transform'));
        fresh.classList.remove('k-enter');
        fresh.classList.add('k-flash');
        node.replaceWith(fresh);
        rendered.set(pos, fresh);
        markActive();
      }
    },

    /** Re-applies filters and sort to the current rows. */
    refresh() { resetCaches(); refreshView(); },

    /** Replaces the columns (another view of the same list); key switches the layout memory. */
    setColumns(columns, { key } = {}) {
      setColumnsInternal(columns, key);
      rebuildColumns();
      refreshView();
    },

    resetLayout() {
      changeLayout('Disposition par défaut', () => defaults());
      root.dataset.density = st.density;
      rebuildColumns();
      resort();
      announce('Disposition par défaut rétablie.');
    },

    focus() { scroller.focus({ preventScroll: true }); },

    destroy() {
      alive = false;
      persist.flush();
      applyQuick.cancel();
      applyColumnFilter.cancel();
      announceFilter.cancel();
      onScroll.cancel();
      cancelAnimationFrame(notify);
      ro?.disconnect();
      host.replaceChildren();
    },
  };

  setColumnsInternal(o.columns);
  rebuildColumns();
  if (st.loading) api.setLoading(true);
  else if (Array.isArray(o.rows)) api.setRows(o.rows);
  else refreshView();
  return api;
}
