import { test, eq, ok } from './harness.mjs';
import { createResults } from '../../web/js/pages/rechercher/results.js';
import { setLayoutStore } from '../../web/js/kit/util.js';
import { reconcileEvents } from '../../web/js/pages/rechercher/reconcile.js';
import { surveyChanges } from '../../web/js/pages/rechercher/survey-progress.js';

const ou = 'OU=Postes,DC=example,DC=local';
const row = (n) => ({ id: String(n), kind: 'computer', kindLabel: 'Poste', name: `PC-${String(n).padStart(6, '0')}`,
  dn: `CN=PC-${n},${ou}`, state: { key: 'active', label: 'Actif', tone: 'ok' }, flags: {}, container: 'Postes', readAt: '2026-11-01T00:00:00Z' });
async function fixture(rows) {
  const styles = [];
  for (const file of ['components.css', 'kit.css', 'pages/rechercher.css']) {
    const link = document.createElement('link'); link.rel = 'stylesheet'; link.href = new URL(`../../web/css/${file}`, import.meta.url).href;
    const loaded = new Promise((resolve, reject) => { link.onload = resolve; link.onerror = () => reject(new Error(`CSS non chargé : ${file}`)); });
    styles.push(link); document.head.append(link); await loaded;
  }
  const memory = new Map();
  setLayoutStore({ read: (key) => memory.get(key), write: (key, value) => memory.set(key, value) });
  const host = document.createElement('section'); host.dataset.page = 'rechercher';
  Object.assign(host.style, { position: 'fixed', left: '0', top: '0', width: '1100px', height: '700px' }); document.body.append(host);
  const panel = createResults(host, {}, new Proxy({}, { get: () => () => [] }));
  const original = { listId: 'a'.repeat(32), kind: 'browse', scope: { mode: 'ou', dn: ou, subtree: true, wholeDomain: false, chip: 'Postes', label: 'Postes', path: 'example.local / Postes' },
    type: 'all', match: 'prefix', plan: {}, rows, loaded: rows.length, limit: 100000, complete: true, limitReached: false,
    continuation: { allowed: false, reason: 'Complet' }, counter: 'Complet', absence: 'Liste relue', readAt: rows[0]?.readAt, sourceLabel: 'Annuaire' };
  panel.show(original);
  await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
  const viewport = host.querySelector('.k-gscroll');
  ok(viewport.clientHeight > 0 && viewport.clientHeight <= 700, 'vrai viewport borné avec les styles de la page et de la grille');
  return { panel, host, original, close() { panel.destroy(); host.remove(); styles.forEach(style => style.remove()); setLayoutStore(null); } };
}

test('Rechercher réel : 100 000 lignes, modifications indexées et une seule reconstruction finale de la grille', async () => {
  const rows = Array.from({ length: 100000 }, (_, n) => row(n));
  const f = await fixture(rows);
  try {
    const grid = f.panel.grid;
    grid.setSort([{ id: 'name', dir: -1 }]);
    grid.setColumnFilter('name', 'PC-000');
    grid.select(['0', '1'], { scroll: false });
    const scroller = f.host.querySelector('.k-gscroll'); scroller.scrollTop = 320;
    const top = scroller.scrollTop;
    const events = rows.filter((_, n) => n % 2 === 0).map((r) => ({ kind: 'update', row: { ...r, name: 'ZZ-' + r.name.slice(3), description: 'Mis à jour' } }));
    // Natural numeric sorting compares 000NEW as zero, before 000999. Use the same numeric part plus a suffix.
    events.push({ kind: 'add', row: { ...row(100000), name: 'PC-000999NEW' } }, { kind: 'mark', id: '100', label: 'hors du périmètre relu' });
    const before = grid.getRenderStats();
    ok(await f.panel.reconcile(events), 'publication terminée');
    const after = grid.getRenderStats();
    eq(after.viewBuilds - before.viewBuilds, 1, 'un seul filtre/tri pour les 50 002 événements, pas un par ligne');
    ok(after.rowPaints > before.rowPaints && after.rowPaints - before.rowPaints < 200, 'seules les lignes virtualisées sont peintes');
    eq(f.panel.rows().length, 100001, 'aucune ligne retirée, ajout conservé');
    eq(grid.getVisibleRows().length, 501, 'filtre appliqué aux valeurs nouvelles et à l’ajout');
    eq(grid.getVisibleRows()[0].name, 'PC-000999NEW', 'tri naturel décroissant conservé');
    eq(grid.getSelectedIds(), ['0', '1'], 'sélection conservée, même pour une ligne désormais masquée');
    eq(scroller.scrollTop, top, 'position de défilement conservée');
    eq(rows[0].name, 'PC-000000', 'objet historique non muté');
    eq(rows[100].state.label, 'Actif', 'état historique non muté');
    eq(f.original.rows.length, 100000, 'tableau historique non agrandi');
    ok(f.panel.result().rows[100].state.label.includes('hors du périmètre relu'), 'marquage conservé dans le nouvel historique');
    ok(f.panel.rows().at(-1)._new, 'marqueur nouveau conservé');
  } finally { f.close(); }
});

test('Rechercher réel : annulation de préparation, puis rattrapage sans dépendre du compteur ajouté du moteur', async () => {
  const f = await fixture(Array.from({ length: 4000 }, (_, n) => row(n)));
  try {
    const original = f.panel.result();
    const events = [{ kind: 'update', row: { ...row(0), name: 'Relu' } }, { kind: 'add', row: row(4000) }];
    let checks = 0;
    const before = f.panel.grid.getRenderStats();
    eq(await f.panel.reconcile(events, { stop: () => ++checks > 1000 }), false, 'préparation interrompue');
    eq(f.panel.grid.getRenderStats().viewBuilds, before.viewBuilds, 'aucun état partiel rendu');
    ok(f.panel.result() === original, 'historique inchangé après arrêt');
    const replay = reconcileEvents(f.panel.rows(), { rows: [row(4000)], added: [], moved: [], missing: [] });
    ok(await f.panel.reconcile(replay), 'rattrapage depuis les GUID réellement affichés');
    eq(f.panel.rows().length, 4001, 'ajout non publié repris une seule fois');
    eq(reconcileEvents(f.panel.rows(), { rows: [row(4000)], added: [], moved: [], missing: [] }).length, 0, 'pas de doublon au passage suivant');
  } finally { f.close(); }
});

test('Rechercher réel : une autre liste ou une fermeture pendant la préparation ne reçoit aucune ancienne ligne', async () => {
  for (const close of [false, true]) {
    const f = await fixture(Array.from({ length: 2000 }, (_, n) => row(n)));
    try {
      const pending = f.panel.reconcile([{ kind: 'add', row: row(9999) }]);
      if (close) f.panel.destroy(); else f.panel.show({ ...f.original, listId: 'b'.repeat(32), rows: [row(123)], loaded: 1 });
      eq(await pending, false, 'ancienne réponse abandonnée');
      if (close) eq(f.host.childElementCount, 0, 'panneau fermé non reconstruit');
      else eq(f.panel.rows().map(r => r.id), ['123'], 'nouvelle liste inchangée');
    } finally { f.close(); }
  }
});

test('Relevé réel : lot du plan confirmé, lignes inchangées et focus conservés, anciens lots ignorés', async () => {
  const rows = Array.from({ length: 10 }, (_, n) => ({ ...row(n), presence: { state: 'unknown', label: 'Non vérifié' },
    console: { login: 'ancien-compte', label: 'ancien-compte' }, description: 'Donnée AD conservée' }));
  const f = await fixture(rows);
  try {
    const run = { planId: 'plan-actuel', runId: null, total: 10, done: 0 };
    const event = { planId: run.planId, runId: 'releve-actuel', total: 10, done: 1,
      batch: [{ id: '0', presence: { state: 'online', label: 'En ligne' }, console: null }] };
    eq(surveyChanges(run, { ...event, planId: 'ancien-plan' }, f.panel.rows()), null, 'même le premier événement étranger ne lie pas le relevé');
    eq(run.runId, null, 'aucun état consommé par une ancienne réponse');
    const untouched = f.host.querySelector('.k-gr[data-pos="1"]');
    const changed = f.host.querySelector('.k-gr[data-pos="0"]');
    ok(untouched && changed, 'deux vraies lignes montées');
    const scroller = f.host.querySelector('.k-gscroll'); scroller.focus();
    f.panel.grid.select(['0', '1'], { scroll: false });
    const before = f.panel.grid.getRenderStats();
    f.panel.updateRows(surveyChanges(run, event, f.panel.rows()));
    const after = f.panel.grid.getRenderStats();
    eq(after.viewBuilds - before.viewBuilds, 1, 'un seul calcul de filtre et tri par lot');
    ok(f.host.querySelector('.k-gr[data-pos="1"]') === untouched, 'aucune reconstruction de la ligne inchangée');
    ok(f.host.querySelector('.k-gr[data-pos="0"]') !== changed, 'seule la ligne modifiée est repeinte');
    ok(document.activeElement === scroller, 'focus clavier conservé');
    eq(f.panel.grid.getSelectedIds(), ['0', '1'], 'sélection conservée');
    eq(f.panel.rows()[0].description, 'Donnée AD conservée', 'colonnes absentes du lot conservées');
    eq(f.panel.rows()[0].console.login, 'ancien-compte', 'console non lue ne supprime pas la dernière donnée');
    eq(f.panel.rows()[0].presence.state, 'online', 'mesure reçue appliquée');
    eq(rows[0].presence.state, 'unknown', 'snapshot historique non muté');
    eq(surveyChanges(run, { ...event, runId: 'ancien-releve' }, f.panel.rows()), null, 'autre relevé rejeté');
    eq(surveyChanges(run, { ...event, done: 0 }, f.panel.rows()), null, 'progression antérieure rejetée');
    // Re-sort and re-filter when a measured column changes, without retaining a stale search cache.
    f.panel.grid.setColumnFilter('name', 'PC-000000');
    f.panel.updateRows([{ ...f.panel.rows()[0], name: 'Renommé' }]);
    eq(f.panel.grid.getVisibleRows().length, 0, 'ancien nom absent du cache de filtre');
  } finally { f.close(); }
});


test('Rechercher réel : aperçu borné à 400 lignes pendant 100 000 résultats, aucun tri croissant par tranche', async () => {
  const f = await fixture([]);
  try {
    const rows = Array.from({ length: 100000 }, (_, n) => row(n));
    f.panel.setLoading('Lecture reçue');
    const before = f.panel.grid.getRenderStats().viewBuilds;
    for (let i = 0; i < rows.length; i += 400) f.panel.stageRows(rows.slice(i, i + 400), i + 400, rows.length);
    eq(f.panel.grid.getRenderStats().viewBuilds - before, 2, 'vidage puis un seul aperçu, aucune reconstruction des 249 préfixes suivants');
    eq(f.panel.grid.getVisibleRows().length, 400, 'aperçu local borné');
    eq(f.panel.result(), null, 'aucune liste complète ni historique prématuré');
    eq(f.host.getAttribute('aria-busy'), 'true', 'rendu encore annoncé en préparation');
    f.panel.show({ ...f.original, rows, loaded: rows.length });
    eq(f.panel.result().rows.length, 100000, 'publication finale entière');
    eq(f.panel.grid.getVisibleRows().length, 100000, 'aucune ligne perdue au passage au tri complet');
    eq(f.host.getAttribute('aria-busy'), null, 'rendu terminé seulement après publication');
  } finally { f.close(); }
});
