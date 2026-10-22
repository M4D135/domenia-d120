// Utilisateurs et postes · « Toutes les associations »: every association of the local store, filtered by text and by the
// facets (six natures and the contradiction mark, Domenia 1 FO-14), with export to a CSV file and « Ouvrir le CSV » (the
// visible rows, or everything after clearing the filters visibly, Domenia 1 REL-050), visible actions on each row, restore of
// the last removal, undo of the last import and the orphan check. Filtering and sorting stay local.
import { glyph } from '../../kit/glyphs.js';
import { createGrid } from '../../kit/grid.js';
import { createFilterBar } from '../../kit/filterbar.js';
import { createCommandBar } from '../../kit/commandbar.js';
import { writeClipboard } from '../../kit/util.js';
import { applyVars, toast, formatDateTime } from '../../ui.js';
import { dateCell } from './subject.js';
import { BADGES, BADGE_ORDER, BADGE_OPTIONS, qualification, avatar, esc, int, nouns, NBSP, errText, sk, dateText } from './model.js';

const IDENTITY = [
  { value: 'same', label: 'Vérifiée', tone: 'ok' },
  { value: 'unknown', label: 'Non vérifiable', tone: 'warn' },
  { value: 'different', label: 'Autre objet', tone: 'alert' },
];
const PERSISTENCE = [
  { value: 'stored', label: 'Enregistrée', tone: 'ok' },
  { value: 'session', label: 'Session uniquement', tone: 'warn' },
];
const SESSION_RESULT = '0'.repeat(32);

/**
 * Creates the « Toutes les associations » tab in panel.
 * @param {HTMLElement} panel
 * @param {object} app  Controller of the screen.
 * @param {{ facet?: string|null }} [o]  Facet pressed at once (« filtre=contradictoire »).
 */
export function createAllTab(panel, app, o = {}) {
  let rows = [];
  let pressed = new Set(o.facet ? [o.facet] : []);
  let data = null;
  let activeCol = null;
  panel.innerHTML = `<section class="card rel-all reveal in">
    <div class="rel-all-head">
      <div class="head-titles"><h3>${glyph('layers')}Toutes les associations</h3><p class="head-sub rel-all-sub">${sk('w40')}</p></div>
      <div class="rel-all-cmd"></div>
    </div>
    <div class="rel-all-filters"></div>
    <div class="rel-export" hidden></div>
    <div class="rel-all-grid"></div>
  </section>`;
  const sub = panel.querySelector('.rel-all-sub');
  const cmdHost = panel.querySelector('.rel-all-cmd');
  const exportHost = panel.querySelector('.rel-export');
  const gridHost = panel.querySelector('.rel-all-grid');
  const facets = (counts) => BADGE_ORDER.map((id) => ({ id, label: BADGES[id].label, count: counts?.find((f) => f.badge === id)?.value ?? 0, tone: BADGES[id].tone, pressed: pressed.has(id) }));
  const bar = createFilterBar(panel.querySelector('.rel-all-filters'), {
    label: 'Filtres des associations',
    facets: facets(null),
    onToggle: (id, on) => { if (on) pressed.add(id); else pressed.delete(id); apply(); app.remember({ filtre: pressed.has('contradictory') ? 'contradictoire' : null }); },
  });

  const cellLink = (cell, label, small, kind) => `<span class="rel-cell-id" data-cell="${cell}">${avatar(kind, label, 'xs')}<span>${esc(label)}${small ? `<small class="mono">${esc(small)}</small>` : ''}</span></span>`;
  const actions = (r) => {
    const key = `data-key="${esc(r.key)}" data-persistence="${esc(r.persistence)}"`;
    return `<span class="rel-acts">
      <button class="rel-act" type="button" data-row-act="user" ${key} data-tip="Voir les relations de ${esc(r.userLogin)}" aria-label="Voir les relations de ${esc(r.userLogin)}">${glyph('user')}</button>
      <button class="rel-act" type="button" data-row-act="computer" ${key} data-tip="Voir les relations de ${esc(r.computer)}" aria-label="Voir les relations de ${esc(r.computer)}">${glyph('monitor')}</button>
      ${r.persistence === 'session'
        ? `<button class="rel-act wr" type="button" data-row-act="save" ${key} data-tip="Enregistrer l’observation (plan, confirmation, reçu)" aria-label="Enregistrer l’observation">${glyph('check')}</button>`
        : `<button class="rel-act danger" type="button" data-row-act="remove" ${key} data-tip="Retirer l’association (plan, confirmation, reçu ; restaurable)" aria-label="Retirer l’association">${glyph('trash')}</button>`}
    </span>`;
  };

  const grid = createGrid(gridHost, {
    key: 'relations.toutes.v2',
    label: 'Toutes les associations utilisateurs-postes',
    rowId: (r) => `${r.key}|${r.persistence}`,
    selection: 'multi',
    loading: true,
    height: '600px',
    quickPlaceholder: 'Filtrer : utilisateur, poste, source, détail…',
    columns: [
      { id: 'user', label: 'Utilisateur', required: true, width: 190, get: (r) => r.userName ?? r.userLogin, html: (v, r) => cellLink('user', v, r.userLogin, 'user') },
      { id: 'computer', label: 'Poste', required: true, width: 136, html: (v) => cellLink('computer', v, null, 'computer') },
      { id: 'badge', label: 'Qualification', type: 'enum', options: BADGE_OPTIONS, width: 146, html: (v, r) => qualification(r) },
      { id: 'when', label: 'Date', type: 'date', width: 108, html: (v, r) => dateCell(v, r), csv: (v) => formatDateTime(v) ?? '' },
      { id: 'source', label: 'Source', width: 160, html: (v) => `<span class="rel-src" data-tip="${esc(v)}">${esc(v)}</span>` },
      { id: 'details', label: 'Détails', width: 196 },
      { id: 'identity', label: 'Identité', type: 'enum', options: IDENTITY, width: 104, tip: 'Une association sans GUID enregistré a une identité non vérifiable.' },
      { id: 'actions', label: 'Actions', width: 112, sortable: false, filterable: false, secret: true, get: () => '', html: (v, r) => actions(r) },
      { id: 'persistence', label: 'Persistance', type: 'enum', options: PERSISTENCE, width: 150, hidden: true },
      { id: 'contradicted', label: 'Contradiction', type: 'bool', width: 130, hidden: true },
      { id: 'declarant', label: 'Déclarant', mono: true, width: 170, hidden: true },
      { id: 'batchId', label: 'Lot d’import', mono: true, width: 220, hidden: true },
      { id: 'identityNote', label: 'Note d’identité', width: 260, hidden: true },
      { id: 'userDn', label: 'DN de l’utilisateur', mono: true, width: 300, hidden: true },
      { id: 'computerDn', label: 'DN du poste', mono: true, width: 300, hidden: true },
    ],
    empty: { icon: 'link', title: 'Aucune association', text: 'Le magasin local ne contient encore aucune association utilisateur-poste.' },
    // Double click on the user or the workstation opens the fiche of that end (Domenia 1 REL-051, DN kept or search by name);
    // elsewhere, or Entrée, shows the relations of the user.
    onActivate: (row) => {
      const col = activeCol;
      activeCol = null;
      if (col === 'user') app.openFiche({ dn: row.userDn, name: row.userLogin });
      else if (col === 'computer') app.openFiche({ dn: row.computerDn, name: row.computer });
      else app.select(row.userDn ?? row.userLogin);
    },
    contextMenu: ({ row }) => (row ? app.rowMenu(row, 'both') : []),
    selectionActions: (sel) => {
      const session = sel.filter((r) => r.persistence === 'session');
      return [
        { label: `Exporter ${nouns(sel.length, 'ligne', 'lignes')}`, icon: 'csv', run: () => grid.exportCsv('selected') },
        { label: 'Copier', icon: 'copy', run: () => writeClipboard(grid.toCsv({ scope: 'selected' })).then((ok) => toast(ok ? `${nouns(sel.length, 'ligne copiée', 'lignes copiées')}.` : 'Copie impossible : presse-papiers indisponible.', { tone: ok ? 'ok' : 'warn' })) },
        ...(session.length ? [{ label: `Enregistrer ${nouns(Math.min(64, session.length), 'observation', 'observations')}`, icon: 'check', kind: 'write', disabled: session.length > 64, reason: '64 au plus par enregistrement.',
          run: () => app.plan('relations.observations.plan', { resultId: SESSION_RESULT, keys: session.slice(0, 64).map((r) => r.key) }) }] : []),
      ];
    },
    // The CSV of the kit (visible columns, formulas neutralised) goes to a file of the exports folder (Domenia 1 REL-050).
    onExport: (csv, info) => app.exportCsv(info.scope === 'selected' ? 'selection' : 'toutes', csv),
  });
  gridHost.addEventListener('dblclick', (e) => { activeCol = e.target instanceof Element ? e.target.closest('.k-gc')?.querySelector('[data-cell]')?.dataset.cell ?? null : null; }, true);
  gridHost.addEventListener('keydown', (e) => { if (e.key === 'Enter') activeCol = gridHost.querySelector('.k-gc.is-act [data-cell]')?.dataset.cell ?? null; }, true);
  gridHost.addEventListener('click', (e) => {
    const b = e.target instanceof Element ? e.target.closest('[data-row-act]') : null;
    if (!b) return;
    e.stopPropagation();
    const row = rows.find((r) => r.key === b.dataset.key && r.persistence === b.dataset.persistence);
    if (!row) return;
    const act = b.dataset.rowAct;
    if (act === 'user') app.select(row.userDn ?? row.userLogin);
    else if (act === 'computer') app.select(row.computerDn ?? row.computer);
    else if (act === 'save') app.plan('relations.observations.plan', { resultId: SESSION_RESULT, keys: [row.key] });
    else if (act === 'remove') app.plan('relations.remove.plan', { key: row.key, fingerprint: row.fingerprint });
  });

  function apply() {
    const shown = pressed.size ? rows.filter((r) => pressed.has(r.badge) || (pressed.has('contradictory') && r.contradicted)) : rows;
    grid.setRows(shown, { keepSelection: true, keepScroll: true });
    bar.setSummary(shown.length !== rows.length ? `→ ${nouns(shown.length, 'association affichée', 'associations affichées')} sur ${int(rows.length)}` : '');
  }

  function paintExport(result) {
    if (!result) { exportHost.hidden = true; return; }
    exportHost.hidden = false;
    exportHost.innerHTML = `<span class="rel-export-ico" aria-hidden="true">${glyph('csv')}</span>
      <div><b>${esc(result.fileName)}</b><span>${esc(nouns(result.rows, 'ligne', 'lignes'))} · ${result.saved ? `dossier des exports${NBSP}: ${esc(result.folder ?? '')}` : 'préparé en mémoire, non écrit (capture, E2E ou sans dossier de données)'} · ${esc(dateText(result.at, { time: true }) ?? '')}</span></div>
      ${result.saved ? `<button class="btn sm" type="button" data-open-export>${glyph('external')}Ouvrir le CSV</button>` : ''}`;
    exportHost.classList.remove('in'); void exportHost.offsetWidth; exportHost.classList.add('in');
    exportHost.querySelector('[data-open-export]')?.addEventListener('click', () => app.openExport(result.fileName));
  }
  const offExport = app.onExport(paintExport);
  if (app.lastExport) paintExport(app.lastExport);

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
    bar.setFacets(facets(data?.facets));
    grid.clearFilters();
    grid.setQuickFilter('');
    apply();
    app.remember({ filtre: null });
    grid.exportCsv('visible');
  }

  return {
    loading() { grid.setLoading(true); },
    show(list) {
      data = list;
      rows = list.rows;
      sub.innerHTML = `Magasin local${NBSP}· Active Directory n’est jamais modifié par une association${NBSP}· double clic sur un utilisateur ou un poste${NBSP}: sa fiche`;
      bar.setFacets(facets(list.facets));
      commands();
      apply();
      applyVars(panel);
    },
    failed(err) {
      grid.setError(errText(err), { retry: () => app.refreshList() });
    },
    /** Presses one facet (the contradiction chip of the header opens this tab filtered). */
    pressFacet(id) {
      pressed = new Set([id]);
      bar.setFacets(facets(data?.facets));
      if (data) apply();
    },
    /** Workstations of the rows shown (after filters), distinct, in order: the « liste chargée » of a detection or a relevé. */
    visibleComputers() {
      const seen = new Set();
      const names = [];
      for (const r of grid.getVisibleRows()) {
        const key = r.computer.toLowerCase();
        if (!seen.has(key)) { seen.add(key); names.push(r.computer); }
      }
      return names;
    },
    destroy() { offExport(); cmd?.destroy(); grid.destroy(); bar.destroy(); },
  };
}
