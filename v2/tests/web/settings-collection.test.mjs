import { test, eq, ok } from './harness.mjs';
import { mount } from '../../web/js/pages/parametres/collecte.js';
const settle = async () => { for (let i = 0; i < 30; i++) await Promise.resolve(); };
const deferred = () => { let resolve; const promise = new Promise(r => { resolve = r; }); return { promise, resolve }; };
function view(id = 'standard', custom = false) {
  const profiles = [['standard', 'Standard'], ['slowNetwork', 'Réseau lent'], ['troubleshooting', 'Dépannage']].map(([value, label]) =>
    ({ id: value, label, description: label, windowLabel: 'Fenêtre du profil', active: value === id }));
  return { profile: profiles.find(p => p.active), profiles, freshnessCustom: custom,
    freshness: ['presence', 'console', 'attributes', 'inventory', 'staticProbe', 'volatileProbe'].map(family =>
      ({ family, label: family, effect: 'Réutilisation', seconds: custom ? 30 : 300, duration: '5 minutes', profileDuration: '5 minutes', source: custom ? 'custom' : 'profile', choices: [{ value: 30, label: '30 secondes' }, { value: 300, label: '5 minutes' }] })),
    window: { text: 'jamais', valid: true, open: false, sentence: 'Fenêtre fermée du profil courant', errors: [], grid: Array.from({ length: 7 }, () => Array(48).fill(false)) },
    windowCustom: false, windowSources: ['Revalidation de liste'], rules: [], warnings: [],
    budgets: [{ id: 'concurrency', label: 'Parallélisme', value: 4, effect: 'Plafond', choices: [{ value: 4, label: '4 postes' }, { value: 8, label: '8 postes' }] }],
  };
}

test('Réglages collecte : changement de profil sérialisé, retour aux durées du profil et budget exact', async () => {
  const host = document.createElement('div'); document.body.append(host);
  const saved = deferred(); const calls = []; let current = view();
  const api = mount(host, { toast() {}, async call(operation, args) {
    calls.push({ operation, args });
    if (operation === 'settings.collection') return current;
    if (args?.profile) return saved.promise;
    if (args?.freshness === null) current = view('slowNetwork');
    return current;
  } });
  try {
    await settle(); host.querySelector('[data-profile="slowNetwork"]').click();
    ok(host.inert, 'édition suspendue tant que le profil précédent n’est pas enregistré');
    host.querySelector('[data-profile="troubleshooting"]').dispatchEvent(new MouseEvent('click', { bubbles: true }));
    eq(calls.filter(c => c.operation === 'settings.collection.set').length, 1, 'pas de deux sauvegardes concurrentes');
    current = view('slowNetwork', true); saved.resolve(current); await settle();
    eq(host.querySelector('[data-profile="slowNetwork"]').getAttribute('aria-checked'), 'true', 'profil confirmé réellement affiché');
    ok(!host.inert && !host.hasAttribute('aria-busy'), 'édition réouverte après réponse');
    host.querySelector('[data-act="fresh-reset"]').click(); await settle();
    eq(calls.at(-1).args, { freshness: null }, 'retour aux durées du profil actif, sans réinitialiser les autres profils');
    const select = host.querySelector('[data-select="budget:concurrency"]'); select.value = '8'; select.dispatchEvent(new Event('change', { bubbles: true })); await settle();
    eq(calls.at(-1).args, { budgets: { concurrency: 8 } }, 'valeur entière choisie transmise');
    ok(calls.every(c => c.operation.startsWith('settings.collection')), 'aucune collecte déclenchée par les réglages');
  } finally { api.destroy(); host.remove(); }
});

test('Réglages collecte : un ancien contrôle de fenêtre ne remplace pas celui du nouveau profil', async () => {
  const host = document.createElement('div'); document.body.append(host);
  const checked = deferred(); let checks = 0;
  const api = mount(host, { toast() {}, async call(operation) {
    if (operation === 'settings.collection.window.check') { checks++; return checked.promise; }
    return view(operation === 'settings.collection' ? 'standard' : 'slowNetwork');
  } });
  try {
    await settle(); let input = host.querySelector('[data-window]'); input.value = 'toujours'; input.dispatchEvent(new Event('input', { bubbles: true }));
    await new Promise(resolve => setTimeout(resolve, 320)); eq(checks, 1, 'contrôle local déclenché après la saisie');
    host.querySelector('[data-profile="slowNetwork"]').click(); await settle();
    checked.resolve({ ...view().window, sentence: 'Ancienne fenêtre ouverte', open: true }); await settle();
    ok(!host.textContent.includes('Ancienne fenêtre ouverte'), 'ancienne réponse ignorée après le nouveau profil');
    input = host.querySelector('[data-window]'); input.value = 'toujours'; input.dispatchEvent(new Event('input', { bubbles: true }));
    api.destroy(); await new Promise(resolve => setTimeout(resolve, 320)); eq(checks, 1, 'départ de la page annule aussi le contrôle différé');
  } finally { api.destroy(); host.remove(); }
});
