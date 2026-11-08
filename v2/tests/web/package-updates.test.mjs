import { test, eq, ok } from './harness.mjs';
import { mount } from '../../web/js/pages/parametres/mises-a-jour.js';

const settle = async () => { for (let i = 0; i < 30; i++) await Promise.resolve(); };
const initial = () => ({ demonstration: true, available: true, busy: false, installedVersion: '2.0.0-demo', folder: 'Fictif', source: 'folder',
  candidate: null, prepared: false, confirmation: null, expiresAt: null, message: 'État local', advice: ['Aucun accès réel'], preparationFolder: null });
function fixture(answer = null) {
  const host = document.createElement('div'); document.body.append(host); const calls = [], toasts = [];
  let state = initial();
  const control = mount(host, { call: async (op, args) => {
    calls.push({ op, args });
    if (answer) { const value = answer(op, args); if (value !== undefined) return value; }
    if (op === 'settings.update.check') state = { ...state, candidate: { version: '2.0.1', fileName: 'Domenia.zip', bytes: 1024, sha256: 'a'.repeat(64), provenance: 'Fictif <b>source</b>' } };
    if (op === 'settings.update.prepare') state = { ...state, prepared: true, confirmation: 'sealed-plan', expiresAt: '2026-10-25T12:00:00Z' };
    if (op === 'settings.update.install') return { accepted: true, simulated: true, message: 'Fictif' };
    return state;
  }, toast: (...args) => toasts.push(args) });
  return { host, calls, toasts, control, destroy() { control.destroy(); host.remove(); } };
}

test('Mises à jour : titre et cartes visibles avec les vraies animations, y compris après une action', async () => {
  const previousIO = window.IntersectionObserver;
  const previousMotion = document.documentElement.dataset.motion;
  const active = new Set();
  window.IntersectionObserver = class {
    constructor(callback) { this.callback = callback; active.add(this); }
    observe(target) { this.callback([{ target, isIntersecting: true, intersectionRatio: 1 }]); }
    unobserve() {}
    disconnect() { active.delete(this); }
  };
  const css = document.createElement('link'); css.rel = 'stylesheet';
  css.href = new URL('../../web/css/motion.css', import.meta.url).href;
  let f;
  try {
    await new Promise((resolve, reject) => { css.onload = resolve; css.onerror = reject; document.head.append(css); });
    document.documentElement.dataset.motion = 'full';
    f = fixture();
    const waiting = f.host.querySelector('header');
    ok(waiting.classList.contains('in'), 'titre rendu dès la lecture locale');
    await settle();
    function visibleCards() {
      const cards = [...f.host.querySelectorAll('header, [data-card]')];
      eq(cards.length, 4, 'titre et trois cartes');
      ok(cards.every(el => el.classList.contains('in') || el.classList.contains('revealed')), 'aucune carte laissée transparente');
      ok(cards.every(el => getComputedStyle(el).animationName === 'reveal-in' || el.classList.contains('revealed')), 'animation réellement reliée au CSS livré');
    }
    visibleCards();
    f.host.querySelector('[data-update="folder"]').click(); await settle(); visibleCards();
    eq(active.size, 1, 'un seul observateur après les nouveaux rendus');
    document.documentElement.dataset.motion = 'reduced';
    ok([...f.host.querySelectorAll('header, [data-card]')].every(el => getComputedStyle(el).opacity === '1'), 'lecture immédiate avec animations réduites');
    f.destroy(); f = null; eq(active.size, 0, 'observateur libéré en quittant la section');
  } finally {
    f?.destroy(); css.remove(); window.IntersectionObserver = previousIO;
    if (previousMotion === undefined) delete document.documentElement.dataset.motion;
    else document.documentElement.dataset.motion = previousMotion;
  }
});

test('Mises à jour : une erreur de lecture reste visible et permet de réessayer sans recherche implicite', async () => {
  let fail = true;
  const f = fixture(op => { if (op === 'settings.update.status' && fail) throw Object.assign(new Error('État local illisible'), { code: 'update.state.unreadable' }); });
  try {
    await settle(); ok(f.host.querySelector('[role="alert"]')?.textContent.includes('État local illisible'), 'erreur explicite');
    fail = false; f.host.querySelector('[data-act="retry"]').click(); await settle();
    ok(f.host.querySelector('[data-update="folder"]'), 'section restaurée après nouvelle lecture locale');
    eq(f.calls.map(c => c.op), ['settings.update.status', 'settings.update.status'], 'aucune recherche distante implicite');
  } finally { f.destroy(); }
});

test('Mises à jour : ouvrir la section lit uniquement l’état local ; source et préparation exigent deux gestes', async () => {
  const f = fixture();
  try {
    await settle(); eq(f.calls.map(c => c.op), ['settings.update.status'], 'aucune recherche ou archive automatique');
    ok(!f.host.querySelector('[data-update="github"]') && !/github/i.test(f.host.textContent), 'GitHub n’est plus une source de mise à jour');
    f.host.querySelector('[data-update="folder"]').click(); await settle();
    eq(f.calls[1], { op: 'settings.update.check', args: { source: 'folder' } }, 'source choisie explicite');
    ok(f.host.textContent.includes('Fictif <b>source</b>') && ![...f.host.querySelectorAll('b')].some(e => e.textContent === 'source'), 'provenance échappée');
    ok(!f.calls.some(c => c.op === 'settings.update.prepare'), 'version trouvée sans téléchargement');
    f.host.querySelector('[data-update="prepare"]').click(); await settle();
    eq(f.calls[2].op, 'settings.update.prepare', 'deuxième geste distinct');
    ok(f.host.querySelector('[data-update="install"]'), 'confirmation accessible seulement après préparation');
    ok(f.host.textContent.includes('Démonstration — données fictives'), 'source fictive toujours indiquée');
  } finally { f.destroy(); }
});

test('Mises à jour : annuler la confirmation ne demande pas l’assistant ; accepter transmet uniquement le plan scellé', async () => {
  const f = fixture();
  try {
    await settle(); f.host.querySelector('[data-update="folder"]').click(); await settle();
    f.host.querySelector('[data-update="prepare"]').click(); await settle();
    f.host.querySelector('[data-update="install"]').click(); await settle();
    document.querySelector('.k-dlg [data-id="cancel"]').click(); await settle();
    eq(f.calls.filter(c => c.op === 'settings.update.install').length, 0, 'annulation sans écriture');
    f.host.querySelector('[data-update="install"]').click(); await settle();
    [...document.querySelectorAll('.k-dlg [data-id="ok"]')].at(-1).click(); await settle();
    eq(f.calls.find(c => c.op === 'settings.update.install').args, { confirmation: 'sealed-plan' }, 'aucun chemin ou URL fourni à l’installation');
  } finally { f.destroy(); }
});

test('Mises à jour : quitter pendant la recherche ignore sa réponse tardive et ne prépare rien', async () => {
  let release; const f = fixture(op => op === 'settings.update.check' ? new Promise(resolve => { release = resolve; }) : undefined);
  try {
    await settle(); f.host.querySelector('[data-update="folder"]').click(); await settle(); ok(release, 'requête réellement pendante');
    f.control.destroy(); const before = f.host.innerHTML;
    release({ ...initial(), message: 'Réponse tardive' }); await settle();
    eq(f.host.innerHTML, before, 'aucune mutation du DOM après destroy');
    eq(f.calls.map(c => c.op), ['settings.update.status', 'settings.update.check'], 'aucune action chaînée après départ');
  } finally { f.destroy(); }
});
