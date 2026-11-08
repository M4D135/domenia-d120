import { test, eq, ok } from '../harness.mjs';
import { watchActivity } from '../../../web/js/pages/operations/activity-watch.js';
import { createBridgeClient } from '../../../web/js/bridge.js';

function fixture() {
  const sent = [];
  let receive;
  const client = createBridgeClient({ postMessage: (message) => sent.push(message), addEventListener: (_, handler) => { receive = handler; } }, { reportPublication: false });
  return { ...client, sent, deliver: (message) => receive({ data: message }),
    answer: (index, data = true) => receive({ data: { id: sent[index].id, op: sent[index].op, kind: 'result', data } }) };
}

async function code(promise) {
  try { await promise; return 'unexpected-success'; } catch (error) { return error.code; }
}

test('file : événement retardé après admission ne rétablit pas une attente', async () => {
  const f = fixture(); let changed = 0;
  f.onEvent('bridge.queue.changed', () => { changed += 1; });
  const result = f.call('search.run', { text: 'test' });
  const event = (stage) => f.deliver({ id: f.sent[0].id, op: `search.run:${stage}`, kind: 'event', data: { state: stage } });
  event('queued'); eq(changed, 1, 'file visible');
  event('admitted'); eq(changed, 2, 'départ visible');
  event('queued'); eq(changed, 2, 'notification arrivée tard ignorée pour la file');
  f.answer(0, { rows: [] }); await result;
  event('queued'); eq(changed, 2, 'demande terminée non réintroduite');
});

test('file : un refus de retrait après admission ne termine pas la lecture originale', async () => {
  const f = fixture(); let completed = false;
  const reading = f.call('search.run').then((value) => { completed = true; return value; });
  f.deliver({ id: f.sent[0].id, op: 'search.run:admitted', kind: 'event', data: { state: 'admitted' } });
  const cancellation = f.call('operations.queue.cancel', { requestId: f.sent[0].id });
  f.answer(1, { removed: false, state: 'notQueued', message: 'Aucun arrêt confirmé.' });
  eq((await cancellation).removed, false, 'réponse exacte conservée');
  eq(completed, false, 'aucune annulation inventée du handler actif');
  f.answer(0, { actual: 'finished' }); eq(await reading, { actual: 'finished' }, 'seul le résultat réel termine la lecture');
  eq(f.sent.length, 2, 'aucun rejeu automatique');
});

test('file : 128 attentes client bornées et quatre contrôles supplémentaires', async () => {
  const f = fixture();
  const ordinary = Array.from({ length: 128 }, () => f.call('search.run'));
  eq(await code(f.call('search.run')), 'operation.busy', '129e ordinaire refusée localement');
  const controls = Array.from({ length: 4 }, () => f.call('operations.queue.cancel', { requestId: 'queued' }));
  eq(await code(f.call('operations.queue.cancel', { requestId: 'queued' })), 'operation.busy', 'réserve également bornée');
  eq(f.sent.length, 132, 'aucun envoi au-delà du plafond');
  for (let i = 0; i < 132; i += 1) f.answer(i);
  await Promise.all([...ordinary, ...controls]);
  const next = f.call('search.run'); eq(f.sent.length, 133, 'place récupérée après réponses'); f.answer(132); await next;
});

test('file : réponse sans id termine les demandes sans les rejouer', async () => {
  const f = fixture(); let changed = 0;
  f.onEvent('bridge.queue.changed', () => { changed += 1; });
  const first = code(f.call('search.run')); const second = code(f.call('search.browse'));
  f.deliver({ id: f.sent[0].id, op: 'search.run:queued', kind: 'event', data: {} });
  f.deliver({ id: null, op: 'bridge', kind: 'error', error: { code: 'message.size', message: 'Refus.' } });
  eq(await first, 'message.size', 'première attente libérée'); eq(await second, 'message.size', 'seconde attente libérée');
  eq(changed, 2, 'vue de file invalidée'); eq(f.sent.length, 2, 'pas de nouvel envoi');
});

test('file : noms et messages hors contrat sont refusés avant publication', async () => {
  const f = fixture();
  eq(await code(f.call('invalid')), 'operation.unknown', 'nom fermé');
  eq(await code(f.call('search.run', { text: 'x'.repeat(1_048_576) })), 'message.size', 'charge utile bornée');
  const cycle = {}; cycle.self = cycle;
  eq(await code(f.call('search.run', cycle)), 'message.json', 'structure non sérialisable');
  eq(f.sent.length, 0, 'rien envoyé');
  const valid = f.call('search.run'); f.answer(0); ok(await valid, 'précondition positive après refus');
});

test('suivi réel : une notification serveur ouvre le bandeau, son résultat seul le termine', async () => {
  const { followBridgeTasks, runningTasks, stopFirstTask } = await import('../../../web/js/shell/tasks.js');
  const f = fixture(); const dispose = followBridgeTasks(f.onEvent, f.call);
  const read = f.call('search.run');
  const taskId = 'a'.repeat(32);
  const event = () => f.deliver({ id: f.sent[0].id, op: 'search.run:tracking', kind: 'event',
    data: { taskId, label: 'Recherche', priority: 'explicit', cancellable: true } });
  try {
    event(); event(); eq(runningTasks().length, 1, 'pas de tâche doublée');
    ok(stopFirstTask(), 'annulation disponible sur la tâche admise');
    eq(f.sent[1].op, 'operations.task.stop', 'vrai contrôle du moteur');
    eq(f.sent[1].args, { id: taskId }, 'identifiant réel, pas une autre lecture');
    f.answer(1, { state: 'stopping' });
    eq(runningTasks().length, 1, 'acquittement de demande d’arrêt ne termine pas le travail');
    f.answer(0, []); await read; eq(runningTasks().length, 0, 'réponse réelle ferme le bandeau');
    event(); eq(runningTasks().length, 0, 'notification tardive non réintroduite');
  } finally { dispose(); }
});

test('suivi partagé : le bandeau reste tant que l’abonné tardif attend le même travail', async () => {
  const { followBridgeTasks, runningTasks } = await import('../../../web/js/shell/tasks.js');
  const f = fixture(); const dispose = followBridgeTasks(f.onEvent, f.call);
  const first = code(f.call('directory.ou.children'));
  const notice = { taskId: 'b'.repeat(32), label: 'Lecture partagée', priority: 'explicit', cancellable: true };
  const event = (index) => f.deliver({ id: f.sent[index].id, op: 'directory.ou.children:tracking', kind: 'event', data: notice });
  try {
    event(0);
    const second = f.call('directory.ou.children'); event(1);
    eq(runningTasks().length, 1, 'un seul travail malgré deux demandes');
    f.deliver({ id: f.sent[0].id, op: 'directory.ou.children', kind: 'error', error: { code: 'operation.cancelled', message: 'Arrêt de l’attente' } });
    eq(await first, 'operation.cancelled', 'première attente terminée');
    eq(runningTasks().length, 1, 'abonné tardif garde son suivi');
    f.answer(1, []); await second; eq(runningTasks().length, 0, 'la vraie réponse du dernier abonné termine le bandeau');
  } finally { dispose(); }
});


test('Activité : le vrai cycle du pont ne relance pas sa propre lecture au repos', async () => {
  const f = fixture(); const watch = watchActivity(f.onEvent);
  async function complete(operation) {
    const answer = f.call(operation), index = f.sent.length - 1, id = f.sent[index].id;
    f.deliver({ id, op: operation + ':admitted', kind: 'event', data: {} });
    f.deliver({ id, op: operation + ':tracking', kind: 'event', data: { taskId: 'a'.repeat(32), label: 'Fixture', priority: 'explicit', cancellable: true } });
    f.answer(index); await answer;
  }
  try {
    await complete('operations.activity'); await complete('shell.activity');
    eq(watch.needed(), false, 'admission, suivi et fin des compteurs restent neutres');
    await complete('search.run'); ok(watch.needed(), 'un autre travail terminé requiert le dernier rafraîchissement');
    watch.acknowledge(); await complete('operations.activity'); eq(watch.needed(), false, 'repos après la dernière réponse');
    ok(watch.needed(true), 'travail natif en nettoyage maintient son suivi');
  } finally { watch.dispose(); }
});
