import { test, eq, ok } from './harness.mjs';
import { mountLibrary } from '../../web/js/pages/requetes/library.js';
import { createStore, emptyRecipe } from '../../web/js/pages/requetes/shared.js';

const settle = async () => { for (let i = 0; i < 24; i++) await Promise.resolve(); await new Promise(requestAnimationFrame); };

test('Bibliothèque : modèle de répartition vers widget, catégorie visible et archives protégées', async () => {
  for (const archived of [false, true]) {
    const panel = document.createElement('main'); panel.className = 'main'; panel.dataset.page = 'requetes'; document.body.append(panel);
    const calls = [], loaded = [];
    const recipe = { ...emptyRecipe(), name: 'Méthodes BitLocker de C:', groupBy: 'probe:sec.bitlockermethodc' };
    const row = { id: 'template.bitlocker.methods', name: recipe.name, category: 'Sécurité', target: 'computer', source: archived ? 'archive' : 'template', archived,
      informations: 'Méthode BitLocker du volume C:', remote: true, revision: 1, widgets: 0 };
    const detail = { ...row, recipe, summary: [], history: [], widgets: [], archivedWidgets: [], consumers: [], sources: 'Sonde WMI', collection: 'Lecture explicite du poste', provenanceText: 'Modèle livré' };
    const store = createStore({ toast() {}, async call(op, args) {
      calls.push({ op, args });
      if (op === 'requetes.library.list') return { rows: [row], total: 1, filtered: 1, categories: ['Sécurité', 'Matériel'], persistent: true };
      if (op === 'requetes.library.get') return detail;
      throw new Error(`Appel non attendu : ${op}`);
    } });
    const ui = mountLibrary(panel, store, { load: (d, options) => loaded.push({ d, options }) });
    try {
      await settle();
      const categories = panel.querySelector('.rq-lib-category');
      eq([...categories.options].map(o => o.textContent), ['Toutes les catégories', 'Sécurité', 'Matériel'], 'catégories accessibles sans menu caché');
      categories.value = 'Sécurité'; categories.dispatchEvent(new Event('change', { bubbles: true })); await settle();
      eq(calls.filter(c => c.op === 'requetes.library.list').at(-1).args.category, 'Sécurité', 'filtre transmis à la bibliothèque');
      const widget = panel.querySelector('[data-act="widget"]');
      eq(widget.disabled, archived, 'une archive ne crée aucun widget avant restauration');
      widget.click();
      if (archived) eq(loaded.length, 0, 'archive non chargée');
      else {
        eq(loaded.length, 1, 'une seule intention de création');
        eq(loaded[0].options, { preview: false, widget: true }, 'accès direct au titre, placement et visuel');
        eq(loaded[0].d.recipe, recipe, 'répartition conservée intégralement sans filtre sur une méthode');
      }
      ok(!calls.some(c => /save|refresh|collect/.test(c.op)), 'choisir le modèle ne lance aucune écriture ni collecte');
    } finally { store.alive = false; ui.destroy(); panel.remove(); }
  }
});
