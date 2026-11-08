// Names proposed by the save mode of the picker (web/js/shell/exports.js; TRV-054, TRV-244).
import { test, eq } from '../harness.mjs';
import { suggestedFileName } from '../../../web/js/shell/exports.js';

test('nom proposé comme celui du moteur', () => {
  const at = new Date(2026, 9, 22, 9, 5);
  eq(suggestedFileName('OU Postes / Lyon', 'csv', at), 'Domenia-OU-Postes-Lyon-20261022-0905.csv', 'sujet nettoyé');
  eq(suggestedFileName(' /// ', 'json', at), 'Domenia-export-20261022-0905.json', 'sujet vide');
  eq(suggestedFileName('Sécurité', 'csv', at), 'Domenia-Sécurité-20261022-0905.csv', 'accents gardés');
});
