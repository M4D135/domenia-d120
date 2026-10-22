// Operation summary and masking (web/js/shell/summary.js; TRV-061).
import { test, eq, ok } from '../harness.mjs';
import { protectText, operationSummary, isSensitiveOption, isSecretAttribute } from '../../../web/js/shell/summary.js';

test('textes ressemblant à un secret masqués', () => {
  eq(protectText('password=Secret42'), 'password=***', 'clé=valeur');
  ok(!protectText('Bearer abc.def').includes('abc'), 'jeton porteur');
  ok(isSecretAttribute('msLAPS-Password'), 'attribut secret');
});

test('résumé avant exécution, options repliées comprises, valeurs sensibles masquées', () => {
  const s = operationSummary('Réinitialiser', [
    { name: 'NewPassword', label: 'Nouveau mot de passe', value: 'x' },
    { name: 'MustChange', label: 'Changer à la connexion', value: true, default: false },
    { name: 'Comment', label: 'Commentaire', value: 'Appel', advanced: true },
  ]);
  eq(s.lines[0].value, '(masqué)', 'sensible masqué');
  eq(s.lines[1].value, 'Oui', 'oui/non visible');
  eq(s.foldedListed, 1, 'option repliée listée');
  eq(isSensitiveOption({ name: 'MustChangePassword', value: true }), false, 'booléen jamais secret');
});
