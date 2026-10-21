// Browser preview of the bridge: same operations and shapes as docs/OPERATIONS.md, fictitious example.local
// directory (values from docs/SIMULATION.md § 4-5). Nothing leaves the page; state lives in memory only.
// Texts follow OPERATIONS.md § 1.2: the space before « : » and « % » is a no-break space (U+00A0) in the strings.

const MIN = 60_000;
const HOUR = 60 * MIN;
const DAY = 24 * HOUR;
const MINUS = '−';
const REF = Date.now();
const TOTAL = 412;
const OBJECTS = 1826;
const DOMAIN = 'example.local';
const SCOPE = { dn: 'OU=Postes,DC=example,DC=local', label: 'Postes', subtree: true };
const DAY_LABELS = ['dim.', 'lun.', 'mar.', 'mer.', 'jeu.', 'ven.', 'sam.'];
const WIDGET_IDS = [
  'workstationsOnline', 'activeAccounts', 'lockedAccounts', 'passwordsExpiring', 'diskAlerts',
  'osDistribution', 'workstationActivity', 'measureFreshness', 'watchlist', 'recentOperations',
];

// ---------- Helpers ----------

const fr = new Intl.NumberFormat('fr-FR'); // U+202F group separator, as the contract requires
const pad = (n) => String(n).padStart(2, '0');
const iso = (t) => new Date(t).toISOString().replace(/\.\d{3}Z$/, 'Z');
const localDate = (t) => { const d = new Date(t); return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`; };
const isWeekend = (t) => [0, 6].includes(new Date(t).getDay());
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const clone = (v) => (typeof structuredClone === 'function' ? structuredClone(v) : JSON.parse(JSON.stringify(v)));

function seeded(seed) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6D2B79F5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}
const rand = seeded(Number(localDate(REF).replaceAll('-', '')));
const between = (lo, hi) => lo + Math.floor(rand() * (hi - lo + 1));

function fail(code, message) {
  return Object.assign(new Error(message), { code });
}

// ---------- Fictitious directory and readings ----------

const profile = isWeekend(REF) ? { online: 61, noAnswer: 324, notChecked: 27 } : { online: 287, noAnswer: 98, notChecked: 27 };
const days = Array.from({ length: 14 }, (_, n) => REF - (13 - n) * DAY);

function buildHistory() {
  const online = days.map((t, n) => (n === 13 ? profile.online : isWeekend(t) ? between(48, 70) : between(265, 300)));
  const seen = days.map((t, n) => (n === 13 ? online[n] : online[n] + (isWeekend(t) ? between(5, 12) : between(8, 25))));
  const active = new Array(14);
  active[13] = 1186;
  for (let n = 12; n >= 0; n--) active[n] = active[n + 1] - [0, 0, 1, 2, 3][between(0, 4)];
  const locked = days.map((_, n) => (n === 13 ? 7 : between(0, 12)));
  const expiring = days.map((_, n) => (n === 13 ? 23 : between(15, 26)));
  const disk = days.map((_, n) => (n === 13 ? 9 : between(6, 11)));
  return { online, seen, active, locked, expiring, disk };
}

const JOURNAL = [
  [12 * MIN, `Lecture de l’annuaire : ${fr.format(OBJECTS)} objets`, 'ok'],
  [28 * MIN, 'Relevé de présence de l’OU Paris : 158 en ligne sur 186', 'ok'],
  [55 * MIN, 'Relevé d’inventaire de l’OU Lyon : 74 postes sur 82', 'ok'],
  [99 * MIN, 'Diagnostic de verrouillage : Camille Bernard', 'warn'],
  [201 * MIN, 'Lecture BitLocker refusée pour l’OU Marseille', 'alert'],
  [226 * MIN, 'Recherche « dupont » : 12 résultats', 'info'],
  [302 * MIN, 'Relevé de présence de l’OU Lyon : 61 en ligne sur 82', 'ok'],
  [390 * MIN, 'Export des comptes verrouillés : 7 lignes', 'info'],
  [DAY + HOUR, `Lecture de l’annuaire : ${fr.format(1824)} objets`, 'ok'],
  [DAY + 2 * HOUR, 'Relevé d’inventaire de l’OU Paris : 171 postes sur 186', 'ok'],
  [DAY + 4 * HOUR, 'Relevé de présence de l’OU Marseille : sondes refusées pour 3 postes', 'warn'],
  [2 * DAY, 'Requête « Postes sans LAPS » : 23 résultats', 'info'],
  [2 * DAY + 3 * HOUR, `Lecture de l’annuaire : ${fr.format(1821)} objets`, 'ok'],
  [3 * DAY, 'Première lecture de l’OU Postes : 431 comptes ordinateur', 'ok'],
].map(([ago, label, tone]) => ({ label, at: iso(REF - ago), tone }));

const WATCH = [
  ['PC-LYO-0031', 'Lyon', '3f2a9c41-7b0e-4d6a-9e15-0c4b8d2f6a17', '3,1', 28 * MIN],
  ['PT-PAR-0118', 'Paris', '8d41e0b2-55c9-4f3e-a2d7-61f09b3c4e88', '4,0', 39 * MIN],
  ['PC-MRS-0007', 'Marseille', 'c07b5e13-2a8f-4b91-8d3c-9e6a14f702d5', '5,2', DAY + 2 * HOUR + 14 * MIN],
  ['PC-PAR-0142', 'Paris', '5ae9d270-1c4b-4e8f-b6a0-27d38c91fe04', '6,4', 34 * MIN],
  ['PT-LIL-0012', 'Lille', '91c6f8a3-6d2e-4a07-9b54-e80f3d1a2c69', '7,7', null],
  ['PC-BDX-0021', 'Bordeaux', 'e4b0137c-9f5a-4c2d-8e61-a3d75b0c9f12', '8,3', 2 * DAY + 6 * HOUR + 28 * MIN],
].map(([name, ou, guid, free, ago]) => ({
  name, dn: `CN=${name},OU=${ou},OU=Postes,DC=example,DC=local`, objectGuid: guid, ruleId: 'lowDisk',
  reason: `Disque C: presque plein : ${free} % libre`, severity: 'alert', otherReasons: 0,
  lastSeenAt: ago === null ? null : iso(REF - ago),
}));

const state = {
  history: buildHistory(),
  presence: { ...profile },
  freshness: { recent: 346, aging: 39, expired: 15, never: 12 },
  measured: { annuaire: REF - 12 * MIN, presence: REF - 28 * MIN, inventory: REF - 55 * MIN },
  enabled: Object.fromEntries(WIDGET_IDS.map((id) => [id, true])),
  journal: [...JOURNAL],
  round: 0,
  running: 0,
  queued: 0,
  dashboardDone: false,
};
// Refreshes run one after the other, as in the engine (OPERATIONS.md § 6).
let refreshChain = Promise.resolve();
const presenceRand = seeded(Number(localDate(REF).replaceAll('-', '')) ^ 0x5eed);

function log(label, tone) {
  state.journal.unshift({ label, at: iso(Date.now()), tone });
}

// One deterministic presence round (SIMULATION.md § 5.3): every active workstation is probed now.
function presenceRound() {
  state.round += 1;
  const online = profile.online + Math.floor(presenceRand() * 13) - 6;
  state.presence = { online, noAnswer: TOTAL - online - 3, notChecked: 3 };
  state.freshness = { recent: TOTAL - 3, aging: 0, expired: 0, never: 3 };
  const h = state.history;
  h.online[13] = online;
  h.seen[13] = Math.max(h.seen[13], online) + Math.floor(presenceRand() * 3);
  state.measured.presence = Date.now();
}

// ---------- Widgets ----------

const META = {
  workstationsOnline: { kind: 'kpi', title: 'Postes en ligne', scope: 'ou', family: 'presence' },
  activeAccounts: { kind: 'kpi', title: 'Comptes actifs', scope: 'domain', family: 'annuaire' },
  lockedAccounts: { kind: 'kpi', title: 'Comptes verrouillés', scope: 'domain', family: 'annuaire' },
  passwordsExpiring: { kind: 'kpi', title: 'Mots de passe expirant sous 7 jours', scope: 'domain', family: 'annuaire' },
  diskAlerts: { kind: 'kpi', title: 'Alertes disque', scope: 'ou', family: 'inventory' },
  osDistribution: { kind: 'distribution', title: 'Systèmes d’exploitation', scope: 'ou', family: 'annuaire' },
  workstationActivity: { kind: 'series', title: 'Activité des postes · 7 jours', scope: 'ou', family: 'local' },
  measureFreshness: { kind: 'gauge', title: 'Fraîcheur des mesures', scope: 'ou', family: 'presence' },
  watchlist: { kind: 'list', title: 'Postes à surveiller', scope: 'ou', family: 'local' },
  recentOperations: { kind: 'timeline', title: 'Dernières opérations', scope: 'session', family: 'local' },
};
const SCOPE_LABELS = { domain: `Domaine ${DOMAIN}`, ou: `OU ${SCOPE.label}`, session: 'Session' };

function upDown(value, up, down) {
  return value > 0 ? up : value < 0 ? down : 'info';
}

function delta(series, rule) {
  const now = series[13]; const before = series[6];
  if (!Number.isFinite(now) || !Number.isFinite(before)) return null;
  const value = now - before;
  const label = value > 0 ? `+${fr.format(value)} sur 7 jours`
    : value < 0 ? `${MINUS}${fr.format(-value)} sur 7 jours` : 'Stable sur 7 jours';
  return { value, period: 'P7D', label, tone: rule(value) };
}

const history = (series) => series.map((value, n) => ({ date: localDate(days[n]), value }));
const part = (key, label, value, tone) => ({ key, label, value, tone });

function kpiData(id) {
  const h = state.history; const p = state.presence;
  switch (id) {
    case 'workstationsOnline':
      return { value: p.online, total: TOTAL, unit: 'postes', delta: delta(h.online, () => 'info'), history: history(h.online),
        breakdown: [part('online', 'En ligne', p.online, 'ok'), part('noAnswer', 'Sans réponse', p.noAnswer, 'warn'), part('notChecked', 'Non vérifié', p.notChecked, 'off')] };
    case 'activeAccounts':
      return { value: h.active[13], total: null, unit: 'comptes', delta: delta(h.active, () => 'info'), history: history(h.active),
        breakdown: [part('enabled', 'Actifs', h.active[13], 'ok'), part('disabled', 'Désactivés', 72, 'off')] };
    case 'lockedAccounts':
      return { value: h.locked[13], total: null, unit: 'comptes', delta: delta(h.locked, (v) => upDown(v, 'alert', 'ok')), history: history(h.locked),
        breakdown: [part('locked', 'Verrouillés', h.locked[13], 'alert'), part('toCheck', 'À vérifier', 0, 'off')] };
    case 'passwordsExpiring':
      return { value: h.expiring[13], total: null, unit: 'comptes', delta: delta(h.expiring, (v) => upDown(v, 'warn', 'ok')), history: history(h.expiring),
        breakdown: [part('expiring', 'Expirent sous 7 jours', h.expiring[13], 'warn'), part('expired', 'Déjà expirés', 11, 'alert'),
          part('mustChange', 'À changer à la prochaine connexion', 4, 'info'), part('neverExpires', 'N’expirent jamais', 16, 'off')] };
    default:
      return { value: h.disk[13], total: null, unit: 'postes', delta: delta(h.disk, (v) => upDown(v, 'alert', 'ok')), history: history(h.disk),
        breakdown: [part('critical', 'Moins de 10 % libre', 9, 'alert'), part('tight', '10 à 20 % libre', 17, 'warn'),
          part('healthy', '20 % et plus', 345, 'ok'), part('unknown', 'Sans relevé', 41, 'off')] };
  }
}

function osData() {
  return {
    total: TOTAL, unit: 'postes', centerText: `${fr.format(TOTAL)} postes`,
    segments: [
      { key: 'w11-24h2', label: 'Windows 11 24H2', value: 223, percent: 54.1, members: [] },
      { key: 'w11-23h2', label: 'Windows 11 23H2', value: 96, percent: 23.3, members: [] },
      { key: 'w11-25h2', label: 'Windows 11 25H2', value: 58, percent: 14.1, members: [] },
      { key: 'w10-22h2', label: 'Windows 10 22H2', value: 23, percent: 5.6, members: [] },
      { key: 'autres', label: 'Autres', value: 12, percent: 2.9, members: ['Windows 10 LTSC 2021'] },
    ],
    lead: { label: 'Windows 11 24H2', percent: 54.1 },
  };
}

function activityData() {
  const seen = state.history.seen.slice(7);
  const points = days.slice(7).map((t, n) => ({
    date: localDate(t), label: DAY_LABELS[new Date(t).getDay()], value: seen[n], partial: n === 6,
  }));
  return { unit: 'postes', max: Math.max(0, ...points.map((p) => p.value ?? 0)), points };
}

function freshnessData() {
  const f = state.freshness;
  return {
    percent: Math.round((f.recent / TOTAL) * 1000) / 10, fresh: f.recent, total: TOTAL, freshDays: 7,
    breakdown: [part('recent', 'Moins de 7 jours', f.recent, 'ok'), part('aging', '7 à 30 jours', f.aging, 'warn'),
      part('expired', 'Plus de 30 jours', f.expired, 'alert'), part('never', 'Jamais relevé', f.never, 'off')],
  };
}

const DETAILS = {
  workstationsOnline: 'Dernier relevé de présence de moins de 30 jours. Une absence de réponse ne prouve pas que le poste est éteint.',
  activeAccounts: 'Comptes utilisateurs activés de tout le domaine (userAccountControl).',
  lockedAccounts: 'Verrouillage calculé par le contrôleur (msDS-User-Account-Control-Computed), comptes actifs.',
  passwordsExpiring: 'Expiration calculée par le contrôleur (msDS-UserPasswordExpiryTimeComputed), comptes actifs.',
  diskAlerts: `Moins de 10 % libre sur C: · 371 postes relevés sur ${TOTAL}.`,
  osDistribution: 'Attributs operatingSystem et operatingSystemVersion des comptes ordinateur activés.',
  workstationActivity: 'Postes distincts ayant répondu au relevé de présence, par jour. Aujourd’hui : journée en cours.',
  measureFreshness: 'Postes actifs dont le dernier relevé de présence date de moins de 7 jours.',
  watchlist: '63 postes avec au moins un point d’attention, du plus grave au moins grave.',
  recentOperations: 'Journal fictif de l’aperçu, les plus récentes d’abord.',
};

function dataOf(id) {
  if (META[id].kind === 'kpi') return kpiData(id);
  if (id === 'osDistribution') return osData();
  if (id === 'workstationActivity') return activityData();
  if (id === 'measureFreshness') return freshnessData();
  if (id === 'watchlist') return { total: 63, shown: WATCH.length, rows: WATCH };
  return { total: state.journal.length, rows: state.journal.slice(0, 6) };
}

function toneOf(id, data) {
  switch (id) {
    case 'lockedAccounts': return data.value > 0 ? 'alert' : 'ok';
    case 'passwordsExpiring': return data.value > 0 ? 'warn' : 'ok';
    case 'diskAlerts': {
      const [critical, tight] = data.breakdown;
      return critical.value > 0 ? 'alert' : tight.value > 0 ? 'warn' : 'ok';
    }
    case 'measureFreshness': return data.percent >= 90 ? 'ok' : data.percent >= 60 ? 'warn' : 'alert';
    case 'watchlist': return data.rows.some((r) => r.severity === 'alert') ? 'alert' : data.rows.length ? 'warn' : 'ok';
    default: return 'info';
  }
}

function measuredOf(id, now) {
  const m = state.measured;
  if (id === 'workstationActivity') return now;
  if (id === 'watchlist') return Math.min(m.annuaire, m.presence, m.inventory);
  if (id === 'recentOperations') return Date.parse(state.journal[0].at);
  return m[META[id].family];
}

function widget(id, now = Date.now()) {
  const meta = META[id];
  const base = { id, kind: meta.kind, title: meta.title, scopeLabel: SCOPE_LABELS[meta.scope] };
  if (!state.enabled[id]) {
    return { ...base, enabled: false, tone: 'off', measuredAt: null, stale: false,
      detail: 'Mesure désactivée : ce widget ne lit rien tant qu’il n’est pas réactivé.', data: null };
  }
  const data = dataOf(id);
  const measuredAt = measuredOf(id, now);
  const stale = now - measuredAt > 7 * DAY;
  return { ...base, enabled: true, tone: stale ? 'off' : toneOf(id, data), measuredAt: iso(measuredAt), stale, detail: DETAILS[id], data: clone(data) };
}

// ---------- Arguments (same rules and texts as the engine) ----------

const invalid = (why) => fail('arguments.invalid', `Arguments invalides : ${why}`);

function noArgs(args) {
  if (args == null) return;
  if (typeof args !== 'object' || Array.isArray(args)) throw invalid('un objet JSON est attendu.');
  if (Object.keys(args).length) throw invalid('cette opération n’en accepte aucun.');
}

function widgetArgs(args, withEnabled) {
  if (args == null || typeof args !== 'object' || Array.isArray(args)) throw invalid('un objet JSON est attendu.');
  const allowed = withEnabled ? ['id', 'enabled'] : ['id'];
  if (Object.keys(args).some((k) => !allowed.includes(k))) throw invalid('propriété non admise.');
  if (typeof args.id !== 'string') throw invalid('« id » est obligatoire et doit être un texte.');
  if (withEnabled && typeof args.enabled !== 'boolean') throw invalid('« enabled » est obligatoire et doit valoir true ou false.');
  if (!WIDGET_IDS.includes(args.id)) {
    throw fail('widget.unknown', withEnabled ? 'Widget inconnu : rien n’a été changé.' : 'Widget inconnu : rien n’a été lu.');
  }
}

// ---------- Operations ----------

// Contract values only (OPERATIONS.md § 2): the preview is a simulation, recognised by webViewRuntime "apercu".
// No modeReason describes a browser preview yet; "argument" (simulation chosen at launch) is the closest one.
function appInfo() {
  return {
    name: 'Domenia', version: '2.0.0-dev', runtime: '10.0.12', webViewRuntime: 'apercu',
    mode: 'simulation', modeLabel: 'Simulation', modeReason: 'argument',
    modeDetail: 'Ouvert dans un navigateur : la page répond avec sa maquette intégrée.',
    banner: `Aperçu : annuaire fictif ${DOMAIN} intégré à la page, aucune requête ne part et rien n’est écrit.`,
  };
}

function sessionInfo() {
  const steps = [
    { id: 'connect', label: 'Connexion à l’annuaire', done: true },
    { id: 'scope', label: 'Choix de l’OU de travail', done: true },
    { id: 'firstRead', label: 'Première lecture', done: true },
    { id: 'dashboard', label: 'Tableau de bord', done: state.dashboardDone },
  ];
  return {
    connection: { state: 'simulated', label: 'Annuaire simulé' },
    domain: { dnsName: DOMAIN, netbiosName: 'EXAMPLE', rootDn: 'DC=example,DC=local' },
    controller: { dnsName: 'DC01.example.local', site: 'Paris' },
    account: { login: 'EXAMPLE\\j.martin', displayName: 'Julien Martin', givenName: 'Julien',
      dn: 'CN=Julien Martin,OU=Informatique,OU=Paris,OU=Utilisateurs,DC=example,DC=local' },
    authentication: { method: 'none', protocol: null, label: 'Aucune (simulation)' },
    scope: { ...SCOPE },
    rights: { level: 'read', label: 'Lecture', estimated: true, detail: 'Aperçu : les droits sont fictifs et aucune écriture n’est possible.' },
    readOnly: true,
    tasks: { running: state.running, queued: state.queued },
    cache: { state: 'fresh', label: 'À jour', lastReadAt: iso(REF - 12 * MIN), objects: OBJECTS, complete: true },
    onboarding: { steps, completed: steps.filter((s) => s.done).length, total: steps.length },
  };
}

function summary() {
  const now = Date.now();
  state.dashboardDone = true;
  return {
    generatedAt: iso(now),
    scope: { ...SCOPE },
    store: { lastReadAt: iso(REF - 12 * MIN), objects: OBJECTS, complete: true },
    widgets: Object.fromEntries(WIDGET_IDS.map((id) => [id, widget(id, now)])),
  };
}

async function measure(id) {
  state.queued -= 1;
  state.running += 1;
  try {
    await sleep(400 + Math.floor(Math.random() * 500));
  } finally {
    state.running -= 1;
  }
  if (!state.enabled[id]) return widget(id); // disabled meanwhile: not published
  const family = META[id].family;
  if (family === 'presence') presenceRound();
  else if (family === 'annuaire') state.measured.annuaire = Date.now();
  else if (family === 'inventory') state.measured.inventory = Date.now();
  log(`Actualisation : ${META[id].title}`, 'ok');
  return widget(id);
}

function refresh(args) {
  widgetArgs(args, false);
  const { id } = args;
  if (!state.enabled[id]) {
    throw fail('widget.disabled', 'Ce widget est désactivé : aucune mesure n’est faite. Réactivez « Mesure active » pour l’actualiser.');
  }
  state.queued += 1;
  const turn = refreshChain.then(() => measure(id));
  refreshChain = turn.catch(() => {});
  return turn;
}

function setEnabled(args) {
  widgetArgs(args, true);
  const { id, enabled } = args;
  if (state.enabled[id] !== enabled) {
    state.enabled[id] = enabled;
    log(`${enabled ? 'Mesure réactivée' : 'Mesure désactivée'} : ${META[id].title}`, 'info');
  }
  return widget(id);
}

const OPERATIONS = {
  'app.info': (args) => { noArgs(args); return appInfo(); },
  'session.info': (args) => { noArgs(args); return sessionInfo(); },
  'dashboard.summary': (args) => { noArgs(args); return summary(); },
  'dashboard.widget.refresh': refresh,
  'dashboard.widget.setEnabled': setEnabled,
};

export async function mockCall(op, args) {
  const handler = Object.hasOwn(OPERATIONS, op) ? OPERATIONS[op] : null;
  if (op !== 'dashboard.widget.refresh') await sleep(300 + Math.floor(Math.random() * 600));
  if (!handler) throw fail('operation.unknown', 'Opération inconnue : rien n’a été exécuté.');
  return clone(await handler(args));
}
