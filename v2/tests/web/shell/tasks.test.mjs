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

test('priorité du bandeau : écriture, geste explicite, sélection ; aucun arrêt d’une autre tâche', () => {
  let stops = 0;
  const background = beginTask({ label: 'Fond', priority: 'background', cancel: () => { stops += 100; } });
  const selection = beginTask({ label: 'Sélection', priority: 'selection', cancel: () => { stops += 10; } });
  const explicit = beginTask({ label: 'Geste', cancel: () => { stops += 1; } });
  const write = beginTask({ label: 'Écriture', priority: 'write', cancel: () => { stops += 1000; } });
  try {
    eq(runningTasks().map((t) => t.label), ['Écriture', 'Geste', 'Sélection', 'Fond'], 'priorité serveur');
    eq(stopFirstTask(), false, 'une écriture en tête interdit d’arrêter la lecture derrière');
    eq(stops, 0, 'aucun autre geste déclenché');
    write.end(); ok(stopFirstTask(), 'arrêt de la tâche explicite visible'); eq(stops, 1, 'un seul destinataire');
    eq(stopFirstTask(), false, 'la sélection attend la fin de la tâche explicite');
    explicit.end(); ok(stopFirstTask(), 'la sélection devient visible'); selection.end();
    eq(stopFirstTask(), false, 'le fond seul ne prend pas le bouton');
  } finally { [write, explicit, selection, background].forEach((t) => t.end()); }
});


test('Bandeau : le dernier geste visible reçoit l’arrêt, le précédent reste intact', () => {
  const stopped = [];
  const old = beginTask({ label: 'Ancienne', cancel: () => stopped.push('old') });
  const recent = beginTask({ label: 'Récente', cancel: () => stopped.push('recent') });
  try {
    eq(runningTasks()[0].label, 'Récente', 'plus récente dans la même priorité');
    ok(stopFirstTask(), 'arrêt demandé'); eq(stopped, ['recent'], 'un seul destinataire visible');
    eq(stopFirstTask(), false, 'pas de passage implicite à la précédente');
  } finally { recent.end(); old.end(); }
});
