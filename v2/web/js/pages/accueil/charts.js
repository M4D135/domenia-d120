// Accueil: drawings of the fleet board widgets (Kpi, Text, Pie, Bar, Column, Line, List, HealthSummary, Health). Every
// figure that has an exact set of workstations is a button (data-targets) that opens « Postes concernés ». SVG and HTML
// strings only; call paint() on the card once inserted (CSS variables through the CSSOM, CSP without style="…").
import { glyph } from '../../kit/glyphs.js';
import { esc, formatNumber, donut } from '../../ui.js';
import { NBSP, isNum, numAttr, plural, tone, localDay } from './shared.js';

const MAX_PARTS = 8;

/** Button attributes that open the exact set of a figure. */
export const targetsAttr = (key, label, count) => (key && (count ?? 1) > 0
  ? ` data-targets="${esc(key)}" data-targets-label="${esc(label)}"` : '');

/** Visual actually drawn: the stored one when the data allows it, else the first allowed (FleetCatalog.ResolveVisual). */
export function visualFor(entry, item) {
  const allowed = {
    value: ['Kpi', 'Text'],
    distribution: ['Pie', 'Bar', 'Column', 'Text', 'Kpi'],
    series: ['Column', 'Bar', 'Text', 'Kpi'],
    timeline: ['Line', 'Column', 'Text'],
    list: ['List'],
    health: ['HealthSummary', 'Health', 'Kpi'],
  }[entry?.kind] ?? ['Kpi', 'Text'];
  return allowed.includes(item?.visual) ? item.visual : allowed[0];
}

// ---------- Value ----------

// Share of a count in its population, drawn under the value: accounts for the AD state figures, active workstations else.
const ACCOUNT_KEYS = new Set(['fleet.enabled', 'fleet.disabled', 'fleet.accountunknown']);
const NO_SHARE = new Set(['fleet.machines', 'fleet.users', 'fleet.lastcheck']);

function share(entry, board) {
  const p = board?.population;
  if (!p || !isNum(entry.number) || entry.unit || NO_SHARE.has(entry.key) || String(entry.key).startsWith('probe:')) return '';
  const accounts = ACCOUNT_KEYS.has(entry.key);
  const base = accounts ? p.machines : p.enabled;
  if (!base || entry.number > base) return '';
  const ratio = entry.number / base;
  const text = `${formatNumber(ratio * 100, ratio * 100 < 10 ? 1 : 0)}${NBSP}% des ${formatNumber(base)}${NBSP}${accounts ? 'comptes' : 'postes actifs'}`;
  return `<div class="fw-share"><span class="fw-share-bar" aria-hidden="true"><span data-p="${ratio.toFixed(4)}"></span></span><span class="fw-share-t">${esc(text)}</span></div>`;
}

function kpi(entry, { big = true, board = null } = {}) {
  const hasNumber = isNum(entry.number);
  const unit = entry.unit ? `<small>${esc(String(entry.unit).trim())}</small>` : '';
  const value = hasNumber
    ? `<span class="visually-hidden">${esc(entry.value)}</span><span data-count="${numAttr(entry.number)}" aria-hidden="true">0</span>${unit}`
    : `<span class="fw-word">${esc(entry.value)}</span>`;
  const label = `${entry.title} : ${entry.value}`;
  const open = entry.targetsKey && (entry.targets ?? 0) > 0;
  const inner = `<span class="fw-value num${big ? '' : ' sm'}">${value}</span>`;
  const glow = `<span class="fw-kpi-glow" aria-hidden="true"></span>`;
  const main = open
    ? `<button class="fw-kpi" type="button"${targetsAttr(entry.targetsKey, entry.title, entry.targets)} data-tip="Voir les postes concernés">${glow}${inner}<span class="fw-open">${glyph('chevronRight')}<span class="visually-hidden">${esc(label)} : voir les postes</span></span></button>`
    : `<div class="fw-kpi">${glow}${inner}</div>`;
  return big ? `<div class="fw-kpi-wrap">${main}${share(entry, board)}</div>` : main;
}

// ---------- Parts: ring, bars, columns, list ----------

/** Parts kept for a drawing: the eight largest, the rest folded into « Autres » (exact sets kept apart). */
function topParts(items) {
  const list = (Array.isArray(items) ? items : []).filter((p) => isNum(p.value));
  if (list.length <= MAX_PARTS) return list;
  const sorted = [...list].sort((a, b) => b.value - a.value);
  const kept = sorted.slice(0, MAX_PARTS - 1);
  const rest = sorted.slice(MAX_PARTS - 1);
  kept.push({ label: `Autres (${formatNumber(rest.length)})`, value: rest.reduce((s, p) => s + p.value, 0), tone: 'off', targetsKey: null, targets: 0, folded: true });
  return kept;
}

function partRow(p, n, total, entry) {
  const share = total > 0 ? p.value / total : 0;
  const pctText = total > 0 ? `${formatNumber(share * 100, share * 100 < 10 ? 1 : 0)}${NBSP}%` : '';
  const sw = p.tone ? '' : `s${(n % 8) + 1}`;
  const toneAttr = p.tone ? ` data-tone="${esc(tone(p.tone) || 'off')}"` : '';
  const attrs = targetsAttr(p.targetsKey, `${entry.title} · ${p.label}`, p.targets);
  const tag = attrs ? 'button' : 'div';
  return `<li data-j="${Math.min(n, 12)}"><${tag} class="fw-part${attrs ? ' open' : ''}"${tag === 'button' ? ' type="button"' : ''}${attrs} data-key="${esc(p.label)}">`
    + `<span class="sw ${sw}"${toneAttr}></span><span class="name">${esc(p.label)}</span><span class="val num">${formatNumber(p.value)}</span>`
    + `<span class="pct num">${pctText}</span><span class="meter ${sw}" aria-hidden="true"><span data-p="${share.toFixed(4)}"${toneAttr}></span></span></${tag}></li>`;
}

function pie(entry) {
  const parts = topParts(entry.items);
  if (!parts.length) return empty(entry);
  const total = parts.reduce((s, p) => s + p.value, 0);
  const ring = donut(parts.map((p, n) => ({ value: p.value, key: p.label, cls: p.tone ? 'toned' : `s${(n % 8) + 1}`, tone: p.tone ? (tone(p.tone) || 'off') : undefined })), {
    total,
    label: `${entry.title} : ${parts.map((p) => `${p.label} ${formatNumber(p.value)}`).join(', ')}`,
    center: `<div><b data-count="${numAttr(total)}">0</b><span>${esc(entry.centerText ? String(entry.centerText).replace(/^[\d\s  ]+/, '') || 'postes' : 'postes')}</span></div>`,
  });
  return `<div class="fw-ring">${ring}<ul class="fw-parts cascade">${parts.map((p, n) => partRow(p, n, total, entry)).join('')}</ul></div>`;
}

function hbars(entry) {
  const parts = topParts(entry.items);
  if (!parts.length) return empty(entry);
  const top = Math.max(1, ...parts.map((p) => p.value));
  const rows = parts.map((p, n) => {
    const attrs = targetsAttr(p.targetsKey, `${entry.title} · ${p.label}`, p.targets);
    const tag = attrs ? 'button' : 'div';
    const toneAttr = p.tone ? ` data-tone="${esc(tone(p.tone) || 'off')}"` : '';
    return `<li data-j="${Math.min(n, 12)}"><${tag} class="fw-hbar${attrs ? ' open' : ''}"${tag === 'button' ? ' type="button"' : ''}${attrs}>`
      + `<span class="name">${esc(p.label)}</span><span class="track" aria-hidden="true"><span class="fill${p.tone ? ' toned' : ` s${(n % 8) + 1}`}"${toneAttr} data-p="${(p.value / top).toFixed(4)}"></span></span>`
      + `<span class="val num">${formatNumber(p.value)}</span></${tag}></li>`;
  }).join('');
  return `<ul class="fw-hbars cascade" aria-label="${esc(entry.title)}">${rows}</ul>`;
}

function columns(entry) {
  const parts = (Array.isArray(entry.items) ? entry.items : []).filter((p) => isNum(p.value)).slice(0, 12);
  if (!parts.length) return empty(entry);
  const top = Math.max(1, ...parts.map((p) => p.value)) * 1.14;
  const cols = parts.map((p, n) => {
    const attrs = targetsAttr(p.targetsKey, `${entry.title} · ${p.label}`, p.targets);
    const tag = attrs ? 'button' : 'div';
    const toneAttr = p.tone ? ` data-tone="${esc(tone(p.tone) || 'off')}"` : '';
    return `<${tag} class="fw-col${attrs ? ' open' : ''}"${tag === 'button' ? ' type="button"' : ''}${attrs} data-i="${n}" data-tip="${esc(`${p.label} : ${plural(p.value, 'poste', 'postes')}`)}">`
      + `<span class="bar${p.tone ? ' toned' : ''}"${toneAttr} data-h="${((p.value / top) * 100).toFixed(1)}"></span><span class="v num" data-h="${((p.value / top) * 100).toFixed(1)}">${formatNumber(p.value)}</span>`
      + `<span class="visually-hidden">${esc(`${p.label} : ${formatNumber(p.value)}`)}</span></${tag}>`;
  }).join('');
  const axis = parts.map((p) => `<span data-tip="${esc(p.label)}">${esc(p.label)}</span>`).join('');
  return `<div class="fw-cols" role="group" aria-label="${esc(entry.title)}"><div class="plot"><div class="gl" aria-hidden="true"><span></span><span></span><span></span></div><div class="cols n${Math.min(parts.length, 12)}">${cols}</div></div>`
    + `<div class="x n${Math.min(parts.length, 12)}" aria-hidden="true">${axis}</div></div>`;
}

function textList(entry) {
  const parts = (Array.isArray(entry.items) ? entry.items : []).filter((p) => isNum(p.value));
  if (entry.kind === 'value' || !parts.length) {
    return `<div class="fw-text"><b class="num">${esc(entry.value)}</b>${entry.unit ? `<small>${esc(entry.unit)}</small>` : ''}</div>`;
  }
  const rows = parts.slice(0, 14).map((p, n) => {
    const attrs = targetsAttr(p.targetsKey, `${entry.title} · ${p.label}`, p.targets);
    const tag = attrs ? 'button' : 'div';
    return `<li data-j="${Math.min(n, 12)}"><${tag} class="fw-line${attrs ? ' open' : ''}"${tag === 'button' ? ' type="button"' : ''}${attrs}><span class="name">${esc(p.label)}</span><span class="val num">${formatNumber(p.value)}</span></${tag}></li>`;
  }).join('');
  return `<ul class="fw-lines cascade">${rows}</ul>${parts.length > 14 ? `<p class="fw-more">${plural(parts.length - 14, 'autre valeur', 'autres valeurs')}</p>` : ''}`;
}

// ---------- Timeline ----------

function smooth(points) {
  let d = `M${points[0][0].toFixed(1)},${points[0][1].toFixed(1)}`;
  for (let n = 0; n < points.length - 1; n++) {
    const [x0, y0] = points[Math.max(0, n - 1)];
    const [x1, y1] = points[n];
    const [x2, y2] = points[n + 1];
    const [x3, y3] = points[Math.min(points.length - 1, n + 2)];
    d += ` C${(x1 + (x2 - x0) / 6).toFixed(1)},${(y1 + (y2 - y0) / 6).toFixed(1)} ${(x2 - (x3 - x1) / 6).toFixed(1)},${(y2 - (y3 - y1) / 6).toFixed(1)} ${x2.toFixed(1)},${y2.toFixed(1)}`;
  }
  return d;
}

const dayNumber = (iso) => {
  const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(String(iso ?? ''));
  return m ? Date.UTC(Number(m[1]), Number(m[2]) - 1, Number(m[3])) / 86_400_000 : NaN;
};

function line(entry, uid) {
  const pts = (Array.isArray(entry.points) ? entry.points : []).filter((p) => isNum(p.value) && Number.isFinite(dayNumber(p.date)));
  if (pts.length < 2) return empty(entry, 'Deux relevés datés au moins sont nécessaires pour tracer une évolution ; aucun jour manquant n’est remplacé par zéro.');
  const W = 600; const H = 180; const PAD = 14;
  const xs = pts.map((p) => dayNumber(p.date));
  const x0 = Math.min(...xs); const x1 = Math.max(...xs);
  const ys = pts.map((p) => p.value);
  const lo = Math.min(...ys); const hi = Math.max(...ys);
  const floor = Math.max(0, lo - (hi - lo) * 0.25);
  const span = hi - floor || 1;
  const coords = pts.map((p, n) => [PAD + ((xs[n] - x0) / (x1 - x0 || 1)) * (W - PAD * 2), PAD + (1 - (p.value - floor) / span) * (H - PAD * 2)]);
  // A gap of more than two days breaks the curve (a missing day is never drawn as a value).
  const runs = [];
  let run = [coords[0]];
  for (let n = 1; n < coords.length; n++) {
    if (xs[n] - xs[n - 1] > 2) { runs.push(run); run = []; }
    run.push(coords[n]);
  }
  runs.push(run);
  const paths = runs.filter((r) => r.length > 1).map((r) => {
    const d = smooth(r);
    return `<path class="area" fill="url(#${uid})" d="${d} L${r.at(-1)[0].toFixed(1)},${H} L${r[0][0].toFixed(1)},${H} Z"/><path class="ln draw" d="${d}"/>`;
  }).join('');
  const singles = runs.filter((r) => r.length === 1).map((r) => `<circle class="lone" cx="${r[0][0].toFixed(1)}" cy="${r[0][1].toFixed(1)}" r="3"/>`).join('');
  const [lx, ly] = coords.at(-1);
  const last = pts.at(-1);
  const first = pts[0];
  const delta = last.value - first.value;
  const trend = delta === 0 ? 'stable' : delta > 0 ? `+${formatNumber(delta)}` : `${formatNumber(delta).replace('-', '−')}`;
  const aria = `${entry.title} : ${plural(pts.length, 'jour relevé', 'jours relevés')}, de ${formatNumber(first.value)} le ${localDay(first.date)} à ${formatNumber(last.value)} le ${localDay(last.date)}`;
  return `<div class="fw-line-chart" role="img" aria-label="${esc(aria)}">
      <div class="fw-line-head"><b class="num" data-count="${numAttr(last.value)}">0</b><span class="trend ${delta > 0 ? 'up' : delta < 0 ? 'down' : 'flat'}">${esc(trend)} sur ${plural(Math.round(x1 - x0), 'jour', 'jours')}</span></div>
      <div class="plot"><svg viewBox="0 0 ${W} ${H}" preserveAspectRatio="none" focusable="false" aria-hidden="true">
        <defs><linearGradient id="${uid}" x1="0" y1="0" x2="0" y2="1"><stop class="g0" offset="0"/><stop class="g1" offset="1"/></linearGradient></defs>
        <g class="gridlines"><line x1="0" x2="${W}" y1="${H * 0.25}" y2="${H * 0.25}"/><line x1="0" x2="${W}" y1="${H * 0.5}" y2="${H * 0.5}"/><line x1="0" x2="${W}" y1="${H * 0.75}" y2="${H * 0.75}"/></g>
        ${paths}${singles}</svg>
        <span class="dot" data-x="${((lx / W) * 100).toFixed(2)}" data-y="${((ly / H) * 100).toFixed(2)}"></span></div>
      <div class="x"><span>${esc(localDay(first.date))}</span><span>min ${formatNumber(lo)} · max ${formatNumber(hi)}</span><span>${esc(localDay(last.date))}</span></div></div>`;
}

// ---------- Health ----------

const LEVEL = { alert: { label: 'Critique', tone: 'alert' }, warn: { label: 'À surveiller', tone: 'warn' }, info: { label: 'Information', tone: 'info' } };

function pointRows(points, limit) {
  return points.slice(0, limit).map((p, n) => {
    const lv = LEVEL[p.level] ?? LEVEL.info;
    const attrs = targetsAttr(p.targetsKey, p.text, p.count);
    const tag = attrs ? 'button' : 'div';
    return `<li data-j="${Math.min(n, 12)}"><${tag} class="fw-point${attrs ? ' open' : ''}" data-level="${lv.tone}"${tag === 'button' ? ' type="button"' : ''}${attrs}>`
      + `<span class="lv" aria-hidden="true"></span><span class="txt">${esc(p.text)}</span>`
      + `<span class="k-pill sm ${lv.tone}"><span class="k-pill-dot" aria-hidden="true"></span>${esc(lv.label)}</span>`
      + `<span class="cnt num">${formatNumber(p.count)}</span>${attrs ? glyph('chevronRight', 'chev') : ''}</${tag}></li>`;
  }).join('');
}

function points(entry, board, limit = 12) {
  const list = Array.isArray(board?.health?.points) ? board.health.points : [];
  if (!list.length) return `<div class="fw-calm">${glyph('check')}<span>Aucun point d’attention sur le périmètre évalué.</span></div>`;
  const more = list.length > limit ? `<p class="fw-more">${plural(list.length - limit, 'autre point', 'autres points')} : ${limit >= 10 ? '' : 'agrandissez le widget ou '}ouvrez « Comprendre le score ».</p>` : '';
  return `<ul class="fw-points cascade">${pointRows(list, limit)}</ul>${more}`;
}

function healthRing(h, size = '') {
  const score = isNum(h.score) ? h.score : null;
  return donut([{ value: score ?? 0, cls: 'toned', tone: tone(h.tone) || 'off' }], {
    total: 100, single: true, size,
    label: `Santé du parc : ${score === null ? h.verdict : `${score}${NBSP}%`}`,
    center: score === null
      ? '<div><b class="fw-word">—</b><span>non calculé</span></div>'
      : `<div><b data-count="${score}" data-suffix="${NBSP}%">0</b><span>sans problème</span></div>`,
  });
}

/**
 * Badge of the score (ACC-055, ACC-052; Domenia 1 Get-DomeniaBoardHealth): « Base AD incomplète », rules suspended for now and
 * the coverage line (« X évalués / Y comptes activés ; Z incomplets »), split on « · » into pills under the verdict: warn for
 * an incomplete base and the suspensions, off for the coverage.
 */
export function healthBadges(h) {
  const parts = String(h?.badge ?? '').split(' · ').map((x) => x.trim()).filter(Boolean);
  if (!parts.length) return '';
  const toneOf = (t) => (/incompl[eè]te|suspendue/i.test(t) && !/évalués/.test(t) ? 'warn' : 'off');
  return `<div class="fw-badges" role="list" aria-label="Limites de l’évaluation">${parts.map((t) => `<span class="k-pill sm ${toneOf(t)}" role="listitem">${esc(t)}</span>`).join('')}</div>`;
}

function healthSummary(entry, board, item) {
  const h = board?.health;
  if (!h) return empty(entry);
  const stat = (key, value, label, cls) => {
    const attrs = targetsAttr(key, `${label} · ${board.scopeLabel}`, value);
    const tag = attrs ? 'button' : 'div';
    return `<${tag} class="fw-stat ${cls}${attrs ? ' open' : ''}"${tag === 'button' ? ' type="button"' : ''}${attrs}><b class="num" data-count="${numAttr(value)}">0</b><span>${esc(label)}</span></${tag}>`;
  };
  const limit = item?.size === 'L' ? 10 : 4;
  return `<div class="fw-health">
      <div class="fw-health-main">
        <div class="fw-health-top">${healthRing(h, 'lg')}
          <div class="fw-health-read"><p class="verdict" data-tone="${esc(tone(h.tone) || 'off')}">${esc(h.verdict)}</p>${healthBadges(h)}<p class="detail">${esc(h.detail)}</p></div></div>
        <div class="fw-stats">${stat(h.healthyKey, h.healthy, 'Sans problème', 'ok')}${stat(h.problemsKey, h.problems, 'Avec problème', 'alert')}${stat(h.unknownKey, h.unassessed, 'Non évalués', 'off')}</div>
      </div>
      <div class="fw-health-points"><p class="fw-points-title">${esc(h.pointsTitle)}${h.masked ? ` <span class="k-pill sm off" data-tip="Postes dont un contrôle est suspendu ou désactivé">${plural(h.masked, 'masqué', 'masqués')}</span>` : ''}</p>${points(entry, board, limit)}</div>
    </div>`;
}

function empty(entry, text) {
  return `<div class="fw-empty">${glyph('info')}<span>${esc(text ?? (entry.detail || 'Aucune valeur à afficher.'))}</span></div>`;
}

/**
 * Body of a widget for its visual.
 * @param {any} entry @param {any} item @param {any} board @param {string} uid  Unique id for SVG gradients.
 */
export function widgetBody(entry, item, board, uid) {
  const v = visualFor(entry, item);
  if (!entry.measured && entry.kind !== 'health' && entry.kind !== 'list' && !(entry.items?.length) && !(entry.points?.length)) {
    return `<div class="fw-pending">${kpi(entry, { big: false })}</div>`;
  }
  switch (v) {
    case 'Kpi': return entry.kind === 'health' ? `<div class="fw-health-only">${healthRing(board.health, 'lg')}${healthBadges(board.health)}</div>` : kpi(entry, { board });
    case 'Text': return textList(entry);
    case 'Pie': return pie(entry);
    case 'Bar': return hbars(entry);
    case 'Column': return entry.kind === 'timeline' ? columns({ ...entry, items: (entry.points ?? []).slice(-12).map((p) => ({ label: p.label, value: p.value })) }) : columns(entry);
    case 'Line': return line(entry, uid);
    case 'List': return points(entry, board, item?.size === 'S' ? 4 : item?.size === 'M' ? 6 : 12);
    case 'Health': return `<div class="fw-health-only">${healthRing(board.health, 'lg')}<p class="verdict" data-tone="${esc(tone(board.health?.tone) || 'off')}">${esc(board.health?.verdict ?? '')}</p>${healthBadges(board.health)}</div>`;
    case 'HealthSummary': return healthSummary(entry, board, item);
    default: return kpi(entry, { board });
  }
}

/** Glyph of a widget by its kind and visual. */
export function widgetGlyph(entry, item) {
  const key = String(entry?.key ?? item?.key ?? '');
  if (key.startsWith('probe:')) return 'chip';
  if (key.startsWith('query:')) return 'database';
  const byKey = {
    'fleet.health': 'shield', 'fleet.attention': 'alert', 'fleet.machines': 'monitor', 'fleet.enabled': 'check', 'fleet.accountunknown': 'info',
    'fleet.accountstatus': 'users', 'fleet.stale': 'clock', 'fleet.disabled': 'power', 'fleet.created': 'sparkles', 'fleet.pwdold': 'key',
    'fleet.servers': 'server', 'fleet.laps': 'lock', 'fleet.bitlocker': 'shield', 'fleet.versions': 'layers', 'fleet.eos': 'calendar',
    'fleet.win10': 'monitor', 'fleet.os': 'chip', 'fleet.lastlogon': 'history', 'fleet.ou': 'ou', 'fleet.presence': 'wifi', 'fleet.wmi': 'activity',
    'fleet.reach': 'zap', 'fleet.users': 'user', 'fleet.lastcheck': 'clock', 'fleet.models': 'tag', 'fleet.releases': 'layers', 'fleet.ram': 'chip',
    'fleet.diskfree': 'disk', 'fleet.lowdisk': 'disk', 'fleet.uptime': 'refresh',
  };
  if (byKey[key]) return byKey[key];
  return key.startsWith('fleet.trend') ? 'activity' : 'gauge';
}
