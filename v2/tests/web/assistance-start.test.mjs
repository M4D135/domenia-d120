// Assistance start (recette 2.0.6, simulation under load): when the first read of the screen fails, the error card is the
// settled content of the view. It must not stay busy, otherwise screen readers keep announcing a reading and the readiness
// signal of the router (data-ready) never comes.
import { test, eq, ok, Failure } from './harness.mjs';
import { render } from '../../web/js/pages/assistance.js';

const pause = (ms) => new Promise((resolve) => { setTimeout(resolve, ms); });

async function until(check, what, ms = 4000) {
  const end = performance.now() + ms;
  for (;;) {
    const value = check();
    if (value) return value;
    if (performance.now() > end) throw new Failure(`${what} : délai dépassé`);
    await pause(20);
  }
}

test('Assistance : un échec de la première lecture laisse une carte d’erreur, plus rien d’occupé', async () => {
  const main = document.createElement('main');
  main.className = 'main';
  main.dataset.page = 'assistance';
  Object.assign(main.style, { position: 'fixed', left: '-10000px', top: '0', width: '1200px', height: '800px', overflow: 'auto' });
  document.body.append(main);
  const calls = [];
  const navigations = [];
  const ctx = {
    params: {},
    app: Promise.resolve({ mode: 'simulation' }),
    call(op) {
      calls.push(op);
      // Same shape as a bridge failure: French message and a code (the detail stays in the technical journal).
      return Promise.reject(Object.assign(new Error('L’opération a échoué. Le détail technique est dans le journal.'), { code: 'operation.failed' }));
    },
    navigate(id, params) { navigations.push([id, params]); },
    pulse: { every: () => () => {} },
    toast() {},
  };
  let dispose = null;
  try {
    dispose = render(main, ctx);
    const card = await until(() => main.querySelector('.as-view .as-error[role="alert"]'), 'carte d’erreur affichée');
    ok(calls.includes('assistance.overview'), `la première lecture est demandée (appels : ${calls.join(', ')})`);
    ok(card.textContent.includes('L’Assistance n’a pas pu démarrer'), 'la carte dit que l’écran n’a pas démarré');
    eq(main.querySelector('.as-view').hasAttribute('aria-busy'), false, 'la vue n’est plus occupée');
    // The retry reopens the screen with its parameters: nothing is read again behind the operator's back.
    card.querySelector('[data-retry]').click();
    eq(navigations, [['assistance', {}]], '« Réessayer » rouvre l’écran');
  } finally {
    if (typeof dispose === 'function') dispose();
    main.remove();
  }
});
