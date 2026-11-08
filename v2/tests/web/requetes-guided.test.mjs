import { test, eq, ok } from './harness.mjs';
import { mountCompose } from '../../web/js/pages/requetes/compose.js';
import { mountCatalog } from '../../web/js/pages/requetes/catalog.js';
import { mountSave } from '../../web/js/pages/requetes/save.js';
import { createStore, clone, emptyRecipe } from '../../web/js/pages/requetes/shared.js';

const instanceId = 'instance:sec.bitlockervolumes:EncryptionMethod';
const probeId = 'probe:sec.bitlockervolumes';
const leaf = (field, value) => ({ kind: 'clause', clause: { field, operator: 'equal', value }, children: [], collectionField: null, quantifier: null });
const group = (kind, children) => ({ kind, children, clause: null, collectionField: null, quantifier: null });
const field = { id: instanceId, name: 'Volumes BitLocker · Méthode de chiffrement', probeId: 'sec.bitlockervolumes', property: 'EncryptionMethod',
  kind: 'Number', source: 'Instance', typeLabel: 'Nombre', category: 'Sécurité', unit: 'Code Microsoft', groupable: false,
  description: 'Méthode du volume.', freshness: 'Selon la collecte', collection: 'Sonde Volumes BitLocker', cost: 'Lecture du poste',
  operators: ['Equal', 'NotEqual', 'IsMissing', 'IsPresent'], choices: [{ name: 'Non chiffré', value: 0 }, { name: 'XTS-AES 128', value: 6 }, { name: 'XTS-AES 256', value: 7 }] };
const os = { id: 'os', name: 'Système AD', source: 'Ad', kind: 'Text', typeLabel: 'Texte', category: 'Annuaire', operators: ['Equal', 'Contains'], choices: [], groupable: true };
const numericField = { ...field, id: 'instance:sec.bitlockervolumes:Size', name: 'Volumes BitLocker · Taille', property: 'Size', choices: [], operators: ['Equal'], unit: 'Octets' };
const systemVolume = { ...field, id: 'probe:sec.bitlockermethodc', name: 'Méthode BitLocker du volume C:', source: 'Probe', probeId: 'sec.bitlockermethodc', kind: 'Text', groupable: true,
  choices: [{ name: 'Non chiffré', value: 'Non chiffré' }, { name: 'XTS-AES 128', value: 'XTS-AES 128' }, { name: 'XTS-AES 256', value: 'XTS-AES 256' }] };
const catalog = { fields: [os, systemVolume], instanceFields: [field, numericField], collections: [{ id: probeId, name: 'Sécurité · Volumes BitLocker' }], ldapFields: [], ldapAttributes: [] };
const settle = async () => { for (let i = 0; i < 16; i++) await Promise.resolve(); await new Promise(requestAnimationFrame); };
async function waitWidgetReady(panel) {
  const deadline = performance.now() + 5000;
  while (panel.querySelector('.rq-w-add')?.disabled !== false) {
    if (performance.now() > deadline) throw new Error('Bibliothèque et validation du widget non prêtes en cinq secondes.');
    await new Promise(resolve => setTimeout(resolve, 20));
  }
}


function fixture(recipe = emptyRecipe()) {
  const calls = [], notices = [], routes = [], previews = [];
  const host = document.createElement('main'); host.className = 'main'; host.dataset.page = 'requetes';
  const composePanel = document.createElement('div'), catalogPanel = document.createElement('div'), savePanel = document.createElement('div');
  host.append(composePanel, catalogPanel, savePanel); document.body.append(host);
  const store = createStore({
    toast(message) { notices.push(message); },
    async call(op, args) {
      calls.push({ op, args: clone(args) });
      if (op === 'requetes.catalog') return catalog;
      if (op === 'requetes.library.list') return { categories: [], persistent: true };
      if (op === 'requetes.widget.list') return [];
      if (op === 'requetes.widget.save') return { id: args.recipe.id, name: args.recipe.name, recipe: clone(args.recipe), revision: 1, fingerprint: 'a'.repeat(64), remote: false,
        receipt: { readBack: true, persisted: true, text: 'Enregistré', fingerprint: 'a'.repeat(64) }, placement: { applied: true, summary: 'Widget ajouté' } };
      if (op === 'requetes.value.preview') return { valid: true, value: Number(args.text), text: args.text };
      throw new Error(`Appel inattendu : ${op}`);
    },
  });
  store.recipe = clone(recipe);
  store.validation = { valid: true, conditionCount: 1, format: 'Domenia.Query/3', errors: [], warnings: [], summary: [], fingerprint: 'a'.repeat(64) };
  let compose, save, information;
  const api = {
    goto(tab) { routes.push(tab); },
    runPreview() { previews.push(clone(store.recipe)); },
    useField(id) { compose ??= mountCompose(composePanel, store, api); compose.useField(id); },
    useDistribution(id) { compose ??= mountCompose(composePanel, store, api); compose.useField(id, { distribution: true }); },
    createWidget() { routes.push('enregistrer'); save ??= mountSave(savePanel, store, api); save.focusWidget(); },
    plan() {}, rename() {},
  };
  return { store, calls, notices, routes, previews, composePanel, catalogPanel, savePanel, api,
    mountCompose() { compose ??= mountCompose(composePanel, store, api); return compose; },
    mountCatalog() { information = mountCatalog(catalogPanel, store, api); },
    destroy() { store.alive = false; compose?.destroy(); information?.destroy(); save?.destroy(); host.remove(); },
  };
}

test('Atelier : changer de modèle réinitialise le titre et le visuel du futur widget, sans effacer un choix pendant une simple édition', async () => {
  const f = fixture({ ...emptyRecipe(), name: 'Premier modèle' });
  try {
    f.api.createWidget(); await settle();
    const title = f.savePanel.querySelector('.rq-w-title');
    title.value = 'Titre personnel'; title.dispatchEvent(new Event('input', { bubbles: true }));
    f.savePanel.querySelector('[data-visual="bar"]').click();
    f.store.setRecipe({ ...f.store.recipe, name: 'Premier modèle corrigé' });
    eq(title.value, 'Titre personnel', 'une modification du même brouillon conserve le titre choisi');
    eq(f.savePanel.querySelector('[data-visual="bar"]').getAttribute('aria-checked'), 'true', 'visuel conservé pendant édition');
    f.store.setRecipe({ ...emptyRecipe(), name: 'Méthodes BitLocker', groupBy: systemVolume.id }, { origin: 'load' });
    f.api.createWidget();
    eq(title.value, 'Méthodes BitLocker', 'le nouveau modèle ne reprend pas l’ancien titre');
    eq(f.savePanel.querySelector('[data-visual="pie"]').getAttribute('aria-checked'), 'true', 'répartition suggérée pour le nouveau modèle');
    f.store.setRecipe({ ...emptyRecipe(), name: 'Comptes actifs' }, { origin: 'load' });
    f.api.createWidget();
    eq(title.value, 'Comptes actifs', 'titre du troisième modèle');
    eq(f.savePanel.querySelector('[data-visual="kpi"]').getAttribute('aria-checked'), 'true', 'compteur sans répartition retrouve le chiffre clé');
  } finally { f.destroy(); }
});

test('Atelier guidé : Utiliser une propriété de volume garde les critères, propose XTS-AES 128 et ouvre directement la création du widget', async () => {
  const recipe = emptyRecipe(); recipe.name = 'Postes Windows avec un volume XTS-AES 128';
  recipe.clauses = [{ field: 'os', operator: 'contains', value: 'Windows 11' }];
  recipe.expression = group('any', [leaf('department', 'Paris'), leaf('department', 'Lyon')]);
  const f = fixture(recipe);
  try {
    f.mountCatalog();
    f.catalogPanel.querySelector('[data-tab="fields"]').click();
    await settle();
    const row = [...f.catalogPanel.querySelectorAll('.k-gr')].find(el => el.textContent.includes(field.name));
    ok(row, 'propriété visible dans le vrai catalogue');
    row.dispatchEvent(new PointerEvent('pointerdown', { bubbles: true }));
    f.catalogPanel.querySelector('.rq-use-field').click();
    await settle();
    const p = f.composePanel;
    ok(p.querySelector('[role="combobox"]').value.includes('Méthode de chiffrement'), 'Utiliser choisit la propriété, même au premier montage asynchrone');
    eq(f.store.recipe, recipe, 'choisir une information ne modifie pas le brouillon');
    const value = p.querySelector('.rq-val-select');
    ok(value, 'choix lisibles proposés à la place de codes à saisir');
    ok(document.activeElement === value, 'la valeur reçoit le focus');
    ok([...value.options].some(o => o.value === '6' && o.textContent === 'XTS-AES 128'), 'libellé et code viennent du catalogue');
    ok(p.querySelector('.rq-instance-scope').textContent.includes('Au moins un volume'), 'portée affichée avant ajout');
    value.value = '6'; value.dispatchEvent(new Event('change', { bubbles: true }));
    p.querySelector('.rq-add').click();
    eq(f.store.recipe.clauses, recipe.clauses, 'le filtre OS est conservé exactement');
    eq(f.store.recipe.expression.children[0], recipe.expression, 'le OU existant reste intact et est restreint en ET');
    const collection = f.store.recipe.expression.children[1];
    eq([collection.kind, collection.collectionField, collection.quantifier], ['collection', probeId, 'any'], 'collection corrélée correcte');
    eq(collection.children[0].children[0].clause, { field: instanceId, operator: 'equal', value: 6 }, 'valeur numérique typée, sans conversion en texte ou en code inconnu');
    ok(p.querySelector('[data-collection-path]').textContent.includes('XTS-AES 128'), 'critère lisible directement dans Vos critères');
    ok(![...p.querySelectorAll('.rq-groupby-select option')].some(o => o.value === instanceId), 'aucune répartition implicite des volumes');
    p.querySelector('.rq-go-preview').click();
    eq(f.previews[0], f.store.recipe, 'aperçu du même brouillon');
    const beforeWidget = clone(f.store.recipe);
    p.querySelector('.rq-go-save').click();
    ok(document.activeElement === f.savePanel.querySelector('.rq-w-title'), 'création guidée : titre du widget directement accessible');
    eq(f.store.recipe, beforeWidget, 'le passage au widget ne change aucun critère');
    await waitWidgetReady(f.savePanel);
    f.savePanel.querySelector('.rq-w-add').click(); await settle();
    eq(f.calls.find(c => c.op === 'requetes.widget.save').args.recipe, beforeWidget, 'la vraie opération d’enregistrement reçoit le brouillon complet');
    eq(f.calls.find(c => c.op === 'requetes.widget.save').args.expectedRevision, 0, 'première création conserve le garde de révision');
    ok(!f.notices.some(n => n.includes('propriété d’instance s’utilise')), 'aucun renvoi opaque vers les conditions avancées');
    ok(!f.calls.some(c => c.op === 'requetes.value.preview'), 'les choix enum du catalogue ne lancent pas de conversion différée');
  } finally { f.destroy(); }
});

test('Atelier guidé : modifier puis retirer un critère de volume conserve les critères AD et reste dans le formulaire simple', async () => {
  const recipe = emptyRecipe(); recipe.clauses = [{ field: 'os', operator: 'equal', value: 'Windows 11' }];
  const f = fixture(recipe);
  try {
    const ui = f.mountCompose(); ui.useField(instanceId); await settle();
    const p = f.composePanel;
    p.querySelector('.rq-val-select').value = '6'; p.querySelector('.rq-val-select').dispatchEvent(new Event('change', { bubbles: true }));
    p.querySelector('.rq-add').click();
    eq(p.querySelector('[data-fold="advanced"]').open, false, 'pas d’arbre avancé imposé pour une condition simple');
    p.querySelector('[data-collection-act="edit"]').click();
    eq(p.querySelector('.rq-val-select').value, '6', 'modification reprend la valeur réellement enregistrée');
    p.querySelector('.rq-val-select').value = '7'; p.querySelector('.rq-val-select').dispatchEvent(new Event('change', { bubbles: true }));
    p.querySelector('.rq-add').click();
    eq(f.store.recipe.expression.children.length, 1, 'modification sans ajouter une seconde condition');
    eq(f.store.recipe.expression.children[0].children[0].children[0].clause.value, 7, 'méthode modifiée');
    eq(f.store.recipe.clauses, recipe.clauses, 'OS intact pendant la modification');
    p.querySelector('[data-collection-act="remove"]').click();
    eq(f.store.recipe.expression, null, 'collection retirée entièrement');
    eq(f.store.recipe.clauses, recipe.clauses, 'les critères AD restent en place');
  } finally { f.destroy(); }
});

test('Atelier avancé : un nombre vide ne devient pas zéro et les choix de méthode restent lisibles', async () => {
  const recipe = emptyRecipe();
  recipe.expression = { ...group('collection', [leaf(instanceId, 6)]), collectionField: probeId, quantifier: 'any' };
  const f = fixture(recipe);
  try {
    f.mountCompose(); await settle();
    const p = f.composePanel;
    ok(p.querySelector('.rq-inst-val') instanceof HTMLSelectElement, 'le formulaire avancé bénéficie aussi du catalogue enum');
    eq([...p.querySelector('.rq-inst-val').options].map(o => o.textContent), ['Non chiffré', 'XTS-AES 128', 'XTS-AES 256'], 'valeurs explicites');
    p.querySelector('.rq-inst-val').value = '7'; p.querySelector('.rq-inst-add').click();
    eq(f.store.recipe.expression.children[0].kind, 'all', 'le critère existant est enveloppé en ET');
    eq(f.store.recipe.expression.children[0].children.map(n => n.clause.value), [6, 7], 'aucune perte du premier critère');
    p.querySelector('.rq-inst-op').value = 'isMissing'; p.querySelector('.rq-inst-op').dispatchEvent(new Event('change', { bubbles: true }));
    ok(p.querySelector('.rq-inst-val').disabled, 'absence ne demande pas de valeur arbitraire');
    p.querySelector('.rq-inst-field').value = numericField.id; p.querySelector('.rq-inst-field').dispatchEvent(new Event('change', { bubbles: true }));
    eq(p.querySelector('.rq-inst-val').value, '', 'nouvelle propriété numérique sans valeur préremplie');
    const beforeEmpty = clone(f.store.recipe);
    p.querySelector('.rq-inst-add').click();
    eq(f.store.recipe, beforeEmpty, 'nombre vide refusé sans inventer zéro');
    ok(f.notices.some(n => n.includes('Saisissez un nombre')), 'refus compréhensible');
  } finally { f.destroy(); }
});

test('Atelier guidé : Créer une répartition conserve le périmètre et les filtres, puis propose un anneau sans choisir une méthode à la place de l’utilisateur', async () => {
  const recipe = emptyRecipe(); recipe.name = 'Méthodes BitLocker C:';
  recipe.clauses = [{ field: 'os', operator: 'contains', value: 'Windows' }];
  const f = fixture(recipe);
  try {
    f.mountCatalog(); f.catalogPanel.querySelector('[data-tab="fields"]').click(); await settle();
    const row = [...f.catalogPanel.querySelectorAll('.k-gr')].find(el => el.textContent.includes(systemVolume.name));
    ok(row, 'la méthode du volume C: figure au catalogue');
    row.dispatchEvent(new PointerEvent('pointerdown', { bubbles: true }));
    f.catalogPanel.querySelector('.rq-use-distribution').click(); await settle();
    eq(f.store.recipe.clauses, recipe.clauses, 'aucun filtre Non chiffré ou XTS-AES 128 ajouté implicitement');
    eq(f.store.recipe.expression, null, 'aucune collection arbitraire');
    eq(f.store.recipe.groupBy, systemVolume.id, 'répartition explicite par le seul volume C:');
    eq(f.composePanel.querySelector('.rq-groupby-select').value, systemVolume.id, 'répartition visible dans le résumé');
    f.composePanel.querySelector('.rq-go-save').click();
    eq(f.savePanel.querySelector('[data-visual="pie"]').getAttribute('aria-checked'), 'true', 'anneau proposé pour une répartition');
    f.savePanel.querySelector('[data-visual="bar"]').click(); f.api.createWidget();
    eq(f.savePanel.querySelector('[data-visual="bar"]').getAttribute('aria-checked'), 'true', 'le choix visuel explicite est conservé lors du retour');
    await waitWidgetReady(f.savePanel);
    f.savePanel.querySelector('.rq-w-add').click(); await settle();
    const saved = f.calls.find(c => c.op === 'requetes.widget.save').args;
    eq([saved.recipe.groupBy, saved.visual], [systemVolume.id, 'bar'], 'le widget reçoit la répartition et le visuel affichés');
    eq(saved.recipe.clauses, recipe.clauses, 'les filtres restent inchangés jusqu’à l’enregistrement');
  } finally { f.destroy(); }
});
