// Browser preview of the Comptes screen (docs/ops/comptes.md): the operations accounts.* with the shapes, error codes and
// texts of the engine (AccountsOperations, AccountsAccessOperations, AccountsRules, AccountsBatch, AccountsBatchSeals,
// AccountAccess), on a small fictitious population of example.local drawn from a fixed seed. Plans, collective seals,
// receipts and the accounts kept in memory live in the memory of the page: nothing leaves it, nothing is kept after a
// reload, no password is ever stored (a typed password only decides « validated » or not, like the simulation, which holds
// none). The write circuit of mock-writes.js keeps its own plans: write.execute and write.receipts.* are wrapped so both
// work. The helpers of mock.js are handed in, so validation messages stay those of the engine.

const MIN = 60_000;
const HOUR = 60 * MIN;
const DAY = 24 * HOUR;
const LIFETIME = 5 * MIN;
const BATCH_LIFETIME = 10 * MIN;
const FILETIME_EPOCH_MS = 11_644_473_600_000;
const ROOT = 'DC=example,DC=local';
const PEOPLE = `OU=Utilisateurs,${ROOT}`;
const CONTROLLER = 'DC01.example.local';
const SESSION_DN = `CN=Julien Martin,OU=Informatique,OU=Paris,${PEOPLE}`;

/**
 * @param {object} h  Helpers of mock.js and the write operations of mock-writes.js (h.writes).
 * @returns {Object<string, (args: any) => any>}
 */
export function createAccountsOperations(h) {
  const { readObject, getString, getOptionalString, requireDistinguishedName, requireNone, invalid, fail, quote, int, sleep, log, NBSP, REF, keyOf, getBoolean, writes } = h;
  const COLON = `${NBSP}: `;
  const iso = (t) => (t == null ? null : new Date(t).toISOString().replace(/\.\d{3}Z$/, 'Z'));
  const second = (t) => Math.floor(t / 1000) * 1000;
  const hex = (bytes) => [...bytes].map((b) => b.toString(16).padStart(2, '0')).join('');
  const random = (n) => crypto.getRandomValues(new Uint8Array(n));
  const newId = () => hex(random(16));
  const newToken = () => btoa(String.fromCharCode(...random(32))).replace(/=+$/, '').replace(/\+/g, '-').replace(/\//g, '_');
  const fileTime = (t) => (t == null ? '0' : String((BigInt(t) + BigInt(FILETIME_EPOCH_MS)) * 10000n));
  const pad = (n) => String(n).padStart(2, '0');
  const dayText = (t) => { const d = new Date(t); return `${pad(d.getDate())}/${pad(d.getMonth() + 1)}/${d.getFullYear()}`; };
  const timeText = (t) => { const d = new Date(t); return `${pad(d.getHours())}:${pad(d.getMinutes())}`; };
  const count = (n, one, many) => `${int(n)} ${Math.abs(n) >= 2 ? many : one}`;

  // ---------------------------------------------------------------- fictitious population (fixed seed)

  let seed = 0x2026_1022;
  const next = () => { seed |= 0; seed = (seed + 0x6D2B79F5) | 0; let t = Math.imul(seed ^ (seed >>> 15), 1 | seed); t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t; return ((t ^ (t >>> 14)) >>> 0) / 4294967296; };
  const pick = (list) => list[Math.floor(next() * list.length)];
  const FIRST = ['Camille', 'Julien', 'Léa', 'Hugo', 'Manon', 'Lucas', 'Chloé', 'Nathan', 'Inès', 'Théo', 'Sarah', 'Louis', 'Emma', 'Gabriel', 'Jade', 'Arthur', 'Zoé', 'Paul', 'Alice', 'Adam'];
  const LAST = ['Bernard', 'Martin', 'Petit', 'Durand', 'Leroy', 'Moreau', 'Simon', 'Laurent', 'Lefebvre', 'Michel', 'Garcia', 'David', 'Bertrand', 'Roux', 'Vincent', 'Fournier', 'Morel', 'Girard', 'André', 'Mercier'];
  const UNITS = [
    { ou: 'Informatique', site: 'Paris', title: 'Technicien support' }, { ou: 'Finances', site: 'Paris', title: 'Comptable' },
    { ou: 'Commercial', site: 'Paris', title: 'Chargé de clientèle' }, { ou: 'Commercial', site: 'Lyon', title: 'Commercial' },
    { ou: 'Logistique', site: 'Lyon', title: 'Gestionnaire de stock' },
  ];
  const accounts = [];
  const add = (a) => { accounts.push({ bad: 0, lockedAt: null, lockExpired: false, lockToCheck: false, enabled: true, pwdSet: REF - 20 * DAY, neverExpires: false, accountExpires: null, lastLogon: REF - 2 * DAY, adminCount: 0, ...a }); };
  const guidOf = (n) => { const b = []; let x = n * 2654435761 >>> 0; for (let i = 0; i < 16; i++) { x = Math.imul(x ^ (x >>> 13), 1274126177) >>> 0; b.push(x & 255); } const s = hex(b); return `${s.slice(0, 8)}-${s.slice(8, 12)}-${s.slice(12, 16)}-${s.slice(16, 20)}-${s.slice(20)}`; };
  add({ name: 'Camille Bernard', sam: 'c.bernard', guid: '6f1c2b7e-9a43-4d1e-8c55-2b7d90e4a1c3', unit: UNITS[3], lockedAt: REF - 18 * MIN, bad: 5, rid: 1105 });
  add({ name: 'Julien Martin', sam: 'j.martin', guid: '0a5e3d21-7c84-4f92-b1a6-5d3e8f20c7b4', unit: UNITS[0], rid: 1106, adminCount: 0 });
  add({ name: 'Julien Martin (admin)', sam: 'adm-j.martin', guid: guidOf(9001), unit: { ou: 'Administration', site: 'Paris', title: 'Administrateur' }, adminCount: 1, rid: 1107, neverExpires: true });
  add({ name: 'svc-sauvegarde', sam: 'svc-sauvegarde', guid: guidOf(9002), unit: { ou: 'Comptes de service', site: 'Paris', title: 'Compte de service' }, neverExpires: true, rid: 1108, lastLogon: REF - 3 * HOUR });
  for (let i = 0; i < 72; i++) {
    const first = pick(FIRST);
    const last = pick(LAST);
    const unit = pick(UNITS);
    const a = { name: `${first} ${last}`, sam: `${first[0]}.${last}`.toLowerCase().normalize('NFD').replace(/[̀-ͯ]/g, '') + (i % 7 === 0 ? String(i) : ''), guid: guidOf(i + 1), unit, rid: 1200 + i };
    if (i < 6) Object.assign(a, { lockedAt: REF - (i * 37 + 9) * MIN, bad: 5 });
    else if (i < 8) Object.assign(a, { lockExpired: true, lockedAt: REF - (i * 3 + 2) * HOUR, bad: 0 });
    else if (i === 8) Object.assign(a, { lockToCheck: true, lockedAt: REF - 50 * MIN, bad: 4 });
    else if (i < 14) a.enabled = false;
    else if (i < 18) a.pwdSet = REF - (95 + i) * DAY;
    else if (i < 23) a.pwdSet = REF - (80 + (i - 18) * 2) * DAY;
    else if (i < 26) a.pwdSet = 0;
    else if (i < 30) a.neverExpires = true;
    else if (i < 32) a.accountExpires = REF - (i - 29) * 4 * DAY;
    else if (i < 35) a.accountExpires = REF + (i - 30) * 8 * DAY;
    if (i >= 40 && i < 48) a.lastLogon = REF - (100 + i) * DAY;
    if (i === 48 || i === 49) a.lastLogon = null;
    if (i >= 50 && i < 54) a.bad = 2;
    add(a);
  }
  for (const a of accounts) {
    a.dn = `CN=${a.name},OU=${a.unit.ou},OU=${a.unit.site},${PEOPLE}`;
    a.created = REF - (400 + (a.rid % 300)) * DAY;
  }
  const byDn = (dn) => accounts.find((a) => keyOf(a.dn) === keyOf(dn)) ?? null;
  const byGuid = (guid) => accounts.find((a) => a.guid === guid) ?? null;
  const policy = {
    maxPasswordAgeDays: 90, minPasswordLength: 12, passwordHistory: 24, lockoutThreshold: 5, lockoutMinutes: 30, observationMinutes: 30,
    label: `Mot de passe valable 90${NBSP}jours · 12 caractères au moins, complexité exigée · verrouillage après 5 essais erronés pendant 30${NBSP}min`, complexityRequired: true,
  };

  // ---------------------------------------------------------------- rules (AccountsRules)

  const lockOf = (a) => (a.lockToCheck ? 'toCheck' : a.lockedAt && !a.lockExpired ? 'locked' : a.lockedAt ? 'expired' : 'unlocked');
  const passwordOf = (a, now) => {
    if (a.pwdSet === 0) return 'mustChange';
    if (a.neverExpires) return 'neverExpires';
    const left = a.pwdSet + 90 * DAY - now;
    return left <= 0 ? 'expired' : left <= 14 * DAY ? 'expiring' : 'valid';
  };
  const STATUS = { locked: ['Verrouillé', 'alert'], lockToCheck: ['Verrouillage à vérifier', 'warn'], disabled: ['Désactivé', 'off'], accountExpired: ['Compte expiré', 'alert'], passwordExpired: ['Mot de passe expiré', 'alert'], mustChange: ['Mot de passe à changer', 'info'], expiring: ['Expire bientôt', 'warn'], ok: ['Actif', 'ok'] };
  function row(a, now = Date.now()) {
    const lock = lockOf(a);
    const password = passwordOf(a, now);
    const accountExpired = a.accountExpires != null && a.accountExpires <= now;
    const status = !a.enabled ? 'disabled' : lock === 'locked' ? 'locked' : lock === 'toCheck' ? 'lockToCheck' : accountExpired ? 'accountExpired'
      : password === 'expired' ? 'passwordExpired' : password === 'mustChange' ? 'mustChange' : password === 'expiring' ? 'expiring' : 'ok';
    return {
      dn: a.dn, guid: a.guid, sam: a.sam, name: a.name, upn: `${a.sam}@example.local`, title: a.unit.title, department: a.unit.ou, office: a.unit.site, ou: a.unit.ou,
      enabled: a.enabled, lock, lockedAt: lock === 'unlocked' ? null : iso(a.lockedAt), badPasswordCount: a.bad, password,
      passwordLastSet: a.pwdSet ? iso(a.pwdSet) : null, passwordExpiresAt: a.pwdSet && !a.neverExpires ? iso(a.pwdSet + 90 * DAY) : null, passwordEstimated: false,
      accountExpiresAt: iso(a.accountExpires), accountExpired, lastLogon: iso(a.lastLogon), privileged: a.adminCount === 1,
      status, statusLabel: STATUS[status][0], tone: STATUS[status][1],
    };
  }
  function counts(rows, now = Date.now()) {
    const c = { total: rows.length, enabled: 0, disabled: 0, locked: 0, lockToCheck: 0, lockExpired: 0, passwordExpired: 0, passwordExpiring: 0, mustChange: 0, neverExpires: 0, accountExpired: 0, accountExpiring: 0, privileged: 0, neverLoggedOn: 0, stale: 0 };
    for (const r of rows) {
      if (r.privileged) c.privileged++;
      if (!r.enabled) { c.disabled++; continue; }
      c.enabled++;
      if (r.lock === 'locked') c.locked++; else if (r.lock === 'toCheck') c.lockToCheck++; else if (r.lock === 'expired') c.lockExpired++;
      if (r.password === 'expired') c.passwordExpired++; else if (r.password === 'expiring') c.passwordExpiring++; else if (r.password === 'mustChange') c.mustChange++; else if (r.password === 'neverExpires') c.neverExpires++;
      if (r.accountExpired) c.accountExpired++; else if (r.accountExpiresAt && Date.parse(r.accountExpiresAt) - now <= 30 * DAY) c.accountExpiring++;
      if (!r.lastLogon) c.neverLoggedOn++; else if (now - Date.parse(r.lastLogon) > 90 * DAY) c.stale++;
    }
    return c;
  }

  // ---------------------------------------------------------------- scope of the section

  let sectionScope = null; // { dn, subtree }
  const scopeOf = () => {
    if (sectionScope) {
      const parts = sectionScope.dn.split(',').filter((p) => p.startsWith('OU=')).map((p) => p.slice(3)).reverse();
      return { dn: sectionScope.dn, label: parts[parts.length - 1], path: parts.join(' › '), subtree: sectionScope.subtree, origin: 'section' };
    }
    return { dn: `OU=Postes,${ROOT}`, label: 'Postes', path: 'Postes', subtree: true, origin: 'working' };
  };
  const OUS = [PEOPLE, `OU=Paris,${PEOPLE}`, `OU=Lyon,${PEOPLE}`, ...new Set(accounts.map((a) => a.dn.slice(a.dn.indexOf(',') + 1)))];

  function scopeGet(args) { requireNone(args); return scopeOf(); }
  async function scopeSet(args) {
    const values = readObject(args, ['dn', 'subtree']);
    const dn = requireDistinguishedName(getString(values, 'dn'), 'dn');
    const subtree = getBoolean(values, 'subtree');
    await sleep(60);
    if (keyOf(dn) === keyOf(ROOT)) throw fail('scope.tooWide', `Choisissez une OU${COLON}la liste des comptes n’est jamais lue sur tout le domaine.`);
    if (!keyOf(dn).endsWith(keyOf(ROOT))) throw fail('scope.outsideDomain', `Cette OU n’appartient pas au domaine de la session${COLON}le périmètre des comptes n’a pas été changé.`);
    if (!OUS.some((o) => keyOf(o) === keyOf(dn)) && keyOf(dn) !== keyOf(`OU=Postes,${ROOT}`)) throw fail('scope.unknown', `OU introuvable${COLON}le périmètre des comptes n’a pas été changé.`);
    sectionScope = { dn: OUS.find((o) => keyOf(o) === keyOf(dn)) ?? dn, subtree };
    log(`Périmètre des comptes${COLON}${scopeOf().path}`, 'info', Date.now());
    return scopeOf();
  }
  function scopeReset(args) { requireNone(args); sectionScope = null; return scopeOf(); }

  // ---------------------------------------------------------------- lists and detail

  async function list(args) {
    requireNone(args);
    await sleep(200);
    const scope = scopeOf();
    const now = Date.now();
    const inScope = accounts.filter((a) => {
      const parent = a.dn.slice(a.dn.indexOf(',') + 1);
      return scope.subtree ? keyOf(a.dn).endsWith(`,${keyOf(scope.dn)}`) : keyOf(parent) === keyOf(scope.dn);
    });
    const rows = inScope.map((a) => row(a, now)).sort((x, y) => x.name.localeCompare(y.name, 'fr', { sensitivity: 'base' }));
    const suggestions = rows.length ? [] : [PEOPLE, `OU=Paris,${PEOPLE}`, `OU=Lyon,${PEOPLE}`].map((dn) => {
      const n = accounts.filter((a) => keyOf(a.dn).endsWith(`,${keyOf(dn)}`)).length;
      const parts = dn.split(',').filter((p) => p.startsWith('OU=')).map((p) => p.slice(3)).reverse();
      return { dn, name: parts[parts.length - 1], path: parts.join(' › '), users: n };
    });
    return { scope, tooWide: false, readAt: iso(second(now)), controller: CONTROLLER, simulated: true, policy, counts: counts(rows, now), rows, truncated: false, limit: 5000, suggestions };
  }

  function actionsOf(a, r) {
    const self = keyOf(a.dn) === keyOf(SESSION_DN);
    const no = (reason) => ({ available: false, reason });
    const ok = { available: true, reason: null };
    return {
      unlock: r.lock === 'locked' || r.lock === 'toCheck' ? ok : no('Ce compte n’est pas verrouillé.'),
      enable: a.enabled ? no('Ce compte est déjà activé.') : ok,
      disable: !a.enabled ? no('Ce compte est déjà désactivé.') : self ? no(`C’est votre compte de session${COLON}le désactiver vous retirerait l’accès à l’annuaire.`) : ok,
      resetPassword: ok,
      mustChange: r.password === 'mustChange' ? no('Le changement de mot de passe est déjà imposé à la prochaine connexion.') : r.password === 'neverExpires' ? no(`Le mot de passe de ce compte n’expire jamais${COLON}un changement imposé resterait sans effet.`) : ok,
      expiration: ok,
      lockouts: ok,
    };
  }

  function bandOf(a, r) {
    const facts = [];
    if (r.badPasswordCount) facts.push({ label: 'Essais erronés', value: int(r.badPasswordCount), tone: 'warn', source: CONTROLLER, limit: `Compteur propre à ce contrôleur${COLON}il n’est pas répliqué.`, hypothesis: null });
    if (r.lock === 'locked') {
      facts.unshift({ label: 'Verrouillé le', value: `${dayText(a.lockedAt)} à ${timeText(a.lockedAt)}`, tone: 'alert', source: CONTROLLER, limit: null, hypothesis: null });
      facts.push({ label: 'Fin prévue', value: timeText(a.lockedAt + 30 * MIN), tone: 'info', source: 'Stratégie du domaine', limit: null, hypothesis: null });
      return { tone: 'alert', title: `Verrouillé depuis ${timeText(a.lockedAt)}`, detail: `Le contrôleur dit le compte verrouillé (bit 0x10 de msDS-User-Account-Control-Computed)${COLON}déverrouillez après avoir vérifié l’identité du demandeur.`, facts, actions: ['unlock', 'lockouts'] };
    }
    if (r.lock === 'toCheck') return { tone: 'warn', title: 'Verrouillage à vérifier', detail: `Seul lockoutTime est lu${COLON}l’état calculé n’a pas répondu. Relisez avant d’agir.`, facts, actions: ['unlock', 'lockouts'] };
    if (!a.enabled) return { tone: 'off', title: 'Compte désactivé', detail: 'Le compte ne peut pas ouvrir de session.', facts, actions: [] };
    if (r.accountExpired) return { tone: 'alert', title: 'Compte expiré', detail: `Expiré le ${dayText(a.accountExpires)}.`, facts, actions: [] };
    if (r.password === 'expired') return { tone: 'alert', title: 'Mot de passe expiré', detail: `Expiré le ${dayText(a.pwdSet + 90 * DAY)} (date calculée par le contrôleur).`, facts, actions: ['reset'] };
    if (r.password === 'mustChange') return { tone: 'info', title: 'Mot de passe à changer', detail: 'Le changement est exigé à la prochaine connexion.', facts, actions: [] };
    if (r.password === 'expiring') return { tone: 'warn', title: 'Mot de passe expirant', detail: `Expire le ${dayText(a.pwdSet + 90 * DAY)}.`, facts, actions: ['reset'] };
    if (r.lock === 'expired') return { tone: 'info', title: 'Verrouillage récent levé', detail: `Le verrouillage du ${dayText(a.lockedAt)} a pris fin selon la stratégie.`, facts, actions: ['lockouts'] };
    if (r.badPasswordCount) return { tone: 'warn', title: 'Essais erronés récents', detail: 'Des essais erronés sont comptés par ce contrôleur.', facts, actions: ['lockouts'] };
    return null;
  }

  async function detail(args) {
    const dn = requireDistinguishedName(getString(readObject(args, ['dn']), 'dn'), 'dn');
    await sleep(160);
    const a = byDn(dn);
    if (!a) throw fail('accounts.unknown', `Ce nom distinctif ne désigne aucun compte utilisateur de l’annuaire fictif${COLON}rien n’a été lu.`);
    const now = Date.now();
    const r = row(a, now);
    const age = a.pwdSet ? Math.floor((now - a.pwdSet) / DAY) : null;
    const [first, ...rest] = a.name.split(' ');
    return {
      account: r,
      identity: { cn: a.name, displayName: a.name, givenName: first, surname: rest.join(' ') || null, mail: `${a.sam}@example.local`, telephone: `+33 1 40 00 ${pad(a.rid % 100)} ${pad((a.rid * 7) % 100)}`, employeeId: String(10000 + a.rid), manager: null, description: null, sid: `S-1-5-21-3623811015-3361044348-30300820-${a.rid}`, created: iso(a.created), changed: iso(now - DAY), usn: 40000 + a.rid },
      state: { disabled: !a.enabled, lock: r.lock, lockedAt: r.lockedAt, lockEndsAt: r.lock === 'locked' ? iso(a.lockedAt + 30 * MIN) : null, badPasswordCount: a.bad, passwordExpired: r.password === 'expired', passwordNeverExpires: a.neverExpires, passwordNotRequired: false, smartCardRequired: false, privileged: r.privileged, accountExpiresAt: r.accountExpiresAt, accountExpired: r.accountExpired, lastLogon: r.lastLogon },
      passwordInfo: { lastSet: r.passwordLastSet, expiresAt: r.passwordExpiresAt, estimated: false, class: r.password, label: { valid: 'Valide', expiring: 'Expire bientôt', expired: 'Expiré', mustChange: 'À changer à la prochaine connexion', neverExpires: 'N’expire jamais' }[r.password], ageDays: age, maxAgeDays: 90, percent: age == null || a.neverExpires ? null : Math.min(100, (age / 90) * 100), tone: { valid: 'ok', expiring: 'warn', expired: 'alert', mustChange: 'info', neverExpires: 'off' }[r.password] },
      band: bandOf(a, r),
      actions: actionsOf(a, r),
      groups: { count: 4 + (a.rid % 5), primaryGroupId: 513, privileged: a.adminCount === 1 ? ['Admins du domaine'] : [] },
      policy, controller: CONTROLLER, readAt: iso(second(now)), simulated: true,
      resetDefaults: { mustChange: true, source: 'Défaut de Domenia 1 (Security.ForcePasswordChangeOnReset)', revealSeconds: 5 },
    };
  }

  async function lockouts(args) {
    const values = readObject(args, ['dn', 'hours']);
    const dn = requireDistinguishedName(getString(values, 'dn'), 'dn');
    const hours = values.hours ?? 168;
    if (!Number.isInteger(hours) || hours < 1 || hours > 720) throw invalid(`${quote('hours')} doit être un entier de 1 à 720.`);
    await sleep(600);
    const a = byDn(dn);
    if (!a) throw fail('accounts.unknown', `Ce nom distinctif ne désigne aucun compte utilisateur de l’annuaire fictif${COLON}rien n’a été lu.`);
    const now = Date.now();
    const pcs = [`PC-${a.unit.site.slice(0, 3).toUpperCase()}-${pad(a.rid % 90)}`, `PC-${a.unit.site.slice(0, 3).toUpperCase()}-${pad((a.rid * 3) % 90)}`];
    const events = a.lockedAt ? [0, 1, 2].map((n) => ({ at: iso(a.lockedAt - n * 26 * HOUR), callerComputer: pcs[n === 2 ? 1 : 0], controller: CONTROLLER, domenia: { near: false, seconds: null, ambiguous: false, label: 'Aucun refus de Domenia juste avant' } })).filter((e) => Date.parse(e.at) >= now - hours * HOUR) : [];
    const origins = [...new Set(events.map((e) => e.callerComputer))].map((computer) => { const n = events.filter((e) => e.callerComputer === computer).length; return { computer, count: n, share: Math.round((n / events.length) * 100) }; });
    const facts = [
      { label: 'État calculé', value: { locked: 'Verrouillé', toCheck: 'À vérifier', expired: 'Verrouillage échu', unlocked: 'Déverrouillé' }[lockOf(a)], tone: lockOf(a) === 'locked' ? 'alert' : 'ok', source: CONTROLLER, limit: null, hypothesis: null },
      { label: 'Verrouillages journalisés', value: int(events.length), tone: events.length ? 'warn' : 'ok', source: `Journal Sécurité de ${CONTROLLER} (4740)`, limit: null, hypothesis: null },
    ];
    if (origins.length) facts.push({ label: 'Postes à l’origine', value: origins.map((o) => o.computer).join(', '), tone: 'warn', source: '4740', limit: null, hypothesis: 'Un poste récurrent suggère une session, un lecteur réseau ou un service qui utilise encore un ancien mot de passe.' });
    return {
      account: { dn: a.dn, name: a.name, sam: a.sam, sid: `S-1-5-21-3623811015-3361044348-30300820-${a.rid}` }, server: CONTROLLER, serverSource: 'pdc', serverLabel: `Émulateur PDC ${CONTROLLER} (fSMORoleOwner)`,
      hours, from: iso(now - hours * HOUR), to: iso(now), maxEvents: 200, truncated: false, state: 'read', events, origins, facts, verdict: lockOf(a),
      summary: events.length ? `${count(events.length, 'verrouillage journalisé', 'verrouillages journalisés')} sur la fenêtre` : 'Aucun verrouillage journalisé sur la fenêtre', simulated: true,
    };
  }

  // ---------------------------------------------------------------- plans (circuit of the engine)

  const plans = new Map();
  const receipts = new Map();
  const KINDS = {
    'account.unlock': { title: 'Déverrouiller le compte', label: 'Déverrouillage du compte' },
    'account.enable': { title: 'Activer le compte', label: 'Activation du compte' },
    'account.disable': { title: 'Désactiver le compte', label: 'Désactivation du compte' },
    'account.mustChangePassword': { title: 'Imposer un nouveau mot de passe', label: 'Changement de mot de passe imposé' },
    'account.expiration': { title: 'Fixer l’expiration du compte', label: 'Expiration du compte' },
    'account.resetPassword': { title: 'Réinitialiser le mot de passe', label: 'Réinitialisation du mot de passe' },
  };
  function seal(a, kind, changes, extra = {}) {
    const now = second(Date.now());
    const typed = a.adminCount === 1;
    const plan = {
      id: newId(), kind, ...KINDS[kind], summary: extra.summary ?? `${a.name}${COLON}${KINDS[kind].label.toLocaleLowerCase('fr')} sur ${CONTROLLER}.`,
      target: { kind: 'user', kindLabel: 'Compte utilisateur', name: a.name, dn: a.dn, objectGuid: a.guid, samAccountName: a.sam },
      changes, risks: extra.risks ?? [],
      confirmation: typed ? { typedNameRequired: true, typedName: a.sam, reason: `Compte à privilèges (adminCount = 1)${COLON}saisissez son nom.` } : { typedNameRequired: false, typedName: null, reason: `Confirmation simple${COLON}compte standard.` },
      reversibility: extra.reversibility ?? { reversible: false, label: 'Sans retour arrière', detail: 'Aucune compensation automatique.' },
      controller: CONTROLLER, operator: 'EXAMPLE\\j.martin', mode: 'simulation', simulated: true, createdAt: iso(now), expiresAt: iso(now + LIFETIME),
      fingerprint: hex(random(32)), details: `Opération${COLON}${kind}\nCible${COLON}${a.name}\nDN${COLON}${a.dn}\nMode${COLON}simulation (annuaire fictif en mémoire, aucun effet réel)`,
    };
    const token = newToken();
    plans.set(plan.id, { plan, token, used: false, apply: extra.apply, done: extra.done });
    return { plan, token };
  }
  const pendingOn = (a) => [...receipts.values()].some((r) => r.pending && r.target.objectGuid === a.guid);
  function target(args, allowed = ['dn']) {
    const values = readObject(args, allowed);
    const dn = requireDistinguishedName(getString(values, 'dn'), 'dn');
    const a = byDn(dn);
    if (!a) throw fail('write.targetUnknown', `Ce nom distinctif ne désigne aucun compte utilisateur de l’annuaire fictif${COLON}aucune écriture préparée.`);
    if (pendingOn(a)) throw fail('write.targetPending', `Une écriture précédente sur cet objet reste à vérifier${COLON}relisez son reçu dans Opérations avant d’en préparer une autre.`);
    return { values, a };
  }
  const nothing = (text) => fail('write.nothingToDo', text);

  async function unlockPlan(args) {
    const { a } = target(args);
    await sleep(160);
    if (!['locked', 'toCheck'].includes(lockOf(a))) throw nothing(`Ce compte n’est pas verrouillé${COLON}aucune écriture à préparer.`);
    return seal(a, 'account.unlock', [{ attribute: 'lockoutTime', label: 'Verrouillage', kind: 'clear', before: `Verrouillé depuis le ${dayText(a.lockedAt)} à ${timeText(a.lockedAt)}`, after: 'Déverrouillé', beforeValue: fileTime(a.lockedAt), afterValue: '0' }],
      { risks: [{ tone: 'warn', text: `Vérifiez l’identité du demandeur${COLON}un verrouillage peut aussi venir d’un ancien mot de passe enregistré sur un poste.` }], apply: () => { a.lockedAt = null; a.lockToCheck = false; a.lockExpired = false; a.bad = 0; } });
  }
  async function enablePlan(args, enable) {
    const { a } = target(args);
    await sleep(140);
    if (enable && a.enabled) throw nothing(`Ce compte est déjà activé${COLON}aucune écriture à préparer.`);
    if (!enable && !a.enabled) throw nothing(`Ce compte est déjà désactivé${COLON}aucune écriture à préparer.`);
    if (!enable && keyOf(a.dn) === keyOf(SESSION_DN)) throw fail('accounts.protectedAccount', `C’est votre compte de session${COLON}le désactiver vous retirerait l’accès à l’annuaire. Aucune écriture n’est préparée.`);
    return seal(a, enable ? 'account.enable' : 'account.disable', [{ attribute: 'userAccountControl', label: 'État du compte', kind: 'replace', before: enable ? 'Désactivé' : 'Activé', after: enable ? 'Activé' : 'Désactivé', beforeValue: enable ? '514' : '512', afterValue: enable ? '512' : '514' }],
      { reversibility: { reversible: true, label: 'Réversible', detail: `Par un nouveau plan «${NBSP}${enable ? 'Désactiver' : 'Activer'}${NBSP}».` }, apply: () => { a.enabled = enable; } });
  }
  async function mustChangePlan(args) {
    const { a } = target(args);
    await sleep(140);
    if (a.pwdSet === 0) throw nothing(`Le changement de mot de passe est déjà imposé à la prochaine connexion${COLON}aucune écriture à préparer.`);
    if (a.neverExpires) throw nothing(`Le mot de passe de ce compte n’expire jamais${COLON}un changement imposé resterait sans effet.`);
    return seal(a, 'account.mustChangePassword', [{ attribute: 'pwdLastSet', label: 'Changement à la prochaine connexion', kind: 'replace', before: `Changé le ${dayText(a.pwdSet)}`, after: 'Exigé (pwdLastSet = 0)', beforeValue: fileTime(a.pwdSet), afterValue: '0' }], { apply: () => { a.pwdSet = 0; } });
  }
  function dayArg(values) {
    if (!Object.hasOwn(values, 'date')) throw invalid(`${quote('date')} doit être une date AAAA-MM-JJ (au plus dans 50 ans) ou null.`);
    const v = values.date;
    if (v === null) return null;
    if (typeof v !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(v)) throw invalid(`${quote('date')} doit être une date AAAA-MM-JJ (au plus dans 50 ans) ou null.`);
    const [y, m, d] = v.split('-').map(Number);
    const t = new Date(y, m - 1, d).getTime();
    if (new Date(t).getDate() !== d || t > Date.now() + 50 * 365 * DAY) throw invalid(`${quote('date')} doit être une date AAAA-MM-JJ (au plus dans 50 ans) ou null.`);
    return t;
  }
  async function expirationPlan(args) {
    const { values, a } = target(args, ['dn', 'date']);
    const day = dayArg(values);
    await sleep(140);
    if (day === a.accountExpires) throw nothing(`Ce compte expire déjà à cette date${COLON}aucune écriture à préparer.`);
    const risks = day != null && day <= Date.now() ? [{ tone: 'alert', text: `Date passée${COLON}le compte sera expiré dès l’écriture.` }] : [];
    return seal(a, 'account.expiration', [{ attribute: 'accountExpires', label: 'Expiration du compte', kind: 'replace', before: a.accountExpires ? `Expire le ${dayText(a.accountExpires)}` : 'Jamais', after: day == null ? 'Jamais' : `Expire le ${dayText(day)} à 0${NBSP}h (dernier jour d’ouverture${COLON}${dayText(day - DAY)})`, beforeValue: fileTime(a.accountExpires), afterValue: day == null ? '0' : fileTime(day) }],
      { risks, reversibility: { reversible: true, label: 'Réversible', detail: 'Par un nouveau plan avec l’ancienne valeur.' }, apply: () => { a.accountExpires = day; } });
  }
  async function passwordPlan(args) {
    const { values, a } = target(args, ['dn', 'password', 'mustChange', 'unlock']);
    const password = getString(values, 'password');
    const mustChange = getBoolean(values, 'mustChange');
    const unlock = getBoolean(values, 'unlock');
    if (password.length < 1 || password.length > 256 || /[\u0000-\u001f]/.test(password)) throw invalid(`${quote('password')} doit faire de 1 à 256 caractères, sans caractère de contrôle.`);
    await sleep(160);
    const classes = [/[A-ZÀ-ÖØ-Þ]/u, /[a-zß-öø-ÿ]/u, /\d/, /[^\p{L}\p{N}]/u].filter((re) => re.test(password)).length;
    const unmet = [];
    if (password.length < 12) unmet.push('12 caractères au moins');
    if (classes < 3) unmet.push('trois types parmi majuscules, minuscules, chiffres et symboles');
    if (password.toLocaleLowerCase('fr').includes(a.sam.toLocaleLowerCase('fr'))) unmet.push('ni le nom du compte ni une partie du nom affiché');
    if (unmet.length) throw fail('accounts.passwordPolicy', `Mot de passe refusé par la stratégie du domaine${COLON}${unmet.join(`${NBSP}; `)}. Rien n’a été préparé.`);
    const locked = ['locked', 'toCheck'].includes(lockOf(a));
    const changes = [{ attribute: 'unicodePwd', label: 'Mot de passe', kind: 'reset', before: 'Mot de passe actuel (jamais lu)', after: 'Nouvelle valeur saisie, ni affichée ni conservée', beforeValue: null, afterValue: null },
      mustChange ? { attribute: 'pwdLastSet', label: 'Changement à la prochaine connexion', kind: 'replace', before: a.pwdSet ? `Changé le ${dayText(a.pwdSet)}` : 'Déjà à changer (0)', after: 'Exigé (pwdLastSet = 0)', beforeValue: fileTime(a.pwdSet), afterValue: '0' }
        : { attribute: 'pwdLastSet', label: 'Date du dernier changement', kind: 'replace', before: a.pwdSet ? `Changé le ${dayText(a.pwdSet)}` : 'Déjà à changer (0)', after: 'Date de l’écriture, posée par le contrôleur', beforeValue: fileTime(a.pwdSet), afterValue: null }];
    if (unlock && locked) changes.push({ attribute: 'lockoutTime', label: 'Verrouillage', kind: 'clear', before: 'Verrouillé', after: 'Déverrouillé', beforeValue: fileTime(a.lockedAt), afterValue: '0' });
    return seal(a, 'account.resetPassword', changes, {
      risks: [{ tone: 'warn', text: `Vérifiez l’identité du demandeur et transmettez le mot de passe par un canal sûr.` }],
      apply: () => { a.pwdSet = mustChange ? 0 : second(Date.now()); if (unlock && locked) { a.lockedAt = null; a.lockToCheck = false; a.bad = 0; } },
    });
  }

  function view(r) {
    const resultLabel = { applied: 'Appliquée (simulation)', noChange: `Déjà faite${COLON}rien envoyé` }[r.result] ?? r.result;
    const tone = r.result === 'applied' || r.result === 'noChange' ? 'ok' : 'warn';
    return { ...r, resultLabel, verificationLabel: 'Vérifiée par relecture', summary: r.result === 'applied' ? `Écriture appliquée et vérifiée par relecture. Simulation${COLON}annuaire fictif en mémoire, aucun effet réel.` : `L’objet était déjà dans l’état demandé${COLON}rien n’a été envoyé.`, tone };
  }
  async function execute(args) {
    const values = readObject(args, ['planId', 'token', 'typedName']);
    const planId = getString(values, 'planId');
    const entry = plans.get(planId);
    if (!entry) return writes['write.execute'](args);
    const token = getString(values, 'token');
    const typedName = getOptionalString(values, 'typedName');
    if (entry.used) throw fail('write.tokenUsed', `Ce plan a déjà servi${COLON}une écriture ne part qu’une fois et n’est jamais rejouée. Préparez de nouveau l’écriture si besoin.`);
    if (entry.token !== token) throw fail('write.tokenInvalid', `Jeton de confirmation refusé${COLON}rien n’a été envoyé. Préparez de nouveau l’écriture.`);
    if (Date.now() >= Date.parse(entry.plan.expiresAt)) throw fail('write.tokenExpired', `Confirmation expirée (plan de plus de 5${NBSP}min)${COLON}rien n’a été envoyé. Préparez de nouveau l’écriture pour relire l’objet.`);
    entry.used = true;
    if (entry.plan.confirmation.typedNameRequired && typedName !== entry.plan.confirmation.typedName) {
      throw fail('write.confirmationMismatch', `Le nom saisi ne correspond pas à la cible${COLON}rien n’a été envoyé. Préparez de nouveau l’écriture.`);
    }
    const a = byGuid(entry.plan.target.objectGuid);
    if (!a) throw fail('write.stale', `Le compte n’existe plus dans l’annuaire${COLON}rien n’a été envoyé.`);
    await sleep(500);
    entry.apply?.();
    const at = iso(second(Date.now()));
    const receipt = view({ id: newId(), kind: entry.plan.kind, title: entry.plan.title, label: entry.plan.label, target: entry.plan.target, at, sentAt: at, completedAt: at, verifiedAt: at,
      operator: entry.plan.operator, controller: CONTROLLER, mode: 'simulation', simulated: true, result: 'applied', verification: 'verified', pending: false, error: null,
      details: [{ label: 'Préconditions', value: `Compte relu sur ${CONTROLLER}${COLON}DN et GUID inchangés.` }, { label: 'Envoi', value: 'Appliquée dans l’annuaire fictif (en mémoire, aucun effet réel).' }, { label: 'Relecture', value: `Relu sur ${CONTROLLER}${COLON}conforme.` }], plan: entry.plan });
    receipts.set(receipt.id, receipt);
    log(`${entry.plan.label} (simulation)${COLON}${entry.plan.target.name} · relecture conforme`, 'ok', Date.now());
    return receipt;
  }
  async function receiptsList(args) {
    const base = await writes['write.receipts.list'](args);
    const mine = [...receipts.values()].map(({ details: _d, plan: _p, ...rest }) => rest);
    const all = [...mine, ...base.receipts].sort((x, y) => (x.at < y.at ? 1 : -1));
    const total = all.length;
    return { ...base, total, receipts: all, summary: base.pending ? base.summary : total ? `Aucune écriture à vérifier. ${count(total, 'reçu conservé', 'reçus conservés')}${NBSP}; rien n’est renvoyé automatiquement.` : base.summary };
  }
  const receiptGet = (args) => receipts.get(args?.id) ?? writes['write.receipts.get'](args);
  const receiptVerify = async (args) => { const r = receipts.get(args?.id); if (!r) return writes['write.receipts.verify'](args); await sleep(220); return r; };

  // ---------------------------------------------------------------- collective actions (AccountsBatch, AccountsBatchSeals)

  const batches = new Map();
  const ACTION_LABELS = { unlock: 'Déverrouiller', enable: 'Activer', disable: 'Désactiver', mustChange: 'Imposer un nouveau mot de passe', expiration: 'Fixer l’expiration' };
  const PLAN_OPS = { unlock: 'accounts.unlock.plan', enable: 'accounts.enable.plan', disable: 'accounts.disable.plan', mustChange: 'accounts.mustChange.plan', expiration: 'accounts.expiration.plan' };
  async function batchPreview(args) {
    const values = readObject(args, ['action', 'dns', 'date', 'ticket']);
    const action = getString(values, 'action');
    if (!ACTION_LABELS[action]) throw invalid(`${quote('action')} doit valoir unlock, enable, disable, mustChange ou expiration.`);
    if (!Array.isArray(values.dns) || values.dns.length === 0 || values.dns.length > 5000) throw invalid(`${quote('dns')} doit être une liste de 1 à 5${' '}000 noms distinctifs valides.`);
    const date = action === 'expiration' ? dayArg(values) : null;
    if (action !== 'expiration' && values.date != null) throw invalid(`${quote('date')} n’est admise que pour l’expiration.`);
    await sleep(240);
    const targets = [];
    const excluded = [];
    const seen = new Set();
    values.dns.forEach((dn, index) => {
      const a = byDn(String(dn));
      if (!a) { excluded.push({ dn, name: String(dn).split(',')[0].replace(/^CN=/, ''), reason: `Compte introuvable dans l’annuaire${COLON}relisez la liste` }); return; }
      const r = row(a);
      let reason = null;
      if (seen.has(a.guid)) reason = 'Doublon d’un compte déjà listé';
      else if (a.adminCount === 1) reason = `Compte à privilèges${COLON}à traiter seul, avec la saisie de son nom`;
      else if (action === 'unlock' && !['locked', 'toCheck'].includes(r.lock)) reason = 'Pas verrouillé';
      else if (action === 'enable' && a.enabled) reason = 'Déjà activé';
      else if (action === 'disable' && !a.enabled) reason = 'Déjà désactivé';
      else if (action === 'disable' && keyOf(a.dn) === keyOf(SESSION_DN)) reason = `Compte de session${COLON}jamais désactivé`;
      else if (action === 'mustChange' && (r.password === 'mustChange' || r.password === 'neverExpires')) reason = 'Changement déjà exigé ou sans effet';
      seen.add(a.guid);
      if (reason) { excluded.push({ dn: a.dn, name: a.name, reason }); return; }
      const [before, after] = { unlock: ['Verrouillé', 'Déverrouillé'], enable: ['Désactivé', 'Activé'], disable: ['Activé', 'Désactivé'], mustChange: ['Valide', 'À changer'], expiration: [a.accountExpires ? `Expire le ${dayText(a.accountExpires)}` : 'Jamais', date ? `Expire le ${dayText(date)}` : 'Jamais'] }[action];
      targets.push({ dn: a.dn, guid: a.guid, name: a.name, sam: a.sam, change: `${before} → ${after}`, before, after, index });
    });
    const groups = Object.entries(excluded.reduce((m, x) => ({ ...m, [x.reason]: (m[x.reason] ?? 0) + 1 }), {})).map(([reason, n]) => ({ reason, count: n })).sort((x, y) => y.count - x.count);
    const n = targets.length;
    const label = action === 'expiration' && date == null ? 'Supprimer l’expiration' : ACTION_LABELS[action];
    const confirmation = n === 0 ? 'none' : n === 1 ? 'simple' : 'typed';
    const id = newId();
    const fingerprint = hex(random(32));
    batches.set(id, { action, date, targets, typed: confirmation === 'typed', confirmed: false, issued: new Set(), expiresAt: Date.now() + BATCH_LIFETIME });
    return {
      action, actionLabel: label, title: `${label} · ${count(n, 'compte', 'comptes')}`, kind: { unlock: 'account.unlock', enable: 'account.enable', disable: 'account.disable', mustChange: 'account.mustChangePassword', expiration: 'account.expiration' }[action],
      planOperation: PLAN_OPS[action], count: n, confirmation, typedCount: n >= 2 ? String(n) : null, targets, shown: 12, excluded, excludedGroups: groups, excludedCount: excluded.length,
      impact: `${count(n, 'compte recevra', 'comptes recevront')} «${NBSP}${label.toLocaleLowerCase('fr')}${NBSP}», chacun avec son plan, son reçu et sa relecture.`, risks: action === 'disable' ? [{ tone: 'alert', text: `Les comptes désactivés ne pourront plus ouvrir de session.` }] : [],
      lines: [`${count(n, 'compte exact', 'comptes exacts')}, ${count(excluded.length, 'exclu', 'exclus')}`], details: targets.map((t) => `${t.name} (${t.sam})${COLON}${t.change}`).join('\n'),
      limit: 20000, date: date == null ? null : new Date(date).toISOString().slice(0, 10), simulated: true,
      batch: { id, fingerprint, count: n, typedRequired: confirmation === 'typed', expiresAt: iso(Date.now() + BATCH_LIFETIME), confirmed: false },
    };
  }
  function findBatch(id) {
    if (typeof id !== 'string' || !/^[0-9a-f]{32}$/.test(id)) throw invalid(`${quote('id')} doit être l’identifiant d’un aperçu collectif (32 caractères hexadécimaux).`);
    const b = batches.get(id);
    if (!b) throw fail('accounts.batchUnknown', `Aperçu collectif inconnu${COLON}rien n’a été préparé. Relisez l’aperçu.`);
    if (b.expiresAt <= Date.now()) { batches.delete(id); throw fail('accounts.batchExpired', `Aperçu collectif expiré (plus de 10${NBSP}min sans geste)${COLON}rien n’a été préparé. Relisez l’aperçu.`); }
    return b;
  }
  function batchConfirm(args) {
    const values = readObject(args, ['id', 'typedCount']);
    const b = findBatch(values.id);
    if (!b.targets.length) { batches.delete(values.id); throw fail('accounts.batchUnknown', `Aucun compte à traiter dans cet aperçu${COLON}rien n’est préparé.`); }
    if (b.typed && String(values.typedCount ?? '').trim() !== String(b.targets.length)) {
      batches.delete(values.id);
      throw fail('accounts.batchCountMismatch', `Le nombre saisi ne correspond pas au nombre exact de comptes${COLON}rien n’a été préparé. Relisez l’aperçu puis confirmez de nouveau.`);
    }
    b.confirmed = true;
    b.expiresAt = Date.now() + BATCH_LIFETIME;
    return { id: values.id, fingerprint: '', count: b.targets.length, typedRequired: b.typed, expiresAt: iso(b.expiresAt), confirmed: true };
  }
  async function batchPlan(args) {
    const values = readObject(args, ['id', 'index']);
    const b = findBatch(values.id);
    if (!b.confirmed) throw fail('accounts.batchUnconfirmed', `Ce lot n’est pas confirmé${COLON}aucun plan n’est préparé avant la confirmation.`);
    if (!Number.isInteger(values.index) || values.index < 0 || values.index >= b.targets.length) throw invalid(`${quote('index')} doit désigner un compte de l’aperçu scellé.`);
    if (b.issued.has(values.index)) throw fail('accounts.batchIssued', `Ce compte du lot a déjà reçu son plan${COLON}une écriture n’est jamais rejouée.`);
    b.issued.add(values.index);
    b.expiresAt = Date.now() + BATCH_LIFETIME;
    const t = b.targets[values.index];
    const call = { unlock: () => unlockPlan({ dn: t.dn }), enable: () => enablePlan({ dn: t.dn }, true), disable: () => enablePlan({ dn: t.dn }, false), mustChange: () => mustChangePlan({ dn: t.dn }), expiration: () => expirationPlan({ dn: t.dn, date: b.date == null ? null : new Date(b.date).toISOString().slice(0, 10) }) }[b.action];
    return call();
  }
  function batchCancel(args) {
    const values = readObject(args, ['ticket']);
    if (typeof values.ticket !== 'string') throw invalid(`${quote('ticket')} est obligatoire.`);
    return { cancelled: false };
  }

  // ---------------------------------------------------------------- accesses of Domenia (AccountAccess)

  const access = { revision: 1, epoch: 1, identity: 'EXAMPLE\\j.martin', displayName: 'Julien Martin', secondary: {}, temporary: {}, remembered: {}, lastTrial: null, validating: false,
    pending: [{ id: 'acc1', scope: 'ReadLaps', scopeLabel: 'Secrets LAPS', operation: 'Lecture du mot de passe LAPS', target: 'PC-PAR-0007', kind: 'accessDenied', kindLabel: 'Accès refusé', at: iso(REF - 14 * MIN), interactive: false, remembered: null }] };
  const bump = () => { access.revision += 1; };
  const usageLabel = (u) => (u === 'remote' ? 'Compte Postes' : 'Compte Secrets');
  function checkLogin(login, scope, target) {
    if (!/^([A-Za-z0-9._-]+\\[^\\@\s]+|[^\\@\s]+@[A-Za-z0-9.-]+|\.\\[^\\@\s]+)$/.test(login)) throw invalid(`${quote('login')} doit être un compte DOMAINE\\compte, compte@domaine, POSTE\\compte ou .\\compte.`);
    const local = login.startsWith('.\\') || (/^[^\\]+\\/.test(login) && !/^(EXAMPLE|example\.local)\\/i.test(login));
    if (local && scope !== 'Remote') throw fail('accounts.credentialContext', `Un compte local ne peut pas lire l’annuaire, LAPS ou BitLocker. Aucun essai n’a été envoyé.`);
    if (local && !target) throw fail('accounts.credentialContext', `Un compte local n’est accepté que pour son poste${COLON}indiquez le poste. Aucun essai n’a été envoyé.`);
    return local;
  }
  async function validate(login, password, scope, target) {
    const local = checkLogin(login, scope, target);
    access.validating = true; bump();
    await sleep(900);
    access.validating = false; bump();
    const now = iso(Date.now());
    const sam = login.replace(/^.*\\/, '').replace(/@.*$/, '');
    const a = local ? { sam } : accounts.find((x) => x.sam.toLowerCase() === sam.toLowerCase());
    const note = ` Simulation${COLON}l’annuaire fictif ne contient aucun mot de passe, seul l’état du compte est vérifié.`;
    const rightsNote = `Droits sur la ressource non certifiés par ce test${COLON}seule l’identité est vérifiée (droits poste et secrets non testés).`;
    if (!password) return { success: false, kind: 'input', message: 'Informations de connexion incomplètes.', hint: 'Complétez les champs demandés.', identity: null, controller: null, tone: 'warn', rightsNote, simulated: true, at: now };
    if (!a) return { success: false, kind: 'unknownAccount', message: 'Compte inconnu de l’annuaire.', hint: 'Vérifiez l’identifiant et son domaine (DOMAINE\\identifiant ou identifiant@domaine).', identity: null, controller: CONTROLLER, tone: 'alert', rightsNote, simulated: true, at: now };
    if (!local && !a.enabled) return { success: false, kind: 'disabled', message: 'Compte désactivé.', hint: 'Demandez sa réactivation puis réessayez.', identity: null, controller: CONTROLLER, tone: 'alert', rightsNote, simulated: true, at: now };
    if (!local && lockOf(a) === 'locked') return { success: false, kind: 'locked', message: 'Compte verrouillé.', hint: 'Demandez son déverrouillage puis réessayez.', identity: null, controller: CONTROLLER, tone: 'alert', rightsNote, simulated: true, at: now };
    const identity = local ? `${target}\\${sam}` : `EXAMPLE\\${a.sam}`;
    return { success: true, kind: 'ok', message: `Identité validée${COLON}${identity} (contrôleur ${CONTROLLER}).`, hint: note.trim(), identity, controller: CONTROLLER, tone: 'ok', rightsNote, simulated: true, at: now };
  }
  function state(args) {
    if (args !== undefined) requireNone(args);
    const temps = Object.entries(access.temporary);
    const secrets = access.secondary.secrets;
    const remote = access.secondary.remote;
    const machine = access.temporary.Remote ?? remote;
    const row = (resource, resourceKey, account, origin, action) => {
      const req = access.pending.find((p) => p.scope === resourceKey);
      return { resource, resourceKey, account, origin, state: req ? `${req.kindLabel} à revoir${COLON}utilisez un autre compte pour cette ressource, ou gardez le compte actuel.` : 'Aucun refus enregistré.', stateTone: req ? 'warn' : 'ok', action: req ? { id: 'recover', label: 'Utiliser un autre compte', argument: req.id } : action };
    };
    const secretsAccount = (k) => access.temporary[k]?.login ?? secrets?.login ?? access.identity;
    const memory = [
      ...['remote', 'secrets'].filter((u) => access.secondary[u]).map((u) => ({ key: `secondary:${u}`, resource: usageLabel(u), account: access.secondary[u].login, origin: u === 'remote' ? 'compte Postes de la page Comptes' : 'compte Secrets de la page Comptes', remaining: 'jusqu’à « Effacer » ou la fin de la session', minutes: -1, usable: true, state: 'Aucun refus enregistré.', stateTone: 'ok' })),
      ...temps.map(([k, t]) => ({ key: `temporary:${k}`, resource: k === 'ReadLaps' ? 'Secrets LAPS' : k === 'ReadBitLocker' ? 'Secrets BitLocker' : k.startsWith('RemoteLocal|') ? `Poste ${k.slice(12)}` : 'Postes', account: t.login, origin: k.startsWith('RemoteLocal|') ? 'compte local temporaire de ce poste' : 'compte temporaire accepté après un refus', remaining: t.lease === 'once' ? 'une seule utilisation' : t.lease === 'session' ? 'jusqu’à la fin de la session' : `encore ${t.minutes}${NBSP}min sans utilisation`, minutes: t.lease === 'inactivity' ? t.minutes : -1, usable: true, state: 'Aucun refus enregistré.', stateTone: 'ok' })),
    ];
    const secondaryView = (u) => {
      const held = access.secondary[u];
      const remembered = access.remembered[u] ?? (u === 'secrets' ? access.remembered.laps ?? null : null);
      return held
        ? { usage: u, label: usageLabel(u), account: held.login, active: true, activatedAt: held.at, controller: CONTROLLER, status: `Actif, validé par l’annuaire${COLON}droits sur la ressource non certifiés par ce test.`, statusTone: 'ok', remembered, resources: u === 'remote' ? ['Remote'] : ['ReadLaps', 'ReadBitLocker'] }
        : { usage: u, label: usageLabel(u), account: null, active: false, activatedAt: null, controller: null, status: u === 'remote' ? `Aucun compte Postes${COLON}les opérations sur les postes utilisent le compte de connexion.` : `Aucun compte Secrets${COLON}LAPS et BitLocker utilisent le compte de connexion.`, statusTone: 'off', remembered, resources: u === 'remote' ? ['Remote'] : ['ReadLaps', 'ReadBitLocker'] };
    };
    const temporaries = temps.length;
    return {
      connection: { connected: true, identity: access.identity, displayName: access.displayName, mode: 'demo', modeLabel: 'Simulation, annuaire fictif', controller: CONTROLLER, site: 'Paris', domain: 'example.local', netbios: 'EXAMPLE', since: iso(REF), authentication: 'Aucune (simulation)', detail: `Simulation, annuaire fictif · contrôleur ${CONTROLLER} · domaine example.local`,
        correction: { available: false, reason: `Simulation${COLON}la session n’utilise aucun mot de passe, il n’y a rien à corriger.` }, relogin: { available: true, reason: null } },
      identities: [{ id: 'directory', label: 'Annuaire', account: access.identity, origin: 'Simulation, annuaire fictif' }, { id: 'remote', label: 'Postes', account: machine?.login ?? access.identity, origin: machine ? 'compte Postes de la page Comptes' : 'compte de connexion' }, { id: 'secrets', label: 'Secrets LAPS et BitLocker', account: secrets?.login ?? 'Compte AD courant', origin: secrets ? 'compte Secrets de la page Comptes' : 'même compte que l’annuaire' }],
      pending: access.pending, pendingLimit: 16,
      inUse: [row('Annuaire', 'Directory', access.identity, 'simulation, annuaire fictif', null), row('Postes (WMI, C$, consoles)', 'Remote', machine?.login ?? access.identity, machine ? 'compte Postes de la page Comptes' : 'compte de connexion', { id: 'try', label: 'Essayer sur un poste', argument: null }),
        row(`Secrets${COLON}LAPS`, 'ReadLaps', secretsAccount('ReadLaps'), access.temporary.ReadLaps ? 'compte temporaire accepté après un refus' : secrets ? 'compte Secrets de la page Comptes' : 'même compte que l’annuaire', { id: 'activate', label: 'Compte Secrets', argument: 'secrets' }),
        row(`Secrets${COLON}BitLocker`, 'ReadBitLocker', secretsAccount('ReadBitLocker'), secrets ? 'compte Secrets de la page Comptes' : 'même compte que l’annuaire', { id: 'activate', label: 'Compte Secrets', argument: 'secrets' })],
      memory, remote: secondaryView('remote'), secrets: secondaryView('secrets'),
      validation: { busy: access.validating, usage: null, label: null, startedAt: null, timeoutSeconds: 12 }, lastTrial: access.lastTrial,
      lease: { defaultMinutes: 30, minMinutes: 1, maxMinutes: 480 }, vault: { available: false, reason: `Indisponible en simulation, comme dans Domenia 1${COLON}aucun mot de passe n’est enregistré sur ce PC.` },
      refusals: 0, generation: access.revision, summary: `${temporaries ? count(temporaries, 'compte en mémoire', 'comptes en mémoire') : 'Aucun compte temporaire en mémoire'} · ${access.pending.length ? count(access.pending.length, 'accès à revoir', 'accès à revoir') : 'aucun accès à revoir'}.`, simulated: true,
      revision: access.revision, epoch: access.epoch, revealSeconds: 5,
    };
  }
  function revision(args) {
    requireNone(args);
    const oldest = access.pending[0];
    return { revision: access.revision, leaseMinute: 0, pending: access.pending.length, oldestPendingId: oldest?.id ?? null, oldestPendingLabel: oldest ? `${oldest.operation} · ${oldest.scopeLabel}${oldest.target ? ` · ${oldest.target}` : ''}` : null, temporaries: Object.keys(access.temporary).length, paused: 0, validating: access.validating, epoch: access.epoch };
  }
  const credential = (args, extra = []) => {
    const values = readObject(args, ['usage', 'login', 'password', ...extra]);
    const usage = getString(values, 'usage');
    if (usage !== 'remote' && usage !== 'secrets') throw invalid(`${quote('usage')} doit valoir remote ou secrets.`);
    return { usage, login: getString(values, 'login').trim(), password: getString(values, 'password') };
  };
  async function test(args) { const c = credential(args); return validate(c.login, c.password, c.usage === 'remote' ? 'Remote' : 'ReadLaps', null); }
  async function activate(args) {
    const c = credential(args);
    const result = await validate(c.login, c.password, c.usage === 'remote' ? 'Remote' : 'ReadLaps', null);
    if (result.success) {
      access.secondary[c.usage] = { login: result.identity, at: iso(Date.now()) };
      access.remembered[c.usage] = { account: result.identity, lastUsedAt: iso(Date.now()) };
      for (const k of c.usage === 'remote' ? ['Remote'] : ['ReadLaps', 'ReadBitLocker']) { delete access.temporary[k]; access.pending = access.pending.filter((p) => p.scope !== k); }
      bump();
      log(`${usageLabel(c.usage)} activé${COLON}${result.identity} (droits sur la ressource non certifiés par ce test)`, 'info', Date.now());
    }
    return { result, state: state() };
  }
  function clear(args) { const u = getString(readObject(args, ['usage']), 'usage'); if (access.secondary[u]) { delete access.secondary[u]; bump(); } return state(); }
  async function recover(args) {
    const values = readObject(args, ['id', 'login', 'password', 'lease', 'minutes', 'target']);
    const req = access.pending.find((p) => p.id === values.id);
    if (!req) throw fail('accounts.requestUnknown', `Cet accès n’est plus en attente${COLON}rien n’a été changé.`);
    const target = req.scope === 'Remote' ? getOptionalString(values, 'target') ?? req.target : null;
    const result = await validate(getString(values, 'login').trim(), getString(values, 'password'), req.scope, target);
    if (result.success) {
      const local = req.scope === 'Remote' && !/^EXAMPLE\\/i.test(result.identity);
      const key = local ? `RemoteLocal|${String(target).toUpperCase()}` : req.scope;
      access.temporary[key] = { login: result.identity, lease: values.lease ?? 'inactivity', minutes: values.minutes ?? 30 };
      access.pending = access.pending.filter((p) => p.scope !== req.scope);
      if (!local) access.remembered[req.scope === 'ReadLaps' ? 'laps' : req.scope === 'Remote' ? 'remote' : 'other'] = { account: result.identity, lastUsedAt: iso(Date.now()) };
      bump();
    }
    return { result, state: state() };
  }
  function dismiss(args) {
    const id = getString(readObject(args, ['id']), 'id');
    if (!access.pending.some((p) => p.id === id)) throw fail('accounts.requestUnknown', `Cet accès n’est plus en attente${COLON}rien n’a été changé.`);
    access.pending = access.pending.filter((p) => p.id !== id); bump();
    return state();
  }
  function forget(args) {
    const key = getString(readObject(args, ['key']), 'key');
    if (key.startsWith('temporary:') && access.temporary[key.slice(10)]) delete access.temporary[key.slice(10)];
    else if (key.startsWith('secondary:') && access.secondary[key.slice(10)]) delete access.secondary[key.slice(10)];
    else throw fail('accounts.keyUnknown', `Ce compte n’est plus en mémoire${COLON}rien n’a été changé.`);
    bump();
    return state();
  }
  function forgetAll(args) { requireNone(args); access.temporary = {}; bump(); return state(); }
  function cancel(args) { requireNone(args); return { cancelled: false }; }
  async function tryRemote(args) {
    const computer = getString(readObject(args, ['computer']), 'computer').trim();
    await sleep(800);
    const local = access.temporary[`RemoteLocal|${computer.toUpperCase()}`];
    const used = local ?? access.temporary.Remote ?? access.secondary.remote;
    const account = used?.login ?? access.identity;
    const ok = /^PC-/i.test(computer);
    access.lastTrial = { computer, account, origin: local ? 'compte local temporaire de ce poste' : used ? 'compte Postes de la page Comptes' : 'compte de connexion', verdict: ok ? 'adminOk' : 'unreachable', success: ok,
      text: ok ? `Accès administrateur OK sur ${computer} (Windows 11 Entreprise).` : `Poste injoignable${COLON}${computer}.`, caption: ok ? 'Microsoft Windows 11 Entreprise' : null, tone: ok ? 'ok' : 'warn', at: iso(Date.now()), simulated: true };
    bump();
    log(`Essai du compte poste sur ${computer}${COLON}${ok ? 'accès administrateur OK' : 'non concluant ou refusé'}`, ok ? 'ok' : 'warn', Date.now());
    return access.lastTrial;
  }
  function correct(args) { readObject(args, ['password']); throw fail('accounts.correctionUnavailable', `Simulation${COLON}la session n’utilise aucun mot de passe, il n’y a rien à corriger.`); }
  async function switchAccount(args) {
    const values = readObject(args, ['login', 'password']);
    const result = await validate(getString(values, 'login').trim(), getString(values, 'password'), 'Directory', null);
    if (!result.success) return { result, identity: null, epoch: access.epoch };
    access.identity = result.identity;
    access.displayName = accounts.find((a) => `EXAMPLE\\${a.sam}`.toLowerCase() === result.identity.toLowerCase())?.name ?? null;
    access.secondary = {}; access.temporary = {}; access.pending = []; access.lastTrial = null; access.epoch += 1; bump();
    log(`Changement de compte${COLON}${result.identity} (nouvelle session${NBSP}; comptes et refus de la session précédente oubliés)`, 'info', Date.now());
    return { result: { ...result, message: `Session ouverte avec ${result.identity} (contrôleur ${CONTROLLER}).`, hint: `Les vues sont relues pour la nouvelle session${NBSP}; rien n’est rejoué.` }, identity: result.identity, epoch: access.epoch };
  }
  function rememberedForget(args) {
    const u = getString(readObject(args, ['usage']), 'usage');
    delete access.remembered[u];
    if (u === 'secrets') { delete access.remembered.laps; delete access.remembered.bitlocker; }
    bump();
    return state();
  }

  // ---------------------------------------------------------------- references

  function requirements(args) {
    requireNone(args);
    const ldap = 'LDAP 389/TCP vers le contrôleur de domaine (signature et scellement).';
    const cim = `CIM/DCOM${COLON}135/TCP puis ports RPC dynamiques du poste${NBSP}; WSMan 5985/5986 seulement s’il est déjà en service.`;
    const rows = [
      ['AccountsList', 'Comptes d’une OU', 'Annuaire', 'Read', 'Lecture', 'Directory', 'Annuaire', 'Compte de connexion', `Lecture de l’annuaire${COLON}tout compte authentifié du domaine lit les attributs ordinaires.`, ldap],
      ['LockoutDiagnosis', 'Verrouillages d’un compte (4740)', 'Réseau', 'Read', 'Lecture', 'Directory', 'Annuaire', 'Compte de connexion', 'Lecteurs des journaux d’événements sur l’émulateur PDC.', `Journal d’événements à distance${COLON}135/TCP puis ports RPC dynamiques du contrôleur.`],
      ['WriteUnlock', 'Déverrouiller un compte', 'Annuaire', 'DirectoryWrite', 'Écriture dans l’annuaire', 'Directory', 'Annuaire', 'Compte de connexion', 'Écriture de lockoutTime sur les comptes de l’OU (délégation).', ldap],
      ['WriteResetPassword', 'Réinitialiser un mot de passe', 'Annuaire', 'DirectoryWrite', 'Écriture dans l’annuaire', 'Directory', 'Annuaire', 'Compte de connexion', 'Droit étendu « Réinitialiser le mot de passe » sur les comptes de l’OU.', `${ldap} Canal scellé obligatoire.`],
      ['WriteAccountDisabled', 'Activer ou désactiver un compte', 'Annuaire', 'DirectoryWrite', 'Écriture dans l’annuaire', 'Directory', 'Annuaire', 'Compte de connexion', 'Écriture de userAccountControl sur les comptes de l’OU.', ldap],
      ['ComputerInventory', 'Inventaire d’un poste', 'Postes', 'Read', 'Lecture', 'Remote', 'Postes', 'Compte poste, sinon compte de connexion', 'Administrateur local du poste, ou droits WMI délégués (activation DCOM à distance et lecture de root\\cimv2).', cim],
      ['ComputerRestart', 'Redémarrage d’un poste', 'Postes', 'RemoteMutation', 'Action sur le poste', 'Remote', 'Postes', 'Compte poste, sinon compte de connexion', 'Administrateur local du poste.', cim],
      ['ReadLaps', 'Mot de passe LAPS d’un poste', 'Annuaire', 'Read', 'Lecture', 'Laps', 'Secrets LAPS', 'Compte secrets, sinon compte de connexion', 'Lecture de l’attribut confidentiel LAPS (délégation).', ldap],
      ['ComputerPing', 'Ping d’un poste', 'Réseau', 'Read', 'Lecture', 'Remote', 'Postes', 'Aucun compte', 'Aucun droit particulier.', 'ICMP écho vers le poste.'],
      ['SettingsSave', 'Réglages de l’application', 'Local', 'LocalWrite', 'Écriture locale', 'Local', 'Local', 'Compte Windows de l’opérateur', 'Écriture dans %LOCALAPPDATA%\\Domenia.', 'Aucun accès réseau.'],
    ].map(([id, label, family, effect, effectLabel, resource, resourceLabel, account, right, accessText]) => ({ id, label, family, provider: family === 'Postes' ? 'Cim' : family === 'Local' ? 'Local' : 'Directory', effect, effectLabel, resource, resourceLabel, account, right, access: accessText, known: true }));
    return { rows, families: ['Annuaire', 'Postes', 'Réseau', 'Local'], unknownText: `Droit non documenté pour cette opération${COLON}lisez le code d’erreur natif.` };
  }
  function transports(args) {
    requireNone(args);
    const t = (id, transport, usage, ports, stateText, stateTone, rule, intrusive) => ({ id, transport, usage, ports, state: stateText, stateTone, rule, intrusive });
    return {
      rows: [
        t('ldap', 'LDAP', 'Lectures et écritures de l’annuaire', '389/TCP (signature et scellement Kerberos ou NTLM)', 'Actif', 'ok', 'Authentification sécurisée Windows. Aucun certificat n’est accepté à l’aveugle.', false),
        t('cim-dcom', 'CIM/DCOM', 'Inventaire et diagnostic des postes', '135/TCP puis ports RPC dynamiques', 'Actif', 'ok', 'Transport par défaut des lectures des postes.', false),
        t('cim-wsman', 'CIM/WSMan', 'Inventaire si WinRM est déjà en service', '5985/TCP, 5986/TCP', 'Autorisé s’il est déjà en service sur le poste', 'info', 'WinRM n’est jamais activé par Domenia.', false),
        t('wts', 'WTS', 'Sessions ouvertes sur un poste', '445/TCP (canal nommé)', 'Actif', 'ok', 'Lecture seule des sessions.', false),
        t('admin-share', 'Partage ADMIN$', 'Copie d’outils sur un poste', '445/TCP', 'Inactif sans autorisation explicite', 'off', 'Seulement pendant une intervention autorisée, pour ce poste.', true),
        t('scheduler', 'Planificateur', 'Tâche ponctuelle sur un poste', '135/TCP puis RPC', 'Inactif sans autorisation explicite', 'off', 'Remote.UseTaskFallback, et une autorisation d’intervention en cours.', true),
        t('psexec', 'PsExec', 'Repli d’exécution distante', '445/TCP', 'Inactif sans autorisation explicite', 'off', 'Aucun compte explicite converti en argument.', true),
      ],
      consentActive: false, consentText: `Aucune autorisation d’intervention en cours${COLON}une autorisation couvre un seul poste pendant 5 minutes, sur geste explicite (Assistance poste, Intervenir).`,
      settingsSource: 'Réglages par défaut de Domenia 1 (Domenia.config.json absent)',
      note: 'Un transport intrusif n’est jamais un repli silencieux d’une lecture ni d’une détection. Rien ici ne modifie un réglage de Windows.',
    };
  }

  return {
    'accounts.list': list,
    'accounts.scope.get': scopeGet,
    'accounts.scope.set': scopeSet,
    'accounts.scope.reset': scopeReset,
    'accounts.detail': detail,
    'accounts.lockouts': lockouts,
    'accounts.batch.preview': batchPreview,
    'accounts.batch.confirm': batchConfirm,
    'accounts.batch.plan': batchPlan,
    'accounts.batch.cancel': batchCancel,
    'accounts.unlock.plan': unlockPlan,
    'accounts.enable.plan': (args) => enablePlan(args, true),
    'accounts.disable.plan': (args) => enablePlan(args, false),
    'accounts.mustChange.plan': mustChangePlan,
    'accounts.expiration.plan': expirationPlan,
    'accounts.password.plan': passwordPlan,
    'accounts.access.state': state,
    'accounts.access.revision': revision,
    'accounts.access.test': test,
    'accounts.access.activate': activate,
    'accounts.access.clear': clear,
    'accounts.access.recover': recover,
    'accounts.access.dismiss': dismiss,
    'accounts.access.forget': forget,
    'accounts.access.forgetAll': forgetAll,
    'accounts.access.cancel': cancel,
    'accounts.access.tryRemote': tryRemote,
    'accounts.connection.correct': correct,
    'accounts.connection.switch': switchAccount,
    'accounts.remembered.forget': rememberedForget,
    'accounts.requirements': requirements,
    'accounts.transports': transports,
    'write.execute': execute,
    'write.receipts.list': receiptsList,
    'write.receipts.get': receiptGet,
    'write.receipts.verify': receiptVerify,
  };
}
