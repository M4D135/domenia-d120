import { test, eq, ok } from './harness.mjs';
import { nativeDirectoryReach, mayObserveDirectory, followDirectoryAvailability } from '../../web/js/shell/directory-availability.js';
const at = '2026-11-01T12:00:00Z';
const session = (state, revision = 0) => ({ connection: { state: 'connected' }, directoryAvailability: { state, observedAt: at,
  revision, lastDisruptionAt: revision ? at : null, notice: 'Constat annuaire natif.' } });
const settle = async () => { for (let i = 0; i < 12; i++) await Promise.resolve(); };

test('Disponibilité : seuls les constats LDAP qualifient le badge, sans confondre identité et présence du service', () => {
  const failed = session('offline', 1); const reach = nativeDirectoryReach(failed);
  ok(reach.offline && !reach.slow && reach.observed, 'panne constatée, session pourtant authentifiée');
  eq(reach.since, Date.parse(at), 'date du constat natif, pas de date de rendu inventée');
  eq(nativeDirectoryReach(failed), reach, 'une consultation du même cache ne rétablit rien');
  ok(nativeDirectoryReach(session('slow', 2)).slow, 'délai LDAP distinct de panne');
  ok(!nativeDirectoryReach(session('online', 2)).offline, 'réponse LDAP réelle rétablit le badge');
  for (const value of [{}, { connection: { state: 'connected' } }, { error: { code: 'operation.timeout' } },
    { directoryAvailability: { state: 'offline', observedAt: 'invalid' } }]) {
    const unknown = nativeDirectoryReach(value);
    ok(!unknown.offline && !unknown.slow && !unknown.observed, 'ni connexion ni erreur d’un autre fournisseur ne deviennent une preuve');
  }
});

test('Disponibilité : relire seulement session.info locale, regrouper les fins et ne jamais boucler après erreur', async () => {
  let release; let reads = 0, faults = 0;
  const first = new Promise(resolve => { release = resolve; });
  const follow = followDirectoryAvailability(async () => { reads++; if (reads === 1) await first; else throw new Error('session locale illisible'); }, () => faults++);
  follow.completed('search.run'); follow.completed('poste.quick'); await settle();
  eq(reads, 1, 'deux fins simultanées regroupées');
  follow.completed('fiche.read'); await settle(); eq(reads, 1, 'aucun chevauchement');
  release(); await settle(); eq(reads, 2, 'un constat arrivé pendant la lecture requiert une seule lecture suivante');
  eq(faults, 1, 'erreur locale observée'); await settle(); eq(reads, 2, 'aucune relance sans nouvelle opération');
  for (const operation of ['session.info', 'session.setScope', 'shell.activity', 'operations.activity', 'settings.read']) {
    ok(!mayObserveDirectory(operation), 'inspection locale sans boucle : ' + operation); follow.completed(operation);
  }
  await settle(); eq(reads, 2, 'aucun minuteur ni lecture indirecte après les inspections');
  ok(mayObserveDirectory('synchro.read') && mayObserveDirectory('write.execute'), 'les familles réellement susceptibles de lire AD sont suivies');
});
