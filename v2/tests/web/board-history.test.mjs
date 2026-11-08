import { test, eq, ok } from './harness.mjs';
import { createBoardLayout } from '../../web/js/pages/poste/board-layout.js';
import { createBoard } from '../../web/js/pages/accueil/board.js';

const settle = async () => { for (let n = 0; n < 24; n++) await Promise.resolve(); };
const host = () => { const el = document.createElement('div'); document.body.append(el); return el; };
const binding = { domainKey: 'a'.repeat(64), recipeId: 'fromD1', revision: 1, fingerprint: 'b'.repeat(64), observedRevision: 1, name: 'Recette D1', currentRevisionProposed: false };
const card = { id: 'q', source: 'query', key: 'd1q-test', visual: 'Text', size: 'M', title: 'Carte conservée', paused: true, group: 'Requêtes', queryBinding: binding };
const version = { id: '1'.repeat(32), savedAt: null, sha256: 'c'.repeat(64), items: [card] };

test('Vrai tableau Poste : aperçu puis restauration, annuler/rétablir et refus d’une annulation devenue étrangère', async () => {
  const el = host(); const calls = []; let serial = 1; let view = { board: 'Computer', stored: true, valid: true, items: [], catalog: [], history: [version], choiceToken: 'initial' };
  let layout;
  const repaint = () => { if (layout) el.innerHTML = layout.toolbar() + layout.render(() => { throw new Error('carte en pause calculée'); }); };
  layout = createBoardLayout(el, { call: async (op, args) => {
    calls.push({ op, args });
    if (op === 'poste.layout.get') return view;
    if (op === 'poste.layout.restore') view = { ...view, items: [card], choiceToken: `token-${serial++}` };
    if (op === 'poste.layout.save') view = { ...view, items: args.items, choiceToken: `token-${serial++}` };
    return view;
  } }, 'Computer', repaint);
  try {
    await layout.load();
    el.querySelector('[data-layout-history]').click(); await settle();
    let dialog = [...document.querySelectorAll('.k-dlg')].at(-1);
    ok(dialog.textContent.includes(version.sha256) && dialog.textContent.includes('en pause'), 'preuve et état exact visibles avant confirmation');
    dialog.querySelector('[data-id="cancel"]').click(); await settle();
    eq(calls.filter(c => c.op.includes('restore')).length, 0, 'aperçu sans mutation');
    el.querySelector('[data-layout-history]').click(); await settle();
    dialog = [...document.querySelectorAll('.k-dlg')].at(-1); dialog.querySelector('[data-id="restore"]').click(); await settle();
    eq(calls.find(c => c.op === 'poste.layout.restore').args, { board: 'Computer', versionId: version.id, expectedChoiceToken: 'initial' }, 'restauration liée au choix examiné');
    ok(el.querySelector('.ps-layout-paused'), 'vraie carte restaurée en pause');
    el.querySelector('[data-layout-undo]').click(); await settle();
    eq(view.items, [], 'annulation restaure le tableau vide');
    el.querySelector('[data-layout-redo]').click(); await settle();
    eq(view.items[0].queryBinding, binding, 'rétablissement garde la liaison');
    view = { ...view, choiceToken: 'other-process' }; await layout.load();
    const writes = calls.filter(c => c.op === 'poste.layout.save').length;
    el.querySelector('[data-layout-undo]').click(); await settle();
    eq(calls.filter(c => c.op === 'poste.layout.save').length, writes, 'autre choix empêche l’ancienne annulation');
  } finally { document.querySelector('.k-dlg [data-id="cancel"]')?.click(); layout.destroy(); el.remove(); }
});

test('Vrai Accueil : liaison transmise, aucune présentation optimiste et restauration conditionnelle des versions', async () => {
  const el = host(); const calls = []; let resolveWrite; let failNext = false;
  let view = { items: [card], valid: true, customized: true, max: 64, choiceToken: 'initial', history: [version] };
  const board = { population: {}, computedAt: '2026-10-25T12:00:00Z', entries: {}, hints: [], scopeLabel: 'Copie locale' };
  const ctx = { toast() {}, pulse: { every() { return () => {}; } }, async call(op, args) {
    calls.push({ op, args });
    if (op === 'accueil.layout') return view;
    if (op === 'accueil.board') return board;
    if (op === 'accueil.layout.save') {
      if (failNext) { failNext = false; throw new Error('Choix concurrent'); }
      return new Promise(resolve => { resolveWrite = () => { view = { ...view, items: args.items.map((i, n) => ({ ...i, id: i.id || `new-${n}` })), choiceToken: 'saved' }; resolve(view); }; });
    }
    if (op === 'accueil.layout.restore') { view = { ...view, items: [card], choiceToken: 'restored' }; return view; }
    throw new Error(`Appel inattendu ${op}`);
  } };
  const api = createBoard(el, { ctx, onTool() {}, onAction() {}, onTargets() {} });
  try {
    await api.load(); api.setEditing(true);
    const adding = api.add([{ source: 'builtin', key: 'fleet.machines', visual: 'Kpi', size: 'S', group: 'Parc' }]);
    await settle();
    eq(api.count(), 1, 'aucun ajout affiché avant succès du document');
    const sent = calls.find(c => c.op === 'accueil.layout.save').args;
    eq(sent.items[0].queryBinding, binding, 'vrai wire du parc conserve la liaison D1');
    eq(sent.expectedChoiceToken, 'initial', 'écriture liée au choix initial');
    resolveWrite(); await adding;
    eq(api.count(), 2, 'nouvelle présentation seulement après succès');
    view = { ...view, items: [{ ...card, id: 'external', title: 'Autre choix' }], choiceToken: 'external' };
    failNext = true;
    el.querySelector('[data-cmd="undo"]').click(); await settle();
    eq(api.layout().items[0].id, 'external', 'échec recharge le vrai choix concurrent, pas l’ancien état optimiste');
    el.querySelector('[data-cmd="versions"]').click(); await settle();
    const dialog = [...document.querySelectorAll('.k-dlg')].at(-1);
    ok(dialog.textContent.includes('Recette') || dialog.textContent.includes('Carte conservée'), 'contenu de la version visible');
    dialog.querySelector('[data-id="restore"]').click(); await settle();
    eq(calls.find(c => c.op === 'accueil.layout.restore').args, { versionId: version.id, expectedChoiceToken: 'external' }, 'restauration sur la disposition relue explicitement');
    eq(api.layout().items[0].queryBinding, binding, 'révision restaurée intacte');
    eq(api.layout().items[0].paused, true, 'pause restaurée intacte');
    ok(calls.every(c => !c.op.includes('refresh') && !c.op.includes('collect')), 'aucune collecte déclenchée');
  } finally { document.querySelector('.k-dlg [data-id="cancel"]')?.click(); api.destroy(); el.remove(); }
});

test('Poste : dix annulations au plus, aucun empilement d’une sauvegarde sans effet', async () => {
  const el = host(); let n = 0; let view = { board: 'Computer', stored: true, valid: true, items: [card], catalog: [], history: [], choiceToken: 'zero' };
  let layout; const repaint = () => { if (layout) el.innerHTML = layout.toolbar(); };
  layout = createBoardLayout(el, { call: async (op, args) => {
    if (op === 'poste.layout.save' && JSON.stringify(view.items) !== JSON.stringify(args.items)) view = { ...view, items: args.items, choiceToken: `t-${++n}` };
    return view;
  } }, 'Computer', repaint);
  try {
    await layout.load();
    for (let i = 0; i < 12; i++) {
      el.querySelector('[data-layout-edit]').click();
      const dialog = [...document.querySelectorAll('.k-dlg')].at(-1);
      dialog.querySelector('[data-field="title"]').value = `Étape ${i}`;
      dialog.querySelector('[data-id="save"]').click(); await settle();
    }
    for (let i = 0; i < 10; i++) { ok(!el.querySelector('[data-layout-undo]').disabled, 'annulation disponible'); el.querySelector('[data-layout-undo]').click(); await settle(); }
    eq(view.items[0].title, 'Étape 1', 'les dix derniers gestes seulement');
    ok(el.querySelector('[data-layout-undo]').disabled, 'borne de dix');
    el.querySelector('[data-layout-edit]').click();
    const dialog = [...document.querySelectorAll('.k-dlg')].at(-1);
    dialog.querySelector('[data-id="save"]').click(); await settle();
    ok(el.querySelector('[data-layout-undo]').disabled, 'sauvegarde identique non empilée');
    ok(!el.querySelector('[data-layout-redo]').disabled, 'pas de perte du rétablissement sur un geste sans effet');
  } finally { document.querySelector('.k-dlg [data-id="cancel"]')?.click(); layout.destroy(); el.remove(); }
});
