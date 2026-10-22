// Web tests of the « Fiche » screen and of the leave guard of the router (KIT.md § 6). Written with the code, run at the very end
// (decision of David of 21/10) by the WebView2 engine of the application: a test page imports this module and calls run(), which
// returns one line per case. No network, no bridge: the page is fed by a scripted ctx.call. Nothing here is executed yet.
import { nobr, stamp, day, gridHeight, presenceWords } from '../../web/js/pages/fiche/common.js';

const cases = [];
const test = (name, fn) => cases.push({ name, fn });
const assert = (condition, message) => { if (!condition) throw new Error(message); };
const tick = (ms = 0) => new Promise((resolve) => setTimeout(resolve, ms));

// ---------------------------------------------------------------- pure helpers

test('Les noms de machines ne se coupent pas à leurs tirets', () => {
  const html = nobr('Sans réponse au ping (poste associé PC-LYO-0002)');
  assert(html.includes('<span class="fi-nobr">PC-LYO-0002</span>'), html);
  assert(nobr('<b>').includes('&lt;b&gt;'), 'le texte est échappé');
});

test('Une seule forme de date sur l’écran', () => {
  const iso = '2026-10-22T05:40:00Z';
  assert(/^\d{2}\/\d{2}\/\d{4} \d{2}:\d{2}$/.test(stamp(iso)), stamp(iso));
  assert(/^\d{2}\/\d{2}\/\d{4}$/.test(day(iso)), day(iso));
  assert(stamp(null) === '—' && day('pas une date') === '—', 'absence : un tiret, jamais 0');
});

test('La hauteur d’une grille suit ses lignes, sans bande vide', () => {
  assert(gridHeight(4) === `${62 + 4 * 40}px`, gridHeight(4));
  assert(gridHeight(500) === '560px', 'plafond');
  assert(gridHeight(null) === `${62 + 8 * 40}px`, 'sans compte : 8 lignes');
});

test('La présence se dit en quelques mots, « à relire » quand elle a vieilli', () => {
  assert(presenceWords({ state: 'stale', label: 'En ligne (poste associé PC-PAR-0007)' }) === 'En ligne (à relire)', 'périmée');
  assert(presenceWords({ state: 'online', label: 'En ligne' }) === 'En ligne', 'fraîche');
  assert(presenceWords(null) === 'Présence non relevée', 'inconnue');
});

// ---------------------------------------------------------------- page: unsaved input and route states

const DN = 'CN=Camille Bernard,OU=Commercial,OU=Lyon,OU=Utilisateurs,DC=example,DC=local';

/** Mounts the fiche page on a scripted bridge (the answers of the browser preview, mock-fiche.js). */
async function mountFiche(params, mode = 'directory') {
  const { render } = await import('../../web/js/pages/fiche.js');
  const { createFicheOperations } = await import('../../web/js/mock-fiche.js');
  const fail = (code, message) => Object.assign(new Error(message), { code });
  const helpers = {
    readObject: (a) => a, getString: (v, n) => v[n], getOptionalString: (v, n) => v[n] ?? null, requireDistinguishedName: (v) => v, requireNone: () => {},
    invalid: (m) => fail('arguments.invalid', m), fail, int: (n) => String(n), sleep: () => Promise.resolve(), NBSP: '\u00A0', REF: Date.now(),
  };
  const operations = createFicheOperations(helpers);
  const calls = [];
  const call = async (op, args) => { calls.push({ op, args }); return operations[op](args); };
  let guard = null;
  const main = document.createElement('main');
  main.dataset.page = 'fiche';
  document.body.append(main);
  const cleanup = render(main, {
    params: Object.freeze({ dn: DN, ...params }), call, navigate: () => {}, link: () => '#/fiche', app: Promise.resolve({ mode }),
    guardLeave: (fn) => { guard = fn; return () => { guard = null; }; }, commands: () => () => {},
  });
  await tick(500);
  return { main, calls, guard: () => guard, cleanup: () => { cleanup?.(); main.remove(); } };
}

test('Un état de route ne lit rien sur le réseau hors simulation et quitte l’adresse', async () => {
  location.hash = `#/fiche?dn=${encodeURIComponent(DN)}&tab=compte&open=lockouts`;
  const page = await mountFiche({ tab: 'compte', open: 'lockouts' });
  assert(!page.calls.some((c) => c.op === 'fiche.lockouts'), 'aucune lecture 4740 sans le clic de l’opérateur');
  assert(!location.hash.includes('open='), 'l’état de route est retiré de l’adresse (un retour arrière ne le rejoue pas)');
  page.cleanup();
});

test('En simulation, run=1 lit sur l’état de route (captures)', async () => {
  const page = await mountFiche({ tab: 'compte', open: 'lockouts', run: '1' }, 'simulation');
  assert(page.calls.some((c) => c.op === 'fiche.lockouts'), 'lecture faite pour la capture, en simulation seulement');
  page.cleanup();
});

test('Quitter une fiche aux saisies non enregistrées demande confirmation (FIC-007)', async () => {
  const page = await mountFiche({});
  const guard = page.guard();
  assert(typeof guard === 'function', 'la fiche déclare son garde au routeur');
  assert((await guard({ hash: '#/accueil', same: false })) === true, 'sans saisie : on part sans question');
  page.cleanup();
});

test('F5 laisse la main au panneau ou au dialogue ouvert', async () => {
  const page = await mountFiche({});
  const modal = document.createElement('div');
  modal.setAttribute('aria-modal', 'true');
  document.body.append(modal);
  const before = page.calls.filter((c) => c.op === 'fiche.read').length;
  document.dispatchEvent(new KeyboardEvent('keydown', { key: 'F5', cancelable: true }));
  await tick(300);
  assert(page.calls.filter((c) => c.op === 'fiche.read').length === before, 'la fiche n’est pas relue derrière le panneau');
  modal.remove();
  page.cleanup();
});

/** Runs every case; returns [{ name, ok, error? }]. */
export async function run() {
  const results = [];
  for (const c of cases) {
    try {
      await c.fn();
      results.push({ name: c.name, ok: true });
    } catch (err) {
      results.push({ name: c.name, ok: false, error: String(err?.message ?? err) });
    }
  }
  return results;
}
