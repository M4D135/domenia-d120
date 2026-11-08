import { test, eq, ok } from './harness.mjs';
import { createPersonalProbes } from '../../web/js/pages/accueil/personal-probes.js';
import { openCatalog } from '../../web/js/pages/accueil/tools.js';

const settle = async () => { for (let i = 0; i < 24; i++) await Promise.resolve(); };
const lastDialog = () => [...document.querySelectorAll('.k-dlg')].at(-1);
const hash = 'a'.repeat(64);
const key = `custom.${hash}`;
const contract = {
  valid: true, summary: 'root\\cimv2 · Win32_ComputerSystem', privilegeLevel: 'AdministrateurLocal', costLevel: 'Léger',
  errors: [], warnings: [], lines: [
    { section: 'Droits', value: 'Délégation à qualifier sur la cible.' },
    { section: 'Comportement', value: 'Lecture CIM ; aucune méthode ni écriture.' },
    { section: 'Limites', value: 'Matériel présenté à Windows. Inconnu : absence ou refus.' },
  ],
};
const entry = (document = '{"SchemaVersion":1,"Probes":[]}') => ({ key, fingerprint: hash, id: 'custom.manufacturer', name: 'Fabricant déclaré', category: 'Personnelles', document, contract });
const preview = (choiceToken = 'before') => ({ choiceToken, documentSha256: hash, addedCount: 1, existingCount: 0, totalCount: 1, capacity: 64, candidates: [entry()], warnings: [] });
const personal = (choiceToken = 'before', entries = []) => ({ choiceToken, capacity: 64, persistent: true, entries });

async function mount(handler = () => undefined, options = {}) {
  const host = document.createElement('div'); host.dataset.page = 'accueil'; document.body.append(host);
  const calls = [];
  let applied = 0;
  const manager = createPersonalProbes(host, {
    ctx: { async call(op, args) {
      calls.push({ op, args });
      const result = await handler(op, args);
      if (result !== undefined) return result;
      if (op === 'accueil.probes.personal') return personal();
      if (op === 'accueil.probes.preview') return preview();
      if (op === 'accueil.probes.apply') return { catalog: personal('after', [entry(args.document)]), addedCount: 1, receipt: { persistent: true, readBack: true, text: 'Catalogue enregistré et relu.' } };
      throw new Error(op);
    } },
    onApplied() { applied += 1; }, ...options,
  });
  await manager.ready;
  host.querySelector('.pp-manager').open = true;
  return {
    host, calls, manager, applied: () => applied,
    editor: host.querySelector('[data-personal-editor]'),
    click(action) { host.querySelector(`[data-personal-action="${action}"]`).click(); },
    type(text) { const input = host.querySelector('[data-personal-editor]'); input.value = text; input.dispatchEvent(new Event('input')); },
    destroy() { manager.destroy(); host.remove(); },
  };
}

test('Sondes personnalisées : aperçu des droits, coût et inconnu ; annuler ne persiste et ne collecte rien', async () => {
  const ui = await mount();
  try {
    ui.type(' {"SchemaVersion":1,"Probes":[]}\n'); ui.click('preview'); await settle();
    const dialog = lastDialog();
    ok(dialog.textContent.includes('AdministrateurLocal') && dialog.textContent.includes('Coût\u00a0: Léger'), 'droits et coût explicites avant enregistrement');
    ok(dialog.textContent.includes('Inconnu : absence ou refus.'), 'sens de l’inconnu visible dans le vrai contrat');
    ok(dialog.textContent.includes('les widgets déjà présents gardent leur sonde'), 'pas de réaffectation implicite');
    eq(ui.calls.map(c => c.op), ['accueil.probes.personal', 'accueil.probes.preview'], 'prévisualisation strictement locale et sans écriture');
    dialog.querySelector('[data-id="cancel"]').click(); await settle();
    eq(ui.calls.length, 2, 'annulation ne lance rien');
    eq(ui.applied(), 0, 'catalogue non changé');
    eq(ui.editor.value, ' {"SchemaVersion":1,"Probes":[]}\n', 'document exact conservé');
  } finally { ui.destroy(); }
});

test('Sondes personnalisées : confirmation liée au texte exact, au choix et à l’empreinte ; ajout séparé', async () => {
  const ui = await mount(); const document = '\n {"SchemaVersion":1,"Probes":[]} \n';
  try {
    ui.type(document); ui.click('preview'); await settle();
    lastDialog().querySelector('[data-id="apply"]').click(); await settle();
    eq(ui.calls.find(c => c.op === 'accueil.probes.apply').args, { document, expectedChoiceToken: 'before', expectedDocumentSha256: hash }, 'applique exactement l’aperçu confirmé');
    eq(ui.calls.map(c => c.op), ['accueil.probes.personal', 'accueil.probes.preview', 'accueil.probes.apply'], 'aucune demande de widget ni collecte à l’import');
    eq(ui.applied(), 1, 'rechargement du catalogue une seule fois après réponse');
    eq(ui.editor.value, document, 'éditeur maintenu après sauvegarde');
    ok(ui.host.textContent.includes('aucune collecte n’a été lancée'), 'résultat dit l’absence de collecte');
    ui.host.querySelector('[data-personal-edit]').click();
    eq(ui.editor.value, document, 'édition repart de la version exacte du moteur');
    ok(ui.host.textContent.includes('les widgets existants conserveront leur sonde'), 'nouvelle version annoncée');
  } finally { ui.destroy(); }
});

test('Sondes personnalisées : conflit de profil garde le document et exige un nouvel aperçu', async () => {
  let reads = 0;
  const ui = await mount((op) => {
    if (op === 'accueil.probes.personal') return personal(++reads === 1 ? 'before' : 'concurrent');
    if (op === 'accueil.probes.apply') throw { code: 'probes.changed', message: 'Le catalogue a changé.' };
  });
  try {
    ui.type('document inchangé'); ui.click('preview'); await settle();
    lastDialog().querySelector('[data-id="apply"]').click(); await settle();
    eq(ui.editor.value, 'document inchangé', 'conflit ne remplace pas le document');
    eq(ui.calls.filter(c => c.op.endsWith('.apply')).length, 1, 'aucun nouvel essai automatique');
    ok(ui.host.querySelector('[data-personal-action="preview"]').disabled, 'ancien choix invalidé');
    ui.click('reload'); await settle();
    eq(ui.editor.value, 'document inchangé', 'actualisation du choix ne touche pas le document');
    ok(!ui.host.querySelector('[data-personal-action="preview"]').disabled, 'nouveau choix disponible pour un nouvel aperçu volontaire');
    eq(ui.calls.filter(c => c.op.endsWith('.preview')).length, 1, 'actualisation du catalogue ne déclenche pas d’aperçu ni d’application');
    eq(ui.applied(), 0, 'aucun succès inventé sur conflit');
  } finally { ui.destroy(); }
});

test('Sondes personnalisées : déclaration refusée intacte, persistance mémoire annoncée honnêtement', async () => {
  let refuse = true;
  const ui = await mount((op, args) => {
    if (op === 'accueil.probes.preview' && refuse) throw { code: 'probes.invalid', message: 'Droits non déclarés.' };
    if (op === 'accueil.probes.apply') return { catalog: { ...personal('memory', [entry(args.document)]), persistent: false }, addedCount: 1, receipt: { persistent: false, readBack: false, text: 'Conservé en mémoire seulement.' } };
  });
  try {
    ui.type('{"déclaration":"à corriger"}'); ui.click('preview'); await settle();
    eq(ui.editor.value, '{"déclaration":"à corriger"}', 'le refus conserve la saisie');
    eq(ui.calls.filter(c => c.op.endsWith('.apply')).length, 0, 'aucune application d’une déclaration refusée');
    refuse = false;
    ui.click('preview'); await settle(); lastDialog().querySelector('[data-id="apply"]').click(); await settle();
    eq(ui.host.querySelector('[data-personal-feedback]').dataset.tone, 'warn', 'la mémoire ne devient pas un succès disque');
    ok(ui.host.textContent.includes('Conservé en mémoire seulement.'), 'reçu réel visible');
  } finally { ui.destroy(); }
});

test('Sondes personnalisées : modification ou fermeture invalide un aperçu tardif', async () => {
  for (const action of ['edit', 'destroy']) {
    let deliver;
    const ui = await mount((op) => op === 'accueil.probes.preview' ? new Promise(resolve => { deliver = resolve; }) : undefined);
    try {
      ui.type('original'); ui.click('preview'); await settle();
      if (action === 'edit') ui.type('nouveau document'); else ui.manager.destroy();
      deliver(preview()); await settle();
      eq(ui.calls.filter(c => c.op.endsWith('.apply')).length, 0, 'aucune écriture tardive');
      eq(ui.applied(), 0, 'aucun changement annoncé');
      if (action === 'edit') eq(ui.editor.value, 'nouveau document', 'réponse périmée ne remplace pas le nouveau document');
      // An old closed dialog can remain during its leave animation; the current one must not be this preview.
      ok(![...document.querySelectorAll('.k-dlg [data-id="apply"]')].some(b => !b.closest('.k-dlg-layer')?.classList.contains('leaving') && b.closest('.k-dlg')?.textContent.includes('Catalogue local du profil')), 'pas de confirmation ouverte par une réponse périmée');
    } finally { ui.destroy(); }
  }
});

test('Sondes personnalisées : fichier préparé sans sauvegarde, borne UTF-8 sans troncature', async () => {
  let text = '\n{"SchemaVersion":1,"Probes":[]}\n';
  const ui = await mount(() => undefined, { chooseFile: async () => ({ fileName: 'sondes.json', text }) });
  try {
    ui.click('import'); await settle();
    eq(ui.editor.value, text, 'texte exact du fichier dans l’éditeur');
    eq(ui.calls.map(c => c.op), ['accueil.probes.personal'], 'choisir un fichier ne valide, persiste ou collecte rien');
    const original = ui.editor.value;
    text = 'é'.repeat(131073); // 262146 octets, malgré un nombre de caractères inférieur à la borne.
    ui.click('import'); await settle();
    eq(ui.editor.value, original, 'fichier trop grand refusé sans troncature ni perte de la saisie');
    ui.type(text); ui.click('preview'); await settle();
    eq(ui.calls.length, 1, 'même borne UTF-8 avant l’appel de prévisualisation');
    eq(ui.editor.value, text, 'texte trop grand conservé pour correction');
  } finally { ui.destroy(); }
});

test('Catalogue réel Accueil : import confirmé rend la sonde ajoutable sans créer de widget à l’import', async () => {
  let saved = false; const calls = []; const items = [];
  const catalog = () => ({
    groups: [], visualNames: { Bar: 'Barres' }, sizeNames: { M: 'Moyenne' }, probeCount: saved ? 1 : 0, queries: [], queriesText: 'Aucune requête.',
    probes: saved ? [{ name: 'Personnelles', probes: [{ id: key, name: 'Fabricant déclaré', category: 'Personnelles', class: 'Win32_ComputerSystem', description: 'Description <img src=x onerror=evil()>', compatibility: 'Windows avec CIMWin32', summary: contract.summary, visuals: ['Bar'], visual: 'Bar', slow: true, skipOnDc: true, origin: 'Personnalisée' }] }] : [],
  });
  const board = { has: (source, id) => items.some(i => i.source === source && i.key === id), count: () => items.length, max: () => 64, async add(values) { items.push(...values); } };
  const drawer = openCatalog({
    board, onProbe() {},
    ctx: { toast() {}, async call(op, args) {
      calls.push({ op, args });
      if (op === 'accueil.widgets.catalog') return catalog();
      if (op === 'accueil.probes.personal') return personal();
      if (op === 'accueil.probes.preview') return preview();
      if (op === 'accueil.probes.apply') { saved = true; return { catalog: personal('after', [entry(args.document)]), addedCount: 1, receipt: { persistent: true, readBack: true, text: 'Catalogue relu.' } }; }
      throw new Error(op);
    } },
  });
  try {
    await settle(); drawer.body.querySelector('[data-tab="probes"]').click(); await settle();
    drawer.body.querySelector('.pp-manager').open = true;
    const editor = drawer.body.querySelector('[data-personal-editor]');
    editor.value = '{"SchemaVersion":1,"Probes":[]}'; editor.dispatchEvent(new Event('input'));
    drawer.body.querySelector('[data-personal-action="preview"]').click(); await settle();
    lastDialog().querySelector('[data-id="apply"]').click(); await settle();
    eq(items.length, 0, 'enregistrer la déclaration ne crée pas de widget');
    eq(calls.filter(c => c.op === 'accueil.widgets.catalog').length, 2, 'catalogue réel relu après enregistrement');
    const heading = drawer.body.querySelector('.cat-item.probe h4');
    eq(heading.title, 'Win32_ComputerSystem', 'classe exacte dans l’infobulle');
    ok(drawer.body.textContent.includes('Windows avec CIMWin32'), 'compatibilité visible');
    ok(drawer.body.textContent.includes('Description <img src=x onerror=evil()>'), 'description exacte');
    ok(!drawer.body.querySelector('.cat-item.probe img'), 'description échappée');
    const search = drawer.body.querySelector('.cat-search input'); search.value = 'Win32_ComputerSystem'; search.dispatchEvent(new Event('input'));
    eq(drawer.body.querySelectorAll('.cat-item.probe').length, 1, 'filtre par classe effectivement raccordé');
    const add = drawer.body.querySelector('[data-cat-add]');
    ok(add && add.dataset.catAdd === `probe|${key}`, 'version immuable proposée par le catalogue');
    ok(!calls.some(c => c.op.startsWith('accueil.widget.') || c.op.startsWith('accueil.refresh.')), 'aucune collecte réseau à l’import');
    add.click(); await settle();
    eq(items.map(i => ({ source: i.source, key: i.key })), [{ source: 'probe', key }], 'le geste Ajouter utilise le chemin normal et la clé exacte');
  } finally { drawer.close(); await drawer.closed; }
});
