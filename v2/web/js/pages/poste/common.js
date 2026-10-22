// Shared pieces of the workstation console (screen « poste », docs/ops/poste.md): formatting, facts, empty and loading
// states, local icons the kit does not have yet, small charts. Nothing here calls the bridge.
import { icon } from '../../icons.js';
import { glyph, pill, NBSP, int } from '../../kit/index.js';
import { esc, relTime, formatDateTime, formatNumber, errorText } from '../../ui.js';

export { esc, NBSP, int, glyph, pill, icon, relTime, formatDateTime, formatNumber, errorText };

/** Local icons of the screen (requested from the kit: battery, cpu, terminal, restart, plug, ping, memory, slow, probe, wake, gpo, laptop). */
const LOCAL = {
  battery: '<rect x="2.5" y="7" width="17" height="10" rx="2.5"/><path d="M21.5 10.5v3"/><path d="M6 10v4M9.5 10v4"/>',
  cpu: '<rect x="6" y="6" width="12" height="12" rx="2"/><rect x="9.5" y="9.5" width="5" height="5" rx="1"/><path d="M9 2.5v3M15 2.5v3M9 18.5v3M15 18.5v3M2.5 9h3M2.5 15h3M18.5 9h3M18.5 15h3"/>',
  terminal: '<rect x="3" y="4" width="18" height="16" rx="3"/><path d="m7 9 3 3-3 3M12.5 15H17"/>',
  restart: '<path d="M4 12a8 8 0 1 0 2.3-5.7"/><path d="M4 4v4.5h4.5"/><path d="M12 8v4l2.5 2"/>',
  plug: '<path d="M9 2v6M15 2v6"/><path d="M6 8h12v4a6 6 0 0 1-12 0Z"/><path d="M12 18v4"/>',
  ping: '<circle cx="12" cy="12" r="2.5"/><path d="M7.8 7.8a6 6 0 0 0 0 8.4M16.2 16.2a6 6 0 0 0 0-8.4M4.9 4.9a10 10 0 0 0 0 14.2M19.1 19.1a10 10 0 0 0 0-14.2"/>',
  layers: '<path d="m12 3 9 5-9 5-9-5Z"/><path d="m3 13 9 5 9-5"/>',
  memory: '<rect x="3" y="7" width="18" height="10" rx="2"/><path d="M7 7v10M11 7v10M15 7v10M3 13h18"/>',
  slow: '<path d="M3 17a9 9 0 0 1 18 0"/><path d="m12 17 4-5"/><circle cx="12" cy="17" r="1.4"/>',
  probe: '<circle cx="11" cy="11" r="6"/><path d="m20 20-4.2-4.2"/><path d="M8.5 11h5M11 8.5v5"/>',
  wake: '<path d="M12 3v8"/><path d="M6.3 6.3a8 8 0 1 0 11.4 0"/>',
  gpo: '<path d="M4 6h16M4 12h10M4 18h7"/><path d="m16 15 2 2 4-4"/>',
  play: '<path d="M7 4.5v15l12-7.5Z"/>',
  laptop: '<rect x="4.5" y="5" width="15" height="10" rx="1.8"/><path d="M2.5 19h19l-1.6-2.5H4.1Z"/>',
};

/** An icon of the kit or of the screen. */
export function ico(name, cls = '') {
  const body = LOCAL[name];
  if (!body) return glyph(name, cls);
  return `<svg class="${cls}" width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${body}</svg>`;
}

export const TONE_ICON = { ok: 'check', warn: 'alert', alert: 'alert', info: 'info', off: 'info' };
export const STATE_LABEL = { observed: 'Constaté', estimated: 'Estimé', refused: 'Refusé', unavailable: 'Indisponible', unknown: 'Inconnu' };
export const LEVEL_TONE = { alert: 'alert', warn: 'warn', info: 'info' };

/** « il y a 3 min » with the full date in the tip, refreshed by the page timer. */
export function rel(iso, prefix = '') {
  if (!iso) return '<span class="ps-faint">—</span>';
  return `<span class="ps-rel" data-rel="${esc(iso)}" data-prefix="${esc(prefix)}" data-tip="${esc(formatDateTime(iso) ?? '')}">${esc(prefix + (relTime(iso) ?? ''))}</span>`;
}

/** Refreshes every relative date of scope (one timer per screen). */
export function tickRelative(scope) {
  for (const el of scope.querySelectorAll('[data-rel]')) {
    const text = relTime(el.dataset.rel);
    if (text) el.textContent = (el.dataset.prefix ?? '') + text;
  }
}

export const sk = (cls) => `<span class="skeleton ps-sk ${cls}"></span>`;
export const skLines = (...cls) => `<div class="ps-sk-stack">${cls.map(sk).join('')}</div>`;

/** A loading card: skeleton lines; the router waits for them to disappear (data-ready). */
export function skeletonCard(title, lines = 4) {
  return `<section class="card ps-card" aria-busy="true"><div class="ps-card-head"><span class="ps-card-icon">${sk('ps-sk-ico')}</span><div class="ps-card-titles"><h3>${esc(title)}</h3></div></div>
    ${skLines(...Array.from({ length: lines }, (_, n) => (n % 3 === 0 ? 'w85' : n % 3 === 1 ? 'w70' : 'w55')))}</section>`;
}

/** Empty state with its reason and, when useful, the action that fills it (run only on its click). */
export function empty({ icon: name = 'info', title, text, action, actionKind, tone = 'info' }) {
  const btn = action ? `<button class="btn sm${actionKind === 'primary' ? ' primary' : ''}" type="button" data-act="${esc(action.id)}">${action.icon ? ico(action.icon) : ''}${esc(action.label)}</button>` : '';
  return `<div class="ps-empty" data-tone="${esc(tone)}"><div class="ps-empty-art">${ico(name)}</div><div class="ps-empty-text"><b>${esc(title)}</b>${text ? `<p>${esc(text)}</p>` : ''}</div>${btn}</div>`;
}

/** Error state: the engine message, the code, and « Réessayer » when the read can be asked again. */
export function failure(err, { retry = 'retry', label = 'Réessayer' } = {}) {
  const code = err?.code ?? '';
  const tone = code === 'poste.unreachable' || code === 'simulation.unavailable' || code === 'poste.cancelled' ? 'warn' : 'alert';
  return `<div class="ps-empty ps-fail" data-tone="${tone}" role="alert"><div class="ps-empty-art">${ico(tone === 'warn' ? 'wifiOff' : 'alert')}</div>
    <div class="ps-empty-text"><b>${esc(code === 'poste.unreachable' ? 'Poste injoignable' : code === 'poste.cancelled' ? 'Relevé arrêté' : 'Lecture impossible')}</b><p>${esc(errorText(err))}</p>${code ? `<p class="ps-code mono">${esc(code)}</p>` : ''}</div>
    ${retry ? `<button class="btn sm" type="button" data-act="${esc(retry)}">${ico('refresh')}${esc(label)}</button>` : ''}</div>`;
}

/** A fact of the engine: label, value, state chip, source, limit and hint (never a bare number without its limits). */
export function fact(f, { compact = false } = {}) {
  const tone = f.tone ?? 'info';
  const state = STATE_LABEL[f.state] ?? f.state;
  const meta = [f.source, f.at ? formatDateTime(f.at) : null].filter(Boolean).join(' · ');
  return `<li class="ps-fact" data-tone="${esc(tone)}"><span class="ps-fact-mark" aria-hidden="true">${ico(TONE_ICON[tone] ?? 'info')}</span>
    <div class="ps-fact-body"><div class="ps-fact-top"><span class="ps-fact-label">${esc(f.label)}</span>${f.state && f.state !== 'observed' ? `<span class="ps-state" data-state="${esc(f.state)}">${esc(state)}</span>` : ''}</div>
    <div class="ps-fact-value">${esc(f.value)}</div>
    ${f.hint ? `<div class="ps-fact-hint">${ico('zap')}<span>${esc(f.hint)}</span></div>` : ''}
    ${!compact && f.limit ? `<div class="ps-fact-limit">${esc(f.limit)}</div>` : ''}
    ${!compact && meta ? `<div class="ps-fact-meta">${esc(meta)}</div>` : ''}</div></li>`;
}

export function facts(list, opts = {}) {
  if (!Array.isArray(list) || list.length === 0) return '';
  return `<ul class="ps-facts${opts.compact ? ' compact' : ''}">${list.map((f) => fact(f, opts)).join('')}</ul>`;
}

/** Card header: tinted icon, title, subtitle, actions on the right. */
export function cardHead(name, title, sub = '', actions = '', tone = '') {
  return `<div class="ps-card-head"><span class="ps-card-icon"${tone ? ` data-tone="${esc(tone)}"` : ''}>${ico(name)}</span>
    <div class="ps-card-titles"><h3>${esc(title)}</h3>${sub ? `<p class="ps-card-sub">${sub}</p>` : ''}</div>${actions ? `<div class="ps-card-actions">${actions}</div>` : ''}</div>`;
}

/** Section title of a long view. */
export function section(title, note = '') {
  return `<div class="ps-sec reveal"><h2>${esc(title)}</h2>${note ? `<span class="ps-sec-note">${esc(note)}</span>` : ''}</div>`;
}

/** Ring of a score 0-100 drawn with one stroke (stroke-dashoffset), tone of the verdict. */
export function scoreRing(score, tone, label, { text, unit } = {}) {
  const value = Number.isFinite(score) ? score : null;
  const p = value === null ? 0 : Math.max(0, Math.min(100, value)) / 100;
  return `<div class="ps-ring" data-tone="${esc(tone ?? 'off')}"${text && String(text).length > 3 ? ' data-long="1"' : ''} role="img" aria-label="${esc(label)}">
    <svg viewBox="0 0 120 120" aria-hidden="true"><circle class="trk" cx="60" cy="60" r="50"/><circle class="arc" cx="60" cy="60" r="50" pathLength="100" data-p="${p.toFixed(3)}"/></svg>
    <div class="ps-ring-c"><b>${esc(text ?? (value === null ? '—' : int(value)))}</b><span>${esc(unit ?? (value === null ? 'sans score' : 'sur 100'))}</span></div></div>`;
}

/** Sets the arcs of rings and bars of scope after the first paint (transform-free: dashoffset on a pathLength). */
export function paintMeters(scope) {
  requestAnimationFrame(() => requestAnimationFrame(() => {
    for (const el of scope.querySelectorAll('[data-p]')) el.style.setProperty('--p', el.dataset.p);
  }));
}

/** A horizontal meter (scaleX), value 0..1, tone. */
export function meter(p, tone = 'accent', label = '') {
  const v = Number.isFinite(p) ? Math.max(0, Math.min(1, p)) : 0;
  return `<span class="ps-meter" data-tone="${esc(tone)}"${label ? ` role="img" aria-label="${esc(label)}"` : ' aria-hidden="true"'}><span data-p="${v.toFixed(3)}"></span></span>`;
}

/** A chip of a state with its tone. */
export function chip(tone, text, tip = '') {
  return `<span class="chip ${esc(tone ?? '')}"${tip ? ` data-tip="${esc(tip)}"` : ''}>${esc(text)}</span>`;
}

/** Bytes as the engine writes them (Go with a comma). */
export function size(bytes) {
  if (!Number.isFinite(bytes)) return '—';
  const gb = bytes / 1024 ** 3;
  if (gb >= 1024) return `${formatNumber(gb / 1024, 1)}${NBSP}To`;
  if (gb >= 1) return `${formatNumber(gb, 1)}${NBSP}Go`;
  return `${formatNumber(bytes / 1024 ** 2, 0)}${NBSP}Mo`;
}

export const pct = (v, d = 0) => (Number.isFinite(v) ? `${formatNumber(v, d)}${NBSP}%` : '—');

/** Fixed-size SVG donut of parts (values), drawn in by dashoffset; returns markup. */
export function donut(parts, { label = '', center = '' } = {}) {
  const total = parts.reduce((s, x) => s + (Number(x.value) || 0), 0);
  let start = 0;
  const arcs = parts.map((x, n) => {
    const share = total > 0 ? (Number(x.value) || 0) / total : 0;
    const len = Math.max(0, share * 100 - (parts.length > 1 ? 0.8 : 0));
    const arc = len > 0 ? `<circle class="seg" cx="60" cy="60" r="46" pathLength="100" data-len="${len.toFixed(2)}" data-tone="${esc(x.tone ?? '')}" data-c="${n % 8}" transform="rotate(${(start * 360 - 90).toFixed(2)} 60 60)"/>` : '';
    start += share;
    return arc;
  }).join('');
  return `<div class="ps-donut" role="img" aria-label="${esc(label)}"><svg viewBox="0 0 120 120" aria-hidden="true"><circle class="trk" cx="60" cy="60" r="46"/>${arcs}</svg><div class="ps-donut-c">${center}</div></div>`;
}

/** Applies data-len (dash length) and data-c / data-tone colours of donuts inside scope. */
export function paintDonuts(scope) {
  for (const el of scope.querySelectorAll('.ps-donut .seg')) {
    el.style.setProperty('--len', el.dataset.len ?? '0');
  }
  requestAnimationFrame(() => requestAnimationFrame(() => scope.querySelectorAll('.ps-donut').forEach((d) => d.classList.add('on'))));
}

/** Simple local filter text: without accents and case. */
export function fold(text) {
  return String(text ?? '').normalize('NFD').replace(/\p{Diacritic}/gu, '').toLowerCase();
}

/** Escaped key/value lines of a sheet of the engine (identity, account, protection). */
export function sheetLines(sheet) {
  if (!sheet?.lines?.length) return '';
  return `<dl class="ps-sheet">${sheet.lines.map((l) => `<div class="ps-sheet-row"${l.state ? ` data-tone="${esc(l.state)}"` : ''}>
    <dt>${esc(l.label)}</dt><dd><span class="ps-sheet-val${l.state === 'off' ? ' faint' : ''}">${esc(l.value)}</span>${l.copy ? `<button class="btn ghost icon sm ps-copy" type="button" data-copy="${esc(l.value)}" aria-label="Copier ${esc(l.label)}" data-tip="Copier">${glyph('copy')}</button>` : ''}
    ${l.detail ? `<span class="ps-sheet-sub">${esc(l.detail)}</span>` : ''}</dd></div>`).join('')}</dl>`;
}

/** Progress line of a long read: done / total and the current label. */
export function progressMarkup() {
  return `<div class="ps-progress" role="progressbar" aria-valuemin="0" aria-valuemax="100" aria-valuenow="0"><span class="ps-progress-bar"><span data-bar></span></span><span class="ps-progress-label" data-label>Préparation…</span></div>`;
}

export function setProgress(host, p) {
  const bar = host?.querySelector('.ps-progress');
  if (!bar || !p) return;
  const value = p.total > 0 ? p.done / p.total : 0;
  bar.setAttribute('aria-valuenow', String(Math.round(value * 100)));
  bar.querySelector('[data-bar]').style.setProperty('--p', value.toFixed(3));
  bar.querySelector('[data-label]').textContent = p.label ?? '';
}
