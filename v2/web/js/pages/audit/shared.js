// Audit AD: helpers shared by the four tabs (severities, explainable facts, states, guard of concurrent reads, copy for a
// ticket). Local only: nothing here calls the bridge.
import { icon } from '../../icons.js';
import { glyph } from '../../kit/glyphs.js';
import { esc, formatNumber, formatDateTime, relTime, errorText, applyVars } from '../../ui.js';

export const NB = ' ';

/** Severities of the findings, from the worst (docs/ops/audit.md § 3). */
export const SEVERITIES = [
  { id: 'critical', label: 'Critique', plural: 'Critiques', tone: 'alert', icon: 'zap', hint: 'Exploitable tout de suite : à traiter en priorité.' },
  { id: 'high', label: 'Élevée', plural: 'Élevées', tone: 'alert', icon: 'alert', hint: 'Risque important, souvent une étape d’attaque connue.' },
  { id: 'medium', label: 'Moyenne', plural: 'Moyennes', tone: 'warn', icon: 'eye', hint: 'Écart aux bonnes pratiques, à planifier.' },
  { id: 'low', label: 'Faible', plural: 'Faibles', tone: 'info', icon: 'info', hint: 'Hygiène de l’annuaire, à revoir à l’occasion.' },
  { id: 'info', label: 'Information', plural: 'Informations', tone: 'off', icon: 'file', hint: 'À connaître, sans écart en soi.' },
];
export const severityOf = (id) => SEVERITIES.find((s) => s.id === id) ?? SEVERITIES[4];

/** Tone shown for a finding: its severity when read, « ok » without gap, « off » when not read (never counted). */
export function findingTone(f) {
  if (f.passed) return 'ok';
  if (f.state !== 'read' && f.state !== 'empty') return 'off';
  return severityOf(f.severity).tone;
}

const PILL_TONES = ['ok', 'warn', 'alert', 'info', 'off', 'accent'];

/**
 * Pill of the kit (same classes) with the tone « crit » of the screen and, with fit, a label cut with an ellipsis in a narrow
 * cell, the full text as a tip (the kit pill never shrinks).
 * @param {string} tone @param {string} label
 * @param {{ size?: 'sm'|'md', icon?: string, tip?: string, fit?: boolean, dot?: boolean }} [o]
 */
export function tonePill(tone, label, o = {}) {
  const crit = tone === 'crit';
  const t = crit ? 'alert' : PILL_TONES.includes(tone) ? tone : 'off';
  const mark = o.icon ? glyph(o.icon, 'k-pill-ico') : o.dot === false ? '' : '<span class="k-pill-dot" aria-hidden="true"></span>';
  const tip = o.tip ?? (o.fit ? label : '');
  const text = o.fit ? `<span class="aud-pill-text">${esc(label)}</span>` : esc(label);
  return `<span class="k-pill ${t}${(o.size ?? 'sm') === 'sm' ? ' sm' : ''}${crit ? ' aud-crit' : ''}${o.fit ? ' aud-fit' : ''}"${tip ? ` data-tip="${esc(tip)}"` : ''}>${mark}${text}</span>`;
}

/** State of a fact (Domenia 1 New-DomeniaFact): Constaté, Estimé, Refusé, Indisponible, Inconnu. */
const FACT_TONES = { observed: 'ok', estimated: 'warn', refused: 'alert', unavailable: 'off', unknown: 'off' };
const FACT_ICONS = { observed: 'check', estimated: 'gauge', refused: 'lock', unavailable: 'wifiOff', unknown: 'info' };

export const KIND_ICONS = { user: 'user', computer: 'monitor', group: 'group', organizationalUnit: 'ou', domain: 'domain', other: 'object' };

export const num = (n) => (Number.isFinite(n) ? formatNumber(n) : '—');
export const plural = (n, one, many) => `${num(n)} ${Math.abs(n) >= 2 ? many : one}`;

/** Text flattened on one line and cut to max characters (Domenia 1 ConvertTo-DomeniaFlatText). */
export function flat(text, max = 400) {
  const value = String(text ?? '').replace(/\s+/g, ' ').trim();
  return value.length <= max ? value : `${value.slice(0, Math.max(0, max - 1))}…`;
}

/** Operator text of an error; browser errors (no code) are logged, never shown in English. */
export function reported(err) {
  if (!err?.code) console.error(err);
  return errorText(err);
}

/** « il y a 3 min » with the full date as a tip; « — » when unknown. */
export function when(iso) {
  const rel = relTime(iso);
  if (!rel) return '<span class="aud-none">—</span>';
  return `<time datetime="${esc(iso)}" data-tip="${esc(formatDateTime(iso) ?? '')}">${esc(rel)}</time>`;
}

/** Explainable facts as a list: label, value, state pill, source and limit (AUD-002). */
export function factsMarkup(facts, { compact = false } = {}) {
  if (!facts?.length) return '';
  return `<ul class="aud-facts${compact ? ' compact' : ''}" role="list">${facts.map((f, n) => `
    <li class="aud-fact" data-tone="${FACT_TONES[f.state] ?? 'off'}" data-i="${n}">
      <span class="aud-fact-mark" aria-hidden="true">${glyph(FACT_ICONS[f.state] ?? 'info')}</span>
      <div class="aud-fact-body">
        <div class="aud-fact-top"><span class="aud-fact-label">${esc(f.label)}</span>${tonePill(FACT_TONES[f.state] ?? 'off', f.stateLabel, { dot: false })}</div>
        <div class="aud-fact-value">${esc(f.value)}</div>
        ${f.source || f.limit ? `<div class="aud-fact-meta">${f.source ? `<span>${glyph('database')}${esc(f.source)}</span>` : ''}${f.limit ? `<span class="limit">${glyph('info')}${esc(f.limit)}</span>` : ''}</div>` : ''}
      </div>
    </li>`).join('')}</ul>`;
}

/** Status line under a read button: what was read, when and on which controller. aria-live polite. */
export function statusMarkup(text, tone = 'info', { busy = false } = {}) {
  const lines = String(text ?? '').split('\n').filter(Boolean);
  if (!lines.length) return '';
  return `<div class="aud-status" data-tone="${esc(tone)}">${busy ? '<span class="k-spin" aria-hidden="true"></span>' : `<span class="aud-status-ico" aria-hidden="true">${icon(tone === 'alert' ? 'alert' : tone === 'warn' ? 'alert' : tone === 'ok' ? 'check' : 'info')}</span>`}
    <div class="aud-status-text">${lines.map((l) => `<p>${esc(l)}</p>`).join('')}</div></div>`;
}

/** Empty state with its art, a sentence and an optional action. */
export function emptyMarkup({ icon: name = 'shield', title, text, action = '', tone = 'accent' }) {
  return `<div class="aud-empty" data-tone="${esc(tone)}">
    <span class="aud-empty-art" aria-hidden="true"><span class="ring"></span>${icon(name)}</span>
    <h3>${esc(title)}</h3>${text ? `<p>${esc(text)}</p>` : ''}${action}</div>`;
}

/** Skeleton block of n lines; aria-busy so the capture waits for the end of the read (CAPTURE.md § 5). */
export function skeletonMarkup(lines = 4, cls = '') {
  return `<div class="aud-skel ${esc(cls)}" aria-busy="true" aria-label="Lecture en cours">${Array.from({ length: lines }, (_, n) => `<span class="skeleton" data-i="${n}"></span>`).join('')}</div>`;
}

/** Chips of a summary: [{ label, value, tone, icon }]. */
export function statChips(items) {
  return `<ul class="aud-stats" role="list">${items.filter(Boolean).map((s, n) => `<li class="aud-stat" data-tone="${esc(s.tone ?? 'off')}" data-j="${n}">${s.icon ? glyph(s.icon) : ''}<b>${esc(s.value)}</b><span>${esc(s.label)}</span></li>`).join('')}</ul>`;
}

const ROW_HEIGHTS = { compact: 32, normal: 40, comfortable: 48 };

/**
 * Height of the scrolling area of a grid for n rows shown (header, rows, room for a horizontal scroll bar): no empty well
 * under a short list, a scroll beyond max. With no row shown (a filter hides them all), room for the empty state of the kit.
 */
export function gridHeight(n, max = 460, density = 'normal') {
  if (n <= 0) return '240px';
  const row = ROW_HEIGHTS[density] ?? 40;
  return `${Math.min(max, 42 + n * row + 14)}px`;
}

/**
 * Keeps a grid of the kit sized to the rows it shows: give onFilterChange to createGrid, then bind(grid, rows.length).
 * The height is a CSS variable set through the CSSOM (CSP: no style attribute in the markup).
 * @param {number} [max]
 */
export function fitGrid(max = 460) {
  let grid = null;
  const apply = (n) => {
    const el = grid?.el;
    if (el) el.style.setProperty('--k-grid-h', gridHeight(n, max, el.dataset.density));
  };
  return {
    onFilterChange: (info) => apply(info.shown),
    bind(g, n) { grid = g; apply(n); return g; },
  };
}

/** Paints vars (--i, --tone…) of fresh markup. */
export function paint(scope) {
  applyVars(scope);
  scope.querySelectorAll('[data-j]').forEach((el) => el.style.setProperty('--j', el.dataset.j));
}

/**
 * Guard of concurrent reads (AUD-003, Domenia 1 New-DomeniaAdAuditRequestState): one counter per kind, so a newer read
 * replaces only the read of the same kind (a services read started during a probe never discards the probe). A kind may
 * belong to a scope (« object:acl »): reset('object') cancels the reads of that scope only (a new target clears the results
 * of the object, never the analysis, the diagnosis or the identities); reset() with no scope cancels them all (new session,
 * screen left).
 */
export function createGuard() {
  const counters = new Map();
  const epochs = new Map();
  let epoch = 0;
  const scopeOf = (kind) => (kind.includes(':') ? kind.slice(0, kind.indexOf(':')) : '');
  return {
    next(kind) {
      const n = (counters.get(kind) ?? 0) + 1;
      counters.set(kind, n);
      return { kind, n, epoch, scoped: epochs.get(scopeOf(kind)) ?? 0 };
    },
    current(token) {
      return Boolean(token) && token.epoch === epoch && (epochs.get(scopeOf(token.kind)) ?? 0) === token.scoped && counters.get(token.kind) === token.n;
    },
    reset(scope) {
      if (scope) {
        epochs.set(scope, (epochs.get(scope) ?? 0) + 1);
        for (const kind of [...counters.keys()]) if (scopeOf(kind) === scope) counters.delete(kind);
        return;
      }
      epoch += 1;
      counters.clear();
      epochs.clear();
    },
  };
}

// ---------- Copy for a ticket (AUD-001) ----------

const MAX_ROWS = 2000;
const MAX_CELL = 400;

/**
 * Plain text of what a view shows: each section with its summary, then its rows, values separated by a tabulation;
 * 2 000 rows per section at most (rows not copied counted), cells flattened to 400 characters. Nothing is read again.
 * @param {string} title @param {Array<{ title?: string, summary?: string, columns?: Array<{label: string, get: (r: any) => any}>, rows?: any[] }>} sections
 */
export function ticketText(title, sections) {
  const lines = [title, ''];
  for (const s of sections) {
    if (!s) continue;
    if (s.title) lines.push(`== ${s.title} ==`);
    if (s.summary) lines.push(...String(s.summary).split('\n'));
    if (s.columns?.length && s.rows?.length) {
      lines.push(s.columns.map((c) => c.label).join('\t'));
      s.rows.slice(0, MAX_ROWS).forEach((r) => lines.push(s.columns.map((c) => flat(c.get(r), MAX_CELL)).join('\t')));
      if (s.rows.length > MAX_ROWS) lines.push(`${plural(s.rows.length - MAX_ROWS, 'ligne non copiée', 'lignes non copiées')}.`);
    }
    lines.push('');
  }
  return lines.join('\r\n').trimEnd();
}

/** Same sections as Markdown tables (improvement of AUD-001: report for a ticket or a wiki). */
export function markdownText(title, sections) {
  const cell = (v) => flat(v, MAX_CELL).replace(/\|/g, '\\|');
  const out = [`# ${title}`, ''];
  for (const s of sections) {
    if (!s) continue;
    if (s.title) out.push(`## ${s.title}`, '');
    if (s.summary) out.push(...String(s.summary).split('\n').map((l) => `> ${l}`), '');
    if (s.columns?.length && s.rows?.length) {
      out.push(`| ${s.columns.map((c) => cell(c.label)).join(' | ')} |`, `|${s.columns.map(() => ' --- ').join('|')}|`);
      s.rows.slice(0, MAX_ROWS).forEach((r) => out.push(`| ${s.columns.map((c) => cell(c.get(r))).join(' | ')} |`));
      if (s.rows.length > MAX_ROWS) out.push('', `_${plural(s.rows.length - MAX_ROWS, 'ligne non copiée', 'lignes non copiées')}._`);
      out.push('');
    }
  }
  out.push(`_Copié depuis Domenia le ${formatDateTime(new Date().toISOString())} : données déjà affichées, aucune relecture._`);
  return out.join('\n');
}

/** CSV (semicolon, French headers, cells starting with = + - @ neutralized), like the kit grid. */
export function csvText(columns, rows) {
  const q = (v) => {
    let s = flat(v, 4000);
    if (/^[=+\-@]/.test(s)) s = `'${s}`;
    return /[;"\r\n]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
  };
  return [columns.map((c) => q(c.label)).join(';'), ...rows.map((r) => columns.map((c) => q(c.get(r))).join(';'))].join('\r\n');
}
