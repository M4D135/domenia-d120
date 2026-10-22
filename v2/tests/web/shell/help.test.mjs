// Help catalogue rules (web/js/shell/help.js; TRV-004 to TRV-007).
import { test, eq, ok, throws } from '../harness.mjs';
import { disabledHelp, presentation, routeOfText, DISABLED_DETAILS, ROUTES } from '../../../web/js/shell/help.js';

test('motif d’un contrôle grisé : catalogue fermé', () => {
  const h = disabledHelp('Ouvrir le dossier', 'prerequisite', 'memoryOnly');
  ok(h.short.startsWith('Ouvrir le dossier : Prérequis non rempli'), 'action et motif');
  ok(h.short.includes('Cette session ne garde rien sur le disque'), 'détail de la session en mémoire');
  eq(h.route, 'apropos', 'route qui débloque');
  ok(DISABLED_DETAILS.policyHidden, 'détail de la règle de l’administrateur');
  throws(() => disabledHelp('x', 'inconnu'), 'motif hors catalogue refusé');
  throws(() => disabledHelp('x', 'busy', 'texte libre'), 'détail libre refusé');
});

test('infobulle selon le rôle', () => {
  eq(presentation('Première phrase. Deuxième.', 'iconButton').tip, 'Première phrase.', 'bouton icône : première phrase');
  eq(presentation('Texte.', 'container').tip, '', 'zone : aucune infobulle');
});

test('routes sûres nommées par un message', () => {
  eq(routeOfText('Relisez son reçu dans Opérations à vérifier.'), 'operations-verifier', 'reçus à vérifier');
  eq(routeOfText('Rien de particulier.'), '', 'aucune route');
  ok(ROUTES.aide && ROUTES['lecture-seule'].panel === 'session', 'catalogue des routes');
});
