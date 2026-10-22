// Overview of the interface: a personalizable board (shell/board.js) fed by local data only — session, operations of the
// session, notifications, recent screens and commands, help catalogue, contrast of the theme shown, safeguards. It is also
// the reference use of the board engine for the screens that offer a board (Accueil, Poste, Logiciels).
import { state, quietCall, on } from '../../shell/store.js';
import { notes } from '../../shell/notify.js';
import { loadHelp, helpAreas, helpSource } from '../../shell/help.js';
import { measureContrast, ratioText } from '../../shell/contrast.js';
import { faultCount, pendingRequests } from '../../shell/guards.js';
import { describeHash } from '../../shell/navigation.js';
import { createBoard } from '../../shell/board.js';

const NBSP = ' ';

const CATALOG = [
  { key: 'session.mode', title: 'Session et mode', kind: 'sheet', visuals: ['sheet', 'list'], size: 'M', group: 'Session', icon: 'wifi', keywords: 'domaine contrôleur compte simulation', description: 'Mode, domaine, contrôleur, compte, OU de travail et écritures de la session.' },
  { key: 'session.cache', title: 'Base locale', kind: 'number', visuals: ['kpi', 'sheet'], size: 'S', group: 'Session', icon: 'database', keywords: 'cache fraîcheur objets', description: 'Objets de la dernière lecture de l’annuaire et son âge.' },
  { key: 'demo.coverage', title: 'Annuaire de démonstration', kind: 'checklist', visuals: ['checklist', 'list'], size: 'M', group: 'Session', icon: 'zap', keywords: 'simulation fictif données', description: 'Catégories d’objets de l’annuaire fictif (simulation).' },
  { key: 'activity.counts', title: 'Opérations de la session', kind: 'series', visuals: ['columns', 'bars', 'kpi'], size: 'M', group: 'Activité', icon: 'activity', keywords: 'lectures reçus tâches', description: 'Lectures en cours et en attente, reçus d’écriture à vérifier et conservés.' },
  { key: 'activity.journal', title: 'Journal des opérations', kind: 'list', visuals: ['list'], size: 'M', group: 'Activité', icon: 'clock', keywords: 'historique journal', description: 'Dernières lignes du journal des opérations de la session.' },
  { key: 'notes.tones', title: 'Notifications par nature', kind: 'distribution', visuals: ['donut', 'bars', 'kpi'], size: 'M', group: 'Notifications', icon: 'bell', keywords: 'messages erreurs avertissements', description: 'Messages de la session, par nature.' },
  { key: 'notes.recent', title: 'Derniers messages', kind: 'list', visuals: ['list'], size: 'M', group: 'Notifications', icon: 'bell', keywords: 'bannières messages', description: 'Derniers messages de la session, fermés compris.' },
  { key: 'nav.recent', title: 'Écrans récents', kind: 'distribution', visuals: ['bars', 'list', 'donut'], size: 'M', group: 'Navigation', icon: 'home', keywords: 'historique écrans visités', description: 'Écrans visités récemment, du plus récent au plus ancien.' },
  { key: 'palette.recent', title: 'Commandes récentes', kind: 'list', visuals: ['list'], size: 'S', group: 'Navigation', icon: 'command', keywords: 'palette commandes', description: 'Dernières commandes lancées depuis la palette.' },
  { key: 'help.coverage', title: 'Catalogue d’aide', kind: 'distribution', visuals: ['bars', 'donut', 'kpi'], size: 'M', group: 'Aide', icon: 'info', keywords: 'aide sujets infobulles', description: 'Sujets d’aide par écran (catalogue de Domenia 1).' },
  { key: 'contrast.theme', title: 'Contraste du thème', kind: 'number', visuals: ['gauge', 'kpi', 'checklist'], size: 'S', group: 'Apparence', icon: 'contrast', keywords: 'wcag lisibilité couleurs', description: 'Paires de couleurs du thème affiché au-dessus du seuil WCAG.' },
  { key: 'prefs.sheet', title: 'Réglages de l’interface', kind: 'sheet', visuals: ['sheet'], size: 'M', group: 'Apparence', icon: 'settings', keywords: 'thème animations menu profil', description: 'Thème, animations, menu, profil d’affichage et infobulles.' },
  { key: 'guards.faults', title: 'Erreurs de l’interface', kind: 'number', visuals: ['kpi'], size: 'S', group: 'Garde-fous', icon: 'shield', keywords: 'exceptions erreurs', description: 'Erreurs internes de l’interface comptées depuis le démarrage.' },
  { key: 'guards.requests', title: 'Demandes en attente', kind: 'number', visuals: ['kpi'], size: 'S', group: 'Garde-fous', icon: 'lock', keywords: 'confirmations demandes', description: 'Demandes qui attendent votre réponse et bloquent les écritures de leur cible.' },
];

// Delivered layout: each section fills a full row of four columns (M = two columns, S = one).
const DEFAULTS = [
  { key: 'session.mode', size: 'M', group: 'Session et activité' }, { key: 'activity.counts', size: 'M', group: 'Session et activité' },
  { key: 'notes.tones', size: 'M', group: 'Messages et contrôles' }, { key: 'contrast.theme', size: 'S', group: 'Messages et contrôles' },
  { key: 'guards.faults', size: 'S', group: 'Messages et contrôles' },
  { key: 'help.coverage', size: 'M', group: 'Aide et navigation' }, { key: 'nav.recent', size: 'M', group: 'Aide et navigation' },
  { key: 'activity.journal', size: 'M', group: 'Journal et réglages' }, { key: 'prefs.sheet', size: 'M', group: 'Journal et réglages' },
];

const PRESETS = [
  { id: 'support', label: 'Support', keys: ['activity.counts', 'activity.journal', 'notes.recent', 'session.mode'] },
  { id: 'apparence', label: 'Apparence', keys: ['contrast.theme', 'prefs.sheet', 'help.coverage'] },
  { id: 'session', label: 'Session', keys: ['session.mode', 'session.cache', 'demo.coverage'] },
];

const EXPLAIN = {
  'session.mode': { formula: 'Lecture de session.info au démarrage, puis à chaque changement d’OU de travail.', scope: 'Session ouverte.', refresh: 'Relit la session dans la mémoire du moteur ; aucune requête réseau.' },
  'session.cache': { formula: 'Objets d’annuaire de la dernière lecture enregistrée et date de cette lecture.', scope: 'Base locale (annuaire fictif en simulation).' },
  'demo.coverage': { formula: 'Compte, dans l’annuaire fictif, des objets de chaque catégorie de démonstration.', scope: 'Simulation seulement.', exclusions: 'En mode annuaire, rien n’est compté.' },
  'activity.counts': { formula: 'Compteurs du moteur (lectures) et reçus d’écriture du mode, relus localement.', scope: 'Session.', refresh: 'Relit les compteurs et le fichier des reçus ; aucune écriture n’est renvoyée.' },
  'activity.journal': { formula: 'Les 50 dernières lignes du journal des opérations de la session.', scope: 'Session.' },
  'notes.tones': { formula: 'Messages affichés depuis le démarrage, regroupés par nature (erreur, attention, information, terminé).', scope: 'Session ; un message répété compte une fois.' },
  'notes.recent': { formula: 'Les messages les plus récents, fermés compris.', scope: 'Session.' },
  'nav.recent': { formula: 'Écrans visités récemment, mémorisés dans les préférences (12 au plus).', scope: 'Ce poste.' },
  'palette.recent': { formula: 'Commandes lancées depuis la palette, mémorisées dans les préférences (12 au plus).', scope: 'Ce poste.' },
  'help.coverage': { formula: 'Sujets du catalogue d’aide de Domenia 1, rattachés à l’écran de Domenia 2 qui porte le contrôle.', scope: 'Catalogue livré (Domenia-UX.help.json).' },
  'contrast.theme': { formula: 'Rapport de contraste WCAG 2.x de chaque paire réellement peinte, tronqué au centième ; 4,5 pour le texte, 3 pour les grands textes et les graphiques.', scope: 'Thème affiché ; changez de thème pour mesurer les autres.', criteria: 'Couleurs calculées par le navigateur (mélanges compris).' },
  'prefs.sheet': { formula: 'Préférences de l’interface : profil WebView2 de ce poste et préférences locales du moteur.', scope: 'Ce poste, ce mode.' },
  'guards.faults': { formula: 'Exceptions non interceptées et promesses rejetées sans traitement depuis le démarrage ; chacune est inscrite au journal technique (nature, écran, nombre).', scope: 'Session.' },
  'guards.requests': { formula: 'Confirmations ouvertes qui attendent une réponse.', scope: 'Session.', criteria: 'Seules les écritures de leur cible attendent ; la navigation et les lectures restent libres.' },
};

const TONE_LEVEL = { alert: 'alert', warn: 'warn', ok: 'ok', info: 'info' };

async function load() {
  const now = new Date().toISOString();
  const s = state.session;
  const app = state.app;
  const data = {};
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
    kind: 'number', number: s?.cache?.objects ?? null, display: s ? new Intl.NumberFormat('fr-FR').format(s.cache.objects) : '—', unit: 'objets',
    subtitle: s?.cache ? s.cache.label : 'Base non lue', state: s?.cache?.state === 'fresh' ? 'ok' : s?.cache?.state === 'empty' ? 'off' : 'warn',
    detail: s?.cache?.complete === false ? 'Lecture incomplète : chiffres possiblement sous-estimés.' : '', at: s?.cache?.lastReadAt ?? null,
    sources: [{ family: app?.mode === 'simulation' ? 'Annuaire fictif' : 'Base locale', at: s?.cache?.lastReadAt ?? null }],
  };
  let activity = null;
  try { activity = await quietCall('shell.activity'); } catch (err) { console.warn(err); }
  data['activity.counts'] = activity ? {
    kind: 'series', value: activity.active, detail: activity.detail, zeroText: 'Aucune lecture en cours ni en attente, aucun reçu d’écriture.',
    items: [
      { label: 'En cours', value: activity.tasks.running },
      { label: 'En attente', value: activity.tasks.queued },
      { label: 'À vérifier', value: activity.receipts.available ? activity.receipts.pending : null, state: activity.receipts.pending ? 'warn' : 'ok' },
      { label: 'Reçus', value: activity.receipts.available ? activity.receipts.total : null },
    ],
    at: activity.at, sources: [{ family: 'Moteur', at: activity.at }, { family: 'Reçus', at: activity.at }],
  } : { kind: 'series', value: '—', detail: 'Activité indisponible dans cet aperçu.', items: [] };
  data['activity.journal'] = {
    kind: 'list', value: activity ? activity.journal.length : 0, empty: 'Aucune opération dans cette session.',
    items: (activity?.journal ?? []).slice(0, 8).map((l) => ({ level: TONE_LEVEL[l.tone] ?? 'info', text: l.label, detail: new Date(l.at).toLocaleTimeString('fr-FR', { hour: '2-digit', minute: '2-digit' }) })),
    at: activity?.at ?? null, sources: [{ family: 'Journal', at: activity?.at ?? null }],
  };
  const all = notes();
  const count = (t) => all.filter((n) => n.tone === t).length;
  data['notes.tones'] = {
    kind: 'distribution', value: all.length, unit: all.length > 1 ? 'messages' : 'message',
    items: [
      { label: 'Erreurs', value: count('alert') }, { label: 'Attention', value: count('warn') },
      { label: 'Informations', value: count('info') }, { label: 'Terminé', value: count('ok') },
    ].filter((i) => i.value > 0),
    detail: all.length ? `${all.filter((n) => !n.read).length} non lu${all.filter((n) => !n.read).length > 1 ? 's' : ''}` : 'Aucun message dans cette session.',
    at: now, sources: [{ family: 'Session', at: now }],
  };
  data['notes.recent'] = {
    kind: 'list', value: all.length, empty: 'Aucun message dans cette session.',
    items: all.slice(0, 8).map((n) => ({ level: TONE_LEVEL[n.tone] ?? 'info', text: n.headline, detail: new Date(n.at).toLocaleTimeString('fr-FR', { hour: '2-digit', minute: '2-digit' }) })),
    at: now,
  };
  const pages = [];
  for (const h of state.recentPages) {
    const d = describeHash(h, []);
    const id = d.id ?? h;
    const found = pages.find((p) => p.id === id);
    if (found) found.value += 1; else pages.push({ id, label: { accueil: 'Accueil', rechercher: 'Rechercher', fiche: 'Fiche', comptes: 'Comptes', relations: 'Utilisateurs et postes', poste: 'Poste', assistance: 'Assistance', requetes: 'Atelier de requêtes', audit: 'Audit AD', schema: 'Schéma', synchro: 'Synchronisation', machine: 'Comptes machine', operations: 'Opérations', parametres: 'Paramètres', shell: 'Aide et interface' }[id] ?? id, value: 1 });
  }
  data['nav.recent'] = { kind: 'distribution', value: state.recentPages.length, unit: 'adresses', items: pages, detail: pages.length ? 'Nombre d’adresses récentes par écran.' : 'Aucun écran récent.', at: now };
  data['palette.recent'] = {
    kind: 'list', value: state.recentCommands.length, empty: 'Aucune commande lancée depuis la palette.',
    items: state.recentCommands.slice(0, 6).map((id) => ({ level: 'info', text: id.replace(/^page:/, 'Écran ').replace(/^screen:/, '').replace(/^theme-/, 'Thème ').replace(/^motion-/, 'Animations ') })),
  };
  try { await loadHelp(); } catch { /* the overview shows what is known */ }
  const counts = new Map();
  // help.js keeps the topics; the number per screen is recomputed from the generated module once loaded.
  const module = await import('../../shell/help-catalog.js').catch(() => null);
  for (const t of module?.HELP_TOPICS ?? []) counts.set(t[4], (counts.get(t[4]) ?? 0) + 1);
  data['help.coverage'] = {
    kind: 'distribution', value: helpSource()?.count ?? 0, unit: 'sujets',
    items: helpAreas().map(([id, label]) => ({ label, value: counts.get(id) ?? 0 })).filter((i) => i.value > 0).sort((a, b) => b.value - a.value),
    detail: 'Infobulles, descriptions accessibles et panneau F1.', at: now,
  };
  const contrast = measureContrast();
  const passed = contrast.results.filter((r) => r.passed).length;
  data['contrast.theme'] = {
    kind: 'number', number: Math.round((passed / Math.max(1, contrast.results.length)) * 100), maximum: 100, unit: '%',
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
      { label: 'Profil d’affichage', value: p.profile === 'expert' ? 'Expert' : 'Essentiel' },
      { label: 'Infobulles d’aide', value: p.helpTips ? 'Actives' : 'Coupées' },
      { label: 'Enregistrement', value: state.engine ? (state.engine.persistent ? 'Préférences du moteur et profil WebView2' : 'Mémoire de la session (capture, essai)') : 'Profil WebView2', state: state.engine && !state.engine.persistent ? 'warn' : 'ok' },
    ],
  };
  const faults = faultCount();
  data['guards.faults'] = { kind: 'number', number: faults, display: String(faults), unit: faults > 1 ? 'erreurs' : 'erreur', state: faults ? 'warn' : 'ok', subtitle: faults ? 'Inscrites au journal technique' : 'Aucune erreur depuis le démarrage' };
  const pending = pendingRequests().length;
  data['guards.requests'] = { kind: 'number', number: pending, display: String(pending), unit: pending > 1 ? 'demandes' : 'demande', state: pending ? 'warn' : 'ok', subtitle: pending ? 'Écritures de leur cible en attente' : 'Rien ne bloque les écritures' };
  let coverage = null;
  try { coverage = await quietCall('shell.demo.coverage'); } catch (err) { console.warn(err); }
  data['demo.coverage'] = coverage?.available ? {
    kind: 'checklist', value: `${coverage.present}/${coverage.total}`, detail: coverage.summary,
    items: coverage.fixtures.map((f) => ({ label: f.label, value: f.count, state: f.present ? 'ok' : 'warn' })),
  } : { kind: 'checklist', value: '—', detail: coverage?.summary ?? 'Disponible en simulation.', items: [] };
  return data;
}

export function renderOverview(panel, ctx) {
  panel.innerHTML = `<div class="sh-tab-intro"><p>Votre tableau de l’interface : <strong>Personnaliser</strong> pour déplacer, redimensionner ou changer la représentation des widgets ; tout est local et chaque changement s’annule.</p></div><div class="sh-overview-board"></div>`;
  const board = createBoard(panel.querySelector('.sh-overview-board'), {
    id: 'interface',
    team: 'Interface',
    title: 'Tableau de l’interface',
    catalog: CATALOG,
    defaults: DEFAULTS,
    presets: PRESETS,
    load,
    explain: (key) => EXPLAIN[key] ?? {},
    summaryHead: () => `Aide et interface · ${state.session?.domain?.dnsName ?? 'session'} · ${new Date().toLocaleString('fr-FR', { dateStyle: 'short', timeStyle: 'short' })}`,
  });
  const onRefresh = (e) => { e.preventDefault(); board.reload(); ctx.announce('Tableau de l’interface actualisé.'); };
  window.addEventListener('domenia:refresh', onRefresh);
  // Theme, motion and display choices change what the board shows (settings, contrast of the theme): read again once the
  // new theme is painted (after the cross-fade of the window).
  let timer = 0;
  const later = () => { clearTimeout(timer); timer = setTimeout(() => board.reload(), 650); };
  const offPrefs = on('prefs', later);
  const offNotes = on('notes', later);
  const observer = new MutationObserver(later);
  observer.observe(document.documentElement, { attributes: true, attributeFilter: ['data-theme'] });
  return () => {
    clearTimeout(timer);
    offPrefs();
    offNotes();
    observer.disconnect();
    window.removeEventListener('domenia:refresh', onRefresh);
    board.destroy();
  };
}
