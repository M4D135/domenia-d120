// « 2. Aperçu »: evaluation of the draft on the local data of the scope, frozen with its definition (requetes.preview).
// Counters, verdict facets (opened on the matching objects, as Domenia 1), a text search on the name and the DN done by the
// engine on the whole frozen population, a virtualized grid loaded entirely (local data: exact sorts and filters), the
// queried values right after the verdict, object detail (« Pourquoi ce résultat ? » and local fiche), distribution,
// coverage, collection of the missing measures, exports prepared by the engine and the selection for Recherche.
import {
  esc, glyph, plural, num, key, VERDICTS, verdictPill, emptyState, skLines, vars, dateText, ago, NBSP, pct, nounOf,
} from './shared.js';
import { openCoverage, openPlan, openExport, openGroups } from './drawers.js';
import {
  createGrid, createFilterBar, createSplit, createTabs, createCommandBar, confirmDialog, writeClipboard, debounce,
} from '../../kit/index.js';
import { countUp, donut, applyVars, reveal, formatNumber, announce } from '../../ui.js';

const KPIS = [
  { id: 'match', label: 'Correspondants', icon: 'check', tone: 'ok', tip: 'La condition est vraie pour ces objets.' },
  { id: 'unknown', label: 'Inconnus', icon: 'info', tone: 'warn', tip: 'Une information manque, a expiré ou n’est pas exploitable : jamais compté comme faux.' },
  { id: 'noMatch', label: 'Non correspondants', icon: 'x', tone: 'off', tip: 'La condition est fausse pour ces objets.' },
  { id: 'population', label: 'Population', icon: 'layers', tone: 'info', tip: 'Objets évalués après le segment, sur les objets recensés du périmètre.' },
];

/** Rows kept in the page at most: beyond, the grid says the list is partial (the base itself stays under 20 000 objects). */
const MAX_ROWS = 50000;
const PAGE = 5000;

export function mountPreview(panel, store, api) {
  const st = {
    evaluation: null, verdict: 'match', state: 'all', text: '', grid: null, split: null, bar: null, detailTabs: null, active: null, loadingPage: 0, rows: [], total: 0,
    loadingAll: false, detailToken: 0, cmdbar: null,
  };
  panel.innerHTML = `<div class="rq-preview">
    <div class="rq-pv-empty"></div>
    <div class="rq-pv-body" hidden>
      <div class="rq-pv-hero card spot reveal">
        <div class="rq-pv-ring"></div>
        <div class="rq-pv-main">
          <div class="rq-pv-title"><h2 class="rq-pv-name"></h2><span class="rq-pv-fresh"></span></div>
          <p class="rq-pv-pop"></p>
          <div class="rq-pv-stale" hidden role="status">${glyph('alert')}<span>Les données ou le brouillon ont changé depuis cet aperçu.</span><button type="button" class="btn xs primary rq-rerun">${glyph('refresh')}Relancer l’aperçu</button></div>
          <div class="rq-pv-cmds"></div>
        </div>
      </div>
      <div class="rq-kpis"></div>
      <section class="card rq-results spot reveal" aria-labelledby="rq-res-title">
        <div class="card-head"><span class="card-icon">${glyph('rows')}</span><div class="rq-head-titles"><h3 id="rq-res-title">Résultats</h3><p class="rq-sub rq-res-sub"></p></div>
          <span class="meta"><button type="button" class="btn xs ghost rq-fold-detail" aria-pressed="false">${glyph('columns')}<span>Masquer le détail</span></button></span></div>
        <div class="rq-res-tools">
          <label class="rq-search rq-res-search">${glyph('search')}<input type="search" class="input sm" maxlength="256" autocomplete="off" spellcheck="false"
            placeholder="Nom ou chemin AD…" aria-label="Chercher par nom ou chemin AD dans tout l’aperçu"></label>
          <div class="rq-res-filters"></div>
        </div>
        <div class="rq-res-split"></div>
      </section>
      <div class="grid rq-pv-lower">
        <section class="card span-7 rq-groups spot reveal" aria-labelledby="rq-grp-title">
          <div class="card-head"><span class="card-icon">${glyph('columns')}</span><div class="rq-head-titles"><h3 id="rq-grp-title">Répartition</h3><p class="rq-sub rq-grp-sub"></p></div>
            <span class="meta"><button type="button" class="btn xs subtle rq-all-groups">${glyph('external')}Toute la répartition…</button></span></div>
          <div class="rq-groups-body"></div>
        </section>
        <section class="card span-5 rq-ldap-mini spot reveal" aria-labelledby="rq-lm-title">
          <div class="card-head"><span class="card-icon">${glyph('hash')}</span><div class="rq-head-titles"><h3 id="rq-lm-title">Définition évaluée</h3><p class="rq-sub">Figée au moment du calcul.</p></div></div>
          <code class="rq-mono rq-lm-filter"></code>
          <ul class="rq-lm-local"></ul>
          <div class="rq-lm-actions"><button type="button" class="btn xs subtle rq-coverage">${glyph('gauge')}Couverture et dates…</button>
            <button type="button" class="btn xs subtle rq-plan">${glyph('wifi')}Collecter les données manquantes…</button></div>
        </section>
      </div>
    </div>
  </div>`;
  const $ = (sel) => panel.querySelector(sel);
  let stopReveal = () => {};

  function renderEmpty(state = 'idle', message = '') {
    $('.rq-pv-body').hidden = true;
    const host = $('.rq-pv-empty');
    host.hidden = false;
    if (state === 'loading') {
      host.innerHTML = `<div class="rq-pv-loading" aria-busy="true"><div class="rq-orbit" aria-hidden="true"><span></span><span></span><span></span></div>
        <p>Évaluation locale de la requête sur le périmètre…</p>${skLines(70, 90, 80)}</div>`;
      return;
    }
    host.innerHTML = emptyState(state === 'error' ? 'alert' : 'play', state === 'error' ? 'Aperçu impossible' : 'Aucun aperçu calculé',
      message || 'L’aperçu évalue la requête sur les données locales du périmètre : aucune lecture réseau, aucun poste contacté.',
      `<button type="button" class="btn primary rq-run">${glyph('play')}Calculer l’aperçu local</button>`);
    host.querySelector('.rq-run').addEventListener('click', () => api.runPreview());
  }

  function kpiTile(k, value, total, n) {
    const share = k.id === 'population' ? null : pct(value, total);
    return `<article class="card rq-kpi kpi spot tilt reveal" data-kpi="${k.id}" data-tone="${k.tone}" data-i="${n}" data-tip="${esc(k.tip)}">
      <div class="label"><span class="card-icon">${glyph(k.icon)}</span>${esc(k.label)}</div>
      <div class="value"><span class="rq-count" data-to="${value}">0</span>${share !== null ? `<small>${formatNumber(share, 1)}${NBSP}%</small>` : ''}</div>
      <div class="foot">${k.id === 'population' ? `sur ${plural(total, 'objet recensé', 'objets recensés')}` : `<span class="rq-kpi-bar"><span data-w="${share}"></span></span>`}</div>
      ${k.id !== 'population' ? `<button type="button" class="rq-kpi-go" data-verdict="${k.id}" aria-label="Afficher les ${esc(k.label.toLowerCase())}"></button>` : ''}
    </article>`;
  }

  function render(evaluation) {
    st.evaluation = evaluation;
    st.verdict = evaluation.verdict ?? 'all';
    st.state = 'all';
    st.text = '';
    $('.rq-res-search input').value = '';
    const host = $('.rq-pv-empty');
    host.hidden = true;
    host.replaceChildren();
    const body = $('.rq-pv-body');
    body.hidden = false;
    body.querySelectorAll('.revealed').forEach((el) => el.classList.add('reveal'));
    const c = evaluation.counts;
    const [one, many] = nounOf(evaluation.population.target);
    $('.rq-pv-name').textContent = evaluation.population.recipeName;
    $('.rq-pv-fresh').innerHTML = `<span class="k-pill info sm">${glyph('clock')}Calculé ${esc(ago(evaluation.evaluatedAt))}</span><span class="k-pill off sm rq-mono">${esc(evaluation.fingerprint.slice(0, 12))}</span>`;
    $('.rq-pv-pop').textContent = evaluation.population.text;
    $('.rq-pv-stale').hidden = true;
    // The centre says the count and its base in two short lines: never a word wider than the ring.
    $('.rq-pv-ring').innerHTML = donut([
      { value: c.matched, tone: 'ok', key: 'match' },
      { value: c.unknown, tone: 'warn', key: 'unknown' },
      { value: c.noMatch, tone: 'off', key: 'noMatch' },
    ], { center: `<b class="rq-count" data-to="${c.matched}">0</b><span>sur ${esc(formatNumber(c.population))}</span>`, label: evaluation.summary });
    $('.rq-kpis').innerHTML = KPIS.map((k, n) => kpiTile(k, k.id === 'match' ? c.matched : k.id === 'unknown' ? c.unknown : k.id === 'noMatch' ? c.noMatch : c.population,
      k.id === 'population' ? c.total : c.population, n)).join('');
    applyVars(body);
    vars(body);
    body.querySelectorAll('.rq-count').forEach((el, n) => countUp(el, Number(el.dataset.to), { delay: n * 60 }));
    $('.rq-res-sub').textContent = `${plural(c.population, one, many)} · ${evaluation.summary}`;
    renderCommands();
    renderFilters();
    renderGrid(evaluation.rows, evaluation.hasMore, evaluation.pageTotal ?? evaluation.rows.length);
    renderGroups();
    renderDefinition();
    stopReveal();
    stopReveal = reveal(body);
    announce(`Aperçu calculé : ${evaluation.summary}.`);
  }

  function renderCommands() {
    const ev = st.evaluation;
    const computer = key(ev.population.target) === 'computer';
    st.cmdbar?.destroy();
    st.cmdbar = createCommandBar($('.rq-pv-cmds'), {
      label: 'Actions de l’aperçu',
      size: 'sm',
      items: [
        { id: 'rerun', label: 'Relancer l’aperçu', icon: 'refresh', run: () => api.runPreview() },
        { id: 'export', label: 'Exporter', icon: 'download', items: [
          { label: 'Correspondants (CSV)', icon: 'csv', run: () => exportRows('match', 'csv') },
          { label: 'Inconnus (CSV)', icon: 'csv', run: () => exportRows('unknown', 'csv') },
          { label: 'Non correspondants (CSV)', icon: 'csv', run: () => exportRows('noMatch', 'csv') },
          { label: 'Tous les objets (CSV)', icon: 'csv', run: () => exportRows('all', 'csv') },
          '-',
          { label: 'Correspondants (JSON, relisible par le script PowerShell)', icon: 'file', run: () => exportRows('match', 'json') },
          { label: 'Tous les objets (JSON)', icon: 'file', run: () => exportRows('all', 'json') },
        ] },
        { id: 'search', label: 'Appliquer aux résultats de Recherche', icon: 'search', run: applySearch },
        { id: 'collect', label: 'Collecter les données manquantes…', icon: 'wifi', kind: 'network', disabled: !computer, reason: 'Seulement pour les postes : les comptes et groupes viennent de l’annuaire.', run: plan },
        { id: 'coverage', label: 'Couverture et dates…', icon: 'gauge', run: coverage },
        { id: 'save', label: 'Enregistrer ou réutiliser', icon: 'star', run: () => api.goto('enregistrer') },
      ],
    });
  }

  function renderFilters() {
    const c = st.evaluation.counts;
    st.bar?.destroy?.();
    st.bar = createFilterBar($('.rq-res-filters'), {
      label: 'Filtres d’affichage des résultats',
      facets: [
        { id: 'match', label: 'Correspondants', count: c.matched, tone: 'ok', pressed: st.verdict === 'match' },
        { id: 'unknown', label: 'Inconnus', count: c.unknown, tone: 'warn', pressed: st.verdict === 'unknown' },
        { id: 'noMatch', label: 'Non correspondants', count: c.noMatch, tone: 'off', pressed: st.verdict === 'noMatch' },
        ...(key(st.evaluation.population.target) === 'group' ? [] : [
          { id: 'active', label: 'Actifs', pressed: st.state === 'active' },
          { id: 'disabled', label: 'Désactivés', pressed: st.state === 'disabled' },
        ]),
      ],
      chips: [{ id: 'scope', label: 'Périmètre', value: st.evaluation.population.scopeLabel, scope: 'Base locale', removable: false, icon: 'ou' }],
      summary: '',
      onToggle: (id, pressed) => {
        if (['match', 'unknown', 'noMatch'].includes(id)) st.verdict = pressed ? id : 'all';
        else st.state = pressed ? id : 'all';
        renderFilters();
        loadPage();
      },
    });
  }

  /** Cell of a queried information: highlighted, the value that decides the verdict. */
  const asked = (text) => `<span class="rq-asked">${esc(text)}</span>`;

  function columnsOf(ev) {
    const computer = key(ev.population.target) === 'computer';
    const cols = [
      { id: 'name', label: 'Nom', required: true, width: 200, get: (r) => r.name },
      { id: 'verdict', label: 'Verdict', type: 'enum', width: 158, get: (r) => r.verdict,
        options: [{ value: 'match', label: 'Correspond', tone: 'ok' }, { value: 'unknown', label: 'Inconnu', tone: 'warn' }, { value: 'noMatch', label: 'Ne correspond pas', tone: 'off' }] },
    ];
    // Headers are uppercase captions: the width follows the label so it reads whole (the grid scrolls sideways if needed).
    const wide = (label, min = 132) => Math.round(Math.max(min, Math.min(280, 64 + label.length * 8.2)));
    // The informations the recipe asks for come right after the verdict (the engine orders them by the conditions).
    for (const c of ev.columns.filter((x) => x.requested)) {
      if (c.kind === 'number') {
        cols.push({ id: c.id, label: c.label, type: 'number', width: wide(c.label), tip: `${c.label} : information interrogée par la requête`,
          get: (r) => (Number.isFinite(r.raw?.[c.id]) ? r.raw[c.id] : null), format: (v, r) => r.values?.[c.id] ?? '—', html: (v, r) => (r.values?.[c.id] ? asked(r.values[c.id]) : '—') });
      } else {
        cols.push({ id: c.id, label: c.label, width: wide(c.label), tip: `${c.label} : information interrogée par la requête`,
          get: (r) => r.values?.[c.id] ?? null, html: (v) => (v ? asked(v) : '—') });
      }
    }
    // Groups have no account state: the column and its facets only exist for workstations and accounts.
    if (key(ev.population.target) !== 'group') {
      cols.push({ id: 'state', label: 'Compte', type: 'enum', width: 118, get: (r) => (r.active === true ? 'active' : r.active === false ? 'disabled' : 'unknown'),
        options: [{ value: 'active', label: 'Actif', tone: 'ok' }, { value: 'disabled', label: 'Désactivé', tone: 'off' }, { value: 'unknown', label: 'État inconnu', tone: 'warn' }] });
    }
    if (computer) {
      cols.push({ id: 'presence', label: 'Présence', type: 'enum', width: 128, get: (r) => r.presence,
        options: [{ value: 'online', label: 'En ligne', tone: 'ok' }, { value: 'offline', label: 'Sans réponse', tone: 'warn' }, { value: 'unchecked', label: 'Non vérifié', tone: 'off' }] });
    }
    for (const c of ev.columns.filter((x) => !x.requested)) {
      if (c.id === 'active') continue;
      if (c.kind === 'number') {
        cols.push({ id: c.id, label: c.label, type: 'number', width: wide(c.label, 130), get: (r) => (Number.isFinite(r.raw?.[c.id]) ? r.raw[c.id] : null), format: (v, r) => r.values?.[c.id] ?? '—' });
      } else {
        cols.push({ id: c.id, label: c.label, width: wide(c.label, c.id === 'site' ? 130 : 170), get: (r) => r.values?.[c.id] ?? null });
      }
    }
    cols.push({ id: 'dn', label: 'Chemin AD', mono: true, width: 360, hidden: true, get: (r) => r.dn });
    return cols;
  }

  function renderGrid(rows, hasMore, total) {
    const ev = st.evaluation;
    const my = ++st.loadingPage;
    st.rows = rows;
    st.total = total;
    if (!st.split) {
      const listNode = document.createElement('div');
      listNode.className = 'rq-res-grid';
      const detailNode = document.createElement('div');
      detailNode.className = 'rq-detail';
      st.split = createSplit($('.rq-res-split'), { a: listNode, b: detailNode, key: 'requetes.apercu.detail.v2', size: 340, min: 280, max: 640, label: 'Taille du détail de l’objet' });
      paintFold();
    }
    const listHost = $('.rq-res-grid');
    // The list is as tall as its rows (a few results leave no empty block), between 320 and 540 px.
    const height = Math.max(320, Math.min(540, 64 + total * 40));
    $('.rq-res-split').style.setProperty('--rq-res-h', `${height + 20}px`);
    st.grid?.destroy();
    st.grid = createGrid(listHost, {
      key: `requetes.apercu.v2.${key(ev.population.target)}`,
      label: 'Résultats de l’aperçu',
      columns: columnsOf(ev),
      rowId: (r) => r.id,
      selection: 'single',
      height: `${height}px`,
      quickFilter: false,
      empty: { icon: 'search', title: 'Aucun objet pour ces filtres', text: 'Changez de verdict, d’état ou de texte : les filtres d’affichage ne changent ni la répartition ni les compteurs.' },
      onActiveChange: (row) => { if (row) showDetail(row); },
      onActivate: (row) => openFiche(row),
      contextMenu: ({ row }) => [
        { label: 'Pourquoi ce résultat ?', icon: 'info', disabled: !row, run: () => showDetail(row) },
        { label: 'Ouvrir la fiche AD', icon: 'object', kbd: 'Entrée', disabled: !row, run: () => openFiche(row) },
        { label: 'Copier', icon: 'copy', disabled: !row, items: [
          { label: 'Le nom', run: () => copy(row.name, 'Nom copié.') },
          { label: 'Le GUID', run: () => copy(row.id, 'GUID copié.') },
          { label: 'Le chemin AD (DN)', run: () => copy(row.dn, 'Chemin AD copié.') },
        ] },
        '-',
        { label: 'Actualiser ce poste…', icon: 'wifi', hint: 'réseau', disabled: !row || key(ev.population.target) !== 'computer', reason: 'Seulement pour un poste.', run: () => refreshObject(row) },
      ],
    });
    st.grid.setRows(rows, { hasMore: false });
    summary();
    // The detail opens on the first object shown, so the explanation is visible at once.
    if (rows[0]) showDetail(rows[0]); else renderDetailEmpty();
    if (hasMore) loadRest(rows.length, my);
  }

  function summary() {
    const ev = st.evaluation;
    if (!st.bar || !ev) return;
    const partial = st.rows.length < st.total;
    st.bar.setSummary(partial
      ? `→ ${formatNumber(st.rows.length)} lignes chargées sur ${plural(st.total, 'objet', 'objets')}${st.loadingAll ? ' (chargement…)' : ' (liste partielle)'}`
      : `→ ${plural(st.total, 'objet affiché', 'objets affichés')} sur ${formatNumber(ev.counts.population)}`);
  }

  /** The rest of a filtered list, page after page: the data are local, so sorts and filters of the grid stay exact. */
  async function loadRest(from, my) {
    const ev = st.evaluation;
    st.loadingAll = true;
    let offset = from;
    while (store.alive && my === st.loadingPage && offset < Math.min(st.total, MAX_ROWS)) {
      summary();
      const res = await store.call('requetes.preview.page', { evaluationId: ev.id, verdict: st.verdict, state: st.state, text: st.text || null, offset, limit: PAGE });
      if (!store.alive || my !== st.loadingPage) return;
      if (res.error) { store.toast(res.message, 'warn'); break; }
      $('.rq-pv-stale').hidden = !res.data.stale;
      st.rows = st.rows.concat(res.data.rows);
      st.grid.appendRows(res.data.rows, { hasMore: false });
      offset += res.data.rows.length;
      if (!res.data.hasMore || !res.data.rows.length) break;
    }
    st.loadingAll = false;
    summary();
  }

  async function loadPage() {
    const ev = st.evaluation;
    if (!ev) return;
    const my = ++st.loadingPage;
    st.grid?.setLoading(true);
    const res = await store.call('requetes.preview.page', { evaluationId: ev.id, verdict: st.verdict, state: st.state, text: st.text || null, offset: 0, limit: PAGE });
    if (!store.alive || my !== st.loadingPage) return;
    if (res.error) { st.grid?.setError(res.message, { retry: () => loadPage() }); return; }
    const page = res.data;
    $('.rq-pv-stale').hidden = !page.stale;
    st.rows = page.rows;
    st.total = page.total;
    st.grid.setRows(page.rows, { hasMore: false });
    summary();
    if (page.hasMore) loadRest(page.rows.length, my);
  }

  const search = debounce(() => {
    const text = $('.rq-res-search input').value.trim();
    if (text === st.text) return;
    st.text = text;
    loadPage();
  }, 240);
  $('.rq-res-search input').addEventListener('input', search);
  $('.rq-res-search input').addEventListener('keydown', (e) => { if (e.key === 'Escape' && e.target.value) { e.preventDefault(); e.stopPropagation(); e.target.value = ''; search(); search.flush(); } });

  function paintFold() {
    const folded = st.split?.isFolded() ?? false;
    const b = $('.rq-fold-detail');
    b.setAttribute('aria-pressed', String(folded));
    b.querySelector('span').textContent = folded ? 'Afficher le détail' : 'Masquer le détail';
  }
  $('.rq-fold-detail').addEventListener('click', () => {
    if (!st.split) return;
    st.split.fold(!st.split.isFolded());
    paintFold();
  });

  function renderDetailEmpty() {
    const host = $('.rq-detail');
    if (!host) return;
    host.innerHTML = `<div class="rq-detail-empty">${glyph('info')}<p><b>Choisissez une ligne</b>Sa fiche locale et l’explication de son verdict s’affichent ici, sans aucune relecture.</p></div>`;
  }

  async function showDetail(row) {
    const ev = st.evaluation;
    const host = $('.rq-detail');
    if (!host || !row) return;
    st.active = row;
    const my = ++st.detailToken;
    host.innerHTML = `<div class="rq-detail-in" aria-busy="true">${skLines(60, 85, 70, 90, 50)}</div>`;
    const res = await store.call('requetes.preview.object', { evaluationId: ev.id, id: row.id });
    if (!store.alive || my !== st.detailToken) return;
    if (res.error) { host.innerHTML = emptyState('alert', 'Détail indisponible', res.message); return; }
    const o = res.data;
    $('.rq-pv-stale').hidden = !o.stale;
    const computer = key(ev.population.target) === 'computer';
    host.innerHTML = `<div class="rq-detail-in">
      <header class="rq-detail-head"><span class="avatar ${computer ? 'pc' : ''}">${glyph(computer ? 'monitor' : key(ev.population.target) === 'group' ? 'group' : 'user')}</span>
        <div class="rq-detail-titles"><h4>${esc(o.name)}</h4><span class="rq-mono rq-detail-dn" data-tip="${esc(o.dn)}">${esc(o.dn)}</span></div>${verdictPill(o.verdict)}</header>
      <div class="rq-detail-actions">
        <button type="button" class="btn xs subtle" data-act="fiche">${glyph('object')}Fiche AD et actions…</button>
        ${computer ? `<button type="button" class="btn xs subtle" data-act="refresh">${glyph('wifi')}Actualiser ce poste…</button>` : ''}
        <button type="button" class="btn xs ghost" data-act="copy">${glyph('copy')}Copier le chemin AD</button>
      </div>
      <div class="rq-detail-tabs"></div>
    </div>`;
    host.querySelector('[data-act="fiche"]').addEventListener('click', () => openFiche(row));
    host.querySelector('[data-act="refresh"]')?.addEventListener('click', () => refreshObject(row));
    host.querySelector('[data-act="copy"]').addEventListener('click', () => copy(o.dn, 'Chemin AD copié.'));
    st.detailTabs?.destroy();
    st.detailTabs = createTabs(host.querySelector('.rq-detail-tabs'), {
      label: 'Détail de l’objet',
      key: 'requetes.detail',
      tabs: [
        { id: 'why', label: 'Pourquoi ce résultat ?', icon: 'info', render: (p) => { p.innerHTML = explanation(o.explanation); vars(p); } },
        { id: 'fiche', label: 'Fiche locale', icon: 'object', count: o.fields.filter((f) => f.known).length, render: (p) => { p.innerHTML = fiche(o); } },
      ],
    });
  }

  function explanation(rows) {
    if (!rows.length) return '<p class="rq-note">Aucune condition : tous les objets du périmètre correspondent.</p>';
    return `<ol class="rq-why">${rows.map((r, n) => `<li class="rq-why-row" data-v="${esc(r.verdictKey)}" data-depth="${r.depth}" data-i="${n}">
      <span class="rq-why-mark" aria-hidden="true">${glyph(VERDICTS[r.verdictKey]?.icon ?? 'info')}</span>
      <div class="rq-why-main"><b>${esc(r.condition)}</b><span>Valeur : ${esc(r.value || '—')} · ${esc(r.state)}${r.observedAt ? ` · ${esc(dateText(r.observedAt))}` : ''}</span></div>
      <span class="rq-why-verdict">${esc(r.verdict)}</span></li>`).join('')}</ol>
      <p class="rq-note">${glyph('shield')}Explication calculée sur la définition figée de l’aperçu, pas sur le brouillon modifié depuis.</p>`;
  }

  function fiche(o) {
    let last = null;
    const rows = o.fields.map((f) => {
      const head = f.requested ? 'Informations de la requête' : f.category;
      const h = head !== last ? `<tr class="rq-fiche-group"><th colspan="3">${esc(head)}</th></tr>` : '';
      last = head;
      return `${h}<tr class="${f.known ? '' : 'unknown'}"><th scope="row">${esc(f.name)}<small>${esc(f.source)}</small></th><td>${esc(f.value || '—')}</td><td>${esc(f.observedAt ? dateText(f.observedAt) : 'Date non disponible')}</td></tr>`;
    }).join('');
    return `<div class="rq-table-wrap rq-fiche"><table class="table rq-table"><tbody>${rows}</tbody></table></div>
      <p class="rq-note">GUID <span class="rq-mono">${esc(o.id)}</span> · calcul du ${esc(dateText(o.computedAt))} · aucune relecture.</p>`;
  }

  async function copy(text, message) {
    await writeClipboard(text);
    store.toast(message, 'ok');
  }

  function openFiche(row) {
    if (!row) return;
    store.ctx.navigate('fiche', { dn: row.dn, guid: row.id, source: 'requetes' });
  }

  async function refreshObject(row) {
    const ok = await confirmDialog({
      title: `Actualiser ${row.name} ?`,
      message: 'Relevé explicite du seul poste choisi (présence, inventaire, sondes et SELECT WMI de la requête), en lecture seule. Rien n’est écrit.',
      confirmLabel: 'Actualiser ce poste',
      icon: 'wifi',
    });
    if (!ok) return;
    const res = await store.call('requetes.collect.object', { evaluationId: st.evaluation.id, id: row.id });
    if (res.error) { store.toast(res.message, 'warn'); return; }
    store.toast(res.data.text, res.data.result.answered ? 'ok' : 'warn');
    $('.rq-pv-stale').hidden = false;
  }

  async function exportRows(verdict, format) {
    const res = await store.call('requetes.preview.export', { evaluationId: st.evaluation.id, verdict, format });
    if (res.error) { store.toast(res.message, 'warn'); return; }
    openExport(store, res.data, { title: 'Export des résultats' });
  }

  /** Domenia 1 freezes the matching objects for Recherche, then opens Rechercher. */
  async function applySearch() {
    const res = await store.call('requetes.search.apply', { evaluationId: st.evaluation.id });
    if (res.error) { store.toast(res.message, 'warn'); return; }
    store.toast(`${plural(res.data.count, 'objet figé', 'objets figés')} pour Recherche (inconnus exclus).`, 'ok');
    store.emit('search', res.data);
    api.navigate('rechercher', { requete: 'selection', retour: 'requetes' });
  }

  function coverage() {
    openCoverage(store, {
      onApply: (hours) => { const next = { ...store.recipe, coherenceHours: hours }; store.setRecipe(next); store.toast(`Fenêtre de ${hours}${NBSP}h appliquée au brouillon.`, 'ok'); },
      onPlan: plan,
    });
  }

  function plan() {
    openPlan(store, { onDone: () => { $('.rq-pv-stale').hidden = false; } });
  }

  function renderGroups() {
    const ev = st.evaluation;
    const g = ev.groups;
    const host = $('.rq-groups-body');
    $('.rq-all-groups').hidden = !g;
    if (!g) {
      $('.rq-grp-sub').textContent = 'Compteur simple : choisissez une répartition dans « Créer » pour regrouper les objets.';
      host.innerHTML = `<div class="rq-groups-none">${glyph('columns')}<p>Choisissez une information de répartition (système, version, OU, modèle, sonde…) : la répartition complète et exacte s’affiche ici, avec la catégorie « Valeur inconnue ».</p>
        <button type="button" class="btn xs subtle rq-pick-group">${glyph('sliders')}Choisir une répartition</button></div>`;
      host.querySelector('.rq-pick-group').addEventListener('click', () => api.goto('creer'));
      return;
    }
    $('.rq-grp-sub').textContent = `${g.fieldName} · ${plural(g.categoryCount, 'valeur', 'valeurs')} · ${plural(g.matched, 'objet correspondant', 'objets correspondants')}`;
    const max = Math.max(1, ...g.items.map((i) => i.value));
    host.innerHTML = g.items.length ? `<ol class="rq-hbars">${g.items.map((item, n) => `<li data-i="${n}"><button type="button" class="rq-hbar" data-n="${n}" data-tip="Afficher ces objets">
      <span class="rq-hbar-label">${esc(item.label)}</span><span class="rq-hbar-track"><span class="rq-hbar-fill${item.select.missing ? ' unknown' : item.label === 'Autres valeurs' ? ' others' : ''}" data-w="${(100 * item.value / max).toFixed(1)}"></span></span>
      <span class="rq-hbar-value"><b>${num(item.value)}</b><small>${formatNumber(item.share, 1)}${NBSP}%</small></span></button></li>`).join('')}</ol>`
      : '<p class="rq-note">Aucun objet correspondant : la répartition est vide.</p>';
    vars(host);
    host.querySelectorAll('.rq-hbar').forEach((b) => b.addEventListener('click', () => segment(g.items[Number(b.dataset.n)].select)));
  }

  async function segment(selection) {
    const res = await store.call('requetes.preview.segment', { evaluationId: st.evaluation.id, label: selection.label, missing: selection.missing, value: selection.value ?? null, excluded: selection.excluded ?? [] });
    if (res.error) { store.toast(res.message, 'warn'); return; }
    store.setRecipe(res.data.recipe, { origin: 'segment' });
    store.toast(`Segment « ${selection.label} » ajouté : nouvel aperçu.`, 'info');
    api.runPreview();
  }

  function renderDefinition() {
    const ldap = st.evaluation.ldap;
    $('.rq-plan').hidden = key(st.evaluation.population.target) !== 'computer';
    $('.rq-lm-filter').textContent = ldap.pretty || ldap.filter;
    $('.rq-lm-local').innerHTML = ldap.residual.length
      ? ldap.residual.map((r) => `<li>${glyph('layers')}${esc(r)}</li>`).join('')
      : `<li class="ok">${glyph('check')}Toutes les conditions s’expriment en LDAP.</li>`;
  }

  $('.rq-all-groups').addEventListener('click', () => openGroups(store, st.evaluation.id, { onShow: segment }));
  $('.rq-coverage').addEventListener('click', coverage);
  $('.rq-plan').addEventListener('click', plan);
  $('.rq-rerun').addEventListener('click', () => api.runPreview());
  panel.addEventListener('click', (e) => {
    const b = e.target instanceof Element ? e.target.closest('.rq-kpi-go') : null;
    if (!b) return;
    st.verdict = b.dataset.verdict;
    renderFilters();
    loadPage();
    $('.rq-results').scrollIntoView({ behavior: 'smooth', block: 'start' });
  });

  const offs = [
    store.on('evaluating', () => renderEmpty('loading')),
    store.on('evaluation', (ev) => (ev ? render(ev) : renderEmpty())),
    store.on('evaluation-error', (message) => renderEmpty('error', message)),
    store.on('recipe', () => { if (st.evaluation && store.validation?.fingerprint && store.validation.fingerprint !== st.evaluation.fingerprint) $('.rq-pv-stale').hidden = false; }),
  ];

  if (store.evaluation) render(store.evaluation);
  else renderEmpty(store.evaluating ? 'loading' : 'idle');

  return {
    destroy() {
      offs.forEach((off) => off());
      stopReveal();
      search.cancel();
      st.loadingPage += 1;
      st.grid?.destroy();
      st.detailTabs?.destroy();
      st.cmdbar?.destroy();
    },
  };
}
