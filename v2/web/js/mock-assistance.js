// Browser preview of the Assistance operations (docs/ops/assistance.md): same operation names, argument checks and result
// shapes as AssistanceOperations, on a few fictitious objects of example.local. The workshop (captures, pins, incidents,
// launches) lives in the memory of the page; nothing leaves it and nothing is written (documents « préparés en mémoire »,
// like the capture mode of the application). The helpers of mock.js are handed in so validation messages match the engine.

const MIN = 60_000;
const ROOT = 'DC=example,DC=local';
const SCOPE = 'dc=example,dc=local';
const SESSION = 'apercu0000000000';

/**
 * @param {object} h  Helpers of mock.js: readObject, getString, getOptionalString, requireDistinguishedName, requireNone,
 *   invalid, fail, quote, int, sleep, log, NBSP.
 * @returns {Object<string, (args: any) => any>}
 */
export function createAssistanceOperations(h) {
  const { readObject, getString, getOptionalString, requireDistinguishedName, requireNone, invalid, fail, quote, int, sleep, NBSP } = h;
  const COLON = `${NBSP}: `;
  const count = (n, one, many) => `${int(n)}${NBSP}${Math.abs(n) >= 2 ? many : one}`;
  const iso = (t) => new Date(t).toISOString();
  const pad = (n) => String(n).padStart(2, '0');
  const hm = (t) => { const d = new Date(t); return `${pad(d.getHours())}:${pad(d.getMinutes())}`; };
  const fileTime = (t) => String((BigInt(Math.trunc(t)) + 11_644_473_600_000n) * 10000n);
  const key = (dn) => String(dn).toLowerCase();
  const now = () => Date.now();
  const hex = (n) => [...crypto.getRandomValues(new Uint8Array(n))].map((b) => b.toString(16).padStart(2, '0')).join('');

  // ---------- Objects of the preview ----------
  const user = (sam, name, ou, extra) => ({ kind: 'user', sam, name, dn: `CN=${name},OU=${ou},OU=Utilisateurs,${ROOT}`, guid: crypto.randomUUID(), ou, ...extra });
  const pc = (name, site, extra) => ({ kind: 'computer', sam: `${name}$`, name, dn: `CN=${name},OU=${site},OU=Postes,${ROOT}`, guid: crypto.randomUUID(), ou: site, ...extra });
  const objects = [
    user('c.bernard', 'Camille Bernard', 'Lyon', { title: 'Chargée de clientèle', locked: 4, manager: 'Cédric Carré' }),
    user('r.garcia', 'Romain Garcia', 'Lyon', { title: 'Technicien', manager: 'Cédric Carré' }),
    user('m.lefevre', 'Maëlle Lefèvre', 'Bordeaux', { title: 'Comptable', expired: true, manager: 'Sophie Martin' }),
    pc('PC-LYO-0042', 'Lyon', { owner: 'c.bernard', freePct: 7, uptime: 34 }),
    pc('PC-BDX-0006', 'Bordeaux', { owner: 'm.lefevre', freePct: 41, uptime: 3 }),
    pc('PT-PAR-0118', 'Paris', { freePct: 22, uptime: 12, silent: true }),
  ];
  const bySam = (sam) => objects.find((o) => o.sam === sam);
  const byDn = (dn) => objects.find((o) => key(o.dn) === key(dn));
  const path = (o) => `${o.kind === 'user' ? 'Utilisateurs' : 'Postes'} › ${o.ou}`;

  function hit(o) {
    const tone = o.locked || o.expired ? 'alert' : o.silent ? 'warn' : 'ok';
    const state = o.locked ? 'Verrouillé' : o.expired ? 'Mot de passe expiré' : o.kind === 'computer' ? (o.silent ? 'Muet' : 'En ligne') : 'Actif';
    return { dn: o.dn, kind: o.kind, name: o.name, login: o.sam, detail: o.kind === 'user' ? o.title : `${o.name.toLowerCase()}.example.local`, path: path(o), tone, stateLabel: state };
  }

  function fields(o, readAt) {
    const f = (name, values, coverage = 'provided') => ({ name, coverage: values.length ? coverage : 'notProvided', values });
    const group = (n) => `CN=${n},OU=Groupes,${ROOT}`;
    if (o.kind === 'user') {
      return [
        f('sAMAccountName', [o.sam]), f('userPrincipalName', [`${o.sam}@example.local`]), f('displayName', [o.name]), f('mail', [`${o.sam}@example.fr`]),
        f('title', [o.title]), f('department', [o.ou === 'Lyon' ? 'Commercial' : 'Finances']), f('manager', [`CN=${o.manager},OU=${o.ou},OU=Utilisateurs,${ROOT}`]),
        f('userAccountControl', ['512']), f('lockoutTime', [o.locked ? fileTime(readAt - 25 * MIN) : '0']), f('pwdLastSet', [fileTime(readAt - (o.expired ? 95 : 32) * 24 * 60 * MIN)]),
        f('accountExpires', ['9223372036854775807']), f('lastLogonTimestamp', [fileTime(readAt - 26 * 60 * MIN)]), f('badPwdCount', [String(o.locked ?? 0)]),
        f('memberOf', [group('GG-Lyon-Commercial'), group('GG-VPN-Utilisateurs'), group('GG-Imprimantes-Lyon')]),
        f('whenCreated', ['2023-02-14T09:12:44.0000000Z']), f('whenChanged', [new Date(readAt - 3 * MIN).toISOString().replace('.000Z', '.0000000Z')]),
        f('distinguishedName', [o.dn]), f('objectGUID', [o.guid]), f('description', []), f('telephoneNumber', []),
      ];
    }
    return [
      f('sAMAccountName', [o.sam]), f('dNSHostName', [`${o.name.toLowerCase()}.example.local`]), f('operatingSystem', ['Windows 11 Entreprise']),
      f('operatingSystemVersion', ['10.0 (22631)']), f('managedBy', o.owner ? [bySam(o.owner).dn] : []), f('userAccountControl', ['4096']),
      f('pwdLastSet', [fileTime(readAt - 12 * 24 * 60 * MIN)]), f('lastLogonTimestamp', [fileTime(readAt - 9 * 60 * MIN)]),
      f('memberOf', [group('GG-Postes-Standard'), group(`GG-Postes-${o.ou}`)]), f('whenCreated', ['2024-06-03T07:40:12.0000000Z']),
      f('whenChanged', [new Date(readAt - 40 * MIN).toISOString().replace('.000Z', '.0000000Z')]), f('distinguishedName', [o.dn]), f('objectGUID', [o.guid]), f('description', []),
    ];
  }

  function findings(o) {
    const out = [];
    const add = (code, level, title, evidence, next, basis = 'observation') => out.push({
      code, level, levelLabel: { attention: 'Attention', toCheck: 'À vérifier', undetermined: 'Indéterminé', information: 'Information' }[level],
      tone: { attention: 'alert', toCheck: 'warn', undetermined: 'off', information: 'info' }[level], title, evidence, next, basis,
      basisLabel: { observation: 'Observation', coverage: 'Couverture', limit: 'Limite' }[basis],
    });
    if (o.locked) add('ACCOUNT_LOCKED', 'attention', 'Compte verrouillé', `lockoutTime renseigné, ${count(o.locked, 'échec récent', 'échecs récents')}.`, 'Cherchez le poste qui verrouille (étape « Verrouillages des 7 derniers jours ») avant de déverrouiller.');
    if (o.expired) add('PASSWORD_EXPIRED', 'attention', 'Mot de passe expiré', 'pwdLastSet dépasse la durée maximale du domaine (90 jours).', 'Faites changer le mot de passe à la prochaine ouverture de session.');
    if (o.freePct !== undefined && o.freePct < 10) add('DISK_LOW', 'attention', 'Disque C presque plein', `${int(o.freePct)}${NBSP}% libre au dernier relevé.`, 'Libérez de l’espace ou étendez le disque ; prévenez l’utilisateur.');
    if (o.uptime > 30) add('UPTIME_LONG', 'toCheck', `Sans redémarrage depuis ${count(o.uptime, 'jour', 'jours')}`, 'Dernier démarrage relevé il y a plus de 30 jours.', 'Un redémarrage planifié règle souvent la lenteur ; prévenez l’utilisateur avant.');
    if (o.silent) add('NO_ANSWER', 'toCheck', 'Aucune réponse au dernier relevé de présence', 'Ni ping ni WMI au dernier relevé.', 'Vérifiez que le poste est allumé et sur le réseau.');
    add('DATA_NOT_LIVE', 'information', 'Lecture de l’aperçu', 'Données fictives du navigateur.', 'Aucune vérification proposée.', 'limit');
    return out;
  }

  function view(o) {
    const readAt = now();
    const f = fields(o, readAt);
    const provided = f.filter((x) => x.coverage === 'provided').length;
    const facts = o.kind === 'user'
      ? [{ label: 'État', value: o.locked ? 'Verrouillé' : 'Actif', tone: o.locked ? 'alert' : 'ok' }, { label: 'Mot de passe', value: o.expired ? 'Expiré depuis 5 jours' : 'Expire dans 58 jours', tone: o.expired ? 'alert' : 'off' },
        { label: 'Dernière connexion', value: 'Hier à 08:12', tone: 'off' }, { label: 'Échecs récents', value: String(o.locked ?? 0), tone: o.locked ? 'warn' : 'off' }, { label: 'Fonction', value: o.title, tone: 'off' }]
      : [{ label: 'Présence', value: o.silent ? 'Muet au dernier relevé' : 'En ligne', tone: o.silent ? 'warn' : 'ok' }, { label: 'Système', value: 'Windows 11 Entreprise 23H2', tone: 'off' },
        { label: 'Nom DNS', value: `${o.name.toLowerCase()}.example.local`, tone: 'off' }, { label: 'Disque C:', value: `${int(o.freePct)}${NBSP}% libre`, tone: o.freePct < 10 ? 'alert' : o.freePct < 20 ? 'warn' : 'ok' },
        { label: 'Dernier démarrage', value: `Il y a ${count(o.uptime, 'jour', 'jours')}`, tone: o.uptime > 30 ? 'warn' : 'off' }];
    const related = o.kind === 'user' ? objects.filter((x) => x.owner === o.sam).map(hit) : o.owner ? [hit(bySam(o.owner))] : [];
    const pills = o.locked ? [{ tone: 'alert', label: 'Verrouillé' }, { tone: 'warn', label: count(o.locked, 'échec récent', 'échecs récents') }]
      : o.expired ? [{ tone: 'alert', label: 'Mot de passe expiré' }] : o.kind === 'computer' ? [{ tone: o.silent ? 'warn' : 'ok', label: o.silent ? 'Muet' : 'En ligne' }] : [{ tone: 'ok', label: 'Actif' }];
    return {
      card: { dn: o.dn, guid: o.guid, kind: o.kind, kindLabel: o.kind === 'user' ? 'Utilisateur' : 'Poste', name: o.name, login: o.sam, path: path(o), facts, pills, related,
        relatedLabel: o.kind === 'user' ? 'Postes dont il est responsable (managedBy)' : 'Utilisateur responsable (managedBy)', readAt: iso(readAt) },
      snapshot: { format: 1, id: hex(16), identity: `guid:${o.guid}`, scope: SCOPE, dn: o.dn, name: o.name, kind: o.kind, kindLabel: o.kind === 'user' ? 'Utilisateur' : 'Poste',
        source: 'live', observedAt: iso(readAt), capturedAt: iso(readAt), fields: f, fieldCount: provided },
      findings: findings(o),
      coverage: { provided, partial: 0, notProvided: f.length - provided, total: f.length, sourceLabel: 'lecture actuelle', observedAt: iso(readAt), text: `${count(provided, 'attribut fourni', 'attributs fournis')} sur ${int(f.length)}` },
    };
  }

  // ---------- Recipes ----------
  const V = {
    fiche: { screen: 'fiche', section: 'compte', label: 'Fiche du compte' },
    policy: { screen: 'audit', section: 'motdepasse', label: 'Audit AD · Stratégie de mot de passe' },
    machine: { screen: 'audit', section: 'poste', label: 'Audit AD · Identité du poste' },
    groups: { screen: 'audit', section: 'groupes', label: 'Audit AD · Groupes' },
    gpo: { screen: 'audit', section: 'gpo', label: 'Audit AD · Stratégies de groupe' },
    health: { screen: 'poste', section: 'reseau', label: 'Poste · Diagnostic réseau' },
    inventory: { screen: 'poste', section: 'materiel', label: 'Poste · Inventaire' },
    software: { screen: 'poste', section: 'logiciels', label: 'Poste · Logiciels' },
    sessions: { screen: 'poste', section: 'sessions', label: 'Poste · Sessions' },
  };
  const OPS = { lockoutEvents: 'LockoutDiagnosis', passwordPolicy: 'PasswordPolicyRead', groups: 'GroupPathRead', gpoLinks: 'GpoLinksRead', gpoApplied: 'GpoAppliedRead',
    machineIdentity: 'MachineIdentityRead', diagnostics: 'ComputerDiagnostics', inventory: 'ComputerInventory', inventoryDeep: 'ComputerInventory', software: 'SoftwareInventory', sessions: 'SessionsList' };
  const step = (id, title, subject, action, view, reads, why, cost, o = {}) => ({ id, title, subject, action, view, reads, why, cost, optional: Boolean(o.optional), privileged: Boolean(o.privileged) });
  const account = () => step('account', 'État du compte', 'user', null, V.fiche, 'Rien de nouveau : état du compte, verrouillage, échéance du mot de passe et échecs, déjà lus à l’ouverture de la fiche.', 'Un compte désactivé, expiré ou verrouillé empêche toute ouverture de session.', 'Aucune lecture.');
  const lockouts = (why, optional = false) => step('lockouts', 'Verrouillages des 7 derniers jours', 'user', 'lockoutEvents', V.fiche, 'Journal Sécurité de l’émulateur PDC : événements 4740 de ce seul compte, 7 jours, 200 au plus.', why, 'Une lecture du journal du contrôleur.', { optional });
  const policy = (why, optional) => step('policy', 'Stratégie de mot de passe applicable', 'user', 'passwordPolicy', V.policy, 'Stratégie fine applicable, stratégie du domaine et échéance calculée ; aucun mot de passe.', why, 'Trois à cinq lectures LDAP bornées.', { optional });
  const reach = (title, why) => step('reach', title, 'computer', 'diagnostics', V.health, 'Réponse au ping et ouverture des ports d’administration du poste.', why, 'Lecture réseau du poste, quelques secondes.');
  const cim = 'Lecture CIM du poste, 10 à 60 secondes ; droits d’administration du poste.';
  const RECIPES = [
    { id: 'logon', title: 'Connexion impossible', symptom: 'L’utilisateur ne peut pas ouvrir de session : mot de passe refusé, compte bloqué ou poste qui n’authentifie plus.', icon: 'key', added: false, steps: [
      account(), lockouts('Trouver le poste qui verrouille le compte.'), policy('Comprendre une expiration ou un seuil propres à ce compte.', true), reach('Poste joignable', 'Un poste hors réseau ne joint pas le contrôleur.'),
      step('identity', 'Identité du poste', 'computer', 'machineIdentity', V.machine, 'Résolution DNS du nom du poste et nom renvoyé par le poste (CIM).', 'Un enregistrement DNS périmé casse la relation avec le domaine.', 'Une résolution DNS et une lecture CIM.', { privileged: true }),
      step('clock', 'Heure et démarrage du poste', 'computer', 'inventory', V.inventory, 'Inventaire rapide : système, démarrage et écart d’horloge.', 'Au-delà de 5 minutes d’écart, Kerberos refuse l’ouverture de session.', cim, { privileged: true })] },
    { id: 'slow', title: 'Poste lent', symptom: 'Le poste répond lentement, à l’ouverture de session ou en continu.', icon: 'gauge', added: false, steps: [
      reach('Réseau du poste', 'Une latence réseau ralentit l’ouverture de session.'),
      step('inventory', 'Mémoire, disques et démarrage', 'computer', 'inventory', V.inventory, 'Inventaire rapide : mémoire, processeur, disques et démarrage.', 'Peu de mémoire ou un disque plein expliquent souvent la lenteur.', cim, { privileged: true }),
      step('sessions', 'Sessions ouvertes', 'computer', 'sessions', V.sessions, 'Sessions console et RDP du poste, sans fermeture.', 'Une session déconnectée occupe la mémoire.', 'Une lecture des sessions du poste.', { optional: true }),
      step('deep', 'Inventaire complet', 'computer', 'inventoryDeep', V.inventory, 'Inventaire complet du poste.', 'Approfondir seulement si nécessaire.', 'Plus long ; droits d’administration du poste.', { optional: true, privileged: true })] },
    { id: 'disk', title: 'Manque d’espace', symptom: 'Le poste signale un disque plein ou une application refuse d’enregistrer.', icon: 'disk', added: false, steps: [
      step('inventory', 'Espace des disques', 'computer', 'inventory', V.inventory, 'Disques logiques, taille et espace libre.', 'Mesurer l’espace restant avant toute action.', cim, { privileged: true }),
      step('sessions', 'Sessions et profils ouverts', 'computer', 'sessions', V.sessions, 'Sessions console et RDP, sans fermeture.', 'Des sessions inactives gardent des profils.', 'Une lecture des sessions du poste.', { optional: true }),
      step('software', 'Logiciels installés', 'computer', 'software', V.software, 'Logiciels lus dans le registre.', 'Repérer un logiciel volumineux.', 'Lecture du registre du poste.', { optional: true, privileged: true })] },
    { id: 'software', title: 'Logiciel absent', symptom: 'Un logiciel attendu n’est pas installé, ou pas dans la bonne version.', icon: 'layers', added: false, steps: [
      step('software', 'Logiciels installés', 'computer', 'software', V.software, 'Logiciels lus dans le registre, sans effet de bord MSI.', 'Vérifier la présence et la version.', 'Lecture du registre du poste.', { privileged: true }),
      step('groups', 'Groupes du poste', 'computer', 'groups', V.groups, 'Groupes du poste, directs et imbriqués.', 'Un logiciel distribué par groupe.', 'Lectures LDAP bornées.'),
      step('gpo', 'Liens GPO du poste', 'computer', 'gpoLinks', V.gpo, 'Liens GPO des OU au-dessus du poste.', 'Un déploiement par stratégie dépend des liens.', 'Une lecture LDAP par niveau d’OU.'),
      step('gpo-applied', 'Stratégies appliquées sur le poste', 'computer', 'gpoApplied', V.gpo, 'Dernier résultat RSoP enregistré.', 'Vérifier l’application réelle.', 'Lecture CIM du poste.', { optional: true, privileged: true }),
      step('groups-user', 'Groupes de l’utilisateur', 'user', 'groups', V.groups, 'Groupes du compte, bornés à 2 000.', 'Un logiciel distribué aux utilisateurs.', 'Lectures LDAP bornées.', { optional: true })] },
    { id: 'printer', title: 'Impression impossible', symptom: 'L’imprimante n’apparaît pas sur le poste, ou les documents restent en attente.', icon: 'printer', added: true, steps: [
      reach('Poste joignable', 'Un poste hors réseau ne joint pas le serveur d’impression.'),
      step('groups', 'Groupes du poste', 'computer', 'groups', V.groups, 'Groupes du poste.', 'Une imprimante déployée par groupe.', 'Lectures LDAP bornées.'),
      step('gpo', 'Liens GPO du poste', 'computer', 'gpoLinks', V.gpo, 'Liens GPO des OU au-dessus du poste.', 'Imprimantes déployées par préférences.', 'Une lecture LDAP par niveau d’OU.'),
      step('gpo-applied', 'Stratégies appliquées sur le poste', 'computer', 'gpoApplied', V.gpo, 'Dernier résultat RSoP.', 'Vérifier l’application.', 'Lecture CIM du poste.', { optional: true, privileged: true }),
      step('drivers', 'Pilotes et logiciels d’impression', 'computer', 'software', V.software, 'Pilotes et utilitaires d’impression.', 'Un pilote absent empêche l’impression.', 'Lecture du registre du poste.', { optional: true, privileged: true }),
      step('groups-user', 'Groupes de l’utilisateur', 'user', 'groups', V.groups, 'Groupes du compte.', 'Imprimante attribuée aux utilisateurs.', 'Lectures LDAP bornées.', { optional: true })] },
    { id: 'drive', title: 'Lecteur réseau absent', symptom: 'Un lecteur réseau attendu n’est pas monté, ou il demande sans cesse un mot de passe.', icon: 'folder', added: true, steps: [
      account(), lockouts('Un lecteur qui garde un ancien mot de passe verrouille le compte.', true),
      step('groups-user', 'Groupes de l’utilisateur', 'user', 'groups', V.groups, 'Groupes du compte.', 'L’accès au partage dépend des groupes.', 'Lectures LDAP bornées.'),
      step('gpo-user', 'Liens GPO de l’utilisateur', 'user', 'gpoLinks', V.gpo, 'Liens GPO au-dessus du compte.', 'Lecteurs montés par stratégie.', 'Une lecture LDAP par niveau d’OU.'),
      reach('Poste joignable', 'Sans réseau, le lecteur reste déconnecté.'),
      step('sessions', 'Sessions ouvertes', 'computer', 'sessions', V.sessions, 'Sessions du poste, sans fermeture.', 'Une session garde d’anciennes connexions SMB.', 'Une lecture des sessions.', { optional: true })] },
    { id: 'remote', title: 'Accès distant impossible', symptom: 'L’utilisateur ne parvient pas à se connecter à distance (VPN, tunnel ou bureau à distance).', icon: 'domain', added: true, steps: [
      account(), policy('Un mot de passe expiré est refusé par la passerelle.', false),
      step('groups-user', 'Groupes de l’utilisateur', 'user', 'groups', V.groups, 'Groupes du compte.', 'Accès réservé à un groupe dédié.', 'Lectures LDAP bornées.'),
      lockouts('Des essais répétés verrouillent le compte.', true),
      step('identity', 'Identité du poste', 'computer', 'machineIdentity', V.machine, 'Résolution DNS et nom CIM.', 'Un tunnel exige un compte ordinateur sain.', 'Une résolution DNS et une lecture CIM.', { optional: true, privileged: true }),
      step('clock', 'Heure du poste', 'computer', 'inventory', V.inventory, 'Écart d’horloge avec le contrôleur.', 'Kerberos échoue au-delà de 5 minutes.', cim, { optional: true, privileged: true })] },
  ];

  // ---------- Workshop of the page ----------
  const ws = { a: null, b: null, pins: [], incidents: [], revision: 1, launches: new Map(), read: new Map() };
  const T0 = now();
  const incident = (minutes, tone, area, title, codes, evidence, next, route, detail) => ({
    id: hex(8), at: iso(T0 - minutes * MIN), level: tone === 'alert' ? 'alert' : 'warn', levelLabel: tone === 'alert' ? 'Erreur' : 'Avertissement', tone, area, title, codes,
    hints: [{ code: codes.split(', ')[0], title, evidence, next, route, routeLabel: route === 'poste' ? 'Ouvrir Poste' : route === 'comptes' ? 'Ouvrir Comptes' : 'Ouvrir Opérations' }], detail, source: 'apercu' });
  ws.incidents = [
    incident(35, 'warn', 'Inventaire', 'Délai de lecture dépassé', 'TIMEOUT', 'Le message signale une attente expirée.', 'Identifiez la méthode et le temps écoulé.', 'operations', 'Relevé d’inventaire de PT-PAR-0121 : délai dépassé après 60 s (lecture WMI).'),
    incident(64, 'alert', 'Inventaire', 'Accès refusé à la ressource', 'ACCESS_DENIED', 'Refus d’accès signalé par une méthode.', 'Vérifiez le compte de la méthode et les droits.', 'comptes', 'Accès refusé (0x80070005) à WMI sur PC-MRS-0012.'),
    incident(88, 'alert', 'Poste', 'Transport RPC indisponible', 'RPC_UNAVAILABLE', 'Code ou message RPC indisponible.', 'Vérifiez la résolution, le chemin réseau et le filtrage RPC.', 'poste', 'Le serveur RPC n’est pas disponible (0x800706BA) : PC-LIL-0007 ne répond pas.'),
    incident(140, 'warn', 'Partages', 'Conflit de sessions SMB', 'SMB_SESSION_CONFLICT', 'Code 1219.', 'Vérifiez les sessions SMB vers cette cible.', 'comptes', 'Erreur système 1219 : connexions multiples à \\\\srv-fic01\\commun.'),
  ];
  const bump = () => { ws.revision += 1; };
  const slotView = (letter) => {
    const s = ws[letter];
    if (!s) return null;
    return { slot: letter, name: s.name, kind: s.kind, kindLabel: s.kindLabel, dn: s.dn, identity: s.identity, source: s.source, sourceLabel: s.source === 'live' ? 'lecture actuelle' : 'capture historique',
      observedAt: s.observedAt, capturedAt: s.capturedAt, fieldCount: s.fieldCount, historical: s.source !== 'live' };
  };
  function comparison() {
    const a = ws.a;
    const b = ws.b;
    if (!a || !b) return { ready: false, sameObject: false, summary: 'Capturez A, relisez ou ouvrez une autre fiche du même type, puis capturez B.', refusal: null, different: 0, undetermined: 0, identical: 0, rows: [] };
    if (a.kind !== b.kind) {
      const refusal = `Comparaison refusée${COLON}types d’objets différents.`;
      return { ready: false, sameObject: false, summary: refusal, refusal, different: 0, undetermined: 0, identical: 0, rows: [] };
    }
    const rows = [];
    for (const fa of a.fields) {
      const fb = b.fields.find((x) => x.name === fa.name);
      if (fa.coverage === 'notProvided' && fb?.coverage === 'notProvided') continue;
      const left = fa.values.join(' ; ');
      const right = fb?.values.join(' ; ') ?? '';
      let status = left === right ? 'identical' : 'different';
      let added = [];
      let removed = [];
      if (fa.coverage !== 'provided' || fb?.coverage !== 'provided') status = 'undetermined';
      else if (fa.name === 'memberOf') {
        added = fb.values.filter((v) => !fa.values.includes(v));
        removed = fa.values.filter((v) => !fb.values.includes(v));
        status = added.length || removed.length ? 'different' : 'identical';
      }
      rows.push({ attribute: fa.name, status, statusLabel: { identical: 'Identique', different: 'Différent', undetermined: 'Indéterminé' }[status], tone: { identical: 'ok', different: 'warn', undetermined: 'off' }[status],
        before: fa.coverage === 'notProvided' ? '[non fourni]' : left, after: fb?.coverage === 'notProvided' ? '[non fourni]' : right, added, removed });
    }
    const n = (s) => rows.filter((r) => r.status === s).length;
    const same = a.identity === b.identity;
    return { ready: true, sameObject: same, summary: `${same ? `Même objet${COLON}avant et après capture.` : `Objets différents${COLON}comparaison de référence, pas un historique.`} ${count(n('different'), 'différence', 'différences')}, ${count(n('undetermined'), 'indéterminé', 'indéterminés')}.`,
      refusal: null, different: n('different'), undetermined: n('undetermined'), identical: n('identical'), rows };
  }
  function workshop() {
    const items = [...ws.incidents].sort((x, y) => Date.parse(y.at) - Date.parse(x.at));
    const captures = (ws.a ? 1 : 0) + (ws.b ? 1 : 0);
    return { a: slotView('a'), b: slotView('b'), comparison: comparison(), pins: ws.pins, pinLimit: 24,
      incidents: { total: items.length, limit: 200, summary: items.length ? `${count(items.length, 'incident', 'incidents')} en mémoire, plafond de 200. Session complète, toutes cibles confondues${COLON}aucun rattachement automatique à une fiche.` : 'Aucun avertissement ni erreur dans cette session.', items },
      revision: ws.revision, summary: `${count(captures, 'capture', 'captures')}, ${count(ws.pins.length, 'repère', 'repères')}, ${count(items.length, 'incident', 'incidents')}${NBSP}; en mémoire seulement, rien n’est écrit sur le disque.`, session: SESSION };
  }

  function stepView(r, s, order, userDn, computerDn) {
    const dn = s.subject === 'user' ? userDn : computerDn;
    const launch = dn ? ws.launches.get(`${key(dn)}|${r.id}|${s.id}`) : null;
    let state;
    if (!dn) state = { phase: 'needSubject', canRun: false, canOpen: false, text: s.subject === 'user' ? 'Sélectionnez le compte concerné.' : 'Sélectionnez le poste concerné.', tone: 'off', at: null };
    else if (!s.action) state = { phase: 'viewOnly', canRun: false, canOpen: true, text: `Sans lecture${COLON}ouvrir la vue`, tone: 'off', at: null };
    else if (launch?.outcome === 'read') state = { phase: 'read', canRun: true, canOpen: true, text: `Lue à ${hm(launch.at)}${COLON}résultat ci-dessous`, tone: 'info', at: iso(launch.at) };
    else if (launch?.outcome === 'failed') state = { phase: 'failed', canRun: true, canOpen: true, text: `Échec à ${hm(launch.at)}${COLON}rien n’est relancé seul`, tone: 'warn', at: iso(launch.at) };
    else state = { phase: 'ready', canRun: true, canOpen: true, text: 'À lancer', tone: 'off', at: null };
    return { order, id: s.id, title: s.title, subject: s.subject, subjectLabel: s.subject === 'user' ? 'Utilisateur' : 'Poste', action: s.action, actionLabel: s.action ? s.title : null,
      operation: s.action ? OPS[s.action] : null, view: s.view, reads: s.reads, why: s.why, cost: s.cost, optional: s.optional, privileged: s.privileged, state,
      reading: launch?.reading ?? null, error: launch?.error ?? null };
  }
  function recipeView(r, userDn, computerDn) {
    const steps = r.steps.map((s, n) => stepView(r, s, n + 1, userDn, computerDn));
    const userReads = r.steps.filter((s) => s.action && s.subject === 'user').length;
    const computerReads = r.steps.filter((s) => s.action && s.subject === 'computer').length;
    const none = r.steps.filter((s) => !s.action).length;
    const privileged = r.steps.filter((s) => s.privileged).length;
    const optional = r.steps.filter((s) => s.optional).length;
    const parts = [];
    if (userReads) parts.push(count(userReads, 'lecture pour le compte', 'lectures pour le compte'));
    if (computerReads) parts.push(userReads ? `${int(computerReads)}${NBSP}pour le poste` : count(computerReads, 'lecture pour le poste', 'lectures pour le poste'));
    if (none) parts.push(`${int(none)}${NBSP}sans lecture`);
    const list = parts.length > 1 ? `${parts.slice(0, -1).join(', ')} et ${parts[parts.length - 1]}` : parts[0] ?? '';
    let plan = `${count(r.steps.length, 'étape', 'étapes')}${list ? `, dont ${list}` : ''}.`;
    if (privileged) plan += ` ${int(privileged)}${NBSP}${privileged > 1 ? 'demandent' : 'demande'} les droits d’administration du poste.`;
    if (optional) plan += ` ${count(optional, 'étape facultative', 'étapes facultatives')}.`;
    plan += ` Aucune étape ne part seule${NBSP}; aucune n’écrit.`;
    return { id: r.id, title: r.title, symptom: r.symptom, icon: r.icon, added: r.added, plan, steps: r.steps.length, userReads, computerReads, privileged, optional,
      done: steps.filter((s) => s.state.phase === 'read').length, stepList: steps };
  }

  function reading(s, o) {
    const facts = {
      diagnostics: [{ label: 'Ping', value: o.silent ? 'Aucune réponse' : '4 ms', tone: o.silent ? 'alert' : 'ok' }, { label: 'Ports 135, 445', value: o.silent ? 'Fermés' : 'Ouverts', tone: o.silent ? 'alert' : 'ok' }, { label: 'Nom résolu', value: `${o.name.toLowerCase()}.example.local`, tone: 'off' }],
      inventory: [{ label: 'Système', value: 'Windows 11 Entreprise 23H2', tone: 'off' }, { label: 'Mémoire', value: `16${NBSP}Go · 71${NBSP}% utilisés`, tone: 'ok' }, { label: 'Disque C:', value: `${int(o.freePct ?? 40)}${NBSP}% libre sur 238${NBSP}Go`, tone: (o.freePct ?? 40) < 10 ? 'alert' : 'ok' }, { label: 'Dernier démarrage', value: `19/09/2026 à 21:49 (${count(o.uptime ?? 3, 'jour', 'jours')})`, tone: (o.uptime ?? 0) > 30 ? 'warn' : 'off' }, { label: 'Écart d’horloge', value: `12${NBSP}s avec le contrôleur`, tone: 'ok' }],
      lockoutEvents: [{ label: 'Verrouillages', value: '4 en 7 jours', tone: 'alert' }, { label: 'Poste le plus fréquent', value: 'PT-LYO-0064', tone: 'warn' }, { label: 'Émulateur PDC', value: 'dc01.example.local', tone: 'off' }],
    }[s.action] ?? [{ label: 'Lecture', value: 'Faite dans l’aperçu', tone: 'off' }];
    const summary = {
      diagnostics: o.silent ? `Aucune réponse au ping ni sur les ports d’administration${COLON}le poste semble hors réseau.` : 'Le poste répond en 4 ms et ses ports d’administration sont ouverts.',
      inventory: (o.freePct ?? 40) < 10 ? `Disque C presque plein et ${count(o.uptime ?? 3, 'jour', 'jours')} sans redémarrage.` : 'Mémoire, disque et horloge dans les normes.',
      lockoutEvents: `4 verrouillages en 7 jours, le plus souvent depuis PT-LYO-0064${COLON}cherchez une session ou un lecteur qui garde l’ancien mot de passe.`,
    }[s.action] ?? 'Lecture faite dans l’aperçu du navigateur.';
    return { action: s.action, operation: OPS[s.action], label: s.title, readAt: iso(now()), tone: facts.some((f) => f.tone === 'alert') ? 'alert' : 'ok', summary, facts, items: [], more: 0,
      limit: 'Aperçu du navigateur : données fictives, aucune lecture réelle.' };
  }

  // ---------- Operations ----------
  const dnArg = (args, name = 'dn') => requireDistinguishedName(getString(readObject(args, [name]), name), name);
  const known = (dn) => byDn(dn) ?? (() => { throw fail('assistance.subjectUnknown', `Objet introuvable dans l’annuaire${COLON}rien n’a été lu.`); })();
  const lastRead = (dn) => ws.read.get(key(dn)) ?? (() => { throw fail('assistance.notRead', `Lisez d’abord la fiche de cet objet dans l’Assistance${COLON}la capture fige ce qui a été lu, sans nouvelle lecture.`); })();
  const saved = (name, text) => ({ saved: false, path: null, name, folder: null, sha256: hex(32), bytes: text.length, message: `Document préparé, non écrit${COLON}l’aperçu garde tout en mémoire.`, at: iso(now()) });

  return {
    'assistance.overview': async (args) => {
      requireNone(args);
      await sleep(120);
      return { recipes: RECIPES.map((r) => recipeView(r, null, null)), workshop: workshop(), limits: { pins: 24, incidents: 200, ticketReference: 80, captureFields: 29, captureValues: 128, dossierComputers: 500, pseudonymKey: 8 },
        readerAvailable: true, exportsPersistent: false, exportsLabel: `Aperçu du navigateur${COLON}les documents restent en mémoire, rien n’est écrit sur le disque.` };
    },
    'assistance.recipes': (args) => {
      const v = readObject(args, ['user', 'computer']);
      const u = getOptionalString(v, 'user');
      const c = getOptionalString(v, 'computer');
      return { userDn: u, computerDn: c, recipes: RECIPES.map((r) => recipeView(r, u, c)) };
    },
    'assistance.subjects.search': async (args) => {
      const text = getString(readObject(args, ['text']), 'text');
      if (text.length > 100) throw invalid(`${quote('text')} doit faire au plus 100 caractères.`);
      await sleep(80);
      const q = text.trim().toLowerCase();
      return objects.filter((o) => q && `${o.sam} ${o.name} ${o.title ?? ''}`.toLowerCase().includes(q)).slice(0, 20).map(hit);
    },
    'assistance.subjects.suggest': async (args) => {
      requireNone(args);
      await sleep(90);
      return [
        { subject: hit(bySam('c.bernard')), reason: 'Compte verrouillé après 4 échecs' },
        { subject: hit(bySam('m.lefevre')), reason: 'Mot de passe expiré' },
        { subject: hit(objects.find((o) => o.name === 'PC-LYO-0042')), reason: 'Disque C presque plein : 7 % libre' },
        { subject: hit(objects.find((o) => o.name === 'PT-PAR-0118')), reason: 'Aucune réponse au dernier relevé de présence (ping et WMI)' },
      ];
    },
    'assistance.computers.resolve': async (args) => {
      const v = readObject(args, ['names']);
      const names = Array.isArray(v.names) ? v.names.map((n) => String(n).trim()).filter(Boolean) : null;
      if (!names) throw invalid(`${quote('names')} doit être une liste de noms de postes.`);
      await sleep(60);
      const found = names.map((n) => objects.find((o) => o.kind === 'computer' && (o.name.toLowerCase() === n.toLowerCase().replace(/\$$/, '')))).filter(Boolean);
      return { found: [...new Set(found)].map(hit), unknown: names.filter((n) => !found.some((o) => o.name.toLowerCase() === n.toLowerCase().replace(/\$$/, ''))), names: names.length, truncated: false };
    },
    'assistance.subject.read': async (args) => {
      const o = known(dnArg(args));
      await sleep(220);
      const v = view(o);
      ws.read.set(key(o.dn), v);
      return v;
    },
    'assistance.subject.analyse': (args) => lastRead(dnArg(args)),
    'assistance.step.run': async (args) => {
      const v = readObject(args, ['recipe', 'step', 'dn']);
      const r = RECIPES.find((x) => x.id === getString(v, 'recipe')) ?? (() => { throw fail('assistance.recipeUnknown', `Recette inconnue${COLON}rien n’a été lancé.`); })();
      const s = r.steps.find((x) => x.id === getString(v, 'step')) ?? (() => { throw fail('assistance.stepUnknown', `Étape inconnue dans cette recette${COLON}rien n’a été lancé.`); })();
      if (!s.action) throw fail('assistance.stepWithoutRead', `Cette étape ne lit rien${COLON}ouvrez sa vue.`);
      const o = known(requireDistinguishedName(getString(v, 'dn'), 'dn'));
      if (o.kind !== s.subject) throw fail('assistance.subjectMismatch', `Cette étape concerne un ${s.subject === 'user' ? 'compte' : 'poste'}${COLON}choisissez le ${s.subject === 'user' ? 'compte' : 'poste'} concerné. Rien n’a été lancé.`);
      await sleep(700);
      const failed = o.silent && s.subject === 'computer' && s.action !== 'diagnostics';
      ws.launches.set(`${key(o.dn)}|${r.id}|${s.id}`, failed
        ? { at: now(), outcome: 'failed', error: `Le serveur RPC n’est pas disponible (0x800706BA)${COLON}${o.name} ne répond pas.` }
        : { at: now(), outcome: 'read', reading: reading(s, o) });
      if (failed) { ws.incidents.push(incident(0, 'warn', 'Session', 'Transport RPC indisponible', 'RPC_UNAVAILABLE', 'Code ou message RPC indisponible.', 'Vérifiez le chemin réseau.', 'poste', `Assistance · ${s.title} (${o.name}) : RPC indisponible.`)); bump(); }
      const u = s.subject === 'user' ? o.dn : null;
      const c = s.subject === 'computer' ? o.dn : null;
      const order = r.steps.indexOf(s) + 1;
      const sv = stepView(r, s, order, u, c);
      const done = r.steps.filter((x) => x.subject === s.subject && ws.launches.get(`${key(o.dn)}|${r.id}|${x.id}`)?.outcome === 'read').length;
      return { recipe: r.id, step: sv, done, total: r.steps.filter((x) => x.subject === s.subject && x.action).length };
    },
    'assistance.workshop.get': (args) => { requireNone(args); return workshop(); },
    'assistance.workshop.poll': (args) => { requireNone(args); return { revision: ws.revision, session: SESSION, incidents: ws.incidents.length, running: 0, queued: 0 }; },
    'assistance.workshop.reset': (args) => { requireNone(args); Object.assign(ws, { a: null, b: null, pins: [], incidents: [] }); ws.launches.clear(); bump(); return workshop(); },
    'assistance.capture.take': (args) => {
      const v = readObject(args, ['slot', 'dn']);
      const slot = getString(v, 'slot');
      if (slot !== 'a' && slot !== 'b') throw invalid(`${quote('slot')} doit valoir a ou b.`);
      const read = lastRead(requireDistinguishedName(getString(v, 'dn'), 'dn'));
      ws[slot] = { ...read.snapshot, capturedAt: iso(now()) };
      bump();
      return workshop();
    },
    'assistance.capture.swap': (args) => { requireNone(args); [ws.a, ws.b] = [ws.b, ws.a]; bump(); return workshop(); },
    'assistance.capture.clear': (args) => {
      const slot = getOptionalString(readObject(args, ['slot']), 'slot');
      if (slot !== null && slot !== 'a' && slot !== 'b') throw invalid(`${quote('slot')} doit valoir a, b ou null.`);
      if (slot === null || slot === 'a') ws.a = null;
      if (slot === null || slot === 'b') ws.b = null;
      bump();
      return workshop();
    },
    'assistance.capture.export': (args) => {
      const slot = getString(readObject(args, ['slot']), 'slot');
      if (!ws[slot]) throw fail('assistance.slotEmpty', `Cet emplacement est vide${COLON}capturez d’abord une fiche.`);
      return saved(`Domenia-Capture-${slot.toUpperCase()}.json`, JSON.stringify(ws[slot]));
    },
    'assistance.capture.import': () => { throw fail('assistance.captureInvalid', `Capture refusée${COLON}l’aperçu du navigateur ne lit pas de fichier. Rien n’a été chargé.`); },
    'assistance.pin.add': (args) => {
      const read = lastRead(dnArg(args));
      const identity = `guid:${read.card.guid}`;
      ws.pins = ws.pins.filter((p) => p.identity !== identity);
      if (ws.pins.length >= 24) throw fail('assistance.pinsFull', `24 repères sont déjà présents${COLON}retirez-en un avant d’en ajouter un autre.`);
      ws.pins.unshift({ identity, name: read.card.name, kind: read.card.kind, kindLabel: read.card.kindLabel, dn: read.card.dn, scope: SCOPE, pinnedAt: iso(now()) });
      bump();
      return workshop();
    },
    'assistance.pin.remove': (args) => { const id = getString(readObject(args, ['identity']), 'identity'); ws.pins = ws.pins.filter((p) => p.identity !== id); bump(); return workshop(); },
    'assistance.pin.locate': async (args) => {
      const id = getString(readObject(args, ['identity']), 'identity');
      const pin = ws.pins.find((p) => p.identity === id) ?? (() => { throw fail('assistance.pinUnknown', `Repère introuvable${COLON}il a peut-être été retiré ou l’atelier vidé.`); })();
      await sleep(150);
      return { pin, dn: pin.dn, kind: pin.kind, moved: false, message: `${pin.name} est toujours à sa place.` };
    },
    'assistance.incidents.clear': (args) => { requireNone(args); ws.incidents = []; bump(); return workshop(); },
    'assistance.report.preview': async (args) => {
      const v = readObject(args, ['dn', 'ticket', 'template', 'incident', 'pseudonymize', 'key']);
      if (v.pseudonymize === true && String(v.key ?? '').length < 8) throw fail('assistance.keyMissing', `Clé de pseudonymisation absente ou trop courte (8 caractères au moins)${COLON}aucun aperçu en clair n’est produit à la place.`);
      await sleep(80);
      const dn = getOptionalString(v, 'dn');
      const read = dn ? lastRead(dn) : null;
      const lines = ['DOMENIA | DOSSIER SUPPORT', `Généré${COLON}${new Date().toLocaleString('fr-FR')}`, 'Analyse locale : aucune écriture dans l’annuaire.'];
      if (read) lines.push('', 'Fiche observée', `- ${read.card.kindLabel}${COLON}${read.card.name} (${read.card.login})`, `- Chemin${COLON}${read.card.dn}`, ...read.findings.map((f) => `- [${f.levelLabel}] ${f.title}`));
      const text = lines.join('\n');
      return { kind: 'support', ready: true, reason: '', text, sha256: hex(32), lines: lines.length, characters: text.length, pseudonymized: v.pseudonymize === true, map: [], counts: null, excluded: null };
    },
    'assistance.report.export': () => saved('Domenia-Support.html', 'html'),
    'assistance.ticket.preview': async (args) => {
      const v = readObject(args, ['dn', 'sections', 'pseudonymize', 'key']);
      const read = lastRead(requireDistinguishedName(getString(v, 'dn'), 'dn'));
      await sleep(80);
      const text = ['DOMENIA | COMPTE RENDU DE TICKET', `Objet${COLON}${read.card.name}`, '', 'TENTÉ', '- Aucune étape lancée dans l’aperçu.', '', 'LIMITES', 'Un refus n’est pas une absence ; un élément non testé reste inconnu.'].join('\n');
      return { kind: 'ticket', ready: true, reason: '', text, sha256: hex(32), lines: 8, characters: text.length, pseudonymized: v.pseudonymize === true, map: [], counts: { attempted: 0, confirmed: 0, refused: 0, notTested: 3 }, excluded: { otherObject: 0, unlinked: 0 } };
    },
    'assistance.ticket.export': () => saved('Domenia-Ticket.txt', 'txt'),
    'assistance.dossier.prepare': async (args) => {
      const v = readObject(args, ['scope', 'dn', 'ou', 'names', 'sections']);
      const scope = getString(v, 'scope');
      if (!['subject', 'workingOu', 'branch', 'pins', 'list'].includes(scope)) throw invalid(`${quote('scope')} doit valoir subject, workingOu, branch, pins ou list.`);
      await sleep(600);
      const files = ['etat.json', 'postes.json', 'observations.json', 'associations.json', 'requetes.json', 'LISEZMOI.txt', 'manifeste.json', 'SHA256SUMS.txt']
        .map((name, n) => { const bytes = [812, 18_244, 96_310, 4_120, 2_048, 1_302, 2_960, 640][n]; return { name, sha256: hex(32), bytes, size: bytes < 1024 ? `${int(bytes)}${NBSP}octets` : `${(bytes / 1024).toFixed(1).replace('.', ',')}${NBSP}Kio` }; });
      return { saved: false, path: null, name: 'Domenia-Diagnostic-apercu', perimeter: 'Aperçu', truncated: false, unresolved: 0,
        sections: [{ section: 'etat', elements: 1, truncated: false, excludedFields: 0 }, { section: 'postes', elements: 38, truncated: false, excludedFields: 0 }, { section: 'observations', elements: 112, truncated: false, excludedFields: 3 }],
        files, excluded: ['Mots de passe', 'Clés BitLocker', 'Données LAPS (métadonnées comprises)', 'Champs nommés comme des secrets'],
        message: `Dossier hors ligne préparé en mémoire, non écrit dans ce mode (aperçu)${COLON}État 1, Postes 38 et Observations 112. Empreintes dans SHA256SUMS.txt${NBSP}; secrets exclus (liste dans manifeste.json).`, createdAt: iso(now()) };
    },
    'assistance.document.reveal': () => { throw fail('assistance.exportMissing', `Document introuvable dans le dossier des exports${COLON}seuls les documents enregistrés pendant cette session s’ouvrent ici.`); },
    'assistance.engine.state': async (args) => {
      requireNone(args);
      await sleep(90);
      return { mode: 'simulation', modeLabel: 'Simulation', source: 'Annuaire fictif de l’aperçu',
        capabilities: [
          { label: 'Recherche et suggestions', available: true, detail: 'Index local (aperçu), sans accès réseau.' },
          { label: 'Lecture des fiches et des étapes', available: true, detail: `Sur votre geste seulement${COLON}une lecture à la fois par objet, 3 en parallèle au plus.` },
          { label: 'Dossier hors ligne', available: true, detail: 'Données locales seulement, 500 postes au plus.' },
          { label: 'Documents', available: true, detail: `Gardés en mémoire${COLON}rien n’est écrit sur le disque.` },
          { label: 'Reçus d’écriture', available: true, detail: 'En mémoire seulement.' }],
        writes: ['Déverrouillage de compte'], readsRunning: 0, readsQueued: 0, readsLimit: 3, measuresRunning: 0, measuresQueued: 0,
        incidentWarnings: ws.incidents.filter((i) => i.tone === 'warn').length, incidentErrors: ws.incidents.filter((i) => i.tone === 'alert').length,
        journalEntries: 12, captures: (ws.a ? 1 : 0) + (ws.b ? 1 : 0), pins: ws.pins.length, stepsRead: ws.launches.size, receiptsPersistent: false, exportsPersistent: false,
        exportsLabel: `Aperçu du navigateur${COLON}les documents restent en mémoire, rien n’est écrit sur le disque.`, summary: `Aucune lecture en cours${NBSP}; état lu sans aucune sonde réseau.` };
    },
  };
}
