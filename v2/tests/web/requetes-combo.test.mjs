import { test, eq, ok } from './harness.mjs';
import { createFieldCombo } from '../../web/js/pages/requetes/combo.js';

test('Atelier : le menu Information couvre les conditions et la valeur sans changer les animations', async () => {
  const styles = [];
  const original = { theme: document.documentElement.dataset.theme, motion: document.documentElement.dataset.motion };
  const recentKey = 'domenia.requetes.champsRecents';
  const recent = localStorage.getItem(recentKey);
  let host, combo;
  try {
    for (const file of ['components.css', 'kit.css', 'motion.css', 'pages/requetes.css']) {
      const css = document.createElement('link'); css.rel = 'stylesheet';
      css.href = new URL(`../../web/css/${file}`, import.meta.url).href;
      styles.push(css);
      await new Promise((resolve, reject) => { css.onload = resolve; css.onerror = () => reject(new Error(`CSS absent : ${file}`)); document.head.append(css); });
    }
    for (const theme of ['light', 'dark', 'contrast']) for (const motion of ['full', 'reduced']) {
      document.documentElement.dataset.theme = theme; document.documentElement.dataset.motion = motion;
      localStorage.removeItem(recentKey);
      host = document.createElement('main'); host.className = 'main'; host.dataset.page = 'requetes';
      Object.assign(host.style, { position: 'fixed', left: '0', top: '0', width: 'min(900px, 100vw)', height: '100vh',
        zIndex: '40', padding: '24px', background: 'var(--bg)', overflow: 'auto' });
      host.innerHTML = `<section class="card rq-builder spot"><div class="card-head"><h3>Condition</h3></div>
        <div class="rq-builder-body">
          <div class="rq-step"><span class="rq-step-n">1</span><div class="rq-step-main"><span class="rq-step-label">Information</span><div class="rq-field-host"></div></div></div>
          <div class="rq-step"><span class="rq-step-n">2</span><div class="rq-step-main"><span class="rq-step-label">Condition</span><div class="rq-ops"><button type="button" aria-checked="true">est égal à</button><button type="button">contient</button></div></div></div>
          <div class="rq-step"><span class="rq-step-n">3</span><div class="rq-step-main"><span class="rq-step-label">Valeur</span><div class="rq-value-host"><input class="input" placeholder="Exemple : Windows 11"></div></div></div>
        </div><div class="rq-help"><p>Le critère est évalué sur les données disponibles.</p></div>
        <div class="rq-builder-actions"><button class="btn primary">Ajouter le critère</button></div></section>`;
      document.body.append(host);
      const chosen = [];
      combo = createFieldCombo(host.querySelector('.rq-field-host'), {
        fields: Array.from({ length: 40 }, (_, i) => ({ id: `field-${i}`, name: `Information ${i + 1}`, category: 'Système', source: 'ad', typeLabel: 'Texte' })),
        value: 'field-0', label: 'Information à filtrer', onChange: field => chosen.push(field.id),
      });
      const input = host.querySelector('[role="combobox"]');
      input.focus(); input.dispatchEvent(new KeyboardEvent('keydown', { key: 'ArrowDown', bubbles: true }));
      // Finish, rather than remove, the actual animations: fill-mode both keeps the stacking context that caused the bug.
      host.getAnimations({ subtree: true }).forEach(animation => animation.finish());
      const pop = host.querySelector('.rq-combo-pop');
      const firstStep = host.querySelector('.rq-step');
      eq(getComputedStyle(firstStep).animationName, 'rq-fade-up', 'animation d’entrée conservée');
      const background = getComputedStyle(pop).backgroundColor;
      // Read the alpha channel: opaque black is rgb(0, 0, 0), which a suffix test would mistake for transparency.
      const alpha = background.startsWith('rgb(') ? 1 : Number(/^rgba\(.*,\s*([\d.]+)\)$/.exec(background)?.[1] ?? 0);
      ok(alpha === 1, `fond opaque en ${theme}/${motion} (${background})`);
      for (const behind of [host.querySelector('.rq-ops button'), host.querySelector('.rq-value-host input')]) {
        const r = behind.getBoundingClientRect(); const box = pop.getBoundingClientRect();
        const x = Math.min(r.left + 24, r.right - 4), y = r.top + r.height / 2;
        ok(x > box.left && x < box.right && y > box.top && y < box.bottom, 'le test vise une zone réellement recouverte');
        const hit = document.elementFromPoint(x, y);
        ok(pop.contains(hit), `la liste reçoit le clic devant les champs en ${theme}/${motion} (reçu : ${hit?.tagName || 'aucun'}.${hit?.className || ''})`);
      }
      const option = pop.querySelector('[data-n="1"]');
      const r = option.getBoundingClientRect(); const hit = document.elementFromPoint(r.left + 20, r.top + r.height / 2);
      ok(option.contains(hit), 'le choix visible est effectivement au-dessus du formulaire');
      hit.dispatchEvent(new MouseEvent('click', { bubbles: true }));
      eq(chosen, ['field-1'], 'le clic choisit l’information, sans agir sur la condition derrière');
      eq(input.getAttribute('aria-expanded'), 'false', 'liste refermée après le choix');
      eq(getComputedStyle(firstStep).zIndex, 'auto', 'priorité de la ligne retirée à la fermeture');
      input.dispatchEvent(new KeyboardEvent('keydown', { key: 'ArrowDown', bubbles: true }));
      input.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true }));
      eq(input.getAttribute('aria-expanded'), 'false', 'Échap ferme toujours la liste');
      combo.destroy(); combo = null; host.remove(); host = null;
    }
  } finally {
    combo?.destroy(); host?.remove(); styles.forEach(css => css.remove());
    if (recent === null) localStorage.removeItem(recentKey); else localStorage.setItem(recentKey, recent);
    for (const [key, value] of Object.entries(original)) {
      if (value === undefined) delete document.documentElement.dataset[key]; else document.documentElement.dataset[key] = value;
    }
  }
});
