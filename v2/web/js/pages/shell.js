// « Aide et interface » (#/shell): the centre of the common shell. Tabs: overview board of the interface (personalizable),
// help browser (820 topics, guides), keyboard shortcuts, notifications of the session, appearance and visual contract,
// accessibility, pickers and exports, local automation contract, demonstration directory. Everything here is local:
// nothing reads the directory without a gesture (docs/SHELL.md).
import { icon } from '../icons.js';
import { esc, reveal } from '../ui.js';
import { createTabs } from '../kit/index.js';
import { state, on } from '../shell/store.js';
import { notes } from '../shell/notify.js';
import { SHORTCUTS, openShortcuts } from '../shell/shortcuts.js';
import { renderOverview } from './shell/overview.js';
import { renderHelpBrowser } from './shell/help-browser.js';
import { renderAppearance, renderAccessibility } from './shell/appearance.js';
import { renderShortcutsTab, renderNotificationsTab } from './shell/session.js';
import { renderTools, renderAutomation, renderDemonstration } from './shell/tools.js';

export const stylesheet = true;

const TABS = [
  { id: 'apercu', label: 'Vue d’ensemble', icon: 'sparkles' },
  { id: 'aide', label: 'Aide', icon: 'info' },
  { id: 'raccourcis', label: 'Raccourcis', icon: 'command' },
  { id: 'notifications', label: 'Notifications', icon: 'bell' },
  { id: 'apparence', label: 'Apparence', icon: 'sun' },
  { id: 'accessibilite', label: 'Accessibilité', icon: 'eye' },
  { id: 'outils', label: 'Sélecteurs et exports', icon: 'folder' },
  { id: 'automatisation', label: 'Automatisation', icon: 'database' },
  { id: 'demonstration', label: 'Démonstration', icon: 'zap' },
];

const THEME_CHIPS = {
  light: ['sun', 'Thème clair'], dark: ['moon', 'Thème sombre'], contrast: ['contrast', 'Contraste élevé'], system: ['monitor', 'Thème de Windows'],
};

/** Chips of the hero: kept in step with the notifications and the preferences while the screen is shown. */
function heroChips() {
  const unread = notes().filter((n) => !n.read).length;
  const [themeIcon, themeLabel] = THEME_CHIPS[state.prefs.theme] ?? THEME_CHIPS.system;
  const sim = state.app?.mode === 'simulation';
  return `<span class="chip">${icon('info')}820 sujets d’aide</span>
    <span class="chip">${icon('command')}${SHORTCUTS.length} raccourcis</span>
    <span class="chip${unread ? ' warn' : ''}">${icon('bell')}${unread ? `${unread} notification${unread > 1 ? 's' : ''} non lue${unread > 1 ? 's' : ''}` : 'Aucune notification non lue'}</span>
    <span class="chip">${icon(themeIcon)}${esc(themeLabel)}</span>
    ${sim ? `<span class="chip info">${icon('zap')}Simulation</span>` : ''}`;
}

export function render(main, ctx) {
  const wanted = TABS.some((t) => t.id === ctx.params.onglet) ? ctx.params.onglet : null;
  const unread = notes().filter((n) => !n.read).length;
  main.innerHTML = `<div class="page sh-centre-page">
    <section class="hero sh-hero reveal">
      <span class="glow-ring" aria-hidden="true"></span>
      <div class="orbs" aria-hidden="true"><span class="orb a"></span><span class="orb b"></span><span class="orb c"></span></div>
      <div class="sh-hero-grid">
        <div class="sh-hero-main">
          <div class="eyebrow">${icon('sparkles')}Coque de Domenia</div>
          <h1 class="gradient-text">Aide et interface</h1>
          <p class="lead">Tout ce qui est commun aux écrans : aide contextuelle des 820 contrôles, raccourcis, palette, notifications de la session, apparence, accessibilité, sélecteurs partagés et exports. Rien n’est lu dans l’annuaire sans votre geste.</p>
          <div class="sh-hero-chips">${heroChips()}</div>
          <div class="hero-row">
            <button class="btn primary" type="button" data-hero="help">${icon('info')}Ouvrir l’aide<kbd>F1</kbd></button>
            <button class="btn" type="button" data-hero="palette">${icon('command')}Palette de commandes<kbd>Ctrl K</kbd></button>
            <button class="btn ghost" type="button" data-hero="keys">${icon('command')}Raccourcis<kbd>Maj ?</kbd></button>
          </div>
        </div>
        <aside class="sh-hero-side card">
          <h2 class="sh-side-title">${icon('zap')}Gestes essentiels</h2>
          <ul class="sh-side-list">
            <li><kbd>Ctrl</kbd><kbd>K</kbd><span>Aller n’importe où, lancer une commande, chercher une aide ou un objet</span></li>
            <li><kbd>F1</kbd><span>Aide sur l’élément survolé ou qui a le focus, motif d’un bouton grisé</span></li>
            <li><kbd>Ctrl</kbd><kbd>L</kbd><span>Journal de la session : notifications et opérations</span></li>
            <li><kbd>Alt</kbd><kbd>←</kbd><span>Écran précédent, avec son état</span></li>
          </ul>
        </aside>
      </div>
    </section>
    <div class="sh-tabs-host reveal"></div>
  </div>`;
  const stopReveal = reveal(main);
  const chips = main.querySelector('.sh-hero-chips');
  const repaintChips = () => {
    const next = heroChips();
    if (chips.dataset.last === next) return;
    chips.dataset.last = next;
    chips.classList.add('quiet');
    chips.innerHTML = next;
  };
  chips.dataset.last = heroChips();
  const offChips = [on('prefs', repaintChips), on('notes', repaintChips)];
  Promise.resolve(ctx.app).then(repaintChips, () => {});
  main.querySelector('.sh-hero').addEventListener('click', (e) => {
    const b = e.target instanceof Element ? e.target.closest('[data-hero]') : null;
    if (!b) return;
    if (b.dataset.hero === 'help') ctx.help.open();
    if (b.dataset.hero === 'palette') ctx.openPalette();
    if (b.dataset.hero === 'keys') openShortcuts();
  });
  const cleanups = [];
  const renderers = {
    apercu: renderOverview,
    aide: renderHelpBrowser,
    raccourcis: renderShortcutsTab,
    notifications: renderNotificationsTab,
    apparence: renderAppearance,
    accessibilite: renderAccessibility,
    outils: renderTools,
    automatisation: renderAutomation,
    demonstration: renderDemonstration,
  };
  const tabs = createTabs(main.querySelector('.sh-tabs-host'), {
    label: 'Rubriques de l’aide et de l’interface',
    key: wanted ? undefined : 'shell.onglet',
    selected: wanted ?? 'apercu',
    tabs: TABS.map((t) => ({
      ...t,
      count: t.id === 'notifications' && unread ? unread : null,
      tone: 'info',
      render: (panel) => {
        const out = renderers[t.id](panel, ctx);
        if (typeof out === 'function') cleanups.push(out);
      },
    })),
    onChange: (id) => {
      // The tab is part of the address (links of the guides, captures), without a new history entry.
      const target = ctx.link('shell', { ...ctx.params, onglet: id });
      if (location.hash !== target) history.replaceState(null, '', target);
    },
  });
  return () => {
    stopReveal();
    offChips.forEach((off) => off());
    cleanups.forEach((fn) => { try { fn(); } catch (err) { console.error(err); } });
    tabs.destroy?.();
  };
}

export const meta = { label: 'Aide et interface', icon: 'sparkles' };
