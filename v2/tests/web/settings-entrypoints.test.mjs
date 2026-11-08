import { test, eq, ok } from './harness.mjs';
import { render as renderHelp } from '../../web/js/pages/shell.js';
import { mount as mountAppearance } from '../../web/js/pages/parametres/apparence.js';
import { interfacePrefs } from '../../web/js/pages/parametres/interface.js';
import { SHORTCUTS } from '../../web/js/shell/shortcuts.js';

const settle = async () => { for (let i = 0; i < 30; i++) await Promise.resolve(); };
const fixture = () => { const host = document.createElement('div'); document.body.append(host); return host; };

test('Paramètres seuls : Aide garde thèmes et profil, sans entrée Démonstration ni réglage Animations', () => {
  const host = fixture(); const address = location.href;
  const dispose = renderHelp(host, { params: { onglet: 'apparence' }, link: (page, params) => `#/${page}?${new URLSearchParams(params)}` });
  try {
    eq([...host.querySelectorAll('[role="tab"]')].filter(el => el.textContent.includes('Démonstration')).length, 0, 'aucun second onglet Démonstration');
    eq(host.querySelectorAll('[data-pref="motion"], [data-group="motion"]').length, 0, 'aucun contrôle Animations dans Aide');
    eq(host.querySelectorAll('[data-pref="theme"]').length, 4, 'quatre thèmes préservés');
    eq(host.querySelectorAll('[data-pref="profile"]').length, 2, 'deux profils préservés');
    ok(!SHORTCUTS.some(([id]) => /^(motion|demo)/.test(id)), 'aucun raccourci de changement de ces réglages');
  } finally { dispose(); host.remove(); history.replaceState(null, '', address); }
});

test('Paramètres seuls : un ancien lien Démonstration conduit à la section actuelle sans commande de bascule', () => {
  const host = fixture(); const routes = [];
  const dispose = renderHelp(host, { params: { onglet: 'demonstration' }, go: (...args) => routes.push(args) });
  try {
    eq(routes, [['parametres', { section: 'demonstration' }]], 'redirection vers Paramètres');
    eq(host.querySelectorAll('button').length, 0, 'aucune deuxième entrée dessinée');
  } finally { dispose(); host.remove(); }
});

test('Paramètres seuls : les trois réglages Animations restent persistants et accessibles au clavier', async () => {
  const host = fixture(), root = document.documentElement;
  const oldMotion = root.getAttribute('data-motion'), oldPrefs = localStorage.getItem('domenia.prefs.v1');
  root.dataset.motion = 'full';
  const prefs = interfacePrefs({}), calls = [];
  const api = mountAppearance(host, {
    prefs, allowExpert: () => true, config: async () => ({}), refreshAppearanceTile() {}, setZoom() {}, toast() {},
    async call(op) { calls.push(op); return { available: false, zoom: 100, window: 'Hôte indisponible dans ce test' }; },
  });
  try {
    await settle();
    eq(host.querySelectorAll('[data-seg="motion"] [role="radio"]').length, 3, 'trois choix conservés dans Paramètres');
    for (const value of ['reduced', 'system', 'full']) {
      host.querySelector(`[data-seg="motion"] [data-value="${value}"]`).click();
      eq(prefs.get().motion, value, `${value} appliqué`);
      eq(JSON.parse(localStorage.getItem('domenia.prefs.v1')).motion, value, `${value} mémorisé`);
    }
    const full = host.querySelector('[data-seg="motion"] [data-value="full"]');
    full.focus(); full.dispatchEvent(new KeyboardEvent('keydown', { key: 'ArrowRight', bubbles: true, cancelable: true }));
    const reduced = host.querySelector('[data-seg="motion"] [data-value="reduced"]');
    ok(document.activeElement === reduced, 'focus conservé sur le choix suivant');
    eq(reduced.getAttribute('aria-checked'), 'true', 'choix clavier appliqué');
    eq(prefs.get().motion, 'reduced', 'préférence clavier conservée');
    eq(calls, ['settings.window'], 'aucun appel de démonstration ou réseau');
  } finally {
    api.destroy(); host.remove();
    if (oldPrefs === null) localStorage.removeItem('domenia.prefs.v1'); else localStorage.setItem('domenia.prefs.v1', oldPrefs);
    if (oldMotion === null) root.removeAttribute('data-motion'); else root.setAttribute('data-motion', oldMotion);
  }
});
