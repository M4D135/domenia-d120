// One set of assertions for the local VM browser and the historical Node entry point.
// Browser fixtures are supplied by the dedicated test host from its local source tree, never fetched.
const node = typeof process !== 'undefined' && !!process.versions?.node;
const harness = node ? null : await import('./harness.mjs');
export const test = node ? (await import('node:test')).test : harness.test;
const fail = (message) => { throw new Error(message || 'Assertion échouée'); };
function same(a, b) {
  if (Object.is(a, b)) return true;
  if (!a || !b || typeof a !== 'object' || typeof b !== 'object' || Object.getPrototypeOf(a) !== Object.getPrototypeOf(b)) return false;
  const keys = Reflect.ownKeys(a); const other = Reflect.ownKeys(b);
  return keys.length === other.length && keys.every(k => Object.hasOwn(b, k) && same(a[k], b[k]));
}
export const assert = node ? (await import('node:assert/strict')).default : {
  ok(value, message) { if (!value) fail(message); },
  equal(actual, expected, message) { if (!Object.is(actual, expected)) fail(`${message || 'Égalité stricte'} : attendu ${String(expected)}, obtenu ${String(actual)}`); },
  deepEqual(actual, expected, message) { if (!same(actual, expected)) fail(`${message || 'Structure différente'} : attendu ${JSON.stringify(expected)}, obtenu ${JSON.stringify(actual)}`); },
  match(value, expression, message) { if (typeof value !== 'string' || !expression.test(value)) fail(message || `${value} ne correspond pas à ${expression}`); },
};
export async function readTestFile(relative) {
  if (!/^(tests|web)\/[A-Za-z0-9_./-]+$/.test(relative) || relative.split('/').includes('..')) throw new Error('Chemin de fixture invalide');
  if (node) return (await import('node:fs/promises')).readFile(new URL(`../../${relative}`, import.meta.url), 'utf8');
  const files = globalThis.__domeniaWebTestFiles;
  if (!files || !Object.hasOwn(files, relative) || typeof files[relative] !== 'string') throw new Error(`Fixture locale absente : ${relative}`);
  return files[relative];
}
export async function parameterSources() {
  if (node) {
    const { readdir } = await import('node:fs/promises');
    return [...(await readdir(new URL('../../web/js/pages/parametres/', import.meta.url))).filter(f => f.endsWith('.js')).map(f => `web/js/pages/parametres/${f}`), 'web/js/pages/parametres.js'];
  }
  const files = Object.keys(globalThis.__domeniaWebTestFiles || {}).filter(f => /^web\/js\/pages\/parametres\/[^/]+\.js$/.test(f));
  if (!files.length) throw new Error('Sources Paramètres absentes du pilote de tests');
  return [...files, 'web/js/pages/parametres.js'];
}
