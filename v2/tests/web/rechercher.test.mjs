// Tests of the pure rules of the Rechercher page (web/js/pages/rechercher/text.js, history.js), written with the code and
// run at the very end (decision of 21/10): `node tests/web/rechercher.test.mjs` from v2/, or by the WebView2 engine. The
// live analysis of the bar reads the vectors shared with the engine (tests/vectors/search-text.json, SearchTextVectorsTests):
// the page must never explain what the engine does not do. No dependency, no network.
import { test, assert, readTestFile } from './test-api.mjs';

// ui.js reads the document at load: a minimal stand-in is enough for these pure functions.
globalThis.document ??= { documentElement: { dataset: {}, style: { setProperty() {} } }, addEventListener() {}, querySelector() { return null; } };
globalThis.window ??= globalThis;
globalThis.matchMedia ??= () => ({ matches: false, addEventListener() {} });

const text = await import('../../web/js/pages/rechercher/text.js');
const { createHistory, placeKey, stepBranches, branchPlan } = await import('../../web/js/pages/rechercher/history.js');
const check = (condition, label) => assert.ok(condition, label);

test('Recherche : Live analysis of the bar: same verdicts as the engine', async () => {

const vectors = JSON.parse(await readTestFile('tests/vectors/search-text.json')).vectors;
const kindOf = (a) => (!a.valid ? 'invalid' : a.kind);
for (const v of vectors) {
  const a = text.analyse(v.text, { match: v.match });
  check(a.valid === v.valid, `validité de « ${v.text} »`);
  check(kindOf(a) === v.kind, `genre de « ${v.text} » : ${kindOf(a)} au lieu de ${v.kind}`);
}
// A word says what is done with it, never a bare « martin… » that reads like a cut text.
check(text.analyse('martin').chips.some((c) => c.label === 'commence par «\u00a0martin\u00a0»'), 'puce « commence par » avec espaces françaises insécables');
check(text.analyse('dufour', { match: 'contains' }).chips.some((c) => c.label === 'contient «\u00a0dufour\u00a0»'), 'puce « contient » avec espaces françaises insécables');
const syntax = text.parseSyntax('utilisateur: "Camille Martin" poste: PC-PAR inconnu: x libre');
check(syntax.tokens.length === 2 && syntax.tokens[0].value === 'Camille Martin', 'jetons et guillemets');
check(syntax.unknown.includes('inconnu') && syntax.free.includes('libre'), 'jeton inconnu cherché comme texte');
});

test('Recherche : Export: the association goes back to three columns, formulas stay neutralised', async () => {

const rows = [
  { association: { label: 'Camille Martin (cmartin)', source: 'Déclaré dans l’annuaire (managedBy)', qualification: 'Déclaré' } },
  { association: { label: '=cmd|calc', source: '+evil', qualification: '-x' } },
  { association: null },
];
const csv = '﻿Nom;Association mémorisée;État\r\nPC-1;Camille Martin (cmartin);Actif\r\nPC-2;\'=cmd|calc;Actif\r\nPC-3;;Actif';
const out = text.expandAssociationColumns(csv, rows).replace(/^﻿/, '').split('\r\n');
check(out[0] === 'Nom;Association mémorisée;Source lien;Qualification;État', 'en-têtes éclatés');
check(out[1] === 'PC-1;Camille Martin (cmartin);Déclaré dans l’annuaire (managedBy);Déclaré;Actif', 'association éclatée');
check(out[2].includes("'=cmd|calc") && out[2].includes("'+evil") && out[2].includes("'-x"), 'formules neutralisées');
check(out[3] === 'PC-3;;;;Actif', 'association absente');
check(!text.expandAssociationColumns(csv, rows).includes('␟'), 'aucun séparateur interne');
check(text.csvCell('=1+1') === "'=1+1" && text.csvCell('a;b') === '"a;b"', 'cellule CSV');
});

test('Recherche : Ticket lines: no GUID, no DN, secrets masked', async () => {

const ticket = text.ticketText([{ kind: 'user', name: 'Camille Martin', login: 'cmartin', dn: 'CN=Camille Martin,OU=Paris,OU=Utilisateurs,DC=example,DC=local', id: '0f8fad5b-d9cb-469f-a165-70867728950e' },
  { kind: 'computer', name: 'PC-PAR-0001 mot de passe: Secret123', dn: 'CN=PC-PAR-0001,OU=Paris,OU=Postes,DC=example,DC=local' }]);
check(!ticket.includes('0f8fad5b') && !ticket.includes('DC=example'), 'ni GUID ni DN');
check(ticket.includes('OU\u00A0: Utilisateurs / Paris'), 'OU lisible');
check(!ticket.includes('Secret123') && ticket.includes('••••••'), 'secret masqué');
check(text.maskSecrets('token=abc pwd: x') === 'token=•••••• pwd: ••••••', 'jetons masqués');
check(text.associatedAccount({ association: { label: 'Camille Martin (cmartin)' } }) === 'cmartin', 'compte associé');
});

test('Recherche : Texts: French typography of the visible sentences', async () => {

check(text.count(0, 'ligne', 'lignes') === '0 ligne' && text.count(2, 'ligne', 'lignes') === '2 lignes', 'singulier pour 0 et 1');
check(text.int(12000) === '12 000' && text.int(-3) === '−3', 'milliers et signe moins');
const empty = text.emptyState('noresult', { query: 'zzqxw', scope: 'Domaine entier', ou: true });
check(empty.actions.some((x) => x.id === 'everywhere') && empty.actions.some((x) => x.id === 'contains'), 'état vide avec actions suivantes');
check(text.emptyState('filter').actions[0].id === 'clearFilters', 'filtre trop étroit');
for (const s of [empty.title, empty.text, text.emptyState('partial').text, text.emptyState('refused').text]) check(!/ [:;!?%]/.test(s), `espace insécable : ${s}`);
});

test('Recherche : History: 40 places, no duplicate, exact steps', async () => {

const h = createHistory();
const place = (text2, n) => ({ request: { op: 'search.run', text: text2, type: 'all' }, result: { rows: Array.from({ length: n }, (_, k) => ({ id: String(k) })) }, label: text2, at: Date.now(), view: { selection: [] } });
check(h.push(place('martin', 3)) === true, 'première étape');
check(h.push(place('martin', 4)) === false, 'même lieu rafraîchi, jamais empilé');
h.push(place('dufour', 2));
h.push(place('PC-PAR', 1));
check(h.step('back').label === 'dufour' && h.canForward(), 'pas en arrière');
check(h.step('forward').label === 'PC-PAR', 'pas en avant');
check(h.jump(0).label === 'martin' && h.list().length === 3, 'saut à une étape');
for (let n = 0; n < 50; n++) h.push(place(`t${n}`, 1));
check(h.list().length === 41, '40 étapes en arrière au plus');
check(placeKey(place('a', 1)) !== placeKey({ ...place('a', 1), request: { op: 'search.run', text: 'a', type: 'users' } }), 'un autre type est un autre lieu');
});

test('Recherche : CSV of the selected rows that are shown (RCH-126): records split outside quotes', async () => {

const grid = '\uFEFFNom;Note\r\nPC-01;"deux\r\nlignes"\r\nPC-02;simple\r\n';
const records = text.csvRecords(grid);
check(records.length === 3, 'en-tête et deux enregistrements, même avec un saut de ligne dans une cellule');
check(records[1] === 'PC-01;"deux\r\nlignes"', 'cellule entre guillemets gardée entière');
check(records[0].startsWith('\uFEFF'), 'marque d’ordre des octets gardée sur l’en-tête');
check(text.selectionText(3, 3) === '3 postes sélectionnés', 'énoncé « 3 postes sélectionnés »');
check(text.selectionText(3, 1) === '3 lignes sélectionnées dont 1 poste', 'énoncé « 3 lignes sélectionnées dont 1 poste »');
});

test('Recherche : Export to a file: the engine receives the list subject, never a path or a DN', async () => {

check(text.exportSubject({ kind: 'browse', scope: { dn: 'OU=Paris,OU=Postes,DC=example,DC=local' } }) === 'Paris', 'branche : son nom');
check(text.exportSubject({ kind: 'browse', scope: { wholeDomain: true } }) === 'domaine', 'domaine entier');
check(text.exportSubject({ kind: 'search', text: 'martin' }) === 'recherche-martin', 'recherche : son texte');
check(text.exportSubject({ kind: 'address', text: 'PC-PAR-0001' }) === 'recherche-PC-PAR-0001', 'adresse : son texte');
check(text.exportSubject({ kind: 'view', view: { name: 'Postes inactifs' } }) === 'Postes inactifs', 'vue : son nom');
check(text.exportSubject({ kind: 'view' }) === 'requete' && text.exportSubject(null) === 'requete', 'sujet par défaut');
check(!text.exportSubject({ kind: 'browse', scope: { dn: 'OU=Paris,OU=Postes,DC=example,DC=local' } }).includes('DC='), 'aucun DN dans le nom');
});

test('Recherche : Tree of a history step (RCH-045): a branch read then folded stays folded when going back', async () => {

const root = 'DC=example,DC=local', postes = 'OU=Postes,' + root, paris = 'OU=Paris,' + postes, lyon = 'OU=Lyon,' + postes, gens = 'OU=Utilisateurs,' + root;
const reads = new Map([[root, 'ok'], [postes, 'ok'], [paris, 'ok'], [lyon, 'error'], [gens, 'ok']]);
const open = new Set([root, postes, gens]); // Paris read then folded by the operator; Lyon failed.
const step = stepBranches(reads, (id) => open.has(id));
check(step.length === 3 && !step.includes(paris), 'une branche lue puis repliée n’est pas gardée par l’étape');
check(!step.includes(lyon), 'une branche en erreur n’est pas gardée');
// Later on, the operator unfolded Paris and folded the users: going back puts the step's tree again, without any read.
const inTree = (id) => id !== gens;
const plan = branchPlan(step, reads, inTree, root);
check(plan.expand.includes(root) && plan.expand.includes(postes), 'les branches de l’étape lues et présentes sont rouvertes');
check(plan.collapse.length === 1 && plan.collapse[0] === paris, 'Paris, repliée à l’étape, est repliée ; la racine reste ouverte');
check(plan.missing === 1, 'une branche disparue de son parent est comptée');
check(branchPlan(['OU=Jamais lue,' + root], reads, () => true, root).missing === 1, 'une branche jamais lue est comptée, sans lecture');
check(branchPlan(null, new Map(), () => true, root).expand.length === 0, 'aucune étape : rien à rouvrir');
});

test('Recherche : Revalidation (RCH-048): new rows, changed rows, moved and absent objects, paced application', async () => {

const { reconcileEvents, applyPaced, EVENTS_PER_TICK, TICK_BUDGET_MS } = await import('../../web/js/pages/rechercher/reconcile.js');
const row = (id, extra = {}) => ({ id, dn: `CN=${id},OU=Paris,DC=example,DC=local`, name: id, login: id.toLowerCase(), state: { key: 'on', label: 'Actif' }, os: 'Windows 11', description: 'x', ...extra });
const before = [row('PC-1'), row('PC-2'), row('PC-3'), row('PC-4')];
const res = {
  rows: [row('PC-1'), row('PC-2', { description: 'Salle 12' }), row('PC-3', { dn: 'CN=PC-3,OU=Lyon,DC=example,DC=local' }), row('PC-9')],
  added: ['PC-9'], moved: ['PC-3'], missing: ['PC-4'],
};
const ev = reconcileEvents(before, res);
const kinds = ev.map((e) => `${e.kind}:${e.row?.id ?? e.id}`);
check(!kinds.includes('update:PC-1'), 'une ligne relue sans changement n’est pas repeinte');
check(kinds.includes('update:PC-2'), 'une ligne changée est repeinte');
check(kinds.includes('add:PC-9'), 'un objet nouveau est ajouté');
check(kinds.includes('update:PC-3') && ev.some((e) => e.kind === 'mark' && e.id === 'PC-3' && e.label === 'hors du périmètre relu'), 'un objet déplacé garde sa ligne par GUID, repeinte puis marquée');
check(ev.some((e) => e.kind === 'mark' && e.id === 'PC-4' && e.label === 'à revérifier'), 'un objet absent est marqué « à revérifier »');
check(!ev.some((e) => e.kind === 'remove'), 'rien n’est jamais retiré');
check(kinds.indexOf('mark:PC-3') > kinds.indexOf('update:PC-3'), 'le marquage suit la mise à jour de la ligne');
check(reconcileEvents(before, { rows: [row('PC-1')], added: ['PC-1'], moved: [], missing: [] }).length === 0, 'un objet « nouveau » déjà listé n’est pas dupliqué');
check(reconcileEvents(before, { rows: [], added: [], moved: [], missing: ['PC-77'] }).length === 0, 'un absent inconnu de la liste n’est pas marqué');
check(reconcileEvents(before, { rows: [row('PC-9')], added: [], moved: [], missing: [] })[0]?.kind === 'add', 'un ajout connu du moteur mais non appliqué avant arrêt est rattrapé par l’UI');
check(reconcileEvents(before, { rows: [row('PC-1', { description: 'modifiée' })], added: ['PC-1'] })[0]?.kind === 'update', 'un ajout déjà appliqué peut encore être actualisé sans doublon');

// Pacing: never more than 8 events per tick, and a tick stops once its 5 ms are spent.
check(EVENTS_PER_TICK === 8 && TICK_BUDGET_MS === 5, 'budget « au plus 8 événements par tic et 5 ms »');
const many = Array.from({ length: 20 }, (_, i) => ({ kind: 'update', row: row(`PC-${i}`) }));
const ticks = [0];
const done = await applyPaced(many, () => ticks[ticks.length - 1]++, { next: async () => { ticks.push(0); }, now: () => 0 });
check(done === 20 && ticks.join(',') === '8,8,4', `tranches de 8 au plus : ${ticks.join(',')}`);
let clock = 0;
const slow = [0];
await applyPaced(many.slice(0, 6), () => { clock += 6; slow[slow.length - 1]++; }, { next: async () => { slow.push(0); }, now: () => clock });
check(slow.join(',') === '1,1,1,1,1,1', 'le coût du rendu, pas celui de préparation, coupe le tic dès le premier événement lent');
let applied = 0;
const partial = await applyPaced(many, () => { applied++; }, { next: async () => {}, now: () => 0, stop: () => applied === 2 });
check(partial === 2, 'une liste remplacée arrête immédiatement les événements restants du même tic');
for (const invalid of [{ perTick: 0 }, { budgetMs: NaN }]) {
  let rejected = false;
  try { await applyPaced(many, () => {}, invalid); } catch (error) { rejected = error instanceof RangeError; }
  check(rejected, 'un budget invalide est refusé');
}

// A previously missing row becomes current again even when its directory attributes did not change.
const formerlyMissing = { id: 'reappears', name: 'PC', state: { key: 'active', label: 'Actif · à revérifier', tone: 'warn' } };
const returned = { ...formerlyMissing, state: { key: 'active', label: 'Actif', tone: 'ok' } };
check(reconcileEvents([formerlyMissing], { rows: [returned] })[0]?.kind === 'update', 'un objet retrouvé perd le marquage ancien');

});
