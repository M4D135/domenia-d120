// Domenia 2 shell: navigation, top bar, mode banner, preferences, notifications, help, palette, shortcuts and router.
// The shell modules live in js/shell/ (docs/SHELL.md documents what a screen can use through ctx).
import { call } from './bridge.js';
import { icon } from './icons.js';
import {
  esc, errorText, initLive, initPointerEffects, inkFollow, setBusy, motionReduced, cssMs, setToastImpl, copyText, announce,
  formatTime,
} from './ui.js';
import { createRouter } from './router.js';
import { createPalette } from './palette.js';
import { openMenu, openDrawer, setLayoutStore } from './kit/index.js';
import { modalOpen, isTextEntry } from './kit/util.js';
import {
  state, on, emit, setTrackedCall, quietCall, setPrefs, adoptEngine, setLayout, setLists, mirrorAllPrefs, writeActive,
  simulation, NAV_MIN, NAV_MAX, NAV_DEFAULT,
} from './shell/store.js';
import { notify, setCentreOpener, unreadCount, exampleNote } from './shell/notify.js';
import {
  loadHelp, topic, registerHelp, searchTopics, disabledHelp, followRoute, setRouteRunner, ROUTES, DISABLED_REASONS,
} from './shell/help.js';
import { initTips } from './shell/tips.js';
import { openHelpPanel, closeHelpPanel, toggleHelpPanel, helpPanelOpen, setHelpActions } from './shell/help-panel.js';
import { openShortcuts } from './shell/shortcuts.js';
import { CATALOGUE, judge, decide, controlOf } from './shell/commands.js';
import {
  aliasOf, trackHash, canBack, canForward, back, forward, describeHash, setSubject, clearSubject, subjectChip, subjectSummary,
  expertDecision, recentAddress,
} from './shell/navigation.js';
import { beginRequest, requestBlocks, installFaultHandlers, ask } from './shell/guards.js';
import { applyLayoutPlan, watchForcedColors, syncWindowChrome } from './shell/environment.js';
import { announceOnce, auditAccessibility } from './shell/a11y.js';
import { closePopover } from './shell/popover.js';
import { openCentre, openActivity, openSession, openAbout, setNavigator } from './shell/panels.js';
import { pickOu, pickObject, pickFile } from './shell/pickers.js';
import { exportRows, exportCsvText, exportJson, gridExporter, importCsv, importJson } from './shell/exports.js';
import { operationSummary } from './shell/summary.js';
import { statusBadge } from './shell/glyphs.js';
import { createBoard } from './shell/board.js';

const root = document.documentElement;
const NBSP = ' ';

const PAGES = [
  { id: 'accueil', label: 'Accueil', icon: 'home', section: 'Pilotage', keywords: 'tableau de bord kpi widgets' },
  { id: 'rechercher', label: 'Rechercher', icon: 'search', section: 'Pilotage', keywords: 'trouver compte poste groupe parcourir' },
  { id: 'fiche', label: 'Fiche', icon: 'object', section: 'Pilotage', keywords: 'objet attributs utilisateur groupe' },
  { id: 'comptes', label: 'Comptes', icon: 'users', section: 'Pilotage', keywords: 'utilisateurs verrouillés mots de passe' },
  { id: 'relations', label: 'Utilisateurs et postes', icon: 'link', section: 'Pilotage', keywords: 'associations relations' },
  { id: 'poste', label: 'Poste', icon: 'monitor', section: 'Pilotage', keywords: 'ordinateur wmi inventaire assistance' },
  { id: 'assistance', label: 'Assistance', icon: 'lifebuoy', section: 'Outils', keywords: 'support aide ticket' },
  { id: 'requetes', label: 'Atelier de requêtes', icon: 'database', section: 'Outils', keywords: 'requête ldap wmi filtre' },
  { id: 'audit', label: 'Audit AD', icon: 'shield', section: 'Outils', keywords: 'sécurité délégations contrôleurs' },
  { id: 'schema', label: 'Schéma de l’annuaire', icon: 'tree', section: 'Outils', keywords: 'classes attributs schema' },
  { id: 'synchro', label: 'Synchronisation', icon: 'sync', section: 'Outils', keywords: 'réplication sync' },
  { id: 'machine', label: 'Comptes machine', icon: 'chip', section: 'Outils', keywords: 'ordinateur compte machine' },
  { id: 'operations', label: 'Opérations', icon: 'activity', section: 'Outils', keywords: 'journal historique tâches reçus' },
  { id: 'shell', label: 'Aide et interface', icon: 'sparkles', section: null, keywords: 'aide raccourcis apparence accessibilité notifications contraste' },
  { id: 'parametres', label: 'Paramètres', icon: 'settings', section: null, keywords: 'préférences réglages outils' },
];

const THEMES = [
  { id: 'light', label: 'Thème clair', icon: 'sun' },
  { id: 'dark', label: 'Thème sombre', icon: 'moon' },
  { id: 'contrast', label: 'Contraste élevé', icon: 'contrast' },
  { id: 'system', label: 'Thème : suivre Windows', icon: 'monitor' },
];
const MOTIONS = [
  { id: 'full', label: 'Animations riches', icon: 'sparkles' },
  { id: 'reduced', label: 'Animations réduites', icon: 'pause' },
  { id: 'system', label: 'Animations : suivre Windows', icon: 'monitor' },
];

// ---------- Theme and motion ----------

const mqDark = matchMedia('(prefers-color-scheme: dark)');
const mqContrast = matchMedia('(forced-colors: active), (prefers-contrast: more)');
let themeInk = null;

function resolvedTheme() {
  if (state.prefs.theme !== 'system') return state.prefs.theme;
  if (mqContrast.matches) return 'contrast';
  return mqDark.matches ? 'dark' : 'light';
}

function applyTheme() {
  root.dataset.theme = resolvedTheme();
  root.dataset.themePref = state.prefs.theme;
  document.querySelectorAll('.theme-switch button').forEach((b) => b.setAttribute('aria-pressed', String(b.dataset.set === state.prefs.theme)));
  themeInk?.update();
  syncWindowChrome();
}

function applyMotion() {
  root.dataset.motion = state.prefs.motion;
}

// Theme swap cross-fades the whole window through a view transition.
function setTheme(id) {
  if (state.prefs.theme === id) return;
  setPrefs({ theme: id });
  if (document.startViewTransition && !motionReduced()) {
    root.classList.add('theme-swap');
    const vt = document.startViewTransition(applyTheme);
    vt.finished.finally(() => root.classList.remove('theme-swap'));
  } else {
    applyTheme();
  }
  announceOnce('theme', THEMES.find((t) => t.id === id)?.label ?? 'Thème');
}

function toggleTheme() {
  setTheme(resolvedTheme() === 'dark' ? 'light' : 'dark');
}

function setMotion(id) {
  setPrefs({ motion: id });
  applyMotion();
  notify(MOTIONS.find((m) => m.id === id)?.label ?? 'Animations', { tone: 'info', life: 2600 });
}

// ---------- Shell markup ----------

// aria-label keeps the name when the label is hidden (collapsed rail, narrow window); the shortcut is exposed through
// aria-keyshortcuts instead of being read as part of the name.
function navItem(page, n) {
  const kbd = n < 9 ? `<kbd class="nav-kbd" aria-hidden="true">Alt ${n + 1}</kbd>` : '';
  const keys = n < 9 ? ` aria-keyshortcuts="Alt+${n + 1}"` : '';
  return `<a class="nav-item" href="#/${page.id}" data-id="${page.id}" aria-label="${esc(page.label)}"${keys} data-tip="${esc(page.label)}">`
    + `${icon(page.icon)}<span class="nav-label">${esc(page.label)}</span>${kbd}</a>`;
}

function navMarkup() {
  const sections = ['Pilotage', 'Outils'].map((name) => {
    const items = PAGES.map((p, n) => (p.section === name ? navItem(p, n) : '')).join('');
    return `<div class="nav-section">${esc(name)}</div>${items}`;
  }).join('');
  const bottom = PAGES.map((p, n) => (p.section === null ? navItem(p, n) : '')).join('');
  return `<nav class="nav" aria-label="Navigation principale">
    <div class="brand" data-tip="Domenia 2"><span class="brand-mark">${icon('logo')}</span><span class="brand-name"><span class="brand-title">Domenia</span><span class="brand-sub">Active Directory</span></span></div>
    <span class="nav-pill" aria-hidden="true"></span>
    ${sections}
    <div class="nav-spacer"></div>
    ${bottom}
    <button class="nav-account" type="button" aria-haspopup="menu" aria-label="Compte de la session" data-tip="Compte de la session">
      <span class="nav-avatar" aria-hidden="true">${icon('user')}</span>
      <span class="nav-account-text"><span class="nav-account-login">Session…</span><span class="nav-account-domain">Domaine non connecté</span></span>
      ${icon('more', 'nav-account-more')}
    </button>
    <button class="nav-item nav-toggle" type="button" aria-expanded="true" aria-label="Replier le menu" aria-keyshortcuts="Control+B" data-tip="Replier le menu (Ctrl B)">
      ${icon('panel')}<span class="nav-label">Replier le menu</span><kbd class="nav-kbd" aria-hidden="true">Ctrl B</kbd>
    </button>
    <div class="nav-grip" role="separator" aria-orientation="vertical" tabindex="0" aria-label="Largeur du menu" aria-valuemin="${NAV_MIN}" aria-valuemax="${NAV_MAX}" aria-valuenow="${NAV_DEFAULT}" data-tip="Glisser pour élargir le menu · flèches au clavier · double clic : largeur par défaut"></div>
  </nav>`;
}

function topbarMarkup() {
  const themes = THEMES.map((t) => `<button type="button" data-set="${t.id}" aria-pressed="false" aria-label="${esc(t.label)}" data-tip="${esc(t.label)}">${icon(t.icon)}</button>`).join('');
  return `<header class="topbar">
    <div class="sh-history" role="group" aria-label="Historique des écrans">
      <button class="btn ghost icon sm" type="button" data-history="back" aria-label="Écran précédent" aria-keyshortcuts="Alt+ArrowLeft" data-tip="Écran précédent (Alt ←)" disabled>${icon('chevronRight')}</button>
      <button class="btn ghost icon sm" type="button" data-history="forward" aria-label="Écran suivant" aria-keyshortcuts="Alt+ArrowRight" data-tip="Écran suivant (Alt →)" disabled>${icon('chevronRight')}</button>
    </div>
    <button class="search-trigger" type="button" aria-haspopup="dialog" aria-keyshortcuts="Control+K">
      ${icon('search')}<span>Rechercher un compte, un poste, une commande, une aide…</span><kbd>Ctrl K</kbd>
    </button>
    <span class="sh-subject" hidden>
      <button class="sh-subject-open" type="button" data-tip="Ouvrir la fiche de l’objet choisi"><span class="sh-subject-text"></span></button>
      <button class="sh-subject-clear" type="button" aria-label="Désélectionner l’objet" data-tip="Désélectionner : rien n’est relu">${icon('x')}</button>
    </span>
    <div class="topbar-spacer"></div>
    <button class="mode-chip" type="button" hidden aria-haspopup="dialog"><span class="glow-ring" aria-hidden="true"></span><span class="dot pulse"></span><span class="txt"></span><span class="visually-hidden detail"></span></button>
    <button class="live" type="button" data-state="unknown" aria-haspopup="dialog"><span class="dot pulse"></span><span class="label">Connexion…</span></button>
    <span class="sh-slot sh-slot-activity">
      <button class="btn ghost icon sh-activity" type="button" aria-haspopup="dialog" aria-label="Opérations de la session" data-tip="Opérations de la session">${icon('activity')}</button>
      <span class="sh-counter" aria-hidden="true"></span>
      <span class="sh-ring" aria-hidden="true"></span>
    </span>
    <div class="segmented theme-switch" role="group" aria-label="Thème"><span class="thumb" aria-hidden="true"></span>${themes}</div>
    <span class="sh-slot sh-slot-bell">
      <button class="btn ghost icon notif" type="button" aria-haspopup="dialog" aria-label="Notifications" aria-keyshortcuts="Control+L" data-tip="Centre de notifications (Ctrl L)">${icon('bell')}</button>
      <span class="sh-counter" aria-hidden="true"></span>
    </span>
    <button class="btn ghost icon sh-help-btn" type="button" aria-label="Aide" aria-keyshortcuts="F1" data-tip="Aide sur l’écran et ses contrôles (F1)">${icon('info')}<span class="sh-help-dot" aria-hidden="true" hidden></span></button>
    <button class="btn ghost icon sh-more" type="button" aria-haspopup="menu" aria-label="Plus de commandes" data-tip="Thème, animations, historique" hidden>${icon('more')}</button>
    <div class="busy-line" aria-hidden="true"></div>
  </header>`;
}

function shellMarkup() {
  return `<a class="skip-link" href="#main">Aller au contenu</a>
  <div class="aurora" aria-hidden="true"></div>
  <div class="cursor-halo" aria-hidden="true"></div>
  <div class="shell">
    ${navMarkup()}
    ${topbarMarkup()}
    <div class="sim-banner" role="note" hidden>
      <span class="sh-banner-icon">${icon('info')}</span>
      <span class="text"></span>
      <button class="btn ghost xs sh-banner-more" type="button" aria-haspopup="dialog">${icon('info')}Détails</button>
    </div>
    <main class="main" id="main" tabindex="-1"></main>
  </div>
  <div class="toasts" role="region" aria-label="Notifications"></div>`;
}

// ---------- Mode, connection and banner ----------

function showVersion(info) {
  const brand = document.querySelector('.brand');
  if (brand && typeof info?.version === 'string' && info.version) brand.dataset.tip = `Domenia 2 · version ${info.version}`;
}

// The browser preview is recognised by its engine (OPERATIONS.md § 2: webViewRuntime "apercu"); it also reports mode
// "simulation", so the preview wording wins. The chip names the mode in one word; the banner below explains it.
function showMode(info) {
  const preview = info?.webViewRuntime === 'apercu';
  const sim = info?.mode === 'simulation';
  const chip = document.querySelector('.mode-chip');
  if (sim || preview) {
    const detail = info.modeDetail || (preview ? `Aperçu dans un navigateur${NBSP}: données de démonstration intégrées à la page.` : `Annuaire fictif${NBSP}: aucune requête ne part.`);
    chip.querySelector('.txt').textContent = preview ? 'Aperçu' : 'Simulation';
    const writes = 'Écritures d’essai sur l’annuaire fictif seulement, sans aucun effet réel.';
    chip.querySelector('.detail').textContent = `${NBSP}: ${detail} ${writes}`;
    chip.dataset.tip = `${detail} ${writes} Cliquez pour le détail de la session.`;
    chip.dataset.mode = preview ? 'preview' : 'simulation';
    chip.hidden = false;
  }
  paintBanner();
}

/** Mode banner (SIMULATION.md § 2.3): simulation, browser preview, or directory writes admitted. */
function paintBanner() {
  const info = state.app;
  const banner = document.querySelector('.sim-banner');
  const shell = document.querySelector('.shell');
  if (!banner || !shell) return;
  const preview = info?.webViewRuntime === 'apercu';
  let text = info?.banner ?? (preview ? `Aperçu dans un navigateur${NBSP}: données fictives intégrées à la page, aucune requête ne part.` : null);
  let tone = preview ? 'preview' : 'info';
  if (!text && writeActive()) {
    text = `Écriture AD active${NBSP}: chaque écriture passe par un plan, une confirmation, un reçu écrit avant l’envoi et une relecture ; rien n’est rejoué automatiquement.`;
    tone = 'warn';
  }
  if (!text) {
    banner.hidden = true;
    shell.classList.remove('has-banner');
    return;
  }
  banner.dataset.tone = tone;
  // One sentence and one button: the launch detail, the fictitious domain and the write circuit are in « Détails ».
  banner.querySelector('.text').textContent = text;
  banner.querySelector('.sh-banner-more').dataset.tip = info?.modeDetail ? `${info.modeDetail} Détail de la session et du mode.` : 'Détail de la session et du mode.';
  banner.hidden = false;
  shell.classList.add('has-banner');
}

const REACH_OFFLINE = new Set(['directory.unreachable', 'directory.offline', 'ldap.unavailable', 'source.offline']);
const REACH_SLOW = new Set(['directory.timeout', 'operation.timeout', 'ldap.timeout']);

function paintLive() {
  const live = document.querySelector('.live');
  const session = state.session;
  if (!live) return;
  const reach = state.reach;
  let stateName = session?.connection?.state ?? 'unknown';
  let label = session?.connection?.label ?? 'Connexion…';
  let tip = 'Session et connexion : domaine, contrôleur, compte, droits.';
  if (reach.offline) {
    stateName = 'offline';
    label = `Annuaire injoignable${reach.since ? ` depuis ${formatTime(new Date(reach.since).toISOString())}` : ''}`;
    tip = 'Le contrôleur ne répond plus : seules les données déjà lues sont consultables. Aucune relance automatique ; l’indicateur revient seul à la prochaine lecture réussie.';
  } else if (reach.slow) {
    stateName = 'slow';
    label = 'Délai dépassé';
    tip = 'Une requête de l’annuaire a dépassé le délai prévu. Cela ne confirme pas une coupure.';
  } else if (session?.domain?.dnsName && session.connection?.state === 'connected') {
    label = `Connecté à ${session.domain.dnsName}`;
    tip = `Session Active Directory ouverte sur ${session.domain.dnsName}.${session.controller?.dnsName ? ` Contrôleur interrogé${NBSP}: ${session.controller.dnsName}.` : ''} Cliquez pour le détail.`;
  }
  live.dataset.state = stateName;
  live.dataset.tip = tip;
  const current = live.querySelector('.label');
  if (current.textContent !== label) {
    const next = document.createElement('span');
    next.className = 'label';
    next.textContent = label;
    current.replaceWith(next);
    announceOnce('session-badge', label);
  }
}

function paintAccount() {
  const s = state.session;
  const login = s?.account?.login ?? '';
  const domain = s?.domain?.dnsName ?? '';
  const button = document.querySelector('.nav-account');
  if (!button) return;
  button.querySelector('.nav-account-login').textContent = login || 'Aucun compte connecté';
  button.querySelector('.nav-account-domain').textContent = domain || 'Domaine non connecté';
  const initials = (s?.account?.displayName ?? login.split('\\').pop() ?? '').replace(/[^\p{L}\s.-]/gu, ' ').split(/[\s.-]+/).filter(Boolean).slice(0, 2).map((w) => w[0].toUpperCase()).join('');
  button.querySelector('.nav-avatar').innerHTML = initials ? esc(initials) : icon('user');
  button.dataset.tip = login ? `${login} · ${domain || 'domaine inconnu'}` : 'Compte de la session';
  button.setAttribute('aria-label', login ? `Compte de la session${NBSP}: ${login}` : 'Compte de la session');
}

/** Screens call it after session.info or session.setScope: badge, account, banner and title follow. */
export function showConnection(session) {
  if (!session?.connection) return;
  state.session = session;
  paintLive();
  paintAccount();
  paintBanner();
  syncWindowChrome();
  emit('session', session);
  window.dispatchEvent(new CustomEvent('domenia:session', { detail: session }));
}

// ---------- Boot ----------

// Bridge calls in flight: the router waits for none before it signals a screen as ready (data-ready).
let inflight = 0;
let activityTimer = 0;

function hold() {
  inflight += 1;
  let released = false;
  return () => { if (!released) { released = true; inflight -= 1; } };
}

function trackedCall(op, args) {
  inflight += 1;
  setBusy(true);
  return call(op, args).then((data) => {
    if (!op.startsWith('shell.') && !op.startsWith('app.') && (state.reach.offline || state.reach.slow)) {
      state.reach = { offline: false, since: null, slow: false };
      paintLive();
    }
    return data;
  }, (err) => {
    if (REACH_OFFLINE.has(err?.code)) { state.reach = { offline: true, since: state.reach.since ?? Date.now(), slow: false }; paintLive(); }
    else if (REACH_SLOW.has(err?.code)) { state.reach = { ...state.reach, slow: true }; paintLive(); }
    throw err;
  }).finally(() => {
    inflight -= 1;
    setBusy(false);
    if (!op.startsWith('shell.')) scheduleActivity();
  });
}

let lastActivity = null;
function refreshActivity() {
  return quietCall('shell.activity').then((a) => {
    lastActivity = a;
    paintActivity(a);
    return a;
  });
}

function scheduleActivity() {
  clearTimeout(activityTimer);
  activityTimer = setTimeout(() => refreshActivity().catch((err) => console.warn(err)), 1500);
}

function paintActivity(a) {
  const slot = document.querySelector('.sh-slot-activity');
  if (!slot) return;
  const counter = slot.querySelector('.sh-counter');
  const text = a?.counterText ?? '';
  counter.textContent = text;
  counter.classList.toggle('on', !!text);
  slot.classList.toggle('running', (a?.tasks?.running ?? 0) > 0);
  slot.classList.toggle('pending', (a?.receipts?.pending ?? 0) > 0);
  const button = slot.querySelector('.sh-activity');
  button.dataset.tip = a ? `Opérations de la session${NBSP}: ${a.detail}` : 'Opérations de la session';
  button.setAttribute('aria-label', a?.active ? `Opérations de la session${NBSP}: ${a.detail}` : 'Opérations de la session');
}

function paintBell() {
  const slot = document.querySelector('.sh-slot-bell');
  if (!slot) return;
  const n = unreadCount();
  const counter = slot.querySelector('.sh-counter');
  const text = n <= 0 ? '' : n > 99 ? '99+' : String(n);
  if (counter.textContent !== text) {
    counter.textContent = text;
    counter.classList.toggle('on', !!text);
    counter.classList.remove('bump');
    void counter.offsetWidth;
    if (text) counter.classList.add('bump');
  }
  slot.querySelector('.notif').setAttribute('aria-label', n ? `Notifications${NBSP}: ${n} non lue${n > 1 ? 's' : ''}` : 'Notifications');
}

function boot() {
  applyTheme();
  applyMotion();
  initLive();
  const host = document.getElementById('app');
  host.innerHTML = shellMarkup();
  const shell = host.querySelector('.shell');
  const nav = shell.querySelector('.nav');
  const main = shell.querySelector('.main');
  const toggle = nav.querySelector('.nav-toggle');
  const topbar = shell.querySelector('.topbar');

  setTrackedCall(trackedCall);
  setToastImpl((message, o = {}) => notify(message, { tone: o.tone, life: o.life, detail: o.detail, key: o.key, route: o.route, actions: o.actions })?.el ?? null);
  installFaultHandlers();
  themeInk = inkFollow(host.querySelector('.theme-switch'), 'button', 'button[aria-pressed="true"]');
  applyTheme();
  initPointerEffects();
  initTips(nav);
  applyLayoutPlan();
  watchForcedColors(() => { if (state.prefs.theme === 'system') applyTheme(); });

  // Layouts of the lists and panels: kept in the WebView2 profile and mirrored to the preferences of the engine (TRV-062).
  const LAYOUT_PREFIX = 'domenia.kit.v1:';
  setLayoutStore({
    read(key) {
      const engine = state.engine?.layouts?.[key];
      if (engine !== undefined) return engine;
      try { const raw = localStorage.getItem(LAYOUT_PREFIX + key); return raw ? JSON.parse(raw) : null; } catch { return null; }
    },
    write(key, value) {
      try { if (value == null) localStorage.removeItem(LAYOUT_PREFIX + key); else localStorage.setItem(LAYOUT_PREFIX + key, JSON.stringify(value)); } catch { /* memory only */ }
      setLayout(key, value);
    },
  });

  const appInfo = trackedCall('app.info').then((info) => { state.app = info; showMode(info); showVersion(info); syncWindowChrome(); return info; }).catch((err) => {
    console.error(err);
    notify(`Informations de l’application indisponibles${NBSP}: ${errorText(err)}`, { tone: 'warn' });
    return null;
  });
  trackedCall('session.info').then(showConnection).catch((err) => console.error(err));
  trackedCall('shell.interface.get').then((snapshot) => {
    const first = !snapshot?.interface || !Object.keys(snapshot.interface).length;
    adoptEngine(snapshot, true);
    if (first) mirrorAllPrefs();
    applyPrefsToShell();
  }).catch((err) => { if (err?.code !== 'operation.unknown') console.warn('Préférences de l’interface non lues', err); });
  refreshActivity().catch(() => {});

  let router = null;

  // ---------- Navigation rail: collapse, width, account ----------

  const slideColumn = (change) => {
    const movers = [...shell.children].filter((el) => el !== nav && !el.hidden);
    const before = movers.map((el) => el.getBoundingClientRect().left);
    change();
    if (motionReduced() || typeof Element.prototype.animate !== 'function') return;
    const duration = cssMs('--t-slow', 520);
    movers.forEach((el, n) => {
      const dx = before[n] - el.getBoundingClientRect().left;
      if (Math.abs(dx) < 1) return;
      el.animate([{ transform: `translateX(${dx}px)` }, { transform: 'translateX(0)' }], { duration, easing: 'cubic-bezier(.16, 1, .3, 1)' });
    });
  };
  // Transient fold of a narrow window (TRV-094): never saved; the operator can unfold for the session.
  let autoFold = false;
  let autoReleased = false;
  const isCollapsed = () => shell.classList.contains('nav-collapsed');
  const paintToggle = (on) => {
    const text = on ? 'Déplier le menu' : 'Replier le menu';
    toggle.setAttribute('aria-expanded', String(!on));
    toggle.setAttribute('aria-label', text);
    toggle.querySelector('.nav-label').textContent = text;
    toggle.dataset.tip = `${text} (Ctrl B)`;
    router?.updatePill();
  };
  const setCollapsed = (on, save = true) => {
    if (save) { setPrefs({ navCollapsed: on }); autoFold = false; autoReleased = true; }
    const apply = () => shell.classList.toggle('nav-collapsed', on);
    if (save) slideColumn(apply); else apply();
    paintToggle(on);
  };
  setCollapsed(state.prefs.navCollapsed, false);
  const applyNavWidth = () => {
    const w = state.prefs.navWidth ?? NAV_DEFAULT;
    shell.style.setProperty('--nav-w', `${w}px`);
    const grip = nav.querySelector('.nav-grip');
    grip.setAttribute('aria-valuenow', String(w));
    grip.setAttribute('aria-valuetext', `${w} pixels`);
  };
  applyNavWidth();
  on('layout', (plan) => {
    if (plan.foldNavigation && !state.prefs.navCollapsed && !autoReleased) { autoFold = true; setCollapsed(true, false); }
    else if (!plan.foldNavigation && autoFold) { autoFold = false; setCollapsed(state.prefs.navCollapsed, false); }
  });
  applyLayoutPlan();
  if (document.documentElement.dataset.narrow !== undefined && !state.prefs.navCollapsed) { autoFold = true; setCollapsed(true, false); }
  // The help panel sits beside the work: when the content column would fall under 1 100 px, the menu folds for as long as
  // the panel stays open (never saved), and comes back when it closes.
  let helpFold = false;
  on('help', (open) => {
    const helpWidth = parseFloat(getComputedStyle(shell).getPropertyValue('--help-w')) || 380;
    if (open && !isCollapsed() && main.clientWidth - helpWidth < 1100) { helpFold = true; setCollapsed(true, false); }
    else if (!open && helpFold) { helpFold = false; if (!autoFold) setCollapsed(state.prefs.navCollapsed, false); }
  });

  const grip = nav.querySelector('.nav-grip');
  grip.addEventListener('pointerdown', (e) => {
    if (isCollapsed() || e.button !== 0) return;
    e.preventDefault();
    grip.setPointerCapture(e.pointerId);
    const startX = e.clientX;
    const startW = state.prefs.navWidth ?? NAV_DEFAULT;
    shell.classList.add('nav-resizing');
    const moveW = (ev) => {
      const w = Math.round(Math.max(NAV_MIN, Math.min(NAV_MAX, startW + ev.clientX - startX)));
      shell.style.setProperty('--nav-w', `${w}px`);
      grip.setAttribute('aria-valuenow', String(w));
    };
    const up = (ev) => {
      grip.removeEventListener('pointermove', moveW);
      grip.removeEventListener('pointerup', up);
      shell.classList.remove('nav-resizing');
      const w = Math.round(Math.max(NAV_MIN, Math.min(NAV_MAX, startW + ev.clientX - startX)));
      setPrefs({ navWidth: w });
      router?.updatePill();
    };
    grip.addEventListener('pointermove', moveW);
    grip.addEventListener('pointerup', up);
  });
  grip.addEventListener('dblclick', () => { setPrefs({ navWidth: null }); applyNavWidth(); announce('Largeur du menu par défaut.'); });
  grip.addEventListener('keydown', (e) => {
    const w = state.prefs.navWidth ?? NAV_DEFAULT;
    const step = e.shiftKey ? 64 : 16;
    let next = null;
    if (e.key === 'ArrowRight') next = w + step;
    else if (e.key === 'ArrowLeft') next = w - step;
    else if (e.key === 'Home') next = NAV_MIN;
    else if (e.key === 'End') next = NAV_MAX;
    else if (e.key === 'Enter') next = NAV_DEFAULT;
    if (next === null) return;
    e.preventDefault();
    setPrefs({ navWidth: Math.max(NAV_MIN, Math.min(NAV_MAX, next)) });
    applyNavWidth();
    router?.updatePill();
  });

  function applyPrefsToShell() {
    applyNavWidth();
    document.querySelector('.sh-help-dot').hidden = !!state.prefs.helpIntroSeen;
  }
  on('prefs', applyPrefsToShell);
  on('prefs-warning', (text) => notify(text, { tone: 'warn', key: 'prefs-warning' }));
  applyPrefsToShell();

  nav.querySelector('.nav-account').addEventListener('click', (e) => {
    const profile = state.prefs.profile;
    openMenu(e.currentTarget, [
      { heading: state.session?.account?.login ?? 'Compte de la session' },
      { label: 'Changer de compte', icon: 'users', hint: 'Comptes', run: () => router.go('comptes') },
      { label: 'Session et connexion', icon: 'wifi', run: () => openSession(document.querySelector('.live:not([hidden])') ?? document.querySelector('.mode-chip')) },
      '-',
      { heading: 'Profil d’affichage' },
      { label: 'Essentiel', radio: 'profile', checked: profile !== 'expert', run: () => { setPrefs({ profile: 'essentiel' }); notify('Profil Essentiel : les vues expertes restent accessibles ponctuellement depuis la palette.', { tone: 'info', life: 3200 }); } },
      { label: 'Expert', radio: 'profile', checked: profile === 'expert', run: () => { setPrefs({ profile: 'expert' }); notify('Profil Expert : vues détaillées affichées par défaut.', { tone: 'info', life: 3200 }); } },
      '-',
      { label: 'À propos de Domenia', icon: 'info', run: () => openAbout() },
    ], { label: 'Compte de la session', placement: 'top-start' });
  });

  // ---------- Top bar ----------

  const anchorOf = (sel) => topbar.querySelector(sel);
  const openCentreAt = (tab = 'notifications') => openCentre(anchorOf('.notif'), tab);
  setCentreOpener((tab) => openCentreAt(tab));
  setNavigator((id, params) => router.go(id, params));

  const sessionAnchor = () => {
    const live = anchorOf('.live');
    return live && getComputedStyle(live).display !== 'none' ? live : anchorOf('.mode-chip');
  };

  // Routes of the explanations and messages (TRV-007): navigation only.
  setRouteRunner((code, r) => {
    if (r.panel === 'session') openSession(sessionAnchor());
    else if (r.panel === 'activity') openActivity(anchorOf('.sh-activity'), refreshActivity);
    else if (r.panel === 'journal') openCentreAt('journal');
    else if (r.panel === 'about') openAbout();
    else if (r.page) {
      router.go(r.page, r.params ?? {});
      if (r.focus === 'search') setTimeout(focusSearchField, 450);
    }
  });

  topbar.addEventListener('click', (e) => {
    const t = e.target instanceof Element ? e.target : null;
    if (!t) return;
    const historyButton = t.closest('[data-history]');
    if (historyButton) { if (historyButton.dataset.history === 'back') back(); else forward(); return; }
    if (t.closest('.search-trigger')) { palette.open(); return; }
    if (t.closest('.mode-chip') || t.closest('.live')) { openSession(t.closest('.mode-chip, .live')); return; }
    if (t.closest('.sh-activity')) { openActivity(anchorOf('.sh-activity'), refreshActivity); return; }
    if (t.closest('.notif')) { openCentreAt('notifications'); return; }
    if (t.closest('.sh-help-btn')) { toggleHelpPanel(); return; }
    const theme = t.closest('.theme-switch button[data-set]');
    if (theme) { setTheme(theme.dataset.set); return; }
    if (t.closest('.sh-subject-clear')) { clearSubject(); announce('Objet désélectionné partout ; rien n’a été relu.'); return; }
    if (t.closest('.sh-subject-open') && state.subject) { router.go(state.subject.kind === 'computer' ? 'poste' : 'fiche', { dn: state.subject.dn }); return; }
    const more = t.closest('.sh-more');
    if (more) {
      openMenu(more, [
        { heading: 'Historique' },
        { label: 'Écran précédent', icon: 'chevronRight', kbd: 'Alt ←', disabled: !canBack(), reason: 'Aucun écran précédent.', run: back },
        { label: 'Écran suivant', icon: 'chevronRight', kbd: 'Alt →', disabled: !canForward(), reason: 'Aucun écran suivant.', run: forward },
        '-',
        { heading: 'Thème' },
        ...THEMES.map((th) => ({ label: th.label, radio: 'theme', checked: state.prefs.theme === th.id, run: () => setTheme(th.id) })),
        '-',
        { heading: 'Animations' },
        ...MOTIONS.map((m) => ({ label: m.label, radio: 'motion', checked: state.prefs.motion === m.id, run: () => setMotion(m.id) })),
      ], { label: 'Plus de commandes', placement: 'bottom-end' });
    }
  });
  host.querySelector('.sh-banner-more').addEventListener('click', (e) => openSession(e.currentTarget));

  // Reserved layout of the top bar (TRV-053, TRV-092): fixed slots, an overflow menu when the width runs short.
  const fitTopbar = () => {
    const w = topbar.clientWidth;
    topbar.classList.toggle('compact', w < 1080);
    topbar.classList.toggle('tight', w < 820);
    topbar.querySelector('.sh-more').hidden = w >= 1080;
    themeInk?.update();
  };
  if ('ResizeObserver' in window) new ResizeObserver(fitTopbar).observe(topbar);
  fitTopbar();
  // The mode moves into the top bar when the content column is narrow (TRV-093): the banner condenses to one line.
  if ('ResizeObserver' in window) new ResizeObserver(() => shell.classList.toggle('main-narrow', main.clientWidth < 1000)).observe(main);

  on('history', ({ canBack: b, canForward: f }) => {
    topbar.querySelector('[data-history="back"]').disabled = !b;
    topbar.querySelector('[data-history="forward"]').disabled = !f;
  });
  on('notes', paintBell);
  on('subject', () => {
    const box = topbar.querySelector('.sh-subject');
    const text = subjectChip();
    box.hidden = !text;
    box.querySelector('.sh-subject-text').textContent = text;
    syncWindowChrome();
  });

  // ---------- Help ----------

  setHelpActions({ openShortcuts, go: (id, params) => router.go(id, params) });
  // A greyed control with a reason of the catalogue (ctx.help.disabled) explains itself when clicked (TRV-006).
  document.addEventListener('click', (e) => {
    const el = e.target instanceof Element ? e.target.closest('[aria-disabled="true"][data-reason-code]') : null;
    if (!el) return;
    e.preventDefault();
    e.stopImmediatePropagation();
    const code = el.dataset.reasonCode;
    notify(el.dataset.reason || 'Action indisponible pour l’instant.', { tone: 'info', route: DISABLED_REASONS[code]?.route ?? '', key: `disabled|${code}|${el.dataset.reason}` });
  }, true);

  // ---------- Palette ----------

  const screenOf = { current: { id: '', commands: [], selectionType: '', machineRows: 0 } };

  function judgeContext() {
    const s = state.session;
    const screen = screenOf.current;
    return {
      connected: s ? s.connection.state !== 'disconnected' : false,
      selectionType: screen.selectionType || (state.subject?.kind ?? ''),
      machineRows: screen.machineRows,
      readOnly: s ? s.readOnly === true : true,
      simulation: simulation(),
      control: (id) => controlOf(id, main),
      blocked: () => (requestBlocks('write', screen.scope ?? '') ? 'Une demande attend votre réponse sur cette cible : répondez-y d’abord.' : ''),
    };
  }

  function shellActions() {
    return [
      ...THEMES.map((t) => ({ id: `theme-${t.id}`, label: t.label, icon: t.icon, keywords: 'thème apparence couleurs', group: 'Présentation', effect: 'local', active: state.prefs.theme === t.id, run: () => setTheme(t.id) })),
      ...MOTIONS.map((m) => ({ id: `motion-${m.id}`, label: m.label, icon: m.icon, keywords: 'animations mouvement', group: 'Présentation', effect: 'local', active: state.prefs.motion === m.id, run: () => setMotion(m.id) })),
      { id: 'nav', label: isCollapsed() ? 'Déplier le menu' : 'Replier le menu', icon: 'panel', kbd: 'Ctrl B', keywords: 'navigation barre latérale', group: 'Présentation', effect: 'local', run: () => setCollapsed(!isCollapsed()) },
      { id: 'help-panel', label: helpPanelOpen() ? 'Fermer l’aide' : 'Ouvrir l’aide de cet écran', icon: 'info', kbd: 'F1', keywords: 'aide f1 guide', group: 'Aide', effect: 'local', run: () => toggleHelpPanel() },
      { id: 'help-centre', label: 'Centre d’aide : les 820 sujets', icon: 'sparkles', keywords: 'aide catalogue sujets', group: 'Aide', effect: 'navigate', run: () => router.go('shell', { onglet: 'aide' }) },
      { id: 'notifications', label: 'Ouvrir le centre de notifications', icon: 'bell', kbd: 'Ctrl L', keywords: 'messages bannières journal', group: 'Navigation', effect: 'local', run: () => openCentreAt('notifications') },
      { id: 'session', label: 'Afficher la session et la connexion', icon: 'wifi', keywords: 'contrôleur domaine compte droits kerberos', group: 'Navigation', effect: 'local', run: () => openSession(sessionAnchor()) },
      { id: 'about', label: 'À propos de Domenia', icon: 'info', keywords: 'version compatibilité', group: 'Application', effect: 'local', run: () => openAbout() },
      { id: 'audit', label: 'Contrôler l’accessibilité de cet écran', icon: 'eye', keywords: 'accessibilité lecteur écran contraste noms', group: 'Application', effect: 'local', run: () => showAudit() },
      { id: 'expert-once', label: 'Afficher la vue experte pour cette consultation', icon: 'zap', keywords: 'expert détails avancé', group: 'Présentation', effect: 'local', run: () => expertOnce() },
      { id: 'pick-ou', label: 'Choisir une OU (sélecteur partagé)', icon: 'folder', keywords: 'ou arborescence favoris', group: 'Sélecteurs', effect: 'read', run: () => pickOu({ title: 'Parcourir les OU' }).then((r) => r && notify(`OU choisie${NBSP}: ${r.path}`, { tone: 'info', life: 3600 })) },
      { id: 'pick-object', label: 'Chercher un objet (sélecteur intégré)', icon: 'search', keywords: 'utilisateur poste ou trouver', group: 'Sélecteurs', effect: 'read', run: () => pickObject({ title: 'Chercher un objet' }).then((r) => r && notify(`${r.kindLabel}${NBSP}: ${r.name} (${r.path})`, { tone: 'info', life: 3600 })) },
      { id: 'exports', label: 'Ouvrir le dossier des exports', icon: 'folder', keywords: 'csv export fichier', group: 'Application', effect: 'local', run: () => quietCall('shell.export.open', { fileName: null }).then((r) => { if (r && !r.opened) notify('Dossier des exports indisponible dans cette session (rien n’est écrit sur le disque).', { tone: 'info' }); }) },
    ];
  }

  function catalogueCommand(c) {
    const shortcuts = { search: 'Ctrl F', dashboard: 'Ctrl D', journal: 'Ctrl L', index: 'Ctrl I', theme: 'Ctrl T', summary: 'Ctrl Maj C', help: 'F1', shortcuts: 'Maj ?', refresh: 'F5' };
    const runners = {
      search: () => focusSearch(),
      operations: () => openActivity(anchorOf('.sh-activity'), refreshActivity),
      journal: () => journalShortcut(),
      tools: () => openHelpPanel(),
      shortcuts: () => openShortcuts(),
      theme: () => toggleTheme(),
      summary: () => copySummary(),
      selfcheck: () => openAbout(),
      parent: () => { const dn = state.subject?.dn ?? ''; const parent = dn.split(/(?<!\\),/).slice(1).join(','); if (parent) router.go('rechercher', { ou: parent }); },
    };
    const run = runners[c.id] ?? (c.route ? () => { const [id, q] = c.route.split('?'); router.go(id, Object.fromEntries(new URLSearchParams(q ?? ''))); } : null);
    return { ...c, icon: { navigate: 'chevronRight', local: 'command', read: 'wifi', sensitive: 'key', write: 'lock' }[c.effect], kbd: shortcuts[c.shortcut] ?? '', run };
  }

  function sources() {
    const ctx = judgeContext();
    const pages = PAGES.map((p, n) => ({
      id: `page:${p.id}`, kind: 'page', label: p.label, icon: p.icon, keywords: p.keywords, group: p.section ?? 'Application',
      hint: p.section ?? '', kbd: n < 9 ? `Alt ${n + 1}` : '', active: router?.current() === p.id, effect: 'navigate', available: true,
      run: () => router.go(p.id),
    }));
    // Recent places only when they name something more than a screen (a DN, an OU, a tab): plain screens are in « Aller à ».
    const here = recentAddress(location.hash);
    const seen = new Set();
    const recentPages = state.recentPages.map(recentAddress).filter((h) => h.includes('?') && h !== here && !seen.has(h) && seen.add(h)).slice(0, 5).map((h) => {
      const d = describeHash(h, PAGES);
      return { id: `recent:${h}`, kind: 'page', label: d.label, icon: d.icon, group: 'Écran récent', hint: 'Récent', effect: 'navigate', available: true, recentPlace: true, run: () => { location.hash = h; } };
    });
    const screen = screenOf.current.commands.map((c, n) => {
      const j = judge({ ...c, catalogue: false }, ctx);
      return { order: n + 1, group: 'Sur cet écran', effect: 'local', ...c, id: `screen:${c.id}`, kind: 'command', available: j.available, reason: j.reason };
    });
    const commands = [...CATALOGUE.map(catalogueCommand), ...shellActions().map((a, n) => ({ ...a, order: 100 + n }))].map((c) => {
      const j = judge(c, ctx);
      return { ...c, kind: 'command', available: j.available, reason: j.reason };
    });
    return { pages: [...pages, ...recentPages], screen, commands, recents: state.recentCommands };
  }

  const palette = createPalette({
    inertTarget: shell,
    sources,
    help: async (q) => {
      try { await loadHelp(); } catch { /* registered topics only */ }
      return searchTopics(q, { limit: 6 }).items.map((t) => ({ id: `help:${t.name}`, kind: 'help', label: t.title, text: t.text, icon: 'info', group: 'Aide', hint: 'Aide', effect: 'local', available: true, run: () => openHelpPanel(t.name) }));
    },
    lookup: async (text) => {
      const r = await trackedCall('shell.lookup', { text, kinds: ['user', 'computer', 'ou'] });
      return r.items.slice(0, 12).map((it) => ({
        id: `object:${it.objectGuid}`, kind: 'object', label: it.name, icon: { user: 'user', computer: 'monitor', ou: 'folder' }[it.kind] ?? 'object',
        group: it.kindLabel, hint: it.detail ?? it.kindLabel, path: it.dn, effect: 'navigate', available: true,
        detailText: `${it.kindLabel} · ${it.path}${it.enabled ? '' : ' · compte désactivé'}`,
        run: () => (it.kind === 'ou' ? router.go('rechercher', { ou: it.dn }) : router.go(it.kind === 'computer' ? 'poste' : 'fiche', { dn: it.dn })),
      }));
    },
    openSearch: (text) => router.go('rechercher', { q: text }),
    onRun: (entry) => runEntry(entry),
  });

  function runEntry(entry) {
    if (entry.kind === 'command' || entry.kind === 'page') {
      const id = entry.id;
      setLists({ recentCommands: [id, ...state.recentCommands.filter((x) => x !== id)].slice(0, 12) });
    }
    const decision = decide(entry);
    if (decision.action === 'none') { notify(decision.status, { tone: 'info' }); return; }
    if (decision.action === 'focus' || decision.action === 'click') {
      const control = entry.target ? (typeof entry.target === 'function' ? entry.target() : main.querySelector(entry.target)) : controlOf(entry.id.replace(/^screen:/, ''), main)?.el;
      if (!control) { notify('Action absente de cet écran : rien n’a été lancé.', { tone: 'info' }); return; }
      control.scrollIntoView({ block: 'center', behavior: motionReduced() ? 'auto' : 'smooth' });
      control.classList.remove('sh-spotlight');
      void control.offsetWidth;
      control.classList.add('sh-spotlight');
      setTimeout(() => control.classList.remove('sh-spotlight'), 2400);
      if (decision.action === 'click') {
        // Re-checked at the last moment: a button disabled since the palette opened is not clicked.
        if (control.disabled || control.getAttribute('aria-disabled') === 'true') { notify('Action devenue indisponible : rien n’a été lancé.', { tone: 'info' }); return; }
        control.click();
      } else {
        control.focus({ preventScroll: true });
      }
      if (decision.status) announce(decision.status);
      return;
    }
    try { entry.run?.(); } catch (err) { console.error(err); notify(errorText(err), { tone: 'alert' }); }
  }

  // ---------- Shortcut actions ----------

  function focusSearchField() {
    const field = main.querySelector('input[type="search"], input[type="text"]');
    field?.focus();
    field?.select?.();
  }

  function focusSearch() {
    const event = new CustomEvent('domenia:focus-search', { cancelable: true });
    if (!window.dispatchEvent(event)) return;
    if (router.current() === 'rechercher') focusSearchField();
    else { router.go('rechercher'); setTimeout(focusSearchField, 450); }
  }

  function journalShortcut() {
    // Ctrl+L never changes the profile: expert profile opens the Opérations screen, the essential one the journal panel.
    if (state.prefs.profile === 'expert') router.go('operations');
    else openCentreAt('journal');
  }

  function copySummary() {
    const text = subjectSummary();
    if (!text) { notify('Aucun objet choisi : ouvrez d’abord une fiche depuis Rechercher.', { tone: 'info', route: 'rechercher' }); return; }
    copyText(text).then((ok) => announce(ok ? 'Résumé de l’objet copié.' : 'Copie impossible.'));
  }

  function refreshScreen() {
    const event = new CustomEvent('domenia:refresh', { cancelable: true });
    if (!window.dispatchEvent(event)) return;
    if (router.current() === 'accueil') { window.dispatchEvent(new CustomEvent('domenia:refresh-home')); return; }
    router.go(router.current() ?? 'accueil', router.params());
    announce('Écran actualisé.');
  }

  function expertOnce() {
    const allow = state.app?.expertAllowed !== false;
    const d = expertDecision({ profile: state.prefs.profile, allowExpert: allow });
    if (!d.show) { notify(d.reason, { tone: 'info' }); return; }
    state.expertOnce = true;
    router.go(router.current() ?? 'accueil', { ...router.params(), vue: 'expert' });
    if (d.reason) notify(d.reason, { tone: 'info', life: 4000 });
  }

  function showAudit() {
    const findings = auditAccessibility(main);
    const alerts = findings.filter((f) => f.severity === 'alert').length;
    openDrawer({
      title: 'Accessibilité de cet écran', subtitle: `${state.page?.label ?? ''} · ${findings.length ? `${findings.length} point${findings.length > 1 ? 's' : ''} à revoir` : 'aucun point relevé'}`,
      icon: 'eye', key: 'shell.audit', width: 520,
      body: findings.length
        ? `<p class="muted">${alerts ? `${alerts} point${alerts > 1 ? 's' : ''} bloquant${alerts > 1 ? 's' : ''} pour un lecteur d’écran.` : 'Aucun point bloquant ; quelques améliorations possibles.'}</p><ol class="sh-audit">${findings.map((f) => `<li data-tone="${f.severity}"><strong>${esc(f.text)}</strong>${f.target ? `<span class="mono">${esc(f.target)}</span>` : ''}</li>`).join('')}</ol>`
        : `<div class="sh-empty-mini">${icon('check')}<p><strong>Aucun point relevé</strong> sur cet écran.</p><p class="faint">Noms accessibles, motifs des contrôles grisés, étiquettes et identifiants vérifiés localement.</p></div>`,
      actions: [{ id: 'close', label: 'Fermer', primary: true, run: (p) => p.close() }],
    });
  }

  // ---------- Router ----------

  // Former names of screens are redirected before the router reads the address (TRV-066).
  const redirect = () => {
    const target = aliasOf(location.hash);
    if (target) history.replaceState(null, '', target);
  };
  window.addEventListener('hashchange', redirect);
  redirect();

  const help = {
    attach: (el, key) => { if (el instanceof Element && key) el.dataset.help = key; },
    open: (key) => openHelpPanel(key ?? ''),
    text: (key) => topic(key),
    topics: (query, o) => loadHelp().then(() => searchTopics(query ?? '', o)),
    register: registerHelp,
    disabled(el, { action, reason, detail = '' } = {}) {
      if (!(el instanceof Element)) return null;
      const h = disabledHelp(action ?? el.getAttribute('aria-label') ?? el.textContent, reason, detail);
      el.setAttribute('aria-disabled', 'true');
      el.dataset.reason = h.short;
      el.dataset.reasonCode = reason;
      el.setAttribute('aria-description', h.help);
      return h;
    },
    enable(el) {
      if (!(el instanceof Element)) return;
      el.removeAttribute('aria-disabled');
      delete el.dataset.reason;
      delete el.dataset.reasonCode;
      el.removeAttribute('aria-description');
    },
    route: (code) => followRoute(code),
    routes: ROUTES,
  };

  router = createRouter({
    main,
    nav,
    pages: PAGES,
    isBusy: () => inflight > 0,
    context: (page) => {
      // A fresh registry per mounted screen: its commands, target and scope never leak to the next screen.
      const screen = { id: page.id, commands: [], selectionType: '', machineRows: 0, scope: '' };
      screenOf.current = screen;
      state.target = null;
      const live = () => screenOf.current === screen;
      return {
        page,
        pages: PAGES,
        call: trackedCall,
        go: (id, params) => router.go(id, params),
        toast: (message, o) => notify(message, o ?? {})?.el ?? null,
        notify,
        app: appInfo,
        showConnection,
        openPalette: () => palette.open(),
        help,
        commands: {
          set: (list) => { if (live()) screen.commands = (Array.isArray(list) ? list : []).filter((c) => c?.id && c.label); palette.refresh(); },
          context: ({ selectionType, machineRows, scope } = {}) => {
            if (!live()) return;
            if (selectionType !== undefined) screen.selectionType = selectionType ?? '';
            if (machineRows !== undefined) screen.machineRows = Number(machineRows) || 0;
            if (scope !== undefined) screen.scope = scope ?? '';
          },
        },
        subject: { get: () => state.subject, set: (s) => setSubject(s, page.id), clear: clearSubject },
        setTarget: (name) => { if (live()) { state.target = name ? String(name).slice(0, 80) : null; syncWindowChrome(); } },
        announce: (text, o) => announceOnce(o?.key ?? `${page.id}:${text}`, text, o),
        exportCsv: exportRows,
        exportCsvText,
        exportJson,
        gridExporter,
        importCsv,
        importJson,
        pickOu,
        pickObject,
        pickFile,
        requests: { ask, begin: beginRequest, blocks: requestBlocks },
        summary: operationSummary,
        statusBadge,
        createBoard: (hostEl, opts) => createBoard(hostEl, opts),
        expert: state.expertOnce || state.prefs.profile === 'expert',
        profile: state.prefs.profile,
      };
    },
    onChange: (page) => {
      closePopover();
      const params = router.params();
      state.expertOnce = params.vue === 'expert';
      state.page = { id: page.id, label: page.label, icon: page.icon, params, hash: location.hash };
      trackHash(location.hash);
      emit('page', state.page);
      syncWindowChrome();
      handleShellParam(params.coque);
    },
  });

  // « ?coque=… » on any screen opens a panel of the shell once the screen is shown (captures, links of the guides).
  function handleShellParam(value) {
    if (!value) return;
    const release = hold();
    setTimeout(() => {
      try {
        if (value === 'aide') openHelpPanel('', false);
        else if (value === 'notifications') openCentreAt('notifications');
        else if (value === 'journal') openCentreAt('journal');
        else if (value === 'operations') openActivity(anchorOf('.sh-activity'), refreshActivity);
        else if (value === 'session') openSession(sessionAnchor());
        else if (value === 'apropos') openAbout();
        else if (value === 'raccourcis') openShortcuts();
        else if (value === 'palette') palette.open();
        else if (value === 'audit') showAudit();
        else if (value === 'exemples') { ['info', 'ok', 'warn', 'alert'].forEach((tone) => exampleNote(tone)); }
        else if (value === 'exemples-centre') { ['info', 'ok', 'warn', 'alert'].forEach((tone) => exampleNote(tone)); setTimeout(() => openCentreAt('notifications'), 200); }
      } catch (err) {
        console.error(err);
      }
      setTimeout(release, 900);
    }, 420);
  }

  // Events
  toggle.addEventListener('click', () => setCollapsed(!isCollapsed()));
  if ('ResizeObserver' in window) new ResizeObserver(() => router.updatePill()).observe(nav);
  window.addEventListener('resize', () => applyLayoutPlan());
  // The hash is the route: the skip link moves the focus instead of changing location.hash.
  host.querySelector('.skip-link').addEventListener('click', (e) => {
    e.preventDefault();
    main.focus({ preventScroll: true });
  });
  const follow = () => { if (state.prefs.theme === 'system') applyTheme(); };
  mqDark.addEventListener('change', follow);
  mqContrast.addEventListener('change', follow);

  // Keyboard (TRV-178 to TRV-180): the catalogue is in shell/shortcuts.js. A dialog or a modal panel keeps its own keys.
  document.addEventListener('keydown', (e) => {
    const mod = e.ctrlKey || e.metaKey;
    const key = e.key.toLowerCase();
    if (mod && !e.altKey && !e.shiftKey && (key === 'k' || key === 'p')) { e.preventDefault(); palette.toggle(); return; }
    if (palette.isOpen()) return;
    if (e.key === 'F5' && !mod) { e.preventDefault(); if (!modalOpen()) refreshScreen(); return; }
    if (e.key === 'F1') { e.preventDefault(); if (!modalOpen()) toggleHelpPanel(); return; }
    if (modalOpen()) return;
    const inText = isTextEntry(e.target);
    if (mod && !e.altKey && !e.shiftKey && key === 'b') { e.preventDefault(); setCollapsed(!isCollapsed()); return; }
    if (mod && !e.altKey && !e.shiftKey && key === 'f') { e.preventDefault(); focusSearch(); return; }
    if (mod && !e.altKey && !e.shiftKey && key === 'd') { e.preventDefault(); router.go('accueil'); return; }
    if (mod && !e.altKey && !e.shiftKey && key === 'l') { e.preventDefault(); journalShortcut(); return; }
    if (mod && !e.altKey && !e.shiftKey && key === 'i') { e.preventDefault(); router.go('parametres', { section: 'stockage' }); return; }
    if (mod && !e.altKey && !e.shiftKey && key === 't') { e.preventDefault(); toggleTheme(); return; }
    if (mod && e.shiftKey && !e.altKey && key === 'c' && !inText) { e.preventDefault(); copySummary(); return; }
    if (e.key === '?' && !mod && !e.altKey && !inText) { e.preventDefault(); openShortcuts(); return; }
    if (e.altKey && !mod && (e.key === 'ArrowLeft' || e.key === 'ArrowRight') && !inText) {
      e.preventDefault();
      if (e.key === 'ArrowLeft') back(); else forward();
      return;
    }
    const digit = /^Digit([1-9])$/.exec(e.code);
    if (e.altKey && !mod && digit) {
      const page = PAGES[Number(digit[1]) - 1];
      if (page) { e.preventDefault(); router.go(page.id); }
      return;
    }
    if (e.key === 'Escape' && helpPanelOpen() && !inText) closeHelpPanel(true);
  });

  router.start();
  paintBell();
}

// A failed start must not leave the boot screen turning forever (shell.css .boot.failed).
try {
  boot();
} catch (err) {
  console.error(err);
  const host = document.getElementById('app');
  if (host) {
    const p = document.createElement('p');
    p.className = 'boot failed';
    p.setAttribute('role', 'alert');
    p.textContent = `Domenia n’a pas pu démarrer${NBSP}: ${errorText(err)}`;
    host.replaceChildren(p);
  }
}
