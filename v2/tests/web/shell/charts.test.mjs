// Charts of the boards (web/js/shell/charts.js; TRV-297 to TRV-300, TRV-284).
import { test, eq, ok } from '../harness.mjs';
import { chartTicks, groupOthers, selectedIndex, sizeText, ageText, donutVisual, barsVisual, emptyVisual, healthVisual, scoreVisual } from '../../../web/js/shell/charts.js';

test('graduations arrondies', () => {
  eq(chartTicks(87).ticks, [0, 50, 100], 'pas de 1, 2 ou 5 × 10^n au-dessus du quart du maximum');
  eq(chartTicks(12).ticks, [0, 5, 10, 15], 'pas de 5 pour 12');
  eq(chartTicks(0.3, { integer: true }).step, 1, 'pas entier pour un comptage');
});

test('« Autres » garde ses membres et leurs critères', () => {
  const items = Array.from({ length: 11 }, (_, i) => ({ label: `C${i}`, value: 11 - i, criterion: `c${i}` }));
  const parts = groupOthers(items, 8);
  eq(parts.length, 8, 'huit parts');
  eq(parts[7].members, ['C7', 'C8', 'C9', 'C10'], 'membres gardés');
  eq(parts[7].criteria, ['c7', 'c8', 'c9', 'c10'], 'critères gardés');
  eq(selectedIndex(parts, 'C9'), 7, 'sélection d’une catégorie regroupée : « Autres »');
  eq(selectedIndex(parts, 'C2'), 2, 'sélection directe');
  eq(selectedIndex(parts, 'inconnue'), -1, 'aucune');
});

test('une part n’est cliquable que si elle porte un critère', () => {
  const html = donutVisual({ items: [{ label: 'A', value: 2, criterion: 'a' }, { label: 'B', value: 1 }] }, { selectable: true, selected: 'A' });
  ok(html.includes('data-seg="0"'), 'part avec critère cliquable');
  ok(!html.includes('data-seg="1"'), 'part sans critère : ligne simple');
  ok(html.includes('class="seg-edge s1"'), 'bord plus foncé sous la part');
  ok(html.includes('has-selection'), 'sélection gardée');
  ok(!donutVisual({ items: [{ label: 'A', value: 2, criterion: 'a' }] }).includes('data-seg'), 'sans écoute du tableau : rien de cliquable');
  ok(barsVisual({ items: [{ label: 'A', value: 2, criterion: 'a' }] }, { selectable: true }).includes('button type="button" class="sh-hbar-row"'), 'barre cliquable');
});

test('états vides : illustration, phrase et action proposée', () => {
  const html = emptyVisual('Aucun message.', { icon: 'bell', action: { id: 'try', label: 'Essayer' } });
  ok(html.includes('sh-empty-art') && html.includes('data-w-action="try"'), 'action proposée');
  ok(donutVisual({ items: [], empty: 'Rien', emptyAction: { id: 'x', label: 'Y' } }).includes('data-w-action="x"'), 'anneau vide : action');
});

test('cartes score et santé', () => {
  const score = scoreVisual({ number: 82, state: 'warn', verdict: 'Quelques points', action: { id: 'go', label: 'Voir' } });
  ok(score.includes('aria-valuenow="82"') && score.includes('data-w-action="go"'), 'score et action');
  const health = healthVisual({ number: 100, state: 'ok', items: [], reliable: true, clearText: 'Rien à vérifier.' });
  ok(health.includes('Rien à vérifier.'), 'aucune alerte : une ligne verte');
  const unreliable = healthVisual({ number: 50, items: [], reliable: false });
  ok(!unreliable.includes('sh-health-clear'), 'score non établi : pas de ligne verte');
  const order = healthVisual({ number: 40, items: [{ level: 'info', text: 'i' }, { level: 'alert', text: 'a' }] });
  ok(order.indexOf('>a<') < order.indexOf('>i<'), 'le plus grave d’abord');
});

test('tailles et âges en français', () => {
  eq(sizeText(1536 * 1024 * 1024), '1,5 Go', 'gigaoctets');
  eq(ageText(new Date(Date.now() + 2 * 60_000).toISOString()), 'à l’instant', 'petite avance d’horloge');
  eq(ageText(new Date(Date.now() + 10 * 60_000).toISOString()), 'non daté', 'date future');
});
