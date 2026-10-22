// « Données » workspace: search of the local index (Domenia 1 TxtIndexSearch, DgIndex, points 1 to 5). The term waits 250 ms
// after the last key (no read on the key itself), a newer search replaces the older one, the engine sorts the whole filtered
// population before cutting the page (the sort menu, not the headers: only fixed expressions exist), a locked base is said and
// tried again once. Double click or « Ouvrir la fiche » opens the object (a fresh read of the directory belongs to the Fiche).
import { createGrid, createSplit, kvSection, bindKv, openMenu, writeClipboard } from '../../kit/index.js';
import { announce } from '../../ui.js';
import {
  esc, icon, glyph, pill, int, count, NBSP, button, errorText, emptyBlock, paint, ago,
} from './common.js';

const SORTS = [
  ['relevance', 'Pertinence'], ['name', 'Nom'], ['type', 'Type'], ['login', 'Identifiant'], ['upn', 'UPN ou DNS'], ['state', 'État'],
  ['description', 'Détail'], ['score', 'Score'], ['reason', 'Correspondance'], ['lastLogon', 'Connexion AD'], ['whenChanged', 'Modifié dans AD'],
];
const SIZES = [50, 100, 200, 500];
const DEBOUNCE_MS = 250;
const RETRY_MS = 600;

const COLUMNS = [
  { id: 'typeLabel', label: 'Type', width: 110, sortable: false, filterable: false, html: (v, r) => `<span class="sy-type">${glyph(r.type === 'computer' ? 'monitor' : 'user')}${esc(v)}</span>` },
  { id: 'name', label: 'Nom', required: true, width: 220, sortable: false, filterable: false },
  { id: 'login', label: 'Identifiant', width: 150, mono: true, sortable: false, filterable: false },
  { id: 'upn', label: 'UPN ou DNS', width: 230, sortable: false, filterable: false },
  {
    id: 'stateLabel', label: 'État', width: 110, type: 'enum', sortable: false, filterable: false,
    options: [{ value: 'Actif', label: 'Actif', tone: 'ok' }, { value: 'Désactivé', label: 'Désactivé', tone: 'off' }],
  },
  { id: 'association', label: 'Association', width: 200, sortable: false, filterable: false },
  { id: 'score', label: 'Score', type: 'number', width: 80, align: 'end', sortable: false, filterable: false, tip: '100\u00A0: exacte · 90\u00A0: début du nom · 70\u00A0: contenu dans la fiche' },
  { id: 'reason', label: 'Correspondance', width: 170, sortable: false, filterable: false },
  { id: 'description', label: 'Détail', width: 260, sortable: false, filterable: false },
  { id: 'location', label: 'Emplacement', width: 220, sortable: false, filterable: false },
  { id: 'lastLogon', label: 'Connexion AD', type: 'date', width: 150, sortable: false, filterable: false },
  { id: 'whenChanged', label: 'Modifié dans AD', type: 'date', width: 150, sortable: false, filterable: false },
  { id: 'dn', label: 'Chemin (DN)', mono: true, hidden: true, width: 380, sortable: false, filterable: false },
  { id: 'guid', label: 'GUID', mono: true, hidden: true, width: 300, sortable: false, filterable: false },
];

function detailMarkup(row) {
  if (!row) {
    return emptyBlock('object', 'Aucun objet choisi', 'Choisissez une ligne pour voir sa fiche locale\u00A0: identité, emplacement, dates lues dans l’annuaire.');
  }
  const crumbs = String(row.location ?? '').split(/\s*›\s*/).filter(Boolean).map((p) => `<span>${esc(p)}</span>`).join(glyph('chevronRight'));
  const head = `<div class="sy-detail-head"><span class="sy-detail-ico" data-type="${esc(row.type)}">${glyph(row.type === 'computer' ? 'monitor' : 'user')}</span>
      <div><h3>${esc(row.name)}</h3><p>${esc(row.typeLabel)} · ${esc(row.login ?? '—')}</p></div>${pill(row.enabled ? 'ok' : 'off', row.stateLabel, { size: 'sm' })}</div>
    <div class="sy-detail-crumbs" aria-label="Emplacement">${crumbs || esc('(racine du domaine)')}</div>`;
  const identity = kvSection({ id: 'identite', title: 'Identité', icon: 'user', items: [
    { label: 'Identifiant', value: row.login, mono: true, copy: true },
    { label: row.type === 'computer' ? 'Nom DNS' : 'UPN', value: row.upn, mono: true, copy: true },
    ...(row.type === 'computer' ? [] : [{ label: 'Nom affiché', value: row.displayName }]),
    { label: 'Détail', value: row.description, wide: true },
    { label: row.type === 'computer' ? 'Système et lieu' : 'Service et fonction', value: row.extra, wide: true },
  ] });
  const ad = kvSection({ id: 'annuaire', title: 'Lu dans l’annuaire', icon: 'clock', items: [
    { label: 'Connexion AD', html: row.lastLogon ? ago(row.lastLogon) : undefined, value: row.lastLogon ? undefined : null },
    { label: 'Modifié dans AD', html: row.whenChanged ? ago(row.whenChanged) : undefined, value: row.whenChanged ? undefined : null },
    ...(row.type === 'computer' ? [{ label: 'Expiration LAPS', html: row.lapsExpiration ? ago(row.lapsExpiration) : undefined, value: row.lapsExpiration ? undefined : null, sub: 'Date seulement, jamais le mot de passe' }] : []),
    { label: 'Enregistré dans la base', html: ago(row.observedAt) },
  ] });
  const where = kvSection({ id: 'emplacement', title: 'Emplacement et identité', icon: 'ou', items: [
    { label: 'Chemin (DN)', value: row.dn, mono: true, copy: true, wide: true },
    { label: 'GUID', value: row.guid, mono: true, copy: true, wide: true },
    { label: 'Association', value: row.association, wide: true },
    { label: 'Correspondance', value: `${row.reason} (score ${row.score})` },
  ] });
  return `${head}<div class="sy-detail-kv">${identity}${ad}${where}</div>
    <div class="sy-detail-actions">${button('Ouvrir la fiche', { icon: 'object', primary: true, sm: true, data: { dt: 'open' }, tip: 'Ouvre la fiche de l’objet (lecture fraîche de l’annuaire)' })}${button('Copier le DN', { icon: 'copy', sm: true, ghost: true, data: { dt: 'copy-dn' } })}</div>`;
}

/** Renders the workspace in its panel; returns its cleanup. */
export function renderData(panel, screen) {
  const ctx = screen.ctx;
  panel.classList.add('sy-ws', 'sy-ws-data');
  const st = { term: typeof ctx.params.q === 'string' ? ctx.params.q.slice(0, 100) : '', sort: 'relevance', descending: false, limit: 200, offset: 0, page: null, seq: 0, attempt: 0, selected: null };
  panel.innerHTML = `<div class="sy-data">
      <div class="sy-data-bar" role="search">
        <label class="sy-search">${icon('search')}<span class="visually-hidden">Rechercher dans la base locale</span>
          <input class="input" type="search" maxlength="100" autocomplete="off" spellcheck="false" placeholder="Nom, identifiant, UPN, description… (vide\u00A0: tout le périmètre)" value="${esc(st.term)}"></label>
        <div class="sy-data-tools">
          <label class="sy-field-inline"><span>Trier par</span><span class="k-select sm"><select class="input" data-d="sort" aria-label="Trier toute la population par">${SORTS.map(([v, l]) => `<option value="${v}">${esc(l)}</option>`).join('')}</select></span></label>
          <button class="btn sm ghost sy-order" type="button" data-d="order" aria-pressed="false" data-tip="Ordre du tri">${glyph('sort')}<span>Croissant</span></button>
          <label class="sy-field-inline"><span>Par page</span><span class="k-select sm"><select class="input" data-d="limit" aria-label="Lignes par page">${SIZES.map((n) => `<option value="${n}"${n === 200 ? ' selected' : ''}>${n}</option>`).join('')}</select></span></label>
          ${button('Exporter CSV', { icon: 'csv', sm: true, data: { d: 'export' }, tip: 'Écrit toutes les lignes de la recherche (20 000 au plus) dans le dossier Exports' })}
        </div>
      </div>
      <p class="sy-data-status" aria-live="polite"><span class="sy-status-text">Lecture de la base locale…</span></p>
      <div class="sy-data-split"></div>
      <nav class="sy-pager" aria-label="Pages de résultats">
        ${button('Page précédente', { icon: 'chevronLeft', sm: true, ghost: true, data: { d: 'prev' }, disabled: true })}
        <span class="sy-pager-text" aria-live="polite">Page 1</span>
        <button class="btn sm ghost" type="button" data-d="next" disabled aria-disabled="true"><span>Page suivante</span>${glyph('chevronRight')}</button>
      </nav>
    </div>`;
  const status = panel.querySelector('.sy-status-text');
  const input = panel.querySelector('input[type="search"]');
  const gridHost = document.createElement('div');
  gridHost.className = 'sy-grid-host';
  const detail = document.createElement('div');
  detail.className = 'sy-detail';
  detail.innerHTML = detailMarkup(null);
  const split = createSplit(panel.querySelector('.sy-data-split'), { a: gridHost, b: detail, key: 'synchro.data', size: 380, min: 300, max: 640, label: 'Largeur de la fiche locale' });
  let kv = bindKv(detail, { key: 'synchro.data.kv' });

  const grid = createGrid(gridHost, {
    key: 'synchro.index',
    label: 'Objets de la base locale',
    rowId: (r) => r.guid,
    selection: 'single',
    quickFilter: false,
    loading: true,
    height: '600px',
    columns: COLUMNS,
    empty: { icon: 'search', title: 'Aucun objet', text: 'Aucun objet de la base locale ne correspond.' },
    onActivate: (row) => open(row),
    onActiveChange: (row) => showDetail(row),
    onSelectionChange: (rows) => showDetail(rows[0] ?? null),
    contextMenu: ({ row }) => [
      { label: 'Ouvrir la fiche', icon: 'object', kbd: 'Entrée', disabled: !row, reason: 'Aucune ligne.', run: () => open(row) },
      { label: 'Copier le DN', icon: 'copy', disabled: !row, reason: 'Aucune ligne.', run: () => copyDn(row) },
      { label: 'Copier le GUID', icon: 'copy', disabled: !row, reason: 'Aucune ligne.', run: () => row && writeClipboard(row.guid) },
    ],
  });

  function showDetail(row) {
    if (row && st.selected && row.guid === st.selected.guid) return;
    st.selected = row ?? null;
    kv.destroy();
    detail.innerHTML = detailMarkup(st.selected);
    kv = bindKv(detail, { key: 'synchro.data.kv' });
    paint(detail);
  }

  function open(row) {
    if (row?.dn) ctx.navigate('fiche', { dn: row.dn });
  }

  async function copyDn(row) {
    if (!row) return;
    await writeClipboard(row.dn);
    announce('DN copié.');
  }

  function pager(page) {
    const prev = panel.querySelector('[data-d="prev"]');
    const next = panel.querySelector('[data-d="next"]');
    const has = page && !page.busy;
    prev.disabled = !(has && page.offset > 0);
    next.disabled = !(has && page.hasMore);
    prev.setAttribute('aria-disabled', String(prev.disabled));
    next.setAttribute('aria-disabled', String(next.disabled));
    panel.querySelector('.sy-pager-text').textContent = has ? `Page ${int(page.page)} sur ${int(page.pages)} · ${count(page.total, 'objet', 'objets')} · ${page.sortLabel}` : 'Page —';
  }

  async function search({ reset = false } = {}) {
    if (reset) st.offset = 0;
    const my = ++st.seq;
    const started = performance.now();
    grid.setLoading(true);
    status.textContent = 'Recherche dans la base locale…';
    try {
      const page = await ctx.call('synchro.index.search', {
        text: st.term, ...screen.scopeArgs(), sort: st.sort, descending: st.descending, offset: st.offset, limit: st.limit,
      });
      if (my !== st.seq || !screen.alive()) return;
      if (page.busy) {
        // A locked base is not an empty result: one short retry, then a message (Domenia 1 point 4).
        if (st.attempt < 1) {
          st.attempt += 1;
          status.textContent = page.message;
          setTimeout(() => { if (my === st.seq) search(); }, RETRY_MS);
          return;
        }
        st.attempt = 0;
        grid.setError('Base locale occupée\u00A0: recherche non effectuée. Réessayez dans un instant.', { retry: () => search() });
        status.textContent = 'Base locale occupée\u00A0: recherche non effectuée.';
        pager(null);
        return;
      }
      st.attempt = 0;
      st.page = page;
      st.offset = page.offset;
      grid.setEmpty(page.total === 0 ? { icon: 'search', title: page.browse ? 'Périmètre vide' : 'Aucun objet', text: page.message } : null);
      grid.setRows(page.rows, { keepSelection: true });
      const ms = Math.round(performance.now() - started);
      status.innerHTML = `${esc(page.message)} <span class="sy-ms">${int(ms)}${NBSP}ms · ${esc(page.scope.label)}</span>`;
      pager(page);
      const wanted = ctx.params.objet;
      if (wanted && page.rows.some((r) => r.guid === wanted)) grid.select([wanted]);
      else if (!st.selected && page.rows[0]) grid.select([page.rows[0].guid], { scroll: false });
    } catch (err) {
      if (my !== st.seq) return;
      console.error(err);
      grid.setError(errorText(err), { retry: () => search() });
      status.textContent = `Recherche non effectuée${NBSP}: ${errorText(err)}`;
      pager(null);
    }
  }

  let timer = 0;
  const onInput = () => {
    st.seq += 1; // an older answer must not replace the list during the wait
    clearTimeout(timer);
    timer = setTimeout(() => {
      st.term = input.value.trim().slice(0, 100);
      if (st.term.length === 1) {
        grid.setRows([]);
        grid.setEmpty({ icon: 'search', title: 'Deux caractères au moins', text: 'Saisissez au moins deux caractères, ou laissez vide pour tous les objets du périmètre.' });
        status.textContent = 'Saisissez au moins deux caractères, ou laissez vide pour tous les objets du périmètre.';
        pager(null);
        return;
      }
      search({ reset: true });
    }, DEBOUNCE_MS);
  };
  input.addEventListener('input', onInput);
  input.addEventListener('keydown', (e) => { if (e.key === 'Enter') { clearTimeout(timer); st.term = input.value.trim(); search({ reset: true }); } });

  const onClick = async (e) => {
    const t = e.target instanceof Element ? e.target.closest('[data-d], [data-dt]') : null;
    if (!t || t.disabled) return;
    const act = t.dataset.d ?? t.dataset.dt;
    if (act === 'prev' && st.page) { st.offset = Math.max(0, st.page.offset - st.limit); search(); }
    else if (act === 'next' && st.page?.hasMore) { st.offset = st.page.offset + st.limit; search(); }
    else if (act === 'order') {
      st.descending = !st.descending;
      t.setAttribute('aria-pressed', String(st.descending));
      t.querySelector('span').textContent = st.descending ? 'Décroissant' : 'Croissant';
      search({ reset: true });
    } else if (act === 'export') exportCsv(t);
    else if (act === 'open') open(st.selected);
    else if (act === 'copy-dn') copyDn(st.selected);
  };
  panel.addEventListener('click', onClick);
  panel.querySelector('[data-d="sort"]').addEventListener('change', (e) => { st.sort = e.target.value; search({ reset: true }); });
  panel.querySelector('[data-d="limit"]').addEventListener('change', (e) => { st.limit = Number(e.target.value) || 200; search({ reset: true }); });

  async function exportCsv(btn) {
    btn.disabled = true;
    btn.setAttribute('aria-busy', 'true');
    try {
      const r = await ctx.call('synchro.index.export', { text: st.term, ...screen.scopeArgs(), sort: st.sort, descending: st.descending });
      ctx.toast(r.written ? `${count(r.rows, 'ligne exportée', 'lignes exportées')}${NBSP}: ${r.fileName}` : r.text, { tone: r.written ? 'ok' : 'info', life: 6000 });
    } catch (err) {
      console.error(err);
      ctx.toast(`Export non écrit${NBSP}: ${errorText(err)}`, { tone: 'alert' });
    } finally {
      btn.disabled = false;
      btn.removeAttribute('aria-busy');
    }
  }

  const offScope = screen.on('scope', () => search({ reset: true }));
  const offStored = screen.on('stored', () => search());
  search({ reset: true });

  return () => {
    clearTimeout(timer);
    offScope();
    offStored();
    panel.removeEventListener('click', onClick);
    kv.destroy();
    grid.destroy();
    split.destroy();
  };
}

void openMenu;
