// WCAG contrast measured on the theme shown (web/js/shell/contrast.js; TRV-009).
import { test, eq, ok } from '../harness.mjs';
import { parseColor, contrastRatio, ratioText, composite, CONTRAST_PAIRS, measureContrast } from '../../../web/js/shell/contrast.js';

test('couleurs lues sous toutes leurs formes', () => {
  eq(parseColor('#fff'), { r: 255, g: 255, b: 255, a: 1 }, 'forme courte');
  eq(parseColor('rgb(0 0 0 / 50%)').a, 0.5, 'alpha en pourcentage');
  eq(parseColor('Canvas'), null, 'couleur système : non lue ici');
});

test('rapports tronqués, jamais arrondis vers le haut', () => {
  eq(ratioText(4.499), '4,49', 'tronqué');
  eq(ratioText(contrastRatio(parseColor('#000'), parseColor('#fff'))), '21,00', 'noir sur blanc');
  const over = composite({ r: 0, g: 0, b: 0, a: 0.5 }, { r: 255, g: 255, b: 255, a: 1 });
  ok(Math.abs(over.r - 127.5) < 0.01, 'superposition d’une couleur translucide');
});

test('les 29 paires du thème affiché sont toutes conformes', () => {
  eq(CONTRAST_PAIRS.length, 29, 'paires mesurées');
  const m = measureContrast();
  eq(m.results.filter((r) => !r.passed).map((r) => r.label), [], 'aucune paire sous le seuil');
});
