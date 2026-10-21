// Domenia 2 shell: navigation, top bar, preferences, shortcuts, palette and router.
import { call } from './bridge.js';
import { icon } from './icons.js';
import {
  esc, errorText, initLive, initPointerEffects, inkFollow, setBusy, toast, motionReduced, cssMs,
} from './ui.js';
import { createRouter } from './router.js';
import { createPalette } from './palette.js';

const root = document.documentElement;

const PAGES = [
  { id: 'accueil', label: 'Accueil', icon: 'home', section: 'Pilotage', keywords: 'tableau de bord kpi widgets' },
  { id: 'rechercher', label: 'Rechercher', icon: 'search', section: 'Pilotage', keywords: 'trouver compte poste groupe' },
  { id: 'fiche', label: 'Fiche', icon: 'object', section: 'Pilotage', keywords: 'objet attributs utilisateur groupe' },
  { id: 'comptes', label: 'Comptes', icon: 'users', section: 'Pilotage', keywords: 'utilisateurs verrouillés mots de passe' },
  { id: 'relations', label: 'Utilisateurs et postes', icon: 'link', section: 'Pilotage', keywords: 'associations relations' },
  { id: 'poste', label: 'Poste', icon: 'monitor', section: 'Pilotage', keywords: 'ordinateur wmi inventaire' },
  { id: 'assistance', label: 'Assistance', icon: 'lifebuoy', section: 'Outils', keywords: 'support aide ticket' },
  { id: 'requetes', label: 'Atelier de requêtes', icon: 'database', section: 'Outils', keywords: 'requête ldap wmi filtre' },
  { id: 'audit', label: 'Audit AD', icon: 'shield', section: 'Outils', keywords: 'sécurité délégations contrôleurs' },
  { id: 'schema', label: 'Schéma de l’annuaire', icon: 'tree', section: 'Outils', keywords: 'classes attributs schema' },
  { id: 'synchro', label: 'Synchronisation', icon: 'sync', section: 'Outils', keywords: 'réplication sync' },
  { id: 'machine', label: 'Comptes machine', icon: 'chip', section: 'Outils', keywords: 'ordinateur compte machine' },
  { id: 'operations', label: 'Opérations', icon: 'activity', section: 'Outils', keywords: 'journal historique tâches' },
  { id: 'parametres', label: 'Paramètres', icon: 'settings', section: null, keywords: 'préférences réglages outils' },
];

const THEMES = [
  { id: 'light', label: 'Thème clair', icon: 'sun' },
  { id: 'dark', label: 'Thème sombre', icon: 'moon' },
  { id: 'contrast', label: 'Contraste élevé', icon: 'contrast' },
  { id: 'system', label: 'Thème : suivre Windows', icon: 'monitor' },
];
const MOTIONS = [
  { id: 'full', label: 'Animations riches', icon: 'sparkles' },
  { id: 'reduced', label: 'Animations réduites', icon: 'pause' },
  { id: 'system', label: 'Animations : suivre Windows', icon: 'monitor' },
];

// ---------- Preferences (localStorage may be unavailable) ----------

const PREF_KEY = 'domenia.prefs.v1';
const DEFAULTS = { theme: 'system', motion: 'full', navCollapsed: false };

function loadPrefs() {
  let saved = {};
  try { saved = JSON.parse(localStorage.getItem(PREF_KEY) ?? '{}') ?? {}; } catch { saved = {}; }
  return {
    theme: THEMES.some((t) => t.id === saved.theme) ? saved.theme : DEFAULTS.theme,
    motion: MOTIONS.some((m) => m.id === saved.motion) ? saved.motion : DEFAULTS.motion,
    navCollapsed: saved.navCollapsed === true,
  };
}

const prefs = loadPrefs();
function savePrefs() {
  try { localStorage.setItem(PREF_KEY, JSON.stringify(prefs)); } catch { /* private mode: keep in memory */ }
}

const mqDark = matchMedia('(prefers-color-scheme: dark)');
const mqContrast = matchMedia('(forced-colors: active), (prefers-contrast: more)');

function resolvedTheme() {
  if (prefs.theme !== 'system') return prefs.theme;
  if (mqContrast.matches) return 'contrast';
  return mqDark.matches ? 'dark' : 'light';
}

function applyTheme() {
  root.dataset.theme = resolvedTheme();
  root.dataset.themePref = prefs.theme;
  document.querySelectorAll('.theme-switch button').forEach((b) => {
    b.setAttribute('aria-pressed', String(b.dataset.set === prefs.theme));
  });
  themeInk?.update();
}

function applyMotion() {
  root.dataset.motion = prefs.motion;
}

// Theme swap cross-fades the whole window through a view transition.
function setTheme(id) {
  if (prefs.theme === id) return;
  prefs.theme = id;
  savePrefs();
  if (document.startViewTransition && !motionReduced()) {
    root.classList.add('theme-swap');
    const vt = document.startViewTransition(applyTheme);
    vt.finished.finally(() => root.classList.remove('theme-swap'));
  } else {
    applyTheme();
  }
}

function setMotion(id) {
  prefs.motion = id;
  savePrefs();
  applyMotion();
  toast(MOTIONS.find((m) => m.id === id)?.label ?? 'Animations', { tone: 'info', life: 2600 });
}

// ---------- Shell markup ----------

// aria-label keeps the name when the label is hidden (collapsed rail, narrow window); the shortcut is exposed
// through aria-keyshortcuts instead of being read as part of the name.
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
    <button class="nav-item nav-toggle" type="button" aria-expanded="true" aria-label="Replier le menu" aria-keyshortcuts="Control+B" data-tip="Replier le menu (Ctrl B)">
      ${icon('panel')}<span class="nav-label">Replier le menu</span><kbd class="nav-kbd" aria-hidden="true">Ctrl B</kbd>
    </button>
  </nav>`;
}

function topbarMarkup() {
  const themes = THEMES.map((t) => `<button type="button" data-set="${t.id}" aria-pressed="false" aria-label="${esc(t.label)}" data-tip="${esc(t.label)}">${icon(t.icon)}</button>`).join('');
  return `<header class="topbar">
    <button class="search-trigger" type="button" aria-haspopup="dialog">
      ${icon('search')}<span>Rechercher un compte, un poste, une commande…</span><kbd>Ctrl K</kbd>
    </button>
    <div class="topbar-spacer"></div>
    <span class="mode-chip" hidden><span class="glow-ring" aria-hidden="true"></span><span class="dot pulse"></span><span class="txt"></span><span class="visually-hidden detail"></span></span>
    <span class="live" data-state="unknown"><span class="dot pulse"></span><span class="label">Connexion…</span></span>
    <div class="segmented theme-switch" role="group" aria-label="Thème"><span class="thumb" aria-hidden="true"></span>${themes}</div>
    <button class="btn ghost icon notif" type="button" aria-label="Notifications" data-tip="Notifications">${icon('bell')}</button>
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
    <div class="sim-banner" role="note" hidden>${icon('info')}<span class="text"></span><span class="detail"></span></div>
    <main class="main" id="main" tabindex="-1"></main>
  </div>
  <div class="toasts" role="region" aria-label="Notifications"></div>`;
}

// ---------- Floating tooltips (escape the nav and button overflow boxes) ----------

function initTips(nav) {
  root.classList.add('js-tips');
  const tip = document.createElement('div');
  tip.className = 'flytip';
  tip.setAttribute('aria-hidden', 'true');
  document.body.appendChild(tip);
  let owner = null;
  let timer = 0;

  const place = (el) => {
    const r = el.getBoundingClientRect();
    const w = tip.offsetWidth; const h = tip.offsetHeight;
    let x; let y;
    if (el.closest('.nav')) { x = r.right + 10; y = r.top + r.height / 2 - h / 2; }
    else if (r.top < 140) { x = r.left + r.width / 2 - w / 2; y = r.bottom + 8; }
    else { x = r.left + r.width / 2 - w / 2; y = r.top - h - 8; }
    x = Math.max(8, Math.min(innerWidth - w - 8, x));
    y = Math.max(8, Math.min(innerHeight - h - 8, y));
    tip.style.setProperty('--tx', `${Math.round(x)}px`);
    tip.style.setProperty('--ty', `${Math.round(y)}px`);
  };
  // Unfolded menu: its items show their label, so they need no tip (the version pill keeps its own).
  const wanted = (el) => !(el.closest('.nav-item') && nav.getBoundingClientRect().width > 120);
  const show = (el) => {
    if (!el.isConnected || !el.dataset.tip || !wanted(el)) return;
    const wasOn = tip.classList.contains('on');
    owner = el;
    tip.textContent = el.dataset.tip;
    if (!wasOn) tip.classList.add('jump');
    place(el);
    if (!wasOn) { void tip.offsetWidth; tip.classList.remove('jump'); }
    tip.classList.add('on');
  };
  const hide = () => { clearTimeout(timer); owner = null; tip.classList.remove('on'); };
  document.addEventListener('pointerover', (e) => {
    const el = e.target instanceof Element ? e.target.closest('[data-tip]') : null;
    if (el === owner) return;
    clearTimeout(timer);
    if (!el) { hide(); return; }
    timer = setTimeout(() => show(el), tip.classList.contains('on') ? 0 : 280);
  });
  document.addEventListener('focusin', (e) => {
    const el = e.target instanceof Element ? e.target.closest('[data-tip]') : null;
    if (el && el.matches(':focus-visible')) show(el); else hide();
  });
  ['pointerdown', 'focusout', 'wheel'].forEach((t) => document.addEventListener(t, hide, { passive: true }));
  document.addEventListener('keydown', (e) => { if (e.key === 'Escape') hide(); });
}

// ---------- Mode, connection and banner ----------

// Full version in the tip of the logo (app.info, OPERATIONS.md § 2); the subtitle under the name says what Domenia
// administers rather than a bare « v2 ».
function showVersion(info) {
  const brand = document.querySelector('.brand');
  if (brand && typeof info?.version === 'string' && info.version) brand.dataset.tip = `Domenia 2 · version ${info.version}`;
}

// The browser preview is recognised by its engine (OPERATIONS.md § 2: webViewRuntime "apercu"); it also reports
// mode "simulation", so the preview wording wins. The chip names the mode in one word and stands for the connection
// indicator, hidden in simulation (shell.css); the banner below explains the mode; the chip's tip and hidden text give
// its reason.
function showMode(info) {
  const preview = info?.webViewRuntime === 'apercu';
  const simulation = info?.mode === 'simulation';
  const chip = document.querySelector('.mode-chip');
  if (simulation || preview) {
    const detail = info.modeDetail || (preview ? 'Aperçu dans un navigateur\u00A0: données de démonstration intégrées à la page.' : 'Annuaire fictif\u00A0: aucune requête ne part.');
    chip.querySelector('.txt').textContent = preview ? 'Aperçu' : 'Simulation';
    chip.querySelector('.detail').textContent = `\u00A0: ${detail} Lecture seule, aucune écriture possible.`;
    chip.dataset.tip = `${detail} Lecture seule, aucune écriture possible.`;
    chip.dataset.mode = preview ? 'preview' : 'simulation';
    chip.hidden = false;
  }
  const text = info?.banner
    ?? (preview ? 'Aperçu dans un navigateur : données fictives intégrées à la page, aucune requête ne part.' : null);
  const banner = document.querySelector('.sim-banner');
  if (text) {
    banner.querySelector('.text').textContent = text;
    banner.querySelector('.detail').textContent = info?.modeDetail ?? '';
    banner.hidden = false;
    document.querySelector('.shell').classList.add('has-banner');
  }
}

export function showConnection(session) {
  const live = document.querySelector('.live');
  if (!live || !session?.connection) return;
  const state = session.connection.state ?? 'unknown';
  const label = session.connection.label ?? '';
  const current = live.querySelector('.label');
  live.dataset.state = state;
  if (current.textContent === label) return;
  const next = document.createElement('span');
  next.className = 'label';
  next.textContent = label;
  current.replaceWith(next);
}

// ---------- Boot ----------

let themeInk = null;

// Bridge calls in flight: the router waits for none before it signals a screen as ready (data-ready).
let inflight = 0;

function trackedCall(op, args) {
  inflight += 1;
  setBusy(true);
  return call(op, args).finally(() => {
    inflight -= 1;
    setBusy(false);
  });
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

  themeInk = inkFollow(host.querySelector('.theme-switch'), 'button', 'button[aria-pressed="true"]');
  applyTheme();
  initPointerEffects();
  initTips(nav);

  const appInfo = trackedCall('app.info').then((info) => { showMode(info); showVersion(info); return info; }).catch((err) => {
    console.error(err);
    toast(`Informations de l’application indisponibles : ${errorText(err)}`, { tone: 'warn' });
    return null;
  });
  trackedCall('session.info').then(showConnection).catch((err) => console.error(err));

  let router = null;
  // The grid column snaps (no layout animation); the content column then slides from its old place with a
  // transform-only animation (FLIP), so only the compositor works during the movement.
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
  const setCollapsed = (on, save = true) => {
    prefs.navCollapsed = on;
    if (save) savePrefs();
    const apply = () => shell.classList.toggle('nav-collapsed', on);
    if (save) slideColumn(apply); else apply();
    const text = on ? 'Déplier le menu' : 'Replier le menu';
    toggle.setAttribute('aria-expanded', String(!on));
    toggle.setAttribute('aria-label', text);
    toggle.querySelector('.nav-label').textContent = text;
    toggle.dataset.tip = `${text} (Ctrl B)`;
    router?.updatePill();
  };
  setCollapsed(prefs.navCollapsed, false);

  const palette = createPalette({
    inertTarget: shell,
    getCommands: () => ({
      pages: PAGES.map((p, n) => ({
        id: p.id, label: p.label, icon: p.icon, keywords: p.keywords,
        hint: p.section ?? '', kbd: n < 9 ? `Alt ${n + 1}` : '', active: router?.current() === p.id,
        run: () => router.go(p.id),
      })),
      actions: [
        ...THEMES.map((t) => ({ id: `theme-${t.id}`, label: t.label, icon: t.icon, keywords: 'thème apparence couleurs', active: prefs.theme === t.id, run: () => setTheme(t.id) })),
        ...MOTIONS.map((m) => ({ id: `motion-${m.id}`, label: m.label, icon: m.icon, keywords: 'animations mouvement', active: prefs.motion === m.id, run: () => setMotion(m.id) })),
        { id: 'nav', label: prefs.navCollapsed ? 'Déplier le menu' : 'Replier le menu', icon: 'panel', kbd: 'Ctrl B', keywords: 'navigation barre latérale', run: () => setCollapsed(!prefs.navCollapsed) },
        { id: 'refresh-home', label: 'Actualiser l’accueil', icon: 'refresh', keywords: 'recharger tableau de bord', run: refreshHome },
      ],
    }),
  });

  function refreshHome() {
    if (router.current() === 'accueil') window.dispatchEvent(new CustomEvent('domenia:refresh-home'));
    else router.go('accueil');
  }

  router = createRouter({
    main,
    nav,
    pages: PAGES,
    isBusy: () => inflight > 0,
    context: (page) => ({
      page,
      pages: PAGES,
      call: trackedCall,
      go: (id, params) => router.go(id, params),
      toast,
      app: appInfo,
      showConnection,
      openPalette: () => palette.open(),
    }),
  });

  // Events
  toggle.addEventListener('click', () => setCollapsed(!prefs.navCollapsed));
  if ('ResizeObserver' in window) new ResizeObserver(() => router.updatePill()).observe(nav);
  host.querySelector('.search-trigger').addEventListener('click', () => palette.open());
  // The hash is the route: the skip link moves the focus instead of changing location.hash.
  host.querySelector('.skip-link').addEventListener('click', (e) => {
    e.preventDefault();
    main.focus({ preventScroll: true });
  });
  host.querySelector('.theme-switch').addEventListener('click', (e) => {
    const b = e.target instanceof Element ? e.target.closest('button[data-set]') : null;
    if (b) setTheme(b.dataset.set);
  });
  host.querySelector('.notif').addEventListener('click', () => {
    toast('Aucune nouvelle notification. Les opérations de la session sont dans « Opérations ».', { tone: 'info' });
  });
  const follow = () => { if (prefs.theme === 'system') applyTheme(); };
  mqDark.addEventListener('change', follow);
  mqContrast.addEventListener('change', follow);

  document.addEventListener('keydown', (e) => {
    const mod = e.ctrlKey || e.metaKey;
    const key = e.key.toLowerCase();
    if (mod && !e.altKey && (key === 'k' || key === 'p')) { e.preventDefault(); palette.toggle(); return; }
    if (palette.isOpen()) return;
    if (mod && !e.altKey && key === 'b') { e.preventDefault(); setCollapsed(!prefs.navCollapsed); return; }
    const digit = /^Digit([1-9])$/.exec(e.code);
    if (e.altKey && !mod && digit) {
      const page = PAGES[Number(digit[1]) - 1];
      if (page) { e.preventDefault(); router.go(page.id); }
    }
  });

  router.start();
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
    p.textContent = `Domenia n’a pas pu démarrer : ${errorText(err)}`;
    host.replaceChildren(p);
  }
}
