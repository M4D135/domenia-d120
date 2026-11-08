import { test, eq, ok } from './harness.mjs';
import { createPulse } from '../../web/js/shell/pulse.js';
import { progressiveRows, selectionPaint } from '../../web/js/pages/rechercher/progressive.js';
function setup() {
  let now = 0, id = 0; const timers = new Map();
  const pulse = createPulse({ now: () => now, setTimer: (run, delay) => { timers.set(++id, { run, at: now + delay }); return id; }, clearTimer: (key) => timers.delete(key) });
  return { pulse, now: () => now, async advance(ms) {
    now += ms;
    for (let i = 0; i < 30; i++) {
      const due = [...timers].find(([, t]) => t.at <= now);
      if (due) { timers.delete(due[0]); due[1].run(); }
      await Promise.resolve();
    }
  } };
}
test('Recherche : aperçu local borné, invalidation et nouveau geste après trois erreurs', async () => {
  const x = setup(); const rows = Array.from({ length: 100000 }, (_, id) => ({ id }));
  const accepted = []; const abort = new AbortController();
  const running = progressiveRows(rows, { ...x, signal: abort.signal, append: (batch) => accepted.push(...batch) });
  await x.advance(0); eq(accepted.length, 400, 'premier aperçu borné');
  abort.abort(); eq(await running, false, 'publication abandonnée avant le tri complet');
  await x.advance(5000); eq(accepted.length, 400, 'aucune ancienne ligne ajoutée');
  let errors = 0;
  const failed = progressiveRows(rows, { ...x, append: () => { errors++; throw new Error('fixture'); } }).catch(() => false);
  await x.advance(0); await x.advance(20); await x.advance(20);
  eq(await failed, false, 'trois échecs arrêtent la demande'); eq(errors, 3, 'pas de boucle infinie');
  const result = []; let finished = false;
  const next = progressiveRows(rows, { ...x, append: (batch) => result.push(...batch) }).then(value => { finished = true; return value; });
  await x.advance(0); eq(finished, false, 'un vrai tour pour peindre le premier aperçu');
  await x.advance(20);
  ok(await next, 'publication finale autorisée après un tour, sans 249 copies jetées');
  eq(result.length, 400, 'un seul aperçu, la grille reçoit ensuite la liste entière une fois');
  eq(rows.length, 100000, 'liste entière intacte');
  eq(x.pulse.count, 0, 'aucun réveil de recherche au repos'); x.pulse.dispose();
});
test('Recherche : petites listes sans temporisation artificielle et ancienne génération sans publication', async () => {
  const x = setup(); const rows = Array.from({ length: 400 }, (_, id) => ({ id })); const preview = [];
  const small = progressiveRows(rows, { ...x, append: batch => preview.push(...batch) });
  await x.advance(0); ok(await small, 'petite liste prête en un passage'); eq(preview, rows, 'toutes les lignes sans délai par douzaine');
  const stale = progressiveRows(rows, { ...x, current: () => false, append: () => { throw new Error('ancienne vue'); } });
  await x.advance(0); eq(await stale, false, 'ancienne génération abandonnée avant tout aperçu');
  eq(x.pulse.count, 0, 'aucun abonnement résiduel'); x.pulse.dispose();
});
test('Sélection : dernier aperçu seul toutes les 200 ms, annulation au changement de vue', async () => {
  const x = setup(); const paints = []; const selection = selectionPaint(x.pulse, value => paints.push(value));
  selection.request(1); selection.request(2); await x.advance(199); eq(paints, [], 'pas de rafale');
  await x.advance(1); eq(paints, [2], 'dernière sélection');
  selection.request(3); selection.cancel(); await x.advance(200); eq(paints, [2], 'aucun ancien aperçu');
  eq(x.pulse.count, 0, 'abonnement libéré'); x.pulse.dispose();
});
