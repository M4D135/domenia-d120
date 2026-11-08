// Status pills and the shared state vocabulary (Domenia 1 suite kit: Prêt, En cours, Arrêt demandé, À vérifier,
// Échec, Vérifié). « Terminé » is not « Vérifié », and a requested stop is not a confirmed cancellation.
import { glyph } from './glyphs.js';
import { esc } from './util.js';

/** Tones of the design tokens (text on soft fill, mark for dots). */
export const TONES = ['ok', 'warn', 'alert', 'info', 'off', 'accent'];

/**
 * Operation states and their wording, shared by every screen.
 * @type {Object<string, {label: string, tone: string, icon?: string, spin?: boolean, pulse?: boolean, tip: string}>}
 */
export const STATES = {
  idle: { label: 'En attente', tone: 'off', icon: 'clock', tip: 'Rien n’est lancé.' },
  ready: { label: 'Prêt', tone: 'ok', icon: 'check', tip: 'Peut être lancé.' },
  running: { label: 'En cours', tone: 'info', spin: true, tip: 'L’opération travaille en arrière-plan.' },
  stopping: { label: 'Arrêt demandé', tone: 'warn', pulse: true, tip: 'L’arrêt est demandé : ce n’est pas encore une annulation confirmée.' },
  check: { label: 'À vérifier', tone: 'warn', icon: 'eye', tip: 'Résultat incertain : relisez avant de conclure.' },
  done: { label: 'Terminé', tone: 'info', icon: 'check', tip: 'Terminé ne veut pas dire vérifié.' },
  verified: { label: 'Vérifié', tone: 'ok', icon: 'shield', tip: 'Relu après l’opération : l’état attendu est confirmé.' },
  failed: { label: 'Échec', tone: 'alert', icon: 'alert', tip: 'L’opération a échoué ; rien n’est rejoué automatiquement.' },
  readonly: { label: 'Lecture seule', tone: 'accent', icon: 'lock', tip: 'Aucune écriture possible dans ce mode.' },
};

/**
 * Status pill.
 * @param {string} tone                      ok, warn, alert, info, off or accent.
 * @param {string} label
 * @param {{ icon?: string, pulse?: boolean, spin?: boolean, tip?: string, size?: 'sm'|'md', dot?: boolean }} [o]
 * @returns {string}
 */
export function pill(tone, label, o = {}) {
  const t = TONES.includes(tone) ? tone : 'off';
  let mark = '';
  if (o.spin) mark = '<span class="k-spin" aria-hidden="true"></span>';
  else if (o.icon) mark = glyph(o.icon, 'k-pill-ico');
  else if (o.dot !== false) mark = `<span class="k-pill-dot${o.pulse ? ' pulse' : ''}" aria-hidden="true"></span>`;
  return `<span class="k-pill ${t}${o.size === 'sm' ? ' sm' : ''}${o.pulse ? ' live' : ''}"${o.tip ? ` data-tip="${esc(o.tip)}"` : ''}>${mark}${esc(label)}</span>`;
}

/**
 * Pill of a shared state (STATES).
 * @param {keyof typeof STATES | string} state
 * @param {{ label?: string, size?: 'sm'|'md' }} [o]  label replaces the standard wording (same tone).
 * @returns {string}
 */
export function statePill(state, o = {}) {
  const s = STATES[state] ?? STATES.idle;
  return pill(s.tone, o.label ?? s.label, { icon: s.spin ? undefined : s.icon, spin: s.spin, pulse: s.pulse, tip: s.tip, size: o.size });
}

/**
 * Small numeric badge (counts on tabs, buttons, menus).
 * @param {number|string} value @param {string} [tone]
 */
export function badge(value, tone = 'off') {
  return `<span class="k-badge ${TONES.includes(tone) ? tone : 'off'}">${esc(value)}</span>`;
}
