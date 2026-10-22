// « Aide et interface » (#/shell): the centre of the common interface. A compact header (title, the three gestures of the
// help) then tabs: overview board of the interface (personalizable), help browser (820 topics, guides), keyboard shortcuts,
// notifications of the session, appearance and visual contract, accessibility, shared tools (pickers, request in the page,
// exports), local automation contract, demonstration directory. Everything here is local: nothing reads the directory
// without a gesture (docs/SHELL.md).
import { icon } from '../icons.js';
import { reveal } from '../ui.js';
import { createTabs } from '../kit/index.js';
import { on } from '../shell/store.js';
import { notes } from '../shell/notify.js';
import { openShortcuts } from '../shell/shortcuts.js';
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
  { id: 'outils', label: 'Outils partagés', icon: 'folder' },
  { id: 'automatisation', label: 'Automatisation', icon: 'database' },
  { id: 'demonstration', label: 'Démonstration', icon: 'zap' },
];

export function render(main, ctx) {
  const wanted = TABS.some((t) => t.id === ctx.params.onglet) ? ctx.params.onglet : null;
  const unread = () => notes().filter((n) => !n.read).length;
  // A compact header, the same on every tab: the content of a tab starts right under the tabs, even on a laptop screen.
  main.innerHTML = `<div class="page sh-centre-page">
    <header class="page-header sh-page-head reveal">
      <div class="head-row"><span class="page-icon">${icon('sparkles')}</span>
        <div class="titles"><h1 class="gradient-text">Aide et interface</h1>
          <p class="subtitle">Interface commune à tous les écrans${' '}: aide, raccourcis, notifications, apparence et outils partagés</p></div></div>
      <div class="actions">
        <button class="btn primary" type="button" data-head="help">${icon('info')}Ouvrir l’aide<kbd>F1</kbd></button>
        <button class="btn" type="button" data-head="palette">${icon('command')}Palette<kbd>Ctrl K</kbd></button>
        <button class="btn ghost" type="button" data-head="keys">${icon('command')}Raccourcis<kbd>Maj ?</kbd></button>
      </div>
    </header>
    <div class="sh-tabs-host reveal"></div>
  </div>`;
  const stopReveal = reveal(main);
  main.querySelector('.sh-page-head').addEventListener('click', (e) => {
    const b = e.target instanceof Element ? e.target.closest('[data-head]') : null;
    if (!b) return;
    if (b.dataset.head === 'help') ctx.help.open();
    if (b.dataset.head === 'palette') ctx.openPalette();
    if (b.dataset.head === 'keys') openShortcuts();
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
      count: t.id === 'notifications' && unread() ? unread() : null,
      tone: 'info',
      render: (panel) => {
        const out = renderers[t.id](panel, ctx);
        if (typeof out === 'function') cleanups.push(out);
      },
    })),
    onChange: (id) => {
      // The tab is part of the address (links of the guides, captures), without a new history entry.
      const params = { ...ctx.params, onglet: id };
      if (id !== 'aide') delete params.ecran;
      const target = ctx.link('shell', params);
      if (location.hash !== target) history.replaceState(null, '', target);
    },
  });
  // The counter of the tab « Notifications » follows the messages while the screen is shown.
  const offNotes = on('notes', () => tabs.setCount?.('notifications', unread() || null, 'info'));
  return () => {
    stopReveal();
    offNotes();
    cleanups.forEach((fn) => { try { fn(); } catch (err) { console.error(err); } });
    tabs.destroy?.();
  };
}

export const meta = { label: 'Aide et interface', icon: 'sparkles' };
