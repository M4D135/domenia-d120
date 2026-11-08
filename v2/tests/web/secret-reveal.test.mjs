import { test, eq, ok } from './harness.mjs';
import { bindReveal } from '../../web/js/pages/comptes/shared.js';

function fixture(seconds) {
  const root = document.createElement('section'); root.dataset.page = 'comptes';
  root.innerHTML = '<div class="cpt-pwd-input"><input class="input" type="password"><button type="button" data-reveal aria-pressed="false">Afficher</button></div>';
  document.body.append(root);
  const input = root.querySelector('input'), button = root.querySelector('button'); input.value = 'Fictif-unique-2026!';
  const control = bindReveal(root, { seconds });
  return { root, input, button, control, layer: () => root.querySelector('.cpt-secret-peek'), close() { control.destroy(); root.remove(); } };
}

test('Révélation : vrai champ toujours masqué, calque sans édition ni sélection, effacement sur chaque sortie', async () => {
  const link = document.createElement('link'); link.rel = 'stylesheet'; link.href = '../../web/css/pages/comptes.css';
  await new Promise((resolve, reject) => { link.onload = resolve; link.onerror = reject; document.head.append(link); });
  const x = fixture(8);
  try {
    x.button.click();
    eq(x.input.type, 'password', 'jamais input text'); eq(x.layer().textContent, x.input.value, 'aperçu demandé');
    eq(x.layer().isContentEditable, false, 'calque non éditable'); eq(getComputedStyle(x.layer()).userSelect, 'none', 'vraie CSS non sélectionnable');
    const former = x.layer(); x.button.click(); eq(former.textContent, '', 'ancien nœud vidé avant retrait'); ok(!x.layer(), 'second clic masque');
    for (const type of ['keydown', 'beforeinput', 'input', 'paste', 'compositionstart', 'focusout']) {
      x.control.show(x.input); const held = x.layer();
      x.input.dispatchEvent(new Event(type, { bubbles: true }));
      eq(held.textContent, '', `${type} efface aussi le nœud conservé`); ok(!x.layer(), `${type} masque`); eq(x.input.type, 'password', 'saisie reste protégée');
    }
    x.control.show(x.input); const event = new Event('copy', { bubbles: true, cancelable: true }); x.layer().dispatchEvent(event);
    ok(event.defaultPrevented, 'copie refusée'); ok(!x.layer(), 'copie masque');
    x.control.show(x.input); window.dispatchEvent(new Event('blur')); ok(!x.layer(), 'désactivation masque');
    x.control.show(x.input); const held = x.layer(); x.control.destroy();
    eq(held.textContent, '', 'destruction efface le calque'); ok(!x.layer(), 'destruction masque');
    x.control.show(x.input); ok(!x.layer(), 'contrôleur détruit ne révèle plus');
  } finally { x.close(); link.remove(); }
});

test('Révélation : délai borné réel, champ retiré et bouton désactivé', async () => {
  const x = fixture(0);
  try {
    ok(x.button.dataset.tip.includes('1'), 'minimum une seconde');
    x.button.disabled = true; x.button.click(); ok(!x.layer(), 'bouton inactif'); x.button.disabled = false;
    x.button.click(); const held = x.layer();
    await new Promise(resolve => setTimeout(resolve, 1150));
    ok(!x.layer(), 'le vrai timer masque'); eq(held.textContent, '', 'aucun clair retenu après délai');
    x.control.show(x.input); const removed = x.layer(); x.input.remove();
    await Promise.resolve(); await Promise.resolve();
    eq(removed.textContent, '', 'retrait du champ vide immédiatement le calque'); ok(!x.layer(), 'calque orphelin supprimé');
  } finally { x.close(); }
  const high = fixture(1000), invalid = fixture('long');
  try { ok(high.button.dataset.tip.includes('30'), 'maximum trente secondes'); ok(invalid.button.dataset.tip.includes('5'), 'défaut cinq secondes'); }
  finally { high.close(); invalid.close(); }
});
