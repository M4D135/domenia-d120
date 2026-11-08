// The real Journaux page owns its shared-pulse subscription. No tests are run during development.
import { test, eq, ok } from './harness.mjs';
import { createPulse } from '../../web/js/shell/pulse.js';
import { mount } from '../../web/js/pages/parametres/journaux.js';

const LOG = { file: { label: 'Fixture locale', exists: true, bytes: 0, records: 0, errors: 0, warnings: 0, sessionErrors: 0 }, lines: [], session: [], rules: [] };
const settle = async () => { for (let i = 0; i < 12; i++) await Promise.resolve(); };
async function until(condition) {
  for (let i = 0; i < 200 && !condition(); i++) await new Promise((resolve) => setTimeout(resolve, 5));
  ok(condition(), 'page locale prête dans le délai du test');
}
function setup(call) {
  let now = 0, id = 0;
  const timers = new Map();
  const pulse = createPulse({ now: () => now, setTimer: (run, delay) => { timers.set(++id, { run, at: now + delay }); return id; }, clearTimer: (key) => timers.delete(key) });
  const host = document.createElement('div');
  document.body.append(host);
  const page = mount(host, { ctx: { pulse }, call, expert: () => false, prefs: { on: () => () => {} }, badge: () => {}, toast: () => {} });
  return { host, pulse, page, async advance(ms) {
    now += ms;
    for (let i = 0; i < 25; i++) {
      const due = [...timers].find(([, timer]) => timer.at <= now);
      if (due) { timers.delete(due[0]); due[1].run(); }
      await settle();
    }
  }, destroy() { page.destroy(); pulse.dispose(); host.remove(); } };
}

test('Journaux : repos, écriture et visibilité suspendent le suivi ; aucune lecture lente superposée', async () => {
  let reads = 0, release;
  const x = setup(async () => { reads++; return reads === 2 ? new Promise((resolve) => { release = resolve; }) : LOG; });
  try {
    await until(() => x.pulse.count === 1);
    eq(reads, 1, 'lecture initiale explicite de la page');
    await x.advance(20_000);
    eq(reads, 1, 'suivi au repos sans activité');
    x.pulse.setState({ active: true });
    await x.advance(3999);
    eq(reads, 1, 'activation ne lit pas immédiatement');
    await x.advance(1);
    eq(reads, 2, 'un suivi actif');
    await x.advance(20_000);
    eq(reads, 2, 'requête lente jamais doublée');
    release(LOG);
    await settle();
    x.pulse.setState({ writing: true });
    await x.advance(20_000);
    eq(reads, 2, 'aucun suivi pendant une écriture');
    x.pulse.setState({ writing: false, visible: false });
    await x.advance(20_000);
    eq(reads, 2, 'aucun suivi masqué');
    x.pulse.setState({ visible: true });
    await x.advance(4000);
    eq(reads, 3, 'une reprise espacée, sans rafale de rattrapage');
    x.page.destroy();
    eq(x.pulse.count, 0, 'démontage libère l’abonnement');
  } finally { x.destroy(); }
});

test('Journaux : réponse initiale après démontage ne crée aucun abonnement orphelin', async () => {
  let release;
  const x = setup(() => new Promise((resolve) => { release = resolve; }));
  x.page.destroy();
  release(LOG);
  await settle();
  await new Promise((resolve) => setTimeout(resolve, 25));
  eq(x.pulse.count, 0, 'schedule tardif constate le démontage');
  x.destroy();
});

test('Journaux : trois échecs arrêtent le suivi et revenir à la fenêtre ne le relance pas', async () => {
  let reads = 0;
  const x = setup(async () => { if (++reads > 1) throw new Error('Fixture de lecture indisponible'); return LOG; });
  try {
    await until(() => x.pulse.count === 1);
    x.pulse.setState({ active: true });
    await x.advance(4000); await x.advance(4000); await x.advance(4000);
    eq(reads, 4, 'lecture initiale puis trois échecs bornés');
    eq(x.pulse.count, 0, 'abonnement en échec arrêté');
    x.pulse.setState({ visible: false }); x.pulse.setState({ visible: true });
    await x.advance(40_000);
    eq(reads, 4, 'aucune relance automatique du suivi arrêté');
    ok(x.host.textContent.includes('Journal vide'), 'dernier affichage local conservé');
  } finally { x.destroy(); }
});
