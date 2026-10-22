// Paramètres: tests of the pure helpers of the screen (web/js/pages/parametres/pure.js), for Node (node --test) or the
// WebView2 engine (KIT.md § 6). Written with the code, run at the end (decision of David, 21/10 and 22/10).
import test from 'node:test';
import assert from 'node:assert/strict';
import {
  SECTION_ALIASES, sectionOf, normalizePrefs, gridDensity, maskNames, markOf, linesAfter, size, masonryPlan,
} from '../../web/js/pages/parametres/pure.js';

const NBSP = ' ';

test('les anciennes adresses mènent à leur section', () => {
  assert.equal(sectionOf('stockage'), 'donnees');
  assert.equal(sectionOf('Base'), 'donnees');
  assert.equal(sectionOf(' journal '), 'journaux');
  assert.equal(sectionOf('apparence'), 'apparence');
  assert.equal(sectionOf('inconnue'), null);
  assert.equal(sectionOf(undefined), null);
  assert.equal(sectionOf('__proto__'), null);
  for (const target of Object.values(SECTION_ALIASES)) assert.equal(sectionOf(target), target);
});

test('les préférences de l’interface suivent le vocabulaire de la coque', () => {
  assert.deepEqual(normalizePrefs(null), { theme: 'system', motion: 'full', navCollapsed: false, profile: 'essentiel', density: 'normal', helpTips: true });
  assert.equal(normalizePrefs({ density: 'confort' }).density, 'normal');
  assert.equal(normalizePrefs({ density: 'confortable' }).density, 'confortable');
  assert.equal(normalizePrefs({ profile: 'admin' }).profile, 'essentiel');
  assert.equal(normalizePrefs({ helpTips: false }).helpTips, false);
  assert.equal(gridDensity('confortable'), 'comfortable');
  assert.equal(gridDensity('compact'), 'compact');
  assert.equal(gridDensity('autre'), 'normal');
});

test('le masquage retire les noms et garde les fichiers et les versions', () => {
  const text = 'Lecture de CN=Camille,OU=Postes,DC=example,DC=local par EXAMPLE\\adm-jmartin (adm@example.local) sur 10.0.0.4 et pc-01.site.example.local ; Domenia.Core.dll 2.0.0.1';
  const masked = maskNames(text);
  assert.ok(!masked.includes('Camille'));
  assert.ok(!masked.includes('adm-jmartin'));
  assert.ok(!masked.includes('adm@example.local'));
  assert.ok(!masked.includes('10.0.0.4'));
  assert.ok(!masked.includes('pc-01.site.example.local'));
  assert.ok(masked.includes('Domenia.Core.dll'));
  assert.ok(masked.includes('2.0.0.1'));
});

test('« Effacer l’affichage » garde un repère stable dans une fenêtre glissante', () => {
  const line = (s, text, level = 'INFO') => ({ at: `2026-10-22T08:00:${String(s).padStart(2, '0')}Z`, level, text });
  const window1 = [line(1, 'a'), line(2, 'b'), line(3, 'c'), line(3, 'c')];
  const mark = markOf(window1);
  assert.equal(mark.rank, 2);
  assert.deepEqual(linesAfter(window1, mark), []);
  // The window slid: the first records left, new ones came.
  const window2 = [line(3, 'c'), line(3, 'c'), line(4, 'd'), line(5, 'e', 'ERREUR')];
  assert.deepEqual(linesAfter(window2, mark).map((l) => l.text), ['d', 'e']);
  // The marked line left the window: every line dated after it is kept, and a line without date too.
  const window3 = [line(6, 'f'), { at: null, level: 'INFO', text: 'sans date' }];
  assert.deepEqual(linesAfter(window3, mark).map((l) => l.text), ['f', 'sans date']);
  assert.equal(linesAfter(window3, null), window3);
  assert.equal(markOf([]), null);
});

test('les tailles s’écrivent en français avec une espace insécable', () => {
  assert.equal(size(512), `512${NBSP}o`);
  assert.equal(size(1536), `1,5${NBSP}Ko`);
  assert.equal(size(2 * 1024 * 1024), `2${NBSP}Mo`);
  assert.equal(size(-1), 'inconnu');
  assert.equal(size(Number.NaN), 'inconnu');
});

test('la maçonnerie à deux colonnes ne laisse jamais de trou à côté d’une grande carte', () => {
  assert.deepEqual(masonryPlan([{ wide: false, height: 100 }, { wide: false, height: 100 }]), [null, null]);
  const plan = masonryPlan([
    { wide: true, height: 50 },
    { wide: false, height: 400 }, { wide: false, height: 100 }, { wide: false, height: 100 }, { wide: false, height: 100 },
    { wide: true, height: 50 },
  ], 20);
  assert.equal(plan[0], null);
  assert.equal(plan[5], null);
  assert.deepEqual(plan.slice(1, 5), [0, 1, 1, 1]);
});

/** Text parts of the string literals of a source: '…', "…" and the static parts of `…` (holes ${…} and comments left out). */
function literalTexts(src) {
  const out = [];
  let i = 0;
  const stack = [];
  let mode = 'code';
  let buf = '';
  while (i < src.length) {
    const c = src[i];
    if (mode === 'code') {
      if (c === '/' && src[i + 1] === '/') { const j = src.indexOf('\n', i); i = j < 0 ? src.length : j; continue; }
      if (c === '/' && src[i + 1] === '*') { const j = src.indexOf('*/', i + 2); i = j < 0 ? src.length : j + 2; continue; }
      if (c === '\'' || c === '"') {
        let j = i + 1; let s = '';
        while (j < src.length && src[j] !== c && src[j] !== '\n') { if (src[j] === '\\') { s += src.slice(j, j + 2); j += 2; continue; } s += src[j]; j++; }
        out.push(s); i = j + 1; continue;
      }
      if (c === '`') { mode = 'tpl'; buf = ''; i++; continue; }
      if (c === '{' && stack.length) stack[stack.length - 1]++;
      if (c === '}' && stack.length) {
        if (stack[stack.length - 1] === 0) { stack.pop(); mode = 'tpl'; buf = ''; i++; continue; }
        stack[stack.length - 1]--;
      }
      i++;
      continue;
    }
    if (c === '\\') { buf += src.slice(i, i + 2); i += 2; continue; }
    if (c === '`') { out.push(buf); mode = 'code'; i++; continue; }
    if (c === '$' && src[i + 1] === '{') { out.push(buf); stack.push(0); mode = 'code'; i += 2; continue; }
    buf += c;
    i++;
  }
  return out;
}

test('aucun texte visible des sections n’a d’espace ordinaire avant la ponctuation haute', async () => {
  const { readFile, readdir } = await import('node:fs/promises');
  const folder = new URL('../../web/js/pages/parametres/', import.meta.url);
  const files = [...(await readdir(folder)).filter((f) => f.endsWith('.js')).map((f) => new URL(f, folder)), new URL('../../web/js/pages/parametres.js', import.meta.url)];
  for (const file of files) {
    const text = await readFile(file, 'utf8');
    for (const s of literalTexts(text)) {
      assert.ok(!/[^\s(\[{] [:;?!](?=\s|$|<)/.test(s), `${file.pathname} : ${s.slice(0, 80)}`);
      assert.ok(!/« | »/.test(s), `${file.pathname} : ${s.slice(0, 80)}`);
    }
  }
});
