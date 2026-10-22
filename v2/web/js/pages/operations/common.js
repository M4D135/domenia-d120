// Shared pieces of the Opérations screen (docs/ops/operations.md): the tabs, silent background reads, French durations and
// dates, tones and their glyphs, small markup helpers. Every datum inserted in HTML goes through esc(); no style attribute
// (CSS variables through setVars / applyVars).
import { call as bridgeCall } from '../../bridge.js';
import { esc, formatDateTime, formatTime, relTime, formatNumber, applyVars } from '../../ui.js';
import { glyph, NBSP, NNBSP, setVars } from '../../kit/index.js';

/** Tabs of the screen, in display order; `id` is the value of the « onglet » parameter of the route. */
export const TABS = [
  { id: 'recus', label: 'Reçus d’écriture', icon: 'shield' },
  { id: 'taches', label: 'Tâches', icon: 'activity' },
  { id: 'journal', label: 'Journal', icon: 'history' },
  { id: 'sante', label: 'Santé du moteur', icon: 'gauge' },
  { id: 'statistiques', label: 'Statistiques', icon: 'layers' },
  { id: 'releves', label: 'Relevés', icon: 'wifi' },
  { id: 'diagnostic', label: 'Diagnostic', icon: 'tools' },
];

export const TONE_ICONS = { ok: 'check', warn: 'eye', alert: 'alert', info: 'info', off: 'pause', accent: 'sparkles' };

/**
 * Background read of the screen (refresh every few seconds): sent through the bridge without the counter of the page, so the
 * busy line does not blink and the readiness signal of the captures (docs/CAPTURE.md § 5) is never held by a refresh. First
 * loads go through ctx.call (counted, skeletons shown).
 */
export function silentCall(op, args) {
  return bridgeCall(op, args);
}

/** « < 1 ms », « 850 ms », « 2,3 s », « 1 min 05 s » (same rules as the engine, ActivityRules.Duration). */
export function duration(ms) {
  if (!Number.isFinite(ms) || ms < 0) return 'non mesurée';
  if (ms < 1) return `<${NBSP}1${NBSP}ms`;
  if (ms < 1000) return `${formatNumber(Math.round(ms))}${NBSP}ms`;
  if (ms < 60_000) return `${formatNumber(ms / 1000, 1)}${NBSP}s`;
  const whole = Math.round(ms / 1000);
  return `${formatNumber(Math.floor(whole / 60))}${NBSP}min ${String(whole % 60).padStart(2, '0')}${NBSP}s`;
}

/** Integer with the narrow no-break space of FrenchText. */
export function int(n) {
  return Number.isFinite(n) ? formatNumber(n).replace(/\s/g, NNBSP) : '—';
}

/** « 1 reçu », « 12 reçus » (0 and 1 take the singular). */
export function count(n, one, many) {
  return `${int(n)} ${Math.abs(n) >= 2 ? many : one}`;
}

/** Relative date with its full date in a tip, for a cell or a line. */
export function when(iso, { prefix = '' } = {}) {
  if (!iso) return '<span class="op-none">—</span>';
  const full = formatDateTime(iso) ?? '';
  return `<time datetime="${esc(iso)}" data-rel="${esc(iso)}" data-prefix="${esc(prefix)}" data-tip="${esc(full)}">${esc(prefix + (relTime(iso) ?? full))}</time>`;
}

/** Hour and minutes of an ISO date (« 14:32 »), or « — ». */
export function hour(iso) {
  return formatTime(iso) ?? '—';
}

/** Full local date and time, or « — ». */
export function fullDate(iso) {
  return formatDateTime(iso) ?? '—';
}

/** Refreshes the relative dates of a scope (one timer per screen). */
export function touchDates(scope) {
  scope.querySelectorAll('time[data-rel]').forEach((t) => {
    const text = relTime(t.dataset.rel);
    if (text) t.textContent = (t.dataset.prefix ?? '') + text;
  });
}

/** A round glyph mark in the tone of a state (decorative: the word beside it carries the meaning). */
export function toneMark(tone, iconName, cls = '') {
  return `<span class="op-mark ${cls}" data-tone="${esc(tone ?? 'info')}" aria-hidden="true">${glyph(iconName ?? TONE_ICONS[tone] ?? 'info')}</span>`;
}

/** Skeleton lines for a card while it loads (the readiness signal waits for them to go). */
export function skeletonLines(n = 3, cls = '') {
  return `<div class="op-sk ${cls}" aria-busy="true">${Array.from({ length: n }, (_, i) => `<span class="skeleton op-sk-line w${[85, 70, 55, 90, 40][i % 5]}"></span>`).join('')}</div>`;
}

/** Empty state of a card: floating art, title and a sentence. */
export function emptyState(iconName, title, text, action = '') {
  return `<div class="op-empty"><span class="op-empty-art" aria-hidden="true">${glyph(iconName)}<i></i><i></i></span>
    <b>${esc(title)}</b>${text ? `<p>${esc(text)}</p>` : ''}${action}</div>`;
}

/** Inline error of a card, with the French message of the engine. */
export function errorBox(message, retryId = '') {
  return `<div class="op-error" role="alert">${glyph('alert')}<span>${esc(message)}</span>${retryId ? `<button class="btn sm subtle" type="button" data-retry="${esc(retryId)}">${glyph('refresh')}Réessayer</button>` : ''}</div>`;
}

/** Section heading inside a tab (like the Accueil: small capitals, a drawn line, a note). */
export function sectionHead(title, note = '', extra = '') {
  return `<div class="op-sec"><h3>${esc(title)}</h3>${note ? `<span class="op-sec-note">${esc(note)}</span>` : ''}${extra}</div>`;
}

/** Card head with icon, title, subtitle and a slot on the right. */
export function cardHead(iconName, title, sub = '', meta = '', tone = '') {
  return `<div class="card-head op-card-head"><span class="card-icon"${tone ? ` data-tone="${esc(tone)}"` : ''}>${glyph(iconName)}</span>
    <div class="op-head-titles"><h3>${esc(title)}</h3>${sub ? `<span class="op-head-sub">${esc(sub)}</span>` : ''}</div>
    ${meta ? `<span class="meta">${meta}</span>` : ''}</div>`;
}

/** Plain text of a row for the clipboard: masked again by the page for what looks like a secret (defence in depth). */
export function maskSecrets(text) {
  return String(text ?? '')
    .replace(/(?<!\d)(?:\d{6}-){7}\d{6}(?!\d)/g, '[clé de récupération masquée]')
    .replace(/\b(Bearer|Basic)\s+[A-Za-z0-9_.~+/=-]+/gi, '$1 ***')
    .replace(/\b(password|passwd|pwd|pass|motdepasse|mot\s+de\s+passe|secret|token|authorization|api[_-]?key|apikey|client[_-]?secret)(\s*[=:]\s*)("[^"]*"|'[^']*'|[^\s;,]+)/gi, '$1$2***');
}

/** Same rule as the engine (ReceiptReviews.LooksSecret) for the live feedback of the review field; the engine checks again. */
export function looksSecret(text) {
  const t = String(text ?? '');
  return maskSecrets(t) !== t || /(^|\s)[-/](?:p|rp|pass|password|pwd)(?:\s+|[:=])\S+/i.test(t);
}

/** Label of an operation kind for the filters. */
export const KIND_LABELS = {
  local: 'Calcul local', localRead: 'Lecture locale', networkRead: 'Lecture réseau', localWrite: 'Écriture locale', write: 'Écriture', batch: 'Lot de collecte',
};

/**
 * CSS variables of a scope from its data attributes (CSP: no style attribute): those of ui.js (data-i, data-j, data-tone, data-p,
 * data-pct…) plus the positions of the charts of the screen (data-x, data-w as fractions of 1, data-h as a fraction of 1).
 */
const painted = new WeakMap();

/**
 * Repaints a refreshed block only when its markup changed (the silent refreshes mostly return the same facts); the
 * later paints mark the block settled, which drops its entrance animations. Returns true when the block was repainted.
 * @param {HTMLElement} host @param {string} html
 */
export function repaint(host, html) {
  if (painted.get(host) === html) return false;
  if (painted.has(host)) host.dataset.settled = 'true';
  painted.set(host, html);
  host.innerHTML = html;
  paintVars(host);
  return true;
}

/** Forgets the last markup of a block painted outside `repaint` (an error box), so that the next paint always lands. */
export function unpaint(host) {
  painted.delete(host);
}

export function paintVars(scope) {
  applyVars(scope);
  scope.querySelectorAll('[data-x],[data-w],[data-h]').forEach((el) => {
    const vars = {};
    if (el.dataset.x !== undefined) vars['--x'] = String(clampUnit(el.dataset.x));
    if (el.dataset.w !== undefined) vars['--w'] = String(clampUnit(el.dataset.w));
    if (el.dataset.h !== undefined) vars['--h'] = String(clampUnit(el.dataset.h));
    setVars(el, vars);
  });
}

function clampUnit(v) {
  const n = Number(v);
  return Number.isFinite(n) ? Math.min(1, Math.max(0, n)) : 0;
}
