// « Bibliothèque »: delivered templates, personal recipes and archives of this domain, in a grid with a usage detail
// (description, sources, collection, declared provenance, revisions, widgets). « Utiliser » loads a recipe into the draft;
// archiving and restoring are local writes with a re-read receipt.
import {
  esc, glyph, key, plural, TARGETS, emptyState, skLines, dateText, vars,
} from './shared.js';
import { createGrid, createSplit, createFilterBar, openDialog } from '../../kit/index.js';
import { reveal, inkFollow } from '../../ui.js';

/** Summary values that only say « nothing here »: not repeated in the detail. */
const EMPTY = new Set(['Aucune contrainte', 'Aucune', 'Aucun']);

const SOURCES = [
  { id: 'all', label: 'Modèles et mes requêtes' },
  { id: 'templates', label: 'Modèles livrés' },
  { id: 'personal', label: 'Mes requêtes' },
  { id: 'archives', label: 'Archives' },
];

export function mountLibrary(panel, store, api) {
  const st = { source: 'all', target: null, category: null, rows: [], grid: null, split: null, bar: null, token: 0, detailToken: 0, active: null };
  panel.innerHTML = `<section class="card rq-library spot reveal" aria-labelledby="rq-lib-title">
    <div class="card-head"><span class="card-icon">${glyph('database')}</span><div class="rq-head-titles"><h3 id="rq-lib-title">Bibliothèque</h3>
      <p class="rq-sub rq-lib-sub">Modèles livrés avec Domenia et requêtes enregistrées pour ce domaine.</p></div>
      <div class="segmented rq-lib-source" role="radiogroup" aria-label="Contenu affiché"><span class="thumb" aria-hidden="true"></span>${SOURCES.map((s) => `<button type="button" role="radio" data-source="${s.id}" aria-checked="${s.id === 'all'}">${esc(s.label)}</button>`).join('')}</div></div>
    <div class="rq-lib-filters"></div>
    <div class="rq-lib-split"></div>
  </section>`;
  const $ = (sel) => panel.querySelector(sel);

  function renderFilters(categories) {
    st.bar?.destroy();
    st.bar = createFilterBar($('.rq-lib-filters'), {
      label: 'Filtres de la bibliothèque',
      facets: [
        ...TARGETS.map((t) => ({ id: `t:${t.id}`, label: t.label, pressed: st.target === t.id })),
      ],
      chips: st.category ? [{ id: 'category', label: 'Catégorie', value: st.category, scope: 'Bibliothèque' }] : [],
      addItems: categories.length ? [{ label: 'Catégorie', icon: 'tag', items: categories.map((c) => ({ label: c, checked: st.category === c, radio: 'cat', run: () => { st.category = c; load(); } })) }] : [],
      onRemove: () => { st.category = null; load(); },
      onClear: () => { st.category = null; st.target = null; load(); },
      onToggle: (id, pressed) => {
        st.target = pressed ? id.slice(2) : null;
        load();
      },
    });
  }

  const columns = [
    { id: 'name', label: 'Nom', required: true, width: 300, get: (r) => r.name },
    { id: 'category', label: 'Catégorie', width: 190, get: (r) => r.category },
    { id: 'source', label: 'Origine', type: 'enum', width: 150, get: (r) => r.source,
      options: [{ value: 'template', label: 'Modèle livré', tone: 'info' }, { value: 'personal', label: 'Mes requêtes', tone: 'ok' }, { value: 'archive', label: 'Archive', tone: 'off' }] },
    { id: 'target', label: 'Cible', type: 'enum', width: 130, get: (r) => r.target, options: TARGETS.map((t) => ({ value: t.id, label: t.label })) },
    { id: 'informations', label: 'Informations', width: 320, get: (r) => r.informations },
    { id: 'remote', label: 'Collecte', type: 'enum', width: 130, get: (r) => (r.remote ? 'yes' : 'no'),
      options: [{ value: 'yes', label: 'Relevés de postes', tone: 'warn' }, { value: 'no', label: 'Base locale', tone: 'ok' }] },
    { id: 'revision', label: 'Révision', type: 'number', width: 100, get: (r) => (r.source === 'template' ? null : r.revision), format: (v) => (v === null ? '—' : String(v)) },
    { id: 'updatedAt', label: 'Mise à jour', type: 'date', width: 150, get: (r) => r.updatedAt },
    { id: 'widgets', label: 'Widgets', type: 'number', width: 100, get: (r) => r.widgets },
    { id: 'description', label: 'Description', width: 360, hidden: true, get: (r) => r.description },
  ];

  function ensureGrid() {
    if (st.grid) return;
    const listNode = document.createElement('div');
    const detailNode = document.createElement('div');
    detailNode.className = 'rq-detail rq-lib-detail';
    st.split = createSplit($('.rq-lib-split'), { a: listNode, b: detailNode, key: 'requetes.bibliotheque.detail', size: 460, min: 340, max: 760, label: 'Taille du détail de la requête' });
    st.grid = createGrid(listNode, {
      key: 'requetes.bibliotheque',
      label: 'Requêtes de la bibliothèque',
      columns,
      rowId: (r) => `${r.source}:${r.id}`,
      selection: 'single',
      height: '560px',
      loading: true,
      quickPlaceholder: 'Chercher une requête (sans accents)…',
      empty: { icon: 'database', title: 'Aucune requête', text: 'Aucune requête ne correspond à ces filtres. Enregistrez votre brouillon depuis « Enregistrer ».' },
      onActiveChange: (row) => { if (row) detail(row); },
      onActivate: (row) => use(row),
      contextMenu: ({ row }) => [
        { label: 'Utiliser dans l’atelier', icon: 'play', kbd: 'Entrée', disabled: !row, run: () => use(row) },
        { label: 'Utiliser et calculer l’aperçu', icon: 'eye', disabled: !row, run: () => use(row, true) },
      ],
    });
    renderDetailEmpty();
  }

  async function load() {
    ensureGrid();
    const my = ++st.token;
    st.grid.setLoading(true);
    const args = { source: st.source, limit: 2000, ...(st.target ? { target: st.target } : {}), ...(st.category ? { category: st.category } : {}) };
    const res = await store.call('requetes.library.list', args);
    if (!store.alive || my !== st.token) return;
    if (res.error) { st.grid.setError(res.message, { retry: load }); return; }
    const data = res.data;
    st.rows = data.rows;
    st.grid.setRows(data.rows, { hasMore: false });
    if (data.rows.length && !st.active) detail(data.rows[0]);
    else if (!data.rows.length) { st.active = null; renderDetailEmpty(); }
    renderFilters(data.categories);
    $('.rq-lib-sub').textContent = `${plural(data.filtered, 'requête', 'requêtes')} affichées sur ${plural(data.total, 'requête', 'requêtes')}${data.unreadable ? ` · ${plural(data.unreadable, 'définition illisible ignorée', 'définitions illisibles ignorées')}` : ''}${data.persistent ? '' : ' · préférences non persistantes'}`;
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
    host.innerHTML = `<div class="rq-detail-in rq-lib-card">
      <header class="rq-detail-head"><span class="avatar">${glyph(target.icon)}</span><div class="rq-detail-titles"><h4>${esc(d.name)}</h4><span>${esc(d.category)} · ${esc(target.label)}</span></div>${sourcePill}</header>
      ${d.description ? `<p class="rq-lib-desc">${esc(d.description)}</p>` : ''}
      <div class="rq-detail-actions">
        <button type="button" class="btn primary sm" data-act="use">${glyph('play')}Utiliser</button>
        <button type="button" class="btn subtle sm" data-act="preview">${glyph('eye')}Utiliser et calculer l’aperçu</button>
        ${d.source === 'archive' ? `<button type="button" class="btn ghost sm" data-act="restore">${glyph('undo')}Restaurer</button>` : ''}
        ${d.source === 'personal' ? `<button type="button" class="btn ghost sm" data-act="archive">${glyph('trash')}Archiver…</button>` : ''}
      </div>
      <dl class="rq-facts">${d.summary.map((l) => ({ element: l.element, values: l.values.filter((v) => v && !EMPTY.has(v)) })).filter((l) => l.values.length && l.element !== 'Nom')
        .map((l) => `<div><dt>${esc(l.element)}</dt><dd>${l.values.map((v) => `<span>${esc(v)}</span>`).join('')}</dd></div>`).join('')}</dl>
      <ul class="rq-lib-notes">
        <li>${glyph('database')}${esc(d.sources)}</li>
        <li>${glyph('wifi')}${esc(d.collection)}</li>
        <li>${glyph('shield')}${esc(d.provenanceText)}</li>
      </ul>
      ${d.source !== 'template' ? `<h5 class="rq-mini-title">Révisions</h5><ol class="rq-revs compact">${[{ revision: d.revision, savedAt: d.updatedAt, fingerprint: '' }, ...[...d.history].sort((a, b) => b.revision - a.revision)].map((h, n) => `<li data-i="${n}"><span class="rq-rev-n">${esc(String(h.revision))}</span><div><b>${h.revision === d.revision ? 'Révision actuelle' : `Révision ${esc(String(h.revision))}`}</b><span>${esc(dateText(h.savedAt))}${h.fingerprint ? ` · <span class="rq-mono">${esc(h.fingerprint.slice(0, 12))}</span>` : ''}</span></div></li>`).join('')}</ol>` : ''}
      ${d.widgets.length ? `<h5 class="rq-mini-title">Widgets liés</h5><ul class="rq-w-items compact">${d.widgets.map((w) => `<li><span class="rq-w-ico">${glyph('gauge')}</span><div class="rq-w-main"><b>${esc(w.title)}</b><span>Révision ${esc(String(w.boundRevision))} · ${esc(w.visual)}</span></div></li>`).join('')}</ul>` : ''}
    </div>`;
    vars(host);
    host.querySelector('[data-act="use"]').addEventListener('click', () => use(row, false, d));
    host.querySelector('[data-act="preview"]').addEventListener('click', () => use(row, true, d));
    host.querySelector('[data-act="restore"]')?.addEventListener('click', () => restore(d));
    host.querySelector('[data-act="archive"]')?.addEventListener('click', () => archive(d));
  }

  async function use(row, preview = false, known = null) {
    let d = known;
    if (!d) {
      const res = await store.call('requetes.library.get', { id: row.id });
      if (res.error) { store.toast(res.message, 'warn'); return; }
      d = res.data;
    }
    api.load(d, { preview });
  }

  async function restore(d) {
    const res = await store.call('requetes.library.restore', { id: d.id, expectedRevision: d.revision, widgets: [] });
    if (res.error) { store.toast(res.message, 'warn'); return; }
    store.toast(`« ${res.data.name} » restaurée (révision ${res.data.revision}). ${res.data.receipt.text}`, res.data.receipt.readBack ? 'ok' : 'warn');
    load();
  }

  async function archive(d) {
    const dlg = openDialog({
      title: `Archiver « ${d.name} » ?`,
      subtitle: 'La requête et ses révisions restent dans les archives.',
      icon: 'trash',
      tone: 'danger',
      body: `<p>${d.widgets.length ? esc(`${plural(d.widgets.length, 'widget sera retiré', 'widgets seront retirés')} des tableaux de bord.`) : 'Aucun widget n’utilise cette requête.'} Rien n’est écrit dans l’annuaire.</p>`,
      actions: [{ id: 'cancel', label: 'Annuler', safe: true }, { id: 'archive', label: 'Archiver', icon: 'trash', danger: true }],
    });
    if (await dlg.result !== 'archive') return;
    const res = await store.call('requetes.library.archive', { id: d.id, expectedRevision: d.revision });
    if (res.error) { store.toast(res.message, 'warn'); return; }
    store.toast(`« ${res.data.name} » archivée. ${res.data.receipt.text}`, res.data.receipt.readBack ? 'ok' : 'warn');
    if (store.saved?.id === d.id) { store.saved = { ...store.saved, archived: true, revision: res.data.revision }; store.emit('saved', store.saved); }
    load();
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
