// Accueil: dashboard of the working OU (hero with the working OU, KPI band, charts, watchlist, timeline, session and
// checks) and the « Choisir l’OU » side panel (tree read on demand, search, counts per OU, sub-OU, apply).
// Data contract: docs/OPERATIONS.md (app.info, session.info, session.setScope, dashboard.summary,
// dashboard.widget.refresh / setEnabled, directory.ou.children / search).
import { icon } from '../icons.js';
import { glyph } from '../kit/glyphs.js';
import { pushModal, popModal, trapFocus, leave, highlight, debounce } from '../kit/util.js';
import {
  esc, errorText, applyVars, reveal, countUp, progressTo, donut, inkFollow, copyText, announce,
  relTime, formatNumber, formatDateTime, formatTime, cssMs, fold,
} from '../ui.js';

/** The screen has its own stylesheet (css/pages/accueil.css), loaded by the router. */
export const stylesheet = true;

const KPI_IDS = ['workstationsOnline', 'activeAccounts', 'lockedAccounts', 'passwordsExpiring', 'diskAlerts'];
const WIDGET_ICONS = {
  workstationsOnline: 'monitor', activeAccounts: 'users', lockedAccounts: 'lock', passwordsExpiring: 'key',
  diskAlerts: 'disk', osDistribution: 'chip', workstationActivity: 'activity', measureFreshness: 'clock',
  watchlist: 'eye', recentOperations: 'zap',
};
// Short KPI titles always fit on one line, so the five tiles line up; the subtitle says what is counted. The engine
// title stays whole in the tip, and its end becomes the subtitle when it carries a threshold.
const KPI_TEXT = {
  workstationsOnline: { title: 'Postes en ligne', sub: 'Réponse au relevé de présence' },
  activeAccounts: { title: 'Comptes actifs', sub: 'Utilisateurs activés' },
  lockedAccounts: { title: 'Comptes verrouillés', sub: 'Trop d’essais de mot de passe' },
  passwordsExpiring: { title: 'Mots de passe', sub: 'Expiration prochaine' },
  diskAlerts: { title: 'Alertes disque', sub: 'Espace libre sur C:' },
};
const PANELS = [
  { id: 'session', label: 'Session' },
  { id: 'application', label: 'Application' },
  { id: 'store', label: 'Base locale', simulated: 'Données fictives' },
];
// No-break space before « % » and « : », as in the engine texts (OPERATIONS.md § 1.2).
const NBSP = ' ';
const pct = (v) => `${formatNumber(v, 1)}${NBSP}%`;
const DAY_MS = 86_400_000;
// Numbers from the bridge written into attributes: always a plain number ("NaN" for a missing measure, shown "—").
const isNum = (v) => typeof v === 'number' && Number.isFinite(v);
const numAttr = (v) => (isNum(v) ? String(v) : 'NaN');
const countText = (v) => (isNum(v) ? formatNumber(v) : 'non mesuré');
const plural = (n, one, many) => `${formatNumber(n)} ${n > 1 ? many : one}`;
const capitalize = (t) => (t ? t[0].toLocaleUpperCase('fr') + t.slice(1) : t);
const RING = '<span class="glow-ring hero-ring" aria-hidden="true"></span>';
const ORBS = '<div class="orbs" aria-hidden="true"><span class="orb a"></span><span class="orb b"></span><span class="orb c"></span></div>';
const longDate = new Intl.DateTimeFormat('fr-FR', { weekday: 'long', day: 'numeric', month: 'long' });
// The simulation (and the browser preview) never opens the local base: its figures come from the fictitious directory
// kept in memory (SIMULATION.md § 1), and the texts say so.
const isSimulated = (s, app) => s?.connection?.state === 'simulated' || app?.mode === 'simulation';
const panelLabel = (p, sim) => (sim && p.simulated ? p.simulated : p.label);
// lastSeenAt is null when no answer to the presence check (ping) is recorded, even if WMI answered (OPERATIONS.md § 4.7).
const NO_PING_TIP = 'Aucune réponse au relevé de présence (ping) n’est enregistrée pour ce poste. Le ping peut être filtré : '
  + 'une absence de réponse n’est jamais un verdict d’arrêt.';
const INVENTORY_RULES = new Set(['lowDisk', 'diskTight', 'uptime']);
const PATH_SEP = `${NBSP}› `;
// directory.ou.search answers at most this many OU (OPERATIONS.md § 10): a full list may hide more matches.
const OU_SEARCH_LIMIT = 50;

// ---------- Distinguished names (RFC 4514) ----------

// Splits a DN into its RDN; escaped commas stay inside their RDN.
function splitDn(dn) {
  const parts = [];
  let cur = '';
  for (let n = 0; n < dn.length; n++) {
    const c = dn[n];
    if (c === '\\' && n + 1 < dn.length) { cur += c + dn[n + 1]; n += 1; continue; }
    if (c === ',') { parts.push(cur.trim()); cur = ''; continue; }
    cur += c;
  }
  if (cur.trim()) parts.push(cur.trim());
  return parts;
}

// Value of an RDN with its escapes decoded (\, and hexadecimal UTF-8 bytes such as \C3\A9).
function rdnValue(rdn) {
  const raw = rdn.slice(rdn.indexOf('=') + 1);
  const bytes = [];
  let out = '';
  const flush = () => { if (bytes.length) { out += new TextDecoder().decode(new Uint8Array(bytes)); bytes.length = 0; } };
  for (let n = 0; n < raw.length; n++) {
    if (raw[n] === '\\' && /^[0-9a-f]{2}$/i.test(raw.slice(n + 1, n + 3))) { bytes.push(parseInt(raw.slice(n + 1, n + 3), 16)); n += 2; continue; }
    flush();
    if (raw[n] === '\\' && n + 1 < raw.length) { out += raw[n + 1]; n += 1; continue; }
    out += raw[n];
  }
  flush();
  return out;
}

const rdnType = (rdn) => rdn.slice(0, Math.max(0, rdn.indexOf('='))).trim().toUpperCase();
const sameDn = (a, b) => typeof a === 'string' && typeof b === 'string' && a.toLowerCase() === b.toLowerCase();

// Root of the domain and chain of the containers of a DN from the top ({ dn, name, type }, the DN itself last).
function dnChain(dn, dnsName) {
  const rdns = splitDn(String(dn ?? ''));
  const dcAt = rdns.findIndex((r) => rdnType(r) === 'DC');
  if (dcAt < 0) return null;
  const domain = dnsName || rdns.slice(dcAt).map(rdnValue).join('.');
  const chain = [];
  for (let k = dcAt - 1; k >= 0; k--) chain.push({ dn: rdns.slice(k).join(','), name: rdnValue(rdns[k]), type: rdnType(rdns[k]) });
  return { root: { dn: rdns.slice(dcAt).join(','), name: domain }, chain };
}

const pathOf = (dn, dnsName) => {
  const c = dnChain(dn, dnsName);
  return c ? [c.root.name, ...c.chain.map((x) => x.name)].join(PATH_SEP) : '';
};

// ---------- CSS variables set through the CSSOM (CSP forbids style="…") ----------

// data-x / data-y / data-h: positions and heights in percent; data-lvl: depth in the OU tree.
function applyLocal(scope) {
  const sel = '[data-x],[data-y],[data-h],[data-lvl]';
  const list = scope.matches?.(sel) ? [scope] : [];
  list.push(...scope.querySelectorAll(sel));
  for (const el of list) {
    for (const k of ['x', 'y', 'h', 'lvl']) {
      const v = el.dataset[k];
      if (v === undefined) continue;
      const n = Number(v);
      el.style.setProperty(`--${k}`, String(Number.isFinite(n) ? Math.min(100, Math.max(0, n)) : 0));
    }
  }
}

function paint(scope) {
  applyVars(scope);
  applyLocal(scope);
}

// ---------- Skeletons ----------

const sk = (cls) => `<span class="skeleton sk ${cls}"></span>`;
const skStack = (...cls) => `<div class="sk-stack">${cls.map(sk).join('')}</div>`;
const secHead = (id, title, note) => `<div class="home-sec reveal" data-sec="${id}"><h2>${esc(title)}</h2><span class="sec-note">${esc(note)}</span></div>`;

function skeletonPage() {
  const kpi = (id) => `<article class="card kpi spot tilt reveal" data-widget="${id}">${skStack('sk-line w40', 'sk-title w70', 'sk-value w55', 'sk-line w85', 'sk-line w70')}</article>`;
  const chart = (id, span, body) => `<section class="card widget ${span} spot reveal" data-widget="${id}"><div class="sk-stack">${sk('sk-line w40')}${body}</div></section>`;
  return `<div class="page home"><div class="grid">
    <section class="hero span-12 reveal" data-slot="hero">
      ${RING}${ORBS}
      <div class="hero-grid"><div class="hero-main">${skStack('sk-line w25', 'sk-title w40', 'sk-line w70', 'sk-line w55')}</div>
        <div class="scope-card">${skStack('sk-line w40', 'sk-title w55', 'sk-line w85', 'sk-line w70')}</div></div>
    </section>
    ${secHead('kpis', 'Indicateurs clés', 'Comptes : tout le domaine · postes : OU de travail')}
    <div class="kpi-band">${KPI_IDS.map(kpi).join('')}</div>
    ${secHead('fleet', 'Parc de l’OU de travail', 'Calculé localement, sans lecture réseau')}
    ${chart('workstationActivity', 'span-5', sk('sk-block w100'))}
    ${chart('osDistribution', 'span-4', sk('sk-ring'))}
    ${chart('measureFreshness', 'span-3', sk('sk-ring'))}
    ${secHead('follow', 'Suivi', 'Postes à surveiller et journal des opérations')}
    ${chart('watchlist', 'span-7', skStack('sk-line w85', 'sk-line w70', 'sk-line w85', 'sk-line w55'))}
    ${chart('recentOperations', 'span-5', skStack('sk-line w70', 'sk-line w55', 'sk-line w70', 'sk-line w40'))}
    <section class="card span-12 spot reveal session-card" data-slot="session">${skStack('sk-line w25', 'sk-line w100', 'sk-line w85')}</section>
  </div></div>`;
}

// ---------- Small pieces ----------

function rel(iso, prefix = '') {
  const text = relTime(iso);
  return text ? `<span data-rel="${esc(iso)}" data-prefix="${esc(prefix)}">${esc(prefix + text)}</span>` : '';
}

function deltaChip(delta) {
  if (!delta) return '<span class="delta flat">Pas d’historique à 7 jours</span>';
  const arrow = delta.value > 0 ? icon('arrowUp') : delta.value < 0 ? icon('arrowDown') : '';
  const tone = ['ok', 'warn', 'alert', 'info'].includes(delta.tone) ? delta.tone : 'info';
  return `<span class="delta ${tone}">${arrow}${esc(delta.label)}</span>`;
}

function stack(breakdown, label) {
  const parts = breakdown.filter((b) => b.value > 0)
    .map((b) => `<span data-tone="${esc(b.tone)}" data-grow="${numAttr(b.value)}" data-tip="${esc(`${b.label} : ${formatNumber(b.value)}`)}"></span>`).join('');
  // The value stays glued to the end of its label, even when a long label wraps.
  const legend = breakdown.map((b) => `<li><span class="dot" data-tone="${esc(b.tone)}"></span><span>${esc(b.label)}${NBSP}<b>${formatNumber(b.value)}</b></span></li>`).join('');
  return `<div class="stack" role="img" aria-label="${esc(label)}">${parts}</div><ul class="stack-legend">${legend}</ul>`;
}

function refreshButton() {
  return `<button class="btn ghost icon sm refresh" type="button" data-refresh aria-label="Actualiser ce widget" data-tip="Actualiser ce widget">${icon('refresh')}</button>`;
}

// « Mesure active » is kept in the preferences of the application (LocalWrite, never the directory).
function enabledSwitch(w) {
  return `<label class="measure-switch" data-tip="Choix mémorisé dans les préférences de Domenia"><input class="switch" type="checkbox" role="switch" data-toggle aria-label="Mesure active : ${esc(w.title)}"${w.enabled ? ' checked' : ''}><span>Mesure active</span></label>`;
}

function whenText(w) {
  if (!w.enabled) return 'Mesure désactivée';
  if (!w.measuredAt) return 'Jamais mesuré';
  return null;
}

function offNote(w) {
  const action = w.enabled ? `<button class="btn sm" type="button" data-refresh>${icon('refresh')}Mesurer maintenant</button>` : '';
  return `<div class="off-note">${icon(w.enabled ? 'info' : 'power')}<span>${esc(w.detail)}</span>${action}</div>`;
}

function staleChip(w) {
  return w.stale ? '<span class="chip warn stale-chip">Mesure ancienne</span>' : '';
}

// Hover tip that keyboard users can reach (tabindex) and screen readers hear (hidden copy of the tip).
function tipSpan(cls, tip, visible) {
  return `<span class="${cls}" tabindex="0" data-tip="${esc(tip)}">${visible}<span class="visually-hidden"> · ${esc(tip)}</span></span>`;
}

// Scope of a widget as a small tag: « Domaine » (whole domain, full name in the tip) or « OU Postes ».
function scopeTag(w) {
  const label = String(w.scopeLabel ?? '');
  const domain = label.startsWith('Domaine');
  const short = domain ? 'Domaine' : label;
  const more = short !== label ? `<span class="visually-hidden">${esc(label.slice(short.length))}</span>` : '';
  return `<span class="scope-tag" data-tip="${esc(label)}">${domain ? glyph('domain') : glyph('ou')}<span class="txt">${esc(short)}${more}</span></span>`;
}

// ---------- KPI tiles ----------

function kpiText(w) {
  const base = KPI_TEXT[w.id];
  const title = String(w.title ?? '');
  if (!base) return { title, sub: '' };
  let sub = base.sub;
  if (title.startsWith(`${base.title} `)) sub = capitalize(title.slice(base.title.length + 1));
  else if (w.id === 'diskAlerts' && typeof w.data?.breakdown?.[0]?.label === 'string') sub = `${w.data.breakdown[0].label} sur C:`;
  return { title: base.title, sub };
}

function smoothPath(points) {
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

// Curve of the 14 days drawn in the background of the tile, under the value; a missing day leaves a gap in x.
function kpiSpark(id, history) {
  const pts = (Array.isArray(history) ? history : [])
    .filter((p) => isNum(p?.value) && !Number.isNaN(Date.parse(p.date)))
    .map((p) => ({ x: Date.parse(p.date) / DAY_MS, y: p.value }));
  if (pts.length < 2) return '';
  const W = 240; const H = 72; const PAD = 8; const RIGHT = 12;
  const x0 = Math.min(...pts.map((p) => p.x)); const x1 = Math.max(...pts.map((p) => p.x));
  const lo = Math.min(...pts.map((p) => p.y)); const hi = Math.max(...pts.map((p) => p.y));
  const span = hi - lo || 1;
  const coords = pts.map((p) => [
    (x1 > x0 ? (p.x - x0) / (x1 - x0) : 1) * (W - RIGHT),
    PAD + (1 - (hi === lo ? 0.5 : (p.y - lo) / span)) * (H - PAD * 2),
  ]);
  const line = smoothPath(coords);
  const [lx, ly] = coords.at(-1);
  const area = `${line} L${lx.toFixed(1)},${H} L${coords[0][0].toFixed(1)},${H} Z`;
  const gid = `kspark-${String(id).replace(/[^a-z0-9-]/gi, '')}`;
  return `<div class="kpi-spark" aria-hidden="true"><svg viewBox="0 0 ${W} ${H}" preserveAspectRatio="none" focusable="false">`
    + `<defs><linearGradient id="${gid}" x1="0" y1="0" x2="0" y2="1"><stop class="ks0" offset="0"/><stop class="ks1" offset="1"/></linearGradient></defs>`
    + `<path class="ks-area" fill="url(#${gid})" d="${area}"/><path class="ks-line" d="${line}"/></svg>`
    + `<span class="ks-dot" data-x="${((lx / W) * 100).toFixed(2)}" data-y="${((ly / H) * 100).toFixed(2)}"></span></div>`;
}

function kpiCard(w) {
  const d = w.data;
  const t = kpiText(w);
  const meta = whenText(w);
  const when = meta ? esc(meta) : rel(w.measuredAt);
  const tip = t.title !== w.title ? ` data-tip="${esc(w.title)}"` : '';
  const head = `<div class="kpi-top"><span class="card-icon">${icon(WIDGET_ICONS[w.id])}</span>${scopeTag(w)}${staleChip(w)}${w.enabled ? refreshButton() : ''}</div>
    <div class="kpi-titles"><h3 class="kpi-title"${tip}>${esc(t.title)}</h3>${t.sub ? `<p class="kpi-sub">${esc(t.sub)}</p>` : ''}</div>`;
  let body;
  if (!d) {
    body = offNote(w);
  } else {
    const small = d.total != null ? `<small>/${NBSP}${formatNumber(d.total)}</small>` : `<small>${esc(d.unit)}</small>`;
    // The final value is in the DOM for assistive technologies; the count-up runs on a hidden twin.
    body = `<div class="kpi-main">${kpiSpark(w.id, d.history)}
        <div class="value num"><span class="visually-hidden">${esc(countText(d.value))}</span><span data-count="${numAttr(d.value)}" aria-hidden="true">0</span>${small}</div>
        <div class="kpi-trend">${deltaChip(d.delta)}</div>
      </div>
      ${stack(d.breakdown, `${w.title} : ${d.breakdown.map((b) => `${b.label} ${b.value}`).join(', ')}`)}`;
  }
  // With data, the method note only lives in the tip; without data it is already written in the off-note. The tip
  // also gives the full date, since a narrow tile may shorten the relative time.
  // A disabled tile says so in its note and its switch: no date beside the switch.
  const measured = formatDateTime(w.measuredAt);
  let foot = '';
  if (d) foot = tipSpan('when', `${measured ? `Mesuré le ${measured} · ` : ''}${w.scopeLabel} · ${w.detail}`, when);
  else if (w.enabled) foot = `<span class="when" data-tip="${esc(w.scopeLabel)}">${when}</span>`;
  return `${head}<div class="card-body">${body}</div><div class="kpi-foot">${enabledSwitch(w)}${foot}</div>`;
}

// ---------- Chart cards ----------

// Same places as the KPI tiles: the scope under the title, the measure date in the foot beside « Mesure active ».
function cardHead(w, extra = '') {
  const where = esc(w.scopeLabel);
  const sub = w.data ? tipSpan('head-sub', w.detail, where) : `<span class="head-sub" data-tip="${esc(w.detail)}">${where}</span>`;
  return `<div class="card-head"><span class="card-icon">${icon(WIDGET_ICONS[w.id])}</span>
    <div class="head-titles"><h3>${esc(w.title)}</h3>${sub}</div>
    <span class="meta">${extra}${staleChip(w)}${w.enabled ? refreshButton() : ''}</span></div>`;
}

function cardFoot(w, action = '') {
  const meta = whenText(w);
  const when = meta ? esc(meta) : rel(w.measuredAt);
  const measured = formatDateTime(w.measuredAt);
  let foot = '';
  if (w.data) foot = tipSpan('when', `${measured ? `Mesuré le ${measured} · ` : ''}${w.scopeLabel}`, when);
  else if (w.enabled) foot = `<span class="when" data-tip="${esc(w.scopeLabel)}">${when}</span>`;
  return `<div class="card-foot">${enabledSwitch(w)}${foot}<span class="spacer"></span>${action}</div>`;
}

// Legend row with its share drawn as a thin meter under the label: the value never floats far from its label.
function legendRow({ key, sw, tone, label, value, share, right, tip, n }) {
  const keyAttr = key ? ` data-key="${esc(key)}"` : '';
  const tipAttr = tip ? ` data-tip="${esc(tip)}"` : '';
  const toneAttr = tone ? ` data-tone="${esc(tone)}"` : '';
  const more = tip ? `<span class="visually-hidden"> : ${esc(tip)}</span>` : '';
  return `<li tabindex="0"${right ? ' class="has-pct"' : ''}${keyAttr} data-j="${n}"${tipAttr}><span class="sw ${sw ?? ''}"${toneAttr}></span><span class="name">${esc(label)}</span>`
    + `<span class="val num">${formatNumber(value)}</span>${right ? `<span class="pct num">${right}</span>` : ''}`
    + `<span class="meter ${sw ?? ''}" aria-hidden="true"><span data-p="${isNum(share) ? share.toFixed(4) : '0'}"${toneAttr}></span></span>${more}</li>`;
}

function osBody(d) {
  if (!d.total || !d.segments.length) return `<div class="off-note">${icon('info')}<span>Aucun ordinateur activé dans cette OU.</span></div>`;
  const legend = d.segments.map((s, n) => legendRow({
    key: s.key, sw: `s${(n % 8) + 1}`, label: s.label, value: s.value, share: s.percent / 100, right: pct(s.percent),
    tip: s.members?.length ? s.members.join(', ') : '', n,
  })).join('');
  const ring = donut(d.segments.map((s) => ({ value: s.value, key: s.key })), {
    total: d.total, label: `${d.centerText} : ${d.segments.map((s) => `${s.label} ${pct(s.percent)}`).join(', ')}`,
    center: `<div><b data-count="${numAttr(d.total)}">0</b><span>${esc(d.unit)}</span></div>`,
  });
  // lead is null when the scope holds no enabled computer (DistributionData.Lead).
  const lead = d.lead ? `<p class="legend-lead"><b>${esc(d.lead.label)}</b> en tête · ${pct(d.lead.percent)}</p>` : '';
  return `<div class="ring-wrap">${ring}<div class="legend-col">${lead}<ul class="legend meters cascade">${legend}</ul></div></div>`;
}

const isoDayParts = (date) => {
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(String(date ?? ''));
  return m ? new Date(Number(m[1]), Number(m[2]) - 1, Number(m[3])) : null;
};

// Seven columns with their value written above the bar; week-end lighter, today hatched (day in progress), a day
// without snapshot shows a dash, never a zero bar. The dashed line is the mean of the complete working days.
function activityBody(d) {
  const values = d.points.map((p) => (isNum(p.value) ? p.value : null));
  const top = Math.max(1, d.max || 0, ...values.filter(isNum)) * 1.16;
  const days = d.points.map((p) => isoDayParts(p.date));
  const weekend = days.map((day) => Boolean(day && (day.getDay() === 0 || day.getDay() === 6)));
  const work = d.points.filter((p, n) => !p.partial && isNum(p.value) && !weekend[n]).map((p) => p.value);
  const mean = work.length ? Math.round(work.reduce((a, b) => a + b, 0) / work.length) : null;
  const cols = d.points.map((p, n) => {
    const cls = `act-col${weekend[n] ? ' weekend' : ''}${p.partial ? ' today' : ''}`;
    if (!isNum(p.value)) return `<div class="${cls} gap" data-i="${n}"><span class="act-none" data-tip="Aucun instantané ce jour-là">—</span></div>`;
    const tip = `${p.label} ${days[n] ? days[n].getDate() : ''} : ${plural(p.value, 'poste', 'postes')}${p.partial ? ' (journée en cours)' : ''}`;
    return `<div class="${cls}" data-h="${((p.value / top) * 100).toFixed(1)}" data-i="${n}" data-tip="${esc(tip)}">`
      + `<span class="act-val num">${formatNumber(p.value)}</span><span class="act-bar"></span></div>`;
  }).join('');
  const avg = mean != null ? `<div class="act-avg" data-y="${((mean / top) * 100).toFixed(1)}" aria-hidden="true"></div>` : '';
  const avgNote = mean != null ? `<span><span class="sw avg"></span>Moyenne en semaine${NBSP}: ${formatNumber(mean)}</span>` : '';
  const axis = d.points.map((p, n) => `<span class="${p.partial ? 'today' : ''}${weekend[n] ? ' weekend' : ''}">${esc(p.label)}<b>${days[n] ? days[n].getDate() : ''}</b></span>`).join('');
  const aria = `Activité sur 7 jours : ${d.points.map((p) => `${p.label} ${p.value ?? 'sans relevé'}`).join(', ')}${mean != null ? `. Moyenne des jours ouvrés : ${mean}` : ''}`;
  return `<div class="act-chart" role="img" aria-label="${esc(aria)}"><div class="act-plot"><div class="act-grid" aria-hidden="true"><span></span><span></span><span></span></div>${avg}<div class="act-cols">${cols}</div></div>`
    + `<div class="act-x" aria-hidden="true">${axis}</div></div>`
    + `<div class="chart-note"><span><span class="sw"></span>Postes ayant répondu</span><span><span class="sw partial"></span>Aujourd’hui : journée en cours</span>${avgNote}</div>`;
}

function freshnessBody(w) {
  const d = w.data;
  const ring = donut([{ value: d.percent, cls: 'toned', tone: w.tone }], {
    total: 100, single: true, size: 'lg', label: `Fraîcheur : ${pct(d.percent)}`,
    center: `<div><b data-count="${numAttr(d.percent)}" data-dec="1" data-suffix="${NBSP}%">0</b><span>${formatNumber(d.fresh)} / ${formatNumber(d.total)}</span></div>`,
  });
  const total = d.total || 1;
  const legend = d.breakdown.map((b, n) => legendRow({ sw: '', tone: b.tone, label: b.label, value: b.value, share: b.value / total, n })).join('');
  const lead = `<p class="legend-lead"><b>${plural(d.fresh, 'poste', 'postes')}</b> relevés depuis moins de ${formatNumber(d.freshDays)}${NBSP}jours</p>`;
  return `<div class="ring-wrap stacked">${ring}<div class="legend-col">${lead}<ul class="legend meters cascade">${legend}</ul></div></div>`;
}

function watchBody(d) {
  if (!d.rows.length) return `<div class="off-note">${icon('check')}<span>Aucun poste à surveiller dans le périmètre.</span></div>`;
  const rows = d.rows.map((r, n) => {
    let seen;
    if (r.lastSeenAt) seen = rel(r.lastSeenAt, 'vu ');
    else {
      const tip = INVENTORY_RULES.has(r.ruleId) ? `${NO_PING_TIP} Son inventaire a pourtant été lu par WMI : le poste répond.` : NO_PING_TIP;
      seen = `<span class="no-ping" data-tip="${esc(tip)}">aucune réponse au ping</span>`;
    }
    const more = r.otherReasons > 0
      ? `<span class="more" data-tip="Autres points d’attention">+${formatNumber(r.otherReasons)}<span class="visually-hidden"> ${r.otherReasons > 1 ? 'autres points' : 'autre point'} d’attention</span></span>` : '';
    const alert = r.severity === 'alert';
    return `<button class="list-row watch-row" type="button" data-go="poste" data-dn="${esc(r.dn)}" data-sev="${alert ? 'alert' : 'warn'}" data-j="${n}" data-tip="${esc(r.dn)}">
      <span class="sev-mark" aria-hidden="true"></span>
      <span class="avatar pc">${icon('monitor')}</span>
      <span class="body"><span class="title">${esc(r.name)}${more}</span><span class="sub">${esc(r.reason)}</span></span>
      <span class="side"><span class="chip ${alert ? 'alert' : 'warn'}"><span class="dot"></span>${alert ? 'Critique' : 'À surveiller'}</span><span class="when">${seen}</span></span>
      ${icon('chevronRight', 'chev')}</button>`;
  }).join('');
  return `<div class="list cascade">${rows}</div>`;
}

function timelineBody(d) {
  if (!d.rows.length) return `<div class="off-note">${icon('info')}<span>Aucune opération dans le journal.</span></div>`;
  const rows = d.rows.map((r, n) => `<div class="ev" data-tone="${esc(r.tone)}" data-j="${n}"><div class="label">${esc(r.label)}</div>`
    + `<div class="when">${rel(r.at)}${formatTime(r.at) ? ` · ${esc(formatTime(r.at))}` : ''}</div></div>`).join('');
  return `<div class="timeline cascade">${rows}</div>`;
}

function chartCard(w) {
  const d = w.data;
  let extra = '';
  let body;
  let action = '';
  if (!d) body = offNote(w);
  else if (w.id === 'osDistribution') body = osBody(d);
  else if (w.id === 'workstationActivity') {
    const today = d.points.find((p) => p.partial);
    if (today && isNum(today.value)) extra = `<span class="head-chip" data-tip="Journée en cours">${formatNumber(today.value)} aujourd’hui</span>`;
    body = activityBody(d);
  } else if (w.id === 'measureFreshness') body = freshnessBody(w);
  else if (w.id === 'watchlist') {
    extra = `<span class="head-chip">${formatNumber(d.shown)} sur ${formatNumber(d.total)}</span>`;
    body = watchBody(d);
    if (d.total > d.shown) action = `<button class="btn sm" type="button" data-go="rechercher">${icon('search')}Voir les ${formatNumber(d.total)} postes dans Rechercher</button>`;
  } else {
    extra = `<span class="head-chip">${formatNumber(d.rows.length)} sur ${formatNumber(d.total)}</span>`;
    body = timelineBody(d);
    action = `<button class="btn sm ghost" type="button" data-go="operations">${icon('activity')}Ouvrir le journal des opérations</button>`;
  }
  return `${cardHead(w, extra)}<div class="card-body">${body}</div>${cardFoot(w, action)}`;
}

// ---------- Hero, working OU, stepper and session panels ----------

// session.info in directory mode without a connection still names the join domain (domain.dnsName may also be null).
function leadText(s) {
  const safety = s.readOnly ? 'Lecture seule : aucune modification de l’annuaire n’est possible.'
    : 'Rien n’est modifié sans votre geste : toute écriture demande une confirmation explicite.';
  const dns = s.domain?.dnsName;
  if (s.connection?.state === 'disconnected' || !dns) {
    return `Annuaire non connecté${dns ? ` (domaine ${dns})` : ''} : les lectures de l’annuaire reprendront à la connexion. ${safety}`;
  }
  const where = s.scope
    ? `Postes de l’OU ${s.scope.label}${s.scope.subtree ? ' et de ses sous-OU' : ''}`
    : 'Aucune OU de travail choisie pour mesurer les postes';
  return `${where}, comptes de tout le domaine ${dns}. ${safety}`;
}

function heroChips(s, lastReadAt, sim) {
  const chips = [];
  if (s.account?.login) chips.push(`<span class="chip" data-tip="${esc(s.account.displayName ? `Compte utilisé pour l’annuaire · ${s.account.displayName}` : 'Compte utilisé pour l’annuaire')}">${icon('user')}<span class="mono">${esc(s.account.login)}</span></span>`);
  if (s.domain?.dnsName) chips.push(`<span class="chip" data-tip="${esc(s.domain.netbiosName ? `Domaine · NetBIOS ${s.domain.netbiosName}` : 'Domaine')}">${glyph('domain')}${esc(s.domain.dnsName)}</span>`);
  if (s.controller) chips.push(`<span class="chip" data-tip="Contrôleur de domaine">${icon('server')}${esc(s.controller.dnsName)}${s.controller.site ? ` · ${esc(s.controller.site)}` : ''}</span>`);
  const date = formatDateTime(lastReadAt);
  if (lastReadAt) {
    const tip = sim
      ? `Lecture fictive du ${date ?? '—'} : en simulation, aucune base locale n’est ouverte et aucun annuaire n’est interrogé.`
      : `Dernière lecture de l’annuaire enregistrée dans la base locale : ${date ?? '—'}. L’Accueil se calcule depuis cette base, sans lecture réseau.`;
    chips.push(`<span class="chip info" data-tip="${esc(tip)}">${icon(sim ? 'sparkles' : 'database')}${rel(lastReadAt, sim ? 'Annuaire fictif · lu ' : 'Annuaire lu ')}</span>`);
  } else {
    chips.push(`<span class="chip warn">${icon('database')}${sim ? 'Annuaire fictif non lu' : 'Base locale vide : aucune lecture de l’annuaire'}</span>`);
  }
  return chips.map((c, n) => c.replace('<span class="chip', `<span data-j="${n}" class="chip`)).join('');
}

// Working OU: name, path (each level opens the OU panel on it, ACC-013), depth and the button of the panel.
function scopeCardMarkup(s) {
  const scope = s?.scope ?? null;
  const chain = scope ? dnChain(scope.dn, s.domain?.dnsName) : null;
  let crumbs = '';
  if (chain) {
    const steps = [{ ...chain.root, root: true }, ...chain.chain];
    crumbs = `<nav class="crumbs" aria-label="Chemin de l’OU de travail"><ol>${steps.map((c, n) => {
      const last = n === steps.length - 1;
      const inner = last ? `<span class="crumb now" aria-current="location">${esc(c.name)}</span>`
        : `<button type="button" class="crumb" data-reveal="${esc(c.dn)}" data-tip="${esc(c.root ? 'Ouvrir le choix de l’OU à la racine du domaine' : `Ouvrir le choix de l’OU sur ${c.name}`)}">${esc(c.name)}</button>`;
      return `<li data-j="${n}">${inner}</li>`;
    }).join('')}</ol></nav>`;
  }
  const depth = scope ? `<span class="chip ${scope.subtree ? 'info' : ''} depth">${scope.subtree ? 'Sous-OU comprises' : 'Cette OU seulement'}</span>` : '';
  const note = scope ? 'Défaut de toutes les sections : postes mesurés dans cette OU, comptes sur tout le domaine.'
    : 'Choisissez une OU : la mesure des postes n’est jamais lancée sur tout le domaine.';
  return `<div class="scope-top"><span class="scope-ico">${glyph('ou')}</span><span class="scope-k" id="scope-card-k">OU de travail</span>${depth}</div>
    <div class="scope-name">${scope ? esc(scope.label) : 'Aucune OU choisie'}</div>
    ${crumbs}
    <p class="scope-note">${esc(note)}</p>
    <button class="btn ${scope ? '' : 'primary '}sm scope-btn" type="button" data-act="scope" aria-haspopup="dialog">${glyph('ou')}Choisir l’OU</button>`;
}

// Ordered list in a labelled group; each step says its state in words (the check mark is decorative).
function stepperMarkup(onb) {
  const steps = onb.steps.map((st, n) => `<li class="step" data-step="${esc(st.id)}" data-j="${n}"><span class="mark" aria-hidden="true"></span>`
    + `<span class="label">${esc(st.label)}</span><span class="visually-hidden step-state"></span></li>`).join('');
  return `<div class="stepper" role="group" aria-labelledby="stepper-title">
    <div class="stepper-head">${icon('sparkles')}<span class="title" id="stepper-title">Premiers pas</span><span class="count"></span></div>
    <div class="progress" role="progressbar" aria-label="Progression des premiers pas" aria-valuemin="0" aria-valuemax="${Number(onb.total) || 0}"><span></span></div>
    <ol class="steps">${steps}</ol></div>`;
}

function updateStepper(root, onb) {
  const stepper = root.querySelector('.stepper');
  if (!stepper || !onb) return;
  const firstOpen = onb.steps.findIndex((s) => !s.done);
  const items = [...stepper.querySelectorAll('[data-step]')];
  onb.steps.forEach((st, n) => {
    const li = items.find((el) => el.dataset.step === st.id);
    if (!li) return;
    const wasDone = li.classList.contains('done');
    li.classList.toggle('done', st.done);
    li.classList.toggle('current', n === firstOpen);
    if (n === firstOpen) li.setAttribute('aria-current', 'step'); else li.removeAttribute('aria-current');
    const state = li.querySelector('.step-state');
    if (state) state.textContent = st.done ? ', terminée' : n === firstOpen ? ', étape en cours' : ', à faire';
    if (wasDone !== st.done || !li.querySelector('.mark').hasChildNodes()) {
      li.querySelector('.mark').innerHTML = st.done ? icon('check') : String(n + 1);
    }
  });
  const all = onb.completed >= onb.total;
  stepper.classList.toggle('complete', all);
  stepper.querySelector('.title').textContent = all ? 'Premiers pas terminés' : 'Premiers pas';
  stepper.querySelector('.count').textContent = `${onb.completed} / ${onb.total}`;
  const bar = stepper.querySelector('.progress');
  bar.setAttribute('aria-valuenow', String(onb.completed));
  bar.setAttribute('aria-valuetext', `${plural(onb.completed, 'étape faite', 'étapes faites')} sur ${formatNumber(onb.total)}`);
  progressTo(bar.firstElementChild, onb.total ? onb.completed / onb.total : 0);
}

// Hero content; the rotating ring and the orbs come from the skeleton and stay, so their motion never restarts.
// Title: the scope, never a greeting by first name (decision of David, 21/10: the operator signs in with an administration
// account); the account itself is a chip.
function heroTitle(s) {
  if (!s.scope) return 'Vue d’ensemble';
  const root = s.domain?.rootDn && s.scope.dn.toLowerCase() === s.domain.rootDn.toLowerCase();
  return `Vue d’ensemble · ${root ? `Domaine ${s.scope.label}` : `OU ${s.scope.label}`}`;
}

function heroMarkup(s, lastReadAt, sim) {
  return `<div class="hero-grid">
      <div class="hero-main">
        <div class="eyebrow">${icon('sparkles')}<span>Tableau de bord</span><span class="eyebrow-date">${esc(longDate.format(new Date()))}</span></div>
        <h1 class="gradient-text">${esc(heroTitle(s))}</h1>
        <p class="lead">${esc(leadText(s))}</p>
        <div class="chips">${heroChips(s, lastReadAt, sim)}</div>
        <div class="hero-row">
          <button class="btn primary" type="button" data-act="refresh-all">${icon('refresh')}<span class="label-progress">Tout actualiser</span></button>
          <button class="btn" type="button" data-act="queries">${icon('database')}Ouvrir l’atelier de requêtes</button>
        </div>
      </div>
      <aside class="scope-card" data-slot="scope" aria-labelledby="scope-card-k">${scopeCardMarkup(s)}</aside>
    </div>
    ${stepperMarkup(s.onboarding)}`;
}

// A DN only breaks after its commas (<wbr>), never in the middle of a name.
const breakable = (text) => esc(text).replace(/,/g, ',<wbr>');
const looksDn = (v) => typeof v === 'string' && /^(?:[A-Za-z]+=[^,]+,)+[A-Za-z]+=/.test(v);
const kv = (label, value, sub = '') => `<div><dt>${esc(label)}</dt><dd>${looksDn(value) ? breakable(value) : esc(value ?? '—')}`
  + `${sub ? `<span class="sub">${looksDn(sub) ? breakable(sub) : esc(sub)}</span>` : ''}</dd></div>`;

const ENGINES = { embarque: 'Moteur fixe du pack', windows: 'Moteur WebView2 de Windows', apercu: 'Navigateur (aperçu)' };

// Each tab groups its lines by subject (same lines as before, more air between them).
function panelGroups(id, s, app, summary, sim) {
  if (id === 'session') {
    if (!s) return [{ title: 'Session', icon: 'shield', rows: [['Session', 'Indisponible']] }];
    return [
      { title: 'Annuaire', icon: 'server', rows: [
        ['Domaine', s.domain?.dnsName ?? 'Non connecté', s.domain?.netbiosName ? `NetBIOS ${s.domain.netbiosName}` : ''],
        ['Contrôleur de domaine', s.controller?.dnsName ?? 'Non connecté', s.controller?.site ? `Site ${s.controller.site}` : ''],
        ['Racine de l’annuaire', s.domain?.rootDn ?? '—'],
        ['Connexion', s.connection?.label],
      ] },
      { title: 'Compte et droits', icon: 'user', rows: [
        ['Compte utilisé pour l’annuaire', s.account?.login, s.account?.displayName ?? ''],
        ['Mode de connexion', s.authentication?.label],
        ['Estimation des droits', s.rights?.label, s.rights?.detail ?? ''],
        ['Lecture seule', s.readOnly ? 'Activée' : 'Désactivée'],
      ] },
      { title: 'Périmètre et tâches', icon: 'folder', rows: [
        ['OU de travail', s.scope?.label ?? 'Aucune OU choisie', s.scope ? pathOf(s.scope.dn, s.domain?.dnsName) : ''],
        ['Branche affichée', s.scope?.dn ?? 'Aucune OU choisie', s.scope ? (s.scope.subtree ? 'Sous-OU comprises' : 'Cette OU seulement') : ''],
        ['Tâches', `${formatNumber(s.tasks?.running ?? 0)} en cours · ${formatNumber(s.tasks?.queued ?? 0)} en attente`],
      ] },
    ];
  }
  if (id === 'application') {
    if (!app) return [{ title: 'Application', icon: 'info', rows: [['Application', 'Informations indisponibles']] }];
    const chromium = /Chrome\/([\d.]+)/.exec(navigator.userAgent)?.[1];
    // The engine's banner text is shown as is (null in directory mode, OPERATIONS.md § 2).
    const banner = typeof app.banner === 'string' && app.banner ? [['Bannière', app.banner]] : [];
    const theme = document.documentElement.dataset.theme;
    const motion = document.documentElement.dataset.motion;
    return [
      { title: 'Domenia', icon: 'logo', rows: [
        ['Application', `${app.name} ${app.version}`],
        ['Mode', app.modeLabel ?? app.mode, app.modeDetail ?? ''],
        ...banner,
      ] },
      { title: 'Moteurs', icon: 'chip', rows: [
        ['Moteur web', ENGINES[app.webViewRuntime] ?? app.webViewRuntime, chromium ? `Chromium ${chromium}` : ''],
        ['.NET embarqué', app.runtime],
      ] },
      { title: 'Affichage', icon: 'sparkles', rows: [
        ['Thème', theme === 'dark' ? 'Thème sombre' : theme === 'contrast' ? 'Contraste élevé' : 'Thème clair'],
        ['Animations', motion === 'reduced' ? 'Animations réduites' : motion === 'system' ? 'Animations : suivre Windows' : 'Animations riches'],
      ] },
    ];
  }
  const store = summary?.store;
  const cache = s?.cache;
  const read = [
    ['État', cache?.label ?? '—'],
    [sim ? 'Lecture de l’annuaire fictif' : 'Dernière lecture de l’annuaire', formatDateTime(store?.lastReadAt ?? cache?.lastReadAt) ?? 'Jamais', relTime(store?.lastReadAt ?? cache?.lastReadAt) ?? ''],
    [sim ? 'Objets de l’annuaire fictif' : 'Objets enregistrés', formatNumber(store?.objects ?? cache?.objects ?? 0)],
    ['Lecture complète', (store?.complete ?? cache?.complete) ? 'Oui' : 'Non : chiffres possiblement sous-estimés'],
  ];
  const board = [
    ['OU de travail', summary?.scope?.label ?? s?.scope?.label ?? '—', summary?.scope?.dn ?? s?.scope?.dn ?? ''],
    ['Tableau de bord calculé', formatDateTime(summary?.generatedAt) ?? '—',
      summary ? (sim ? 'Depuis l’annuaire fictif en mémoire, sans lecture réseau' : 'Depuis la base locale, sans lecture réseau') : ''],
  ];
  if (sim) board.push(['Base locale', 'Jamais ouverte en simulation', 'Aucune donnée fictive n’y entre']);
  return [
    { title: sim ? 'Annuaire fictif' : 'Lecture de l’annuaire', icon: 'database', rows: read },
    { title: 'Tableau de bord', icon: 'activity', rows: board },
  ];
}

function sessionMarkup(sim) {
  const tabs = PANELS.map((p, n) => `<button type="button" role="tab" id="tab-${p.id}" aria-controls="panel-${p.id}" aria-selected="${n === 0}" tabindex="${n === 0 ? 0 : -1}">${esc(panelLabel(p, sim))}</button>`).join('');
  const panels = PANELS.map((p, n) => `<div class="tab-panel" role="tabpanel" id="panel-${p.id}" aria-labelledby="tab-${p.id}"${n ? ' hidden' : ''}><div class="kv-groups"></div></div>`).join('');
  return `<div class="card-head"><span class="card-icon">${icon('shield')}</span>
      <div class="head-titles"><h3>Session et vérifications</h3><span class="head-sub">Informations déjà chargées, sans lecture réseau</span></div></div>
    <div class="tabs" role="tablist" aria-label="Session et vérifications">${tabs}<span class="ink" aria-hidden="true"></span></div>
    ${panels}
    <div class="card-actions">
      <button class="btn" type="button" data-act="check">${icon('shield')}Vérifier l’application</button>
      <button class="btn" type="button" data-act="cache">${icon('trash')}Vider le cache</button>
      <button class="btn" type="button" data-act="journal">${icon('file')}Ouvrir le journal</button>
      <span class="spacer"></span>
      <button class="btn ghost" type="button" data-act="copy">${icon('copy')}Copier</button>
    </div>`;
}

// ---------- « Choisir l’OU » side panel ----------

const countsText = (c) => [plural(c.users, 'utilisateur', 'utilisateurs'), plural(c.computers, 'ordinateur', 'ordinateurs'), plural(c.groups, 'groupe', 'groupes')].join(', ');
const validCounts = (c) => c && isNum(c.users) && isNum(c.computers) && isNum(c.groups);
const validOu = (o) => o && typeof o.dn === 'string' && o.dn && typeof o.name === 'string';

function countsMarkup(c) {
  if (!validCounts(c)) return '';
  const item = (n, ic, one, many, cls) => `<span class="ou-cnt ${cls}${n ? '' : ' zero'}" data-tip="${esc(plural(n, one, many))}">${glyph(ic)}${formatNumber(n)}</span>`;
  return `<span class="ou-counts" aria-hidden="true">${item(c.users, 'user', 'utilisateur', 'utilisateurs', 'u')}${item(c.computers, 'monitor', 'ordinateur', 'ordinateurs', 'c')}${item(c.groups, 'group', 'groupe', 'groupes', 'g')}</span>`
    + `<span class="visually-hidden">, ${esc(countsText(c))}</span>`;
}

// Panel over the page (never a new window): tree read level by level with directory.ou.children (a closed branch is
// never read), search with directory.ou.search, and session.setScope on « Appliquer ». The tree stays in memory while
// the Accueil is shown; « Relire » reads it again.
function createOuPanel({ ctx, current, onApplied, fallbackFocus }) {
  let layer = null;
  let panel = null;
  let tree = null;
  let results = null;
  let input = null;
  let applyBtn = null;
  let subBox = null;
  let release = null;
  let opener = null;
  let isOpen = false;
  let busy = false;
  let root = null;
  let selected = null; // { dn, name, path, counts }
  let subtree = true;
  let hits = [];
  let treeToken = 0;
  let searchToken = 0;
  let seq = 0;
  const nodes = new Map(); // lower-case DN → node

  const sim = () => isSimulated(current().session, current().app);
  const nodeOf = (el) => (el instanceof Element ? nodes.get(el.closest('[role="treeitem"]')?.dataset.key ?? '') ?? null : null);
  const visibleItems = () => [...tree.querySelectorAll('[role="treeitem"]')].filter((el) => !el.parentElement.closest('[role="group"][hidden]'));

  function makeNode(o, level, isRoot = false) {
    seq += 1;
    const node = {
      id: `ou-n-${seq}`, key: o.dn.toLowerCase(), dn: o.dn, name: o.name, path: typeof o.path === 'string' ? o.path : '',
      hasChildren: isRoot || Boolean(o.hasChildren), counts: validCounts(o.counts) ? o.counts : null, level, isRoot,
      el: null, group: null, loaded: false, loading: null, expanded: false,
    };
    nodes.set(node.key, node);
    return node;
  }

  function nodeMarkup(n, j) {
    const twisty = n.hasChildren ? glyph('chevronRight') : '';
    return `<div class="ou-node${n.isRoot ? ' root' : ''}" role="treeitem" id="${n.id}" aria-level="${n.level}"${n.hasChildren ? ' aria-expanded="false"' : ''} aria-selected="false" tabindex="-1" data-key="${esc(n.key)}">
      <div class="ou-row" data-lvl="${n.level - 1}" data-j="${Math.min(j, 16)}">
        <span class="ou-twisty${n.hasChildren ? '' : ' leaf'}" aria-hidden="true">${twisty}</span>
        <span class="ou-ico" aria-hidden="true">${n.isRoot ? glyph('domain') : glyph('ou')}</span>
        <span class="ou-name">${esc(n.name)}</span>
        ${n.isRoot ? '<span class="ou-tag root-tag">Domaine</span>' : '<span class="ou-tag now-tag" hidden>Actuelle</span>'}
        ${n.counts ? countsMarkup(n.counts) : ''}
      </div>
      ${n.hasChildren ? '<div class="ou-group" role="group" hidden></div>' : ''}
    </div>`;
  }

  function attach(scope) {
    scope.querySelectorAll('[role="treeitem"]').forEach((el) => {
      const n = nodes.get(el.dataset.key);
      if (!n) return;
      n.el = el;
      n.group = el.querySelector(':scope > [role="group"]');
    });
    paint(scope);
  }

  // Selected OU (aria-selected), current working OU (« Actuelle ») and the roving tab stop.
  function refreshMarks() {
    const cur = current().session?.scope?.dn;
    nodes.forEach((n) => {
      if (!n.el) return;
      const on = Boolean(selected && sameDn(selected.dn, n.dn));
      n.el.setAttribute('aria-selected', String(on));
      n.el.classList.toggle('is-current', Boolean(cur && sameDn(cur, n.dn)));
      const tag = n.el.querySelector(':scope > .ou-row .now-tag');
      if (tag) tag.hidden = !(cur && sameDn(cur, n.dn));
    });
    if (!tree.querySelector('[role="treeitem"][tabindex="0"]')) {
      const first = tree.querySelector('[role="treeitem"][aria-selected="true"]') ?? tree.querySelector('[role="treeitem"]');
      first?.setAttribute('tabindex', '0');
    }
  }

  function setActive(node, focus = false) {
    if (!node?.el) return;
    tree.querySelectorAll('[role="treeitem"][tabindex="0"]').forEach((el) => { if (el !== node.el) el.tabIndex = -1; });
    node.el.tabIndex = 0;
    if (focus) node.el.focus({ preventScroll: true });
    node.el.querySelector(':scope > .ou-row')?.scrollIntoView({ block: 'nearest' });
  }

  function skeletonRows(n) {
    return Array.from({ length: n }, (_, k) => `<div class="ou-skel" role="none" data-j="${k}"><span class="skeleton sk sk-line ${['w55', 'w40', 'w70', 'w55', 'w40'][k % 5]}"></span></div>`).join('');
  }

  function errorBlock(err, retry) {
    return `<div class="ou-err" role="none">${icon('alert')}<span>${esc(reported(err))}</span><button class="btn sm" type="button" ${retry}>${icon('refresh')}Réessayer</button></div>`;
  }

  function reported(err) {
    if (!err?.code) console.error(err);
    return errorText(err);
  }

  function renderChildren(parent, list) {
    const kids = list.filter(validOu).map((o) => makeNode(o, parent.level + 1));
    if (!kids.length) {
      // Announced with sub-OU but none came back: the branch becomes a leaf.
      parent.hasChildren = false;
      parent.el.removeAttribute('aria-expanded');
      const twisty = parent.el.querySelector(':scope > .ou-row .ou-twisty');
      if (twisty) { twisty.classList.add('leaf'); twisty.innerHTML = ''; }
      parent.group.innerHTML = '';
      parent.group.hidden = true;
      return;
    }
    parent.group.innerHTML = kids.map((k, j) => nodeMarkup(k, j)).join('');
    attach(parent.group);
    refreshMarks();
  }

  function load(node) {
    if (node.loading) return node.loading;
    node.group.setAttribute('aria-busy', 'true');
    node.group.innerHTML = skeletonRows(2);
    paint(node.group);
    const my = treeToken;
    node.loading = (async () => {
      try {
        const r = await ctx.call('directory.ou.children', { dn: node.dn });
        if (my !== treeToken) return;
        renderChildren(node, Array.isArray(r?.children) ? r.children : []);
        node.loaded = true;
      } catch (err) {
        if (my !== treeToken) return;
        node.group.innerHTML = errorBlock(err, `data-ou-retry="${esc(node.key)}"`);
      } finally {
        node.group?.removeAttribute('aria-busy');
        node.loading = null;
      }
    })();
    return node.loading;
  }

  async function expand(node) {
    if (!node?.hasChildren || !node.group) return;
    node.expanded = true;
    node.el.setAttribute('aria-expanded', 'true');
    node.group.hidden = false;
    if (!node.loaded) await load(node);
  }

  function collapse(node) {
    if (!node?.hasChildren || !node.group) return;
    node.expanded = false;
    node.el.setAttribute('aria-expanded', 'false');
    node.group.hidden = true;
  }

  async function loadRoot() {
    const my = ++treeToken;
    nodes.clear();
    root = null;
    tree.setAttribute('aria-busy', 'true');
    tree.innerHTML = skeletonRows(6);
    paint(tree);
    try {
      const r = await ctx.call('directory.ou.children', { dn: null });
      if (my !== treeToken) return false;
      const s = current().session;
      const p = r?.parent ?? {};
      const dn = typeof p.dn === 'string' && p.dn ? p.dn : s?.domain?.rootDn ?? 'DC=';
      const name = typeof p.name === 'string' && p.name ? p.name : s?.domain?.dnsName ?? 'Domaine';
      root = makeNode({ dn, name, path: typeof p.path === 'string' ? p.path : name, hasChildren: true }, 1, true);
      tree.innerHTML = nodeMarkup(root, 0);
      attach(tree);
      root.expanded = true;
      root.el.setAttribute('aria-expanded', 'true');
      root.group.hidden = false;
      renderChildren(root, Array.isArray(r?.children) ? r.children : []);
      root.loaded = true;
      refreshMarks();
      return true;
    } catch (err) {
      if (my !== treeToken) return false;
      tree.innerHTML = errorBlock(err, 'data-ou-retry-root');
      return false;
    } finally {
      if (my === treeToken) tree.removeAttribute('aria-busy');
    }
  }

  // Opens the branches down to an OU (its parents are read one by one, only if needed) and returns its node.
  async function revealDn(dn) {
    if (!root) return null;
    if (!dn || sameDn(dn, root.dn)) return root;
    const info = dnChain(dn, root.name);
    let node = root;
    for (const step of info?.chain ?? []) {
      await expand(node);
      const next = nodes.get(step.dn.toLowerCase());
      if (!next) break;
      node = next;
    }
    return node;
  }

  function select(node) {
    if (!node) return;
    if (node.isRoot) {
      showError('Choisissez une OU : le domaine entier ne peut pas être l’OU de travail, la mesure des postes n’est jamais lancée sur tout le domaine.', 'info');
      setActive(node, true);
      return;
    }
    hideError();
    selected = { dn: node.dn, name: node.name, path: node.path, counts: node.counts };
    refreshMarks();
    setActive(node, true);
    updateFoot();
    announce(`OU sélectionnée : ${node.name}`);
  }

  function showError(text, tone = 'alert') {
    const box = panel.querySelector('.ou-error');
    box.dataset.tone = tone;
    box.querySelector('span').textContent = text;
    box.hidden = false;
    box.classList.remove('shake');
    void box.offsetWidth;
    box.classList.add('shake');
  }

  function hideError() {
    panel.querySelector('.ou-error').hidden = true;
  }

  function updateFoot() {
    const cur = current().session?.scope ?? null;
    const pick = panel.querySelector('.ou-pick');
    if (selected) {
      const path = selected.path || pathOf(selected.dn, root?.name);
      pick.innerHTML = `<span class="ou-pick-k">Sélection</span>
        <span class="ou-pick-name">${glyph('ou')}<b>${esc(selected.name)}</b>${countsMarkup(selected.counts)}</span>
        <span class="ou-pick-path"><span class="txt" data-tip="${esc(selected.dn)}">${esc(path)}</span>
        <button class="btn ghost icon sm" type="button" data-ou-copy aria-label="Copier le DN de l’OU sélectionnée" data-tip="Copier le chemin LDAP (DN)">${icon('copy')}</button></span>`;
    } else {
      pick.innerHTML = '<span class="ou-pick-k">Sélection</span><span class="ou-pick-none">Aucune OU sélectionnée : choisissez-en une dans l’arborescence ou par la recherche.</span>';
    }
    paint(pick);
    const same = Boolean(selected && cur && sameDn(selected.dn, cur.dn) && cur.subtree === subtree);
    applyBtn.disabled = !selected || same || busy;
    const effect = panel.querySelector('.ou-effect');
    if (!selected) effect.textContent = '';
    else if (same) effect.textContent = 'C’est déjà l’OU de travail : rien à changer.';
    else {
      effect.textContent = `Les widgets de postes porteront sur l’OU ${selected.name}${subtree ? ' et ses sous-OU' : ' seule, sans ses sous-OU'} ; `
        + `les comptes restent comptés sur tout le domaine. Aucune lecture réseau : l’Accueil se recalcule depuis ${sim() ? 'l’annuaire fictif en mémoire' : 'la base locale'}.`;
    }
    effect.classList.remove('flash');
    void effect.offsetWidth;
    effect.classList.add('flash');
  }

  function nowLine() {
    const s = current().session;
    const cur = s?.scope;
    panel.querySelector('.ou-now').innerHTML = cur
      ? `<span class="k">OU actuelle</span><b>${esc(cur.label)}</b><span class="faint">${esc(pathOf(cur.dn, s.domain?.dnsName))} · ${cur.subtree ? 'sous-OU comprises' : 'cette OU seulement'}</span>`
      : '<span class="k">OU actuelle</span><b>Aucune</b><span class="faint">la mesure des postes attend une OU</span>';
  }

  function showTree() {
    results.hidden = true;
    results.innerHTML = '';
    tree.hidden = false;
    hits = [];
    panel.querySelector('.ou-search').classList.remove('searching');
  }

  function renderHits(list, text, truncated) {
    hits = list;
    const wanted = fold(text);
    if (!list.length) {
      results.innerHTML = `<div class="ou-empty">${icon('search')}<p>Aucune OU ne contient «${NBSP}${esc(text)}${NBSP}».</p></div>`;
      announce('Aucune OU trouvée.');
      return;
    }
    const head = `${plural(list.length, 'OU trouvée', 'OU trouvées')}${truncated ? ` : d’autres peuvent correspondre, précisez la recherche` : ''}`;
    results.innerHTML = `<p class="ou-hits-k">${esc(head)}</p><ul class="ou-hits cascade" aria-label="Résultats de la recherche">${list.map((o, n) => `<li data-j="${Math.min(n, 14)}">`
      + `<button class="ou-hit" type="button" data-n="${n}">${glyph('ou')}<span class="ou-hit-text"><span class="ou-hit-name">${highlight(o.name, wanted)}</span>`
      + `<span class="ou-hit-path">${highlight(o.path ?? '', wanted)}</span></span>${countsMarkup(o.counts)}</button></li>`).join('')}</ul>`;
    paint(results);
    announce(head);
  }

  const runSearch = debounce(async (text) => {
    const my = ++searchToken;
    tree.hidden = true;
    results.hidden = false;
    results.setAttribute('aria-busy', 'true');
    results.innerHTML = skeletonRows(4);
    paint(results);
    panel.querySelector('.ou-search').classList.add('searching');
    try {
      const r = await ctx.call('directory.ou.search', { text });
      if (my !== searchToken || !isOpen) return;
      const list = (Array.isArray(r) ? r : Array.isArray(r?.results) ? r.results : Array.isArray(r?.items) ? r.items : []).filter(validOu);
      // The engine answers a bare array (OPERATIONS.md § 10); { results, truncated } is still read.
      renderHits(list, text, r?.truncated === true || list.length >= OU_SEARCH_LIMIT);
    } catch (err) {
      if (my !== searchToken || !isOpen) return;
      results.innerHTML = errorBlock(err, 'data-ou-retry-search');
    } finally {
      if (my === searchToken) {
        results.removeAttribute('aria-busy');
        panel.querySelector('.ou-search').classList.remove('searching');
      }
    }
  }, 220);

  function onInput() {
    const text = input.value.trim();
    if (!text) { runSearch.cancel(); searchToken += 1; showTree(); return; }
    runSearch(text);
  }

  async function chooseHit(o) {
    hideError();
    selected = { dn: o.dn, name: o.name, path: o.path ?? '', counts: validCounts(o.counts) ? o.counts : null };
    updateFoot();
    input.value = '';
    runSearch.cancel();
    searchToken += 1;
    showTree();
    const node = await revealDn(o.dn);
    if (!isOpen) return;
    refreshMarks();
    if (node && sameDn(node.dn, o.dn)) setActive(node, true);
    announce(`OU sélectionnée : ${o.name}`);
  }

  async function apply() {
    if (!selected || busy) return;
    busy = true;
    hideError();
    applyBtn.disabled = true;
    applyBtn.classList.add('spinning');
    try {
      const session = await ctx.call('session.setScope', { dn: selected.dn, subtree });
      if (!isOpen) return;
      applyBtn.classList.remove('spinning');
      applyBtn.classList.add('done');
      await close();
      await onApplied(session);
    } catch (err) {
      if (isOpen) showError(reported(err));
      else ctx.toast(reported(err), { tone: 'alert' });
    } finally {
      busy = false;
      applyBtn.classList.remove('spinning', 'done');
      if (isOpen) updateFoot();
    }
  }

  function onTreeKey(e) {
    const node = nodeOf(document.activeElement);
    if (!node) return;
    const items = visibleItems();
    const at = items.indexOf(node.el);
    const go = (el) => { const n = nodeOf(el); if (n) setActive(n, true); };
    switch (e.key) {
      case 'ArrowDown': go(items[Math.min(items.length - 1, at + 1)]); break;
      case 'ArrowUp': go(items[Math.max(0, at - 1)]); break;
      case 'Home': go(items[0]); break;
      case 'End': go(items.at(-1)); break;
      case 'ArrowRight':
        if (node.hasChildren && !node.expanded) expand(node);
        else if (node.expanded) {
          const first = node.group?.querySelector(':scope > [role="treeitem"]');
          if (first) go(first);
        }
        break;
      case 'ArrowLeft':
        if (node.expanded && !node.isRoot) collapse(node);
        else go(node.el.parentElement.closest('[role="treeitem"]'));
        break;
      case 'Enter':
      case ' ':
        select(node);
        break;
      default: return;
    }
    e.preventDefault();
  }

  function onHitKey(e) {
    const buttons = [...results.querySelectorAll('.ou-hit')];
    const at = buttons.indexOf(document.activeElement);
    if (at < 0) return;
    if (e.key === 'ArrowDown') { buttons[Math.min(buttons.length - 1, at + 1)].focus(); e.preventDefault(); }
    else if (e.key === 'ArrowUp') { (at === 0 ? input : buttons[at - 1]).focus(); e.preventDefault(); }
  }

  function onInputKey(e) {
    if (e.key !== 'ArrowDown') return;
    const first = results.hidden ? tree.querySelector('[role="treeitem"][tabindex="0"]') : results.querySelector('.ou-hit');
    if (first) { first.focus(); e.preventDefault(); }
  }

  function onClick(e) {
    const t = e.target instanceof Element ? e.target : null;
    if (!t) return;
    if (t.closest('[data-ou-close]')) { close(); return; }
    if (t.closest('[data-ou-apply]')) { apply(); return; }
    if (t.closest('[data-ou-reload]')) { reloadTree(); return; }
    if (t.closest('[data-ou-copy]')) {
      if (selected) copyText(selected.dn).then((ok) => ctx.toast(ok ? 'DN de l’OU copié dans le presse-papiers.' : 'Copie impossible : le presse-papiers est indisponible.', { tone: ok ? 'ok' : 'warn', life: 2600 }));
      return;
    }
    if (t.closest('[data-ou-retry-root]')) { reloadTree(); return; }
    if (t.closest('[data-ou-retry-search]')) { onInput(); return; }
    const retry = t.closest('[data-ou-retry]');
    if (retry) { const n = nodes.get(retry.dataset.ouRetry); if (n) load(n); return; }
    const hit = t.closest('.ou-hit');
    if (hit) { const o = hits[Number(hit.dataset.n)]; if (o) chooseHit(o); return; }
    const twisty = t.closest('.ou-twisty');
    const node = nodeOf(t);
    if (!node) return;
    if (twisty && node.hasChildren) {
      if (node.expanded && !node.isRoot) collapse(node); else expand(node);
      setActive(node, true);
      return;
    }
    if (t.closest('.ou-row')) select(node);
  }

  function onDouble(e) {
    const node = nodeOf(e.target);
    if (node?.hasChildren && !node.isRoot) { if (node.expanded) collapse(node); else expand(node); }
  }

  // Modal surface: the application shortcuts wait until the panel is closed; Échap clears the search, then closes.
  function onKeys(e) {
    if (!isOpen) return;
    const mod = e.ctrlKey || e.metaKey;
    const key = e.key.toLowerCase();
    if ((mod && !e.altKey && ['k', 'p', 'b'].includes(key)) || (e.altKey && !mod && /^Digit[1-9]$/.test(e.code))) {
      e.preventDefault();
      e.stopPropagation();
      return;
    }
    if (e.key !== 'Escape') return;
    e.preventDefault();
    e.stopPropagation();
    if (document.activeElement === input && input.value) { input.value = ''; onInput(); return; }
    close();
  }

  function build() {
    layer = document.createElement('div');
    layer.className = 'k-surface ou-layer';
    layer.hidden = true;
    layer.innerHTML = `<div class="ou-backdrop" data-ou-close></div>
      <aside class="ou-panel" role="dialog" aria-modal="true" aria-labelledby="ou-title" aria-describedby="ou-desc" tabindex="-1">
        <span class="ou-glow" aria-hidden="true"></span>
        <header class="ou-head">
          <span class="ou-head-icon">${glyph('ou')}</span>
          <div class="ou-titles"><h2 id="ou-title">Choisir l’OU de travail</h2>
            <p id="ou-desc">Elle sert de défaut à toutes les sections sans choix propre. Le choix est gardé dans les préférences de Domenia, jamais dans l’annuaire.</p></div>
          <button class="btn ghost icon sm" type="button" data-ou-reload aria-label="Relire l’arborescence" data-tip="Relire l’arborescence">${icon('refresh')}</button>
          <button class="btn ghost icon sm" type="button" data-ou-close aria-label="Fermer" data-tip="Fermer (Échap)">${icon('x')}</button>
        </header>
        <div class="ou-now"></div>
        <div class="ou-search">${icon('search')}<input class="ou-input" type="search" placeholder="Rechercher une OU par nom ou chemin" aria-label="Rechercher une OU par nom ou par chemin" autocomplete="off" spellcheck="false" maxlength="100"><span class="ou-spin" aria-hidden="true"></span></div>
        <div class="ou-body">
          <div class="ou-tree" role="tree" aria-label="Arborescence des OU"></div>
          <div class="ou-results" hidden></div>
        </div>
        <footer class="ou-foot">
          <div class="ou-pick"></div>
          <label class="ou-sub"><input class="switch" type="checkbox" data-ou-subtree><span>Inclure les sous-OU</span></label>
          <p class="ou-effect"></p>
          <p class="ou-error" role="alert" hidden>${icon('info')}<span></span></p>
          <div class="ou-actions"><button class="btn ghost" type="button" data-ou-close>Annuler</button>
            <button class="btn primary" type="button" data-ou-apply>${icon('check')}<span>Appliquer</span></button></div>
        </footer>
      </aside>`;
    document.body.appendChild(layer);
    panel = layer.querySelector('.ou-panel');
    tree = layer.querySelector('.ou-tree');
    results = layer.querySelector('.ou-results');
    input = layer.querySelector('.ou-input');
    applyBtn = layer.querySelector('[data-ou-apply]');
    subBox = layer.querySelector('[data-ou-subtree]');
    layer.addEventListener('click', onClick);
    tree.addEventListener('dblclick', onDouble);
    tree.addEventListener('keydown', onTreeKey);
    results.addEventListener('keydown', onHitKey);
    input.addEventListener('input', onInput);
    input.addEventListener('keydown', onInputKey);
    subBox.addEventListener('change', () => { subtree = subBox.checked; updateFoot(); });
  }

  async function reloadTree() {
    const keep = selected?.dn;
    const ok = await loadRoot();
    if (!ok || !isOpen) return;
    const node = await revealDn(keep ?? current().session?.scope?.dn);
    refreshMarks();
    if (node) setActive(node);
  }

  async function open({ opener: from = null, revealDn: target = null } = {}) {
    if (isOpen) return;
    if (!layer) build();
    opener = from ?? document.activeElement;
    isOpen = true;
    const s = current().session;
    const cur = s?.scope ?? null;
    subtree = cur ? cur.subtree !== false : true;
    subBox.checked = subtree;
    selected = cur ? { dn: cur.dn, name: cur.label, path: pathOf(cur.dn, s.domain?.dnsName), counts: null } : null;
    input.value = '';
    showTree();
    hideError();
    nowLine();
    updateFoot();
    layer.classList.remove('leaving');
    layer.hidden = false;
    pushModal(layer);
    release = trapFocus(panel);
    window.addEventListener('keydown', onKeys, true);
    input.focus({ preventScroll: true });
    if (!root) {
      const ok = await loadRoot();
      if (!ok || !isOpen) return;
    } else {
      refreshMarks();
    }
    const node = await revealDn(target ?? cur?.dn ?? null);
    if (!isOpen) return;
    // The selected OU may now carry its counts (read with its level).
    const sel = selected ? nodes.get(selected.dn.toLowerCase()) : null;
    if (sel && !selected.counts && sel.counts) { selected.counts = sel.counts; selected.path = sel.path || selected.path; updateFoot(); }
    refreshMarks();
    if (node) setActive(node);
  }

  async function close() {
    if (!isOpen) return;
    isOpen = false;
    window.removeEventListener('keydown', onKeys, true);
    runSearch.cancel();
    searchToken += 1;
    release?.();
    release = null;
    await leave(layer, 520);
    if (isOpen) return; // reopened during the animation
    layer.hidden = true;
    layer.classList.remove('leaving');
    popModal(layer);
    const back = opener?.isConnected ? opener : fallbackFocus?.();
    back?.focus({ preventScroll: true });
  }

  function destroy() {
    window.removeEventListener('keydown', onKeys, true);
    runSearch.cancel();
    release?.();
    if (layer) {
      if (isOpen) popModal(layer);
      layer.remove();
    }
    isOpen = false;
    treeToken += 1;
    searchToken += 1;
  }

  return { open, close, destroy, isOpen: () => isOpen };
}

// ---------- Page ----------

export function render(main, ctx) {
  const st = { session: null, summary: null, app: null, widgets: {}, alive: true, refreshing: false };
  const pending = new Map();
  const busy = new Map(); // widget id → measurements in flight
  const toggling = new Set(); // widgets whose « Mesure active » change is not confirmed yet
  const stops = [];
  let ink = null;
  let ticker = 0;

  const sim = () => isSimulated(st.session, st.app);
  const stagger = () => cssMs('--stagger', 55);
  const shown = (el) => !(el.classList.contains('reveal') && !el.classList.contains('in'));
  const whenShown = (el, fn) => { if (shown(el)) fn(0); else pending.set(el, fn); };
  const startReveal = (scope) => stops.push(reveal(scope, {
    onIn: (el, n) => { const fn = pending.get(el); if (fn) { pending.delete(el); fn(n); } },
  }));

  function runCounters(scope, previous, n = 0) {
    scope.querySelectorAll('[data-count]').forEach((el, k) => {
      const to = Number(el.dataset.count);
      const before = previous?.get(k);
      const from = Number.isFinite(before) ? before : 0; // a missing measure ("NaN") counts from 0
      countUp(el, to, { decimals: Number(el.dataset.dec ?? 0), suffix: el.dataset.suffix ?? '', from, delay: n * stagger() + 160 });
    });
  }

  function currentValues(card) {
    const map = new Map();
    card.querySelectorAll('[data-count]').forEach((el, k) => map.set(k, Number(el.dataset.count)));
    return map;
  }

  // Operator text of an error; browser errors (no code) are logged, their English message is not shown.
  function reported(err) {
    if (!err?.code) console.error(err);
    return errorText(err);
  }

  // ----- Widgets -----

  // Widget ids come from the bridge: escaped before they enter a selector.
  const cardOf = (id) => main.querySelector(`[data-widget="${CSS.escape(String(id))}"]`);

  function paintWidget(w, { bump = false } = {}) {
    const card = w && typeof w === 'object' ? cardOf(w.id) : null;
    if (!card) return;
    if (!bump && st.widgets[w.id] && !card.classList.contains('is-broken')
      && JSON.stringify(st.widgets[w.id]) === JSON.stringify(w)) return; // unchanged
    const previous = card.querySelector('[data-count]') ? currentValues(card) : null;
    st.widgets[w.id] = w;
    try {
      card.classList.remove('is-broken');
      card.dataset.tone = w.tone;
      card.classList.toggle('is-off', !w.enabled);
      card.classList.toggle('is-stale', w.enabled && w.stale);
      card.innerHTML = w.kind === 'kpi' ? kpiCard(w) : chartCard(w);
      paint(card);
      if (w.id === 'osDistribution') bindLegend(card);
    } catch (err) {
      // One unexpected widget must not take the whole dashboard down: only its own card shows the problem.
      console.error(`Widget « ${w.id} » : affichage impossible`, err, w);
      paintBroken(card, w);
      syncCard(w.id);
      return;
    }
    syncCard(w.id);
    whenShown(card, (n) => runCounters(card, previous, n));
    if (bump) card.querySelector('.value')?.classList.add('bump');
  }

  function paintBroken(card, w) {
    card.classList.add('is-broken');
    card.classList.remove('is-off', 'is-stale');
    card.dataset.tone = 'warn';
    const retry = w.enabled ? `<button class="btn sm" type="button" data-refresh>${icon('refresh')}Actualiser</button>` : '';
    card.innerHTML = `<div class="card-head"><span class="card-icon">${icon('alert')}</span><div class="head-titles"><h3>${esc(w.title ?? 'Widget')}</h3></div></div>
      <div class="card-body"><div class="off-note">${icon('alert')}<span>Données inattendues : ce widget ne peut pas s’afficher.
        Les autres widgets ne sont pas concernés.</span>${retry}</div></div>`;
    applyVars(card);
  }

  function bindLegend(card) {
    const ring = card.querySelector('.ring');
    const segs = ring ? [...ring.querySelectorAll('circle[data-key]')] : [];
    card.querySelectorAll('.legend li[data-key]').forEach((li) => {
      // Compare keys instead of building a selector from them (any character may appear in a key).
      const seg = segs.find((c) => c.dataset.key === li.dataset.key);
      const on = () => { ring?.classList.add('has-focus'); seg?.classList.add('focus'); li.classList.add('focus'); };
      const off = () => { ring?.classList.remove('has-focus'); seg?.classList.remove('focus'); li.classList.remove('focus'); };
      li.addEventListener('pointerenter', on);
      li.addEventListener('pointerleave', off);
      li.addEventListener('focus', on);
      li.addEventListener('blur', off);
    });
  }

  // Refresh buttons are locked while the widget is measured or while its « Mesure active » change is pending.
  function syncCard(id) {
    const card = cardOf(id);
    if (!card) return;
    const measuring = (busy.get(id) ?? 0) > 0;
    card.querySelectorAll('[data-refresh]').forEach((b) => {
      b.classList.toggle('spinning', measuring);
      b.disabled = measuring || toggling.has(id);
    });
    card.querySelectorAll('[data-toggle]').forEach((t) => { t.disabled = toggling.has(id); });
    card.querySelector('.card-body')?.classList.toggle('updating', measuring);
    card.classList.toggle('measuring', measuring);
  }

  function setCardBusy(id, on) {
    const n = Math.max(0, (busy.get(id) ?? 0) + (on ? 1 : -1));
    if (n) busy.set(id, n); else busy.delete(id);
    syncCard(id);
  }

  // Keyboard position inside a card, kept across a repaint (the card's inner HTML is replaced).
  function focusKey(card) {
    const a = document.activeElement;
    if (!card || !(a instanceof Element) || !card.contains(a)) return null;
    if (a.matches('[data-toggle]')) return '[data-toggle]';
    if (a.matches('[data-refresh]')) return '[data-refresh]';
    return null;
  }

  function restoreFocus(id, key) {
    const card = cardOf(id);
    if (!key || !card) return;
    const a = document.activeElement;
    if (a instanceof Element && card.contains(a)) return; // still in place
    if (a && a !== document.body && a !== main) return; // the operator has moved on
    const el = card.querySelector(`${key}:not(:disabled)`) ?? card.querySelector('[data-refresh]:not(:disabled), [data-toggle]:not(:disabled)');
    el?.focus({ preventScroll: true });
  }

  // Result: 'ok', 'failed', or 'skipped' (widget disabled meanwhile: nothing published, OPERATIONS.md § 7).
  async function refreshWidget(id, { quiet = false } = {}) {
    const key = focusKey(cardOf(id));
    setCardBusy(id, true);
    try {
      const w = await ctx.call('dashboard.widget.refresh', { id });
      if (!st.alive) return 'ok';
      setCardBusy(id, false);
      if (w?.enabled === false) {
        paintWidget(w);
        restoreFocus(id, key);
        if (!quiet) ctx.toast(`${w.title} : mesure désactivée pendant l’actualisation, rien n’a été publié.`, { tone: 'info' });
        return 'skipped';
      }
      paintWidget(w, { bump: true });
      restoreFocus(id, key);
      if (!quiet) ctx.toast(`${w.title} : mesure actualisée.`, { tone: 'ok', life: 3000 });
      return 'ok';
    } catch (err) {
      if (!st.alive) return 'failed';
      setCardBusy(id, false);
      restoreFocus(id, key);
      ctx.toast(reported(err), { tone: err?.code === 'widget.disabled' || err?.code === 'scope.tooWide' ? 'warn' : 'alert' });
      return 'failed';
    }
  }

  async function toggleWidget(input) {
    const card = input.closest('[data-widget]');
    const id = card.dataset.widget;
    const enabled = input.checked;
    const key = focusKey(card);
    toggling.add(id);
    syncCard(id);
    const settle = (checked) => {
      const fresh = cardOf(id)?.querySelector('[data-toggle]');
      if (fresh) fresh.checked = checked;
      restoreFocus(id, key);
    };
    try {
      const w = await ctx.call('dashboard.widget.setEnabled', { id, enabled });
      if (!st.alive) return;
      toggling.delete(id);
      paintWidget(w);
      syncCard(id);
      settle(w.enabled);
      ctx.toast(enabled ? `Mesure réactivée : ${w.title}. Ce choix est mémorisé.`
        : `Mesure désactivée : ${w.title}. Aucune lecture n’est faite pour ce widget, et ce choix est mémorisé.`, { tone: 'info', life: 3600 });
    } catch (err) {
      if (!st.alive) return;
      toggling.delete(id);
      input.checked = !enabled;
      syncCard(id);
      settle(st.widgets[id]?.enabled ?? !enabled);
      ctx.toast(reported(err), { tone: 'alert' });
    }
  }

  function refreshAllText(results) {
    const total = results.length;
    const ok = results.filter((r) => r === 'ok').length;
    const failed = results.filter((r) => r === 'failed').length;
    const skipped = total - ok - failed;
    const note = skipped ? ` ${plural(skipped, 'mesure désactivée', 'mesures désactivées')} pendant l’actualisation : rien n’a été publié pour ${skipped > 1 ? 'elles' : 'elle'}.` : '';
    if (failed) return { text: `Actualisation terminée : ${formatNumber(failed)} widget${failed > 1 ? 's' : ''} sur ${formatNumber(total)} en échec.${note}`, tone: 'warn' };
    if (!ok) return { text: `Aucun widget remesuré.${note}`, tone: 'info' };
    return { text: `Tableau de bord actualisé : ${plural(ok, 'widget remesuré', 'widgets remesurés')}.${note}`, tone: 'ok' };
  }

  async function refreshAll(button) {
    if (st.refreshing) return;
    if (!main.querySelector('[data-widget]')) { start(); return; } // error state: reload the whole page
    if (!st.summary) return; // first summary not there yet: nothing to measure
    const ids = Object.values(st.widgets).filter((w) => w.enabled && !toggling.has(w.id)).map((w) => w.id);
    if (!ids.length) {
      ctx.toast('Aucun widget à mesurer : réactivez « Mesure active » sur au moins un widget.', { tone: 'info' });
      return;
    }
    st.refreshing = true;
    const label = button.querySelector('.label-progress');
    let done = 0;
    button.classList.add('spinning');
    button.disabled = true;
    label.textContent = `Actualisation · 0 / ${ids.length}`;
    const results = await Promise.all(ids.map((id) => refreshWidget(id, { quiet: true }).then((r) => {
      done += 1;
      if (st.alive) label.textContent = `Actualisation · ${done} / ${ids.length}`;
      return r;
    })));
    if (!st.alive) return;
    try {
      await reload({ silent: true });
      const { text, tone } = refreshAllText(results);
      ctx.toast(text, { tone });
    } catch (err) {
      ctx.toast(reported(err), { tone: 'alert' });
    } finally {
      st.refreshing = false;
      const b = main.querySelector('[data-act="refresh-all"]');
      if (b) { b.classList.remove('spinning'); b.disabled = false; b.querySelector('.label-progress').textContent = 'Tout actualiser'; }
    }
  }

  // ----- Hero, working OU and session -----

  // The working-OU card is rebuilt only when the OU, its depth or the domain change, so a refresh never replays its
  // entrance; a new OU chosen in the panel also gets a short highlight.
  const scopeKey = (s) => JSON.stringify([s?.scope?.dn ?? null, s?.scope?.label ?? null, s?.scope?.subtree ?? null, s?.domain?.dnsName ?? null]);

  function paintHero({ scopeChanged = false } = {}) {
    const hero = main.querySelector('[data-slot="hero"]');
    if (!hero || !st.session) return;
    const lastReadAt = st.summary?.store?.lastReadAt ?? st.session.cache?.lastReadAt ?? null;
    if (!hero.querySelector('h1')) {
      // Keep the ring and the orbs of the skeleton: only the content is replaced.
      [...hero.children].forEach((el) => { if (!el.matches('.orbs, .glow-ring')) el.remove(); });
      hero.insertAdjacentHTML('beforeend', heroMarkup(st.session, lastReadAt, sim()));
      const card = hero.querySelector('.scope-card');
      if (card) card.dataset.key = scopeKey(st.session);
      paint(hero);
    } else {
      hero.querySelector('h1').textContent = heroTitle(st.session);
      hero.querySelector('.chips').innerHTML = heroChips(st.session, lastReadAt, sim());
      hero.querySelector('.lead').textContent = leadText(st.session);
      applyVars(hero.querySelector('.chips'));
      const card = hero.querySelector('.scope-card');
      if (card) {
        const key = scopeKey(st.session);
        if (card.dataset.key !== key) {
          card.dataset.key = key;
          card.innerHTML = scopeCardMarkup(st.session);
          paint(card);
        }
        if (scopeChanged) {
          card.classList.remove('changed');
          void card.offsetWidth;
          card.classList.add('changed');
        }
      }
    }
    const fleet = main.querySelector('[data-sec="fleet"] h2');
    if (fleet) fleet.textContent = st.session.scope ? `Parc de l’OU ${st.session.scope.label}` : 'Parc de l’OU de travail';
    updateStepper(hero, st.session.onboarding);
    syncRefreshAll();
  }

  // « Tout actualiser » waits for the first summary (nothing to measure before it); in the error state it reloads.
  function syncRefreshAll() {
    const b = main.querySelector('[data-act="refresh-all"]');
    if (!b || st.refreshing) return;
    b.disabled = !st.summary && Boolean(main.querySelector('[data-widget]'));
  }

  function paintPanels() {
    const slot = main.querySelector('[data-slot="session"]');
    if (!slot) return;
    if (!slot.querySelector('.tabs')) {
      slot.innerHTML = sessionMarkup(sim());
      bindTabs(slot);
    }
    PANELS.forEach((p) => {
      const tab = slot.querySelector(`#tab-${p.id}`);
      if (tab && tab.textContent !== panelLabel(p, sim())) tab.textContent = panelLabel(p, sim());
      const host = slot.querySelector(`#panel-${p.id} .kv-groups`);
      host.innerHTML = panelGroups(p.id, st.session, st.app, st.summary, sim()).map((g, n) => `<section class="kv-group" data-j="${n}">`
        + `<h4>${icon(g.icon)}${esc(g.title)}</h4><dl class="kv">${g.rows.map((r) => kv(...r)).join('')}</dl></section>`).join('');
      host.querySelectorAll('.kv > div').forEach((div, n) => { div.dataset.j = String(Math.min(n, 12)); });
      applyVars(host);
    });
    ink?.update();
  }

  function selectTab(slot, id, focus = false) {
    slot.querySelectorAll('[role="tab"]').forEach((t) => {
      const on = t.id === `tab-${id}`;
      t.setAttribute('aria-selected', String(on));
      t.tabIndex = on ? 0 : -1;
      if (on && focus) t.focus();
    });
    slot.querySelectorAll('[role="tabpanel"]').forEach((p) => { p.hidden = p.id !== `panel-${id}`; });
    ink?.update();
  }

  function bindTabs(slot) {
    const list = slot.querySelector('.tabs');
    ink = inkFollow(list, '[role="tab"]', '[aria-selected="true"]');
    stops.push(() => ink?.stop());
    list.addEventListener('click', (e) => {
      const t = e.target instanceof Element ? e.target.closest('[role="tab"]') : null;
      if (t) selectTab(slot, t.id.slice(4));
    });
    list.addEventListener('keydown', (e) => {
      const ids = PANELS.map((p) => p.id);
      const cur = ids.indexOf(list.querySelector('[aria-selected="true"]').id.slice(4));
      const next = { ArrowRight: cur + 1, ArrowLeft: cur - 1, Home: 0, End: ids.length - 1 }[e.key];
      if (next === undefined) return;
      e.preventDefault();
      selectTab(slot, ids[(next + ids.length) % ids.length], true);
    });
  }

  function copySummary() {
    const s = st.session;
    const lines = [`Domenia — tableau de bord du ${formatDateTime(st.summary?.generatedAt ?? new Date().toISOString())}`];
    if (typeof st.app?.banner === 'string' && st.app.banner) lines.push(st.app.banner);
    if (s) {
      lines.push(`Domaine : ${s.domain?.dnsName ?? 'non connecté'}`, `Contrôleur : ${s.controller?.dnsName ?? 'non connecté'}`,
        `Compte : ${s.account?.login ?? '—'}`,
        `OU de travail : ${s.scope ? `${pathOf(s.scope.dn, s.domain?.dnsName) || s.scope.label} (${s.scope.subtree ? 'sous-OU comprises' : 'cette OU seulement'}) — ${s.scope.dn}` : 'aucune'}`);
    }
    for (const w of Object.values(st.widgets)) {
      const d = w.data;
      let value = w.enabled ? 'aucune mesure' : 'mesure désactivée';
      try {
        if (d && w.kind === 'kpi') value = `${formatNumber(d.value)}${d.total != null ? ` / ${formatNumber(d.total)}` : ` ${d.unit}`}${d.delta ? ` (${d.delta.label})` : ''}`;
        else if (d && w.kind === 'gauge') value = `${pct(d.percent)} (${formatNumber(d.fresh)} / ${formatNumber(d.total)})`;
        else if (d && w.kind === 'distribution') value = d.segments.length ? d.segments.map((x) => `${x.label} ${pct(x.percent)}`).join(', ') : 'aucun ordinateur';
        else if (d && w.kind === 'series') value = d.points.map((p) => `${p.label} ${p.value ?? '—'}`).join(', ');
        else if (d && w.kind === 'list') value = `${formatNumber(d.total)} postes : ${d.rows.map((r) => `${r.name} (${r.reason})`).join(' ; ')}`;
        else if (d && w.kind === 'timeline') value = d.rows.map((r) => r.label).join(' ; ');
      } catch (err) {
        console.error(`Widget « ${w.id} » : copie impossible`, err, w);
        value = 'données inattendues';
      }
      lines.push(`${w.title} — ${w.scopeLabel} : ${value}`);
    }
    copyText(lines.join('\n')).then((ok) => ctx.toast(ok ? 'Tableau de bord copié dans le presse-papiers.' : 'Copie impossible : le presse-papiers est indisponible.', { tone: ok ? 'ok' : 'warn' }));
  }

  async function checkApplication(button) {
    button.disabled = true;
    const t0 = performance.now();
    try {
      const [app, session] = await Promise.all([ctx.call('app.info'), ctx.call('session.info')]);
      if (!st.alive) return;
      st.app = app; st.session = session;
      ctx.showConnection?.(session);
      paintPanels();
      const ms = Math.round(performance.now() - t0);
      ctx.toast(`Pont vérifié : ${app.name} ${app.version} répond en ${formatNumber(ms)} ms. Les contrôles complets arrivent avec le moteur.`, { tone: 'ok' });
    } catch (err) {
      ctx.toast(`Vérification en échec : ${reported(err)}`, { tone: 'alert' });
    } finally {
      button.disabled = false;
    }
  }

  // ----- Working OU -----

  // After session.setScope: the page shows the new OU at once, then every widget is computed again from the local data
  // (dashboard.summary, no network read) while the cards show that they are being recalculated.
  async function scopeApplied(session) {
    if (!st.alive || !session) return;
    st.session = session;
    ctx.showConnection?.(session);
    paintHero({ scopeChanged: true });
    paintPanels();
    window.dispatchEvent(new CustomEvent('domenia:scope-changed', { detail: { scope: session.scope ?? null } }));
    main.querySelectorAll('[data-widget]').forEach((card) => card.querySelector('.card-body')?.classList.add('updating'));
    const scope = session.scope;
    try {
      await reload({ silent: true });
      if (!st.alive) return;
      const where = scope ? `OU de travail : ${scope.label}${scope.subtree ? ' et ses sous-OU' : ' seule'}.` : 'OU de travail retirée.';
      ctx.toast(`${where} Accueil recalculé depuis ${sim() ? 'l’annuaire fictif en mémoire' : 'la base locale'}, sans lecture réseau.`, { tone: 'ok' });
    } catch (err) {
      if (st.alive) ctx.toast(reported(err), { tone: 'alert' });
    } finally {
      if (st.alive) Object.keys(st.widgets).forEach(syncCard);
    }
  }

  const panel = createOuPanel({
    ctx,
    current: () => ({ session: st.session, app: st.app }),
    onApplied: scopeApplied,
    fallbackFocus: () => main.querySelector('.scope-card [data-act="scope"]'),
  });

  function onAction(btn) {
    const act = btn.dataset.act;
    if (act === 'refresh-all') refreshAll(btn);
    else if (act === 'scope') panel.open({ opener: btn });
    else if (act === 'queries') ctx.go('requetes');
    else if (act === 'check') checkApplication(btn);
    else if (act === 'cache') ctx.toast('Vider le cache arrive dans une prochaine étape. Aucun objet Active Directory n’est modifié.', { tone: 'info' });
    else if (act === 'journal') ctx.go('operations');
    else if (act === 'copy') copySummary();
    else if (act === 'retry') start();
  }

  // #/accueil?ou=choisir opens the « Choisir l’OU » panel once the dashboard is shown (links from other screens, guides,
  // capture mode). Once per visit: « Réessayer » or a refresh does not open it again.
  let linkOpened = false;
  function openFromLink() {
    if (linkOpened || ctx.params?.ou !== 'choisir' || !st.alive) return;
    linkOpened = true;
    panel.open({ opener: main.querySelector('.scope-card [data-act="scope"]') }).catch((err) => console.error(err));
  }

  // ----- Loading -----

  function showError(err) {
    const grid = main.querySelector('.grid');
    if (!grid) return;
    const text = reported(err);
    const keepHero = st.session ? main.querySelector('[data-slot="hero"]') : null;
    grid.innerHTML = '';
    if (keepHero) grid.appendChild(keepHero);
    grid.insertAdjacentHTML('beforeend', `<section class="card span-12 error-card reveal" role="alert"><div class="empty">
      <div class="art">${icon('alert')}</div><h2>Tableau de bord indisponible</h2>
      <p>${esc(text)}</p>${err?.code ? `<span class="code">${esc(err.code)}</span>` : ''}
      <button class="btn primary" type="button" data-act="retry">${icon('refresh')}Réessayer</button></div></section>`);
    startReveal(grid);
    syncRefreshAll();
  }

  // Parameters of a link of the page: the object of a watchlist row; for Rechercher, the working OU (never the whole
  // domain, ACC-031).
  function goParams(el) {
    if (el.dataset.dn) return { dn: el.dataset.dn };
    const scope = st.session?.scope;
    const root = st.session?.domain?.rootDn;
    if (el.dataset.go === 'rechercher' && scope && (!root || scope.dn.toLowerCase() !== root.toLowerCase())) {
      return { ou: scope.dn, subtree: scope.subtree ? '1' : '0' };
    }
    return {};
  }

  async function reload({ silent = false } = {}) {
    // One after the other: the summary's own read never counts among the running tasks of session.info, and the
    // « dashboard » onboarding step is already done when the session is read.
    const summary = await ctx.call('dashboard.summary');
    const session = await ctx.call('session.info');
    if (!st.alive) return;
    st.summary = summary;
    st.session = session;
    ctx.showConnection?.(session);
    Object.values(summary.widgets).forEach((w) => paintWidget(w));
    paintHero();
    paintPanels();
    if (!silent) {
      ctx.toast(sim() ? 'Accueil actualisé depuis l’annuaire fictif en mémoire.' : 'Accueil actualisé depuis la base locale.', { tone: 'ok', life: 2600 });
    }
  }

  async function start() {
    pending.clear();
    st.widgets = {};
    st.summary = null;
    stops.splice(0).forEach((stop) => stop());
    main.innerHTML = skeletonPage();
    paint(main);
    startReveal(main);
    ctx.app.then((app) => {
      if (!st.alive) return;
      st.app = app;
      if (st.summary) paintPanels();
      if (st.session) paintHero();
    });
    try {
      const sessionCall = ctx.call('session.info');
      const summaryCall = ctx.call('dashboard.summary');
      // Awaited below, after the session; this handler only keeps an early failure from being reported as unhandled.
      summaryCall.catch(() => {});
      st.session = await sessionCall.catch(() => null);
      if (!st.alive) return;
      if (st.session) { ctx.showConnection?.(st.session); paintHero(); }
      st.summary = await summaryCall;
      if (!st.alive) return;
      Object.values(st.summary.widgets).forEach((w) => paintWidget(w));
      // Session read again once the summary is done: its read no longer counts among the running tasks (stable count),
      // and the « dashboard » onboarding step shows as done.
      const after = await ctx.call('session.info').catch(() => null);
      if (!st.alive) return;
      if (after) st.session = after;
      paintHero();
      paintPanels();
      openFromLink();
    } catch (err) {
      if (st.alive) showError(err);
    }
  }
  // ----- Events (delegated) -----

  const onClick = (e) => {
    const t = e.target instanceof Element ? e.target : null;
    const refresh = t?.closest('[data-refresh]');
    if (refresh) {
      const id = refresh.closest('[data-widget]')?.dataset.widget;
      // No measure while « Mesure active » is being changed (the widget may be off already on the engine side).
      if (id && !toggling.has(id) && !refresh.disabled) refreshWidget(id);
      return;
    }
    const crumb = t?.closest('[data-reveal]');
    if (crumb) { panel.open({ opener: crumb, revealDn: crumb.dataset.reveal }); return; }
    const act = t?.closest('[data-act]');
    if (act) { onAction(act); return; }
    const go = t?.closest('[data-go]');
    if (go) ctx.navigate(go.dataset.go, goParams(go));
  };
  const onChange = (e) => {
    if (e.target instanceof HTMLInputElement && e.target.matches('[data-toggle]')) toggleWidget(e.target);
  };
  const onRefreshHome = () => {
    if (!main.querySelector('[data-widget]')) { start(); return; }
    reload().catch((err) => ctx.toast(reported(err), { tone: 'alert' }));
  };
  main.addEventListener('click', onClick);
  main.addEventListener('change', onChange);
  window.addEventListener('domenia:refresh-home', onRefreshHome);
  ticker = setInterval(() => {
    main.querySelectorAll('[data-rel]').forEach((el) => {
      const text = relTime(el.dataset.rel);
      if (text) el.textContent = `${el.dataset.prefix ?? ''}${text}`;
    });
  }, 30_000);

  start();

  return () => {
    st.alive = false;
    clearInterval(ticker);
    main.removeEventListener('click', onClick);
    main.removeEventListener('change', onChange);
    window.removeEventListener('domenia:refresh-home', onRefreshHome);
    stops.forEach((stop) => stop());
    // The panel outlives a reload of the page content (« Réessayer »): it goes with the page only.
    panel.destroy();
  };
}
