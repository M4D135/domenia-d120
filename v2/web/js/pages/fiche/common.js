// Shared helpers of the « Fiche » screen: kinds and their icons, tones, state pills, fact tables, skeletons, errors and
// small builders reused by every tab (docs/ops/fiche.md). Pure markup helpers: nothing here calls the bridge.
import { glyph, pill, NBSP, int, quote } from '../../kit/index.js';
import { esc, errorText, formatDateTime, relTime } from '../../ui.js';

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

/** Small round avatar: initials for people, an icon for the other kinds. */
export function avatar(kind, initials, cls = '') {
  const k = kindOf(kind);
  const inner = (kind === 'user' || kind === 'contact') && initials ? `<span class="fi-initials">${esc(initials)}</span>` : glyph(k.icon);
  return `<span class="fi-avatar ${esc(cls)}" data-kind="${esc(k.hue)}" aria-hidden="true">${inner}</span>`;
}

/** A link to another fiche (button: the screen handles navigation). */
export function ficheLink(link, { cls = '' } = {}) {
  if (!link || !link.dn) return '<span class="fi-none">—</span>';
  const k = kindOf(link.kind);
  return `<button type="button" class="fi-link ${esc(cls)}" data-open="${esc(link.dn)}" data-tip="${esc(link.detail ? `${link.detail} · ${link.dn}` : link.dn)}">`
    + `${glyph(k.icon)}<span>${esc(link.name)}</span></button>`;
}

/** Section title inside a tab. */
export function secTitle(title, note = '', icon = '') {
  return `<div class="fi-sec">${icon ? glyph(icon) : ''}<h2>${esc(title)}</h2>${note ? `<span class="fi-sec-note">${esc(note)}</span>` : ''}</div>`;
}

/** Card frame with a head (icon, title, subtitle, meta) and a body. */
export function card({ id = '', icon = 'info', tone = '', title, sub = '', meta = '', body = '', cls = '', foot = '' }) {
  return `<section class="card fi-card spot ${esc(cls)}"${id ? ` data-card="${esc(id)}"` : ''}>
    <div class="card-head"><span class="card-icon"${tone ? ` data-tone="${esc(tone)}"` : ''}>${glyph(icon)}</span>
      <div class="fi-card-titles"><h3>${esc(title)}</h3>${sub ? `<p class="fi-card-sub">${esc(sub)}</p>` : ''}</div>
      ${meta ? `<span class="meta">${meta}</span>` : ''}</div>
    <div class="fi-card-body">${body}</div>${foot ? `<div class="fi-card-foot">${foot}</div>` : ''}
  </section>`;
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

/** Empty state inside a card or a tab. */
export function emptyNote(icon, title, text = '', action = '') {
  return `<div class="fi-empty"><span class="fi-empty-art">${glyph(icon)}</span><strong>${esc(title)}</strong>${text ? `<p>${esc(text)}</p>` : ''}${action}</div>`;
}

/** Pill of a sheet state ({ id, tone, label, detail }). */
export function statePills(states) {
  return (states ?? []).map((s, n) => `<span class="fi-state" data-j="${n}">${pill(s.tone === 'accent' ? 'accent' : s.tone, s.label, { tip: s.detail, dot: true, pulse: s.id === 'locked' })}</span>`).join('');
}

/** « il y a 3 min » with the full date in a tip. */
export function when(iso, prefix = '') {
  if (!iso) return '<span class="fi-none">—</span>';
  const t = Date.parse(iso);
  const full = formatDateTime(iso) ?? iso;
  // Relative within a month (« il y a 3 h »), the date beyond: « il y a 51 mois » says less than « le 04/08/2022 ».
  const text = !Number.isNaN(t) && Math.abs(Date.now() - t) < 30 * 86_400_000 ? relTime(iso) : `le ${dateOnly(t)}`;
  return `<time datetime="${esc(iso)}" data-tip="${esc(full)}">${esc(prefix)}${esc(text)}</time>`;
}

function dateOnly(t) {
  const d = new Date(t);
  if (Number.isNaN(d.getTime())) return '—';
  const pad = (n) => String(n).padStart(2, '0');
  return `${pad(d.getDate())}/${pad(d.getMonth() + 1)}/${d.getFullYear()}`;
}

/**
 * Table of facts (call sheet, support summary, lockouts): label, value, state pill, then the source and date when they differ
 * from the previous line (the table stays readable), and the detail line. Sections become group headers.
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
      <span class="fi-fact-value">${esc(f.value)}${statePill ? ` ${statePill}` : ''}</span>
      ${showMeta ? `<span class="fi-fact-meta">${esc(meta)}</span>` : ''}
      ${detail ? `<span class="fi-fact-detail">${esc(detail)}</span>` : ''}
    </div>`);
  });
  return `<div class="fi-facts${selectable ? ' selectable' : ''}" role="list">${out.join('')}</div>`;
}

/** Support facts grouped by rubric (Get-DomeniaUserSupportSummary). */
export function supportGroups(facts) {
  const groups = new Map();
  for (const f of facts ?? []) {
    if (!groups.has(f.group)) groups.set(f.group, []);
    groups.get(f.group).push(f);
  }
  return [...groups].map(([name, items]) => `<div class="fi-support-group"><h4>${esc(name)}</h4><dl>${items.map((f) => `<div class="fi-support-row"${f.limit ? ` data-tip="${esc(f.limit)}"` : ''}>
    <dt>${esc(f.label)}</dt><dd>${esc(f.value)}${f.limit ? `<span class="fi-limit" aria-hidden="true">${glyph('info')}</span><span class="visually-hidden"> · ${esc(f.limit)}</span>` : ''}</dd></div>`).join('')}</dl></div>`).join('');
}

/** Copy a text through the clipboard of the page; the kit announces it. */
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

/** Path of a DN from the domain (« example.local › Postes › Paris »), without the object itself. */
export function parentPath(path) {
  return path ?? '';
}
