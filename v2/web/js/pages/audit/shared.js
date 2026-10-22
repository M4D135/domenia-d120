// Audit AD: helpers shared by the four tabs (severities, explainable facts, states, guard of concurrent reads, copy for a
// ticket). Local only: nothing here calls the bridge.
import { icon } from '../../icons.js';
import { glyph } from '../../kit/glyphs.js';
import { pill } from '../../kit/status.js';
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
        <div class="aud-fact-top"><span class="aud-fact-label">${esc(f.label)}</span>${pill(FACT_TONES[f.state] ?? 'off', f.stateLabel, { size: 'sm', dot: false })}</div>
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

/** Height of a grid for n rows: no empty well under a short list, a scroll beyond about ten rows. */
export function gridHeight(n, max = 460) {
  return `${Math.min(max, Math.max(170, 96 + Math.max(1, n) * 40))}px`;
}

/** Paints vars (--i, --tone…) of fresh markup. */
export function paint(scope) {
  applyVars(scope);
  scope.querySelectorAll('[data-j]').forEach((el) => el.style.setProperty('--j', el.dataset.j));
}

/**
 * Guard of concurrent reads (AUD-003): one counter per kind, so a newer read replaces only the read of the same kind; a
 * new target (or a new session) cancels them all.
 */
export function createGuard() {
  const counters = new Map();
  let epoch = 0;
  return {
    next(kind) {
      const n = (counters.get(kind) ?? 0) + 1;
      counters.set(kind, n);
      return { kind, n, epoch };
    },
    current(token) {
      return token.epoch === epoch && counters.get(token.kind) === token.n;
    },
    reset() {
      epoch += 1;
      counters.clear();
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
