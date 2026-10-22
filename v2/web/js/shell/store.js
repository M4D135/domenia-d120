// Shared state of the shell: application info, session, interface preferences (local and engine), global subject, current
// screen, and a small event bus. Every shell module and the screens read the same state (docs/SHELL.md).
import { call } from '../bridge.js';

const PREF_KEY = 'domenia.prefs.v1';
const THEMES = ['light', 'dark', 'contrast', 'system'];
const MOTIONS = ['full', 'reduced', 'system'];
const PROFILES = ['essentiel', 'expert'];
const DENSITIES = ['compact', 'normal', 'confortable'];
export const NAV_MIN = 200;
export const NAV_MAX = 360;
export const NAV_DEFAULT = 248;

/** Interface preferences kept in the WebView2 profile (read by boot.js before the first paint) and mirrored to the engine. */
function readLocal() {
  let saved = {};
  try { saved = JSON.parse(localStorage.getItem(PREF_KEY) ?? '{}') ?? {}; } catch { saved = {}; }
  return normalizePrefs(saved);
}

export function normalizePrefs(raw) {
  const p = raw && typeof raw === 'object' ? raw : {};
  const width = Number(p.navWidth);
  return {
    theme: THEMES.includes(p.theme) ? p.theme : 'system',
    motion: MOTIONS.includes(p.motion) ? p.motion : 'full',
    navCollapsed: p.navCollapsed === true,
    navWidth: Number.isInteger(width) && width >= NAV_MIN && width <= NAV_MAX ? width : null,
    profile: PROFILES.includes(p.profile) ? p.profile : 'essentiel',
    helpTips: p.helpTips !== false,
    helpIntroSeen: p.helpIntroSeen === true,
    density: DENSITIES.includes(p.density) ? p.density : 'normal',
    bannerCompact: p.bannerCompact === true,
  };
}

export const state = {
  /** app.info (null until known, or when unavailable). */
  app: null,
  /** Last session.info seen (boot, or a screen through ctx.showConnection). */
  session: null,
  prefs: readLocal(),
  /** Engine side of the preferences (shell.interface.get): null until read. */
  engine: null,
  /** True once shell.interface.get answered or failed: a board never saves before its stored layout was looked at. */
  engineRead: false,
  /** Rules of the administrator (shell.policy, UI.AllowExpertProfile): Expert offered until told otherwise. */
  policy: { expertAllowed: true, source: 'défaut' },
  /** Recent commands and pages, pinned commands (engine preferences; memory until read). */
  recentCommands: [],
  recentPages: [],
  pinnedCommands: [],
  /** Global subject chosen by Rechercher (TRV-169): { kind, name, dn, objectGuid? } or null. */
  subject: null,
  /** Screen shown: { id, label, icon, params, hash }. */
  page: null,
  /** Target named by the screen for the title (« Fiche · Camille Martin »), reset at each screen change. */
  target: null,
  /** Expert view asked for the current navigation only (TRV-167). */
  expertOnce: false,
  /** Unsaved input declared by the screen shown (ctx.dirty): { label } or null. */
  dirty: null,
  /** Accesses suspended by the guard of authentication, reported by a screen (ctx.access.report). */
  access: { suspended: 0, detail: '' },
  /** Directory reachability seen through the bridge (TRV-051): { offline, since, slow }. */
  reach: { offline: false, since: null, slow: false },
};

// ---------- Events ----------

const listeners = new Map();

/** Subscribes to a shell event; returns the unsubscribe function. */
export function on(name, fn) {
  if (!listeners.has(name)) listeners.set(name, new Set());
  listeners.get(name).add(fn);
  return () => listeners.get(name)?.delete(fn);
}

export function emit(name, detail) {
  for (const fn of [...(listeners.get(name) ?? [])]) {
    try { fn(detail); } catch (err) { console.error(err); }
  }
}

// ---------- Bridge helpers ----------

let tracked = (op, args) => call(op, args);

/** app.js hands its counted call (data-ready waits for it). */
export function setTrackedCall(fn) { tracked = fn; }

/** Counted call: the screen is not « ready » while it runs (capture, E2E). */
export function trackedCall(op, args) { return tracked(op, args); }

/**
 * Background call of the shell (not counted for data-ready). Resolves null when the operation does not exist (browser
 * preview, older engine); other failures are thrown.
 */
export async function quietCall(op, args) {
  try {
    return await call(op, args);
  } catch (err) {
    if (err?.code === 'operation.unknown') return null;
    throw err;
  }
}

// ---------- Preferences ----------

let engineTimer = 0;
let pendingInterface = {};

function writeLocal() {
  try { localStorage.setItem(PREF_KEY, JSON.stringify(state.prefs)); } catch { /* private mode: memory only */ }
}

/** Changes interface preferences: kept at once (local), mirrored to the engine shortly after (LocalWrite). */
export function setPrefs(changes) {
  const next = normalizePrefs({ ...state.prefs, ...changes });
  const changed = {};
  for (const [k, v] of Object.entries(next)) if (state.prefs[k] !== v) changed[k] = v;
  if (!Object.keys(changed).length) return;
  state.prefs = next;
  writeLocal();
  Object.assign(pendingInterface, changed);
  scheduleEngine();
  emit('prefs', changed);
}

function scheduleEngine() {
  clearTimeout(engineTimer);
  engineTimer = setTimeout(flushEngine, 400);
}

let pendingLayouts = {};
let pendingBoards = {};
let pendingFavourites = null;

async function flushEngine() {
  const iface = pendingInterface;
  const layouts = pendingLayouts;
  const boards = pendingBoards;
  const favourites = pendingFavourites;
  pendingInterface = {};
  pendingLayouts = {};
  pendingBoards = {};
  pendingFavourites = null;
  const args = {};
  const out = { ...iface };
  if (iface.navWidth === null) out.navWidth = null;
  if (Object.keys(out).length) args.interface = out;
  if (Object.keys(layouts).length) args.layouts = layouts;
  if (Object.keys(boards).length) args.boards = boards;
  if (favourites) args.ouFavourites = favourites;
  if (!Object.keys(args).length) return;
  try {
    const snapshot = await quietCall('shell.interface.set', args);
    if (snapshot) adoptEngine(snapshot, false);
    if (snapshot?.warning) emit('prefs-warning', snapshot.warning);
  } catch (err) {
    console.warn('Préférences de l’interface non enregistrées', err);
  }
}

/**
 * Parameters of an address that name an object of the directory or a typed text: such an address stays in the memory of the
 * session (history, palette) and never reaches the preferences file (same rule as ShellInterfaceRules.IsRecentPage).
 */
const PRIVATE_PARAMETERS = new Set(['dn', 'ou', 'q', 'guid', 'objectguid', 'sam', 'upn', 'nom', 'cible', 'poste', 'user', 'compte']);

/** True when a recent address may be written to the preferences (no DN, no typed text, printable ASCII, 300 characters). */
export function isPersistableAddress(hash) {
  const text = String(hash ?? '');
  const m = /^#\/([a-z][a-z0-9-]{0,29})(?:\?(.*))?$/.exec(text);
  if (!m || text.length > 300 || /[^\x21-\x7e]/.test(text)) return false;
  if (!m[2]) return true;
  if (/%3d/i.test(m[2])) return false;
  return m[2].split('&').filter(Boolean).every((pair) => !PRIVATE_PARAMETERS.has(pair.split('=')[0].toLowerCase()));
}

/** Recent commands and pages and pinned commands go to the engine with the interface preferences. */
export function setLists({ recentCommands, recentPages, pinnedCommands }) {
  if (Array.isArray(recentCommands)) { state.recentCommands = recentCommands.slice(0, 12); pendingInterface.recentCommands = state.recentCommands; }
  if (Array.isArray(recentPages)) {
    state.recentPages = recentPages.slice(0, 12);
    // The session keeps every address; only those without an object of the directory are written.
    pendingInterface.recentPages = state.recentPages.filter(isPersistableAddress);
  }
  if (Array.isArray(pinnedCommands)) { state.pinnedCommands = pinnedCommands.slice(0, 12); pendingInterface.pinnedCommands = state.pinnedCommands; }
  scheduleEngine();
}

/** Remembered layout of a list or panel (kit setLayoutStore), mirrored to the engine. */
export function setLayout(key, value) {
  pendingLayouts[key] = value ?? null;
  if (state.engine) {
    if (value == null) delete state.engine.layouts[key]; else state.engine.layouts[key] = value;
  }
  scheduleEngine();
}

const BOARD_PREFIX = 'domenia.board.v1:';

/** Layout document of a board (board.js), kept in the WebView2 profile and mirrored to the engine. */
export function setBoard(id, value) {
  pendingBoards[id] = value ?? null;
  try {
    if (value == null) localStorage.removeItem(BOARD_PREFIX + id); else localStorage.setItem(BOARD_PREFIX + id, JSON.stringify(value));
  } catch { /* memory and engine only */ }
  if (state.engine) {
    if (value == null) delete state.engine.boards[id]; else state.engine.boards[id] = value;
  }
  scheduleEngine();
}

/** Stored document of a board: the engine first, then the WebView2 profile (engine unavailable, browser preview). */
export function readBoard(id) {
  const engine = state.engine?.boards?.[id];
  if (engine !== undefined) return engine;
  try { const raw = localStorage.getItem(BOARD_PREFIX + id); return raw ? JSON.parse(raw) : undefined; } catch { return undefined; }
}

/** Marks the engine preferences as looked at (answered, or failed: the profile copy is then the reference). */
export function markEngineRead() {
  if (state.engineRead) return;
  state.engineRead = true;
  emit('engine', state.engine);
}

/** Favourite OUs of the domain of the session (pickers.js). */
export function setFavourites(dns) {
  pendingFavourites = [...dns];
  if (state.engine) state.engine.ouFavourites = [...dns];
  scheduleEngine();
  emit('favourites', dns);
}

/**
 * Engine preferences read (or written back): local values win, engine values fill what the profile lost. Changes made while
 * the call was in flight (still waiting to be sent) are laid over the snapshot, so a layout changed meanwhile is never
 * replaced by the older value the engine answered with.
 */
export function adoptEngine(snapshot, first) {
  const iface = snapshot?.interface && typeof snapshot.interface === 'object' ? snapshot.interface : {};
  const layouts = snapshot?.layouts && typeof snapshot.layouts === 'object' ? { ...snapshot.layouts } : {};
  const boards = snapshot?.boards && typeof snapshot.boards === 'object' ? { ...snapshot.boards } : {};
  for (const [k, v] of Object.entries(pendingLayouts)) { if (v == null) delete layouts[k]; else layouts[k] = v; }
  for (const [k, v] of Object.entries(pendingBoards)) { if (v == null) delete boards[k]; else boards[k] = v; }
  state.engine = {
    persistent: snapshot?.persistent === true,
    interface: iface,
    layouts,
    boards,
    ouFavourites: pendingFavourites ? [...pendingFavourites] : Array.isArray(snapshot?.ouFavourites) ? [...snapshot.ouFavourites] : [],
  };
  if (first) {
    let raw = {};
    try { raw = JSON.parse(localStorage.getItem(PREF_KEY) ?? '{}') ?? {}; } catch { raw = {}; }
    const fill = {};
    for (const k of ['navWidth', 'profile', 'helpTips', 'helpIntroSeen', 'density', 'bannerCompact']) {
      if (!(k in raw) && k in iface) fill[k] = iface[k];
    }
    if (Object.keys(fill).length) {
      state.prefs = normalizePrefs({ ...state.prefs, ...fill });
      writeLocal();
      emit('prefs', fill);
    }
    if (Array.isArray(iface.recentCommands)) state.recentCommands = iface.recentCommands;
    // Addresses of this session (with their DN) come first; the stored ones follow.
    if (Array.isArray(iface.recentPages)) state.recentPages = [...new Set([...state.recentPages, ...iface.recentPages])].slice(0, 12);
    if (Array.isArray(iface.pinnedCommands)) state.pinnedCommands = iface.pinnedCommands;
  }
  state.engineRead = true;
  emit('engine', state.engine);
}

/** The whole local state of the preferences, mirrored once to the engine (first start of this version). */
export function mirrorAllPrefs() {
  Object.assign(pendingInterface, state.prefs);
  scheduleEngine();
}

// ---------- Screen, target, subject ----------

/** Pages whose title names a target (Domenia 1 Get-DomeniaShellPages, Subject = Selection or Machine). */
export const TARGET_PAGES = { fiche: 'Aucune sélection', poste: 'Aucun poste sélectionné', relations: 'Aucune sélection' };

export function writeActive() {
  return state.app?.mode === 'annuaire' && state.session?.readOnly === false;
}

/** False when the administrator hides the Expert profile (UI.AllowExpertProfile = false). */
export function expertAllowed() {
  return state.policy?.expertAllowed !== false;
}

/** Profile really applied: Essentiel when the administrator hides Expert, whatever was saved. */
export function effectiveProfile() {
  return state.prefs.profile === 'expert' && expertAllowed() ? 'expert' : 'essentiel';
}

/** Mark of the session: account, domain and root DN. A change closes the panels and withdraws the requests. */
export function sessionMark(session = state.session) {
  return `${session?.account?.login ?? ''}|${session?.domain?.dnsName ?? ''}|${session?.domain?.rootDn ?? ''}`;
}

export function simulation() {
  return state.app?.mode === 'simulation' || state.app?.webViewRuntime === 'apercu';
}
