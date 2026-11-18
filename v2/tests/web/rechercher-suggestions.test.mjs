import { test, eq, ok } from './harness.mjs';
import { createBar } from '../../web/js/pages/rechercher/bar.js';
import { setLayoutStore } from '../../web/js/kit/util.js';

async function fixture(onSuggest = async () => []) {
  const styles = [];
  for (const file of ['layout.css', 'motion.css', 'components.css', 'kit.css', 'pages/rechercher.css']) {
    const css = document.createElement('link'); css.rel = 'stylesheet';
    css.href = new URL(`../../web/css/${file}`, import.meta.url).href;
    styles.push(css);
    await new Promise((resolve, reject) => { css.onload = resolve; css.onerror = () => reject(new Error(`CSS absent : ${file}`)); document.head.append(css); });
  }
  const memory = new Map();
  setLayoutStore({ read: key => memory.get(key), write: (key, value) => memory.set(key, value) });
  const host = document.createElement('main'); host.className = 'main'; host.dataset.page = 'rechercher';
  Object.assign(host.style, { position: 'fixed', left: '0', top: '0', width: 'min(1100px, 100vw)', height: '100vh', zIndex: '40', background: 'var(--bg)' });
  host.innerHTML = `<div class="page rch">
    <section class="rch-hero reveal in"><div class="rch-hero-top"><h1>Rechercher</h1></div><div class="rch-bar-host"></div></section>
    <div class="rch-work reveal in"><aside class="rch-side card glass">Unités d’organisation</aside><section class="rch-results card glass">Résultats</section><aside class="rch-preview card glass">Aperçu</aside></div>
  </div>`;
  document.body.append(host);
  const submitted = [], opened = [];
  const bar = createBar(host.querySelector('.rch-bar-host'), {
    getRecents: () => Array.from({ length: 8 }, (_, n) => ({ kind: 'search', text: `Recherche ${n + 1}` })),
    onSuggest, onSubmit: state => submitted.push(state), onOpenObject: (...args) => opened.push(args),
    onClearRecents() {}, onSyntaxHelp() {},
  });
  const input = host.querySelector('.rch-input');
  return { host, bar, input, submitted, opened,
    open() { input.focus(); input.click(); host.getAnimations({ subtree: true }).forEach(animation => animation.finish()); },
    close() { bar.destroy(); host.remove(); styles.forEach(css => css.remove()); setLayoutStore(null); },
  };
}

test('Rechercher : historique au premier plan devant les options et les résultats, en barre large et compacte', async () => {
  const original = { theme: document.documentElement.dataset.theme, motion: document.documentElement.dataset.motion };
  const f = await fixture();
  try {
    for (const theme of ['light', 'dark', 'contrast']) for (const motion of ['full', 'reduced']) for (const compact of [false, true]) {
      document.documentElement.dataset.theme = theme; document.documentElement.dataset.motion = motion;
      f.bar.setText(''); f.bar.setCompact(compact);
      const hero = f.host.querySelector('.rch-hero');
      // Match the page's compact(): its entry animation is settled before the compact animation takes over.
      if (compact && hero.classList.contains('reveal')) { hero.classList.remove('reveal', 'in'); hero.classList.add('revealed'); }
      hero.classList.toggle('compact', compact);
      f.open();
      eq(getComputedStyle(hero).opacity, '1', 'l’en-tête est réellement visible après son animation');
      const pop = f.host.querySelector('.rch-sugg'), field = f.host.querySelector('.rch-field');
      eq(f.input.getAttribute('aria-expanded'), 'true', 'historique ouvert');
      const box = pop.getBoundingClientRect();
      // The menu overlaps the actual options in the expanded bar and the actual result panes in both layouts.
      const behind = [f.host.querySelector('.rch-work')];
      if (!compact) behind.unshift(f.host.querySelector('.rch-opts button'));
      for (const el of behind) {
        const r = el.getBoundingClientRect();
        const x = Math.max(r.left, box.left) + 24, y = Math.max(r.top, box.top) + 12;
        ok(x < Math.min(r.right, box.right) && y < Math.min(r.bottom, box.bottom), 'le point contrôlé recouvre réellement le panneau');
        const hit = document.elementFromPoint(x, y);
        ok(pop.contains(hit), `historique cliquable devant ${el.className} (${theme}/${motion}/${compact}, reçu ${hit?.tagName}.${hit?.className})`);
      }
      const background = getComputedStyle(pop).backgroundColor;
      const alpha = background.startsWith('rgb(') ? 1 : Number(/^rgba\(.*,\s*([\d.]+)\)$/.exec(background)?.[1] ?? 0);
      eq(alpha, 1, 'fond opaque : le texte des panneaux ne traverse pas l’historique');
      const option = pop.querySelector('[data-n="1"]'), r = option.getBoundingClientRect();
      const hit = document.elementFromPoint(r.left + 20, r.top + r.height / 2);
      ok(option.contains(hit), 'le choix visible reçoit le clic');
      hit.dispatchEvent(new MouseEvent('click', { bubbles: true }));
      eq(f.input.value, 'Recherche 2', 'choix recopié dans le champ');
      eq(f.input.getAttribute('aria-expanded'), 'false', 'historique refermé après le choix');
      eq(getComputedStyle(field).zIndex, 'auto', 'priorité retirée après fermeture');
      eq(f.submitted, [], 'choisir l’historique ne lance pas de recherche implicite');
      f.bar.setText(''); f.open();
      f.input.dispatchEvent(new KeyboardEvent('keydown', { key: 'ArrowDown', bubbles: true }));
      eq(f.input.getAttribute('aria-activedescendant'), 'rch-sg-0', 'navigation clavier conservée');
      f.input.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true }));
      eq(f.input.getAttribute('aria-expanded'), 'false', 'Échap referme l’historique');
      eq(f.input.getAttribute('aria-activedescendant'), null, 'aucun choix masqué encore actif');
    }
  } finally {
    f.close();
    for (const [key, value] of Object.entries(original)) {
      if (value === undefined) delete document.documentElement.dataset[key]; else document.documentElement.dataset[key] = value;
    }
  }
});

test('Rechercher : une suggestion locale en retard ne rouvre pas l’historique fermé par Échap', async () => {
  let started, finish;
  const requested = new Promise(resolve => { started = resolve; });
  const f = await fixture(() => { started(); return new Promise(resolve => { finish = resolve; }); });
  try {
    f.bar.setText('Re'); f.input.focus(); f.input.click();
    f.input.dispatchEvent(new KeyboardEvent('keydown', { key: 'ArrowDown', bubbles: true }));
    await requested;
    eq(f.input.getAttribute('aria-expanded'), 'true', 'historique visible pendant la lecture locale');
    f.input.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true }));
    finish([{ text: 'Retour tardif', label: 'Retour tardif', detail: 'Base locale', kind: 'computer', dn: 'CN=Retour,DC=example,DC=local' }]);
    await new Promise(resolve => setTimeout(resolve, 0));
    eq(f.input.getAttribute('aria-expanded'), 'false', 'réponse périmée abandonnée après fermeture explicite');
    eq(f.submitted, [], 'aucune recherche envoyée');
  } finally { finish?.([]); f.close(); }
});
