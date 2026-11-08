// Browser preview of the « Audit AD » operations (docs/ops/audit.md): same names, argument checks, result shapes, error
// codes and texts as AuditOperations and AuditService, on a small fixed part of the fictitious example.local directory (the
// accounts, groups, workstations and controllers named by the contract and the scenarios). Read only, nothing leaves the
// page; the reads kept for the local estimates follow the same rule as the engine (the latest request decides the object).
// The helpers of mock.js are handed in, so validation messages stay word for word those of the engine.

/**
 * @param {object} h  Helpers of mock.js: readObject, getString, requireDistinguishedName, requireNone, invalid, fail, quote,
 *   int, count, sleep, fold, getBoolean, sessionInfo, findOu, isRoot, ouItem, NBSP, REF, DOMAIN, ROOT_DN.
 * @returns {Object<string, (args: any) => any>}
 */
export function createAuditOperations(h) {
  const { readObject, getString, requireDistinguishedName, requireNone, invalid, fail, quote, int, count, sleep, fold, getBoolean, sessionInfo, findOu, isRoot, NBSP, REF, DOMAIN, ROOT_DN } = h;
  const COLON = `${NBSP}: `;
  const MIN = 60_000;
  const HOUR = 60 * MIN;
  const DAY = 24 * HOUR;
  const iso = (t) => new Date(t).toISOString().replace(/\.\d{3}Z$/, 'Z');
  const keyOf = (dn) => String(dn).toLowerCase();
  const DOMAIN_SID = 'S-1-5-21-3623811015-3361044348-30300820';
  const DC01 = `DC01.${DOMAIN}`;
  const DC02 = `DC02.${DOMAIN}`;
  const wait = (lo, hi) => sleep(lo + Math.floor(Math.random() * (hi - lo)));
  const PATH = `${NBSP}› `;

  // ---------- Objects of the preview ----------

  const U = (cn, ou, sam, extra = {}) => ({ dn: `CN=${cn},${ou}`, kind: 'user', name: extra.display ?? cn, sam, ...extra });
  const users = `OU=Informatique,OU=Paris,OU=Utilisateurs,${ROOT_DN}`;
  const OBJECTS = [
    U('Julien Martin', users, 'j.martin', { rid: 1104, description: 'Technicien support N2' }),
    U('Camille Bernard', users, 'c.bernard', { rid: 1121 }),
    U('adm-j.martin', `OU=Comptes à privilèges,${ROOT_DN}`, 'adm-j.martin', { rid: 1401, privileged: true }),
    U('svc-web', `OU=Comptes de service,${ROOT_DN}`, 'svc-web', { rid: 1301, description: 'Pool applicatif intranet' }),
    U('svc-annuaire', `OU=Comptes de service,${ROOT_DN}`, 'svc-annuaire', { rid: 1302, description: 'Synchronisation de l’annuaire' }),
    U('Administrateur', `CN=Users,${ROOT_DN}`, 'Administrateur', { rid: 500, privileged: true }),
    { dn: `CN=GG-Support-N2,OU=Sécurité,OU=Groupes,${ROOT_DN}`, kind: 'group', name: 'GG-Support-N2', sam: 'GG-Support-N2', rid: 1201 },
    { dn: `CN=GG-Admins-Postes,OU=Sécurité,OU=Groupes,${ROOT_DN}`, kind: 'group', name: 'GG-Admins-Postes', sam: 'GG-Admins-Postes', rid: 1202, privileged: true },
    { dn: `CN=Admins du domaine,CN=Users,${ROOT_DN}`, kind: 'group', name: 'Admins du domaine', sam: 'Admins du domaine', rid: 512, privileged: true },
    { dn: `CN=Utilisateurs du domaine,CN=Users,${ROOT_DN}`, kind: 'group', name: 'Utilisateurs du domaine', sam: 'Utilisateurs du domaine', rid: 513 },
    ...['PC-PAR-0001', 'PC-PAR-0002', 'PC-PAR-0003', 'PT-PAR-0001', 'PT-PAR-0002', 'PC-LYO-0001'].map((n, i) => ({
      dn: `CN=${n},OU=${n.includes('LYO') ? 'Lyon' : 'Paris'},OU=Postes,${ROOT_DN}`, kind: 'computer', name: n, sam: `${n}$`, rid: 2001 + i, dns: `${n.toLowerCase()}.${DOMAIN}`,
    })),
    { dn: `CN=DC01,OU=Domain Controllers,${ROOT_DN}`, kind: 'computer', name: 'DC01', sam: 'DC01$', rid: 1000, dns: DC01.toLowerCase() },
    { dn: `CN=DC02,OU=Domain Controllers,${ROOT_DN}`, kind: 'computer', name: 'DC02', sam: 'DC02$', rid: 1001, dns: DC02.toLowerCase() },
  ];
  const BY_DN = new Map(OBJECTS.map((o) => [keyOf(o.dn), o]));
  const KIND_LABELS = { user: 'Utilisateur', computer: 'Ordinateur', group: 'Groupe', organizationalUnit: 'Unité d’organisation', domain: 'Domaine', other: 'Objet' };
  const guidOf = (text) => {
    let x = 0x811c9dc5;
    const hex = [];
    for (let k = 0; k < 4; k++) {
      for (const c of `${k}/${text}`) x = Math.imul(x ^ c.charCodeAt(0), 16777619) >>> 0;
      hex.push(x.toString(16).padStart(8, '0'));
    }
    const s = hex.join('');
    return `${s.slice(0, 8)}-${s.slice(8, 12)}-4${s.slice(13, 16)}-a${s.slice(17, 20)}-${s.slice(20, 32)}`;
  };

  function pathOf(dn) {
    const parts = dn.split(/(?<!\\),/).filter((p) => !/^DC=/i.test(p)).map((p) => p.replace(/^[A-Za-z]+=/, '').replace(/\\(.)/g, '$1')).reverse();
    return [DOMAIN, ...parts].join(PATH);
  }

  const REASONS = {
    policy: 'La stratégie de mot de passe se lit pour un compte utilisateur.',
    groups: 'Les appartenances se lisent pour un utilisateur, un ordinateur ou un groupe.',
    gpoLinks: 'Les liens GPO se lisent pour un utilisateur, un ordinateur, une unité d’organisation ou le domaine.',
    gpoApplied: 'Le résultat appliqué se lit sur un ordinateur.',
    machineIdentity: 'L’identité AD, DNS et poste se vérifie pour un ordinateur.',
    relations: 'Les associations concernent un utilisateur ou un ordinateur.',
  };
  function availability(kind) {
    const a = (ok, key) => ({ allowed: ok, reason: ok ? null : REASONS[key] });
    return {
      policy: a(kind === 'user', 'policy'),
      groups: a(['user', 'computer', 'group'].includes(kind), 'groups'),
      acl: a(true),
      gpoLinks: a(['user', 'computer', 'organizationalUnit', 'domain'].includes(kind), 'gpoLinks'),
      gpoApplied: a(kind === 'computer', 'gpoApplied'),
      machineIdentity: a(kind === 'computer', 'machineIdentity'),
      relations: a(kind === 'user' || kind === 'computer', 'relations'),
      comparison: a(true),
    };
  }

  function find(dn) {
    const o = BY_DN.get(keyOf(dn));
    if (o) return o;
    if (isRoot(dn)) return { dn: ROOT_DN, kind: 'domain', name: DOMAIN, sam: null };
    const ou = findOu(dn);
    return ou ? { dn: ou.dn, kind: 'organizationalUnit', name: ou.name, sam: null } : null;
  }
  const view = (o) => ({
    dn: o.dn, kind: o.kind, kindLabel: KIND_LABELS[o.kind], name: o.name, samAccountName: o.sam ?? null, objectGuid: guidOf(o.dn),
    sid: o.rid ? `${DOMAIN_SID}-${o.rid}` : null, dnsHostName: o.dns ?? null, path: pathOf(o.dn), description: o.description ?? null, availability: availability(o.kind),
  });
  function targetOf(dn) {
    const o = find(dn);
    if (!o) throw fail('audit.targetUnknown', `Objet introuvable dans l’annuaire de la session${COLON}rien n’a été lu.`);
    return o;
  }
  function checked(dn, key) {
    const o = targetOf(dn);
    const a = availability(o.kind)[key];
    if (!a.allowed) throw fail('audit.notApplicable', a.reason);
    claim(o.dn);
    return o;
  }
  const dnArg = (args) => requireDistinguishedName(getString(readObject(args, ['dn']), 'dn'), 'dn');

  // Reads kept for the local estimates: the current object only; the latest request decides (AuditService.Claim).
  let slot = { dn: null };
  const claim = (dn) => { if (keyOf(slot.dn ?? '') !== keyOf(dn)) slot = { dn }; return slot; };
  const current = (dn) => (keyOf(slot.dn ?? '') === keyOf(dn) ? slot : null);

  // ---------- Catalogue and analysis ----------

  // [id, category, title, objectKind, severity when found, one, many, source, limit, advice] (AuditFindings.Catalogue)
  const CATALOGUE = [
  ["dcsyncRights", "Délégations", "Droits de réplication (DCSync) hors administrateurs", "other", "critical", "bénéficiaire", "bénéficiaires", "DACL de la racine du domaine : droits étendus « Répliquer les modifications » et « Répliquer toutes les modifications »", "Entrées lues sur la racine seulement ; les contrôleurs, administrateurs et contrôleurs d’entreprise sont attendus et exclus.", "Retirer ces droits sauf besoin documenté (outil de synchronisation d’annuaire) : ils permettent d’extraire tous les secrets du domaine."],
  ["unconstrainedDelegation", "Kerberos", "Délégation non contrainte hors contrôleurs", "computer", "critical", "compte", "comptes", "userAccountControl:1.2.840.113556.1.4.803:=524288, contrôleurs exclus", "Comptes utilisateurs et ordinateurs du domaine, 60 au plus.", "Passer en délégation contrainte ou basée sur la ressource : un compte autorisé ici peut réutiliser le ticket de quiconque s’y connecte."],
  ["krbtgtPassword", "Kerberos", "Mot de passe du compte krbtgt", "user", "high", "jour", "jours", "pwdLastSet du compte krbtgt", "Âge calculé depuis la dernière modification lue ; un changement récent peut ne pas être encore répliqué.", "Changer le mot de passe de krbtgt deux fois, à un intervalle supérieur à la durée de vie des tickets."],
  ["constrainedDelegation", "Kerberos", "Délégation contrainte avec transition de protocole", "user", "high", "compte", "comptes", "msDS-AllowedToDelegateTo renseigné et userAccountControl TRUSTED_TO_AUTH_FOR_DELEGATION", "Comptes du domaine, 60 au plus ; les cibles de délégation sont dans le détail.", "Vérifier que chaque cible est nécessaire : la transition de protocole permet d’obtenir un ticket pour n’importe quel utilisateur."],
  ["asrepRoast", "Kerberos", "Comptes sans pré-authentification Kerberos", "user", "high", "compte", "comptes", "userAccountControl:1.2.840.113556.1.4.803:=4194304", "Comptes utilisateurs du domaine, 60 au plus.", "Réactiver la pré-authentification : sans elle, un attaquant obtient de quoi casser le mot de passe hors ligne (AS-REP roasting)."],
  ["passwordNotRequired", "Mots de passe", "Mot de passe non requis (PASSWD_NOTREQD)", "user", "high", "compte", "comptes", "userAccountControl:1.2.840.113556.1.4.803:=32, comptes actifs", "Comptes utilisateurs actifs du domaine, 60 au plus.", "Retirer l’option et imposer un mot de passe conforme à la stratégie."],
  ["reversibleEncryption", "Mots de passe", "Chiffrement réversible des mots de passe", "user", "high", "compte", "comptes", "pwdProperties du domaine (bit 16) et userAccountControl:1.2.840.113556.1.4.803:=128", "Stratégie du domaine et comptes actifs, 60 au plus.", "Désactiver le chiffrement réversible et faire changer les mots de passe concernés."],
  ["kerberoast", "Kerberos", "Comptes utilisateurs avec SPN (Kerberoasting)", "user", "medium", "compte", "comptes", "(&(objectCategory=person)(objectClass=user)(servicePrincipalName=*))", "Comptes utilisateurs du domaine, 60 au plus ; krbtgt exclu.", "Préférer des comptes de service gérés (gMSA) ou des mots de passe longs et aléatoires ; jamais de SPN sur un compte à privilèges."],
  ["domainPasswordPolicy", "Mots de passe", "Stratégie de mot de passe du domaine", null, "medium", "écart", "écarts", "minPwdLength, lockoutThreshold et pwdProperties de la racine du domaine", "Stratégie du domaine seulement ; les stratégies fines sont dans la section dédiée.", "Viser au moins 12 caractères, la complexité et un seuil de verrouillage."],
  ["privilegedNotProtected", "Comptes à privilèges", "Comptes à privilèges hors de « Protected Users »", "user", "medium", "compte", "comptes", "Membres actifs des groupes privilégiés absents du groupe Protected Users (RID 525)", "Appartenances directes et imbriquées lues dans la copie de l’analyse ; krbtgt exclu.", "Ajouter les comptes d’administration à Protected Users après avoir vérifié leurs usages (pas de NTLM, pas de délégation)."],
  ["passwordNeverExpires", "Mots de passe", "Mots de passe sans expiration", "user", "medium", "compte", "comptes", "userAccountControl:1.2.840.113556.1.4.803:=65536, comptes actifs", "Comptes utilisateurs actifs, 60 au plus.", "Réserver l’option aux comptes de service documentés, de préférence des gMSA."],
  ["machineAccountQuota", "Délégations", "Quota de jonction de postes (ms-DS-MachineAccountQuota)", null, "medium", "poste par utilisateur", "postes par utilisateur", "ms-DS-MachineAccountQuota de la racine du domaine", "Valeur du domaine ; une délégation de jonction sur une OU est une autre voie, non lue ici.", "Mettre le quota à 0 et déléguer la jonction à un groupe dédié."],
  ["staleUsers", "Hygiène des comptes", "Comptes actifs sans connexion depuis 90 jours", "user", "medium", "compte", "comptes", "lastLogonTimestamp antérieur à 90 jours, comptes actifs", "Date approximative (réplication différée de 9 à 14 jours) ; une date ancienne ne suffit pas à déclarer un compte supprimable.", "Désactiver après vérification auprès du responsable, puis supprimer selon la procédure."],
  ["lapsMissing", "Postes", "Postes sans mot de passe LAPS", "computer", "medium", "poste", "postes", "Postes actifs sans msLAPS-PasswordExpirationTime ni ms-Mcs-AdmPwdExpirationTime", "Postes actifs du domaine ; seules les dates d’expiration sont lues, jamais un mot de passe.", "Appliquer la stratégie LAPS aux OU concernées et vérifier le relevé sur ces postes."],
  ["recycleBin", "Annuaire", "Corbeille Active Directory désactivée", null, "medium", "écart", "écarts", "msDS-EnabledFeature de CN=Partitions", "Fonctionnalité de la forêt.", "Activer la corbeille (irréversible, sans impact sur les objets existants)."],
  ["adminCountOrphans", "Comptes à privilèges", "adminCount résiduel (anciens comptes à privilèges)", "user", "low", "compte", "comptes", "adminCount=1 sans appartenance actuelle à un groupe protégé", "Appartenances lues dans la copie de l’analyse ; l’héritage reste désactivé sur ces comptes.", "Remettre adminCount à 0 et réactiver l’héritage des autorisations après vérification."],
  ["builtinAdminActive", "Comptes à privilèges", "Compte Administrateur intégré utilisé", "user", "low", "compte", "comptes", "Compte RID 500 actif avec une connexion récente", "lastLogonTimestamp approximatif.", "Utiliser des comptes d’administration nominatifs et garder le compte intégré pour le secours."],
  ["neverLoggedUsers", "Hygiène des comptes", "Comptes actifs jamais utilisés", "user", "low", "compte", "comptes", "Comptes actifs sans lastLogonTimestamp", "Comptes créés récemment compris.", "Vérifier l’arrivée prévue ; désactiver les comptes sans usage."],
  ["staleComputers", "Postes", "Postes actifs sans connexion depuis 90 jours", "computer", "low", "poste", "postes", "lastLogonTimestamp antérieur à 90 jours ou absent, postes actifs", "Date approximative ; un poste rangé ou en réparation est aussi concerné.", "Vérifier puis désactiver et déplacer en quarantaine."],
  ["lapsExpired", "Postes", "Mots de passe LAPS expirés", "computer", "low", "poste", "postes", "msLAPS-PasswordExpirationTime dépassé", "Le poste renouvelle son mot de passe à sa prochaine connexion au domaine.", "Vérifier que ces postes joignent encore le domaine."],
  ["disabledInGroups", "Hygiène des comptes", "Comptes désactivés encore membres de groupes", "user", "low", "compte", "comptes", "Comptes désactivés avec memberOf non vide (hors groupe principal)", "Appartenances directes seulement.", "Retirer les appartenances à la sortie, selon la procédure de départ."],
  ["privilegedMembers", "Comptes à privilèges", "Membres des groupes privilégiés", "user", "info", "membre", "membres", "Membres directs et imbriqués d’Admins du domaine, Administrateurs, Administrateurs de l’entreprise et du schéma, opérateurs", "Groupes intégrés du domaine ; les délégations sur des OU ne sont pas comptées ici.", "Garder ces groupes aussi petits que possible et revoir leur composition régulièrement."],
  ["lockedAccounts", "Hygiène des comptes", "Comptes verrouillés", "user", "info", "compte", "comptes", "État calculé par le contrôleur (msDS-User-Account-Control-Computed, bit 0x10)", "Un lockoutTime non nul sans cet état ne prouve pas un verrouillage actuel.", "Vérifier l’identité du demandeur avant tout déverrouillage (écran Comptes)."],
  ["disabledAccounts", "Hygiène des comptes", "Comptes désactivés", "user", "info", "compte", "comptes", "userAccountControl:1.2.840.113556.1.4.803:=2", "Comptes utilisateurs du domaine, 200 au plus.", "Supprimer après la durée de conservation prévue."],
  ["trusts", "Annuaire", "Approbations de domaine", "domain", "info", "approbation", "approbations", "(objectClass=trustedDomain) sous CN=System", "Approbations déclarées dans ce domaine ; l’état des canaux n’est pas testé.", "Vérifier la nécessité et le filtrage des SID de chaque approbation."]
  ];
  const SEVERITY_LABELS = { critical: 'Critique', high: 'Élevée', medium: 'Moyenne', low: 'Faible', info: 'Information' };
  const SEVERITY_TONES = { critical: 'alert', high: 'alert', medium: 'warn', low: 'info', info: 'off' };
  const WEIGHTS = { critical: 15, high: 6, medium: 3, low: 1, info: 0 };
  const ORDER = ['critical', 'high', 'medium', 'low', 'info'];

  // Figures of the default seed (docs/ops/audit.md § 10); names of the objects named by each finding.
  const people = ['Sophie Laurent', 'Thomas Petit', 'Nadia Moreau', 'Lucas Garcia', 'Emma Roux', 'Hugo Fournier', 'Léa Girard', 'Nathan Bonnet', 'Chloé Dupont', 'Louis Lambert', 'Inès Fontaine', 'Paul Rousseau', 'Manon Vincent', 'Jules Muller', 'Sarah Lefèvre', 'Adam Mercier'];
  const FOUND = {
    dcsyncRights: { total: 1, names: ['svc-annuaire'], detail: 'Répliquer toutes les modifications de l’annuaire sur la racine' },
    unconstrainedDelegation: { total: 0 },
    krbtgtPassword: { value: 1461, text: `Mot de passe de krbtgt inchangé depuis ${int(1461)} jours` },
    constrainedDelegation: { total: 1, names: ['svc-web'], detail: 'Vers HTTP/intranet.example.local, avec transition de protocole' },
    asrepRoast: { total: 0 },
    passwordNotRequired: { total: 0 },
    reversibleEncryption: { total: 0 },
    kerberoast: { total: 5, names: ['svc-web', 'svc-sql', 'svc-sauvegarde', 'svc-impression', 'svc-annuaire'] },
    domainPasswordPolicy: { value: 0, text: 'Longueur minimale 12, verrouillage après 5 essais' },
    privilegedNotProtected: { total: 1, names: ['Administrateur'] },
    passwordNeverExpires: { total: 16, names: people },
    machineAccountQuota: { value: 10, text: 'ms-DS-MachineAccountQuota vaut 10' },
    staleUsers: { total: 9, names: people.slice(3, 12) },
    lapsMissing: { total: 23, names: Array.from({ length: 23 }, (_, i) => `PC-${['PAR', 'LYO', 'MRS'][i % 3]}-${String(140 + i).padStart(4, '0')}`), kind: 'computer' },
    recycleBin: { value: 0, text: 'Corbeille Active Directory activée' },
    adminCountOrphans: { total: 4, names: ['adm-c.bernard', 'adm-t.petit', 'adm-n.moreau', 'adm-l.garcia'] },
    builtinAdminActive: { total: 0 },
    neverLoggedUsers: { total: 3, names: people.slice(13) },
    staleComputers: { total: 11, names: Array.from({ length: 11 }, (_, i) => `PC-PAR-${String(300 + i).padStart(4, '0')}`), kind: 'computer' },
    lapsExpired: { total: 6, names: Array.from({ length: 6 }, (_, i) => `PT-LYO-${String(20 + i).padStart(4, '0')}`), kind: 'computer' },
    disabledInGroups: { total: 5, names: people.slice(0, 5) },
    privilegedMembers: { total: 9, names: ['Administrateur', 'adm-j.martin', 'adm-c.bernard', 'adm-t.petit', 'adm-n.moreau', 'adm-l.garcia', 'GG-Admins-Postes', 'GG-Admins-Serveurs', 'svc-annuaire'] },
    lockedAccounts: { total: 7, names: people.slice(5, 12) },
    disabledAccounts: { total: 72, names: Array.from({ length: 72 }, (_, i) => `${people[i % people.length]} (${i + 1})`) },
    trusts: { total: 1, names: ['partenaire.local'], kind: 'domain' },
  };

  function grade(id, f) {
    const sev = CATALOGUE.find((c) => c[0] === id)[4];
    if (id === 'krbtgtPassword') return f.value > 365 * 3 ? 'high' : f.value > 365 ? 'medium' : f.value > 180 ? 'low' : null;
    if (id === 'machineAccountQuota') return f.value > 0 ? 'medium' : null;
    if (id === 'domainPasswordPolicy' || id === 'recycleBin') return f.value > 0 ? sev : null;
    return f.total > 0 ? sev : null;
  }

  let lastOverview = null;
  function findings(previous) {
    const list = CATALOGUE.map(([id, category, title, objectKind, sev, one, many, source, limit, advice]) => {
      const f = FOUND[id];
      const severity = grade(id, f);
      const passed = severity === null;
      const scalar = f.value !== undefined;
      const n = scalar ? f.value : f.total;
      const before = previous?.findings.find((x) => x.id === id);
      return {
        id, severity: passed ? 'info' : severity, severityLabel: passed ? 'Sans écart' : SEVERITY_LABELS[severity], tone: passed ? 'ok' : SEVERITY_TONES[severity],
        category, title,
        summary: f.text ? `${f.text}${passed ? `${NBSP}: sans écart.` : '.'}` : passed ? `Aucun ${one} concerné.` : `${count(n, one, many)} concerné${n > 1 ? 's' : ''}.`,
        count: n, countLabel: count(n, one, many), passed, state: 'read', source, limit, advice, objectKind,
        explorable: !scalar && (f.names?.length ?? 0) > 0, truncated: false, delta: before ? n - before.count : null,
        examples: !passed && f.names ? f.names.slice(0, 3) : [],
      };
    });
    const rank = (f) => (f.passed ? 1 : 0);
    return list.sort((a, b) => rank(a) - rank(b) || ORDER.indexOf(a.severity) - ORDER.indexOf(b.severity) || CATALOGUE.findIndex((c) => c[0] === a.id) - CATALOGUE.findIndex((c) => c[0] === b.id));
  }

  function sections() {
    const item = (label, value, tone = null) => ({ label, value, tone });
    const s = (id, title, icon, items, message = null) => ({ id, title, icon, state: 'read', stateLabel: 'Lu', tone: 'ok', message, items });
    return [
      s('directory', 'Annuaire', 'database', [item('Contexte par défaut', ROOT_DN), item('Contrôleur interrogé', DC01), item('Niveau fonctionnel du domaine', 'Windows Server 2016'), item('Niveau fonctionnel de la forêt', 'Windows Server 2016'), item('USN le plus élevé', int(1284733))]),
      s('fsmo', 'Rôles FSMO', 'key', [item('Émulateur PDC', DC01), item('Maître RID', DC01), item('Maître d’infrastructure', DC01), item('Maître de schéma', DC01), item('Maître d’attribution de noms', DC01), item('RID restants', int(1072641843))]),
      s('passwordPolicy', 'Stratégie de mot de passe', 'lock', [item('Longueur minimale', '12 caractères'), item('Historique', '24 mots de passe'), item('Durée maximale', '90 jours'), item('Verrouillage', 'Après 5 essais, 30 min')]),
      s('fineGrained', 'Stratégies affinées', 'layers', [item('PSO-Comptes-a-privileges', 'Priorité 10 · 16 caractères'), item('PSO-Comptes-de-service', 'Priorité 20 · 24 caractères')]),
      s('recycleBin', 'Corbeille AD', 'trash', [item('État', 'Activée', 'ok'), item('Objets supprimés lus', '12')]),
      s('controllers', 'Contrôleurs', 'server', [item('DC01', `Paris · Windows Server 2022`), item('DC02', `Lyon · Windows Server 2022`)]),
      s('sites', 'Sites et sous-réseaux', 'domain', [item('Sites', '5'), item('Sous-réseaux', '11')]),
      s('trusts', 'Approbations', 'link', [item('partenaire.local', 'Sortante · forêt', 'warn')]),
      s('gpo', 'Stratégies de groupe', 'layers', [item('GPO lues', '16'), item('Modifiées sous 30 jours', '3')]),
      s('privilegedGroups', 'Groupes privilégiés', 'shield', [item('Admins du domaine', '3 membres'), item('Administrateurs de l’entreprise', '1 membre'), item('Administrateurs du schéma', '0 membre'), item('Opérateurs de compte', '2 membres')]),
      s('watchlist', 'Comptes à surveiller', 'eye', [item('Désactivés', '72'), item('Sans expiration du mot de passe', '16', 'warn'), item('Avec SPN', '5', 'warn'), item('krbtgt', `Inchangé depuis ${int(1461)} jours`, 'alert')]),
    ];
  }

  async function overview(args) {
    requireNone(args);
    await wait(700, 1400);
    const list = findings(lastOverview);
    const counted = list.filter((f) => !f.passed);
    const counts = { critical: 0, high: 0, medium: 0, low: 0, info: 0, passed: list.length - counted.length };
    counted.forEach((f) => { counts[f.severity] += 1; });
    const value = Math.max(0, 100 - counted.reduce((sum, f) => sum + WEIGHTS[f.severity], 0));
    const [tone, label] = value >= 85 ? ['ok', 'Bon'] : value >= 65 ? ['info', 'Correct'] : value >= 40 ? ['warn', 'À améliorer'] : ['alert', 'Préoccupant'];
    const total = counted.length;
    const plural = (n, one, many) => count(n, one, many);
    const view = {
      readAt: iso(Date.now()), controller: DC01, durationMs: 1180,
      score: { value, tone, label, detail: 'Indicatif : 100 moins 15 par constat critique, 6 par élevé, 3 par moyen, 1 par faible.' },
      counts, findings: list, sections: sections(), refused: 0, anomalies: 0,
      summary: `Analyse de ${DC01}${COLON}${plural(total, 'constat', 'constats')} (${[['critical', 'critique', 'critiques'], ['high', 'élevé', 'élevés'], ['medium', 'moyen', 'moyens'], ['low', 'faible', 'faibles'], ['info', 'information', 'informations']].map(([k, one, many]) => plural(counts[k], one, many)).join(', ')}), ${plural(counts.passed, 'contrôle sans écart', 'contrôles sans écart')}, 11 sections, 0 refus. Lecture seule${COLON}l’annuaire n’est jamais compté en entier.`,
      previous: lastOverview ? { readAt: lastOverview.readAt, score: lastOverview.score.value, delta: value - lastOverview.score.value, label: value === lastOverview.score.value ? 'Score inchangé depuis la vue précédente' : `${value > lastOverview.score.value ? 'En hausse' : 'En baisse'} de ${count(Math.abs(value - lastOverview.score.value), 'point', 'points')} depuis la vue précédente` } : null,
    };
    lastOverview = view;
    return view;
  }

  function catalogue(args) {
    requireNone(args);
    return CATALOGUE.map(([id, category, title, , sev, , , source, , advice]) => ({ id, category, title, severity: sev, severityLabel: SEVERITY_LABELS[sev], tone: SEVERITY_TONES[sev], source, advice }));
  }

  function findingObjects(args) {
    const id = getString(readObject(args, ['id']), 'id');
    if (id.length === 0 || id.length > 64) throw invalid(`${quote('id')} doit être un identifiant de constat.`);
    if (!lastOverview) throw fail('audit.overviewNotRead', `Analysez d’abord le domaine${COLON}l’exploration montre seulement les objets lus par l’analyse, sans relecture.`);
    const finding = lastOverview.findings.find((f) => f.id === id);
    if (!finding) throw fail('audit.findingUnknown', `Constat inconnu${COLON}rien n’a été lu.`);
    const f = FOUND[id];
    const kind = f.kind ?? (finding.objectKind === 'computer' ? 'computer' : 'user');
    const rows = (f.names ?? []).map((name, i) => {
      const known = OBJECTS.find((o) => o.name === name || o.sam === name);
      const container = kind === 'computer' ? `Postes${PATH}${name.includes('LYO') ? 'Lyon' : name.includes('MRS') ? 'Marseille' : 'Paris'}` : kind === 'domain' ? 'Système' : `Utilisateurs${PATH}Paris`;
      return {
        dn: known?.dn ?? `CN=${name},${kind === 'computer' ? `OU=Paris,OU=Postes,${ROOT_DN}` : `OU=Commercial,OU=Paris,OU=Utilisateurs,${ROOT_DN}`}`,
        name, kind, kindLabel: KIND_LABELS[kind], samAccountName: known?.sam ?? (kind === 'computer' ? `${name}$` : null), enabled: id !== 'disabledAccounts' && id !== 'disabledInGroups',
        lastLogon: id === 'neverLoggedUsers' ? null : iso(REF - (20 + i * 9) * DAY), passwordLastSet: iso(REF - (200 + i * 13) * DAY), detail: id === 'dcsyncRights' || id === 'constrainedDelegation' ? f.detail : null, container,
      };
    });
    return {
      id, title: finding.title, severity: finding.severity, severityLabel: finding.severityLabel, total: rows.length, shown: rows.length, truncated: false, limit: 500, readAt: lastOverview.readAt,
      summary: `${count(rows.length, 'objet lu', 'objets lus')} par l’analyse. Exploration sans relecture${COLON}ces objets sont ceux de la dernière analyse.`, rows,
    };
  }

  async function localTotals(args) {
    requireNone(args);
    await wait(40, 120);
    const types = [['user', 'Utilisateur', 1258, 72], ['computer', 'Ordinateur', 454, 13], ['group', 'Groupe', 75, 0], ['organizationalUnit', 'OU', 39, 0], ['container', 'Conteneur', 3, 0]]
      .map(([type, label, c, disabled]) => ({ type, label, count: c, disabled }));
    return {
      state: 'read', stateLabel: 'Lue', lastSyncAt: iso(REF - 3 * HOUR), complete: true, simulated: true, total: types.reduce((s, t) => s + t.count, 0), types,
      summary: `Copie locale fictive de l’annuaire en mémoire${COLON}aucune base locale n’est ouverte en simulation.`,
    };
  }

  // ---------- Controllers ----------

  const CONTROLLERS = [
    { dnsName: DC01, name: 'DC01', site: 'Paris', operatingSystem: 'Windows Server 2022 Datacenter', roles: ['Émulateur PDC'], pdc: true, readOnly: false, dn: `CN=DC01,OU=Domain Controllers,${ROOT_DN}` },
    { dnsName: DC02, name: 'DC02', site: 'Lyon', operatingSystem: 'Windows Server 2022 Datacenter', roles: [], pdc: false, readOnly: false, dn: `CN=DC02,OU=Domain Controllers,${ROOT_DN}` },
  ];

  async function dcList(args) {
    requireNone(args);
    await wait(150, 400);
    return { controllers: CONTROLLERS, pdc: DC01, truncated: false, summary: `2 contrôleurs lus, émulateur PDC${COLON}${DC01}. Choisissez-en jusqu’à 10, puis lancez le diagnostic.`, readAt: iso(Date.now()) };
  }

  /** « controllers »: same checks as the bridge then AuditControllerRules (RequireControllers, RequireKnown). */
  function chosen(values) {
    const raw = values.controllers;
    if (!Array.isArray(raw) || raw.length > 100 || raw.some((x) => typeof x !== 'string' || x.length > 254)) throw invalid(`${quote('controllers')} doit être un tableau de noms de contrôleurs.`);
    const list = raw.map((x) => x.trim()).filter(Boolean).filter((x, i, all) => all.findIndex((y) => keyOf(y) === keyOf(x)) === i);
    if (!list.length) throw fail('audit.controllersInvalid', 'Choisissez au moins un contrôleur dans la liste.');
    if (list.length > 10) throw fail('audit.controllersInvalid', `Diagnostic borné à 10 contrôleurs${COLON}${int(list.length)} sont choisis.`);
    if (list.some((n) => !/^[A-Za-z0-9][A-Za-z0-9.-]{0,253}$/.test(n))) throw fail('audit.controllersInvalid', `Nom de contrôleur invalide${COLON}aucune lecture.`);
    return list.map((n) => {
      const dc = CONTROLLERS.find((c) => keyOf(c.dnsName) === keyOf(n) || keyOf(c.name) === keyOf(n));
      if (!dc) throw fail('audit.controllersInvalid', `${quote(n.length > 80 ? `${n.slice(0, 80)}…` : n)} n’est pas un contrôleur de la liste du domaine${COLON}aucune lecture. Relisez la liste des contrôleurs.`);
      return dc.dnsName;
    }).filter((v, i, a) => a.indexOf(v) === i);
  }

  async function dcProbe(args) {
    const dcs = chosen(readObject(args, ['controllers']));
    await wait(500, 1100);
    const at = Date.now();
    const rows = dcs.map((dc) => {
      const bad = dc === DC02;
      return {
        controller: dc, verdict: bad ? 'check' : 'clear', verdictLabel: bad ? 'À vérifier' : 'Sans écart', tone: bad ? 'warn' : 'ok', ldap: true, kerberos: true,
        reach: 'Oui (LDAP 389, Kerberos 88)', time: bad ? 'Écart de 2 s avec ce poste' : 'Écart de 0 s avec ce poste', skewSeconds: bad ? 2 : 0, synchronized: 'Oui',
        replication: bad ? '1 lien en échec sur 5' : '5 liens sans échec', failures: bad ? 3 : 0, dns: 'Présent dans les SRV _ldap et _kerberos',
        reasons: bad ? ['Réplication entrante en échec depuis 26 h (ForestDnsZones, partenaire DC01).'] : [], detail: bad ? 'Réplication à vérifier.' : 'Aucun écart constaté.',
      };
    });
    const partitions = [ROOT_DN, `CN=Configuration,${ROOT_DN}`, `CN=Schema,CN=Configuration,${ROOT_DN}`, `DC=DomainDnsZones,${ROOT_DN}`, `DC=ForestDnsZones,${ROOT_DN}`];
    const neighbors = dcs.flatMap((dc) => partitions.map((p) => {
      const fails = dc === DC02 && p.startsWith('DC=ForestDnsZones');
      return {
        controller: dc, partner: dc === DC01 ? 'DC02' : 'DC01', partition: p, lastSuccess: iso(at - (fails ? 26 * HOUR : 12 * MIN)), lastSuccessLabel: fails ? 'il y a 26 h' : 'il y a 12 min',
        lastAttempt: iso(at - 4 * MIN), lastAttemptLabel: 'il y a 4 min', result: fails ? '1722 (serveur RPC non disponible)' : '0 (succès)', failures: fails ? 3 : 0, never: false, tone: fails ? 'warn' : 'ok',
      };
    }));
    const fact = (label, value, state = 'observed', source = null, limit = null) => ({ label, value, state, stateLabel: state === 'observed' ? 'Constaté' : 'Estimé', source, limit, id: null });
    return {
      rows, neighbors,
      facts: [fact('Enregistrements SRV _ldap._tcp.dc._msdcs', `${DC01}, ${DC02}`, 'observed', 'DNS'), fact('Écart d’heure maximal', '2 s', 'estimated', 'RootDSE currentTime', 'Seuil de 300 s.')],
      summary: `${count(rows.length, 'contrôleur diagnostiqué', 'contrôleurs diagnostiqués')}${COLON}${count(rows.filter((r) => r.verdict === 'check').length, 'à vérifier', 'à vérifier')}.`, readAt: iso(at),
    };
  }

  async function dcServices(args) {
    const dcs = chosen(readObject(args, ['controllers']));
    await wait(600, 1300);
    const rows = dcs.flatMap((dc) => ['NTDS', 'Netlogon', 'Kdc', 'W32Time', 'ADWS', 'DNS', 'DFSR', 'NtFrs'].map((service) => {
      const stopped = dc === DC02 && service === 'ADWS';
      if (service === 'NtFrs') return { controller: dc, service, state: 'Absent', startMode: '—', finding: 'Non utilisé : DFSR réplique SYSVOL', tone: 'ok' };
      return { controller: dc, service, state: stopped ? 'Arrêté' : 'En cours', startMode: 'Automatique', finding: stopped ? `Non démarré${COLON}à vérifier` : 'Conforme', tone: stopped ? 'warn' : 'ok' };
    }));
    return { rows, skipped: 0, budgetSeconds: 60 + 25 * dcs.length, summary: `Services de ${count(dcs.length, 'contrôleur', 'contrôleurs')} lus par CIM${COLON}${count(rows.filter((r) => r.tone === 'warn').length, 'service à vérifier', 'services à vérifier')}. Aucun service démarré ni arrêté.`, readAt: iso(Date.now()) };
  }

  async function dcCompare(args) {
    const values = readObject(args, ['dn', 'controllers']);
    const dn = requireDistinguishedName(getString(values, 'dn'), 'dn');
    const dcs = chosen(values);
    const o = targetOf(dn);
    await wait(400, 900);
    const attrs = [['displayName', o.name], ['description', o.description ?? ''], ['userAccountControl', '512'], ['memberOf', o.kind === 'user' ? 'GG-Support-N2' : '']];
    const rows = attrs.map(([attribute, value]) => ({
      attribute, identical: !(attribute === 'description' && dcs.length > 1),
      values: dcs.map((dc, i) => ({ controller: dc, value: attribute === 'description' && i > 0 ? `${value} (ancienne)` : value, version: attribute === 'description' ? 3 - i : 1, changedAt: iso(REF - (attribute === 'description' ? (i ? 3 : 1) : 120) * DAY), origin: 'DC01' })),
    }));
    const differences = rows.filter((r) => !r.identical).length;
    return {
      dn: o.dn, name: o.name, controllers: dcs, rows, differences, comparable: dcs.length > 1, notRead: [],
      note: 'Les USN, locaux à chaque contrôleur, ne sont jamais comparés.', summary: differences ? `${count(differences, 'attribut diffère', 'attributs diffèrent')} entre les contrôleurs.` : 'Valeurs identiques sur les contrôleurs lus.', readAt: iso(Date.now()),
    };
  }

  // ---------- Target, search, suggestions ----------

  function target(args) {
    const o = targetOf(dnArg(args));
    claim(o.dn);
    return view(o);
  }

  function search(args) {
    const text = getString(readObject(args, ['text']), 'text');
    if (text.length > 100) throw invalid(`${quote('text')} doit faire au plus ${int(100)} caractères.`);
    const needle = fold(text.trim());
    if (!needle) return [];
    const rank = (o) => {
      const keys = [o.name, o.sam ?? '', o.dns ?? ''].map(fold);
      return keys.includes(needle) ? 0 : keys.some((k) => k.startsWith(needle)) ? 1 : keys.some((k) => k.includes(needle)) ? 2 : 9;
    };
    return OBJECTS.map((o) => ({ o, r: rank(o) })).filter((x) => x.r < 9).sort((a, b) => a.r - b.r || a.o.name.localeCompare(b.o.name, 'fr')).slice(0, 20).map((x) => view(x.o));
  }

  function suggestions(args) {
    requireNone(args);
    const s = sessionInfo();
    const out = [];
    const add = (id, dn, label, detail) => {
      const o = dn ? find(dn) : null;
      if (o && !out.some((x) => keyOf(x.target.dn) === keyOf(o.dn))) out.push({ id, label, detail: detail ?? o.name, target: view(o) });
    };
    add('account', s.account.dn, 'Compte de la session', s.account.login);
    if (s.scope?.dn && !isRoot(s.scope.dn)) add('scope', s.scope.dn, 'OU de travail', s.scope.label);
    add('root', ROOT_DN, 'Racine du domaine', DOMAIN);
    const admins = OBJECTS.find((o) => o.rid === 512);
    add('domainAdmins', admins.dn, admins.name, 'Groupe privilégié (RID 512)');
    return out;
  }

  // ---------- Object reads ----------

  const fact = (label, value, state = 'observed', source = null, limit = null, id = null) => ({
    label, value, state, stateLabel: { observed: 'Constaté', estimated: 'Estimé', refused: 'Refusé', unavailable: 'Indisponible', unknown: 'Inconnu' }[state], source, limit, id,
  });

  async function policy(args) {
    const o = checked(dnArg(args), 'policy');
    await wait(200, 500);
    const pso = o.privileged || o.sam === 'j.martin' ? 'PSO-Comptes-a-privileges' : o.sam.startsWith('svc-') ? 'PSO-Comptes-de-service' : null;
    const expires = REF + (pso ? 41 : 63) * DAY;
    return {
      dn: o.dn, state: pso ? 'applies' : 'none', policyKnown: true,
      summary: pso ? `Stratégie fine ${pso} appliquée (msDS-ResultantPSO).` : 'Aucune stratégie fine ne vise ce compte : la stratégie du domaine s’applique.',
      facts: [
        fact('Stratégie appliquée', pso ?? 'Stratégie du domaine', 'observed', 'msDS-ResultantPSO'),
        fact('Longueur minimale', pso ? '16 caractères' : '12 caractères', 'observed', pso ? pso : 'Racine du domaine'),
        fact('Durée maximale', pso ? '60 jours' : '90 jours', 'observed'),
        fact('Expiration du mot de passe', new Date(expires).toLocaleDateString('fr-FR'), 'observed', 'msDS-UserPasswordExpiryTimeComputed', null, 'expiry'),
      ],
      expiresAt: iso(expires), controller: DC01, readAt: iso(Date.now()),
    };
  }

  const GROUPS = {
    support: OBJECTS.find((x) => x.name === 'GG-Support-N2'),
    admins: OBJECTS.find((x) => x.name === 'GG-Admins-Postes'),
    domainUsers: OBJECTS.find((x) => x.rid === 513),
  };

  async function groups(args) {
    const o = checked(dnArg(args), 'groups');
    const claimed = slot;
    await wait(250, 650);
    const rows = o.kind === 'user' && !o.privileged ? [
      { dn: GROUPS.support.dn, name: GROUPS.support.name, depth: 1, via: 'Appartenance directe', path: [o.name, GROUPS.support.name], state: 'Lu', tone: 'ok', cycle: false, privileged: false },
      { dn: GROUPS.admins.dn, name: GROUPS.admins.name, depth: 2, via: `Par ${GROUPS.support.name}`, path: [o.name, GROUPS.support.name, GROUPS.admins.name], state: 'Lu', tone: 'ok', cycle: false, privileged: true },
    ] : [];
    const node = (x, depth, kind, privileged = false) => ({ id: keyOf(x.dn), label: x.name, depth, kind, privileged, cycle: false, unread: false });
    const nodes = [node(o, 0, 'start'), ...rows.map((r) => ({ id: keyOf(r.dn), label: r.name, depth: r.depth, kind: 'group', privileged: r.privileged, cycle: false, unread: false })), node(GROUPS.domainUsers, 1, 'primary')];
    const edges = [...rows.map((r, i) => ({ from: i === 0 ? keyOf(o.dn) : keyOf(rows[i - 1].dn), to: keyOf(r.dn), cycle: false })), { from: keyOf(o.dn), to: keyOf(GROUPS.domainUsers.dn), cycle: false }];
    const read = {
      dn: o.dn, rows, cycles: [], unread: [], primaryGroup: { dn: GROUPS.domainUsers.dn, name: GROUPS.domainUsers.name, sid: `${DOMAIN_SID}-513`, text: 'Groupe principal (primaryGroupID 513), absent de memberOf.' },
      truncated: false, direct: rows.filter((r) => r.depth === 1).length, nested: rows.filter((r) => r.depth > 1).length, maxDepth: rows.length ? 2 : 0, privileged: rows.filter((r) => r.privileged).length,
      summary: `${count(rows.length, 'groupe lu', 'groupes lus')}, aucun cycle. Une lecture bornée ne prouve jamais une absence.`, graph: { nodes, edges }, controller: DC01, readAt: iso(Date.now()), elapsedMs: 182,
    };
    if (slot === claimed) claimed.groups = read;
    return read;
  }

  function explain(read, groupDn, confirmed) {
    const row = read.rows.find((r) => keyOf(r.dn) === keyOf(groupDn));
    const primary = keyOf(read.primaryGroup.dn) === keyOf(groupDn);
    const name = row?.name ?? (primary ? read.primaryGroup.name : groupDn.split(',')[0].replace(/^CN=/i, ''));
    const member = row || primary ? true : null;
    const text = row ? `Membre par ${row.path.slice(1).join(' → ')}.` : primary ? 'Membre par le groupe principal (primaryGroupID).' : `Appartenance non trouvée dans les groupes lus${COLON}une lecture bornée ne prouve pas une absence.`;
    return {
      dn: read.dn, groupDn, groupName: name, member, certain: Boolean(row || primary), path: row?.path ?? (primary ? [read.rows[0]?.path[0] ?? '', name] : []),
      text: confirmed ? `${text}\nAppartenance ${member ? 'confirmée par le contrôleur' : 'non confirmée par le contrôleur'} (règle LDAP_MATCHING_RULE_IN_CHAIN).` : text, confirmed, error: null,
    };
  }
  const groupArgs = (args) => {
    const values = readObject(args, ['dn', 'groupDn']);
    return [requireDistinguishedName(getString(values, 'dn'), 'dn'), requireDistinguishedName(getString(values, 'groupDn'), 'groupDn')];
  };
  const groupsOf = (dn) => current(dn)?.groups ?? (() => { throw fail('audit.groupsNotRead', 'Lisez d’abord les appartenances de cet objet, puis choisissez un groupe.'); })();

  function groupPath(args) {
    const [dn, group] = groupArgs(args);
    return explain(groupsOf(dn), group, false);
  }
  async function membership(args) {
    const [dn, group] = groupArgs(args);
    checked(dn, 'groups');
    const read = groupsOf(dn);
    await wait(150, 400);
    return explain(read, group, true);
  }

  const DCSYNC = 'Réplication de l’annuaire hors administrateurs (DCSync)';
  function aces(o) {
    const ace = (index, trustee, rid, allow, rights, targetText, origin, explicit, risk = null) => ({
      index, trustee, sid: rid.startsWith('S-') ? rid : `${DOMAIN_SID}-${rid}`, allow, type: allow ? 'Autorisation' : 'Refus', rights, target: targetText, appliesTo: 'Tous les objets',
      origin, scope: explicit ? 'Cet objet seulement' : 'Cet objet et ses descendants', explicit, onObject: true, domainAccount: !rid.startsWith('S-'), risk, riskLabel: risk === DCSYNC ? 'DCSync hors administrateurs' : risk,
    });
    if (isRoot(o.dn)) {
      return [
        ace(0, 'Admins du domaine', '512', true, 'Contrôle total', 'Tout l’objet', 'Posée sur l’objet', true),
        ace(1, 'svc-annuaire', '1302', true, 'Droit étendu', 'Répliquer toutes les modifications de l’annuaire', 'Posée sur l’objet', true, DCSYNC),
        ace(2, 'Contrôleurs de domaine d’entreprise', 'S-1-5-9', true, 'Droit étendu', 'Répliquer les modifications de l’annuaire', 'Posée sur l’objet', true),
        ace(3, 'Utilisateurs authentifiés', 'S-1-5-11', true, 'Lire', 'Tout l’objet', 'Posée sur l’objet', true),
      ];
    }
    return [
      ace(0, 'Admins du domaine', '512', true, 'Contrôle total', 'Tout l’objet', 'Héritée de la racine', false),
      ace(1, 'GG-Support-N2', '1201', true, 'Droit étendu', 'Réinitialiser le mot de passe', 'Héritée de OU=Utilisateurs', false),
      ace(2, 'GG-Support-N2', '1201', true, 'Écrire la propriété', 'lockoutTime', 'Héritée de OU=Utilisateurs', false),
      ace(3, 'Utilisateurs authentifiés', 'S-1-5-11', true, 'Lire', 'Tout l’objet', 'Héritée de la racine', false),
      ace(4, 'SELF', 'S-1-5-10', true, 'Écrire la propriété', 'Informations personnelles', 'Posée sur l’objet', true),
    ];
  }

  async function acl(args) {
    const o = checked(dnArg(args), 'acl');
    const claimed = slot;
    await wait(300, 700);
    const rows = aces(o);
    const trustees = [...new Map(rows.map((r) => [r.sid, { sid: r.sid, name: r.trustee, entries: rows.filter((x) => x.sid === r.sid).length, domainAccount: r.domainAccount }])).values()];
    const read = {
      dn: o.dn, state: 'read', stateLabel: 'Lu', owner: 'Admins du domaine', ownerSid: `${DOMAIN_SID}-512`, protected: Boolean(o.privileged), total: rows.length, truncated: false, maxAces: 1000,
      explicit: rows.filter((r) => r.explicit).length, inherited: rows.filter((r) => !r.explicit).length, deny: rows.filter((r) => !r.allow).length, rows, trustees,
      summary: `${count(rows.length, 'entrée lue', 'entrées lues')}, propriétaire Admins du domaine.`, limit: 'Une entrée observée n’est pas un droit effectif : groupes, refus et héritage peuvent changer le résultat.',
      controller: DC01, readAt: iso(Date.now()),
    };
    if (slot === claimed) { claimed.acl = read; claimed.tokens = null; }
    return read;
  }

  const RIGHTS = [['full', 'Contrôle total'], ['read', 'Lire'], ['write', 'Modifier des attributs'], ['reset', 'Réinitialiser le mot de passe'], ['members', 'Modifier les membres'], ['create', 'Créer des objets enfants'], ['delete', 'Supprimer'], ['dacl', 'Modifier les autorisations'], ['owner', 'Changer le propriétaire']];
  function estimateOf(read, sid, withGroups) {
    const mine = read.rows.filter((r) => r.sid === sid);
    if (!mine.length) throw fail('audit.trusteeUnknown', `Ce bénéficiaire ne figure dans aucune entrée lue${COLON}rien n’est estimé.`);
    const full = mine.some((r) => r.rights === 'Contrôle total');
    const rows = RIGHTS.map(([id, label]) => {
      const by = full ? mine.find((r) => r.rights === 'Contrôle total') : id === 'reset' ? mine.find((r) => r.target === 'Réinitialiser le mot de passe') : id === 'read' ? mine.find((r) => r.rights === 'Lire') : id === 'write' ? mine.find((r) => r.rights.startsWith('Écrire')) : null;
      const result = by ? (id === 'write' && !full ? 'partial' : 'allowed') : 'notGranted';
      return { id, label, result, resultLabel: { allowed: 'Autorisé', partial: 'Partiel', notGranted: 'Non accordé', denied: 'Refusé' }[result], tone: { allowed: 'ok', partial: 'warn', notGranted: 'off', denied: 'alert' }[result], decidedBy: by ? `${by.explicit ? 'Entrée posée sur l’objet' : 'entrée héritée'} n° ${by.index + 1}` : null };
    });
    return {
      dn: read.dn, sid, trustee: mine[0].trustee, includesGroups: withGroups, groupsState: withGroups ? 'read' : 'notRead', groupsMessage: null, groupCount: withGroups ? 3 : 0, rows,
      limits: withGroups ? 'Estimation avec les groupes du bénéficiaire : jamais un droit effectif.' : `Groupes du bénéficiaire non lus${COLON}une estimation, jamais un droit effectif.`,
      summary: `${count(rows.filter((r) => r.result === 'allowed').length, 'droit autorisé', 'droits autorisés')} sur neuf.`,
    };
  }
  const sidArgs = (args) => {
    const values = readObject(args, ['dn', 'sid']);
    const dn = requireDistinguishedName(getString(values, 'dn'), 'dn');
    const sid = getString(values, 'sid');
    if (sid.length < 5 || sid.length > 184 || !sid.startsWith('S-1-') || !/^[0-9-]*$/.test(sid.slice(4))) throw invalid(`${quote('sid')} doit être un identifiant de sécurité (S-1-…).`);
    return [dn, sid];
  };
  const aclOf = (dn) => current(dn)?.acl ?? (() => { throw fail('audit.aclNotRead', `Lisez d’abord les délégations de cet objet${COLON}l’estimation porte sur les entrées lues.`); })();

  function estimate(args) {
    const [dn, sid] = sidArgs(args);
    return estimateOf(aclOf(dn), sid, Boolean(current(dn)?.tokens));
  }
  async function tokenGroups(args) {
    const [dn, sid] = sidArgs(args);
    const read = aclOf(dn);
    if (!read.rows.some((r) => r.sid === sid)) throw fail('audit.trusteeUnknown', `Ce bénéficiaire ne figure dans aucune entrée lue${COLON}rien n’est estimé.`);
    if (!sid.startsWith('S-1-5-21-')) throw fail('audit.builtinTrustee', 'Les groupes se lisent pour un compte ou un groupe d’un domaine, pas pour une identité intégrée.');
    await wait(200, 500);
    if (current(dn)?.acl === read) current(dn).tokens = true;
    return estimateOf(read, sid, true);
  }

  function chainOf(o) {
    const parts = o.dn.split(/(?<!\\),/);
    const chain = [];
    for (let i = o.kind === 'organizationalUnit' ? 0 : 1; i < parts.length; i++) {
      const dn = parts.slice(i).join(',');
      if (/^OU=/i.test(parts[i])) chain.push(dn);
      if (/^DC=/i.test(parts[i])) { chain.push(dn); break; }
    }
    return chain.length ? chain : [ROOT_DN];
  }
  function gpoRows(o, rsop) {
    const row = (name, linkedToDn, enforced, outcome) => ({
      name, guid: guidOf(name), linkedTo: linkedToDn ? linkedToDn.split(',')[0].replace(/^(OU|DC)=/i, '') : '', linkedToDn, link: 'Activé', enforced: enforced ? 'Oui' : 'Non', inheritance: 'Hérité',
      expected: linkedToDn ? 'Oui' : 'Indéterminé', outcome: rsop ? outcome : 'unproven', result: rsop ? { applied: 'Appliquée (ordre d’application lu)', filtered: 'Filtrée par sécurité ou WMI', notApplied: 'Non appliquée' }[outcome] : 'Non prouvé : lien lu, résultat du poste non lu',
      resultState: rsop ? 'observed' : 'unknown', proof: rsop ? 'RSOP_GPLink' : 'gPLink', gpoStatus: 'Activée', tone: rsop ? (outcome === 'applied' ? 'ok' : 'warn') : 'off',
    });
    const chain = chainOf(o);
    const rows = [
      row('Postes - Sécurité de base', chain.find((d) => /^OU=Postes,/i.test(d)) ?? null, true, 'applied'),
      row('Postes - BitLocker', chain.find((d) => /^OU=Postes,/i.test(d)) ?? null, false, o.name.startsWith('PT-') ? 'applied' : 'filtered'),
      row('Default Domain Policy', ROOT_DN, false, 'applied'),
    ].filter((r) => r.linkedToDn);
    if (rsop) rows.push(row('Site Paris - Proxy', null, false, 'applied'));
    return rows;
  }
  async function gpo(args, applied) {
    const o = checked(dnArg(args), applied ? 'gpoApplied' : 'gpoLinks');
    const claimed = slot;
    await wait(300, 700);
    if (slot === claimed) { if (applied) claimed.rsop = true; else claimed.links = true; }
    const rsop = Boolean(claimed.rsop);
    const chain = chainOf(o);
    return {
      dn: o.dn, chain, rows: gpoRows(o, rsop),
      facts: [fact('Conteneurs lus', String(chain.length), 'observed', 'gPLink et gPOptions'), fact('Résultat sur le poste', rsop ? 'Lu (RSoP)' : 'Non lu', rsop ? 'observed' : 'unknown', 'CIM root\\rsop\\computer', 'Les liens de site ne sont pas lus dans l’annuaire.')],
      linksRead: Boolean(claimed.links), appliedProven: rsop, rsopState: rsop ? 'observed' : 'unknown', computer: o.kind === 'computer' ? o.name : null,
      summary: rsop ? 'Liens lus et résultat appliqué confrontés : seule une GPO avec un ordre d’application est dite appliquée.' : `${count(chain.length, 'conteneur lu', 'conteneurs lus')}${COLON}un lien ne prouve pas l’application.`,
      linksReadAt: claimed.links ? iso(Date.now()) : null, rsopReadAt: rsop ? iso(Date.now()) : null,
    };
  }

  async function machineIdentity(args) {
    const o = checked(dnArg(args), 'machineIdentity');
    await wait(300, 700);
    const address = `10.90.14.${30 + (o.rid % 200)}`;
    return {
      dn: o.dn, state: 'coherent', stateLabel: 'Cohérente', tone: 'ok', summary: 'L’annuaire, le DNS et le poste désignent le même ordinateur.', reasons: [], warnings: [],
      facts: [
        fact('Nom dans l’annuaire', o.dns ?? o.name, 'observed', 'Attributs sAMAccountName et dNSHostName', null, 'adName'),
        fact('Résolution DNS', address, 'observed', 'DNS', 'Un enregistrement DNS peut être périmé.', 'dnsForward'),
        fact('Nom inverse (PTR)', o.dns ?? o.name, 'observed', `DNS inverse de ${address}`, 'Un enregistrement inverse peut être périmé.', 'dnsReverse'),
        fact('Identité renvoyée par le poste', o.name, 'observed', 'CIM Win32_ComputerSystem', null, 'reported'),
      ],
      address, expected: o.name, reported: o.name, readAt: iso(Date.now()),
    };
  }

  const JULIEN_PC = 'PC-PAR-0001';
  async function relations(args) {
    const o = targetOf(dnArg(args));
    await wait(40, 120);
    const applicable = o.kind === 'user' || o.kind === 'computer';
    const linked = o.sam === 'j.martin' || o.name === JULIEN_PC;
    const lines = applicable && linked ? [
      { fact: 'Affectation déclarée', value: `j.martin · ${JULIEN_PC} (il y a 41 jours)`, badge: 'declared', badgeLabel: 'Déclarée', rule: 'Affectation saisie dans Domenia : la seule qui vaut affectation.' },
      { fact: 'Dernière session observée', value: `${JULIEN_PC} (il y a 2 h)`, badge: 'observed', badgeLabel: 'Observée', rule: 'Session console du relevé de présence : une observation ne vaut pas affectation.' },
      { fact: 'Historique', value: '6 associations enregistrées', badge: 'history', badgeLabel: 'Historique', rule: 'Base locale de Domenia : la présence dans l’historique ne prouve pas une session actuelle.' },
    ] : [];
    return {
      dn: o.dn, applicable, lines, declared: lines.length ? 1 : 0, observed: lines.length ? 1 : 0, history: lines.length ? 6 : 0,
      text: !applicable ? 'Les associations concernent un utilisateur ou un ordinateur.' : lines.length ? `${count(lines.length, 'association connue', 'associations connues')} en mémoire locale.` : 'Aucune association connue en mémoire locale pour cet objet.',
    };
  }

  async function history(args) {
    const values = readObject(args, ['dn', 'limit']);
    const dn = requireDistinguishedName(getString(values, 'dn'), 'dn');
    let limit = 200;
    if (Object.hasOwn(values, 'limit') && values.limit !== null) {
      if (!Number.isInteger(values.limit) || values.limit < 1 || values.limit > 1000) throw invalid(`${quote('limit')} doit être un entier de 1 à ${int(1000)} ou null.`);
      limit = values.limit;
    }
    const o = checked(dn, 'relations');
    await wait(80, 200);
    const linked = o.sam === 'j.martin' || o.name === JULIEN_PC;
    if (!linked) return { dn: o.dn, state: 'empty', stateLabel: 'Vide', total: 0, shown: 0, limit, rows: [], summary: 'Aucun historique enregistré dans la base locale de Domenia pour cet objet.' };
    const sources = [['Ouverture de session', 'history', 'Historique'], ['Relevé de présence', 'observed', 'Observée'], ['Saisie dans Domenia', 'declared', 'Déclarée']];
    const rows = Array.from({ length: 6 }, (_, i) => {
      const [source, badge, nature] = sources[i % 3];
      const at = REF - (i * 9 + 1) * DAY - i * 37 * MIN;
      return { at: iso(at), dateLabel: new Date(at).toLocaleString('fr-FR', { dateStyle: 'short', timeStyle: 'short' }), user: 'j.martin', computer: JULIEN_PC, nature, badge, rule: '', source, verifiedInAd: i % 2 ? 'Oui' : 'Non vérifié', details: badge === 'history' ? 'Ouverture de session interactive' : '' };
    }).slice(0, limit);
    return { dn: o.dn, state: 'read', stateLabel: 'Lu', total: 6, shown: rows.length, limit, rows, summary: `${count(rows.length, 'ligne affichée', 'lignes affichées')} sur ${count(6, 'enregistrée', 'enregistrées')} dans la base locale. La présence dans l’historique ne prouve pas une session actuelle.` };
  }

  // ---------- Identities of an OU ----------

  async function identities(args) {
    const values = readObject(args, ['dn', 'subtree']);
    const dn = requireDistinguishedName(getString(values, 'dn'), 'dn');
    const subtree = getBoolean(values, 'subtree');
    const ou = findOu(dn);
    if (!ou && !isRoot(dn)) throw fail('ou.unknown', `OU introuvable${COLON}rien n’a été lu.`);
    if (isRoot(dn) && subtree) throw fail('audit.scopeTooWide', `Le domaine entier n’est pas analysé${COLON}choisissez une OU, ou décochez ${quote('Inclure les sous-OU')}.`);
    await wait(500, 1200);
    const objects = isRoot(dn) ? 12 : (ou.counts.users + ou.counts.computers);
    const findings = objects > 0 ? [
      { id: 'dup-1', category: 'Valeur en double', element: 'Adresse c.bernard@example.local', objects: [{ name: 'Camille Bernard', dn: OBJECTS[1].dn }, { name: 'adm-c.bernard', dn: null }], objectsText: 'Camille Bernard, adm-c.bernard', conclusion: 'À revoir', limit: 'Comparaison dans le périmètre lu seulement.', tone: 'warn' },
      { id: 'rec-1', category: 'Nom recyclé ou objet recréé', element: 'PC-PAR-0003', objects: [{ name: 'PC-PAR-0003', dn: OBJECTS.find((x) => x.name === 'PC-PAR-0003').dn }], objectsText: 'PC-PAR-0003', conclusion: 'À revoir', limit: 'La base locale associe ce nom à un autre GUID : objet recréé ou nom réutilisé.', tone: 'warn' },
    ] : [];
    const categories = ['Valeur en double', 'Nom DNS partagé', 'Nom AD et nom DNS divergents', 'Nom recyclé ou objet recréé'].map((c) => ({ category: c, count: findings.filter((f) => f.category === c).length }));
    const path = `${isRoot(dn) ? DOMAIN : ou.path}${subtree ? ' (sous-OU comprises)' : ''}`;
    return {
      baseDn: dn, path, subtree, limit: 5000, objects, truncated: false, findings, categories, localIndex: 'read', localIndexText: 'Noms comparés avec la copie locale fictive de la simulation.',
      summary: `${count(objects, 'objet lu', 'objets lus')}, ${count(findings.length, 'constat à revoir', 'constats à revoir')}. Aucune fusion ni correction automatique.`, controller: DC01, readAt: iso(Date.now()),
    };
  }

  return {
    'audit.target': target,
    'audit.objects.search': search,
    'audit.suggestions': suggestions,
    'audit.catalogue': catalogue,
    'audit.overview': overview,
    'audit.finding.objects': findingObjects,
    'audit.localTotals': localTotals,
    'audit.dc.list': dcList,
    'audit.dc.probe': dcProbe,
    'audit.dc.services': dcServices,
    'audit.dc.compare': dcCompare,
    'audit.object.policy': policy,
    'audit.object.groups': groups,
    'audit.object.groupPath': groupPath,
    'audit.object.membership': membership,
    'audit.object.acl': acl,
    'audit.object.estimate': estimate,
    'audit.object.tokenGroups': tokenGroups,
    'audit.object.gpoLinks': (args) => gpo(args, false),
    'audit.object.gpoApplied': (args) => gpo(args, true),
    'audit.object.machineIdentity': machineIdentity,
    'audit.object.relations': relations,
    'audit.object.history': history,
    'audit.identities.scan': identities,
  };
}
