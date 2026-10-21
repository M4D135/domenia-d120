// Accueil: dashboard of the working OU (hero, KPIs, charts, watchlist, timeline, session and checks).
// Data contract: docs/OPERATIONS.md (session.info, dashboard.summary, dashboard.widget.refresh / setEnabled).
import { icon } from '../icons.js';
import {
  esc, errorText, applyVars, reveal, countUp, progressTo, sparkline, donut, bars, inkFollow, copyText,
  relTime, formatNumber, formatDateTime, formatTime, cssMs,
} from '../ui.js';

const KPI_IDS = ['workstationsOnline', 'activeAccounts', 'lockedAccounts', 'passwordsExpiring', 'diskAlerts'];
const WIDGET_ICONS = {
  workstationsOnline: 'monitor', activeAccounts: 'users', lockedAccounts: 'lock', passwordsExpiring: 'key',
  diskAlerts: 'disk', osDistribution: 'chip', workstationActivity: 'activity', measureFreshness: 'clock',
  watchlist: 'eye', recentOperations: 'zap',
};
const PANELS = [
  { id: 'session', label: 'Session' },
  { id: 'application', label: 'Application' },
  { id: 'store', label: 'Base locale', simulated: 'Données fictives' },
];
// No-break space before « % », as in the engine texts (OPERATIONS.md § 1.2).
const NBSP = '\u00A0';
const pct = (v) => `${formatNumber(v, 1)}${NBSP}%`;
const DAY_MS = 86_400_000;
// Numbers from the bridge written into attributes: always a plain number ("NaN" for a missing measure, shown "—").
const isNum = (v) => typeof v === 'number' && Number.isFinite(v);
const numAttr = (v) => (isNum(v) ? String(v) : 'NaN');
const countText = (v) => (isNum(v) ? formatNumber(v) : 'non mesuré');
const plural = (n, one, many) => `${formatNumber(n)} ${n > 1 ? many : one}`;
const RING = '<span class="glow-ring hero-ring" aria-hidden="true"></span>';
// The simulation (and the browser preview) never opens the local base: its figures come from the fictitious directory
// kept in memory (SIMULATION.md § 1), and the texts say so.
const isSimulated = (s) => s?.connection?.state === 'simulated';
const panelLabel = (p, s) => (isSimulated(s) && p.simulated ? p.simulated : p.label);
// lastSeenAt is null when no answer to the presence check (ping) is recorded, even if WMI answered (OPERATIONS.md § 4.7).
const NO_PING_TIP = 'Aucune réponse au relevé de présence (ping) n’est enregistrée pour ce poste. Le ping peut être filtré : '
  + 'une absence de réponse n’est jamais un verdict d’arrêt.';
const ORBS = '<div class="orbs" aria-hidden="true"><span class="orb a"></span><span class="orb b"></span><span class="orb c"></span></div>';

// ---------- Skeletons ----------

const sk = (cls) => `<span class="skeleton sk ${cls}"></span>`;
const skStack = (...cls) => `<div class="sk-stack">${cls.map(sk).join('')}</div>`;

function skeletonPage() {
  const kpi = (id) => `<article class="card kpi spot tilt reveal" data-widget="${id}">${skStack('sk-line w55', 'sk-value w40', 'sk-line w85', 'sk-line w70')}</article>`;
  const chart = (id, span, body) => `<section class="card ${span} spot reveal" data-widget="${id}"><div class="sk-stack">${sk('sk-line w40')}${body}</div></section>`;
  return `<div class="page home"><div class="grid">
    <section class="hero span-12 reveal" data-slot="hero">
      ${RING}${ORBS}
      ${skStack('sk-line w25', 'sk-title w40', 'sk-line w70', 'sk-line w55')}
    </section>
    <div class="kpi-band">${KPI_IDS.map(kpi).join('')}</div>
    ${chart('osDistribution', 'span-4', sk('sk-ring'))}
    ${chart('workstationActivity', 'span-5', sk('sk-block w100'))}
    ${chart('measureFreshness', 'span-3', sk('sk-ring'))}
    ${chart('watchlist', 'span-7', skStack('sk-line w85', 'sk-line w70', 'sk-line w85', 'sk-line w55'))}
    ${chart('recentOperations', 'span-5', skStack('sk-line w70', 'sk-line w55', 'sk-line w70', 'sk-line w40'))}
    <section class="card span-12 spot reveal" data-slot="session">${skStack('sk-line w25', 'sk-line w100', 'sk-line w85')}</section>
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
  return `<button class="btn ghost icon sm" type="button" data-refresh aria-label="Actualiser ce widget" data-tip="Actualiser ce widget">${icon('refresh')}</button>`;
}

function enabledSwitch(w, withLabel) {
  const text = withLabel ? '<span>Mesure active</span>' : '';
  const tip = withLabel ? '' : ' data-tip="Mesure active"';
  return `<label class="kpi-switch"${tip}><input class="switch" type="checkbox" role="switch" data-toggle aria-label="Mesure active : ${esc(w.title)}"${w.enabled ? ' checked' : ''}>${text}</label>`;
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

// ---------- Widget cards ----------

// Hover tip that keyboard users can reach (tabindex) and screen readers hear (hidden copy of the tip).
function tipSpan(cls, tip, visible) {
  return `<span class="${cls}" tabindex="0" data-tip="${esc(tip)}">${visible}<span class="visually-hidden"> · ${esc(tip)}</span></span>`;
}

function kpiCard(w) {
  const d = w.data;
  const meta = whenText(w);
  const when = meta ? esc(meta) : rel(w.measuredAt);
  let body;
  if (!d) {
    body = offNote(w);
  } else {
    const days = d.history.map((p) => ({ x: Date.parse(p.date) / DAY_MS, value: p.value }));
    const small = d.total != null ? `<small>/ ${formatNumber(d.total)}</small>` : `<small>${esc(d.unit)}</small>`;
    // The final value is in the DOM for assistive technologies; the count-up runs on a hidden twin.
    body = `<div class="kpi-main">
        <div class="value num"><span class="visually-hidden">${esc(countText(d.value))}</span><span data-count="${numAttr(d.value)}" aria-hidden="true">0</span>${small}</div>
        <div class="kpi-trend">${deltaChip(d.delta)}${sparkline(days)}</div>
      </div>
      ${stack(d.breakdown, `${w.title} : ${d.breakdown.map((b) => `${b.label} ${b.value}`).join(', ')}`)}`;
  }
  // With data, the method note only lives in the tip; without data it is already written in the off-note. The tip
  // also gives the full date, since a narrow card may shorten the relative time.
  const measured = formatDateTime(w.measuredAt);
  const foot = d ? tipSpan('when', `${measured ? `Mesuré le ${measured} · ` : ''}${w.scopeLabel} · ${w.detail}`, when)
    : `<span class="when" data-tip="${esc(w.scopeLabel)}">${when}</span>`;
  return `<div class="kpi-top"><span class="card-icon">${icon(WIDGET_ICONS[w.id])}</span>
      <span class="label">${esc(w.title)}</span>${staleChip(w)}${w.enabled ? refreshButton() : ''}</div>
    <div class="card-body">${body}</div>
    <div class="kpi-foot">${enabledSwitch(w, true)}${foot}</div>`;
}

function cardHead(w, extra = '') {
  const meta = whenText(w);
  const when = meta ? esc(meta) : rel(w.measuredAt);
  const where = `${esc(w.scopeLabel)} · ${when}`;
  const scope = w.data ? tipSpan('where', w.detail, where) : `<span data-tip="${esc(w.detail)}">${where}</span>`;
  return `<div class="card-head"><span class="card-icon">${icon(WIDGET_ICONS[w.id])}</span><h3>${esc(w.title)}</h3>
    <span class="meta">${extra}${staleChip(w)}${scope}
    ${w.enabled ? refreshButton() : ''}${enabledSwitch(w, false)}</span></div>`;
}

function osBody(d) {
  // Legend rows take the focus: the matching segment lights up, and the members of « Autres » are read too.
  const legend = d.segments.map((s, n) => {
    const members = s.members?.length ? s.members.join(', ') : '';
    const tip = members ? ` data-tip="${esc(members)}"` : '';
    const more = members ? `<span class="visually-hidden"> : ${esc(members)}</span>` : '';
    return `<li tabindex="0" data-key="${esc(s.key)}" data-j="${n}"${tip}><span class="sw s${(n % 8) + 1}"></span><span class="name">${esc(s.label)}</span>`
      + `<span class="val">${formatNumber(s.value)}</span><span class="pct">${pct(s.percent)}</span>${more}</li>`;
  }).join('');
  const ring = donut(d.segments.map((s) => ({ value: s.value, key: s.key })), {
    total: d.total, label: `${d.centerText} : ${d.segments.map((s) => `${s.label} ${pct(s.percent)}`).join(', ')}`,
    center: `<div><b data-count="${numAttr(d.total)}">0</b><span>${esc(d.unit)}</span></div>`,
  });
  return `<div class="ring-wrap">${ring}<ul class="legend cascade">${legend}</ul></div>`;
}

function activityBody(d) {
  const values = d.points.map((p) => (p.value == null ? null : p.value));
  const labels = d.points.map((p) => p.label);
  const partial = d.points.map((p) => p.partial);
  const aria = `Activité sur 7 jours : ${d.points.map((p) => `${p.label} ${p.value ?? 'sans relevé'}`).join(', ')}`;
  return `${bars(values, labels, { max: d.max || undefined, partial, label: aria })}
    <div class="chart-note"><span><span class="sw"></span>Postes ayant répondu</span><span><span class="sw partial"></span>Aujourd’hui : journée en cours</span></div>`;
}

function freshnessBody(w) {
  const d = w.data;
  const ring = donut([{ value: d.percent, cls: 'toned', tone: w.tone }], {
    total: 100, single: true, size: 'lg', label: `Fraîcheur : ${pct(d.percent)}`,
    center: `<div><b data-count="${numAttr(d.percent)}" data-dec="1" data-suffix="${NBSP}%">0</b><span>${formatNumber(d.fresh)} / ${formatNumber(d.total)}</span></div>`,
  });
  const legend = d.breakdown.map((b, n) => `<li data-j="${n}"><span class="sw" data-tone="${esc(b.tone)}"></span><span class="name">${esc(b.label)}</span><span class="val">${formatNumber(b.value)}</span></li>`).join('');
  return `<div class="ring-wrap stacked">${ring}<ul class="legend cascade">${legend}</ul></div>`;
}

function watchBody(d) {
  if (!d.rows.length) return `<div class="off-note">${icon('check')}<span>Aucun poste à surveiller dans le périmètre.</span></div>`;
  const rows = d.rows.map((r, n) => {
    const seen = r.lastSeenAt ? rel(r.lastSeenAt, 'vu ') : `<span data-tip="${esc(NO_PING_TIP)}">aucune réponse au ping</span>`;
    const more = r.otherReasons > 0
      ? `<span class="more" data-tip="Autres points d’attention">+${formatNumber(r.otherReasons)}<span class="visually-hidden"> ${r.otherReasons > 1 ? 'autres points' : 'autre point'} d’attention</span></span>` : '';
    const sev = r.severity === 'alert' ? 'Critique' : 'À surveiller';
    return `<button class="list-row" type="button" data-go="poste" data-j="${n}" data-tip="${esc(r.dn)}">
      <span class="avatar pc">${icon('monitor')}</span>
      <span class="body"><span class="title">${esc(r.name)}</span><span class="sub">${esc(r.reason)}</span></span>
      ${more}<span class="when">${seen}</span><span class="chip ${r.severity === 'alert' ? 'alert' : 'warn'}"><span class="dot"></span>${sev}</span>
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
  let foot = '';
  if (!d) body = offNote(w);
  else if (w.id === 'osDistribution') {
    // lead is null when the scope holds no enabled computer (DistributionData.Lead).
    if (d.lead) extra = `<span>${esc(d.lead.label)} en tête · ${pct(d.lead.percent)}</span>`;
    body = osBody(d);
  }
  else if (w.id === 'workstationActivity') body = activityBody(d);
  else if (w.id === 'measureFreshness') body = freshnessBody(w);
  else if (w.id === 'watchlist') {
    extra = `<span>${formatNumber(d.shown)} sur ${formatNumber(d.total)}</span>`;
    body = watchBody(d);
    if (d.total > d.shown) foot = `<div class="card-actions"><span class="spacer"></span><button class="btn sm" type="button" data-go="rechercher">${icon('search')}Voir les ${formatNumber(d.total)} postes dans Rechercher</button></div>`;
  } else {
    extra = `<span>${formatNumber(d.rows.length)} sur ${formatNumber(d.total)}</span>`;
    body = timelineBody(d);
    foot = `<div class="card-actions"><span class="spacer"></span><button class="btn sm ghost" type="button" data-go="operations">${icon('activity')}Ouvrir le journal des opérations</button></div>`;
  }
  return `${cardHead(w, extra)}<div class="card-body">${body}</div>${foot}`;
}

// ---------- Hero, stepper and session panels ----------

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

function heroChips(s, lastReadAt) {
  const chips = [];
  if (s.domain?.dnsName) chips.push(`<span class="chip" data-tip="${esc(s.domain.netbiosName ? `NetBIOS : ${s.domain.netbiosName}` : 'Domaine')}">${icon('server')}${esc(s.domain.dnsName)}</span>`);
  if (s.controller) chips.push(`<span class="chip" data-tip="Contrôleur de domaine">${icon('server')}${esc(s.controller.dnsName)}${s.controller.site ? ` · ${esc(s.controller.site)}` : ''}</span>`);
  if (s.scope) chips.push(`<span class="chip" data-tip="${esc(s.scope.dn)}">${icon('folder')}OU ${esc(s.scope.label)}</span>`);
  const simulated = isSimulated(s);
  const readTip = simulated
    ? `Lecture fictive du ${formatDateTime(lastReadAt) ?? '—'} : en simulation, aucune base locale n’est ouverte.`
    : formatDateTime(lastReadAt) ?? '';
  chips.push(lastReadAt
    ? `<span class="chip info" data-tip="${esc(readTip)}">${icon('database')}${rel(lastReadAt, simulated ? 'Annuaire fictif lu ' : 'Base locale lue ')}</span>`
    : `<span class="chip warn">${icon('database')}${simulated ? 'Annuaire fictif non lu' : 'Base locale vide'}</span>`);
  return chips.map((c, n) => c.replace('<span class="chip', `<span data-j="${n}" class="chip`)).join('');
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
  stepper.querySelector('.title').textContent = all ? 'Premiers pas terminés' : 'Premiers pas';
  stepper.querySelector('.count').textContent = `${onb.completed} / ${onb.total}`;
  const bar = stepper.querySelector('.progress');
  bar.setAttribute('aria-valuenow', String(onb.completed));
  bar.setAttribute('aria-valuetext', `${plural(onb.completed, 'étape faite', 'étapes faites')} sur ${formatNumber(onb.total)}`);
  progressTo(bar.firstElementChild, onb.total ? onb.completed / onb.total : 0);
}

// Hero content; the rotating ring and the orbs come from the skeleton and stay, so their motion never restarts.
function heroMarkup(s, lastReadAt) {
  const name = s.account?.givenName ? `Bonjour ${s.account.givenName}` : 'Bonjour';
  return `<div class="eyebrow">${icon('sparkles')}Tableau de bord${s.scope ? ` · OU ${esc(s.scope.label)}` : ''}</div>
    <h1 class="gradient-text">${esc(name)}</h1>
    <p class="lead">${esc(leadText(s))}</p>
    <div class="chips">${heroChips(s, lastReadAt)}</div>
    <div class="hero-row">
      <button class="btn primary" type="button" data-act="refresh-all">${icon('refresh')}<span class="label-progress">Tout actualiser</span></button>
      <button class="btn" type="button" data-act="scope">${icon('folder')}Choisir l’OU</button>
      <button class="btn" type="button" data-act="queries">${icon('database')}Ouvrir l’atelier de requêtes</button>
    </div>
    ${stepperMarkup(s.onboarding)}`;
}

const kv = (label, value, sub = '') => `<div><dt>${esc(label)}</dt><dd>${esc(value ?? '—')}${sub ? `<span class="sub">${esc(sub)}</span>` : ''}</dd></div>`;

const ENGINES = { embarque: 'Moteur fixe du pack', windows: 'Moteur WebView2 de Windows', apercu: 'Navigateur (aperçu)' };

function panelRows(id, s, app, summary) {
  if (id === 'session') {
    if (!s) return [['Session', 'Indisponible']];
    return [
      ['Domaine', s.domain?.dnsName ?? 'Non connecté', s.domain?.netbiosName ? `NetBIOS ${s.domain.netbiosName}` : ''],
      ['Contrôleur de domaine', s.controller?.dnsName ?? 'Non connecté', s.controller?.site ? `Site ${s.controller.site}` : ''],
      ['Compte utilisé pour l’annuaire', s.account?.login, s.account?.displayName ?? ''],
      ['Mode de connexion', s.authentication?.label],
      ['Racine de l’annuaire', s.domain?.rootDn ?? '—'],
      ['Branche affichée', s.scope?.dn ?? 'Aucune OU choisie', s.scope ? (s.scope.subtree ? 'Sous-OU comprises' : 'Cette OU seulement') : ''],
      ['Estimation des droits', s.rights?.label, s.rights?.detail ?? ''],
      ['Lecture seule', s.readOnly ? 'Activée' : 'Désactivée'],
      ['Tâches', `${formatNumber(s.tasks?.running ?? 0)} en cours · ${formatNumber(s.tasks?.queued ?? 0)} en attente`],
      ['Connexion', s.connection?.label],
    ];
  }
  if (id === 'application') {
    if (!app) return [['Application', 'Informations indisponibles']];
    const chromium = /Chrome\/([\d.]+)/.exec(navigator.userAgent)?.[1];
    // The engine's banner text is shown as is (null in directory mode, OPERATIONS.md § 2).
    const banner = typeof app.banner === 'string' && app.banner ? [['Bannière', app.banner]] : [];
    return [
      ['Application', `${app.name} ${app.version}`],
      ['Mode', app.modeLabel ?? app.mode, app.modeDetail ?? ''],
      ...banner,
      ['Moteur web', ENGINES[app.webViewRuntime] ?? app.webViewRuntime, chromium ? `Chromium ${chromium}` : ''],
      ['.NET embarqué', app.runtime],
      ['Affichage', document.documentElement.dataset.theme === 'dark' ? 'Thème sombre' : document.documentElement.dataset.theme === 'contrast' ? 'Contraste élevé' : 'Thème clair',
        document.documentElement.dataset.motion === 'reduced' ? 'Animations réduites' : document.documentElement.dataset.motion === 'system' ? 'Animations : suivre Windows' : 'Animations riches'],
    ];
  }
  const store = summary?.store;
  const cache = s?.cache;
  const simulated = isSimulated(s);
  const rows = [
    ['État', cache?.label ?? '—'],
    [simulated ? 'Lecture de l’annuaire fictif' : 'Dernière lecture de l’annuaire', formatDateTime(store?.lastReadAt ?? cache?.lastReadAt) ?? 'Jamais', relTime(store?.lastReadAt ?? cache?.lastReadAt) ?? ''],
    [simulated ? 'Objets de l’annuaire fictif' : 'Objets enregistrés', formatNumber(store?.objects ?? cache?.objects ?? 0)],
    ['Lecture complète', (store?.complete ?? cache?.complete) ? 'Oui' : 'Non : chiffres possiblement sous-estimés'],
    ['OU de travail', summary?.scope?.label ?? s?.scope?.label ?? '—', summary?.scope?.dn ?? s?.scope?.dn ?? ''],
    ['Tableau de bord calculé', formatDateTime(summary?.generatedAt) ?? '—',
      summary ? (simulated ? 'Depuis l’annuaire fictif en mémoire, sans lecture réseau' : 'Depuis la base locale, sans lecture réseau') : ''],
  ];
  if (simulated) rows.push(['Base locale', 'Jamais ouverte en simulation', 'Aucune donnée fictive n’y entre']);
  return rows;
}

function sessionMarkup(s) {
  const tabs = PANELS.map((p, n) => `<button type="button" role="tab" id="tab-${p.id}" aria-controls="panel-${p.id}" aria-selected="${n === 0}" tabindex="${n === 0 ? 0 : -1}">${esc(panelLabel(p, s))}</button>`).join('');
  const panels = PANELS.map((p, n) => `<div class="tab-panel" role="tabpanel" id="panel-${p.id}" aria-labelledby="tab-${p.id}"${n ? ' hidden' : ''}><dl class="kv cascade"></dl></div>`).join('');
  return `<div class="card-head"><span class="card-icon">${icon('shield')}</span><h3>Session et vérifications</h3>
      <span class="meta">Informations déjà chargées, sans lecture réseau</span></div>
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
  const st = { session: null, summary: null, app: null, widgets: {}, alive: true, refreshing: false };
  const pending = new Map();
  const busy = new Map(); // widget id → measurements in flight
  const toggling = new Set(); // widgets whose « Mesure active » change is not confirmed yet
  const stops = [];
  let ink = null;
  let ticker = 0;

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
      applyVars(card);
      if (w.id === 'osDistribution') bindLegend(card);
    } catch (err) {
      // One unexpected widget must not take the whole dashboard down: only its own card shows the problem.
      console.error(`Widget « ${w.id} » : affichage impossible`, err, w);
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
    card.innerHTML = `<div class="card-head"><span class="card-icon">${icon('alert')}</span><h3>${esc(w.title ?? 'Widget')}</h3></div>
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
      ctx.toast(enabled ? `Mesure réactivée : ${w.title}.` : `Mesure désactivée : ${w.title}. Aucune lecture n’est faite pour ce widget.`, { tone: 'info', life: 3600 });
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

  // ----- Hero and session -----

  function paintHero() {
    const hero = main.querySelector('[data-slot="hero"]');
    if (!hero || !st.session) return;
    const lastReadAt = st.summary?.store?.lastReadAt ?? st.session.cache?.lastReadAt ?? null;
    if (!hero.querySelector('h1')) {
      // Keep the ring and the orbs of the skeleton: only the content is replaced.
      [...hero.children].forEach((el) => { if (!el.matches('.orbs, .glow-ring')) el.remove(); });
      hero.insertAdjacentHTML('beforeend', heroMarkup(st.session, lastReadAt));
      applyVars(hero);
    } else {
      hero.querySelector('.chips').innerHTML = heroChips(st.session, lastReadAt);
      hero.querySelector('.lead').textContent = leadText(st.session);
      applyVars(hero.querySelector('.chips'));
    }
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
      slot.innerHTML = sessionMarkup(st.session);
      bindTabs(slot);
    }
    PANELS.forEach((p) => {
      const tab = slot.querySelector(`#tab-${p.id}`);
      if (tab && tab.textContent !== panelLabel(p, st.session)) tab.textContent = panelLabel(p, st.session);
      const dl = slot.querySelector(`#panel-${p.id} dl`);
      dl.innerHTML = panelRows(p.id, st.session, st.app, st.summary).map((r) => kv(...r)).join('');
      dl.querySelectorAll(':scope > div').forEach((div, n) => div.dataset.j = String(Math.min(n, 12)));
      applyVars(dl);
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
        `Compte : ${s.account?.login ?? '—'}`, `OU de travail : ${s.scope?.dn ?? 'aucune'}`);
    }
    for (const w of Object.values(st.widgets)) {
      const d = w.data;
      let value = w.enabled ? 'aucune mesure' : 'mesure désactivée';
      try {
        if (d && w.kind === 'kpi') value = `${formatNumber(d.value)}${d.total != null ? ` / ${formatNumber(d.total)}` : ` ${d.unit}`}${d.delta ? ` (${d.delta.label})` : ''}`;
        else if (d && w.kind === 'gauge') value = `${pct(d.percent)} (${formatNumber(d.fresh)} / ${formatNumber(d.total)})`;
        else if (d && w.kind === 'distribution') value = d.segments.map((x) => `${x.label} ${pct(x.percent)}`).join(', ');
        else if (d && w.kind === 'series') value = d.points.map((p) => `${p.label} ${p.value ?? '—'}`).join(', ');
        else if (d && w.kind === 'list') value = `${formatNumber(d.total)} postes : ${d.rows.map((r) => `${r.name} (${r.reason})`).join(' ; ')}`;
        else if (d && w.kind === 'timeline') value = d.rows.map((r) => r.label).join(' ; ');
      } catch (err) {
        console.error(`Widget « ${w.id} » : copie impossible`, err, w);
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

  function onAction(btn) {
    const act = btn.dataset.act;
    if (act === 'refresh-all') refreshAll(btn);
    else if (act === 'scope') {
      const ou = st.session?.scope?.label;
      ctx.toast(`Le choix de l’OU de travail arrive dans une prochaine étape ; ${ou ? `le périmètre reste l’OU ${ou}.` : 'aucune OU de travail n’est encore choisie.'}`, { tone: 'info' });
    }
    else if (act === 'queries') ctx.go('requetes');
    else if (act === 'check') checkApplication(btn);
    else if (act === 'cache') ctx.toast('Vider le cache arrive dans une prochaine étape. Aucun objet Active Directory n’est modifié.', { tone: 'info' });
    else if (act === 'journal') ctx.go('operations');
    else if (act === 'copy') copySummary();
    else if (act === 'retry') start();
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

  async function reload({ silent = false } = {}) {
    const [summary, session] = await Promise.all([ctx.call('dashboard.summary'), ctx.call('session.info')]);
    if (!st.alive) return;
    st.summary = summary;
    st.session = session;
    ctx.showConnection?.(session);
    Object.values(summary.widgets).forEach((w) => paintWidget(w));
    paintHero();
    paintPanels();
    // The "dashboard" onboarding step completes once a summary succeeded: show it.
    if (session.onboarding?.completed < session.onboarding?.total) {
      const after = await ctx.call('session.info').catch(() => null);
      if (after && st.alive) { st.session = after; paintHero(); paintPanels(); }
    }
    if (!silent) {
      ctx.toast(isSimulated(st.session) ? 'Accueil actualisé depuis l’annuaire fictif en mémoire.' : 'Accueil actualisé depuis la base locale.', { tone: 'ok', life: 2600 });
    }
  }

  async function start() {
    pending.clear();
    st.widgets = {};
    st.summary = null;
    stops.splice(0).forEach((stop) => stop());
    main.innerHTML = skeletonPage();
    applyVars(main);
    startReveal(main);
    ctx.app.then((app) => { if (!st.alive) return; st.app = app; if (st.summary) paintPanels(); });
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
      paintHero();
      paintPanels();
      const onb = st.session?.onboarding;
      if (onb && onb.completed < onb.total) {
        const after = await ctx.call('session.info').catch(() => null);
        if (after && st.alive) { st.session = after; paintHero(); paintPanels(); }
      }
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
    const act = t?.closest('[data-act]');
    if (act) { onAction(act); return; }
    const go = t?.closest('[data-go]');
    if (go) ctx.go(go.dataset.go);
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
  };
}
