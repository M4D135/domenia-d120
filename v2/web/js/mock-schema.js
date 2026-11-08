// Browser preview of the « Schéma de l’annuaire » and « Comptes machine » screens (docs/ops/schema.md): same operations,
// result shapes and error codes as the engine (SchemaOperations, MachineOperations), on a reduced fictitious schema (the
// common classes and about fifty well-known attributes, not the 244 of the simulation) and a few workstations of
// example.local. The filter analysis is a compact port of LdapFilter (parse, index use, advice, tree, objectCategory
// suggestion). Everything lives in the memory of the page: nothing leaves it, nothing is kept after a reload. The helpers of
// mock.js are handed in, so validation messages stay word for word those of the engine.

const ROOT_DN = 'DC=example,DC=local';
const SERVER = 'DC01.example.local';
const SESSION_ACCOUNT = 'EXAMPLE\\j.martin';
const LIST_MAX_TEXT = 128;
const LIST_MAX_LIMIT = 5000;
const WATCH_MS = 25_000;

// Syntax families (SchemaSyntaxKind) and their labels.
const FAMILY = {
  text: 'Texte', dn: 'Référence (DN)', int: 'Entier', largeInt: 'Grand entier', time: 'Date et heure', bool: 'Booléen', binary: 'Octets', sid: 'SID', other: 'Autre',
};
const SYNTAX = {
  text: ['2.5.5.12', 'Texte Unicode', 64], dn: ['2.5.5.1', 'Nom distinctif (DN)', 127], int: ['2.5.5.9', 'Entier (32 bits)', 2],
  largeInt: ['2.5.5.16', 'Grand entier (compteur ou date FILETIME)', 65], time: ['2.5.5.11', 'Date et heure (temps généralisé)', 24],
  bool: ['2.5.5.8', 'Booléen', 1], binary: ['2.5.5.10', 'Chaîne d’octets', 4], sid: ['2.5.5.17', 'Identifiant de sécurité (SID)', 4],
  other: ['2.5.5.2', 'Identifiant d’objet (OID)', 6],
};

// [name, family, single, flags, description]; flags: i indexed, t substring index, g global catalog, c confidential,
// k constructed, d defunct, a ANR.
const ATTRIBUTES = [
  ['accountExpires', 'largeInt', 1, 'g', 'Date d’expiration du compte (FILETIME).'],
  ['canonicalName', 'text', 1, 'k', 'Chemin lisible de l’objet, calculé à la lecture.'],
  ['cn', 'text', 1, 'ig', 'Nom commun de l’objet.'],
  ['createTimeStamp', 'time', 1, 'k', 'Date de création, calculée à partir de whenCreated.'],
  ['department', 'text', 1, '', 'Service de la personne.'],
  ['description', 'text', 0, '', 'Description libre de l’objet.'],
  ['directReports', 'dn', 0, '', 'Collaborateurs directs (lien retour de manager).'],
  ['displayName', 'text', 1, 'iga', 'Nom affiché dans les carnets d’adresses.'],
  ['dNSHostName', 'text', 1, 'ig', 'Nom DNS complet de l’ordinateur.'],
  ['exampleLegacyCode', 'text', 1, 'd', 'Ancien code d’inventaire de l’entreprise (désactivé).'],
  ['gPLink', 'text', 1, '', 'Stratégies de groupe liées à l’OU.'],
  ['givenName', 'text', 1, 'iga', 'Prénom.'],
  ['info', 'text', 1, '', 'Notes libres.'],
  ['lastLogonTimestamp', 'largeInt', 1, 'i', 'Dernière ouverture de session répliquée (FILETIME, à 14 jours près).'],
  ['lockoutTime', 'largeInt', 1, 'g', 'Date de verrouillage du compte (FILETIME).'],
  ['mail', 'text', 1, 'iga', 'Adresse de messagerie.'],
  ['manager', 'dn', 1, 'g', 'Responsable hiérarchique (lien direct).'],
  ['member', 'dn', 0, 'g', 'Membres du groupe (lien direct).'],
  ['memberOf', 'dn', 0, 'g', 'Groupes dont l’objet est membre (lien retour, calculé par le contrôleur).'],
  ['ms-Mcs-AdmPwd', 'text', 1, 'c', 'Mot de passe LAPS hérité (confidentiel, jamais affiché par Domenia).'],
  ['ms-Mcs-AdmPwdExpirationTime', 'largeInt', 1, '', 'Date d’expiration du mot de passe LAPS hérité.'],
  ['msDS-User-Account-Control-Computed', 'int', 1, 'k', 'État calculé du compte (verrouillage, mot de passe expiré).'],
  ['msDS-UserPasswordExpiryTimeComputed', 'largeInt', 1, 'k', 'Date d’expiration calculée du mot de passe.'],
  ['msFVE-RecoveryPassword', 'text', 1, 'c', 'Mot de passe de récupération BitLocker (confidentiel).'],
  ['msLAPS-PasswordExpirationTime', 'largeInt', 1, 'i', 'Date d’expiration du mot de passe Windows LAPS.'],
  ['name', 'text', 1, 'ig', 'Nom relatif de l’objet (RDN).'],
  ['objectCategory', 'dn', 1, 'ig', 'Catégorie de l’objet, indexée.'],
  ['objectClass', 'other', 0, 'ig', 'Classes de l’objet, de la plus générale à la plus précise.'],
  ['objectGUID', 'binary', 1, 'ig', 'Identifiant unique de l’objet.'],
  ['objectSid', 'sid', 1, 'ig', 'Identifiant de sécurité du compte.'],
  ['operatingSystem', 'text', 1, 'g', 'Système d’exploitation de l’ordinateur.'],
  ['operatingSystemVersion', 'text', 1, 'g', 'Version du système d’exploitation.'],
  ['ou', 'text', 0, 'ig', 'Nom de l’unité d’organisation.'],
  ['primaryGroupID', 'int', 1, 'ig', 'Groupe principal (RID).'],
  ['pwdLastSet', 'largeInt', 1, 'g', 'Dernier changement du mot de passe (FILETIME, 0 : à changer).'],
  ['sAMAccountName', 'text', 1, 'iga', 'Nom de compte (avant Windows 2000).'],
  ['servicePrincipalName', 'text', 0, 'ig', 'Noms de principal de service (Kerberos).'],
  ['sn', 'text', 1, 'iga', 'Nom de famille.'],
  ['telephoneNumber', 'text', 1, 'g', 'Numéro de téléphone.'],
  ['title', 'text', 1, '', 'Fonction.'],
  ['tokenGroups', 'sid', 0, 'k', 'Groupes de sécurité, imbrications comprises, calculés à la lecture.'],
  ['userAccountControl', 'int', 1, 'ig', 'Indicateurs du compte (désactivé, mot de passe sans expiration…).'],
  ['userPrincipalName', 'text', 1, 'ig', 'Nom d’ouverture de session (UPN).'],
  ['whenChanged', 'time', 1, 'g', 'Dernière modification de l’objet sur ce contrôleur.'],
  ['whenCreated', 'time', 1, 'g', 'Date de création de l’objet.'],
].map(([name, kind, single, flags, description]) => ({
  name, kind, singleValued: !!single, indexed: flags.includes('i'), tuple: flags.includes('t'), gc: flags.includes('g'), confidential: flags.includes('c'),
  constructed: flags.includes('k'), defunct: flags.includes('d'), anr: flags.includes('a'), description,
}));

// [name, category, subClassOf, auxiliary, must, may, description]; category: 1 structural, 2 abstract, 3 auxiliary, 0 class 88.
const CLASSES = [
  ['top', 2, 'top', [], ['objectClass', 'objectCategory'], ['cn', 'description', 'whenCreated', 'whenChanged', 'name', 'objectGUID', 'canonicalName', 'createTimeStamp', 'memberOf', 'info'], 'Classe racine : tout objet en hérite.'],
  ['person', 0, 'top', [], ['cn'], ['sn', 'telephoneNumber'], 'Personne (X.500, 1988) : nom commun et téléphone.'],
  ['organizationalPerson', 0, 'person', [], [], ['title', 'department', 'manager', 'directReports', 'givenName', 'displayName'], 'Personne d’une organisation : fonction, service, responsable.'],
  ['user', 1, 'organizationalPerson', ['securityPrincipal', 'mailRecipient'], [], ['userPrincipalName', 'userAccountControl', 'pwdLastSet', 'lastLogonTimestamp', 'lockoutTime', 'accountExpires', 'primaryGroupID', 'msDS-User-Account-Control-Computed', 'msDS-UserPasswordExpiryTimeComputed'], 'Compte d’utilisateur du domaine.'],
  ['inetOrgPerson', 1, 'user', [], [], [], 'Personne au format inetOrgPerson (RFC 2798).'],
  ['computer', 1, 'user', [], [], ['dNSHostName', 'operatingSystem', 'operatingSystemVersion', 'servicePrincipalName', 'ms-Mcs-AdmPwd', 'ms-Mcs-AdmPwdExpirationTime', 'msLAPS-PasswordExpirationTime'], 'Compte d’ordinateur : poste, serveur ou contrôleur.'],
  ['msDS-ManagedServiceAccount', 1, 'computer', [], [], [], 'Compte de service géré, propre à un serveur.'],
  ['msDS-GroupManagedServiceAccount', 1, 'computer', [], [], [], 'Compte de service géré de groupe (gMSA).'],
  ['contact', 1, 'organizationalPerson', ['mailRecipient'], [], [], 'Contact de messagerie, sans compte ni mot de passe.'],
  ['group', 1, 'top', ['securityPrincipal', 'mailRecipient'], [], ['member'], 'Groupe de sécurité ou de distribution.'],
  ['organizationalUnit', 1, 'top', [], ['ou'], ['gPLink'], 'Unité d’organisation.'],
  ['container', 1, 'top', [], ['cn'], [], 'Conteneur.'],
  ['securityPrincipal', 3, 'top', [], ['objectSid', 'sAMAccountName'], ['tokenGroups'], 'Principal de sécurité : SID et nom de compte.'],
  ['mailRecipient', 3, 'top', [], ['cn'], ['mail', 'telephoneNumber'], 'Destinataire de messagerie.'],
  ['msFVE-RecoveryInformation', 1, 'top', [], ['msFVE-RecoveryPassword'], [], 'Informations de récupération BitLocker.'],
  ['exampleLegacyAsset', 1, 'top', [], [], ['exampleLegacyCode'], 'Ancien inventaire de l’entreprise (désactivé).'],
].map(([name, category, subClassOf, auxiliary, must, may, description]) => ({ name, category, subClassOf, auxiliary, must, may, description, defunct: name === 'exampleLegacyAsset' }));

const CATEGORY_LABEL = { 0: 'Classe 88', 1: 'Structurelle', 2: 'Abstraite', 3: 'Auxiliaire' };
const CATEGORY_ID = { 0: 'class88', 1: 'structural', 2: 'abstract', 3: 'auxiliary' };
const USUAL_CATEGORY = {
  user: 'person', inetorgperson: 'person', contact: 'person', person: 'person', organizationalperson: 'person', computer: 'computer', group: 'group',
  organizationalunit: 'organizationalUnit', 'msds-groupmanagedserviceaccount': 'msDS-GroupManagedServiceAccount', 'msds-managedserviceaccount': 'msDS-ManagedServiceAccount',
};

const WORKSTATIONS = [
  ...Array.from({ length: 12 }, (_, n) => ({ name: `PC-PAR-${String(n + 1).padStart(4, '0')}`, os: 'Windows 11 Entreprise', ou: 'Postes › Paris', server: false })),
  ...Array.from({ length: 4 }, (_, n) => ({ name: `SRV-FIC-0${n + 1}`, os: 'Windows Server 2022 Standard', ou: 'Serveurs', server: true })),
  { name: 'DC01', os: 'Windows Server 2022 Datacenter', ou: 'Domain Controllers', server: true },
];

/**
 * @param {object} h  Helpers of mock.js: readObject, getString, getOptionalString, requireNone, invalid, fail, quote, int, sleep, log, NBSP.
 * @returns {Object<string, (args: any) => any>}
 */
export function createSchemaOperations(h) {
  const { readObject, getString, getOptionalString, requireNone, invalid, fail, quote, int, sleep, log, NBSP } = h;
  const COLON = `${NBSP}: `;
  const count = (n, one, many) => `${int(n)} ${Math.abs(n) >= 2 ? many : one}`;
  const iso = (t) => new Date(t).toISOString().replace(/\.\d{3}Z$/, 'Z');
  const lower = (s) => String(s).toLowerCase();
  const attrs = new Map(ATTRIBUTES.map((a) => [lower(a.name), a]));
  const classes = new Map(CLASSES.map((c) => [lower(c.name), c]));
  let catalog = null; // { readAt }
  let reading = false;

  // ---------------------------------------------------------------- schema words
  const syntaxLabel = (a) => SYNTAX[a.kind][1];
  const indexText = (a) => (a.constructed ? 'Calculé, non filtrable' : a.indexed ? (a.tuple ? 'Indexé, sous-chaîne comprise' : 'Indexé') : 'Non indexé');
  const notRead = () => fail('schema.notRead', `Schéma non lu dans cette session${COLON}lisez-le d’abord (lecture explicite, rien n’est modifié).`);
  const requireCatalog = () => { if (!catalog) throw notRead(); };
  const nameArg = (value, argument) => {
    const v = String(value).trim();
    if (!/^[A-Za-z0-9-]{1,128}$/.test(v)) throw invalid(`${quote(argument)} doit être un nom LDAP (lettres, chiffres et tirets, 128 au plus).`);
    return v;
  };
  const pad = (n) => String(n).padStart(2, '0');
  const stamp = (t) => { const d = new Date(t); return `${pad(d.getDate())}/${pad(d.getMonth() + 1)}/${d.getFullYear()} à ${pad(d.getHours())}:${pad(d.getMinutes())}`; };

  function status() {
    const limits = { attributes: 8000, classes: 3000, seconds: 90 };
    if (!catalog) {
      return {
        read: false, server: null, readAt: null, classes: 0, attributes: 0, truncated: false, durationMs: null,
        text: 'Schéma non lu dans cette session. La lecture est explicite et ne modifie rien.', tone: 'off', lastError: null, simulated: true, limits, statistics: null,
      };
    }
    const families = new Map();
    for (const a of ATTRIBUTES) families.set(a.kind, (families.get(a.kind) ?? 0) + 1);
    const cats = new Map();
    for (const c of CLASSES) cats.set(c.category, (cats.get(c.category) ?? 0) + 1);
    const indexed = ATTRIBUTES.filter((a) => a.indexed && !a.constructed).length;
    return {
      read: true, server: SERVER, readAt: iso(catalog.readAt), classes: CLASSES.length, attributes: ATTRIBUTES.length, truncated: false, durationMs: 2140,
      text: `Schéma lu le ${stamp(catalog.readAt)} sur ${SERVER}${COLON}${count(CLASSES.length, 'classe', 'classes')}, ${count(ATTRIBUTES.length, 'attribut', 'attributs')}.`,
      tone: 'ok', lastError: null, simulated: true, limits,
      statistics: {
        indexed, tupleIndexed: ATTRIBUTES.filter((a) => a.tuple).length, inGlobalCatalog: ATTRIBUTES.filter((a) => a.gc).length,
        confidential: ATTRIBUTES.filter((a) => a.confidential).length, constructed: ATTRIBUTES.filter((a) => a.constructed).length, linked: 4,
        defunct: ATTRIBUTES.filter((a) => a.defunct).length + CLASSES.filter((c) => c.defunct).length, singleValued: ATTRIBUTES.filter((a) => a.singleValued).length,
        indexedPercent: Math.round((indexed * 1000) / ATTRIBUTES.length) / 10,
        syntaxes: [...families.entries()].sort((a, b) => b[1] - a[1]).map(([id, n]) => ({ id, label: FAMILY[id], count: n })),
        categories: [...cats.entries()].sort((a, b) => a[0] - b[0]).map(([k, n]) => ({ id: CATEGORY_ID[k], label: CATEGORY_LABEL[k], count: n })),
      },
    };
  }

  const classRow = (c) => ({
    name: c.name, kind: 'class', nature: c.defunct ? 'Obsolète' : CATEGORY_LABEL[c.category], detail: c.subClassOf && c.subClassOf !== c.name ? `Hérite de ${c.subClassOf}` : 'Classe racine',
    description: c.description, defunct: c.defunct, category: CATEGORY_LABEL[c.category], subClassOf: c.subClassOf, syntaxLabel: null, indexText: null,
    singleValued: null, indexed: null, inGlobalCatalog: null, confidential: null, constructed: null,
  });
  const attributeRow = (a) => ({
    name: a.name, kind: 'attribute', nature: a.defunct ? 'Obsolète' : syntaxLabel(a), detail: `${a.singleValued ? 'Une valeur' : 'Plusieurs valeurs'} · ${indexText(a)}`,
    description: a.description, defunct: a.defunct, category: null, subClassOf: null, syntaxLabel: syntaxLabel(a), indexText: indexText(a),
    singleValued: a.singleValued, indexed: a.indexed && !a.constructed, inGlobalCatalog: a.gc, confidential: a.confidential, constructed: a.constructed,
  });

  function list(args) {
    const values = readObject(args, ['kind', 'text', 'limit']);
    const kind = getString(values, 'kind');
    if (kind !== 'classes' && kind !== 'attributes') throw invalid(`${quote('kind')} vaut classes ou attributes.`);
    const text = (getOptionalString(values, 'text') ?? '');
    if (text.length > LIST_MAX_TEXT) throw invalid(`${quote('text')} doit faire au plus ${int(LIST_MAX_TEXT)} caractères.`);
    let limit = 500;
    if (Object.hasOwn(values, 'limit') && values.limit !== null) {
      if (!Number.isInteger(values.limit) || values.limit < 1 || values.limit > LIST_MAX_LIMIT) throw invalid(`${quote('limit')} doit être un entier de 1 à ${int(LIST_MAX_LIMIT)}.`);
      limit = values.limit;
    }
    requireCatalog();
    const term = lower(text.trim());
    const source = (kind === 'classes' ? CLASSES : ATTRIBUTES).slice().sort((a, b) => lower(a.name).localeCompare(lower(b.name)));
    const found = source.filter((e) => !term || lower(e.name).includes(term) || lower(e.description).includes(term));
    const rows = found.slice(0, limit).map(kind === 'classes' ? classRow : attributeRow);
    const attributes = kind === 'attributes';
    let summary = attributes ? count(found.length, 'attribut trouvé', 'attributs trouvés') : count(found.length, 'classe trouvée', 'classes trouvées');
    if (found.length > rows.length) summary += `, ${count(rows.length, attributes ? 'affiché' : 'affichée', attributes ? 'affichés' : 'affichées')}${COLON}précisez le filtre`;
    return { kind, text: text.trim(), total: found.length, shown: rows.length, limit, summary: `${summary}.`, rows };
  }

  const subclasses = (name) => CLASSES.filter((c) => lower(c.subClassOf) === lower(name) && lower(c.name) !== lower(name)).map((c) => c.name).sort();
  function exclusions(name) {
    const category = USUAL_CATEGORY[lower(name)];
    if (!category) return [];
    const out = [];
    const queue = [...subclasses(name)];
    const seen = new Set([lower(name)]);
    while (queue.length) {
      const n = queue.shift();
      if (seen.has(lower(n))) continue;
      seen.add(lower(n));
      queue.push(...subclasses(n));
      const c = classes.get(lower(n));
      if (!c || c.defunct || (c.category !== 1 && c.category !== 0)) continue;
      if (lower(USUAL_CATEGORY[lower(n)] ?? n) !== lower(category)) out.push(c.name);
    }
    return out.sort((a, b) => lower(a).localeCompare(lower(b)));
  }
  const classList = (names) => (names.length <= 3
    ? (names.length <= 1 ? names.join('') : `${names.slice(0, -1).join(', ')} et ${names[names.length - 1]}`)
    : `${names.slice(0, 3).join(', ')} et ${count(names.length - 3, 'autre', 'autres')}`);
  function recommended(name) {
    const category = USUAL_CATEGORY[lower(name)];
    if (!category) return `(objectClass=${name})`;
    return lower(category) === lower(name) ? `(objectCategory=${category})` : `(&(objectCategory=${category})(objectClass=${name}))`;
  }

  function classDetail(args) {
    const name = nameArg(getString(readObject(args, ['name']), 'name'), 'name');
    requireCatalog();
    const root = classes.get(lower(name));
    if (!root) throw fail('schema.unknownClass', `Classe inconnue du schéma lu${COLON}rien n’a été affiché.`);
    const chain = [];
    const lineage = [];
    const found = new Map();
    const queue = [[root.name, 'self', null, 0]];
    const seen = new Set();
    while (queue.length && seen.size < 256) {
      const [n, relation, via, depth] = queue.shift();
      if (seen.has(lower(n))) continue;
      seen.add(lower(n));
      const c = classes.get(lower(n));
      chain.push(n);
      lineage.push({ name: n, relation, via, categoryLabel: c ? CATEGORY_LABEL[c.category] : null, known: !!c, depth });
      if (!c) continue;
      for (const a of c.must) if (!found.has(lower(a)) || !found.get(lower(a)).required) found.set(lower(a), { name: a, required: true, origin: c.name, order: found.get(lower(a))?.order ?? found.size });
      for (const a of c.may) if (!found.has(lower(a))) found.set(lower(a), { name: a, required: false, origin: c.name, order: found.size });
      if (c.subClassOf && lower(c.subClassOf) !== lower(c.name)) queue.push([c.subClassOf, 'parent', c.name, depth + 1]);
      for (const x of c.auxiliary) queue.push([x, 'auxiliary', c.name, depth + 1]);
    }
    const rows = [...found.values()].map((e) => attrs.get(lower(e.name)) ? { e, a: attrs.get(lower(e.name)) } : null).filter(Boolean)
      .map(({ e, a }) => ({
        name: a.name, required: e.required, origin: e.origin, syntaxLabel: syntaxLabel(a), kind: a.kind, singleValued: a.singleValued,
        values: a.singleValued ? 'Une' : 'Plusieurs', indexText: indexText(a), indexed: a.indexed && !a.constructed, inGlobalCatalog: a.gc,
        confidential: a.confidential, constructed: a.constructed, defunct: a.defunct, description: a.description,
      }))
      .sort((x, y) => (y.required - x.required) || lower(x.name).localeCompare(lower(y.name)));
    const supers = [];
    for (let c = root, guard = 0; c && guard < 256; guard += 1) {
      supers.push(c.name);
      if (!c.subClassOf || lower(c.subClassOf) === lower(c.name)) break;
      c = classes.get(lower(c.subClassOf));
    }
    const required = rows.filter((r) => r.required).length;
    const excluded = exclusions(root.name);
    const rec = recommended(root.name);
    return {
      name: root.name, oid: null, description: root.description, category: CATEGORY_ID[root.category], categoryLabel: CATEGORY_LABEL[root.category], defunct: root.defunct,
      subClassOf: root.subClassOf, auxiliary: root.auxiliary, chain, superclasses: supers, lineage, subclasses: subclasses(root.name), attributes: rows,
      missing: [...found.values()].filter((e) => !attrs.has(lower(e.name))).map((e) => e.name), requiredCount: required, optionalCount: rows.length - required, walkTruncated: false,
      summary: `${root.name} · classe ${CATEGORY_LABEL[root.category].toLowerCase()} · chaîne${COLON}${chain.join(' → ')} · ${count(rows.length, 'attribut possible', 'attributs possibles')}.`,
      filter: `(objectClass=${root.name})`, recommendedFilter: rec,
      recommendedNote: rec.startsWith('(objectClass=') || !excluded.length ? null
        : `Le filtre recommandé écarte ${classList(excluded)}${excluded.length > 1 ? ', qui dérivent de ' : ', qui dérive de '}${root.name} avec une autre catégorie${COLON}gardez (objectClass=${root.name}) pour ${excluded.length > 1 ? 'les inclure' : 'l’inclure'}.`,
      filterAdvice: `Filtre sur cette classe${COLON}(objectClass=${root.name}). Les classes dérivées en font partie (un poste est aussi de classe user)${COLON}ajoutez un critère objectCategory pour cibler. Choisissez un attribut pour son détail.`,
    };
  }

  function example(a) {
    switch (a.kind) {
      case 'dn': return `(${a.name}=CN=valeur,${ROOT_DN})`;
      case 'int': return `(${a.name}=0)`;
      case 'largeInt': return `(${a.name}>=133000000000000000)`;
      case 'time': return `(${a.name}>=20260101000000.0Z)`;
      case 'bool': return `(${a.name}=TRUE)`;
      case 'text': return `(${a.name}=valeur*)`;
      default: return `(${a.name}=*)`;
    }
  }

  function attributeDetail(args) {
    const name = nameArg(getString(readObject(args, ['name']), 'name'), 'name');
    requireCatalog();
    const a = attrs.get(lower(name));
    if (!a) throw fail('schema.unknownAttribute', `Attribut inconnu du schéma lu${COLON}rien n’a été affiché.`);
    const notes = [];
    if (a.constructed) notes.push(`Attribut calculé${COLON}il se lit, il ne sert jamais de critère de filtre.`);
    else if (a.indexed) notes.push(`Attribut indexé${COLON}une égalité ou un début de valeur est ciblé.`);
    else notes.push(`Attribut non indexé${COLON}gardez-le à côté d’un critère indexé.`);
    if (a.defunct) notes.push(`Attribut obsolète${COLON}il ne sert pas dans une nouvelle requête.`);
    if (a.confidential) notes.push(`Attribut confidentiel${COLON}sans droit de lecture particulier, ce critère ne retient aucun objet.`);
    const flags = [
      ['indexed', 'Indexé', a.indexed, 'ok', 'Une égalité ou un début de valeur est servi par l’index.'],
      ['tuple', 'Sous-chaîne indexée', a.tuple, 'ok', 'Un joker en tête utilise aussi l’index.'],
      ['anr', 'Recherche ambiguë (ANR)', a.anr, 'info', 'Fait partie de la recherche ambiguë (anr=…).'],
      ['gc', 'Catalogue global', a.gc, 'info', 'Répliqué dans le catalogue global de la forêt.'],
      ['single', 'Une seule valeur', a.singleValued, 'info', 'L’attribut porte au plus une valeur.'],
      ['confidential', 'Confidentiel', a.confidential, 'warn', 'Lisible seulement avec un droit particulier.'],
      ['constructed', 'Calculé', a.constructed, 'warn', 'Calculé par le contrôleur à la lecture.'],
      ['defunct', 'Obsolète', a.defunct, 'alert', 'Désactivé dans le schéma.'],
    ].map(([id, label, on, tone, tip]) => ({ id, label, on: !!on, tone, tip }));
    const usedBy = CLASSES.filter((c) => c.must.concat(c.may).some((x) => lower(x) === lower(a.name)))
      .map((c) => ({ name: c.name, required: c.must.some((x) => lower(x) === lower(a.name)) })).sort((x, y) => lower(x.name).localeCompare(lower(y.name)));
    const insertable = !a.constructed && !a.defunct;
    return {
      name: a.name, oid: null, description: a.description, syntax: SYNTAX[a.kind][0], syntaxLabel: syntaxLabel(a), kind: a.kind, omSyntax: SYNTAX[a.kind][2],
      singleValued: a.singleValued, valuesLabel: a.singleValued ? 'Une valeur' : 'Plusieurs valeurs', indexText: indexText(a), inGlobalCatalog: a.gc,
      defunct: a.defunct, constructed: a.constructed, flags, linkId: null, linkLabel: null, linkPartner: null, rangeLower: null, rangeUpper: null, rangeLabel: null,
      summary: `${syntaxLabel(a)} · ${a.singleValued ? 'une valeur' : 'plusieurs valeurs'} · ${indexText(a).toLowerCase()}`,
      hint: { example: example(a), notes }, insertable,
      insertReason: insertable ? null : a.constructed ? `Attribut calculé${COLON}il ne se filtre pas.` : `Attribut obsolète${COLON}il ne sert pas dans une nouvelle requête.`,
      usedBy: usedBy.slice(0, 60), usedByTotal: usedBy.length,
    };
  }

  // ---------------------------------------------------------------- LDAP filter (compact port of LdapFilter)
  const KIND_LABEL = {
    and: 'Tous les critères (ET)', or: 'Au moins un critère (OU)', not: 'Négation (NON)', equality: 'Égalité', presence: 'Présence', substring: 'Sous-chaîne',
    greaterOrEqual: 'Supérieur ou égal', lessOrEqual: 'Inférieur ou égal', approx: 'Approché', extensible: 'Règle de correspondance',
  };
  const INDEX_LABEL = { yes: 'Index utilisé', no: 'Objet par objet', unknown: 'Index inconnu' };
  const LEVEL = { targeted: ['Ciblé', 'ok'], broad: ['Large', 'warn'], unknown: ['Inconnu', 'info'], invalid: ['Invalide', 'alert'] };

  function parse(input) {
    let text = String(input ?? '').trim();
    if (!text) return { valid: false, error: 'Filtre vide.', position: 0, text };
    if (!text.startsWith('(')) text = `(${text})`;
    let i = 0;
    let items = 0;
    const err = (message, position = i) => { throw Object.assign(new Error(message), { position }); };
    function node() {
      const start = i;
      if (text[i] !== '(') err(`Parenthèse ouvrante attendue, position ${i}.`);
      i += 1;
      items += 1;
      const c = text[i];
      if (c === '&' || c === '|' || c === '!') {
        i += 1;
        const children = [];
        while (text[i] === '(') children.push(node());
        if (text[i] !== ')') err(i >= text.length ? 'Parenthèse fermante manquante.' : `Parenthèse fermante attendue, position ${i}.`);
        if (!children.length) err('Un ET (&) ou un OU (|) sans filtre est vide.');
        if (c === '!' && children.length !== 1) err('Une négation (!) porte sur un seul filtre.');
        i += 1;
        return { kind: c === '&' ? 'and' : c === '|' ? 'or' : 'not', start, end: i, children, attribute: '', value: '', rule: '', leading: false };
      }
      const close = text.indexOf(')', i);
      if (close < 0) err('Parenthèse fermante manquante.');
      const item = text.slice(i, close);
      if (item.includes('(')) err(`Parenthèse non échappée dans une valeur${COLON}écrivez \\28 et \\29.`, i + item.indexOf('('));
      const m = /^([^=~<>:]*)((?::dn)?(?::[^=:]+)?)(~=|>=|<=|:=|=)(.*)$/s.exec(item);
      if (!m) err(`Assertion sans opérateur${COLON}${quote(item)}.`);
      const [, attribute, rule, op, value] = m;
      if (attribute && !/^[A-Za-z][A-Za-z0-9-]*$|^\d+(\.\d+)+$/.test(attribute)) err(`Nom d’attribut invalide${COLON}${quote(attribute)}.`);
      i = close + 1;
      let kind = op === '~=' ? 'approx' : op === '>=' ? 'greaterOrEqual' : op === '<=' ? 'lessOrEqual' : op === ':=' ? 'extensible' : 'equality';
      if (kind === 'equality' && value === '*') kind = 'presence';
      else if (kind === 'equality' && value.includes('*')) kind = 'substring';
      return { kind, start, end: i, children: [], attribute, value, rule: rule.replace(/^:/, ''), leading: kind === 'substring' && value.startsWith('*') };
    }
    try {
      const root = node();
      if (i < text.length) err(`Texte inattendu après le filtre, position ${i}.`);
      return { valid: true, root, text, items };
    } catch (e) {
      return { valid: false, error: e.message, position: e.position ?? i, text };
    }
  }

  function indexUse(n) {
    if (n.kind === 'not') return 'no';
    if (n.kind === 'extensible') return 'no';
    if (n.kind === 'and') { const u = n.children.map(indexUse); return u.includes('yes') ? 'yes' : u.includes('unknown') ? 'unknown' : 'no'; }
    if (n.kind === 'or') { const u = n.children.map(indexUse); return u.includes('no') ? 'no' : u.includes('unknown') ? 'unknown' : 'yes'; }
    if (lower(n.attribute) === 'anr' && (n.kind === 'equality' || n.kind === 'substring')) return 'yes';
    if (n.kind === 'presence' && ['objectclass', 'objectcategory'].includes(lower(n.attribute))) return 'no';
    const a = catalog ? attrs.get(lower(n.attribute)) : null;
    if (!a) return 'unknown';
    if (a.constructed || !a.indexed) return 'no';
    if (n.kind === 'substring' && n.leading) return a.tuple ? 'yes' : 'no';
    return 'yes';
  }
  function leaves(n, negated = false, out = []) {
    if (['and', 'or', 'not'].includes(n.kind)) n.children.forEach((c) => leaves(c, negated || n.kind === 'not', out));
    else out.push({ n, negated });
    return out;
  }
  function view(n, text, negated = false) {
    const use = indexUse(n);
    const leaf = !['and', 'or', 'not'].includes(n.kind);
    return {
      kind: n.kind, label: KIND_LABEL[n.kind], text: text.slice(n.start, n.end), attribute: leaf ? n.attribute : null, value: leaf ? n.value : null,
      rule: n.rule || null, negated, leadingWildcard: n.leading, indexUse: use, indexLabel: INDEX_LABEL[use],
      children: n.children.map((c) => view(c, text, negated || n.kind === 'not')),
    };
  }
  function suggest(p) {
    const root = p.root;
    const level = root.kind === 'and' ? root.children : [root];
    const leaf = level.find((n) => n.kind === 'equality' && lower(n.attribute) === 'objectclass' && USUAL_CATEGORY[lower(n.value)]);
    const reasons = [];
    let filter = null;
    if (leaf && !level.some((n) => lower(n.attribute) === 'objectcategory')) {
      const excluded = exclusions(leaf.value);
      if (excluded.length || indexUse(root) !== 'yes') {
        const clause = `(objectCategory=${USUAL_CATEGORY[lower(leaf.value)]})`;
        filter = root.kind === 'and' ? p.text.slice(0, root.start + 2) + clause + p.text.slice(root.start + 2) : `(&${clause}${p.text})`;
        reasons.push(excluded.length
          ? `${clause} cible la catégorie, indexée, mais écarte ${classList(excluded)}${excluded.length > 1 ? ', qui dérivent de ' : ', qui dérive de '}${leaf.value} avec une autre catégorie${COLON}gardez objectClass seul pour ${excluded.length > 1 ? 'les inclure' : 'l’inclure'}.`
          : `${clause} est indexé${COLON}il limite les objets examinés par le contrôleur, sans changer le résultat.`);
      }
    }
    for (const { n } of leaves(root)) {
      if (lower(n.attribute) === 'createtimestamp' || lower(n.attribute) === 'modifytimestamp') {
        const stored = lower(n.attribute) === 'createtimestamp' ? 'whenCreated' : 'whenChanged';
        filter = (filter ?? p.text).replace(n.attribute, stored);
        reasons.push(`${n.attribute} est calculé${COLON}${stored} porte la même date et se filtre.`);
      }
    }
    if (root.kind === 'not') reasons.push(`Un filtre fait seulement d’une négation lit tout le périmètre${COLON}ajoutez un critère indexé, par exemple (objectCategory=person).`);
    return reasons.length ? { filter: filter && parse(filter).valid ? filter : null, reasons } : null;
  }

  function analysis(filter) {
    const p = parse(filter);
    const schemaUsed = !!catalog;
    if (!p.valid) {
      const message = `Filtre non valide${COLON}${p.error}`;
      return {
        valid: false, error: p.error, errorPosition: p.position, normalized: p.text || null, level: 'invalid', levelLabel: 'Invalide', tone: 'alert', indexUse: 'unknown',
        schemaUsed, attributes: [], notIndexed: [], unknown: [], leadingWildcards: [], constructed: [], confidential: [], negations: 0, extensible: 0,
        advice: [message], text: message, tree: null, suggestion: null,
      };
    }
    const once = (list, v) => { if (v && !list.includes(v)) list.push(v); };
    const out = { attributes: [], notIndexed: [], unknown: [], leadingWildcards: [], constructed: [], confidential: [] };
    let negations = 0;
    let extensible = 0;
    for (const { n, negated } of leaves(p.root)) {
      if (negated) negations += 1;
      if (n.kind === 'extensible') extensible += 1;
      once(out.attributes, n.attribute);
      if (n.leading) once(out.leadingWildcards, n.attribute);
      if (!n.attribute || lower(n.attribute) === 'anr') continue;
      const a = catalog ? attrs.get(lower(n.attribute)) : null;
      if (!a) { once(out.unknown, n.attribute); continue; }
      if (a.constructed) once(out.constructed, n.attribute);
      if (!a.indexed) once(out.notIndexed, n.attribute);
      if (a.confidential) once(out.confidential, n.attribute);
    }
    const use = indexUse(p.root);
    const level = use === 'yes' ? 'targeted' : use === 'no' ? 'broad' : 'unknown';
    const advice = [];
    if (!schemaUsed) advice.push(`Index non vérifiés${COLON}lisez le schéma de l’annuaire (bouton ${quote('Lire le schéma')}) pour savoir quels attributs sont indexés.`);
    if (use === 'yes') advice.push(`Filtre ciblé${COLON}un critère indexé limite les objets examinés par le contrôleur.`);
    else if (use === 'no') advice.push(`Filtre large${COLON}le contrôleur examine chaque objet du périmètre. Ajoutez un critère indexé (égalité ou début de valeur), ou limitez la recherche à une OU.`);
    else if (schemaUsed) advice.push(out.unknown.length ? `Coût indéterminé${COLON}${out.unknown.join(', ')} ${out.unknown.length > 1 ? 'sont absents' : 'est absent'} du schéma lu.` : 'Coût indéterminé.');
    if (out.leadingWildcards.length) advice.push(`Joker en tête sur ${out.leadingWildcards.join(', ')}${COLON}cette sous-chaîne n’utilise pas l’index habituel.`);
    if (negations) advice.push(`La négation (!) n’utilise aucun index${COLON}gardez-la à côté d’un critère indexé.`);
    if (extensible) advice.push(`Règle de correspondance (par exemple sur les bits de userAccountControl)${COLON}évaluée objet par objet.`);
    if (out.constructed.length) advice.push(`Attribut calculé ${out.constructed.join(', ')}${COLON}le contrôleur ne l’évalue pas dans un filtre${NBSP}; utilisez l’attribut stocké correspondant.`);
    if (out.confidential.length) advice.push(`Attribut confidentiel ${out.confidential.join(', ')}${COLON}sans droit de lecture particulier, ce critère ne retient aucun objet.`);
    return {
      valid: true, error: null, errorPosition: null, normalized: p.text, level, levelLabel: LEVEL[level][0], tone: LEVEL[level][1], indexUse: use, schemaUsed,
      ...out, negations, extensible, advice, text: `Coût LDAP${COLON}${LEVEL[level][0]}. ${advice.join(' ')}`,
      tree: p.items <= 300 ? view(p.root, p.text) : null, suggestion: suggest(p),
    };
  }

  function analyze(args) {
    const filter = getString(readObject(args, ['filter']), 'filter');
    return analysis(filter);
  }

  function insert(args) {
    const values = readObject(args, ['filter', 'attribute']);
    const filter = getOptionalString(values, 'filter') ?? '';
    const name = nameArg(getString(values, 'attribute'), 'attribute');
    requireCatalog();
    const a = attrs.get(lower(name));
    if (!a) throw fail('schema.unknownAttribute', `Attribut inconnu du schéma lu${COLON}rien n’a été affiché.`);
    if (a.constructed || a.defunct) {
      return { filter, changed: false, message: a.constructed ? `${a.name} est calculé${COLON}il ne sert pas de critère. Rien n’a été ajouté.` : `${a.name} est obsolète${COLON}rien n’a été ajouté.`, analysis: analysis(filter || '(x=*)') };
    }
    const clause = example(a);
    const trimmed = filter.trim();
    const p = parse(trimmed);
    let next;
    if (!trimmed) next = clause;
    else if (p.valid && p.root.kind === 'and') next = `${p.text.slice(0, -1)}${clause})`;
    else next = `(&${p.valid ? p.text : (trimmed.startsWith('(') ? trimmed : `(${trimmed})`)}${clause})`;
    return { filter: next, changed: true, message: `Critère sur ${a.name} ajouté au brouillon${COLON}complétez la valeur. Rien n’est exécuté.`, analysis: analysis(next) };
  }

  async function read(args) {
    requireNone(args);
    if (reading) throw fail('schema.readBusy', `Une lecture du schéma est déjà en cours${COLON}attendez sa fin (une seule lecture à la fois).`);
    reading = true;
    try {
      await sleep(900);
      catalog = { readAt: Date.now() };
      log(`Schéma lu sur ${SERVER}${COLON}${count(CLASSES.length, 'classe', 'classes')}, ${count(ATTRIBUTES.length, 'attribut', 'attributs')}`, 'info', Date.now());
      return status();
    } finally {
      reading = false;
    }
  }

  // ---------------------------------------------------------------- workstation account
  const machine = { typed: null, generation: 0, version: 0, pauses: new Map(), trials: [], waiters: [] };
  const bump = () => { machine.version += 1; const w = machine.waiters.splice(0); w.forEach((f) => f()); };
  const ORIGIN = {
    temporaryLocal: 'compte local temporaire de ce poste', temporary: 'compte temporaire accepté après un refus', typed: 'compte poste saisi, en mémoire seulement',
    remote: 'compte Postes de la page Comptes', connection: 'compte de connexion', windows: 'session Windows',
  };
  const LEVELS = [
    ['temporaryLocal', 'Compte local accepté pour ce poste', `Accepté après un refus d’accès sur ce poste, pour lui seul${NBSP}; gardé en mémoire avec son bail.`],
    ['temporary', 'Compte temporaire Postes', `Accepté après un refus sur un poste${NBSP}; vaut pour tous les postes tant que son bail est valide.`],
    ['typed', 'Compte poste saisi', `Saisi dans le panneau ${quote('Compte poste')}${NBSP}; en mémoire seulement, jamais enregistré.`],
    ['remote', 'Compte Postes', 'Compte administrateur des postes configuré dans la page Comptes.'],
    ['connection', 'Compte de connexion', `Simulation${COLON}aucune connexion par identifiants${NBSP}; l’annuaire fictif n’en demande pas.`],
    ['windows', 'Session Windows', `Compte de la session Windows qui a lancé Domenia${NBSP}; toujours disponible.`],
  ];
  const machineKey = (t) => { const v = String(t ?? '').trim(); return /^[A-Za-z0-9][A-Za-z0-9-]{0,62}(\.[A-Za-z0-9-]{1,63})*$/.test(v) ? v.split('.')[0].toUpperCase() : null; };
  const findStation = (t) => WORKSTATIONS.find((w) => w.name === machineKey(t)) ?? null;
  const station = (w) => (w ? {
    id: `00000000-0000-4000-8000-${String(WORKSTATIONS.indexOf(w)).padStart(12, '0')}`, name: w.name, dnsHostName: `${lower(w.name)}.example.local`,
    dn: `CN=${w.name},OU=${w.ou.split(' › ')[0]},${ROOT_DN}`, path: `example.local › ${w.ou}`, operatingSystem: w.os, enabled: true,
    presence: { state: 'online', label: 'En ligne', tone: 'ok', checkedAt: iso(Date.now() - 6 * 60_000) },
  } : null);
  const placeOf = (source) => (source === 'typed' ? `typed#${machine.generation}` : `${source}|${lower(SESSION_ACCOUNT)}`);

  function machineState(target) {
    const key = machineKey(target);
    const accounts = [null, null, machine.typed?.account ?? null, null, null, SESSION_ACCOUNT];
    const active = accounts.findIndex(Boolean);
    const levels = LEVELS.map(([source, title, detail], n) => {
      const account = accounts[n];
      const pause = account ? machine.pauses.get(placeOf(source)) ?? null : null;
      const state = n === active ? 'active' : account ? 'available' : source === 'temporaryLocal' && !key ? 'notApplicable' : 'empty';
      const label = pause ? 'En pause après un refus' : { active: 'En service', available: 'Disponible, non utilisé', notApplicable: 'Propre au poste choisi', empty: 'Non configuré' }[state];
      return {
        rank: n + 1, source, title, origin: ORIGIN[source], account, state, stateLabel: label, tone: pause ? 'warn' : state === 'active' ? 'ok' : state === 'available' ? 'info' : 'off',
        detail, paused: !!pause, pauseReason: pause?.reason ?? null,
      };
    });
    const source = LEVELS[active][0];
    const account = accounts[active];
    const windows = source === 'windows';
    const short = windows ? 'session Windows' : account;
    const long = windows ? `session Windows (${account})` : `${account} (${ORIGIN[source]})`;
    const pause = machine.pauses.get(placeOf(source)) ?? null;
    const tip = `Compte utilisé pour les opérations sur ce poste${COLON}${long}. Ouvre un panneau pour saisir un autre compte ou revenir au compte de connexion.${pause ? ` En pause après un refus${COLON}${pause.reason}` : ''}`;
    const secrets = [
      ['temporary', 'Compte temporaire Secrets', 'compte temporaire accepté après un refus', null],
      ['secrets', 'Compte Secrets', 'compte Secrets de la page Comptes', null],
      ['directory', 'Compte de l’annuaire', 'compte de l’annuaire', SESSION_ACCOUNT],
    ].map(([s, title, origin, acct], n) => ({
      rank: n + 1, source: s, title, origin, account: acct, state: acct ? 'active' : 'empty', stateLabel: acct ? 'En service' : 'Non configuré', tone: acct ? 'ok' : 'off',
      detail: n === 2 ? `Compte de connexion, sinon session Windows${NBSP}; toujours disponible.` : 'Configuré dans la page Comptes ou accepté après un refus.', paused: false, pauseReason: null,
    }));
    return {
      inUse: { source, account, origin: ORIGIN[source], short, long, pill: `Compte poste${COLON}${short} ▾`, tip, rank: active + 1, paused: !!pause, pauseReason: pause?.reason ?? null, tone: pause ? 'warn' : 'ok' },
      sentence: `Opérations poste${COLON}${long}.`, targetName: key ? String(target).trim() : null, target: station(findStation(target)), levels,
      confidentialReads: { account: SESSION_ACCOUNT, origin: 'compte de l’annuaire', long: `${SESSION_ACCOUNT} (compte de l’annuaire)`, levels: secrets },
      typed: machine.typed, credentialRequired: false,
      credentialNote: `Simulation${COLON}aucun mot de passe n’est demandé. Le compte est gardé par son nom, en mémoire, pour essayer la règle et l’essai d’accès sur l’annuaire fictif.`,
      generation: machine.generation, version: machine.version, simulated: true, trials: machine.trials.slice(),
      safeguards: [
        `Le compte poste vaut pour cette session${COLON}jamais enregistré sur le disque, jamais journalisé.`,
        'Le mot de passe quitte la page dans un seul message, devient aussitôt une SecureString en lecture seule jusqu’à l’API Windows, et n’est ni affiché, ni renvoyé à la page, ni passé en ligne de commande.',
        `Fermer le panneau, Échap ou un clic à côté ne changent rien${COLON}un mot de passe saisi sans ${quote('Utiliser ce compte')} est effacé.`,
        `Un refus met en pause ce compte, à cette place de la règle${COLON}la prochaine opération avec lui est refusée tant qu’un essai réussi ne l’a pas validé.`,
        `Simulation${COLON}aucun mot de passe n’est demandé, aucun poste n’est contacté${NBSP}; l’essai lit l’annuaire fictif.`,
      ],
    };
  }

  function targetArg(values) {
    const t = getOptionalString(values, 'target');
    if (!t || !t.trim()) return null;
    if (!machineKey(t)) throw invalid(`${quote('target')} doit être un nom de poste.`);
    return t.trim();
  }
  function accountArg(value) {
    if (!value || !value.trim()) throw fail('machine.accountEmpty', `Compte poste vide${COLON}rien n’a changé.`);
    const v = value.trim();
    if (!/^(\.|[A-Za-z0-9][A-Za-z0-9._-]{0,14})\\[^\\/"[\]:;|=,+*?<>@\s]+$|^[^\\/"[\]:;|=,+*?<>@\s]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$/.test(v)) {
      throw fail('machine.accountInvalid', `Identifiant non reconnu${COLON}écrivez DOMAINE\\nom, POSTE\\nom, .\\nom ou nom@domaine. Rien n’a changé.`);
    }
    return v;
  }
  function noPassword(values) {
    if (getOptionalString(values, 'password')) throw fail('machine.passwordRefused', `Simulation${COLON}aucun mot de passe n’est demandé ni gardé. Laissez le champ vide.`);
  }

  function machineArgs(args) {
    return args === undefined || args === null ? {} : readObject(args, ['target']);
  }

  return {
    'schema.status': (args) => { requireNone(args); return status(); },
    'schema.read': read,
    'schema.list': list,
    'schema.class': classDetail,
    'schema.attribute': attributeDetail,
    'schema.filter.analyze': analyze,
    'schema.filter.insert': insert,
    'machine.account.state': (args) => machineState(targetArg(machineArgs(args))),
    'machine.account.use': (args) => {
      const values = readObject(args, ['account', 'password', 'target']);
      const account = accountArg(getString(values, 'account'));
      const target = targetArg(values);
      noPassword(values);
      machine.typed = { account, since: iso(Date.now()), withCredential: false };
      machine.generation += 1;
      bump();
      log('Compte poste saisi pour la session (en mémoire seulement)', 'info', Date.now());
      return machineState(target);
    },
    'machine.account.forget': (args) => {
      const target = targetArg(machineArgs(args));
      if (machine.typed) { machine.typed = null; machine.generation += 1; bump(); }
      return machineState(target);
    },
    'machine.account.trial': async (args) => {
      const values = readObject(args, ['target', 'account', 'password']);
      const target = targetArg(values);
      if (!target) throw fail('machine.targetMissing', `Choisissez d’abord un poste${COLON}l’essai porte sur un seul poste, jamais sur une liste.`);
      const candidateText = getOptionalString(values, 'account');
      const candidate = candidateText === null ? null : accountArg(candidateText);
      noPassword(values);
      await sleep(700);
      const w = findStation(target);
      if (!w) throw fail('machine.targetUnknown', `Poste introuvable dans l’annuaire${COLON}aucun essai n’est parti.`);
      const before = machineState(target);
      const account = candidate ?? before.inUse.account;
      const prefix = account.includes('\\') ? account.split('\\')[0].toUpperCase() : 'EXAMPLE';
      let verdict;
      if (prefix === '.' || prefix === w.name) verdict = 'adminOk';
      else if (prefix !== 'EXAMPLE') verdict = 'rejected';
      else if (/administrateur/i.test(account)) verdict = 'adminOk';
      else if (/j\.martin$/i.test(account)) verdict = w.server ? 'denied' : 'adminOk';
      else verdict = 'rejected';
      const who = candidate ? `${account} (compte à valider, pas encore en service)` : before.inUse.long;
      const text = {
        adminOk: `Accès administrateur OK sur ${w.name} avec ${who}. Système${COLON}Microsoft ${w.os}.`,
        denied: `Accès refusé sur ${w.name} avec ${who}${COLON}droit administrateur requis sur ce poste.`,
        rejected: `Identifiants refusés par ${w.name} pour ${who}${COLON}vérifiez le compte et son mot de passe.`,
      }[verdict];
      const tone = { adminOk: 'ok', denied: 'warn', rejected: 'alert' }[verdict];
      const trial = {
        verdict, success: verdict === 'adminOk', text, tone, computer: w.name, account: before.inUse.source === 'windows' && !candidate ? before.inUse.long : account,
        origin: candidate ? 'compte à valider, pas encore en service' : before.inUse.origin, caption: verdict === 'adminOk' ? `Microsoft ${w.os}` : null,
        candidate: !!candidate, simulated: true, at: iso(Date.now()),
      };
      machine.trials.unshift(trial);
      machine.trials.length = Math.min(machine.trials.length, 8);
      if (!candidate) {
        const place = placeOf(before.inUse.source);
        if (verdict === 'rejected') machine.pauses.set(place, { reason: text });
        else if (verdict === 'adminOk') machine.pauses.delete(place);
      }
      bump();
      log(`Essai du compte poste sur ${w.name}${COLON}${{ adminOk: 'accès administrateur OK', denied: 'accès refusé', rejected: 'identifiants refusés' }[verdict]} (simulation)`, tone, Date.now());
      return { trial, state: machineState(target) };
    },
    'machine.account.watch': async (args) => {
      const values = readObject(args, ['since', 'target']);
      const since = Object.hasOwn(values, 'since') ? values.since : null;
      if (since !== null && (!Number.isInteger(since) || since < 0)) throw invalid(`${quote('since')} doit être un entier positif ou null.`);
      const target = targetArg(values);
      if (since !== null && since === machine.version) {
        await new Promise((resolve) => { machine.waiters.push(resolve); setTimeout(resolve, WATCH_MS); });
      }
      const s = machineState(target);
      return { version: s.version, changed: since === null || s.version !== since, inUse: s.inUse, sentence: s.sentence, generation: s.generation };
    },
    'machine.workstations.search': (args) => {
      const text = getString(readObject(args, ['text']), 'text');
      if (text.length > 64) throw invalid(`${quote('text')} doit faire au plus ${int(64)} caractères.`);
      const t = lower(text.trim());
      if (!t) return [];
      return WORKSTATIONS.filter((w) => lower(w.name).includes(t))
        .sort((a, b) => (lower(b.name).startsWith(t) - lower(a.name).startsWith(t)) || a.name.localeCompare(b.name)).slice(0, 12).map(station);
    },
  };
}
