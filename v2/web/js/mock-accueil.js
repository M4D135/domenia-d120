// Browser preview of the Accueil operations (docs/ops/accueil.md, PLATFORM.md § 2.6): same names, result shapes and error codes
// as the engine (AccueilOperations, AccueilService), on a short fixture of the fictitious OU « Postes » of example.local (the
// figures of its default seed, rounded). Enough for the page to show every part: fleet board and its exact sets, layout, first
// steps, favourites, last view, refresh (plan, run, stop, state), catalogue, health rules, provenance, analysis and session
// tools. Nothing leaves the page; layout and health choices last for the page only.

const MIN = 60_000;
const HOUR = 60 * MIN;
const DAY = 24 * HOUR;

/**
 * @param {object} h  Helpers of mock.js: readObject, getString, getOptionalString, requireNone, invalid, fail, quote, int, sleep,
 *   log, NBSP, REF, DOMAIN, ROOT_DN, scope (() => current working OU { dn, label, subtree }).
 * @returns {Object<string, (args: any) => any>}
 */
export function createAccueilOperations(h) {
  const { readObject, getString, getOptionalString, requireNone, invalid, fail, quote, int, sleep, log, NBSP, REF, DOMAIN, ROOT_DN } = h;
  const COLON = `${NBSP}: `;
  const iso = (t) => new Date(t).toISOString().replace(/\.\d{3}Z$/, 'Z');
  const day = (t) => { const d = new Date(t); return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`; };
  const plural = (n, one, many) => `${int(n)}${NBSP}${n >= 2 ? many : one}`;
  const hex = (n) => [...crypto.getRandomValues(new Uint8Array(n))].map((b) => b.toString(16).padStart(2, '0')).join('');
  const st = { revision: 0, layout: null, run: null, last: null, plans: new Map(), helpSeen: false, firstSteps: { dismissed: false, finished: true }, snapshots: [] };

  // ---------- Fixture: 30 workstations stand for the 412 of the OU (exact sets are short, the figures are those of the seed) ----------
  const SITES = ['Paris', 'Lyon', 'Marseille', 'Bordeaux'];
  const OS = ['Windows 11 24H2 Entreprise', 'Windows 11 23H2 Entreprise', 'Windows 11 25H2 Entreprise', 'Windows 10 22H2 Entreprise'];
  const rows = Array.from({ length: 30 }, (_, n) => {
    const site = SITES[n % 4];
    const name = `PC-${site.slice(0, 3).toUpperCase()}-${String(n * 7 + 3).padStart(4, '0')}`;
    const alerts = n % 9 === 0 ? 1 : 0;
    const warnings = n % 4 === 0 ? 1 : 0;
    return {
      name, dn: `CN=${name},OU=${site},OU=Postes,${ROOT_DN}`, guid: `00000000-0000-4000-8000-${String(n + 1).padStart(12, '0')}`, ou: `Postes${NBSP}› ${site}`,
      state: 'Activé', system: OS[n % 4], lastLogon: day(REF - (n % 11) * DAY), presence: n % 5 === 0 ? 'Sans réponse' : 'En ligne',
      diskFree: n % 9 === 0 ? 6.4 : 18 + (n % 7) * 9, uptimeDays: n % 6 === 0 ? 34 : n % 12, model: n % 2 ? 'Latitude 5440' : 'EliteBook 840 G9', user: `u${100 + n}`,
      score: n % 13 === 0 ? null : Math.max(0, 100 - 25 * alerts - 10 * warnings), alerts, warnings,
    };
  });
  const set = (pred) => rows.filter(pred).map((r) => r.guid);
  const SETS = {
    'fleet.machines': set(() => true), 'fleet.enabled': set(() => true), 'fleet.attention': set((r) => r.alerts || r.warnings),
    'fleet.health|Sans problème': set((r) => r.score === 100), 'fleet.health|Problèmes': set((r) => r.score !== null && r.score < 100), 'fleet.health|Incomplets': set((r) => r.score === null),
    'fleet.lowdisk': set((r) => r.diskFree < 10), 'fleet.win10': set((r) => r.system.startsWith('Windows 10')), 'fleet.stale': set((r) => r.presence === 'Sans réponse'),
    'missing:lowdisk': set((r) => r.score === null),
  };
  OS.forEach((os, k) => { SETS[`fleet.versions|${os}`] = set((r) => r.system === os); });
  const part = (label, value, key, tone = null) => ({ label, value, tone, targetsKey: key, targets: SETS[key]?.length ?? value });
  const entry = (key, title, group, kind, value, number, detail, extra = {}) => ({
    key, title, group, kind, value, number, unit: null, detail, tone: null, centerText: null, subtitle: null, items: [], points: [], targets: number, targetsKey: SETS[key] ? key : null, action: null, measured: true, ...extra,
  });
  const points = Array.from({ length: 30 }, (_, k) => ({ date: day(REF - (29 - k) * DAY), label: '', value: 14 + Math.round(4 * Math.sin(k / 4)) }));

  function board() {
    st.revision += 1;
    const sc = h.scope();
    const health = {
      score: 82, verdict: 'Parc plutôt sain', tone: 'ok', detail: `334 postes sur 404 évalués sans point détecté · 8 non évalués`, badge: null,
      pointsTitle: 'Points à vérifier', alerts: 1, warnings: 3, information: 2, masked: 0, total: 412, assessed: 404, healthy: 334, problems: 70, unassessed: 8,
      healthyKey: 'fleet.health|Sans problème', problemsKey: 'fleet.health|Problèmes', unknownKey: 'fleet.health|Incomplets',
      points: [
        { id: 'lowdisk', rule: 'Disque critique', level: 'alert', text: `16 postes avec moins de 10${NBSP}% libre sur C:.`, count: 16, targetsKey: 'fleet.lowdisk' },
        { id: 'stale', rule: 'Sans connexion AD', level: 'warn', text: `11 postes sans connexion au domaine depuis 90 jours ou plus${COLON}à vérifier.`, count: 11, targetsKey: 'fleet.stale' },
        { id: 'eos.ended', rule: 'Fin de service', level: 'warn', text: '23 postes sous Windows 10 sans support.', count: 23, targetsKey: 'fleet.win10' },
        { id: 'unreachable', rule: 'Sans réponse', level: 'info', text: `98 postes sans réponse au ping au dernier relevé${COLON}absence de réponse, pas une preuve d’arrêt.`, count: 98, targetsKey: null },
      ],
    };
    const entries = {
      'fleet.health': entry('fleet.health', 'Santé du parc', 'Santé', 'health', 'Parc plutôt sain', 82, health.detail, { unit: `${NBSP}%`, tone: 'ok', targetsKey: 'fleet.health|Sans problème' }),
      'fleet.attention': entry('fleet.attention', 'Points à vérifier', 'Santé', 'list', 'Points à vérifier', 4, `1 critique · 3 à surveiller`, { tone: 'warn', targetsKey: 'fleet.attention' }),
      'fleet.machines': entry('fleet.machines', 'Comptes ordinateur', 'Inventaire du périmètre', 'value', '431', 431, `Tous les comptes AD${COLON}activés, désactivés et état inconnu.`),
      'fleet.enabled': entry('fleet.enabled', 'Comptes AD activés', 'Inventaire du périmètre', 'value', '412', 412, 'Comptes AD activés ; ce nombre ne décrit pas la présence réseau.'),
      'fleet.stale': entry('fleet.stale', 'Sans connexion AD depuis 90 j', 'Inventaire du périmètre', 'value', '11', 11, `lastLogonTimestamp approximatif${COLON}2 dates inconnues, sans rapport avec le ping.`, { tone: 'warn' }),
      'fleet.lowdisk': entry('fleet.lowdisk', 'Disque C: presque plein', 'Inventaire du périmètre', 'value', '16', 16, `Postes avec moins de 10${NBSP}% libre.`, { tone: 'alert' }),
      'fleet.versions': entry('fleet.versions', 'Versions de Windows', 'Versions de Windows', 'distribution', '412', 412, '214 postes sur 412', { centerText: '412 postes', items: OS.map((os, k) => part(os, [214, 96, 58, 23][k], `fleet.versions|${os}`)), targetsKey: null }),
      'fleet.win10': entry('fleet.win10', 'Postes sous Windows 10', 'Versions de Windows', 'value', '23', 23, `Hors LTSC, LTSB et IoT${COLON}fin de service le 14/10/2025.`, { tone: 'alert' }),
      'fleet.trend.problems': entry('fleet.trend.problems', 'Postes à traiter sur 30 jours', 'Évolution', 'timeline', '15', 15, 'Instantanés quotidiens locaux ; un jour sans instantané reste vide.', { points, targetsKey: null }),
    };
    return {
      revision: `${String(st.revision).padStart(8, '0')}${hex(4)}`, computedAt: iso(Date.now()), scope: sc, scopeLabel: `OU ${sc.label}`,
      population: { machines: 431, enabled: 412, disabled: 19, unknown: 0, criteria: 'comptes ordinateur recensés', storeId: 'apercu' },
      entries, health, hints: [], summary: `431 comptes ordinateur dans le périmètre${COLON}412 activés, 19 désactivés.`,
      snapshot: { id: 'actuel', kind: 'current', label: 'Vue actuelle', day: day(REF), computedAt: iso(Date.now()), figures: {} },
    };
  }

  const DEFAULT_LAYOUT = [
    ['fleet.health', 'HealthSummary', 'L', 'Santé'], ['fleet.machines', 'Kpi', 'S', 'Inventaire du périmètre'], ['fleet.enabled', 'Kpi', 'S', 'Inventaire du périmètre'],
    ['fleet.stale', 'Kpi', 'S', 'Inventaire du périmètre'], ['fleet.lowdisk', 'Kpi', 'S', 'Inventaire du périmètre'], ['fleet.versions', 'Pie', 'M', 'Versions de Windows'],
    ['fleet.win10', 'Kpi', 'S', 'Versions de Windows'], ['fleet.trend.problems', 'Line', 'L', 'Évolution'],
  ].map(([key, visual, size, group], n) => ({ id: `b-${key}-${n + 1}`, source: 'builtin', key, visual, size, title: null, paused: false, group }));
  const layout = () => ({ items: st.layout ?? DEFAULT_LAYOUT, customized: Boolean(st.layout), max: 64 });

  const firstSteps = () => ({
    steps: [
      { id: 'connect', number: 1, label: 'Connexion à l’annuaire', text: `Connecté à ${DOMAIN}.`, done: true, enabled: true, current: false, actionLabel: 'Voir la session' },
      { id: 'scope', number: 2, label: 'Choix de l’OU de travail', text: `OU de travail${COLON}${h.scope().label}.`, done: true, enabled: true, current: false, actionLabel: 'Choisir l’OU' },
      { id: 'firstRead', number: 3, label: 'Première lecture', text: 'Première lecture de cette OU enregistrée dans la base locale.', done: true, enabled: true, current: false, actionLabel: 'Mettre à jour la base locale' },
      { id: 'dashboard', number: 4, label: 'Tableau de bord', text: 'Vue d’ensemble calculée depuis la base locale.', done: true, enabled: true, current: false, actionLabel: 'Voir le tableau de bord' },
      { id: 'rights', number: 5, label: 'Vérifier l’application', text: 'Facultatif.', done: false, enabled: true, current: false, actionLabel: 'Vérifier l’application' },
    ],
    next: null, done: true, deferred: '', dismissed: st.firstSteps.dismissed, helpSeen: st.helpSeen, readInterrupted: false, offline: false, completed: 4, total: 4, finished: st.firstSteps.finished,
  });

  const STAGES = {
    backup: ['Sauvegarde vérifiée de la base locale', `Sans objet dans l’aperçu${COLON}aucune base locale n’est ouverte.`],
    directory: ['Lecture AD de l’OU', 'Objets de l’OU relus, puis enregistrés dans la base locale.'],
    commit: ['Reçu d’enregistrement local', 'La collecte des postes attend le reçu de la base.'],
    presence: ['Relevé de présence (ping)', 'Un écho par poste actif de l’OU.'],
    inventory: ['Inventaire WMI des postes en ligne', 'WMI seulement sur les postes qui ont répondu et dont une mesure manque.'],
  };
  const MODE_STAGES = { directory: ['backup', 'directory', 'commit'], presence: ['presence'], inventory: ['presence', 'inventory'], all: ['backup', 'directory', 'commit', 'presence', 'inventory'] };

  async function plan(args) {
    const v = readObject(args, ['mode']);
    const mode = getString(v, 'mode');
    if (!['directory', 'presence', 'inventory', 'all', 'resume'].includes(mode)) throw invalid(`${quote('mode')} doit valoir directory, presence, inventory, all ou resume.`);
    if (st.run) throw fail('refresh.running', `Une actualisation de l’OU est déjà en cours${COLON}attendez sa fin ou arrêtez-la.`);
    const sc = h.scope();
    if (sc.dn.toLowerCase() === ROOT_DN.toLowerCase()) throw fail('scope.tooWide', `Choisissez une OU${COLON}aucune mesure de postes sur tout le domaine.`);
    if (mode === 'resume' && !st.last?.resumable) throw fail('refresh.nothingToResume', `Aucune actualisation interrompue à reprendre pour cette OU${COLON}lancez une actualisation complète.`);
    await sleep(120);
    const ids = mode === 'resume' ? st.last.stages.filter((s) => s.state !== 'done' && s.state !== 'na').map((s) => s.id) : MODE_STAGES[mode];
    const p = {
      id: hex(16), mode, title: mode === 'resume' ? 'Reprendre l’actualisation interrompue' : mode === 'all' ? 'Tout actualiser' : mode === 'directory' ? 'Mettre à jour la base locale de l’OU' : mode === 'presence' ? 'Actualiser la présence (ping)' : 'Actualiser l’inventaire (ping puis WMI)',
      summary: `Aperçu du navigateur${COLON}aucune connexion, les étapes sont simulées dans la page.`, scope: sc, targets: 412,
      stages: ids.map((id) => ({ id, label: STAGES[id][0], detail: STAGES[id][1] })), probes: [], probeNames: [], estimateSeconds: 40,
      estimateText: `Durée estimée en mode annuaire${COLON}environ 40${NBSP}s pour 412 postes actifs.`, warnings: [], confirm: mode === 'resume' ? 'Reprendre' : 'Lancer',
      createdAt: iso(Date.now()), expiresAt: iso(Date.now() + 5 * MIN), online: ids.includes('inventory') ? 314 : 0, reused: ids.includes('inventory') ? 287 : 0, reuseDays: 30,
      reuseSince: iso(Date.now() - 30 * DAY), resumeOf: mode === 'resume' ? st.last.id : null, onlineSince: null,
    };
    st.plans.set(p.id, p);
    return p;
  }

  async function run(args, publish) {
    const v = readObject(args, ['planId', 'force']);
    const p = st.plans.get(getString(v, 'planId'));
    st.plans.delete(getString(v, 'planId'));
    if (!p) throw fail('refresh.planUnknown', `Plan d’actualisation inconnu ou déjà utilisé${COLON}préparez de nouveau l’actualisation. Rien n’a été lancé.`);
    const id = hex(8);
    const started = Date.now();
    st.run = { id, plan: p, stages: p.stages.map((s) => ({ ...s, state: 'waiting', startedAt: null, finishedAt: null })), stopping: false };
    for (let k = 0; k < st.run.stages.length; k++) {
      const s = st.run.stages[k];
      if (st.run.stopping) { s.state = 'skipped'; s.detail = `Non lancée${COLON}actualisation arrêtée.`; continue; }
      s.state = 'running';
      publish?.({ runId: id, stage: s.id, state: 'running', label: s.label, detail: s.detail, index: k, count: st.run.stages.length, percent: Math.round((100 * k) / st.run.stages.length) });
      await sleep(s.id === 'backup' ? 200 : 700);
      s.state = s.id === 'backup' ? 'na' : st.run.stopping ? 'stopped' : 'done';
      if (s.id === 'inventory') s.detail = v.force ? 'Inventaire relu sur 314 postes ayant répondu au ping' : `Inventaire relu sur 27 postes ayant répondu au ping · 287 déjà à jour, non contactés`;
      publish?.({ runId: id, stage: s.id, state: s.state, label: s.label, detail: s.detail, index: k, count: st.run.stages.length, percent: Math.round((100 * (k + 1)) / st.run.stages.length) });
    }
    const status = st.run.stopping ? 'cancelled' : 'success';
    st.last = {
      id, mode: p.mode, status, label: status === 'success' ? `Tout actualisé${COLON}OU ${p.scope.label}` : `Actualisation arrêtée${COLON}OU ${p.scope.label}`, scope: p.scope,
      startedAt: iso(started), finishedAt: iso(Date.now()), stages: st.run.stages, runs: [], stopping: st.run.stopping, forced: Boolean(v.force),
      resumable: status !== 'success' && st.run.stages.some((s) => ['skipped', 'stopped'].includes(s.state)),
    };
    st.run = null;
    log(st.last.label, status === 'success' ? 'ok' : 'info', Date.now());
    return st.last;
  }

  const noRows = (label) => ({ total: 0, rows: [], label });
  return {
    'accueil.board': async (args) => { requireNone(args); await sleep(260); return board(); },
    'accueil.targets': async (args) => {
      const v = readObject(args, ['revision', 'key']);
      const key = getString(v, 'key');
      const guids = SETS[key];
      if (!guids) throw fail('targets.unknown', `Ensemble de postes introuvable dans ce calcul${COLON}rien n’a été lu.`);
      await sleep(90);
      return { key, label: key.replace('|', ' · '), total: guids.length, truncated: false, rows: rows.filter((r) => guids.includes(r.guid)), revision: getString(v, 'revision') };
    },
    'accueil.layout': (args) => { requireNone(args); return layout(); },
    'accueil.layout.save': (args) => { const v = readObject(args, ['items']); st.layout = (v.items ?? []).map((i, n) => ({ ...i, id: i.id || `b-${i.key}-${n + 1}`, group: DEFAULT_LAYOUT.find((d) => d.key === i.key)?.group ?? 'Autres widgets' })); return layout(); },
    'accueil.layout.reset': () => { st.layout = null; return layout(); },
    'accueil.widgets.catalog': (args) => {
      requireNone(args);
      return {
        groups: [...new Set(DEFAULT_LAYOUT.map((i) => i.group))].map((g) => ({ name: g, widgets: DEFAULT_LAYOUT.filter((i) => i.group === g).map((i) => ({ key: i.key, title: i.key, group: g, kind: 'value', visual: i.visual, visuals: [i.visual], size: i.size, description: 'Widget de l’aperçu.', default: true })) })),
        visualNames: { Kpi: 'Chiffre clé', Pie: 'Anneau', Line: 'Courbe', HealthSummary: 'Score et points' }, sizeNames: { S: 'Compacte', M: 'Moyenne', L: 'Large' }, presets: [], probes: [], probeCount: 0,
        queriesAvailable: false, queriesText: `«${NBSP}Mes requêtes${NBSP}»${COLON}la bibliothèque de l’atelier de requêtes n’est pas encore disponible dans cette version.`,
      };
    },
    'accueil.refresh.plan': plan,
    'accueil.refresh.run': run,
    'accueil.refresh.stop': (args) => { requireNone(args); if (!st.run) return { stopping: false, label: `Aucune actualisation en cours${COLON}rien à arrêter.` }; st.run.stopping = true; return { stopping: true, label: `Arrêt demandé${COLON}l’étape en cours se termine sans lancer de nouvelle collecte.` }; },
    'accueil.refresh.state': (args) => { requireNone(args); return { running: Boolean(st.run), current: null, last: st.last }; },
    'accueil.firstSteps': (args) => { requireNone(args); return firstSteps(); },
    'accueil.firstSteps.dismiss': (args) => { const v = readObject(args, ['dismissed']); st.firstSteps.dismissed = Boolean(v.dismissed); return firstSteps(); },
    'accueil.help.seen': (args) => { requireNone(args); st.helpSeen = true; return { helpSeen: true }; },
    'accueil.favorites': (args) => { requireNone(args); return { items: [], max: 12 }; },
    'accueil.lastView': (args) => { requireNone(args); return { available: true, text: `Dernière vue enregistrée, non recalculée${COLON}412 postes actifs, dont 70 à traiter.`, computedAt: iso(REF - 3 * HOUR), machines: 412, problems: 70, scopeLabel: `OU ${h.scope().label}` }; },
    'accueil.lastView.save': () => ({ available: true, text: '', computedAt: iso(Date.now()), machines: 412, problems: 70, scopeLabel: `OU ${h.scope().label}` }),
    'accueil.session.details': (args) => { requireNone(args); return { associations: 1186, associationsText: `1${' '}186 liens utilisateur–poste connus dans l’annuaire fictif`, lastCheck: null, calculations: [{ at: iso(Date.now()), milliseconds: 84 }], localWriteFailures: 0, runs: 3, snapshots: st.snapshots.length }; },
    'accueil.health.explain': async () => { await sleep(120); return { summary: `Score = part des postes évalués sans problème${COLON}334${NBSP}/${NBSP}404.`, activeRules: 11, disabledRules: 0, suspendedRules: 0, maskedMachines: 0, population: 412, unknown: 8, assessed: 404, rows: [], policies: [], scope: h.scope().dn, revision: `${String(st.revision).padStart(8, '0')}` }; },
    'accueil.provenance': () => { throw fail('preview.unavailable', `Aperçu du navigateur${COLON}provenance servie par le moteur seulement.`); },
    'accueil.collections': () => noRows('Relevés'),
    'accueil.journal': () => ({ total: 0, rows: [] }),
    'accueil.log.tail': () => ({ path: '%LOCALAPPDATA%\\Domenia\\logs\\domenia.log', available: false, lines: [], truncated: false, summary: `Aperçu du navigateur${COLON}aucun journal technique.` }),
    'accueil.selfCheck': () => ({ checkedAt: iso(Date.now()), ok: 1, warnings: 0, failures: 0, summary: 'Tous les contrôles sont passés.', checks: [{ id: 'mode', label: 'Mode de fonctionnement', tone: 'info', detail: 'Aperçu du navigateur.' }] }),
    'accueil.cache.clear': () => ({ cleared: [], text: `Cache vidé${COLON}la prochaine vue se recalcule.` }),
    'accueil.analysis.snapshots': () => ({ items: [{ id: 'actuel', kind: 'current', label: 'Vue actuelle', day: day(REF), computedAt: iso(Date.now()) }], tables: [] }),
    'accueil.health.policy': () => { throw fail('preview.unavailable', `Aperçu du navigateur${COLON}règles de santé servies par le moteur seulement.`); },
    'accueil.health.exceptions': () => ({ rows: [] }),
    'accueil.snapshot.take': (args) => { const v = readObject(args, ['label']); const s = { id: `manuel-${hex(4)}`, kind: 'manual', label: getOptionalString(v, 'label') ?? 'Instantané manuel', day: day(REF), computedAt: iso(Date.now()) }; st.snapshots.push(s); return s; },
    'accueil.bitlocker.read': () => { throw fail('preview.unavailable', `Aperçu du navigateur${COLON}aucune lecture de l’annuaire.`); },
  };
}
