import { test, eq, ok } from './harness.mjs';
import { createBoardTransfer } from '../../web/js/pages/board-transfer.js';
import { createBoardLayout } from '../../web/js/pages/poste/board-layout.js';
import { createBoard } from '../../web/js/pages/accueil/board.js';
const settle = async () => { for (let i = 0; i < 24; i++) await Promise.resolve(); };
const mount = () => { const el = document.createElement('div'); document.body.append(el); return el; };
const lastDialog = () => [...document.querySelectorAll('.k-dlg')].at(-1);

test('Import de disposition : original et choix examinés conservés, révisions seulement après consentement', async () => {
  const calls = []; const text = '{"Layout":[]}';
  const transfer = createBoardTransfer(async (op, args) => { calls.push({ op, args }); return { summary: 'Révision proposée', sha256: 'a'.repeat(64), items: [], needsQueryConsent: true, queryBindingsSha256: 'bound', sessionStamp: 'session' }; }, () => true, async () => ({ fileName: 'Domenia.json', text }));
  try {
    const pending = transfer.prepare('import', 'Computer', 'original-choice'); await settle();
    const dialog = lastDialog();
    ok(dialog.textContent.includes('Tableau volontairement vide') && dialog.textContent.includes('original conservé'), 'vide et preuve explicites');
    ok(dialog.querySelector('[data-id="apply"]').disabled, 'liaison proposée non autorisée par défaut');
    const box = dialog.querySelector('[data-board-bind]'); box.checked = true; box.dispatchEvent(new Event('change'));
    dialog.querySelector('[data-id="apply"]').click();
    const request = await pending;
    eq(request, { operation: 'shell.board.import.apply', args: { board: 'Computer', expectedChoiceToken: 'original-choice', text, sha256: 'a'.repeat(64), allowQueryProposal: true, queryBindingsSha256: 'bound', sessionStamp: 'session' } }, 'texte et identité de l’aperçu exacts');
    eq(calls.length, 1, 'préparation n’écrit jamais elle-même');
  } finally { transfer.destroy(); }
});

test('Défaut équipe des vrais Poste et Logiciels : annuler intact, confirmation liée au choix avant aperçu', async () => {
  for (const board of ['Computer', 'Software']) {
    const el = mount(); const calls = []; let layout;
    let view = { board, items: [], valid: true, catalog: [], history: [], choiceToken: 'initial' };
    const paint = () => { if (layout) el.innerHTML = layout.toolbar() + layout.render(() => ''); };
    layout = createBoardLayout(el, { call: async (op, args) => {
      calls.push({ op, args });
      if (op === 'poste.layout.get') return view;
      if (op === 'shell.board.default.preview') return { source: 'équipe', sourceSha256: 'a'.repeat(64), summary: 'Défaut local', items: [] };
      if (op === 'shell.board.default.apply') { view = { ...view, choiceToken: 'saved' }; return view; }
      if (op === 'shell.board.export') return { saved: false, summary: 'Préparée en mémoire' };
      throw new Error(op);
    } }, board, paint);
    try {
      await layout.load(); el.querySelector('[data-layout-transfer="default"]').click(); await settle();
      lastDialog().querySelector('[data-id="cancel"]').click(); await settle();
      eq(calls.filter(c => c.op.endsWith('.apply')).length, 0, 'annulation ne touche pas le choix vide');
      el.querySelector('[data-layout-transfer="default"]').click(); await settle();
      lastDialog().querySelector('[data-id="apply"]').click(); await settle();
      eq(calls.find(c => c.op.endsWith('.apply')).args, { board, expectedChoiceToken: 'initial', sourceSha256: 'a'.repeat(64) }, 'vrai consommateur conserve le jeton de départ');
      el.querySelector('[data-layout-transfer="export"]').click(); await settle();
      eq(calls.find(c => c.op === 'shell.board.export').args.expectedChoiceToken, 'saved', 'export du choix effectivement sauvegardé');
    } finally { layout.destroy(); el.remove(); }
  }
});

test('Accueil exporte le choix affiché et destruction empêche un import tardif', async () => {
  const el = mount(); const calls = []; const view = { items: [], valid: true, history: [], choiceToken: 'fleet-empty', max: 64 };
  const ctx = { pulse: { every() { return () => {}; } }, toast() {}, async call(op, args) {
    calls.push({ op, args });
    if (op === 'accueil.layout') return view;
    if (op === 'accueil.board') return { population: {}, entries: {}, hints: [] };
    if (op === 'shell.board.export') return { saved: false, summary: 'Mémoire' };
    throw new Error(op);
  } };
  const board = createBoard(el, { ctx, onTool() {}, onAction() {}, onTargets() {} });
  try {
    await board.load(); el.querySelector('[data-cmd="export-file"]').click(); await settle();
    eq(calls.find(c => c.op === 'shell.board.export').args, { board: 'Fleet', expectedChoiceToken: 'fleet-empty' }, 'parcours réel du tableau vide');
  } finally { board.destroy(); el.remove(); }
  let deliver; const transfer = createBoardTransfer(() => new Promise(resolve => { deliver = resolve; }), () => true);
  const pending = transfer.prepare('default', 'Fleet', 'old'); transfer.destroy();
  deliver({ summary: 'Tardif', items: [], sourceSha256: 'a'.repeat(64) });
  eq(await pending, null, 'aucune restitution après destruction');
});
