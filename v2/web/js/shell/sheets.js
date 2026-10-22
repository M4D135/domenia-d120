// Embedded sheets (panels and dialogs of the kit) seen from the shell (TRV-056, TRV-057; Domenia 1 Show-DomeniaEmbeddedWindow,
// Register-DomeniaSurfaceKeys, Set-DomeniaEmbeddedTheme, Get-DomeniaSurfaceRecord): Entrée activates the default button of a
// modal panel outside multi-line text, every control gets a default tooltip by its type (password never saved, « Annuler »
// validates nothing…) and an accessible name, and the time the interface stayed blocked by a modal panel is measured (count
// and duration only, technical journal). The panels themselves stay those of the kit (web/js/kit/drawer.js, dialog.js).
import { state, quietCall } from './store.js';
import { accessibleName } from './a11y.js';

/** Default tooltips by type of control (Domenia 1 Set-DomeniaEmbeddedTheme). */
export const SHEET_TIPS = Object.freeze({
  password: 'Mot de passe de cette demande. Jamais enregistré dans les préférences.',
  text: 'Saisie de ce panneau. Annuler ne valide aucune modification.',
  grid: 'Sélectionnez une ligne. Le choix doit être confirmé avec le bouton du panneau.',
  list: 'Sélectionnez un élément puis confirmez votre choix.',
  cancel: 'Ferme le panneau sans rien valider ni enregistrer.',
  button: 'Action de ce panneau. Les contrôles de droits restent applicables.',
});

/**
 * Default tooltip of a control of a sheet, or '' when it keeps its own (data-tip, data-help, title) or needs none.
 * @param {{ tag: string, type?: string, role?: string, label?: string }} c
 */
export function sheetTip({ tag, type = '', role = '', label = '' }) {
  const t = String(tag ?? '').toUpperCase();
  const name = String(label ?? '').trim().toLowerCase();
  if (t === 'INPUT' && type === 'password') return SHEET_TIPS.password;
  if ((t === 'INPUT' && ['', 'text', 'search', 'number', 'date', 'datetime-local', 'time', 'email'].includes(type)) || t === 'TEXTAREA') return SHEET_TIPS.text;
  if (role === 'grid' || role === 'treegrid') return SHEET_TIPS.grid;
  if (role === 'listbox' || role === 'tree') return SHEET_TIPS.list;
  if (t === 'BUTTON' && (name === 'annuler' || name === 'fermer')) return SHEET_TIPS.cancel;
  return '';
}

const SELECTOR = 'input, textarea, select, button, [role="grid"], [role="treegrid"], [role="listbox"], [role="tree"]';

/** Applies the default tooltips, descriptions and names to the controls of a sheet (once per control). */
export function decorateSheet(scope) {
  for (const el of scope.querySelectorAll(SELECTOR)) {
    if (el.dataset.sheetDecorated === '1' || el.type === 'hidden') continue;
    el.dataset.sheetDecorated = '1';
    const own = el.dataset.tip || el.dataset.help || el.title;
    const name = accessibleName(el);
    const tip = sheetTip({ tag: el.tagName, type: el.getAttribute('type') ?? '', role: el.getAttribute('role') ?? '', label: name });
    if (!own && tip) el.dataset.tip = tip;
    if (!el.hasAttribute('aria-description')) {
      const help = own || tip || (el.tagName === 'BUTTON' ? SHEET_TIPS.button : '');
      if (help && help !== name) el.setAttribute('aria-description', help);
    }
    if (!name && (own || tip)) el.setAttribute('aria-label', own || tip);
  }
}

/** True when Entrée should run the default button: a plain field or the panel itself, never a button, a list or a long text. */
export function enterRunsDefault(target) {
  if (!(target instanceof Element)) return false;
  if (target.matches('.k-drw')) return true;
  if (target.closest('[role="grid"], [role="tree"], [role="treegrid"], [role="listbox"], [role="menu"], [role="tablist"], [contenteditable="true"]')) return false;
  if (target.tagName === 'INPUT') return ['', 'text', 'search', 'number', 'date', 'datetime-local', 'time', 'email', 'checkbox', 'radio'].includes(target.getAttribute('type') ?? '');
  return target.tagName === 'SELECT';
}

const opened = new Map(); // layer → { at, route }
const pendingMetric = { count: 0, ms: 0, route: '' };
let metricTimer = 0;

function routeName() {
  const id = state.page?.id;
  return id && /^[a-z][a-z0-9-]{0,29}$/.test(id) ? id : 'demarrage';
}

function flushMetric() {
  if (!pendingMetric.count) return;
  const { count, ms, route } = pendingMetric;
  pendingMetric.count = 0;
  pendingMetric.ms = 0;
  quietCall('shell.metric', { kind: 'sheet', route, count: Math.min(count, 1000), milliseconds: Math.min(Math.round(ms), 86_400_000) })
    .catch((err) => console.warn('Temps bloqué non signalé au journal', err));
}

let blockedTotal = 0;
let blockedCount = 0;

/** Modal panels closed during the session and the time they held the interface. */
export function blockedTime() { return { count: blockedCount, ms: blockedTotal }; }

function closedLayer(layer) {
  const o = opened.get(layer);
  if (!o) return;
  opened.delete(layer);
  const ms = Math.max(0, performance.now() - o.at);
  blockedTotal += ms;
  blockedCount += 1;
  if (pendingMetric.count && pendingMetric.route !== o.route) flushMetric();
  pendingMetric.route = o.route;
  pendingMetric.count += 1;
  pendingMetric.ms += ms;
  clearTimeout(metricTimer);
  metricTimer = setTimeout(flushMetric, 2000);
}

/** Installs the behaviour of the sheets for the whole window (once). */
export function installSheets() {
  // Entrée runs the primary button of the modal panel that has the focus, when no field of the panel used the key.
  document.addEventListener('keydown', (e) => {
    if (e.key !== 'Enter' || e.defaultPrevented || e.isComposing || e.ctrlKey || e.metaKey || e.altKey || e.shiftKey) return;
    const target = e.target instanceof Element ? e.target : null;
    const panel = target?.closest('.k-drw-layer.modal .k-drw');
    if (!panel || !enterRunsDefault(target)) return;
    const primary = panel.querySelector('.k-drw-foot .btn.primary:not([disabled]):not([aria-disabled="true"])');
    if (!primary) return;
    e.preventDefault();
    primary.click();
  });
  const scan = (node) => {
    if (!(node instanceof HTMLElement)) return;
    const layers = node.matches('.k-drw-layer, .k-dlg-layer') ? [node] : [...node.querySelectorAll('.k-drw-layer, .k-dlg-layer')];
    for (const layer of layers) {
      decorateSheet(layer);
      if ((layer.matches('.k-drw-layer.modal') || layer.matches('.k-dlg-layer')) && !opened.has(layer)) opened.set(layer, { at: performance.now(), route: routeName() });
    }
  };
  new MutationObserver((records) => {
    for (const r of records) {
      r.addedNodes.forEach((n) => {
        if (n instanceof HTMLElement && (n.matches('.k-drw-layer, .k-dlg-layer') || n.parentElement === document.body)) scan(n);
        else if (n instanceof HTMLElement) { const layer = n.closest('.k-drw-layer, .k-dlg-layer'); if (layer) decorateSheet(layer); }
      });
      r.removedNodes.forEach((n) => { if (n instanceof HTMLElement && opened.has(n)) closedLayer(n); });
    }
  }).observe(document.body, { childList: true, subtree: true });
  window.addEventListener('pagehide', flushMetric);
}
