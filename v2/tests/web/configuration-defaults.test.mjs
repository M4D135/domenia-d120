import { test, eq, ok } from './harness.mjs';
import { mount } from '../../web/js/pages/parametres/configuration-distribuable.js';
import { applyImportedInterface, proposePackConfiguration } from '../../web/js/shell/configuration-defaults.js';
const settle = async () => { for (let n = 0; n < 24; n++) await Promise.resolve(); };
const lastDialog = () => [...document.querySelectorAll('.k-dlg')].at(-1);

test('Configuration à diffuser : OU explicite, écriture sur place confirmée et succès seulement après résultat', async () => {
  const host = document.createElement('div'); document.body.append(host); const calls = []; const messages = [];
  let releasePackage;
  const ctx = { prefs: { get: () => ({ theme: 'system', motion: 'full', navCollapsed: false, profile: 'essentiel', density: 'normal', helpTips: true }), set() {} }, toast: text => messages.push(text), async call(op, args) {
    calls.push({ op, args });
    if (op === 'settings.configuration.options') return { simulated: false, fileName: 'Domenia.settings.seed.json', fingerprint: 'current', excluded: ['settings.connection'], choices: [
      { key: 'settings.zoom', label: 'Zoom', value: 100, valid: true, selected: true },
      { key: 'session.workingScope.hash', label: 'OU de travail', value: { dn: 'OU=Equipe,DC=example,DC=invalid' }, valid: true, selected: false },
    ] };
    if (op === 'settings.configuration.export') return { text: '{"configuration":"exacte"}', sha256: 'abc', included: args.keys, excluded: ['settings.connection'] };
    if (op === 'settings.defaults.package') return new Promise(resolve => { releasePackage = resolve; });
    throw new Error(op);
  } };
  const page = mount(host, ctx);
  try {
    await settle();
    ok(!host.querySelector('[data-config-key="session.workingScope.hash"]').checked, 'OU non choisie par défaut');
    host.querySelector('[data-config-key="session.workingScope.hash"]').checked = true;
    host.querySelector('[data-config-action="package"]').click(); await settle();
    eq(calls.find(c => c.op === 'settings.configuration.export').args.keys, ['settings.zoom', 'session.workingScope.hash'], 'sélection réelle transmise');
    const text = lastDialog().textContent;
    ok(text.includes('settings.connection') && text.includes('wad/Domenia.settings.seed.json') && text.includes('ZIP officiel, le manifeste et les binaires restent intacts'), 'emplacement, portée et exclusion visibles');
    eq(lastDialog().querySelector('[data-id="confirm"]').textContent.trim(), 'Écrire la configuration par défaut', 'action sur place nommée');
    lastDialog().querySelector('[data-id="confirm"]').click(); await settle();
    eq(calls.find(c => c.op === 'settings.defaults.package').args, { text: '{"configuration":"exacte"}' }, 'texte validé exact, pas d’options recomposées');
    eq(messages.length, 0, 'aucun succès avant résultat');
    releasePackage({ simulated: false, file: 'C:\\Domenia\\wad\\Domenia.settings.seed.json', message: 'Configuration par défaut écrite dans wad/Domenia.settings.seed.json.' }); await settle();
    eq(messages, ['Configuration par défaut écrite dans wad/Domenia.settings.seed.json.'], 'message du résultat réel');
    eq(host.querySelector('[data-config-result]').textContent, 'Configuration par défaut écrite dans wad/Domenia.settings.seed.json.', 'résultat conservé dans la page');
  } finally { page.destroy(); host.remove(); }
});

test('Configuration à diffuser : après écriture, empreinte relue et choix conservés pour une seconde écriture', async () => {
  // Banc 2.1.6 (kit e46237d5) : la décision du profil enregistrée après l’écriture changeait l’empreinte ; le clic
  // suivant était refusé « Préférences modifiées depuis la sélection ».
  const host = document.createElement('div'); document.body.append(host); const calls = []; const messages = [];
  let fingerprint = 'avant-ecriture';
  const ctx = { prefs: { get: () => ({ theme: 'system', motion: 'full', navCollapsed: false, profile: 'essentiel', density: 'normal', helpTips: true }), set() {} }, toast: text => messages.push(text), async call(op, args) {
    calls.push({ op, args });
    if (op === 'settings.configuration.options') return { simulated: false, fileName: 'Domenia.settings.seed.json', fingerprint, excluded: [], choices: [
      { key: 'settings.zoom', label: 'Zoom', value: 100, valid: true, selected: true },
      { key: 'session.workingScope.hash', label: 'OU de travail', value: { dn: 'OU=Equipe,DC=example,DC=invalid' }, valid: true, selected: false },
    ] };
    if (op === 'settings.configuration.export') {
      if (args.fingerprint !== fingerprint) throw new Error('Préférences modifiées depuis la sélection ; relisez les choix.');
      return { text: JSON.stringify({ keys: args.keys, ui: args.interface !== null }), sha256: 'abc', included: args.keys, excluded: [] };
    }
    if (op === 'settings.defaults.package') { fingerprint = 'decision-enregistree'; return { simulated: false, message: 'Configuration par défaut écrite dans wad/Domenia.settings.seed.json.' }; }
    throw new Error(op);
  } };
  const page = mount(host, ctx);
  try {
    await settle();
    host.querySelector('[data-config-key="session.workingScope.hash"]').checked = true;
    host.querySelector('[data-config-ui]').checked = false;
    host.querySelector('[data-config-action="package"]').click(); await settle();
    lastDialog().querySelector('[data-id="confirm"]').click(); await settle(); await settle();
    eq(calls.filter(c => c.op === 'settings.configuration.options').length, 2, 'options relues après l’écriture');
    ok(host.querySelector('[data-config-key="session.workingScope.hash"]').checked && host.querySelector('[data-config-key="settings.zoom"]').checked
      && !host.querySelector('[data-config-ui]').checked, 'choix de la page conservés après relecture');
    eq(host.querySelector('[data-config-result]').textContent, 'Configuration par défaut écrite dans wad/Domenia.settings.seed.json.', 'résultat conservé après relecture');
    ok(!host.querySelector('[data-config-action="package"]').disabled, 'action de nouveau disponible');
    host.querySelector('[data-config-action="package"]').click(); await settle();
    eq(calls.filter(c => c.op === 'settings.configuration.export').at(-1).args, { keys: ['settings.zoom', 'session.workingScope.hash'], interface: null, fingerprint: 'decision-enregistree' },
      'seconde écriture préparée avec l’empreinte relue et les mêmes choix');
    eq(lastDialog().querySelector('[data-id="confirm"]').textContent.trim(), 'Écrire la configuration par défaut', 'fenêtre de confirmation ouverte');
    eq(messages, ['Configuration par défaut écrite dans wad/Domenia.settings.seed.json.'], 'aucun refus affiché');
    lastDialog().querySelector('[data-id="cancel"]').click(); await settle();
  } finally { page.destroy(); host.remove(); }
});

test('Proposition du premier lancement : comparaison visible et refus enregistré par build+SHA', async () => {
  const calls = [];
  const run = proposePackConfiguration(async (op, args) => {
    calls.push({ op, args });
    if (op.endsWith('.status')) return { needsDecision: true, decisionId: 'build-seed-id', sourceSha256: 'seed-sha', document: { text: 'seed-text' }, message: 'Nouvelle version' };
    if (op.endsWith('.preview')) return { fingerprint: 'current-document', sha256: 'text-sha', changes: [{ key: 'settings.zoom', before: '100', after: '125' }], summary: 'Copie avant remplacement' };
    if (op.endsWith('.decide')) return { applied: false, summary: 'Conservé' };
    throw new Error(op);
  }, () => { throw new Error('UI modifiée sur refus'); }, () => {});
  await settle();
  ok(lastDialog().textContent.includes('100') && lastDialog().textContent.includes('125'), 'avant/après présenté');
  lastDialog().querySelector('[data-id="decline"]').click(); await run;
  eq(calls.at(-1), { op: 'settings.configuration.seed.decide', args: { decisionId: 'build-seed-id', sourceSha256: 'seed-sha', fingerprint: 'current-document', apply: false } }, 'refus enregistré pour la vraie source et le choix aperçu');
});

test('Interface importée : une seule application par profil, les choix ultérieurs restent intacts', () => {
  const data = new Map(); const storage = { getItem: key => data.get(key), setItem: (key, value) => data.set(key, value) };
  const changes = []; const result = { interfaceId: 'import-1', interface: { theme: 'dark' } };
  ok(applyImportedInterface(result, value => changes.push(value), storage), 'première réception appliquée');
  ok(!applyImportedInterface(result, value => changes.push(value), storage), 'relecture du même import ignorée');
  eq(changes, [{ theme: 'dark' }], 'pas de restauration forcée après un choix personnel');
  ok(applyImportedInterface({ interfaceId: 'import-2', interface: { theme: 'light' } }, value => changes.push(value), storage), 'nouvelle confirmation distincte appliquée');
});

test('Section détruite : aucune restitution de choix ou commande de pack après réponse tardive', async () => {
  const host = document.createElement('div'); let deliver;
  const page = mount(host, { call: () => new Promise(resolve => { deliver = resolve; }) });
  page.destroy(); deliver({ choices: [], excluded: [] }); await settle();
  eq(host.textContent, '', 'réponse tardive ignorée');
});
