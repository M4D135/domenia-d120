import { test, eq, ok, throws } from './harness.mjs';
import { prepareQuerySelection, filterQuerySelection } from '../../web/js/pages/rechercher/query-selection.js';
import { createResults } from '../../web/js/pages/rechercher/results.js';
import { openCatalog } from '../../web/js/pages/rechercher/library.js';

const root = 'DC=test,DC=local';
const ids = ['11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222', '33333333-3333-3333-3333-333333333333'];
const selected = (values = [ids[0]]) => ({ target: 'computer', rootDn: root, ids: values, recipeName: 'Sélection D1', fingerprint: 'a'.repeat(64), at: '2026-10-25T12:00:00Z' });
const row = (id, kind = 'computer') => ({ id, kind, kindLabel: kind, name: 'PC-' + id.slice(0, 2), dn: `CN=PC-${id.slice(0, 2)},${root}`,
  state: { key: 'active', label: 'Actif', tone: 'ok' }, flags: {}, container: 'test.local', readAt: '2026-10-25T12:00:00Z' });
const result = (rows) => ({ listId: 'abc', kind: 'browse', scope: { mode: 'ou', dn: root, subtree: true, wholeDomain: true, chip: 'Domaine', label: 'Domaine', path: 'test.local' },
  type: 'all', match: 'prefix', plan: {}, rows, loaded: rows.length, limit: 200, complete: true, limitReached: false,
  continuation: { allowed: false, reason: 'Complet' }, counter: 'Complet', absence: 'Données locales', readAt: '2026-10-25T12:00:00Z', sourceLabel: 'Copie locale' });

 test('Recherche : GUID seuls, [] actif et qualification de domaine', () => {
  const rows = [row(ids[0]), row(ids[1]), { ...row(ids[0], 'user'), name: 'Même GUID utilisateur' }];
  eq(filterQuerySelection(rows, prepareQuerySelection(selected([`{${ids[0].toUpperCase()}}`]), root)), [rows[0]], 'seuls postes du GUID exact');
  eq(filterQuerySelection(rows, prepareQuerySelection(selected([]), root)), [], 'vide explicite filtre tout');
  eq(filterQuerySelection(rows, null), rows, 'absence de sélection conserve tout');
  throws(() => prepareQuerySelection(selected(), 'DC=other'), 'domaine divergent refusé');
  throws(() => prepareQuerySelection(selected(['PC-11']), root), 'nom non accepté à la place du GUID');
 });

 test('Vrais résultats : sélection persistante sur nouvelle liste/suite/cache, [] et effacement sans lecture', () => {
  const host = document.createElement('div'); document.body.append(host);
  const callbacks = new Proxy({}, { get: () => () => [] });
  const panel = createResults(host, {}, callbacks);
  try {
    panel.show(result([row(ids[0]), row(ids[1]), row(ids[2], 'user')]));
    panel.setQuerySelection(prepareQuerySelection(selected(), root));
    eq(panel.grid.getVisibleRows().map(r => r.id), [ids[0]], 'filtre sur la vraie grille');
    panel.setLoading('Recherche');
    panel.showCached({ rows: [row(ids[0]), row(ids[1])], readAt: '2026-10-25T12:00:00Z' });
    eq(panel.grid.getVisibleRows().map(r => r.id), [ids[0]], 'cache provisoire également filtré');
    panel.show(result([row(ids[1]), row(ids[0])]));
    eq(panel.grid.getVisibleRows().map(r => r.id), [ids[0]], 'filtre conservé sur nouvelle lecture');
    panel.append({ ...result([row(ids[2])]), loaded: 3, appended: true });
    eq(panel.grid.getVisibleRows().map(r => r.id), [ids[0]], 'suite non correspondante masquée');
    panel.setQuerySelection(prepareQuerySelection(selected([]), root));
    eq(panel.grid.getVisibleRows().length, 0, '[] reste un filtre actif');
    ok(host.textContent.includes('Sélection figée') && host.textContent.includes('0 GUID'), 'état vide explicite visible');
    panel.setQuerySelection(null);
    eq(panel.grid.getVisibleRows().length, 3, 'effacement restaure toutes les lignes déjà chargées');
    panel.show({ ...result([]), interrupted: true, complete: false, interruption: 'Lecture interrompue' });
    ok(panel.scopeSentence().includes('résultat partiel interrompu'), 'interruption ne devient pas une simple limite');
    panel.show({ ...result([]), kind: 'localQuery', complete: false, recipe: { sourceComplete: false } });
    ok(host.querySelector('.rch-counter').textContent.includes('Copie locale partielle'), 'source partielle jamais annoncée complète');
  } finally { panel.destroy(); host.remove(); }
 });

 test('Catalogue réel : recette, révision et empreinte visibles ; calcul uniquement sur Exécuter', async () => {
  let run = null; const calls = [];
  const recipe = { id: 'myRecipe', revision: 3, fingerprint: 'c'.repeat(64), rootDn: root };
  const entry = { id: 'recipe:myRecipe', name: 'Recette locale', category: 'Mes recettes', source: 'Bibliothèque locale', typeLabel: 'Postes', description: 'SELECT mémorisé', cost: 'Calcul local', local: true, recipe };
  await openCatalog({ call: async op => { calls.push(op); return { entries: [entry], note: 'Copie locale' }; } }, { ou: () => ({ dn: 'OU=Postes,' + root, name: 'Postes', subtree: true }), onRun: (...args) => { run = args; } });
  const drawer = document.querySelector('.rch-cat');
  try {
    drawer.querySelector('[data-id="recipe:myRecipe"]').click();
    eq(calls, ['search.catalog'], 'ouvrir et sélectionner ne calcule rien');
    ok(drawer.textContent.includes(recipe.fingerprint) && drawer.textContent.includes('Révision'), 'preuve complète affichée');
    drawer.querySelector('[data-run]').click();
    eq(run[0].recipe, recipe, 'révision exacte transmise au consommateur');
    eq(run[1].wholeDomain, false, 'OU choisie conservée');
  } finally { document.querySelector('.k-drawer-close')?.click(); }
 });
