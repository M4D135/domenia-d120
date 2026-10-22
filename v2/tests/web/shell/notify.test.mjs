// Banners (web/js/shell/notify.js; TRV-172 to TRV-174).
import { test, eq, ok } from '../harness.mjs';
import { bannerPlan, supportText } from '../../../web/js/shell/notify.js';

test('plan d’une bannière', () => {
  const p = bannerPlan('alert', 'Erreur INC-4F2A : lecture.\n\nDétail.');
  eq(p.code, 'INC-4F2A', 'code extrait');
  eq(p.autoClose, 0, 'erreur gardée');
  eq(p.body, 'Détail.', 'paragraphes');
  eq(bannerPlan('info', 'Simple.').autoClose, 5000, 'information fermée après 5 s');
  eq(bannerPlan('info', 'Simple.', 'détail').autoClose, 0, 'avec détail : gardée');
});

test('copie pour le support masquée et typographiée', () => {
  const text = supportText({ code: 'INC-0001', at: Date.now(), count: 2, screen: 'Accueil', message: 'password=Secret42', detail: '' });
  ok(!text.includes('Secret42'), 'secret masqué');
  ok(text.includes('Occurrences\u00a0: 2'), 'espace insécable avant les deux-points');
});
