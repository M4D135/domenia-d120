// Freshness indicator: « Lu il y a 3 min », amber once ageing, « Périmé » past its limit, « Jamais lu » without a
// date. One shared ticker updates every indicator on screen; it stops when none is left.
import { esc, NBSP } from './util.js';
import { relTime, formatDateTime } from '../ui.js';

const TICK_MS = 20_000;
const DEFAULT_STALE = 15 * 60_000;
let timer = 0;

/**
 * Markup of a freshness indicator.
 * @param {string|null} at                   ISO date of the read (null: never read).
 * @param {{ staleAfter?: number, label?: string, source?: string }} [o]  staleAfter in ms (default 15 min); label « Lu ».
 * @returns {string}
 */
export function freshness(at, o = {}) {
  const stale = o.staleAfter ?? DEFAULT_STALE;
  return `<span class="k-fresh" data-at="${esc(at ?? '')}" data-stale="${stale}" data-label="${esc(o.label ?? 'Lu')}"${o.source ? ` data-source="${esc(o.source)}"` : ''}>`
    + `<span class="k-fresh-dot" aria-hidden="true"></span><span class="k-fresh-text"></span></span>`;
}

function minutes(ms) {
  const m = Math.round(ms / 60_000);
  return m >= 120 ? `${Math.round(m / 60)}${NBSP}h` : `${m}${NBSP}min`;
}

/** Updates one indicator (text, state, tip). */
function update(node) {
  const at = node.dataset.at;
  const stale = Number(node.dataset.stale) || DEFAULT_STALE;
  const label = node.dataset.label || 'Lu';
  const source = node.dataset.source ? ` · ${node.dataset.source}` : '';
  const text = node.querySelector('.k-fresh-text');
  const t = Date.parse(at ?? '');
  let state;
  let line;
  let tip;
  if (!at || Number.isNaN(t)) {
    state = 'never';
    line = 'Jamais lu';
    tip = `Aucune lecture enregistrée${source}.`;
  } else {
    const age = Date.now() - t;
    const rel = relTime(at) ?? '';
    state = age >= stale ? 'stale' : age >= stale / 2 ? 'aging' : 'fresh';
    line = state === 'stale' ? `Périmé · ${rel}` : `${label} ${rel}`;
    tip = `${label} le ${formatDateTime(at) ?? ''}${source} · périmé après ${minutes(stale)}`;
  }
  if (node.dataset.state !== state) node.dataset.state = state;
  if (text.textContent !== line) text.textContent = line;
  node.dataset.tip = tip;
}

function tick() {
  const nodes = document.querySelectorAll('.k-fresh');
  nodes.forEach(update);
  if (!nodes.length) { clearInterval(timer); timer = 0; }
}

/**
 * Fills the indicators inside scope and keeps every indicator on screen up to date.
 * @param {HTMLElement|Document} [scope]
 */
export function startFreshness(scope = document) {
  scope.querySelectorAll('.k-fresh').forEach(update);
  if (!timer) timer = setInterval(tick, TICK_MS);
}

/**
 * Changes the date of an indicator (after a new read), with a short highlight.
 * @param {HTMLElement} node @param {string|null} at
 */
export function touchFreshness(node, at) {
  node.dataset.at = at ?? '';
  update(node);
  node.classList.remove('renewed');
  void node.offsetWidth;
  node.classList.add('renewed');
  if (!timer) timer = setInterval(tick, TICK_MS);
}
