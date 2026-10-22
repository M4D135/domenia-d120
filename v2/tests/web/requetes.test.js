// Tests of the pure parts of the query workshop page (docs/KIT.md § 6: written now, run at the end in the WebView2 engine).
// Each test is a function that throws on failure; `run()` returns one line per test. Nothing here calls the bridge.
import { paint } from '../../web/js/pages/requetes/ldap-editor.js';
import { walk, nodeAt, targetGroupPath } from '../../web/js/pages/requetes/compose.js';
import { dnParts, valueText, clauseText, emptyRecipe } from '../../web/js/pages/requetes/shared.js';
import { originParams } from '../../web/js/pages/requetes.js';

function ok(condition, message) {
  if (!condition) throw new Error(message);
}

function equal(expected, actual, message) {
  if (JSON.stringify(expected) !== JSON.stringify(actual)) throw new Error(`${message} : attendu ${JSON.stringify(expected)}, obtenu ${JSON.stringify(actual)}`);
}

const clause = (field, operator, value) => ({ kind: 'clause', clause: { field, operator, value }, children: [], collectionField: null, quantifier: null });
const group = (kind, children = []) => ({ kind, clause: null, children, collectionField: null, quantifier: null });

export const tests = {
  'Le surligneur LDAP colore groupes, attributs, opérateurs, jokers et échappements'() {
    const html = paint('(&(cn=PC*)(!(description=a\\2a)))', 0);
    ok(html.includes('<span class="l-op">&amp;</span>'), 'opérateur ET coloré');
    ok(html.includes('<span class="l-attr">cn</span>'), 'attribut coloré');
    ok(html.includes('<span class="l-star">*</span>'), 'joker coloré');
    ok(html.includes('<span class="l-esc">\\2a</span>'), 'échappement coloré');
    ok(html.includes('<span class="l-op">!</span>'), 'opérateur NON coloré');
  },
  'Le surligneur marque la position d’erreur donnée par le moteur, même après la fin du texte'() {
    ok(paint('(cn=a', 5).includes('<mark class="l-err">'), 'erreur au dernier caractère');
    ok(paint('(cn=a', 9).endsWith('<mark class="l-err"> </mark>\n'), 'erreur après la fin');
    ok(!paint('(cn=<b>)', 0).includes('<b>'), 'texte échappé, jamais du balisage');
  },
  'L’arbre de conditions se parcourt avec chemins, profondeurs et collection'() {
    const tree = group('all', [clause('os', 'contains', '11'), { ...group('collection', [group('all', [clause('instance:svc:State', 'equal', 'Running')])]), collectionField: 'probe:svc' }]);
    const rows = walk(tree);
    equal(['', '/0', '/1', '/1/0', '/1/0/0'], rows.map((r) => r.path), 'chemins en profondeur');
    equal([0, 1, 1, 2, 3], rows.map((r) => r.depth), 'profondeurs');
    equal('svc', rows[4].collection, 'propriété rattachée à sa collection');
    equal('instance:svc:State', nodeAt(tree, '/1/0/0').node.clause.field, 'nœud trouvé par son chemin');
    equal(1, nodeAt(tree, '/1').index, 'index dans le parent');
  },
  'Un nouvel élément va dans le groupe choisi, ou dans un ET créé sous un NON'() {
    const tree = group('all', [{ ...group('not'), children: [clause('active', 'equal', true)] }]);
    equal('/0/0', targetGroupPath(tree, '/0'), 'sous le NON');
    equal('all', tree.children[0].children[0].kind, 'ET créé autour de l’élément existant');
    equal('', targetGroupPath(tree, ''), 'groupe racine');
    equal('/0/0', targetGroupPath(tree, '/0/0/0'), 'le parent d’un critère');
  },
  'Le fil d’Ariane d’un DN garde les échappements et part du domaine'() {
    const parts = dnParts('CN=PC\\, 1,OU=Paris,OU=Postes,DC=example,DC=local');
    equal(['CN', 'OU', 'OU', 'DC', 'DC'], parts.map((p) => p.type), 'types');
    equal('PC, 1', parts[0].value, 'virgule échappée gardée dans la valeur');
    equal('OU=Postes,DC=example,DC=local', parts[2].dn, 'DN de chaque niveau');
  },
  'Les valeurs des paramètres et des critères se lisent en français'() {
    equal('8 Go', valueText(8, { unit: 'Go' }), 'unité');
    equal('Oui', valueText(true, null), 'booléen');
    equal('paramètre Seuil', valueText({ parameter: 'Seuil' }, null), 'référence de paramètre');
    equal('Système est renseigné', clauseText({ field: 'os', operator: 'isPresent', value: null }, { name: 'Système' }), 'test de présence sans valeur');
  },
  'Un critère paramétré se lit avec le nom du paramètre, jamais une valeur figée'() {
    const field = { name: 'Espace libre C: relevé (%)', unit: '%', kind: 'number' };
    equal('Espace libre C: relevé (%) est inférieur à paramètre Seuil', clauseText({ field: 'diskFreePercent', operator: 'less', value: { parameter: 'Seuil' } }, field), 'paramètre');
    equal('Espace libre C: relevé (%) est inférieur à 10\u00a0%', clauseText({ field: 'diskFreePercent', operator: 'less', value: 10 }, field), 'valeur figée avec son unité');
    equal('Filtre LDAP (cn=PC*)', clauseText({ field: 'ldap.filter', operator: 'equal', value: '(cn=PC*)' }, null), 'filtre brut');
  },
  'Le retour vers l’écran d’origine ne garde que des paramètres simples et bornés'() {
    equal({ onglet: 'postes', ou: 'OU=Paris,DC=example,DC=local' }, originParams('onglet=postes&ou=OU%3DParis%2CDC%3Dexample%2CDC%3Dlocal'), 'paramètres décodés');
    equal({ a: '1' }, originParams('a=1&=2&3x=4&b%=5&sans-valeur'), 'noms invalides et paires mal formées ignorés');
    equal({}, originParams('a='.padEnd(2049, 'x')), 'au-delà de 2 048 caractères : rien');
    equal({}, originParams(null), 'absent : rien');
  },
  'Un brouillon vide part de la cible et n’a aucune condition'() {
    const r = emptyRecipe('user');
    equal('user', r.target, 'cible');
    equal(0, r.clauses.length, 'aucun critère');
    equal(32, r.id.length, 'identifiant de 32 caractères');
  },
};

export function run() {
  return Object.entries(tests).map(([name, test]) => {
    try {
      test();
      return `ok    ${name}`;
    } catch (err) {
      return `échec ${name} : ${err.message}`;
    }
  });
}
