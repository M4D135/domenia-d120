// Minimal test harness of the web modules (no dependency): `test(name, fn)` registers a test, `eq`, `ok`, `throws` check,
// `run()` runs everything and returns { passed, failed, results }. The modules of the shell use the DOM (document, CSS),
// so the tests run in a page: tests/web/run.html, opened by the WebView2 engine of the pack or any Chromium from a static
// server rooted at v2/ (the page imports ../../web/js/…). Written on 22 October 2026, run at the very end (decision of 21/10).
const tests = [];

export function test(name, fn) { tests.push({ name, fn }); }

export class Failure extends Error {}

export function ok(condition, message) { if (!condition) throw new Failure(message); }

export function eq(actual, expected, message) {
  const a = JSON.stringify(actual);
  const e = JSON.stringify(expected);
  if (a !== e) throw new Failure(`${message} (attendu ${e}, obtenu ${a})`);
}

export function throws(fn, message) {
  try { fn(); } catch { return; }
  throw new Failure(`${message} (aucune exception)`);
}

export async function run() {
  const results = [];
  for (const t of tests) {
    try {
      await t.fn();
      results.push({ name: t.name, passed: true });
    } catch (err) {
      results.push({ name: t.name, passed: false, error: String(err?.message ?? err) });
    }
  }
  const failed = results.filter((r) => !r.passed).length;
  return { passed: results.length - failed, failed, results };
}
