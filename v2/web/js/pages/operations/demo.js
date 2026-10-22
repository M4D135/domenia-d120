// Local sample data of the Opérations screen (route parameter « exemple=1 »), for the captures of the guides and for the
// browser preview: receipts and tasks with the exact shapes of the contract (docs/ops/operations.md), on the fictitious
// example.local directory. Nothing is read, nothing is sent: every action of a sample says so and does nothing.
import { NBSP } from '../../kit/index.js';

const C = `${NBSP}:`;
const iso = (ms) => new Date(ms).toISOString().replace(/\.\d{3}Z$/, 'Z');
const hex = (seed) => Array.from({ length: 32 }, (_, i) => ((seed * 7919 + i * 104729) % 16).toString(16)).join('');

const TARGETS = {
  camille: { kind: 'user', kindLabel: 'Compte utilisateur', name: 'Camille Bernard', dn: 'CN=Camille Bernard,OU=Commercial,OU=Lyon,OU=Utilisateurs,DC=example,DC=local', objectGuid: '6f1c2b7e-9a43-4d1e-8c55-2b7d90e4a1c3', samAccountName: 'c.bernard' },
  lucas: { kind: 'user', kindLabel: 'Compte utilisateur', name: 'Lucas Moreau', dn: 'CN=Lucas Moreau,OU=Logistique,OU=Marseille,OU=Utilisateurs,DC=example,DC=local', objectGuid: '2b9e0c4d-1f7a-4c3e-9d21-7a5b3c8e6f10', samAccountName: 'l.moreau' },
  ines: { kind: 'user', kindLabel: 'Compte utilisateur', name: 'Inès Fontaine', dn: 'CN=Inès Fontaine,OU=Finances,OU=Paris,OU=Utilisateurs,DC=example,DC=local', objectGuid: '9d4a1e2b-3c5f-4a6b-8e7d-0f1a2b3c4d5e', samAccountName: 'i.fontaine' },
  pc: { kind: 'computer', kindLabel: 'Ordinateur', name: 'PC-LYO-0042', dn: 'CN=PC-LYO-0042,OU=Lyon,OU=Postes,DC=example,DC=local', objectGuid: '4e5f6a7b-8c9d-4e0f-a1b2-c3d4e5f6a7b8', samAccountName: 'PC-LYO-0042$' },
  group: { kind: 'group', kindLabel: 'Groupe', name: 'GG-App-CRM', dn: 'CN=GG-App-CRM,OU=Sécurité,OU=Groupes,DC=example,DC=local', objectGuid: '7a8b9c0d-1e2f-4a3b-9c4d-5e6f7a8b9c0d', samAccountName: 'GG-App-CRM' },
  hugo: { kind: 'user', kindLabel: 'Compte utilisateur', name: 'Hugo Lambert', dn: 'CN=Hugo Lambert,OU=Commercial,OU=Lille,OU=Utilisateurs,DC=example,DC=local', objectGuid: '1c2d3e4f-5a6b-4c7d-8e9f-0a1b2c3d4e5f', samAccountName: 'h.lambert' },
};

const PROFILES = [
  { key: 'pending', kind: 'account.unlock', title: 'Déverrouiller le compte', label: 'Déverrouillage du compte', target: TARGETS.lucas, minutes: 7,
    result: 'unknown', resultLabel: 'Issue inconnue, à vérifier', verification: 'unknown', verificationLabel: 'Non vérifiée', pending: true, tone: 'warn',
    summary: `Issue inconnue après l’envoi${C} vérifiez par une relecture. Rien n’est renvoyé automatiquement. Les nouvelles écritures sur cet objet restent bloquées jusqu’à la vérification.`,
    error: { code: 'write.outcomeUnknown', message: `Issue inconnue après l’envoi${C} vérifiez l’objet par une relecture avant toute nouvelle écriture. Rien n’est renvoyé automatiquement.` },
    details: [['Préconditions', `Compte relu sur DC01.example.local${C} toujours verrouillé, DN et GUID inchangés.`], ['Envoi', `Aucune réponse du contrôleur dans le délai${C} issue inconnue.`], ['Relecture', `Relecture impossible${C} contrôleur injoignable au moment de la relecture.`]],
    change: ['lockoutTime', 'Verrouillage', 'clear', 'Verrouillé depuis 09:41', 'Déverrouillé'] },
  { key: 'sent', kind: 'account.enabled', title: 'Activer le compte', label: 'Activation du compte', target: TARGETS.hugo, minutes: 62,
    result: 'sent', resultLabel: 'Envoyée, issue à vérifier', verification: 'unknown', verificationLabel: 'Relecture en attente', pending: true, tone: 'warn',
    summary: `Écriture envoyée sans confirmation (application fermée ou interrompue)${C} issue à vérifier par une relecture. Rien n’est renvoyé automatiquement. Les nouvelles écritures sur cet objet restent bloquées jusqu’à la vérification.`,
    error: null, details: [['Préconditions', `Compte relu sur DC01.example.local${C} désactivé, DN et GUID inchangés.`]],
    change: ['userAccountControl', 'État du compte', 'replace', 'Désactivé', 'Activé'] },
  { key: 'ok', kind: 'account.unlock', title: 'Déverrouiller le compte', label: 'Déverrouillage du compte', target: TARGETS.camille, minutes: 18,
    result: 'applied', resultLabel: 'Appliquée (simulation)', verification: 'verified', verificationLabel: 'Vérifiée par relecture', pending: false, tone: 'ok',
    summary: `Écriture appliquée et vérifiée par relecture. Simulation${C} annuaire fictif en mémoire, aucun effet réel.`, error: null,
    details: [['Préconditions', `Compte relu sur DC01.example.local${C} toujours verrouillé, DN et GUID inchangés.`], ['Envoi', 'lockoutTime remis à zéro dans l’annuaire fictif (en mémoire, aucun effet réel), comme le ferait DC01.example.local.'], ['Relecture', `lockoutTime = 0 relu sur DC01.example.local${C} compte déverrouillé.`]],
    change: ['lockoutTime', 'Verrouillage', 'clear', 'Verrouillé depuis 16:08', 'Déverrouillé'] },
  { key: 'update', kind: 'object.update', title: 'Enregistrer la fiche', label: 'Enregistrement de la fiche', target: TARGETS.ines, minutes: 95,
    result: 'applied', resultLabel: 'Appliquée (simulation)', verification: 'verified', verificationLabel: 'Vérifiée par relecture', pending: false, tone: 'ok',
    summary: `Écriture appliquée et vérifiée par relecture. Simulation${C} annuaire fictif en mémoire, aucun effet réel.`, error: null,
    details: [['Préconditions', `Fiche relue sur DC01.example.local${C} valeurs « avant » inchangées.`], ['Envoi', 'Attributs écrits dans l’annuaire fictif (en mémoire, aucun effet réel).'], ['Relecture', `title et telephoneNumber relus${C} 2/2 conformes.`]],
    change: ['title', 'Fonction', 'replace', 'Comptable', 'Contrôleuse de gestion'] },
  { key: 'mismatch', kind: 'group.member', title: 'Modifier les membres du groupe', label: 'Membres du groupe', target: TARGETS.group, minutes: 180,
    result: 'applied', resultLabel: 'Appliquée (simulation)', verification: 'mismatch', verificationLabel: 'Écart à la relecture', pending: false, tone: 'alert',
    summary: `Écriture acceptée, mais la relecture montre un autre état${C} vérifiez l’objet avant toute nouvelle écriture. Rien n’est renvoyé automatiquement. Simulation${C} annuaire fictif en mémoire, aucun effet réel.`, error: null,
    details: [['Préconditions', `Groupe relu sur DC02.example.local${C} membres inchangés.`], ['Envoi', 'Membre ajouté dans l’annuaire fictif.'], ['Relecture', `Appartenance directe relue sur DC01.example.local${C} membre absent (réplication possible).`]],
    change: ['member', 'Membres', 'add', '—', 'Hugo Lambert'] },
  { key: 'reviewed', kind: 'account.unlock', title: 'Déverrouiller le compte', label: 'Déverrouillage du compte', target: TARGETS.camille, minutes: 1500,
    result: 'unknown', resultLabel: 'Issue inconnue, à vérifier', verification: 'reviewed', verificationLabel: 'Revue manuelle', pending: false, tone: 'info',
    summary: `Revue manuelle consignée${C} l’objet a été contrôlé avec un autre outil, ce n’est pas une vérification automatique. Les nouvelles écritures sur cet objet ne sont plus bloquées. Rien n’est renvoyé automatiquement.`,
    error: { code: 'write.outcomeUnknown', message: 'Issue inconnue après l’envoi.' },
    details: [['Préconditions', `Compte relu${C} toujours verrouillé.`], ['Envoi', `Issue inconnue après l’envoi${C} à vérifier.`], ['Revue manuelle', `Motif consigné par EXAMPLE\\j.martin${C} « Vérifié dans la console Utilisateurs et ordinateurs Active Directory sur DC01.example.local${C} état attendu constaté ».`]],
    change: ['lockoutTime', 'Verrouillage', 'clear', 'Verrouillé depuis 08:12', 'Déverrouillé'] },
  { key: 'refused', kind: 'account.expiration', title: 'Définir l’expiration du compte', label: 'Expiration du compte', target: TARGETS.hugo, minutes: 2950,
    result: 'notApplied', resultLabel: 'Non appliquée', verification: 'mismatch', verificationLabel: 'Relue : objet inchangé', pending: false, tone: 'alert',
    summary: `Écriture refusée avant tout changement${C} rien n’a été modifié. Rien n’est renvoyé automatiquement.`,
    error: { code: 'write.denied', message: `Droits insuffisants sur l’objet${C} rien n’a été modifié.` },
    details: [['Préconditions', 'Compte relu, valeurs inchangées.'], ['Envoi', `Refus du contrôleur${C} droits insuffisants.`], ['Relecture', `accountExpires relu${C} valeur d’origine.`]],
    change: ['accountExpires', 'Expiration du compte', 'replace', 'Jamais', '31/12/2026'] },
];

/** Sample receipts in the shape of write.receipts.list (rows) and of operations.receipts.detail (full). */
export function sampleReceipts(now = Date.now()) {
  const rows = PROFILES.map((p, n) => {
    const at = now - p.minutes * 60_000;
    const id = hex(n + 11);
    const plan = {
      id: hex(n + 41), kind: p.kind, title: p.title, label: p.label, summary: `${p.target.name}${C} ${p.label.toLowerCase()}.`, target: p.target,
      changes: [{ attribute: p.change[0], label: p.change[1], kind: p.change[2], before: p.change[3], after: p.change[4], beforeValue: null, afterValue: null }],
      risks: [], confirmation: { typedNameRequired: false, typedName: null, reason: 'Confirmation simple.' },
      reversibility: { reversible: p.kind !== 'account.unlock', label: p.kind === 'account.unlock' ? 'Sans retour arrière' : 'Compensable', detail: '' },
      controller: 'DC01.example.local', operator: 'EXAMPLE\\j.martin', mode: 'simulation', simulated: true,
      createdAt: iso(at - 40_000), expiresAt: iso(at + 260_000), fingerprint: hex(n + 77) + hex(n + 78),
      details: `Opération${C} ${p.kind}\nCible${C} ${p.target.kindLabel} ${p.target.name}\nDN${C} ${p.target.dn}\nContrôleur${C} DC01.example.local\nMode${C} simulation (exemple local)`,
    };
    return {
      id, kind: p.kind, title: p.title, label: p.label, target: p.target, at: iso(at), sentAt: iso(at - 2000),
      completedAt: p.result === 'sent' ? null : iso(at - 1000), verifiedAt: p.verification === 'unknown' && p.result === 'sent' ? null : iso(at),
      operator: 'EXAMPLE\\j.martin', controller: 'DC01.example.local', mode: 'simulation', simulated: true,
      result: p.result, resultLabel: p.resultLabel, verification: p.verification, verificationLabel: p.verificationLabel, pending: p.pending, tone: p.tone,
      summary: p.summary, error: p.error, details: p.details.map(([label, value]) => ({ label, value })), plan, sample: true,
    };
  });
  return {
    total: rows.length, pending: rows.filter((r) => r.pending).length, unreadable: 0, truncated: false,
    summary: `2 écritures restent à vérifier${C} les nouvelles écritures sur leurs objets sont bloquées jusqu’à leur relecture. Rien n’est renvoyé automatiquement.`,
    receipts: rows,
  };
}

const RULES = {
  'account.unlock': ['État', `Relire lockoutTime${C} compte déverrouillé attendu (valeur 0).`, false, 'Un déverrouillage ne se compense pas.'],
  'account.enabled': ['État', `Relire userAccountControl${C} état activé ou désactivé attendu.`, true, ''],
  'object.update': ['Attribut', 'Relire chaque attribut modifié sur le contrôleur initial et le comparer à la valeur envoyée.', true, ''],
  'group.member': ['Appartenance', 'Relire l’attribut member du groupe sur le contrôleur qui a reçu l’écriture.', true, ''],
  'account.expiration': ['Attribut', 'Relire accountExpires sur le contrôleur initial.', true, ''],
};

/** Detail of a sample receipt, in the shape of operations.receipts.detail (nothing can be sent from it). */
export function sampleDetail(receipt) {
  const [proof, check, compensable, why] = RULES[receipt.kind] ?? ['Relecture', 'Relecture de l’exécuteur.', false, ''];
  const offered = compensable && receipt.result === 'applied' && receipt.verification === 'verified';
  const reason = !compensable ? why
    : receipt.pending || receipt.verification === 'unknown' ? `Issue d’origine non vérifiée${C} relisez le reçu avant toute compensation.`
      : receipt.verification === 'reviewed' ? `Issue établie par une revue manuelle${C} relisez l’objet avant toute compensation.`
        : receipt.result === 'notApplied' ? `Rien à compenser${C} aucune modification de l’opération n’a été appliquée.`
          : receipt.verification === 'mismatch' ? `Valeur relue différente de l’opération${C} la compensation écraserait un autre changement, elle n’est pas proposée.`
            : `Compensation possible${C} préparez-la depuis la fiche de l’objet, comme une nouvelle écriture (plan relu sur le contrôleur, confirmation, reçu et relecture). Jamais automatique.`;
  const head = `${receipt.label} · ${receipt.target.name} · ${receipt.pending ? 'à vérifier' : receipt.verificationLabel.toLowerCase()}.`;
  return {
    receipt,
    rule: { kind: receipt.kind, label: receipt.label, proof, check, verifiable: true, partial: false, compensable, compensation: why },
    compensation: {
      offered, reason, newPlanRequired: true, automatic: false, notCovered: '',
      changes: offered ? receipt.plan.changes.map((c) => ({ attribute: c.attribute, label: c.label, before: c.after, after: c.before })) : [],
    },
    actions: {
      selection: `${head} Exemple local${C} aucune action n’est envoyée depuis cet aperçu.`,
      canVerify: false, verifyWhy: `Exemple local${C} rien n’est relu.`, canReview: receipt.pending, reviewWhy: receipt.pending ? null : `Ce reçu est déjà résolu${C} aucune revue n’est nécessaire.`,
      templates: [
        `Vérifié dans la console Utilisateurs et ordinateurs Active Directory sur DC01.example.local${C} état attendu constaté.`,
        `Contrôlé avec Get-ADUser sur DC01.example.local${C} valeur attendue relue.`,
        `Confirmé par l’utilisateur${C} ouverture de session réussie après l’intervention.`,
        `Simulation${C} objet contrôlé dans l’annuaire fictif depuis la fiche de Domenia.`,
      ],
    },
    executorAvailable: false,
    sample: true,
  };
}

const ACTS = [
  ['write.execute', 'write', 'Déverrouillage du compte', 'Écriture simulée', 'unknown', 'write.outcomeUnknown', 7, 2480, 1],
  ['accounts.unlock.plan', 'localRead', 'Plan de déverrouillage', 'Lecture locale', 'succeeded', null, 8, 164, 1],
  ['dashboard.widget.refresh', 'networkRead', 'Actualisation d’un widget', 'Lecture (annuaire fictif)', 'succeeded', null, 9, 812, 1],
  ['directory.ou.children', 'localRead', 'Lecture d’une branche d’OU', 'Lecture locale', 'succeeded', null, 12, 118, 7],
  ['session.setScope', 'localWrite', 'Choix de l’OU de travail', 'Écriture locale', 'succeeded', null, 13, 74, 1],
  ['write.execute', 'write', 'Déverrouillage du compte', 'Écriture simulée', 'succeeded', null, 18, 1210, 1],
  ['write.receipts.verify', 'networkRead', 'Relecture d’un reçu', 'Lecture (annuaire fictif)', 'refused', 'receipt.unknown', 21, 22, -1],
  ['operations.check.run', 'networkRead', 'Vérification de l’application', 'Lecture (annuaire fictif)', 'succeeded', null, 25, 940, 17],
  ['dashboard.widget.refresh', 'networkRead', 'Actualisation d’un widget', 'Lecture (annuaire fictif)', 'stopped', 'operation.stopped', 31, 388, -1],
  ['operations.export.save', 'localWrite', 'Export CSV', 'Écriture locale', 'succeeded', null, 40, 36, 1],
  ['dashboard.summary', 'localRead', 'Tableau de bord', 'Lecture locale', 'failed', 'operation.failed', 44, 5320, -1],
];

const OUTCOMES = {
  succeeded: ['Terminée', 'ok', 'check'], stopped: ['Arrêtée', 'warn', 'pause'], refused: ['Refusée avant envoi', 'alert', 'lock'],
  failed: ['Échec', 'alert', 'alert'], unknown: [`Résultat inconnu${C} relire avant toute nouvelle tentative`, 'warn', 'eye'],
};

/** Sample tasks in the shape of operations.activity: two in progress (one collection batch) and eleven recent ones. */
export function sampleActivity(now = Date.now()) {
  const dur = (ms) => (ms < 1000 ? `${Math.round(ms)}${NBSP}ms` : `${(ms / 1000).toFixed(1).replace('.', ',')}${NBSP}s`);
  const recent = ACTS.map(([op, kind, label, kindLabel, outcome, category, minutes, ms, volume], n) => {
    const [outcomeLabel, tone, icon] = OUTCOMES[outcome];
    const started = now - minutes * 60_000;
    const id = hex(n + 101);
    const write = kind === 'write';
    const phases = [
      { phase: 'request', label: 'Demande', atMs: 0, durationMs: null, durationText: 'non mesurée', measured: false, detail: null, outcome: null },
      { phase: 'engine', label: 'Traitement dans le moteur', atMs: 0, durationMs: ms, durationText: dur(ms), measured: true, detail: volume >= 0 ? `${volume} élément${volume > 1 ? 's' : ''}` : null, outcome: null },
      ...(write ? [
        { phase: 'queue', label: 'File d’attente du canal d’écriture et contrôles du plan', atMs: 0, durationMs: 140, durationText: dur(140), measured: true, detail: null, outcome: null },
        { phase: 'step', label: 'Relecture de l’objet avant l’envoi', atMs: 140, durationMs: 120, durationText: dur(120), measured: true, detail: null, outcome: null },
        { phase: 'step', label: 'Reçu enregistré, envoi du changement', atMs: 260, durationMs: ms - 420, durationText: dur(ms - 420), measured: true, detail: null, outcome: null },
        { phase: 'step', label: 'Relecture après l’écriture', atMs: ms - 160, durationMs: 160, durationText: dur(160), measured: true, detail: null, outcome: null },
      ] : []),
      { phase: 'end', label: `Fin${C} ${outcomeLabel}`, atMs: ms, durationMs: null, durationText: '—', measured: false, detail: category, outcome },
    ];
    const advice = outcome === 'succeeded' ? null
      : outcome === 'unknown' ? `Résultat inconnu${C} relisez l’objet avant toute nouvelle tentative${NBSP}; Domenia ne rejoue jamais une écriture. Son reçu, s’il attend une vérification, s’ouvre dans l’onglet Reçus d’écriture (filtre « À vérifier »). Référence ${id.slice(0, 8)} dans le journal technique.`
        : outcome === 'stopped' ? `Arrêtée sur demande${C} ce qui était déjà lu est conservé. Relancez l’action depuis son écran si besoin.`
          : outcome === 'refused' ? `Refusée avant envoi${C} rien n’a été fait. Relancez l’action depuis son écran une fois la cause levée. Référence ${id.slice(0, 8)} dans le journal technique.`
            : `Échec imprévu${C} le détail technique est dans le journal. Relancez l’action depuis son écran après sa lecture. Référence ${id.slice(0, 8)} dans le journal technique.`;
    const dominant = write ? 'Reçu enregistré, envoi du changement' : 'Traitement dans le moteur';
    return {
      id, reference: id.slice(0, 8), operation: op, screen: op.split('.')[0], label, kind, kindLabel, foreground: !['localRead', 'local'].includes(kind) || op.endsWith('.plan'),
      listed: true, state: 'completed', stateLabel: outcomeLabel, tone, icon, outcome, outcomeLabel, startedAt: iso(started), endedAt: iso(started + ms),
      durationMs: ms, durationText: dur(ms), dominantLabel: dominant, dominantMs: write ? ms - 420 : ms, volume: volume >= 0 ? volume : null,
      volumeText: volume >= 0 ? `${volume} élément${volume > 1 ? 's' : ''}` : null, canStop: false, stopReason: `Tâche terminée${C} rien à arrêter.`,
      detail: `${outcome === 'succeeded' ? 'Terminée' : 'Fin'} après ${dur(ms)}${volume >= 0 ? `, ${volume} élément${volume > 1 ? 's' : ''}` : ''}.`, access: write ? 'Écriture sur l’annuaire fictif en mémoire, sans aucun effet réel.' : 'Lecture locale.',
      advice, category, text: phases.map((p) => (p.durationMs ? `${p.label} ${p.durationText}` : p.label)).join(' → '), dropped: 0, phases, progress: null, sample: true,
    };
  });
  const open = [
    {
      id: 'batch:releve-01', reference: 'releve01', operation: 'operations.survey.resume', screen: 'operations', label: 'Lot WMI · Bordeaux et sous-OU', kind: 'batch',
      kindLabel: 'Lot de collecte', foreground: true, listed: true, state: 'running', stateLabel: 'En cours', tone: 'info', icon: 'activity', outcome: null, outcomeLabel: null,
      startedAt: iso(now - 6400), endedAt: null, durationMs: 6400, durationText: '6,4 s', dominantLabel: null, dominantMs: null, volume: 9, volumeText: '9 éléments',
      canStop: true, stopReason: null, detail: '9/15 postes traités · 0 lecture non confirmée · 1 lecture en cours · 0 enregistrement en attente.',
      access: `Relevé fictif des postes${C} aucune sonde ne part.`, advice: null, category: null, text: 'Lot WMI · Bordeaux et sous-OU → En cours', dropped: 0,
      phases: [{ phase: 'request', label: 'Demande confirmée par l’opérateur', atMs: 0, durationMs: null, durationText: 'non mesurée', measured: false, detail: null, outcome: null }],
      progress: { done: 9, total: 15, failed: 0, phase: 'En cours', header: 'WMI · 9/15', counters: '9/15 postes traités · 0 lecture non confirmée · 1 lecture en cours · 0 enregistrement en attente.' }, sample: true,
    },
    {
      id: hex(201), reference: hex(201).slice(0, 8), operation: 'operations.check.run', screen: 'operations', label: 'Vérification de l’application', kind: 'networkRead',
      kindLabel: 'Lecture (annuaire fictif)', foreground: true, listed: true, state: 'running', stateLabel: 'En cours', tone: 'info', icon: 'activity', outcome: null, outcomeLabel: null,
      startedAt: iso(now - 1300), endedAt: null, durationMs: 1300, durationText: '1,3 s', dominantLabel: null, dominantMs: null, volume: null, volumeText: null, canStop: true, stopReason: null,
      detail: `Traitement actif. Aucun résultat final annoncé. Accès requis${C} lecture de l’annuaire fictif${C} aucune requête ne part.`, access: `Lecture de l’annuaire fictif${C} aucune requête ne part.`,
      advice: null, category: null, text: 'Demande → Traitement dans le moteur', dropped: 0,
      phases: [{ phase: 'request', label: 'Demande', atMs: 0, durationMs: null, durationText: 'non mesurée', measured: false, detail: null, outcome: null }], progress: null, sample: true,
    },
  ];
  return {
    generatedAt: iso(now), summary: { running: 2, queued: 0, stopRequested: 0, cleanup: 0, active: 2, total: 2, text: '2 en cours', resources: 1, resourcesText: `Ressources détenues${C} 1 jeton d’arrêt (un par lecture en cours)` },
    open, recent, kept: recent.length + 1, listed: recent.length, faults: 0,
    note: `Exemple local${C} tâches d’illustration, aucune n’a été lancée.`,
  };
}
