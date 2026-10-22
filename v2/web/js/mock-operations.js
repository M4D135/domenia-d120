// Browser preview of the Opérations screen (docs/ops/operations.md): the operations.* of the engine with the exact shapes of the
// contract and the same error codes and texts, over the receipts of mock-writes.js (memory of the page) and the journal of
// mock.js. The activity, the statistics and the runs are those of an illustrative session of the fictitious example.local
// directory (pages/operations/demo.js for the tasks); nothing is read, nothing leaves the page, no document is written (the
// preview answers « préparé, non écrit », as the engine does without a data folder).
import { sampleActivity } from './pages/operations/demo.js';

const MIN = 60_000;
const BINS = ['≤ 10 ms', '≤ 50 ms', '≤ 100 ms', '≤ 250 ms', '≤ 500 ms', '≤ 1 s', '≤ 5 s', '> 5 s'];

/**
 * @param {object} h Helpers of mock.js: readObject, getString, getOptionalString, getBoolean, requireNone, invalid, fail, quote,
 *   int, count, sleep, log, NBSP, REF, writes ({ operations, review }), journal(), session().
 * @returns {Object<string, (args: any) => any>}
 */
export function createOperationsOperations(h) {
  const { readObject, getString, getOptionalString, getBoolean, requireNone, invalid, fail, quote, int, count, sleep, log, NBSP, REF, writes } = h;
  const COLON = `${NBSP}: `;
  const iso = (t) => new Date(t).toISOString().replace(/\.\d{3}Z$/, 'Z');
  const ms = (v) => (v < 1000 ? `${int(Math.round(v))}${NBSP}ms` : `${(v / 1000).toFixed(1).replace('.', ',')}${NBSP}s`);
  const receiptsList = () => writes.operations['write.receipts.list']();
  const SERVED = ['account.unlock'];
  let lastCheck = null;
  let survey = null; // { id, total, startedAt, stopAt }
  let remaining = 15;
  let offered = false;

  function summaryOf(running, stopping) {
    const parts = [running ? `${int(running)} en cours` : '', stopping ? `${int(stopping)} arrêt demandé` : ''].filter(Boolean);
    return {
      running, queued: 0, stopRequested: stopping, cleanup: 0, active: running + stopping, total: running + stopping, text: parts.join(' · ') || 'Aucune tâche',
      resources: running, resourcesText: running ? `Ressources détenues${COLON}${count(running, 'jeton d’arrêt', 'jetons d’arrêt')} (un par lecture en cours)` : 'Aucune ressource détenue',
    };
  }

  function pill(list) {
    const pending = list.receipts.filter((r) => r.pending).sort((a, b) => (a.sentAt < b.sentAt ? -1 : 1));
    if (!pending.length) return { visible: false, text: '', help: '', oldest: null };
    const first = pending[0];
    const d = new Date(first.sentAt);
    const pad = (n) => String(n).padStart(2, '0');
    return {
      visible: true,
      text: pending.length === 1 ? '1 opération à vérifier' : `${int(pending.length)} opérations à vérifier`,
      help: `Une écriture envoyée attend une vérification ou une revue${COLON}les nouvelles écritures restent bloquées. Ouvre la liste des reçus${NBSP}; rien n’est rejoué.`,
      oldest: {
        id: first.id, label: first.label, target: first.target.name, targetKind: first.target.kindLabel, at: first.sentAt,
        text: `${pending.length === 1 ? 'À vérifier' : 'Le plus ancien'}${COLON}${first.label} · ${first.target.name}, envoyée le ${pad(d.getDate())}/${pad(d.getMonth() + 1)}/${d.getFullYear()} à ${pad(d.getHours())}:${pad(d.getMinutes())}.`,
      },
    };
  }

  function writeState(list) {
    if (list.pending > 0) return [`${count(list.pending, 'opération à vérifier', 'opérations à vérifier')}${COLON}les nouvelles écritures restent bloquées jusqu’à ${list.pending === 1 ? 'sa vérification ou sa revue' : 'leur vérification ou leur revue'}.`, 'warn'];
    return [`Au repos${COLON}aucune écriture incertaine.`, 'ok'];
  }

  function activity() {
    const a = sampleActivity(REF);
    const open = a.open.filter((t) => t.kind !== 'batch');
    const batch = batchRow();
    const rows = batch ? [batch, ...open] : open;
    const running = rows.filter((r) => r.state === 'running').length;
    const stopping = rows.filter((r) => r.state === 'stopRequested').length;
    return { ...a, open: rows, summary: summaryOf(running, stopping), note: `Aperçu dans un navigateur${COLON}tâches d’illustration, aucune n’a été lancée.` };
  }

  // ---------------------------------------------------------------- survey (Relevés), in the memory of the page

  function surveyState() {
    if (!survey) return null;
    const elapsed = Date.now() - survey.startedAt;
    const stopped = survey.stopAt != null && Date.now() - survey.stopAt > 400;
    const perStep = 600;
    const done = Math.min(survey.total, Math.max(0, Math.floor((Math.min(elapsed, survey.stopAt != null ? survey.stopAt - survey.startedAt : elapsed) - 1050) / perStep)));
    const finished = stopped || elapsed > 1050 + survey.total * perStep + 700;
    if (finished && survey.open) {
      survey.open = false;
      remaining = stopped ? Math.max(0, remaining - done) : 0;
      survey.done = stopped ? done : survey.total;
    }
    const d = survey.open ? done : survey.done;
    const phase = !survey.open ? 'done' : survey.stopAt != null ? 'stopping' : elapsed < 600 ? 'preparing' : elapsed < 1050 ? 'readingDirectory' : d >= survey.total ? 'saving' : 'running';
    const label = { done: stopped ? 'arrêté' : 'réussi', stopping: 'Arrêt demandé', preparing: 'Préparation', readingDirectory: 'Lecture AD', saving: 'Enregistrement', running: 'En cours' }[phase];
    const inFlight = phase === 'running' ? 1 : 0;
    const saves = phase === 'saving' ? 1 : 0;
    return {
      id: survey.id, family: 'inventory', type: 'WMI', scopeDn: 'OU=Bordeaux,OU=Postes,DC=example,DC=local', scopeName: 'Bordeaux et sous-OU', total: survey.total, done: d,
      failed: d > 4 ? 1 : 0, phase, phaseLabel: label, open: survey.open, stopRequested: survey.stopAt != null, startedAt: iso(survey.startedAt), endedAt: survey.open ? null : iso(Date.now()),
      status: `${int(d)}/${int(survey.total)} postes traités · ${count(d > 4 ? 1 : 0, 'lecture non confirmée', 'lectures non confirmées')} · 0 erreur de ping · ${count(inFlight, 'lecture en cours', 'lectures en cours')} · ${count(saves, 'enregistrement en attente', 'enregistrements en attente')} · 0 poste non relu faute de capacité.`,
      pingErrors: 0, inFlight, pendingSaves: saves, skipped: 0,
    };
  }

  function batchRow() {
    const s = surveyState();
    if (!s?.open) return null;
    const order = [['preparing', 'Préparation'], ['readingDirectory', 'Lecture AD'], ['confirming', 'À confirmer'], ['running', 'En cours'], ['saving', 'Enregistrement']];
    const at = s.phase === 'stopping' ? 3 : order.findIndex(([c]) => c === s.phase);
    const elapsed = Date.now() - Date.parse(s.startedAt);
    return {
      id: `batch:${s.id}`, reference: s.id.replace(/-/g, '').padEnd(8, '0').slice(0, 8), operation: 'operations.survey.resume', screen: 'operations', label: `Lot ${s.type} · ${s.scopeName}`,
      kind: 'batch', kindLabel: 'Lot de collecte', foreground: true, listed: true, state: s.stopRequested ? 'stopRequested' : 'running', stateLabel: s.phaseLabel,
      tone: s.stopRequested ? 'warn' : 'info', icon: s.stopRequested ? 'pause' : 'activity', outcome: null, outcomeLabel: null, startedAt: s.startedAt, endedAt: null,
      durationMs: elapsed, durationText: ms(elapsed), dominantLabel: null, dominantMs: null, volume: s.done, volumeText: count(s.done, 'élément', 'éléments'),
      canStop: !s.stopRequested, stopReason: s.stopRequested ? `Arrêt demandé${COLON}Lot ${s.type} · ${s.scopeName}. La lecture est encore active.` : null, detail: s.status,
      access: `Relevé fictif des postes${COLON}aucune sonde ne part.`, advice: null, next: `Attendre la fin ou arrêter la lecture${COLON}ce qui est déjà lu est conservé.`, category: null,
      text: `Lot ${s.type} · ${s.scopeName} → ${s.phaseLabel} (${s.status})`, dropped: 0,
      phases: [{ phase: 'request', label: 'Demande confirmée par l’opérateur', atMs: 0, durationMs: null, durationText: 'non mesurée', measured: false, detail: null, outcome: null }],
      progress: {
        done: s.done, total: s.total, failed: s.failed, phase: s.phaseLabel, header: `${s.type} · ${s.done}/${s.total}`, counters: s.status, pingErrors: 0, inFlight: s.inFlight,
        pendingSaves: s.pendingSaves, skipped: 0, steps: order.map(([c, l], n) => ({ phase: c, label: l, state: n < at ? 'done' : n === at ? 'current' : 'todo' })),
      },
    };
  }

  function offer() {
    const open = survey?.open;
    return {
      resumable: !open && remaining > 0, remaining: open ? 0 : remaining, total: 36, family: 'inventory', type: 'WMI', scopeName: 'Bordeaux et sous-OU',
      scopeDn: 'OU=Bordeaux,OU=Postes,DC=example,DC=local', interruptedAt: iso(REF - 130 * MIN),
      reason: open ? `Relevé en cours${COLON}s’il est arrêté, ses postes restants seront proposés ici.`
        : remaining > 0 ? `Relevé d’inventaire (WMI) de l’OU Bordeaux interrompu il y a 2${NBSP}h 10${COLON}${count(remaining, 'poste restant', 'postes restants')} sur 36. «${NBSP}Reprendre${NBSP}» ne lit que ces postes, après confirmation.`
          : `Aucun relevé interrompu${COLON}rien à reprendre.`,
      offered,
    };
  }

  const RUNS = [
    ['directory', 'Objets AD', 'Postes et sous-OU', 'OU=Postes', 12, 'success', '466 objets AD', 12, ''],
    ['presence', 'Ping', 'Paris et sous-OU', 'OU=Paris,OU=Postes', 28, 'success', '186/186 postes', 28, ''],
    ['inventory', 'WMI', 'Lyon et sous-OU', 'OU=Lyon,OU=Postes', 55, 'partial', '82/82 postes, 8 non confirmés', 55, `8 postes sans réponse WMI (éteints ou filtrés).`],
    ['inventory', 'WMI', 'Bordeaux et sous-OU', 'OU=Bordeaux,OU=Postes', 130, 'error', '21/36 postes', 11_800, `Interrompu${COLON}application fermée pendant le relevé (21 postes lus sur 36).`],
    ['presence', 'Ping', 'Lyon et sous-OU', 'OU=Lyon,OU=Postes', 302, 'success', '82/82 postes', 302, ''],
    ['presence', 'Ping', 'Marseille et sous-OU', 'OU=Marseille,OU=Postes', 1680, 'partial', '74/74 postes, 3 non confirmés', 1680, `Sondes refusées pour 3 postes (pare-feu du site).`],
  ];

  // ---------------------------------------------------------------- operations

  return {
    'operations.overview': async (args) => {
      requireNone(args);
      await sleep(60);
      const list = receiptsList();
      const a = activity();
      const listed = a.recent.filter((r) => r.listed);
      return {
        at: iso(Date.now()), mode: 'simulation', simulation: true, receiptsTotal: list.total, receiptsPending: list.pending, receiptsUnreadable: 0, receiptsReadable: true,
        receiptsPersistent: false, receiptsSummary: list.summary, pill: pill(list), tasks: a.summary, sessionTasks: listed.length + a.open.length,
        sessionFailures: listed.filter((r) => ['refused', 'failed', 'unknown', 'timedOut'].includes(r.outcome)).length,
        successPercent: listed.length ? Math.round((1000 * listed.filter((r) => r.outcome === 'succeeded').length) / listed.length) / 10 : null,
        engine: { count: 0, p50: null, p95: null, max: null, p95Stated: false, minimumForP95: 20 }, writeKinds: SERVED, hiddenAutomatic: a.recent.length - listed.length,
        note: `Simulation${COLON}les écritures ne touchent que l’annuaire fictif en mémoire${NBSP}; reçus marqués «${NBSP}simulé${NBSP}».`,
      };
    },
    'operations.receipts': (args) => { requireNone(args); return receiptsList(); },
    'operations.center': (args) => {
      requireNone(args);
      const list = receiptsList();
      const a = activity();
      const [state, tone] = writeState(list);
      return { at: iso(Date.now()), pill: pill(list), receiptsReadable: true, writeState: state, writeTone: tone, summary: a.summary, open: a.open, attention: a.recent.filter((r) => r.listed && ['refused', 'failed', 'unknown', 'timedOut'].includes(r.outcome)).length, note: a.note };
    },
    'operations.interface.report': (args) => {
      const values = readObject(args, ['renders', 'stall']);
      const renders = Array.isArray(values.renders) ? values.renders.length : 0;
      return { kept: renders, logged: !!values.stall };
    },
    'operations.activity': (args) => { requireNone(args); return activity(); },
    'operations.task.stop': (args) => {
      const id = getString(readObject(args, ['id']), 'id');
      const batch = batchRow();
      if (id.startsWith('batch:') && batch && batch.id === id) {
        survey.stopAt = Date.now();
        return batchRow() ?? batch;
      }
      if (!id.startsWith('batch:') && !/^[0-9a-f]{32}$/.test(id)) throw invalid(`${quote('id')} doit être un identifiant de tâche.`);
      throw fail('operations.taskUnknown', `Tâche introuvable ou déjà terminée${COLON}rien n’a été arrêté.`);
    },
    'operations.receipts.detail': async (args) => {
      const id = getString(readObject(args, ['id']), 'id');
      const r = await writes.operations['write.receipts.get']({ id });
      return detailOf(r);
    },
    'operations.receipts.review': async (args) => {
      const values = readObject(args, ['id', 'reason']);
      const id = getString(values, 'id');
      const reason = getString(values, 'reason').trim();
      if (reason.length < 12 || reason.length > 240) throw fail('receipt.reviewInvalid', `Motif de la revue${COLON}${count(reason.length, 'caractère', 'caractères')}${COLON}${reason.length < 12 ? '12 au minimum' : '240 au maximum'}.`);
      if (/\b(password|passwd|pwd|pass|motdepasse|mot\s+de\s+passe|secret|token|authorization|api[_-]?key|apikey|client[_-]?secret)\s*[=:]\s*\S+/i.test(reason)) {
        throw fail('receipt.reviewInvalid', `Motif de la revue${COLON}le motif ressemble à un secret${NBSP}: décrivez le contrôle sans recopier de mot de passe, de clé ni de jeton.`);
      }
      return detailOf(await writes.review(id, reason));
    },
    'operations.rules': (args) => {
      requireNone(args);
      return {
        kinds: [
          { kind: 'account.unlock', label: 'Déverrouillage du compte', proof: 'État', check: `Relire lockoutTime${COLON}compte déverrouillé attendu (valeur 0).`, verifiable: true, partial: false, compensable: false, compensation: 'Un déverrouillage ne se compense pas.', available: true },
          { kind: 'account.enabled', label: 'Activation ou désactivation du compte', proof: 'État', check: `Relire userAccountControl${COLON}état activé ou désactivé attendu.`, verifiable: true, partial: false, compensable: true, compensation: 'Compensation possible.', available: false },
          { kind: 'password.reset', label: 'Réinitialisation du mot de passe', proof: 'Date', check: `Relire pwdLastSet${COLON}date postérieure à l’envoi.`, verifiable: true, partial: false, compensable: false, compensation: 'Un mot de passe modifié n’est pas restaurable.', available: false },
          { kind: 'object.update', label: 'Modification de la fiche', proof: 'Attribut', check: 'Relire chaque attribut modifié sur le contrôleur initial.', verifiable: true, partial: false, compensable: true, compensation: 'Compensation possible.', available: false },
          { kind: 'group.member', label: 'Membres du groupe', proof: 'Appartenance', check: 'Relire l’attribut member du groupe.', verifiable: true, partial: false, compensable: true, compensation: 'Compensation possible.', available: false },
          { kind: 'object.delete', label: 'Suppression de l’objet', proof: 'Absence', check: 'Relire l’objet par son GUID : une absence constatée est requise.', verifiable: true, partial: false, compensable: false, compensation: 'Une suppression ne se compense pas ici.', available: false },
        ],
        lifecycles: [],
        note: `1 type d’écriture servi dans ce mode${COLON}account.unlock.`,
      };
    },
    'operations.health': async (args) => {
      requireNone(args);
      await sleep(40);
      const cats = [['localSearch', 'Recherche locale'], ['render', 'Traitement des résultats dans l’interface'], ['local', 'Autres lectures et écritures locales (annuaire fictif en mémoire, reçus, préférences, documents)'],
        ['directory', 'Lectures de l’annuaire fictif'], ['computers', 'Collecte fictive sur les postes'], ['writes', 'Écritures sur l’annuaire fictif']];
      const empty = { count: 0, p50: null, p95: null, max: null, p95Stated: false, minimumForP95: 20 };
      return {
        at: iso(Date.now()), memoryMb: null,
        categories: cats.map(([id, label]) => ({ id, label, summary: empty, text: `${label}${COLON}aucune mesure dans cette session.`, histogram: [0, 0, 0, 0, 0, 0, 0, 0], histogramLabels: BINS })),
        slow: [], traceFaults: 0, localSave: `En mémoire uniquement${COLON}stockage local indisponible ou désactivé dans ce mode, rien n’est enregistré sur le disque.`, localSaveTone: 'info',
        sqlite: `Base locale${COLON}aucune base SQLite ouverte en simulation (annuaire fictif en mémoire)${NBSP}; aucune attente de verrou possible.`,
        providers: [`WMI · 3 cibles (PC-LIL-0007, PC-MRS-0019, PC-PAR-0112)${COLON}reprise progressive, une lecture de fond de plus à chaque réponse.`],
        collection: [
          `Actions explicites de l’opérateur${COLON}aucune demande terminée dans cette session${NBSP}; départ immédiat, sans file d’attente.`,
          `Lectures automatiques (affichage, actualisations)${COLON}aucune demande terminée dans cette session${NBSP}; départ immédiat, sans file d’attente.`,
          `Écritures${COLON}canal unique, une à la fois${NBSP}; aucune écriture dans cette session.`,
        ],
        writeWaits: empty, note: `Aperçu dans un navigateur${COLON}aucune mesure du moteur.`,
      };
    },
    'operations.engine': async (args) => {
      requireNone(args);
      const list = receiptsList();
      const [state, tone] = writeState(list);
      return {
        at: iso(Date.now()), product: 'Domenia', version: '2.0.0', runtime: 'Aperçu', os: navigator.userAgent.includes('Windows') ? 'Windows' : 'Navigateur', is64Bit: true, memoryMb: null,
        mode: 'Simulation', readOnly: false, writeState: state, writeTone: tone, receipts: `En mémoire seulement (aperçu).`, preferences: 'Stockage du navigateur.', operations: 0, tasks: 0, taskLines: [],
        notes: [`Aperçu dans un navigateur${COLON}aucun moteur, aucune requête.`],
      };
    },
    'operations.stats': async (args) => {
      requireNone(args);
      const row = (operation, label, kind, kindLabel, samples, avg, p50, p95, bytes) => ({
        operation, label, screen: operation.split('.')[0], kind, kindLabel, samples, sessionSamples: 0, averageMs: avg, medianMs: p50, p95Ms: p95, perItemMs: avg, averageItems: 1,
        successPercent: 100, lastRun: iso(REF - 3 * 60 * MIN), averageBytes: bytes, bytesPerSecond: bytes ? Math.round(bytes / (avg / 1000)) : null, remoteAttempts: 0, fallbackPercent: null,
      });
      return {
        generatedAt: iso(Date.now()), samples: 96, operations: 4, history: true, summary: '96 mesures sur 4 types d’opération (dont 0 de cette session).',
        note: `Aperçu dans un navigateur${COLON}historique d’illustration.`,
        rows: [row('dashboard.summary', 'Tableau de bord', 'localRead', 'Lecture locale', 41, 212.4, 205, 296, null), row('dashboard.widget.refresh', 'Actualisation d’un widget', 'networkRead', 'Lecture (annuaire fictif)', 27, 688.1, 660, 951, 1840),
          row('directory.ou.children', 'Lecture d’une branche d’OU', 'localRead', 'Lecture locale', 22, 128.3, 120, 181, null), row('write.execute', 'Exécution d’une écriture', 'write', 'Écriture simulée', 6, 801.5, 790, null, 3900)],
      };
    },
    'operations.journal': async (args) => {
      requireNone(args);
      const rows = h.journal();
      const lines = rows.slice(0, 400).map((e) => ({ at: iso(e.at), label: e.label, tone: e.tone, origin: e.at <= REF ? 'simulation' : 'session' }));
      return { at: iso(Date.now()), session: lines.filter((l) => l.origin === 'session').length, source: lines.filter((l) => l.origin !== 'session').length, lines, note: `Journal de la session et journal fictif de l’aperçu.` };
    },
    'operations.runs': async (args) => {
      requireNone(args);
      await sleep(80);
      const current = surveyState();
      return {
        generatedAt: iso(Date.now()), available: true,
        rows: RUNS.map(([family, type, ou, dn, minutes, status, counts, success, reason]) => ({
          id: `${family}:${dn.toLowerCase()}`, family, type, ou, ouDn: `${dn},DC=example,DC=local`, attemptAt: iso(REF - minutes * MIN), status,
          statusLabel: { success: 'réussi', partial: 'partiel', error: 'en échec', cancelled: 'arrêté' }[status], tone: { success: 'ok', partial: 'warn', error: 'alert', cancelled: 'off' }[status],
          counts, successAt: iso(REF - success * MIN), reason,
        })),
        current, offer: offer(), currentText: current?.open ? `${current.type} · ${current.scopeName} — ${current.status}` : 'Aucun relevé en cours.',
        note: `Relevés fictifs de l’aperçu${COLON}aucune sonde ne part.`,
      };
    },
    'operations.survey.resume': async (args) => {
      const values = readObject(args, ['remaining']);
      const n = values.remaining;
      if (!Number.isInteger(n) || n < 1 || n > 100_000) throw invalid(`${quote('remaining')} est obligatoire et doit être un entier de 1 à 100${' '}000.`);
      if (survey?.open) throw fail('operations.surveyBusy', `Un relevé est déjà en cours${COLON}la reprise attendra sa fin. Rien n’a été lu.`);
      if (remaining <= 0) throw fail('operations.surveyNone', `Aucun relevé interrompu à reprendre${COLON}rien n’a été lu.`);
      if (n !== remaining) throw fail('operations.surveyChanged', `Le relevé interrompu a changé depuis son affichage${COLON}relisez-le avant de le reprendre. Rien n’a été lu.`);
      await sleep(180);
      survey = { id: `releve-${String(Date.now() % 100).padStart(2, '0')}`, total: n, startedAt: Date.now(), stopAt: null, open: true, done: 0 };
      offered = true;
      return surveyState();
    },
    'operations.survey.stop': (args) => {
      requireNone(args);
      if (!survey?.open) return null;
      if (survey.stopAt == null) survey.stopAt = Date.now();
      return surveyState();
    },
    'operations.survey.forget': async (args) => {
      requireNone(args);
      if (survey?.open) throw fail('operations.surveyBusy', `Un relevé est en cours${COLON}il ne peut pas être abandonné pendant sa lecture. Arrêtez-le d’abord.`);
      remaining = 0;
      offered = true;
      return offer();
    },
    'operations.survey.postpone': (args) => { requireNone(args); offered = true; return offer(); },
    'operations.blockers': async (args) => {
      requireNone(args);
      const list = receiptsList();
      const lines = [{ tone: 'info', text: `Simulation${COLON}les écritures ne touchent que l’annuaire fictif en mémoire, sans effet réel.`, routeLabel: null, route: null }];
      if (list.pending > 0) lines.push({ tone: 'warn', text: `${list.pending === 1 ? 'Une opération précédente reste à vérifier' : `${int(list.pending)} opérations précédentes restent à vérifier`}${COLON}toutes les nouvelles écritures sont bloquées jusqu’à leur relecture ou leur revue. Consultez les reçus, pas une relance automatique.`, routeLabel: 'Ouvrir les reçus à vérifier', route: 'operations?onglet=recus&filtre=a-verifier' });
      lines.push({ tone: 'info', text: `Reçus en mémoire seulement (capture, E2E ou sans dossier de données)${COLON}ils disparaîtront à la fermeture.`, routeLabel: null, route: null });
      lines.push({ tone: 'info', text: `Actions d’un objet (fiche, déverrouillage, mot de passe, groupes)${COLON}elles demandent un objet choisi dans Rechercher ou dans une liste${NBSP}; aucune sélection n’est gardée d’un écran à l’autre.`, routeLabel: 'Rechercher un objet', route: 'rechercher' });
      lines.push({ tone: 'info', text: `Boutons LAPS et BitLocker${COLON}lectures de secrets pas encore servies dans cette version${NBSP}; aucun secret n’est jamais affiché, copié ni exporté par Opérations.`, routeLabel: null, route: null });
      lines.push({ tone: 'info', text: `Identité des lectures LAPS et BitLocker${COLON}compte de la session (EXAMPLE\\j.martin), sans autre identité ni élévation.`, routeLabel: null, route: null });
      if (!lines.some((l) => l.tone === 'warn' || l.tone === 'alert')) lines.unshift({ tone: 'ok', text: `Aucun blocage commun observé. Un droit précis reste vérifié par la ressource lors de l’action${COLON}consultez son infobulle ou son message.`, routeLabel: null, route: null });
      return {
        at: iso(Date.now()), lines,
        transports: [`Aucune connexion${COLON}annuaire fictif en mémoire, aucune requête LDAP, WMI ni ping ne part.`, `WinRM, PsExec et tâches planifiées distantes${COLON}non utilisés par Domenia 2.`],
        note: `Ce bilan lit uniquement les états de la session${COLON}il ne teste ni ne modifie aucun droit.`,
      };
    },
    'operations.check.run': async (args) => {
      const values = readObject(args, ['full', 'page']);
      const full = getBoolean(values, 'full');
      const page = values.page ?? null;
      await sleep(320);
      const rows = [
        ['Moteur', 'Runtime .NET', 'info', 'Aperçu dans un navigateur : aucun moteur .NET.'],
        ['Sécurité', 'Politique d’écriture', 'ok', `Une seule porte d’écriture (write.execute)${COLON}plan scellé, jeton à usage unique de 5${NBSP}min, reçu avant l’envoi, relecture, jamais rejouée.`],
        ['Sécurité', 'Vérification non destructive', 'ok', `Aucune écriture${COLON}cette vérification ne fait que des lectures.`],
        ['Stockage local', 'Reçus d’écriture', 'info', `En mémoire seulement (capture ou E2E)${COLON}${count(receiptsList().total, 'reçu', 'reçus')}.`],
        ['Annuaire', 'Session', 'ok', 'Compte EXAMPLE\\j.martin · domaine example.local · contrôleur DC01.example.local (annuaire fictif).'],
        ['Annuaire', 'Recherche utilisateur', 'ok', `Exemple${COLON}Camille Bernard.`],
        ...(full ? [['Mesure', 'Recherches répétées', 'ok', `Mesures${COLON}41 / 38 / 44${NBSP}ms (annuaire fictif, 25 objets par recherche).`]] : []),
        ['Interface', 'Politique de sécurité du contenu', page?.strictPolicy ? 'ok' : 'error', page?.strictPolicy ? `Stricte${COLON}scripts et styles de la page seulement, aucune connexion sortante, aucun style en ligne.` : 'Politique de sécurité du contenu absente ou affaiblie.'],
        ['Interface', 'Structure de l’application', page && page.structure >= page.structureTotal ? 'ok' : 'error', `${int(page?.structure ?? 0)}/${int(page?.structureTotal ?? 4)} éléments présents (navigation, barre supérieure, contenu, notifications).`],
        ['Interface', 'Moteur web', page?.webView ? 'ok' : 'info', page?.webView ? `WebView2 ${page.webView}.` : 'Version du moteur web non lue.'],
      ].map(([category, test, status, detail], n) => ({ category, test, status, durationMs: n * 3, detail }));
      const ok = rows.filter((r) => r.status === 'ok').length;
      const errors = rows.filter((r) => r.status === 'error').length;
      const warnings = rows.filter((r) => r.status === 'warn').length;
      const infos = rows.filter((r) => r.status === 'info').length;
      const total = rows.reduce((s, r) => s + r.durationMs, 0);
      const summary = `${int(ok)} OK · ${count(errors, 'erreur', 'erreurs')} · ${count(warnings, 'point à savoir', 'points à savoir')}${infos ? ` · ${int(infos)} pour information` : ''} · ${ms(total)}. Aucune écriture effectuée.`;
      lastCheck = { at: iso(Date.now()), full, ok, errors, warnings, totalMs: total, summary, rows };
      log(`Vérification de l’application ${full ? 'complète' : 'rapide'}${COLON}${summary}`, errors ? 'warn' : 'ok', Date.now());
      return lastCheck;
    },
    'operations.diagnostic.preview': async (args) => {
      readObject(args, ['webView', 'theme', 'interfaceP50Ms', 'interfaceP95Ms', 'interfaceSamples']);
      const json = JSON.stringify({ format: 'Domenia.Diagnostic.3', capturedUtc: iso(Date.now()), containsNames: false, containsMessages: false, containsSecrets: false, containsTargets: false, versions: { domenia: '2.0.0' }, counters: { receiptsPending: receiptsList().pending, simulation: true }, metrics: [], errors: [], traces: [], slowness: [] }, null, 2);
      return {
        format: 'Domenia.Diagnostic.3', json, bytes: new TextEncoder().encode(json).length, sha256: '0'.repeat(64), at: iso(Date.now()),
        preview: [`Versions${COLON}domenia 2.0.0.`, `Compteurs${COLON}tâches ouvertes, reçus à vérifier, mémoire, réactivité de l’interface, lecture seule et mode.`, `Jamais inclus${COLON}mots de passe, clés, jetons, messages d’erreur, noms de comptes, de postes ou de groupes, chemins AD, adresses, chemins de fichiers et contenu des journaux.`],
      };
    },
    'operations.diagnostic.save': (args) => notWritten('Domenia-Diagnostic.json', args),
    'operations.dossier.save': (args) => {
      const values = readObject(args, ['anonymize', 'webView']);
      getBoolean(values, 'anonymize');
      getOptionalString(values, 'webView');
      return notWritten('Domenia-Dossier.zip');
    },
    'operations.export.save': (args) => {
      const values = readObject(args, ['subject', 'csv']);
      const subject = getString(values, 'subject');
      if (!['recus', 'operations', 'statistiques', 'releves', 'verification', 'journal'].includes(subject)) throw invalid(`${quote('subject')} doit désigner une liste de l’écran Opérations.`);
      getString(values, 'csv');
      return notWritten(`Domenia-${subject}.csv`);
    },
  };

  function notWritten(name) {
    return {
      saved: false, path: null, name, folder: null, sha256: '0'.repeat(64), bytes: 0,
      message: `Document préparé, non écrit${COLON}ce mode (capture, E2E ou sans dossier de données) garde tout en mémoire.`, at: iso(Date.now()),
    };
  }

  function detailOf(r) {
    const served = SERVED.includes(r.kind);
    const head = `${r.label} · ${r.target.name} · ${r.pending ? 'à vérifier' : r.verificationLabel.toLowerCase()}.`;
    return {
      receipt: r,
      rule: { kind: r.kind, label: r.label, proof: 'État', check: `Relire lockoutTime${COLON}compte déverrouillé attendu (valeur 0).`, verifiable: true, partial: false, compensable: false, compensation: 'Un déverrouillage ne se compense pas.' },
      compensation: { offered: false, reason: 'Un déverrouillage ne se compense pas.', changes: [], newPlanRequired: true, automatic: false, notCovered: '' },
      actions: {
        selection: r.pending ? `${head} Relecture possible sur le contrôleur initial${NBSP}; à défaut, contrôlez avec un autre outil puis consignez votre revue.` : `${head} Ce reçu est résolu${COLON}il ne bloque plus aucune écriture. Une nouvelle relecture reste possible${COLON}seule une lecture part.`,
        canVerify: served, verifyWhy: served ? null : `Relecture indisponible dans ce mode${COLON}aucun lecteur de ce type d’écriture n’est branché.`,
        canReview: r.pending, reviewWhy: r.pending ? null : `Ce reçu est déjà résolu${COLON}aucune revue n’est nécessaire.`,
        templates: [
          `Vérifié dans la console Utilisateurs et ordinateurs Active Directory sur ${r.controller ?? 'le contrôleur de la session'}${COLON}état attendu constaté.`,
          `Contrôlé avec Get-ADUser sur ${r.controller ?? 'le contrôleur de la session'}${COLON}valeur attendue relue.`,
          `Confirmé par l’utilisateur${COLON}ouverture de session réussie après l’intervention.`,
          `Simulation${COLON}objet contrôlé dans l’annuaire fictif depuis la fiche de Domenia.`,
        ],
      },
      executorAvailable: served,
    };
  }
}
