// Real Poste/Logiciels renderers and their shared persisted layout. Registered for the final VM browser run only.
import { test, eq, ok, throws } from './harness.mjs';
import { createBoardLayout } from '../../web/js/pages/poste/board-layout.js';
import { computerCard } from '../../web/js/pages/poste/overview.js';
import { softwareCard, renderInventory } from '../../web/js/pages/poste/inventory.js';
import { createProbeCards } from '../../web/js/pages/poste/probe-cards.js';
import { createQueryCards } from '../../web/js/pages/poste/query-cards.js';

const item = (id, key, paused = false) => ({ id, key, source: 'builtin', visual: 'Kpi', size: 'S', title: null, paused, group: '' });
const view = (items, board = 'Computer') => ({ board, stored: true, valid: true, items, catalog: items.map((i) => ({ key: i.key, title: `Titre ${i.id}`, visual: 'Kpi', size: 'S' })) });
const host = () => { const el = document.createElement('div'); document.body.append(el); return el; };
const settle = async () => { for (let i = 0; i < 8; i++) await Promise.resolve(); };

test('Sections et présentations : édition, ordre exact des sections contiguës et sauvegarde fidèle', async () => {
  const el = host(); let saved;
  const items = [{ ...item('a', 'computer.memory.usage'), group: 'A', visual: 'Gauge' },
    { ...item('b', 'computer.cpu.load', true), group: 'B', visual: 'Gauge' },
    { ...item('c', 'computer.battery'), group: 'A', visual: 'Gauge' }];
  const current = { ...view(items), catalog: items.map((i) => ({ key: i.key, title: i.id, visual: 'Gauge', visuals: ['Gauge', 'Kpi', 'Text'], size: 'S' })) };
  const layout = createBoardLayout(el, { call: async (op, args) => { if (op === 'poste.layout.save') saved = args; return current; } }, 'Computer', () => {});
  let dialog;
  try {
    await layout.load(); el.innerHTML = layout.toolbar() + layout.render(() => '<p>Valeur</p>');
    eq([...el.querySelectorAll('.ps-layout-group')].map((n) => n.textContent), ['A', 'B', 'A'], 'aucun regroupement ne change l’ordre importé');
    eq([...el.querySelectorAll('[data-layout-item]')].map((n) => n.dataset.layoutItem), ['a', 'b', 'c'], 'ordre des cartes inchangé');
    el.querySelector('[data-layout-edit]').click(); dialog = [...document.querySelectorAll('.k-dlg')].at(-1);
    const row = dialog.querySelector('[data-layout-row="0"]');
    row.querySelector('[data-field="group"]').value = '<Mes ressources>';
    row.querySelector('[data-field="visual"]').value = 'Text';
    dialog.querySelector('[data-id="save"]').click(); await settle();
    eq(saved.items[0].group, '<Mes ressources>', 'section explicite persistée');
    eq(saved.items[0].visual, 'Text', 'vraie présentation choisie persistée');
    eq(saved.items[1].paused, true, 'pause des autres cartes conservée');
  } finally { dialog?.querySelector('[data-id="cancel"]')?.click(); layout.destroy(); el.remove(); }
});

test('Présentations réelles : histogrammes, anneaux, listes et barres conservent valeurs, inconnus et filtres logiciels', () => {
  const el = host();
  const software = { board: { tiles: [], publishers: [
    { field: 'publisher', value: 'A', label: 'Éditeur A', count: 5, clickable: true },
    { field: 'publisher', value: 'unknown', label: 'Inconnu', count: 2, clickable: false },
  ] } };
  try {
    for (const visual of ['Pie', 'Bar', 'Column', 'Text', 'Kpi']) {
      el.innerHTML = softwareCard(software, 'software.publishers', 'Éditeurs', visual);
      eq(el.querySelectorAll('[data-part]').length, 1, `filtre conservé en ${visual}`);
      eq(el.querySelector('[data-part]').dataset.part, 'publisher|A|Éditeur A', 'filtre précis inchangé');
      ok(el.textContent.includes('5') && el.textContent.includes('2'), 'mêmes comptes réels');
      if (visual === 'Column') eq(el.querySelectorAll('svg rect').length, 2, 'deux barres verticales réelles');
      if (visual === 'Text') ok(!el.querySelector('svg'), 'liste sans graphique');
    }
    const computer = { board: { resources: { memory: { percent: 61, state: 'warn', detail: 'Mesuré' } } } };
    for (const visual of ['Gauge', 'Kpi', 'Text']) {
      el.innerHTML = computerCard(computer, 'computer.memory.usage', 'Mémoire', visual);
      ok(el.textContent.includes('61'), `même mesure en ${visual}`);
    }
    el.innerHTML = computerCard({ board: { widgetValues: [{ key: 'computer.display', value: 'Carte réelle', detail: '2560 × 1440 pixels · relevé daté', state: 'info' }] } }, 'computer.display', 'Affichage');
    ok(el.textContent.includes('Carte réelle') && el.textContent.includes('2560 × 1440'), 'carte et résolution typées réellement consommées');
  } finally { el.remove(); }
});

test('Requêtes Poste : pause et [] ne calculent rien, carte active affiche sa révision locale sans bibliothèque déduite', async () => {
  const el = host(); const calls = []; const opens = [];
  const data = { computer: { guid: '11111111-1111-1111-1111-111111111111' } };
  const state = { dn: 'CN=PC,DC=test', data, ctx: { navigate: (...args) => opens.push(args) }, call: async (op, args) => {
    calls.push([op, args]); return { title: 'Ma recette', recipeId: 'recipe', revision: 1, currentRevision: 2,
      verdict: 'unknown', explanation: 'Inventaire absent', provenance: 'Révision 1 · empreinte vérifiée · révision 2 à confirmer' };
  } };
  const queries = createQueryCards(el, state);
  let chosen = [{ ...item('paused', 'd1q-paused', true), source: 'query' }, { ...item('active', 'd1q-active'), source: 'query' }];
  const layout = createBoardLayout(el, { call: async () => view(chosen) }, 'Computer', () => {});
  try {
    await layout.load(); el.innerHTML = layout.render(queries.render); queries.refresh(); await settle();
    eq(calls, [['poste.layout.query', { dn: state.dn, computer: data.computer.guid, item: 'active' }]], 'seule carte active exacte, pas de widget.list ni collecte');
    ok(el.textContent.includes('Inconnu') && el.textContent.includes('Révision 1'), 'inconnu et révision réellement rendus');
    el.querySelector('[data-query-open]').click(); eq(opens, [['requetes', { recette: 'recipe', onglet: 'enregistrer' }]], 'vraie recette ouverte');
    chosen = []; await layout.load(); el.innerHTML = layout.render(queries.render); queries.refresh(); await settle();
    eq(calls.length, 1, '[] ne lance aucun calcul supplémentaire');
  } finally { queries.destroy(); layout.destroy(); el.remove(); }
});

test('Migration Query : l’aperçu montre la nouvelle liaison, annuler ne lie rien, confirmer transmet son empreinte', async () => {
  const el = host(); const calls = [];
  const hash = 'b'.repeat(64); const source = 'a'.repeat(64); const seal = 'c'.repeat(64);
  const proposal = { board: 'Computer', state: 'ready', summary: 'Nouvelle liaison à confirmer', queryBindingsSha256: seal,
    items: [{ ...item('d1', 'd1q-example'), source: 'query', queryBinding: { name: 'Recette réelle', revision: 7, fingerprint: hash, currentRevisionProposed: true } }] };
  const layout = createBoardLayout(el, { call: async (op, args) => {
    calls.push([op, args]);
    if (op === 'shell.interface.migration.preview') return { available: true, sourceSha256: source, boards: [proposal] };
    if (op === 'shell.interface.migrate') return { applied: true, summary: 'Liée' };
    return view([]);
  } }, 'Computer', () => {});
  let dialog;
  try {
    await layout.load(); el.innerHTML = layout.toolbar(); el.querySelector('[data-layout-import]').click(); await settle();
    dialog = [...document.querySelectorAll('.k-dlg')].at(-1);
    ok(dialog.textContent.includes('révision 7') && dialog.textContent.includes(hash), 'révision et empreinte visibles');
    ok(dialog.querySelector('[data-id="apply"]').textContent.includes('lier ces révisions'), 'confirmation nomme la liaison');
    dialog.querySelector('[data-id="cancel"]').click(); await settle();
    eq(calls.filter(([op]) => op === 'shell.interface.migrate').length, 0, 'aperçu puis annulation sans écriture');
    el.querySelector('[data-layout-import]').click(); await settle(); dialog = [...document.querySelectorAll('.k-dlg')].at(-1);
    dialog.querySelector('[data-id="apply"]').click(); await settle();
    eq(calls.find(([op]) => op === 'shell.interface.migrate')[1], { board: 'Computer', sourceSha256: source, queryBindingsSha256: seal }, 'seule empreinte confirmée envoyée, jamais recette ni droits');
  } finally { dialog?.querySelector('[data-id="cancel"]')?.click(); layout.destroy(); el.remove(); }
});

const probeResult = (page = 1) => ({ status: { state: 'read' }, statusLabel: 'Lue', provenance: 'Relevé daté du cache',
  probe: { limitations: 'Firmware incomplet possible', unknownMeaning: 'Absence reste inconnue' },
  columns: ['Name', 'Capacity'], rows: [['<DIMM A>', null]], total: 101, page, pages: 2 });

test('Sondes Poste : pause sans lecture, doublons dédupliqués, pagination locale et provenance réelle', async () => {
  const el = host(); const calls = [];
  const items = [{ ...item('paused', 'hw.processors', true), source: 'probe' },
    { ...item('a', 'hw.memorymodules'), source: 'probe' }, { ...item('b', 'hw.memorymodules'), source: 'probe' }];
  const state = { dn: 'CN=PC,DC=test', data: { computer: { guid: '11111111-1111-1111-1111-111111111111' } }, call: async (op, args) => {
    calls.push([op, args]); return op === 'poste.layout.get' ? view(items) : probeResult(args.page);
  } };
  const probes = createProbeCards(el, state);
  const layout = createBoardLayout(el, state, 'Computer', () => {});
  try {
    await layout.load(); el.innerHTML = layout.render(probes.render); probes.refresh(); await settle();
    eq(calls.map(([op]) => op), ['poste.layout.get', 'poste.layout.probe'], 'une seule lecture locale de sonde active');
    eq(calls[1][1], { dn: state.dn, computer: state.data.computer.guid, probe: 'hw.memorymodules', page: 1 }, 'identité exacte de la sonde');
    eq(el.querySelectorAll('[data-probe-card]').length, 2, 'deux cartes alimentées par le même résultat');
    ok(el.textContent.includes('<DIMM A>') && !el.querySelector('DIMM'), 'valeur affichée comme texte');
    ok(el.textContent.includes('Non lu') && el.textContent.includes('Relevé daté du cache'), 'inconnu et provenance préservés');
    el.querySelector('[data-probe-page="2"]').click(); await settle();
    eq(calls[2][1].page, 2, 'seule la page locale demandée');
    ok(el.textContent.includes('page 2 / 2'), 'page affichée');
  } finally { layout.destroy(); probes.destroy(); el.remove(); }
});

test('Sondes Poste : deux lectures au plus, les cartes masquées ne démarrent pas et la destruction ignore les retours', async () => {
  const el = host(); const calls = []; const pending = [];
  const probes = createProbeCards(el, { dn: 'CN=PC,DC=test', data: { computer: { guid: '11111111-1111-1111-1111-111111111111' } }, call: (op, args) => {
    calls.push(args.probe); return new Promise((resolve) => pending.push(resolve));
  } });
  try {
    el.innerHTML = ['hw.memorymodules', 'hw.processors', 'hw.batteries'].map((key) => probes.render({ key }, key)).join('');
    probes.refresh(); await settle(); eq(calls.length, 2, 'concurrence bornée');
    el.querySelector('[data-probe-card="hw.batteries"]').remove();
    pending[0](probeResult()); await settle();
    eq(calls.length, 2, 'carte masquée pendant l’attente jamais lue');
    probes.destroy(); el.textContent = 'Autre écran'; pending[1](probeResult()); await settle();
    eq(el.textContent, 'Autre écran', 'retour tardif ne repeint pas un écran détruit');
  } finally { probes.destroy(); el.remove(); }
});

test('Éditeur Poste : l’ajout d’une sonde conserve sa source et ne devient pas une carte intégrée', async () => {
  const el = host(); let write;
  const current = { ...view([]), catalog: [{ key: 'hw.memorymodules', title: 'Barrettes', source: 'probe', visual: 'Table', size: 'L', default: false }] };
  const layout = createBoardLayout(el, { call: async (op, args) => {
    if (op === 'poste.layout.save') write = args; return current;
  } }, 'Computer', () => {});
  let dialog;
  try {
    await layout.load(); el.innerHTML = layout.toolbar(); el.querySelector('[data-layout-edit]').click();
    dialog = [...document.querySelectorAll('.k-dlg')].at(-1);
    dialog.querySelector('[data-add]').click(); dialog.querySelector('[data-id="save"]').click(); await settle();
    eq(write.items[0].source, 'probe', 'contrat de source conservé');
    eq(write.items[0].key, 'hw.memorymodules', 'catalogue détaillé exact');
  } finally { dialog?.querySelector('[data-id="cancel"]')?.click(); layout.destroy(); el.remove(); }
});

test('Poste : ordre, titres et pause utilisent le rendu réel sans évaluer la carte arrêtée', async () => {
  const el = host();
  const items = [item('pause', 'computer.cpu.load', true), { ...item('ram', 'computer.memory.usage'), title: '<Ma mémoire>' }];
  const calls = [];
  const layout = createBoardLayout(el, { call: async (op) => { calls.push(op); return view(items); } }, 'Computer', () => {});
  let cpuRead = 0;
  const resources = { memory: { percent: 61, detail: '9,8 Gio sur 16 Gio', state: 'warn' }, get cpu() { cpuRead++; throw new Error('Carte en pause évaluée'); } };
  try {
    await layout.load();
    el.innerHTML = layout.render((i, title) => computerCard({ board: { resources } }, i.key, title));
    eq([...el.querySelectorAll('[data-layout-item]')].map((n) => n.dataset.layoutItem), ['pause', 'ram'], 'ordre conservé dans le DOM');
    eq(cpuRead, 0, 'carte en pause jamais rendue');
    eq(el.querySelector('[role="meter"]').getAttribute('aria-valuenow'), '61', 'vraie mesure du snapshot');
    ok(el.textContent.includes('<Ma mémoire>'), 'titre affiché comme texte');
    ok(el.textContent.includes('En pause'), 'pause visible');
    eq(calls, ['poste.layout.get'], 'lecture locale de disposition seulement');
  } finally { layout.destroy(); el.remove(); }
});

test('Poste : [] et disposition incompatible ne réintroduisent aucune carte', async () => {
  const el = host();
  let current = view([]);
  const layout = createBoardLayout(el, { call: async () => current }, 'Computer', () => {});
  let renders = 0;
  try {
    await layout.load();
    el.innerHTML = layout.render(() => { renders++; return 'faux défaut'; });
    eq(renders, 0, '[] ne rend rien');
    ok(el.textContent.includes('volontairement vide'), '[] expliqué');
    current = { ...current, valid: false, reason: 'Original conservé' };
    await layout.load();
    el.innerHTML = layout.render(() => { renders++; return 'faux défaut'; });
    eq(renders, 0, 'incompatible ne rend rien');
    ok(el.querySelector('[role="alert"]'), 'incompatibilité exposée');
  } finally { layout.destroy(); el.remove(); }
});

test('Poste : aucune mesure inconnue ne devient zéro et les clés inconnues échouent', () => {
  const el = host();
  try {
    el.innerHTML = computerCard({ board: { counts: [{ key: 'computer.devices', value: null, detail: 'Source absente' }] } }, 'computer.devices', 'Périphériques');
    ok(el.textContent.includes('Non lu'), 'compteur inconnu distinct de zéro');
    el.innerHTML = computerCard({ board: { resources: { memory: { percent: null, detail: 'Non lu', state: 'off' } } } }, 'computer.memory.usage', 'Mémoire');
    ok(!el.querySelector('[aria-valuenow]'), 'jauge inconnue sans valeur fictive');
    throws(() => computerCard({ board: {} }, 'computer.unknown', 'Inconnue'), 'clé inconnue rejetée');
  } finally { el.remove(); }
});

test('Logiciels : vraies valeurs et filtres cliquables gardent leur provenance', () => {
  const el = host();
  const data = { board: { tiles: [{ key: 'software.count', value: '17', detail: 'Inventaire local', empty: false }], publishers: [
    { field: 'publisher', value: 'Éditeur', label: 'Éditeur', count: 5, clickable: true },
    { field: 'publisher', value: 'unknown', label: 'Non renseigné', count: 12, clickable: false },
  ] } };
  try {
    el.innerHTML = softwareCard(data, 'software.count', 'Mes logiciels') + softwareCard(data, 'software.publishers', 'Éditeurs');
    eq(el.querySelector('.ps-soft-tile b').textContent, '17', 'compte du vrai SoftwareBoard');
    ok(el.textContent.includes('Inventaire local'), 'détail de la source conservé');
    eq(el.querySelectorAll('[data-part]').length, 1, 'part inconnue jamais cliquable');
    eq(el.querySelector('[data-part]').dataset.part, 'publisher|Éditeur|Éditeur', 'filtre de liste utilisable');
    throws(() => softwareCard(data, 'software.unknown', 'Inconnu'), 'aucun faux consommateur');
  } finally { el.remove(); }
});

test('Éditeur Poste : réordonne, change le titre et la pause, puis persiste [] explicitement', async () => {
  const el = host();
  let stored = view([item('a', 'computer.cpu.load'), item('b', 'computer.memory.usage')]);
  const writes = [];
  const layout = createBoardLayout(el, { call: async (op, args) => {
    if (op === 'poste.layout.save') { writes.push(structuredClone(args)); stored = { ...stored, items: args.items }; }
    return stored;
  } }, 'Computer', () => {});
  let dialog;
  try {
    await layout.load();
    el.innerHTML = layout.toolbar();
    el.querySelector('[data-layout-edit]').click();
    dialog = [...document.querySelectorAll('.k-dlg')].at(-1);
    const row = dialog.querySelector('[data-layout-row="1"]');
    row.querySelector('[data-field="title"]').value = 'Mémoire prioritaire';
    row.querySelector('[data-field="paused"]').checked = true;
    row.querySelector('[data-move="-1"]').click();
    dialog.querySelector('[data-id="save"]').click();
    await settle();
    eq(writes[0].items.map((i) => i.id), ['b', 'a'], 'ordre envoyé au vrai contrat de sauvegarde');
    eq(writes[0].items[0].title, 'Mémoire prioritaire', 'saisie conservée lors du déplacement');
    eq(writes[0].items[0].paused, true, 'pause conservée');
    el.querySelector('[data-layout-edit]').click();
    dialog = [...document.querySelectorAll('.k-dlg')].at(-1);
    while (dialog.querySelector('[data-remove]')) dialog.querySelector('[data-remove]').click();
    dialog.querySelector('[data-id="save"]').click();
    await settle();
    eq(writes[1], { board: 'Computer', items: [] }, 'tableau vide envoyé explicitement');
  } finally { dialog?.querySelector('[data-id="cancel"]')?.click(); layout.destroy(); el.remove(); }
});

test('Page Logiciels : une synthèse masquée ou vide ne lit pas les cartes et ne contacte pas le poste', async () => {
  const el = host();
  const calls = [];
  let dataReads = 0;
  const cached = { origin: 'Inventaire local', provenance: 'Cache', accessSummary: 'Lecture locale', complete: false, total: 0, rows: [], columns: {},
    get board() { dataReads++; throw new Error('Synthèse masquée ou vide évaluée'); } };
  const destroy = renderInventory(el, { initialTab: 'logiciels', dn: 'CN=PC,DC=test', on: () => () => {},
    call: async (op) => {
      calls.push(op);
      if (op === 'poste.layout.get') return view([], 'Software');
      if (op === 'poste.software.cached') return cached;
      throw new Error(`Lecture inattendue ${op}`);
    } });
  try {
    await settle();
    eq(dataReads, 0, 'aucune carte lue en vue liste');
    el.querySelector('[data-view="synthese"]').click();
    eq(dataReads, 0, '[] évite toute lecture de carte');
    ok(el.textContent.includes('volontairement vide'), 'le vrai consommateur affiche []');
    eq(calls.sort(), ['poste.layout.get', 'poste.software.cached'], 'uniquement les deux lectures locales');
  } finally { destroy(); el.remove(); }
});

test('Disposition détruite : un résultat tardif ne repeint pas la page suivante', async () => {
  const el = host();
  let finish;
  let paints = 0;
  const layout = createBoardLayout(el, { call: () => new Promise((resolve) => { finish = resolve; }) }, 'Computer', () => { paints++; });
  const pending = layout.load();
  layout.destroy();
  finish(view([]));
  await pending;
  eq(paints, 0, 'résultat tardif ignoré');
  el.remove();
});

test('Poste : cartes détaillées D1 consomment les valeurs réelles, les inconnus restent inconnus', () => {
  const el = host();
  const line = (key, value) => ({ key, value, detail: 'Provenance inventaire', state: 'info', copy: false });
  const board = {
    identity: { lines: [line('computer.os', 'Windows 11'), line('computer.ip', '192.0.2.14')] },
    adAccount: { lines: [line('computer.ad.password', 'il y a 12 j'), line('computer.ad.account', 'Activé')] },
    protection: { lines: [line('computer.bitlocker', 'Protection suspendue'), line('computer.hotfix', 'il y a 5 j')] },
    widgetValues: [line('computer.wsus', 'WSUS déclaré (non appliqué)'), line('computer.updates', '26100.1234')],
    counts: [{ key: 'computer.admins', value: 3, detail: 'Domaine\\Support' }, { key: 'computer.drivers', value: null, detail: 'Non lu' }],
    sections: [{ key: 'certificates', value: '2 certificats', detail: '1 expiré · lecture partielle', state: 'warn', facts: [] }],
    health: { points: [{ level: 'warn', text: 'Contrôle incomplet', route: { view: 'inventaire', tab: 'materiel', label: 'Voir l’inventaire' } }], detail: 'Données locales', state: 'warn' },
  };
  try {
    const expected = {
      'computer.os': 'Windows 11', 'computer.ip': '192.0.2.14', 'computer.ad.password': 'il y a 12 j',
      'computer.ad.account': 'Activé', 'computer.bitlocker': 'Protection suspendue', 'computer.hotfix': 'il y a 5 j',
      'computer.wsus': 'WSUS déclaré (non appliqué)', 'computer.updates': '26100.1234', 'computer.admins': '3',
      'computer.drivers': 'Non lu', 'computer.certificates': '1 expiré · lecture partielle', 'computer.attention': 'Contrôle incomplet',
    };
    for (const [key, text] of Object.entries(expected)) {
      el.innerHTML = computerCard({ board }, key, 'Titre personnel');
      ok(el.textContent.includes(text), `${key} rend sa vraie donnée`);
      ok(el.textContent.includes('Titre personnel'), `${key} conserve son titre`);
    }
    for (const key of ['computer.model', 'computer.cpu', 'computer.memory', 'computer.uptime', 'computer.user', 'computer.domain',
      'computer.ad.lastlogon', 'computer.ad.ou', 'computer.ad.laps', 'computer.ad.managedby', 'computer.ad.clock',
      'computer.antivirus', 'computer.firewall', 'computer.secureboot', 'computer.reboot', 'computer.sessions', 'computer.autostart',
      'computer.shares', 'computer.printers', 'computer.display', 'computer.physicaldisk']) {
      el.innerHTML = computerCard({ board }, key, key);
      ok(el.textContent.includes('Non lu'), `${key} n’invente aucune donnée`);
    }
    el.innerHTML = computerCard({ board }, 'computer.attention', 'Points');
    eq(el.querySelector('[data-route]').dataset.route, 'inventaire/materiel', 'action de la carte reste utilisable');
  } finally { el.remove(); }
});

test('Import Poste : le geste transmet les deux empreintes de l’aperçu et aucune donnée de configuration', async () => {
  const el = host();
  const calls = [];
  const sha = 'a'.repeat(64), configSha = 'b'.repeat(64);
  const proposal = { board: 'Computer', state: 'ready', choiceExists: false, summary: 'Disposition d’équipe locale', items: [],
    teamSource: { path: 'C:\\D1\\Domenia.config.json', sha256: configSha, setting: 'Dashboard.DefaultLayoutComputer' } };
  const layout = createBoardLayout(el, { call: async (op, args) => {
    calls.push({ op, args });
    if (op === 'shell.interface.migration.preview') return { available: true, sourcePath: 'C:\\D1\\Domenia.settings.json', sourceSha256: sha, boards: [proposal], warnings: [] };
    if (op === 'shell.interface.migrate') return { applied: true, summary: 'Importée' };
    return view([]);
  } }, 'Computer', () => {});
  let dialog;
  try {
    await layout.load();
    el.innerHTML = layout.toolbar();
    el.querySelector('[data-layout-import]').click();
    await settle();
    dialog = [...document.querySelectorAll('.k-dlg')].at(-1);
    ok(dialog.textContent.includes('Domenia.settings.json') && dialog.textContent.includes('Domenia.config.json'), 'les deux sources sont visibles avant décision');
    dialog.querySelector('[data-id="apply"]').click();
    await settle();
    eq(calls.find((c) => c.op === 'shell.interface.migrate').args,
      { board: 'Computer', sourceSha256: sha, configurationSha256: configSha }, 'empreintes seules, sans chemins ni disposition fournis au moteur');
  } finally { dialog?.querySelector('[data-id="cancel"]')?.click(); layout.destroy(); el.remove(); }
});

test('Glisser-déposer réel : ordre, pause, section et liaison gardés sur Poste et Logiciels', async () => {
  for (const board of ['Computer', 'Software']) {
    const el = host(); let saved; let dialog;
    const keys = board === 'Computer' ? ['computer.os', 'computer.cpu', 'computer.memory'] : ['software.count', 'software.size', 'software.recent'];
    const items = keys.map((key, n) => ({ ...item(String(n), key, n === 1), group: `G${n}` }));
    if (board === 'Computer') items[0] = { ...items[0], source: 'query', key: 'd1q-proof', visual: 'Text', queryBinding: { recipeId: 'real', revision: 2, fingerprint: 'a'.repeat(64), libraryWidgetId: 'b'.repeat(32) } };
    const current = { ...view(items, board), choiceToken: 'f'.repeat(64) };
    const layout = createBoardLayout(el, { call: async (op, args) => { if (op === 'poste.layout.save') { saved = args; return { ...current, items: args.items }; } return current; } }, board, () => {});
    try {
      await layout.load(); el.innerHTML = layout.toolbar(); el.querySelector('[data-layout-edit]').click();
      dialog = [...document.querySelectorAll('.k-dlg')].at(-1);
      const editor = dialog.querySelector('.ps-layout-editor');
      editor.querySelector('[data-layout-row="0"] [data-field="title"]').value = 'Titre avant déplacement';
      const transfer = { setData() {}, effectAllowed: '', dropEffect: '' };
      const fire = (target, type) => { const event = new Event(type, { bubbles: true, cancelable: true }); Object.defineProperty(event, 'dataTransfer', { value: transfer }); target.dispatchEvent(event); };
      // An external drop alone must not reorder or create any item.
      fire(editor.querySelector('[data-layout-row="2"]'), 'drop');
      eq(editor.querySelector('[data-layout-row="0"] [data-field="title"]').value, 'Titre avant déplacement', 'texte extérieur ignoré');
      fire(editor.querySelector('[data-layout-row="0"] [data-drag-handle]'), 'dragstart');
      fire(editor.querySelector('[data-layout-row="2"]'), 'dragover');
      ok(editor.querySelector('[data-layout-row="2"]').classList.contains('ps-layout-drop'), 'destination visible');
      fire(editor.querySelector('[data-layout-row="2"]'), 'drop');
      dialog.querySelector('[data-id="save"]').click(); await settle();
      eq(saved.items.map(i => i.id), ['1', '2', '0'], 'ordre effectivement transmis au vrai handler de disposition');
      eq(saved.expectedChoiceToken, current.choiceToken, 'sauvegarde liée au choix montré à l’ouverture');
      eq(saved.items[0].paused, true, 'pause conservée');
      eq(saved.items[2].title, 'Titre avant déplacement', 'saisie non perdue lors du déplacement');
      eq(saved.items[2].group, 'G0', 'section reste liée à la carte');
      if (board === 'Computer') eq(saved.items[2].queryBinding, items[0].queryBinding, 'révision et identité de widget intactes');
    } finally { dialog?.querySelector('[data-id="cancel"]')?.click(); layout.destroy(); el.remove(); }
  }
});
