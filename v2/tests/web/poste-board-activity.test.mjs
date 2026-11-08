import { test, eq, ok } from './harness.mjs';
import { createBoardLayout } from '../../web/js/pages/poste/board-layout.js';
import { createPosteReadActivity, boardActivity } from '../../web/js/pages/poste/board-activity.js';
const dn = 'CN=PC1,OU=Postes,DC=test';
const deferred = () => { let resolve, reject; const promise = new Promise((a, b) => { resolve = a; reject = b; }); return { promise, resolve, reject }; };
const row = (id, key, source = 'builtin', paused = false) => ({ id, key, source, paused, visual: 'Kpi', size: 'S', title: null, group: '' });

test('Cartes Poste et Logiciels : suivre les vrais appels du poste, conserver les chiffres et arrêter les abonnements', async () => {
  for (const board of ['Computer', 'Software']) {
    const host = document.createElement('div'); document.body.append(host);
    const items = board === 'Software' ? [row('count', 'software.count')] : [row('ram', 'computer.memory'), row('ad', 'computer.ad.ou'), row('paused', 'computer.memory', 'builtin', true)];
    const view = { board, valid: true, stored: true, items, catalog: items.map(item => ({ key: item.key, title: item.id, source: item.source, visual: item.visual, size: item.size })) };
    const listeners = new Map(); const calls = []; const read = deferred();
    const state = { dn, reading: [], running: [], on(name, fn) {
      if (!listeners.has(name)) listeners.set(name, new Set()); listeners.get(name).add(fn);
      return () => listeners.get(name).delete(fn);
    } };
    const tracking = createPosteReadActivity(async (operation, args) => {
      calls.push({ operation, args }); return operation === 'poste.layout.get' ? view : read.promise;
    }, rows => { state.reading = rows; for (const fn of listeners.get('reading') ?? []) fn(); });
    state.call = (...args) => tracking.call(...args);
    const layout = createBoardLayout(host, state, board, () => {});
    try {
      await layout.load(); host.innerHTML = layout.render(() => '<b data-value>42</b>');
      eq(calls.map(call => call.operation), ['poste.layout.get'], 'afficher des cartes ne collecte rien');
      const operation = board === 'Software' ? 'poste.software' : 'poste.inventory';
      const foreign = state.call(operation, { dn: 'CN=PC2,OU=Postes,DC=test' });
      ok([...host.querySelectorAll('[data-board-progress]')].every(line => line.hidden), 'lecture d’un autre poste jamais attribuée à celui-ci');
      const pending = state.call(operation, { dn });
      const shown = [...host.querySelectorAll('[data-board-progress]')].filter(line => !line.hidden);
      eq(shown.length, 1, 'seule carte active de la source concernée');
      ok(shown[0].textContent.includes(board === 'Software' ? 'logiciels' : 'Inventaire WMI'), 'phase explicite');
      eq(host.querySelector('[data-value]').textContent, '42', 'dernière valeur inchangée');
      ok(!shown[0].textContent.includes('0/0'), 'aucun compteur de postes fabriqué pour une source sans total');
      read.resolve({ complete: true }); await Promise.all([foreign, pending]);
      ok([...host.querySelectorAll('[data-board-progress]')].every(line => line.hidden), 'fin réelle des promesses retire le suivi');
      eq(host.querySelector('[data-value]').textContent, '42', 'le suivi ne prétend pas remplacer les mesures');
      layout.destroy();
      eq([...listeners.values()].reduce((sum, set) => sum + set.size, 0), 0, 'pas de listener de carte après démontage');
    } finally { read.resolve({}); tracking.destroy(); layout.destroy(); host.remove(); }
  }
});

test('Carte sonde : seule la sonde explicitement demandée reçoit un suivi, jamais une autre version', async () => {
  const state = { dn, reading: [{ dn, kind: 'probes', probes: ['hw.model'] }], running: [{ dn, kind: 'probes' }] };
  ok(boardActivity(row('model', 'hw.model', 'probe'), 'Computer', state).includes('Sonde WMI'), 'projection demandée exacte');
  eq(boardActivity(row('ram', 'hw.ram', 'probe'), 'Computer', state), '', 'une autre sonde n’est pas annoncée en collecte');
  eq(boardActivity(row('query', 'query-v1', 'query'), 'Computer', state), '', 'évaluation locale de requête distincte');
  const read = deferred(); const snapshots = [];
  const tracking = createPosteReadActivity(() => read.promise, rows => snapshots.push(rows));
  const pending = tracking.call('poste.software', { dn }).catch(error => error.message);
  eq(snapshots.at(-1).length, 1, 'lecture suivie avant réponse');
  read.reject(new Error('lecture refusée'));
  eq(await pending, 'lecture refusée', 'erreur originale conservée');
  eq(snapshots.at(-1).length, 0, 'aucune collecte fantôme après erreur');
  tracking.destroy();
});


test('Suivi Poste : un observateur défaillant ne bloque pas la vraie lecture ni son résultat', async () => {
  let calls = 0;
  const tracking = createPosteReadActivity(async () => { calls++; return 42; }, () => { throw new Error('rendu indisponible'); });
  try { eq(await tracking.call('poste.inventory', { dn }), 42, 'résultat du lecteur conservé'); eq(calls, 1, 'une seule lecture réelle'); }
  finally { tracking.destroy(); }
});
