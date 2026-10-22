// Embedded sheets seen from the shell (web/js/shell/sheets.js; TRV-056, TRV-057).
import { test, eq } from '../harness.mjs';
import { sheetTip, enterRunsDefault, SHEET_TIPS } from '../../../web/js/shell/sheets.js';

test('infobulle par défaut selon le type de contrôle', () => {
  eq(sheetTip({ tag: 'INPUT', type: 'password' }), SHEET_TIPS.password, 'mot de passe jamais enregistré');
  eq(sheetTip({ tag: 'TEXTAREA' }), SHEET_TIPS.text, 'saisie : Annuler ne valide rien');
  eq(sheetTip({ tag: 'DIV', role: 'grid' }), SHEET_TIPS.grid, 'liste à choisir');
  eq(sheetTip({ tag: 'BUTTON', label: 'Annuler' }), SHEET_TIPS.cancel, 'Annuler');
  eq(sheetTip({ tag: 'BUTTON', label: 'Valider' }), '', 'bouton ordinaire : rien d’imposé');
});

test('Entrée lance le bouton par défaut hors texte multiligne, liste ou bouton', () => {
  const input = document.createElement('input');
  eq(enterRunsDefault(input), true, 'champ simple');
  eq(enterRunsDefault(document.createElement('textarea')), false, 'texte multiligne');
  eq(enterRunsDefault(document.createElement('button')), false, 'bouton : son propre clic');
  const grid = document.createElement('div');
  grid.setAttribute('role', 'grid');
  const cell = document.createElement('input');
  grid.appendChild(cell);
  eq(enterRunsDefault(cell), false, 'champ d’une grille');
});
