import { openPlan } from '../../web/js/pages/requetes/drawers.js';
import { test, eq, ok } from './harness.mjs';
import { render } from '../../web/js/pages/requetes.js';
import { mountSave } from '../../web/js/pages/requetes/save.js';

const settle = async () => { for (let i = 0; i < 30; i++) await Promise.resolve(); };
function fixture(call, saved = null) {
  const events = new Map(); const notices = [];
  const store = { alive: true, version: 1, recipe: { id: 'recipe', name: 'Ma requête', target: 'computer', clauses: [] }, saved,
    validation: { valid: true, conditionCount: 0, format: 'Domenia.Query/3', fingerprint: 'a'.repeat(64) },
    call, toast: text => notices.push(text), on(name, fn) { const list = events.get(name) ?? []; list.push(fn); events.set(name, list); return () => {}; },
    emit(name) { for (const fn of events.get(name) ?? []) fn(); },
  };
  const panel = document.createElement('div'); document.body.append(panel);
  const ui = mountSave(panel, store, { rename() {} });
  return { panel, store, notices, dispose() { store.alive = false; ui.destroy(); panel.remove(); } };
}

test('Atelier : aucune écriture avant lecture confirmée, échec visible et reprise explicite', async () => {
  let answer; let reads = 0; const writes = [];
  const f = fixture(async op => {
    if (op === 'requetes.library.list') { reads++; return new Promise(resolve => { answer = resolve; }); }
    if (op === 'requetes.widget.list') return { data: [] };
    writes.push(op); return { error: { code: 'unexpected' }, message: 'écriture inattendue' };
  });
  const disabled = () => [...f.panel.querySelectorAll('.rq-save-go,.rq-save-copy,.rq-w-add')].every(button => button.disabled);
  try {
    ok(disabled(), 'même un brouillon valide attend la bibliothèque');
    f.panel.querySelector('.rq-save-go').dispatchEvent(new MouseEvent('click', { bubbles: true })); await settle();
    eq(writes, [], 'le handler vérifie aussi la garde');
    answer({ error: { code: 'library.unavailable' }, message: 'disque indisponible' }); await settle();
    ok(disabled() && f.panel.textContent.includes('Bibliothèque non relue'), 'échec ne devient pas une bibliothèque vide');
    f.panel.querySelector('.rq-library-retry').click(); await settle(); eq(reads, 2, 'un seul nouvel essai demandé');
    answer({ data: { categories: [], persistent: true } }); await settle();
    ok(!disabled(), 'écriture proposée après réponse confirmée'); eq(writes, [], 'relire ne sauvegarde rien');
  } finally { f.dispose(); }
});

test('Atelier : une référence non relue reste distincte d’un nouveau brouillon et une archive est conservée', async () => {
  let unavailable = true;
  const f = fixture(async op => {
    if (op === 'requetes.library.list') return { data: { categories: [], persistent: true } };
    if (op === 'requetes.library.get') return unavailable ? { error: { code: 'library.unavailable' } } : { data: { revision: 4, archived: true } };
    if (op === 'requetes.widget.list') return { data: [] };
    throw new Error('Aucune mutation attendue');
  }, { id: 'recipe', source: 'personal', revision: 2, fingerprint: 'b'.repeat(64), unconfirmed: true });
  try {
    await settle();
    ok(f.panel.querySelector('.rq-rev-state').textContent.includes('Révision non déterminée'), 'ancien identifiant conservé sans fausse confirmation');
    ok(f.panel.querySelector('.rq-save-copy').disabled, 'copie également bloquée tant que la référence est inconnue');
    unavailable = false; f.panel.querySelector('.rq-library-retry').click(); await settle();
    eq(f.store.saved.revision, 2, 'relire n’adopte pas silencieusement une autre base');
    eq(f.store.saved.libraryChanged, 4, 'révision actuelle connue séparément');
    ok(f.store.saved.archived && f.panel.querySelector('.rq-rev-state').textContent.includes('Archivée'), 'archive visible et non assimilée à un brouillon neuf');
    ok(f.panel.querySelector('.rq-save-archive').disabled, 'archive non réarchivée');
  } finally { f.dispose(); }
});


test('Atelier : un double clic ne crée pas deux écritures et changer de brouillon ne lui rattache pas le reçu précédent', async () => {
  let answer; let writes = 0;
  const f = fixture(async op => {
    if (op === 'requetes.library.list') return { data: { categories: [], persistent: true } };
    if (op === 'requetes.widget.list') return { data: [] };
    if (op === 'requetes.library.save') { writes++; return new Promise(resolve => { answer = resolve; }); }
    throw new Error('Appel inattendu : ' + op);
  });
  try {
    await settle(); const button = f.panel.querySelector('.rq-save-go');
    button.click(); button.dispatchEvent(new MouseEvent('click', { bubbles: true })); await settle();
    eq(writes, 1, 'un seul enregistrement en cours');
    f.store.recipe = { ...f.store.recipe, id: 'other', name: 'Autre brouillon' }; f.store.version++;
    answer({ data: { id: 'recipe', name: 'Ma requête', revision: 1, receipt: { readBack: true, persisted: true, savedAt: new Date().toISOString(), text: 'Confirmé' } } });
    await settle();
    eq(f.store.saved, null, 'le reçu de la première requête ne devient pas la base de la seconde');
    eq(f.store.recipe.id, 'other', 'nouveau brouillon préservé');
    ok(!button.disabled, 'commande de nouveau disponible après la fin réelle');
  } finally { f.dispose(); }
});


test('Atelier complet : la sélection Accueil reçue tardivement ne remplace pas une saisie commencée', async () => {
  const host = document.createElement('main'); document.body.append(host);
  const calls = []; const notices = []; const beforeUrl = location.href; let answer;
  const scope = { effective: { dn: 'OU=Postes,DC=test,DC=local', label: 'Postes', subtree: true }, domain: { dnsName: 'test.local' }, counts: {}, base: null };
  const dispose = render(host, {
    params: { source: 'accueil', revision: 'r1', cle: 'fleet.attention', onglet: 'enregistrer' },
    pages: [], link: () => beforeUrl, navigate() {}, toast: message => notices.push(message),
    async call(op, args) {
      calls.push(op);
      if (op === 'requetes.scope') return scope;
      if (op === 'requetes.library.list') return { categories: [], persistent: true };
      if (op === 'requetes.widget.list') return [];
      if (op === 'requetes.home.recipe') return new Promise(resolve => { answer = resolve; });
      if (op === 'requetes.validate') return { valid: true, recipe: args.recipe, conditionCount: 0, fingerprint: 'a'.repeat(64) };
      if (op === 'requetes.draft.keep') return { persisted: false };
      throw Object.assign(new Error('Appel interdit : ' + op), { code: 'test.unexpected' });
    },
  });
  try {
    await settle(); ok(answer, 'transfert lancé depuis la vraie page');
    host.querySelector('.rq-rename').click();
    const input = host.querySelector('#rq-name'); input.value = 'Ma saisie pendant la lecture';
    input.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }));
    answer({ draft: { recipe: { name: 'Ancienne sélection' }, note: 'Ancien calcul' }, scope }); await settle();
    eq(host.querySelector('.rq-title-text').textContent, 'Ma saisie pendant la lecture', 'saisie conservée');
    ok(!calls.includes('requetes.preview'), 'aucun aperçu de la sélection arrivée trop tard');
    ok(notices.some(n => n.includes('brouillon saisi')), 'refus expliqué');
  } finally { dispose(); host.remove(); history.replaceState(history.state, '', beforeUrl); }
});


test('Atelier : un reçu non relu ne devient ni une sauvegarde confirmée ni une nouvelle base utilisable', async () => {
  const f = fixture(async op => {
    if (op === 'requetes.library.list') return { data: { categories: [], persistent: true } };
    if (op === 'requetes.widget.list') return { data: [] };
    if (op === 'requetes.library.save') return { data: { id: 'recipe', name: 'Ma requête', revision: 1,
      receipt: { readBack: false, persisted: true, savedAt: new Date().toISOString(), text: 'Relecture impossible' } } };
    throw new Error('Appel inattendu : ' + op);
  });
  try {
    await settle(); f.panel.querySelector('.rq-save-go').click(); await settle();
    ok(f.store.saved.unconfirmed, 'révision retournée conservée comme incertaine');
    ok(f.panel.querySelector('.rq-save-go').disabled && f.panel.querySelector('.rq-w-add').disabled, 'pas de nouvelle mutation avant relecture');
    ok(f.panel.querySelector('.rq-receipt').textContent.includes('Enregistrement non confirmé'), 'pas de succès inventé');
    ok(!f.panel.querySelector('.rq-library-retry').disabled, 'récupération disponible');
  } finally { f.dispose(); }
});


test('Atelier collecte : avis de fenêtre visible, confirmation unique et accord explicite transmis avec le ticket', async () => {
  const calls = [];
  const plan = { targets: Array.from({ length: 201 }, (_, i) => String(i)), total: 201, reused: 0, disabled: 0,
    workload: { level: 'Modéré' }, probeIds: [], fieldCounts: [], text: 'Fenêtre de fond fermée : ce relevé manuel reste possible après confirmation.' };
  const store = { alive: true, recipe: {}, toast() {}, async call(operation, args) {
    calls.push({ operation, args });
    return operation === 'requetes.collect.plan' ? { data: { plan, ticket: 'ticket-exact' } } : { error: { code: 'test.stop' }, message: 'Fin de scénario' };
  } };
  let drawer;
  try {
    await openPlan(store); await settle();
    drawer = [...document.querySelectorAll('.k-drw')].at(-1);
    const launch = drawer.querySelector('.k-drw-foot [data-id="run"]');
    launch.click(); launch.dispatchEvent(new MouseEvent('click', { bubbles: true })); await settle();
    const dialogs = [...document.querySelectorAll('.k-dlg')];
    eq(dialogs.length, 1, 'le double clic ne crée pas deux confirmations');
    ok(dialogs[0].textContent.includes('Fenêtre de fond fermée'), 'avis du plan présent dans la confirmation');
    eq(calls.filter(call => call.operation === 'requetes.collect.run').length, 0, '201 postes attendent le geste explicite');
    dialogs[0].querySelector('[data-id="ok"]').click(); await settle();
    eq(calls.filter(call => call.operation === 'requetes.collect.run').map(call => call.args), [{ ticket: 'ticket-exact', confirmed: true }], 'accord lié à ce ticket, une seule fois');
    ok(launch.disabled, 'ticket consommé non rejoué après réponse en erreur');
  } finally {
    store.alive = false;
    document.querySelector('.k-dlg [data-id="cancel"]')?.click(); drawer?.querySelector('.k-drw-x')?.click();
    await new Promise(resolve => setTimeout(resolve, 350));
  }
});
