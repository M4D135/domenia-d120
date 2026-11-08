import { createPulse } from '../../web/js/shell/pulse.js';
import { test, eq, ok } from './harness.mjs';
import { render } from '../../web/js/pages/rechercher.js';
import { openTargets } from '../../web/js/pages/accueil/tools.js';
import { setLayoutStore } from '../../web/js/kit/util.js';

const root = 'DC=example,DC=local', ou = `OU=Postes,${root}`;
const settle = async () => { for (let i = 0; i < 32; i++) await Promise.resolve(); };
async function until(check) {
  const deadline = performance.now() + 5000;
  while (!check()) { if (performance.now() > deadline) throw new Error('Résultat de recherche non présenté en cinq secondes.'); await new Promise(resolve => setTimeout(resolve, 20)); }
}

test('Accueil vers Rechercher : la vraie page résout calcul et ensemble, sans ouvrir toute l’OU après refus', async () => {
  for (const fail of [false, true]) {
    const host = document.createElement('main'); document.body.append(host);
    const pulse = createPulse();
    const calls = []; let reached; const requested = new Promise(resolve => { reached = resolve; });
    setLayoutStore({ read() {}, write() {} });
    const dispose = render(host, {
      params: { source: 'accueil', ou, revision: 'calculation-1', cle: 'fleet.enabled' },
      pulse, navigate() {},
      async call(op, args) {
        calls.push({ op, args });
        if (op === 'session.info') return { account: { login: 'test' }, domain: { rootDn: root, dnsName: 'example.local' }, scope: { dn: ou, label: 'Postes', subtree: true } };
        if (op === 'search.memory') return { recents: [], favorites: [], workspaces: [] };
        if (op === 'search.catalog') return { entries: [] };
        if (op === 'search.policy') return {};
        if (op === 'search.containers') return [];
        if (op === 'directory.ou.children' || op === 'directory.branch.children') return { children: [] };
        if (op === 'search.survey.state') return {};
        if (op === 'requetes.search.selection') return null;
        if (op === 'search.home.selection') {
          reached();
          if (fail) throw { code: 'board.replaced', message: 'Calcul remplacé : cliquez de nouveau sur le chiffre.' };
          return { listId: 'a'.repeat(32), kind: 'selection', scope: { mode: 'ou', dn: ou, subtree: true, wholeDomain: false, chip: 'Postes', label: 'Postes', path: 'Postes' },
            type: 'computers', match: 'prefix', plan: {}, rows: [], loaded: 0, limit: 1, complete: true, limitReached: false, continuation: { allowed: false },
            counter: 'Aucun poste', absence: 'Ensemble vide du calcul', sourceLabel: 'Ensemble local de l’Accueil', readAt: '2026-11-01T00:00:00Z' };
        }
        throw new Error(`Appel inattendu : ${op}`);
      },
    });
    try {
      let timeout;
      try { await Promise.race([requested, new Promise((_, reject) => { timeout = setTimeout(() => reject(new Error('Route Accueil non appelée')), 5000); })]); }
      finally { clearTimeout(timeout); }
      await until(() => host.textContent.includes(fail ? 'Calcul remplacé' : 'Aucun résultat'));
      eq(calls.filter(c => c.op === 'search.home.selection').map(c => c.args), [{ revision: 'calculation-1', key: 'fleet.enabled' }], 'identifiants moteur exacts');
      ok(!calls.some(c => ['search.browse', 'search.run', 'search.view'].includes(c.op)), 'aucun élargissement ni repli réseau');
      ok(host.textContent.includes(fail ? 'Calcul remplacé' : 'Aucun résultat'), 'état vide réel ou refus du moteur visible');
      if (!fail) ok(host.querySelector('.rch-counter')?.textContent.includes('Liste complète dans ce périmètre (0 résultat)'), 'absence confirmée uniquement dans le calcul transmis');
    } finally { dispose(); pulse.dispose(); setLayoutStore(null); host.remove(); }
  }
});

test('Tiroir Postes concernés : ouverture bloquée pendant la lecture, puis transmet le même calcul et la même clé', async () => {
  let answer; const waiting = new Promise(resolve => { answer = resolve; }); const navigations = [];
  const drawer = openTargets({ ctx: { call: () => waiting, navigate: (...args) => navigations.push(args) }, revision: 'r1', key: 'rule:memory', label: 'Mémoire', scope: { dn: ou, subtree: true }, onReplaced() {} });
  try {
    const button = drawer.foot.querySelector('[data-id="search"]');
    ok(button.disabled, 'aucune ouverture avant validation de l’ensemble');
    answer({ rows: [{ guid: 'a', name: 'PC1' }], total: 1, revision: 'r1' }); await settle();
    ok(!button.disabled, 'ensemble reçu');
    button.click(); await settle();
    eq(navigations, [['rechercher', { ou, sousou: '1', type: 'computers', source: 'accueil', revision: 'r1', cle: 'rule:memory' }]], 'pas de liste approchée');
  } finally { drawer.close(); await drawer.closed; }
});


test('Tiroir Accueil vers Atelier : transfère la clé du calcul complet, même si la liste visible est tronquée ou vide', async () => {
  for (const total of [0, 3500]) {
    let answer; const navigations = [];
    const drawer = openTargets({ ctx: { call: () => new Promise(resolve => { answer = resolve; }), navigate: (...args) => navigations.push(args) },
      revision: 'r-home', key: 'fleet.attention', label: 'Attention', scope: { dn: ou, subtree: true }, onReplaced() {} });
    try {
      const button = drawer.foot.querySelector('[data-id="workshop"]');
      ok(button.disabled, 'la lecture du calcul doit réussir avant le transfert');
      answer({ rows: total ? [{ guid: 'a', name: 'PC1' }] : [], total, truncated: total > 1 }); await settle();
      ok(!button.disabled, 'le vide confirmé peut aussi devenir une sélection vide explicite');
      button.click(); await settle();
      eq(navigations, [['requetes', { source: 'accueil', revision: 'r-home', cle: 'fleet.attention', apercu: '1', retour: 'accueil' }]], 'aucun GUID reconstruit depuis la page visible');
    } finally { drawer.close(); await drawer.closed; }
  }
});
