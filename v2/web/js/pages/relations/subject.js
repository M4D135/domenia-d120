// Utilisateurs et postes · « Sujet » tab: subject picker (local index, never the network), landing with suggestions, and
// the view of one user or workstation: identity, primary relation, separate statements (declared, observed, history,
// clues), relations as an animated graph, a list or a chronology, recent logons and the rules of the badges shown.
import { glyph } from '../../kit/glyphs.js';
import { createGrid } from '../../kit/grid.js';
import { timeline, bindTimeline } from '../../kit/timeline.js';
import { debounce, uid } from '../../kit/util.js';
import { applyVars, inkFollow, reveal, relTime, formatDateTime } from '../../ui.js';
import { renderGraph, graphLegend } from './graph.js';
import {
  BADGES, BADGE_OPTIONS, badge, dot, avatar, when, esc, int, nouns, NBSP, errText, empty, sk,
} from './model.js';

const VIEWS = [
  { id: 'graphe', label: 'Graphe', icon: 'layers' },
  { id: 'liste', label: 'Liste', icon: 'rows' },
  { id: 'chronologie', label: 'Chronologie', icon: 'history' },
];

const IDENTITY = [
  { value: 'same', label: 'Vérifiée', tone: 'ok' },
  { value: 'unknown', label: 'Non vérifiable', tone: 'warn' },
  { value: 'different', label: 'Autre objet', tone: 'alert' },
];
const PERSISTENCE = [
  { value: 'stored', label: 'Enregistrée', tone: 'ok' },
  { value: 'session', label: 'Session uniquement', tone: 'warn' },
];

/** Subject picker: a search field with a listbox of users and workstations of the local index. */
function pickerMarkup(id, value = '') {
  return `<div class="rel-picker" role="search">
    <span class="rel-picker-ico" aria-hidden="true">${glyph('search')}</span>
    <input class="input rel-picker-input" type="search" id="${id}" value="${esc(value)}" autocomplete="off" spellcheck="false"
      placeholder="Utilisateur ou poste : identifiant, nom ou PC-…" aria-label="Choisir un utilisateur ou un poste"
      role="combobox" aria-expanded="false" aria-controls="${id}-list" aria-autocomplete="list">
    <kbd class="rel-picker-kbd" aria-hidden="true">Entrée</kbd>
    <ul class="rel-picker-list" id="${id}-list" role="listbox" aria-label="Utilisateurs et postes" hidden></ul>
  </div>`;
}

function optionMarkup(m, i, active) {
  const reason = m.reason ? `<span class="rel-opt-reason">${esc(m.reason)}</span>` : '';
  return `<li class="rel-opt${active ? ' active' : ''}" role="option" id="rel-opt-${i}" aria-selected="${active}" data-ref="${esc(m.dn)}" data-j="${Math.min(i, 12)}">
    ${avatar(m.kind, m.name, 'sm')}<span class="rel-opt-text"><b>${esc(m.name)}</b><span class="mono">${esc(m.login)}</span>${m.detail ? `<span class="rel-opt-detail">${esc(m.detail)}</span>` : ''}</span>
    ${reason}<span class="rel-opt-links" data-tip="Associations mémorisées">${glyph('link')}${int(m.links)}</span></li>`;
}

/**
 * Creates the « Sujet » tab in panel.
 * @param {HTMLElement} panel
 * @param {object} app  Controller of the screen (relations.js): ctx, select(ref), openPanel(name), plan(op, args), removeRow(row), saveSession(row).
 */
export function createSubjectTab(panel, app) {
  const pickerId = uid('relpick');
  let view = VIEWS.some((v) => v.id === app.params.vue) ? app.params.vue : 'graphe';
  let data = null;
  let grid = null;
  let graphCtl = null;
  let ink = null;
  const stops = [];

  panel.innerHTML = `<div class="rel-sub">
    <div class="rel-sub-bar reveal">${pickerMarkup(pickerId)}<div class="rel-sub-recent" aria-label="Sujets récents"></div></div>
    <div class="rel-sub-body" aria-live="polite"></div>
  </div>`;
  const body = panel.querySelector('.rel-sub-body');
  const input = panel.querySelector('.rel-picker-input');
  const list = panel.querySelector('.rel-picker-list');
  stops.push(reveal(panel));

  // ---------- Picker ----------
  let options = [];
  let activeIndex = -1;
  let requestId = 0;
  const closeList = () => { list.hidden = true; input.setAttribute('aria-expanded', 'false'); input.removeAttribute('aria-activedescendant'); };
  function paintOptions(matches, title) {
    options = matches;
    activeIndex = matches.length ? 0 : -1;
    list.innerHTML = (title ? `<li class="rel-opt-title" role="presentation">${esc(title)}</li>` : '')
      + (matches.length ? matches.map((m, i) => optionMarkup(m, i, i === 0)).join('') : '<li class="rel-opt-none" role="presentation">Aucun utilisateur ni poste de l’index local ne correspond.</li>');
    applyVars(list);
    list.hidden = false;
    input.setAttribute('aria-expanded', 'true');
    if (activeIndex >= 0) input.setAttribute('aria-activedescendant', 'rel-opt-0');
  }
  const search = debounce(async () => {
    const my = ++requestId;
    try {
      const res = await app.ctx.call('relations.subjects.search', { text: input.value.slice(0, 100) });
      if (my !== requestId || !app.alive) return;
      if (!input.value.trim()) paintOptions(res.suggestions, 'Suggestions');
      else paintOptions(res.results, res.truncated ? 'Premiers résultats : affinez la recherche.' : '');
    } catch (err) {
      if (my !== requestId) return;
      list.innerHTML = `<li class="rel-opt-none" role="presentation">${esc(errText(err))}</li>`;
      list.hidden = false;
    }
  }, 180);
  input.addEventListener('input', search);
  input.addEventListener('focus', () => { if (list.hidden) search(); });
  input.addEventListener('keydown', (e) => {
    if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
      if (list.hidden) { search(); return; }
      e.preventDefault();
      if (!options.length) return;
      activeIndex = (activeIndex + (e.key === 'ArrowDown' ? 1 : -1) + options.length) % options.length;
      list.querySelectorAll('.rel-opt').forEach((li, i) => { li.classList.toggle('active', i === activeIndex); li.setAttribute('aria-selected', String(i === activeIndex)); });
      input.setAttribute('aria-activedescendant', `rel-opt-${activeIndex}`);
      list.querySelector('.rel-opt.active')?.scrollIntoView({ block: 'nearest' });
    } else if (e.key === 'Enter') {
      e.preventDefault();
      const chosen = options[activeIndex];
      if (chosen) { closeList(); app.select(chosen.dn); } else if (input.value.trim().length >= 2) { closeList(); app.select(input.value.trim()); }
    } else if (e.key === 'Escape' && !list.hidden) {
      e.preventDefault();
      e.stopPropagation();
      closeList();
    }
  });
  list.addEventListener('pointerdown', (e) => {
    const li = e.target instanceof Element ? e.target.closest('.rel-opt') : null;
    if (!li) return;
    e.preventDefault();
    closeList();
    app.select(li.dataset.ref);
  });
  const outside = (e) => { if (!(e.target instanceof Node) || !panel.querySelector('.rel-picker').contains(e.target)) closeList(); };
  document.addEventListener('pointerdown', outside, true);

  function paintRecent() {
    const host = panel.querySelector('.rel-sub-recent');
    const recent = app.recent();
    host.innerHTML = recent.length ? `<span class="rel-recent-k">Récents</span>${recent.map((r, j) => `<button class="chip rel-recent" type="button" data-ref="${esc(r.dn)}" data-j="${j}">${glyph(r.kind === 'computer' ? 'monitor' : 'user')}${esc(r.login)}</button>`).join('')}` : '';
    applyVars(host);
  }
  panel.querySelector('.rel-sub-recent').addEventListener('click', (e) => {
    const b = e.target instanceof Element ? e.target.closest('[data-ref]') : null;
    if (b) app.select(b.dataset.ref);
  });

  // ---------- Landing (no subject) ----------
  async function landing() {
    teardownView();
    data = null;
    body.innerHTML = `<div class="rel-landing">
      <section class="card rel-landing-hero reveal">${empty('link', 'Choisissez un utilisateur ou un poste',
        'Ses associations s’affichent ici dans les deux sens : affectation déclarée, sessions observées, historique et indices, chacun avec sa source et sa date. Rien n’est lu sur le réseau pour les afficher.',
        `<button class="btn primary" type="button" data-focus-picker>${glyph('search')}Rechercher un sujet</button>`)}
        <ul class="rel-landing-legend" aria-label="Lecture des badges">${['declared', 'observed', 'history', 'imported', 'hint', 'contradictory'].map((b, j) => `<li data-j="${j}">${badge(b)}<span>${esc(BADGES[b].tip)}</span></li>`).join('')}</ul></section>
      <section class="rel-suggest" aria-label="Suggestions">${[0, 1, 2, 3].map(() => `<div class="card rel-suggest-card">${sk('w40')}${sk('w70')}${sk('w55')}</div>`).join('')}</section>
    </div>`;
    body.querySelector('[data-focus-picker]').addEventListener('click', () => input.focus());
    applyVars(body);
    stops.push(reveal(body));
    try {
      const res = await app.ctx.call('relations.subjects.search', { text: '' });
      if (!app.alive || data) return;
      const host = body.querySelector('.rel-suggest');
      if (!host) return;
      host.innerHTML = res.suggestions.length
        ? res.suggestions.map((m, j) => `<button class="card rel-suggest-card spot tilt reveal" type="button" data-ref="${esc(m.dn)}" data-j="${j}">
            <span class="rel-suggest-top">${avatar(m.kind, m.name)}<span class="rel-suggest-kind">${m.kind === 'computer' ? 'Poste' : 'Utilisateur'}</span></span>
            <b class="rel-suggest-name">${esc(m.name)}</b>${m.login !== m.name ? `<span class="rel-suggest-login mono">${esc(m.login)}</span>` : `<span class="rel-suggest-login">${esc(m.detail ?? '')}</span>`}
            <span class="rel-suggest-reason">${glyph(m.reason?.startsWith('Affecté') ? 'alert' : 'sparkles')}${esc(m.reason ?? '')}</span>
            <span class="rel-suggest-links">${glyph('link')}${esc(nouns(m.links, 'association', 'associations'))}</span></button>`).join('')
        : '';
      applyVars(host);
      stops.push(reveal(host));
      host.addEventListener('click', (e) => {
        const b = e.target instanceof Element ? e.target.closest('[data-ref]') : null;
        if (b) app.select(b.dataset.ref);
      });
    } catch (err) {
      const host = body.querySelector('.rel-suggest');
      if (host) host.innerHTML = `<p class="rel-note warn">${glyph('alert')}${esc(errText(err))}</p>`;
    }
  }

  // ---------- Subject view ----------
  function teardownView() {
    grid?.destroy(); grid = null;
    graphCtl?.destroy(); graphCtl = null;
    ink?.stop(); ink = null;
  }

  function loading(ref) {
    teardownView();
    body.innerHTML = `<div class="rel-subject" aria-busy="true">
      <aside class="card rel-id">${sk('rel-sk-avatar')}${sk('w70')}${sk('w40')}${sk('w85')}${sk('rel-sk-block')}${sk('w85')}${sk('w70')}</aside>
      <section class="card rel-rel">${sk('w40')}<div class="rel-sk-graph skeleton"></div></section>
      <section class="card rel-logons">${sk('w40')}${sk('w85')}${sk('w70')}</section>
      <section class="card rel-why">${sk('w40')}${sk('w85')}${sk('w70')}</section>
      <span class="visually-hidden">Lecture des relations de ${esc(ref)}…</span>
    </div>`;
  }

  function failed(ref, err) {
    teardownView();
    body.innerHTML = `<section class="card rel-error" role="alert">${empty('alert', 'Relations non lues', errText(err),
      `<button class="btn" type="button" data-retry>${glyph('refresh')}Réessayer</button><button class="btn ghost" type="button" data-clear>${glyph('x')}Changer de sujet</button>`)}</section>`;
    body.querySelector('[data-retry]').addEventListener('click', () => app.select(ref));
    body.querySelector('[data-clear]').addEventListener('click', () => app.clear());
  }

  function primaryMarkup(p, kind) {
    const label = kind === 'user' ? 'Poste principal' : 'Utilisateur principal';
    if (!p) {
      return `<div class="rel-primary none"><span class="rel-primary-k">${label}</span><p>Aucune relation${NBSP}: ${esc(kind === 'user' ? 'aucun poste associé à cet utilisateur.' : 'aucun utilisateur associé à ce poste.')}</p></div>`;
    }
    return `<div class="rel-primary" data-badge="${esc(p.badge)}">
      <span class="rel-primary-k">${label}${badge(p.badge, { size: 'sm' })}</span>
      <button class="rel-primary-name" type="button" ${p.dn ? `data-ref="${esc(p.dn)}"` : 'disabled'} data-tip="Voir ses relations">${avatar(kind === 'user' ? 'computer' : 'user', p.name, 'md')}<span><b>${esc(p.name)}</b>${p.login !== p.name ? `<span class="mono">${esc(p.login)}</span>` : ''}</span>${glyph('chevronRight')}</button>
      <p class="rel-primary-why">${esc(p.reason)}${p.whenText ? ` · ${esc(p.whenText)}` : ''}</p></div>`;
  }

  function factsMarkup(lines) {
    return `<ul class="rel-facts">${lines.map((l, j) => `<li data-badge="${esc(l.badge)}" data-j="${j}">${dot(l.badge)}<div><b>${esc(l.fact)}</b><span>${esc(l.value)}</span></div></li>`).join('')}</ul>`;
  }

  function countsMarkup(c) {
    const items = [
      ['declared', c.declared, 'déclarée', 'déclarées'], ['observed', c.observed, 'observée', 'observées'], ['history', c.history, 'historique', 'historiques'],
      ['imported', c.imported, 'importée', 'importées'], ['hint', c.hints, 'indice', 'indices'], ['contradictory', c.contradicted, 'contradictoire', 'contradictoires'],
    ].filter((x) => x[1] > 0);
    const extra = [];
    if (c.unverified > 0) extra.push(`<span class="chip warn" data-tip="Associations sans GUID enregistré : identité non vérifiable.">${glyph('info')}${esc(nouns(c.unverified, 'non vérifiable', 'non vérifiables'))}</span>`);
    if (c.sessionOnly > 0) extra.push(`<span class="chip info" data-tip="Observations de cette session, pas encore enregistrées.">${glyph('clock')}${esc(nouns(c.sessionOnly, 'de session', 'de session'))}</span>`);
    return `<div class="rel-counts">${items.map(([b, n, one, many], j) => `<span class="rel-count" data-badge="${b}" data-j="${j}">${dot(b)}<b>${int(n)}</b>${esc(n > 1 ? many : one)}</span>`).join('')}${extra.join('')}</div>`;
  }

  function show(res) {
    teardownView();
    data = res;
    const s = res.subject;
    const isUser = s.kind === 'user';
    const dir = res.direction;
    const lastLogon = s.lastLogon ? `<span class="chip" data-tip="${esc(`Dernière authentification connue de l’annuaire : ${formatDateTime(s.lastLogon) ?? ''} (lastLogonTimestamp, à 14 jours près)`)}">${glyph('clock')}${esc(relTime(s.lastLogon) ?? '')}</span>` : '';
    body.innerHTML = `<div class="rel-subject" data-kind="${esc(s.kind)}">
      <aside class="card rel-id spot reveal" aria-label="Identité du sujet">
        <span class="rel-id-glow" aria-hidden="true"></span>
        <div class="rel-id-top">${avatar(s.kind, s.name, 'xl')}
          <div class="rel-id-titles"><span class="rel-id-kind">${isUser ? 'Utilisateur' : 'Poste'}</span><h2>${esc(s.name)}</h2>
            <p class="mono rel-id-login">${esc(s.login)}</p>${s.detail ? `<p class="rel-id-detail">${esc(s.detail)}</p>` : ''}</div></div>
        <div class="rel-id-pills"><span class="chip ${s.enabled ? 'ok' : 'warn'}">${glyph(s.enabled ? 'check' : 'power')}${s.enabled ? 'Activé' : 'Désactivé'}</span>${lastLogon}</div>
        <p class="rel-id-path" data-tip="${esc(s.dn)}">${glyph('ou')}<span>${esc(s.path)}</span></p>
        ${primaryMarkup(res.primary, s.kind)}
        ${factsMarkup(res.overview.lines)}
        <div class="rel-id-actions">
          <button class="btn primary" type="button" data-act="add">${glyph('plus')}Ajouter une association</button>
          <button class="btn" type="button" data-act="detect">${glyph('wifi')}${esc(dir.detectLabel)}</button>
          ${isUser ? `<button class="btn" type="button" data-act="compare">${glyph('split')}Comparer les groupes</button>` : ''}
          <button class="btn ghost" type="button" data-act="fiche">${glyph('external')}Ouvrir la fiche</button>
        </div>
      </aside>
      <section class="card rel-rel spot reveal" aria-label="Relations">
        <div class="card-head"><span class="card-icon">${glyph('link')}</span>
          <div class="head-titles"><h3>Relations</h3><span class="head-sub">${esc(res.context)}</span></div>
          <div class="meta"><div class="segmented rel-views" role="group" aria-label="Présentation des relations"><span class="thumb" aria-hidden="true"></span>
            ${VIEWS.map((v) => `<button type="button" data-view="${v.id}" aria-pressed="${v.id === view}">${glyph(v.icon)}<span>${esc(v.label)}</span></button>`).join('')}</div></div></div>
        ${countsMarkup(res.counts)}
        <div class="rel-view" data-view-host></div>
        ${res.restore ? `<div class="rel-restore"><span>${glyph('undo')}Dernière suppression locale, toutes associations confondues${NBSP}: ${esc(res.restore.userLogin)} → ${esc(res.restore.computer)}</span><button class="btn sm" type="button" data-act="restore" data-tip="${esc(res.restore.tip)}">${glyph('undo')}${esc(res.restore.label)}</button></div>` : ''}
      </section>
      <section class="card rel-logons reveal" aria-label="Dernières ouvertures de session">
        <div class="card-head"><span class="card-icon">${glyph('clock')}</span><div class="head-titles"><h3>Dernières ouvertures de session</h3>
          <span class="head-sub">Sessions observées, relevés d’historique et dernière authentification de l’annuaire</span></div></div>
        <div class="rel-logons-body">${logonsMarkup(res.logons.slice(0, 7))}</div>
        ${res.logons.length > 7 ? `<button class="btn ghost sm" type="button" data-view-jump="chronologie">${glyph('history')}Toute la chronologie (${int(res.logons.length)})</button>` : ''}
      </section>
      <section class="card rel-why reveal" aria-label="Qualifications expliquées">
        <div class="card-head"><span class="card-icon">${glyph('shield')}</span><div class="head-titles"><h3>Qualifications expliquées</h3>
          <span class="head-sub">Chaque badge dit la règle qui le produit, jamais un pourcentage</span></div></div>
        ${whyMarkup(res)}
      </section>
    </div>`;
    applyVars(body);
    bindTimeline(body);
    const seg = body.querySelector('.rel-views');
    ink = inkFollow(seg, 'button', 'button[aria-pressed="true"]');
    seg.addEventListener('click', (e) => {
      const b = e.target instanceof Element ? e.target.closest('[data-view]') : null;
      if (b) setView(b.dataset.view, true);
    });
    body.querySelector('[data-view-jump]')?.addEventListener('click', (e) => setView(e.currentTarget.dataset.viewJump, true));
    body.querySelector('.rel-id-actions').addEventListener('click', (e) => {
      const b = e.target instanceof Element ? e.target.closest('[data-act]') : null;
      if (!b) return;
      if (b.dataset.act === 'add') app.openPanel(isUser ? 'rechercher' : 'rechercher');
      if (b.dataset.act === 'detect') app.openPanel(isUser ? 'detecter' : 'session');
      if (b.dataset.act === 'compare') app.compareWith(s);
      if (b.dataset.act === 'fiche') app.openFiche(s.dn);
    });
    body.querySelector('[data-act="restore"]')?.addEventListener('click', () => app.restore(res.restore.entryId));
    body.querySelector('.rel-primary-name[data-ref]')?.addEventListener('click', (e) => app.select(e.currentTarget.dataset.ref));
    stops.push(reveal(body));
    paintView();
  }

  function logonsMarkup(logons) {
    if (!logons.length) return `<p class="rel-quiet">${glyph('info')}Aucune ouverture de session relevée ni observée pour ce sujet.</p>`;
    return `<ol class="rel-logon-list">${logons.map((l, j) => `<li data-badge="${esc(l.badge)}" data-j="${j}">
      <span class="rel-logon-mark">${glyph(l.kind === 'history' ? 'history' : l.kind === 'hint' ? 'shield' : 'eye')}</span>
      <div class="rel-logon-text" data-tip="${esc(`${l.text} · ${l.source}`)}"><b>${esc(l.text)}</b><span>${esc(l.source)}</span></div>
      <time datetime="${esc(l.when)}" data-tip="${esc(formatDateTime(l.when) ?? '')}">${esc(l.whenText)}</time></li>`).join('')}</ol>`;
  }

  function whyMarkup(res) {
    const present = new Map();
    for (const row of res.associations) {
      if (!present.has(row.badge)) present.set(row.badge, { n: 0, rule: row.rule });
      present.get(row.badge).n += 1;
    }
    if (!present.size) return `<p class="rel-quiet">${glyph('info')}Aucune association, donc aucun badge à expliquer.</p>`;
    return `<ul class="rel-why-list">${[...present.entries()].sort((a, b) => Object.keys(BADGES).indexOf(a[0]) - Object.keys(BADGES).indexOf(b[0]))
      .map(([b, v], j) => `<li data-j="${j}">${badge(b)}<span class="rel-why-n">${int(v.n)}</span><p>${esc(BADGES[b]?.tip ?? v.rule)}</p></li>`).join('')}</ul>`;
  }

  function setView(id, user) {
    if (!VIEWS.some((v) => v.id === id) || id === view) return;
    view = id;
    body.querySelectorAll('.rel-views [data-view]').forEach((b) => b.setAttribute('aria-pressed', String(b.dataset.view === id)));
    ink?.update();
    if (user) app.remember({ vue: id });
    paintView();
  }

  function paintView() {
    if (!data) return;
    const host = body.querySelector('[data-view-host]');
    grid?.destroy(); grid = null;
    graphCtl?.destroy(); graphCtl = null;
    host.className = `rel-view v-${view}`;
    host.innerHTML = '';
    if (!data.associations.length) {
      host.innerHTML = empty('link', data.direction.emptyHint, 'Ajoutez une association déclarée, ou détectez-la : rien n’est sondé sans votre geste.',
        `<button class="btn primary" type="button" data-empty-add>${glyph('plus')}Ajouter une association</button>`);
      host.querySelector('[data-empty-add]').addEventListener('click', () => app.openPanel('rechercher'));
      return;
    }
    if (view === 'graphe') {
      host.innerHTML = '<div class="rel-graph-host"></div><div class="rel-graph-foot"></div>';
      graphCtl = renderGraph(host.querySelector('.rel-graph-host'), data.graph, {
        label: `Relations de ${data.subject.name}`,
        onOpen: (node) => app.select(node.dn),
      });
      host.querySelector('.rel-graph-foot').innerHTML = graphLegend(data.graph);
      applyVars(host);
    } else if (view === 'liste') {
      host.innerHTML = '<div class="rel-grid-host"></div>';
      grid = createGrid(host.querySelector('.rel-grid-host'), listOptions());
      grid.setRows(data.associations);
    } else {
      host.innerHTML = timeline(data.logons.map((l) => ({
        when: l.when, title: l.text, text: l.source, tone: l.tone, icon: l.kind === 'history' ? 'history' : l.kind === 'hint' ? 'shield' : 'eye',
        html: badge(l.badge, { size: 'sm', label: l.badgeLabel }),
      })), { label: 'Chronologie des ouvertures de session', empty: 'Aucune ouverture de session relevée ni observée.' });
      bindTimeline(host);
    }
  }

  function listOptions() {
    const isUser = data.subject.kind === 'user';
    return {
      key: `relations.sujet.${isUser ? 'user' : 'computer'}`,
      label: `Associations de ${data.subject.name}`,
      rowId: (r) => r.key,
      selection: 'single',
      height: `${Math.min(460, 58 + data.associations.length * 40)}px`,
      columns: [
        {
          id: 'other', label: isUser ? 'Poste' : 'Utilisateur', required: true, width: 220,
          get: (r) => (isUser ? r.computer : r.userName ?? r.userLogin),
          html: (v, r) => `<span class="rel-cell-id">${avatar(isUser ? 'computer' : 'user', v, 'xs')}<span>${esc(v)}${!isUser && r.userName ? `<small class="mono">${esc(r.userLogin)}</small>` : ''}</span></span>`,
        },
        { id: 'badge', label: 'Qualification', type: 'enum', options: BADGE_OPTIONS, width: 150, html: (v, r) => badge(v, { size: 'sm', tip: r.rule }) },
        { id: 'when', label: 'Date', type: 'date', width: 130 },
        { id: 'source', label: 'Source', width: 190 },
        { id: 'persistence', label: 'Persistance', type: 'enum', options: PERSISTENCE, width: 150 },
        { id: 'identity', label: 'Identité', type: 'enum', options: IDENTITY, width: 140, tip: 'GUID enregistré : même objet, même après renommage.' },
        { id: 'details', label: 'Détails', width: 280, hidden: true },
        { id: 'declarant', label: 'Déclarant', mono: true, hidden: true },
        { id: 'computerDn', label: 'DN du poste', mono: true, hidden: true },
        { id: 'userDn', label: 'DN de l’utilisateur', mono: true, hidden: true },
      ],
      empty: { icon: 'link', title: 'Aucune association', text: data.direction.emptyHint },
      onActivate: (row) => { const dn = isUser ? row.computerDn : row.userDn; if (dn) app.select(dn); },
      contextMenu: ({ row }) => app.rowMenu(row, isUser ? 'computer' : 'user'),
    };
  }

  paintRecent();
  return {
    loading, show, failed, landing, paintRecent,
    current: () => data,
    setView: (id) => setView(id, false),
    focusPicker: () => input.focus(),
    destroy() {
      teardownView();
      document.removeEventListener('pointerdown', outside, true);
      search.cancel();
      stops.forEach((fn) => fn());
    },
  };
}
