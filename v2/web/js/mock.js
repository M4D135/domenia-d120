// Browser preview of the bridge (no WebView2 host): same operations, result shapes, error codes and messages as the
// engine (docs/OPERATIONS.md; src/Domenia.Bridge, src/Domenia.Core/Dashboard), on the fictitious example.local directory
// of the simulation with the figures of the day of its default seed (docs/SIMULATION.md § 4 and 5). Nothing leaves the
// page and the state lives in memory only. Only app.info says that this is a browser preview (webViewRuntime "apercu",
// its own detail and banner). Texts follow OPERATIONS.md § 1.2, written with the helpers below: U+00A0 before « : » and
// « % » and inside « », U+202F between thousands, U+2212 minus sign, decimal comma.

const MIN = 60_000;
const HOUR = 60 * MIN;
const DAY = 24 * HOUR;
const NBSP = ' ';
const COLON = `${NBSP}: `;
const SEED = 20261021;

// Default seed of the simulation (SIMULATION.md § 4.2 to 4.5 and 5.1).
const DOMAIN = 'example.local';
const ROOT_DN = 'DC=example,DC=local';
const SCOPE = { dn: `OU=Postes,${ROOT_DN}`, label: 'Postes', subtree: true };
const OBJECTS = 1826;
const USERS = 1258;
const ACTIVE_USERS = 1186;
const WORKSTATIONS = 412;
const ERROR_PROBES = 3; // probes always in error: never read, kept as they are by every round
const NEVER_ANSWER = 14; // 13 workstations inactive in the directory and 1 whose ping is filtered (WMI only)
const NOT_CHECKED = 27; // round 0: 12 never read (3 probes in error included) and 15 read more than 30 days ago
const ROUND_SPREAD = 6;
const ROUND_JITTER = 40;
const WATCH_TOTAL = 63;
const STALE_AFTER = 7 * DAY;

// ---------- Texts (same rules as FrenchText) ----------

function int(n) {
  const digits = String(Math.abs(Math.trunc(n))).replace(/\B(?=(\d{3})+(?!\d))/g, ' ');
  return n < 0 ? `−${digits}` : digits;
}

function dec(x, decimals = 1) {
  const scale = 10 ** decimals;
  const [whole, fraction] = (Math.round(Math.abs(x) * scale) / scale).toFixed(decimals).split('.');
  const text = `${int(Number(whole))}${fraction ? `,${fraction}` : ''}`;
  return x < 0 && Math.round(Math.abs(x) * scale) !== 0 ? `−${text}` : text;
}

const percentText = (x) => `${dec(x)}${NBSP}%`;
const count = (n, one, many) => `${int(n)} ${Math.abs(n) >= 2 ? many : one}`;
const quote = (text) => `«${NBSP}${text}${NBSP}»`;
const signed = (n) => (n > 0 ? `+${int(n)}` : int(n));

// ---------- Dates ----------

// Instant in UTC to the second with « Z »; local calendar day as yyyy-MM-dd (BridgeJson, OPERATIONS.md § 1.2).
const iso = (t) => new Date(t).toISOString().replace(/\.\d{3}Z$/, 'Z');
const pad = (n) => String(n).padStart(2, '0');
// Days are counted on the calendar, as LocalDays does: a change of summer time never skips or repeats a day.
const dayOf = (t) => { const d = new Date(t); return new Date(d.getFullYear(), d.getMonth(), d.getDate()); };
const addDays = (day, k) => new Date(day.getFullYear(), day.getMonth(), day.getDate() + k);
const isoDay = (day) => `${day.getFullYear()}-${pad(day.getMonth() + 1)}-${pad(day.getDate())}`;
const isWeekend = (day) => day.getDay() === 0 || day.getDay() === 6;
// Fixed abbreviations, whatever the culture of the workstation (FrenchText.DayAbbreviation), by getDay() index.
const DAY_LABELS = ['dim.', 'lun.', 'mar.', 'mer.', 'jeu.', 'ven.', 'sam.'];

// ---------- Deterministic draws ----------

function fnv1a(text) {
  let h = 0x811c9dc5;
  for (const c of text) {
    h ^= c.codePointAt(0);
    h = Math.imul(h, 0x01000193) >>> 0;
  }
  return h >>> 0;
}

// Named sub-sequence of the seed, like SeededRandom.Fork: a new draw somewhere never moves the others.
function fork(name) {
  let a = (SEED ^ fnv1a(name)) >>> 0;
  const next = () => {
    a = (a + 0x6D2B79F5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
  const between = (lo, hi) => lo + Math.floor(next() * (hi - lo + 1));
  const shuffle = (list) => {
    for (let i = list.length - 1; i > 0; i--) {
      const j = between(0, i);
      [list[i], list[j]] = [list[j], list[i]];
    }
    return list;
  };
  return { next, between, shuffle };
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const clone = (v) => (typeof structuredClone === 'function' ? structuredClone(v) : JSON.parse(JSON.stringify(v)));

// Simulated latency (SIMULATION.md § 6.3): local reads 120 to 250 ms, refreshes 400 to 900 ms, separate draw counters.
const draws = { read: 0, refresh: 0 };
function latency(kind, lo, hi) {
  draws[kind] += 1;
  return fork(`latency/${kind}/${draws[kind]}`).between(lo, hi);
}

function fail(code, message) {
  return Object.assign(new Error(message), { code });
}

// ---------- Reference and history ----------

// Reference read once and truncated to the minute; profile chosen by the local day of the week (SIMULATION.md § 4.1).
const REF = Math.floor(Date.now() / MIN) * MIN;
const TODAY = dayOf(REF);
const TARGET = isWeekend(TODAY) ? 61 : 287;

// 13 daily snapshots (days J−13 to J−1), drawn in the same order as the generator (SIMULATION.md § 5.2).
const HISTORY = (() => {
  const accounts = fork('history/accounts');
  const active = new Array(13);
  let value = ACTIVE_USERS;
  for (let back = 1; back <= 13; back++) {
    value -= isWeekend(addDays(TODAY, -back)) ? 0 : accounts.between(0, 3);
    active[13 - back] = value;
  }
  const random = fork('history');
  return Array.from({ length: 13 }, (_, k) => {
    const day = addDays(TODAY, k - 13);
    const weekend = isWeekend(day);
    const online = weekend ? random.between(48, 70) : random.between(265, 300);
    const seen = online + (weekend ? random.between(5, 12) : random.between(8, 25));
    return {
      date: isoDay(day), online, seen, active: active[k],
      locked: random.between(0, 12), expiring: random.between(15, 26), disk: random.between(6, 11),
    };
  });
})();

// ---------- Presence (SIMULATION.md § 5.1 and 5.3) ----------

// One fixed rank per active workstation of the OU. Round 0: the lowest ranks among those that can answer are online.
const PRESENCE = (() => {
  const ranks = fork('presence').shuffle(Array.from({ length: WORKSTATIONS }, (_, i) => i));
  const order = fork('presence/roles').shuffle(Array.from({ length: WORKSTATIONS }, (_, i) => i));
  const errors = order.slice(0, ERROR_PROBES);
  const silent = order.slice(ERROR_PROBES, ERROR_PROBES + NEVER_ANSWER);
  const candidates = order.slice(ERROR_PROBES + NEVER_ANSWER).sort((x, y) => ranks[x] - ranks[y]);
  return { ranks, errors, silent, candidates, online: candidates.slice(0, TARGET), offline: candidates.slice(TARGET) };
})();

// Answers of round 0 lie between the start of the local day (8 hours at most) and the reference minus 28 minutes.
const WINDOW_START = Math.max(TODAY.getTime(), REF - 8 * HOUR);
const WINDOW_END = REF - 28 * MIN < WINDOW_START ? REF : REF - 28 * MIN;
const inWindow = (ago) => Math.min(WINDOW_END, Math.max(WINDOW_START, REF - ago));

// Watch list of the default seed: the six lowest free spaces on C: (SIMULATION.md § 5.1). Rows 0, 1 and 3 answered today,
// rows 2 and 5 answered days ago, row 4 is the workstation whose ping is filtered (never seen).
const WATCH = [
  ['PC-LYO-0031', 'Lyon', '3f2a9c41-7b0e-4d6a-9e15-0c4b8d2f6a17', 3.1, PRESENCE.online[0], inWindow(28 * MIN)],
  ['PT-PAR-0118', 'Paris', '8d41e0b2-55c9-4f3e-a2d7-61f09b3c4e88', 4.0, PRESENCE.online[1], inWindow(39 * MIN)],
  ['PC-MRS-0007', 'Marseille', 'c07b5e13-2a8f-4b91-8d3c-9e6a14f702d5', 5.2, PRESENCE.offline.at(-1), REF - (2 * DAY + 3 * HOUR + 14 * MIN)],
  ['PC-PAR-0142', 'Paris', '5ae9d270-1c4b-4e8f-b6a0-27d38c91fe04', 6.4, PRESENCE.online[2], inWindow(34 * MIN)],
  ['PT-LIL-0012', 'Lille', '91c6f8a3-6d2e-4a07-9b54-e80f3d1a2c69', 7.7, PRESENCE.silent[0], null],
  ['PC-BDX-0021', 'Bordeaux', 'e4b0137c-9f5a-4c2d-8e61-a3d75b0c9f12', 8.3, PRESENCE.offline.at(-2), REF - (3 * DAY + 6 * HOUR + 28 * MIN)],
].map(([name, site, objectGuid, free, station, seenAt]) => ({
  station, seenAt,
  row: {
    name, dn: `CN=${name},OU=${site},${SCOPE.dn}`, objectGuid, ruleId: 'lowDisk',
    reason: `Disque C: presque plein${COLON}${percentText(free)} libre`, severity: 'alert', otherReasons: 0,
  },
}));

// ---------- Journal (SIMULATION.md § 5.4) ----------

const SOURCE_JOURNAL = [
  [12 * MIN, `Lecture de l’annuaire${COLON}${count(OBJECTS, 'objet', 'objets')}`, 'ok'],
  [28 * MIN, `Relevé de présence de l’OU Paris${COLON}158 en ligne sur 186`, 'ok'],
  [55 * MIN, `Relevé d’inventaire de l’OU Lyon${COLON}74 postes sur 82`, 'ok'],
  [99 * MIN, `Diagnostic de verrouillage${COLON}Camille Bernard`, 'warn'],
  [201 * MIN, 'Lecture BitLocker refusée pour l’OU Marseille', 'alert'],
  [226 * MIN, `Recherche ${quote('dupont')}${COLON}12 résultats`, 'info'],
  [302 * MIN, `Relevé de présence de l’OU Lyon${COLON}61 en ligne sur 82`, 'ok'],
  [390 * MIN, `Export des comptes verrouillés${COLON}7 lignes`, 'info'],
  [1500 * MIN, `Lecture de l’annuaire${COLON}${count(1824, 'objet', 'objets')}`, 'ok'],
  [1560 * MIN, `Relevé d’inventaire de l’OU Paris${COLON}171 postes sur 186`, 'ok'],
  [1680 * MIN, `Relevé de présence de l’OU Marseille${COLON}sondes refusées pour 3 postes`, 'warn'],
  [2880 * MIN, `Requête ${quote('Postes sans LAPS')}${COLON}23 résultats`, 'info'],
  [3060 * MIN, `Lecture de l’annuaire${COLON}${count(1821, 'objet', 'objets')}`, 'ok'],
  [4320 * MIN, `Première lecture de l’OU Postes${COLON}431 comptes ordinateur`, 'ok'],
].map(([ago, label, tone]) => ({ at: REF - ago, label, tone }));
const JOURNAL_CAPACITY = 200; // OperationJournal.DefaultCapacity

// ---------- Session state ----------

const state = {
  readAt: REF - 12 * MIN, // directory read of the fictitious local base
  inventoryAt: REF - 55 * MIN, // most recent inventory reading
  presenceAt: WINDOW_END, // most recent presence reading
  presence: { online: TARGET, noAnswer: WORKSTATIONS - TARGET - NOT_CHECKED, notChecked: NOT_CHECKED },
  freshness: { recent: 346, aging: 39, expired: 15, never: 12 },
  seenToday: new Set(PRESENCE.online),
  watchSeen: WATCH.map((w) => w.seenAt),
  round: 0,
  disabled: new Set(),
  journal: [], // operations of the session, most recent first
  loaded: false, // a state is in memory once a summary or a refresh succeeded
  dashboardDone: false,
  running: 0,
  queued: 0,
};
// Refreshes run one after the other, as in the engine (OPERATIONS.md § 6).
let refreshChain = Promise.resolve();

function log(label, tone, at) {
  state.journal.unshift({ at, label, tone });
  if (state.journal.length > JOURNAL_CAPACITY) state.journal.length = JOURNAL_CAPACITY;
}

// Round k ≥ 1: every active workstation is probed now; the probes in error keep their reading, the silent ones do not
// answer, and among the others exactly target + e_k answer, the lowest scores rank + j(k).
function presenceRound(at) {
  state.round += 1;
  const random = fork(`presence/${state.round}`);
  const spread = random.between(-ROUND_SPREAD, ROUND_SPREAD);
  const scored = PRESENCE.candidates.map((station) => ({ station, rank: PRESENCE.ranks[station], score: PRESENCE.ranks[station] + random.between(0, ROUND_JITTER - 1) }));
  const n = Math.min(Math.max(TARGET + spread, 0), scored.length);
  const responders = new Set(scored.sort((x, y) => x.score - y.score || x.rank - y.rank).slice(0, n).map((c) => c.station));
  responders.forEach((station) => state.seenToday.add(station));
  WATCH.forEach((w, i) => { if (responders.has(w.station)) state.watchSeen[i] = at; });
  state.presence = { online: n, noAnswer: WORKSTATIONS - ERROR_PROBES - n, notChecked: ERROR_PROBES };
  state.freshness = { recent: WORKSTATIONS - ERROR_PROBES, aging: 0, expired: 0, never: ERROR_PROBES };
  state.presenceAt = at;
}

// ---------- Widgets (DashboardCalculator) ----------

const CATALOG = [
  ['workstationsOnline', 'kpi', 'Postes en ligne', 'ou', 'presence'],
  ['activeAccounts', 'kpi', 'Comptes actifs', 'domain', 'directory'],
  ['lockedAccounts', 'kpi', 'Comptes verrouillés', 'domain', 'directory'],
  ['passwordsExpiring', 'kpi', 'Mots de passe expirant sous 7 jours', 'domain', 'directory'],
  ['diskAlerts', 'kpi', 'Alertes disque', 'ou', 'inventory'],
  ['osDistribution', 'distribution', 'Systèmes d’exploitation', 'ou', 'directory'],
  ['workstationActivity', 'series', 'Activité des postes · 7 jours', 'ou', 'local'],
  ['measureFreshness', 'gauge', 'Fraîcheur des mesures', 'ou', 'presence'],
  ['watchlist', 'list', 'Postes à surveiller', 'ou', 'local'],
  ['recentOperations', 'timeline', 'Dernières opérations', 'session', 'local'],
].map(([id, kind, title, scope, family]) => ({ id, kind, title, scope, family }));
const BY_ID = new Map(CATALOG.map((w) => [w.id, w]));
const SCOPE_LABELS = { domain: `Domaine ${DOMAIN}`, ou: `OU ${SCOPE.label}`, session: 'Session' };

const DISABLED_DETAIL = `Mesure désactivée${COLON}ce widget ne lit rien tant qu’il n’est pas réactivé.`;
const NO_MEMORY_DETAIL = `Aucune mesure en mémoire${COLON}actualisez ce widget.`;

const part = (key, label, value, tone) => ({ key, label, value, tone });
const riseIs = (rise) => (d) => (d > 0 ? rise : d < 0 ? 'ok' : 'info');
const alwaysInfo = () => 'info';

// History: the past snapshots then today's value; delta against the snapshot of 7 days ago, null if it is missing.
function kpi(value, total, unit, figure, deltaTone, breakdown) {
  const history = [...HISTORY.map((h) => ({ date: h.date, value: h[figure] })), { date: isoDay(TODAY), value }];
  const past = HISTORY.find((h) => h.date === isoDay(addDays(TODAY, -7)));
  let delta = null;
  if (past) {
    const d = value - past[figure];
    delta = { value: d, period: 'P7D', label: d === 0 ? 'Stable sur 7 jours' : `${signed(d)} sur 7 jours`, tone: deltaTone(d) };
  }
  return { value, total, unit, delta, history, breakdown };
}

function journalRows() {
  return [...state.journal, ...SOURCE_JOURNAL].sort((x, y) => y.at - x.at);
}

// Tone, measure date, detail and data of an enabled widget.
function measure(def, now) {
  switch (def.id) {
    case 'workstationsOnline': {
      const p = state.presence;
      return {
        tone: 'info', at: state.presenceAt,
        detail: 'Dernier relevé de présence de moins de 30 jours. Une absence de réponse ne prouve pas que le poste est éteint.',
        data: kpi(p.online, WORKSTATIONS, 'postes', 'online', alwaysInfo, [
          part('online', 'En ligne', p.online, 'ok'), part('noAnswer', 'Sans réponse', p.noAnswer, 'warn'),
          part('notChecked', 'Non vérifié', p.notChecked, 'off')]),
      };
    }
    case 'activeAccounts':
      return {
        tone: 'info', at: state.readAt, detail: 'Comptes utilisateurs activés de tout le domaine (userAccountControl).',
        data: kpi(ACTIVE_USERS, null, 'comptes', 'active', alwaysInfo, [
          part('enabled', 'Actifs', ACTIVE_USERS, 'ok'), part('disabled', 'Désactivés', USERS - ACTIVE_USERS, 'off')]),
      };
    case 'lockedAccounts':
      return {
        tone: 'alert', at: state.readAt,
        detail: 'Verrouillage calculé par le contrôleur (msDS-User-Account-Control-Computed), comptes actifs.',
        data: kpi(7, null, 'comptes', 'locked', riseIs('alert'), [
          part('locked', 'Verrouillés', 7, 'alert'), part('toCheck', 'À vérifier', 0, 'off')]),
      };
    case 'passwordsExpiring':
      return {
        tone: 'warn', at: state.readAt,
        detail: 'Expiration calculée par le contrôleur (msDS-UserPasswordExpiryTimeComputed), comptes actifs.',
        data: kpi(23, null, 'comptes', 'expiring', riseIs('warn'), [
          part('expiring', 'Expirent sous 7 jours', 23, 'warn'), part('expired', 'Déjà expirés', 11, 'alert'),
          part('mustChange', 'À changer à la prochaine connexion', 4, 'info'), part('neverExpires', 'N’expirent jamais', 16, 'off')]),
      };
    case 'diskAlerts':
      return {
        tone: 'alert', at: state.inventoryAt,
        detail: `Moins de 10${NBSP}% libre sur C: · ${count(371, 'poste relevé', 'postes relevés')} sur ${int(WORKSTATIONS)}.`,
        data: kpi(9, null, 'postes', 'disk', riseIs('alert'), [
          part('critical', `Moins de 10${NBSP}% libre`, 9, 'alert'), part('tight', `10 à 20${NBSP}% libre`, 17, 'warn'),
          part('healthy', `20${NBSP}% et plus`, 345, 'ok'), part('unknown', 'Sans relevé', 41, 'off')]),
      };
    case 'osDistribution':
      // Editions of one release grouped; percentages to the tenth by the largest remainder (sum 100.0).
      return {
        tone: 'info', at: state.readAt,
        detail: 'Attributs operatingSystem et operatingSystemVersion des comptes ordinateur activés.',
        data: {
          total: WORKSTATIONS, unit: 'postes', centerText: count(WORKSTATIONS, 'poste', 'postes'),
          segments: [
            { key: 'w11-24h2', label: 'Windows 11 24H2', value: 223, percent: 54.1, members: [] },
            { key: 'w11-23h2', label: 'Windows 11 23H2', value: 96, percent: 23.3, members: [] },
            { key: 'w11-25h2', label: 'Windows 11 25H2', value: 58, percent: 14.1, members: [] },
            { key: 'w10-22h2', label: 'Windows 10 22H2', value: 23, percent: 5.6, members: [] },
            { key: 'autres', label: 'Autres', value: 12, percent: 2.9, members: ['Windows 10 LTSC 2021'] },
          ],
          lead: { label: 'Windows 11 24H2', percent: 54.1 },
        },
      };
    case 'workstationActivity': {
      const points = [];
      for (let offset = 6; offset >= 0; offset--) {
        const day = addDays(TODAY, -offset);
        const value = offset === 0 ? state.seenToday.size : (HISTORY.find((h) => h.date === isoDay(day))?.seen ?? null);
        points.push({ date: isoDay(day), label: DAY_LABELS[day.getDay()], value, partial: offset === 0 });
      }
      return {
        tone: 'info', at: now,
        detail: `Postes distincts ayant répondu au relevé de présence, par jour. Aujourd’hui${COLON}journée en cours.`,
        data: { unit: 'postes', max: Math.max(0, ...points.map((p) => p.value ?? 0)), points },
      };
    }
    case 'measureFreshness': {
      const f = state.freshness;
      const percent = Math.round((f.recent * 1000) / WORKSTATIONS) / 10;
      return {
        tone: percent >= 90 ? 'ok' : percent >= 60 ? 'warn' : 'alert', at: state.presenceAt,
        detail: 'Postes actifs dont le dernier relevé de présence date de moins de 7 jours.',
        data: {
          percent, fresh: f.recent, total: WORKSTATIONS, freshDays: 7,
          breakdown: [
            part('recent', 'Moins de 7 jours', f.recent, 'ok'), part('aging', '7 à 30 jours', f.aging, 'warn'),
            part('expired', 'Plus de 30 jours', f.expired, 'alert'), part('never', 'Jamais relevé', f.never, 'off')],
        },
      };
    }
    case 'watchlist': {
      const rows = WATCH.map((w, i) => ({ ...w.row, lastSeenAt: state.watchSeen[i] == null ? null : iso(state.watchSeen[i]) }));
      return {
        // The list mixes directory, presence and inventory figures: it is as old as the oldest of them.
        tone: 'alert', at: Math.min(state.readAt, state.presenceAt, state.inventoryAt),
        detail: `${count(WATCH_TOTAL, 'poste', 'postes')} avec au moins un point d’attention, du plus grave au moins grave.`,
        data: { total: WATCH_TOTAL, shown: rows.length, rows },
      };
    }
    default: {
      const entries = journalRows();
      return {
        tone: 'info', at: entries[0].at, detail: 'Journal fictif de la simulation, les plus récentes d’abord.',
        data: { total: entries.length, rows: entries.slice(0, 6).map((e) => ({ label: e.label, at: iso(e.at), tone: e.tone })) },
      };
    }
  }
}

// One shape for every widget (OPERATIONS.md § 4.2): data is null if and only if disabled or never measured.
function widget(id, now = Date.now()) {
  const def = BY_ID.get(id);
  const base = { id, kind: def.kind, title: def.title, scopeLabel: SCOPE_LABELS[def.scope] };
  if (state.disabled.has(id)) {
    return { ...base, enabled: false, tone: 'off', measuredAt: null, stale: false, detail: DISABLED_DETAIL, data: null };
  }
  const m = measure(def, now);
  const stale = now - m.at > STALE_AFTER;
  return { ...base, enabled: true, tone: stale ? 'off' : m.tone, measuredAt: iso(m.at), stale, detail: m.detail, data: m.data };
}

function notMeasured(id, detail) {
  const def = BY_ID.get(id);
  return { id, kind: def.kind, title: def.title, scopeLabel: SCOPE_LABELS[def.scope], enabled: true, tone: 'off', measuredAt: null, stale: false, detail, data: null };
}

// ---------- Arguments (BridgeArguments: same order of checks, same texts) ----------

const invalid = (precision) => fail('arguments.invalid', `Arguments invalides${COLON}${precision}`);
const isObject = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);

function requireNone(args) {
  if (args === undefined || args === null) return;
  if (!isObject(args)) throw invalid('un objet JSON est attendu.');
  if (Object.keys(args).length) throw invalid('cette opération n’en accepte aucun.');
}

function readObject(args, allowed) {
  if (!isObject(args)) throw invalid('un objet JSON est attendu.');
  if (Object.keys(args).some((k) => !allowed.includes(k))) throw invalid('propriété non admise.');
  return args;
}

function getString(values, name) {
  if (Object.hasOwn(values, name) && typeof values[name] === 'string') return values[name];
  throw invalid(`${quote(name)} est obligatoire et doit être un texte.`);
}

function getBoolean(values, name) {
  if (Object.hasOwn(values, name) && typeof values[name] === 'boolean') return values[name];
  throw invalid(`${quote(name)} est obligatoire et doit valoir true ou false.`);
}

// ---------- Operations ----------

// Contract values (OPERATIONS.md § 2); the preview is recognised by webViewRuntime "apercu". No modeReason describes a
// browser preview: "argument" (simulation chosen at launch) is the closest one, the detail and the banner say the rest.
function appInfo(args) {
  requireNone(args);
  return {
    name: 'Domenia', version: '2.0.0-dev', runtime: '10.0.12', webViewRuntime: 'apercu',
    mode: 'simulation', modeLabel: 'Simulation', modeReason: 'argument',
    modeDetail: `Ouvert dans un navigateur${COLON}la page répond avec sa maquette intégrée.`,
    banner: `Aperçu${COLON}annuaire fictif ${DOMAIN} intégré à la page, aucune requête ne part et rien n’est écrit.`,
  };
}

const storeStatus = () => ({ lastReadAt: iso(state.readAt), objects: OBJECTS, complete: true });

function sessionInfo(args) {
  requireNone(args);
  const now = Date.now();
  const age = now - state.readAt;
  const [cacheState, cacheLabel] = age < DAY ? ['fresh', 'À jour'] : age <= 7 * DAY ? ['aging', 'À relire bientôt'] : ['stale', 'Ancienne'];
  const steps = [
    { id: 'connect', label: 'Connexion à l’annuaire', done: true },
    { id: 'scope', label: 'Choix de l’OU de travail', done: true },
    { id: 'firstRead', label: 'Première lecture', done: true },
    { id: 'dashboard', label: 'Tableau de bord', done: state.dashboardDone },
  ];
  return {
    connection: { state: 'simulated', label: 'Annuaire simulé' },
    domain: { dnsName: DOMAIN, netbiosName: 'EXAMPLE', rootDn: ROOT_DN },
    controller: { dnsName: `DC01.${DOMAIN}`, site: 'Paris' },
    account: {
      login: 'EXAMPLE\\j.martin', displayName: 'Julien Martin', givenName: 'Julien',
      dn: `CN=Julien Martin,OU=Informatique,OU=Paris,OU=Utilisateurs,${ROOT_DN}`,
    },
    authentication: { method: 'none', protocol: null, label: 'Aucune (simulation)' },
    scope: { ...SCOPE },
    rights: { level: 'read', label: 'Lecture', estimated: true, detail: `Simulation${COLON}les droits sont fictifs et aucune écriture n’est possible.` },
    readOnly: true,
    tasks: { running: state.running, queued: state.queued },
    cache: { state: cacheState, label: cacheLabel, ...storeStatus() },
    onboarding: { steps, completed: steps.filter((s) => s.done).length, total: steps.length },
  };
}

async function summary(args) {
  requireNone(args);
  state.running += 1;
  try {
    await sleep(latency('read', 120, 250));
  } finally {
    state.running -= 1;
  }
  const now = Date.now();
  const result = {
    generatedAt: iso(now),
    scope: { ...SCOPE },
    store: storeStatus(),
    widgets: Object.fromEntries(CATALOG.map((def) => [def.id, widget(def.id, now)])),
  };
  state.loaded = true;
  state.dashboardDone = true;
  return result;
}

async function measureNow(id) {
  state.queued -= 1;
  state.running += 1;
  try {
    // Disabled while waiting: nothing is read.
    if (state.disabled.has(id)) return widget(id);
    const def = BY_ID.get(id);
    await sleep(latency('refresh', 400, 900));
    const now = Date.now();
    // Directory and inventory: same values read again, dated now. Presence: one more round. Local computation: nothing.
    if (def.family === 'directory') state.readAt = now;
    else if (def.family === 'inventory') state.inventoryAt = now;
    else if (def.family === 'presence') presenceRound(now);
    state.loaded = true;
    log(`Actualisation${COLON}${def.title}`, 'ok', now);
    // Disabled during the measure: the measure is kept, the widget comes back disabled (nothing is published).
    return widget(id, now);
  } finally {
    state.running -= 1;
  }
}

function refresh(args) {
  const id = getString(readObject(args, ['id']), 'id');
  if (!BY_ID.has(id)) throw fail('widget.unknown', `Widget inconnu${COLON}rien n’a été lu.`);
  if (state.disabled.has(id)) {
    throw fail('widget.disabled', `Ce widget est désactivé${COLON}aucune mesure n’est faite. Réactivez ${quote('Mesure active')} pour l’actualiser.`);
  }
  state.queued += 1;
  const turn = refreshChain.then(() => measureNow(id));
  refreshChain = turn.catch(() => {});
  return turn;
}

function setEnabled(args) {
  const values = readObject(args, ['id', 'enabled']);
  const id = getString(values, 'id');
  const enabled = getBoolean(values, 'enabled');
  if (!BY_ID.has(id)) throw fail('widget.unknown', `Widget inconnu${COLON}rien n’a été changé.`);
  const changed = enabled === state.disabled.has(id);
  if (changed) {
    if (enabled) state.disabled.delete(id); else state.disabled.add(id);
    log(`${enabled ? 'Mesure réactivée' : 'Mesure désactivée'}${COLON}${BY_ID.get(id).title}`, 'info', Date.now());
  }
  // Enabling reuses the last state in memory, without any read; none before the first summary.
  if (enabled && !state.loaded) return notMeasured(id, NO_MEMORY_DETAIL);
  return widget(id);
}

const OPERATIONS = {
  'app.info': appInfo,
  'session.info': sessionInfo,
  'dashboard.summary': summary,
  'dashboard.widget.refresh': refresh,
  'dashboard.widget.setEnabled': setEnabled,
};

const MAX_MESSAGE_LENGTH = 1_048_576; // BridgeDispatcher.MaxMessageLength

// Same answers as the host: arguments travel as JSON, results come back as fresh JSON values.
export async function mockCall(op, args) {
  let wire;
  try {
    const text = JSON.stringify({ op, args });
    if (text.length > MAX_MESSAGE_LENGTH) throw fail('message.size', `Message de l’interface refusé${COLON}taille non admise.`);
    wire = JSON.parse(text);
  } catch (err) {
    if (err?.code) throw err;
    throw fail('message.json', 'Message de l’interface illisible.');
  }
  const handler = typeof wire.op === 'string' && Object.hasOwn(OPERATIONS, wire.op) ? OPERATIONS[wire.op] : null;
  if (!handler) throw fail('operation.unknown', `Opération inconnue${COLON}rien n’a été exécuté.`);
  return clone(await handler(wire.args));
}
