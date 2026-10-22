// Accueil: overview of the working OU — hero (scope title, account chip, freshness of the AD read, « Tout actualiser » with its
// menu and its status strip, journey, help, working OU, first steps), sticky section index, KPI band, charts, the fleet board
// (widgets with their exact workstations, layout shaped by the operator, health rules, analysis, provenance), watchlist,
// timeline, session and its tools. The « Choisir l’OU » panel is the kit drawer with the kit tree (pages/accueil/ou-picker.js).
// #/accueil?section=<id> shows one section alone (links, guides, captures of a section at the top of the screen).
// Data contract: docs/OPERATIONS.md (app.info, session.info, session.setScope, dashboard.summary, dashboard.widget.*,
// directory.ou.*) and docs/ops/accueil.md (accueil.*).
import { icon } from '../icons.js';
import { glyph } from '../kit/glyphs.js';
import { freshness, startFreshness } from '../kit/freshness.js';
import {
  esc, applyVars, reveal, countUp, donut, inkFollow, copyText, relTime, formatNumber, formatDateTime, formatTime,
  cssMs, motionReduced,
} from '../ui.js';
import {
  NBSP, pct, isNum, numAttr, plural, capitalize, isSimulated, reported, dnChain, pathOf, isRootDn, paint, sk, skStack,
  localStamp, sameDn, rememberObject, lastObject,
} from './accueil/shared.js';
import { createOuPicker } from './accueil/ou-picker.js';
import { createBoard } from './accueil/board.js';
import { createRefresh } from './accueil/refresh.js';
import { openTargets, openCatalog, openProbeContract, openExplain, openProvenance, openAnalysis } from './accueil/tools.js';
import { openHealthRules } from './accueil/health.js';
import { stepsMarkup, journeyMarkup, animateSteps, openHelp, openSelfCheck, clearCache, openJournal } from './accueil/session-tools.js';

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
// Top widgets that have a counterpart in the fleet board (design review, tour 2): the indicator measures on demand, the board
// shows the same population computed from the local base with its exact workstations. A link joins them.
const RELATED = {
  workstationsOnline: { key: 'fleet.presence', label: 'Présence détaillée dans le tableau du parc' },
  diskAlerts: { key: 'fleet.lowdisk', label: 'Postes concernés dans le tableau du parc' },
  watchlist: { key: 'fleet.health', label: 'Santé et points d’attention dans le tableau du parc' },
  osDistribution: { key: 'fleet.versions', label: 'Versions de Windows dans le tableau du parc' },
};
const relatedButton = (id) => (RELATED[id]
  ? `<button class="btn ghost icon xs kpi-related" type="button" data-related="${esc(RELATED[id].key)}" aria-label="${esc(RELATED[id].label)}" data-tip="${esc(RELATED[id].label)}">${glyph('layers')}</button>`
  : '');
const PANELS = [
  { id: 'session', label: 'Session' },
  { id: 'application', label: 'Application' },
  { id: 'store', label: 'Base locale', simulated: 'Données fictives' },
];
const SECTIONS = [
  { id: 'kpis', label: 'Indicateurs', icon: 'gauge', link: 'indicateurs' },
  { id: 'fleet', label: 'Activité', icon: 'activity', link: 'activite' },
  { id: 'board', label: 'Tableau du parc', icon: 'layers', link: 'tableau' },
  { id: 'follow', label: 'Suivi', icon: 'eye', link: 'suivi' },
  { id: 'session', label: 'Session', icon: 'shield', link: 'session' },
];
// ?section=<link> of the address → section id.
const SECTION_LINKS = new Map(SECTIONS.map((x) => [x.link, x.id]));
// Age after which the AD read of the hero turns red (amber from half of it): one day (ACC-020, badge coloured by age).
const AD_STALE_MS = 24 * 3_600_000;
const DAY_MS = 86_400_000;
const countText = (v) => (isNum(v) ? formatNumber(v) : 'non mesuré');
const RING = '<span class="glow-ring hero-ring" aria-hidden="true"></span>';
const ORBS = '<div class="orbs" aria-hidden="true"><span class="orb a"></span><span class="orb b"></span><span class="orb c"></span></div>';
const longDate = new Intl.DateTimeFormat('fr-FR', { weekday: 'long', day: 'numeric', month: 'long' });
const panelLabel = (p, sim) => (sim && p.simulated ? p.simulated : p.label);
// lastSeenAt is null when no answer to the presence check (ping) is recorded, even if WMI answered (OPERATIONS.md § 4.7).
const NO_PING_TIP = 'Aucune réponse au relevé de présence (ping) n’est enregistrée pour ce poste. Le ping peut être filtré : '
  + 'une absence de réponse n’est jamais un verdict d’arrêt.';
const INVENTORY_RULES = new Set(['lowDisk', 'diskTight', 'uptime']);
// Tools opened from the address (#/accueil?outil=…), for links from other screens, guides and the capture mode.
const TOOLS = new Set(['widgets', 'sante', 'score', 'analyse', 'provenance', 'journal', 'verifier', 'aide', 'actualiser', 'base', 'wmi', 'ping', 'reprendre']);

// ---------- Skeletons ----------

const secHead = (id, title, note) => `<div class="home-sec reveal" data-sec="${id}" data-in-sec="${id}" id="acc-sec-${id}"><h2>${esc(title)}</h2><span class="sec-note">${esc(note)}</span></div>`;

function skeletonPage() {
  const kpi = (id) => `<article class="card kpi spot tilt reveal" data-widget="${id}">${skStack('sk-line w40', 'sk-title w70', 'sk-value w55', 'sk-line w85', 'sk-line w70')}</article>`;
  const chart = (id, span, body, sec) => `<section class="card widget ${span} spot reveal" data-widget="${id}" data-in-sec="${sec}"><div class="sk-stack">${sk('sk-line w40')}${body}</div></section>`;
  return `<div class="page home"><div class="grid">
    <section class="hero span-12 reveal" data-slot="hero">
      ${RING}${ORBS}
      <div class="hero-grid"><div class="hero-main">${skStack('sk-line w25', 'sk-title w40', 'sk-line w70', 'sk-line w55')}</div>
        <div class="scope-card">${skStack('sk-line w40', 'sk-title w55', 'sk-line w85', 'sk-line w70')}</div></div>
    </section>
    <span class="acc-nav-sentinel span-12" aria-hidden="true"></span>
    <nav class="acc-nav span-12" aria-label="Sections de l’Accueil"><div class="acc-nav-band">
      <span class="acc-nav-scope" aria-hidden="true"></span>
      <div class="acc-nav-track">${SECTIONS.map((x, n) => `<button type="button" class="acc-nav-btn" data-nav="${x.id}" data-j="${n}">${glyph(x.icon)}<span>${esc(x.label)}</span></button>`).join('')}<span class="ink acc-nav-ink" aria-hidden="true"></span></div>
      <span class="acc-nav-focus" hidden></span></div></nav>
    ${secHead('kpis', 'Indicateurs clés', `Mesurés à la demande · comptes${NBSP}: tout le domaine · postes${NBSP}: OU de travail`)}
    <div class="kpi-band" data-in-sec="kpis">${KPI_IDS.map(kpi).join('')}</div>
    ${secHead('fleet', 'Activité de l’OU de travail', 'Calculé localement, sans lecture réseau')}
    ${chart('workstationActivity', 'span-5', sk('sk-block w100'), 'fleet')}
    ${chart('osDistribution', 'span-4', sk('sk-ring'), 'fleet')}
    ${chart('measureFreshness', 'span-3', sk('sk-ring'), 'fleet')}
    ${secHead('board', 'Tableau du parc', 'OU de travail, recalculé depuis la base locale après chaque mesure · chaque chiffre ouvre ses postes exacts')}
    <section class="span-12 board" data-slot="board" data-in-sec="board" aria-labelledby="acc-sec-board"></section>
    ${secHead('follow', 'Suivi', 'Postes à surveiller et journal des opérations')}
    ${chart('watchlist', 'span-7', skStack('sk-line w85', 'sk-line w70', 'sk-line w85', 'sk-line w55'), 'follow')}
    ${chart('recentOperations', 'span-5', skStack('sk-line w70', 'sk-line w55', 'sk-line w70', 'sk-line w40'), 'follow')}
    <section class="card span-12 spot reveal session-card" data-slot="session" data-in-sec="session" id="acc-sec-session">${skStack('sk-line w25', 'sk-line w100', 'sk-line w85')}</section>
  </div></div>`;
}

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
  const head = `<div class="kpi-top"><span class="card-icon">${icon(WIDGET_ICONS[w.id])}</span>${scopeTag(w)}${staleChip(w)}${relatedButton(w.id)}${w.enabled ? refreshButton() : ''}</div>
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
    <span class="meta">${extra}${staleChip(w)}${relatedButton(w.id)}${w.enabled ? refreshButton() : ''}</span></div>`;
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
    return `<button class="list-row watch-row" type="button" data-go="poste" data-dn="${esc(r.dn)}" data-name="${esc(r.name)}" data-sev="${alert ? 'alert' : 'warn'}" data-j="${n}" data-tip="${esc(r.dn)}">
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
    // Rechercher receives the working OU (never the whole domain, ACC-031); the exact list of the board is under « Points d’attention ».
    if (d.total > d.shown) action = `<button class="btn sm" type="button" data-go="rechercher" data-tip="${esc(`Ouvre Rechercher sur l’OU de travail ; les ${formatNumber(d.total)} postes exacts sont dans «${NBSP}Points d’attention${NBSP}» du tableau du parc`)}">${icon('search')}Ouvrir l’OU dans Rechercher</button>`;
  } else {
    extra = `<span class="head-chip">${formatNumber(d.rows.length)} sur ${formatNumber(d.total)}</span>`;
    body = timelineBody(d);
    action = `<button class="btn sm ghost" type="button" data-go="operations">${icon('activity')}Ouvrir le journal des opérations</button>`;
  }
  return `${cardHead(w, extra)}<div class="card-body">${body}</div>${cardFoot(w, action)}`;
}

// ---------- Hero, working OU, first steps and session panels ----------

// session.info in directory mode without a connection still names the join domain (domain.dnsName may also be null).
// The OU is named by the title and the card: the lead says what is measured where, without repeating it.
function leadText(s) {
  const safety = s.readOnly ? `Lecture seule${NBSP}: aucune modification de l’annuaire n’est possible.`
    : `Rien n’est modifié sans votre geste${NBSP}: toute écriture demande une confirmation explicite.`;
  const dns = s.domain?.dnsName;
  if (s.connection?.state === 'disconnected' || !dns) {
    return `Annuaire non connecté${dns ? ` (domaine ${dns})` : ''}${NBSP}: les lectures de l’annuaire reprendront à la connexion. ${safety}`;
  }
  const where = s.scope
    ? `Postes mesurés dans l’OU de travail${s.scope.subtree ? ' et ses sous-OU' : ' seule'}`
    : 'Aucune OU de travail choisie pour mesurer les postes';
  return `${where}, comptes de tout le domaine ${dns}. ${safety}`;
}

function heroChips(s, lastReadAt, sim, dir = null) {
  const chips = [];
  if (s.account?.login) chips.push(`<span class="chip" data-tip="${esc(s.account.displayName ? `Compte utilisé pour l’annuaire · ${s.account.displayName}` : 'Compte utilisé pour l’annuaire')}">${icon('user')}<span class="mono">${esc(s.account.login)}</span></span>`);
  if (s.domain?.dnsName) chips.push(`<span class="chip" data-tip="${esc(s.domain.netbiosName ? `Domaine · NetBIOS ${s.domain.netbiosName}` : 'Domaine')}">${glyph('domain')}${esc(s.domain.dnsName)}</span>`);
  if (s.controller) chips.push(`<span class="chip" data-tip="Contrôleur de domaine">${icon('server')}${esc(s.controller.dnsName)}${s.controller.site ? ` · ${esc(s.controller.site)}` : ''}</span>`);
  // Freshness of the AD read of the branch (ACC-020): the last complete read covering the working OU, given by accueil.board
  // (board.directory), never the global date of the base; a partial attempt or a date in the future is said, and a partial
  // read never replaces the date. Green, amber past half a day, red past a day (kit freshness indicator, its tip dates it).
  if (dir && dir.status) {
    const tip = `${dir.text}${dir.sourceDn ? ` · lu depuis ${dir.sourceDn}` : ''} · le nombre de postes compte aussi les comptes désactivés.`;
    const label = sim ? 'Annuaire fictif lu' : 'Branche lue';
    if (dir.clockInvalid) {
      chips.push(`<span class="chip alert" data-tip="${esc(tip)}">${icon('alert')}Date de lecture dans le futur${NBSP}: horloge à vérifier</span>`);
    }
    if (dir.at) {
      chips.push(`<span class="chip ad-fresh${dir.partial ? ' warn' : ''}" data-tip="${esc(tip)}">${freshness(dir.at, { staleAfter: AD_STALE_MS, label, source: sim ? 'lecture fictive, aucune base locale ouverte' : 'dernière lecture complète de la branche' })}${dir.partial ? `<span class="chip-note">${NBSP}· tentative partielle</span>` : ''}</span>`);
    } else {
      chips.push(`<span class="chip warn" data-tip="${esc(tip)}">${icon('database')}${dir.partial ? `Lecture AD partielle${NBSP}: aucune lecture complète de la branche` : `Aucune lecture AD complète de la branche`}</span>`);
    }
  } else if (lastReadAt) {
    chips.push(`<span class="chip ad-fresh">${freshness(lastReadAt, { staleAfter: AD_STALE_MS, label: sim ? 'Annuaire fictif lu' : 'Annuaire lu', source: sim ? 'lecture fictive, aucune base locale ouverte' : 'lecture complète enregistrée dans la base locale' })}</span>`);
  } else {
    chips.push(`<span class="chip warn">${icon('database')}${sim ? 'Annuaire fictif non lu' : `Base locale vide${NBSP}: aucune lecture de l’annuaire`}</span>`);
  }
  return chips.map((c, n) => c.replace('<span class="chip', `<span data-j="${n}" class="chip`)).join('');
}

// Working OU: name, the path of its parents (each level opens the OU panel on it, ACC-013), depth and the button of the panel.
function scopeCardMarkup(s) {
  const scope = s?.scope ?? null;
  const chain = scope ? dnChain(scope.dn, s.domain?.dnsName) : null;
  let crumbs = '';
  if (chain) {
    // The OU itself is the name above: the path shows where it lives, from the domain.
    const steps = [{ ...chain.root, root: true }, ...chain.chain.slice(0, -1)];
    crumbs = `<nav class="crumbs" aria-label="Emplacement de l’OU de travail"><span class="crumbs-k">Dans</span><ol>${steps.map((c, n) => {
      const inner = `<button type="button" class="crumb" data-reveal="${esc(c.dn)}"${c.root ? ' data-root="1"' : ''} data-tip="${esc(c.root ? 'Ouvrir le choix de l’OU à la racine du domaine (tout le domaine se confirme)' : `Choisir ${c.name} comme OU de travail, même profondeur`)}">${esc(c.name)}</button>`;
      return `<li data-j="${n}">${inner}</li>`;
    }).join('')}</ol></nav>`;
  }
  const depth = scope ? `<span class="chip ${scope.subtree ? 'info' : ''} depth">${scope.subtree ? 'Sous-OU comprises' : 'Cette OU seulement'}</span>` : '';
  const note = scope ? `Défaut de toutes les sections${NBSP}: postes mesurés dans cette OU, comptes sur tout le domaine.`
    : `Choisissez une OU${NBSP}: la mesure des postes n’est jamais lancée sur tout le domaine.`;
  return `<div class="scope-top"><span class="scope-ico">${glyph('ou')}</span><span class="scope-k" id="scope-card-k">OU de travail</span>${depth}</div>
    <div class="scope-name">${scope ? esc(scope.label) : 'Aucune OU choisie'}</div>
    ${crumbs}
    <p class="scope-note">${esc(note)}</p>
    <button class="btn ${scope ? '' : 'primary '}sm scope-btn" type="button" data-act="scope" aria-haspopup="dialog">${glyph('ou')}Choisir l’OU</button>`;
}

// Hero content; the rotating ring and the orbs come from the skeleton and stay, so their motion never restarts.
// Title: the scope, never a greeting by first name (decision of David, 21/10: the operator signs in with an administration
// account); the account itself is a chip.
function heroTitle(s) {
  if (!s.scope) return 'Vue d’ensemble';
  const root = s.domain?.rootDn && s.scope.dn.toLowerCase() === s.domain.rootDn.toLowerCase();
  return `Vue d’ensemble · ${root ? `Domaine ${s.scope.label}` : `OU ${s.scope.label}`}`;
}

// One row of actions: the only primary of the screen (« Tout actualiser » and its menu), the journey (its third step opens the
// query workshop) and the help « ? »; the status strip of a refresh sits under it. « Choisir l’OU » lives in the OU card.
function heroMarkup(s, lastReadAt, sim, helpSeen, dir = null) {
  return `<div class="hero-grid">
      <div class="hero-main">
        <div class="eyebrow">${icon('sparkles')}<span>Tableau de bord</span><span class="eyebrow-date">${esc(longDate.format(new Date()))}</span></div>
        <h1 class="gradient-text">${esc(heroTitle(s))}</h1>
        <p class="lead">${esc(leadText(s))}</p>
        <div class="chips">${heroChips(s, lastReadAt, sim, dir)}</div>
        <div class="hero-row">
          <div class="hero-actions" data-slot="refresh-actions"></div>
          <span class="spacer"></span>
          <div class="hero-journey" data-slot="journey">${journeyMarkup(lastObject())}</div>
          ${helpButton(helpSeen)}
        </div>
        <div class="hero-status" data-slot="refresh-status"></div>
      </div>
      <aside class="scope-card" data-slot="scope" aria-labelledby="scope-card-k">${scopeCardMarkup(s)}</aside>
    </div>
    <div class="steps-slot" data-slot="steps"></div>`;
}

// « ? » of the screen with its « Nouveau » mark until the help is opened once (ACC-017, UxHelpBadge).
function helpButton(helpSeen) {
  const tip = helpSeen ? 'Aide de l’Accueil' : `Nouveau${NBSP}: aide disponible`;
  return `<button class="btn ghost icon help-btn" type="button" data-act="help" aria-label="${esc(tip)}" data-tip="${esc(tip)}">${glyph('lifebuoy')}`
    + `${helpSeen ? '' : '<span class="new-dot" aria-hidden="true"></span>'}</button>`;
}

// A DN only breaks after its commas (<wbr>), never in the middle of a name.
const breakable = (text) => esc(text).replace(/,/g, ',<wbr>');
const looksDn = (v) => typeof v === 'string' && /^(?:[A-Za-z]+=[^,]+,)+[A-Za-z]+=/.test(v);
// A long explanation goes under the line, across the whole group (« wide »), instead of wrapping in the narrow value column.
const kv = (label, value, sub = '', wide = '') => `<div${wide ? ' class="has-note"' : ''}><dt>${esc(label)}</dt><dd>${looksDn(value) ? breakable(value) : esc(value ?? '—')}`
  + `${sub ? `<span class="sub">${looksDn(sub) ? breakable(sub) : esc(sub)}</span>` : ''}</dd>${wide ? `<p class="kv-note">${esc(wide)}</p>` : ''}</div>`;

const ENGINES = { embarque: 'Moteur fixe du pack', windows: 'Moteur WebView2 de Windows', apercu: 'Navigateur (aperçu)' };

// Each tab groups its lines by subject (same lines as before, more air between them).
function panelGroups(id, s, app, summary, sim, extra = {}) {
  if (id === 'session') {
    if (!s) return [{ title: 'Session', icon: 'shield', rows: [['Session', 'Indisponible']] }];
    const d = extra.details;
    const b = extra.board;
    const obj = extra.object;
    const calcs = d?.calculations ?? [];
    const lastCalc = calcs.at(-1);
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
        ['Estimation des droits', s.rights?.label, '', s.rights?.detail ?? ''],
        ['Lecture seule', s.readOnly ? 'Activée' : 'Désactivée'],
      ] },
      { title: 'Périmètre et tâches', icon: 'folder', rows: [
        ['OU de travail', s.scope?.label ?? 'Aucune OU choisie', s.scope ? pathOf(s.scope.dn, s.domain?.dnsName) : ''],
        ['Branche affichée', s.scope?.dn ?? 'Aucune OU choisie', s.scope ? (s.scope.subtree ? 'Sous-OU comprises' : 'Cette OU seulement') : ''],
        ['Tâches', `${formatNumber(s.tasks?.running ?? 0)} en cours · ${formatNumber(s.tasks?.queued ?? 0)} en attente`],
      ] },
      // « Détails de la session » of Domenia 1 (ACC-019): what is displayed, its statistics, the links and the last check.
      { title: 'Vue affichée et vérifications', icon: 'activity', wide: true, rows: [
        ['Résultats affichés', b ? `${plural(extra.widgets ?? 0, 'widget', 'widgets')} · ${plural(b.population?.enabled ?? 0, 'poste actif calculé', 'postes actifs calculés')}` : 'Tableau du parc en cours de calcul',
          b ? `Calcul du ${localStamp(b.computedAt)}${lastCalc ? ` en ${formatNumber(lastCalc.milliseconds)}${NBSP}ms` : ''}` : ''],
        ['Statistiques de la liste', b ? `${plural(b.population?.machines ?? 0, 'compte ordinateur', 'comptes ordinateur')} · ${formatNumber(b.population?.enabled ?? 0)} activés · ${formatNumber(b.population?.disabled ?? 0)} désactivés` : '—',
          b?.health ? `Santé${NBSP}: ${b.health.verdict}${isNum(b.health.score) ? ` (${b.health.score}${NBSP}%)` : ''} · ${plural(b.health.problems ?? 0, 'poste à traiter', 'postes à traiter')}` : ''],
        ['Liens utilisateur–poste', d ? d.associationsText : '—'],
        ['Dernière vérification', d?.lastCheck ? d.lastCheck.summary : 'Pas encore lancée dans cette session', d?.lastCheck ? `Le ${localStamp(d.lastCheck.checkedAt)}` : '« Vérifier l’application » ci-dessous'],
        ['Objet sélectionné', obj ? obj.name : 'Aucun objet choisi depuis l’Accueil', obj ? `${obj.kind === 'poste' ? 'Poste' : 'Objet'} · ${pathOf(obj.dn, s.domain?.dnsName) || obj.dn}` : ''],
        ['Derniers calculs', calcs.length ? calcs.map((c) => `${formatNumber(c.milliseconds)}${NBSP}ms`).join(' · ') : '—', calcs.length ? `${plural(calcs.length, 'calcul gardé', 'calculs gardés')} pour comparer (cinq au plus)` : ''],
        ...(d?.localWriteFailures ? [['Écritures locales', `${plural(d.localWriteFailures, 'échec', 'échecs')} d’écriture des préférences`, 'Les choix valent pour la session ; trois échecs suspendent les collectes']] : []),
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
      <div class="head-titles"><h3>Session et vérifications</h3><span class="head-sub">Informations déjà chargées, sans lecture réseau</span></div>
      <span class="meta"><button class="btn ghost sm" type="button" data-act="help">${glyph('lifebuoy')}Aide</button></span></div>
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

// ---------- Page ----------

export function render(main, ctx) {
  const st = {
    session: null, summary: null, app: null, widgets: {}, alive: true, steps: null, stepsHidden: false, helpSeen: true,
    favorites: [], lastView: null, refreshing: false, stepsRecalled: false, boardState: { state: 'idle' }, details: null,
    focus: null, directory: null,
  };
  const pending = new Map();
  const busy = new Map(); // widget id → measurements in flight
  const toggling = new Set(); // widgets whose « Mesure active » change is not confirmed yet
  const stops = [];
  let ink = null;
  let navInk = null;
  let detailsAsked = false;
  let ticker = 0;
  let board = null;
  let refresh = null;
  let liveTimer = 0;
  let boardTimer = 0;

  // A measure of the top widgets (ping, inventory, directory) changes the local state the fleet board is computed from: the
  // board is computed again once, 1 s after the last measure, so both never show contradictory figures (ACC-033). Local
  // calculation only, no network; a running OU refresh already recomputes it every 15 s.
  let measureSyncs = 0;
  function scheduleBoardReload() {
    clearTimeout(boardTimer);
    boardTimer = setTimeout(() => {
      boardTimer = 0;
      if (!st.alive || st.refreshing || !board) return;
      // The number of recomputations after a measure is kept on the board (data-measure-sync) for the E2E scenarios.
      Promise.resolve(board.load()).then(() => {
        const slot = main.querySelector('[data-slot="board"]');
        if (st.alive && slot) slot.dataset.measureSync = String(++measureSyncs);
      }).catch((err) => console.error(err));
    }, 1000);
  }

  const sim = () => isSimulated(st.session, st.app);
  const stagger = () => cssMs('--stagger', 55);
  const shown = (el) => !(el.classList.contains('reveal') && !el.classList.contains('in'));
  const whenShown = (el, fn) => { if (shown(el)) fn(0); else pending.set(el, fn); };
  const startReveal = (scope) => stops.push(reveal(scope, {
    onIn: (el, n) => { const fn = pending.get(el); if (fn) { pending.delete(el); fn(n); } },
  }));
  const scopeOk = () => Boolean(st.session?.scope && !isRootDn(st.session.scope.dn));

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

  // ----- Widgets of dashboard.summary -----

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
        if (!quiet) ctx.toast(`${w.title} : mesure désactivée pendant l’actualisation, rien n’a été publié.`, { tone: 'info' });
        return 'skipped';
      }
      paintWidget(w, { bump: true });
      restoreFocus(id, key);
      scheduleBoardReload();
      if (!quiet) ctx.toast(`${w.title} : mesure actualisée.`, { tone: 'ok', life: 3000 });
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

  // ----- Hero, working OU, first steps -----

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
      hero.insertAdjacentHTML('beforeend', heroMarkup(st.session, lastReadAt, sim(), st.helpSeen, st.directory));
      const card = hero.querySelector('.scope-card');
      if (card) card.dataset.key = scopeKey(st.session);
      paint(hero);
      mountRefresh();
    } else {
      hero.querySelector('h1').textContent = heroTitle(st.session);
      hero.querySelector('.lead').textContent = leadText(st.session);
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
    board?.refreshTools?.();
    const chips = hero.querySelector('.chips');
    const html = heroChips(st.session, lastReadAt, sim(), st.directory);
    if (chips.dataset.html !== html) {
      chips.dataset.html = html;
      chips.innerHTML = html;
      applyVars(chips);
      startFreshness(chips);
    }
    paintFavorites();
    paintSteps();
    const fleet = main.querySelector('[data-sec="fleet"] h2');
    if (fleet) fleet.textContent = st.session.scope ? `Activité de l’OU ${st.session.scope.label}` : 'Activité de l’OU de travail';
    const boardHead = main.querySelector('[data-sec="board"] h2');
    if (boardHead) boardHead.textContent = st.session.scope ? `Tableau du parc · OU ${st.session.scope.label}` : 'Tableau du parc';
    const navScope = main.querySelector('.acc-nav-scope');
    if (navScope) navScope.textContent = st.session.scope ? heroTitle(st.session).replace(/^Vue d’ensemble · /, '') : '';
    syncHeroActions();
  }

  // Favourite working OU under the card: one click switches (session.setScope), the panel manages them.
  function paintFavorites() {
    const card = main.querySelector('.scope-card');
    if (!card) return;
    let host = card.querySelector('.scope-favs');
    const list = (st.favorites ?? []).filter((f) => f.exists).slice(0, 6);
    if (!list.length) { host?.remove(); return; }
    if (!host) {
      host = document.createElement('div');
      host.className = 'scope-favs';
      card.querySelector('.scope-btn')?.before(host);
    }
    const cur = st.session?.scope;
    host.innerHTML = `<span class="scope-favs-k">${icon('star')}Favorites</span>${list.map((f, n) => {
      const now = cur && sameDn(cur.dn, f.dn) && cur.subtree === f.subtree;
      return `<button type="button" class="fav-chip${now ? ' now' : ''}" data-fav-dn="${esc(f.dn)}" data-fav-sub="${f.subtree ? '1' : '0'}" data-j="${n}"${now ? ' aria-current="true"' : ''} data-tip="${esc(f.path)}">${esc(f.name)}</button>`;
    }).join('')}`;
    paint(host);
  }

  // The card of the first steps goes away for good once the four steps are done (Home.FirstStepsDone, ACC-015); the help shows it
  // again for the visit. It is rebuilt only when what it shows changes.
  function paintSteps() {
    const slot = main.querySelector('[data-slot="steps"]');
    if (!slot) return;
    const info = st.steps;
    const showSteps = Boolean(info) && (st.stepsRecalled || (!info.finished && !info.dismissed && !st.stepsHidden));
    const html = showSteps ? stepsMarkup(info, { helpSeen: st.helpSeen, board: { state: st.boardState.state, machines: st.boardState.machines } }) : '';
    if (slot.dataset.html === html) return;
    slot.dataset.html = html;
    slot.innerHTML = html;
    paint(slot);
    if (showSteps) animateSteps(slot, info);
  }

  async function loadSteps() {
    try {
      const info = await ctx.call('accueil.firstSteps');
      if (!st.alive) return;
      st.steps = info;
      st.helpSeen = info.helpSeen;
      st.stepsHidden = info.dismissed;
      paintSteps();
      syncHelpDot();
      if (info.done && !st.stepsRecalled) slotJourney();
    } catch (err) {
      reported(err);
    }
  }

  function syncHelpDot() {
    main.querySelectorAll('[data-act="help"]').forEach((b) => {
      b.querySelector('.new-dot')?.remove();
      if (!st.helpSeen) b.insertAdjacentHTML('beforeend', '<span class="new-dot" aria-hidden="true"></span>');
      if (b.classList.contains('icon')) {
        const tip = st.helpSeen ? 'Aide de l’Accueil' : `Nouveau${NBSP}: aide disponible`;
        b.setAttribute('aria-label', tip);
        b.dataset.tip = tip;
      }
    });
  }

  // « Consulter » names the object last chosen from the Accueil.
  function slotJourney() {
    const slot = main.querySelector('[data-slot="journey"]');
    if (slot) slot.innerHTML = journeyMarkup(lastObject());
  }

  async function setStepsHidden(hidden) {
    st.stepsHidden = hidden;
    st.stepsRecalled = !hidden;
    paintSteps();
    try {
      const info = await ctx.call('accueil.firstSteps.dismiss', { dismissed: hidden });
      if (st.alive && info) { st.steps = info; paintSteps(); }
      ctx.toast(hidden ? `Premiers pas masqués${NBSP}: l’aide de l’Accueil (?) les réaffiche.` : 'Premiers pas réaffichés.', { tone: 'info', life: 2600 });
    } catch (err) {
      ctx.toast(reported(err), { tone: 'alert' });
    }
  }

  function stepAction(id) {
    if (id === 'connect') { scrollToSection('session'); return; }
    if (id === 'scope') { picker.open(); return; }
    if (id === 'firstRead') { refresh?.plan('directory'); return; }
    if (id === 'dashboard') {
      // First calculation followed in the button (ACC-016): an error offers « Réessayer », which computes again.
      if (st.boardState.state === 'error') board?.load({ quiet: false }); else scrollToSection('board');
      return;
    }
    if (id === 'rights') openSelfCheck({ ctx, onDone: () => loadSteps() });
  }

  function syncHeroActions() {
    refresh?.sync();
  }

  function paintPanels() {
    const slot = main.querySelector('[data-slot="session"]');
    if (!slot) return;
    if (!slot.querySelector('.tabs')) {
      slot.innerHTML = sessionMarkup(sim());
      bindTabs(slot);
    }
    const extra = { details: st.details, board: board?.board() ?? null, widgets: board?.layout()?.items?.length ?? 0, object: lastObject() };
    PANELS.forEach((p) => {
      const tab = slot.querySelector(`#tab-${p.id}`);
      if (tab && tab.textContent !== panelLabel(p, sim())) tab.textContent = panelLabel(p, sim());
      const host = slot.querySelector(`#panel-${p.id} .kv-groups`);
      const html = panelGroups(p.id, st.session, st.app, st.summary, sim(), extra).map((g, n) => `<section class="kv-group${g.wide ? ' wide' : ''}" data-j="${n}">`
        + `<h4>${icon(g.icon)}${esc(g.title)}</h4><dl class="kv">${g.rows.map((r) => kv(...r)).join('')}</dl></section>`).join('');
      if (host.dataset.html === html) return;
      host.dataset.html = html;
      host.innerHTML = html;
      host.querySelectorAll('.kv > div').forEach((div, n) => { div.dataset.j = String(Math.min(n, 12)); });
      applyVars(host);
    });
    ink?.update();
  }

  // « Détails de la session » (ACC-019) are read when the session card shows, then after a check or a refresh.
  async function loadDetails() {
    try {
      st.details = await ctx.call('accueil.session.details');
      if (st.alive) paintPanels();
    } catch (err) {
      reported(err);
    }
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
    const b = board?.board();
    const lines = [`Domenia — vue d’ensemble du ${formatDateTime(st.summary?.generatedAt ?? new Date().toISOString())}`];
    if (typeof st.app?.banner === 'string' && st.app.banner) lines.push(st.app.banner);
    if (s) {
      lines.push(`Domaine${NBSP}: ${s.domain?.dnsName ?? 'non connecté'}`, `Contrôleur${NBSP}: ${s.controller?.dnsName ?? 'non connecté'}`,
        `Compte${NBSP}: ${s.account?.login ?? '—'}`,
        `OU de travail${NBSP}: ${s.scope ? `${pathOf(s.scope.dn, s.domain?.dnsName) || s.scope.label} (${s.scope.subtree ? 'sous-OU comprises' : 'cette OU seulement'}) — ${s.scope.dn}` : 'aucune'}`);
    }
    for (const w of Object.values(st.widgets)) {
      const d = w.data;
      let value = w.enabled ? 'aucune mesure' : 'mesure désactivée';
      try {
        if (d && w.kind === 'kpi') value = `${formatNumber(d.value)}${d.total != null ? ` / ${formatNumber(d.total)}` : ` ${d.unit}`}${d.delta ? ` (${d.delta.label})` : ''}`;
        else if (d && w.kind === 'gauge') value = `${pct(d.percent)} (${formatNumber(d.fresh)} / ${formatNumber(d.total)})`;
        else if (d && w.kind === 'distribution') value = d.segments.length ? d.segments.map((x) => `${x.label} ${pct(x.percent)}`).join(', ') : 'aucun ordinateur';
        else if (d && w.kind === 'series') value = d.points.map((p) => `${p.label} ${p.value ?? '—'}`).join(', ');
        else if (d && w.kind === 'list') value = `${formatNumber(d.total)} postes${NBSP}: ${d.rows.map((r) => `${r.name} (${r.reason})`).join(' ; ')}`;
        else if (d && w.kind === 'timeline') value = d.rows.map((r) => r.label).join(' ; ');
      } catch (err) {
        console.error(`Widget « ${w.id} » : copie impossible`, err, w);
        value = 'données inattendues';
      }
      lines.push(`${w.title} — ${w.scopeLabel}${NBSP}: ${value}`);
    }
    if (b) {
      lines.push('', `Tableau du parc — ${b.scopeLabel} (calculé le ${localStamp(b.computedAt)})`, b.summary,
        `Santé du parc${NBSP}: ${b.health.verdict}${isNum(b.health.score) ? ` (${b.health.score}${NBSP}%)` : ''} · ${b.health.pointsTitle}`);
      for (const item of board.layout()?.items ?? []) {
        const e = b.entries[item.source === 'probe' ? `probe:${item.key}` : item.source === 'query' ? `query:${item.key}` : item.key];
        if (e && e.kind !== 'health' && e.kind !== 'list') lines.push(`${e.title}${NBSP}: ${e.value}${e.unit ? ` ${String(e.unit).trim()}` : ''}`);
      }
    }
    copyText(lines.join('\n')).then((ok) => ctx.toast(ok ? 'Vue d’ensemble copiée dans le presse-papiers.' : `Copie impossible${NBSP}: le presse-papiers est indisponible.`, { tone: ok ? 'ok' : 'warn' }));
  }

  // ----- Working OU -----

  // After session.setScope: the page shows the new OU at once, then every widget is computed again from the local data
  // (dashboard.summary and accueil.board, no network read) while the cards show that they are being recalculated.
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
      await Promise.all([reload({ silent: true }), loadLastView(), loadFavorites()]);
      if (!st.alive) return;
      const where = scope ? `OU de travail${NBSP}: ${scope.label}${scope.subtree ? ' et ses sous-OU' : ' seule'}.` : 'OU de travail retirée.';
      ctx.toast(`${where} Accueil recalculé depuis ${sim() ? 'l’annuaire fictif en mémoire' : 'la base locale'}, sans lecture réseau.`, { tone: 'ok' });
    } catch (err) {
      if (st.alive) ctx.toast(reported(err), { tone: 'alert' });
    } finally {
      if (st.alive) Object.keys(st.widgets).forEach(syncCard);
    }
  }

  async function switchFavorite(dn, subtree) {
    try {
      const session = await ctx.call('session.setScope', { dn, subtree });
      await scopeApplied(session);
    } catch (err) {
      ctx.toast(reported(err), { tone: 'alert' });
    }
  }

  async function loadFavorites() {
    try {
      const r = await ctx.call('accueil.favorites');
      if (!st.alive) return;
      st.favorites = r.items ?? [];
      paintFavorites();
    } catch (err) {
      reported(err);
    }
  }

  async function loadLastView() {
    try {
      st.lastView = await ctx.call('accueil.lastView');
    } catch (err) {
      st.lastView = null;
      reported(err);
    }
  }

  const picker = createOuPicker({
    ctx,
    current: () => ({ session: st.session, app: st.app }),
    onApplied: scopeApplied,
  });

  // ----- Tools -----

  function openTargetsFor(key, label, revision) {
    const b = board?.board();
    if (!b) return;
    openTargets({ ctx, revision: revision ?? b.revision, key, label, scope: st.session?.scope ?? null, onReplaced: () => board.load({ quiet: false }) });
  }

  function onBoardAction(id) {
    if (id === 'collect') { refresh?.plan('inventory'); return; }
    if (id === 'bitlocker') readBitLocker();
  }

  // One BitLocker read at a time (the engine refuses a second one too, bitlocker.running): the buttons of the tile wait,
  // greyed with their reason and a spinner, until the read ends.
  let bitLockerBusy = false;
  function setBitLockerButtons(on) {
    main.querySelectorAll('[data-fw-action="bitlocker"]').forEach((b) => {
      b.disabled = on;
      b.classList.toggle('is-busy', on);
      if (on) { b.dataset.reason = 'Lecture de la présence BitLocker en cours…'; b.setAttribute('aria-busy', 'true'); } else { delete b.dataset.reason; b.removeAttribute('aria-busy'); }
    });
  }
  async function readBitLocker() {
    if (bitLockerBusy) {
      ctx.toast(`Lecture BitLocker déjà en cours${NBSP}: attendez sa fin.`, { tone: 'info', life: 2600 });
      return;
    }
    bitLockerBusy = true;
    setBitLockerButtons(true);
    try {
      ctx.toast('Lecture de la présence des clés BitLocker de l’OU…', { tone: 'info', life: 2000 });
      const r = await ctx.call('accueil.bitlocker.read');
      if (!st.alive) return;
      ctx.toast(r.text, { tone: r.withoutKey ? 'warn' : 'ok', life: 5200 });
      bitLockerBusy = false;
      await board.load();
    } catch (err) {
      ctx.toast(reported(err), { tone: err?.code === 'scope.tooWide' || err?.code === 'bitlocker.running' ? 'warn' : 'alert' });
    } finally {
      bitLockerBusy = false;
      if (st.alive) setBitLockerButtons(false);
    }
  }

  function openTool(id) {
    if (id === 'catalog' || id === 'widgets') openCatalog({ ctx, board, onProbe: (pid) => openProbeContract(ctx, pid) });
    else if (id === 'explain' || id === 'score') openExplain({ ctx, onTargets: openTargetsFor });
    else if (id === 'health' || id === 'sante') openHealthRules({ ctx, onSaved: () => board.load() });
    else if (id === 'analysis' || id === 'analyse') openAnalysis({ ctx, onTargets: openTargetsFor });
    else if (id === 'provenance') openProvenance({ ctx });
    else if (id === 'journal') openJournal({ ctx });
    else if (id === 'verifier') openSelfCheck({ ctx, onDone: () => { loadSteps(); loadDetails(); } });
    else if (id === 'aide') openHelpPanel();
    else if (id === 'actualiser') refresh?.plan('all');
    else if (id === 'base') refresh?.plan('directory');
    else if (id === 'wmi') refresh?.plan('inventory');
    else if (id === 'ping') refresh?.plan('presence');
    else if (id === 'reprendre') refresh?.plan('resume');
    else if (id.startsWith('probe:')) openProbeContract(ctx, id.slice(6));
  }

  function openHelpPanel() {
    openHelp({
      ctx,
      stepsHidden: !st.stepsRecalled && Boolean(st.stepsHidden || st.steps?.dismissed || st.steps?.finished),
      onSeen: (seen) => { st.helpSeen = seen; syncHelpDot(); },
      onShowSteps: () => setStepsHidden(false),
    });
  }

  // ----- Sections: sticky index with its ink on the section in view -----

  const sectionTarget = (id) => (id === 'session' ? main.querySelector('[data-slot="session"]') : main.querySelector(`[data-sec="${CSS.escape(id)}"]`));

  function scrollToSection(id) {
    if (st.focus && st.focus !== id) setFocus(null);
    const target = sectionTarget(id);
    if (!target) return;
    const nav = main.querySelector('.acc-nav');
    const top = target.getBoundingClientRect().top - main.getBoundingClientRect().top + main.scrollTop - (nav?.offsetHeight ?? 0) - 12;
    main.scrollTo({ top, behavior: motionReduced() ? 'auto' : 'smooth' });
    setNav(id);
  }

  // One section alone (#/accueil?section=…): the others fold away, the band offers to show them all again.
  function setFocus(id) {
    st.focus = id && SECTIONS.some((x) => x.id === id) ? id : null;
    const page = main.querySelector('.home');
    if (!page) return;
    if (st.focus) page.dataset.focus = st.focus; else delete page.dataset.focus;
    const chip = main.querySelector('.acc-nav-focus');
    if (chip) {
      chip.hidden = !st.focus;
      chip.innerHTML = st.focus ? `${glyph('eye')}<span>${esc(SECTIONS.find((x) => x.id === st.focus).label)} seul</span><button class="btn ghost sm" type="button" data-act="focus-off">${glyph('layers')}Tout afficher</button>` : '';
    }
    if (st.focus) setNav(st.focus);
    navInk?.update();
  }

  function setNav(id) {
    main.querySelectorAll('.acc-nav-btn').forEach((b) => {
      if (b.dataset.nav === id) b.setAttribute('aria-current', 'true'); else b.removeAttribute('aria-current');
    });
    navInk?.update();
  }

  function watchSections() {
    const track = main.querySelector('.acc-nav-track');
    if (!track) return;
    navInk = inkFollow(track, '.acc-nav-btn', '[aria-current="true"]');
    stops.push(() => navInk?.stop());
    const targets = () => SECTIONS.map((sec) => [sec.id, sectionTarget(sec.id)]).filter(([, el]) => el && el.offsetParent !== null);
    // The section in view is the last one whose top passed the upper third of the screen; the bottom of the page is the last.
    let frame = 0;
    const update = () => {
      frame = 0;
      const list = targets();
      if (!list.length) return;
      const limit = main.getBoundingClientRect().top + main.clientHeight * 0.32;
      let current = list[0][0];
      for (const [id, el] of list) if (el.getBoundingClientRect().top <= limit) current = id;
      if (main.scrollTop + main.clientHeight >= main.scrollHeight - 2) current = list.at(-1)[0];
      setNav(current);
    };
    const onScroll = () => { if (!frame) frame = requestAnimationFrame(update); };
    main.addEventListener('scroll', onScroll, { passive: true });
    stops.push(() => { main.removeEventListener('scroll', onScroll); cancelAnimationFrame(frame); });
    update();
    // The band becomes opaque and names the OU once it sticks under the top bar.
    const sentinel = main.querySelector('.acc-nav-sentinel');
    const nav = main.querySelector('.acc-nav');
    if (sentinel && nav && 'IntersectionObserver' in window) {
      const io = new IntersectionObserver(([e]) => nav.classList.toggle('stuck', !e.isIntersecting), { root: main, threshold: 0 });
      io.observe(sentinel);
      stops.push(() => io.disconnect());
    }
  }

  function onAction(btn) {
    const act = btn.dataset.act;
    if (act === 'scope') picker.open();
    else if (act === 'focus-off') setFocus(null);
    else if (act === 'check') openSelfCheck({ ctx, onDone: () => { loadSteps(); loadDetails(); } });
    else if (act === 'cache') clearCache({ ctx, onCleared: () => { board?.load(); reload({ silent: true }).catch(reported); } });
    else if (act === 'journal') openJournal({ ctx });
    else if (act === 'copy') copySummary();
    else if (act === 'help') openHelpPanel();
    else if (act === 'steps-hide') setStepsHidden(true);
    else if (act === 'retry') start();
  }

  // #/accueil?ou=choisir opens « Choisir l’OU », ?outil=… a tool, ?postes=<clé> the workstations of a figure and
  // ?personnaliser=1 the layout mode, once the screen is shown (links, guides, capture). Once per visit.
  let linkOpened = false;
  function openFromLink() {
    if (linkOpened || !st.alive) return;
    linkOpened = true;
    const p = ctx.params ?? {};
    if (p.ou === 'choisir') { picker.open(); return; }
    if (typeof p.section === 'string' && SECTION_LINKS.has(p.section)) setFocus(SECTION_LINKS.get(p.section));
    if (p.personnaliser === '1') board?.setEditing(true);
    if (typeof p.outil === 'string' && TOOLS.has(p.outil)) { openTool(p.outil); return; }
    if (typeof p.postes === 'string' && p.postes) openTargetsFor(p.postes, board?.board()?.entries?.[p.postes]?.title ?? p.postes);
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
      <div class="art">${icon('alert')}</div><h2>Vue d’ensemble indisponible</h2>
      <p>${esc(text)}</p>${err?.code ? `<span class="code">${esc(err.code)}</span>` : ''}
      <button class="btn primary" type="button" data-act="retry">${icon('refresh')}Réessayer</button></div></section>`);
    startReveal(grid);
  }

  // Parameters of a link of the page: the object of a watchlist row; for Rechercher, the working OU (never the whole
  // domain, ACC-031).
  function goParams(el) {
    if (el.dataset.dn) {
      rememberObject({ dn: el.dataset.dn, name: el.dataset.name ?? '', kind: el.dataset.go === 'poste' ? 'poste' : 'objet' });
      return { dn: el.dataset.dn };
    }
    const scope = st.session?.scope;
    if (el.dataset.go === 'rechercher' && scope && !isRootDn(scope.dn)) {
      return { ou: scope.dn, sousou: scope.subtree ? '1' : '0', type: 'computers' };
    }
    return {};
  }

  async function reload({ silent = false } = {}) {
    // One after the other: the summary's own read never counts among the running tasks of session.info.
    const summary = await ctx.call('dashboard.summary');
    const session = await ctx.call('session.info');
    if (!st.alive) return;
    st.summary = summary;
    st.session = session;
    ctx.showConnection?.(session);
    Object.values(summary.widgets).forEach((w) => paintWidget(w));
    paintHero();
    paintPanels();
    await Promise.all([board?.load(), loadSteps()]);
    if (detailsAsked) loadDetails();
    if (!silent) {
      ctx.toast(sim() ? 'Accueil actualisé depuis l’annuaire fictif en mémoire.' : 'Accueil actualisé depuis la base locale.', { tone: 'ok', life: 2600 });
    }
  }

  function mountParts() {
    const boardHost = main.querySelector('[data-slot="board"]');
    board?.destroy();
    let lastSaved = null;
    board = createBoard(boardHost, {
      ctx,
      onTargets: (key, label) => openTargetsFor(key, label),
      onAction: onBoardAction,
      onTool: openTool,
      // « Ouvrir les postes de l’OU dans Rechercher » (Domenia 1, ACC-031): the working OU and its depth, never the domain root.
      onOpenSearch: (check) => {
        const scope = st.session?.scope;
        const ok = Boolean(scope && !isRootDn(scope.dn));
        if (check || !ok) return ok;
        ctx.navigate('rechercher', { ou: scope.dn, sousou: scope.subtree ? '1' : '0', type: 'computers', source: 'accueil' });
        return true;
      },
      onComputed: (b) => {
        // Remembered for the next start of the same base and OU (counts and date only, never a name); the engine writes it
        // only when its counts change, or once a minute.
        if (b.revision === lastSaved) return;
        lastSaved = b.revision;
        ctx.call('accueil.lastView.save', { revision: b.revision }).catch((err) => reported(err));
      },
      onState: (state, b) => {
        st.boardState = { state, machines: b?.population?.enabled };
        paintSteps();
        if (state === 'ready') {
          // Freshness of the branch for the chip of the header (ACC-020), from the calculation just drawn.
          st.directory = b?.directory ?? null;
          paintHero();
          paintPanels();
        }
      },
    });
  }

  // The refresh lives in the hero: mounted once its slots exist (first painting of the hero).
  function mountRefresh() {
    const actions = main.querySelector('[data-slot="refresh-actions"]');
    const status = main.querySelector('[data-slot="refresh-status"]');
    if (!actions || !status) return;
    refresh?.destroy();
    refresh = createRefresh({
      actions,
      status,
      ctx,
      scopeOk,
      onRunning: (on) => {
        st.refreshing = on;
        // During a collection the board is computed again from the measures already recorded, every 15 s at most (ACC-037).
        clearInterval(liveTimer);
        liveTimer = on ? setInterval(() => { if (st.alive && !document.hidden) board?.load(); }, 15_000) : 0;
      },
      onFinished: () => {
        reload({ silent: true }).catch((err) => ctx.toast(reported(err), { tone: 'alert' }));
      },
    });
  }

  async function start() {
    pending.clear();
    st.widgets = {};
    st.summary = null;
    stops.splice(0).forEach((stop) => stop());
    main.innerHTML = skeletonPage();
    paint(main);
    startReveal(main);
    watchSections();
    mountParts();
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
      const [session] = await Promise.all([sessionCall.catch(() => null), loadLastView(), loadFavorites()]);
      st.session = session;
      if (!st.alive) return;
      if (st.session) { ctx.showConnection?.(st.session); paintHero(); }
      st.summary = await summaryCall;
      if (!st.alive) return;
      Object.values(st.summary.widgets).forEach((w) => paintWidget(w));
      const computing = board.load();
      board.showLastView(st.lastView);
      await computing;
      if (!st.alive) return;
      // Session and first steps read again once the summary and the board are done: their reads no longer count among the
      // running tasks, and the « Tableau de bord » step shows as done.
      const [after] = await Promise.all([ctx.call('session.info').catch(() => null), loadSteps()]);
      if (!st.alive) return;
      if (after) st.session = after;
      paintHero();
      paintPanels();
      openFromLink();
      // Session details when the session card first shows (Domenia 1: built only when the fold is open).
      const card = main.querySelector('[data-slot="session"]');
      if (card) whenShown(card, () => { detailsAsked = true; loadDetails(); });
    } catch (err) {
      if (st.alive) showError(err);
    }
  }

  // ----- Events (delegated) -----

  // Link of a top widget to its counterpart in the fleet board: scrolls to the card and gives it the focus, or says how to add it.
  function showRelated(key) {
    const card = main.querySelector(`[data-slot="board"] [data-entry="${CSS.escape(key)}"]`);
    if (!card) {
      ctx.toast(`Ce widget n’est pas dans la disposition du tableau du parc${NBSP}: ajoutez-le depuis «${NBSP}Ajouter un widget${NBSP}».`, { tone: 'info', life: 4200 });
      return;
    }
    card.scrollIntoView({ behavior: motionReduced() ? 'auto' : 'smooth', block: 'center' });
    card.classList.remove('flash');
    void card.offsetWidth;
    card.classList.add('flash');
    const focusable = card.matches('[tabindex]') ? card : card.querySelector('button, [tabindex]');
    focusable?.focus({ preventScroll: true });
  }

  const onClick = (e) => {
    const t = e.target instanceof Element ? e.target : null;
    const related = t?.closest('[data-related]');
    if (related) { showRelated(related.dataset.related); return; }
    const refreshBtn = t?.closest('[data-refresh]');
    if (refreshBtn) {
      const id = refreshBtn.closest('[data-widget]')?.dataset.widget;
      // No measure while « Mesure active » is being changed (the widget may be off already on the engine side).
      if (id && !toggling.has(id) && !refreshBtn.disabled) refreshWidget(id);
      return;
    }
    const nav = t?.closest('[data-nav]');
    if (nav) { scrollToSection(nav.dataset.nav); return; }
    const fav = t?.closest('[data-fav-dn]');
    if (fav) { if (!fav.classList.contains('now')) switchFavorite(fav.dataset.favDn, fav.dataset.favSub === '1'); return; }
    const journey = t?.closest('[data-journey]');
    if (journey) {
      const id = journey.dataset.journey;
      const obj = lastObject();
      if (id === 'find') ctx.navigate('rechercher', goParams({ dataset: { go: 'rechercher' } }));
      else if (id === 'view') { if (obj) ctx.navigate(obj.kind === 'poste' ? 'poste' : 'fiche', { dn: obj.dn }); else ctx.go('fiche'); }
      else ctx.go('requetes');
      return;
    }
    const step = t?.closest('[data-step-act]');
    if (step && !step.disabled) { stepAction(step.dataset.stepAct); return; }
    // A level of the path chooses that OU at once, keeping the depth (Domenia 1, ACC-013); the domain opens the panel.
    const crumb = t?.closest('[data-reveal]');
    if (crumb) {
      if (crumb.dataset.root === '1') picker.open({ revealDn: crumb.dataset.reveal });
      else switchFavorite(crumb.dataset.reveal, st.session?.scope?.subtree !== false);
      return;
    }
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
  const onObject = () => { slotJourney(); if (detailsAsked) paintPanels(); };
  main.addEventListener('click', onClick);
  main.addEventListener('change', onChange);
  window.addEventListener('domenia:refresh-home', onRefreshHome);
  window.addEventListener('domenia:object-selected', onObject);
  ticker = setInterval(() => {
    main.querySelectorAll('[data-rel]').forEach((el) => {
      const text = relTime(el.dataset.rel);
      if (text) el.textContent = `${el.dataset.prefix ?? ''}${text}`;
    });
  }, 30_000);

  start();

  return () => {
    clearTimeout(boardTimer);
    st.alive = false;
    clearInterval(ticker);
    clearInterval(liveTimer);
    main.removeEventListener('click', onClick);
    main.removeEventListener('change', onChange);
    window.removeEventListener('domenia:refresh-home', onRefreshHome);
    window.removeEventListener('domenia:object-selected', onObject);
    stops.forEach((stop) => stop());
    board?.destroy();
    refresh?.destroy();
    // Panels belong to the page: leaving the screen closes them (the kit drawers also close on hashchange).
    picker.destroy();
  };
}

