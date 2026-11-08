import { test, eq, ok } from './harness.mjs';
import { createTasks } from '../../web/js/pages/operations/tasks.js';
import { setLayoutStore } from '../../web/js/kit/util.js';

test('Opérations : le vrai tiroir distingue 200 ms en admission et 20 ms dans le moteur', async () => {
  const host = document.createElement('main'); document.body.append(host);
  setLayoutStore({ read() {}, write() {} });
  const tasks = createTasks(host, { ctx: { pulse: { every() { return () => {}; } }, call() { throw new Error('Aucun appel requis'); } }, demo: true });
  const row = { id: 'phase-test', reference: 'abcd', operation: 'search.run', screen: 'rechercher', label: 'Lire la liste',
    kind: 'networkRead', kindLabel: 'Lecture réseau', foreground: true, listed: true, state: 'completed', stateLabel: 'Terminée',
    tone: 'ok', icon: 'check', outcome: 'succeeded', outcomeLabel: 'Terminée', startedAt: '2026-11-01T01:00:00Z', endedAt: '2026-11-01T01:00:00Z',
    durationMs: 20, durationText: '20 ms', detail: 'Traitement terminé', volume: 3, volumeText: '3 éléments', canStop: false,
    dominantLabel: 'Admission dans le moteur', dominantMs: 200, access: 'Lecture', text: 'Trace', phases: [
      { phase: 'request', label: 'Demande', atMs: 0, durationMs: null, durationText: 'non mesurée', measured: false },
      { phase: 'admission', label: 'Admission dans le moteur', atMs: 0, durationMs: 200, durationText: '200 ms', measured: true },
      { phase: 'work', label: 'Traitement dans le moteur', atMs: 0, durationMs: 20, durationText: '20 ms', measured: true },
      { phase: 'end', label: 'Fin', atMs: 20, durationMs: null, durationText: '—', measured: false },
    ] };
  const snapshot = task => ({ summary: { text: 'Aucune opération en cours', resourcesText: '' }, open: [], recent: [task] });
  let drawer;
  try {
    tasks.update(snapshot(row)); drawer = tasks.openTrace(row.id);
    const bar = phase => drawer.body.querySelector(`[data-phase="${phase}"] .op-wf-bar`);
    eq(bar('admission').dataset.x, '0.0000', 'attente à l’origine');
    eq(bar('admission').dataset.w, '0.9091', '200 sur 220, pas une barre totale tronquée');
    eq(bar('work').dataset.x, '0.9091', 'traitement après l’attente');
    eq(bar('work').dataset.w, '0.0909', '20 sur 220');
    eq(drawer.body.querySelector('.op-trace-totals > div b').textContent, '20 ms', 'total moteur séparé');
    ok(drawer.body.querySelector('.op-wf-note').textContent.includes('reste celui du moteur'), 'axe expliqué');
    const sameBody = drawer.body;
    tasks.update(snapshot({ ...row, phases: row.phases.map(p => p.phase === 'admission' ? { ...p, durationMs: 40, durationText: '40 ms' } : p) }));
    ok(drawer.body === sameBody, 'panneau existant mis à jour');
    eq(bar('admission').dataset.w, '0.6667', 'nouvelle mesure redessine l’échelle');
    eq(bar('work').dataset.x, '0.6667', 'décalage recalculé');
    eq(drawer.body.querySelector('.op-trace-totals > div b').textContent, '20 ms', 'total inchangé après mise à jour');
  } finally {
    if (drawer) { drawer.close(); await drawer.closed; }
    tasks.destroy(); setLayoutStore(null); host.remove();
  }
});
