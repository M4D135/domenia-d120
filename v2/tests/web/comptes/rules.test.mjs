// Tests of the pure rules of the Comptes page (web/js/pages/comptes/rules.js): no DOM, no bridge. Written with the code, run
// at the very end (decision of David of 21/10): `node --test tests/web` (Node 20 or later), or by the WebView2 engine.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  passwordChecks, passwordScore, generatePassword, expirationReasons, csvCell, previewCsv, mayPrefill, parseFrenchDay, frenchDay,
  dateOfIso, int, PASSWORD_SETS, PASSWORD_MAX,
} from '../../../web/js/pages/comptes/rules.js';

const NBSP = ' ';
const account = { sam: 'c.bernard', name: 'Camille Bernard', minLength: 12 };

test('passwordChecks follows AccountPasswordReset.CheckPolicy (complexity on)', () => {
  const weak = passwordChecks('court', '', account);
  assert.deepEqual(weak.map((c) => c.id), ['length', 'classes', 'name', 'match']);
  assert.equal(weak.find((c) => c.id === 'length').met, false);
  assert.equal(weak.find((c) => c.id === 'classes').met, false);
  const named = passwordChecks('Bernard-2026!xyz', 'Bernard-2026!xyz', account);
  assert.equal(named.find((c) => c.id === 'name').met, false, 'a part of the display name is refused');
  const good = passwordChecks('Vélo-Bleu-2026!', 'Vélo-Bleu-2026!', account);
  assert.ok(good.every((c) => c.met), 'a compliant password meets every rule');
  assert.equal(passwordChecks('Vélo-Bleu-2026!', 'autre', account).find((c) => c.id === 'match').met, false);
});

test('passwordChecks without complexity checks the length only, like the engine', () => {
  const checks = passwordChecks('bernardbernard', 'bernardbernard', { ...account, complexity: false });
  assert.deepEqual(checks.map((c) => c.id), ['length', 'match']);
  assert.ok(checks.every((c) => c.met));
});

test('the minimum length falls back to 1 like the engine (Math.Max(1, minLength)), never to 12', () => {
  const zero = passwordChecks('a', 'a', { ...account, minLength: 0, complexity: false });
  assert.equal(zero[0].met, true);
  assert.equal(zero[0].label, `1${NBSP}caractère au moins`);
  const missing = passwordChecks('ab', 'ab', { sam: 'x', name: 'y', complexity: false });
  assert.equal(missing[0].met, true);
  assert.equal(passwordChecks('x'.repeat(PASSWORD_MAX + 1), '', { ...account, complexity: false })[0].met, false, '256 characters at most');
});

test('labels use French typography (narrow no-break space in thousands, no-break space before units)', () => {
  assert.equal(int(1234), '1 234');
  assert.equal(int(-5), '−5');
  assert.equal(passwordChecks('', '', { ...account, minLength: 14 })[0].label, `14${NBSP}caractères au moins`);
});

test('passwordScore goes from 0 to 4', () => {
  assert.equal(passwordScore('', passwordChecks('', '', account)), 0);
  const value = 'Vélo-Bleu-2026!-Rouge';
  assert.equal(passwordScore(value, passwordChecks(value, value, account)), 4);
  assert.ok(passwordScore('court', passwordChecks('court', '', account)) < 2);
});

test('generatePassword draws every class, no look-alike, the requested length', () => {
  for (let i = 0; i < 50; i++) {
    const value = generatePassword(16);
    assert.equal(value.length, 16);
    PASSWORD_SETS.forEach((set) => assert.ok([...value].some((ch) => set.includes(ch)), `class ${set}`));
    assert.ok(!/[O0Il1]/.test(value), 'no look-alike characters');
    assert.ok(passwordChecks(value, value, { sam: 'zz', name: 'zz', minLength: 12 }).every((c) => c.met), 'meets the default policy');
  }
  assert.equal(generatePassword(2).length, PASSWORD_SETS.length, 'at least one character of each class');
});

test('expirationReasons always says why an action is greyed', () => {
  const blocked = expirationReasons({ expiration: { available: false, reason: 'krbtgt est un compte système.' } }, { accountExpiresAt: null });
  assert.equal(blocked.set, 'krbtgt est un compte système.');
  assert.equal(blocked.never, 'krbtgt est un compte système.', 'the engine reason first, not « aucune expiration »');
  const free = expirationReasons({ expiration: { available: true } }, { accountExpiresAt: null });
  assert.equal(free.set, null);
  assert.equal(free.never, `Le compte n’a aucune expiration${NBSP}: rien à supprimer.`);
  assert.deepEqual(expirationReasons({ expiration: { available: true } }, { accountExpiresAt: '2027-01-31T00:00:00Z' }), { set: null, never: null });
});

test('csvCell neutralises formulas and quotes separators', () => {
  assert.equal(csvCell('=cmd|calc'), "'=cmd|calc");
  assert.equal(csvCell('+1'), "'+1");
  assert.equal(csvCell('@x'), "'@x");
  assert.equal(csvCell('a;b'), '"a;b"');
  assert.equal(csvCell('dit "oui"'), '"dit ""oui"""');
  assert.equal(csvCell(null), '');
});

test('previewCsv lists the targets then the named exclusions, CRLF, never a secret', () => {
  const csv = previewCsv({
    targets: [{ name: 'Camille Bernard', sam: 'c.bernard', dn: 'CN=Camille Bernard,OU=Lyon,DC=example,DC=local', change: 'Verrouillé → Déverrouillé', before: 'Verrouillé', after: 'Déverrouillé' }],
    excluded: [{ name: 'krbtgt', dn: 'CN=krbtgt,CN=Users,DC=example,DC=local', reason: 'Compte système (krbtgt) : jamais écrit' }],
  });
  const lines = csv.split('\r\n');
  assert.equal(lines.length, 3);
  assert.equal(lines[0], 'Rang;Nom;Compte;DN;Changement;Avant;Après;Statut');
  assert.ok(lines[1].startsWith('1;Camille Bernard;c.bernard;'));
  assert.ok(lines[2].includes(`Exclu${NBSP}: Compte système (krbtgt)`));
});

test('French days are parsed strictly and written JJ/MM/AAAA', () => {
  assert.equal(parseFrenchDay('20/11/2026'), '2026-11-20');
  assert.equal(parseFrenchDay('5/1/2027'), '2027-01-05');
  assert.equal(parseFrenchDay('20112026'), '2026-11-20');
  assert.equal(parseFrenchDay('2026-11-20'), '2026-11-20');
  assert.equal(parseFrenchDay('31/02/2026'), null, 'not a real day');
  assert.equal(parseFrenchDay('29/02/2028'), '2028-02-29', 'leap year');
  assert.equal(parseFrenchDay('11/21/2026'), null, 'the American order is never read as a day');
  assert.equal(parseFrenchDay('01/01/1500'), null, 'before FILETIME');
  assert.equal(frenchDay('2026-11-20'), '20/11/2026');
  assert.equal(frenchDay('2026-02-30'), '');
  assert.equal(dateOfIso('x'), null);
});

test('a field typed by the operator, or focused, is never prefilled by a later read (CPT-016)', () => {
  assert.equal(mayPrefill({ value: '', dirty: false, focused: false }), true);
  assert.equal(mayPrefill({ value: 'EXAMPLE\\adm', dirty: true, focused: false }), false);
  assert.equal(mayPrefill({ value: '', dirty: false, focused: true }), false);
});
