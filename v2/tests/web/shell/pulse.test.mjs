import { test, eq, ok } from '../harness.mjs';
import { createPulse } from '../../../web/js/shell/pulse.js';

function setup() {
  let now = 0, id = 0;
  const timers = new Map();
  const pulse = createPulse({ now: () => now, setTimer: (run, delay) => { timers.set(++id, { run, at: now + delay }); return id; }, clearTimer: (key) => timers.delete(key) });
  async function advance(ms) {
    now += ms;
    for (let pass = 0; pass < 30; pass++) {
      const due = [...timers].find(([, timer]) => timer.at <= now);
      if (due) { timers.delete(due[0]); due[1].run(); }
      await Promise.resolve();
    }
  }
  return { pulse, advance, timers };
}

test('Battement : un seul réveil et aucune réentrance d’un abonné lent', async () => {
  const x = setup(); let first = 0, second = 0, release;
  x.pulse.every('slow', 100, () => { first++; return new Promise((resolve) => { release = resolve; }); });
  x.pulse.every('fast', 200, () => { second++; });
  eq(x.timers.size, 1, 'un seul timer physique');
  await x.advance(100); await x.advance(500);
  eq(first, 1, 'le travail lent ne se superpose pas'); eq(second, 1, 'les autres abonnés continuent');
  release(); await x.advance(0); await x.advance(100);
  eq(first, 2, 'nouveau passage seulement après la fin et l’intervalle');
  x.pulse.dispose(); eq(x.timers.size, 0, 'aucun timer sans abonné');
});

test('Battement : arrêt définitif après trois fautes et aucune relance au retour visible', async () => {
  const x = setup(); let failures = 0, calls = 0;
  x.pulse.every('fault', 100, async () => { calls++; throw new Error('fixture'); }, { onError: (_, count) => { failures = count; } });
  await x.advance(100); await x.advance(100); await x.advance(100);
  eq(failures, 3, 'trois diagnostics distincts'); eq(x.pulse.count, 0, 'abonné arrêté');
  x.pulse.setState({ visible: false }); x.pulse.setState({ visible: true }); await x.advance(1000);
  eq(calls, 3, 'pas de reprise automatique');
});

test('Repos : masqué dort ; visible reprend le rendu mais activation et fin d’écriture attendent pour le réseau', async () => {
  const x = setup(); let render = 0, network = 0;
  x.pulse.every('display', 100, () => { render++; });
  x.pulse.every('network', 100, () => { network++; }, { background: true });
  x.pulse.setState({ visible: false, active: false });
  eq(x.timers.size, 0, 'pas de réveil masqué'); await x.advance(1000);
  x.pulse.setState({ visible: true }); await x.advance(0);
  eq(render, 1, 'rattrapage unique du rendu'); eq(network, 0, 'fenêtre inactive sans lecture de fond');
  x.pulse.setState({ active: true }); await x.advance(0); eq(network, 0, 'activation sans lecture');
  await x.advance(100); eq(network, 1, 'intervalle écoulé après activation');
  x.pulse.setState({ writing: true }); await x.advance(200); eq(network, 1, 'écriture suspend le fond');
  x.pulse.setState({ writing: false }); await x.advance(0); eq(network, 1, 'fin d’écriture sans lecture immédiate');
  await x.advance(100); eq(network, 2, 'abonnement explicite conservé');
  x.pulse.dispose();
});

test('Battement : libérer un propriétaire ne supprime pas les abonnés des autres vues', async () => {
  const x = setup(); let removed = 0, kept = 0;
  x.pulse.every('route', 100, () => { removed++; });
  const stop = x.pulse.every('shell', 100, () => { kept++; });
  x.pulse.forget('route'); await x.advance(100);
  eq(removed, 0, 'ancienne page libérée'); eq(kept, 1, 'coque conservée');
  stop(); stop(); ok(x.timers.size === 0 && x.pulse.count === 0, 'libération idempotente');
});
