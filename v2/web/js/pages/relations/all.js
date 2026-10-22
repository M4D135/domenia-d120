// Utilisateurs et postes · « Toutes les associations »: every association of the local store, filtered by text and by the
// qualification facets (Domenia 1 FO-14), with export (visible rows, or everything after clearing the filters visibly),
// restore of the last removal, undo of the last import and the orphan check. Filtering and sorting stay local.
import { glyph } from '../../kit/glyphs.js';
import { createGrid } from '../../kit/grid.js';
import { createFilterBar } from '../../kit/filterbar.js';
import { createCommandBar } from '../../kit/commandbar.js';
import { applyVars } from '../../ui.js';
import { BADGES, BADGE_ORDER, BADGE_OPTIONS, badge, avatar, esc, int, nouns, NBSP, errText, sk } from './model.js';

const IDENTITY = [
  { value: 'same', label: 'Vérifiée', tone: 'ok' },
  { value: 'unknown', label: 'Non vérifiable', tone: 'warn' },
  { value: 'different', label: 'Autre objet', tone: 'alert' },
];
const PERSISTENCE = [
  { value: 'stored', label: 'Enregistrée', tone: 'ok' },
  { value: 'session', label: 'Session uniquement', tone: 'warn' },
];

/**
 * Creates the « Toutes les associations » tab in panel.
 * @param {HTMLElement} panel
 * @param {object} app  Controller of the screen.
 */
export function createAllTab(panel, app) {
  let rows = [];
  let pressed = new Set();
  let data = null;
  panel.innerHTML = `<section class="card rel-all reveal in">
    <div class="rel-all-head">
      <div class="head-titles"><h3>${glyph('layers')}Toutes les associations</h3><p class="head-sub rel-all-sub">${sk('w40')}</p></div>
      <div class="rel-all-cmd"></div>
    </div>
    <div class="rel-all-filters"></div>
    <div class="rel-all-grid"></div>
  </section>`;
  const sub = panel.querySelector('.rel-all-sub');
  const cmdHost = panel.querySelector('.rel-all-cmd');
  const bar = createFilterBar(panel.querySelector('.rel-all-filters'), {
    label: 'Filtres des associations',
    facets: BADGE_ORDER.map((id) => ({ id, label: BADGES[id].label, count: 0, tone: BADGES[id].tone })),
    onToggle: (id, on) => { if (on) pressed.add(id); else pressed.delete(id); apply(); },
  });
  const grid = createGrid(panel.querySelector('.rel-all-grid'), {
    key: 'relations.toutes',
    label: 'Toutes les associations utilisateurs-postes',
    rowId: (r) => `${r.key}|${r.persistence}`,
    selection: 'multi',
    loading: true,
    height: '600px',
    quickPlaceholder: 'Filtrer : utilisateur, poste, source, détail…',
    columns: [
      {
        id: 'user', label: 'Utilisateur', required: true, width: 230, get: (r) => r.userName ?? r.userLogin,
        html: (v, r) => `<button class="rel-cell-link" type="button" data-open="${esc(r.userDn ?? r.userLogin)}" data-tip="Voir ses relations">${avatar('user', v, 'xs')}<span>${esc(v)}<small class="mono">${esc(r.userLogin)}</small></span></button>`,
      },
      {
        id: 'computer', label: 'Poste', required: true, width: 160,
        html: (v, r) => `<button class="rel-cell-link" type="button" data-open="${esc(r.computerDn ?? v)}" data-tip="Voir ses relations">${avatar('computer', v, 'xs')}<span>${esc(v)}</span></button>`,
      },
      { id: 'badge', label: 'Qualification', type: 'enum', options: BADGE_OPTIONS, width: 150, html: (v, r) => badge(v, { size: 'sm', tip: r.rule }) },
      { id: 'when', label: 'Date', type: 'date', width: 130 },
      { id: 'source', label: 'Source', width: 200 },
      { id: 'details', label: 'Détails', width: 300 },
      { id: 'persistence', label: 'Persistance', type: 'enum', options: PERSISTENCE, width: 150, hidden: true },
      { id: 'identity', label: 'Identité', type: 'enum', options: IDENTITY, width: 140, tip: 'Une association sans GUID enregistré a une identité non vérifiable.' },
      { id: 'declarant', label: 'Déclarant', mono: true, width: 170, hidden: true },
      { id: 'batchId', label: 'Lot d’import', mono: true, width: 220, hidden: true },
      { id: 'identityNote', label: 'Note d’identité', width: 260, hidden: true },
    ],
    empty: { icon: 'link', title: 'Aucune association', text: 'Le magasin local ne contient encore aucune association utilisateur-poste.' },
    onActivate: (row) => app.select(row.userDn ?? row.userLogin),
    contextMenu: ({ row }) => (row ? app.rowMenu(row, 'both') : []),
    selectionActions: (sel) => [
      { label: `Copier ${nouns(sel.length, 'ligne', 'lignes')}`, icon: 'copy', run: () => grid.exportCsv('selected') },
    ],
  });
  panel.querySelector('.rel-all-grid').addEventListener('click', (e) => {
    const b = e.target instanceof Element ? e.target.closest('[data-open]') : null;
    if (!b) return;
    e.stopPropagation();
    app.select(b.dataset.open);
  });

  function apply() {
    const shown = pressed.size ? rows.filter((r) => pressed.has(r.badge)) : rows;
    grid.setRows(shown, { keepSelection: true, keepScroll: true });
    const filtered = shown.length !== rows.length;
    bar.setSummary(filtered ? `→ ${nouns(shown.length, 'association affichée', 'associations affichées')} sur ${int(rows.length)}` : `${nouns(rows.length, 'association', 'associations')}`);
  }

  let cmd = null;
  function commands() {
    const restore = data?.restore;
    const batch = data?.lastImport;
    cmd?.destroy();
    cmd = createCommandBar(cmdHost, {
      label: 'Actions des associations',
      size: 'sm',
      items: [
        { id: 'export', label: 'Exporter', icon: 'csv', run: () => grid.exportCsv('visible') },
        { id: 'export-all', label: 'Exporter tout', icon: 'download', run: exportAll },
        { id: 'restore', label: restore ? restore.label : 'Restaurer', icon: 'undo', kind: 'write', disabled: !restore, reason: 'Aucune suppression locale à restaurer.', run: () => app.restore(restore?.entryId ?? null) },
        { id: 'undo', label: 'Annuler l’import', icon: 'undo', kind: 'write', danger: true, disabled: !batch, reason: 'Aucun lot d’import présent dans les associations.', run: () => app.undoImport(batch?.batchId ?? null) },
        { id: 'import', label: 'Importer…', icon: 'download', overflow: true, run: () => app.openPanel('import') },
        { id: 'orphans', label: 'Nettoyer les orphelines…', icon: 'trash', kind: 'network', overflow: true, run: () => app.openPanel('orphelines') },
        { id: 'refresh', label: 'Relire', icon: 'refresh', iconOnly: true, pinned: true, run: () => app.refreshList() },
      ],
    });
  }

  // « Exporter tout » clears the text filter and the chips first, visibly, then exports every association (Domenia 1 FO-14).
  function exportAll() {
    pressed = new Set();
    bar.setFacets(BADGE_ORDER.map((id) => ({ id, label: BADGES[id].label, count: data?.facets.find((f) => f.badge === id)?.value ?? 0, tone: BADGES[id].tone, pressed: false })));
    grid.clearFilters();
    grid.setQuickFilter('');
    apply();
    grid.exportCsv('visible');
  }

  return {
    loading() { grid.setLoading(true); },
    show(list) {
      data = list;
      rows = list.rows;
      sub.innerHTML = `${esc(nouns(list.total, 'association', 'associations'))} du magasin local${NBSP}· Active Directory n’est jamais modifié par une association`;
      bar.setFacets(BADGE_ORDER.map((id) => ({ id, label: BADGES[id].label, count: list.facets.find((f) => f.badge === id)?.value ?? 0, tone: BADGES[id].tone, pressed: pressed.has(id) })));
      commands();
      apply();
      applyVars(panel);
    },
    failed(err) {
      grid.setError(errText(err), { retry: () => app.refreshList() });
    },
    destroy() { cmd?.destroy(); grid.destroy(); bar.destroy(); },
  };
}
