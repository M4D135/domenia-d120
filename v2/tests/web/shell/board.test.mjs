// Pure layout rules of the boards (web/js/shell/board.js; TRV-306 to TRV-313, TRV-293, TRV-294).
import { test, eq, ok } from '../harness.mjs';
import {
  cleanLayout, moveItem, moveGroup, presetLayout, readLayoutDocument, readStored, layoutChange, layoutDocument, widgetText,
  boardSummary, keyGesture, nextSize, searchTerms, matchesCatalog, addItem, updateItem, FORMAT,
  activeItems, columnsFor, placeholderOf, hasMeasure, PAUSE_TEXT, visualsFor, allowedVisuals,
} from '../../../web/js/shell/board.js';

const CATALOG = [
  { key: 'disk.free', title: 'Espace disque', visuals: ['bars', 'donut'], size: 'M', group: 'Santé', keywords: 'stockage', origin: 'builtin' },
  { key: 'ram', title: 'Mémoire', visuals: ['kpi', 'gauge'], group: 'Santé' },
  { key: 'uptime', title: 'En service depuis', visuals: ['kpi'], group: 'Poste', origin: 'probe' },
];

test('cleanLayout corrige, déduplique et traduit les clés de Domenia 1', () => {
  const layout = cleanLayout([
    { Key: 'disk.free', Visual: 'PIE', Size: 'XL', Id: 'a' },
    { key: 'inconnu' },
    { key: 'ram', id: 'a' },
    { Key: 'Uptime', Group: 'Ailleurs' },
  ], CATALOG, 'w', { Uptime: 'uptime' });
  eq(layout.map((i) => i.key), ['disk.free', 'ram', 'uptime'], 'widgets connus seulement, clé de Domenia 1 traduite');
  eq(layout[0].visual, 'bars', 'représentation corrigée');
  eq(layout[0].size, 'M', 'taille corrigée');
  ok(layout[1].id !== 'a', 'identifiant unique');
  eq(layout[2].group, 'Ailleurs', 'section gardée');
});

test('déplacements dans la section, sur un autre widget, sections entières', () => {
  const base = cleanLayout([{ key: 'disk.free', id: 'd' }, { key: 'ram', id: 'r' }, { key: 'uptime', id: 'u' }], CATALOG);
  eq(moveItem(base, 'r', { step: 'back' }).map((i) => i.id), ['r', 'd', 'u'], 'vers la gauche');
  eq(moveItem(base, 'd', { step: 'back' }), base, 'déjà premier : inchangé');
  const onto = moveItem(base, 'u', { onto: 'd' });
  eq(onto[0].id, 'u', 'prend la place du widget visé');
  eq(onto[0].group, 'Santé', 'rejoint sa section');
  eq(moveGroup(base, 'Poste', 'up').map((i) => i.group), ['Poste', 'Santé', 'Santé'], 'section remontée');
  eq(nextSize('L', 1), 'L', 'taille bornée');
  eq(addItem(base, { id: 'n', key: 'ram', group: 'Santé' }).map((i) => i.id), ['d', 'r', 'n', 'u'], 'ajout en fin de section');
  eq(updateItem(base, 'd', { group: 'Poste' }).map((i) => i.id), ['r', 'u', 'd'], 'changement de section : fin de la nouvelle section');
});

test('disposition prête : ses widgets d’abord, rien de retiré', () => {
  const base = cleanLayout([{ key: 'uptime', id: 'u' }], CATALOG);
  const next = presetLayout(base, ['ram'], CATALOG);
  eq(next.map((i) => i.key), ['ram', 'uptime'], 'widget ajouté en tête, l’existant gardé');
});

test('import : le tableau répond à son nom d’équipe et à son identifiant', () => {
  const doc = JSON.stringify(layoutDocument('Computer', cleanLayout([{ key: 'ram' }], CATALOG)));
  ok(readLayoutDocument(['Computer', 'poste'], doc).valid, 'nom d’équipe accepté');
  ok(readLayoutDocument(['Computer', 'poste'], JSON.stringify({ Format: FORMAT, Board: 'poste', Layout: [{ Key: 'ram' }] })).valid, 'identifiant accepté');
  eq(readLayoutDocument('poste', JSON.stringify({ Format: FORMAT, Board: 'Fleet', Layout: [{ Key: 'ram' }] })).valid, false, 'autre tableau refusé');
  eq(readLayoutDocument('poste', '{').reason, 'Texte JSON illisible.', 'JSON cassé');
  eq(readLayoutDocument('poste', '[]').valid, false, 'aucun widget');
});

test('disposition enregistrée : document versionné, liste de la version 1, tableau vidé', () => {
  const stored = readStored({ format: 'Domenia.BoardDocument.2', layout: [{ key: 'ram' }], history: [1, 2, 3, 4, 5, 6] }, CATALOG);
  eq(stored.layout.length, 1, 'disposition');
  eq(stored.history.length, 5, 'cinq versions au plus');
  eq(readStored([], CATALOG).layout, [], '« [] » reste vide');
  eq(readStored(undefined, CATALOG), null, 'rien d’enregistré');
});

test('changement de disposition : ajouts et retraits pour suspendre les collectes', () => {
  const change = layoutChange([{ key: 'ram' }, { key: 'uptime' }], [{ key: 'ram' }, { key: 'disk.free' }]);
  eq(change.added, ['disk.free'], 'ajouté');
  eq(change.removed, ['uptime'], 'retiré');
});

test('copie d’un widget : rien pour un widget vide ou suspendu, 20 lignes au plus', () => {
  eq(widgetText('Mémoire', null), '', 'sans données : rien');
  eq(widgetText('Mémoire', { kind: 'number', paused: true, value: 3 }), '', 'suspendu : rien');
  eq(widgetText('Liste', { kind: 'list', items: [] }), '', 'liste vide : rien');
  const many = widgetText('Disques', { kind: 'distribution', value: 30, items: Array.from({ length: 25 }, (_, i) => ({ label: `D${i}`, value: 1 })) });
  ok(many.includes('et 5 autres'), '« et N autres »');
  ok(!widgetText('Note', { value: 'password=Secret42' }).includes('Secret42'), 'secret masqué');
  const health = widgetText('Santé', { kind: 'score', number: 82, verdict: 'Quelques points à vérifier', items: [{ level: 'warn', text: 'Point', detail: 'Apparence' }] });
  ok(health.includes('Santé : 82') && health.includes('Quelques points à vérifier') && health.includes('(Apparence)'), 'carte santé copiée');
  ok(boardSummary('Tableau', [{ title: 'Mémoire', entry: { value: 3 } }], 'markdown').startsWith('# Tableau'), 'résumé Markdown');
});

test('gestes du clavier d’un widget', () => {
  eq(keyGesture({ key: 'ArrowLeft', altKey: true }, true), { action: 'move', value: 'back' }, 'Alt ←');
  eq(keyGesture({ key: 'ArrowLeft', altKey: true }, false), null, 'hors personnalisation : rien');
  eq(keyGesture({ key: 'c', ctrlKey: true }, false), { action: 'copy' }, 'Ctrl C');
  eq(keyGesture({ key: 'F10', shiftKey: true }, false), { action: 'menu' }, 'Maj F10');
});

test('recherche du catalogue avec synonymes et filtre d’origine', () => {
  ok(matchesCatalog(CATALOG[0], searchTerms('ssd')), 'ssd trouve le disque');
  ok(matchesCatalog(CATALOG[2], searchTerms('uptime')), 'uptime trouve « en service »');
  eq(matchesCatalog(CATALOG[0], searchTerms(''), { origin: 'probe' }), false, 'origine filtrée');
  ok(matchesCatalog(CATALOG[1], searchTerms(''), { origin: 'builtin' }), 'origine par défaut : intégrée');
});

test('colonnes du tableau : paliers de Domenia 1 et 24 px d’hystérésis (TRV-315)', () => {
  eq([1300, 1100, 1099, 780, 779, 440, 439, 200].map((w) => columnsFor(w)), [4, 4, 3, 3, 2, 2, 1, 1], 'paliers 1 100, 780, 440');
  eq(columnsFor(1090, 4), 4, 'à moins de 24 px du palier, le nombre en cours est gardé');
  eq(columnsFor(1070, 4), 3, 'au-delà de 24 px, le palier est franchi');
  eq(columnsFor(1110, 3), 3, 'en montant aussi');
  eq(columnsFor(500, 4), 2, 'un saut de deux paliers ne garde rien');
  eq(columnsFor(Number.NaN, 2), 1, 'largeur illisible : une colonne');
});

test('mesure suspendue : place gardée, sortie des collectes, réversible (TRV-288)', () => {
  const base = cleanLayout([{ key: 'disk.free', id: 'd', Paused: true }, { key: 'ram', id: 'r' }], CATALOG);
  eq(base[0].paused, true, 'Paused de Domenia 1 relu');
  eq(activeItems(base).map((i) => i.key), ['ram'], 'le widget suspendu ne compte plus parmi les mesures');
  const resumed = updateItem(base, 'd', { paused: undefined });
  eq(layoutChange(base, resumed), { keys: ['disk.free', 'ram'], added: ['disk.free'], removed: [] }, 'reprendre rend la clé aux collectes');
  eq(layoutChange(resumed, base).removed, ['disk.free'], 'suspendre la retire');
  eq(layoutDocument('poste', base).Layout[0].Paused, true, 'export : la suspension voyage avec la disposition');
  eq(widgetText('Espace disque', { paused: true, value: 3 }), '', 'rien à copier d’un widget suspendu');
});

test('place compacte d’un widget sans chiffre, jamais une mesure (TRV-314)', () => {
  eq(placeholderOf({ paused: true }).action, 'resume', 'suspendu : Reprendre la mesure');
  eq(placeholderOf({ paused: true }).message, PAUSE_TEXT, 'texte de la suspension par défaut');
  eq(placeholderOf({ entry: { collecting: 'Collecte 3/12' } }), { state: 'collecting', message: 'Collecte 3/12', action: '', actionText: '' }, 'en collecte, sans bouton');
  eq(placeholderOf({ entry: undefined, loaded: false }), null, 'première lecture en cours : le squelette le dit');
  eq(placeholderOf({ entry: undefined, loaded: true }).actionText, 'Collecter', 'jamais collecté');
  eq(placeholderOf({ entry: undefined, loaded: true, item: { need: 'local' } }).actionText, 'Recalculer', 'calcul local');
  eq(placeholderOf({ entry: { collected: true }, loaded: true, item: { fleet: true } }).actionText, 'Actualiser', 'absent du dernier calcul du parc');
  eq(placeholderOf({ entry: { collected: true }, loaded: true }).actionText, 'Relire', 'absent du dernier relevé du poste');
  eq(placeholderOf({ entry: { value: 0 }, loaded: true }), null, 'zéro est une mesure');
  eq(placeholderOf({ entry: { value: null }, loaded: true }), null, 'non mesuré : le dessin écrit « — »');
  ok(hasMeasure({ items: [{ label: 'a', value: 1 }] }) && !hasMeasure({ placeholder: { message: 'x' } }), 'liste = mesure, place = pas de mesure');
});

test('représentations autorisées par type de donnée (TRV-286)', () => {
  eq(visualsFor('Timeline'), ['line', 'columns', 'text'], 'la courbe seulement pour des valeurs datées');
  ok(!visualsFor('Distribution').includes('line'), 'une répartition n’est pas une ligne de temps');
  eq(visualsFor('Number', true)[0], 'gauge', 'jauge pour un nombre avec maximum');
  ok(!visualsFor('Number').includes('gauge'), 'pas de jauge sans maximum');
  eq(allowedVisuals({ dataKind: 'Health' }), ['health', 'score', 'kpi'], 'carte santé d’abord');
  eq(allowedVisuals({ visuals: ['bars', 'inconnu'] }), ['bars'], 'liste du catalogue, représentations inconnues écartées');
  const layout = cleanLayout([{ key: 'trend', visual: 'line' }, { key: 'share', visual: 'line' }],
    [{ key: 'trend', title: 'Tendance', dataKind: 'Timeline', group: 'Parc' }, { key: 'share', title: 'Part', dataKind: 'Distribution', group: 'Parc' }]);
  eq(layout.map((i) => i.visual), ['line', 'donut'], 'une représentation devenue invalide est corrigée');
});
