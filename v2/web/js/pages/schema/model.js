// Shared pieces of the schema screen: text helpers, tones and icons of the schema vocabulary, small markup blocks.
// Everything here is local: no bridge call, no network.
import { glyph } from '../../kit/glyphs.js';
import { esc, int, count, quote, NBSP } from '../../kit/util.js';

export { glyph, esc, int, count, quote, NBSP };

/** Operator text of a bridge error (French message of the engine), or a French fallback. */
export function errText(err, fallback = 'Erreur interne de l’interface.') {
  return err && err.code && err.message ? String(err.message) : fallback;
}

/** Shimmer line of a skeleton. */
export const sk = (cls = '') => `<span class="skeleton sch-sk ${cls}"></span>`;

/** Icon of a syntax family (SchemaSyntaxKind, camelCase). */
export const KIND_ICONS = {
  dn: 'link', text: 'file', bool: 'check', int: 'hash', largeInt: 'hash', time: 'calendar', binary: 'chip', sid: 'key', other: 'info',
};

/** Colour series of a syntax family in the overview ring (categorical palette of the tokens; « other » in neutral grey). */
export const KIND_SERIES = { text: 's1', dn: 's2', int: 's3', largeInt: 's4', time: 's5', bool: 's6', binary: 's7', sid: 's8', other: 'sx' };

/** Tone of an index text (SchemaRules.IndexText). */
export function indexTone(text) {
  if (!text) return 'off';
  if (text.startsWith('Indexé')) return 'ok';
  if (text.startsWith('Calculé')) return 'warn';
  return 'off';
}

/** Tones of the class categories: one table for the grid pills and the chips of the detail, so both always agree. */
export const CATEGORY_TONES = {
  Structurelle: 'accent', Auxiliaire: 'info', Abstraite: 'off', 'Classe 88': 'off', Obsolète: 'alert', Inconnue: 'off',
};

/** Tone of a class category label. */
export function categoryTone(label) {
  return CATEGORY_TONES[label] ?? 'off';
}

/** Stages of a schema read, in the order of the engine (schema.read:stage). */
export const STAGES = [
  { id: 'context', label: 'Contexte du schéma', short: 'Contexte', text: 'CN=Schema,CN=Configuration du contrôleur de la session' },
  { id: 'attributes', label: 'Définitions des attributs', short: 'Attributs', text: 'attributeSchema · 8 000 au plus' },
  { id: 'classes', label: 'Définitions des classes', short: 'Classes', text: 'classSchema · 3 000 au plus' },
];

/** Small pill (kit look, local class so that the page keeps its own rhythm). */
export function chip(tone, label, { icon, tip, cls = '' } = {}) {
  return `<span class="sch-chip ${esc(tone)} ${cls}"${tip ? ` data-tip="${esc(tip)}"` : ''}>${icon ? glyph(icon) : ''}<span>${esc(label)}</span></span>`;
}

/** Code block with a copy button (the value is copied from data-copy, never from the page text). */
export function codeLine(text, { label = 'Copier', cls = '' } = {}) {
  return `<div class="sch-code ${cls}"><code>${esc(text)}</code>`
    + `<button class="btn ghost icon xs sch-copy" type="button" data-copy="${esc(text)}" aria-label="${esc(label)}" data-tip="${esc(label)}">${glyph('copy')}</button></div>`;
}

/**
 * Colours an LDAP filter for display (local tokenizer; the engine is the judge of validity). Returns trusted markup: every
 * piece of the text goes through esc().
 */
export function highlightFilter(text) {
  const out = [];
  let i = 0;
  const n = text.length;
  const push = (cls, s) => out.push(cls ? `<span class="t-${cls}">${esc(s)}</span>` : esc(s));
  while (i < n) {
    const c = text[i];
    if (c === '(' || c === ')') { push('paren', c); i += 1; continue; }
    if ((c === '&' || c === '|' || c === '!') && i > 0 && text[i - 1] === '(') { push('op', c); i += 1; continue; }
    if (text[i - 1] === '(' || i === 0) {
      // Assertion: attribute, optional :rule, comparator, value up to the next closing parenthesis.
      const end = text.indexOf(')', i);
      const item = end < 0 ? text.slice(i) : text.slice(i, end);
      const m = /^([^=~<>:()]*)((?::[^=()]*)?)(~=|>=|<=|:=|=)?(.*)$/s.exec(item);
      if (m && m[3]) {
        if (m[1]) push('attr', m[1]);
        if (m[2]) push('rule', m[2]);
        push('cmp', m[3]);
        const value = m[4];
        let j = 0;
        while (j < value.length) {
          if (value[j] === '*') { push('wild', '*'); j += 1; continue; }
          if (value[j] === '\\') { push('esc', value.slice(j, j + 3)); j += 3; continue; }
          let k = j;
          while (k < value.length && value[k] !== '*' && value[k] !== '\\') k += 1;
          push('val', value.slice(j, k));
          j = k;
        }
        i += item.length;
        continue;
      }
    }
    push('', c);
    i += 1;
  }
  return out.join('');
}

/** « il y a 3 min » style date in a French short form for the hero (date and time). */
export function shortDateTime(iso) {
  const t = Date.parse(iso ?? '');
  if (Number.isNaN(t)) return '—';
  return new Intl.DateTimeFormat('fr-FR', { day: '2-digit', month: '2-digit', year: 'numeric', hour: '2-digit', minute: '2-digit' }).format(t);
}
