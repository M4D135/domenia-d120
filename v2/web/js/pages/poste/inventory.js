// « Inventaire » of the workstation console: hardware and system (quick or full inventory, access report, categories,
// copy and export to two files named after the workstation; the last inventory shown again at once, from this session
// or from the local base), software (from the last inventory, then read on the workstation; synthesis with clickable
// charts; columns never read are not offered), services (read, filter, start / restart / stop through the write circuit
// from the bar of the selected service), processes (processor share measured between two reads) and Windows sessions
// (consultation only, card of the account). Every network read starts from a button.
import { createTabs, createGrid, writeClipboard, openMenu, confirmDialog } from '../../kit/index.js';
import { runWrite } from '../../write-flow.js';
import {
  esc, ico, rel, facts, cardHead, empty, failure, chip, meter, paintMeters, donut, paintDonuts, progressMarkup, setProgress,
  NBSP, int, count, size, pct, errorText, skLines, fitGrid, saveExport,
} from './common.js';
import { reveal as revealCards, toast, announce } from '../../ui.js';

const TABS = [
  { id: 'materiel', label: 'Matériel et système', icon: 'chip' },
  { id: 'logiciels', label: 'Logiciels', icon: 'layers' },
  { id: 'services', label: 'Services', icon: 'settings' },
  { id: 'processus', label: 'Processus', icon: 'activity' },
  { id: 'sessions', label: 'Sessions', icon: 'users' },
];

export function renderInventory(panel, state) {
  panel.classList.add('ps-inventory');
  panel.innerHTML = '<div class="ps-subtabs" data-slot="tabs"></div>';
  const renderers = { materiel: hardware, logiciels: software, services, processus: processes, sessions };
  const tabs = createTabs(panel.querySelector('[data-slot="tabs"]'), {
    label: 'Parties de l’inventaire',
    selected: state.initialTab && renderers[state.initialTab] ? state.initialTab : 'materiel',
    tabs: TABS.map((t) => ({ ...t, render: (host) => renderers[t.id](host, state) })),
  });
  const off = state.on('tab', ({ view, tab }) => { if (view === 'inventaire' && renderers[tab]) tabs.select(tab); });
  const offRun = state.on('run', (r) => { if (r.what === 'inventory') tabs.select('materiel'); });
  return () => { off(); offRun(); tabs.destroy(); };
}

/** Grants the single fallback read (CIM refused), after the operator confirms it; true when granted. */
async function grantFallback(state) {
  const ok = await confirmDialog({
    title: 'Autoriser une seule lecture de repli ?',
    message: `CIM refuse la lecture de ${state.data.computer.name}. Une seule lecture, sur ce poste seulement, pourra passer par une tâche planifiée unique, créée puis supprimée : elle laisse une trace sur le poste. Rien n’est lancé avant votre prochain geste.`,
    confirmLabel: 'Autoriser une lecture',
  });
  if (!ok) return false;
  try {
    const r = await state.call('poste.consent.grant', { dn: state.dn, kind: 'readFallback', minutes: 5 });
    state.data.consent = r.consent;
    state.emit('consent', r.consent);
    toast('Lecture de repli autorisée pour la prochaine lecture refusée par CIM (5 min).', { tone: 'info' });
    return true;
  } catch (err) {
    toast(errorText(err), { tone: 'alert' });
    return false;
  }
}

// ---------- Hardware and system ----------

function hardware(host, state) {
  let alive = true;
  let grid = null;
  let category = '';
  let result = null;
  let running = false;
  host.innerHTML = `<div class="grid ps-grid">
    <section class="card ps-card span-12 ps-inv-head reveal" data-slot="head"></section>
    <section class="card ps-card span-8 reveal" data-slot="rows">${cardHead('layers', 'Lignes de l’inventaire', 'Valeurs CIM traduites ; la valeur brute reste en info-bulle, à la copie et à l’export')}<div data-slot="grid"></div></section>
    <section class="card ps-card span-4 reveal" data-slot="access">${cardHead('shield', 'Détail par source', 'Chaque source rend son propre état : un refus n’empêche pas les autres')}<div data-slot="access-body"></div></section>
  </div>`;
  const head = host.querySelector('[data-slot="head"]');
  const paintHead = () => {
    const inv = state.data.inventory;
    const busy = running;
    const notice = result?.notice ? `<p class="ps-badge-line" data-tone="${result.partial ? 'info' : 'warn'}">${ico(result.partial ? 'info' : 'alert')}<span>${esc(result.notice)}</span>
      ${result.noticeAction === 'readFallback' ? `<button class="btn sm" type="button" data-act="fallback">${ico('shield')}Autoriser une lecture de repli…</button>` : ''}</p>` : '';
    head.innerHTML = `<div class="ps-inv-bar"><div class="ps-inv-title"><span class="ps-card-icon">${ico('layers')}</span>
        <div><h3>${esc(result ? result.modeLabel : inv ? inv.modeLabel : 'Aucun inventaire')}</h3>
        <p class="ps-card-sub">${result ? `${esc(result.summary)} · ${esc(result.origin)} · ${rel(result.collectedAt, 'lu ')}` : inv ? `${esc(inv.origin)} · ${rel(inv.at, 'lu ')}` : 'Rien n’est lu sans votre geste : rapide ≈ 1 min (55 s au plus), complet ≈ 3 min (150 s au plus).'}</p></div></div>
      <div class="ps-inv-actions">
        <button class="btn primary" type="button" data-act="quick"${busy ? ' disabled' : ''}>${ico('layers')}Inventaire rapide</button>
        <button class="btn" type="button" data-act="deep"${busy ? ' disabled' : ''} data-tip="Ajoute processus, événements système, tâches planifiées, certificats machine et connexions">${ico('layers')}Inventaire complet</button>
        <button class="btn ghost" type="button" data-act="stop"${busy ? '' : ' hidden'} data-tip="Arrête l’inventaire : les sources déjà lues sont gardées (résultat partiel)">${ico('pause')}Arrêter</button>
        <button class="btn ghost icon" type="button" data-act="more" aria-label="Copier ou exporter" data-tip="Copier ou exporter"${result ? '' : ' disabled'}>${ico('more')}</button>
      </div></div>
      ${notice}
      <div data-slot="progress"${busy ? '' : ' hidden'}>${progressMarkup()}</div>`;
  };
  const gridHost = host.querySelector('[data-slot="grid"]');
  const columnsFor = (r) => [
    { id: 'category', label: 'Catégorie', width: 160, type: 'enum', options: (r?.categories ?? []).map((c) => ({ value: c.name, label: c.name })) },
    { id: 'item', label: 'Élément', width: 220 },
    { id: 'label', label: 'Valeur', width: 380, html: (v, row) => `<span${row.value && row.value !== row.label ? ` data-tip="${esc(`Valeur brute : ${row.value}`)}"` : ''}>${esc(v)}</span>`, csv: (v, row) => (row.value && row.value !== row.label ? `${v} [${row.value}]` : v) },
    { id: 'value', label: 'Valeur brute', width: 220, mono: true, hidden: true },
  ];
  grid = createGrid(gridHost, {
    key: 'poste.inventaire',
    label: 'Lignes de l’inventaire',
    rowId: (r) => `${r.category}|${r.item}|${r.value}`,
    selection: 'multi',
    loading: true,
    columns: columnsFor(null),
    empty: { icon: 'layers', title: 'Aucune ligne', text: 'Lancez un inventaire rapide ou complet du poste.' },
  });
  const paintAccess = () => {
    const body = host.querySelector('[data-slot="access-body"]');
    if (!result) {
      body.innerHTML = empty({ icon: 'shield', title: 'Pas encore lu', text: 'Le détail par source apparaît avec un inventaire (OK, vide, partiel, refusé, injoignable, interrompu…).' });
      return;
    }
    const categories = result.categories;
    body.innerHTML = `<div class="ps-cats" role="group" aria-label="Filtrer par catégorie"><button class="chip${category ? '' : ' info'}" type="button" data-cat="" aria-pressed="${category ? 'false' : 'true'}">Toutes <b>${int(result.rows.length)}</b></button>
      ${categories.filter((c) => c.rows > 0).map((c) => `<button class="chip${category === c.name ? ' info' : ''}" type="button" data-cat="${esc(c.name)}" aria-pressed="${category === c.name ? 'true' : 'false'}">${esc(c.name)} <b>${int(c.rows)}</b></button>`).join('')}</div>
      <ul class="ps-access">${result.access.map((a) => `<li data-tone="${esc(a.tone)}"><span class="ps-dot" data-tone="${esc(a.tone)}" aria-hidden="true"></span><span class="ps-access-name">${esc(a.category)}</span>
        <span class="ps-access-state">${esc(a.statusLabel)}</span><span class="ps-access-meta">${esc(count(a.items, 'élément', 'éléments'))} · ${int(a.durationMs)}${NBSP}ms · ${esc(a.transport)}${a.detail ? ` · ${esc(a.detail)}` : ''}</span></li>`).join('')}</ul>`;
  };
  const show = () => {
    if (!result) return;
    const rows = category ? result.rows.filter((r) => r.category === category) : result.rows;
    grid.setColumns(columnsFor(result), { key: 'poste.inventaire' });
    grid.setRows(rows);
    fitGrid(grid, rows.length, { max: 560 });
    paintAccess();
  };
  async function run(deep) {
    if (running) return;
    running = true;
    paintHead();
    const progress = host.querySelector('[data-slot="progress"]');
    const stop = state.progress('poste.inventory', (p) => setProgress(progress, p));
    grid.setLoading(true);
    setTimeout(() => state.refreshRunning(), 120);
    try {
      result = await state.call('poste.inventory', { dn: state.dn, deep });
      if (!alive) return;
      category = '';
      running = false;
      paintHead();
      show();
      announce(`${result.modeLabel}${result.partial ? ' partiel' : ''}${NBSP}: ${count(result.rows.length, 'ligne', 'lignes')}.`);
      toast(`${result.modeLabel} de ${state.data.computer.name}${NBSP}: ${result.summary}`, { tone: result.partial || result.notice ? 'info' : 'ok' });
      state.reload();
    } catch (err) {
      console.error(err);
      if (!alive) return;
      running = false;
      paintHead();
      grid.setError(errorText(err), { retry: () => run(deep) });
      host.querySelector('[data-slot="access-body"]').innerHTML = failure(err, { retry: deep ? 'deep' : 'quick' });
    } finally {
      stop();
      state.refreshRunning();
    }
  }
  async function cached() {
    // The last inventory is shown again without any network read (Domenia 1 PST-029, PST-036): this session first, else the
    // last one validated in the local base, with its date and provenance.
    try {
      const r = await state.call('poste.inventory.cached', { dn: state.dn });
      if (!alive) return;
      if (r && !result) {
        result = r;
        paintHead();
        show();
        return;
      }
      if (!r) {
        grid.setRows([]);
        fitGrid(grid, 0);
        paintAccess();
      }
    } catch (err) {
      if (alive) grid.setError(errorText(err), { retry: cached });
    }
  }
  const exportRows = () => {
    const access = ['Catégorie;État;Éléments;Durée (ms);Transport;Détail', ...result.access.map((a) => [a.category, a.statusLabel, a.items, a.durationMs, a.transport, a.detail ?? '']
      .map((v) => { const t = String(v ?? ''); return /[;"\n]/.test(t) || /^[=+\-@]/.test(t) ? `"${t.replace(/^([=+\-@])/, "'$1").replace(/"/g, '""')}"` : t; }).join(';'))].join('\r\n');
    saveExport(state, 'inventaire', [{ part: 'lignes', csv: grid.toCsv({ scope: 'visible' }) }, { part: 'sources', csv: access }]);
  };
  paintHead();
  cached();
  const onClick = (e) => {
    const t = e.target instanceof Element ? e.target.closest('[data-act],[data-cat]') : null;
    if (!t || !host.contains(t) || t.disabled) return;
    if (t.dataset.cat !== undefined && !t.dataset.act) { category = t.dataset.cat; show(); return; }
    const act = t.dataset.act;
    if (act === 'quick') run(false);
    else if (act === 'deep') run(true);
    else if (act === 'retry') run(false);
    else if (act === 'stop') state.stop('inventory');
    else if (act === 'fallback') grantFallback(state).then((ok) => { if (ok && alive) run(result?.deep ?? false); });
    else if (act === 'more') {
      openMenu(t, [
        { label: 'Exporter (lignes et détail par source)', icon: 'csv', disabled: !result, reason: 'Aucun inventaire à exporter.', run: exportRows },
        { label: 'Copier le rapport texte', icon: 'copy', disabled: !result, reason: 'Aucun inventaire.', run: () => writeClipboard(result.report).then(() => toast('Rapport copié.', { tone: 'ok' })) },
        { label: 'Copier la sélection (tabulée)', icon: 'copy', run: () => writeClipboard(grid.toCsv({ scope: 'selected' })).then(() => toast('Sélection copiée.', { tone: 'ok' })) },
      ], { label: 'Copier ou exporter', placement: 'bottom-end' });
    }
  };
  host.addEventListener('click', onClick);
  const off = state.on('run', (r) => { if (r.what === 'inventory') run(r.deep); });
  if (state.essai === 'inventaire') run(false);
  revealCards(host);
  return () => { alive = false; off(); host.removeEventListener('click', onClick); grid?.destroy(); };
}

// ---------- Software ----------

/** Columns of the software list: those never read are not offered (Domenia 1 PST-043); technical ones behind « Colonnes ». */
function softwareColumns(c) {
  const read = c ?? { publisher: true, installDate: true, size: true, location: true, uninstall: true, source: true, profile: true };
  return [
    { id: 'name', label: 'Nom', required: true, width: 270 },
    { id: 'version', label: 'Version', width: 120, mono: true },
    read.publisher && { id: 'publisher', label: 'Éditeur', width: 180 },
    read.installDate && { id: 'installDate', label: 'Installé le', type: 'date', dateStyle: 'date', width: 120 },
    read.size && { id: 'sizeBytes', label: 'Taille', type: 'number', width: 100, format: (v) => (v == null ? '—' : size(v)) },
    { id: 'architecture', label: 'Architecture', type: 'enum', width: 130, options: [{ value: '64 bits', label: '64 bits' }, { value: '32 bits', label: '32 bits' }] },
    { id: 'scope', label: 'Portée', type: 'enum', width: 110, options: [{ value: 'Machine', label: 'Machine' }, { value: 'Utilisateur', label: 'Utilisateur' }, { value: 'Store', label: 'Store' }] },
    { id: 'familyLabel', label: 'Famille', width: 140 },
    read.location && { id: 'location', label: 'Emplacement', width: 260, mono: true, hidden: true },
    read.uninstall && { id: 'uninstall', label: 'Désinstallation', width: 240, mono: true, hidden: true },
    read.source && { id: 'source', label: 'Source', width: 140, hidden: true },
  ].filter(Boolean);
}

function software(host, state) {
  let alive = true;
  let result = null;
  let select = null;
  let scope = '';
  let view = 'liste';
  host.innerHTML = `<div class="grid ps-grid">
    <section class="card ps-card span-12 reveal" data-slot="head"></section>
    <div class="span-12 ps-soft-board" data-slot="board" hidden></div>
    <section class="card ps-card span-12 reveal" data-slot="list">${cardHead('layers', 'Logiciels', '<span data-slot="prov"></span>', `<span class="ps-chipfilter" data-slot="chip" hidden></span>
      <div class="segmented ps-seg" role="group" aria-label="Portée"><button type="button" data-scope="" aria-pressed="true">Toutes</button><button type="button" data-scope="Machine" aria-pressed="false">Machine</button><button type="button" data-scope="Utilisateur" aria-pressed="false">Utilisateur</button><button type="button" data-scope="Store" aria-pressed="false">Store</button></div>`)}
      <div data-slot="grid"></div><p class="ps-faint" data-slot="covered"></p></section>
  </div>`;
  const grid = createGrid(host.querySelector('[data-slot="grid"]'), {
    key: 'poste.logiciels',
    label: 'Logiciels du poste',
    rowId: (r) => r.id,
    selection: 'multi',
    loading: true,
    columns: softwareColumns(null),
    empty: { icon: 'layers', title: 'Aucun logiciel', text: 'Chargez les logiciels du poste (lecture réseau) : machine, profils ouverts, Store.' },
  });
  const paintHead = (busy = false) => {
    host.querySelector('[data-slot="head"]').innerHTML = `<div class="ps-inv-bar"><div class="ps-inv-title"><span class="ps-card-icon">${ico('layers')}</span>
      <div><h3>${result ? esc(result.origin) : 'Logiciels'}</h3><p class="ps-card-sub">${result ? esc(result.accessSummary) : 'Liste tirée de l’inventaire, puis lue sur le poste à la demande ; jamais Win32_Product.'}</p></div></div>
      <div class="ps-inv-actions"><label class="ps-check-opt"><input type="checkbox" data-opt="perUser"> Profils</label><label class="ps-check-opt"><input type="checkbox" data-opt="store"> Store</label>
        <label class="ps-check-opt"><input type="checkbox" data-opt="updates"> Mises à jour</label>
        <button class="btn primary" type="button" data-act="load"${busy ? ' disabled' : ''}>${ico('refresh')}Charger les logiciels</button>
        <div class="segmented ps-seg" role="group" aria-label="Affichage"><button type="button" data-view="liste" aria-pressed="${view === 'liste'}">Liste</button><button type="button" data-view="synthese" aria-pressed="${view === 'synthese'}">Synthèse</button></div>
        <button class="btn ghost icon" type="button" data-act="export" aria-label="Copier ou exporter" data-tip="Copier ou exporter la liste"${result ? '' : ' disabled'}>${ico('csv')}</button></div></div>
      ${busy ? progressMarkup() : ''}`;
  };
  const filterRows = () => (result?.rows ?? []).filter((r) => (!scope || r.scope === scope) && (!select || (select.field === 'publisher' ? (r.publisher ?? 'Éditeur non renseigné') === select.value : select.field === 'architecture' ? r.architecture === select.value : select.field === 'scope' ? r.scope === select.value : r.name === select.value)));
  const showRows = () => {
    const rows = filterRows();
    grid.setRows(rows, { keepSelection: true });
    fitGrid(grid, rows.length, { max: 540 });
  };
  const paint = () => {
    if (!result) return;
    host.querySelector('[data-slot="prov"]').textContent = result.provenance;
    host.querySelector('[data-slot="covered"]').textContent = result.notCovered ?? '';
    const chipHost = host.querySelector('[data-slot="chip"]');
    chipHost.hidden = !select;
    chipHost.innerHTML = select ? `<span class="chip info">${ico('filter')}Filtré${NBSP}: ${esc(select.label)}<button class="ps-chip-x" type="button" data-act="unselect" aria-label="Retirer le filtre du graphique">${ico('x')}</button></span>` : '';
    showRows();
    const boardHost = host.querySelector('[data-slot="board"]');
    boardHost.innerHTML = board(result);
    boardHost.hidden = view !== 'synthese';
    paintMeters(host);
    paintDonuts(host);
    revealCards(host);
  };
  /** A new result: the columns follow what was read (a list from the inventory never offers its unread columns). */
  const take = (r) => {
    result = r;
    const fromInventory = !r.complete;
    grid.setColumns(softwareColumns(r.columns), { key: fromInventory ? 'poste.logiciels.inventaire' : 'poste.logiciels' });
  };
  async function cached() {
    try {
      const r = await state.call('poste.software.cached', { dn: state.dn });
      if (!alive) return;
      take(r);
      paintHead();
      paint();
      if (!r.total) { grid.setRows([]); fitGrid(grid, 0); }
    } catch (err) {
      if (alive) grid.setError(errorText(err));
    }
  }
  async function load() {
    paintHead(true);
    grid.setLoading(true);
    const opts = Object.fromEntries([...host.querySelectorAll('[data-opt]')].map((i) => [i.dataset.opt, i.checked]));
    try {
      const r = await state.call('poste.software', { dn: state.dn, perUser: opts.perUser, store: opts.store, updates: opts.updates });
      if (!alive) return;
      select = null;
      take(r);
      paintHead();
      paint();
      announce(`${count(r.total, 'logiciel lu', 'logiciels lus')}.`);
    } catch (err) {
      if (!alive) return;
      paintHead();
      if (err?.code === 'poste.cimRefused') {
        grid.setError(errorText(err), { retry: async () => { if (await grantFallback(state)) load(); } });
      } else {
        grid.setError(errorText(err), { retry: load });
      }
    }
  }
  paintHead();
  cached();
  host.addEventListener('click', (e) => {
    const t = e.target instanceof Element ? e.target.closest('[data-act],[data-scope],[data-view],[data-part]') : null;
    if (!t || !host.contains(t) || t.disabled) return;
    if (t.dataset.scope !== undefined) {
      scope = t.dataset.scope;
      t.parentElement.querySelectorAll('button').forEach((b) => b.setAttribute('aria-pressed', String(b === t)));
      showRows();
      return;
    }
    if (t.dataset.view) { view = t.dataset.view; paintHead(); paint(); return; }
    if (t.dataset.part) {
      const [field, value, label] = t.dataset.part.split('|');
      select = select && select.field === field && select.value === value ? null : { field, value, label };
      paint();
      return;
    }
    const act = t.dataset.act;
    if (act === 'load') load();
    else if (act === 'unselect') { select = null; paint(); }
    else if (act === 'export') {
      // The file is named after its provenance: the last inventory or a reading of the workstation (Domenia 1 PST-047).
      const kind = result?.complete ? 'logiciels' : 'logiciels-inventaire';
      openMenu(t, [
        { label: 'Exporter la liste visible (CSV)', icon: 'csv', run: () => saveExport(state, kind, [{ part: 'liste', csv: grid.toCsv({ scope: 'visible' }) }]) },
        { label: 'Copier la liste visible', icon: 'copy', run: () => writeClipboard(grid.toCsv({ scope: 'visible' })).then(() => toast('Liste copiée.', { tone: 'ok' })) },
      ], { label: 'Exporter', placement: 'bottom-end' });
    }
  });
  if (state.essai === 'logiciels') load();
  return () => { alive = false; grid.destroy(); };
}

function board(r) {
  const b = r.board;
  const tiles = b.tiles.map((t) => `<div class="card ps-soft-tile reveal" data-tone="${esc(t.state ?? '')}"${t.empty ? ' data-empty="1"' : ''}><span>${esc(t.label)}</span><b>${esc(t.value)}</b><small>${esc(t.detail)}</small></div>`).join('');
  const ring = (title, parts) => {
    const clickable = parts.filter((p) => p.count > 0);
    return `<section class="card ps-card reveal"><h4 class="ps-mini-title">${esc(title)}</h4><div class="ps-soft-ring">${donut(clickable.map((p) => ({ value: p.count, tone: p.clickable ? '' : 'off' })), { label: title, center: `<b>${int(clickable.reduce((s, p) => s + p.count, 0))}</b>` })}
      <ul class="ps-legend">${clickable.map((p, n) => `<li>${p.clickable ? `<button class="ps-part" type="button" data-part="${esc(p.field)}|${esc(p.value)}|${esc(p.label)}" data-c="${n % 8}">` : `<span class="ps-part off" data-c="off">`}<span class="ps-dot" data-c="${p.clickable ? n % 8 : 'off'}" aria-hidden="true"></span><span>${esc(p.label)}</span><b>${int(p.count)}</b>${p.clickable ? '</button>' : '</span>'}</li>`).join('')}</ul></div></section>`;
  };
  const max = Math.max(1, ...b.largest.map((p) => p.bytes ?? 0));
  return `<div class="ps-soft-tiles">${tiles}</div>
    <div class="ps-soft-charts">${ring('Éditeurs', b.publishers)}${ring('Architecture', b.architectures)}${ring('Portée', b.scopes)}
      <section class="card ps-card reveal"><h4 class="ps-mini-title">Les plus gros</h4><ul class="ps-bars">${b.largest.map((p) => `<li><button class="ps-part bar" type="button" data-part="${esc(p.field)}|${esc(p.value)}|${esc(p.label)}"><span class="ps-bar-name">${esc(p.label)}</span>${meter((p.bytes ?? 0) / max, 'accent')}<span class="ps-bar-val">${esc(size(p.bytes))}</span></button></li>`).join('')}</ul></section></div>`;
}

// ---------- Services ----------

function services(host, state) {
  let alive = true;
  let result = null;
  let onlyStopped = false;
  let text = '';
  let current = null;
  host.innerHTML = `<div class="grid ps-grid">
    <section class="card ps-card span-12 reveal">
      ${cardHead('settings', 'Services du poste', '<span data-slot="summary">Win32_Service lu au clic, en lecture seule, 500 instances au plus.</span>', `<button class="btn primary" type="button" data-act="read">${ico('refresh')}Lire les services</button>`)}
      <div class="ps-svc-bar" data-slot="bar">
        <label class="ps-search sm"><span class="visually-hidden">Filtrer les services</span>${ico('filter')}<input class="input" type="search" data-filter placeholder="Nom ou libellé du service…" autocomplete="off"></label>
        <label class="ps-check-opt"><input type="checkbox" data-opt="stopped"> Automatiques arrêtés seulement</label>
        <div class="ps-svc-actions" role="toolbar" aria-label="Actions sur le service choisi">
          <span class="ps-svc-current" data-slot="current">Choisissez un service dans la liste</span>
          <button class="btn sm is-write" type="button" data-svc="start" disabled>${ico('play')}Démarrer…</button>
          <button class="btn sm is-write" type="button" data-svc="restart" disabled>${ico('refresh')}Redémarrer…</button>
          <button class="btn sm danger is-write" type="button" data-svc="stop" disabled>${ico('power')}Arrêter…</button>
        </div>
      </div>
      <div data-slot="grid"></div></section>
    <section class="card ps-card span-12 reveal" data-slot="profile" hidden></section>
  </div>`;
  const grid = createGrid(host.querySelector('[data-slot="grid"]'), {
    key: 'poste.services',
    label: 'Services',
    rowId: (r) => r.name,
    selection: 'single',
    columns: [
      { id: 'displayName', label: 'Service', required: true, width: 320 },
      { id: 'name', label: 'Nom court', width: 160, mono: true },
      { id: 'stateLabel', label: 'État', type: 'enum', width: 120, get: (r) => r.state, options: [{ value: 'Running', label: 'En cours', tone: 'ok' }, { value: 'Stopped', label: 'Arrêté', tone: 'off' }] },
      { id: 'startLabel', label: 'Démarrage', width: 190 },
      { id: 'flag', label: 'Constat', type: 'enum', width: 190, get: (r) => (r.autoStopped ? 'fault' : r.stopExpected ? 'expected' : r.inProfile ? 'profile' : ''), options: [
        { value: 'fault', label: 'Automatique arrêté', tone: 'warn' }, { value: 'expected', label: 'Arrêt attendu', tone: 'info' }, { value: 'profile', label: 'Profil attendu', tone: 'ok' }] },
      { id: 'processId', label: 'PID', type: 'number', width: 90 },
      { id: 'account', label: 'Compte', width: 220, hidden: true },
      { id: 'dependsOn', label: 'Dépend de', width: 200, get: (r) => r.dependenciesRead === false ? `${r.dependsOn.join(', ')}${r.dependsOn.length ? ' · ' : ''}Lecture incomplète` : r.dependsOn.join(', ') || 'Aucune dépendance', hidden: true },
      { id: 'dependents', label: 'Dépendants', width: 200, get: (r) => r.dependentsComplete === false ? `${r.dependents.join(', ')}${r.dependents.length ? ' · ' : ''}Liste incomplète` : r.dependents.join(', ') || 'Aucun dépendant', hidden: true },
    ],
    empty: { icon: 'settings', title: 'Services non lus', text: 'Cliquez sur « Lire les services » : une lecture CIM du poste, en lecture seule.' },
    contextMenu: ({ row }) => actions(row),
    onSelectionChange: (rows) => { current = rows[0] ?? null; paintActions(); },
    onActivate: (row) => { current = row; paintActions(); host.querySelector('[data-svc]:not([disabled])')?.focus(); },
  });
  function actions(row) {
    if (!row) return [];
    return [
      { heading: row.displayName },
      { label: 'Démarrer…', icon: 'play', kind: 'write', disabled: !row.canStart, reason: row.startMode === 'Disabled' ? 'Service désactivé : Domenia ne change pas son type de démarrage.' : 'Le service n’est pas arrêté.', run: () => write(row, 'start') },
      { label: 'Redémarrer…', icon: 'refresh', kind: 'write', danger: true, disabled: !row.canRestart, reason: 'Le service n’est pas en cours.', run: () => write(row, 'restart') },
      { label: 'Arrêter…', icon: 'power', kind: 'write', danger: true, disabled: !row.canStop, reason: 'Le service n’est pas en cours.', run: () => write(row, 'stop') },
      '-',
      { label: 'Copier le nom court', icon: 'copy', run: () => writeClipboard(row.name) },
    ];
  }
  /** The bar of the selected service (Domenia 1 BtnCompServiceStart, BtnCompServiceRestart): what is possible, and why not. */
  function paintActions() {
    const label = host.querySelector('[data-slot="current"]');
    const set = (id, on, reason) => {
      const b = host.querySelector(`[data-svc="${id}"]`);
      if (!b) return;
      b.disabled = !on;
      if (on) b.removeAttribute('data-tip'); else b.dataset.tip = reason;
    };
    if (!current) {
      label.textContent = 'Choisissez un service dans la liste';
      ['start', 'restart', 'stop'].forEach((id) => set(id, false, 'Choisissez d’abord un service.'));
      return;
    }
    label.textContent = `${current.displayName} · ${current.stateLabel}`;
    set('start', current.canStart, current.startMode === 'Disabled' ? 'Service désactivé : Domenia ne change pas son type de démarrage.' : 'Le service n’est pas arrêté.');
    set('restart', current.canRestart, 'Le service n’est pas en cours.');
    set('stop', current.canStop, 'Le service n’est pas en cours.');
  }
  function write(row, action) {
    runWrite(state.ctx, { plan: 'poste.service.plan', args: { dn: state.dn, name: row.name, action }, subtitle: `${state.data.computer.name} · ${row.displayName}`, onDone: () => read() });
  }
  const apply = () => {
    const needle = text.toLowerCase();
    const rows = (result?.rows ?? []).filter((r) => (!onlyStopped || r.autoStopped) && (!needle || r.name.toLowerCase().includes(needle) || r.displayName.toLowerCase().includes(needle)));
    grid.setRows(rows, { keepSelection: true });
    fitGrid(grid, rows.length, { max: 520 });
    current = grid.getSelection()[0] ?? null;
    paintActions();
  };
  async function read() {
    grid.setLoading(true);
    try {
      result = await state.call('poste.services', { dn: state.dn });
      if (!alive) return;
      host.querySelector('[data-slot="summary"]').textContent = result.summary;
      apply();
      const profile = host.querySelector('[data-slot="profile"]');
      profile.hidden = false;
      profile.innerHTML = `${cardHead('shield', 'Profil attendu d’un poste du domaine', '15 services ; un écart est une piste, aucun service n’est modifié')}
        <ul class="ps-profile">${result.profile.map((p) => `<li data-tone="${esc(p.tone)}"><span class="ps-dot" data-tone="${esc(p.tone)}" aria-hidden="true"></span><b class="mono">${esc(p.name)}</b><span>${esc(p.reason)}</span><span class="ps-profile-state">${esc(p.text)}</span></li>`).join('')}</ul>`;
      revealCards(host);
    } catch (err) {
      if (alive) grid.setError(errorText(err), { retry: read });
    }
  }
  host.addEventListener('click', (e) => {
    const t = e.target instanceof Element ? e.target.closest('[data-act],[data-svc]') : null;
    if (!t || t.disabled) return;
    if (t.dataset.act === 'read') read();
    else if (t.dataset.svc && current) write(current, t.dataset.svc);
  });
  host.querySelector('[data-opt="stopped"]').addEventListener('change', (e) => { onlyStopped = e.target.checked; apply(); });
  host.querySelector('[data-filter]').addEventListener('input', (e) => { text = e.target.value.trim(); apply(); });
  fitGrid(grid, 0);
  if (state.essai === 'services') read();
  return () => { alive = false; grid.destroy(); };
}

// ---------- Processes ----------

function processes(host, state) {
  let alive = true;
  host.innerHTML = `<div class="grid ps-grid">
    <section class="card ps-card span-12 reveal">${cardHead('activity', 'Processus', '<span data-slot="summary">Deux lectures espacées : la part du processeur se mesure, jamais d’une photographie unique.</span>', `<button class="btn primary" type="button" data-act="read">${ico('refresh')}Mesurer les processus</button>`)}
      <div class="ps-proc-top" data-slot="top"></div><div data-slot="grid"></div></section></div>`;
  const grid = createGrid(host.querySelector('[data-slot="grid"]'), {
    key: 'poste.processus',
    label: 'Processus',
    rowId: (r) => String(r.id),
    columns: [
      { id: 'name', label: 'Processus', width: 260, required: true },
      { id: 'cpuPercent', label: 'Processeur', type: 'number', width: 160, html: (v) => (v == null ? '<span class="ps-faint">non mesuré</span>' : `${meter(v / 100, v >= 50 ? 'warn' : 'accent')}<span class="ps-num">${esc(pct(v, 1))}</span>`), csv: (v) => (v == null ? '' : String(v)) },
      { id: 'workingSetBytes', label: 'Mémoire', type: 'number', width: 130, format: (v) => size(v) },
      { id: 'id', label: 'PID', type: 'number', width: 90 },
      { id: 'user', label: 'Compte', width: 170 },
      { id: 'startedAt', label: 'Démarré', type: 'date', width: 150 },
      { id: 'note', label: 'Note', width: 280, hidden: true },
    ],
    empty: { icon: 'activity', title: 'Processus non mesurés', text: 'Cliquez sur « Mesurer les processus » : deux lectures de Win32_Process à 1,5 s d’intervalle.' },
  });
  fitGrid(grid, 0);
  async function read() {
    grid.setLoading(true);
    try {
      const r = await state.call('poste.processes', { dn: state.dn });
      if (!alive) return;
      host.querySelector('[data-slot="summary"]').textContent = r.summary;
      host.querySelector('[data-slot="top"]').innerHTML = facts(r.facts, { compact: true });
      grid.setRows(r.rows);
      fitGrid(grid, r.rows.length, { max: 520 });
      requestAnimationFrame(() => paintMeters(host));
    } catch (err) {
      if (alive) grid.setError(errorText(err), { retry: read });
    }
  }
  host.addEventListener('click', (e) => { if (e.target instanceof Element && e.target.closest('[data-act="read"]')) read(); });
  if (state.essai === 'processus') read();
  return () => { alive = false; grid.destroy(); };
}

// ---------- Sessions ----------

function sessions(host, state) {
  let alive = true;
  host.innerHTML = `<div class="grid ps-grid">
    <section class="card ps-card span-12 reveal">${cardHead('users', 'Sessions Windows', '<span data-slot="summary">Lecture à la demande par l’API WTS ; consultation seule (aucune déconnexion).</span>', `<button class="btn primary" type="button" data-act="read">${ico('refresh')}Lire les sessions</button>`)}
      <p class="ps-badge-line" data-slot="empty" data-tone="info" hidden></p><div data-slot="grid"></div></section></div>`;
  const grid = createGrid(host.querySelector('[data-slot="grid"]'), {
    key: 'poste.sessions',
    label: 'Sessions',
    rowId: (r) => r.session,
    selection: 'single',
    columns: [
      { id: 'session', label: 'Session', width: 130 },
      { id: 'user', label: 'Utilisateur', width: 230, required: true },
      { id: 'protocol', label: 'Protocole', type: 'enum', width: 130, options: [{ value: 'Console', label: 'Console' }, { value: 'RDP', label: 'RDP' }] },
      { id: 'state', label: 'État', width: 130 },
      { id: 'opened', label: 'Ouverte à', width: 130 },
      { id: 'idle', label: 'Inactive depuis', width: 160 },
      { id: 'clientName', label: 'Client', width: 150 },
    ],
    empty: { icon: 'users', title: 'Sessions non lues', text: 'Une console vide ne prouve jamais l’absence de session RDP.' },
    onActivate: (row) => openAccount(row),
    contextMenu: ({ row }) => [{ label: 'Ouvrir la fiche du compte', icon: 'user', disabled: !row?.login, reason: 'Ligne sans compte : aucune recherche lancée.', run: () => openAccount(row) }],
  });
  fitGrid(grid, 0);
  /** The account of a session by its sAMAccountName, domain removed (Domenia 1 Open-DomeniaSessionFiche), then its card. */
  async function openAccount(row) {
    if (!row?.login) { toast('Ligne sans compte : aucune recherche lancée.', { tone: 'info' }); return; }
    try {
      const user = await state.call('poste.account.find', { login: row.login });
      if (user?.dn) state.ctx.navigate('fiche', { dn: user.dn });
      else toast(`Aucun compte ${row.login} dans l’annuaire connu${NBSP}: la session peut être un compte local du poste.`, { tone: 'info' });
    } catch (err) {
      toast(errorText(err), { tone: 'warn' });
    }
  }
  async function read() {
    grid.setLoading(true);
    try {
      const r = await state.call('poste.sessions', { dn: state.dn });
      if (!alive) return;
      host.querySelector('[data-slot="summary"]').textContent = r.statusText;
      const e = host.querySelector('[data-slot="empty"]');
      e.hidden = !r.emptyText;
      e.innerHTML = r.emptyText ? `${ico('info')}<span>${esc(r.emptyText)}</span>` : '';
      grid.setRows(r.rows);
      fitGrid(grid, r.rows.length, { max: 420 });
    } catch (err) {
      if (alive) grid.setError(errorText(err), { retry: read });
    }
  }
  host.addEventListener('click', (e) => { if (e.target instanceof Element && e.target.closest('[data-act="read"]')) read(); });
  if (state.essai === 'sessions') read();
  return () => { alive = false; grid.destroy(); };
}

export { chip, skLines };
