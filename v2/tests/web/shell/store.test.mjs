// Preferences of the interface (web/js/shell/store.js; TRV-062, TRV-095).
import { test, eq } from '../harness.mjs';
import { normalizePrefs, isPersistableAddress, sessionMark } from '../../../web/js/shell/store.js';

test('préférences bornées', () => {
  const p = normalizePrefs({ theme: 'violet', navWidth: 999, profile: 'expert', bannerCompact: true });
  eq(p.theme, 'system', 'thème inconnu : celui de Windows');
  eq(p.navWidth, null, 'largeur hors bornes');
  eq(p.profile, 'expert', 'profil');
  eq(p.bannerCompact, true, 'bandeau replié');
});

test('adresses récentes enregistrées seulement sans objet de l’annuaire', () => {
  eq(isPersistableAddress('#/shell?onglet=aide'), true, 'onglet d’écran');
  eq(isPersistableAddress('#/fiche?dn=CN%3DCamille'), false, 'DN : session seulement');
  eq(isPersistableAddress('#/rechercher?q=martin'), false, 'texte saisi : session seulement');
  eq(isPersistableAddress('#/accueil'), true, 'écran seul');
  eq(isPersistableAddress('https://x'), false, 'adresse externe');
});

test('marque de la session : compte, domaine, racine', () => {
  eq(sessionMark({ account: { login: 'EX\\adm' }, domain: { dnsName: 'example.local', rootDn: 'DC=example,DC=local' } }), 'EX\\adm|example.local|DC=example,DC=local', 'marque');
  eq(sessionMark(null), '||', 'sans session');
});
