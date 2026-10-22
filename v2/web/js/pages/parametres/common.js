// Paramètres: shared pieces of the sections (markup helpers, French wording, bridge calls with the browser preview).
// Every value from the bridge is inserted through esc(); CSS variables go through the CSSOM (CSP: no style attribute).
import { icon } from '../../icons.js';
import { glyph } from '../../kit/glyphs.js';
import { pill } from '../../kit/status.js';
import { esc, errorText, formatNumber, formatDateTime, relTime, applyVars } from '../../ui.js';

export { esc, icon, glyph, pill, formatNumber, formatDateTime, relTime };

/** No-break space (before « : », « % », inside « »). */
export const NBSP = ' ';
export const COLON = `${NBSP}: `;

/** Tones accepted by the kit (data-tone, pills). */
const TONES = new Set(['ok', 'warn', 'alert', 'info', 'off', 'accent']);
export const tone = (t) => (TONES.has(t) ? t : 'off');

/** « 1 234 » with the French grouping. */
export const int = (n) => (Number.isFinite(n) ? formatNumber(n) : '—');

/** Number and noun with the French plural rule (0 and 1 take the singular). */
export const count = (n, one, many) => `${int(n)}${NBSP}${Math.abs(n) >= 2 ? many : one}`;

/** « 41,2 Mo » from bytes (unknown: « inconnu »). */
export function size(bytes) {
  if (!Number.isFinite(bytes) || bytes < 0) return 'inconnu';
  if (bytes < 1024) return `${int(bytes)}${NBSP}o`;
  const units = ['Ko', 'Mo', 'Go', 'To'];
  let value = bytes;
  let unit = 'o';
  for (const u of units) {
    value /= 1024;
    unit = u;
    if (value < 1024) break;
  }
  const rounded = Math.round(value * 10) / 10;
  return `${formatNumber(rounded, Number.isInteger(rounded) ? 0 : 1)}${NBSP}${unit}`;
}

/** Local date and time, or « — ». */
export const when = (iso) => formatDateTime(iso) ?? '—';

/** Relative time in a span refreshed by the page ticker. */
export function rel(iso, prefix = '') {
  const text = relTime(iso);
  return text ? `<span data-rel="${esc(iso)}" data-prefix="${esc(prefix)}">${esc(prefix + text)}</span>` : '';
}

/** True when the bridge refused an operation that the browser preview does not know either. */
const isPreview = () => !(window.chrome && window.chrome.webview);

/**
 * Bridge call of the screen: ctx.call (tracked by the shell for its busy line and data-ready). In the browser preview,
 * an operation unknown to the shared mock is answered by the preview of this screen (same shapes), so the page can be
 * seen without the engine.
 */
export function makeCall(ctx) {
  return async (op, args = {}) => {
    try {
      return await ctx.call(op, args);
    } catch (err) {
      if (err?.code === 'operation.unknown' && isPreview()) {
        const preview = await import('./preview.js');
        return preview.previewCall(op, args);
      }
      throw err;
    }
  };
}

/** Operator text of an error (bridge message, or a French fallback). */
export const reported = (err, fallback) => errorText(err, fallback ?? 'Opération impossible pour l’instant.');

/** Section header inside the content column. */
export function sectionHead(s, actions = '') {
  return `<header class="pr-sec-head reveal">
    <span class="pr-sec-icon" data-tone="${esc(s.tone ?? 'accent')}">${glyph(s.icon)}</span>
    <div class="pr-sec-titles"><h2>${esc(s.title)}</h2><p>${esc(s.lead)}</p></div>
    <div class="pr-sec-actions">${actions}</div>
  </header>`;
}

/** A card of a section: icon, title, subtitle, optional head actions; body as trusted markup. */
export function card({ id = '', title, sub = '', iconName = 'settings', actions = '', body = '', cls = '', toneName = '' }) {
  return `<section class="card pr-card spot reveal ${esc(cls)}"${id ? ` data-card="${esc(id)}"` : ''}>
    <div class="pr-card-head"><span class="pr-card-icon"${toneName ? ` data-tone="${esc(toneName)}"` : ''}>${glyph(iconName)}</span>
      <div class="pr-card-titles"><h3>${esc(title)}</h3>${sub ? `<span class="pr-card-sub">${esc(sub)}</span>` : ''}</div>
      ${actions ? `<div class="pr-card-actions">${actions}</div>` : ''}</div>
    <div class="pr-card-body">${body}</div>
  </section>`;
}

/** Setting row: label and description on the left, control on the right. */
export function row({ label, desc = '', control = '', id = '', setting = '', tip = '' }) {
  return `<div class="pr-row"${id ? ` data-row="${esc(id)}"` : ''}${setting ? ` data-setting="${esc(setting)}"` : ''}>
    <div class="pr-row-text"><span class="pr-row-label">${esc(label)}</span>${desc ? `<span class="pr-row-desc">${esc(desc)}</span>` : ''}</div>
    <div class="pr-row-control"${tip ? ` data-tip="${esc(tip)}"` : ''}>${control}</div>
  </div>`;
}

/** Key/value lines (dl) for facts. */
export function facts(items) {
  return `<dl class="pr-facts">${items.filter(Boolean).map(([k, v, sub, extra]) => `<div class="pr-fact"><dt>${esc(k)}</dt><dd>${v === null || v === undefined || v === ''
    ? '<span class="pr-none">—</span><span class="visually-hidden">non renseigné</span>' : esc(v)}${sub ? `<span class="pr-fact-sub">${esc(sub)}</span>` : ''}${extra ?? ''}</dd></div>`).join('')}</dl>`;
}

/** Bulleted sentences (rules, safeguards). */
export function notes(lines, cls = '') {
  if (!lines?.length) return '';
  return `<ul class="pr-notes ${esc(cls)}">${lines.map((l, n) => `<li data-j="${n}">${glyph('info')}<span>${esc(l)}</span></li>`).join('')}</ul>`;
}

/** Segmented choice (radio group) built on the shared .segmented control; data-value on each button. */
export function segmented(name, label, options, value) {
  return `<div class="segmented pr-seg" role="radiogroup" aria-label="${esc(label)}" data-seg="${esc(name)}"><span class="thumb" aria-hidden="true"></span>${options.map((o) =>
    `<button type="button" role="radio" aria-checked="${String(o.value) === String(value)}" aria-pressed="${String(o.value) === String(value)}" data-value="${esc(o.value)}"${o.tip ? ` data-tip="${esc(o.tip)}"` : ''}>${o.icon ? glyph(o.icon) : ''}<span>${esc(o.label)}</span></button>`).join('')}</div>`;
}

/** Switch (checkbox role="switch"). */
export function toggle(name, label, checked, { disabled = false, reason = '' } = {}) {
  return `<label class="pr-switch"${reason ? ` data-tip="${esc(reason)}"` : ''}><input class="switch" type="checkbox" role="switch" data-toggle="${esc(name)}" aria-label="${esc(label)}"${checked ? ' checked' : ''}${disabled ? ' disabled' : ''}></label>`;
}

/** Switch with its visible label (toolbar). */
export function switchLabel(name, label, checked, { disabled = false, reason = '' } = {}) {
  return `<label class="pr-check"${reason ? ` data-tip="${esc(reason)}"` : ''}><input class="switch" type="checkbox" role="switch" data-toggle="${esc(name)}"${checked ? ' checked' : ''}${disabled ? ' disabled' : ''}><span>${esc(label)}</span></label>`;
}

/** Native select styled by the kit (.k-select). */
export function select(name, label, options, value, { disabled = false } = {}) {
  return `<span class="k-select sm pr-select"><select class="input" data-select="${esc(name)}" aria-label="${esc(label)}"${disabled ? ' disabled' : ''}>${options.map((o) =>
    `<option value="${esc(o.value)}"${String(o.value) === String(value) ? ' selected' : ''}>${esc(o.label)}</option>`).join('')}</select></span>`;
}

/** Button with icon; data-act carries the action. kind: '' | 'primary' | 'ghost' | 'danger'. */
export function button(act, label, iconName, { kind = '', disabled = false, reason = '', write = false, extra = '', small = true } = {}) {
  const cls = ['btn', kind, small ? 'sm' : ''].filter(Boolean).join(' ');
  const mark = write ? `<span class="pr-write-mark" aria-hidden="true" data-tip="Écriture : plan, confirmation, reçu et relecture">${glyph('edit')}</span>` : '';
  // A refused action stays focusable and says why (aria-disabled and its tip); the page blocks its clicks.
  return `<button type="button" class="${cls}" data-act="${esc(act)}"${disabled ? ' aria-disabled="true"' : ''}${disabled && reason ? ` data-tip="${esc(reason)}"` : ''}${extra}>${iconName ? glyph(iconName) : ''}<span>${esc(label)}</span>${mark}</button>`;
}

/** Turns an action on or off, with the reason of a refusal in its tip (and for screen readers). */
export function setOff(btn, off, reason = '') {
  if (!btn) return;
  if (off) {
    btn.setAttribute('aria-disabled', 'true');
    if (reason) btn.dataset.tip = reason;
  } else {
    btn.removeAttribute('aria-disabled');
    delete btn.dataset.tip;
  }
}

/** True for an action that is refused or busy. */
export const isOff = (btn) => !btn || btn.disabled || btn.getAttribute('aria-disabled') === 'true';

/** Empty or unavailable state inside a card. */
export function emptyState(iconName, title, text, action = '') {
  return `<div class="pr-empty"><span class="pr-empty-art">${glyph(iconName)}</span><b>${esc(title)}</b><p>${esc(text)}</p>${action}</div>`;
}

/** Error card of a section (with « Réessayer »). */
export function errorBlock(err, retryAct = 'retry') {
  return `<div class="pr-error" role="alert"><span class="pr-error-art">${icon('alert')}</span><div><b>Lecture impossible</b><p>${esc(reported(err))}</p>${err?.code ? `<span class="pr-code">${esc(err.code)}</span>` : ''}</div>
    <button type="button" class="btn sm" data-act="${esc(retryAct)}">${icon('refresh')}Réessayer</button></div>`;
}

/** Skeleton of a section while it loads (data-ready waits for it to disappear). */
export function skeleton(cards = 3) {
  const one = '<section class="card pr-card pr-skel"><div class="pr-sk-stack"><span class="skeleton pr-sk w40"></span><span class="skeleton pr-sk w70"></span><span class="skeleton pr-sk w100 tall"></span><span class="skeleton pr-sk w85"></span></div></section>';
  return `<div class="pr-grid">${Array.from({ length: cards }, () => one).join('')}</div>`;
}

/** Paints the data-* variables of a scope (tones, delays, percentages) through the CSSOM. */
export function paint(scope) {
  applyVars(scope);
  for (const el of scope.querySelectorAll('[data-w]')) {
    const w = Number(el.dataset.w);
    el.style.setProperty('--w', String(Number.isFinite(w) ? Math.max(0, Math.min(100, w)) : 0));
  }
  balance(scope);
}

/**
 * Two-column masonry of the card grids: each run of half-width cards between two wide ones is shared between two column
 * stacks, the next card going under the shorter stack (order kept inside each stack), so a short card never leaves a hole
 * beside a tall one. Only when the grid shows two columns and every card of the run is laid out (a hidden tab waits).
 */
export function balance(scope) {
  const grids = scope.matches?.('.pr-grid') ? [scope] : [...scope.querySelectorAll('.pr-grid')];
  for (const grid of grids) {
    if (grid.dataset.balanced || !grid.isConnected) continue;
    if (getComputedStyle(grid).gridTemplateColumns.split(' ').filter(Boolean).length < 2) continue;
    const children = [...grid.children];
    const isWide = (el) => el.classList.contains('pr-wide') || el.classList.contains('pr-footnote');
    if (children.some((el) => !isWide(el) && el.offsetHeight === 0)) continue;
    const runs = [];
    let run = [];
    for (const el of children) {
      if (isWide(el)) { if (run.length) runs.push(run); run = []; runs.push(el); } else run.push(el);
    }
    if (run.length) runs.push(run);
    if (!runs.some((r) => Array.isArray(r) && r.length > 2)) { grid.dataset.balanced = 'simple'; continue; }
    const gap = parseFloat(getComputedStyle(grid).rowGap) || 0;
    const measured = new Map(children.map((el) => [el, el.offsetHeight]));
    const parts = runs.map((r) => {
      if (!Array.isArray(r)) return r;
      if (r.length < 3) return r;
      const cols = [document.createElement('div'), document.createElement('div')];
      const heights = [0, 0];
      for (const card of r) {
        const k = heights[0] <= heights[1] ? 0 : 1;
        cols[k].append(card);
        heights[k] += measured.get(card) + gap;
      }
      cols.forEach((c) => { c.className = 'pr-col'; });
      return cols;
    });
    grid.replaceChildren(...parts.flat());
    grid.dataset.balanced = 'cols';
  }
}

/** Keeps the thumb of each .segmented of a scope under its pressed button (transform only). */
export function syncSegments(scope) {
  for (const seg of scope.querySelectorAll('.pr-seg')) {
    const thumb = seg.querySelector(':scope > .thumb');
    const on = seg.querySelector('button[aria-pressed="true"]');
    if (!thumb) continue;
    if (!on) { thumb.style.setProperty('opacity', '0'); continue; }
    thumb.style.removeProperty('opacity');
    thumb.style.setProperty('--x', `${on.offsetLeft}px`);
    thumb.style.setProperty('--w', `${on.offsetWidth}px`);
    thumb.style.setProperty('--k', String(on.offsetWidth / 100));
  }
}

/** Updates the pressed button of a segmented control. */
export function pressSegment(seg, value) {
  seg.querySelectorAll('button[data-value]').forEach((b) => {
    const on = b.dataset.value === String(value);
    b.setAttribute('aria-pressed', String(on));
    b.setAttribute('aria-checked', String(on));
  });
  syncSegments(seg.parentElement ?? seg);
}

/** A thin horizontal meter (share of a total), value 0..100. */
export function meter(value, label, toneName = 'accent') {
  const v = Number.isFinite(value) ? Math.max(0, Math.min(100, value)) : 0;
  // toneName null: the colour comes from the stylesheet (series colours of a legend).
  const toneAttr = toneName ? ` data-tone="${esc(tone(toneName))}"` : '';
  return `<span class="pr-meter" role="img" aria-label="${esc(label)}"${toneAttr}><span class="pr-meter-fill" data-w="${v}"></span></span>`;
}

/** Hidden copy of a tip for screen readers. */
export const srText = (text) => `<span class="visually-hidden">${esc(text)}</span>`;
