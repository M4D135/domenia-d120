// Audit AD · « Synthèse »: the domain analysis (AUD-023) with its findings by severity, the totals of the local copy
// (AUD-022), and the exploration of the objects of a finding in a side panel, without a new read. The analysis leaves only
// on the operator's gesture (« Analyser le domaine »); the catalogue of the controls shown before it is local (no read).
import { icon } from '../../icons.js';
import { glyph } from '../../kit/glyphs.js';
import { pill } from '../../kit/status.js';
import { kvSection, bindKv } from '../../kit/kv.js';
import { createGrid } from '../../kit/grid.js';
import { openDrawer } from '../../kit/drawer.js';
import { esc, fold, countUp, formatDateTime, cssMs } from '../../ui.js';
import { debounce } from '../../kit/util.js';
import {
  SEVERITIES, severityOf, KIND_ICONS, num, plural, when, statusMarkup, emptyMarkup, skeletonMarkup, paint, reported, gridHeight,
} from './shared.js';

const SEV_ORDER = Object.fromEntries(SEVERITIES.map((s, n) => [s.id, n]));

/**
 * @param {HTMLElement} panel
 * @param {any} app  Page context: ctx, guard, target(dn), setParams(p), overviewChanged(view), state.
 */
export function createOverview(panel, app) {
  const st = { catalogue: null, view: null, totals: null, busy: false, error: null, severity: null, text: '', category: null };
  const cleanups = [];
  let kvBinding = null;
  let drawer = null;

  panel.innerHTML = '<div class="aud-ov" data-state="idle"><div class="aud-ov-body"></div></div>';
  const root = panel.querySelector('.aud-ov');
  const body = panel.querySelector('.aud-ov-body');

  // ---------- Before the analysis ----------

  function catalogueMarkup(scanning) {
    const list = st.catalogue ?? [];
    const groups = new Map();
    list.forEach((c) => { if (!groups.has(c.category)) groups.set(c.category, []); groups.get(c.category).push(c); });
    let n = 0;
    const cards = [...groups].map(([category, checks]) => `
      <section class="aud-cat-group">
        <h4>${esc(category)}<span>${num(checks.length)}</span></h4>
        <ul role="list">${checks.map((c) => `<li class="aud-check" data-tone="${esc(c.tone)}" data-i="${n++}">
          <span class="aud-check-dot" aria-hidden="true"></span><span class="aud-check-title">${esc(c.title)}</span>
          <span class="aud-check-sev" data-tip="${esc(`Gravité s’il y a un écart : ${c.severityLabel}`)}">${esc(c.severityLabel)}</span></li>`).join('')}</ul>
      </section>`).join('');
    return `<div class="aud-catalogue${scanning ? ' scanning' : ''}"${scanning ? ' aria-busy="true"' : ''}>
      <div class="aud-catalogue-head"><h3>${scanning ? 'Analyse en cours…' : 'Ce que l’analyse vérifie'}</h3>
        <p>${scanning ? 'Lecture bornée des sections du domaine et des recherches de chaque contrôle sur le contrôleur de la session.'
          : `${plural(list.length, 'contrôle', 'contrôles')} et onze sections du domaine. Chaque contrôle est une recherche bornée : l’annuaire n’est jamais compté en entier.`}</p></div>
      <div class="aud-cat-groups">${cards}</div></div>`;
  }

  function renderIdle() {
    root.dataset.state = st.busy ? 'busy' : 'idle';
    const action = `<button class="btn primary aud-run" type="button" data-run${st.busy ? ' disabled' : ''}>${st.busy ? '<span class="k-spin" aria-hidden="true"></span>' : icon('shield')}<span>${st.busy ? 'Analyse en cours…' : 'Analyser le domaine'}</span></button>`;
    body.innerHTML = `<div class="aud-idle">
      <div class="aud-idle-hero reveal">
        ${emptyMarkup({
          icon: 'shield',
          title: st.error ? 'Analyse impossible' : 'Le domaine n’est pas encore analysé',
          text: st.error ?? 'L’analyse lit la configuration du domaine section par section et cherche les écarts de sécurité connus. Rien n’est écrit et aucun mot de passe n’est lu.',
          tone: st.error ? 'alert' : 'accent',
          action: `<div class="aud-idle-actions">${action}<span class="aud-net-note">${glyph('wifi')}Lecture réseau sur ce clic seulement</span></div>`,
        })}
      </div>
      ${st.catalogue ? catalogueMarkup(st.busy) : '<div class="aud-catalogue">' + '<div class="aud-skel" aria-busy="true"><span class="skeleton"></span><span class="skeleton"></span><span class="skeleton"></span></div></div>'}
    </div>`;
    paint(body);
  }

  // ---------- After the analysis ----------

  function bandMarkup(view) {
    const counts = view.counts;
    const tiles = SEVERITIES.map((s, n) => {
      const value = counts[s.id] ?? 0;
      const on = st.severity === s.id;
      return `<button type="button" class="aud-sev card spot reveal${value ? '' : ' zero'}" data-sev="${s.id}" data-tone="${s.tone}" aria-pressed="${on}" data-i="${n}"
          data-tip="${esc(s.hint)}">
        <span class="aud-sev-glow" aria-hidden="true"></span>
        <span class="aud-sev-top"><span class="aud-sev-ico" aria-hidden="true">${icon(s.icon)}</span><span class="aud-sev-name">${esc(value > 1 ? s.plural : s.label)}</span></span>
        <b class="aud-sev-n" data-count="${value}">${num(value)}</b>
        <span class="aud-sev-foot">${value ? plural(value, 'constat', 'constats') : 'aucun constat'}</span>
      </button>`;
    }).join('');
    const passed = `<button type="button" class="aud-sev card spot reveal passed" data-sev="passed" data-tone="ok" aria-pressed="${st.severity === 'passed'}" data-i="5"
        data-tip="Contrôles lus sans écart">
      <span class="aud-sev-glow" aria-hidden="true"></span>
      <span class="aud-sev-top"><span class="aud-sev-ico" aria-hidden="true">${icon('check')}</span><span class="aud-sev-name">Sans écart</span></span>
      <b class="aud-sev-n" data-count="${counts.passed}">${num(counts.passed)}</b>
      <span class="aud-sev-foot">${plural(counts.passed, 'contrôle', 'contrôles')}</span></button>`;
    return `<div class="aud-sev-band" role="group" aria-label="Filtrer les constats par gravité">${tiles}${passed}</div>`;
  }

  function deltaMarkup(delta) {
    if (!Number.isFinite(delta) || delta === 0) return '';
    const up = delta > 0;
    return `<span class="aud-delta ${up ? 'worse' : 'better'}" data-tip="Par rapport à la vue précédente de la session">${icon(up ? 'arrowUp' : 'arrowDown')}${up ? '+' : '−'}${num(Math.abs(delta))}</span>`;
  }

  function findingCard(f, n) {
    const sev = severityOf(f.severity);
    const unread = f.state !== 'read' && f.state !== 'empty';
    return `<article class="aud-finding card spot reveal${unread ? ' unread' : ''}" data-id="${esc(f.id)}" data-sev="${esc(f.severity)}" data-tone="${esc(unread ? 'off' : f.tone)}" data-i="${n}">
      <span class="aud-finding-rail" aria-hidden="true"></span>
      <header class="aud-finding-head">
        ${pill(unread ? 'off' : sev.tone, unread ? f.countLabel : f.severityLabel, { size: 'sm', icon: unread ? 'lock' : sev.icon })}
        <span class="aud-finding-cat">${esc(f.category)}</span>${deltaMarkup(f.delta)}
      </header>
      <h3>${esc(f.title)}</h3>
      <div class="aud-finding-count"><b data-count="${unread ? 'NaN' : f.count}">${unread ? '—' : num(f.count)}</b><span>${esc(unread ? 'non lu' : f.countLabel.replace(/^[\d\s  ]+/, ''))}</span></div>
      ${f.examples?.length ? `<p class="aud-finding-ex">${f.examples.map((x) => `<span>${esc(x)}</span>`).join('')}${f.count > f.examples.length && !unread ? `<em>+${num(f.count - f.examples.length)}</em>` : ''}</p>` : `<p class="aud-finding-sum">${esc(f.summary)}</p>`}
      <p class="aud-finding-advice">${glyph('sparkles')}<span>${esc(f.advice)}</span></p>
      <footer class="aud-finding-foot">
        ${f.explorable ? `<button class="btn sm subtle" type="button" data-explore="${esc(f.id)}">${glyph('eye')}Explorer ${f.truncated ? 'les objets lus' : 'les objets'}</button>` : '<span class="aud-finding-noobj">Aucun objet à explorer</span>'}
        <button class="btn ghost icon xs" type="button" data-why="${esc(f.id)}" aria-label="Source et limite du contrôle" data-tip="Source et limite">${glyph('info')}</button>
      </footer>
      <div class="aud-finding-why" hidden><p><b>Source</b>${esc(f.source)}</p><p><b>Limite</b>${esc(f.limit)}</p></div>
    </article>`;
  }

  function visibleFindings() {
    const all = st.view?.findings ?? [];
    const needle = fold(st.text.trim());
    return all.filter((f) => {
      if (st.severity === 'passed' ? !f.passed : f.passed) return false;
      if (st.severity && st.severity !== 'passed' && f.severity !== st.severity) return false;
      if (st.category && f.category !== st.category) return false;
      if (needle && !fold(`${f.title} ${f.category} ${f.summary} ${f.advice}`).includes(needle)) return false;
      return true;
    });
  }

  function boardMarkup() {
    const list = visibleFindings();
    const categories = [...new Set((st.view?.findings ?? []).filter((f) => !f.passed).map((f) => f.category))];
    const chips = categories.map((c) => `<button type="button" class="chip aud-cat-chip" data-cat="${esc(c)}" aria-pressed="${st.category === c}">${esc(c)}</button>`).join('');
    let n = 0;
    let groupsMarkup = '';
    if (st.severity === 'passed') {
      groupsMarkup = `<div class="aud-passed-list">${list.map((f) => `<div class="aud-passed-row reveal" data-i="${n++}">${icon('check')}<div><b>${esc(f.title)}</b><span>${esc(f.summary)}</span></div><span class="aud-finding-cat">${esc(f.category)}</span></div>`).join('')}</div>`;
    } else {
      const groups = SEVERITIES.map((s) => ({ s, items: list.filter((f) => f.severity === s.id) })).filter((g) => g.items.length);
      groupsMarkup = groups.map((g) => `<section class="aud-group" data-sev="${g.s.id}" data-tone="${g.s.tone}">
          <h3 class="aud-group-head reveal" data-i="${n++}"><span class="aud-group-ico">${icon(g.s.icon)}</span>${esc(g.items.length > 1 ? g.s.plural : g.s.label)}<span class="aud-group-n">${num(g.items.length)}</span></h3>
          <div class="aud-findings">${g.items.map((f) => findingCard(f, n++)).join('')}</div></section>`).join('');
    }
    const empty = list.length ? '' : emptyMarkup({ icon: 'search', title: 'Aucun constat pour ce filtre', text: 'Changez de gravité ou effacez la recherche : rien n’est relu.', tone: 'off',
      action: '<button class="btn sm" type="button" data-clear>Effacer les filtres</button>' });
    const passedCount = st.view.counts.passed;
    return `<section class="aud-board">
      <div class="aud-board-head">
        <h2>${st.severity === 'passed' ? 'Contrôles sans écart' : 'Constats'}<span class="aud-board-n">${num(list.length)}</span></h2>
        <label class="aud-search-field">${glyph('search')}<input class="input" type="search" data-filter placeholder="Filtrer les constats…" value="${esc(st.text)}" aria-label="Filtrer les constats"></label>
      </div>
      ${categories.length > 1 && st.severity !== 'passed' ? `<div class="aud-cat-chips" role="group" aria-label="Filtrer par catégorie">${chips}</div>` : ''}
      ${groupsMarkup}${empty}
      ${st.severity === 'passed' || !passedCount ? '' : `<button type="button" class="aud-passed-link" data-sev-pick="passed">${icon('check')}${plural(passedCount, 'contrôle sans écart', 'contrôles sans écart')} : afficher la liste</button>`}
    </section>`;
  }

  function totalsCard() {
    const t = st.totals;
    if (!t) return `<article class="card aud-totals reveal" aria-busy="true"><div class="aud-skel"><span class="skeleton"></span><span class="skeleton"></span></div></article>`;
    const max = Math.max(1, ...t.types.map((r) => r.count));
    return `<article class="card aud-totals reveal" data-tone="${t.state === 'read' ? 'info' : 'off'}">
      <div class="card-head"><span class="card-icon">${icon('database')}</span><div><h3>${t.simulated ? 'Copie locale fictive' : 'Copie locale du domaine'}</h3>
        <p class="aud-sub">${t.lastSyncAt ? `Synchronisée ${when(t.lastSyncAt)}` : 'Jamais synchronisée'}${t.complete ? '' : ' · incomplète'}</p></div>${pill(t.state === 'read' ? 'ok' : 'off', t.stateLabel, { size: 'sm' })}</div>
      <div class="aud-totals-big"><b data-count="${t.total}">${num(t.total)}</b><span>objets dans la copie</span></div>
      <ul class="aud-totals-bars" role="list">${t.types.map((r, n) => `<li data-i="${n}"><span class="lbl">${esc(r.label)}</span>
        <span class="bar"><span class="fill" data-p="${(r.count / max).toFixed(3)}"></span></span><b>${num(r.count)}</b>
        <span class="off">${r.disabled ? `dont ${num(r.disabled)} désactivé${r.disabled > 1 ? 's' : ''}` : ''}</span></li>`).join('')}</ul>
      <p class="aud-note">${esc(t.summary)}</p></article>`;
  }

  function sectionsMarkup(view) {
    const cards = view.sections.map((s) => `<div class="aud-section reveal" data-tone="${esc(s.tone)}">${kvSection({
      id: s.id,
      title: s.title,
      icon: s.icon,
      meta: s.stateLabel,
      items: s.items.map((i) => ({ label: i.label, value: i.value, tone: i.tone ?? undefined, mono: /^(CN|OU|DC)=/.test(i.value), copy: /^(CN|OU|DC)=/.test(i.value) })),
      open: !['directory', 'sites', 'gpo'].includes(s.id),
    })}${s.message ? `<p class="aud-note">${esc(s.message)}</p>` : ''}</div>`).join('');
    return `<section class="aud-domain"><div class="aud-sec-title reveal"><h2>Vue du domaine</h2><span>${esc(view.controller)} · ${plural(view.sections.length, 'section', 'sections')}, ${plural(view.refused, 'refus', 'refus')}</span></div>
      <div class="aud-domain-grid">${totalsCard()}${cards}</div></section>`;
  }

  function renderReady() {
    root.dataset.state = 'ready';
    const view = st.view;
    body.innerHTML = `${statusMarkup(view.summary, view.counts.critical ? 'alert' : view.counts.high ? 'warn' : 'ok')}
      ${bandMarkup(view)}<div class="aud-board-host">${boardMarkup()}</div>${sectionsMarkup(view)}`;
    paint(body);
    kvBinding?.destroy();
    kvBinding = bindKv(body.querySelector('.aud-domain-grid'), { key: 'audit.sections' });
    app.reveal(body);
    runCounters(body);
  }

  function runCounters(scope) {
    const stagger = cssMs('--stagger', 55);
    scope.querySelectorAll('[data-count]').forEach((el, n) => countUp(el, Number(el.dataset.count), { delay: Math.min(n, 12) * stagger + 160 }));
    scope.querySelectorAll('.fill[data-p]').forEach((el) => requestAnimationFrame(() => el.classList.add('in')));
  }

  function refreshBoard() {
    const host = body.querySelector('.aud-board-host');
    if (!host || !st.view) return;
    host.innerHTML = boardMarkup();
    paint(host);
    app.reveal(host);
    runCounters(host);
    body.querySelectorAll('.aud-sev').forEach((b) => b.setAttribute('aria-pressed', String(b.dataset.sev === st.severity)));
  }

  function render() {
    if (st.view && !st.busy) renderReady();
    else if (st.view && st.busy) {
      root.dataset.state = 'busy';
      body.querySelector('.aud-board-host')?.setAttribute('aria-busy', 'true');
    } else renderIdle();
  }

  // ---------- Reads ----------

  async function loadCatalogue() {
    try {
      st.catalogue = await app.ctx.call('audit.catalogue');
    } catch (err) {
      st.catalogue = [];
      app.toast(reported(err), { tone: 'warn' });
    }
    if (!st.view) renderIdle();
  }

  async function run() {
    if (st.busy) return;
    const token = app.guard.next('overview');
    st.busy = true;
    st.error = null;
    app.busy('analyse', true);
    render();
    try {
      const [view, totals] = await Promise.all([
        app.ctx.call('audit.overview'),
        app.ctx.call('audit.localTotals').catch((err) => ({ state: 'unavailable', stateLabel: 'Non lue', types: [], total: 0, summary: reported(err), lastSyncAt: null, complete: false, simulated: false })),
      ]);
      if (!app.alive() || !app.guard.current(token)) return;
      st.view = view;
      st.totals = totals;
      app.overviewChanged(view);
      app.toast(`Analyse terminée : ${plural(view.findings.filter((f) => !f.passed && f.state === 'read').length, 'constat', 'constats')}, score ${view.score.value}/100.`, { tone: view.counts.critical ? 'warn' : 'ok' });
    } catch (err) {
      if (!app.alive() || !app.guard.current(token)) return;
      st.error = reported(err);
      app.toast(st.error, { tone: 'alert' });
    } finally {
      if (app.alive() && app.guard.current(token)) {
        st.busy = false;
        app.busy('analyse', false);
        render();
      }
    }
  }

  // ---------- Exploration of a finding (side panel, no new read) ----------

  async function explore(id) {
    const finding = st.view?.findings.find((f) => f.id === id);
    if (!finding) return;
    app.setParams({ constat: id });
    const sev = severityOf(finding.severity);
    const node = document.createElement('div');
    node.className = 'aud-explore';
    node.dataset.page = 'audit'; // the drawer lives outside .main: the screen stylesheet still applies (audit.css)
    node.innerHTML = `<div class="aud-explore-head" data-tone="${esc(finding.tone)}">
        <div class="aud-explore-count"><b>${num(finding.count)}</b><span>${esc(finding.countLabel.replace(/^[\d\s  ]+/, ''))}</span></div>
        <div class="aud-explore-text"><p>${esc(finding.summary)}</p><p class="aud-explore-advice">${glyph('sparkles')}${esc(finding.advice)}</p></div></div>
      <dl class="aud-explore-meta"><div><dt>Source</dt><dd>${esc(finding.source)}</dd></div><div><dt>Limite</dt><dd>${esc(finding.limit)}</dd></div></dl>
      <div class="aud-explore-status"></div><div class="aud-explore-grid"></div>`;
    let grid = null;
    drawer = openDrawer({
      title: finding.title,
      subtitle: `${finding.severityLabel} · ${finding.category}`,
      icon: sev.icon,
      key: 'audit.explore',
      width: 820,
      minWidth: 480,
      maxWidth: 1200,
      body: node,
      actions: [
        { id: 'close', label: 'Fermer', run: (p) => p.close() },
        { id: 'copy', label: 'Copier la liste (CSV)', icon: 'copy', run: () => { if (grid) grid.exportCsv('visible'); } },
      ],
      onClose: () => { grid?.destroy(); grid = null; drawer = null; app.setParams({ constat: null }); },
    });
    const gridHost = node.querySelector('.aud-explore-grid');
    gridHost.innerHTML = skeletonMarkup(6);
    let result;
    try {
      result = await app.ctx.call('audit.finding.objects', { id });
    } catch (err) {
      if (drawer) gridHost.innerHTML = statusMarkup(reported(err), 'alert');
      return;
    }
    if (!drawer) return;
    node.querySelector('.aud-explore-status').innerHTML = statusMarkup(`${result.summary} Lu ${formatDateTime(result.readAt) ?? ''}.`, result.truncated ? 'warn' : 'info');
    gridHost.replaceChildren();
    // The grid is sized to its rows once they are known: no empty well under a short list.
    grid = createGrid(gridHost, {
      key: 'audit.explore.objets',
      label: `Objets du constat ${finding.title}`,
      rowId: (r) => r.dn,
      selection: 'single',
      height: gridHeight(result.rows.length, 560),
      columns: [
        { id: 'name', label: 'Nom', required: true, width: 220, html: (v, r) => `<span class="aud-obj">${glyph(KIND_ICONS[r.kind] ?? 'object')}${esc(v)}</span>` },
        { id: 'detail', label: 'Détail', width: 320 },
        { id: 'samAccountName', label: 'Compte', mono: true, width: 150 },
        { id: 'container', label: 'Emplacement', width: 200 },
        { id: 'kindLabel', label: 'Type', width: 110, hidden: true },
        { id: 'enabled', label: 'Actif', type: 'bool', width: 90 },
        { id: 'lastLogon', label: 'Dernière connexion', type: 'date', width: 160 },
        { id: 'passwordLastSet', label: 'Mot de passe changé', type: 'date', width: 160, hidden: true },
        { id: 'dn', label: 'Chemin (DN)', mono: true, hidden: true, width: 360 },
      ],
      empty: { icon: 'search', title: 'Aucun objet', text: 'Ce constat ne nomme aucun objet.' },
      onActivate: (row) => { drawer?.close(); app.target(row.dn); },
      contextMenu: ({ row }) => [
        { label: 'Auditer cet objet', icon: 'shield', kbd: 'Entrée', disabled: !row, run: () => { drawer?.close(); app.target(row.dn); } },
        { label: 'Ouvrir la fiche', icon: 'object', disabled: !row, run: () => { drawer?.close(); app.ctx.navigate('fiche', { dn: row.dn }); } },
      ],
    });
    grid.setRows(result.rows, { hasMore: false });
  }

  // ---------- Events ----------

  const onClick = (e) => {
    const t = e.target instanceof Element ? e.target : null;
    if (!t) return;
    if (t.closest('[data-run]')) { run(); return; }
    const sev = t.closest('[data-sev]:is(.aud-sev)');
    if (sev) { st.severity = st.severity === sev.dataset.sev ? null : sev.dataset.sev; st.category = null; refreshBoard(); return; }
    const pick = t.closest('[data-sev-pick]');
    if (pick) { st.severity = pick.dataset.sevPick; refreshBoard(); return; }
    const cat = t.closest('[data-cat]');
    if (cat) { st.category = st.category === cat.dataset.cat ? null : cat.dataset.cat; refreshBoard(); return; }
    const ex = t.closest('[data-explore]');
    if (ex) { explore(ex.dataset.explore); return; }
    const why = t.closest('[data-why]');
    if (why) {
      const box = why.closest('.aud-finding')?.querySelector('.aud-finding-why');
      if (box) { box.hidden = !box.hidden; why.setAttribute('aria-expanded', String(!box.hidden)); }
      return;
    }
    if (t.closest('[data-clear]')) { st.severity = null; st.category = null; st.text = ''; refreshBoard(); }
  };
  const onInput = debounce((e) => {
    if (!(e.target instanceof HTMLInputElement) || !e.target.matches('[data-filter]')) return;
    st.text = e.target.value;
    const caret = e.target.selectionStart;
    refreshBoard();
    const input = body.querySelector('[data-filter]');
    input?.focus({ preventScroll: true });
    if (input && caret != null) input.setSelectionRange(caret, caret);
  }, 220);
  body.addEventListener('click', onClick);
  body.addEventListener('input', onInput);
  cleanups.push(() => { body.removeEventListener('click', onClick); body.removeEventListener('input', onInput); });

  renderIdle();
  loadCatalogue();

  return {
    run,
    explore,
    state: () => st,
    /** Sections for « Copier la vue » / « Exporter ». */
    sections() {
      if (!st.view) return [{ title: 'Synthèse', summary: 'Domaine non analysé : rien à copier.' }];
      const findings = st.view.findings.slice().sort((a, b) => (a.passed - b.passed) || (SEV_ORDER[a.severity] - SEV_ORDER[b.severity]));
      return [
        { title: 'Synthèse', summary: `${st.view.summary}\nScore de santé : ${st.view.score.value}/100 (${st.view.score.label}). ${st.view.score.detail}` },
        {
          title: 'Constats',
          columns: [
            { label: 'Gravité', get: (f) => f.severityLabel },
            { label: 'Catégorie', get: (f) => f.category },
            { label: 'Contrôle', get: (f) => f.title },
            { label: 'Nombre', get: (f) => f.countLabel },
            { label: 'Constat', get: (f) => f.summary },
            { label: 'Conseil', get: (f) => f.advice },
            { label: 'Limite', get: (f) => f.limit },
          ],
          rows: findings,
        },
        ...st.view.sections.map((s) => ({
          title: `${s.title} (${s.stateLabel})`,
          columns: [{ label: 'Élément', get: (i) => i.label }, { label: 'Valeur', get: (i) => i.value }],
          rows: s.items,
        })),
        st.totals ? { title: 'Copie locale', summary: st.totals.summary } : null,
      ];
    },
    findingColumns: () => [
      { label: 'Gravité', get: (f) => f.severityLabel },
      { label: 'Catégorie', get: (f) => f.category },
      { label: 'Contrôle', get: (f) => f.title },
      { label: 'Nombre', get: (f) => f.count },
      { label: 'Constat', get: (f) => f.summary },
      { label: 'Conseil', get: (f) => f.advice },
      { label: 'Source', get: (f) => f.source },
      { label: 'Limite', get: (f) => f.limit },
    ],
    destroy() {
      drawer?.close();
      kvBinding?.destroy();
      cleanups.forEach((fn) => fn());
    },
  };
}
