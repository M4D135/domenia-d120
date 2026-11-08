// Radio groups of the appearance tab (web/js/pages/shell/appearance.js; APG radio group).
import { test, eq } from '../harness.mjs';
import { radioMove } from '../../../web/js/pages/shell/appearance.js';

test('flèches qui bouclent, Début et Fin, choix désactivés évités', () => {
  eq(radioMove('ArrowRight', 0, 3), 1, 'suivant');
  eq(radioMove('ArrowRight', 2, 3), 0, 'boucle');
  eq(radioMove('ArrowLeft', 0, 3), 2, 'précédent en boucle');
  eq(radioMove('Home', 2, 3), 0, 'Début');
  eq(radioMove('End', 0, 3), 2, 'Fin');
  eq(radioMove('ArrowRight', 0, 2, [1]), 0, 'Expert masqué : reste sur Essentiel');
  eq(radioMove('Enter', 0, 3), -1, 'autre touche');
});
