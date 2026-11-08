// Status glyphs (TRV-008, Domenia 1 Get-DomeniaStatusGlyph): a status is carried by a symbol AND a word; colour only
// reinforces them. French and English aliases are recognised whatever the case or the accents; an unknown status is shown
// as « Inconnu », never as a success. Pure, apart from statusBadge which returns trusted markup.
import { esc } from '../ui.js';

/** The 14 normalized statuses: key, symbol, word, tone of the design tokens. */
export const STATUS_GLYPHS = Object.freeze([
  { key: 'success', glyph: '✓', word: 'Confirmé', tone: 'ok' },
  { key: 'observed', glyph: '●', word: 'Constaté', tone: 'neutral' },
  { key: 'estimated', glyph: '≈', word: 'Estimé', tone: 'off' },
  { key: 'warning', glyph: '⚠', word: 'Attention', tone: 'warn' },
  { key: 'partial', glyph: '◐', word: 'Partiel', tone: 'warn' },
  { key: 'error', glyph: '✕', word: 'Erreur', tone: 'alert' },
  { key: 'refused', glyph: '⊘', word: 'Refusé', tone: 'alert' },
  { key: 'uncertain', glyph: '⚑', word: 'À vérifier', tone: 'warn' },
  { key: 'pending', glyph: '◷', word: 'En cours', tone: 'info' },
  { key: 'unknown', glyph: '?', word: 'Inconnu', tone: 'off' },
  { key: 'unavailable', glyph: '○', word: 'Indisponible', tone: 'off' },
  { key: 'empty', glyph: '∅', word: 'Vide', tone: 'off' },
  { key: 'nochange', glyph: '=', word: 'Aucun changement', tone: 'off' },
  { key: 'info', glyph: 'i', word: 'Information', tone: 'info' },
]);

const ALIASES = {
  ok: 'success', verifie: 'success', verified: 'success', reussi: 'success', succes: 'success', success: 'success', confirme: 'success',
  constate: 'observed', observed: 'observed', estime: 'estimated', estimated: 'estimated',
  attention: 'warning', avertissement: 'warning', warning: 'warning', partiel: 'partial', partial: 'partial',
  failed: 'error', failure: 'error', echec: 'error', erreur: 'error', error: 'error',
  refuse: 'refused', denied: 'refused', 'acces refuse': 'refused', refused: 'refused',
  'a verifier': 'uncertain', incertain: 'uncertain', unconfirmed: 'uncertain', 'non confirme': 'uncertain', uncertain: 'uncertain',
  'en cours': 'pending', inprogress: 'pending', running: 'pending', pending: 'pending',
  inconnu: 'unknown', indetermine: 'unknown', unknown: 'unknown',
  indisponible: 'unavailable', injoignable: 'unavailable', unreachable: 'unavailable', unavailable: 'unavailable',
  vide: 'empty', empty: 'empty', 'aucun changement': 'nochange', nochange: 'nochange', information: 'info', info: 'info',
};

const fold = (t) => String(t ?? '').trim().replace(/\s+/g, ' ').normalize('NFD').replace(/\p{Diacritic}/gu, '').toLowerCase();

/**
 * Glyph of a status text. `recognized` is false for an unknown status (shown as « Inconnu »).
 * @param {string} status
 * @returns {{ key: string, glyph: string, word: string, tone: string, recognized: boolean, requested: string }}
 */
export function statusGlyph(status) {
  const key = ALIASES[fold(status)];
  const entry = STATUS_GLYPHS.find((g) => g.key === key);
  const unknown = STATUS_GLYPHS.find((g) => g.key === 'unknown');
  return { ...(entry ?? unknown), recognized: !!entry, requested: String(status ?? '') };
}

/** Badge of a status: symbol, word, tone (accessible name = the word). */
export function statusBadge(status, { label } = {}) {
  const g = statusGlyph(status);
  return `<span class="sh-status" data-tone="${g.tone}"><span class="sh-status-glyph" aria-hidden="true">${esc(g.glyph)}</span>${esc(label ?? g.word)}</span>`;
}
