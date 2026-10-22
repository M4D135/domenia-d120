// Tests of the pure helpers of the Assistance page (web/js/pages/assistance/format.js: formatting, the list parser of the
// offline dossier, the routes of the steps and the command line shown).
// Written with the code, run at the very end (decision of 21/10): « node tests/web/assistance-format.test.mjs » from v2/,
// or by the WebView2 engine. No DOM, no bridge: format.js imports nothing.
import assert from 'node:assert/strict';
import {
  NBSP, plural, int, initials, dnParts, dnPath, dnName, isDn, fileTimeToIso, readableValue, isIdentifier, parseNames, stepRoute, dossierCommand,
} from '../../web/js/pages/assistance/format.js';

const tests = [];
const test = (name, fn) => tests.push([name, fn]);

test('plural: number and noun on one line, French rule for 0 and 1', () => {
  assert.equal(plural(0, 'étape', 'étapes'), `0${NBSP}étape`);
  assert.equal(plural(1, 'étape', 'étapes'), `1${NBSP}étape`);
  assert.equal(plural(2, 'étape', 'étapes'), `2${NBSP}étapes`);
  assert.equal(plural(12345, 'poste', 'postes'), `12 345${NBSP}postes`);
  assert.equal(int(-3), '−3');
});

test('initials: people and workstations', () => {
  assert.equal(initials('Camille Bernard', 'user'), 'CB');
  assert.equal(initials('Jean-Luc d’Arc', 'user'), 'JA');
  assert.equal(initials('PC-LYO-0042', 'computer'), '42');
  assert.equal(initials('SRV', 'computer'), 'SR');
  assert.equal(initials('', 'user'), '?');
});

test('dnParts, dnPath, dnName: escapes kept, domain left out', () => {
  const dn = 'CN=Carré\\, Cédric,OU=Commercial,OU=Lyon,OU=Utilisateurs,DC=example,DC=local';
  assert.deepEqual(dnParts(dn).slice(0, 2), ['CN=Carré, Cédric', 'OU=Commercial']);
  assert.equal(dnPath(dn), `Utilisateurs${NBSP}› Lyon${NBSP}› Commercial`);
  assert.equal(dnName(dn), 'Carré, Cédric');
  assert.equal(dnName('pas un dn'), 'pas un dn');
  assert.ok(isDn(dn));
  assert.ok(!isDn('Camille Bernard'));
});

test('FILETIME and generalized times become dates; 0 and « never » are said', () => {
  assert.equal(fileTimeToIso('0'), null);
  assert.equal(fileTimeToIso('9223372036854775807'), null);
  assert.equal(fileTimeToIso('116444736000000000'), '1970-01-01T00:00:00.000Z');
  const lockout = readableValue('lockoutTime', '0');
  assert.equal(lockout.kind, 'special');
  assert.equal(lockout.text, 'aucun verrouillage');
  assert.equal(readableValue('pwdLastSet', '0').text, 'changement exigé à la prochaine ouverture de session');
  assert.equal(readableValue('accountExpires', '9223372036854775807').text, 'jamais');
  const date = readableValue('pwdLastSet', '134371043600000000');
  assert.equal(date.kind, 'date');
  assert.match(date.text, /^\d{2}\/\d{2}\/\d{4} \d{2}:\d{2}$/);
  assert.equal(date.raw, '134371043600000000');
  const changed = readableValue('whenChanged', '2026-10-22T00:59:20.0000000Z');
  assert.equal(changed.kind, 'date');
  assert.equal(changed.iso, '2026-10-22T00:59:20.000Z');
});

test('DN values show the name, the raw DN stays available', () => {
  const manager = readableValue('manager', 'CN=Cédric Carré,OU=Lyon,DC=example,DC=local');
  assert.equal(manager.kind, 'dn');
  assert.equal(manager.text, 'Cédric Carré');
  assert.equal(manager.raw, 'CN=Cédric Carré,OU=Lyon,DC=example,DC=local');
  assert.equal(readableValue('distinguishedName', 'CN=A,DC=b,DC=c').text, 'CN=A,DC=b,DC=c');
  assert.equal(readableValue('title', 'Technicien').kind, 'text');
});

test('identifiers stay on one line, sentences may wrap', () => {
  assert.ok(isIdentifier('pc-bdx-0006.example.local'));
  assert.ok(!isIdentifier('Windows 11 Entreprise'));
  assert.ok(!isIdentifier(''));
});

test('parseNames: lines, commas, semicolons and spaces; blanks and duplicates removed, order kept', () => {
  assert.deepEqual(parseNames('PC-01\nPC-02, pc-01;PC-03  PC-04\n\n'), ['PC-01', 'PC-02', 'PC-03', 'PC-04']);
  assert.deepEqual(parseNames(''), []);
  assert.deepEqual(parseNames(null), []);
});

test('stepRoute: Fiche « tab », Audit « tab=objet » and « vue », Poste « onglet »', () => {
  const dn = 'CN=PC-01,OU=Postes,DC=example,DC=local';
  assert.deepEqual(stepRoute({ screen: 'fiche', section: 'compte' }, dn), { screen: 'fiche', params: { dn, tab: 'compte' } });
  assert.deepEqual(stepRoute({ screen: 'audit', section: 'acl' }, dn), { screen: 'audit', params: { tab: 'objet', dn, vue: 'acl' } });
  assert.deepEqual(stepRoute({ screen: 'poste', section: 'inventaire' }, dn), { screen: 'poste', params: { dn, onglet: 'inventaire' } });
});

test('dossierCommand: one perimeter, quoted arguments, --sections only when not all, « etat,postes » for none', () => {
  const all = [{ id: 'observations' }, { id: 'associations' }, { id: 'requetes' }];
  assert.equal(dossierCommand({ postes: ['PC-01', 'PC-02'] }, ['observations', 'associations', 'requetes'], all, false),
    'Domenia.exe dossier --sortie "<dossier local>" --postes PC-01,PC-02');
  assert.equal(dossierCommand({ ou: 'OU=Postes Lyon,DC=example,DC=local' }, ['observations'], all, true),
    'Domenia.exe dossier --sortie "<dossier local>" --ou "OU=Postes Lyon,DC=example,DC=local" --sections observations --simulation');
  assert.equal(dossierCommand({ guids: ['a', 'b'] }, [], all, false), 'Domenia.exe dossier --sortie "<dossier local>" --guids a,b --sections etat,postes');
  assert.equal(dossierCommand(null, [], all, false), '');
});

let failed = 0;
for (const [name, fn] of tests) {
  try {
    await fn();
    console.log(`ok   ${name}`);
  } catch (err) {
    failed += 1;
    console.error(`ÉCHEC ${name}\n     ${err.message}`);
  }
}
console.log(`${tests.length - failed} réussi(s), ${failed} en échec`);
process.exitCode = failed ? 1 : 0;
