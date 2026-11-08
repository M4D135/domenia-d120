import { test, eq, ok } from './harness.mjs';
import { mount } from '../../web/js/pages/parametres/configuration-distribuable.js';
import { applyImportedInterface, proposePackConfiguration } from '../../web/js/shell/configuration-defaults.js';
const settle = async () => { for (let n = 0; n < 24; n++) await Promise.resolve(); };
const lastDialog = () => [...document.querySelectorAll('.k-dlg')].at(-1);

test('Configuration à diffuser : OU explicite, confirmation exacte du pack et annulation sans faux succès', async () => {
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
    ok(lastDialog().textContent.includes('settings.connection') && lastDialog().textContent.includes('pack installé reste intact'), 'portée et exclusion visibles');
    lastDialog().querySelector('[data-id="confirm"]').click(); await settle();
    eq(calls.find(c => c.op === 'settings.defaults.package').args, { text: '{"configuration":"exacte"}' }, 'texte validé exact, pas d’options recomposées');
    eq(messages.length, 0, 'aucun succès avant résultat');
    releasePackage({ cancelled: true }); await settle();
    eq(messages.length, 0, 'annulation du sélecteur sans succès');
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
