// Boards that the operator arranges (TRV-306 to TRV-313, TRV-293 to TRV-296, TRV-179, TRV-284): « Personnaliser » mode,
// add or modify a widget in a panel (search with synonyms, filters, visual, size, section, live preview), move by drag and
// drop or by the keyboard, resize, change of representation, removal, ten undo steps with redo, ready-made layouts, the
// delivered or team layout, export and import of the layout (JSON), persistence with its five previous versions, copy of a
// widget or of the whole board for a ticket (text, Markdown or HTML), « Comprendre ce chiffre », dates of the data and an
// accessible table for every chart, selection of a part that carries a criterion (« Autres » keeps its members), actions
// of a widget, removal that suspends the collections of the widget (onLayout). The stored layout is always read before the
// first save (the engine answers after the first screen may already be shown). Layout rules are pure functions
// (tests/web/shell/board.test.mjs).
import { icon } from '../icons.js';
import { esc, fold, copyText, announce, motionReduced } from '../ui.js';
import { openMenu, openDrawer, confirmDialog, glyph } from '../kit/index.js';
import { isTextEntry } from '../kit/util.js';
import { state, setBoard, readBoard, quietCall, on } from './store.js';
import { notify } from './notify.js';
import { visualMarkup, paintCharts, dataDates, dataTable, num, sizeText } from './charts.js';
import { exportJson, importJson } from './exports.js';
import { protectText } from './summary.js';
import { ask } from './guards.js';

const NBSP = ' ';
export const FORMAT = 'Domenia.BoardLayout.1';
const DOC_FORMAT = 'Domenia.BoardDocument.2';
const UNDO_MAX = 10;
const HISTORY_MAX = 5;
const SIZES = ['S', 'M', 'L'];
export const SIZE_LABELS = { S: 'Compacte', M: 'Moyenne', L: 'Large' };
export const VISUAL_LABELS = {
  kpi: 'Chiffre clé', gauge: 'Jauge', score: 'Carte score', health: 'Santé : score et points', donut: 'Anneau', bars: 'Barres',
  columns: 'Histogramme', line: 'Courbe', text: 'Liste', list: 'Liste de points', sheet: 'Fiche', checklist: 'Liste d’état',
};

/**
 * Representations that make sense for a kind of data, preferred first (TRV-286, Domenia 1 Get-DomeniaBoardVisuals,
 * decisions of 07/10 and 08/10): a curve only for dated values (buckets and shares are not a time line), a gauge only for a
 * number with a maximum. A catalogue item gives its `visuals`, or its `dataKind` (and `hasMaximum`) and gets these.
 */
export function visualsFor(dataKind, hasMaximum = false) {
  switch (String(dataKind ?? '').toLowerCase()) {
    case 'value': return ['kpi', 'text'];
    case 'number': return hasMaximum ? ['gauge', 'kpi', 'text'] : ['kpi', 'text'];
    case 'distribution': return ['donut', 'bars', 'columns', 'text', 'kpi'];
    case 'measure': return ['columns', 'bars', 'kpi', 'text'];
    case 'series': return ['columns', 'bars', 'text', 'kpi'];
    case 'timeline': return ['line', 'columns', 'text'];
    case 'list': return ['list'];
    case 'health': return ['health', 'score', 'kpi'];
    case 'sheet': return ['sheet', 'text'];
    case 'checklist': return ['checklist', 'sheet', 'text'];
    default: return ['kpi', 'text'];
  }
}

/** Representations allowed for a catalogue item: its own list when it gives one, else those of its kind of data. */
export function allowedVisuals(c) {
  const own = Array.isArray(c?.visuals) ? c.visuals.filter((v) => Object.hasOwn(VISUAL_LABELS, v)) : [];
  return own.length ? own : visualsFor(c?.dataKind, !!c?.hasMaximum);
}
/** Origins of the widgets of a catalogue (filter of the editor, Domenia 1 Show-DomeniaBoardEditor). */
export const ORIGIN_LABELS = { builtin: 'Intégrés', team: 'Équipe', query: 'Requêtes enregistrées', probe: 'Sondes du poste' };
/** A fleet widget reads every workstation of the scope when refreshed: beyond this many, adding it asks first. */
export const FLEET_CONFIRM_ABOVE = 200;
/** Search synonyms of the catalogue (Domenia 1 $DomeniaBoardSearchSynonyms). */
export const SYNONYMS = {
  ram: ['memoire'], memory: ['memoire'], ssd: ['disque', 'stockage'], hdd: ['disque'], stockage: ['disque', 'volume'],
  defender: ['antivirus', 'defender'], av: ['antivirus'], firewall: ['pare-feu'], reboot: ['redemarrage'], restart: ['redemarrage'],
  redemarrer: ['redemarrage'], ip: ['adresse ip', 'reseau'], uptime: ['en service', 'demarrage'], maj: ['mise a jour', 'correctif', 'windows update'],
  update: ['mise a jour', 'correctif', 'windows update'], patch: ['correctif'], kb: ['correctif'], cpu: ['processeur'], gpu: ['graphique', 'affichage'],
  notif: ['notification'], aide: ['help', 'aide'], raccourci: ['clavier'],
};

// ---------- Pure layout rules ----------

/** Words of a catalogue search with their synonyms; every word must then match one of its forms (SP-19). */
export function searchTerms(text) {
  return fold(String(text ?? '')).split(/\s+/).filter(Boolean).map((w) => ({ word: w, forms: [w, ...(SYNONYMS[w] ?? [])] }));
}

export function matchesCatalog(item, terms, { origin = '', category = '' } = {}) {
  if (origin && (item.origin ?? 'builtin') !== origin) return false;
  if (category && fold(item.group) !== fold(category)) return false;
  const hay = fold(`${item.title} ${item.keywords ?? ''} ${item.group} ${item.description ?? ''}`);
  return terms.every((t) => t.forms.some((f) => hay.includes(f)));
}

/**
 * Cleans a layout read, imported or delivered: unknown widgets dropped, representation and size corrected, ids unique. Keys
 * of Domenia 1 (team layouts, exported documents) are translated through `legacyKeys` ({ 'DiskSpace': 'disk.free' }).
 */
export function cleanLayout(items, catalog, prefix = 'w', legacyKeys = {}) {
  const byKey = new Map(catalog.map((c) => [c.key, c]));
  const seen = new Set();
  const out = [];
  (Array.isArray(items) ? items : []).forEach((raw, position) => {
    if (!raw || typeof raw !== 'object') return;
    const given = String(raw.key ?? raw.Key ?? '');
    const key = byKey.has(given) ? given : String(legacyKeys?.[given] ?? given);
    const c = byKey.get(key);
    if (!c) return;
    let id = String(raw.id ?? raw.Id ?? '');
    if (!/^[a-z0-9-]{1,40}$/i.test(id) || seen.has(id)) {
      const base = `${prefix}-${key.replace(/[^a-z0-9]+/gi, '-').toLowerCase()}-${position}`.slice(0, 40);
      id = base;
      let n = 2;
      while (seen.has(id)) id = `${base}-${n++}`;
    }
    seen.add(id);
    const visualRaw = String(raw.visual ?? raw.Visual ?? '').toLowerCase();
    const allowed = allowedVisuals(c);
    const visual = allowed.includes(visualRaw) ? visualRaw : allowed[0];
    const sizeRaw = String(raw.size ?? raw.Size ?? '');
    const size = SIZES.includes(sizeRaw) ? sizeRaw : (c.size ?? (visual === 'kpi' ? 'S' : 'M'));
    const group = String(raw.group ?? raw.Group ?? '').trim().slice(0, 60) || c.group;
    const title = String(raw.title ?? raw.Title ?? '').trim().slice(0, 80);
    const item = { id, key, visual, size, group, title };
    if (raw.paused === true || raw.Paused === true) item.paused = true;
    out.push(item);
  });
  return out;
}

/** Sections in the order of their first widget. */
export function groupsOf(layout) {
  const seen = [];
  for (const i of layout) if (i.group && !seen.some((g) => fold(g) === fold(i.group))) seen.push(i.group);
  return seen;
}

/** New widget at the end of its section (or of the board when the section is new). */
export function addItem(layout, item) {
  const out = [...layout];
  let at = -1;
  out.forEach((i, n) => { if (fold(i.group) === fold(item.group)) at = n; });
  if (at < 0) out.push(item); else out.splice(at + 1, 0, item);
  return out;
}

export function removeItem(layout, id) { return layout.filter((i) => i.id !== id); }

/** Changes some fields of a widget; moved to another section, it goes to the end of that section. */
export function updateItem(layout, id, changes) {
  const target = layout.find((i) => i.id === id);
  if (!target) return layout;
  const updated = { ...target, ...changes };
  if (fold(updated.group) !== fold(target.group)) return addItem(removeItem(layout, id), updated);
  return layout.map((i) => (i.id === id ? updated : i));
}

/** Moves a widget: onto another one (takes its place, joins its section) or one step inside its section. */
export function moveItem(layout, id, { onto = '', step = '' } = {}) {
  const items = [...layout];
  const index = items.findIndex((i) => i.id === id);
  if (index < 0) return layout;
  const moving = items[index];
  if (onto) {
    if (onto === id) return layout;
    const targetIndex = items.findIndex((i) => i.id === onto);
    if (targetIndex < 0) return layout;
    const target = items[targetIndex];
    items.splice(index, 1);
    let place = items.indexOf(target);
    if (index < targetIndex) place += 1;
    items.splice(place, 0, { ...moving, group: target.group });
    return items;
  }
  const positions = items.map((i, n) => (fold(i.group) === fold(moving.group) ? n : -1)).filter((n) => n >= 0);
  const place = positions.indexOf(index);
  const goal = { back: place - 1, forward: place + 1, first: 0, last: positions.length - 1 }[step] ?? place;
  const bounded = Math.max(0, Math.min(positions.length - 1, goal));
  if (bounded === place) return layout;
  items.splice(index, 1);
  items.splice(positions[bounded], 0, moving);
  return items;
}

/** Moves a whole section up or down, widgets keeping their order. */
export function moveGroup(layout, group, direction) {
  const groups = groupsOf(layout);
  const index = groups.findIndex((g) => fold(g) === fold(group));
  const target = index + (direction === 'up' ? -1 : 1);
  if (index < 0 || target < 0 || target >= groups.length) return layout;
  [groups[index], groups[target]] = [groups[target], groups[index]];
  return groups.flatMap((g) => layout.filter((i) => fold(i.group) === fold(g)));
}

/** Next size by the keyboard, bounded to Compacte and Large. */
export function nextSize(size, step) {
  const at = Math.max(0, SIZES.indexOf(size));
  return SIZES[Math.max(0, Math.min(2, at + Math.sign(step)))];
}

/**
 * Ready-made layout (Domenia 1 Get-DomeniaBoardPresetLayout): puts the widgets of the preset first, adding the missing ones,
 * without removing the operator's widgets nor changing their sizes.
 */
export function presetLayout(layout, keys, catalog) {
  const items = [...layout];
  for (const key of keys) {
    if (items.some((i) => i.key === key)) continue;
    const c = catalog.find((x) => x.key === key);
    if (c) items.push({ id: `p-${key.replace(/[^a-z0-9]+/gi, '-').toLowerCase()}`.slice(0, 40), key, visual: allowedVisuals(c)[0], size: c.size ?? 'M', group: c.group, title: '' });
  }
  const rank = new Map(keys.map((k, n) => [k, n]));
  const groupRank = new Map();
  for (const i of items) {
    const r = rank.get(i.key) ?? 1000;
    const g = fold(i.group);
    if (!groupRank.has(g) || r < groupRank.get(g)) groupRank.set(g, r);
  }
  return items.map((i, n) => ({ i, n })).sort((a, b) => (groupRank.get(fold(a.i.group)) - groupRank.get(fold(b.i.group))) || ((rank.get(a.i.key) ?? 1000) - (rank.get(b.i.key) ?? 1000)) || (a.n - b.n)).map((x) => x.i);
}

/** Exported document (Domenia 1 ConvertTo-DomeniaBoardLayoutDocument), readable by « Importer » and as a team layout. */
export function layoutDocument(board, layout, at = new Date()) {
  return {
    Format: FORMAT, Board: board, ExportedUtc: at.toISOString().replace(/\.\d{3}Z$/, 'Z'),
    Layout: layout.map((i) => ({ Id: i.id, Source: 'Builtin', Key: i.key, Visual: i.visual, Title: i.title, Size: i.size, Group: i.group, ...(i.paused ? { Paused: true } : {}) })),
  };
}

/**
 * Reads an imported text or a team layout: a document of this board or a plain list. { valid, items, reason }. `board` is the
 * name or the list of names the board answers to (its team name and its identifier: « Computer » and « poste »).
 */
export function readLayoutDocument(board, text) {
  const names = (Array.isArray(board) ? board : [board]).filter(Boolean).map((b) => String(b).toLowerCase());
  if (!String(text ?? '').trim()) return { valid: false, items: [], reason: 'Fichier vide.' };
  let parsed;
  try { parsed = JSON.parse(text); } catch { return { valid: false, items: [], reason: 'Texte JSON illisible.' }; }
  let items = parsed;
  if (parsed && !Array.isArray(parsed) && typeof parsed === 'object' && 'Layout' in parsed) {
    if (parsed.Format && parsed.Format !== FORMAT) return { valid: false, items: [], reason: `Format inconnu${NBSP}: ${String(parsed.Format).slice(0, 40)}.` };
    if (parsed.Board && !names.includes(String(parsed.Board).toLowerCase())) return { valid: false, items: [], reason: `Disposition du tableau « ${String(parsed.Board).slice(0, 40)} », pas de celui-ci.` };
    items = parsed.Layout;
  }
  items = Array.isArray(items) ? items.filter((i) => i && typeof i === 'object') : [];
  if (!items.length) return { valid: false, items: [], reason: 'Aucun widget dans ce fichier.' };
  return { valid: true, items, reason: '' };
}

/** Stored document of a board: the layout and its five previous versions (TRV-313 improvement). */
export function readStored(doc, catalog, legacyKeys = {}) {
  if (doc && typeof doc === 'object' && doc.format === DOC_FORMAT && Array.isArray(doc.layout)) {
    return { layout: cleanLayout(doc.layout, catalog, 'w', legacyKeys), history: Array.isArray(doc.history) ? doc.history.slice(0, HISTORY_MAX) : [], customized: true };
  }
  // Version 1: a plain list (Domenia 1 Dashboard.<Board>.Layout); « [] » is a board emptied on purpose and stays empty.
  if (Array.isArray(doc)) return { layout: cleanLayout(doc, catalog, 'w', legacyKeys), history: [], customized: true };
  return null;
}

/**
 * Widgets that are measured (Domenia 1 Select-DomeniaActiveBoardItems): a paused widget keeps its place, size and title but
 * leaves every collection and calculation (TRV-288).
 */
export function activeItems(layout) { return (layout ?? []).filter((i) => i && !i.paused); }

/**
 * Keys measured, added and removed between two layouts (onLayout: the screen suspends the collections of removed widgets).
 * Pausing a widget removes its key, resuming adds it back.
 */
export function layoutChange(before, after) {
  const was = new Set(activeItems(before).map((i) => i.key));
  const now = new Set(activeItems(after).map((i) => i.key));
  return { keys: [...now], added: [...now].filter((k) => !was.has(k)), removed: [...was].filter((k) => !now.has(k)) };
}

/** Width of a column step and its count (Domenia 1 Get-DomeniaBoardColumnCount). */
const COLUMN_BOUNDS = [[4, 1100], [3, 780], [2, 440]];
const COLUMN_HYSTERESIS = 24;

/**
 * Columns of the board for its width (TRV-315, Domenia 1 Get-DomeniaBoardColumnCount): 4 from 1 100 px, 3 from 780, 2 from
 * 440, a single column below. The count in use is kept while the width stays within 24 px of the boundary it would cross, so
 * a scroll bar that appears or disappears never switches the layout back and forth.
 */
export function columnsFor(width, current = 0) {
  const w = Number(width);
  let raw = 1;
  if (Number.isFinite(w)) for (const [count, min] of COLUMN_BOUNDS) { if (w >= min) { raw = count; break; } }
  if (current >= 1 && current <= 4 && Math.abs(current - raw) === 1) {
    const edge = COLUMN_BOUNDS.find(([count]) => count === Math.max(current, raw))?.[1] ?? 0;
    if (Math.abs(w - edge) < COLUMN_HYSTERESIS) return current;
  }
  return raw;
}

/** What pausing a widget changes when its catalogue item says nothing more (Domenia 1 Get-DomeniaWidgetPauseText). */
export const PAUSE_TEXT = `Widget suspendu${NBSP}: il n’est plus calculé ni actualisé. Les lectures communes aux autres widgets restent faites pour eux.`;

/** True when an entry carries a figure, a list or a verdict to draw. */
export function hasMeasure(e) {
  if (!e || typeof e !== 'object' || e.paused || e.placeholder || e.collecting) return false;
  if (e.value !== undefined && e.value !== null && e.value !== '') return true;
  return (e.items ?? []).length > 0 || !!e.verdict || Number.isFinite(Number(e.number)) || (e.rows ?? []).length > 0;
}

/**
 * Compact place of a widget without a figure (TRV-314, Domenia 1 Get-DomeniaWidgetPlaceholder, decision of 14/10): paused,
 * being collected, read by the complete inventory only, absent from the last reading, not computed or not collected yet,
 * with the button that acts on it. Never a measure. null when the widget has a figure, or while the first read runs (the
 * skeleton says it). An entry may carry its own `placeholder` ({ state, message, action, actionText }).
 * @returns {{ state: string, message: string, action: ''|'resume'|'refresh', actionText: string } | null}
 */
export function placeholderOf({ paused = false, entry, item = {}, loaded = false, board = '' } = {}) {
  const NB = NBSP;
  if (paused) return { state: 'paused', message: String(item.pauseText || PAUSE_TEXT), action: 'resume', actionText: 'Reprendre la mesure' };
  if (entry?.collecting) return { state: 'collecting', message: String(entry.collecting), action: '', actionText: '' };
  if (entry?.placeholder && typeof entry.placeholder === 'object') {
    const p = entry.placeholder;
    const action = p.action === 'resume' || p.action === 'refresh' ? p.action : '';
    return { state: String(p.state ?? 'missing'), message: String(p.message ?? ''), action, actionText: action ? String(p.actionText ?? 'Actualiser') : '' };
  }
  if (hasMeasure(entry)) return null;
  if (!entry && !loaded) return null;
  if (entry && typeof entry === 'object' && (entry.value === null || entry.number === null)) return null;
  if (entry?.deepOnly) return { state: 'deep', message: `Lu par l’inventaire complet seulement${NB}: le dernier inventaire était rapide.`, action: 'refresh', actionText: 'Inventaire complet' };
  if (entry?.collected) {
    const when = entry.collectedAt ? ` du ${new Date(entry.collectedAt).toLocaleString('fr-FR', { dateStyle: 'short', timeStyle: 'short' })}` : '';
    const fleet = board === 'fleet' || item.fleet;
    return { state: 'absent', message: fleet ? `Aucune valeur dans le dernier calcul${when} pour ce périmètre.` : `Absent du dernier relevé${when}${NB}: information non renvoyée.`, action: 'refresh', actionText: fleet ? 'Actualiser' : 'Relire' };
  }
  if (item.need === 'local') return { state: 'missing', message: 'Pas encore calculé.', action: 'refresh', actionText: 'Recalculer' };
  return { state: 'missing', message: 'Pas encore collecté pour ce tableau.', action: 'refresh', actionText: 'Collecter' };
}

/**
 * Plain text of a widget for a ticket (Domenia 1 ConvertTo-DomeniaWidgetText): 20 lines at most, then « et N autres ». A
 * widget without data or suspended gives '' (nothing is copied).
 */
export function widgetText(title, e) {
  if (!e || e.paused) return '';
  const hasValue = e.value !== undefined && e.value !== null && e.value !== '';
  if (!hasValue && !(e.items ?? []).length && !e.verdict && !Number.isFinite(Number(e.number))) return '';
  const value = hasValue ? (e.display ?? (typeof e.value === 'number' ? num(e.value) : e.value)) : Number.isFinite(Number(e.number)) ? num(e.number) : '';
  const lines = [value !== '' ? `${title}${NBSP}: ${value}${e.unit ? ` ${e.unit}` : ''}` : title];
  for (const k of ['verdict', 'subtitle', 'detail', 'badge']) if (e[k] && e[k] !== e.value) lines.push(String(e[k]));
  const items = e.items ?? [];
  const total = e.kind === 'distribution' ? items.reduce((s, i) => s + (Number(i.value) || 0), 0) : 0;
  for (const i of items.slice(0, 20)) {
    if (i.level) { lines.push(`- ${({ alert: 'Critique', warn: 'À surveiller', ok: 'Conforme' })[i.level] ?? 'Information'}${NBSP}: ${i.text ?? i.label}${i.detail ? ` (${i.detail})` : ''}`); continue; }
    const value = i.display ?? (i.value !== undefined && i.value !== null ? num(i.value) : '');
    const share = total > 0 ? ` (${Math.round(((Number(i.value) || 0) / total) * 100)}${NBSP}%)` : '';
    lines.push(`- ${i.label}${value !== '' ? `${NBSP}: ${value}${share}` : ''}${i.detail ? ` (${i.detail})` : ''}`);
  }
  if (items.length > 20) lines.push(`- et ${items.length - 20} autre${items.length - 20 > 1 ? 's' : ''}`);
  if (e.at) lines.push(`Données du ${new Date(e.at).toLocaleString('fr-FR', { dateStyle: 'short', timeStyle: 'short' })}`);
  return protectText(lines.join('\r\n'));
}

/** Summary of a whole board (TRV-294): text, Markdown or HTML. */
export function boardSummary(head, entries, format = 'text') {
  const blocks = entries.map(({ title, entry }) => widgetText(title, entry)).filter(Boolean);
  if (format === 'markdown') {
    return [`# ${head}`, ...blocks.map((b) => { const [first, ...rest] = b.split('\r\n'); return `## ${first}\n${rest.join('\n')}`; })].join('\n\n');
  }
  if (format === 'html') {
    return `<h1>${esc(head)}</h1>${blocks.map((b) => { const [first, ...rest] = b.split('\r\n'); return `<h2>${esc(first)}</h2>${rest.length ? `<ul>${rest.map((l) => `<li>${esc(l.replace(/^- /, ''))}</li>`).join('')}</ul>` : ''}`; }).join('')}`;
  }
  return [head, ...blocks].join('\r\n\r\n');
}

/** Keyboard gesture of a focused widget (Domenia 1 Get-DomeniaBoardKeyGesture): { action, value } or null. */
export function keyGesture(e, editing) {
  const key = e.key;
  if (e.ctrlKey || e.metaKey) {
    if (!e.altKey && !e.shiftKey && key.toLowerCase() === 'c') return { action: 'copy' };
    return null;
  }
  if (!e.altKey && !e.shiftKey && key === 'F5') return { action: 'refresh' };
  if (!e.altKey && e.shiftKey && key === 'F10') return { action: 'menu' };
  if (key === 'ContextMenu') return { action: 'menu' };
  if (!editing) return null;
  if (!e.altKey && !e.shiftKey && key === 'Delete') return { action: 'remove' };
  if (!e.altKey) return null;
  if (e.shiftKey) {
    if (key === 'ArrowRight' || key === 'ArrowUp') return { action: 'size', value: 1 };
    if (key === 'ArrowLeft' || key === 'ArrowDown') return { action: 'size', value: -1 };
    return null;
  }
  const steps = { ArrowLeft: 'back', ArrowRight: 'forward', Home: 'first', End: 'last' };
  return steps[key] ? { action: 'move', value: steps[key] } : null;
}

/** Parts of a ring as drawn (8 at most, then « Autres »), for the selection. */
function groupOthersOf(entry) {
  const valid = (entry.items ?? []).filter((i) => i && Number(i.value) > 0);
  if (valid.length <= 8) return valid;
  const tail = valid.slice(7);
  const criteria = tail.flatMap((i) => (i.criteria ?? (i.criterion ? [i.criterion] : [])));
  return [...valid.slice(0, 7), { label: `Autres (${tail.length} catégories)`, other: true, members: tail.map((i) => i.label), criteria, criterion: criteria.join('|') || undefined }];
}

const PLACE_ICONS = { paused: 'pause', collecting: 'sync', deep: 'search', absent: 'info', missing: 'clock' };

/** Markup of the compact place of a widget without a figure (TRV-314): why, and the button that acts on it. */
export function placeMarkup(place) {
  const button = place.action
    ? `<button class="btn sm${place.action === 'resume' ? ' primary' : ''}" type="button" data-w-place="${esc(place.action)}">${icon(place.action === 'resume' ? 'play' : 'refresh')}${esc(place.actionText)}</button>`
    : '';
  return `<div class="sh-place" data-state="${esc(place.state)}"><span class="sh-place-icon${place.state === 'collecting' ? ' spin' : ''}" aria-hidden="true">${icon(PLACE_ICONS[place.state] ?? 'info')}</span>`
    + `<p class="sh-place-text">${esc(place.message)}</p>${button}</div>`;
}

// ---------- Board UI ----------

/**
 * Creates a board.
 * @param {HTMLElement} host
 * @param {{ id: string, team?: string, title: string, catalog: Array<object>, defaults: Array<object>,
 *   presets?: Array<{ id: string, label: string, keys: string[] }>, load: () => Promise<Record<string, object>>,
 *   refreshItem?: (key: string) => Promise<object>, explain?: (key: string, entry: object) => object, summaryHead?: () => string,
 *   legacyKeys?: Record<string, string>, fleetSize?: () => number,
 *   onLayout?: (change: { keys: string[], added: string[], removed: string[] }) => void,
 *   onSegment?: (key: string, part: { label: string, criterion?: string, criteria?: string[], members?: string[], selected: boolean }) => void,
 *   onAction?: (key: string, action: string) => void }} o
 */
export function createBoard(host, o) {
  const catalog = (o.catalog ?? []).map((c) => ({ ...c, visuals: allowedVisuals(c) }));
  const legacy = o.legacyKeys ?? {};
  const delivered = () => cleanLayout(o.defaults, catalog, 'b', legacy);
  // The stored layout is known only once the engine answered (or failed): until then the board shows the delivered layout
  // and never saves, so a stored layout is never overwritten by the delivered one.
  let ready = state.engineRead;
  const stored = ready ? readStored(readBoard(o.id), catalog, legacy) : null;
  let layout = stored ? stored.layout : delivered();
  let history = stored?.history ?? [];
  let gestured = false;
  let editing = false;
  let undo = [];
  let redo = [];
  let data = {};
  let tables = new Set();
  let alive = true;
  let columns = 4;
  let dragId = null;
  let loaded = false;
  // A board updated while it is hidden (a tab not shown) is drawn at its next appearance, only if the session, the object
  // and the scope stayed the same; otherwise it is emptied and read again (TRV-303, Domenia 1 Show-DomeniaBoard -DeferIfHidden).
  let deferred = false;
  let loadedContext = '';
  const contextOf = () => { try { return String(o.context?.() ?? ''); } catch (err) { console.error(err); return ''; } };
  const selection = {}; // widget key → label of the part selected (kept across reloads, « Autres » included)

  host.innerHTML = `<div class="sh-board" data-board="${esc(o.id)}">
    <div class="sh-board-bar" role="toolbar" aria-label="Commandes du tableau">
      <button class="btn sm" type="button" data-b="edit" aria-pressed="false">${icon('settings')}<span>Personnaliser</span></button>
      <button class="btn sm subtle" type="button" data-b="add">${icon('sparkles')}Ajouter un widget</button>
      <button class="btn sm ghost" type="button" data-b="presets" aria-haspopup="menu">${icon('panel')}Dispositions prêtes</button>
      <button class="btn sm ghost" type="button" data-b="undo" hidden aria-keyshortcuts="Control+Z">${glyph('undo')}<span>Annuler</span></button>
      <button class="btn sm ghost" type="button" data-b="redo" hidden aria-keyshortcuts="Control+Y">${glyph('undo')}<span>Rétablir</span></button>
      <span class="sh-board-spacer"></span>
      <button class="btn sm ghost" type="button" data-b="copy" aria-haspopup="menu">${icon('copy')}Copier le résumé</button>
      <button class="btn sm ghost icon" type="button" data-b="more" aria-haspopup="menu" aria-label="Plus de commandes du tableau" data-tip="Par défaut, exporter, importer, versions">${icon('more')}</button>
    </div>
    <p class="sh-board-hint" hidden>${icon('info')}<span>Glissez un widget sur un autre pour le déplacer. Clavier${NBSP}: Alt ← → déplace, Alt Maj ← → change la taille, Suppr retire, Ctrl Z annule.</span></p>
    <div class="sh-board-sections"></div>
  </div>`;
  const root = host.querySelector('.sh-board');
  const sections = root.querySelector('.sh-board-sections');

  const catalogOf = (key) => catalog.find((c) => c.key === key);
  const titleOf = (item) => item.title || catalogOf(item.key)?.title || item.key;

  function save(next, label, { undoable = true } = {}) {
    if (JSON.stringify(next) === JSON.stringify(layout)) return;
    if (!ready) {
      notify('Disposition enregistrée en cours de lecture : réessayez dans un instant, rien n’a été changé.', { tone: 'info', key: `board-wait|${o.id}` });
      return;
    }
    gestured = true;
    const change = layoutChange(layout, next);
    if (undoable) {
      undo.push({ layout, label });
      if (undo.length > UNDO_MAX) undo.shift();
      redo = [];
    }
    history = [{ savedAt: new Date().toISOString(), layout }, ...history].slice(0, HISTORY_MAX);
    layout = next;
    setBoard(o.id, { format: DOC_FORMAT, version: 2, savedAt: new Date().toISOString(), layout, history });
    render();
    if (label) announce(label);
    if (change.added.length || change.removed.length) tellLayout(change);
  }

  function tellLayout(change) {
    try { o.onLayout?.(change); } catch (err) { console.error(err); }
    // A widget added after the first read has no data yet: the screen reads it once (it was not part of the collection).
    if (change.added.length && Object.keys(data).length) {
      for (const key of change.added) {
        if (data[key] === undefined) { const item = layout.find((i) => i.key === key); if (item) refreshItem(item, { quiet: true }); }
      }
    }
  }

  // The stored layout arrives after the board was shown: adopted as long as the operator changed nothing.
  const offEngine = ready ? () => {} : on('engine', () => {
    if (ready || !alive) return;
    ready = true;
    offEngine();
    if (gestured) return;
    const late = readStored(readBoard(o.id), catalog, legacy);
    if (late) {
      const change = layoutChange(layout, late.layout);
      layout = late.layout;
      history = late.history;
      render();
      if (change.added.length || change.removed.length) tellLayout(change);
    }
    syncBar();
  });

  function undoStep() {
    const step = undo.pop();
    if (!step) return;
    redo.push({ layout, label: step.label });
    save(step.layout, `Annulé${NBSP}: ${step.label}`, { undoable: false });
  }

  function redoStep() {
    const step = redo.pop();
    if (!step) return;
    undo.push({ layout, label: step.label });
    save(step.layout, `Rétabli${NBSP}: ${step.label}`, { undoable: false });
  }

  function syncBar() {
    root.classList.toggle('reading', !ready);
    root.querySelectorAll('.sh-board-bar [data-b="edit"], .sh-board-bar [data-b="add"], .sh-board-bar [data-b="presets"]').forEach((b) => {
      if (ready) { b.removeAttribute('aria-disabled'); delete b.dataset.reason; } else { b.setAttribute('aria-disabled', 'true'); b.dataset.reason = 'Lecture de la disposition enregistrée…'; }
    });
    const edit = root.querySelector('[data-b="edit"]');
    edit.setAttribute('aria-pressed', String(editing));
    edit.querySelector('span').textContent = editing ? 'Terminer' : 'Personnaliser';
    root.classList.toggle('editing', editing);
    root.querySelector('.sh-board-hint').hidden = !editing;
    const u = root.querySelector('[data-b="undo"]');
    u.hidden = !undo.length;
    u.querySelector('span').textContent = undo.length ? `Annuler${NBSP}: ${undo.at(-1).label}` : 'Annuler';
    root.querySelector('[data-b="redo"]').hidden = !redo.length;
  }

  function widgetMarkup(item) {
    const entry = data[item.key];
    const c = catalogOf(item.key);
    const title = titleOf(item);
    const span = Math.min(columns, { S: 1, M: 2, L: 3 }[item.size] ?? 2);
    const place = placeholderOf({ paused: !!item.paused, entry, item: c ?? {}, loaded, board: o.id });
    const body = place ? placeMarkup(place)
      : !entry ? '<div class="skeleton sk sk-block"></div>'
        : tables.has(item.id) ? dataTable({ ...entry, title })
          : visualMarkup(item.visual, { ...entry, title }, { selectable: typeof o.onSegment === 'function', selected: selection[item.key] ?? null });
    const said = place ? `${NBSP}: ${place.message}` : entry?.value !== undefined && entry?.value !== null ? `${NBSP}: ${entry.display ?? entry.value}` : '';
    return `<article class="sh-widget card spot${place ? ' placed' : ''}" tabindex="0" data-id="${esc(item.id)}" data-key="${esc(item.key)}" data-span="${span}" data-size="${item.size}"${place ? ` data-place="${esc(place.state)}"` : ''}
        aria-label="${esc(`${title}${said}`)}" draggable="${editing}">
      <header class="sh-widget-head">
        ${c?.icon ? `<span class="card-icon" data-tone="${esc(entry?.state ?? 'info')}">${icon(c.icon)}</span>` : ''}
        <div class="sh-widget-titles"><h3>${esc(title)}</h3>${entry?.detail ? `<p class="sh-widget-detail">${esc(entry.detail)}</p>` : ''}</div>
        <button class="btn ghost icon xs" type="button" data-w="explain" aria-label="Comprendre ce chiffre" data-tip="Comprendre ce chiffre">${icon('info')}</button>
        <button class="btn ghost icon xs" type="button" data-w="menu" aria-haspopup="menu" aria-label="Menu du widget ${esc(title)}" data-tip="Menu du widget (Maj F10)">${icon('more')}</button>
      </header>
      <div class="sh-widget-body">${body}</div>
      ${entry?.sources?.length ? `<footer class="sh-dates">${dataDates(entry.sources)}</footer>` : ''}
      ${editing ? `<div class="sh-widget-edit" aria-hidden="false">
        <button class="sh-round" type="button" data-w="back" aria-label="Déplacer vers la gauche" data-tip="Déplacer vers la gauche (Alt ←)">${icon('chevronRight')}</button>
        <button class="sh-round" type="button" data-w="forward" aria-label="Déplacer vers la droite" data-tip="Déplacer vers la droite (Alt →)">${icon('chevronRight')}</button>
        <button class="sh-round" type="button" data-w="size" aria-label="Taille : ${SIZE_LABELS[item.size]}" data-tip="Taille ${SIZE_LABELS[item.size]} (Alt Maj →)">${esc(item.size)}</button>
        <button class="sh-round" type="button" data-w="modify" aria-label="Modifier le widget" data-tip="Modifier : représentation, titre, section">${icon('settings')}</button>
        <button class="sh-round danger" type="button" data-w="remove" aria-label="Retirer du tableau" data-tip="Retirer du tableau (Suppr)">${icon('x')}</button>
      </div>` : ''}
    </article>`;
  }

  function render() {
    if (!alive) return;
    // Hidden board (a tab not shown): drawn at its next appearance (the resize observer sees it), never in the dark.
    if (!root.isConnected || !root.getClientRects().length) { deferred = true; return; }
    deferred = false;
    const groups = groupsOf(layout);
    const focusedId = document.activeElement?.closest?.('.sh-widget')?.dataset.id;
    if (!layout.length) {
      sections.innerHTML = `<div class="sh-board-empty card">${icon('sparkles')}<h3>Tableau vide</h3><p class="muted">Ce tableau a été vidé volontairement : il le reste. Ajoutez un widget ou revenez à la disposition par défaut.</p>
        <div class="sh-board-empty-actions"><button class="btn primary sm" type="button" data-b="add">${icon('sparkles')}Ajouter un widget</button><button class="btn sm" type="button" data-b="default">${icon('refresh')}Disposition par défaut</button></div></div>`;
      syncBar();
      return;
    }
    sections.innerHTML = groups.map((g, gi) => `<section class="sh-board-section" data-group="${esc(g)}">
      <header class="sh-board-section-head"><h3>${esc(g)}</h3>
        ${editing ? `<span class="sh-board-section-tools"><button class="btn ghost icon xs" type="button" data-g="up" aria-label="Monter la section ${esc(g)}"${gi === 0 ? ' disabled' : ''}>${icon('arrowUp')}</button><button class="btn ghost icon xs" type="button" data-g="down" aria-label="Descendre la section ${esc(g)}"${gi === groups.length - 1 ? ' disabled' : ''}>${icon('arrowDown')}</button></span>` : ''}
      </header>
      <div class="sh-board-grid">${layout.filter((i) => fold(i.group) === fold(g)).map(widgetMarkup).join('')}
        ${editing ? `<button class="sh-board-addhere" type="button" data-add-group="${esc(g)}">${icon('sparkles')}Ajouter ici</button>` : ''}</div>
    </section>`).join('');
    sections.querySelectorAll('[data-span]').forEach((el) => el.style.setProperty('--span', el.dataset.span));
    paintCharts(sections);
    syncBar();
    if (focusedId) sections.querySelector(`.sh-widget[data-id="${CSS.escape(focusedId)}"]`)?.focus({ preventScroll: true });
  }

  // The widgets enter in cascade once; later renders (a move, a resize, a reload) keep them in place.
  let settleTimer = 0;
  async function load() {
    const context = contextOf();
    try {
      data = (await o.load()) ?? {};
    } catch (err) {
      console.error(err);
      data = {};
    }
    loaded = true;
    loadedContext = context;
    render();
    if (!settleTimer) settleTimer = setTimeout(() => root.classList.add('settled'), 1200);
  }

  async function refreshItem(item, { quiet = false } = {}) {
    if (item.paused) {
      notify(`Mesure suspendue${NBSP}: «${NBSP}${titleOf(item)}${NBSP}» n’est pas actualisé. «${NBSP}Reprendre la mesure${NBSP}» le réactive.`, { tone: 'info', key: `paused-refresh|${o.id}|${item.id}` });
      return;
    }
    if (!o.refreshItem) { await load(); return; }
    try {
      data[item.key] = await o.refreshItem(item.key);
      render();
      if (!quiet) announce(`Widget actualisé${NBSP}: ${titleOf(item)}.`);
    } catch (err) {
      notify(err?.message ?? 'Actualisation impossible.', { tone: 'warn' });
    }
  }

  /**
   * Pauses or resumes the measurement of one widget (TRV-288, Domenia 1 Set-DomeniaBoardItemPaused): it keeps its place, size
   * and title, the change is saved with the layout and can be undone; onLayout tells the screen to leave it out of its
   * collections (or to take it back), and resuming collects what the widget is missing.
   */
  function setPaused(item, paused) {
    if (!!item.paused === paused) return;
    save(updateItem(layout, item.id, { paused: paused || undefined }), paused ? `Mesure suspendue${NBSP}: ${titleOf(item)}` : `Mesure reprise${NBSP}: ${titleOf(item)}`);
    if (paused) {
      notify(`Mesure suspendue${NBSP}: «${NBSP}${titleOf(item)}${NBSP}» garde sa place et n’est plus collecté. «${NBSP}Reprendre la mesure${NBSP}» le réactive.`, { tone: 'info', life: 5000, key: `pause|${o.id}|${item.id}` });
      return;
    }
    const resumed = layout.find((i) => i.id === item.id);
    if (resumed) refreshItem(resumed, { quiet: true });
  }

  function copyItem(item) {
    const text = item.paused ? '' : widgetText(titleOf(item), data[item.key]);
    // A widget without data, or suspended, copies nothing: the clipboard keeps what it held.
    if (!text) { announce(`Rien à copier${NBSP}: ce widget n’a pas encore de données.`); notify(`Rien à copier${NBSP}: «${NBSP}${titleOf(item)}${NBSP}» n’a pas encore de données.`, { tone: 'info', life: 3000, key: `copy-empty|${item.key}` }); return; }
    copyText(text).then((ok) => announce(ok ? `Widget copié${NBSP}: ${titleOf(item)}.` : 'Copie impossible.'));
  }

  function selectPart(item, index) {
    const entry = data[item.key];
    if (!entry) return;
    const parts = item.visual === 'donut' ? groupOthersOf(entry) : (entry.items ?? []).slice(0, 12);
    const part = parts[index];
    if (!part) return;
    const was = selection[item.key];
    const on = was !== part.label && !(part.other && (part.members ?? []).includes(was));
    if (on) selection[item.key] = part.label; else delete selection[item.key];
    render();
    announce(on ? `Part choisie${NBSP}: ${part.label}.` : 'Choix de la part retiré.');
    try {
      o.onSegment?.(item.key, { label: part.label, criterion: part.criterion, criteria: part.criteria ?? (part.criterion ? [part.criterion] : []), members: part.members, selected: on });
    } catch (err) { console.error(err); }
  }

  function explainItem(item) {
    const entry = data[item.key] ?? {};
    const c = catalogOf(item.key) ?? {};
    const x = o.explain?.(item.key, entry) ?? {};
    const rows = [
      ['Valeur affichée', entry.display ?? (entry.value !== undefined ? String(entry.value) : '—')],
      ['Formule', x.formula ?? c.description ?? 'Formule non documentée.'],
      ['Périmètre', x.scope ?? '—'],
      ['Critères', x.criteria ?? '—'],
      ['Exclusions', x.exclusions ?? 'Aucune.'],
      ['Couverture', x.coverage ?? '—'],
      ['Dates des données', (entry.sources ?? []).map((s) => `${s.family} ${s.at ? new Date(s.at).toLocaleString('fr-FR') : 'non daté'}`).join(' · ') || '—'],
      ['Ce que relit « Actualiser »', x.refresh ?? 'Rien : le widget se recalcule à partir des données déjà présentes.'],
    ];
    openDrawer({
      title: 'Comprendre ce chiffre', subtitle: titleOf(item), icon: 'info', key: 'shell.board.explain', width: 480,
      body: `<dl class="sh-kv sh-explain">${rows.map(([k, v]) => `<div class="sh-kv-row"><dt>${esc(k)}</dt><dd>${esc(v)}</dd></div>`).join('')}</dl><p class="faint">Aucune lecture n’est faite pour expliquer : le texte décrit le calcul affiché.</p>`,
      actions: [
        { id: 'copy', label: 'Copier l’explication', icon: 'copy', run: () => copyText(rows.map(([k, v]) => `${k}${NBSP}: ${v}`).join('\r\n')).then((ok) => announce(ok ? 'Explication copiée.' : 'Copie impossible.')) },
        { id: 'close', label: 'Fermer', primary: true, run: (p) => p.close() },
      ],
    });
  }

  function itemMenu(item, anchor) {
    const c = catalogOf(item.key);
    openMenu(anchor, [
      { heading: titleOf(item) },
      { label: 'Actualiser', icon: 'refresh', kbd: 'F5', run: () => refreshItem(item) },
      { label: 'Copier en texte', icon: 'copy', kbd: 'Ctrl C', run: () => copyItem(item) },
      { label: 'Comprendre ce chiffre', icon: 'info', run: () => explainItem(item) },
      { label: tables.has(item.id) ? 'Voir le graphique' : 'Voir en tableau', icon: 'columns', run: () => { if (tables.has(item.id)) tables.delete(item.id); else tables.add(item.id); render(); } },
      '-',
      { label: 'Représentation', icon: 'gauge', items: (c?.visuals ?? []).map((v) => ({ label: VISUAL_LABELS[v] ?? v, radio: 'visual', checked: item.visual === v, run: () => save(updateItem(layout, item.id, { visual: v }), `Représentation ${VISUAL_LABELS[v]}${NBSP}: ${titleOf(item)}`) })) },
      { label: 'Taille', icon: 'columns', items: SIZES.map((s) => ({ label: SIZE_LABELS[s], radio: 'size', checked: item.size === s, run: () => save(updateItem(layout, item.id, { size: s }), `Taille ${SIZE_LABELS[s]}${NBSP}: ${titleOf(item)}`) })) },
      { label: 'Déplacer', icon: 'panel', items: [
        { label: 'Au début de la section', kbd: 'Alt Début', run: () => save(moveItem(layout, item.id, { step: 'first' }), `Déplacé au début${NBSP}: ${titleOf(item)}`) },
        { label: 'Vers la gauche', kbd: 'Alt ←', run: () => save(moveItem(layout, item.id, { step: 'back' }), `Déplacé${NBSP}: ${titleOf(item)}`) },
        { label: 'Vers la droite', kbd: 'Alt →', run: () => save(moveItem(layout, item.id, { step: 'forward' }), `Déplacé${NBSP}: ${titleOf(item)}`) },
        { label: 'À la fin de la section', kbd: 'Alt Fin', run: () => save(moveItem(layout, item.id, { step: 'last' }), `Déplacé à la fin${NBSP}: ${titleOf(item)}`) },
      ] },
      { label: 'Modifier…', icon: 'settings', run: () => editor(item) },
      '-',
      item.paused
        ? { label: 'Reprendre la mesure', icon: 'play', run: () => setPaused(item, false) }
        : { label: 'Suspendre la mesure', icon: 'pause', run: () => setPaused(item, true) },
      { label: 'Retirer du tableau', icon: 'x', danger: true, kbd: 'Suppr', run: () => save(removeItem(layout, item.id), `Widget retiré${NBSP}: ${titleOf(item)}. « Annuler » le remet.`) },
    ], { label: `Menu du widget ${titleOf(item)}`, placement: 'bottom-end' });
  }

  async function resetTo(source) {
    let next = delivered();
    let label = 'Disposition par défaut rétablie';
    if (source === 'team' && o.team) {
      try {
        const team = await quietCall('shell.board.team', { board: o.team });
        const doc = team?.text ? readLayoutDocument([o.team, o.id], team.text) : null;
        const clean = doc?.valid ? cleanLayout(doc.items, catalog, 't', legacy) : [];
        if (clean.length) { next = clean; label = 'Disposition d’équipe appliquée'; } else {
          notify(team?.problem ? `Disposition d’équipe ignorée (${team.problem})${NBSP}: la disposition livrée s’applique.` : 'Aucune disposition d’équipe connue de ce tableau : la disposition livrée s’applique.', { tone: 'info' });
        }
      } catch (err) { console.warn(err); }
    }
    save(next, label);
  }

  async function importLayout() {
    const file = await importJson('Importer une disposition');
    if (!file) return;
    const doc = readLayoutDocument([o.team, o.id], file.text);
    if (!doc.valid) { notify(`Disposition non importée${NBSP}: ${doc.reason}`, { tone: 'warn' }); return; }
    const clean = cleanLayout(doc.items, catalog, 'i', legacy);
    const ignored = doc.items.length - clean.length;
    if (!clean.length) { notify('Aucun widget connu de ce tableau dans ce fichier.', { tone: 'warn' }); return; }
    save(clean, `Disposition importée${NBSP}: ${file.fileName}${ignored ? ` (${ignored} widget${ignored > 1 ? 's' : ''} inconnu${ignored > 1 ? 's' : ''} ignoré${ignored > 1 ? 's' : ''})` : ''}`);
  }

  function versions(anchor) {
    if (!history.length) { notify('Aucune version précédente de ce tableau pour l’instant.', { tone: 'info' }); return; }
    openMenu(anchor, [
      { heading: 'Versions précédentes' },
      ...history.map((h, n) => ({ label: new Date(h.savedAt).toLocaleString('fr-FR', { dateStyle: 'short', timeStyle: 'medium' }), hint: `${h.layout?.length ?? 0} widget${(h.layout?.length ?? 0) > 1 ? 's' : ''}`, run: () => save(cleanLayout(h.layout, catalog, 'w', legacy), `Version ${n + 1} restaurée`) })),
    ], { label: 'Versions précédentes', placement: 'bottom-end' });
  }

  function editor(existing = null, group = '') {
    let search = '';
    let origin = '';
    let category = '';
    let selected = existing ? catalogOf(existing.key) : null;
    let visual = existing?.visual ?? selected?.visuals[0] ?? 'kpi';
    let size = existing?.size ?? selected?.size ?? 'M';
    let section = existing?.group ?? group ?? '';
    let title = existing?.title ?? '';
    const body = document.createElement('div');
    body.className = 'sh-editor';
    const categories = [...new Set(catalog.map((c) => c.group))];
    const origins = [...new Set(catalog.map((c) => c.origin ?? 'builtin'))];
    const draw = () => {
      const terms = searchTerms(search);
      const list = catalog.filter((c) => matchesCatalog(c, terms, { origin, category }));
      const shown = new Set(layout.map((i) => i.key));
      if (selected && !selected.visuals.includes(visual)) visual = selected.visuals[0];
      const preview = selected ? (data[selected.key] ?? selected.sample ?? null) : null;
      body.innerHTML = `<div class="sh-editor-cols">
        <div class="sh-editor-list">
          <label class="sh-pick-find">${icon('search')}<span class="visually-hidden">Chercher une information</span><input class="input" type="search" data-e="q" value="${esc(search)}" placeholder="Chercher : notifications, aide, contraste…" autocomplete="off"></label>
          <div class="sh-editor-facets" role="group" aria-label="Origine"><span class="sh-editor-facet-l">Origine</span><button class="k-facet" type="button" data-e-origin="" aria-pressed="${!origin}">Toutes</button>${origins.map((g) => `<button class="k-facet" type="button" data-e-origin="${esc(g)}" aria-pressed="${origin === g}">${esc(ORIGIN_LABELS[g] ?? g)}<span class="k-facet-n">${catalog.filter((c) => (c.origin ?? 'builtin') === g).length}</span></button>`).join('')}</div>
          <div class="sh-editor-facets" role="group" aria-label="Catégories"><span class="sh-editor-facet-l">Catégorie</span><button class="k-facet" type="button" data-e-cat="" aria-pressed="${!category}">Toutes</button>${categories.map((g) => `<button class="k-facet" type="button" data-e-cat="${esc(g)}" aria-pressed="${category === g}">${esc(g)}</button>`).join('')}</div>
          <ol class="sh-editor-items">${list.map((c) => `<li><button type="button" class="sh-editor-item" data-e-key="${esc(c.key)}" aria-pressed="${selected?.key === c.key}">${icon(c.icon ?? 'gauge')}<span><strong>${esc(c.title)}</strong><span class="sh-pick-path">${esc(c.description ?? c.group)}</span></span>${shown.has(c.key) ? '<span class="k-badge info">Déjà affiché</span>' : ''}${c.network ? '<span class="k-badge warn">Interroge le poste</span>' : ''}${c.fleet ? '<span class="k-badge warn">Interroge le parc</span>' : ''}</button></li>`).join('') || '<li class="faint">Aucune information ne correspond.</li>'}</ol>
        </div>
        <div class="sh-editor-form">${selected ? `
          <h3 class="sh-sub">Représentation</h3>
          <div class="sh-editor-visuals" role="radiogroup" aria-label="Représentation">${selected.visuals.map((v) => `<button type="button" class="sh-thumb" role="radio" aria-checked="${v === visual}" data-e-visual="${v}"><span class="sh-thumb-art" data-art="${v}" aria-hidden="true"></span>${esc(VISUAL_LABELS[v] ?? v)}</button>`).join('')}</div>
          <div class="k-form">
            <label class="k-field w-full"><span class="k-label">Titre (facultatif)</span><input class="input" data-e="title" maxlength="80" value="${esc(title)}" placeholder="${esc(selected.title)}"></label>
            <label class="k-field w-half"><span class="k-label">Taille</span><select class="input k-select" data-e="size">${SIZES.map((s) => `<option value="${s}"${s === size ? ' selected' : ''}>${SIZE_LABELS[s]}</option>`).join('')}</select></label>
            <label class="k-field w-half"><span class="k-label">Section</span><input class="input" data-e="section" maxlength="60" list="sh-editor-sections" value="${esc(section || selected.group)}"><datalist id="sh-editor-sections">${groupsOf(layout).map((g) => `<option value="${esc(g)}"></option>`).join('')}</datalist></label>
          </div>
          <h3 class="sh-sub">Aperçu${preview && !data[selected.key] ? ' (exemple)' : ''}</h3>
          <div class="sh-editor-preview card">${preview ? visualMarkup(visual, { ...preview, title: title || selected.title }) : '<p class="faint">Aperçu disponible après la première lecture.</p>'}</div>
          ${selected.network ? `<p class="sh-pick-error">${icon('wifi')}Ce widget interroge le poste quand on l’actualise : rien n’est lu à l’ajout.</p>` : ''}` : `<div class="sh-empty-mini">${icon('sparkles')}<p><strong>Choisissez une information</strong> dans la liste.</p></div>`}
        </div>
      </div>`;
      paintCharts(body);
    };
    const panel = openDrawer({
      title: existing ? 'Modifier le widget' : 'Ajouter un widget', subtitle: o.title, icon: 'sparkles', key: 'shell.board.editor', width: 860, maxWidth: 1100, body,
      actions: [
        { id: 'cancel', label: 'Annuler', run: (p) => p.close() },
        { id: 'ok', label: existing ? 'Enregistrer' : 'Ajouter', primary: true, run: async (p) => {
          if (!selected) { announce('Choisissez d’abord une information.'); return; }
          const fleet = selected.fleet ? (o.fleetSize?.() ?? 0) : 0;
          if (!existing && fleet > FLEET_CONFIRM_ABOVE) {
            // Domenia 1: a fleet widget beyond 200 workstations asks before it joins the board (nothing is read here).
            const answer = await ask({
              scope: `board:${o.id}`, scopeLabel: o.title, title: `Ajouter un widget qui interroge ${num(fleet)} postes${NBSP}?`,
              message: `«${NBSP}${selected.title}${NBSP}» lira chaque poste du périmètre à chaque actualisation. Rien n’est lu à l’ajout${NBSP}; la première lecture part sur votre geste «${NBSP}Actualiser${NBSP}».`,
              confirmLabel: 'Ajouter quand même', impact: `${num(fleet)} postes`,
            });
            if (answer !== 'confirm') return;
          }
          const groupName = (section || selected.group).trim().slice(0, 60) || selected.group;
          if (existing) save(updateItem(layout, existing.id, { key: selected.key, visual, size, group: groupName, title: title.trim() }), `Widget modifié${NBSP}: ${title || selected.title}`);
          else {
            let id = `w-${selected.key.replace(/[^a-z0-9]+/gi, '-').toLowerCase()}`.slice(0, 34);
            let n = 2;
            while (layout.some((i) => i.id === id)) id = `${id.replace(/-\d+$/, '')}-${n++}`;
            save(addItem(layout, { id, key: selected.key, visual, size, group: groupName, title: title.trim() }), `Widget ajouté${NBSP}: ${title || selected.title}`);
          }
          p.close();
        } },
      ],
    });
    body.addEventListener('input', (e) => {
      const t = e.target;
      if (!(t instanceof HTMLElement)) return;
      if (t.dataset.e === 'q') { search = t.value; const at = t.selectionStart; draw(); const q = body.querySelector('[data-e="q"]'); q.focus(); q.setSelectionRange(at, at); }
      if (t.dataset.e === 'title') title = t.value;
      if (t.dataset.e === 'section') section = t.value;
    });
    body.addEventListener('change', (e) => { if (e.target instanceof HTMLSelectElement && e.target.dataset.e === 'size') size = e.target.value; });
    body.addEventListener('click', (e) => {
      const t = e.target instanceof Element ? e.target : null;
      const cat = t?.closest('[data-e-cat]');
      if (cat) { category = cat.dataset.eCat; draw(); return; }
      const org = t?.closest('[data-e-origin]');
      if (org) { origin = org.dataset.eOrigin; draw(); return; }
      const k = t?.closest('[data-e-key]');
      if (k) { selected = catalogOf(k.dataset.eKey); visual = selected.visuals[0]; size = selected.size ?? 'M'; draw(); return; }
      const v = t?.closest('[data-e-visual]');
      if (v) { visual = v.dataset.eVisual; draw(); }
    });
    draw();
    void panel;
  }

  // ---------- Events ----------

  root.addEventListener('click', (e) => {
    const t = e.target instanceof Element ? e.target : null;
    const b = t?.closest('[data-b]');
    if (b) {
      const act = b.dataset.b;
      if (act === 'edit') { editing = !editing; render(); announce(editing ? 'Mode Personnaliser : glisser-déposer et gestes du clavier actifs.' : 'Personnalisation terminée.'); }
      if (act === 'add') editor(null);
      if (act === 'undo') undoStep();
      if (act === 'redo') redoStep();
      if (act === 'default') resetTo('team');
      if (act === 'presets') {
        openMenu(b, (o.presets ?? []).map((p) => ({ label: p.label, icon: 'panel', run: () => save(presetLayout(layout, p.keys, catalog), `Disposition prête${NBSP}: ${p.label}`) })), { label: 'Dispositions prêtes', placement: 'bottom-start' });
      }
      if (act === 'copy') {
        const head = o.summaryHead?.() ?? o.title;
        const entries = layout.map((i) => ({ title: titleOf(i), entry: i.paused ? null : data[i.key] }));
        openMenu(b, [
          { label: 'En texte (ticket)', icon: 'copy', run: () => copyText(boardSummary(head, entries, 'text')).then((ok) => announce(ok ? 'Résumé copié.' : 'Copie impossible.')) },
          { label: 'En Markdown', icon: 'file', run: () => copyText(boardSummary(head, entries, 'markdown')).then((ok) => announce(ok ? 'Résumé Markdown copié.' : 'Copie impossible.')) },
          { label: 'En HTML', icon: 'file', run: () => copyText(boardSummary(head, entries, 'html')).then((ok) => announce(ok ? 'Résumé HTML copié.' : 'Copie impossible.')) },
        ], { label: 'Copier le résumé', placement: 'bottom-end' });
      }
      if (act === 'more') {
        openMenu(b, [
          { label: 'Disposition par défaut ou d’équipe', icon: 'refresh', run: () => resetTo('team') },
          { label: 'Disposition livrée', icon: 'refresh', run: () => resetTo('delivered') },
          { label: 'Versions précédentes…', icon: 'clock', run: () => versions(b) },
          '-',
          { label: 'Exporter la disposition (JSON)', icon: 'download', run: () => exportJson(`disposition-${o.id}`, layoutDocument(o.team ?? o.id, layout)) },
          { label: 'Exporter la disposition sous…', icon: 'download', run: () => exportJson(`disposition-${o.id}`, layoutDocument(o.team ?? o.id, layout), { chooseLocation: true }) },
          { label: 'Importer une disposition…', icon: 'file', run: () => importLayout() },
        ], { label: 'Plus de commandes du tableau', placement: 'bottom-end' });
      }
      return;
    }
    const g = t?.closest('[data-g]');
    if (g) {
      const group = g.closest('[data-group]').dataset.group;
      save(moveGroup(layout, group, g.dataset.g), `Section déplacée${NBSP}: ${group}`);
      return;
    }
    const addHere = t?.closest('[data-add-group]');
    if (addHere) { editor(null, addHere.dataset.addGroup); return; }
    const seg = t?.closest('[data-seg]');
    const segCard = seg?.closest('.sh-widget');
    if (seg && segCard && !editing) {
      const item = layout.find((i) => i.id === segCard.dataset.id);
      if (item) selectPart(item, Number(seg.dataset.seg));
      return;
    }
    const placeButton = t?.closest('[data-w-place]');
    const placeCard = placeButton?.closest('.sh-widget');
    if (placeButton && placeCard) {
      const item = layout.find((i) => i.id === placeCard.dataset.id);
      if (!item) return;
      if (placeButton.dataset.wPlace === 'resume') setPaused(item, false);
      else refreshItem(item);
      return;
    }
    const action = t?.closest('[data-w-action]');
    const actCard = action?.closest('.sh-widget');
    if (action && actCard) {
      try { o.onAction?.(actCard.dataset.key, action.dataset.wAction); } catch (err) { console.error(err); }
      return;
    }
    const w = t?.closest('[data-w]');
    const card = t?.closest('.sh-widget');
    if (!w || !card) return;
    const item = layout.find((i) => i.id === card.dataset.id);
    if (!item) return;
    const act = w.dataset.w;
    if (act === 'menu') itemMenu(item, w);
    if (act === 'explain') explainItem(item);
    if (act === 'back' || act === 'forward') save(moveItem(layout, item.id, { step: act }), `Déplacé${NBSP}: ${titleOf(item)}`);
    if (act === 'size') save(updateItem(layout, item.id, { size: SIZES[(SIZES.indexOf(item.size) + 1) % 3] }), `Taille modifiée${NBSP}: ${titleOf(item)}`);
    if (act === 'modify') editor(item);
    if (act === 'remove') save(removeItem(layout, item.id), `Widget retiré${NBSP}: ${titleOf(item)}. « Annuler » le remet.`);
  });

  root.addEventListener('keydown', (e) => {
    const card = e.target instanceof Element ? e.target.closest('.sh-widget') : null;
    if ((e.ctrlKey || e.metaKey) && !e.altKey && !isTextEntry(e.target)) {
      if (e.key.toLowerCase() === 'z' && !e.shiftKey && undo.length) { e.preventDefault(); undoStep(); return; }
      if ((e.key.toLowerCase() === 'y' || (e.key.toLowerCase() === 'z' && e.shiftKey)) && redo.length) { e.preventDefault(); redoStep(); return; }
    }
    if (!card || e.target !== card) return;
    const item = layout.find((i) => i.id === card.dataset.id);
    const g = item ? keyGesture(e, editing) : null;
    if (!g) return;
    e.preventDefault();
    e.stopPropagation();
    if (g.action === 'copy') copyItem(item);
    if (g.action === 'refresh') refreshItem(item);
    if (g.action === 'menu') itemMenu(item, card.querySelector('[data-w="menu"]') ?? card);
    if (g.action === 'remove') save(removeItem(layout, item.id), `Widget retiré${NBSP}: ${titleOf(item)}. « Annuler » le remet.`);
    if (g.action === 'size') save(updateItem(layout, item.id, { size: nextSize(item.size, g.value) }), `Taille ${SIZE_LABELS[nextSize(item.size, g.value)]}${NBSP}: ${titleOf(item)}`);
    if (g.action === 'move') save(moveItem(layout, item.id, { step: g.value }), `Déplacé${NBSP}: ${titleOf(item)}`);
  });

  // Drag and drop, in « Personnaliser » mode only; the content area scrolls near its edges.
  root.addEventListener('dragstart', (e) => {
    const card = e.target instanceof Element ? e.target.closest('.sh-widget') : null;
    if (!editing || !card) { e.preventDefault(); return; }
    dragId = card.dataset.id;
    card.classList.add('dragging');
    e.dataTransfer.effectAllowed = 'move';
    e.dataTransfer.setData('text/plain', dragId);
  });
  root.addEventListener('dragover', (e) => {
    if (!dragId) return;
    const card = e.target instanceof Element ? e.target.closest('.sh-widget') : null;
    if (card && card.dataset.id !== dragId) { e.preventDefault(); root.querySelectorAll('.drop-target').forEach((x) => x !== card && x.classList.remove('drop-target')); card.classList.add('drop-target'); }
    const main = document.getElementById('main');
    if (main) {
      const r = main.getBoundingClientRect();
      if (e.clientY < r.top + 60) main.scrollBy({ top: -18, behavior: motionReduced() ? 'auto' : 'auto' });
      else if (e.clientY > r.bottom - 60) main.scrollBy({ top: 18 });
    }
  });
  root.addEventListener('drop', (e) => {
    const card = e.target instanceof Element ? e.target.closest('.sh-widget') : null;
    if (!dragId || !card) return;
    e.preventDefault();
    const moving = layout.find((i) => i.id === dragId);
    const id = dragId;
    dragId = null;
    save(moveItem(layout, id, { onto: card.dataset.id }), `Déplacé${NBSP}: ${moving ? titleOf(moving) : ''}`);
  });
  root.addEventListener('dragend', () => { dragId = null; root.querySelectorAll('.dragging, .drop-target').forEach((x) => x.classList.remove('dragging', 'drop-target')); });

  // Right click on a widget opens its menu at the pointer (TRV-316), like Maj F10 and the Menu key.
  root.addEventListener('contextmenu', (e) => {
    const card = e.target instanceof Element ? e.target.closest('.sh-widget') : null;
    if (!card || (e.target instanceof Element && isTextEntry(e.target))) return;
    const item = layout.find((i) => i.id === card.dataset.id);
    if (!item) return;
    e.preventDefault();
    itemMenu(item, e);
  });

  // Columns of the board by width (TRV-315, columnsFor: 24 px of hysteresis), the change drawn once, 300 ms after the last
  // resize; resizing reads and computes nothing. A board shown again after being hidden is drawn then, or emptied and read
  // again when its session, object or scope changed meanwhile (TRV-303).
  let resizeTimer = 0;
  const ro = 'ResizeObserver' in window ? new ResizeObserver(() => {
    if (!alive) return;
    if (deferred && root.getClientRects().length) {
      if (loaded && contextOf() !== loadedContext) {
        data = {};
        loaded = false;
        Object.keys(selection).forEach((k) => delete selection[k]);
        render();
        load();
      } else {
        render();
      }
    }
    const next = columnsFor(sections.clientWidth, columns);
    if (next === columns) return;
    clearTimeout(resizeTimer);
    resizeTimer = setTimeout(() => {
      const settled = columnsFor(sections.clientWidth, columns);
      if (settled === columns || !alive) return;
      columns = settled;
      root.style.setProperty('--cols', String(columns));
      render();
    }, 300);
  }) : null;
  ro?.observe(sections);
  ro?.observe(root);
  columns = columnsFor(sections.clientWidth || 1100, 0);
  root.style.setProperty('--cols', String(columns));

  render();
  load().then(() => { try { o.onLayout?.(layoutChange([], layout)); } catch (err) { console.error(err); } });

  return {
    reload: load,
    layout: () => layout,
    ready: () => ready,
    selection: () => ({ ...selection }),
    clearSelection(key) { if (key) delete selection[key]; else Object.keys(selection).forEach((k) => delete selection[k]); render(); },
    setEditing(on) { editing = !!on; render(); },
    destroy() { alive = false; clearTimeout(settleTimer); clearTimeout(resizeTimer); ro?.disconnect(); offEngine(); },
    sizeText,
  };
}

/** Removal with confirmation of a whole board layout (used by the screens that offer « Vider le tableau »). */
export async function confirmEmpty(title) {
  return confirmDialog({ title: `Vider ${title}${NBSP}?`, message: 'Le tableau restera vide jusqu’à ce que vous ajoutiez un widget ou reveniez à la disposition par défaut. « Annuler » le rétablit.', confirmLabel: 'Vider' });
}
