// Environment of the window: layout plan for short or narrow windows (TRV-094; Domenia 1 Get-DomeniaUxHeightPlan), Windows
// high contrast (TRV-001), and the title and frame of the window following the screen and the theme (TRV-011, TRV-050).
// Display state only: a resize never changes a saved preference.
import { state, emit, quietCall, writeActive, TARGET_PAGES } from './store.js';

const root = document.documentElement;

// ---------- Layout plan ----------

/**
 * Plan of a viewport: short under 940 px of height (compact banner, captions folded), low under 700 (smaller spacing),
 * tiny under 560, narrow under 1280 px of width (the menu folds for the session; the saved choice is kept).
 */
export function heightPlan(height, width) {
  const short = height > 0 && height < 940;
  const low = height > 0 && height < 700;
  const tiny = height > 0 && height < 560;
  const narrow = width > 0 && width < 1280;
  return { short, low, tiny, narrow, foldNavigation: narrow || (short && width > 0 && width < 1200) };
}

/** Width the content column keeps beside the help panel before the menu folds (five indicators of the Accueil in a row). */
export const HELP_CONTENT_MIN = 1280;

/**
 * Fold of the menu while the help panel is open (Domenia 1: « le menu se replie », improved): 'fold' when the content beside
 * the panel would fall under 1 280 px, 'unfold' when the panel closed or the window grew enough for the menu to come back
 * (40 px of margin, so a width near the threshold does not swing), 'none' otherwise. `content` is the width of the content
 * column, the panel included (it is laid over it); `navExpanded` and `navCollapsed` are the two widths of the menu.
 * @param {{ helpOpen: boolean, helpFold: boolean, collapsed: boolean, content: number, help: number, navExpanded: number, navCollapsed: number }} o
 * @returns {'fold'|'unfold'|'none'}
 */
export function foldPlan({ helpOpen, helpFold, collapsed, content, help, navExpanded, navCollapsed }) {
  const room = content - help;
  if (helpOpen && !collapsed && room < HELP_CONTENT_MIN) return 'fold';
  if (!helpOpen && helpFold) return 'unfold';
  if (helpOpen && helpFold && collapsed && room - (navExpanded - navCollapsed) >= HELP_CONTENT_MIN + 40) return 'unfold';
  return 'none';
}

let lastPlan = null;

/** Applies the plan to <html data-short|data-low|data-tiny|data-narrow>; emits « layout » when it changes. */
export function applyLayoutPlan() {
  const plan = heightPlan(innerHeight, innerWidth);
  const key = JSON.stringify(plan);
  if (key === lastPlan) return plan;
  lastPlan = key;
  for (const name of ['short', 'low', 'tiny', 'narrow']) {
    if (plan[name]) root.dataset[name] = ''; else delete root.dataset[name];
  }
  emit('layout', plan);
  return plan;
}

// ---------- Windows high contrast ----------

const forced = matchMedia('(forced-colors: active)');

/** Follows the Windows contrast themes (Noir, Blanc…): tokens take the system colours of their role (shell.css). */
export function watchForcedColors(onChange) {
  const apply = () => {
    if (forced.matches) root.dataset.forced = ''; else delete root.dataset.forced;
  };
  apply();
  forced.addEventListener('change', () => { apply(); onChange?.(); });
  // A switch from one contrast theme to another (Noir to Blanc) changes the scheme seen under forced colours.
  matchMedia('(prefers-color-scheme: dark)').addEventListener('change', () => { if (forced.matches) onChange?.(); });
}

// ---------- Title and frame of the window ----------

let chromeTimer = 0;
let lastChrome = '';

/** « Fiche · Camille Martin » for the screen shown (Domenia 1 Get-DomeniaPageTitle). */
export function pageTitle() {
  const page = state.page;
  if (!page) return '';
  const target = state.target ?? (page.id in TARGET_PAGES ? TARGET_PAGES[page.id] : '');
  return target ? `${page.label} · ${target}` : page.label;
}

function hexOf(token) {
  const v = getComputedStyle(root).getPropertyValue(token).trim();
  return /^#[0-9a-f]{6}$/i.test(v) ? v : null;
}

/** Sends the title and theme to the host shortly after a change (the window title shows in Alt+Tab and the taskbar). */
export function syncWindowChrome() {
  clearTimeout(chromeTimer);
  chromeTimer = setTimeout(() => {
    const title = pageTitle();
    document.title = title ? `${title} · Domenia` : 'Domenia';
    const theme = root.dataset.theme;
    const args = {
      title, dark: theme === 'dark' || theme === 'contrast', writeActive: writeActive(),
      caption: theme === 'contrast' ? '#000000' : hexOf('--nav-bg'), text: theme === 'contrast' ? '#ffffff' : hexOf('--text'),
    };
    const key = JSON.stringify(args);
    if (key === lastChrome) return;
    lastChrome = key;
    quietCall('shell.window.chrome', args).catch((err) => console.warn('Barre de titre non mise à jour', err));
  }, 80);
}
