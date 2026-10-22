// Browser preview of the search screen (docs/ops/rechercher.md): the search.* operations with the result shapes, error
// codes and main texts of the engine (SearchService, SearchOperations, SimulatedSearchReader), on a small fictitious
// example.local directory built in the page (about a hundred objects, deterministic). Surveys, revalidations and memory live
// in the memory of the page: nothing leaves it, nothing is kept after a reload. Progress events are not replayed (the
// preview has no host to push them): a survey answers at its end. The helpers of mock.js are handed in.

const MIN = 60_000;
const HOUR = 60 * MIN;
const DAY = 24 * HOUR;
const MAX_LIMIT = 20000;
const PLAN_LIFETIME = 10 * MIN;

/**
 * @param {object} h  Helpers of mock.js: readObject, getString, getOptionalString, requireDistinguishedName, invalid, fail, quote, int, sleep, NBSP, REF.
 * @returns {Object<string, (args: any) => any>}
 */
export function createSearchOperations(h) {
  const { readObject, getString, getOptionalString, requireDistinguishedName, invalid, fail, quote, int, sleep, NBSP, REF } = h;
  const COLON = `${NBSP}: `;
  const ROOT = 'DC=example,DC=local';
  const DNS = 'example.local';
  const now = () => REF ?? Date.now();
  const iso = (t) => new Date(t).toISOString().replace(/\.\d{3}Z$/, 'Z');
  const hex = () => [...crypto.getRandomValues(new Uint8Array(16))].map((b) => b.toString(16).padStart(2, '0')).join('');
  const count = (n, one, many) => `${int(n)} ${Math.abs(n) >= 2 ? many : one}`;
  const fold = (t) => String(t ?? '').normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase();
  let seed = 20261022;
  const rnd = () => { seed = (seed * 1103515245 + 12345) % 2147483648; return seed / 2147483648; };
  const guid = () => {
    const b = Array.from({ length: 16 }, () => Math.floor(rnd() * 256).toString(16).padStart(2, '0')).join('');
    return `${b.slice(0, 8)}-${b.slice(8, 12)}-4${b.slice(13, 16)}-a${b.slice(17, 20)}-${b.slice(20, 32)}`;
  };
  const leaf = (dn) => dn.split(',')[0].split('=')[1];
  const pathOf = (dn) => [DNS, ...dn.split(',').filter((p) => !/^DC=/i.test(p)).map((p) => p.split('=')[1]).reverse()].join(`${NBSP}› `);
  const under = (dn, base, subtree) => {
    const a = dn.toLowerCase(); const b = base.toLowerCase();
    if (!a.endsWith(`,${b}`)) return false;
    return subtree || a.slice(0, a.length - b.length - 1).split(',').length === 1;
  };

  // ---------- Fictitious directory ----------

  const sites = ['Paris', 'Lyon', 'Bordeaux'];
  const first = ['Camille', 'Martine', 'Julien', 'Émilie', 'Marc', 'Sophie', 'Thomas', 'Claire', 'Nicolas', 'Léa', 'Antoine', 'Inès', 'Hugo', 'Chloé'];
  const last = ['Martin', 'Dufour', 'Bernard', 'Petit', 'Durand', 'Lefèvre', 'Moreau', 'Girard', 'Roux', 'Fournier'];
  const objects = [];
  const presence = (state, at) => ({
    state, tone: { online: 'ok', noReply: 'warn', error: 'alert' }[state] ?? 'off',
    label: { online: 'En ligne', noReply: 'Sans réponse au ping', error: 'Erreur de ping', unknown: 'Non vérifié' }[state],
    checkedAt: at ? iso(at) : null, lastOnlineAt: state === 'online' && at ? iso(at) : null,
    detail: state === 'online' ? 'Écho ICMP reçu.' : state === 'noReply' ? 'Aucun écho : éteint, hors réseau ou ICMP filtré.' : state === 'error' ? 'Nom non résolu par le DNS.' : 'Aucun relevé de moins de 30 jours.',
  });
  const flags = (o = {}) => ({ disabled: false, locked: false, lockToCheck: false, passwordExpired: false, passwordNeverExpires: false, passwordNotRequired: false, mustChange: false, inactive: false, neverLoggedOn: false, admin: false, accountExpiring: false, accountExpired: false, ...o });
  const base = (kind, name, dn, extra) => ({
    id: guid(), kind, kindLabel: { user: 'Utilisateur', computer: 'Poste', group: 'Groupe', ou: 'OU' }[kind], name, display: null, login: null, upn: null, mail: null, description: null,
    dn, container: pathOf(dn.split(',').slice(1).join(',')), os: null, osVersion: null, lastLogon: null, changed: iso(now() - Math.floor(rnd() * 40) * DAY), created: iso(now() - 400 * DAY),
    readAt: iso(now() - 12 * MIN), presence: null, console: null, association: null, address: null, group: null, verdict: null, rank: 0, ...extra,
  });
  const users = [];
  sites.forEach((site, s) => {
    for (let n = 0; n < 14; n++) {
      const f = first[(n + s * 3) % first.length]; const l = last[(n * 7 + s) % last.length];
      const sam = `${fold(f)[0]}.${fold(l)}${n > 9 ? n : ''}`;
      const locked = (n + s) % 9 === 0; const disabled = n === 13;
      const dn = `CN=${f} ${l},OU=${site},OU=Utilisateurs,${ROOT}`;
      const u = base('user', `${f} ${l}`, dn, {
        display: `${f} ${l}`, login: sam, upn: `${sam}@${DNS}`, mail: `${fold(f)}.${fold(l)}@${DNS}`,
        state: disabled ? { key: 'disabled', label: 'Désactivé', tone: 'off' } : locked ? { key: 'locked', label: 'Verrouillé', tone: 'alert' } : { key: 'active', label: 'Actif', tone: 'ok' },
        flags: flags({ locked, disabled, inactive: n === 11, neverLoggedOn: n === 12 }), lastLogon: n === 12 ? null : iso(now() - (n === 11 ? 120 : n % 6) * DAY),
      });
      users.push(u); objects.push(u);
    }
  });
  sites.forEach((site, s) => {
    for (let n = 1; n <= 24; n++) {
      const name = `PC-${site.slice(0, 3).toUpperCase()}-${String(n).padStart(4, '0')}`;
      const dn = `CN=${name},OU=${site},OU=Postes,${ROOT}`;
      const owner = users[(s * 14 + n) % users.length];
      const st = n % 7 === 0 ? 'noReply' : n % 11 === 0 ? 'unknown' : n === 23 ? 'error' : 'online';
      const at = st === 'unknown' ? null : now() - (n % 5) * HOUR - 28 * MIN;
      const c = base('computer', name, dn, {
        login: name, upn: `${name.toLowerCase()}.${DNS}`, description: `Poste de ${owner.name}`, os: n % 4 === 0 ? 'Windows 10 22H2' : 'Windows 11 23H2', osVersion: n % 4 === 0 ? '10.0 (19045)' : '10.0 (22631)',
        state: n === 24 ? { key: 'disabled', label: 'Désactivé', tone: 'off' } : { key: 'active', label: 'Actif', tone: 'ok' }, flags: flags({ disabled: n === 24, inactive: n % 10 === 0 }),
        lastLogon: iso(now() - (n % 10 === 0 ? 100 : n % 3) * DAY), presence: presence(st, at),
        console: st === 'online' && n % 2 ? { state: 'seen', label: `${owner.name} (${owner.login})`, user: owner.name, login: owner.login, userDn: owner.dn, at: iso(at) } : st === 'online' ? { state: 'none', label: 'Aucune session à la console', user: null, login: null, userDn: null, at: iso(at) } : { state: 'unknown', label: 'Non déterminé', user: null, login: null, userDn: null, at: null },
        association: n % 3 ? { label: `${owner.name} (${owner.login})`, dn: owner.dn, source: 'Déclaré dans l’annuaire (managedBy)', qualification: 'Déclaré', note: 'L’identité de la personne au poste n’est pas vérifiable par Domenia.' } : null,
        address: st === 'unknown' ? null : { ip: `10.${(s + 1) * 10}.1.${10 + n}`, mac: `D4-81-D7-0${s}-00-${String(n).padStart(2, '0')}`, observedAt: iso(at), notice: 'Adresse relevée par Domenia ; elle a pu changer depuis.' },
      });
      objects.push(c);
    }
  });
  ['GG-Support', 'GG-Comptabilité', 'GG-Direction', 'GG-Paris', 'GG-Lyon', 'GG-Bordeaux', 'Admins locaux'].forEach((g, n) => objects.push(base('group', g, `CN=${g},OU=Groupes,${ROOT}`, {
    login: g, state: { key: 'group', label: 'Groupe', tone: 'info' }, flags: flags({ admin: n === 6 }), group: { scopeLabel: n === 6 ? 'Domaine local' : 'Globale', members: 3 + n * 4 },
  })));
  const OUS = [`OU=Postes,${ROOT}`, `OU=Utilisateurs,${ROOT}`, `OU=Groupes,${ROOT}`, ...sites.map((s) => `OU=${s},OU=Postes,${ROOT}`), ...sites.map((s) => `OU=${s},OU=Utilisateurs,${ROOT}`)];
  objects.sort((a, b) => fold(a.name).localeCompare(fold(b.name)));
  const byId = new Map(objects.map((o) => [o.id, o]));

  // ---------- Lists ----------

  const lists = new Map();
  const plans = new Map();
  let resume = null;
  let suspended = null;
  const ofType = (o, type) => type === 'all' || ({ users: 'user', computers: 'computer', groups: 'group', ous: 'ou' }[type] === o.kind);
  const typeLabel = (t) => ({ all: 'Tous les types', users: 'Personnes', computers: 'Postes', groups: 'Groupes', ous: 'OU' }[t] ?? 'Tous les types');
  const readType = (v) => { const t = getOptionalString(v, 'type') ?? 'all'; if (!['all', 'users', 'computers', 'groups', 'ous'].includes(t)) throw invalid(`${quote('type')} vaut all, users, computers, groups ou ous.`); return t; };
  const readLimit = (v, fallback = 100) => { const n = v.limit ?? fallback; if (!Number.isInteger(n) || n < 1 || n > MAX_LIMIT) throw invalid(`${quote('limit')} doit être un entier de 1 à ${int(MAX_LIMIT)}.`); return n; };
  const requireList = (id) => { const l = lists.get(id); if (!l) throw fail('search.listUnknown', `Liste inconnue ou trop ancienne${COLON}relancez la recherche.`); return l; };

  function scopeOf(global, dn, subtree) {
    const whole = dn.toLowerCase() === ROOT.toLowerCase();
    const name = whole ? DNS : leaf(dn);
    const path = whole ? DNS : pathOf(dn);
    if (global) return whole ? { mode: 'global', dn: ROOT, label: 'Domaine entier', path, subtree: true, wholeDomain: true, chip: 'Partout · domaine entier' }
      : { mode: 'global', dn, label: `Dans ${quote(name)} · sous-OU incluses`, path, subtree: true, wholeDomain: false, chip: `Dans ${quote(name)}` };
    const parts = path.split(`${NBSP}› `);
    const parent = parts.length >= 2 ? parts.at(-2) : DNS;
    return { mode: 'ou', dn, label: whole ? 'Tout le domaine · sous-OU incluses' : `Dans cette OU${COLON}${name} (dans ${parent}) · ${subtree ? 'Sous-OU incluses' : 'Enfants directs'}`, path, subtree: whole || subtree, wholeDomain: whole, chip: `${whole ? 'Domaine' : 'OU'} ${name}` };
  }

  function result(l, rows, appended = false) {
    const more = l.matches.length > l.loaded;
    const next = Math.min(MAX_LIMIT, Math.max(l.limit + 1, l.limit * 2));
    return {
      listId: l.id, kind: l.kind, scope: l.scope, type: l.type, text: l.text, match: l.match, plan: l.plan, rows, loaded: l.loaded, limit: l.limit, complete: !more, limitReached: more,
      continuation: more ? { allowed: true, nextLimit: next, page: next - l.loaded, jumpLimit: next < 1000 ? 1000 : 0, jumpText: next < 1000 ? `Charger jusqu’à ${int(1000)}` : null, reason: `Lit les ${int(next - l.loaded)} lignes suivantes, sans relire les lignes déjà chargées.` }
        : { allowed: false, nextLimit: l.limit, page: 0, jumpLimit: 0, jumpText: null, reason: `Liste complète${COLON}aucune suite à charger.` },
      counter: more ? `${count(l.loaded, 'ligne chargée', 'lignes chargées')} · liste limitée à ${int(l.limit)}${COLON}affinez ou chargez la suite` : `${count(l.loaded, 'résultat', 'résultats')} · liste complète`,
      absence: `Portée${COLON}${l.scope.label}. Un objet extérieur à cette portée n’est pas recherché. ${more ? `Plafond de ${int(l.limit)} lignes atteint${COLON}la liste est incomplète.` : 'Lecture terminée dans cette portée et selon ces critères ; elle ne prouve pas une absence ailleurs dans l’annuaire.'}`,
      offer: l.kind === 'search' && l.match === 'prefix' && !more && l.loaded <= 3 && !l.text.includes('*') ? { term: l.text, label: `Chercher aussi les noms qui contiennent ${quote(l.text)}`, tip: 'Relance la même recherche sur les noms qui contiennent ce texte. Plus lent ; rien n’est lu avant le clic.' } : null,
      dns: null, view: l.view, verdicts: l.verdicts ?? null, sourceLabel: l.kind === 'localQuery' || l.kind === 'address' ? 'Relevés fictifs' : 'Annuaire fictif (aperçu)', readAt: iso(now() - 2000), appended,
    };
  }

  function open(kind, { text = '', type = 'all', match = 'prefix', dn = ROOT, subtree = true, global = false, view = null, plan = null, matches, limit }) {
    const l = { id: hex(), kind, text, type, match, scope: scopeOf(global, dn, subtree), plan: plan ?? { kind: kind === 'browse' ? 'browse' : 'default', valid: true, reason: '', hint: '', notes: [], tokens: [], identifier: null, address: null, ldapFilter: '', costly: false, freeText: text }, view, matches, loaded: 0, limit, known: new Set() };
    lists.set(l.id, l);
    if (lists.size > 24) lists.delete(lists.keys().next().value);
    const rows = matches.slice(0, limit);
    l.loaded = rows.length;
    rows.forEach((r) => l.known.add(r.id));
    return { l, rows };
  }

  async function run(args) {
    const v = readObject(args, ['text', 'scope', 'type', 'limit', 'match']);
    const text = getString(v, 'text').trim();
    const type = readType(v); const limit = readLimit(v);
    const match = getOptionalString(v, 'match') ?? 'prefix';
    if (text.replace(/\*/g, '').length < 2) throw fail('search.textInvalid', `Saisissez au moins 2 caractères${COLON}un nom, un identifiant, une adresse ou un poste.`);
    const scopeDn = getOptionalString(v, 'scope');
    const baseDn = scopeDn ? requireDistinguishedName(scopeDn, 'scope') : ROOT;
    await sleep(160);
    const words = fold(text).split(/\s+/).filter(Boolean);
    const values = (o) => [o.name, o.login, o.display, o.upn, o.mail].filter(Boolean).map(fold);
    const ok = (o) => ofType(o, type) && (baseDn === ROOT || under(o.dn, baseDn, true))
      && words.every((w) => values(o).some((x) => (match === 'contains' ? x.includes(w.replace(/\*/g, '')) : x.startsWith(w.replace(/\*/g, '')) || x.split(/[\s.-]/).some((p) => p.startsWith(w)))));
    const exact = (o) => values(o).includes(fold(text));
    const matches = objects.filter(ok).map((o) => ({ ...o, rank: exact(o) ? 0 : fold(o.name).startsWith(words[0] ?? '') ? 4 : 6 })).sort((a, b) => a.rank - b.rank);
    const plan = { kind: match === 'contains' ? 'contains' : 'default', valid: true, reason: '', hint: match === 'contains' ? 'Noms qui contiennent les mots : plus lent.' : 'Chaque mot doit figurer au début d’un nom, d’un compte, d’un nom affiché, d’un courriel ou d’un nom DNS.', notes: [], tokens: [], identifier: null, address: null,
      ldapFilter: `(&(|(objectCategory=person)(objectCategory=computer)(objectCategory=group))(|(name=${text}*)(sAMAccountName=${text}*)(displayName=${text}*)))`, costly: match === 'contains', freeText: text };
    const { l, rows } = open('search', { text, type, match, dn: baseDn, global: true, plan, matches, limit });
    return result(l, rows);
  }

  async function browse(args) {
    const v = readObject(args, ['dn', 'subtree', 'type', 'limit']);
    const dn = requireDistinguishedName(getString(v, 'dn'), 'dn');
    const type = readType(v); const limit = readLimit(v); const subtree = v.subtree === true;
    if (dn !== ROOT && !OUS.some((o) => o.toLowerCase() === dn.toLowerCase())) throw fail('ou.unknown', `OU introuvable${COLON}rien n’a été lu.`);
    await sleep(140);
    const matches = objects.filter((o) => ofType(o, type) && (dn === ROOT || under(o.dn, dn, subtree)));
    const { l, rows } = open('browse', { type, dn, subtree, matches, limit });
    return result(l, rows);
  }

  const VIEWS = [
    { id: 'lockedusers', name: 'Comptes avec un verrouillage enregistré', category: 'Comptes', type: 'users', test: (o) => o.flags.locked },
    { id: 'disabled', name: 'Comptes désactivés', category: 'Comptes', type: 'users', test: (o) => o.flags.disabled },
    { id: 'inactiveusers', name: 'Comptes actifs sans connexion depuis 90 jours', category: 'Comptes', type: 'users', test: (o) => o.flags.inactive },
    { id: 'stalecomputers', name: 'Postes sans connexion depuis 90 jours', category: 'Postes', type: 'computers', test: (o) => o.flags.inactive },
  ];
  const LOCAL = [{ id: 'local.lowdisk', name: 'Disque C presque plein (moins de 10 % libre)', category: 'Matériel' }, { id: 'local.noreply', name: 'Sans réponse au dernier relevé de présence', category: 'Présence' }];

  async function view(args) {
    const v = readObject(args, ['id', 'dn', 'subtree', 'wholeDomain', 'limit']);
    const def = VIEWS.find((x) => x.id === getString(v, 'id'));
    if (!def) throw fail('search.viewUnknown', `Vue inconnue${COLON}rien n’a été lu.`);
    const dnRaw = getOptionalString(v, 'dn');
    if (!v.wholeDomain && (!dnRaw || dnRaw === ROOT)) throw invalid(`${quote('dn')} est obligatoire sans ${quote('wholeDomain')}${COLON}tout le domaine est un choix explicite.`);
    const dn = v.wholeDomain ? ROOT : requireDistinguishedName(dnRaw, 'dn');
    await sleep(160);
    const whole = dn === ROOT;
    const matches = objects.filter((o) => ofType(o, def.type) && def.test(o) && (whole || under(o.dn, dn, v.subtree === true)));
    const info = { id: def.id, name: def.name, note: 'Vue prête à l’emploi en lecture seule.', wholeDomain: whole, surveyAllowed: !whole, reason: whole ? `Vue sur tout le domaine${COLON}aucun relevé des postes (ping, détection, analyse) n’est proposé sur cette liste.` : '' };
    const { l, rows } = open('view', { type: def.type, dn, subtree: true, view: info, matches, limit: readLimit(v) });
    return result(l, rows);
  }

  async function localQuery(args) {
    const v = readObject(args, ['id', 'dn', 'subtree', 'verdict', 'limit']);
    const id = getString(v, 'id');
    const def = LOCAL.find((x) => x.id === id);
    if (!def) throw fail('search.viewUnknown', `Vue inconnue${COLON}rien n’a été lu.`);
    const dn = requireDistinguishedName(getString(v, 'dn'), 'dn');
    const verdict = getOptionalString(v, 'verdict') ?? 'match';
    await sleep(120);
    const pcs = objects.filter((o) => o.kind === 'computer' && !o.flags.disabled && (dn === ROOT || under(o.dn, dn, v.subtree === true)));
    const judged = pcs.map((o, n) => {
      const kind = def.id === 'local.noreply' ? (o.presence?.state === 'noReply' ? 'match' : o.presence?.state === 'unknown' ? 'unknown' : 'noMatch') : n % 9 === 0 ? 'match' : n % 7 === 0 ? 'unknown' : 'noMatch';
      const label = { match: 'Correspond', unknown: 'Inconnu', noMatch: 'Ne correspond pas' }[kind];
      return { kind, row: { ...o, verdict: `${label} · ${kind === 'unknown' ? 'Aucun relevé récent' : def.id === 'local.lowdisk' ? `${(kind === 'match' ? 6 : 34) + (n % 4)} % libre` : o.presence?.label ?? ''}` } };
    });
    const order = { match: 0, unknown: 1, noMatch: 2 };
    const shown = judged.filter((j) => verdict === 'all' || j.kind === verdict).sort((a, b) => order[a.kind] - order[b.kind]).map((j) => j.row);
    const totals = { match: judged.filter((j) => j.kind === 'match').length, unknown: judged.filter((j) => j.kind === 'unknown').length, noMatch: judged.filter((j) => j.kind === 'noMatch').length,
      shown: { match: 'Correspondants', unknown: 'Inconnus', noMatch: 'Non correspondants' }[verdict] ?? 'Tous les postes', completeAt: null, coverage: `Aucune lecture complète du périmètre${COLON}${count(judged.filter((j) => j.kind === 'unknown').length, 'poste', 'postes')} sans relevé de moins de 30 jours.` };
    const whole = dn === ROOT;
    const info = { id, name: def.name, note: 'Requête locale sur les relevés enregistrés : aucune lecture de l’annuaire ni des postes.', wholeDomain: whole, surveyAllowed: !whole, reason: whole ? `Requête sur tout le domaine${COLON}aucun relevé des postes n’est proposé sur cette liste.` : '' };
    const { l, rows } = open('localQuery', { type: 'computers', dn, subtree: v.subtree === true, view: info, matches: shown, limit: readLimit(v) });
    l.verdicts = totals;
    return result(l, rows);
  }

  async function more(args) {
    const v = readObject(args, ['listId', 'limit']);
    const l = requireList(getString(v, 'listId'));
    if (l.busy) throw fail('search.listBusy', `Lecture en cours${COLON}attendez la fin du chargement.`);
    const target = readLimit(v);
    if (target <= l.loaded) throw fail('search.listComplete', `Taille demandée hors des bornes${COLON}de ${int(l.loaded + 1)} à ${int(MAX_LIMIT)} lignes.`);
    l.busy = true;
    try {
      await sleep(140);
      const rows = l.matches.slice(l.loaded, target);
      l.loaded += rows.length; l.limit = target;
      rows.forEach((r) => l.known.add(r.id));
      return result(l, rows, true);
    } finally { l.busy = false; }
  }

  // ---------- Survey and checks ----------

  async function surveyPlan(args) {
    const v = readObject(args, ['mode', 'listId', 'ids', 'scope', 'resume']);
    const mode = getString(v, 'mode');
    if (!['ping', 'console', 'analyse', 'complete', 'unaddressed'].includes(mode)) throw invalid(`${quote('mode')} vaut ping, console, analyse, complete ou unaddressed.`);
    const l = requireList(getString(v, 'listId'));
    const ids = v.resume ? (resume?.ids ?? []) : (Array.isArray(v.ids) ? v.ids : []);
    if (ids.some((id) => !l.known.has(id))) throw fail('search.surveyRefused', `Des lignes demandées n’appartiennent pas à la liste affichée${COLON}rien n’est relevé.`);
    const rows = ids.map((id) => byId.get(id)).filter(Boolean);
    const targets = rows.filter((r) => r.kind === 'computer' && !r.flags.disabled).map((r) => ({ id: r.id, name: r.name, dn: r.dn, address: r.address?.ip ?? null }));
    const excluded = rows.filter((r) => r.kind !== 'computer' || r.flags.disabled).map((r) => ({ name: r.name, reason: r.kind !== 'computer' ? 'pas un poste' : 'compte ordinateur désactivé' }));
    const covers = ids.length >= l.known.size;
    const admission = l.view && !l.view.surveyAllowed ? { allowed: false, code: 'wholeDomainView', reason: l.view.reason, maximum: 500 }
      : !targets.length ? { allowed: false, code: 'empty', reason: 'Aucun poste dans les résultats affichés.', maximum: 500 }
        : targets.length > 500 ? { allowed: false, code: 'ceiling', reason: `${count(targets.length, 'poste affiché', 'postes affichés')}${COLON}plafond 500. Filtrez la liste.`, maximum: 500 }
          : l.scope.wholeDomain && l.scope.mode !== 'global' && covers ? { allowed: false, code: 'domainRoot', reason: `Liste de la racine du domaine sans autre filtre${COLON}aucun relevé de tout le domaine. Choisissez une OU ou filtrez la liste.`, maximum: 500 }
            : { allowed: true, code: 'allowed', reason: '', maximum: 500 };
    const label = { ping: 'Qui répond ?', console: 'Qui est connecté ?', analyse: 'Matériel et widgets', complete: 'Relevé complet', unaddressed: 'Postes sans adresse' }[mode];
    const planId = hex();
    plans.set(planId, { mode, listId: l.id, targets, admission, expires: Date.now() + PLAN_LIFETIME, typed: targets.length > 100 });
    return {
      planId, mode, modeLabel: label, admission, title: `${v.resume ? 'Reprendre le relevé' : 'Vérifier la liste'}${COLON}${label}`, target: 'les résultats affichés',
      lines: [`${count(targets.length, 'poste', 'postes')} ${targets.length > 1 ? 'affichés' : 'affiché'}`, `Ce qui sera lu${COLON}présence${mode === 'ping' ? '' : ' · utilisateur connecté'}, en lecture seule.`, `Durée estimée${COLON}moins d’une minute ; arrêt possible à tout moment.`],
      details: [`Profil de collecte « Standard »${COLON}chaque poste reçoit un nouvel écho.`, `Budget${COLON}échos par lots de 32, 15${NBSP}s au plus par poste ; une seule tentative, rien n’est rejoué.`, `Fenêtre de collecte${COLON}permise à tout moment (profil « Standard »).`],
      outsideWindow: false, confirmText: `${mode === 'ping' ? 'Pinger' : 'Vérifier'} ${count(targets.length, 'poste', 'postes')}`, estimateSeconds: 10, estimate: 'moins d’une minute', targets, excluded,
      typedCountRequired: targets.length > 100, resume: !!v.resume, expiresAt: iso(Date.now() + PLAN_LIFETIME),
    };
  }

  async function surveyRun(args) {
    const v = readObject(args, ['planId', 'typedCount']);
    const plan = plans.get(getString(v, 'planId'));
    plans.delete(getString(v, 'planId'));
    if (!plan || plan.expires < Date.now()) throw fail('search.surveyPlanUnknown', `Plan de relevé inconnu, déjà utilisé ou expiré${COLON}rien n’est lu. Relancez la confirmation.`);
    if (!plan.admission.allowed) throw fail('search.surveyRefused', plan.admission.reason);
    if (plan.typed && v.typedCount !== plan.targets.length) throw fail('search.surveyTypedCount', `Nombre saisi différent du nombre de postes (${int(plan.targets.length)})${COLON}rien n’est lu.`);
    resume = null;
    await sleep(600);
    let online = 0; let noReply = 0; let errors = 0;
    const rows = plan.targets.map((t) => {
      const o = byId.get(t.id);
      const state = rnd() < 0.8 ? 'online' : rnd() < 0.8 ? 'noReply' : 'error';
      if (state === 'online') online++; else if (state === 'noReply') noReply++; else errors++;
      o.presence = presence(state, now());
      return o;
    });
    const total = plan.targets.length;
    const text = `${int(total)}/${int(total)} · ${int(online)} en ligne · ${int(noReply)} sans réponse · ${count(errors, 'erreur', 'erreurs')}`;
    const status = { validated: total, total, elapsedSeconds: 1, slow: 0, suspended: 0, retries: 0, cimReachable: 0, cimAvoided: 0, remaining: 0,
      lines: [`Résultats validés${COLON}${int(total)} sur ${int(total)} · attente réelle 1${NBSP}s.`, `Sources ralenties${COLON}aucune.`, `Sources suspendues${COLON}aucune.`, `Nouveaux essais${COLON}aucun (une seule tentative par poste, rien n’est rejoué).`, `Requêtes CIM évitées${COLON}sans objet pour ce relevé.`, `Plan de reprise${COLON}aucun, tous les postes visés ont été lus.`] };
    return { runId: hex(), mode: plan.mode, done: total, total, online, noReply, errors, stopped: false, text, detail: `Relevé${COLON}${text}.`, rows, startedAt: iso(Date.now() - 1000), endedAt: iso(Date.now()), status, resume: null };
  }

  const surveyState = () => ({ resume: resume ? { listId: resume.listId, mode: resume.mode, modeLabel: 'Qui répond ?', remaining: resume.ids.length, total: resume.total, stoppedAt: iso(Date.now()), text: `Relevé interrompu${COLON}${count(resume.ids.length, 'poste restant', 'postes restants')}.` } : null, checksSuspended: !!suspended, suspendedReason: suspended ?? '' });

  async function recheck(args) {
    const v = readObject(args, ['id', 'mode', 'listId', 'onClick']);
    const o = byId.get(getString(v, 'id'));
    if (!o || o.kind !== 'computer' || o.flags.disabled) throw fail('search.notWorkstation', `Cette ligne n’est pas un poste actif${COLON}aucune sonde n’est envoyée.`);
    if (v.onClick && suspended) throw fail('search.checksSuspended', suspended);
    const l = getOptionalString(v, 'listId') ? requireList(getString(v, 'listId')) : null;
    if (l?.view && !l.view.surveyAllowed) throw fail('search.surveyRefused', l.view.reason);
    await sleep(300);
    o.presence = presence(rnd() < 0.85 ? 'online' : 'noReply', now());
    return o;
  }

  async function netdiag(args) {
    const v = readObject(args, ['listId', 'ids']);
    const l = requireList(getString(v, 'listId'));
    if (l.view && !l.view.surveyAllowed) throw fail('search.surveyRefused', l.view.reason);
    const rows = (v.ids ?? []).map((id) => byId.get(id)).filter((o) => o?.kind === 'computer' && !o.flags.disabled).slice(0, 50);
    if (!rows.length) throw fail('search.surveyRefused', `Aucun poste actif dans la sélection${COLON}rien n’est envoyé.`);
    await sleep(500);
    const lines = rows.map((o) => ({ id: o.id, name: o.name, address: o.address?.ip ?? null, ping: presence('online', now()), ports: [[445, 'SMB'], [135, 'RPC'], [5985, 'WinRM'], [5986, 'WinRM HTTPS']].map(([port, service], n) => ({ port, service, state: n < 3 ? 'open' : 'closed', label: n < 3 ? 'Ouvert' : 'Fermé', tone: n < 3 ? 'ok' : 'off' })), summary: 'Joignable · ouverts : SMB, RPC, WinRM', tone: 'ok' }));
    const summary = `${count(lines.length, 'poste diagnostiqué', 'postes diagnostiqués')} · aucun compte envoyé, rien modifié.`;
    return { lines, excluded: [], summary, report: lines.map((x) => `${x.name}\t${x.address ?? ''}`).join('\r\n'), at: iso(now()) };
  }

  // ---------- Memory ----------

  const memory = { recents: [], favorites: [], workspaces: [], queryFavorites: [], undo: null, maxFavorites: 50, maxWorkspaces: 100, persistent: false, warning: null, imported: 0 };
  const mem = () => JSON.parse(JSON.stringify(memory));

  return {
    'search.run': run,
    'search.browse': browse,
    'search.view': view,
    'search.localQuery': localQuery,
    'search.more': more,
    'search.containers': async () => { await sleep(60); return [{ dn: `CN=Users,${ROOT}`, name: 'Users', system: false, objects: -1 }, { dn: `CN=Computers,${ROOT}`, name: 'Computers', system: false, objects: -1 }, { dn: `CN=System,${ROOT}`, name: 'System', system: true, objects: -1 }]; },
    'search.suggest': async (args) => {
      const v = readObject(args, ['text', 'type']);
      const t = fold(getString(v, 'text')); const type = readType(v);
      return objects.filter((o) => ofType(o, type) && (fold(o.name).startsWith(t) || fold(o.login ?? '').startsWith(t))).slice(0, 8).map((o) => ({ source: 'local', text: o.name, label: o.name, detail: `Base locale · ${o.kindLabel}${o.login && o.login !== o.name ? ` · ${o.login}` : ''}`, kind: o.kind, dn: o.dn }));
    },
    'search.preview': async (args) => {
      const o = byId.get(getString(readObject(args, ['id']), 'id'));
      if (!o) throw fail('search.objectUnknown', `Objet inconnu de la base locale${COLON}rien n’est affiché.`);
      await sleep(120);
      return { row: o, sections: [{ id: 'attributes', title: 'Attributs de l’annuaire', items: [{ label: 'Attribut AD · whenChanged', value: o.changed ?? '—', date: 'Lu il y a 12 min', tone: null, mono: false }] }], source: 'Annuaire fictif (aperçu)', attributes: 1, truncated: false };
    },
    'search.compare': async (args) => {
      const ids = readObject(args, ['ids']).ids ?? [];
      const rows = ids.map((id) => byId.get(id)).filter(Boolean);
      if (rows.length < 2 || rows.length > 8) throw invalid(`${quote('ids')} doit compter de 2 à 8 identifiants.`);
      const lines = [['Identité', 'Nom', (r) => r.name], ['Identité', 'Compte', (r) => r.login ?? '—'], ['Système', 'Système', (r) => r.os ?? '—']].map(([family, property, get]) => {
        const values = rows.map((r) => ({ text: get(r), date: 'Lu il y a 12 min', known: true }));
        const same = new Set(values.map((x) => x.text)).size === 1;
        return { family, property, comparison: same ? 'Identiques' : 'Différentes', difference: same ? 'same' : 'different', values };
      });
      return { kind: rows[0].kind, objects: rows, lines, different: lines.filter((x) => x.difference === 'different').length, same: lines.filter((x) => x.difference === 'same').length, unknown: 0, summary: `${count(rows.length, 'objet', 'objets')} comparés` };
    },
    'search.catalog': async () => ({
      entries: [...VIEWS.map((x) => ({ id: `ad:${x.id}`, name: x.name, category: x.category, source: 'Annuaire fictif', typeLabel: typeLabel(x.type), description: 'Vue prête à l’emploi en lecture seule.', cost: 'Filtre indexé : coût modéré.', ldapFilter: '(objectCategory=person)', favorite: memory.queryFavorites.includes(`ad:${x.id}`), local: false })),
        ...LOCAL.map((x) => ({ id: `local:${x.id.slice(6)}`, name: x.name, category: x.category, source: 'Base locale et relevés datés', typeLabel: 'Postes', description: 'Calcul local sur les relevés enregistrés.', cost: 'Aucune lecture de l’annuaire ni des postes.', ldapFilter: '', favorite: memory.queryFavorites.includes(`local:${x.id.slice(6)}`), local: true }))],
      favorites: memory.queryFavorites.length, note: `Choisir une requête ne lance rien${COLON}elle part sur votre clic, sur l’OU choisie dans l’arbre.`,
    }),
    'search.dns.reverse': async (args) => { const ip = getString(readObject(args, ['ip']), 'ip'); await sleep(300); return { ip, name: null, message: `Aucun nom trouvé dans le DNS pour ${ip}${COLON}une absence de réponse ne prouve pas qu’aucun poste n’utilise cette adresse.` }; },
    'search.revalidate': async (args) => { const ids = readObject(args, ['ids']).ids ?? []; await sleep(160); const rows = ids.map((id) => byId.get(id)).filter(Boolean); return { rows, missing: [], checkedAt: iso(now()), summary: `Liste vérifiée${COLON}${count(rows.length, 'objet relu', 'objets relus')}` }; },
    'search.reconcile': async (args) => {
      const l = requireList(getString(readObject(args, ['listId']), 'listId'));
      await sleep(200);
      const rows = l.matches.slice(0, l.loaded);
      return { listId: l.id, rows, added: [], moved: [], missing: [], loaded: l.loaded, checkpoint: `Point de reprise${COLON}Annuaire fictif (aperçu), lecture n°${NBSP}1`, readAt: iso(now()), summary: `Liste revérifiée${COLON}${count(rows.length, 'objet relu', 'objets relus')}.` };
    },
    'search.measures': async (args) => { const v = readObject(args, ['listId', 'offset']); const l = requireList(getString(v, 'listId')); const off = v.offset ?? 0; const ids = [...l.known]; const rows = ids.slice(off, off + 250).map((id) => byId.get(id)); return { rows, offset: off, next: off + 250 < ids.length ? off + 250 : null, total: ids.length, readAt: iso(now()) }; },
    'search.preload': async (args) => { const o = byId.get(getString(readObject(args, ['id']), 'id')); if (!o) throw fail('search.objectUnknown', 'Objet introuvable à la relecture.'); await sleep(140); return { row: o, sourceLabel: 'Annuaire fictif (aperçu)', readAt: iso(now()) }; },
    'search.survey.plan': surveyPlan,
    'search.survey.run': surveyRun,
    'search.survey.stop': async () => ({ stopped: false, message: 'Aucun relevé en cours sous cet identifiant.' }),
    'search.survey.state': async () => surveyState(),
    'search.survey.forget': async () => { resume = null; return surveyState(); },
    'search.checks.resume': async () => { suspended = null; return surveyState(); },
    'search.recheck': recheck,
    'search.netdiag': netdiag,
    'search.memory': async () => mem(),
    'search.recent.add': async (args) => {
      const v = readObject(args, ['kind', 'text', 'type', 'dn']);
      const kind = getString(v, 'kind');
      if (!['search', 'object'].includes(kind)) throw invalid(`${quote('kind')} vaut search ou object.`);
      const text = getString(v, 'text');
      memory.recents = [{ kind, text, type: getOptionalString(v, 'type'), dn: getOptionalString(v, 'dn'), at: iso(Date.now()) }, ...memory.recents.filter((r) => fold(r.text) !== fold(text))].slice(0, 20);
      return mem();
    },
    'search.recent.clear': async () => { memory.recents = []; return mem(); },
    'search.favorite.pin': async (args) => {
      const v = readObject(args, ['dn', 'name', 'subtree', 'type', 'term']);
      const dn = requireDistinguishedName(getString(v, 'dn'), 'dn');
      if (dn === ROOT || !OUS.includes(dn)) throw fail('search.favoriteRefused', `Seule une OU existante s’épingle${COLON}rien n’est changé.`);
      memory.favorites = [...memory.favorites.filter((f) => f.dn !== dn), { dn, name: leaf(dn), label: getOptionalString(v, 'name') ?? leaf(dn), path: pathOf(dn), subtree: v.subtree !== false, type: getOptionalString(v, 'type') ?? 'all', term: getOptionalString(v, 'term') }];
      return mem();
    },
    'search.favorite.unpin': async (args) => { const dn = getString(readObject(args, ['dn']), 'dn'); memory.favorites = memory.favorites.filter((f) => f.dn !== dn); return mem(); },
    'search.favorite.move': async (args) => { const v = readObject(args, ['dn', 'index']); const at = memory.favorites.findIndex((f) => f.dn === v.dn); if (at >= 0) { const [f] = memory.favorites.splice(at, 1); memory.favorites.splice(Math.max(0, Math.min(memory.favorites.length, v.index)), 0, f); } return mem(); },
    'search.workspace.save': async (args) => {
      const v = readObject(args, ['name', 'dn', 'subtree', 'type', 'presence', 'filter', 'limit', 'columnSet', 'layout']);
      const name = getString(v, 'name');
      if (memory.workspaces.some((w) => fold(w.name) === fold(name))) throw fail('search.workspaceRefused', `Une vue porte déjà ce nom${COLON}choisissez-en un autre.`);
      memory.workspaces.push({ id: hex(), name, ouDn: v.dn, subtree: v.subtree, type: v.type ?? 'all', presence: v.presence ?? 'all', filter: v.filter ?? '', limit: v.limit ?? 100, columnSet: v.columnSet ?? 'mixed', layout: v.layout ?? null, label: pathOf(v.dn), savedAt: iso(Date.now()) });
      return mem();
    },
    'search.workspace.remove': async (args) => { const id = getString(readObject(args, ['id']), 'id'); const w = memory.workspaces.find((x) => x.id === id); memory.workspaces = memory.workspaces.filter((x) => x.id !== id); memory.undo = w ?? null; return mem(); },
    'search.workspace.undo': async () => { if (memory.undo) { memory.workspaces.push(memory.undo); memory.undo = null; } return mem(); },
    'search.query.favorite': async (args) => { const v = readObject(args, ['id', 'favorite']); const id = getString(v, 'id'); if (!/^(ad|local):[a-z0-9]+$/.test(id)) throw fail('search.queryUnknown', `Requête inconnue${COLON}rien n’est changé.`); memory.queryFavorites = v.favorite ? [...new Set([...memory.queryFavorites, id])] : memory.queryFavorites.filter((x) => x !== id); return mem(); },
  };
}
