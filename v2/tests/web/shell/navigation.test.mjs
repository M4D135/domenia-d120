// Navigation rules (web/js/shell/navigation.js; TRV-066, TRV-167, TRV-169 to TRV-171).
import { test, eq, ok } from '../harness.mjs';
import { aliasOf, recentAddress, describeHash, rdnValue, expertDecision, subjectSummary, setSubject } from '../../../web/js/shell/navigation.js';

test('anciennes adresses redirigées, paramètres gardés', () => {
  eq(aliasOf('#/journal'), '#/operations', 'journal');
  eq(aliasOf('#/aide?x=1'), '#/shell?onglet=aide&x=1', 'paramètres ajoutés');
  eq(aliasOf('#/accueil'), null, 'adresse actuelle');
});

test('adresses récentes sans paramètres passagers', () => {
  eq(recentAddress('#/poste?dn=CN%3DPC&coque=aide&vue=expert'), '#/poste?dn=CN%3DPC', 'coque et vue retirés');
  eq(describeHash('#/fiche?dn=CN%3DCamille%20Martin%2COU%3DX', [{ id: 'fiche', label: 'Fiche' }]).label, 'Fiche · Camille Martin', 'objet nommé par son DN');
  eq(rdnValue('CN=Dupont\\, Jean,OU=X'), 'Dupont, Jean', 'échappement retiré');
});

test('vue experte ponctuelle : refusée avec sa raison', () => {
  eq(expertDecision({ profile: 'essentiel' }).temporary, true, 'Essentiel : pour cette consultation');
  eq(expertDecision({ profile: 'expert' }).temporary, false, 'Expert : vue normale');
  const hidden = expertDecision({ profile: 'essentiel', allowExpert: false });
  eq(hidden.show, false, 'Expert masqué par l’administrateur : refusé');
  ok(hidden.reason.includes('administrateur'), 'raison donnée');
  eq(expertDecision({ profile: 'essentiel', applies: false, reason: 'Aucune fiche ouverte.' }).reason, 'Aucune fiche ouverte.', 'vue sans objet : raison de l’écran');
});

test('sujet global choisi par Rechercher seulement', () => {
  eq(setSubject({ kind: 'user', name: 'X', dn: 'CN=X,DC=a' }, 'fiche'), false, 'refusé hors de Rechercher');
  eq(subjectSummary({ kind: 'computer', name: 'PC-01', dn: 'CN=PC-01,OU=Paris,OU=Postes,DC=example,DC=local' }).split('\r\n')[1], 'OU\u00a0: Postes / Paris', 'chemin du conteneur');
});
