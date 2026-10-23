// « Bibliothèque »: delivered templates, personal recipes and archives of this domain, in a grid with a usage detail
// (description, sources, collection, declared provenance, revisions, widgets and linked elements). « Utiliser » loads a
// recipe into the draft (never an archive: restore it first); archiving goes through the impact review of the linked
// elements, removes the widgets in the same write and can be undone; restoring brings the widgets back.
import {
  esc, glyph, key, plural, TARGETS, emptyState, skLines, vars, ago,
} from './shared.js';
import { createGrid, createSplit, createFilterBar, openDialog } from '../../kit/index.js';
import { reveal, inkFollow } from '../../ui.js';
import { mountRevisionHistory } from './history.js';

/** Summary values that only say « nothing here »: not repeated in the detail. */
const EMPTY = new Set(['Aucune contrainte', 'Aucune', 'Aucun']);

const SOURCES = [
  { id: 'all', label: 'Modèles et mes requêtes' },
  { id: 'templates', label: 'Modèles livrés' },
  { id: 'personal', label: 'Mes requêtes' },
  { id: 'archives', label: 'Archives' },
];

const ARCHIVED_REASON = 'Requête archivée : restaurez-la pour l’utiliser.';

export function mountLibrary(panel, store, api) {
  const st = { source: 'all', target: null, category: null, sort: 'name', rows: [], grid: null, split: null, bar: null, token: 0, detailToken: 0, active: null };
  panel.innerHTML = `<section class="card rq-library spot reveal" aria-labelledby="rq-lib-title">
    <div class="card-head"><span class="card-icon">${glyph('database')}</span><div class="rq-head-titles"><h3 id="rq-lib-title">Bibliothèque</h3>
      <p class="rq-sub rq-lib-sub">Modèles livrés avec Domenia et requêtes enregistrées pour ce domaine.</p></div>
      <div class="segmented rq-lib-source" role="radiogroup" aria-label="Contenu affiché"><span class="thumb" aria-hidden="true"></span>${SOURCES.map((s) => `<button type="button" role="radio" data-source="${s.id}" aria-checked="${s.id === 'all'}">${esc(s.label)}</button>`).join('')}</div></div>
    <div class="rq-lib-filters"></div>
    <div class="rq-lib-receipt" hidden role="status"></div>
    <div class="rq-lib-split"></div>
  </section>`;
  const $ = (sel) => panel.querySelector(sel);

  function renderFilters(categories) {
    st.bar?.destroy();
    st.bar = createFilterBar($('.rq-lib-filters'), {
      label: 'Filtres de la bibliothèque',
      facets: [
        ...TARGETS.map((t) => ({ id: `t:${t.id}`, label: t.label, pressed: st.target === t.id })),
        { id: 'recent', label: 'Récentes d’abord', pressed: st.sort === 'recent' },
      ],
      chips: st.category ? [{ id: 'category', label: 'Catégorie', value: st.category, scope: 'Bibliothèque' }] : [],
      addItems: categories.length ? [{ label: 'Catégorie', icon: 'tag', items: categories.map((c) => ({ label: c, checked: st.category === c, radio: 'cat', run: () => { st.category = c; load(); } })) }] : [],
      onRemove: () => { st.category = null; load(); },
      onClear: () => { st.category = null; st.target = null; st.sort = 'name'; load(); },
      onToggle: (id, pressed) => {
        if (id === 'recent') st.sort = pressed ? 'recent' : 'name';
        else st.target = pressed ? id.slice(2) : null;
        load();
      },
    });
  }

  const columns = [
    { id: 'name', label: 'Nom', required: true, width: 330, get: (r) => r.name },
    { id: 'informations', label: 'Informations nécessaires', width: 300, get: (r) => r.informations },
    { id: 'target', label: 'Cible', type: 'enum', width: 120, get: (r) => r.target, options: TARGETS.map((t) => ({ value: t.id, label: t.label })) },
    { id: 'source', label: 'Origine', type: 'enum', width: 132, get: (r) => r.source,
      options: [{ value: 'template', label: 'Modèle livré', tone: 'info' }, { value: 'personal', label: 'Mes requêtes', tone: 'ok' }, { value: 'archive', label: 'Archive', tone: 'off' }] },
    { id: 'category', label: 'Catégorie', width: 150, get: (r) => r.category },
    { id: 'remote', label: 'Collecte', type: 'enum', width: 132, get: (r) => (r.remote ? 'yes' : 'no'),
      options: [{ value: 'yes', label: 'Relevés de postes', tone: 'warn' }, { value: 'no', label: 'Base locale', tone: 'ok' }] },
    { id: 'updatedAt', label: 'Mise à jour', type: 'date', width: 140, get: (r) => r.updatedAt },
    { id: 'revision', label: 'Révision', type: 'number', width: 96, get: (r) => (r.source === 'template' ? null : r.revision), format: (v) => (v === null ? '—' : String(v)) },
    { id: 'widgets', label: 'Widgets', type: 'number', width: 92, get: (r) => r.widgets },
    { id: 'description', label: 'Description', width: 360, hidden: true, get: (r) => r.description },
  ];

  function ensureGrid() {
    if (st.grid) return;
    const listNode = document.createElement('div');
    const detailNode = document.createElement('div');
    detailNode.className = 'rq-detail rq-lib-detail';
    st.split = createSplit($('.rq-lib-split'), { a: listNode, b: detailNode, key: 'requetes.bibliotheque.detail.v2', size: 400, min: 320, max: 720, label: 'Taille du détail de la requête' });
    st.grid = createGrid(listNode, {
      key: 'requetes.bibliotheque.v2',
      label: 'Requêtes de la bibliothèque',
      columns,
      rowId: (r) => `${r.source}:${r.id}`,
      selection: 'single',
      height: '560px',
      loading: true,
      quickPlaceholder: 'Chercher une requête…',
      empty: { icon: 'database', title: 'Aucune requête', text: 'Aucune requête ne correspond à ces filtres. Enregistrez votre brouillon depuis « Enregistrer ».' },
      onActiveChange: (row) => { if (row) detail(row); },
      onActivate: (row) => use(row),
      contextMenu: ({ row }) => [
        { label: 'Utiliser dans l’atelier', icon: 'play', kbd: 'Entrée', disabled: !row || row.archived, reason: ARCHIVED_REASON, run: () => use(row) },
        { label: 'Utiliser et calculer l’aperçu', icon: 'eye', disabled: !row || row.archived, reason: ARCHIVED_REASON, run: () => use(row, true) },
        ...(row?.archived ? [{ label: 'Restaurer…', icon: 'undo', run: () => restoreRow(row) }] : []),
      ],
    });
    renderDetailEmpty();
  }

  async function load() {
    ensureGrid();
    const my = ++st.token;
    st.grid.setLoading(true);
    const args = { source: st.source, sort: st.sort, limit: 5000, ...(st.target ? { target: st.target } : {}), ...(st.category ? { category: st.category } : {}) };
    const res = await store.call('requetes.library.list', args);
    if (!store.alive || my !== st.token) return;
    if (res.error) { st.grid.setError(res.message, { retry: load }); return; }
    const data = res.data;
    st.rows = data.rows;
    st.grid.setRows(data.rows, { hasMore: false, keepSelection: true });
    const still = st.active && data.rows.find((r) => r.id === st.active.id && r.source === st.active.source);
    if (still) detail(still);
    else if (data.rows.length) detail(data.rows[0]);
    else { st.active = null; renderDetailEmpty(); }
    renderFilters(data.categories);
    $('.rq-lib-sub').textContent = `${plural(data.filtered, 'requête', 'requêtes')} affichées sur ${plural(data.total, 'requête', 'requêtes')}${st.sort === 'recent' ? ' · les plus récentes d’abord' : ''}${data.unreadable ? ` · ${plural(data.unreadable, 'définition illisible conservée', 'définitions illisibles conservées')}` : ''}${data.persistent ? '' : ' · mode sans enregistrement sur le disque'}`;
  }

  function renderDetailEmpty() {
    const host = panel.querySelector('.rq-lib-detail');
    host.innerHTML = `<div class="rq-detail-empty">${glyph('database')}<p><b>Choisissez une requête</b>Son usage, ses sources, sa collecte et sa provenance s’affichent ici.</p></div>`;
  }

  async function detail(row) {
    const host = panel.querySelector('.rq-lib-detail');
    st.active = row;
    const my = ++st.detailToken;
    host.innerHTML = `<div class="rq-detail-in" aria-busy="true">${skLines(60, 90, 80, 70, 85)}</div>`;
    const res = await store.call('requetes.library.get', { id: row.id });
    if (!store.alive || my !== st.detailToken) return;
    if (res.error) { host.innerHTML = emptyState('alert', 'Détail indisponible', res.message); return; }
    const d = res.data;
    const target = TARGETS.find((t) => t.id === key(d.recipe.target)) ?? TARGETS[0];
    const sourcePill = { template: '<span class="k-pill info sm">Modèle livré</span>', personal: '<span class="k-pill ok sm">Mes requêtes</span>', archive: '<span class="k-pill off sm">Archive</span>' }[d.source] ?? '';
    const archived = d.source === 'archive';
    host.innerHTML = `<div class="rq-detail-in rq-lib-card">
      <header class="rq-detail-head"><span class="avatar">${glyph(target.icon)}</span><div class="rq-detail-titles"><h4>${esc(d.name)}</h4><span>${esc(d.category)} · ${esc(target.label)}${d.updatedAt ? ` · ${esc(ago(d.updatedAt))}` : ''}</span></div>${sourcePill}</header>
      ${d.description ? `<p class="rq-lib-desc">${esc(d.description)}</p>` : ''}
      <div class="rq-detail-actions">
        <button type="button" class="btn primary sm" data-act="use"${archived ? ` disabled aria-describedby="rq-lib-why"` : ''}>${glyph('play')}Utiliser</button>
        <button type="button" class="btn subtle sm" data-act="preview"${archived ? ' disabled' : ''}>${glyph('eye')}Utiliser et calculer l’aperçu</button>
        ${archived ? `<button type="button" class="btn ghost sm" data-act="restore">${glyph('undo')}Restaurer${d.archivedWidgets.length ? ` avec ${plural(d.archivedWidgets.length, 'widget', 'widgets')}` : ''}</button>` : ''}
        ${d.source === 'personal' ? `<button type="button" class="btn ghost sm" data-act="archive">${glyph('trash')}Archiver…</button>` : ''}
      </div>
      ${archived ? `<p class="rq-note" id="rq-lib-why">${glyph('info')}${esc(ARCHIVED_REASON)}</p>` : ''}
      <dl class="rq-facts">${d.summary.map((l) => ({ element: l.element, values: l.values.filter((v) => v && !EMPTY.has(v)) })).filter((l) => l.values.length && l.element !== 'Nom')
        .map((l) => `<div><dt>${esc(l.element)}</dt><dd>${l.values.map((v) => `<span>${esc(v)}</span>`).join('')}</dd></div>`).join('')}</dl>
      <ul class="rq-lib-notes">
        <li>${glyph('database')}${esc(d.sources)}</li>
        <li>${glyph('wifi')}${esc(d.collection)}</li>
        <li>${glyph('shield')}${esc(d.provenanceText)}</li>
      </ul>
      ${d.source !== 'template' ? '<h5 class="rq-mini-title">Révisions</h5><div class="rq-history"></div>' : ''}
      ${d.widgets.length ? `<h5 class="rq-mini-title">Widgets liés</h5><ul class="rq-w-items compact">${d.widgets.map((w) => `<li><span class="rq-w-ico">${glyph(w.board === 'computer' ? 'object' : 'gauge')}</span><div class="rq-w-main"><b>${esc(w.title)}</b><span>Révision ${esc(String(w.boundRevision))} · ${esc(w.visual)}</span></div></li>`).join('')}</ul>` : ''}
      ${d.archivedWidgets.length ? `<h5 class="rq-mini-title">Widgets retirés par l’archivage</h5><ul class="rq-w-items compact">${d.archivedWidgets.map((w) => `<li><span class="rq-w-ico">${glyph('undo')}</span><div class="rq-w-main"><b>${esc(w.title)}</b><span>Remis par la restauration</span></div></li>`).join('')}</ul>` : ''}
      ${d.consumers.length ? `<h5 class="rq-mini-title">Éléments liés</h5><ul class="rq-w-items compact">${d.consumers.map((c) => `<li><span class="rq-w-ico">${glyph(c.kind.startsWith('legacy') ? 'history' : c.kind === 'health' ? 'activity' : 'search')}</span><div class="rq-w-main"><b>${esc(c.title)}</b><span>${c.kind.startsWith('legacy') ? `Lien Domenia 1 · révision ${esc(String(c.boundRevision))} conservée · disposition non importée` : c.kind === 'health' ? `Santé · révision ${esc(String(c.boundRevision))} conservée` : 'Favori de Recherche · définition courante'}</span></div></li>`).join('')}</ul>` : ''}
    </div>`;
    vars(host);
    if (d.source !== 'template') mountRevisionHistory(host.querySelector('.rq-history'), d);
    host.querySelector('[data-act="use"]').addEventListener('click', () => use(row, false, d));
    host.querySelector('[data-act="preview"]').addEventListener('click', () => use(row, true, d));
    host.querySelector('[data-act="restore"]')?.addEventListener('click', () => restore(d));
    host.querySelector('[data-act="archive"]')?.addEventListener('click', () => archive(d));
  }

  async function use(row, preview = false, known = null) {
    if (!row) return;
    if (row.archived || row.source === 'archive') { store.toast(ARCHIVED_REASON, 'warn'); return; }
    let d = known;
    if (!d) {
      const res = await store.call('requetes.library.get', { id: row.id });
      if (res.error) { store.toast(res.message, 'warn'); return; }
      d = res.data;
    }
    api.load(d, { preview });
  }

  function libraryReceipt(text, ok, action = null) {
    const box = panel.querySelector('.rq-lib-receipt');
    box.hidden = false;
    box.className = `rq-lib-receipt rq-receipt ${ok ? 'ok' : 'warn'} pop`;
    box.innerHTML = `<span class="rq-receipt-mark">${glyph(ok ? 'check' : 'alert')}</span><div class="rq-receipt-text"><span>${esc(text)}</span></div>
      ${action ? `<button type="button" class="btn xs subtle rq-receipt-act">${glyph(action.icon)}${esc(action.label)}</button>` : ''}`;
    if (action) box.querySelector('.rq-receipt-act').addEventListener('click', action.run, { once: true });
  }

  async function restoreRow(row) {
    const res = await store.call('requetes.library.get', { id: row.id });
    if (res.error) { store.toast(res.message, 'warn'); return; }
    restore(res.data);
  }

  async function restore(d) {
    const res = await store.call('requetes.library.restore', { id: d.id, expectedRevision: d.revision, restoreWidgets: true });
    if (res.error) { store.toast(res.message, 'warn'); return; }
    const back = res.data.restoredWidgets?.length ?? 0;
    libraryReceipt(`« ${res.data.name} » restaurée (révision ${res.data.revision})${back ? ` avec ${plural(back, 'widget', 'widgets')}` : ''}. ${res.data.receipt.text}`, res.data.receipt.readBack);
    if (store.saved?.id === d.id) { store.saved = { ...store.saved, archived: false, revision: res.data.revision }; store.emit('saved', store.saved); }
    st.active = { ...st.active, source: 'personal', archived: false };
    st.source = st.source === 'archives' ? 'all' : st.source;
    panel.querySelectorAll('[data-source]').forEach((x) => x.setAttribute('aria-checked', String(x.dataset.source === st.source)));
    ink.update();
    load();
  }

  /** Same impact review as « Enregistrer » (Domenia 1 PnlQueryImpact), then one write and an undo in the receipt. */
  async function archive(d) {
    const impact = await store.call('requetes.library.impact', { id: d.id });
    if (impact.error) { store.toast(impact.message, 'warn'); return; }
    const i = impact.data;
    const rows = i.rows.map((r) => `<tr><th scope="row">${esc(r.name)}</th><td>${esc(r.element)}</td><td>${esc(r.link)}</td></tr>`).join('');
    const dlg = openDialog({
      title: `Archiver « ${d.name} » ?`,
      subtitle: 'La requête et ses révisions restent dans les archives ; la restauration remet ses widgets.',
      icon: 'trash',
      tone: 'danger',
      size: rows ? 'lg' : 'md',
      body: `<div class="rq-impact"><p>${i.widgets ? esc(`${plural(i.widgets, 'widget sera retiré', 'widgets seront retirés')} des tableaux de bord, dans la même écriture que l’archivage.`) : 'Aucun widget n’utilise cette requête.'} Rien n’est écrit dans l’annuaire.</p>
        ${rows ? `<h4>Éléments qui utilisent cette requête</h4><div class="rq-table-wrap"><table class="table rq-table"><thead><tr><th>Nom</th><th>Élément</th><th>Lien</th></tr></thead><tbody>${rows}</tbody></table></div>` : ''}</div>`,
      actions: [{ id: 'cancel', label: 'Annuler', safe: true }, { id: 'archive', label: i.widgets ? 'Archiver et retirer les widgets' : 'Archiver', icon: 'trash', danger: true }],
    });
    if (await dlg.result !== 'archive') return;
    const res = await store.call('requetes.library.archive', { id: d.id, expectedRevision: d.revision });
    if (res.error) { store.toast(res.message, 'warn'); return; }
    const removed = res.data.removedWidgets?.length ?? 0;
    if (store.saved?.id === d.id) { store.saved = { ...store.saved, archived: true, revision: res.data.revision }; store.emit('saved', store.saved); }
    await load();
    libraryReceipt(`« ${res.data.name} » archivée${removed ? `, ${plural(removed, 'widget retiré', 'widgets retirés')}` : ''}. ${res.data.receipt.text}`, res.data.receipt.readBack, {
      label: 'Annuler l’archivage',
      icon: 'undo',
      run: () => restore({ id: d.id, revision: res.data.revision }),
    });
  }

  panel.querySelectorAll('[data-source]').forEach((b) => b.addEventListener('click', () => {
    st.source = b.dataset.source;
    panel.querySelectorAll('[data-source]').forEach((x) => x.setAttribute('aria-checked', String(x === b)));
    ink.update();
    load();
  }));
  const ink = inkFollow($('.rq-lib-source'), '[data-source]', '[aria-checked="true"]');
  const offs = [store.on('saved', () => load())];
  const stopReveal = reveal(panel);
  load();

  return {
    refresh: load,
    destroy() {
      offs.forEach((off) => off());
      ink.stop();
      stopReveal();
      st.grid?.destroy();
      st.bar?.destroy();
    },
  };
}
