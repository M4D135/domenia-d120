import { test, eq, ok } from './harness.mjs';
import { mount } from '../../web/js/pages/parametres/connexion.js';
const settle = async () => { for (let i = 0; i < 30; i++) await Promise.resolve(); };
const closeAnimation = () => new Promise(resolve => setTimeout(resolve, 400));
function view({ follows = false, token = 'scope-1' } = {}) {
  return { simulated: false, account: { login: 'TEST\\reader' }, connection: { state: 'connected', label: 'Connecté' },
    domain: { dnsName: 'test.local', rootDn: 'DC=test,DC=local' }, authentication: { label: 'Windows' }, rights: { label: 'Lecture', detail: '' }, readOnly: true,
    preferences: { rememberLogin: false, editable: true, rules: [] }, safeguards: [],
    scope: { label: 'Paris', dn: 'OU=Paris,DC=test,DC=local', subtree: true, isDefault: true, defaultDn: 'OU=Paris,DC=test,DC=local' },
    sections: [{ id: 'accueil', label: 'Accueil', follows: true, scopeLabel: 'Paris', detail: 'Suit' },
      { id: 'accounts', label: 'Comptes', follows, scopeLabel: follows ? 'Paris' : 'Service A', detail: 'Choix de la section', canFollow: !follows, followToken: follows ? null : token }],
  };
}
function fixture() {
  const host = document.createElement('div'); host.className = 'pr-page'; document.body.append(host);
  const calls = []; let current = view();
  const api = mount(host, { ctx: {}, toast() {}, async call(op, args) {
    calls.push({ op, args });
    if (op === 'settings.connection') return current;
    if (op === 'settings.scope.follow') { current = view({ follows: true }); return current; }
    throw new Error(`Contact imprévu : ${op}`);
  } });
  return { host, calls, api, async close() { api.destroy(); document.querySelector('.k-dlg-foot [data-id="cancel"]')?.click(); await closeAnimation(); host.remove(); } };
}
test('OU des sections : le choix propre est montré et conservé sans confirmation', async () => {
  const f = fixture();
  try {
    await settle(); ok(f.host.textContent.includes('OU propre · Service A'), 'vraie exception affichée');
    eq(f.calls.length, 1, 'ouverture locale seule');
    f.host.querySelector('[data-follow-section]').click(); await settle();
    const dialog = document.querySelector('[role="dialog"]');
    ok(dialog.textContent.includes('Service A') && dialog.textContent.includes('Paris'), 'anciens et nouveaux périmètres nommés');
    dialog.querySelector('[data-id="cancel"]').click(); await settle();
    eq(f.calls.length, 1, 'annuler ne réécrit rien'); ok(f.host.textContent.includes('OU propre · Service A'), 'OU étroite conservée');
  } finally { await f.close(); }
});
test('OU des sections : accord explicite lié à la vue, pas de double envoi ni de collecte', async () => {
  const f = fixture();
  try {
    await settle(); const button = f.host.querySelector('[data-follow-section]'); button.click(); button.click(); await settle();
    eq(document.querySelectorAll('[role="dialog"]').length, 1, 'confirmation unique');
    document.querySelector('.k-dlg-foot [data-id="ok"]').click(); await settle();
    eq(f.calls, [{ op: 'settings.connection', args: undefined }, { op: 'settings.scope.follow', args: { section: 'accounts', token: 'scope-1', confirmed: true } }], 'choix comparé côté moteur, aucun réseau');
    ok(!f.host.querySelector('[data-follow-section]'), 'section suit réellement après réponse');
    ok(f.host.textContent.includes('Suit · Paris'), 'nouveau périmètre affiché');
  } finally { await f.close(); }
});
test('OU des sections : quitter pendant la confirmation interdit toute écriture tardive', async () => {
  const f = fixture();
  try {
    await settle(); f.host.querySelector('[data-follow-section]').click(); await settle(); f.api.destroy();
    document.querySelector('.k-dlg-foot [data-id="ok"]').click(); await settle(); eq(f.calls.length, 1, 'aucun changement après départ');
  } finally { await f.close(); }
});
