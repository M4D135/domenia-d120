// Paramètres: the interface preferences that the shell owns (docs/SHELL.md): theme, animations, folded menu, display profile,
// density of the lists and help tips. One store and one vocabulary, those of the shell: localStorage « domenia.prefs.v1 »,
// profile « essentiel » | « expert », density « compact » | « normal » | « confortable ». When the shell exposes its API to
// the screens (ctx.prefs: get, set, on), Paramètres uses it and nothing else; until then it drives the very controls of the
// shell (theme buttons of the top bar, button of the menu) and writes the same key, keeping every other key of the shell.
// The zoom is not here: it is the native zoom of the window, set by the host (settings.window.zoom.set).

import { normalizePrefs, gridDensity, PREF_VALUES } from './pure.js';

export { gridDensity };

const PREF_KEY = 'domenia.prefs.v1';
const { theme: THEMES, motion: MOTIONS, profile: PROFILES, density: DENSITIES } = PREF_VALUES;

function readStore() {
  try {
    const raw = JSON.parse(localStorage.getItem(PREF_KEY) ?? '{}');
    return raw && typeof raw === 'object' ? raw : {};
  } catch {
    return {};
  }
}

function writeStore(next) {
  try { localStorage.setItem(PREF_KEY, JSON.stringify(next)); } catch { /* private mode: applied for the session only */ }
}

/** The preferences as the shell normalizes them (same defaults). */
export const normalize = normalizePrefs;

/**
 * The adapter of a screen context. get(): current preferences; set(changes): applies and remembers them; on(fn): called
 * after any change (from Paramètres, the top bar, Ctrl B, another screen); expert(): Expert view now (profile, or the
 * one-time expert view of the shell, ctx.expert); help: the help panel of the shell when it exists.
 */
export function interfacePrefs(ctx) {
  const root = document.documentElement;
  const api = ctx?.prefs && typeof ctx.prefs.get === 'function' && typeof ctx.prefs.set === 'function' ? ctx.prefs : null;
  const listeners = new Set();
  const emit = (changed) => { for (const fn of [...listeners]) { try { fn(changed); } catch (err) { console.error(err); } } };

  // The theme and the animations as the shell applied them; the folded menu is the remembered choice (the shell may fold
  // it for a while on a narrow window without changing the choice).
  function domState() {
    return { theme: root.dataset.themePref, motion: root.dataset.motion };
  }

  function get() {
    if (api) return normalize(api.get());
    const stored = readStore();
    const dom = domState();
    return normalize({ ...stored, ...Object.fromEntries(Object.entries(dom).filter(([, v]) => v !== undefined)) });
  }

  // The shell of this version rewrites its key with its own fields only: the fields it does not know are written back.
  function keepShellFields(snapshot) {
    const now = readStore();
    const keep = {};
    for (const k of ['profile', 'density', 'helpTips']) if (k in snapshot && !(k in now)) keep[k] = snapshot[k];
    if (Object.keys(keep).length) writeStore({ ...now, ...keep });
  }

  function set(changes) {
    const clean = {};
    if (THEMES.includes(changes.theme)) clean.theme = changes.theme;
    if (MOTIONS.includes(changes.motion)) clean.motion = changes.motion;
    if (typeof changes.navCollapsed === 'boolean') clean.navCollapsed = changes.navCollapsed;
    if (PROFILES.includes(changes.profile)) clean.profile = changes.profile;
    if (DENSITIES.includes(changes.density)) clean.density = changes.density;
    if (typeof changes.helpTips === 'boolean') clean.helpTips = changes.helpTips;
    if (!Object.keys(clean).length) return get();
    if (api) {
      api.set(clean);
      emit(clean);
      return get();
    }
    const snapshot = readStore();
    const local = {};
    for (const k of ['motion', 'profile', 'density', 'helpTips']) if (k in clean) local[k] = clean[k];
    if (Object.keys(local).length) writeStore({ ...readStore(), ...local });
    if ('motion' in clean) root.dataset.motion = clean.motion;
    if ('theme' in clean && root.dataset.themePref !== clean.theme) {
      // The theme buttons of the top bar: the same view transition, the same memory as a click of the operator.
      document.querySelector(`.theme-switch button[data-set="${clean.theme}"]`)?.click();
    }
    if ('navCollapsed' in clean && normalize(snapshot).navCollapsed !== clean.navCollapsed) document.querySelector('.nav-toggle')?.click();
    keepShellFields({ ...snapshot, ...local });
    window.dispatchEvent(new CustomEvent('domenia:prefs', { detail: clean }));
    emit(clean);
    return get();
  }

  function on(fn) {
    listeners.add(fn);
    const offs = [() => listeners.delete(fn)];
    if (api && typeof api.on === 'function') {
      const off = api.on(fn);
      if (typeof off === 'function') offs.push(off);
    } else {
      const observer = new MutationObserver(() => fn({}));
      observer.observe(root, { attributes: true, attributeFilter: ['data-theme-pref', 'data-motion'] });
      const shell = document.querySelector('.shell');
      if (shell) observer.observe(shell, { attributes: true, attributeFilter: ['class'] });
      const onStorage = (e) => { if (e.key === PREF_KEY) fn({}); };
      window.addEventListener('storage', onStorage);
      offs.push(() => observer.disconnect(), () => window.removeEventListener('storage', onStorage));
    }
    return () => offs.forEach((off) => off());
  }

  return {
    get,
    set,
    on,
    /** Expert view now: the profile, or the one-time expert view of the shell (« ?vue=expert »). */
    expert: (allowed = true) => allowed && (ctx?.expert === true || get().profile === 'expert'),
    /** The help panel (F1) of the shell, when this version has it. */
    help: ctx?.help && typeof ctx.help.open === 'function' ? ctx.help : null,
    /** True when the shell gives its API to the screens (one source of truth). */
    shared: !!api,
  };
}

const READING_KEY = 'domenia.parametres.v1';
const LEGACY_UI_KEY = 'domenia.ui.v1';

/** Reading options of the technical journal (Domenia 1: wrap and text size remembered): a convenience of this viewer. */
export function readingPrefs() {
  try {
    const raw = JSON.parse(localStorage.getItem(READING_KEY) ?? '{}');
    return raw && typeof raw === 'object' ? raw : {};
  } catch {
    return {};
  }
}

export function saveReadingPrefs(patch) {
  try { localStorage.setItem(READING_KEY, JSON.stringify({ ...readingPrefs(), ...patch })); } catch { /* private mode: for the session only */ }
}

/**
 * One-time move of the older key of Paramètres (« domenia.ui.v1 », before the store of the shell): the reading options of the
 * journal go to their own key, the profile and the density to the key of the shell when it has none, then the old key is
 * removed. The zoom is no longer a page setting (native zoom of the window, kept by the host).
 */
export function migrateLegacyUi() {
  let old;
  try { old = JSON.parse(localStorage.getItem(LEGACY_UI_KEY) ?? 'null'); } catch { old = null; }
  if (!old || typeof old !== 'object') return false;
  const reading = {};
  if (typeof old.logWrap === 'boolean') reading.logWrap = old.logWrap;
  if (Number.isInteger(old.logSize)) reading.logSize = old.logSize;
  if (Object.keys(reading).length) saveReadingPrefs(reading);
  const shell = readStore();
  const fill = {};
  if (!('profile' in shell) && PROFILES.includes(old.profile)) fill.profile = old.profile;
  if (!('density' in shell) && (old.density === 'compact' || old.density === 'confort')) fill.density = old.density === 'compact' ? 'compact' : 'normal';
  if (Object.keys(fill).length) writeStore({ ...shell, ...fill });
  try { localStorage.removeItem(LEGACY_UI_KEY); } catch { /* nothing to remove */ }
  return true;
}
