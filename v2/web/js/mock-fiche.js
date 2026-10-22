// Browser preview of the « Fiche » screen (docs/ops/fiche.md, PLATFORM.md § 2.6): the same operations and result shapes as
// FicheOperations, on a few objects of the fictitious example.local directory (a locked user, his manager, a workstation, a
// group, an OU and a contact). Nothing leaves the page. The plans of the writes answer « source.unavailable »: the write
// circuit of the fiche is tried in the application itself, in simulation (the preview has no secure window for a password).
// The helpers of mock.js are handed in, so validation messages stay word for word those of the engine.

const MIN = 60_000;
const HOUR = 60 * MIN;
const DAY = 24 * HOUR;
const ROOT = 'DC=example,DC=local';

/**
 * @param {object} h  Helpers of mock.js: readObject, getString, getOptionalString, requireDistinguishedName, requireNone, invalid,
 *   fail, quote, int, sleep, NBSP, REF.
 * @returns {Object<string, (args: any) => any>}
 */
export function createFicheOperations(h) {
  const { readObject, getString, getOptionalString, requireDistinguishedName, requireNone, invalid, fail, int, sleep, NBSP, REF } = h;
  const C = `${NBSP}: `;
  const iso = (t) => new Date(t).toISOString().replace(/\.\d{3}Z$/, 'Z');
  const pad = (n) => String(n).padStart(2, '0');
  const local = (t) => { const d = new Date(t); return `${pad(d.getDate())}/${pad(d.getMonth() + 1)}/${d.getFullYear()} ${pad(d.getHours())}:${pad(d.getMinutes())}`; };
  const dayText = (t) => { const d = new Date(t); return `${pad(d.getDate())}/${pad(d.getMonth() + 1)}/${d.getFullYear()}`; };
  const count = (n, one, many) => `${int(n)}${NBSP}${Math.abs(n) >= 2 ? many : one}`;
  const recent = [];

  const DN = {
    user: `CN=Camille Bernard,OU=Commercial,OU=Lyon,OU=Utilisateurs,${ROOT}`,
    manager: `CN=Cédric Carré,OU=Commercial,OU=Lyon,OU=Utilisateurs,${ROOT}`,
    pc: `CN=PC-LYO-0002,OU=Lyon,OU=Postes,${ROOT}`,
    group: `CN=GG-Commercial-Lyon,OU=Sécurité,OU=Groupes,${ROOT}`,
    ou: `OU=Commercial,OU=Lyon,OU=Utilisateurs,${ROOT}`,
    contact: `CN=Agence Voyages Sud,OU=Distribution,OU=Groupes,${ROOT}`,
  };
  const SUMMARIES = [
    { dn: DN.user, name: 'Camille Bernard', kind: 'user', sam: 'c.bernard', detail: 'Technico-commerciale · Commercial · Lyon', disabled: false, objectGuid: '443838bd-e367-498e-9a78-0f7f0746cc8f', upn: 'c.bernard@example.local' },
    { dn: DN.manager, name: 'Cédric Carré', kind: 'user', sam: 'c.carre', detail: 'Responsable d’agence · Commercial · Lyon', disabled: false, objectGuid: '7d1c0c6a-31a2-4b2e-9f0e-2c3b6c9e1a10', upn: 'c.carre@example.local' },
    { dn: DN.pc, name: 'PC-LYO-0002', kind: 'computer', sam: 'PC-LYO-0002$', detail: 'Windows 11 Entreprise · Lyon', disabled: false, objectGuid: '0f3a77e2-55d1-4a0b-8b8e-1a2b3c4d5e6f' },
    { dn: DN.group, name: 'GG-Commercial-Lyon', kind: 'group', sam: 'GG-Commercial-Lyon', detail: 'Groupe de sécurité global', disabled: false, objectGuid: 'a1b2c3d4-0000-4000-8000-000000000001', groupType: -2147483646 },
    { dn: DN.ou, name: 'Commercial', kind: 'ou', sam: null, detail: 'example.local › Utilisateurs › Lyon', disabled: false, objectGuid: 'a1b2c3d4-0000-4000-8000-000000000002' },
    { dn: DN.contact, name: 'Agence Voyages Sud', kind: 'contact', sam: null, detail: 'Contact · Distribution', disabled: false, objectGuid: 'a1b2c3d4-0000-4000-8000-000000000003' },
  ];
  const find = (dn) => SUMMARIES.find((s) => s.dn.toLowerCase() === String(dn).toLowerCase());
  const known = (dn) => find(dn) ?? (() => { throw fail('fiche.unknown', `Objet introuvable dans l’annuaire${C}rien n’a été lu.`); })();
  const readable = (dn) => ['example.local', ...dn.split(',').filter((p) => p.startsWith('OU=')).map((p) => p.slice(3)).reverse()].join(' › ');
  const parent = (dn) => dn.slice(dn.indexOf(',') + 1);
  const lockedAt = REF - 22 * MIN;

  const freshness = (readAt) => [
    { nature: 'identity', label: 'Identité AD', state: 'fresh', observedAt: iso(readAt), ageSeconds: 0, text: `Identité AD${C}${local(readAt)}`, validitySeconds: 86400, lastAttempt: null, validity: `valable 1${NBSP}j` },
    { nature: 'attributes', label: 'Attributs AD', state: 'fresh', observedAt: iso(readAt), ageSeconds: 0, text: `Attributs AD${C}${local(readAt)}`, validitySeconds: 900, lastAttempt: null, validity: `valable 15${NBSP}min` },
    { nature: 'presence', label: 'Présence réseau', state: 'stale', observedAt: iso(REF - 3 * HOUR), ageSeconds: 10800, text: `Présence réseau${C}${local(REF - 3 * HOUR)} (à relire)`, validitySeconds: 120, lastAttempt: null, validity: `valable 2${NBSP}min` },
    { nature: 'console', label: 'Session console', state: 'stale', observedAt: iso(REF - 3 * HOUR), ageSeconds: 10800, text: `Session console${C}${local(REF - 3 * HOUR)} (à relire)`, validitySeconds: 300, lastAttempt: null, validity: `valable 5${NBSP}min` },
    { nature: 'history', label: 'Historique', state: 'unknown', observedAt: null, ageSeconds: null, text: `Historique${C}jamais observé`, validitySeconds: 0, lastAttempt: null, validity: 'sans expiration' },
  ];
  const settings = {
    forcePasswordChange: true, passwordLength: 16, clipboardSeconds: 30, rawWrite: true, containerDelete: false, typedDelete: true,
    items: [{ key: 'AllowRawAttributeWrite', label: 'Écriture brute d’un attribut', value: 'Oui', source: 'simulation', sourceLabel: `Simulation${C}autorisée sur l’annuaire fictif (refusée par défaut en mode annuaire)` }],
    fileText: `Domenia.config.json absent${C}valeurs par défaut de Domenia 1.`, freshnessText: 'Profil Standard',
  };
  const action = (id, label, kind, reason = null, danger = false) => ({ id, label, kind, available: reason === null, reason, danger });
  const previewWrites = `Aperçu dans un navigateur${C}les écritures de la fiche s’essaient dans l’application, en simulation.`;

  function sheetOf(s, readAt) {
    const user = s.kind === 'user';
    const computer = s.kind === 'computer';
    const item = (key, label, value, extra = {}) => ({ key, label, value, sub: null, mono: false, copy: false, tone: null, wide: false, link: null, ...extra });
    const sections = user ? [
      { id: 'identite', title: 'Identité', icon: 'user', items: [item('displayName', 'Nom affiché', s.name), item('sAMAccountName', 'Identifiant', s.sam, { mono: true, copy: true }), item('userPrincipalName', 'Nom de connexion', s.upn, { mono: true, copy: true })] },
      { id: 'organisation', title: 'Organisation', icon: 'users', items: [item('title', 'Fonction', 'Technico-commerciale'), item('department', 'Service', 'Commercial'), item('manager', 'Responsable', 'Cédric Carré', { sub: 'Responsable d’agence · Commercial · Lyon', link: { dn: DN.manager, name: 'Cédric Carré', kind: 'user', detail: 'Responsable d’agence' } })] },
    ] : [{ id: computer ? 'systeme' : 'groupe', title: computer ? 'Système' : 'Général', icon: computer ? 'monitor' : 'object', items: [item('description', 'Description', s.detail, { wide: true })] }];
    const account = user || computer ? {
      stateLabel: user ? 'Actif / Verrouillé' : 'Actif', uac: 512, uacLabel: 'Compte normal', disabled: false, lock: user ? 'locked' : 'unlocked', lockLabel: user ? `Verrouillé depuis le ${local(lockedAt)}` : 'Non verrouillé',
      lockedAt: user ? iso(lockedAt) : null, badPasswordCount: user ? 5 : 0, badPasswordAt: user ? iso(lockedAt - MIN) : null, passwordLastSet: iso(REF - 35 * DAY), mustChange: false,
      passwordExpires: user ? iso(REF + 55 * DAY) : null, passwordLabel: user ? `Expire le ${dayText(REF + 55 * DAY)} (dans 55 jours)` : `Mot de passe machine renouvelé le ${dayText(REF - 17 * DAY)}`,
      passwordTone: 'ok', accountExpires: null, accountNeverExpires: true, accountExpiresLabel: 'N’expire jamais', accountExpiresTone: 'ok',
      logon: { state: 'known', approx: iso(REF - 8 * DAY), ageDays: 8, text: `Activité approximative${C}dernière connexion connue vers le ${dayText(REF - 8 * DAY)} (lastLogonTimestamp, répliqué).`, badge: 'Actif ces 14 jours', badgeTone: 'ok' },
      options: [{ id: 'passwordNeverExpires', label: 'Le mot de passe n’expire jamais', flag: 65536, on: false, highRisk: false, advanced: false, detail: 'Le compte ignore la durée de validité de la stratégie.' }],
      protected: false, computer,
    } : null;
    const tabs = [{ id: 'general', label: 'Général', count: null }];
    if (user) tabs.push({ id: 'compte', label: 'Compte', count: null }, { id: 'groupes', label: 'Groupes', count: 2 });
    if (computer) tabs.push({ id: 'compte', label: 'Compte machine', count: null }, { id: 'groupes', label: 'Groupes', count: 0 });
    if (s.kind === 'group') tabs.push({ id: 'membres', label: 'Membres', count: 2 }, { id: 'groupes', label: 'Membre de', count: 0 });
    if (s.kind === 'ou') tabs.push({ id: 'membres', label: 'Contenu', count: 2 });
    if (s.kind === 'contact') tabs.push({ id: 'groupes', label: 'Groupes', count: 0 });
    tabs.push({ id: 'relations', label: 'Relations', count: user || computer ? 1 : null }, { id: 'droits', label: 'Droits', count: null }, { id: 'attributs', label: 'Attributs', count: 12 }, { id: 'historique', label: 'Historique', count: null });
    if (user) tabs.push({ id: 'appel', label: 'Fiche d’appel', count: null });
    const actions = [
      action('edit', 'Modifier', 'write', previewWrites),
      ...(user ? [action('unlock', 'Déverrouiller', 'write', previewWrites), action('resetPassword', 'Réinitialiser le mot de passe…', 'write', previewWrites, true), action('lockouts', 'Lire les verrouillages (4740)', 'network'), action('logonByDc', 'Lire la connexion sur chaque contrôleur', 'network'), action('compare', 'Comparer les droits avec…', 'network'), action('callSheet', 'Fiche d’appel', 'local')] : []),
      ...(user || computer ? [action('presence', 'Vérifier la présence', 'network')] : []),
      ...(computer ? [action('openPoste', 'Ouvrir dans Poste', 'local')] : []),
      action('delete', 'Supprimer…', 'write', previewWrites, true), action('rights', 'Estimer les droits effectifs', 'network'), action('reread', 'Relire depuis l’annuaire', 'network'),
      action('copySummary', 'Copier le résumé', 'local'), action('openParent', 'Ouvrir le parent', 'local'),
    ];
    const initials = s.name.split(/\s+/).map((w) => w[0]).join('').slice(0, 2).toUpperCase();
    return {
      identity: { kind: s.kind, kindLabel: { user: 'Compte utilisateur', computer: 'Poste de travail', group: 'Groupe de sécurité global', ou: 'Unité d’organisation', contact: 'Contact' }[s.kind], name: s.name, dn: s.dn, guid: s.objectGuid,
        sid: user ? 'S-1-5-21-2737171963-2917597168-928610198-2564' : null, sam: s.sam, upn: s.upn ?? null, objectClass: s.kind, classes: ['top', s.kind], created: iso(REF - 800 * DAY), changed: iso(REF - 22 * MIN), usn: 799865,
        path: readable(s.dn), parentDn: parent(s.dn), initials, subtitle: s.detail },
      origin: { source: 'simulation', label: 'Annuaire fictif', readAt: iso(readAt), controller: 'DC01.example.local', preview: false, detail: `Aperçu navigateur, lu le ${local(readAt)}.` },
      states: user ? [{ id: 'enabled', tone: 'ok', label: 'Activé', detail: 'Le compte peut ouvrir une session.' }, { id: 'locked', tone: 'alert', label: 'Verrouillé', detail: `Depuis le ${local(lockedAt)}.` }] : [{ id: 'enabled', tone: 'ok', label: 'Activé', detail: '' }],
      band: user ? { tone: 'alert', alerts: [`Verrouillé depuis le ${local(lockedAt)}`, '5 mauvais mots de passe'], limits: `Compteur d’échecs propre au contrôleur interrogé${C}il n’est pas répliqué.`, unlock: true, lockouts: true } : null,
      sections, edit: { available: false, reason: previewWrites, fields: [] }, account,
      counts: { groups: user ? 2 : 0, members: s.kind === 'group' ? 2 : null, children: s.kind === 'ou' ? 2 : null, linked: user || computer ? 1 : 0, reports: user ? 0 : null },
      freshness: freshness(readAt), manager: user ? { dn: DN.manager, name: 'Cédric Carré', kind: 'user', detail: 'Responsable d’agence' } : null,
      linked: user ? [{ name: 'PC-LYO-0002', dn: DN.pc, objectGuid: SUMMARIES[2].objectGuid, kind: 'computer', evidence: 'observed', evidenceLabel: 'Observé', rule: 'Session console lue sur le poste.', when: iso(REF - 3 * HOUR), source: 'Session console', primary: true }] : [],
      presence: user || computer ? { state: 'stale', label: 'Sans réponse au ping (poste associé PC-LYO-0002)', checkedAt: iso(REF - 3 * HOUR), computer: 'PC-LYO-0002', computerDn: DN.pc, detail: `Relevé du ${local(REF - 3 * HOUR)} (à relire${C}plus de 2${NBSP}min).` } : null,
      actions, tabs, landing: s.kind === 'group' || s.kind === 'ou' ? 'membres' : 'general',
      summary: `Type${C}${s.kind}\r\nNom${C}${s.name}\r\nDN${C}${s.dn}`,
      support: user ? [{ group: 'Identité', label: 'Nom affiché', value: s.name, state: 'known', source: 'Annuaire fictif', limit: null, hypothesis: null, reader: 'DC01.example.local', dateText: local(readAt) }] : [],
      signature: `preview-${s.objectGuid.slice(0, 8)}`, settings,
    };
  }

  const dnArg = (args) => requireDistinguishedName(getString(readObject(args, ['dn']), 'dn'), 'dn');

  return {
    'fiche.preview': async (args) => { dnArg(args); await sleep(30); return null; },
    'fiche.read': async (args) => {
      const values = readObject(args, ['dn', 'reread']);
      const s = known(requireDistinguishedName(getString(values, 'dn'), 'dn'));
      await sleep(220);
      return sheetOf(s, Date.now());
    },
    'fiche.resolve': async (args) => {
      const text = getString(readObject(args, ['text']), 'text').trim().toLowerCase().replace(/^example\\/, '');
      const s = SUMMARIES.find((x) => [x.sam?.toLowerCase(), x.upn?.toLowerCase(), x.name.toLowerCase(), x.dn.toLowerCase()].includes(text));
      if (!s) throw fail('fiche.notFound', `Aucun objet de la base locale ne correspond exactement${C}lancez une recherche globale. Rien n’a été lu sur le réseau.`);
      return s;
    },
    'fiche.pick': async (args) => {
      const values = readObject(args, ['text', 'kinds']);
      const text = getString(values, 'text').toLowerCase();
      const kinds = Array.isArray(values.kinds) ? values.kinds : null;
      return SUMMARIES.filter((s) => (!kinds || kinds.includes(s.kind)) && (s.name.toLowerCase().includes(text) || (s.sam ?? '').toLowerCase().includes(text)));
    },
    'fiche.recent': async (args) => { requireNone(args); return recent.slice(); },
    'fiche.recent.add': async (args) => {
      const s = known(dnArg(args));
      const at = iso(Date.now());
      const i = recent.findIndex((r) => r.dn === s.dn);
      if (i >= 0) recent.splice(i, 1);
      recent.unshift({ dn: s.dn, name: s.name, kind: s.kind, detail: s.detail, at, exists: true });
      recent.length = Math.min(recent.length, 12);
      return recent.slice();
    },
    'fiche.recent.clear': async (args) => { requireNone(args); recent.length = 0; return []; },
    'fiche.attributes': async (args) => {
      const s = known(dnArg(args));
      await sleep(160);
      const rows = [['cn', s.name, 'text', false], ['description', s.detail, 'text', true], ['distinguishedName', s.dn, 'dn', false], ['whenChanged', local(REF - 22 * MIN), 'date', false]]
        .map(([name, display, syntax, writable]) => ({ name, values: [display], display, syntax, multi: false, writable, blocked: writable ? null : `Attribut tenu par l’annuaire${C}${name} ne s’écrit pas directement.` }));
      return { dn: s.dn, total: rows.length, sensitive: 0, rows, rawWrite: { allowed: true, reason: null, blockSensitive: true, blockList: ['objectGUID', 'objectSid', 'unicodePwd'], settings: settings.items, fileText: settings.fileText }, note: 'Attributs sensibles (mots de passe, LAPS, BitLocker, clés) jamais lus ni affichés.' };
    },
    'fiche.groups': async (args) => {
      const s = known(dnArg(args));
      await sleep(140);
      const rows = s.kind === 'user' ? [{ name: 'GG-Commercial-Lyon', dn: DN.group, type: 'Groupe de sécurité global', category: 'security', ou: readable(DN.group), privileged: false, protected: false, membership: 'Directe', depth: 1, via: null, primary: false }] : [];
      return { dn: s.dn, total: rows.length, shown: rows.length, complete: true, label: count(rows.length, 'groupe direct', 'groupes directs'), note: null, primary: s.kind === 'user' ? { name: 'Utilisateurs du domaine', dn: null, rid: 513, label: 'Utilisateurs du domaine (RID 513)' } : null, privileged: 0, rows };
    },
    'fiche.groups.nested': async (args) => { const s = known(dnArg(args)); await sleep(200); return { dn: s.dn, direct: 1, nested: 0, truncated: false, unread: 0, summary: 'Aucun groupe imbriqué en plus des groupes directs.', rows: [] }; },
    'fiche.groups.why': async (args) => {
      const values = readObject(args, ['dn', 'group']);
      requireDistinguishedName(getString(values, 'dn'), 'dn');
      const group = requireDistinguishedName(getString(values, 'group'), 'group');
      return { group: find(group)?.name ?? group, known: true, member: true, needsRead: false, path: ['Camille Bernard', find(group)?.name ?? group], text: `«${NBSP}Camille Bernard${NBSP}» est membre direct${C}l’attribut member du groupe le nomme.`, basis: 'direct' };
    },
    'fiche.groups.delta': async (args) => {
      const values = readObject(args, ['dn', 'current', 'add', 'remove']);
      const dn = requireDistinguishedName(getString(values, 'dn'), 'dn');
      const steps = [...(values.add ?? []).map((g) => ({ action: 'add', groupDn: g, groupName: find(g)?.name ?? g, memberDn: dn, label: `Ajouter à ${find(g)?.name ?? g}` })),
        ...(values.remove ?? []).map((g) => ({ action: 'remove', groupDn: g, groupName: find(g)?.name ?? g, memberDn: dn, label: `Retirer de ${find(g)?.name ?? g}` }))];
      return { steps, notes: [], writesFullList: false };
    },
    'fiche.groups.delta.check': async (args) => {
      const values = readObject(args, ['dn', 'steps']);
      const dn = requireDistinguishedName(getString(values, 'dn'), 'dn');
      if (!Array.isArray(values.steps)) throw invalid('« steps » doit être un tableau d’au plus 64 étapes { action, group }.');
      const rows = values.steps.map((st) => ({ label: st.group, groupDn: st.group, groupName: st.group, action: st.action, status: 'toCheck', statusLabel: 'À vérifier' }));
      return { dn, overall: rows.length ? 'toCheck' : 'none', overallLabel: rows.length ? 'À vérifier' : 'Aucun changement', rows, readAt: iso(Date.now()), text: 'Aperçu navigateur : aucune relecture du contrôleur.' };
    },
    'fiche.members': async (args) => {
      const s = known(dnArg(args));
      await sleep(160);
      const rows = [SUMMARIES[0], SUMMARIES[1]].map((m) => ({ name: m.name, dn: m.dn, type: 'user', typeLabel: 'Utilisateur', ou: readable(m.dn), disabled: false, detail: m.detail, privileged: false }));
      return { dn: s.dn, mode: s.kind === 'group' ? 'members' : 'children', total: 2, shown: 2, complete: true, label: s.kind === 'group' ? '2 membres directs' : '2 objets dans cette branche', note: null, counts: [{ type: 'user', label: 'Utilisateurs', count: 2 }], rows };
    },
    'fiche.relations': async (args) => {
      const s = known(dnArg(args));
      const user = s.kind === 'user';
      return { dn: s.dn, manager: user ? { dn: DN.manager, name: 'Cédric Carré', kind: 'user', detail: 'Responsable d’agence · Commercial · Lyon' } : null, reports: [], managedBy: null, manages: [],
        associations: user ? sheetOf(s, Date.now()).linked : [], note: `Relations de la base locale${C}aucun pourcentage de fiabilité.` };
    },
    'fiche.history': async (args) => {
      const s = known(dnArg(args));
      await sleep(120);
      return { dn: s.dn, events: [{ when: iso(REF - 22 * MIN), title: 'Objet modifié', text: 'whenChanged', tone: 'info', icon: 'edit', actor: null, meta: null, kind: 'directory', receiptId: null }], pending: 0, note: 'Dates lues dans l’annuaire et métadonnées de réplication.' };
    },
    'fiche.compare': async () => { throw fail('fiche.notFound', `Aperçu navigateur${C}la comparaison s’essaie dans l’application, en simulation.`); },
    'fiche.rights': async (args) => {
      dnArg(args);
      await sleep(400);
      const cap = (id, capability, state) => ({ id, capability, state, stateLabel: state === 'allowed' ? 'Autorisé' : 'Indéterminé', source: 'Liste d’accès de l’objet', detail: 'Estimation de l’aperçu navigateur.', ace: null });
      const rows = [cap('read', 'Lecture de l’objet', 'allowed'), cap('edit', 'Modifier les attributs', 'unknown')];
      return { available: true, reason: null, owner: 'Admins du domaine', matchingAces: 1, tokenSids: 4, rows, note: 'Estimation seulement.', report: 'Aperçu', readAt: iso(Date.now()) };
    },
    'fiche.lockouts': async (args) => {
      const values = readObject(args, ['dn', 'hours']);
      const s = known(requireDistinguishedName(getString(values, 'dn'), 'dn'));
      await sleep(600);
      const hours = values.hours ?? 168;
      return { dn: s.dn, state: 'read', controller: 'DC01.example.local', hours, truncated: false, readAt: iso(Date.now()), recurrence: 1,
        rows: [{ at: iso(lockedAt), local: local(lockedAt), computer: 'PC-LYO-0002', controller: 'DC01.example.local', domenia: 'refus Domenia 40 s avant', domeniaNear: true }],
        facts: [{ group: 'Journal', label: 'Verrouillages journalisés', value: '1 événement 4740', state: 'known', source: 'Journal Sécurité de DC01.example.local', limit: null, hypothesis: null }], report: 'Aperçu' };
    },
    'fiche.logonByDc': async (args) => {
      dnArg(args);
      await sleep(700);
      return { rows: [{ controller: 'DC01.example.local', type: 'RWDC', state: 'read', value: local(REF - 2 * HOUR), at: iso(REF - 2 * HOUR), logonCount: 412 }], readCount: 1, knownCount: 1, complete: true,
        mostRecent: iso(REF - 2 * HOUR), mostRecentController: 'DC01.example.local', logonCount: 412, text: '1 contrôleur lu sur 1.', interval: { days: 14, state: 'absent', text: '' } };
    },
    'fiche.presence': async (args) => {
      dnArg(args);
      await sleep(500);
      return { computer: 'PC-LYO-0002', computerDn: DN.pc, state: 'offline', label: 'Sans réponse au ping', checkedAt: iso(Date.now()), consoleUser: null, via: 'Poste associé PC-LYO-0002 (Observé, principal)', detail: 'Aucune réponse en 1,5 s.', error: null };
    },
    'fiche.callSheet': async () => { throw fail('fiche.notApplicable', `Aperçu navigateur${C}la fiche d’appel se calcule dans l’application, en simulation.`); },
    'fiche.callSheet.read': async () => { throw fail('fiche.notApplicable', `Aperçu navigateur${C}la fiche d’appel se calcule dans l’application, en simulation.`); },
    'fiche.destinations': async (args) => {
      const values = readObject(args, ['dn']);
      const dn = getOptionalString(values, 'dn');
      if (dn) requireDistinguishedName(dn, 'dn');
      await sleep(90);
      return dn ? [] : [
        { dn: `OU=Utilisateurs,${ROOT}`, name: 'Utilisateurs', kind: 'ou', path: 'example.local › Utilisateurs', hasChildren: false, objects: 3 },
        { dn: `CN=Users,${ROOT}`, name: 'Users', kind: 'container', path: 'example.local › Users', hasChildren: false, objects: 12 },
      ];
    },
    ...Object.fromEntries(['update', 'enable', 'expiration', 'expirePassword', 'options', 'rawAttribute', 'move', 'membership', 'delete', 'createOu', 'resetPassword']
      .map((verb) => [`fiche.${verb}.plan`, async () => { throw fail('source.unavailable', previewWrites); }])),
  };
}
