import { test, eq, ok } from './harness.mjs';
import { mount as mountAppearance } from '../../web/js/pages/parametres/apparence.js';
import { interfacePrefs } from '../../web/js/pages/parametres/interface.js';

const settle = async () => { for (let i = 0; i < 30; i++) await Promise.resolve(); };
const wait = ms => new Promise(resolve => setTimeout(resolve, ms));

// Runs the real boot.js once more in this page while the canvas answers as the given graphics stack (null: no accelerated
// WebGL), then restores the page. Without a boot screen in the page, its start guard has nothing to act on.
async function bootWith(renderer) {
  const root = document.documentElement, names = ['data-theme', 'data-theme-pref', 'data-motion', 'data-render'];
  const saved = names.map(name => root.getAttribute(name));
  const proto = HTMLCanvasElement.prototype, original = proto.getContext, calls = [];
  let lost = 0;
  root.removeAttribute('data-render');
  proto.getContext = function (kind, options) {
    calls.push([kind, options?.failIfMajorPerformanceCaveat === true]);
    if (renderer === null) return null;
    return {
      RENDERER: 0x1F01,
      getExtension(name) {
        if (name === 'WEBGL_debug_renderer_info') return { UNMASKED_RENDERER_WEBGL: 0x9246 };
        if (name === 'WEBGL_lose_context') return { loseContext() { lost++; } };
        return null;
      },
      getParameter(p) { return p === 0x9246 ? renderer : 'WebKit WebGL'; },
    };
  };
  const script = document.createElement('script');
  script.src = new URL('../../web/js/boot.js', import.meta.url).href;
  try {
    await new Promise((resolve, reject) => { script.onload = resolve; script.onerror = reject; document.head.append(script); });
    await wait(30);
    return { render: root.dataset.render, motion: root.dataset.motion, calls, lost };
  } finally {
    proto.getContext = original; script.remove();
    names.forEach((name, i) => { if (saved[i] === null) root.removeAttribute(name); else root.setAttribute(name, saved[i]); });
  }
}

test('Affichage sans accélération graphique : mesuré au démarrage, une seule fois, sans changer le choix Animations', async () => {
  const none = await bootWith(null);
  eq(none.render, 'software', 'aucun WebGL accéléré : rendu logiciel');
  eq(none.calls, [['webgl', true]], 'une seule mesure, avec refus du rendu dégradé');
  const warp = await bootWith('ANGLE (Microsoft, Microsoft Basic Render Driver Direct3D11 vs_5_0 ps_5_0, D3D11)');
  eq(warp.render, 'software', 'pilote d’affichage de base de Windows : rendu logiciel');
  eq(warp.lost, 1, 'contexte de mesure libéré');
  const shader = await bootWith('ANGLE (Google, Vulkan 1.3.0 (SwiftShader Device (Subzero) (0x0000C0DE)), SwiftShader driver)');
  eq(shader.render, 'software', 'SwiftShader : rendu logiciel');
  const gpu = await bootWith('ANGLE (NVIDIA, NVIDIA GeForce RTX 3060 Direct3D11 vs_5_0 ps_5_0, D3D11)');
  eq(gpu.render, undefined, 'carte graphique : affichage normal');
  eq(gpu.lost, 1, 'contexte de mesure libéré aussi avec accélération');
  ok([none, warp, shader, gpu].every(r => ['full', 'reduced', 'system'].includes(r.motion)), 'choix Animations appliqué comme avant');
});

test('Affichage sans accélération graphique : les boucles s’arrêtent après un passage, l’aurore reste immobile', async () => {
  const root = document.documentElement;
  const oldMotion = root.getAttribute('data-motion'), oldRender = root.getAttribute('data-render');
  const css = document.createElement('link'); css.rel = 'stylesheet';
  css.href = new URL('../../web/css/motion.css', import.meta.url).href;
  const host = document.createElement('div');
  host.innerHTML = '<div class="aurora"></div><span class="pulse"></span>';
  try {
    await new Promise((resolve, reject) => { css.onload = resolve; css.onerror = reject; document.head.append(css); });
    document.body.append(host);
    root.dataset.motion = 'full'; root.removeAttribute('data-render');
    const aurora = host.querySelector('.aurora'), pulse = host.querySelector('.pulse');
    eq(getComputedStyle(aurora).animationName, 'aurora-drift', 'aurore animée avec accélération');
    eq(getComputedStyle(pulse, '::after').animationIterationCount, 'infinite', 'anneau en boucle avec accélération');
    root.dataset.render = 'software';
    eq(getComputedStyle(aurora).animationName, 'none', 'aurore immobile sans accélération');
    eq(getComputedStyle(pulse, '::after').animationIterationCount, '1', 'boucle arrêtée après un passage');
    eq(getComputedStyle(pulse, '::after').animationName, 'pulse-ring', 'animation ponctuelle conservée avec le choix Riches');
    eq(root.dataset.motion, 'full', 'choix de l’opérateur inchangé');
  } finally {
    host.remove(); css.remove();
    if (oldMotion === null) root.removeAttribute('data-motion'); else root.setAttribute('data-motion', oldMotion);
    if (oldRender === null) root.removeAttribute('data-render'); else root.setAttribute('data-render', oldRender);
  }
});

test('Affichage sans accélération graphique : Paramètres > Apparence le dit et fige la démonstration', async () => {
  const root = document.documentElement;
  const host = document.createElement('div'); host.dataset.page = 'parametres'; document.body.append(host);
  const oldMotion = root.getAttribute('data-motion'), oldRender = root.getAttribute('data-render'), oldPrefs = localStorage.getItem('domenia.prefs.v1');
  root.dataset.motion = 'full'; root.dataset.render = 'software';
  const api = mountAppearance(host, {
    prefs: interfacePrefs({}), allowExpert: () => true, config: async () => ({}), refreshAppearanceTile() {}, setZoom() {}, toast() {},
    async call() { return { available: false, zoom: 100, window: 'Hôte indisponible dans ce test' }; },
  });
  try {
    await settle();
    const state = host.querySelector('[data-slot="motion-state"]').textContent;
    ok(state.includes('Animations riches en ce moment'), 'choix Riches affiché tel quel');
    ok(state.includes('sans accélération graphique') && state.includes('après un passage'), 'raison et effet expliqués');
    ok(host.querySelector('.pr-motion-demo').classList.contains('still'), 'démonstration figée');
    root.removeAttribute('data-render');
    host.querySelector('[data-seg="motion"] [data-value="full"]').click(); await wait(60);
    ok(!host.querySelector('[data-slot="motion-state"]').textContent.includes('accélération'), 'aucune mention avec accélération');
  } finally {
    api.destroy(); host.remove();
    if (oldPrefs === null) localStorage.removeItem('domenia.prefs.v1'); else localStorage.setItem('domenia.prefs.v1', oldPrefs);
    if (oldMotion === null) root.removeAttribute('data-motion'); else root.setAttribute('data-motion', oldMotion);
    if (oldRender === null) root.removeAttribute('data-render'); else root.setAttribute('data-render', oldRender);
  }
});
