// Pure rules of the shared pickers (web/js/shell/pickers.js; TRV-242 to TRV-246).
import { test, eq, ok } from '../harness.mjs';
import {
  distinctOuLabels, revealPath, verifyDecision, isSharePath, conflictOf, safeFileName, rdn, ouPathNames, ouDisplayPath, OU_SEARCH_LIMIT,
} from '../../../web/js/shell/pickers.js';

const ROOT = 'DC=example,DC=local';

test('favoris de même nom désambiguïsés par leurs parents', () => {
  const labels = distinctOuLabels([`OU=Postes,OU=Lyon,${ROOT}`, `OU=Postes,OU=Paris,${ROOT}`, `OU=Serveurs,${ROOT}`]);
  eq(labels.map((l) => l.label), ['Postes (Lyon)', 'Postes (Paris)', 'Serveurs'], 'libellés distincts');
  eq(labels[2].ambiguous, false, 'nom unique gardé tel quel');
  const deep = distinctOuLabels([`OU=Postes,OU=Site,OU=Lyon,${ROOT}`, `OU=Postes,OU=Site,OU=Paris,${ROOT}`]);
  eq(deep.map((l) => l.label), ['Postes (Lyon / Site)', 'Postes (Paris / Site)'], 'élargi d’un parent à la fois');
  eq(distinctOuLabels([`OU=A,${ROOT}`, `ou=a,${ROOT}`]).length, 1, 'même DN sans casse : une fois');
});

test('chemin d’une OU dans l’arbre, parent par parent', () => {
  eq(revealPath(`OU=Paris,OU=Postes,${ROOT}`, ROOT), ['dc=example,dc=local', 'ou=postes,dc=example,dc=local', 'ou=paris,ou=postes,dc=example,dc=local'], 'racine puis parents');
  eq(revealPath('OU=X,DC=autre,DC=local', ROOT), null, 'hors du domaine');
  eq(rdn('OU=R\\&D,DC=a'), 'R&D', 'échappement retiré');
  eq(ouPathNames(`OU=Paris,OU=Postes,${ROOT}`), ['Paris', 'Postes'], 'noms de la feuille vers le haut');
  eq(ouDisplayPath(`OU=Paris,OU=Postes,${ROOT}`), 'Postes › Paris', 'chemin lisible');
  eq(OU_SEARCH_LIMIT, 100, '100 OU par recherche');
});

test('revérification : déplacé à confirmer, introuvable ou refusé jamais rendu', () => {
  eq(verifyDecision({ state: 'ok' }).accept, true, 'même objet');
  eq(verifyDecision({ state: 'moved' }), { accept: false, confirm: true, tone: 'warn' }, 'déplacé : confirmation visible');
  eq(verifyDecision({ state: 'missing' }).accept, false, 'introuvable');
  eq(verifyDecision({ state: 'denied' }).confirm, false, 'refusé');
});

test('mode enregistrement : nom, conflit et partage', () => {
  ok(safeFileName('Domenia-Postes-20261022-0905.csv', 'csv'), 'nom d’export');
  eq(safeFileName('CON.csv', 'csv'), false, 'périphérique');
  eq(safeFileName('a?.csv', 'csv'), false, 'caractère interdit');
  eq(safeFileName('rapport.json', 'csv'), false, 'nature');
  const entries = [{ kind: 'folder', name: 'rapport.csv' }, { kind: 'file', name: 'Rapport.CSV', size: 3, at: '2026-10-22T09:05:00Z' }];
  eq(conflictOf(entries, 'rapport.csv').size, 3, 'fichier existant trouvé sans casse');
  eq(conflictOf(entries, 'autre.csv'), null, 'aucun conflit');
  ok(isSharePath('\\\\srv-fic-01\\Partage'), 'partage reconnu');
  eq(isSharePath('C:\\Partage'), false, 'chemin local');
});
