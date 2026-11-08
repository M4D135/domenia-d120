import { test, eq, ok } from './harness.mjs';
import { createWidgetCollections, collectionText } from '../../web/js/pages/accueil/widget-collections.js';
import { bannerPlan, close, notes, notify } from '../../web/js/shell/notify.js';

const settle = async () => { for (let i = 0; i < 15; i++) await Promise.resolve(); };
const deferred = () => { let resolve; const promise = new Promise(r => { resolve = r; }); return { promise, resolve }; };
const scope = { dn: 'OU=Postes,DC=example,DC=local', label: 'Postes', subtree: true };
const item = { id: 'widget-one', key: 'fleet.lastcheck', title: 'Dernier ping', paused: false };
const plan = { id: 'a'.repeat(32), widgetId: item.id, title: item.title, scope, targets: 2, fresh: 0, confirmationRequired: false, detail: 'Lecture de deux postes.' };
function setup(call, onChanged = async () => true, toast = () => {}) {
  const host = document.createElement('div');
  host.innerHTML = '<article data-item="widget-one"><strong data-figure>42</strong><p data-widget-progress hidden></p></article><details data-widget-queue hidden></details>';
  document.body.append(host);
  const subscriptions = new Map();
  const ctx = { call, toast, pulse: { every(name, interval, callback) {
    eq(interval, 1000, 'suivi à une seconde'); subscriptions.set(name, callback); return () => subscriptions.delete(name);
  } } };
  const collections = createWidgetCollections({ ctx, host, isAlive: () => true, onChanged });
  collections.scope(scope);
  return { host, collections, subscriptions, destroy() { collections.destroy(); host.remove(); } };
}

test('Accueil widget : ajout explicite, chiffres conservés et file libérée seulement après dessin achevé', async () => {
  const calls = []; const reading = deferred(); const drawing = deferred();
  const x = setup(async (op, args) => {
    calls.push({ op, args });
    if (op === 'accueil.widget.plan') return plan;
    if (op === 'accueil.widget.run') return reading.promise;
    if (op === 'accueil.widget.state') return [{ ...plan, phase: 'running', done: 1, total: 2 }];
    return null;
  }, () => drawing.promise);
  try {
    const work = x.collections.collect(item, 'add'); await settle();
    eq(calls.filter(c => c.op === 'accueil.widget.run').length, 1, 'le geste d’ajout suffit sous le seuil');
    eq(calls.find(c => c.op === 'accueil.widget.run').args.confirmed, false, 'aucune confirmation inventée');
    eq(x.subscriptions.size, 1, 'un seul suivi partagé pour la progression');
    await [...x.subscriptions.values()][0]();
    eq(x.host.querySelector('[data-figure]').textContent, '42', 'la progression ne remplace pas la dernière mesure');
    ok(x.host.querySelector('[data-widget-progress]').textContent.includes('1/2'), 'compteurs de progression indépendants');
    reading.resolve({ failed: 0 }); await settle();
    eq(calls.filter(c => c.op === 'accueil.widget.drawn').length, 0, 'fin du moteur ne suffit pas');
    drawing.resolve(true); await work;
    eq(calls.filter(c => c.op === 'accueil.widget.drawn').length, 1, 'dessin réellement achevé acquitté une fois');
    eq(x.subscriptions.size, 0, 'suivi retiré au repos');
  } finally { x.destroy(); }
});

test('Accueil widget : une préparation tardive après changement d’OU ne lance aucune collecte', async () => {
  const pending = deferred(); const calls = [];
  const x = setup(async op => { calls.push(op); return op === 'accueil.widget.plan' ? pending.promise : null; });
  try {
    const work = x.collections.collect(item, 'add');
    x.collections.scope({ ...scope, dn: 'OU=Autres,DC=example,DC=local' });
    pending.resolve(plan); await work;
    ok(!calls.includes('accueil.widget.run'), 'identité de vue changée avant admission');
    ok(calls.includes('accueil.widget.cancel'), 'plan local tardif retiré');
  } finally { x.destroy(); }
});

test('Accueil widget : le résultat partiel libère le catalogue et conserve son avertissement dans le journal', async () => {
  const region = document.createElement('div'); region.className = 'toasts'; document.body.append(region);
  const calls = []; const notices = []; let nextPlan = 0;
  const x = setup(async op => {
    calls.push(op);
    if (op === 'accueil.widget.plan') return { ...plan, id: String(++nextPlan).padStart(32, '0') };
    if (op === 'accueil.widget.run') return { failed: 1, detail: 'Collecte partielle ; les mesures confirmées restent conservées.' };
    return null;
  }, async () => true, (message, options) => {
    ok(calls.includes('accueil.widget.drawn'), 'le résultat a été dessiné avant sa notification');
    notices.push(notify(message, options));
  });
  try {
    await x.collections.collect(item, 'add');
    await x.collections.collect(item, 'add');
    eq(notices.length, 2, 'les deux résultats partiels restent annoncés');
    ok(notices[0] !== notices[1], 'deux plans distincts ne transforment pas le même avertissement en bannière épinglée');
    for (const notice of notices) {
      ok(notice.el, 'le résultat partiel reste visible');
      eq(notice.tone, 'warn', 'un résultat partiel ne devient pas un succès');
      ok(!notice.pinned && !notice.el.classList.contains('sticky') && notice.left > 0 && notice.left <= 6000, 'la bannière libère les actions sans fermeture obligatoire');
      notice.el.querySelector('.toast-close').click();
      ok(notice.closed && notes().includes(notice), 'fermer la bannière conserve le résultat dans le journal');
    }
    eq(x.host.querySelector('[data-figure]').textContent, '42', 'les dernières mesures restent affichées');
    eq(bannerPlan('warn', 'Une écriture reste à vérifier.').autoClose, 0, 'les avertissements exigeant une action restent persistants');
  } finally { for (const notice of notices) close(notice, false); x.destroy(); region.remove(); }
});

test('Accueil widget : Actualiser demande une confirmation et un dessin échoué n’est jamais acquitté', async () => {
  const calls = [];
  const x = setup(async op => { calls.push(op); if (op === 'accueil.widget.plan') return { ...plan, confirmationRequired: true }; return { failed: 0 }; }, async () => false);
  try {
    const work = x.collections.collect(item, 'refresh'); await settle();
    ok(!calls.includes('accueil.widget.run'), 'attend la vraie confirmation');
    const button = document.querySelector('.k-dlg-foot [data-id="run"]');
    ok(button, 'confirmation contient le bouton Lancer'); button.click(); await work;
    ok(calls.includes('accueil.widget.run'), 'lecture après validation');
    ok(!calls.includes('accueil.widget.drawn'), 'dessin refusé reste non acquitté');
    ok(calls.includes('accueil.widget.cancel'), 'demande arrêtée au lieu de libérer la file sur une ancienne vue');
  } finally { x.destroy(); }
});


test('Widgets : phases métier sans inventer un total pendant la préparation', () => {
  for (const [phase, label] of [['inventory', 'Inventaire WMI'], ['software', 'Logiciels'], ['probe', 'WMI mémorisé'], ['query', 'Requête']]) {
    ok(collectionText({ phase, done: 3, total: 7 }).includes(label + ' · 3/7'), 'source et progression réelles : ' + phase);
  }
  ok(!collectionText({ phase: 'preparing', done: 0, total: 0 }).includes('0/0'), 'volume encore inconnu avant le plan');
  ok(!collectionText({ phase: 'running' }).includes('undefined'), 'aucun compteur fabriqué sans mesure');
  ok(collectionText({ phase: 'running', progressUnavailable: true }).includes('peut encore'), 'absence du suivi ne certifie ni arrêt ni fin');
});

test('Accueil widget : une lecture de progression tardive ne repeuple pas une autre OU', async () => {
  const status = deferred(); const reading = deferred();
  const x = setup(async op => {
    if (op === 'accueil.widget.plan') return plan;
    if (op === 'accueil.widget.run') return reading.promise;
    if (op === 'accueil.widget.state') return status.promise;
    return null;
  });
  try {
    const work = x.collections.collect(item, 'add'); await settle();
    const pending = [...x.subscriptions.values()][0]();
    x.collections.scope({ ...scope, dn: 'OU=Autre,DC=example,DC=local' });
    reading.resolve({ failed: 0 }); await work;
    status.resolve([{ ...plan, phase: 'inventory', done: 1, total: 2 }]); await pending;
    ok(x.host.querySelector('[data-widget-progress]').hidden, 'ancienne progression écartée après la fin du geste');
    eq(x.subscriptions.size, 0, 'aucun suivi réactivé par une ancienne réponse');
  } finally { x.destroy(); }
});


test('Accueil widget : une ancienne collecte qui finit ne retire pas la nouvelle demande de la même carte', async () => {
  const old = deferred(); const next = deferred(); let plans = 0; const calls = [];
  const x = setup(async (operation, args) => {
    calls.push({ operation, args });
    if (operation === 'accueil.widget.plan') return { ...plan, id: (++plans === 1 ? 'a' : 'b').repeat(32) };
    if (operation === 'accueil.widget.run') return args.planId.startsWith('a') ? old.promise : next.promise;
    return null;
  });
  try {
    const first = x.collections.collect(item, 'add'); await settle();
    x.collections.scope({ ...scope, dn: 'OU=Autre,DC=example,DC=local' });
    ok(x.host.querySelector('[data-widget-progress]').hidden, 'ancienne demande détachée immédiatement');
    const second = x.collections.collect(item, 'add'); await settle();
    eq(plans, 2, 'nouveau périmètre peut préparer sa propre demande');
    old.resolve({ failed: 0 }); await first;
    ok(!x.host.querySelector('[data-widget-progress]').hidden, 'la fin ancienne ne supprime pas la demande actuelle');
    eq(calls.filter(call => call.operation === 'accueil.widget.drawn').length, 0, 'ancien tableau jamais acquitté');
    next.resolve({ failed: 0 }); await second;
    eq(calls.filter(call => call.operation === 'accueil.widget.drawn').map(call => call.args.id), ['b'.repeat(32)], 'seule la nouvelle collecte est acquittée');
  } finally { old.resolve({ failed: 0 }); next.resolve({ failed: 0 }); x.destroy(); }
});
