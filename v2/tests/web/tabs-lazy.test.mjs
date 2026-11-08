import { test, eq, ok } from './harness.mjs';
import { createTabs } from '../../web/js/kit/tabs.js';

test('Onglets : aucun contenu caché calculé, un seul montage par ouverture et nettoyage complet', () => {
  const host = document.createElement('div'); document.body.append(host);
  const calls = [], cleaned = [];
  const tabs = createTabs(host, { label: 'Détails', selected: 'a', tabs: ['a', 'b', 'c'].map((id) => ({ id, label: id, disabled: id === 'c', render(panel) {
    ok(!panel.hidden, 'mesure du contenu seulement quand le panneau est visible'); calls.push(id); panel.textContent = id; return () => cleaned.push(id);
  } })) });
  try {
    eq(calls.join(','), 'a', 'le panneau lourd b ne coûte rien avant ouverture');
    tabs.setCount('b', 3500); eq(calls.join(','), 'a', 'mettre à jour un badge ne monte pas le panneau caché');
    tabs.select('b'); eq(calls.join(','), 'a,b', 'montage au premier affichage');
    tabs.select('a'); tabs.select('b'); tabs.select('c');
    eq(calls.join(','), 'a,b', 'retours et onglet interdit ne dupliquent aucun calcul');
    eq(tabs.current(), 'b', 'interdit ignoré');
    ok(tabs.panel('a').hidden && !tabs.panel('b').hidden, 'un seul panneau visible');
  } finally { tabs.destroy(); host.remove(); }
  eq(cleaned.sort().join(','), 'a,b', 'chaque ressource montée libérée');
});
