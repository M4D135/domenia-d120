import { test, eq, ok } from './harness.mjs';
import { targetSummary, bindTargetPages } from '../../web/js/pages/rechercher/actions.js';

test('Confirmation réseau : aperçu de douze postes et détail complet paginé sans gonfler le DOM', () => {
  const targets = Array.from({ length: 3501 }, (_, n) => ({ name: `PC-${n + 1}`, address: '192.0.2.1' }));
  const excluded = Array.from({ length: 130 }, (_, n) => ({ name: `Exclu-${n}`, reason: 'désactivé' }));
  const root = document.createElement('section'); root.innerHTML = targetSummary(targets, excluded); document.body.append(root);
  try {
    bindTargetPages(root, targets);
    eq(root.querySelector('ul').children.length, 12, 'aperçu limité à douze');
    eq(root.querySelector('.excluded').children.length, 100, 'au plus cent exclusions affichées');
    ok(root.textContent.includes('30 autres'), 'nombre restant annoncé');
    const details = root.querySelector('details'); details.open = true; details.dispatchEvent(new Event('toggle'));
    const list = root.querySelector('[data-target-page]'); eq(list.children.length, 100, 'détail borné par page');
    for (let n = 0; n < 35; n++) root.querySelector('[data-target-next]').click();
    eq(list.children.length, 1, 'dernier poste conservé'); eq(list.firstElementChild.querySelector('span').textContent, 'PC-3501', 'aucune troncature');
    ok(root.querySelector('[data-target-next]').disabled, 'pas de dépassement');
    root.querySelector('[data-target-prev]').click(); eq(list.children.length, 100, 'navigation réversible');
    root.innerHTML = targetSummary([{ name: '<img src=x onerror=alert(1)>', address: '<script>bad</script>' }], []);
    ok(!root.querySelector('img,script'), 'noms et adresses échappés');
    // The native toggle of `details.open = true` arrives after the redraw: it must stay on the old page controls.
    const errors = []; const onError = (e) => { errors.push(e.message); e.preventDefault(); };
    window.addEventListener('error', onError);
    try { details.dispatchEvent(new Event('toggle')); } finally { window.removeEventListener('error', onError); }
    eq(errors, [], 'bascule tardive sans erreur après redessin');
  } finally { root.remove(); }
});
