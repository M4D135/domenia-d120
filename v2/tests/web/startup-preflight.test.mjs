import { test, eq, ok, throws } from './harness.mjs';
import { createPageLoader, validatePages, checkShell, preparePages } from '../../web/js/shell/page-preflight.js';
import { createRouter } from '../../web/js/router.js';
import { sessionMark } from '../../web/js/shell/store.js';

test('Démarrage : modules invalides jamais acceptés, imports partagés et aucun rendu au précontrôle', async () => {
  let reads = 0; let renders = 0;
  const load = createPageLoader(async () => ++reads === 1 ? {} : { render() { renders++; } });
  let refused = false;
  try { await load('accueil'); } catch { refused = true; }
  ok(refused, 'contrat render obligatoire');
  const [a, b] = await Promise.all([load('accueil'), load('accueil')]);
  eq(reads, 2, 'le refus est évacué et les demandes suivantes partagent le même import');
  ok(a === b, 'module vérifié unique'); eq(renders, 0, 'aucune collecte ou présentation pendant import');
  for (const id of [undefined, '../accueil', '_todo', 'accueil.js']) {
    let rejected = false; try { await load(id); } catch { rejected = true; }
    ok(rejected, 'pas de chemin libre');
  }
  eq(reads, 2, 'identifiants refusés avant le chargeur');
  throws(() => validatePages([{ id: 'accueil', label: 'Accueil' }, { id: 'accueil', label: 'Autre' }]), 'doublon');
  throws(() => validatePages([{ label: 'Absent' }]), 'identifiant absent');
});

test('Démarrage : inventaire DOM réel, contrôles essentiels uniques et nommés', () => {
  const host = document.createElement('div');
  host.innerHTML = '<div class="shell"><nav class="nav"><button class="nav-toggle" aria-label="Menu"></button><div class="nav-foot"></div></nav><header class="topbar"><button class="sh-activity" aria-label="Opérations"></button><button class="notif" aria-label="Notifications"></button><button class="sh-help-btn" aria-label="Aide"></button></header><main id="main"></main></div>';
  checkShell(host);
  host.querySelector('.notif').removeAttribute('aria-label');
  throws(() => checkShell(host), 'nom critique absent');
  host.querySelector('.notif').textContent = 'Notifications'; checkShell(host);
  const copy = host.querySelector('main').cloneNode(); host.append(copy);
  throws(() => checkShell(host), 'deux destinations principales refusées');
  copy.remove(); host.querySelector('.nav-foot').remove();
  throws(() => checkShell(host), 'footer critique absent');
});

test('Démarrage : préparation locale séquentielle, rendement et arrêt sans lancer la suite', async () => {
  const events = []; let active = 0; let peak = 0; let stopped = false;
  const pages = ['accueil', 'rechercher', 'poste', 'parametres'].map(id => ({ id, label: id }));
  await preparePages(pages, async id => {
    peak = Math.max(peak, ++active); events.push(id); await Promise.resolve(); active--;
    if (id === 'poste') throw new Error('fichier indisponible');
  }, { skip: 'accueil', stopped: () => stopped, yieldTurn: async () => { events.push('yield'); }, report(result) {
    events.push(result.ok ? 'ok' : 'refus'); if (!result.ok) stopped = true;
  } });
  eq(peak, 1, 'aucun chargement parallèle');
  eq(events, ['yield', 'rechercher', 'ok', 'yield', 'poste', 'refus', 'yield'], 'refus annoncé, arrêt avant écran suivant');
});

const wait = ms => new Promise(resolve => setTimeout(resolve, ms));
async function until(predicate) {
  const deadline = performance.now() + 5000;
  while (!predicate()) { if (performance.now() > deadline) throw new Error('Jalon de test non reçu en cinq secondes.'); await wait(20); }
}
test('Navigation : une préparation lente libère la transition et un refus périmé reste silencieux', async () => {
  const oldHash = location.hash; const oldMotion = document.documentElement.dataset.motion; const oldTransition = document.startViewTransition;
  document.documentElement.dataset.motion = 'full';
  const host = document.createElement('div'); host.innerHTML = '<nav></nav><main tabindex="-1"></main>'; document.body.append(host);
  let finish; let rejectOld; let callbackValue = 'not-called'; const errors = []; const ready = [];
  const pendingRender = new Promise(resolve => { finish = resolve; });
  const pendingImport = new Promise((_, reject) => { rejectOld = reject; });
  document.startViewTransition = callback => { callbackValue = callback(); return { finished: Promise.resolve(), updateCallbackDone: Promise.resolve() }; };
  history.replaceState(null, '', '#/first');
  const router = createRouter({ main: host.querySelector('main'), nav: host.querySelector('nav'),
    pages: ['first', 'slow', 'old'].map(id => ({ id, label: id })), context: () => ({}),
    onError: (_, id) => errors.push(id), onReady: page => ready.push(page.id),
    loadPage: async id => id === 'old' ? pendingImport : { own: true, mod: { async render(main) {
      main.textContent = id; if (id === 'slow') await pendingRender;
    } } },
  });
  try {
    await router.start(); await until(() => ready.length === 1);
    history.replaceState(null, '', '#/slow'); await router.start();
    eq(callbackValue, undefined, 'la transition ne prend pas possession de la lecture asynchrone');
    await wait(200); eq(ready, ['first'], 'page lente pas encore qualifiée');
    finish(); await until(() => ready.length === 2); eq(ready, ['first', 'slow'], 'disponibilité après la fin réelle');
    history.replaceState(null, '', '#/old'); const old = router.start();
    history.replaceState(null, '', '#/first'); await router.start();
    rejectOld(new Error('import ancien refusé')); await old;
    eq(errors, [], 'aucune alerte sur une navigation déjà abandonnée');
  } finally {
    finish(); router.destroy(); host.remove(); history.replaceState(null, '', oldHash || location.pathname);
    document.startViewTransition = oldTransition;
    if (oldMotion === undefined) delete document.documentElement.dataset.motion; else document.documentElement.dataset.motion = oldMotion;
    delete document.documentElement.dataset.ready;
  }
});

test('Démarrage : le vrai routeur attend la fin du rendu et ne qualifie pas une page refusée', async () => {
  const old = location.hash; const host = document.createElement('div'); host.innerHTML = '<nav></nav><main tabindex="-1"></main>'; document.body.append(host);
  let finish; const rendering = new Promise(resolve => { finish = resolve; }); const ready = []; const errors = [];
  history.replaceState(null, '', '#/fixture');
  const router = createRouter({ main: host.querySelector('main'), nav: host.querySelector('nav'), pages: [{ id: 'fixture', label: 'Test' }],
    context: () => ({}), onReady: page => ready.push(page.id), onError: (_, id) => errors.push(id),
    loadPage: async (_, required) => {
      ok(required, 'aucun écran déclaré ne peut se rabattre sur le placeholder');
      return { own: true, mod: { async render(main) { main.textContent = 'chargement'; await rendering; main.textContent = 'disponible'; } } };
    },
  });
  try {
    await router.start(); await wait(220); eq(ready, [], 'une promesse de rendu active interdit la disponibilité');
    finish(); await until(() => ready.length === 1); eq(ready, ['fixture'], 'rendu terminé et calme vérifié'); eq(errors, [], 'pas de faux incident');
  } finally { finish(); router.destroy(); host.remove(); history.replaceState(null, '', old || location.pathname); delete document.documentElement.dataset.ready; }
  const badHost = document.createElement('div'); badHost.innerHTML = '<nav></nav><main></main>'; document.body.append(badHost);
  history.replaceState(null, '', '#/broken');
  const bad = createRouter({ main: badHost.querySelector('main'), nav: badHost.querySelector('nav'), pages: [{ id: 'broken', label: 'Refus' }], context: () => ({}),
    onReady: page => ready.push(page.id), onError: (_, id) => errors.push(id), loadPage: async () => { throw new Error('module invalide'); } });
  try {
    await bad.start(); await wait(250); eq(ready, ['fixture'], 'page d’erreur jamais annoncée disponible');
    eq(errors, ['broken'], 'incident transmis'); ok(badHost.querySelector('[data-retry]'), 'refus lisible avec reprise');
  } finally { bad.destroy(); badHost.remove(); history.replaceState(null, '', old || location.pathname); delete document.documentElement.dataset.ready; }
});


test('Session : même compte et domaine distinguent génération et base, jamais les dates de collecte', () => {
  const session = { account: { login: 'TEST\\operator' }, domain: { dnsName: 'test.local', rootDn: 'DC=test,DC=local' }, epoch: 4, storeId: 'a'.repeat(64), connection: { state: 'disconnected' }, cache: { lastReadAt: '2026-10-21T12:00:00Z', objects: 1 } };
  const mark = sessionMark(session);
  eq(sessionMark({ ...session, cache: { lastReadAt: '2026-10-22T12:00:00Z', objects: 100 } }), mark, 'mise à jour normale sans fermeture');
  ok(sessionMark({ ...session, epoch: 5 }) !== mark, 'reconnexion de même compte identifiée');
  ok(sessionMark({ ...session, storeId: 'b'.repeat(64) }) !== mark, 'bascule locale même hors ligne identifiée');
});

test('Session : invalidation retire l’ancien écran et son garde en attente, un refus tardif ne rétablit rien', async () => {
  const oldHash = location.hash; const oldMotion = document.documentElement.dataset.motion;
  document.documentElement.dataset.motion = 'reduced';
  const host = document.createElement('div'); host.innerHTML = '<nav></nav><main tabindex="-1"></main>'; document.body.append(host);
  let answerGuard; const pendingGuard = new Promise(resolve => { answerGuard = resolve; });
  let generation = 1; let cleaned = 0; let guards = 0; const ready = [];
  history.replaceState(null, '', '#/fixture');
  const router = createRouter({ main: host.querySelector('main'), nav: host.querySelector('nav'), pages: [{ id: 'fixture', label: 'Test' }], context: () => ({}), onReady: page => ready.push(page.id),
    loadPage: async () => ({ own: true, mod: { render(main, ctx) {
      const mine = generation; main.textContent = `base ${mine}`;
      ctx.guardLeave(() => { guards++; return pendingGuard; });
      return () => { cleaned++; };
    } } }),
  });
  try {
    await router.start(); await until(() => ready.length === 1);
    const oldNavigation = router.start(); await until(() => guards === 1);
    generation = 2;
    window.dispatchEvent(new CustomEvent('domenia:session-invalidating'));
    eq(host.querySelector('main').textContent, '', 'aucune donnée de l’ancienne base laissée visible');
    eq(cleaned, 1, 'abonnements et vue précédents nettoyés');
    await router.start(); await until(() => ready.length === 2);
    eq(host.querySelector('main').textContent, 'base 2', 'nouveau contexte peut rendre sans attendre l’ancien garde');
    answerGuard(false); await oldNavigation;
    eq(host.querySelector('main').textContent, 'base 2', 'ancien refus sans effet après invalidation');
    eq(guards, 1, 'pas de nouveau dialogue issu de l’ancien contexte');
  } finally {
    answerGuard(false); router.destroy(); host.remove(); history.replaceState(null, '', oldHash || location.pathname); delete document.documentElement.dataset.ready;
    if (oldMotion === undefined) delete document.documentElement.dataset.motion; else document.documentElement.dataset.motion = oldMotion;
  }
});


test('Session : un rendu asynchrone abandonné garde son DOM détaché et ne pose plus de garde', async () => {
  const oldHash = location.hash; const oldMotion = document.documentElement.dataset.motion;
  document.documentElement.dataset.motion = 'reduced';
  const host = document.createElement('div'); host.innerHTML = '<nav></nav><main tabindex="-1"></main>'; document.body.append(host);
  let finishOld; const pending = new Promise(resolve => { finishOld = resolve; });
  let phase = 1; let oldGuard = 0; let cleaned = 0; let oldHost; const ready = [];
  history.replaceState(null, '', '#/fixture');
  const viewport = host.querySelector('main');
  const router = createRouter({ main: viewport, nav: host.querySelector('nav'), pages: [{ id: 'fixture', label: 'Test' }], context: () => ({}), onReady: page => ready.push(page.id),
    loadPage: async () => ({ own: true, mod: { async render(main, ctx) {
      const mine = phase;
      ok(ctx.viewport === viewport, 'élément de défilement du shell conservé');
      main.textContent = `base ${mine}`;
      if (mine === 1) {
        oldHost = main; await pending;
        main.innerHTML = '<div>réponse de l’ancienne base</div>';
        ctx.guardLeave(() => { oldGuard++; return false; });
        ctx.navigate('obsolete');
        return () => { cleaned++; };
      }
    } } }),
  });
  try {
    await router.start(); await until(() => oldHost);
    phase = 2; window.dispatchEvent(new CustomEvent('domenia:session-invalidating'));
    await router.start(); await until(() => ready.length === 1);
    finishOld(); await until(() => cleaned === 1);
    ok(!oldHost.isConnected, 'aucune racine de l’ancienne génération encore dans le document');
    eq(viewport.textContent, 'base 2', 'une écriture DOM après await ne remplace pas la nouvelle base');
    eq(location.hash, '#/fixture', 'un ancien contexte ne change plus la route');
    eq(ready, ['fixture'], 'rendu abandonné jamais qualifié');
    phase = 3; await router.start(); await until(() => ready.length === 2);
    eq(viewport.textContent, 'base 3', 'nouvelle navigation libre');
    eq(oldGuard, 0, 'garde enregistré trop tard ignoré');
  } finally {
    finishOld(); router.destroy(); host.remove(); history.replaceState(null, '', oldHash || location.pathname); delete document.documentElement.dataset.ready;
    if (oldMotion === undefined) delete document.documentElement.dataset.motion; else document.documentElement.dataset.motion = oldMotion;
  }
});
