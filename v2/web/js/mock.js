// Browser preview of the bridge (no WebView2 host): same operations, result shapes, error codes and messages as the
// engine (docs/OPERATIONS.md; src/Domenia.Bridge, src/Domenia.Core/Dashboard), on the fictitious example.local directory
// of the simulation with the figures of the day of its default seed (docs/SIMULATION.md § 4 and 5). Nothing leaves the
// page. Only app.info says that this is a browser preview (webViewRuntime "apercu", its own detail and banner). Texts
// follow OPERATIONS.md § 1.2, written with the helpers below: U+00A0 before « : » and « % » and inside « », U+202F
// between thousands, U+2212 minus sign, decimal comma.
//
// Working OU: directory.ou.children, directory.ou.search and session.setScope read the 39 OU of the simulation
// (SIMULATION.md § 4.3); every widget of workstations is computed on the machines of the chosen OU. The LocalWrite
// operations (session.setScope, dashboard.widget.setEnabled) keep their choice like the engine keeps
// preferences-simulation.json: here in the browser storage of the preview, one JSON document replaced at once.
// Write circuit (accounts.unlock.plan, write.execute, write.receipts.*): mock-writes.js, in the memory of the page.

import { createWriteOperations } from './mock-writes.js';
import { createFicheOperations } from './mock-fiche.js';

const MIN = 60_000;
const HOUR = 60 * MIN;
const DAY = 24 * HOUR;
const NBSP = '\u00A0';
const COLON = `${NBSP}: `;
const SEED = 20261021;

// Default seed of the simulation (SIMULATION.md § 4.2 to 4.6 and 5.1).
const DOMAIN = 'example.local';
const ROOT_DN = 'DC=example,DC=local';
const DEFAULT_SCOPE_DN = `OU=Postes,${ROOT_DN}`;
const OBJECTS = 1826;
const USERS = 1258;
const ACTIVE_USERS = 1186;
const COMPUTERS = 454;
const GROUPS = 75;
const WORKSTATIONS = 412;
const ERROR_PROBES = 3; // probes always in error: never read, kept as they are by every round
const NEVER_ANSWER = 14; // 13 workstations inactive in the directory and 1 whose ping is filtered (WMI only)
const ROUND_SPREAD = 6;
const ROUND_JITTER = 40;
const STALE_AFTER = 7 * DAY; // FI-04: a measure older than this is greyed
const FRESH_DAYS = 7;
const OBSERVATION_MAX_AGE = 30 * DAY; // ObservationMaxAgeDays
const SEARCH_LIMIT = 50;
const SEARCH_MAX_LENGTH = 100; // DirectoryTreeOperations.MaxSearchLength
const MAX_DN_LENGTH = 2048; // BridgeArguments.MaxDistinguishedNameLength

// ---------- Texts (same rules as FrenchText) ----------

function int(n) {
  const digits = String(Math.abs(Math.trunc(n))).replace(/\B(?=(\d{3})+(?!\d))/g, '\u202F');
  return n < 0 ? `\u2212${digits}` : digits;
}

function dec(x, decimals = 1) {
  const scale = 10 ** decimals;
  const [whole, fraction] = (Math.round(Math.abs(x) * scale) / scale).toFixed(decimals).split('.');
  const text = `${int(Number(whole))}${fraction ? `,${fraction}` : ''}`;
  return x < 0 && Math.round(Math.abs(x) * scale) !== 0 ? `\u2212${text}` : text;
}

const percentText = (x) => `${dec(x)}${NBSP}%`;
const count = (n, one, many) => `${int(n)} ${Math.abs(n) >= 2 ? many : one}`;
const quote = (text) => `«${NBSP}${text}${NBSP}»`;
const signed = (n) => (n > 0 ? `+${int(n)}` : int(n));
// Accent- and case-insensitive form (search of OU).
const fold = (text) => String(text ?? '').normalize('NFD').replace(/\p{Diacritic}/gu, '').toLowerCase();
const byName = (a, b) => a.localeCompare(b, 'fr', { sensitivity: 'base' }) || (a < b ? -1 : a > b ? 1 : 0);

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

// Port of SeededRandom (src/Domenia.Simulation/SeededRandom.cs), bit for bit: SplitMix64, named sub-streams from the root
// seed and the FNV-1a 64 hash of their UTF-8 name, unbiased integers by rejection. Same seed and same names give the
// same numbers as the engine (the 13 daily snapshots below, among others), in 64-bit BigInt arithmetic.
const MASK64 = (1n << 64n) - 1n;
const GOLDEN = 0x9E3779B97F4A7C15n;
const SEED64 = BigInt(SEED);
const utf8 = new TextEncoder();

function mix64(value) {
  let z = value;
  z = ((z ^ (z >> 30n)) * 0xBF58476D1CE4E5B9n) & MASK64;
  z = ((z ^ (z >> 27n)) * 0x94D049BB133111EBn) & MASK64;
  return z ^ (z >> 31n);
}

function fnv1a64(text) {
  let h = 14695981039346656037n;
  for (const b of utf8.encode(text)) h = ((h ^ BigInt(b)) * 1099511628211n) & MASK64;
  return h;
}

// Named sub-sequence of the seed (SeededRandom.Fork): a new draw somewhere never moves the others.
function fork(name) {
  let state = mix64(((SEED64 ^ fnv1a64(name)) + GOLDEN) & MASK64);
  const nextU64 = () => {
    state = (state + GOLDEN) & MASK64;
    return mix64(state);
  };
  // NextUInt64Below: rejection of the top incomplete range keeps every value equally likely.
  const below = (bound) => {
    const b = BigInt(bound);
    const limit = MASK64 - (((MASK64 % b) + 1n) % b);
    for (;;) {
      const v = nextU64();
      if (v <= limit) return Number(v % b);
    }
  };
  // NextDouble: 53 random bits in [0 ; 1[.
  const next = () => Number(nextU64() >> 11n) / 9007199254740992;
  // Inclusive bounds: between(lo, hi) is Next(lo, hi + 1) of the engine.
  const between = (lo, hi) => lo + below(hi - lo + 1);
  const shuffle = (list) => {
    for (let i = list.length - 1; i > 0; i--) {
      const j = below(i + 1);
      [list[i], list[j]] = [list[j], list[i]];
    }
    return list;
  };
  return { next, between, shuffle };
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const clone = (v) => (typeof structuredClone === 'function' ? structuredClone(v) : JSON.parse(JSON.stringify(v)));

// Simulated latency (SIMULATION.md § 6.3): local reads 120 to 250 ms, refreshes 400 to 900 ms; the OU tree and the
// preferences have their own draw counters, so they never shift the delays of the dashboard.
const draws = { read: 0, refresh: 0, tree: 0, write: 0 };
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
const TODAY_START = TODAY.getTime();
const TARGET = isWeekend(TODAY) ? 61 : 287;

// 13 daily snapshots (days J−13 to J−1), drawn in the same order and from the same sub-streams as the generator
// (SimulatedWorldGenerator.BuildHistory, SIMULATION.md § 5.2): the same numbers as the engine. They describe
// the default working OU (OU Postes with its sub-OU): like the engine, their workstation figures are never shown for
// another OU (DashboardCalculator: history of the scope it was recorded for only).
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

// ---------- Organisational units (SIMULATION.md § 4.3: 39 OU) ----------

const SITES = [
  { name: 'Paris', code: 'PAR', stations: 186, unknownInventory: 15, inventoryAgo: 26 * HOUR },
  { name: 'Lyon', code: 'LYO', stations: 82, unknownInventory: 8, inventoryAgo: 55 * MIN },
  { name: 'Marseille', code: 'MRS', stations: 64, unknownInventory: 8, inventoryAgo: 2 * DAY + 5 * HOUR },
  { name: 'Lille', code: 'LIL', stations: 44, unknownInventory: 6, inventoryAgo: 3 * DAY + HOUR },
  { name: 'Bordeaux', code: 'BDX', stations: 36, unknownInventory: 4, inventoryAgo: 4 * DAY + 3 * HOUR },
];

// [name, objects placed directly in the OU { u: users, c: computers, g: groups }, sub-OU]
const TREE = [
  ['Domain Controllers', { c: 2 }],
  ['Utilisateurs', {}, [
    ['Paris', {}, [['Direction', { u: 18 }], ['Finances', { u: 92 }], ['Ressources humaines', { u: 64 }],
      ['Informatique', { u: 71 }], ['Juridique', { u: 33 }], ['Communication', { u: 41 }], ['Achats', { u: 52 }],
      ['Commercial', { u: 189 }]]],
    ['Lyon', {}, [['Commercial', { u: 141 }], ['Logistique', { u: 89 }]]],
    ['Marseille', {}, [['Commercial', { u: 102 }], ['Logistique', { u: 88 }]]],
    ['Lille', {}, [['Commercial', { u: 130 }]]],
    ['Bordeaux', {}, [['Commercial', { u: 78 }]]],
    ['Départs', { u: 48 }],
  ]],
  ['Postes', {}, [...SITES.map((s) => [s.name, { c: s.stations }]), ['Quarantaine', { c: 19 }]]],
  ['Serveurs', {}, [['Applications', { c: 12 }], ['Fichiers', { c: 4 }], ['Impression', { c: 2 }]]],
  ['Groupes', {}, [['Sécurité', { g: 28 }], ['Distribution', { g: 6 }], ['Ressources', { g: 24 }]]],
  ['Comptes de service', { u: 13 }],
  ['Comptes à privilèges', { u: 6 }],
];

// RFC 4514 escaping of an attribute value; DN are compared without case, as the directory does.
const escapeRdn = (v) => v.replace(/[,+"\\<>;=]/g, (c) => `\\${c}`).replace(/^([ #])/, '\\$1').replace(/ $/, '\\ ');
const keyOf = (dn) => String(dn).toLowerCase();
const PATH_SEP = `${NBSP}› `;

// Root of the domain: counts cover the whole directory (default containers CN=Users, CN=Computers, CN=Builtin
// included); it is never an OU and is never chosen as the working OU.
const ROOT = { dn: ROOT_DN, name: DOMAIN, path: DOMAIN, children: [], counts: { users: USERS, computers: COMPUTERS, groups: GROUPS } };
const OU_BY_KEY = new Map();
(function build(list, parent) {
  for (const [name, direct, sub] of list) {
    const ou = {
      dn: `OU=${escapeRdn(name)},${parent.dn}`, name, path: `${parent.path}${PATH_SEP}${name}`, parent, children: [],
      direct: { users: direct.u ?? 0, computers: direct.c ?? 0, groups: direct.g ?? 0 }, counts: null,
    };
    parent.children.push(ou);
    OU_BY_KEY.set(keyOf(ou.dn), ou);
    if (sub) build(sub, ou);
  }
})(TREE, ROOT);

// Counts of an OU: objects of its whole branch (the OU and its sub-OU), so that a closed branch tells what it holds.
(function totals(ou) {
  for (const child of ou.children) totals(child);
  if (ou === ROOT) return;
  ou.counts = { ...ou.direct };
  for (const child of ou.children) {
    ou.counts.users += child.counts.users;
    ou.counts.computers += child.counts.computers;
    ou.counts.groups += child.counts.groups;
  }
})(ROOT);
const sortTree = (ou) => { ou.children.sort((a, b) => byName(a.name, b.name)); ou.children.forEach(sortTree); };
sortTree(ROOT);

const ouItem = (ou) => ({ dn: ou.dn, name: ou.name, path: ou.path, hasChildren: ou.children.length > 0, counts: { ...ou.counts } });
const findOu = (dn) => OU_BY_KEY.get(keyOf(dn)) ?? null;
const isRoot = (dn) => keyOf(dn) === keyOf(ROOT_DN);

// ---------- Machines of the directory (SIMULATION.md § 4.5 and 5.1) ----------

// One fixed rank per active workstation of the OU Postes. Round 0: the lowest ranks among those that can answer are
// online.
const PRESENCE = (() => {
  const ranks = fork('presence').shuffle(Array.from({ length: WORKSTATIONS }, (_, i) => i));
  const order = fork('presence/roles').shuffle(Array.from({ length: WORKSTATIONS }, (_, i) => i));
  const errors = order.slice(0, ERROR_PROBES);
  const silent = order.slice(ERROR_PROBES, ERROR_PROBES + NEVER_ANSWER);
  const candidates = order.slice(ERROR_PROBES + NEVER_ANSWER).sort((x, y) => ranks[x] - ranks[y]);
  return { ranks, errors, silent, candidates, online: candidates.slice(0, TARGET), offline: candidates.slice(TARGET) };
})();

// Answers of round 0 lie between the start of the local day (8 hours at most) and the reference minus 28 minutes.
const WINDOW_START = Math.max(TODAY_START, REF - 8 * HOUR);
const WINDOW_END = REF - 28 * MIN < WINDOW_START ? REF : REF - 28 * MIN;
const inWindow = (ago) => Math.min(WINDOW_END, Math.max(WINDOW_START, REF - ago));

// The six lowest free spaces on C: of the default seed (watch list of OPERATIONS.md § 5). Rows 0, 1 and 3 answered
// today, rows 2 and 5 answered days ago, row 4 is the workstation whose ping is filtered (never seen, WMI inventory).
const WATCH_FIXED = [
  ['PC-LYO-0031', 'Lyon', '3f2a9c41-7b0e-4d6a-9e15-0c4b8d2f6a17', 3.1, PRESENCE.online[0], inWindow(28 * MIN)],
  ['PT-PAR-0118', 'Paris', '8d41e0b2-55c9-4f3e-a2d7-61f09b3c4e88', 4.0, PRESENCE.online[1], inWindow(39 * MIN)],
  ['PC-MRS-0007', 'Marseille', 'c07b5e13-2a8f-4b91-8d3c-9e6a14f702d5', 5.2, PRESENCE.offline.at(-1), REF - (2 * DAY + 3 * HOUR + 14 * MIN)],
  ['PC-PAR-0142', 'Paris', '5ae9d270-1c4b-4e8f-b6a0-27d38c91fe04', 6.4, PRESENCE.online[2], inWindow(34 * MIN)],
  ['PT-LIL-0012', 'Lille', '91c6f8a3-6d2e-4a07-9b54-e80f3d1a2c69', 7.7, PRESENCE.silent[0], null],
  ['PC-BDX-0021', 'Bordeaux', 'e4b0137c-9f5a-4c2d-8e61-a3d75b0c9f12', 8.3, PRESENCE.offline.at(-2), REF - (3 * DAY + 6 * HOUR + 28 * MIN)],
];

// Releases of the systems (editions of one release grouped, OPERATIONS.md § 4.4).
const RELEASES = {
  'w11-24h2': 'Windows 11 24H2', 'w11-23h2': 'Windows 11 23H2', 'w11-25h2': 'Windows 11 25H2',
  'w10-22h2': 'Windows 10 22H2', 'w10-ltsc2021': 'Windows 10 LTSC 2021',
  ws2022: 'Windows Server 2022', ws2025: 'Windows Server 2025', ws2019: 'Windows Server 2019',
};

function guid(random) {
  const hex = Array.from({ length: 32 }, () => random.between(0, 15).toString(16));
  hex[12] = '4';
  hex[16] = ((parseInt(hex[16], 16) & 0x3) | 0x8).toString(16);
  const s = hex.join('');
  return `${s.slice(0, 8)}-${s.slice(8, 12)}-${s.slice(12, 16)}-${s.slice(16, 20)}-${s.slice(20)}`;
}

// Points of attention (Domenia 1 health rules, OPERATIONS.md § 4.8): one per workstation, in the order of the rules.
const RULE_ORDER = ['lowDisk', 'neverLoggedOn', 'stale', 'machinePasswordOld', 'diskTight', 'uptime'];
const days = (n) => count(n, 'jour', 'jours');
function point(ruleId, value) {
  switch (ruleId) {
    case 'lowDisk': return { ruleId, value, severity: 'alert', otherReasons: 0, reason: `Disque C presque plein${COLON}${percentText(value)} libre` };
    case 'diskTight': return { ruleId, value, severity: 'warn', otherReasons: 0, reason: `Peu d’espace sur le disque C${COLON}${percentText(value)} libre` };
    case 'uptime': return { ruleId, value, severity: 'warn', otherReasons: 0, reason: `Sans redémarrage depuis ${days(value)}` };
    // Inactive and never connected workstations also have an old machine password (SIMULATION.md § 4.5).
    case 'stale': return { ruleId, value, severity: 'warn', otherReasons: 1, reason: `Aucune connexion au domaine depuis ${days(value)}` };
    case 'neverLoggedOn': return { ruleId, value: 0, severity: 'warn', otherReasons: 1, reason: 'Jamais connecté au domaine' };
    default: return { ruleId, value, severity: 'warn', otherReasons: 0, reason: `Mot de passe machine changé il y a ${days(value)}` };
  }
}

const MACHINES = (() => {
  const stations = Array.from({ length: WORKSTATIONS }, (_, i) => ({
    kind: 'station', i, role: 'candidate', site: null, name: null, guid: null, os: null,
    presence: { probedAt: null, answeredAt: null }, inventory: null, point: null,
  }));
  PRESENCE.errors.forEach((i) => { stations[i].role = 'error'; });
  // Silent: the filtered ping first, then 11 workstations without logon for 90 days and 2 never connected.
  PRESENCE.silent.forEach((i, n) => { stations[i].role = n === 0 ? 'filtered' : n <= 11 ? 'stale' : 'neverLoggedOn'; });

  const fixed = new Set();
  WATCH_FIXED.forEach(([name, site, id, free, i, seenAt]) => {
    const s = stations[i];
    Object.assign(s, { name, site, guid: id });
    s.inventory = { at: 0, free, uptime: 3 };
    s.point = point('lowDisk', free);
    s.fixedSeen = seenAt;
    fixed.add(i);
  });

  // Sites: the fixed rows keep theirs, the other workstations fill each site to its size.
  const free = fork('sites').shuffle(stations.filter((s) => !s.site).map((s) => s.i));
  for (const site of SITES) {
    const need = site.stations - stations.filter((s) => s.site === site.name).length;
    free.splice(0, need).forEach((i) => { stations[i].site = site.name; });
  }

  // Names: PC (fixed, 70 %) or PT (laptop, 30 %), numbered per site after the numbers of the fixed rows.
  const names = fork('names');
  const ids = fork('guid');
  for (const site of SITES) {
    const reserved = new Set(WATCH_FIXED.filter((w) => w[1] === site.name).map((w) => Number(w[0].slice(-4))));
    let number = 0;
    stations.filter((s) => s.site === site.name && !s.name).forEach((s) => {
      do number += 1; while (reserved.has(number));
      s.name = `${names.next() < 0.3 ? 'PT' : 'PC'}-${site.code}-${String(number).padStart(4, '0')}`;
      s.guid = guid(ids);
    });
  }

  // Systems of the 412 workstations (SIMULATION.md § 4.5).
  const releases = [['w11-24h2', 223], ['w11-23h2', 96], ['w11-25h2', 58], ['w10-22h2', 23], ['w10-ltsc2021', 12]]
    .flatMap(([key, n]) => Array(n).fill(key));
  fork('os').shuffle(releases).forEach((key, i) => { stations[i].os = key; });

  // Presence of round 0: 287 online, 98 without answer (59 read within 7 days, 39 within 30), 27 not checked
  // (15 read more than 30 days ago, 12 never read with the 3 probes in error): freshness 346 / 39 / 15 / 12.
  const times = fork('presence/times');
  for (const i of PRESENCE.online) {
    const s = stations[i];
    const at = s.fixedSeen ?? inWindow(times.between(28, 480) * MIN);
    s.presence = { probedAt: at, answeredAt: at };
  }
  const pool = fork('presence/age').shuffle([...PRESENCE.silent.slice(1), ...PRESENCE.offline].filter((i) => !fixed.has(i)));
  const answeredBefore = (s, probedAt) => (s.role === 'candidate' ? probedAt - times.between(1, 15) * DAY - times.between(0, 600) * MIN : null);
  pool.slice(0, 9).forEach((i) => { stations[i].presence = { probedAt: null, answeredAt: null }; });
  pool.slice(9, 24).forEach((i) => {
    const probedAt = REF - times.between(31, 90) * DAY - times.between(0, 600) * MIN;
    stations[i].presence = { probedAt, answeredAt: answeredBefore(stations[i], probedAt) };
  });
  pool.slice(24, 63).forEach((i) => {
    const probedAt = REF - times.between(7 * 24 + 1, 29 * 24) * HOUR;
    stations[i].presence = { probedAt, answeredAt: answeredBefore(stations[i], probedAt) };
  });
  [...pool.slice(63), PRESENCE.silent[0], ...[2, 5].map((n) => WATCH_FIXED[n][4])].forEach((i) => {
    const s = stations[i];
    if (s.fixedSeen) { s.presence = { probedAt: WINDOW_END, answeredAt: s.fixedSeen }; return; }
    const probedAt = Math.min(WINDOW_END, REF - times.between(28, 6 * 24 * 60 + 20 * 60) * MIN);
    s.presence = { probedAt, answeredAt: answeredBefore(s, probedAt) };
  });

  // Inventory (WMI): 371 read within 30 days, 41 without a usable reading; the dates follow the journal of the
  // simulation (Lyon read 55 minutes ago, Paris yesterday). Workstations in alert all have an inventory.
  const inventory = fork('inventory');
  for (const site of SITES) {
    const members = stations.filter((s) => s.site === site.name);
    const unknown = new Set(inventory.shuffle(members.filter((s) => !fixed.has(s.i)).map((s) => s.i)).slice(0, site.unknownInventory));
    members.forEach((s) => {
      if (unknown.has(s.i)) { s.inventory = null; return; }
      s.inventory = { at: REF - site.inventoryAgo, free: s.inventory?.free ?? null, uptime: s.inventory?.uptime ?? null };
    });
  }

  // Points of attention: 9 critical disks, 17 tight, 21 old restarts, 11 inactive, 2 never connected, 3 old machine
  // passwords alone: 63 workstations (SIMULATION.md § 5.1).
  const points = fork('points');
  const eligible = points.shuffle(stations.filter((s) => s.role === 'candidate' && s.inventory && !fixed.has(s.i)).map((s) => s.i));
  const take = (n) => eligible.splice(0, n).map((i) => stations[i]);
  take(3).forEach((s, n) => { s.inventory.free = [8.9, 9.4, 9.8][n]; s.point = point('lowDisk', s.inventory.free); });
  take(17).forEach((s) => { s.inventory.free = (102 + points.between(0, 95)) / 10; s.point = point('diskTight', s.inventory.free); });
  take(21).forEach((s) => { s.inventory.uptime = points.between(31, 75); s.point = point('uptime', s.inventory.uptime); });
  take(3).forEach((s) => { s.point = point('machinePasswordOld', points.between(61, 120)); });
  stations.forEach((s) => {
    if (s.role === 'stale') s.point = point('stale', points.between(91, 400));
    else if (s.role === 'neverLoggedOn') s.point = point('neverLoggedOn', 0);
    if (s.inventory) {
      s.inventory.free ??= (205 + points.between(0, 575)) / 10;
      s.inventory.uptime ??= points.between(0, 12);
    }
  });

  stations.forEach((s) => {
    s.ouDn = `OU=${escapeRdn(s.site)},${DEFAULT_SCOPE_DN}`;
    s.dn = `CN=${s.name},${s.ouDn}`;
    delete s.fixedSeen;
  });

  // Servers and domain controllers: no presence reading nor inventory in the simulation until a round reads them.
  const serverOs = fork('servers').shuffle([...Array(10).fill('ws2022'), ...Array(4).fill('ws2025'), ...Array(4).fill('ws2019')]);
  const servers = [
    ...['APP-01', 'APP-02', 'APP-03', 'APP-04', 'APP-05', 'APP-06', 'SQL-01', 'SQL-02', 'SQL-03', 'WEB-01', 'WEB-02', 'WEB-03'].map((n) => [`SRV-${n}`, 'Applications']),
    ...['FIC-01', 'FIC-02', 'FIC-03', 'FIC-04'].map((n) => [`SRV-${n}`, 'Fichiers']),
    ...['IMP-01', 'IMP-02'].map((n) => [`SRV-${n}`, 'Impression']),
  ].map(([name, ou], n) => ({ name, ouDn: `OU=${ou},OU=Serveurs,${ROOT_DN}`, os: serverOs[n] }));
  servers.push({ name: 'DC01', ouDn: `OU=Domain Controllers,${ROOT_DN}`, os: 'ws2022' }, { name: 'DC02', ouDn: `OU=Domain Controllers,${ROOT_DN}`, os: 'ws2022' });
  const serverIds = fork('guid/servers');
  const others = servers.map((s) => ({
    kind: 'server', i: -1, role: 'server', site: null, name: s.name, guid: guid(serverIds), os: s.os, ouDn: s.ouDn,
    dn: `CN=${s.name},${s.ouDn}`, presence: { probedAt: null, answeredAt: null }, inventory: null, point: null,
  }));

  const all = [...stations, ...others];
  all.forEach((m) => { m.ouKey = keyOf(m.ouDn); });
  return all;
})();

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

// ---------- Widgets catalogue ----------

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

// ---------- Session state and simulated preferences ----------

const state = {
  readAt: REF - 12 * MIN, // directory read of the fictitious local base
  scope: { dn: DEFAULT_SCOPE_DN, label: 'Postes', subtree: true },
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

// preferences-simulation.json of the engine, kept in the browser storage of the preview (one document, replaced at
// once). Unreadable or unavailable storage: defaults, and the choices live as long as the page.
const PREFS_KEY = 'domenia.apercu.preferences-simulation.v1';

function loadPreferences() {
  let doc = null;
  try { doc = JSON.parse(localStorage.getItem(PREFS_KEY) ?? 'null'); } catch { doc = null; }
  if (!doc || typeof doc !== 'object' || doc.version !== 1) return;
  const dn = typeof doc.scope?.dn === 'string' ? doc.scope.dn : null;
  const ou = dn ? findOu(dn) : null;
  // The whole domain is restored too (always with its sub-OU), as the engine does.
  if (dn && isRoot(dn)) state.scope = { dn: ROOT_DN, label: DOMAIN, subtree: true };
  else if (ou) state.scope = { dn: ou.dn, label: ou.name, subtree: doc.scope.subtree !== false };
  if (doc.widgets && typeof doc.widgets === 'object') {
    for (const [id, enabled] of Object.entries(doc.widgets)) if (BY_ID.has(id) && enabled === false) state.disabled.add(id);
  }
}

function savePreferences() {
  const doc = {
    version: 1,
    scope: { dn: state.scope.dn, subtree: state.scope.subtree },
    widgets: Object.fromEntries(CATALOG.map((def) => [def.id, !state.disabled.has(def.id)])),
  };
  try { localStorage.setItem(PREFS_KEY, JSON.stringify(doc)); } catch { /* storage unavailable: kept for this page only */ }
}

loadPreferences();

function log(label, tone, at) {
  state.journal.unshift({ at, label, tone });
  if (state.journal.length > JOURNAL_CAPACITY) state.journal.length = JOURNAL_CAPACITY;
}

// ---------- Scope of the workstation widgets ----------

const inScope = (m, scope = state.scope) => {
  const key = keyOf(scope.dn);
  return m.ouKey === key || (scope.subtree && m.ouKey.endsWith(`,${key}`));
};
const scopedMachines = () => MACHINES.filter((m) => inScope(m));
const scopeLabels = () => ({ domain: `Domaine ${DOMAIN}`, ou: `OU ${state.scope.label}`, session: 'Session' });

// Round k ≥ 1: every machine of the working OU is probed now; the probes in error keep their reading, the silent
// workstations do not answer, and among the others the workstations of the OU that belong to the target + e_k lowest
// scores (rank + j(k)) answer. Servers answer every round.
function presenceRound(at) {
  state.round += 1;
  const random = fork(`presence/${state.round}`);
  const spread = random.between(-ROUND_SPREAD, ROUND_SPREAD);
  const scored = PRESENCE.candidates.map((i) => ({ i, rank: PRESENCE.ranks[i], score: PRESENCE.ranks[i] + random.between(0, ROUND_JITTER - 1) }));
  const n = Math.min(Math.max(TARGET + spread, 0), scored.length);
  const responders = new Set(scored.sort((x, y) => x.score - y.score || x.rank - y.rank).slice(0, n).map((c) => c.i));
  for (const m of scopedMachines()) {
    if (m.role === 'error') continue;
    m.presence.probedAt = at;
    if (m.kind === 'server' || responders.has(m.i)) m.presence.answeredAt = at;
  }
}

function presenceStats(list, now) {
  const s = { online: 0, noAnswer: 0, notChecked: 0, recent: 0, aging: 0, expired: 0, never: 0, seenToday: 0, at: null };
  for (const m of list) {
    const { probedAt, answeredAt } = m.presence;
    if (answeredAt != null && answeredAt >= TODAY_START) s.seenToday += 1;
    if (probedAt == null) { s.notChecked += 1; s.never += 1; continue; }
    const age = now - probedAt;
    s.at = s.at == null || probedAt > s.at ? probedAt : s.at;
    if (age > OBSERVATION_MAX_AGE) s.notChecked += 1;
    else if (answeredAt != null && answeredAt >= probedAt) s.online += 1;
    else s.noAnswer += 1;
    if (age < FRESH_DAYS * DAY) s.recent += 1;
    else if (age <= OBSERVATION_MAX_AGE) s.aging += 1;
    else s.expired += 1;
  }
  return s;
}

function diskStats(list, now) {
  const s = { critical: 0, tight: 0, healthy: 0, unknown: 0, read: 0, at: null };
  for (const m of list) {
    const inv = m.inventory;
    if (!inv || now - inv.at > OBSERVATION_MAX_AGE || !(inv.free > 0)) { s.unknown += 1; continue; }
    s.read += 1;
    s.at = s.at == null || inv.at > s.at ? inv.at : s.at;
    if (inv.free < 10) s.critical += 1;
    else if (inv.free < 20) s.tight += 1;
    else s.healthy += 1;
  }
  return s;
}

// Largest remainder to the tenth: the percentages always add up to exactly 100.0.
function tenths(values, total) {
  const raw = values.map((v) => (v * 1000) / total);
  const floors = raw.map(Math.floor);
  let rest = 1000 - floors.reduce((a, b) => a + b, 0);
  raw.map((r, n) => ({ n, frac: r - floors[n] })).sort((a, b) => b.frac - a.frac || a.n - b.n)
    .forEach(({ n }) => { if (rest > 0) { floors[n] += 1; rest -= 1; } });
  return floors.map((f) => f / 10);
}

function distribution(list) {
  const total = list.length;
  const counts = new Map();
  list.forEach((m) => counts.set(m.os, (counts.get(m.os) ?? 0) + 1));
  const ranked = [...counts.entries()].map(([key, value]) => ({ key, label: RELEASES[key] ?? 'Système non renseigné', value }))
    .sort((a, b) => b.value - a.value || byName(a.label, b.label));
  let segments = ranked.map((r) => ({ ...r, members: [] }));
  if (ranked.length > 4) {
    const rest = ranked.slice(4);
    segments = [...segments.slice(0, 4), { key: 'autres', label: 'Autres', value: rest.reduce((a, r) => a + r.value, 0), members: rest.map((r) => r.label) }];
  }
  const percents = total ? tenths(segments.map((s) => s.value), total) : [];
  segments = segments.map((s, n) => ({ key: s.key, label: s.label, value: s.value, percent: percents[n], members: s.members }));
  return {
    total, unit: 'postes', centerText: count(total, 'poste', 'postes'), segments,
    lead: segments.length ? { label: segments[0].label, percent: segments[0].percent } : null,
  };
}

// Watch list order: severity, rule, measured value (free space rising, age falling), then name (ordinal).
function watchRows(list) {
  const flagged = list.filter((m) => m.point);
  const severe = (p) => (p.ruleId === 'lowDisk' || p.ruleId === 'diskTight' ? p.value : -p.value);
  flagged.sort((a, b) => (a.point.severity === b.point.severity ? 0 : a.point.severity === 'alert' ? -1 : 1)
    || RULE_ORDER.indexOf(a.point.ruleId) - RULE_ORDER.indexOf(b.point.ruleId)
    || severe(a.point) - severe(b.point)
    || (a.name < b.name ? -1 : a.name > b.name ? 1 : 0));
  return flagged;
}

// ---------- Widgets (DashboardCalculator) ----------

const DISABLED_DETAIL = `Mesure désactivée${COLON}ce widget ne lit rien tant qu’il n’est pas réactivé.`;
const NO_MEMORY_DETAIL = `Aucune mesure en mémoire${COLON}actualisez ce widget.`;
const NO_MACHINE_DETAIL = `Aucun ordinateur activé dans cette OU${COLON}rien à mesurer.`;
const NO_PRESENCE_DETAIL = `Aucun relevé de présence${COLON}actualisez ce widget pour mesurer les postes.`;
const NO_INVENTORY_DETAIL = `Aucun relevé d’inventaire${COLON}actualisez ce widget pour mesurer l’espace disque.`;

const part = (key, label, value, tone) => ({ key, label, value, tone });
const riseIs = (rise) => (d) => (d > 0 ? rise : d < 0 ? 'ok' : 'info');
const alwaysInfo = () => 'info';

// Workstation figures of the history: recorded for the default working OU, shown for it only (none for another OU,
// whose KPI then has today's point alone and no delta, as in the engine).
const historyOfScope = () => keyOf(state.scope.dn) === keyOf(DEFAULT_SCOPE_DN) && state.scope.subtree === true;
function pastValues(figure) {
  return historyOfScope() ? domainPast(figure) : [];
}

// Account figures of the history: the whole domain, whatever the working OU.
function domainPast(figure) {
  return HISTORY.map((h) => ({ date: h.date, value: h[figure] }));
}

// History: the past snapshots then today's value; delta against the snapshot of 7 days ago, null if it is missing.
function kpi(value, total, unit, past, deltaTone, breakdown) {
  const history = [...past, { date: isoDay(TODAY), value }];
  const before = past.find((h) => h.date === isoDay(addDays(TODAY, -7)));
  let delta = null;
  if (before) {
    const d = value - before.value;
    delta = { value: d, period: 'P7D', label: d === 0 ? 'Stable sur 7 jours' : `${signed(d)} sur 7 jours`, tone: deltaTone(d) };
  }
  return { value, total, unit, delta, history, breakdown };
}

function journalRows() {
  return [...state.journal, ...SOURCE_JOURNAL].sort((x, y) => y.at - x.at);
}

// Tone, measure date, detail and data of an enabled widget; { none } when nothing is measured in the working OU.
function measure(def, now) {
  const list = def.scope === 'ou' ? scopedMachines() : [];
  switch (def.id) {
    case 'workstationsOnline': {
      if (!list.length) return { none: NO_MACHINE_DETAIL };
      const p = presenceStats(list, now);
      if (p.at == null) return { none: NO_PRESENCE_DETAIL };
      return {
        tone: 'info', at: p.at,
        detail: 'Dernier relevé de présence de moins de 30 jours. Une absence de réponse ne prouve pas que le poste est éteint.',
        data: kpi(p.online, list.length, 'postes', pastValues('online'), alwaysInfo, [
          part('online', 'En ligne', p.online, 'ok'), part('noAnswer', 'Sans réponse', p.noAnswer, 'warn'),
          part('notChecked', 'Non vérifié', p.notChecked, 'off')]),
      };
    }
    case 'activeAccounts':
      return {
        tone: 'info', at: state.readAt, detail: 'Comptes utilisateurs activés de tout le domaine (userAccountControl).',
        data: kpi(ACTIVE_USERS, null, 'comptes', domainPast('active'), alwaysInfo, [
          part('enabled', 'Actifs', ACTIVE_USERS, 'ok'), part('disabled', 'Désactivés', USERS - ACTIVE_USERS, 'off')]),
      };
    case 'lockedAccounts':
      return {
        tone: 'alert', at: state.readAt,
        detail: 'Verrouillage calculé par le contrôleur (msDS-User-Account-Control-Computed), comptes actifs.',
        data: kpi(7, null, 'comptes', domainPast('locked'), riseIs('alert'), [
          part('locked', 'Verrouillés', 7, 'alert'), part('toCheck', 'À vérifier', 0, 'off')]),
      };
    case 'passwordsExpiring':
      return {
        tone: 'warn', at: state.readAt,
        detail: 'Expiration calculée par le contrôleur (msDS-UserPasswordExpiryTimeComputed), comptes actifs.',
        data: kpi(23, null, 'comptes', domainPast('expiring'), riseIs('warn'), [
          part('expiring', 'Expirent sous 7 jours', 23, 'warn'), part('expired', 'Déjà expirés', 11, 'alert'),
          part('mustChange', 'À changer à la prochaine connexion', 4, 'info'), part('neverExpires', 'N’expirent jamais', 16, 'off')]),
      };
    case 'diskAlerts': {
      if (!list.length) return { none: NO_MACHINE_DETAIL };
      const d = diskStats(list, now);
      if (!d.read) return { none: NO_INVENTORY_DETAIL };
      return {
        tone: d.critical > 0 ? 'alert' : d.tight > 0 ? 'warn' : 'ok', at: d.at,
        detail: `Moins de 10${NBSP}% libre sur C: · ${count(d.read, 'poste relevé', 'postes relevés')} sur ${int(list.length)}.`,
        data: kpi(d.critical, null, 'postes', pastValues('disk'), riseIs('alert'), [
          part('critical', `Moins de 10${NBSP}% libre`, d.critical, 'alert'), part('tight', `10 à 20${NBSP}% libre`, d.tight, 'warn'),
          part('healthy', `20${NBSP}% et plus`, d.healthy, 'ok'), part('unknown', 'Sans relevé', d.unknown, 'off')]),
      };
    }
    case 'osDistribution':
      return {
        tone: 'info', at: state.readAt,
        detail: 'Attributs operatingSystem et operatingSystemVersion des comptes ordinateur activés.',
        data: distribution(list),
      };
    case 'workstationActivity': {
      const today = presenceStats(list, now).seenToday;
      const points = [];
      for (let offset = 6; offset >= 0; offset--) {
        const day = addDays(TODAY, -offset);
        const past = HISTORY.find((h) => h.date === isoDay(day));
        const value = offset === 0 ? today : historyOfScope() && past ? past.seen : null;
        points.push({ date: isoDay(day), label: DAY_LABELS[day.getDay()], value, partial: offset === 0 });
      }
      return {
        tone: 'info', at: now,
        detail: `Postes distincts ayant répondu au relevé de présence, par jour. Aujourd’hui${COLON}journée en cours.`,
        data: { unit: 'postes', max: Math.max(0, ...points.map((p) => p.value ?? 0)), points },
      };
    }
    case 'measureFreshness': {
      if (!list.length) return { none: NO_MACHINE_DETAIL };
      const f = presenceStats(list, now);
      if (f.at == null) return { none: NO_PRESENCE_DETAIL };
      const percent = Math.round((f.recent * 1000) / list.length) / 10;
      return {
        tone: percent >= 90 ? 'ok' : percent >= 60 ? 'warn' : 'alert', at: f.at,
        detail: 'Postes actifs dont le dernier relevé de présence date de moins de 7 jours.',
        data: {
          percent, fresh: f.recent, total: list.length, freshDays: FRESH_DAYS,
          breakdown: [
            part('recent', 'Moins de 7 jours', f.recent, 'ok'), part('aging', '7 à 30 jours', f.aging, 'warn'),
            part('expired', 'Plus de 30 jours', f.expired, 'alert'), part('never', 'Jamais relevé', f.never, 'off')],
        },
      };
    }
    case 'watchlist': {
      const flagged = watchRows(list);
      const rows = flagged.slice(0, 6).map((m) => ({
        name: m.name, dn: m.dn, objectGuid: m.guid, ruleId: m.point.ruleId, reason: m.point.reason,
        severity: m.point.severity, otherReasons: m.point.otherReasons,
        lastSeenAt: m.presence.answeredAt == null ? null : iso(m.presence.answeredAt),
      }));
      const disks = diskStats(list, now);
      const presenceAt = presenceStats(list, now).at;
      const inventoried = disks.read > 0;
      let tone = rows.some((r) => r.severity === 'alert') ? 'alert' : rows.length ? 'warn' : 'ok';
      if (tone === 'ok' && !inventoried) tone = 'info';
      const head = flagged.length
        ? `${count(flagged.length, 'poste', 'postes')} avec au moins un point d’attention, du plus grave au moins grave.`
        : 'Aucun poste avec un point d’attention dans cette OU.';
      let detail = head;
      if (!list.length) detail = `Aucun ordinateur activé dans cette OU${COLON}aucun point d’attention à évaluer.`;
      else if (!inventoried) detail = `${head} Aucun relevé d’inventaire de moins de 30 jours${COLON}disques et redémarrages non évalués.`;
      return {
        // The list mixes directory, presence and inventory figures: it is as old as the oldest of them.
        tone, at: Math.min(...[state.readAt, presenceAt, disks.at].filter((t) => t != null)),
        detail,
        data: { total: flagged.length, shown: rows.length, rows },
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
  const base = { id, kind: def.kind, title: def.title, scopeLabel: scopeLabels()[def.scope] };
  if (state.disabled.has(id)) {
    return { ...base, enabled: false, tone: 'off', measuredAt: null, stale: false, detail: DISABLED_DETAIL, data: null };
  }
  const m = measure(def, now);
  if (m.none) return { ...base, enabled: true, tone: 'off', measuredAt: null, stale: false, detail: m.none, data: null };
  const stale = now - m.at > STALE_AFTER;
  return { ...base, enabled: true, tone: stale ? 'off' : m.tone, measuredAt: iso(m.at), stale, detail: m.detail, data: m.data };
}

function notMeasured(id, detail) {
  const def = BY_ID.get(id);
  return { id, kind: def.kind, title: def.title, scopeLabel: scopeLabels()[def.scope], enabled: true, tone: 'off', measuredAt: null, stale: false, detail, data: null };
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

// Optional text (GetOptionalString): absent or null gives null; any other kind is refused.
function getOptionalString(values, name) {
  if (!Object.hasOwn(values, name) || values[name] === null) return null;
  if (typeof values[name] === 'string') return values[name];
  throw invalid(`${quote(name)} doit être un texte ou null.`);
}

// Well-formed distinguished name (DistinguishedName.Parse, RFC 4514, multi-valued RDN refused), 2 048 characters at most.
function isDistinguishedName(dn) {
  let readingType = true;
  let type = '';
  for (let i = 0; i < dn.length; i++) {
    const c = dn[i];
    if (readingType) {
      if (c === '=') {
        if (!type) return false;
        readingType = false;
      } else if (/[A-Za-z0-9.-]/.test(c)) {
        type += c;
      } else {
        return false;
      }
      continue;
    }
    if (c === '\\') {
      if (i + 1 >= dn.length) return false;
      i += i + 2 < dn.length && /[0-9A-Fa-f]/.test(dn[i + 1]) && /[0-9A-Fa-f]/.test(dn[i + 2]) ? 2 : 1;
      continue;
    }
    if (c === ',') { readingType = true; type = ''; continue; }
    if (c === '+') return false;
  }
  return !readingType;
}

function requireDistinguishedName(value, name) {
  if (value.length === 0 || value.length > MAX_DN_LENGTH || !isDistinguishedName(value)) {
    throw invalid(`${quote(name)} doit être un nom distinctif valide.`);
  }
  return value;
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
    banner: `Aperçu${COLON}annuaire fictif ${DOMAIN} intégré à la page, aucune requête ne part. Vos choix (OU de travail, mesures actives) restent dans ce navigateur, les écritures d’essai dans la page.`,
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
    scope: { ...state.scope },
    rights: { level: 'read', label: 'Lecture', estimated: true, detail: `Simulation${COLON}les droits sont fictifs${NBSP}; les écritures ne modifient que l’annuaire fictif, en mémoire.` },
    // Writes are admitted in simulation, on the in-memory overlay only (decision of 21/10): same as the engine.
    readOnly: false,
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
    scope: { ...state.scope },
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
    // Directory and inventory: same values read again, dated now. Presence: one more round on the working OU. Local
    // computation: nothing.
    if (def.family === 'directory') state.readAt = now;
    else if (def.family === 'inventory') scopedMachines().forEach((m) => { if (m.inventory) m.inventory.at = now; });
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
  const family = BY_ID.get(id).family;
  if ((family === 'presence' || family === 'inventory') && isRoot(state.scope.dn)) {
    throw fail('scope.tooWide', `Choisissez une OU${COLON}la mesure des postes n’est jamais lancée sur tout le domaine.`);
  }
  state.queued += 1;
  const turn = refreshChain.then(() => measureNow(id));
  refreshChain = turn.catch(() => {});
  return turn;
}

// LocalWrite: the state is kept in the preferences; an unchanged state is neither written nor journalled.
function setEnabled(args) {
  const values = readObject(args, ['id', 'enabled']);
  const id = getString(values, 'id');
  const enabled = getBoolean(values, 'enabled');
  if (!BY_ID.has(id)) throw fail('widget.unknown', `Widget inconnu${COLON}rien n’a été changé.`);
  const changed = enabled === state.disabled.has(id);
  if (changed) {
    if (enabled) state.disabled.delete(id); else state.disabled.add(id);
    savePreferences();
    log(`${enabled ? 'Mesure réactivée' : 'Mesure désactivée'}${COLON}${BY_ID.get(id).title}`, 'info', Date.now());
  }
  // Enabling reuses the last state in memory, without any read; none before the first summary.
  if (enabled && !state.loaded) return notMeasured(id, NO_MEMORY_DETAIL);
  return widget(id);
}

// directory.ou.children (LocalRead in simulation): the root of the domain for dn null, else the sub-OU of an OU.
// « dn » absent or null designates the root (OPERATIONS.md § 9); a text must be a valid DN (same check as the engine).
async function ouChildren(args) {
  const dn = getOptionalString(readObject(args, ['dn']), 'dn');
  if (dn !== null) requireDistinguishedName(dn, 'dn');
  // The simulated reader waits before answering, an unknown OU included.
  await sleep(latency('tree', 60, 160));
  const parent = dn === null || isRoot(dn) ? ROOT : findOu(dn);
  if (!parent) throw fail('ou.unknown', `OU introuvable${COLON}rien n’a été lu.`);
  return {
    parent: { dn: parent.dn, name: parent.name, path: parent.path },
    children: parent.children.map(ouItem),
  };
}

// directory.ou.search: at most 50 OU whose name or path holds the text, without accents nor case, by path. A bare array,
// as the engine answers (OPERATIONS.md § 10): exactly 50 may mean that more OU match.
async function ouSearch(args) {
  // Length of the text as sent, before any trimming, with the engine's words.
  const raw = getString(readObject(args, ['text']), 'text');
  if (raw.length > SEARCH_MAX_LENGTH) throw invalid(`${quote('text')} doit faire au plus ${int(SEARCH_MAX_LENGTH)} caractères.`);
  const text = raw.trim();
  await sleep(latency('tree', 60, 160));
  if (!text) return [];
  const wanted = fold(text);
  const found = [...OU_BY_KEY.values()].filter((ou) => fold(ou.name).includes(wanted) || fold(ou.path).includes(wanted))
    .sort((a, b) => byName(a.path, b.path));
  return found.slice(0, SEARCH_LIMIT).map(ouItem);
}

// session.setScope (LocalWrite): the OU must exist in the domain; the choice is kept in the preferences and answered
// with the updated session.info. Same order of checks as the engine (WorkingScope.SetAsync); the root is accepted as
// « tout le domaine », always with its sub-OU (OPERATIONS.md § 11): workstation measures then answer scope.tooWide.
async function setScope(args) {
  const values = readObject(args, ['dn', 'subtree']);
  const dn = requireDistinguishedName(getString(values, 'dn'), 'dn');
  const subtree = getBoolean(values, 'subtree');
  if (isRoot(dn)) {
    await sleep(latency('write', 40, 110));
    if (!isRoot(state.scope.dn) || !state.scope.subtree) {
      state.scope = { dn: ROOT_DN, label: DOMAIN, subtree: true };
      savePreferences();
      log(`OU de travail${COLON}${DOMAIN}`, 'info', Date.now());
    }
    return sessionInfo();
  }
  const ou = findOu(dn);
  if (!keyOf(dn).endsWith(`,${keyOf(ROOT_DN)}`)) {
    throw fail('scope.outsideDomain', `Cette OU n’appartient pas au domaine de la session${COLON}l’OU de travail n’a pas été changée.`);
  }
  if (!ou) throw fail('scope.unknown', `OU introuvable${COLON}l’OU de travail n’a pas été changée.`);
  await sleep(latency('write', 40, 110));
  const changed = keyOf(ou.dn) !== keyOf(state.scope.dn) || subtree !== state.scope.subtree;
  if (changed) {
    state.scope = { dn: ou.dn, label: ou.name, subtree };
    savePreferences();
    // Same journal line as the engine (WorkingScope.SetAsync).
    log(`OU de travail${COLON}${ou.path}${subtree ? '' : ' (sans sous-OU)'}`, 'info', Date.now());
  }
  return sessionInfo();
}

const OPERATIONS = {
  'app.info': appInfo,
  'session.info': sessionInfo,
  'session.setScope': setScope,
  'dashboard.summary': summary,
  'dashboard.widget.refresh': refresh,
  'dashboard.widget.setEnabled': setEnabled,
  'directory.ou.children': ouChildren,
  'directory.ou.search': ouSearch,
  ...createWriteOperations({
    readObject, getString, getOptionalString, requireDistinguishedName, requireNone, invalid, fail, quote, int, sleep, log, NBSP, REF,
  }),
  ...createFicheOperations({ readObject, getString, getOptionalString, requireDistinguishedName, requireNone, invalid, fail, int, sleep, NBSP, REF }),
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
