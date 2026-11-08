// Paramètres: shared pieces of the sections (markup helpers, French wording, bridge calls with the browser preview).
// Every value from the bridge is inserted through esc(); CSS variables go through the CSSOM (CSP: no style attribute).
import { icon } from '../../icons.js';
import { glyph } from '../../kit/glyphs.js';
import { pill } from '../../kit/status.js';
import { esc, errorText, formatNumber, formatDateTime, relTime, applyVars } from '../../ui.js';
import { size, masonryPlan } from './pure.js';

export { esc, icon, glyph, pill, formatNumber, formatDateTime, relTime };

/** No-break space (before « : », « ; », « ? », « ! », « % », inside « »). */
export const NBSP = '\u00A0';
export const COLON = `${NBSP}: `;

/** « texte » with the no-break spaces of French typography. */
export const quote = (text) => `«${NBSP}${text}${NBSP}»`;

/** Keeps a command option or a file name in one piece (« --simulation » never cut after its dashes). */
export const nobreak = (text) => String(text ?? '').replace(/(^|\s)--(?=\w)/g, '$1\u2011\u2011').replace(/(\w)-(?=\w)/g, '$1\u2011');

/** Tones accepted by the kit (data-tone, pills). */
const TONES = new Set(['ok', 'warn', 'alert', 'info', 'off', 'accent']);
export const tone = (t) => (TONES.has(t) ? t : 'off');

/** « 1 234 » with the French grouping. */
export const int = (n) => (Number.isFinite(n) ? formatNumber(n) : '—');

/** Number and noun with the French plural rule (0 and 1 take the singular). */
export const count = (n, one, many) => `${int(n)}${NBSP}${Math.abs(n) >= 2 ? many : one}`;

/** « 41,2 Mo » from bytes (unknown: « inconnu »). */
export { size };

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

/**
 * Segmented choice (radio group) built on the shared .segmented control; data-value on each button. One tab stop (the
 * checked radio), arrows move and choose (radioKeys), as the APG radio group pattern.
 */
export function segmented(name, label, options, value) {
  const any = options.some((o) => String(o.value) === String(value));
  return `<div class="segmented pr-seg" role="radiogroup" aria-label="${esc(label)}" data-seg="${esc(name)}"><span class="thumb" aria-hidden="true"></span>${options.map((o, n) => {
    const on = String(o.value) === String(value);
    return `<button type="button" role="radio" aria-checked="${on}" tabindex="${on || (!any && n === 0) ? 0 : -1}" data-value="${esc(o.value)}"${o.disabled ? ' aria-disabled="true"' : ''}${o.tip ? ` data-tip="${esc(o.tip)}"` : ''}>${o.icon ? glyph(o.icon) : ''}<span>${esc(o.label)}</span></button>`;
  }).join('')}</div>`;
}

/**
 * Keyboard of the radio groups of a scope (segments, theme cards, collection profiles): ← → ↑ ↓ move to the next radio and
 * choose it, Début and Fin the first and the last; the checked radio keeps the only tab stop. Returns true when handled.
 */
export function radioKeys(e) {
  const radio = e.target instanceof Element ? e.target.closest('[role="radio"]') : null;
  const group = radio?.closest('[role="radiogroup"]');
  if (!radio || !group) return false;
  const keys = { ArrowRight: 1, ArrowDown: 1, ArrowLeft: -1, ArrowUp: -1 };
  if (!(e.key in keys) && e.key !== 'Home' && e.key !== 'End') return false;
  const radios = [...group.querySelectorAll('[role="radio"]')].filter((r) => r.getAttribute('aria-disabled') !== 'true' && !r.disabled);
  if (!radios.length) return false;
  e.preventDefault();
  const at = Math.max(0, radios.indexOf(radio));
  const next = e.key === 'Home' ? radios[0] : e.key === 'End' ? radios[radios.length - 1] : radios[(at + keys[e.key] + radios.length) % radios.length];
  next.focus();
  next.click();
  return true;
}

/** Moves the only tab stop of a radio group to its checked radio. */
export function rovingTabs(group) {
  const radios = [...group.querySelectorAll('[role="radio"]')];
  const checked = radios.find((r) => r.getAttribute('aria-checked') === 'true') ?? radios[0];
  radios.forEach((r) => r.setAttribute('tabindex', r === checked ? '0' : '-1'));
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
  const mark = write ? `<span class="pr-write-mark" aria-hidden="true" data-tip="Écriture : plan, confirmation, reçu et relecture">${glyph('edit')}</span>` : '';
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
    const gap = parseFloat(getComputedStyle(grid).rowGap) || 0;
    const stacks = masonryPlan(children.map((el) => ({ wide: isWide(el), height: el.offsetHeight })), gap);
    if (stacks.every((k) => k === null)) { grid.dataset.balanced = 'simple'; continue; }
    const parts = [];
    let cols = null;
    children.forEach((el, n) => {
      if (stacks[n] === null) { cols = null; parts.push(el); return; }
      if (!cols) {
        cols = [document.createElement('div'), document.createElement('div')];
        cols.forEach((c) => { c.className = 'pr-col'; });
        parts.push(cols);
      }
      cols[stacks[n]].append(el);
    });
    grid.replaceChildren(...parts.flat());
    grid.dataset.balanced = 'cols';
  }
}

/** Keeps the thumb of each .segmented of a scope under its pressed button (transform only). */
export function syncSegments(scope) {
  for (const seg of scope.querySelectorAll('.pr-seg')) {
    const thumb = seg.querySelector(':scope > .thumb');
    const on = seg.querySelector('button[aria-checked="true"]');
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
    b.setAttribute('aria-checked', String(on));
  });
  rovingTabs(seg);
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
