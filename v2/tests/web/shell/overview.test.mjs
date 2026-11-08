// Health of the interface (web/js/pages/shell/overview.js; TRV-298 health card).
import { test, eq, ok } from '../harness.mjs';
import { interfaceHealth, CATALOG } from '../../../web/js/pages/shell/overview.js';

test('score sur 100 et points du plus grave au moins grave', () => {
  eq(interfaceHealth({}).score, 100, 'tout en ordre');
  eq(interfaceHealth({}).points, [], 'aucun point');
  const h = interfaceHealth({ contrastFailures: 3, faults: 1, requests: 1, persistent: false, unreadAlerts: 1 });
  eq(h.score, 100 - 12 - 10 - 10 - 15 - 5, 'pénalités');
  eq(h.state, 'alert', 'état rouge sous 70');
  ok(h.points.length === 5 && h.points[0].level === 'alert', 'points listés');
  eq(interfaceHealth({ faults: 9 }).score, 70, 'erreurs : 30 points au plus');
});

test('catalogue : la santé propose les cartes santé et score', () => {
  eq(CATALOG.find((c) => c.key === 'interface.health').visuals, ['health', 'score', 'list'], 'représentations');
  ok(CATALOG.every((c) => c.visuals.length && c.group && c.description), 'chaque widget est décrit');
});
