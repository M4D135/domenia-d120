// Overview of the interface: a welcome band (what the interface offers, the gestures to know) and a personalizable board
// (shell/board.js) fed by local data only — health of the interface, session, operations of the session, notifications,
// recent places, help catalogue, contrast of the theme shown, safeguards. It is also the reference use of the board engine
// for the screens that offer a board (Accueil, Poste, Logiciels): health card, selection of a part (help topics by screen
// open the help browser on that screen), actions of a widget and empty states that offer what fills them.
import { icon } from '../../icons.js';
import { esc } from '../../ui.js';
import { state, quietCall, on } from '../../shell/store.js';
import { notes, exampleNote } from '../../shell/notify.js';
import { loadHelp, helpAreas, helpSource } from '../../shell/help.js';
import { measureContrast, ratioText } from '../../shell/contrast.js';
import { faultCount, pendingRequests, swallowedCount } from '../../shell/guards.js';
import { describeHash, recentAddress } from '../../shell/navigation.js';
import { createBoard } from '../../shell/board.js';
import { SHORTCUTS } from '../../shell/shortcuts.js';
import { blockedTime } from '../../shell/sheets.js';

const NBSP = ' ';

const SCREEN_LABELS = {
  accueil: 'Accueil', rechercher: 'Rechercher', fiche: 'Fiche', comptes: 'Comptes', relations: 'Utilisateurs et postes', poste: 'Poste',
  assistance: 'Assistance', requetes: 'Atelier de requêtes', audit: 'Audit AD', schema: 'Schéma', synchro: 'Synchronisation',
  machine: 'Comptes machine', operations: 'Opérations', parametres: 'Paramètres', shell: 'Aide et interface',
};

export const CATALOG = [
  { key: 'interface.health', title: 'Santé de l’interface', kind: 'score', visuals: ['health', 'score', 'list'], size: 'L', group: 'Vue d’ensemble', icon: 'shield', keywords: 'score état contrôle santé', description: 'Score sur 100 et points à vérifier : contraste du thème, erreurs, demandes en attente, enregistrement des réglages.' },
  { key: 'notes.unread', title: 'Messages non lus', kind: 'number', visuals: ['kpi', 'gauge'], size: 'S', group: 'Vue d’ensemble', icon: 'bell', keywords: 'notifications non lues', description: 'Messages de la session que vous n’avez pas encore lus.' },
  { key: 'session.mode', title: 'Session et mode', kind: 'sheet', visuals: ['sheet', 'list'], size: 'M', group: 'Session', icon: 'wifi', keywords: 'domaine contrôleur compte simulation', description: 'Mode, domaine, contrôleur, compte, OU de travail et écritures de la session.' },
  { key: 'session.cache', title: 'Base locale', kind: 'number', visuals: ['kpi', 'sheet'], size: 'S', group: 'Session', icon: 'database', keywords: 'cache fraîcheur objets', description: 'Objets de la dernière lecture de l’annuaire et son âge.' },
  { key: 'demo.coverage', title: 'Annuaire de démonstration', kind: 'checklist', visuals: ['checklist', 'list'], size: 'M', group: 'Session', icon: 'zap', keywords: 'simulation fictif données', description: 'Catégories d’objets de l’annuaire fictif (simulation).' },
  { key: 'activity.counts', title: 'Opérations de la session', kind: 'series', visuals: ['columns', 'bars', 'kpi'], size: 'M', group: 'Activité', icon: 'activity', keywords: 'lectures reçus tâches', description: 'Lectures en cours et en attente, reçus d’écriture à vérifier et conservés.' },
  { key: 'activity.journal', title: 'Journal des opérations', kind: 'list', visuals: ['list'], size: 'M', group: 'Activité', icon: 'clock', keywords: 'historique journal', description: 'Dernières lignes du journal des opérations de la session.' },
  { key: 'notes.tones', title: 'Messages par nature', kind: 'distribution', visuals: ['donut', 'bars', 'kpi'], size: 'M', group: 'Notifications', icon: 'bell', keywords: 'messages erreurs avertissements', description: 'Messages de la session, par nature.' },
  { key: 'notes.recent', title: 'Derniers messages', kind: 'list', visuals: ['list'], size: 'M', group: 'Notifications', icon: 'bell', keywords: 'bannières messages', description: 'Derniers messages de la session, fermés compris.' },
  { key: 'nav.recent', title: 'Lieux récents', kind: 'list', visuals: ['list', 'sheet'], size: 'M', group: 'Navigation', icon: 'home', keywords: 'historique écrans visités fiches', description: 'Écrans et fiches ouverts récemment, du plus récent au plus ancien.' },
  { key: 'palette.recent', title: 'Commandes récentes', kind: 'list', visuals: ['list'], size: 'S', group: 'Navigation', icon: 'command', keywords: 'palette commandes', description: 'Dernières commandes lancées depuis la palette.' },
  { key: 'help.coverage', title: 'Aide par écran', kind: 'distribution', visuals: ['bars', 'donut', 'kpi'], size: 'M', group: 'Aide', icon: 'info', keywords: 'aide sujets infobulles', description: 'Sujets d’aide par écran (catalogue de Domenia 1) ; un écran de la liste ouvre ses sujets.' },
  { key: 'contrast.theme', title: 'Contraste du thème', kind: 'number', visuals: ['gauge', 'kpi', 'checklist'], size: 'S', group: 'Apparence', icon: 'contrast', keywords: 'wcag lisibilité couleurs', description: 'Paires de couleurs du thème affiché au-dessus du seuil WCAG.' },
  { key: 'prefs.sheet', title: 'Réglages de l’interface', kind: 'sheet', visuals: ['sheet'], size: 'M', group: 'Apparence', icon: 'settings', keywords: 'thème animations menu profil', description: 'Thème, animations, menu, profil d’affichage et infobulles.' },
  { key: 'guards.checks', title: 'Garde-fous', kind: 'checklist', visuals: ['checklist', 'sheet'], size: 'M', group: 'Garde-fous', icon: 'lock', keywords: 'erreurs demandes panneaux confirmations', description: 'Erreurs de l’interface, demandes en attente et temps bloqué par les panneaux depuis le démarrage.' },
];

// Delivered layout: each section fills full rows of four columns (L = three columns, M = two, S = one).
const DEFAULTS = [
  { key: 'interface.health', size: 'L', group: 'Vue d’ensemble' }, { key: 'notes.unread', size: 'S', group: 'Vue d’ensemble' },
  { key: 'session.mode', size: 'M', group: 'Session et activité' }, { key: 'activity.counts', size: 'M', group: 'Session et activité' },
  { key: 'help.coverage', size: 'M', group: 'Aide et navigation' }, { key: 'nav.recent', size: 'M', group: 'Aide et navigation' },
  { key: 'guards.checks', size: 'M', group: 'Garde-fous et réglages' }, { key: 'prefs.sheet', size: 'M', group: 'Garde-fous et réglages' },
];

const PRESETS = [
  { id: 'support', label: 'Support', keys: ['activity.counts', 'activity.journal', 'notes.recent', 'session.mode'] },
  { id: 'apparence', label: 'Apparence', keys: ['contrast.theme', 'prefs.sheet', 'help.coverage'] },
  { id: 'session', label: 'Session', keys: ['session.mode', 'session.cache', 'demo.coverage'] },
];

// Keys of the board of Domenia 1 (Interface board of the team layouts) that have a widget here.
const LEGACY_KEYS = { SessionState: 'session.mode', LocalCache: 'session.cache', Activity: 'activity.counts', Journal: 'activity.journal', Contrast: 'contrast.theme' };

const EXPLAIN = {
  'interface.health': { formula: '100 points, moins 4 par paire de couleurs sous le seuil WCAG, 10 par erreur de l’interface (30 au plus), 10 par demande en attente, 15 si les réglages ne sont gardés que pour la session, 5 par erreur non lue.', scope: 'Interface de ce poste, depuis le démarrage.', criteria: 'Vert à partir de 90, ambre à partir de 70, rouge en dessous.', refresh: 'Mesure de nouveau le contraste et relit les compteurs ; aucune requête réseau.' },
  'notes.unread': { formula: 'Messages affichés depuis le démarrage que vous n’avez pas encore lus (ouvrir le centre les marque lus).', scope: 'Session.' },
  'session.mode': { formula: 'Lecture de session.info au démarrage, puis à chaque changement d’OU de travail.', scope: 'Session ouverte.', refresh: 'Relit la session dans la mémoire du moteur ; aucune requête réseau.' },
  'session.cache': { formula: 'Objets d’annuaire de la dernière lecture enregistrée et date de cette lecture.', scope: 'Base locale (annuaire fictif en simulation).' },
  'demo.coverage': { formula: 'Compte, dans l’annuaire fictif, des objets de chaque catégorie de démonstration.', scope: 'Simulation seulement.', exclusions: 'En mode annuaire, rien n’est compté.' },
  'activity.counts': { formula: 'Compteurs du moteur (lectures) et reçus d’écriture du mode, relus localement.', scope: 'Session.', refresh: 'Relit les compteurs et le fichier des reçus ; aucune écriture n’est renvoyée.' },
  'activity.journal': { formula: 'Les 50 dernières lignes du journal des opérations de la session.', scope: 'Session.' },
  'notes.tones': { formula: 'Messages affichés depuis le démarrage, regroupés par nature (erreur, attention, information, terminé).', scope: 'Session ; un message répété compte une fois.' },
  'notes.recent': { formula: 'Les messages les plus récents, fermés compris.', scope: 'Session.' },
  'nav.recent': { formula: 'Écrans et fiches ouverts récemment (12 au plus). Les adresses qui nomment un objet de l’annuaire restent en mémoire pour la session et ne sont jamais enregistrées.', scope: 'Ce poste.' },
  'palette.recent': { formula: 'Commandes lancées depuis la palette, mémorisées dans les préférences (12 au plus).', scope: 'Ce poste.' },
  'help.coverage': { formula: 'Sujets du catalogue d’aide de Domenia 1, rattachés à l’écran de Domenia 2 qui porte le contrôle.', scope: 'Catalogue livré (Domenia-UX.help.json).', criteria: 'Un écran de la liste ouvre ses sujets dans l’onglet Aide.' },
  'contrast.theme': { formula: 'Rapport de contraste WCAG 2.x de chaque paire réellement peinte, tronqué au centième ; 4,5 pour le texte, 3 pour les grands textes et les graphiques.', scope: 'Thème affiché ; changez de thème pour mesurer les autres.', criteria: 'Couleurs calculées par le navigateur (mélanges compris).' },
  'prefs.sheet': { formula: 'Préférences de l’interface : profil WebView2 de ce poste et préférences locales du moteur.', scope: 'Ce poste, ce mode.' },
  'guards.checks': { formula: 'Exceptions non interceptées, erreurs volontairement ignorées, demandes qui attendent une réponse et temps pendant lequel un panneau modal a bloqué l’interface.', scope: 'Session ; chaque erreur est inscrite au journal technique (nature, écran, nombre).', criteria: 'Seules les écritures de la cible d’une demande attendent ; la navigation et les lectures restent libres.' },
};

const TONE_LEVEL = { alert: 'alert', warn: 'warn', ok: 'ok', info: 'info' };
const time = (iso) => new Date(iso).toLocaleTimeString('fr-FR', { hour: '2-digit', minute: '2-digit' });

/**
 * Health of the interface (pure, tests/web/shell/overview.test.mjs): score out of 100 and the points to check, most serious
 * first, from the contrast failures, the faults, the waiting requests, the persistence of the settings and the unread errors.
 */
export function interfaceHealth({ contrastFailures = 0, faults = 0, requests = 0, persistent = true, unreadAlerts = 0 }) {
  const points = [];
  let score = 100;
  if (contrastFailures > 0) { score -= Math.min(40, contrastFailures * 4); points.push({ level: contrastFailures > 2 ? 'alert' : 'warn', text: `${contrastFailures} paire${contrastFailures > 1 ? 's' : ''} de couleurs sous le seuil WCAG dans le thème affiché`, detail: 'Apparence' }); }
  if (faults > 0) { score -= Math.min(30, faults * 10); points.push({ level: 'alert', text: `${faults} erreur${faults > 1 ? 's' : ''} interne${faults > 1 ? 's' : ''} de l’interface depuis le démarrage`, detail: 'Journal technique' }); }
  if (requests > 0) { score -= requests * 10; points.push({ level: 'warn', text: `${requests} demande${requests > 1 ? 's' : ''} en attente de votre réponse`, detail: 'Écritures de la cible bloquées' }); }
  if (!persistent) { score -= 15; points.push({ level: 'info', text: 'Réglages gardés pour cette session seulement (capture, essai ou disque indisponible)', detail: 'Préférences' }); }
  if (unreadAlerts > 0) { score -= Math.min(20, unreadAlerts * 5); points.push({ level: 'warn', text: `${unreadAlerts} message${unreadAlerts > 1 ? 's' : ''} d’erreur non lu${unreadAlerts > 1 ? 's' : ''}`, detail: 'Centre de notifications' }); }
  score = Math.max(0, Math.min(100, score));
  const state = score >= 90 ? 'ok' : score >= 70 ? 'warn' : 'alert';
  const verdict = score >= 90 ? 'Interface en bon état' : score >= 70 ? 'Quelques points à vérifier' : 'Points à traiter';
  return { score, state, verdict, points };
}

async function load() {
  const now = new Date().toISOString();
  const s = state.session;
  const app = state.app;
  const data = {};
  const all = notes();
  const unread = all.filter((n) => !n.read);
  const contrast = measureContrast();
  const passed = contrast.results.filter((r) => r.passed).length;
  const health = interfaceHealth({
    contrastFailures: contrast.failures, faults: faultCount(), requests: pendingRequests().length,
    persistent: state.engine ? state.engine.persistent : true, unreadAlerts: unread.filter((n) => n.tone === 'alert').length,
  });
  data['interface.health'] = {
    kind: 'score', number: health.score, value: health.score, display: `${health.score}`, unit: 'sur 100', state: health.state, verdict: health.verdict,
    subtitle: `Thème ${({ light: 'clair', dark: 'sombre', contrast: 'contraste élevé' })[document.documentElement.dataset.theme] ?? 'affiché'} · ${passed}${NBSP}/${NBSP}${contrast.results.length} paires conformes`,
    pointsTitle: 'Points à vérifier', items: health.points, reliable: true, clearText: 'Rien à vérifier : contraste, erreurs, demandes et réglages en ordre.',
    action: contrast.failures ? { id: 'contrast', label: 'Voir le contraste', icon: 'contrast' } : { id: 'appearance', label: 'Réglages d’apparence', icon: 'sun' },
    at: now, sources: [{ family: 'Interface', at: now }],
  };
  data['notes.unread'] = {
    kind: 'number', number: unread.length, value: unread.length, display: String(unread.length), unit: unread.length > 1 ? 'messages' : 'message',
    state: unread.some((n) => n.tone === 'alert') ? 'alert' : unread.length ? 'warn' : 'ok',
    subtitle: unread.length ? `${all.length} message${all.length > 1 ? 's' : ''} dans la session` : 'Tout est lu', at: now,
  };
  data['session.mode'] = {
    kind: 'sheet', value: app?.modeLabel ?? '—', detail: s?.connection?.label ?? '',
    items: [
      { label: 'Mode', value: app?.modeLabel ?? '—', detail: app?.modeDetail ?? '' },
      { label: 'Domaine', value: s?.domain?.dnsName ?? '—' },
      { label: 'Contrôleur', value: s?.controller?.dnsName ?? '—', detail: s?.controller?.site ? `Site ${s.controller.site}` : '' },
      { label: 'Compte', value: s?.account?.login ?? '—' },
      { label: 'OU de travail', value: s?.scope?.label ?? '—', detail: s?.scope ? (s.scope.subtree ? 'Sous-OU comprises' : 'Sans les sous-OU') : '' },
      { label: 'Écritures', value: s ? (s.readOnly ? 'Lecture seule' : (app?.mode === 'simulation' ? 'Essai sur l’annuaire fictif' : 'Admises, avec plan et reçu')) : '—', state: s && !s.readOnly && app?.mode !== 'simulation' ? 'warn' : 'ok' },
    ],
    at: now, sources: [{ family: 'Session', at: now }],
  };
  data['session.cache'] = {
    kind: 'number', number: s?.cache?.objects ?? null, value: s?.cache?.objects ?? null, display: s ? new Intl.NumberFormat('fr-FR').format(s.cache.objects) : '—', unit: 'objets',
    subtitle: s?.cache ? s.cache.label : 'Base non lue', state: s?.cache?.state === 'fresh' ? 'ok' : s?.cache?.state === 'empty' ? 'off' : 'warn',
    detail: s?.cache?.complete === false ? 'Lecture incomplète : chiffres possiblement sous-estimés.' : '', at: s?.cache?.lastReadAt ?? null,
    sources: [{ family: app?.mode === 'simulation' ? 'Annuaire fictif' : 'Base locale', at: s?.cache?.lastReadAt ?? null }],
  };
  let activity = null;
  try { activity = await quietCall('shell.activity'); } catch (err) { console.warn(err); }
  data['activity.counts'] = activity ? {
    kind: 'series', value: activity.active, detail: activity.detail, zeroText: 'Aucune lecture en cours ni en attente, aucun reçu à vérifier.',
    items: [
      { label: 'En cours', value: activity.tasks.running },
      { label: 'En attente', value: activity.tasks.queued },
      { label: 'À vérifier', value: activity.receipts.available ? activity.receipts.pending : null, state: activity.receipts.pending ? 'warn' : 'ok' },
      { label: 'Reçus', value: activity.receipts.available ? activity.receipts.total : null },
    ],
    at: activity.at, sources: [{ family: 'Moteur', at: activity.at }, { family: 'Reçus', at: activity.at }],
  } : { kind: 'series', value: '—', detail: 'Activité indisponible dans cet aperçu.', items: [], empty: 'Activité indisponible dans cet aperçu.', emptyIcon: 'activity' };
  data['activity.journal'] = {
    kind: 'list', value: activity ? activity.journal.length : 0, empty: 'Aucune opération dans cette session pour l’instant : actualisations, exports et écritures s’inscriront ici.', emptyIcon: 'clock',
    emptyAction: { id: 'operations', label: 'Ouvrir Opérations', icon: 'activity' },
    items: (activity?.journal ?? []).slice(0, 8).map((l) => ({ level: TONE_LEVEL[l.tone] ?? 'info', text: l.label, detail: time(l.at) })),
    at: activity?.at ?? null, sources: [{ family: 'Journal', at: activity?.at ?? null }],
  };
  const count = (t) => all.filter((n) => n.tone === t).length;
  data['notes.tones'] = {
    kind: 'distribution', value: all.length, unit: all.length > 1 ? 'messages' : 'message',
    items: [
      { label: 'Erreurs', value: count('alert') }, { label: 'Attention', value: count('warn') },
      { label: 'Informations', value: count('info') }, { label: 'Terminé', value: count('ok') },
    ].filter((i) => i.value > 0),
    empty: 'Aucun message dans cette session.', emptyIcon: 'bell', emptyAction: { id: 'try-notes', label: 'Essayer les bannières', icon: 'sparkles' },
    detail: all.length ? `${unread.length} non lu${unread.length > 1 ? 's' : ''}` : '', at: now, sources: [{ family: 'Session', at: now }],
  };
  data['notes.recent'] = {
    kind: 'list', value: all.length, empty: 'Aucun message dans cette session.', emptyIcon: 'bell', emptyAction: { id: 'try-notes', label: 'Essayer les bannières', icon: 'sparkles' },
    items: all.slice(0, 8).map((n) => ({ level: TONE_LEVEL[n.tone] ?? 'info', text: n.headline, detail: time(n.at) })),
    at: now,
  };
  // Recent places: the screen and what the address names (a fiche, an OU, a tab), most recent first, without the screen shown.
  const here = recentAddress(location.hash);
  const places = [];
  for (const h of state.recentPages.map(recentAddress)) {
    if (!h || h === here || places.some((p) => p.hash === h)) continue;
    const d = describeHash(h, Object.entries(SCREEN_LABELS).map(([id, label]) => ({ id, label })));
    places.push({ hash: h, label: d.label });
    if (places.length >= 8) break;
  }
  data['nav.recent'] = {
    kind: 'list', value: places.length, empty: 'Aucun lieu récent : les écrans et fiches que vous ouvrez s’ajoutent ici.', emptyIcon: 'home',
    emptyAction: { id: 'search', label: 'Ouvrir Rechercher', icon: 'search' },
    items: places.map((p) => ({ level: 'info', text: p.label, detail: p.hash.includes('?') ? 'fiche ou vue' : 'écran' })),
    at: now,
  };
  data['palette.recent'] = {
    kind: 'list', value: state.recentCommands.length, empty: 'Aucune commande lancée depuis la palette (Ctrl K).', emptyIcon: 'command',
    emptyAction: { id: 'palette', label: 'Ouvrir la palette', icon: 'command' },
    items: state.recentCommands.slice(0, 6).map((id) => ({ level: 'info', text: id.replace(/^page:/, 'Écran ').replace(/^screen:/, '').replace(/^theme-/, 'Thème ').replace(/^motion-/, 'Animations ') })),
  };
  try { await loadHelp(); } catch (err) { console.warn(err); }
  const counts = new Map();
  const module = await import('../../shell/help-catalog.js').catch(() => null);
  for (const t of module?.HELP_TOPICS ?? []) counts.set(t[4], (counts.get(t[4]) ?? 0) + 1);
  data['help.coverage'] = {
    kind: 'distribution', value: helpSource()?.count ?? 0, unit: 'sujets',
    // Each screen carries its criterion: a click opens its topics in the help browser.
    items: helpAreas().map(([id, label]) => ({ label, value: counts.get(id) ?? 0, criterion: id })).filter((i) => i.value > 0).sort((a, b) => b.value - a.value),
    detail: 'Infobulles, descriptions accessibles et panneau F1 ; cliquez un écran pour ses sujets.', at: now,
  };
  data['contrast.theme'] = {
    kind: 'number', number: Math.round((passed / Math.max(1, contrast.results.length)) * 100), value: passed, maximum: 100, unit: '%',
    display: `${passed}${NBSP}/${NBSP}${contrast.results.length}`, state: contrast.failures === 0 ? 'ok' : contrast.failures <= 2 ? 'warn' : 'alert',
    detail: `Plus faible${NBSP}: ${ratioText(contrast.minimum)}${NBSP}:${NBSP}1`,
    items: contrast.results.map((r) => ({ label: r.label, value: `${r.text}${NBSP}:${NBSP}1`, state: r.passed ? 'ok' : 'warn' })).sort((a, b) => (a.state === b.state ? 0 : a.state === 'warn' ? -1 : 1)),
    at: now, sources: [{ family: 'Thème affiché', at: now }],
  };
  const p = state.prefs;
  data['prefs.sheet'] = {
    kind: 'sheet', value: p.theme,
    items: [
      { label: 'Thème', value: { light: 'Clair', dark: 'Sombre', contrast: 'Contraste élevé', system: 'Suivre Windows' }[p.theme] },
      { label: 'Animations', value: { full: 'Riches', reduced: 'Réduites', system: 'Suivre Windows' }[p.motion] },
      { label: 'Menu', value: p.navCollapsed ? 'Replié' : 'Déplié', detail: p.navWidth ? `Largeur ${p.navWidth}${NBSP}px` : 'Largeur par défaut' },
      { label: 'Profil d’affichage', value: p.profile === 'expert' && state.policy.expertAllowed !== false ? 'Expert' : 'Essentiel', detail: state.policy.expertAllowed === false ? 'Expert masqué par l’administrateur' : '' },
      { label: 'Infobulles d’aide', value: p.helpTips ? 'Actives' : 'Coupées' },
      { label: 'Enregistrement', value: state.engine ? (state.engine.persistent ? 'Préférences du moteur et profil WebView2' : 'Mémoire de la session (capture, essai)') : 'Profil WebView2', state: state.engine && !state.engine.persistent ? 'warn' : 'ok' },
    ],
    action: { id: 'appearance', label: 'Modifier', icon: 'settings' },
  };
  const faults = faultCount();
  const pending = pendingRequests().length;
  const blocked = blockedTime();
  data['guards.checks'] = {
    kind: 'checklist', value: faults + pending,
    items: [
      { label: 'Erreurs internes de l’interface', value: String(faults), state: faults ? 'alert' : 'ok' },
      { label: 'Erreurs ignorées volontairement (tracées)', value: String(swallowedCount()), state: 'info' },
      { label: 'Demandes en attente de réponse', value: String(pending), state: pending ? 'warn' : 'ok' },
      { label: 'Panneaux modaux de la session', value: blocked.count ? `${blocked.count} · ${Math.round(blocked.ms / 1000)}${NBSP}s bloquées` : 'aucun', state: 'info' },
    ],
    at: now,
  };
  let coverage = null;
  try { coverage = await quietCall('shell.demo.coverage'); } catch (err) { console.warn(err); }
  data['demo.coverage'] = coverage?.available ? {
    kind: 'checklist', value: `${coverage.present}/${coverage.total}`, detail: coverage.summary,
    items: coverage.fixtures.map((f) => ({ label: f.label, value: f.count, state: f.present ? 'ok' : 'warn' })),
  } : { kind: 'checklist', value: '—', detail: coverage?.summary ?? 'Disponible en simulation.', items: [], empty: coverage?.summary ?? 'Disponible en simulation.', emptyIcon: 'zap' };
  return data;
}

function welcomeMarkup() {
  const gestures = [
    [['Ctrl', 'K'], 'Aller n’importe où, lancer une commande, chercher une aide ou un objet'],
    [['F1'], 'Aide de l’élément survolé ou qui a le focus, motif d’un bouton grisé'],
    [['Ctrl', 'L'], 'Journal de la session'],
    [['Alt', '←'], 'Écran précédent, avec son état'],
  ];
  return `<section class="sh-welcome card">
    <div class="sh-welcome-text">
      <h2>Tout ce qui est commun aux écrans</h2>
      <p class="muted">Aide contextuelle des 820 contrôles, palette, notifications de la session, apparence, accessibilité, sélecteurs partagés et exports. Rien n’est lu dans l’annuaire sans votre geste.</p>
      <div class="sh-welcome-chips">
        <span class="chip">${icon('info')}820 sujets d’aide</span>
        <span class="chip">${icon('command')}${SHORTCUTS.length} raccourcis</span>
        <span class="chip" data-welcome="unread"></span>
      </div>
    </div>
    <ul class="sh-gestures" aria-label="Gestes essentiels">${gestures.map(([keys, text]) => `<li><span class="sh-gesture-keys">${keys.map((k) => `<kbd>${esc(k)}</kbd>`).join('')}</span><span>${esc(text)}</span></li>`).join('')}</ul>
  </section>`;
}

export function renderOverview(panel, ctx) {
  panel.innerHTML = `${welcomeMarkup()}<div class="sh-tab-intro"><p><strong>Votre tableau de l’interface</strong>${NBSP}: «${NBSP}Personnaliser${NBSP}» déplace, redimensionne ou change la représentation des widgets${NBSP}; tout est local et chaque changement s’annule.</p></div><div class="sh-overview-board"></div>`;
  const paintUnread = () => {
    const chip = panel.querySelector('[data-welcome="unread"]');
    const n = notes().filter((x) => !x.read).length;
    chip.classList.toggle('warn', n > 0);
    chip.innerHTML = `${icon('bell')}${n ? `${n} notification${n > 1 ? 's' : ''} non lue${n > 1 ? 's' : ''}` : 'Aucune notification non lue'}`;
  };
  paintUnread();
  const board = createBoard(panel.querySelector('.sh-overview-board'), {
    id: 'interface',
    team: 'Interface',
    title: 'Tableau de l’interface',
    catalog: CATALOG,
    defaults: DEFAULTS,
    presets: PRESETS,
    legacyKeys: LEGACY_KEYS,
    load,
    explain: (key) => EXPLAIN[key] ?? {},
    summaryHead: () => `Aide et interface · ${state.session?.domain?.dnsName ?? 'session'} · ${new Date().toLocaleString('fr-FR', { dateStyle: 'short', timeStyle: 'short' })}`,
    // A screen of the help coverage opens its topics in the help browser (the part carries its criterion).
    onSegment: (key, part) => {
      if (key !== 'help.coverage' || !part.selected || !part.criterion) return;
      board.clearSelection(key);
      ctx.go('shell', { onglet: 'aide', ecran: part.criterion.split('|')[0] });
    },
    onAction: (key, action) => {
      if (action === 'contrast' || action === 'appearance') ctx.go('shell', { onglet: 'apparence' });
      else if (action === 'operations') ctx.go('operations');
      else if (action === 'search') ctx.go('rechercher');
      else if (action === 'palette') ctx.openPalette();
      else if (action === 'try-notes') ['info', 'warn'].forEach((tone) => exampleNote(tone));
    },
  });
  const onRefresh = (e) => { e.preventDefault(); board.reload(); ctx.announce('Tableau de l’interface actualisé.'); };
  window.addEventListener('domenia:refresh', onRefresh);
  // Theme, motion and display choices change what the board shows (settings, contrast of the theme): read again once the
  // new theme is painted (after the cross-fade of the window).
  let timer = 0;
  const later = () => { clearTimeout(timer); timer = setTimeout(() => board.reload(), 650); };
  const offPrefs = on('prefs', later);
  const offNotes = on('notes', () => { paintUnread(); later(); });
  const offPolicy = on('policy', later);
  const observer = new MutationObserver(later);
  observer.observe(document.documentElement, { attributes: true, attributeFilter: ['data-theme'] });
  return () => {
    clearTimeout(timer);
    offPrefs();
    offNotes();
    offPolicy();
    observer.disconnect();
    window.removeEventListener('domenia:refresh', onRefresh);
    board.destroy();
  };
}
