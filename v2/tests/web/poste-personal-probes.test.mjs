// Actual Poste layout/probe-card controllers. Written for critical Windows UI selection; no native provider is invoked here.
import { test, eq, ok } from './harness.mjs';
import { createBoardLayout } from '../../web/js/pages/poste/board-layout.js';
import { createProbeCards } from '../../web/js/pages/poste/probe-cards.js';

const key = `custom.${'a'.repeat(64)}`;
const guid = '11111111-1111-1111-1111-111111111111';
const dn = 'CN=PC1,OU=Postes,DC=test,DC=local';
const item = { id: 'team-card', key, source: 'probe', visual: 'Table', size: 'L', title: null, paused: false, group: '' };
const entry = { key, title: 'Fabricant personnel', source: 'probe', visual: 'Table', visuals: ['Table', 'Kpi', 'Text'], size: 'L', default: false };
const view = (items = [item]) => ({ board: 'Computer', valid: true, stored: true, choiceToken: 'b'.repeat(64), items, catalog: [entry] });
const contract = { name: 'Fabricant personnel', valid: true, privilegeLevel: 'LectureDistanteWmi', costLevel: 'Léger', summary: 'Projection déclarative exacte.',
  lines: [{ section: 'Inconnu', value: 'Absence ou refus restent inconnus.' }, { section: 'Comportement', value: 'Lecture CIM, aucun script et aucune méthode.' }], warnings: [], errors: [] };
const plan = () => ({ id: 'plan-poste', widgetId: item.id, computerGuid: guid, computer: 'PC1', dn, key, contract, detail: 'Un poste, version figée, contrôleurs exclus.' });
const page = (read = false) => ({ probe: { id: key, limitations: 'Matériel présenté à Windows seulement.', unknownMeaning: 'Inconnu sans réponse.' },
  status: { state: read ? 'read' : 'notRead' }, statusLabel: read ? 'Lue' : 'Non lue', columns: ['Valeur interprétée'], rows: read ? [['<Fabricant réel>']] : [],
  total: read ? 1 : 0, page: 1, pages: 1, provenance: `Cache du relevé · First / Text · version ${key}` });
const host = () => { const el = document.createElement('div'); document.body.append(el); return el; };
const settle = async () => { for (let i = 0; i < 24; i++) await Promise.resolve(); };
const dialog = () => [...document.querySelectorAll('.k-dlg-layer:not(.leaving) .k-dlg')].at(-1);
const state = (call) => ({ dn, data: { computer: { guid, name: 'PC1' } }, call });

test('Poste personnel : ajout de clé 71 via Personnaliser sans collecte ni réaffectation', async () => {
  const el = host(); const calls = []; let saved;
  const layout = createBoardLayout(el, state(async (op, args) => {
    calls.push(op); if (op === 'poste.layout.save') saved = args; return view(args?.items ?? []);
  }), 'Computer', () => {});
  try {
    await layout.load(); el.innerHTML = layout.toolbar(); el.querySelector('[data-layout-edit]').click();
    dialog().querySelector('[data-add]').click(); dialog().querySelector('[data-id="save"]').click(); await settle();
    eq(saved.items[0].key, key, 'référence immuable complète');
    ok(saved.items[0].id.length <= 64, 'identifiant de carte indépendant et borné');
    eq(saved.items[0].source, 'probe', 'source préservée');
    eq(calls, ['poste.layout.get', 'poste.layout.save'], 'ajout local uniquement');
  } finally { dialog()?.querySelector('[data-id="cancel"]')?.click(); layout.destroy(); el.remove(); }
});

test('Poste personnel : vrai contrat avant confirmation, refus de fermeture et cache après reçu exact', async () => {
  const el = host(); const calls = []; let read = false;
  const probes = createProbeCards(el, state(async (op, args) => {
    calls.push({ op, args });
    if (op === 'poste.layout.probe') return page(read);
    if (op === 'poste.personalProbe.plan') return plan();
    if (op === 'poste.personalProbe.discard') return { discarded: true };
    if (op === 'poste.personalProbe.run') { read = true; return { id: plan().id, key, page: page(true), receipt: { readBack: true, text: 'Résultat enregistré et relu.' } }; }
    throw new Error(op);
  }));
  try {
    el.innerHTML = probes.render(item, 'Fabricant personnel'); probes.refresh(); await settle();
    eq(calls.map(c => c.op), ['poste.layout.probe'], 'affichage du cache sans collecte');
    el.querySelector('[data-personal-probe-read]').click(); await settle();
    ok(dialog().textContent.includes('LectureDistanteWmi') && dialog().textContent.includes('Léger'), 'droits et coût déclarés visibles');
    ok(dialog().textContent.includes('Absence ou refus restent inconnus.') && dialog().textContent.includes(key), 'inconnu et version exacts');
    dialog().querySelector('[data-id="cancel"]').click(); await settle();
    ok(!calls.some(c => c.op === 'poste.personalProbe.run'), 'fermer ne collecte pas');
    eq(calls.find(c => c.op === 'poste.personalProbe.discard').args, { id: plan().id }, 'préparation abandonnée');
    el.querySelector('[data-personal-probe-read]').click(); await settle();
    dialog().querySelector('[data-id="read"]').click(); await settle();
    eq(calls.find(c => c.op === 'poste.personalProbe.plan').args, { dn, computer: guid, item: item.id }, 'carte et cible figées');
    eq(calls.find(c => c.op === 'poste.personalProbe.run').args, { id: plan().id, confirmed: true }, 'seul plan serveur confirmé');
    eq(calls.filter(c => c.op === 'poste.layout.probe').length, 2, 'relecture locale après collecte');
    ok(el.textContent.includes('<Fabricant réel>') && !el.querySelector('Fabricant'), 'valeur réelle échappée');
    ok(el.textContent.includes('Résultat enregistré et relu.') && el.textContent.includes('First / Text'), 'reçu et transformation visibles');
  } finally { dialog()?.querySelector('[data-id="cancel"]')?.click(); probes.destroy(); el.remove(); }
});

test('Poste personnel : carte retirée ou écran fermé avant retour de plan ne peut plus collecter', async () => {
  for (const closePage of [false, true]) {
    const el = host(); const calls = []; let finish;
    const probes = createProbeCards(el, state((op, args) => {
      calls.push(op);
      if (op === 'poste.layout.probe') return Promise.resolve(page());
      if (op === 'poste.personalProbe.plan') return new Promise(resolve => { finish = resolve; });
      if (op === 'poste.personalProbe.discard') return Promise.resolve({ discarded: true });
      throw new Error(`Collecte inattendue ${op} ${JSON.stringify(args)}`);
    }));
    try {
      el.innerHTML = probes.render(item, 'Fabricant'); probes.refresh(); await settle();
      el.querySelector('[data-personal-probe-read]').click(); await settle();
      if (closePage) probes.destroy(); else { el.innerHTML = '<p>Carte en pause</p>'; probes.refresh(); }
      finish(plan()); await settle();
      ok(!calls.includes('poste.personalProbe.run'), 'aucune réponse tardive convertie en consentement');
      ok(calls.includes('poste.personalProbe.discard'), 'préparation tardive abandonnée');
      ok(!dialog(), 'aucune confirmation sur le nouvel écran');
    } finally { probes.destroy(); el.remove(); }
  }
});

test('Poste personnel : arrêt conserve les commandes bloquées jusqu’à la réponse physique puis relit le cache', async () => {
  const el = host(); const calls = []; let finish;
  const probes = createProbeCards(el, state(async (op, args) => {
    calls.push({ op, args });
    if (op === 'poste.layout.probe') return page();
    if (op === 'poste.personalProbe.plan') return plan();
    if (op === 'poste.personalProbe.run') return new Promise((_, reject) => { finish = reject; });
    if (op === 'poste.collect.stop') return { text: 'Arrêt demandé ; lecture native encore en cours.' };
    throw new Error(op);
  }));
  try {
    el.innerHTML = probes.render(item, 'Fabricant'); probes.refresh(); await settle();
    el.querySelector('[data-personal-probe-read]').click(); await settle();
    dialog().querySelector('[data-id="read"]').click(); await settle();
    el.querySelector('[data-personal-probe-stop]').click(); await settle();
    eq(calls.find(c => c.op === 'poste.collect.stop').args, { dn, kind: 'probes' }, 'arrêt limité au type de relevé de ce poste');
    ok(el.querySelector('[data-personal-probe-read]').disabled, 'aucun second envoi pendant la fin native');
    eq(calls.filter(c => c.op === 'poste.layout.probe').length, 1, 'pas de faux recalcul avant la fin');
    finish(Object.assign(new Error('Lecture arrêtée ; qualification AD finale non terminée.'), { code: 'poste.cancelled' })); await settle();
    eq(calls.filter(c => c.op === 'poste.layout.probe').length, 2, 'cache relu après la fin physique signalée');
    ok(!el.querySelector('[data-personal-probe-read]').disabled, 'nouveau geste possible après clôture');
    ok(!el.querySelector('[data-tone="ok"]'), 'arrêt non annoncé réussi');
  } finally { probes.destroy(); el.remove(); }
});

test('Poste personnel : absence de définition conserve la carte et ne déclenche aucun repli ni collecte', async () => {
  const el = host(); const calls = [];
  const probes = createProbeCards(el, state(async (op) => {
    calls.push(op); throw Object.assign(new Error('Définition de sonde absente de ce profil ; aucune collecte.'), { code: 'probes.changed' });
  }));
  try {
    el.innerHTML = probes.render(item, 'Ancienne sonde'); probes.refresh(); await settle();
    ok(el.textContent.includes('Ancienne sonde') && el.textContent.includes('Définition de sonde absente'), 'carte et refus visibles');
    el.querySelector('[data-personal-probe-read]').click(); await settle();
    eq(calls, ['poste.layout.probe', 'poste.personalProbe.plan'], 'aucune définition cachée ni repli sous un autre alias');
    ok(!dialog(), 'aucune fausse confirmation possible');
  } finally { probes.destroy(); el.remove(); }
});
