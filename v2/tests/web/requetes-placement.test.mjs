import { test, eq, ok } from './harness.mjs';
import { mountSave } from '../../web/js/pages/requetes/save.js';

const settle = async () => { for (let n = 0; n < 16; n++) await Promise.resolve(); };

test('Atelier réel : visuels de poste, reçu partiel et reprise du placement sans réécrire la recette', async () => {
  const panel = document.createElement('div'); document.body.append(panel);
  const calls = []; const notices = []; const listeners = new Map(); let plans = 0; let placed = false;
  const widget = { id: 'b'.repeat(32), recipeId: 'test', board: 'computer', visual: 'text', title: 'Ma carte', boundRevision: 1, fingerprint: 'a'.repeat(64), displayable: true, state: 'Révision 1', recipeName: 'Ma recette' };
  const store = {
    alive: true, recipe: { id: 'test', name: 'Ma recette', target: 'computer', clauses: [] }, saved: null, version: 1,
    validation: { valid: true, conditionCount: 0, format: 'Domenia.Query/3', fingerprint: 'a'.repeat(64) },
    on(name, cb) { if (!listeners.has(name)) listeners.set(name, []); listeners.get(name).push(cb); return () => {}; },
    emit(name) { for (const cb of listeners.get(name) ?? []) cb(); },
    setRecipe(recipe) { this.recipe = recipe; }, toast(message, tone) { notices.push({ message, tone }); },
    async call(op, args) {
      calls.push({ op, args });
      if (op === 'requetes.library.list') return { data: { categories: [], persistent: false } };
      if (op === 'requetes.widget.list') return { data: [{ ...widget, placed }] };
      if (op === 'requetes.widget.place') { placed = true; return { data: { applied: true, summary: 'Widget ajouté au tableau Poste.' } }; }
      if (op === 'requetes.widget.save') return { data: {
        id: 'test', name: 'Ma recette', revision: 1, fingerprint: widget.fingerprint, recipe: this.recipe, widget, remote: true,
        receipt: { readBack: true, persisted: false, text: 'Bibliothèque relue', fingerprint: widget.fingerprint },
        placement: { applied: false, summary: 'Disposition incompatible conservée ; ajout non appliqué.' },
      } };
      throw new Error(`Appel inattendu : ${op}`);
    },
  };
  const ui = mountSave(panel, store, { plan() { plans++; }, rename() {} });
  try {
    await settle();
    panel.querySelector('[data-board="computer"]').click();
    eq([...panel.querySelectorAll('[data-visual]')].filter(b => !b.hidden && !b.disabled).map(b => b.dataset.visual), ['kpi', 'text'], 'pas de distribution de population pour un poste');
    panel.querySelector('[data-visual="text"]').click();
    panel.querySelector('.rq-w-add').click(); await settle();
    eq(calls.filter(c => c.op === 'requetes.widget.save').length, 1, 'un seul enregistrement explicite');
    eq(calls.find(c => c.op === 'requetes.widget.save').args.visual, 'text', 'vraie présentation choisie envoyée');
    ok(panel.querySelector('.rq-receipt').textContent.includes('ajout au tableau non appliqué'), 'pas de succès de placement mensonger');
    ok(panel.querySelector('.rq-receipt').classList.contains('warn'), 'reçu distinct visible');
    eq(plans, 0, 'échec de placement n’ouvre pas de collecte');
    panel.querySelector('[data-place]').click(); await settle();
    eq(calls.find(c => c.op === 'requetes.widget.place').args, { id: widget.id, revision: 1, fingerprint: widget.fingerprint }, 'réessai lié aux preuves affichées');
    eq(calls.filter(c => c.op === 'requetes.widget.save').length, 1, 'réessai ne crée pas une seconde révision');
    ok(!panel.querySelector('[data-place]'), 'bouton retiré après placement réussi');
    ok(notices.some(n => n.tone === 'warn') && notices.some(n => n.tone === 'ok'), 'deux résultats distingués');
  } finally { store.alive = false; ui.destroy(); panel.remove(); }
});
