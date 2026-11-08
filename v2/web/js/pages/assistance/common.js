// Assistance · shared pieces: local icons, kit pills, avatars, empty states, skeletons, buttons that say why they are greyed,
// readable values and DN that break at their commas. Everything returns trusted markup built with esc(); nothing here calls
// the bridge.
import { glyph } from '../../kit/glyphs.js';
import { pill, freshness } from '../../kit/index.js';
import { esc, formatDateTime, reveal } from '../../ui.js';
import { NBSP, COLON, plural, initials, dnParts, readableValue, isIdentifier } from './format.js';

export { NBSP, COLON, plural, initials };

// Icons the application set does not have (same 24 px grid and 1.8 stroke as icons.js).
const LOCAL = {
  printer: '<path d="M7 8V3.5h10V8"/><rect x="3" y="8" width="18" height="9" rx="2.5"/><path d="M7 14h10v6.5H7Z"/><path d="M17 11.5h.01"/>',
  swap: '<path d="M7 4 3.5 7.5 7 11"/><path d="M3.5 7.5H17"/><path d="m17 13 3.5 3.5L17 20"/><path d="M20.5 16.5H7"/>',
  ticket: '<path d="M4 7.5A2.5 2.5 0 0 1 6.5 5h11A2.5 2.5 0 0 1 20 7.5v2a2 2 0 0 0 0 5v2a2.5 2.5 0 0 1-2.5 2.5h-11A2.5 2.5 0 0 1 4 16.5v-2a2 2 0 0 0 0-5Z"/><path d="M14 5v14" stroke-dasharray="2 2.4"/>',
  archive: '<rect x="3" y="4" width="18" height="5" rx="1.5"/><path d="M5 9v9.5A1.5 1.5 0 0 0 6.5 20h11a1.5 1.5 0 0 0 1.5-1.5V9"/><path d="M10 13h4"/>',
  route: '<circle cx="6" cy="19" r="2.2"/><circle cx="18" cy="5" r="2.2"/><path d="M8.2 19H15a3.5 3.5 0 0 0 0-7H9a3.5 3.5 0 0 1 0-7h6.8"/>',
  scan: '<path d="M4 8V5.5A1.5 1.5 0 0 1 5.5 4H8M16 4h2.5A1.5 1.5 0 0 1 20 5.5V8M20 16v2.5a1.5 1.5 0 0 1-1.5 1.5H16M8 20H5.5A1.5 1.5 0 0 1 4 18.5V16"/><path d="M4 12h16"/>',
  bulb: '<path d="M9 18h6M10 21h4"/><path d="M12 3a6 6 0 0 0-3.6 10.8c.7.5 1.1 1.3 1.1 2.2h5c0-.9.4-1.7 1.1-2.2A6 6 0 0 0 12 3Z"/>',
  compare: '<rect x="3" y="4" width="7.5" height="16" rx="2"/><rect x="13.5" y="4" width="7.5" height="16" rx="2"/><path d="M6 9h1.5M6 13h1.5M16.5 9H18M16.5 13H18"/>',
  steps: '<path d="M4 6h3M4 12h3M4 18h3"/><path d="M10 6h10M10 12h10M10 18h10"/>',
  fingerprint: '<path d="M12 11v3.5a6.5 6.5 0 0 1-1.2 3.8"/><path d="M8.5 9.2A4 4 0 0 1 16 11v1.5"/><path d="M5.5 15.5A10 10 0 0 0 6 11a6 6 0 0 1 10.8-3.6"/><path d="M18.4 14.5a14 14 0 0 1-.9 4"/><path d="M15.4 16.7a12 12 0 0 1-1.3 3.3"/><path d="M3.6 8.5A9 9 0 0 1 12 3a9 9 0 0 1 8.5 6.2"/>',
  upload: '<path d="M12 16V5M7 9.5l5-5 5 5"/><path d="M4.5 19.5h15"/>',
  save: '<path d="M5.5 3.5h10l4 4v11a1.5 1.5 0 0 1-1.5 1.5h-12A1.5 1.5 0 0 1 4.5 18.5v-13A2 2 0 0 1 5.5 3.5Z"/><path d="M8 3.5v5h7v-5M8 20v-6h8v6"/>',
  list: '<path d="M9 6h11M9 12h11M9 18h11"/><circle cx="4.5" cy="6" r="1.2"/><circle cx="4.5" cy="12" r="1.2"/><circle cx="4.5" cy="18" r="1.2"/>',
};

/** Icon by name: local set first, then the kit glyphs and the application icons. */
export function ico(name, cls = '') {
  const body = LOCAL[name];
  if (!body) return glyph(name, cls);
  return `<svg class="${cls}" width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${body}</svg>`;
}

/** Tones of the bridge (ok, warn, alert, info, off, accent); anything else becomes off. */
export function tone(value) {
  return ['ok', 'warn', 'alert', 'info', 'off', 'accent'].includes(value) ? value : 'off';
}

/** A toned pill of the kit (docs/KIT.md § 4.12), small size; icons of this screen are accepted too. */
export function chip(t, label, { icon: name = '', tip = '', size = 'sm' } = {}) {
  if (!LOCAL[name]) return pill(tone(t), label, { icon: name || undefined, tip: tip || undefined, size });
  return `<span class="k-pill ${tone(t)}${size === 'sm' ? ' sm' : ''}"${tip ? ` data-tip="${esc(tip)}"` : ''}>${ico(name, 'k-pill-ico')}${esc(label)}</span>`;
}

/**
 * A button of the screen. A greyed button stays focusable and says why (aria-disabled, tooltip and accessible description,
 * docs/KIT.md § 1.2); the page ignores its clicks.
 * @param {{ label: string, icon?: string, cls?: string, data?: Object<string,string>, disabled?: boolean, reason?: string, tip?: string, aria?: string, iconOnly?: boolean, spin?: boolean }} b
 */
export function button(b) {
  const data = Object.entries(b.data ?? {}).map(([k, v]) => ` data-${k}="${esc(v)}"`).join('');
  const tip = b.disabled && b.reason ? b.reason : b.tip ?? (b.iconOnly ? b.label : '');
  const mark = b.spin ? '<span class="k-spin" aria-hidden="true"></span>' : b.icon ? ico(b.icon) : '';
  const text = b.iconOnly ? `<span class="visually-hidden">${esc(b.label)}</span>` : esc(b.label);
  const why = b.disabled && b.reason ? `<span class="visually-hidden">${COLON}${esc(b.reason)}</span>` : '';
  return `<button class="btn ${b.cls ?? 'subtle sm'}${b.iconOnly ? ' icon' : ''}" type="button"${data}${b.disabled ? ' aria-disabled="true"' : ''}`
    + `${tip ? ` data-tip="${esc(tip)}"` : ''}${b.aria ? ` aria-label="${esc(b.aria)}"` : ''}>${mark}${text}${why}</button>`;
}

export function avatar(name, kind, size = '') {
  const cls = kind === 'computer' ? 'pc' : 'user';
  return `<span class="as-avatar ${cls}${size ? ` ${size}` : ''}" aria-hidden="true">${kind === 'computer' ? ico('monitor') : ''}<b>${esc(initials(name, kind))}</b></span>`;
}

/** « Lu il y a 3 min » that keeps itself up to date (kit freshness, startFreshness on the page). */
export function fresh(iso, label = 'Lu', staleAfter = 15 * 60_000) {
  return freshness(iso ?? null, { label, staleAfter });
}

/** Empty state of a card: icon tile, title, text and optional actions (trusted markup). */
export function empty(iconName, title, text, actions = '') {
  return `<div class="as-empty"><div class="as-empty-art">${ico(iconName)}</div><h3>${esc(title)}</h3><p>${esc(text)}</p>${actions ? `<div class="as-empty-actions">${actions}</div>` : ''}</div>`;
}

/** Skeleton lines while a read runs (the capture host waits for them to disappear). */
export function skeleton(lines = ['w40', 'w85', 'w70', 'w55']) {
  return `<div class="as-sk-stack" aria-busy="true">${lines.map((cls) => `<span class="skeleton as-sk ${cls}"></span>`).join('')}</div>`;
}

/** Short fingerprint: first 12 hexadecimal characters, full value in the tip. */
export function shortHash(sha) {
  const value = String(sha ?? '');
  return `<code class="as-hash" data-tip="${esc(value)}">${esc(value.slice(0, 12))}…</code>`;
}

/** Bridge error code of a refusal, or ''. */
export function codeOf(err) {
  return err && typeof err.code === 'string' ? err.code : '';
}

/** A DN that breaks only between its RDN (after each comma), never inside a word. */
export function dnHtml(dn) {
  return dnParts(dn).map((p) => `<span class="as-rdn">${esc(p)}</span>`).join(',<wbr>');
}

/** Text of a monospace preview whose DN break after their commas (the copied text stays the original). */
export function breakableText(text) {
  return esc(text).replace(/,(?=\S)/g, ',<wbr>');
}

/**
 * One captured value as the operator reads it: a local date (raw value in the tip), « jamais », the name of a DN (full DN in
 * the tip), an identifier kept on one line, or the text.
 */
export function valueHtml(attribute, value) {
  const v = readableValue(attribute, value);
  if (v.kind === 'date') return `<time class="as-val-date" datetime="${esc(v.iso)}" data-tip="${esc(`${formatDateTime(v.iso) ?? v.text} · valeur brute${COLON}${v.raw}`)}">${esc(v.text)}</time>`;
  if (v.kind === 'special') return `<span class="as-val-special" data-tip="${esc(`Valeur brute${COLON}${v.raw}`)}">${esc(v.text)}</span>`;
  if (v.kind === 'dn') return v.text === v.raw ? `<span class="mono as-dn">${dnHtml(v.raw)}</span>` : `<span class="as-val-dn" data-tip="${esc(v.raw)}">${esc(v.text)}</span>`;
  return isIdentifier(v.text) ? `<span class="mono as-ident" data-tip="${esc(v.text)}">${esc(v.text)}</span>` : `<span class="mono">${esc(v.text)}</span>`;
}

/** A fact tile value: identifiers (DNS names, accounts) stay on one line with the full value in the tip. */
export function factValue(value) {
  return isIdentifier(value) && /[-.]/.test(value) ? `<b class="as-ident" data-tip="${esc(value)}">${esc(value)}</b>` : `<b>${esc(value)}</b>`;
}

/**
 * Entrance of a view: the cards come in once, on the first paint; a repaint (new incident, new answer, typing) shows the new
 * content at once instead of replaying the entrance.
 * @returns {() => void} cleanup of the observer
 */
export function enter(host, state) {
  if (state.painted) {
    host.querySelectorAll('.reveal').forEach((node) => node.classList.remove('reveal'));
    return () => {};
  }
  state.painted = true;
  return reveal(host);
}
