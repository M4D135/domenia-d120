// Shared helpers of the « Fiche » screen: kinds and their icons, tones, state pills, fact tables, dates, freshness chips,
// skeletons, errors and small builders reused by every tab (docs/ops/fiche.md). Pure markup helpers: nothing here calls the
// bridge. Dates follow one convention on the whole screen: « 22/10/2026 03:35 » (or « 04/08/2022 » for a day), the relative
// form (« il y a 3 min ») being kept for the freshness chips only.
import { glyph, pill, freshness, NBSP, int, quote } from '../../kit/index.js';
import { esc, errorText } from '../../ui.js';

/** Kinds of the contract and how the screen shows them. */
export const KINDS = {
  user: { icon: 'user', label: 'Utilisateur', hue: 'user' },
  computer: { icon: 'monitor', label: 'Ordinateur', hue: 'computer' },
  group: { icon: 'group', label: 'Groupe', hue: 'group' },
  ou: { icon: 'ou', label: 'Unité d’organisation', hue: 'ou' },
  contact: { icon: 'link', label: 'Contact', hue: 'contact' },
  container: { icon: 'folder', label: 'Conteneur', hue: 'container' },
  unknown: { icon: 'object', label: 'Objet', hue: 'container' },
};

export const kindOf = (kind) => KINDS[kind] ?? KINDS.unknown;

/** Measure states of the call sheet (Get-DomeniaMeasureStateKeys) and their tone. */
export const STATE_TONES = { known: 'ok', absent: 'off', notRead: 'off', refused: 'alert', expired: 'warn', incomplete: 'warn', error: 'alert', estimated: 'info', unknown: 'off', unavailable: 'alert' };

/** Tone of a fact state. */
export const factTone = (state) => STATE_TONES[state] ?? 'off';

const pad = (n) => String(n).padStart(2, '0');

/** « 22/10/2026 03:35 » in local time, or « — ». */
export function stamp(iso) {
  const d = new Date(iso);
  if (!iso || Number.isNaN(d.getTime())) return '—';
  return `${pad(d.getDate())}/${pad(d.getMonth() + 1)}/${d.getFullYear()} ${pad(d.getHours())}:${pad(d.getMinutes())}`;
}

/** « 22/10/2026 » in local time, or « — ». */
export function day(iso) {
  const d = new Date(iso);
  if (!iso || Number.isNaN(d.getTime())) return '—';
  return `${pad(d.getDate())}/${pad(d.getMonth() + 1)}/${d.getFullYear()}`;
}

/** A dated value: « 22/10/2026 03:35 » (time element, the same text in its tip). */
export function when(iso, { dateOnly = false } = {}) {
  if (!iso) return '<span class="fi-none">—</span>';
  const text = dateOnly ? day(iso) : stamp(iso);
  return `<time datetime="${esc(iso)}">${esc(text)}</time>`;
}

/**
 * Text with the names of machines kept on one line (« PC-LYO-0002 » never breaks at its dashes): escaped, then each token made
 * of capitals, digits and dashes wrapped in a no-break span.
 */
export function nobr(text) {
  return esc(String(text ?? '')).replace(/\b([A-Z0-9]+(?:-[A-Z0-9]+)+\$?)/g, '<span class="fi-nobr">$1</span>');
}

/** Small round avatar: initials for people, an icon for the other kinds. */
export function avatar(kind, initials, cls = '') {
  const k = kindOf(kind);
  const inner = (kind === 'user' || kind === 'contact') && initials ? `<span class="fi-initials">${esc(initials)}</span>` : glyph(k.icon);
  return `<span class="fi-avatar ${esc(cls)}" data-kind="${esc(k.hue)}" aria-hidden="true">${inner}</span>`;
}

/** Initials of a display name (« Camille Bernard » → « CB »). */
export function initialsOf(name) {
  const words = String(name ?? '').split(/[\s,.\-_]+/).filter((w) => /[\p{L}\p{N}]/u.test(w));
  if (words.length >= 2) return (words[0][0] + words[1][0]).toUpperCase();
  return words[0] ? words[0].slice(0, 2) : '?';
}

/** A link to another fiche (button: the screen handles navigation and the unsaved input guard). */
export function ficheLink(link, { cls = '' } = {}) {
  if (!link || !link.dn) return '<span class="fi-none">—</span>';
  const k = kindOf(link.kind);
  return `<button type="button" class="fi-link ${esc(cls)}" data-open="${esc(link.dn)}" data-tip="${esc(link.detail ? `${link.detail} · ${link.dn}` : link.dn)}">`
    + `${glyph(k.icon)}<span>${esc(link.name)}</span></button>`;
}

/**
 * Card frame with a head (icon, title, subtitle, meta) and a body. `fresh` adds the freshness chip of the data of the card
 * (FIC-036: one uniform chip per block).
 */
export function card({ id = '', icon = 'info', tone = '', title, sub = '', meta = '', body = '', cls = '', foot = '', fresh = '' }) {
  return `<section class="card fi-card spot ${esc(cls)}"${id ? ` data-card="${esc(id)}"` : ''}>
    <div class="card-head"><span class="card-icon"${tone ? ` data-tone="${esc(tone)}"` : ''}>${glyph(icon)}</span>
      <div class="fi-card-titles"><h3>${esc(title)}</h3>${sub ? `<p class="fi-card-sub">${esc(sub)}</p>` : ''}</div>
      ${meta || fresh ? `<span class="meta">${fresh}${meta}</span>` : ''}</div>
    <div class="fi-card-body">${body}</div>${foot ? `<div class="fi-card-foot">${foot}</div>` : ''}
  </section>`;
}

const FRESH_LABELS = { identity: 'Identité', attributes: 'Lu', presence: 'Présence', console: 'Console', history: 'Historique' };

/**
 * Freshness chip of one nature of the sheet (kit freshness: « Lu il y a 3 min », amber at half of the validity, « Périmé »
 * beyond), with the validity of the usage profile and the last attempt in its tip. Nothing when the nature is not on the sheet.
 */
export function freshChip(sheet, nature) {
  const f = (sheet?.freshness ?? []).find((x) => x.nature === nature);
  if (!f) return '';
  const tip = [f.text, f.validity ? `Validité${NBSP}: ${f.validity}` : '', f.lastAttempt ? `Dernière tentative${NBSP}: ${stamp(f.lastAttempt)}` : ''].filter(Boolean).join(' · ');
  const staleAfter = f.validitySeconds > 0 ? f.validitySeconds * 1000 : 365 * 86_400_000;
  return `<span class="fi-fresh-chip" data-nature="${esc(nature)}" data-tip="${esc(tip)}">${freshness(f.observedAt, { label: FRESH_LABELS[nature] ?? 'Lu', staleAfter, source: f.validity })}</span>`;
}

/** Skeleton lines for a card or a tab while it reads. */
export function skeleton(lines = 4, cls = '') {
  const widths = ['w85', 'w70', 'w55', 'w40', 'w70', 'w85'];
  return `<div class="fi-sk ${esc(cls)}" aria-busy="true" aria-label="Lecture en cours">${Array.from({ length: lines }, (_, n) => `<span class="skeleton fi-sk-line ${widths[n % widths.length]}"></span>`).join('')}</div>`;
}

/** Error block with an optional retry button (data-retry). */
export function failure(err, { title = 'Lecture impossible', retry = true, sent = false } = {}) {
  const code = err?.code ? `<span class="fi-code">${esc(err.code)}</span>` : '';
  return `<div class="fi-fail" role="alert"><span class="fi-fail-ico">${glyph('alert')}</span>
    <div class="fi-fail-body"><strong>${esc(title)}</strong><p>${esc(errorText(err))}</p>${code}${sent ? '' : `<p class="fi-fail-note">${glyph('shield')}Rien n’a été modifié.</p>`}</div>
    ${retry ? `<button class="btn sm" type="button" data-retry>${glyph('refresh')}Réessayer</button>` : ''}</div>`;
}

/** Empty state inside a card or a tab (compact: icon at the left of the text). */
export function emptyNote(icon, title, text = '', action = '') {
  return `<div class="fi-empty"><span class="fi-empty-art">${glyph(icon)}</span><div class="fi-empty-text"><strong>${esc(title)}</strong>${text ? `<p>${esc(text)}</p>` : ''}</div>${action}</div>`;
}

/** Pill of a sheet state ({ id, tone, label, detail }). */
export function statePills(states) {
  return (states ?? []).map((s, n) => `<span class="fi-state" data-j="${n}">${pill(s.tone === 'accent' ? 'accent' : s.tone, s.label, { tip: s.detail, dot: true, pulse: s.id === 'locked' })}</span>`).join('');
}

/**
 * Table of facts (call sheet, lockouts): label, value, state pill, then the source and date when they differ from the previous
 * line (the table stays readable), and the detail line. Sections become group headers.
 */
export function factRows(facts, { section = false, selectable = false } = {}) {
  if (!facts?.length) return emptyNote('info', 'Aucun fait relevé');
  let lastSection = '';
  let lastMeta = '';
  const out = [];
  facts.forEach((f, n) => {
    if (section && f.section && f.section !== lastSection) {
      lastSection = f.section;
      lastMeta = '';
      out.push(`<div class="fi-fact-group" role="presentation">${esc(f.section)}</div>`);
    }
    const state = f.state ?? 'known';
    const tone = factTone(state);
    const statePill = state === 'known' ? '' : pill(tone, f.stateLabel ?? state, { size: 'sm' });
    const meta = [f.source, f.dateText].filter(Boolean).join(' · ');
    const showMeta = meta && meta !== lastMeta;
    lastMeta = meta;
    const detail = [f.detail, f.limit, f.hypothesis].filter(Boolean).join(' ');
    out.push(`<div class="fi-fact${f.attention ? ' attention' : ''}" role="listitem" data-j="${n}" data-state="${esc(state)}"${selectable ? ' tabindex="0"' : ''}${meta && !showMeta ? ` data-tip="${esc(meta)}"` : ''}>
      <span class="fi-fact-label">${f.attention ? `<span class="fi-attn" aria-hidden="true">${glyph('alert')}</span>` : ''}${esc(f.label)}</span>
      <span class="fi-fact-value">${nobr(f.value)}${statePill ? ` ${statePill}` : ''}</span>
      ${showMeta ? `<span class="fi-fact-meta">${esc(meta)}</span>` : ''}
      ${detail ? `<span class="fi-fact-detail">${esc(detail)}</span>` : ''}
    </div>`);
  });
  return `<div class="fi-facts${selectable ? ' selectable' : ''}" role="list">${out.join('')}</div>`;
}

/**
 * Support facts grouped by rubric (Get-DomeniaUserSupportSummary, FIC-044): each fact with its source, its reader (the
 * controller that answered) and the date of the read, and its limit when it has one.
 */
export function supportGroups(facts) {
  const groups = new Map();
  for (const f of facts ?? []) {
    if (!groups.has(f.group)) groups.set(f.group, []);
    groups.get(f.group).push(f);
  }
  return [...groups].map(([name, items], g) => `<section class="fi-support-group" data-j="${g}"><h4>${esc(name)}</h4><dl>${items.map((f) => `<div class="fi-support-row">
    <dt>${esc(f.label)}</dt><dd><span class="fi-support-value">${nobr(f.value)}</span>
      <span class="fi-support-meta">${esc([f.source, f.reader, f.dateText].filter(Boolean).join(' · '))}</span>
      ${f.limit ? `<span class="fi-support-limit">${glyph('info')}${esc(f.limit)}</span>` : ''}</dd></div>`).join('')}</dl></section>`).join('');
}

/** Plain text of the support summary, for « Copier » (no secret: the facts are display values of the directory). */
export function supportText(facts, name) {
  const lines = [`Résumé support${NBSP}: ${name}`];
  let group = '';
  for (const f of facts ?? []) {
    if (f.group !== group) { group = f.group; lines.push('', group); }
    lines.push(`- ${f.label}${NBSP}: ${f.value} (${[f.source, f.reader, f.dateText].filter(Boolean).join(', ')})${f.limit ? ` · ${f.limit}` : ''}`);
  }
  return lines.join('\r\n');
}

export { quote, NBSP, int };

/** Plain text of a CSV-like table for « Copier tout ». */
export function tabular(rows, columns) {
  const head = columns.map((c) => c.label).join('\t');
  return [head, ...rows.map((r) => columns.map((c) => String(c.get(r) ?? '').replace(/[\t\r\n]+/g, ' ')).join('\t'))].join('\r\n');
}

/** Short French count: « 3 groupes ». */
export function plural(n, one, many) {
  return `${int(n)}${NBSP}${Math.abs(n) >= 2 ? many : one}`;
}

/**
 * Height of the scrolling area of a grid for n rows (kit --k-grid-h: the column head and the rows, the toolbar apart), between min
 * and max: no empty band under the last row, a scroll only beyond max.
 */
export function gridHeight(rows, { min = 168, max = 560, row = 40 } = {}) {
  const n = Number.isFinite(rows) ? Math.max(rows, 3) : 8;
  return `${Math.max(min, Math.min(max, 62 + row * n))}px`;
}

/** Presence in a few words (« En ligne », « Sans réponse au ping »), « (à relire) » when the measure is older than its validity. */
export function presenceWords(p) {
  if (!p) return 'Présence non relevée';
  const core = String(p.label ?? '').replace(/\s*\([^)]*\)\s*$/, '') || 'Présence non relevée';
  return p.state === 'stale' ? `${core} (à relire)` : core;
}
