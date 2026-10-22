// Shared helpers of the « Synchronisation et base autonome » screen: French text, tones, skeletons, small pieces of markup.
// Every data inserted in HTML goes through esc(); variables reach CSS through setVars (strict CSP: no style attribute).
import { icon } from '../../icons.js';
import { esc, relTime, formatDateTime, errorText, applyVars } from '../../ui.js';
import { glyph, pill, int, count, NBSP, setVars } from '../../kit/index.js';

export { esc, icon, glyph, pill, int, count, NBSP, setVars, relTime, formatDateTime, errorText };

/** Tones of the contract (Tone enum, camelCase) to the kit tones. */
export const toneOf = (t) => (['ok', 'warn', 'alert', 'info', 'off', 'accent'].includes(t) ? t : 'off');

/** « il y a 12 min » with the full date in a tip, or « — ». */
export function ago(iso, prefix = '') {
  const rel = relTime(iso);
  if (!rel) return '<span class="sy-none" aria-label="non renseigné">—</span>';
  return `<time class="sy-ago" datetime="${esc(iso)}" data-tip="${esc(formatDateTime(iso) ?? '')}">${esc(prefix + rel)}</time>`;
}

/** Local date « 21 oct. 2026, 18:14 », « — » when absent. */
export const when = (iso) => formatDateTime(iso) ?? '—';

/** Skeleton line of the screen (the router waits for skeletons to disappear before data-ready). */
export const sk = (cls) => `<span class="skeleton sk ${cls}"></span>`;
export const skStack = (...cls) => `<div class="sk-stack">${cls.map(sk).join('')}</div>`;

/** Error block with an optional retry button (data-retry). */
export function errorBlock(err, retry = true) {
  return `<div class="sy-error" role="alert">${icon('alert')}<div><b>Lecture impossible</b><p>${esc(errorText(err))}</p></div>`
    + `${retry ? `<button class="btn sm" type="button" data-retry>${icon('refresh')}Réessayer</button>` : ''}</div>`;
}

/** Empty state of a card. */
export function emptyBlock(iconName, title, text, action = '') {
  return `<div class="sy-empty"><span class="sy-empty-art">${glyph(iconName)}</span><b>${esc(title)}</b>${text ? `<p>${esc(text)}</p>` : ''}${action}</div>`;
}

/** Card head: icon, title, sub-title, optional right side. */
export function cardHead(iconName, title, sub = '', right = '', tone = '') {
  return `<header class="sy-card-head"><span class="card-icon"${tone ? ` data-tone="${esc(tone)}"` : ''}>${glyph(iconName)}</span>`
    + `<div class="sy-card-titles"><h3>${esc(title)}</h3>${sub ? `<p>${esc(sub)}</p>` : ''}</div>${right ? `<div class="sy-card-tools">${right}</div>` : ''}</header>`;
}

/** Button markup with an optional kind mark (network read: blue dot; write: pencil). */
export function button(label, o = {}) {
  const cls = ['btn', o.primary ? 'primary' : '', o.ghost ? 'ghost' : '', o.danger ? 'danger' : '', o.sm ? 'sm' : '', o.subtle ? 'subtle' : ''].filter(Boolean).join(' ');
  const kind = o.kind === 'network' ? '<span class="sy-kind net" aria-hidden="true"></span>' : o.kind === 'write' ? `<span class="sy-kind wr" aria-hidden="true">${glyph('edit')}</span>` : '';
  const kindText = o.kind === 'network' ? '<span class="visually-hidden"> (lecture de l’annuaire)</span>' : o.kind === 'write' ? '<span class="visually-hidden"> (écriture de la base locale)</span>' : '';
  const attrs = Object.entries(o.data ?? {}).map(([k, v]) => ` data-${k}="${esc(v)}"`).join('');
  const tip = o.tip ? ` data-tip="${esc(o.tip)}"` : '';
  const dis = o.disabled ? ` disabled aria-disabled="true"` : '';
  return `<button class="${cls}" type="button"${attrs}${tip}${dis}>${o.icon ? glyph(o.icon) : ''}<span>${esc(label)}</span>${kind}${kindText}</button>`;
}

/** Sets --i on the children of a host for a cascade entrance. */
export function stagger(host, selector = ':scope > *') {
  host.querySelectorAll(selector).forEach((node, n) => node.style.setProperty('--i', String(Math.min(n, 18))));
}

/** Short hash for display. */
export const shortHash = (sha) => (typeof sha === 'string' ? sha.slice(0, 12) : '');

/** Type label and glyph of an index object. */
export const typeGlyph = (type) => (type === 'computer' ? 'monitor' : 'user');

/** French label of the phases of a read (SyncPhase). */
export const PHASES = [
  { id: 'backup', label: 'Sauvegarde', icon: 'shield' },
  { id: 'reading', label: 'Lecture AD', icon: 'download' },
  { id: 'census', label: 'Recensement', icon: 'users' },
  { id: 'fingerprint', label: 'Empreinte', icon: 'hash' },
  { id: 'validation', label: 'Validation', icon: 'check' },
  { id: 'done', label: 'Prêt', icon: 'sparkles' },
];

/** Applies --p (0..1) on bars and arcs after the first paint, so their transform transition plays. */
export function fill(host) {
  const nodes = host.querySelectorAll('[data-fill]');
  requestAnimationFrame(() => requestAnimationFrame(() => {
    nodes.forEach((node) => node.style.setProperty('--p', String(Math.max(0, Math.min(1, Number(node.dataset.fill) || 0)))));
  }));
}

/** Applies the CSS variables of a scope (--tone from data-tone, --i, flex-grow) then the fills. */
export function paint(host) {
  applyVars(host);
  fill(host);
}
