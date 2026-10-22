// Tests of the pure rules of the Rechercher page (web/js/pages/rechercher/text.js, history.js), written with the code and
// run at the very end (decision of 21/10): `node tests/web/rechercher.test.mjs` from v2/, or by the WebView2 engine. The
// live analysis of the bar reads the vectors shared with the engine (tests/vectors/search-text.json, SearchTextVectorsTests):
// the page must never explain what the engine does not do. No dependency, no network.
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

// ui.js reads the document at load: a minimal stand-in is enough for these pure functions.
globalThis.document ??= { documentElement: { dataset: {}, style: { setProperty() {} } }, addEventListener() {}, querySelector() { return null; } };
globalThis.window ??= globalThis;
globalThis.matchMedia ??= () => ({ matches: false, addEventListener() {} });

const here = dirname(fileURLToPath(import.meta.url));
const text = await import(join(here, '../../web/js/pages/rechercher/text.js'));
const { createHistory, placeKey } = await import(join(here, '../../web/js/pages/rechercher/history.js'));

let failed = 0;
let passed = 0;
function check(condition, label) {
  if (condition) passed++;
  else { failed++; console.error(`ÉCHEC : ${label}`); }
}

// ---------- Live analysis of the bar: same verdicts as the engine ----------

const vectors = JSON.parse(readFileSync(join(here, '../vectors/search-text.json'), 'utf8')).vectors;
const kindOf = (a) => (!a.valid ? 'invalid' : a.kind);
for (const v of vectors) {
  const a = text.analyse(v.text, { match: v.match });
  check(a.valid === v.valid, `validité de « ${v.text} »`);
  check(kindOf(a) === v.kind, `genre de « ${v.text} » : ${kindOf(a)} au lieu de ${v.kind}`);
}
// A word says what is done with it, never a bare « martin… » that reads like a cut text.
check(text.analyse('martin').chips.some((c) => c.label === 'commence par « martin »'), 'puce « commence par »');
check(text.analyse('dufour', { match: 'contains' }).chips.some((c) => c.label === 'contient « dufour »'), 'puce « contient »');
const syntax = text.parseSyntax('utilisateur: "Camille Martin" poste: PC-PAR inconnu: x libre');
check(syntax.tokens.length === 2 && syntax.tokens[0].value === 'Camille Martin', 'jetons et guillemets');
check(syntax.unknown.includes('inconnu') && syntax.free.includes('libre'), 'jeton inconnu cherché comme texte');

// ---------- Export: the association goes back to three columns, formulas stay neutralised ----------

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

// ---------- Ticket lines: no GUID, no DN, secrets masked ----------

const ticket = text.ticketText([{ kind: 'user', name: 'Camille Martin', login: 'cmartin', dn: 'CN=Camille Martin,OU=Paris,OU=Utilisateurs,DC=example,DC=local', id: '0f8fad5b-d9cb-469f-a165-70867728950e' },
  { kind: 'computer', name: 'PC-PAR-0001 mot de passe: Secret123', dn: 'CN=PC-PAR-0001,OU=Paris,OU=Postes,DC=example,DC=local' }]);
check(!ticket.includes('0f8fad5b') && !ticket.includes('DC=example'), 'ni GUID ni DN');
check(ticket.includes('OU\u00A0: Utilisateurs / Paris'), 'OU lisible');
check(!ticket.includes('Secret123') && ticket.includes('••••••'), 'secret masqué');
check(text.maskSecrets('token=abc pwd: x') === 'token=•••••• pwd: ••••••', 'jetons masqués');
check(text.associatedAccount({ association: { label: 'Camille Martin (cmartin)' } }) === 'cmartin', 'compte associé');

// ---------- Texts: French typography of the visible sentences ----------

check(text.count(0, 'ligne', 'lignes') === '0 ligne' && text.count(2, 'ligne', 'lignes') === '2 lignes', 'singulier pour 0 et 1');
check(text.int(12000) === '12 000' && text.int(-3) === '−3', 'milliers et signe moins');
const empty = text.emptyState('noresult', { query: 'zzqxw', scope: 'Domaine entier', ou: true });
check(empty.actions.some((x) => x.id === 'everywhere') && empty.actions.some((x) => x.id === 'contains'), 'état vide avec actions suivantes');
check(text.emptyState('filter').actions[0].id === 'clearFilters', 'filtre trop étroit');
for (const s of [empty.title, empty.text, text.emptyState('partial').text, text.emptyState('refused').text]) check(!/ [:;!?%]/.test(s), `espace insécable : ${s}`);

// ---------- History: 40 places, no duplicate, exact steps ----------

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

// ---------- CSV of the selected rows that are shown (RCH-126): records split outside quotes ----------

const grid = '\uFEFFNom;Note\r\nPC-01;"deux\r\nlignes"\r\nPC-02;simple\r\n';
const records = text.csvRecords(grid);
check(records.length === 3, 'en-tête et deux enregistrements, même avec un saut de ligne dans une cellule');
check(records[1] === 'PC-01;"deux\r\nlignes"', 'cellule entre guillemets gardée entière');
check(records[0].startsWith('\uFEFF'), 'marque d’ordre des octets gardée sur l’en-tête');
check(text.selectionText(3, 3) === '3 postes sélectionnés', 'énoncé « 3 postes sélectionnés »');
check(text.selectionText(3, 1) === '3 lignes sélectionnées dont 1 poste', 'énoncé « 3 lignes sélectionnées dont 1 poste »');

console.log(`${passed} vérifications réussies, ${failed} en échec.`);
if (failed) process.exit(1);
