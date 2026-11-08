import { test, eq, ok } from './harness.mjs';
import { consultationAllowed, consultationIdentity } from '../../web/js/shell/consultation-guard.js';
import { changedBranches, publishConfirmedWrite } from '../../web/js/shell/post-write.js';
import { createRouter } from '../../web/js/router.js';

test('Consultation : reçus actifs, incertains ou illisibles refusés, sans vérification réseau', async () => {
  const calls = [], notices = [];
  for (const state of [null, { inFlight: true }, { pending: 1 }, { unreadable: 1 }]) {
    eq(await consultationAllowed(async operation => { calls.push(operation); return state; }, text => notices.push(text)), false);
  }
  eq(await consultationAllowed(async () => { throw new Error('disque indisponible'); }, text => notices.push(text)), false);
  eq(await consultationAllowed(async operation => { calls.push(operation); return { pending: 0, unreadable: 0, inFlight: false }; }, () => {}), true);
  ok(calls.every(operation => operation === 'write.receipts.list'), 'aucune relance ni lecture du domaine');
  eq(notices.length, 5, 'chaque refus est expliqué');
});

test('Consultation : comptes temporaires et distants invalident la même session', () => {
  const session = { account: { login: 'A' }, domain: { rootDn: 'DC=test' }, epoch: 2, storeId: 'base', accessSelectionVersion: 4, machineAccountGeneration: 3 };
  for (const change of [{ epoch: 3 }, { storeId: 'autre' }, { accessSelectionVersion: 5 }, { machineAccountGeneration: 4 }])
    ok(consultationIdentity(session) !== consultationIdentity({ ...session, ...change }), 'identité complète');
  eq(consultationIdentity(session), consultationIdentity({ ...session, cache: { objects: 150 } }), 'un rafraîchissement ne change pas le compte');
});

test('Arbre : seules les branches d’un déplacement vérifié sont relues dans la bonne session', () => {
  const receipt = { pending: false, verification: 'verified', result: 'applied', target: { dn: 'CN=PC,OU=A,DC=test' },
    plan: { changes: [{ kind: 'move', attribute: 'distinguishedName', beforeValue: 'CN=PC,OU=A,DC=test', afterValue: 'CN=PC,OU=B,DC=test' }] } };
  eq(changedBranches(receipt), ['OU=A,DC=test', 'OU=B,DC=test']);
  eq(changedBranches({ ...receipt, verification: 'unknown' }), []);
  eq(changedBranches({ ...receipt, pending: true }), []);
  const session = { epoch: 1 }; let events = 0;
  const receive = () => events++;
  window.addEventListener('domenia:write-verified', receive);
  try {
    eq(publishConfirmedWrite(receipt, consultationIdentity(session), { epoch: 2 }), false);
    eq(events, 0, 'retour ancien silencieux');
    eq(publishConfirmedWrite(receipt, consultationIdentity(session), session), true);
    eq(events, 1, 'publication unique');
  } finally { window.removeEventListener('domenia:write-verified', receive); }
});

test('Navigation réelle : refus avant destruction et accès conservé aux reçus', async () => {
  const previous = location.hash, motion = document.documentElement.dataset.motion;
  document.documentElement.dataset.motion = 'reduced';
  const host = document.createElement('div'); host.innerHTML = '<nav></nav><main></main>'; document.body.append(host);
  let cleaned = 0, reads = 0;
  history.replaceState(null, '', '#/rechercher');
  const router = createRouter({ main: host.querySelector('main'), nav: host.querySelector('nav'),
    pages: ['rechercher', 'requetes', 'operations'].map(id => ({ id, label: id })), context: () => ({}),
    beforeNavigate: id => id === 'operations' || consultationAllowed(async () => { reads++; return { pending: 1 }; }, () => {}),
    loadPage: async id => ({ own: true, mod: { render(main) { main.textContent = id; return () => cleaned++; } } }),
  });
  try {
    await router.start();
    history.replaceState(null, '', '#/requetes'); await router.start();
    eq(router.current(), 'rechercher'); eq(location.hash, '#/rechercher'); eq(cleaned, 0, 'ancienne page conservée');
    eq(reads, 1, 'un contrôle local');
    history.replaceState(null, '', '#/operations'); await router.start();
    eq(router.current(), 'operations'); eq(cleaned, 1, 'résolution disponible');
  } finally {
    router.destroy(); host.remove(); history.replaceState(null, '', previous || location.pathname);
    if (motion === undefined) delete document.documentElement.dataset.motion; else document.documentElement.dataset.motion = motion;
  }
});
