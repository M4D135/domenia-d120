// Layout plan of the window and fold of the menu beside the help panel (web/js/shell/environment.js; TRV-094).
import { test, eq } from '../harness.mjs';
import { heightPlan, foldPlan, HELP_CONTENT_MIN } from '../../../web/js/shell/environment.js';

test('fenêtre courte, basse, étroite', () => {
  eq(heightPlan(900, 1600), { short: true, low: false, tiny: false, narrow: false, foldNavigation: false }, 'courte et large');
  eq(heightPlan(650, 1100).foldNavigation, true, 'courte et étroite : menu replié');
  eq(heightPlan(1000, 1200).narrow, true, 'étroite');
});

test('le menu se replie quand le contenu passerait sous 1 280 px à côté de l’aide', () => {
  const base = { help: 380, navExpanded: 248, navCollapsed: 72 };
  eq(HELP_CONTENT_MIN, 1280, 'seuil');
  eq(foldPlan({ ...base, helpOpen: true, helpFold: false, collapsed: false, content: 1600 }), 'fold', '1 600 − 380 < 1 280');
  eq(foldPlan({ ...base, helpOpen: true, helpFold: false, collapsed: false, content: 1700 }), 'none', 'assez de place');
  eq(foldPlan({ ...base, helpOpen: false, helpFold: true, collapsed: true, content: 1700 }), 'unfold', 'aide fermée : menu rendu');
  eq(foldPlan({ ...base, helpOpen: true, helpFold: true, collapsed: true, content: 1900 }), 'unfold', 'fenêtre agrandie : menu rendu');
  eq(foldPlan({ ...base, helpOpen: true, helpFold: true, collapsed: true, content: 1800 }), 'none', 'marge de 40 px : pas de va-et-vient');
  eq(foldPlan({ ...base, helpOpen: true, helpFold: false, collapsed: true, content: 1000 }), 'none', 'menu déjà replié par l’opérateur : rien');
});
