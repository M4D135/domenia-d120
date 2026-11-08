import { test, eq, ok } from './harness.mjs';
import { mount } from '../../web/js/pages/parametres/demonstration.js';

const settle = async () => { for (let n = 0; n < 30; n++) await Promise.resolve(); };
const page = () => { const host = document.createElement('div'); document.body.append(host); return host; };
const view = { active: true, modeLabel: 'Démonstration — données fictives', reason: 'demonstration', detail: 'example.invalid', facts: null, howTo: [], guarantees: ['Aucun réseau réel.'] };
const state = { active: true, available: true, busy: false, message: 'Contexte réel conservé.' };
const dialog = () => [...document.querySelectorAll('.k-dlg-layer:not(.leaving) .k-dlg')].at(-1);

test('Démonstration : la vraie page exige confirmation du reset, ne double pas la demande et distingue quitter', async () => {
  const host = page(); const calls = []; const messages = [];
  const api = mount(host, { toast: text => messages.push(text), async call(op) {
    calls.push(op);
    if (op === 'settings.demo') return view;
    if (op === 'settings.demo.session') return state;
    if (op === 'settings.storage') return { scenario: 'normal' };
    if (op === 'shell.demo.coverage') return { available: true, fixtures: [{ label: 'Objets fictifs', count: 3, present: true, detail: 'Couverture déplacée depuis Aide.' }] };
    return { accepted: true, message: 'Transition demandée.' };
  } });
  try {
    await settle();
    ok(host.textContent.includes('Réinitialiser la démonstration') && host.textContent.includes('Quitter la démonstration'), 'vrais contrôles explicites');
    ok(host.textContent.includes('Objets fictifs') && host.textContent.includes('Couverture déplacée depuis Aide.'), 'information de couverture conservée dans Paramètres');
    const reset = host.querySelector('[data-act="demo:reset"]');
    reset.click(); reset.click(); await settle();
    eq(document.querySelectorAll('.k-dlg-layer:not(.leaving) .k-dlg').length, 1, 'une seule confirmation');
    dialog().querySelector('[data-id="cancel"]').click(); await settle();
    eq(calls.filter(op => op === 'settings.demo.reset').length, 0, 'annulation ne change pas la fiction');
    reset.click(); await settle();
    dialog().querySelector('[data-id="reset"]').click(); await settle();
    eq(calls.filter(op => op === 'settings.demo.reset').length, 1, 'confirmation envoyée une fois au moteur');
    host.querySelector('[data-act="demo:exit"]').click(); await settle();
    eq(calls.filter(op => op === 'settings.demo.exit').length, 1, 'sortie distincte du reset');
    ok(messages.every(text => text === 'Transition demandée.'), 'aucun succès de bascule inventé avant confirmation native');
  } finally { api.destroy(); host.remove(); }
});

test('Démonstration : fermeture du panneau pendant confirmation ou réponse ne crée aucune action tardive', async () => {
  const host = page(); const writes = []; const messages = [];
  const api = mount(host, { toast: text => messages.push(text), async call(op) {
    if (op === 'settings.demo') return view;
    if (op === 'settings.demo.session') return state;
    if (op === 'settings.storage') return { scenario: 'normal' };
    if (op === 'shell.demo.coverage') return { available: false, summary: 'Couverture indisponible dans ce scénario.' };
    writes.push(op); return { message: 'fait' };
  } });
  await settle(); host.querySelector('[data-act="demo:reset"]').click(); await settle();
  api.destroy(); await settle();
  eq(writes, [], 'dialogue retiré sans reset dans un contexte quitté');
  eq(messages, [], 'aucun message tardif');
  host.remove();
  const other = page(); let resolve; const calls = [];
  const pending = mount(other, { toast() {}, call(op) { calls.push(op); return new Promise(done => { resolve = done; }); } });
  pending.destroy(); resolve(view); await settle();
  eq(calls, ['settings.demo'], 'réponse tardive ne relance pas la lecture de la session suivante');
  other.remove();
});

test('Démonstration : le contexte normal propose ouvrir et jamais réinitialiser le contexte réel', async () => {
  const host = page(); const calls = [];
  const api = mount(host, { toast() {}, async call(op) {
    calls.push(op);
    if (op === 'settings.demo') return { ...view, active: false, modeLabel: 'Annuaire réel' };
    if (op === 'settings.demo.session') return { ...state, active: false };
    return { accepted: true, message: 'Transition demandée.' };
  } });
  try {
    await settle();
    ok(host.querySelector('[data-act="demo:open"]'), 'entrée visible dans le même écran');
    ok(!host.querySelector('[data-act="demo:reset"]') && !host.querySelector('[data-act="demo:exit"]'), 'pas de reset du contexte normal');
    host.querySelector('[data-act="demo:open"]').click(); await settle();
    eq(calls.filter(op => op === 'settings.demo.open').length, 1, 'moteur sollicité explicitement');
  } finally { api.destroy(); host.remove(); }
});
