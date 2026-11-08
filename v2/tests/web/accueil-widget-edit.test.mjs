import { test, eq, ok } from './harness.mjs';
import { createBoard } from '../../web/js/pages/accueil/board.js';
import { closeMenus } from '../../web/js/kit/menu.js';
import { sectionsOf, placeWidget, moveSection, renameSection } from '../../web/js/pages/accueil/board-organization.js';

const settle = async () => { for (let n = 0; n < 24; n++) await Promise.resolve(); };
const menuItem = (menu, label) => [...menu.querySelectorAll('[role="menuitem"]')].find(el => el.textContent.includes(label));

test('Accueil : crayon toujours accessible et édition de la requête exacte sans ouvrir la carte', async () => {
  for (const bound of [true, false]) {
    const host = document.createElement('div'); document.body.append(host);
    const calls = []; const navigations = [];
    const item = { id: 'my-widget', source: 'query', key: 'widget-link', visual: 'Kpi', size: 'S', title: 'Mes XTS 128', paused: false, group: 'Requêtes',
      ...(bound ? { queryBinding: { recipeId: 'actual-query', revision: 2 } } : {}) };
    const ctx = { toast() {}, navigate: (...args) => navigations.push(args), pulse: { every() { return () => {}; } }, async call(op) {
      calls.push(op);
      if (op === 'accueil.layout') return { items: [item], valid: true, customized: true, max: 64, choiceToken: 'initial', history: [] };
      if (op === 'accueil.board') return { population: {}, computedAt: '2026-10-28T12:00:00Z', hints: [], entries: {
        'query:widget-link': { key: 'query:widget-link', title: item.title, kind: 'value', value: '12', number: 12, measured: true, items: [], timeline: [], sources: ['AD', 'WMI'] },
      } };
      if (op === 'requetes.widget.list') return [{ id: 'widget-link', board: 'fleet', recipeId: 'actual-query' }];
      throw new Error(`Appel inattendu ${op}`);
    } };
    const api = createBoard(host, { ctx, onTool() {}, onAction() {}, onTargets() {} });
    let menu;
    try {
      await api.load();
      eq([...host.querySelectorAll('.fw-source')].map(el => el.textContent), ['AD', 'WMI'], 'sources exactes du moteur affichées discrètement');
      ok(!api.editing(), 'pas besoin d’activer le mode de disposition pour modifier un widget');
      const edit = host.querySelector('[data-cmd="edit"]');
      ok(edit.textContent.includes('Modifier l’accueil'), 'entrée de personnalisation nommée clairement');
      ok(host.querySelector('[data-cmd="catalog"]'), 'ajout de widget accessible directement');
      edit.click(); ok(api.editing(), 'mode de déplacement accessible');
      ok(host.querySelector('[data-cmd="edit"]').textContent.includes('Terminer'), 'sortie explicite');
      host.querySelector('[data-cmd="edit"]').click(); ok(!api.editing(), 'sortie du mode de disposition');
      host.querySelector('article').click(); eq(navigations.length, 0, 'le corps du widget garde sa fonction');
      const pencil = host.querySelector('[data-fw-menu]');
      eq(pencil.getAttribute('aria-label'), 'Modifier le widget Mes XTS 128', 'nom clair pour le clavier et le lecteur d’écran');
      eq(pencil.dataset.tip, 'Modifier le widget', 'aide explicite');
      pencil.focus(); ok(document.activeElement === pencil, 'contrôle natif accessible au clavier');
      pencil.click(); await settle();
      menu = document.getElementById(pencil.getAttribute('aria-controls')) ?? [...document.querySelectorAll('[role="menu"]')].at(-1);
      ok(menuItem(menu, 'Renommer') && menuItem(menu, 'Retirer du tableau') && menuItem(menu, 'Mettre en pause'), 'fonctions existantes conservées');
      ok(menu.textContent.includes('Représentation') && menu.textContent.includes('Largeur') && menu.textContent.includes('Hauteur'), 'représentation et dimensions restent accessibles');
      menu.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true }));
      eq(pencil.getAttribute('aria-expanded'), 'false', 'Échap ferme le menu');
      ok(document.activeElement === pencil, 'retour du focus au crayon');
      menu.remove(); pencil.click();
      menu = [...document.querySelectorAll('[role="menu"]')].at(-1);
      menuItem(menu, 'Modifier la requête').click(); await new Promise(requestAnimationFrame); await settle();
      eq(navigations, [['requetes', { recette: 'actual-query', onglet: 'creer' }]], 'la requête est ouverte, jamais la clé du widget ni un brouillon vide');
      eq(calls.filter(c => c === 'requetes.widget.list').length, bound ? 0 : 1, 'liaison explicite réutilisée, lien historique résolu localement');
      ok(!calls.some(c => c.includes('refresh') || c.includes('collect') || c.includes('save')), 'modifier ne lance ni collecte ni écriture');
    } finally { closeMenus(); menu?.remove(); api.destroy(); host.remove(); }
  }
});

test('Accueil : organisation pure conserve toutes les cartes, leur liaison et les sections sans doublon', () => {
  const binding = { recipeId: 'recipe', revision: 7, fingerprint: 'f'.repeat(64) };
  const items = [{ id: 'a', group: 'A', size: 'S' }, { id: 'q', group: 'A', source: 'query', queryBinding: binding, paused: true, height: 'L', hidden: true }, { id: 'b', group: 'B', size: 'L' }];
  const moved = placeWidget(items, 'q', 'B', 'b');
  eq(moved.map(i => [i.id, i.group]), [['a', 'A'], ['q', 'B'], ['b', 'B']], 'placement exact avant une carte de la destination');
  eq(moved[1], { ...items[1], group: 'B' }, 'aucun attribut perdu');
  const newSection = placeWidget(moved, 'a', 'Nouvelle');
  eq(sectionsOf(newSection).map(g => g.name), ['B', 'Nouvelle'], 'une section sans carte disparaît et la nouvelle arrive en dernier');
  const ordered = moveSection(newSection, 'Nouvelle', -1);
  eq(ordered.map(i => i.id), ['a', 'q', 'b'], 'section déplacée avec toutes ses cartes');
  eq(renameSection(ordered, 'Nouvelle', 'Perso').map(i => i.group), ['Perso', 'B', 'B'], 'renommage sans changement d’ordre');
  eq(renameSection(ordered, 'Nouvelle', 'B'), ordered, 'pas de fusion implicite sous un nom déjà présent');
  eq(items[1].group, 'A', 'document initial intact pour Annuler');
});

test('Accueil : sections, dimensions et masquage sont enregistrés, annulables et ne collectent rien', async () => {
  const host = document.createElement('div'); host.className = 'board'; host.dataset.page = 'accueil'; document.body.append(host);
  const binding = { recipeId: 'recipe', revision: 2, fingerprint: 'a'.repeat(64) };
  let view = { items: [
    { id: 'a', source: 'builtin', key: 'fleet.machines', title: 'Parc', group: 'A', size: 'S', visual: 'Kpi', paused: false },
    { id: 'q', source: 'query', key: 'link', title: 'XTS 128', group: 'A', size: 'M', visual: 'Kpi', paused: false, queryBinding: binding },
    { id: 'b', source: 'builtin', key: 'fleet.lastcheck', title: 'Présence', group: 'B', size: 'M', visual: 'Text', paused: false },
  ], valid: true, customized: true, choiceToken: 'initial', history: [], max: 64 };
  let serial = 0; const calls = [];
  const ctx = { toast() {}, pulse: { every() { return () => {}; } }, async call(op, args) {
    calls.push({ op, args });
    if (op === 'accueil.layout') return view;
    if (op === 'accueil.layout.save') {
      eq(args.expectedChoiceToken, view.choiceToken, 'chaque édition est liée au dernier choix confirmé');
      view = { ...view, items: args.items, choiceToken: `saved-${++serial}` }; return view;
    }
    if (op === 'accueil.board') return { population: {}, hints: [], entries: {}, computedAt: '2026-10-28T12:00:00Z' };
    throw new Error(`Appel inattendu ${op}`);
  } };
  const api = createBoard(host, { ctx, onTool() {}, onTargets() {}, onAction() {} });
  const lastMenu = () => [...document.querySelectorAll('[role="menu"]')].at(-1);
  const choose = async label => { const menu = lastMenu(); const item = menuItem(menu, label); ok(item, `action ${label} présente`); item.click(); await new Promise(requestAnimationFrame); await settle(); };
  const widgetMenu = id => host.querySelector(`[data-item="${id}"] [data-fw-menu]`).click();
  const sectionMenu = name => [...host.querySelectorAll('[data-group]')].find(el => el.dataset.group === name).querySelector('[data-fw-section]').click();
  try {
    await api.load(); api.setEditing(true);
    sectionMenu('A'); await choose('Renommer la section');
    let dialog = [...document.querySelectorAll('.k-dlg')].at(-1);
    dialog.querySelector('[name="section"]').value = 'Opérations'; dialog.querySelector('[data-id="save"]').click(); await settle();
    eq(sectionsOf(view.items).map(g => g.name), ['Opérations', 'B'], 'section renommée dans le vrai document');
    sectionMenu('B'); await choose('Monter la section');
    eq(sectionsOf(view.items).map(g => g.name), ['B', 'Opérations'], 'ordre sections persisté');
    widgetMenu('q'); await choose('Déplacer vers une section'); await choose('B');
    eq(view.items.map(i => [i.id, i.group]), [['b', 'B'], ['q', 'B'], ['a', 'Opérations']], 'carte de requête déplacée sans duplicata');
    widgetMenu('q'); await choose('Largeur');
    lastMenu().querySelectorAll('[role="menuitemradio"]')[2].click(); await new Promise(requestAnimationFrame); await settle();
    widgetMenu('q'); await choose('Hauteur');
    lastMenu().querySelectorAll('[role="menuitemradio"]')[3].click(); await new Promise(requestAnimationFrame); await settle();
    eq(view.items.find(i => i.id === 'q').size, 'L', 'largeur conservée'); eq(view.items.find(i => i.id === 'q').height, 'L', 'hauteur indépendante conservée');
    widgetMenu('q'); await choose('Masquer le widget');
    eq(view.items.find(i => i.id === 'q').paused, false, 'masquer ne suspend pas les mesures');
    api.setEditing(false); ok(!host.querySelector('[data-item="q"]'), 'masqué dans la vue normale');
    api.setEditing(true); ok(host.querySelector('[data-item="q"]').classList.contains('is-hidden'), 'retrouvable en édition');
    sectionMenu('B'); await choose('Masquer la section');
    api.setEditing(false); ok(![...host.querySelectorAll('[data-group]')].some(el => el.dataset.group === 'B'), 'section entière masquée');
    api.setEditing(true); sectionMenu('B'); await choose('Afficher la section');
    widgetMenu('a'); await choose('Déplacer vers une section'); await choose('Nouvelle section');
    dialog = [...document.querySelectorAll('.k-dlg')].at(-1);
    dialog.querySelector('[name="section"]').value = 'Personnel'; dialog.querySelector('[data-id="save"]').click(); await settle();
    eq(sectionsOf(view.items).map(g => g.name), ['B', 'Personnel'], 'création d’une section avec le widget choisi');
    host.querySelector('[data-cmd="undo"]').click(); await settle();
    eq(sectionsOf(view.items).map(g => g.name), ['B', 'Opérations'], 'annulation retrouve le nom et l’ordre antérieurs');
    host.querySelector('[data-cmd="redo"]').click(); await settle();
    eq(sectionsOf(view.items).map(g => g.name), ['B', 'Personnel'], 'rétablissement exact');
    eq(view.items.find(i => i.id === 'q').queryBinding, binding, 'requête liée inchangée après tous les gestes');
    ok(calls.every(c => ['accueil.layout', 'accueil.board', 'accueil.layout.save'].includes(c.op)), 'aucun geste de présentation ne lance une collecte');
  } finally { closeMenus(); document.querySelector('.k-dlg [data-id="cancel"]')?.click(); api.destroy(); host.remove(); }
});
