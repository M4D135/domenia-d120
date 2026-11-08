import { test, eq, ok } from './harness.mjs';
import { createGrid } from '../../web/js/kit/grid.js';
import { createTabs } from '../../web/js/kit/tabs.js';
import { presentationTabs, bindPresentation } from '../../web/js/kit/presentation.js';
import { installGuiPolicy } from '../../web/js/shell/gui-policy.js';
import { renderDiagnostic } from '../../web/js/pages/poste/diagnostic.js';
import { createResults } from '../../web/js/pages/rechercher/results.js';
import { paintLocalAssistant } from '../../web/js/shell/local-assistant.js';
import { readLayout, writeLayout } from '../../web/js/kit/util.js';
import { createBar } from '../../web/js/pages/rechercher/bar.js';
import { analyse } from '../../web/js/pages/rechercher/text.js';

const settle = async () => { await Promise.resolve(); await new Promise(requestAnimationFrame); };
function context(expert = false) {
  let value = { expert, guiPolicy: [] }; const listeners = new Set();
  return { presentation: { get: () => value, on(fn) { listeners.add(fn); return () => listeners.delete(fn); } },
    update(patch) { value = { ...value, ...patch }; for (const fn of listeners) fn(); }, listeners };
}
function host() { const el = document.createElement('div'); el.style.width = '1000px'; document.body.append(el); return el; }

test('Profils : onglet technique initial masqué, retour sans relire ni perdre la saisie, nettoyages complets', () => {
  const el = host(), ctx = context(), mounted = [];
  const off = bindPresentation(el, ctx);
  const tabs = presentationTabs(el, ctx, { label: 'Fiche', selected: 'tech', tabs: [
    { id: 'general', label: 'Général', render(p) { mounted.push('general'); p.innerHTML = '<input value="Brouillon">'; } },
    { id: 'tech', label: 'Technique', expert: true, render(p) { mounted.push('tech'); p.textContent = 'Détails déjà lus'; } },
  ] });
  try {
    eq(tabs.current(), 'general', 'adresse technique remplacée par le premier onglet utilisable');
    eq(mounted, ['general'], 'aucun montage masqué');
    const input = el.querySelector('input'); input.value = 'Modification en cours';
    ctx.update({ expert: true }); tabs.select('tech'); eq(mounted, ['general', 'tech'], 'ouverture explicite unique');
    ctx.update({ expert: false }); eq(tabs.current(), 'general', 'repli immédiat du panneau technique');
    ok(tabs.panel('tech').hidden, 'contenu réellement masqué'); eq(input.value, 'Modification en cours', 'brouillon conservé');
    ctx.update({ expert: true }); tabs.select('tech'); eq(mounted.length, 2, 'aucune relecture ni remonte au retour');
    eq(el.dataset.profile, 'expert', 'décorations suivent la même préférence');
  } finally { tabs.destroy(); off(); el.remove(); }
  eq(ctx.listeners.size, 0, 'aucun abonnement orphelin');
});

test('Onglets : politique arrivée tardivement retire le panneau sélectionné et toute sélection clavier interdite', async () => {
  const el = host(); el.className = 'fi-page';
  const tabs = createTabs(el, { label: 'Fiche', selected: 'droits', tabs: ['general', 'droits'].map(id => ({ id, label: id, render: p => { p.textContent = id; } })) });
  const policy = installGuiPolicy(el, () => [{ element: 'TabFicheRights', policy: 'Hidden', valid: true, text: 'Vue restreinte' }]);
  try {
    await settle(); eq(tabs.current(), 'general', 'panneau de repli'); ok(tabs.panel('droits').hidden, 'aucun contenu interdit laissé visible');
    tabs.select('droits'); eq(tabs.current(), 'general', 'appel programmatique refusé aussi');
    const first = el.querySelector('[data-tab="general"]'); first.focus(); first.dispatchEvent(new KeyboardEvent('keydown', { key: 'End', bubbles: true }));
    eq(tabs.current(), 'general', 'navigation ignore onglets cachés');
    first.hidden = true; await settle(); eq(tabs.current(), undefined, 'aucun onglet disponible');
    ok(tabs.panel('general').hidden, 'aucun ancien panneau reste visible');
    first.hidden = false; await settle(); eq(tabs.current(), 'general', 'repli rétabli sans monter de nouveau contenu');
  } finally { policy.dispose(); tabs.destroy(); el.remove(); }
});

test('Colonnes techniques : restriction temporaire sans changer ordre, lignes ou préférence du tableau', () => {
  const el = host(); const grid = createGrid(el, { label: 'Base', key: 'test.presentation.columns', columns: [
    { id: 'name', label: 'Nom', required: true }, { id: 'score', label: 'Score', type: 'number' },
  ], rows: [{ id: '1', name: 'PC1', score: 100 }] });
  try {
    const before = grid.toCsv({ scope: 'visible' }); ok(before.includes('Score'), 'colonne initiale');
    grid.restrictColumns(['score']); const simple = grid.toCsv({ scope: 'visible' });
    ok(!simple.includes('Score') && simple.includes('PC1'), 'projection simple, lignes conservées');
    grid.restrictColumns([]); eq(grid.toCsv({ scope: 'visible' }), before, 'préférence initiale retrouvée intacte');
  } finally { grid.destroy(); el.remove(); }
});

test('Colonnes techniques : filtre en sommeil puis restauré après retour Expert et actualisation des lignes', () => {
  const el = host(), events = []; const columns = [
    { id: 'name', label: 'Nom', required: true }, { id: 'score', label: 'Score', type: 'number' },
  ];
  const rows = [{ id: '1', name: 'PC1', score: 100 }, { id: '2', name: 'PC2', score: 20 }];
  const grid = createGrid(el, { label: 'Filtres', columns, rows, onFilterChange: e => events.push(e) });
  try {
    grid.setColumnFilter('score', '>50');
    ok(grid.toCsv({ scope: 'visible' }).includes('PC1') && !grid.toCsv({ scope: 'visible' }).includes('PC2'), 'filtre réellement appliqué');
    grid.restrictColumns(['score']);
    ok(grid.toCsv({ scope: 'visible' }).includes('PC2'), 'filtre invisible suspendu');
    eq(events.at(-1).columns, {}, 'aucun filtre technique présenté comme actif');
    grid.setRows([...rows, { id: '3', name: 'PC3', score: 80 }], { columns });
    ok(grid.toCsv({ scope: 'visible' }).includes('PC2'), 'actualisation respecte la restriction');
    grid.restrictColumns([]);
    const restored = grid.toCsv({ scope: 'visible' });
    ok(restored.includes('PC1') && restored.includes('PC3') && !restored.includes('PC2'), 'filtre restauré sur les nouvelles lignes');
    eq(events.at(-1).columns, { score: '>50' }, 'saisie initiale retrouvée');
    grid.restrictColumns(['score']); grid.clearFilters(); grid.restrictColumns([]);
    ok(grid.toCsv({ scope: 'visible' }).includes('PC2'), 'effacer tous les filtres efface aussi ceux en sommeil');
  } finally { grid.destroy(); el.remove(); }
});

test('Poste réel : WMI caché en Essentiel, ouvert une seule fois en Expert puis panneau fermé au retour', async () => {
  const el = host(), ctx = context(), calls = [];
  const destroy = renderDiagnostic(el, { ctx, initialTab: 'wmi', dn: 'CN=PC1,DC=test', on: () => () => {},
    async call(op) { calls.push(op); if (op === 'poste.detail.cached') return { display: null, notice: 'Aucun cache' }; throw new Error(op); } });
  try {
    await settle(); eq(calls, [], 'le diagnostic réseau de repli ne collecte rien');
    const wmi = el.querySelector('[data-tab="wmi"]'); ok(wmi.hidden, 'outil technique caché');
    ctx.update({ expert: true }); wmi.click(); await settle(); eq(calls, ['poste.detail.cached'], 'seul le relevé local est ouvert');
    ctx.update({ expert: false }); await settle(); ok(wmi.hidden, 'onglet caché à nouveau');
    eq(el.querySelector('[aria-selected="true"]').dataset.tab, 'reseau', 'repli réel');
    eq(calls.length, 1, 'aucun contact natif ajouté');
  } finally { destroy(); el.remove(); }
});

test('Réglage des profils de colonnes : choix désactivé sans effacer le profil personnel', () => {
  const el = host(), ctx = context(); const saved = readLayout('rechercher.results');
  writeLayout('rechercher.results', { set: 'computers' }); ctx.update({ columnProfiles: false });
  const panel = createResults(el, ctx, new Proxy({}, { get: () => () => [] }));
  try {
    eq(panel.set, 'mixed', 'profil neutre quand le commutateur est arrêté'); ok(el.querySelector('.rch-sets').hidden, 'choix masqué');
    el.querySelector('[data-set="users"]').click(); eq(panel.set, 'mixed', 'clic forcé sans effet');
    eq(readLayout('rechercher.results'), { set: 'computers' }, 'préférence précédente intacte');
    ctx.update({ columnProfiles: true }); eq(panel.set, 'computers', 'préférence restaurée quand autorisée');
    ok(!el.querySelector('.rch-sets').hidden, 'choix disponible');
  } finally { panel.destroy(); writeLayout('rechercher.results', saved); el.remove(); }
});

test('Assistant local : désactivé par défaut, suggestions adaptées et ouverture d’aide seulement sur geste', () => {
  const el = host(), queries = [];
  try {
    paintLocalAssistant(el, { page: { id: 'accueil' } }, q => queries.push(q)); ok(el.hidden, 'absent par défaut');
    paintLocalAssistant(el, { policy: { localAssistant: true }, page: { id: 'requetes' } }, q => queries.push(q));
    eq(queries, [], 'aucune recherche automatique'); ok(el.textContent.includes('requête prête'), 'guidage de l’Atelier');
    el.querySelector('button').click(); eq(queries, ['bibliothèque'], 'seule une recherche dans l’aide est demandée');
    paintLocalAssistant(el, { policy: { localAssistant: true }, reach: { offline: true } }, q => queries.push(q));
    ok(el.textContent.includes('données conservées'), 'l’indisponibilité privilégie les informations locales');
    paintLocalAssistant(el, { policy: { localAssistant: false } }, q => queries.push(q)); ok(el.hidden && !el.children.length, 'arrêt appliqué immédiatement');
  } finally { el.remove(); }
});

test('Syntaxe désactivée : la vraie barre annonce du texte simple et conserve la saisie envoyée', () => {
  const el = host(), submitted = [];
  const bar = createBar(el, { syntaxEnabled: false, getRecents: () => [], onSuggest: async () => [], onSubmit: request => submitted.push(request) });
  try {
    const value = 'poste: PC001'; bar.setText(value);
    ok(el.textContent.includes('Syntaxe avancée désactivée'), 'prévisualisation raccordée au commutateur');
    el.querySelector('form').dispatchEvent(new SubmitEvent('submit', { bubbles: true, cancelable: true }));
    eq(submitted.length, 1, 'un geste explicite'); eq(submitted[0].text, value, 'ni suppression ni interprétation locale du préfixe');
    eq(analyse(value, { syntaxEnabled: false }).kind, 'default', 'aucun jeton appliqué');
    eq(analyse('550e8400-e29b-41d4-a716-446655440000', { syntaxEnabled: false }).kind, 'default', 'identifiant avancé également désactivé comme dans le moteur');
    eq(analyse('192.0.2.8', { syntaxEnabled: false }).kind, 'address', 'adresses locales restent qualifiées');
    eq(analyse(value).kind, 'syntax', 'comportement par défaut conservé');
  } finally { bar.destroy(); el.remove(); }
});
