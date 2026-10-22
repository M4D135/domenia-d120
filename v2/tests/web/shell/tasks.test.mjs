// Tasks of the strip of the top bar (web/js/shell/tasks.js; TRV-049, TRV-053).
import { test, eq, ok } from '../harness.mjs';
import { beginTask, runningTasks, stopFirstTask, elapsedText, progressShare } from '../../../web/js/shell/tasks.js';

test('temps écoulé et progression bornée', () => {
  eq(elapsedText(7_000), '0:07', 'secondes');
  eq(elapsedText(3_723_000), '1:02:03', 'heures');
  eq(progressShare(1.7), 1, 'bornée à 1');
  eq(progressShare(null), null, 'inconnue');
});

test('un arrêt demandé n’est pas une annulation confirmée', () => {
  let asked = 0;
  const t = beginTask({ label: 'Lecture', cancel: () => { asked += 1; } });
  t.progress(0.5, 'moitié');
  ok(stopFirstTask(), 'arrêt demandé');
  eq(asked, 1, 'l’écran est prévenu');
  eq(runningTasks()[0].stopping, true, 'la tâche dit « Arrêt demandé »');
  eq(runningTasks().length, 1, 'elle reste tant que l’écran ne l’a pas terminée');
  eq(stopFirstTask(), false, 'pas de seconde demande');
  t.end();
  eq(runningTasks().length, 0, 'terminée par son écran');
});
