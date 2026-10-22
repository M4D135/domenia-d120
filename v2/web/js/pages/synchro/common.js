// Shared helpers of the « Synchronisation et base autonome » screen: French text, one clock and one date format for the whole
// screen, tones, skeletons, small pieces of markup. Every data inserted in HTML goes through esc(); variables reach CSS through
// setVars (strict CSP: no style attribute).
import { icon } from '../../icons.js';
import { esc, errorText, applyVars } from '../../ui.js';
import { glyph, pill, int, count, NBSP, setVars } from '../../kit/index.js';

export { esc, icon, glyph, pill, int, count, NBSP, setVars, errorText };

/** Tones of the contract (Tone enum, camelCase) to the kit tones. */
export const toneOf = (t) => (['ok', 'warn', 'alert', 'info', 'off', 'accent'].includes(t) ? t : 'off');

const pad2 = (n) => String(n).padStart(2, '0');

/**
 * Local date and time « 22/10/2026 05:16 », the format of the engine (SyncText.LocalDateTime) and of the grids
 * (dateStyle « datetime »): one format on the whole screen. « — » when absent.
 */
export function stamp(iso) {
  const t = Date.parse(iso ?? '');
  if (Number.isNaN(t)) return '—';
  const d = new Date(t);
  return `${pad2(d.getDate())}/${pad2(d.getMonth() + 1)}/${d.getFullYear()} ${pad2(d.getHours())}:${pad2(d.getMinutes())}`;
}

/** Local time « 05:31 ». */
export function hour(iso) {
  const t = Date.parse(iso ?? '');
  if (Number.isNaN(t)) return '—';
  const d = new Date(t);
  return `${pad2(d.getHours())}:${pad2(d.getMinutes())}`;
}

/**
 * Elapsed time in the words of the engine (SyncText.Elapsed: « à l’instant », « il y a 12 min », « il y a 3 h », « il y a
 * 2 j »), measured against the clock of the engine (screen.now()), never against the clock of the page alone: every age of
 * the screen reads the same.
 */
export function since(iso, now) {
  const t = Date.parse(iso ?? '');
  if (Number.isNaN(t)) return null;
  const minutes = (now - t) / 60_000;
  if (minutes < -5) return 'à une date future (horloge à vérifier)';
  if (minutes < 1) return 'à l’instant';
  if (minutes < 60) return `il y a ${int(Math.floor(minutes))}${NBSP}min`;
  if (minutes < 1440) return `il y a ${int(Math.floor(minutes / 60))}${NBSP}h`;
  return `il y a ${int(Math.floor(minutes / 1440))}${NBSP}j`;
}

/**
 * A date that may lie ahead (an expiration): « dans 10 j » before it, « expirée il y a 2 j » after it, the full date in a
 * tip; measured on the clock of the engine like every age of the screen.
 */
export function due(iso, now) {
  const t = Date.parse(iso ?? '');
  if (Number.isNaN(t)) return '<span class="sy-none" aria-label="non renseigné">—</span>';
  const minutes = (t - now) / 60_000;
  let text;
  if (minutes <= 0) text = `expirée ${since(iso, now)}`;
  else if (minutes < 60) text = `dans ${int(Math.ceil(minutes))}${NBSP}min`;
  else if (minutes < 1440) text = `dans ${int(Math.floor(minutes / 60))}${NBSP}h`;
  else text = `dans ${int(Math.floor(minutes / 1440))}${NBSP}j`;
  return `<time class="sy-ago" datetime="${esc(iso)}" data-tip="${esc(stamp(iso))}">${esc(text)}</time>`;
}

/** « il y a 12 min » with the full date in a tip, or « — » (non renseigné). */
export function ago(iso, now, prefix = '') {
  const rel = since(iso, now);
  if (!rel) return '<span class="sy-none" aria-label="non renseigné">—</span>';
  return `<time class="sy-ago" datetime="${esc(iso)}" data-tip="${esc(stamp(iso))}">${esc(prefix + rel)}</time>`;
}

/** Skeleton line of the screen (the router waits for skeletons to disappear before data-ready). */
export const sk = (cls) => `<span class="skeleton sk ${cls}"></span>`;
export const skStack = (...cls) => `<div class="sk-stack">${cls.map(sk).join('')}</div>`;

/** Error block with an optional retry button (data-retry). */
export function errorBlock(err, retry = true) {
  return `<div class="sy-error" role="alert">${icon('alert')}<div><b>Lecture impossible</b><p>${esc(errorText(err))}</p></div>`
    + `${retry ? `<button class="btn sm" type="button" data-retry>${icon('refresh')}Réessayer</button>` : ''}</div>`;
}

/** Empty state of a card; « compact » keeps it on one line (a card that only says « nothing yet »). */
export function emptyBlock(iconName, title, text, action = '', compact = false) {
  return `<div class="sy-empty${compact ? ' compact' : ''}"><span class="sy-empty-art">${glyph(iconName)}</span><div class="sy-empty-text"><b>${esc(title)}</b>${text ? `<p>${esc(text)}</p>` : ''}</div>${action}</div>`;
}

/** Card head: icon, title, sub-title, optional right side. */
export function cardHead(iconName, title, sub = '', right = '', tone = '') {
  return `<header class="sy-card-head"><span class="card-icon"${tone ? ` data-tone="${esc(tone)}"` : ''}>${glyph(iconName)}</span>`
    + `<div class="sy-card-titles"><h3>${esc(title)}</h3>${sub ? `<p>${esc(sub)}</p>` : ''}</div>${right ? `<div class="sy-card-tools">${right}</div>` : ''}</header>`;
}

/** Section title of the screen, as on the Accueil (« INDICATEURS CLÉS »): a label, a drawn line, a note. */
export const secHead = (id, title, note = '') => `<div class="sy-sec reveal" data-sec="${esc(id)}"><h2>${esc(title)}</h2>${note ? `<span class="sy-sec-note">${esc(note)}</span>` : ''}</div>`;

/** Button markup with an optional kind mark (network read: blue dot; write: pencil). */
export function button(label, o = {}) {
  const cls = ['btn', o.primary ? 'primary' : '', o.ghost ? 'ghost' : '', o.danger ? 'danger' : '', o.sm ? 'sm' : '', o.subtle ? 'subtle' : ''].filter(Boolean).join(' ');
  const kind = o.kind === 'network' ? '<span class="sy-kind net" aria-hidden="true"></span>' : o.kind === 'write' ? `<span class="sy-kind wr" aria-hidden="true">${glyph('edit')}</span>` : '';
  const kindText = o.kind === 'network' ? '<span class="visually-hidden"> (lecture de l’annuaire)</span>' : o.kind === 'write' ? '<span class="visually-hidden"> (écriture de la base locale)</span>' : '';
  const attrs = Object.entries(o.data ?? {}).map(([k, v]) => ` data-${k}="${esc(v)}"`).join('');
  const tip = o.tip ? ` data-tip="${esc(o.tip)}"` : '';
  const dis = o.disabled ? ' disabled aria-disabled="true"' : '';
  return `<button class="${cls}" type="button"${attrs}${tip}${dis}>${o.icon ? glyph(o.icon) : ''}<span>${esc(label)}</span>${kind}${kindText}</button>`;
}

/** Short hash for display. */
export const shortHash = (sha) => (typeof sha === 'string' ? sha.slice(0, 12) : '');

/** Type label and glyph of an index object. */
export const typeGlyph = (type) => (type === 'computer' ? 'monitor' : 'user');

/** French label of the phases of a read (SyncPhase), with what each one does (shown by the estimate). */
export const PHASES = [
  { id: 'backup', label: 'Sauvegarde', icon: 'shield', text: 'Copie vérifiée de la base, sauf si une copie de moins de 30 min sert déjà de point de retour.' },
  { id: 'reading', label: 'Lecture AD', icon: 'download', text: 'Lecture seule de l’annuaire, par lots, avec progression et arrêt possible.' },
  { id: 'census', label: 'Recensement', icon: 'users', text: 'Toutes les identités du domaine, pour repérer ce qui manque à la base (passes du domaine).' },
  { id: 'fingerprint', label: 'Empreinte', icon: 'hash', text: 'Empreinte SHA-256 du lot reçu, vérifiée de nouveau avant l’enregistrement.' },
  { id: 'validation', label: 'Validation', icon: 'check', text: 'Rapprochement avec la base\u00A0: ajouts, déplacements, valeurs modifiées, non revus.' },
  { id: 'done', label: 'Prêt', icon: 'sparkles', text: 'Rien n’est écrit\u00A0: vous relisez l’aperçu, puis vous confirmez l’enregistrement.' },
];

/** Grid height fitted to its rows (between min and max rows): no half-empty grid, no endless one. */
export function fitGrid(grid, rows, { min = 3, max = 12, extra = 54 } = {}) {
  const n = Math.max(min, Math.min(max, rows || 0));
  setVars(grid.el, { '--k-grid-h': `calc(${n} * var(--k-row, 40px) + ${extra}px)` });
}

/** A counter of requests: an answer of an older request (or of an older generation of the base) never repaints a newer one. */
export function latest() {
  let seq = 0;
  let generation = -1;
  return {
    next: () => ++seq,
    /** True when the answer of request « my » may be shown (newest request, base not older than what is shown). */
    keep(my, gen) {
      if (my !== seq) return false;
      if (Number.isFinite(gen)) {
        if (gen < generation) return false;
        generation = gen;
      }
      return true;
    },
  };
}

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
