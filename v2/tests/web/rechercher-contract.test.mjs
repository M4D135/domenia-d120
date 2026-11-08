import { test, eq, ok } from './harness.mjs';
import { setLayoutStore } from '../../web/js/kit/util.js';
import { treeMemoryKey } from '../../web/js/pages/rechercher/tree-memory.js';
import { createSide } from '../../web/js/pages/rechercher/side.js';
import { createResults } from '../../web/js/pages/rechercher/results.js';

const root = 'DC=example,DC=local';
const ou = `OU=Postes,${root}`;
const legacyKey = `rechercher.tree.${root.toLowerCase()}`;
const allowedKey = key => /^[A-Za-z0-9][A-Za-z0-9:._-]{0,99}$/.test(key);

test('Recherche : clé de mémoire bornée, stable et propre à chaque domaine', async () => {
  const key = await treeMemoryKey(root);
  ok(allowedKey(key), 'clé acceptée par ShellInterfaceRules.IsLayoutKey');
  ok(!allowedKey(legacyKey), 'la clé DN historique démontre le désaccord');
  eq(await treeMemoryKey(`  ${root.toUpperCase()}  `), key, 'casse et espaces extérieurs normalisés');
  ok(await treeMemoryKey('DC=other,DC=local') !== key, 'aucun mélange entre domaines');
  ok(allowedKey(await treeMemoryKey(Array.from({length:30}, (_, n) => `DC=part${n}`).join(','))), 'domaine long toujours sous 100 caractères');
  ok(!key.includes('example'), 'le DN ne figure plus dans la clé');
});

async function sideFixture(saved, answer) {
  const host = document.createElement('aside');
  document.body.append(host);
  const writes = [], calls = [], browsed = [], selected = [], issues = [];
  const key = await treeMemoryKey(root);
  const values = new Map(saved(key));
  setLayoutStore({read: name => values.get(name), write: (name, value) => {writes.push([name, value]); values.set(name, value);}});
  const side = createSide(host, {call: async (operation, args) => {
    calls.push({operation, args});
    if (answer) { const result = answer(operation, args); if (result !== undefined) return result; }
    if (operation === 'search.containers') return [];
    if (operation === 'directory.branch.children') return {children: args?.dn ? [] : [{dn:ou,name:'Postes',path:'example.local / Postes',hasChildren:false,kind:'ou'}]};
    throw new Error(`Appel imprévu : ${operation}`);
  }}, {
    root, dns:'example.local', memoryKey:key,
    onSelect:(node, how) => selected.push({dn:node.data.dn, how}),
    onBrowse:(dn, name, subtree) => browsed.push({dn,name,subtree}),
    onFavorite:()=>{}, onPin:()=>{}, onUnpin:()=>{}, onMove:()=>{}, isPinned:()=>false,
    onNavigate:()=>{}, readOnly:()=>true, onRestoreIssue:issue=>issues.push(issue), onFold:()=>{},
  });
  return {host,side,key,writes,calls,browsed,selected,issues,close(){side.destroy();setLayoutStore(null);host.remove();}};
}

test('Arbre réel : ancienne mémoire locale reprise, nouvelle clé seule écrite après le geste', async () => {
  const fixture = await sideFixture(() => [[legacyKey, {v:1,selected:ou,expanded:[],subtree:false}]]);
  try {
    await fixture.side.ready;
    eq(fixture.side.subtree, false, 'ancienne profondeur reprise');
    eq(fixture.side.selected()?.data.dn, ou, 'ancienne sélection reprise');
    eq(fixture.browsed, [], 'restaurer ne liste pas implicitement l’OU');
    fixture.host.querySelector('.rch-browse').click();
    eq(fixture.browsed, [{dn:ou,name:'Postes',subtree:false}], 'geste unique et profondeur booléenne réelle');
    const depth = fixture.host.querySelector('.rch-depth input');
    depth.checked = true; depth.dispatchEvent(new Event('change', {bubbles:true}));
  } finally { fixture.close(); }
  eq(fixture.writes.length, 1, 'une sauvegarde différée regroupée');
  eq(fixture.writes[0][0], fixture.key, 'nouvelle clé envoyée au moteur');
  ok(fixture.writes.every(([key]) => allowedKey(key)), 'aucune clé refusée par le contrat');
  eq(fixture.writes[0][1].selected, ou, 'sélection conservée dans la valeur');
  eq(fixture.writes[0][1].subtree, true, 'dernier choix sauvegardé');
});

test('Arbre réel : préférence moteur actuelle prioritaire sur la copie locale historique', async () => {
  const fixture = await sideFixture(key => [
    [legacyKey, {v:1,selected:ou,expanded:[],subtree:false}],
    [key, {v:1,selected:null,expanded:[],subtree:true}],
  ]);
  try {
    await fixture.side.ready;
    eq(fixture.side.subtree, true, 'préférence actuelle gardée');
    eq(fixture.side.selected(), null, 'ancienne sélection non réintroduite');
    eq(fixture.browsed, [], 'aucune collecte par migration de préférence');
  } finally { fixture.close(); }
});

test('Arbre réel : fermeture annule la sélection clavier différée et finit une seule sauvegarde locale', async () => {
  const fixture = await sideFixture(() => []);
  try {
    await fixture.side.ready;
    const input = fixture.host.querySelector('.rch-ousearch input');
    input.value = 'Postes'; input.dispatchEvent(new Event('input', {bubbles:true}));
    const before = fixture.calls.length;
    ok(!fixture.calls.some(c => c.operation === 'directory.ou.search'), 'taper ne déclenche aucune lecture AD');
    fixture.host.querySelector('.k-tree-scroll').dispatchEvent(new KeyboardEvent('keydown', {key:'End',bubbles:true}));
    eq(fixture.side.tree.getSelected()?.id, ou, 'la sélection clavier a effectivement commencé');
    eq(fixture.selected, [], 'notification de sélection encore différée');
    const depth = fixture.host.querySelector('.rch-depth input');
    depth.checked = false; depth.dispatchEvent(new Event('change', {bubbles:true}));
    eq(fixture.writes, [], 'sauvegarde locale encore différée');
    fixture.side.destroy();
    eq(fixture.writes.length, 1, 'dernier geste local sauvegardé exactement à la fermeture');
    fixture.side.destroy();
    input.dispatchEvent(new KeyboardEvent('keydown', {key:'Enter',bubbles:true}));
    await new Promise(resolve => setTimeout(resolve, 400));
    eq(fixture.calls.length, before, 'aucun appel réseau différé ni geste de l’ancien champ après fermeture');
    eq(fixture.selected, [], 'le rappel clavier de 300 ms a été annulé');
    eq(fixture.writes.length, 1, 'aucune seconde sauvegarde après fermeture');
    eq(fixture.host.childElementCount, 0, 'arbre réellement détruit, fermeture répétable');
  } finally { fixture.close(); }
});

test('Arbre réel : réponse OU tardive, succès ou erreur, ne repeint pas le panneau fermé', async () => {
  for (const fails of [false, true]) {
    let settle;
    const pending = new Promise((resolve, reject) => { settle = fails ? reject : resolve; });
    const fixture = await sideFixture(() => [], operation => operation === 'directory.ou.search' ? pending : undefined);
    try {
      await fixture.side.ready;
      const input = fixture.host.querySelector('.rch-ousearch input');
      const list = fixture.host.querySelector('.rch-ousearch-list');
      const note = fixture.host.querySelector('.rch-ousearch-note');
      input.value = 'Postes'; input.dispatchEvent(new Event('input', {bubbles:true}));
      input.dispatchEvent(new KeyboardEvent('keydown', {key:'Enter',bubbles:true}));
      eq(fixture.calls.filter(c => c.operation === 'directory.ou.search').length, 1, 'une lecture sur Entrée explicite');
      const before = {calls:fixture.calls.length, list:list.innerHTML, note:note.textContent};
      fixture.side.destroy();
      settle(fails ? Object.assign(new Error('Lecture tardive refusée'), {code:'source.unavailable'})
        : [{dn:ou,name:'Postes',path:'example.local / Postes'}]);
      await new Promise(resolve => setTimeout(resolve, 0));
      eq(list.innerHTML, before.list, 'aucun résultat tardif, même sur les anciens nœuds détachés');
      eq(note.textContent, before.note, 'aucun message tardif, y compris en cas d’erreur');
      eq(fixture.calls.length, before.calls, 'aucune lecture de suivi');
      eq(fixture.host.childElementCount, 0, 'panneau fermé');
    } finally { fixture.close(); }
  }
});

test('Arbre réel : fermeture pendant le chargement racine arrête toute restauration ultérieure', async () => {
  let finish;
  const pending = new Promise(resolve => { finish = resolve; });
  const fixture = await sideFixture(key => [[key, {v:1,selected:`OU=Sous,${ou}`,expanded:[ou],subtree:true}]],
    (operation, args) => operation === 'directory.branch.children' && !args.dn ? pending : undefined);
  try {
    const before = fixture.calls.length;
    fixture.side.destroy();
    finish({children:[{dn:ou,name:'Postes',path:'example.local / Postes',hasChildren:true,kind:'ou'}]});
    await fixture.side.ready;
    eq(fixture.calls.length, before, 'aucune lecture de branche mémorisée après la réponse tardive');
    eq(fixture.selected, [], 'aucune sélection tardive');
    eq(fixture.issues, [], 'fermer ne transforme pas la réponse abandonnée en OU absente');
    eq(fixture.writes, [], 'aucune préférence créée par la réponse tardive');
    eq(fixture.host.childElementCount, 0, 'le chargement ne reconstruit pas le panneau');
  } finally { fixture.close(); }
});

test('Résultats réels : source indisponible efface la réussite précédente et reste inconnue', () => {
  const host = document.createElement('section'); document.body.append(host);
  const panel = createResults(host, {}, new Proxy({}, {get:() => () => []}));
  const row = {id:'11111111-1111-1111-1111-111111111111',kind:'computer',kindLabel:'Poste',name:'POSTE-01',dn:`CN=POSTE-01,${ou}`,
    state:{key:'active',label:'Actif',tone:'ok'},flags:{},container:'Postes',readAt:'2026-10-26T12:00:00Z'};
  try {
    panel.show({listId:'a'.repeat(32),kind:'browse',scope:{mode:'ou',dn:ou,subtree:true,wholeDomain:false,chip:'Postes',label:'Postes',path:'example.local / Postes'},
      type:'all',match:'prefix',plan:{},rows:[row],loaded:1,limit:100,complete:true,limitReached:false,
      continuation:{allowed:false,reason:'Complet'},counter:'Complet',absence:'Liste relue',readAt:row.readAt,sourceLabel:'Annuaire'});
    panel.setLoading('Lecture en cours');
    panel.showCached({rows:[row],readAt:row.readAt});
    panel.setError({code:'source.unavailable',message:'La lecture n’a pas abouti.'}, () => {});
    eq(panel.result(), null, 'aucun résultat qualifié après erreur');
    eq(panel.grid.getVisibleRows(), [], 'anciennes lignes non présentées comme relues');
    ok(host.textContent.includes('Aucune source disponible'), 'échec affiché');
    ok(host.textContent.includes('l’état réel est inconnu'), 'une erreur ne prouve pas une absence');
    ok(!host.classList.contains('loading'), 'état de lecture terminé');
  } finally {panel.destroy();host.remove();}
});
