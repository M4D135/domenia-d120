// Palette rules (web/js/shell/commands.js; TRV-175, TRV-176).
import { test, eq, ok } from '../harness.mjs';
import { searchKey, judge, selectEntries, decide, screenCommand, CATALOGUE } from '../../../web/js/shell/commands.js';

const ctx = { connected: true, selectionType: '', machineRows: 0, readOnly: false, simulation: true, control: () => null, blocked: () => '' };

test('catalogue fermé de 44 commandes', () => { eq(CATALOGUE.length, 44, 'commandes'); });

test('recherche sans accents, casse ni apostrophe', () => {
  eq(searchKey('L’Index local'), 'lindex local', 'repli');
  const found = selectEntries([{ label: 'Détecter l’utilisateur', order: 2 }, { label: 'Ouvrir l’index', order: 1 }], 'detecter');
  eq(found.length, 1, 'un mot suffit');
});

test('jugement selon la connexion, la sélection, la lecture seule et le bouton réel', () => {
  eq(judge({ effect: 'write', requires: 'user' }, ctx).reason, 'Sélectionnez un utilisateur.', 'type d’objet');
  eq(judge({ effect: 'write' }, { ...ctx, readOnly: true }).available, false, 'lecture seule');
  eq(judge({ effect: 'read', needsConnection: true }, { ...ctx, connected: false }).available, false, 'connexion');
  eq(judge({ effect: 'write' }, { ...ctx, blocked: () => 'Une demande attend.' }).reason, 'Une demande attend.', 'demande en attente');
  eq(judge({ catalogue: true, effect: 'read', id: 'ping' }, ctx).reason, 'Action absente de cet écran.', 'bouton absent');
  eq(judge({ disabled: 'Aucune liste.' }, ctx).reason, 'Aucune liste.', 'motif donné');
});

test('décision : la palette n’écrit jamais', () => {
  eq(decide({ effect: 'write', label: 'X', available: true }).action, 'focus', 'écriture : bouton amené');
  eq(decide({ effect: 'sensitive', label: 'X', available: true }).action, 'focus', 'lecture protégée : bouton amené');
  eq(decide({ effect: 'read', label: 'X', available: true }).action, 'click', 'lecture sans exécution propre : clic');
  eq(decide({ available: false, reason: 'r' }).action, 'none', 'indisponible');
});

test('commande d’écran sans effet déclaré : traitée comme une écriture, jamais exécutée', () => {
  const c = screenCommand({ id: 'x', label: 'X', run: () => { throw new Error('ne doit pas tourner'); } });
  eq(c.effect, 'write', 'effet prudent');
  ok(!('run' in c), 'exécution retirée');
  eq(screenCommand({ id: 'y', label: 'Y', effect: 'read' }).effect, 'read', 'effet déclaré gardé');
});
