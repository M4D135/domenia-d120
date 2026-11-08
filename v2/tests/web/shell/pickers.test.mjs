// Pure rules of the shared pickers (web/js/shell/pickers.js; TRV-242 to TRV-246).
import { test, eq, ok, throws } from '../harness.mjs';
import {
  distinctOuLabels, revealPath, verifyDecision, isSharePath, conflictOf, safeFileName, rdn, ouPathNames, ouDisplayPath,
  OU_SEARCH_LIMIT, OU_LABELS_LIMIT, OU_DN_MAXIMUM_LENGTH,
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

test('désambiguïsation bornée à 500 DN, comme la fonction de référence', () => {
  eq(OU_LABELS_LIMIT, 500, 'la borne annoncée est 500 DN');
  const many = Array.from({ length: 900 }, (_, i) => `OU=Postes${i},${ROOT}`);
  const bounded = distinctOuLabels(many);
  eq(bounded.length, OU_LABELS_LIMIT, 'au-delà de la borne, les DN ne sont pas labellisés');
  eq(bounded[0].dn, `OU=Postes0,${ROOT}`, 'l’ordre d’entrée est gardé dès le premier DN');
  eq(bounded[OU_LABELS_LIMIT - 1].dn, `OU=Postes${OU_LABELS_LIMIT - 1},${ROOT}`, 'la borne porte sur les DN retenus');
  eq(distinctOuLabels(many, 3).length, 3, 'une borne plus basse est respectée');
  eq(distinctOuLabels(Array.from({ length: 600 }, (_, i) => `OU=Postes,OU=S${i % 2},${ROOT}`)).length, 2, 'les doublons ne consomment pas la borne');
  throws(() => distinctOuLabels([`OU=A,${ROOT}`], 0), 'une borne nulle est refusée');
  throws(() => distinctOuLabels([`OU=A,${ROOT}`], 2001), 'une borne au-dessus de 2000 est refusée');
  throws(() => distinctOuLabels([`OU=A,${ROOT}`], 1.5), 'une borne non entière est refusée');
  eq(OU_DN_MAXIMUM_LENGTH, 4096, 'un DN trop long n’est pas lu');
  const tooLong = `OU=${'x'.repeat(OU_DN_MAXIMUM_LENGTH + 1)},${ROOT}`;
  eq(distinctOuLabels([tooLong, `OU=Postes,${ROOT}`]).map((l) => l.dn), [`OU=Postes,${ROOT}`], 'un DN démesuré est écarté, les autres restent labellisés');
  const atLimit = `OU=${'x'.repeat(OU_DN_MAXIMUM_LENGTH - ROOT.length - 4)},${ROOT}`;
  eq(atLimit.length, OU_DN_MAXIMUM_LENGTH, 'DN exactement à la longueur maximale');
  eq(distinctOuLabels([atLimit]).length, 1, 'à la longueur maximale, le DN est encore labellisé');
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
