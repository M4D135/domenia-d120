// Audit AD · « Objet »: reads on one object, frozen at the gesture (AUD-010): password policy (AUD-011), nested groups and
// « why a member » (AUD-012, AUD-013), delegations and access estimate (AUD-021, AUD-014, AUD-015), group policy links and
// result on the workstation (AUD-016, AUD-017), workstation identity (AUD-018), relations and their history (AUD-019,
// AUD-020). A new target clears what was read for the previous object, and only that (Domenia 1
// Clear-DomeniaAdAuditObjectResults): the analysis, the diagnosis and the identities of the other tabs go on. A result is
// applied only to the target it was read for.
//
// Layout: without a target, the search and the suggestions sit beside the six reads; once an object is chosen, it becomes
// a compact band above the views (search at its side), so the grids get the whole width.
import { icon } from '../../icons.js';
import { glyph } from '../../kit/glyphs.js';
import { createTabs } from '../../kit/tabs.js';
import { createGrid } from '../../kit/grid.js';
import { createDnBreadcrumb } from '../../kit/breadcrumb.js';
import { copyButton, bindCopy } from '../../kit/copy.js';
import { timeline, bindTimeline } from '../../kit/timeline.js';
import { esc } from '../../ui.js';
import { debounce } from '../../kit/util.js';
import {
  KIND_ICONS, num, plural, when, factsMarkup, statusMarkup, emptyMarkup, skeletonMarkup, statChips, paint, reported, tonePill, fitGrid,
} from './shared.js';
import { renderGraph } from './graph.js';

const VIEWS = [
  { id: 'motdepasse', label: 'Mot de passe', icon: 'key', avail: 'policy' },
  { id: 'groupes', label: 'Groupes', icon: 'group', avail: 'groups' },
  { id: 'delegations', label: 'Délégations', icon: 'lock', avail: 'acl' },
  { id: 'gpo', label: 'GPO', icon: 'layers', avail: 'gpoLinks' },
  { id: 'poste', label: 'Identité du poste', icon: 'monitor', avail: 'machineIdentity' },
  { id: 'relations', label: 'Relations', icon: 'link', avail: 'relations' },
];
const AVAIL_LABELS = {
  policy: 'Mot de passe', groups: 'Groupes', acl: 'Délégations', gpoLinks: 'Liens GPO', gpoApplied: 'GPO appliquées',
  machineIdentity: 'Identité du poste', relations: 'Relations', comparison: 'Comparaison',
};
const AVAIL_TIPS = {
  policy: 'Stratégie de mot de passe applicable', groups: 'Groupes imbriqués et cycles', acl: 'Délégations (liste de contrôle d’accès)', gpoLinks: 'Liens GPO de l’objet',
  gpoApplied: 'Résultat GPO sur le poste (RSoP)', machineIdentity: 'Identité AD, DNS et poste', relations: 'Postes et utilisateurs, historique', comparison: 'Comparaison entre contrôleurs (onglet Contrôleurs)',
};
const RESULT_TONES = { allowed: 'ok', denied: 'alert', partial: 'warn', notGranted: 'off' };
const KIND_LABEL_SUGGEST = { account: 'user', scope: 'ou', root: 'domain', domainAdmins: 'shield', selection: 'pin' };

/**
 * @param {HTMLElement} panel
 * @param {any} app  Page context.
 */
export function createObjectTab(panel, app) {
  const st = {
    target: null, loadingTarget: false, error: null, view: app.params.vue ?? 'motdepasse',
    results: {}, busy: new Map(), errors: {}, aclExplicit: false, sid: null, estimate: null, historySource: null, groupPick: null, membership: null,
    suggestions: null, hits: [], hitIndex: -1,
  };
  const views = new Map();
  const viewGrids = new Map();
  let tabs = null;
  let graph = null;
  let crumb = null;
  const cleanups = [];

  panel.innerHTML = `<div class="aud-obj-layout" data-mode="pick">
    <div class="aud-target-col">
      <div class="aud-target-host"></div>
      <div class="aud-find card">
        <label class="aud-find-label" for="aud-find-input">${glyph('search')}<span>Choisir un objet</span></label>
        <div class="aud-find-field"><input id="aud-find-input" class="input" type="search" autocomplete="off" spellcheck="false" placeholder="Nom, compte ou nom DNS…"
          role="combobox" aria-expanded="false" aria-controls="aud-find-list" aria-autocomplete="list"></div>
        <ul id="aud-find-list" class="aud-find-list" role="listbox" aria-label="Objets trouvés" hidden></ul>
        <p class="aud-find-note">${glyph('database')}Recherche dans l’index local : aucune lecture de l’annuaire.</p>
      </div>
      <div class="aud-suggest card"></div>
    </div>
    <section class="aud-obj-main"></section>
  </div>`;
  const layout = panel.querySelector('.aud-obj-layout');
  const input = panel.querySelector('#aud-find-input');
  const list = panel.querySelector('#aud-find-list');
  const targetHost = panel.querySelector('.aud-target-host');
  const suggestHost = panel.querySelector('.aud-suggest');
  const main = panel.querySelector('.aud-obj-main');
  cleanups.push(bindCopy(targetHost));

  const dnOf = () => st.target?.dn ?? null;
  const sameDn = (a, b) => Boolean(a && b) && a.toLowerCase() === b.toLowerCase();
  const avail = (key) => st.target?.availability?.[key] ?? { allowed: false, reason: 'Choisissez d’abord un objet : cette lecture porte sur l’objet sélectionné.' };

  // ---------- Target ----------

  function retakeButton() {
    const sel = app.selection();
    if (!sel) {
      return `<button class="btn sm ghost" type="button" data-retake aria-disabled="true" data-tip="Aucun objet choisi dans Rechercher ni ouvert depuis une fiche : choisissez l’objet ici.">${glyph('refresh')}Reprendre la sélection</button>`;
    }
    const tip = sel.source === 'subject'
      ? `Reprend l’objet choisi dans Rechercher (${sel.name}) : les résultats de l’objet actuel sont effacés, rien n’est lu.`
      : 'Reprend l’objet de la fiche ouverte (adresse de l’écran) : les résultats de l’objet actuel sont effacés, rien n’est lu.';
    return `<button class="btn sm ghost" type="button" data-retake data-tip="${esc(tip)}">${glyph('refresh')}Reprendre la sélection</button>`;
  }

  function idChip(label, value, copyLabel) {
    if (!value) return '';
    return `<li><span class="k">${esc(label)}</span><span class="v mono" data-tip="${esc(value)}">${esc(value)}</span>${copyLabel ? copyButton(value, { label: copyLabel, done: `${label} copié` }) : ''}</li>`;
  }

  function targetMarkup() {
    if (st.loadingTarget) return `<div class="card aud-target loading">${skeletonMarkup(3)}</div>`;
    if (!st.target) {
      return `<div class="card aud-target empty">${emptyMarkup({
        icon: 'object', title: st.error ? 'Objet introuvable' : 'Aucun objet choisi', tone: st.error ? 'warn' : 'accent',
        text: st.error ?? 'Cherchez un compte, un ordinateur, un groupe ou une OU, choisissez une suggestion, ou ouvrez l’audit depuis la fiche d’un objet.',
      })}</div>`;
    }
    const t = st.target;
    const a = t.availability;
    const chips = Object.keys(AVAIL_LABELS).map((k, n) => `<li class="${a[k].allowed ? 'ok' : 'no'}" data-j="${n}" data-tip="${esc(a[k].reason ?? AVAIL_TIPS[k])}">${glyph(a[k].allowed ? 'check' : 'minus')}<span>${esc(AVAIL_LABELS[k])}</span></li>`).join('');
    return `<article class="card aud-target reveal" data-kind="${esc(t.kind)}" aria-label="Objet audité">
      <div class="aud-target-id"><span class="aud-avatar" aria-hidden="true">${glyph(KIND_ICONS[t.kind] ?? 'object')}</span>
        <div class="aud-target-names"><h2>${esc(t.name)}</h2><span class="aud-target-kind">${esc(t.kindLabel)}${t.samAccountName ? ` · <span class="mono">${esc(t.samAccountName)}</span>` : ''}</span></div></div>
      <div class="aud-target-meta">
        <div class="aud-target-crumb"></div>
        <ul class="aud-target-ids" role="list">${idChip('GUID', t.objectGuid, 'Copier le GUID')}${idChip('SID', t.sid, 'Copier le SID')}${idChip('DNS', t.dnsHostName, '')}</ul>
        ${t.description ? `<p class="aud-target-desc">${esc(t.description)}</p>` : ''}
      </div>
      <div class="aud-target-actions">
        <button class="btn sm" type="button" data-fiche>${glyph('object')}Ouvrir la fiche</button>
        ${retakeButton()}
      </div>
      <div class="aud-avail-row"><span class="aud-target-h">Lectures possibles</span><ul class="aud-avail" role="list">${chips}</ul></div>
    </article>`;
  }

  function renderTarget() {
    crumb?.destroy?.();
    crumb = null;
    layout.dataset.mode = st.target || st.loadingTarget ? 'target' : 'pick';
    // Without a target, the band is hidden unless it has something to say (an object not found).
    targetHost.hidden = !st.target && !st.loadingTarget && !st.error;
    targetHost.innerHTML = targetMarkup();
    paint(targetHost);
    app.reveal(targetHost);
    const host = targetHost.querySelector('.aud-target-crumb');
    if (host && st.target) {
      crumb = createDnBreadcrumb(host, { dn: st.target.dn, label: 'Emplacement de l’objet', maxVisible: 5, onNavigate: (dn) => setTarget(dn) });
    }
  }

  async function loadSuggestions() {
    try {
      st.suggestions = await app.ctx.call('audit.suggestions');
    } catch (err) {
      st.suggestions = [];
      reported(err);
    }
    if (app.alive()) renderSuggestions();
  }

  function renderSuggestions() {
    if (!st.suggestions) { suggestHost.innerHTML = skeletonMarkup(3); return; }
    const items = st.suggestions.map((s) => ({ dn: s.target.dn, label: s.label, sub: s.detail, icon: KIND_LABEL_SUGGEST[s.id] ?? KIND_ICONS[s.target.kind] ?? 'object' }));
    const sel = app.selection();
    if (sel?.source === 'subject' && !items.some((i) => sameDn(i.dn, sel.dn))) items.unshift({ dn: sel.dn, label: 'Sélection de Rechercher', sub: sel.name, icon: 'pin' });
    suggestHost.innerHTML = `<h3 class="aud-suggest-h">${glyph('sparkles')}Suggestions</h3>
      ${items.length ? `<ul class="aud-suggest-list" role="list">${items.map((i, n) => `<li data-i="${n}"><button type="button" class="aud-suggest-item" data-pick="${esc(i.dn)}">
        <span class="aud-suggest-ico">${glyph(i.icon)}</span><span><b>${esc(i.label)}</b><small>${esc(i.sub ?? '')}</small></span>${glyph('chevronRight')}</button></li>`).join('')}</ul>`
        : '<p class="aud-muted">Aucune suggestion : cherchez un objet ci-dessus.</p>'}`;
    paint(suggestHost);
  }

  /** Frees the busy state of every read of the object (a new target or a new session): their late answers are ignored. */
  function dropObjectReads() {
    for (const action of st.busy.keys()) app.busy(action, false);
    st.busy.clear();
    app.guard.reset('object');
  }

  async function setTarget(dn, { keepView = false, launch = false } = {}) {
    if (!dn) return;
    // AUD-003, AUD-010: only the reads of the previous object are cancelled; every other tab goes on.
    dropObjectReads();
    st.results = {};
    st.errors = {};
    st.sid = null;
    st.estimate = null;
    st.membership = null;
    st.groupPick = null;
    st.historySource = null;
    st.error = null;
    // The previous object leaves at once: no view of it stays clickable while the new one is looked up.
    st.target = null;
    st.loadingTarget = true;
    app.targetChanged(null);
    renderTarget();
    renderMain();
    const token = app.guard.next('object:target');
    try {
      const target = await app.ctx.call('audit.target', { dn });
      if (!app.alive() || !app.guard.current(token)) return;
      st.target = target;
      app.targetChanged(target);
      const allowed = (id) => target.availability[VIEWS.find((v) => v.id === id)?.avail]?.allowed;
      if (!keepView || !allowed(st.view)) {
        st.view = VIEWS.find((v) => target.availability[v.avail]?.allowed)?.id ?? 'delegations';
        if (keepView && app.params.vue && allowed(app.params.vue)) st.view = app.params.vue;
      }
      app.setParams({ dn: target.dn, vue: st.view });
    } catch (err) {
      if (!app.alive() || !app.guard.current(token)) return;
      st.target = null;
      st.error = reported(err);
      app.targetChanged(null);
    } finally {
      if (app.alive() && app.guard.current(token)) {
        st.loadingTarget = false;
        renderTarget();
        renderMain();
        if (launch && st.target) runView(st.view);
      }
    }
  }

  // ---------- Search (local index) ----------

  function renderHits() {
    const open = st.hits.length > 0 && document.activeElement === input;
    list.hidden = !open;
    input.setAttribute('aria-expanded', String(open));
    list.innerHTML = st.hits.map((h, n) => `<li role="option" id="aud-hit-${n}" aria-selected="${n === st.hitIndex}" data-pick="${esc(h.dn)}" class="aud-hit">
      <span class="aud-hit-ico">${glyph(KIND_ICONS[h.kind] ?? 'object')}</span><span class="aud-hit-text"><b>${esc(h.name)}</b><small>${esc(h.kindLabel)} · ${esc(h.path)}</small></span></li>`).join('');
    if (st.hitIndex >= 0) input.setAttribute('aria-activedescendant', `aud-hit-${st.hitIndex}`); else input.removeAttribute('aria-activedescendant');
  }
  const search = debounce(async () => {
    const text = input.value.trim();
    if (!text) { st.hits = []; st.hitIndex = -1; renderHits(); return; }
    const token = app.guard.next('find');
    try {
      const hits = await app.ctx.call('audit.objects.search', { text: text.slice(0, 100) });
      if (!app.alive() || !app.guard.current(token)) return;
      st.hits = hits;
      st.hitIndex = hits.length ? 0 : -1;
      renderHits();
      app.announce(hits.length ? `${plural(hits.length, 'objet trouvé', 'objets trouvés')}.` : 'Aucun objet trouvé.');
    } catch (err) {
      if (app.alive()) app.toast(reported(err), { tone: 'warn' });
    }
  }, 250);
  const onInputKey = (e) => {
    if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
      if (!st.hits.length) return;
      e.preventDefault();
      st.hitIndex = (st.hitIndex + (e.key === 'ArrowDown' ? 1 : -1) + st.hits.length) % st.hits.length;
      renderHits();
    } else if (e.key === 'Enter' && st.hitIndex >= 0) {
      e.preventDefault();
      const hit = st.hits[st.hitIndex];
      st.hits = [];
      renderHits();
      input.value = hit.name;
      setTarget(hit.dn);
    } else if (e.key === 'Escape' && st.hits.length) {
      e.stopPropagation();
      st.hits = [];
      renderHits();
    }
  };
  const onBlur = () => setTimeout(() => { if (app.alive()) renderHits(); }, 160);
  input.addEventListener('input', search);
  input.addEventListener('keydown', onInputKey);
  input.addEventListener('focus', renderHits);
  input.addEventListener('blur', onBlur);
  cleanups.push(() => {
    input.removeEventListener('input', search);
    input.removeEventListener('keydown', onInputKey);
    input.removeEventListener('focus', renderHits);
    input.removeEventListener('blur', onBlur);
  });

  // ---------- Views ----------

  function destroyViewParts() {
    viewGrids.forEach((g) => g.destroy());
    viewGrids.clear();
    graph?.destroy();
    graph = null;
  }

  function renderMain() {
    destroyViewParts();
    tabs?.destroy();
    tabs = null;
    views.clear();
    st.painted = null;
    if (!st.target) {
      main.innerHTML = st.loadingTarget ? `<div class="card">${skeletonMarkup(6)}</div>`
        : `<div class="card aud-obj-intro">${emptyMarkup({ icon: 'shield', title: 'Six lectures sur un objet', text: 'Stratégie de mot de passe, groupes imbriqués, délégations, stratégies de groupe, identité du poste, postes et utilisateurs. Chaque lecture part sur votre geste et ne porte que sur l’objet choisi.' })}
          <ul class="aud-intro-list" role="list">${VIEWS.map((v, n) => `<li data-i="${n}">${glyph(v.icon)}<span>${esc(v.label)}</span></li>`).join('')}</ul></div>`;
      paint(main);
      return;
    }
    main.innerHTML = '<div class="aud-views"></div>';
    tabs = createTabs(main.querySelector('.aud-views'), {
      label: 'Lectures sur l’objet',
      selected: st.view,
      tabs: VIEWS.map((v) => ({
        id: v.id, label: v.label, icon: v.icon, disabled: !avail(v.avail).allowed, reason: avail(v.avail).reason ?? undefined,
        render: (p) => { views.set(v.id, p); paintView(v.id); },
      })),
      onChange: (id) => {
        st.view = id;
        app.setParams({ vue: id });
        if (st.painted !== id) paintView(id);
        if (id === 'relations' && !st.results.relations && !st.busy.has('relations')) runRelations();
      },
    });
    if (st.view === 'relations' && !st.results.relations) runRelations();
  }

  function head(title, hint, buttons) {
    return `<div class="aud-view-head"><div class="aud-view-title"><h3>${esc(title)}</h3><p>${esc(hint)}</p></div><div class="aud-view-actions">${buttons}</div></div>`;
  }
  function button(action, label, { iconName = 'play', primary = true, net = true, disabled = false, reason = '' } = {}) {
    const busy = st.busy.has(action);
    return `<button class="btn sm ${primary ? 'primary' : 'subtle'}${net ? ' is-net' : ''}" type="button" data-act="${action}"${busy || disabled ? ' aria-disabled="true"' : ''}
      ${reason ? `data-tip="${esc(reason)}"` : net ? 'data-tip="Lecture réseau : part seulement sur ce clic"' : ''}>${busy ? '<span class="k-spin" aria-hidden="true"></span>' : glyph(iconName)}${esc(label)}${net ? '<span class="k-cmd-net" aria-hidden="true"></span>' : ''}</button>`;
  }
  function bodyFor(key, idle) {
    if (st.busy.has(key) && !st.results[key]) return skeletonMarkup(6, 'aud-view-skel');
    if (st.errors[key] && !st.results[key]) return statusMarkup(st.errors[key], 'alert');
    if (!st.results[key]) return idle;
    return null;
  }

  // Only the view shown is painted (a read that ends on a hidden view is painted when the view is shown again): the
  // grids and the graph of the other views are never torn down under the operator's eyes.
  function paintView(id) {
    const p = views.get(id);
    if (!p || id !== st.view) return;
    st.painted = id;
    destroyViewParts();
    const fn = { motdepasse: viewPolicy, groupes: viewGroups, delegations: viewAcl, gpo: viewGpo, poste: viewIdentity, relations: viewRelations }[id];
    fn(p);
    paint(p);
    app.reveal(p);
  }
  const repaint = () => paintView(st.view);

  /** Creates a grid sized to the rows it shows, kept for « Copier la vue » (rows as displayed). */
  function viewGrid(name, host, options, rows, max) {
    const fit = fitGrid(max);
    const grid = fit.bind(createGrid(host, { ...options, height: '240px', onFilterChange: fit.onFilterChange }), rows.length);
    grid.setRows(rows);
    viewGrids.set(name, grid);
    return grid;
  }
  /** Rows a grid shows (filters and sort applied), or the rows read when the grid is not painted. */
  const shownRows = (name, rows) => viewGrids.get(name)?.getVisibleRows() ?? rows;

  // ----- Mot de passe (AUD-011)

  function viewPolicy(p) {
    const r = st.results.policy;
    const idle = emptyMarkup({ icon: 'key', title: 'Stratégie non lue', text: 'Lecture à la demande pour un compte utilisateur : msDS-ResultantPSO, stratégie fine désignée, stratégie du domaine et échéance calculée par le contrôleur.', tone: 'off' });
    let content = bodyFor('policy', idle);
    if (!content) {
      const tone = r.state === 'applies' ? 'info' : r.state === 'none' ? 'ok' : 'warn';
      const label = r.state === 'applies' ? 'Stratégie fine' : r.state === 'none' ? 'Stratégie du domaine' : 'Inconnue';
      const expiry = r.facts.find((f) => f.id === 'expiry');
      content = `<div class="aud-policy-hero" data-tone="${tone}">
          <div class="aud-policy-state">${tonePill(tone, label, { size: 'md', icon: r.state === 'unreadable' ? 'eye' : 'shield' })}<p>${esc(r.summary)}</p></div>
          ${expiry ? `<div class="aud-policy-expiry"><span>Expiration</span><b>${esc(expiry.value)}</b>${r.expiresAt ? `<small>${when(r.expiresAt)}</small>` : `<small>${esc(expiry.stateLabel)}</small>`}</div>` : ''}
        </div>
        ${factsMarkup(r.facts)}
        <p class="aud-foot-note">Lu sur ${esc(r.controller)} ${when(r.readAt)}. Aucun mot de passe n’est lu.</p>`;
    }
    p.innerHTML = `<div class="aud-view">${head('Stratégie de mot de passe applicable', 'La plus petite priorité gagne quand plusieurs stratégies fines visent le compte ; le contrôleur a déjà fait ce choix.',
      button('policy', st.results.policy ? 'Relire la stratégie' : 'Lire la stratégie applicable', { iconName: 'key' }))}<div class="aud-view-body">${content}</div></div>`;
  }

  // ----- Groupes imbriqués (AUD-012, AUD-013)

  function viewGroups(p) {
    const r = st.results.groups;
    const idle = emptyMarkup({ icon: 'group', title: 'Appartenances non lues', text: 'Parcourt les groupes de l’objet puis leurs propres groupes : 2 000 groupes, 16 niveaux et 10 secondes au plus. Une lecture bornée ne prouve jamais une absence.', tone: 'off' });
    let content = bodyFor('groups', idle);
    if (!content) {
      const choices = r.rows.map((g) => ({ dn: g.dn, label: g.name }));
      if (r.primaryGroup?.dn) choices.push({ dn: r.primaryGroup.dn, label: `${r.primaryGroup.name} (groupe principal)` });
      const m = st.membership;
      const path = m?.path?.length ? `<ol class="aud-path">${m.path.map((n, i) => `<li data-j="${i}">${i === 0 ? glyph(KIND_ICONS[st.target.kind] ?? 'object') : glyph('group')}<span>${esc(n)}</span></li>`).join('')}</ol>` : '';
      content = `${statChips([
          { label: 'groupes', value: num(r.rows.length), icon: 'group', tone: 'info' },
          { label: 'directs', value: num(r.direct), tone: 'off' },
          { label: 'par imbrication', value: num(r.nested), tone: 'off' },
          { label: 'profondeur maximale', value: num(r.maxDepth), tone: 'off' },
          { label: 'privilégiés', value: num(r.privileged), icon: 'star', tone: r.privileged ? 'warn' : 'off' },
          { label: r.cycles.length > 1 ? 'cycles' : 'cycle', value: num(r.cycles.length), icon: 'sync', tone: r.cycles.length ? 'alert' : 'off' },
        ])}
        <div class="aud-groups-grid">
          <div class="card aud-graph-card"><div class="card-head"><span class="card-icon">${glyph('split')}</span><h3>Graphe des imbrications</h3>
            <span class="meta">${glyph('star')}privilégié · ${glyph('sync')}cycle</span></div><div class="aud-graph-host"></div></div>
          <div class="card aud-why"><div class="card-head"><span class="card-icon">${glyph('search')}</span><h3>Pourquoi membre de ce groupe ?</h3></div>
            <label class="k-select"><select class="input" data-group-pick aria-label="Groupe à expliquer"><option value="">Choisir un groupe…</option>
              ${choices.map((c) => `<option value="${esc(c.dn)}"${c.dn === st.groupPick ? ' selected' : ''}>${esc(c.label)}</option>`).join('')}</select></label>
            <div class="aud-why-body">${m ? `${path}<div class="aud-why-text" data-tone="${m.member === true ? 'ok' : m.member === false ? 'warn' : 'off'}">${m.text.split('\n').map((l) => `<p>${esc(l)}</p>`).join('')}</div>`
              : '<p class="aud-muted">Choisissez un groupe dans la liste ou cliquez sur une case du graphe : le chemin est calculé sur les appartenances lues, sans nouvelle lecture.</p>'}</div>
            <div class="aud-why-actions">${button('membership', 'Confirmer sur le contrôleur', { iconName: 'shield', primary: false, disabled: !st.groupPick, reason: st.groupPick ? '' : 'Choisissez d’abord un groupe.' })}</div>
          </div>
        </div>
        ${statusMarkup(r.summary, r.truncated ? 'warn' : 'info')}
        <div class="aud-grid-host" data-grid="groups"></div>
        <p class="aud-foot-note">Lu sur ${esc(r.controller)} ${when(r.readAt)} en ${num(r.elapsedMs)} ms.</p>`;
    }
    p.innerHTML = `<div class="aud-view">${head('Groupes imbriqués et cycles', 'Appartenances directes et imbriquées, groupe principal (absent de memberOf), groupes non lus et cycles.',
      button('groups', r ? 'Relire les appartenances' : 'Lire les appartenances imbriquées', { iconName: 'group' }))}<div class="aud-view-body">${content}</div></div>`;
    if (r) {
      graph = renderGraph(p.querySelector('.aud-graph-host'), r.graph, {
        label: `Appartenances de ${st.target.name}`,
        onPick: (id) => {
          const row = r.rows.find((g) => g.dn.toLowerCase() === id) ?? (r.primaryGroup?.dn?.toLowerCase() === id ? { dn: r.primaryGroup.dn } : null);
          if (row) pickGroup(row.dn);
        },
      });
      viewGrid('groups', p.querySelector('[data-grid="groups"]'), {
        key: 'audit.groupes.v2', label: 'Groupes de l’objet', rowId: (g) => g.dn, selection: 'single',
        columns: [
          { id: 'name', label: 'Groupe', required: true, width: 240 },
          { id: 'depth', label: 'Profondeur', type: 'number', width: 132 },
          { id: 'via', label: 'Arrive par', width: 220 },
          { id: 'state', label: 'État de lecture', width: 210, html: (v, g) => tonePill(g.tone, v, { fit: true }) },
          { id: 'cycle', label: 'Cycle', type: 'bool', width: 100 },
          { id: 'privileged', label: 'Privilégié', type: 'bool', width: 130 },
          { id: 'path', label: 'Chemin', width: 320, hidden: true, get: (g) => g.path.join(' → ') },
          { id: 'dn', label: 'Chemin (DN)', mono: true, hidden: true, width: 360 },
        ],
        onActivate: (g) => pickGroup(g.dn),
        contextMenu: ({ row }) => [
          { label: 'Pourquoi membre ?', icon: 'search', disabled: !row, run: () => pickGroup(row.dn) },
          { label: 'Auditer ce groupe', icon: 'shield', disabled: !row, run: () => setTarget(row.dn) },
        ],
      }, r.rows, 420);
      if (st.groupPick) graph.highlight(st.groupPick.toLowerCase());
    }
  }

  async function pickGroup(dn) {
    st.groupPick = dn || null;
    st.membership = null;
    if (!dn) { repaint(); return; }
    const token = app.guard.next('object:groupPath');
    try {
      const m = await app.ctx.call('audit.object.groupPath', { dn: dnOf(), groupDn: dn });
      if (!app.alive() || !app.guard.current(token)) return;
      st.membership = m;
    } catch (err) {
      if (!app.alive() || !app.guard.current(token)) return;
      st.membership = { text: reported(err), path: [], member: null };
    }
    repaint();
    views.get('groupes')?.querySelector('.aud-why')?.scrollIntoView({ block: 'nearest' });
  }

  // ----- Délégations (AUD-021, AUD-014, AUD-015)

  function estimatePanel(r) {
    const e = st.estimate;
    const selected = r.rows.find((x) => x.sid === st.sid);
    const tokenBusy = st.busy.has('tokenGroups');
    return `<aside class="card aud-estimate" aria-live="polite">
            <div class="card-head"><span class="card-icon">${glyph('gauge')}</span><div><h3>Estimation pour le bénéficiaire</h3>
              <p class="aud-sub">${selected ? esc(selected.trustee) : 'Sélectionnez une entrée'}</p></div></div>
            ${e ? `<ul class="aud-rights" role="list">${e.rows.map((x, n) => `<li data-tone="${RESULT_TONES[x.result]}" data-i="${n}"><span class="aud-right-mark">${glyph(x.result === 'allowed' ? 'check' : x.result === 'denied' ? 'x' : x.result === 'partial' ? 'minus' : 'dot')}</span>
                <div><b>${esc(x.label)}</b><span>${esc(x.resultLabel)}</span>${x.decidedBy ? `<small>${esc(x.decidedBy)}</small>` : ''}</div></li>`).join('')}</ul>
              <p class="aud-note">${esc(e.summary)} ${esc(e.limits)}</p>`
              : '<p class="aud-muted">Choisissez une entrée de la liste : neuf droits sont estimés sur les entrées lues, refus d’abord, sans relire l’annuaire.</p>'}
            <div class="aud-estimate-actions">${button('tokenGroups', tokenBusy ? 'Lecture des groupes…' : 'Inclure ses groupes', {
              iconName: 'group', primary: false,
              disabled: !selected || !selected.domainAccount,
              reason: !selected ? 'Choisissez d’abord une entrée.' : !selected.domainAccount ? 'Les groupes se lisent pour un compte ou un groupe d’un domaine, pas pour une identité intégrée.' : 'Lit les groupes de sécurité du bénéficiaire (tokenGroups) : une lecture LDAP.',
            })}${e?.includesGroups ? tonePill('ok', `${num(e.groupCount)} groupes inclus`, { icon: 'check' }) : ''}</div>
          </aside>`;
  }

  function aclColumns() {
    return [
      // The quick filter of the grid reads the display text: the SID and the objects aimed at are searched even when their
      // columns are folded, as Domenia 1 Select-DomeniaDelegationRows (trustee, SID, rights, target, objects).
      { id: 'trustee', label: 'Bénéficiaire', required: true, width: 220, format: (v, x) => `${x.trustee} ${x.sid}`, html: (v, x) => `<span data-tip="${esc(`${x.trustee} · ${x.sid}`)}">${esc(x.trustee)}</span>`, csv: (v, x) => x.trustee },
      { id: 'risk', label: 'À examiner', width: 160, tip: 'Réplication de l’annuaire hors administrateurs, écriture large accordée à tous les comptes',
        get: (x) => x.riskLabel ?? x.risk ?? '', csv: (v, x) => x.risk ?? '',
        html: (v, x) => (x.risk ? tonePill('alert', x.riskLabel ?? x.risk, { icon: 'alert', fit: true, tip: x.risk }) : '<span class="aud-none">—</span>'), sortKey: (v, x) => (x.risk ? 0 : 1) },
      { id: 'type', label: 'Type', width: 112, type: 'enum', options: [{ value: 'Autorisation', label: 'Autorisation', tone: 'ok' }, { value: 'Refus', label: 'Refus', tone: 'alert' }] },
      { id: 'rights', label: 'Droits', width: 180 },
      { id: 'target', label: 'Cible', width: 150, format: (v, x) => `${x.target} ${x.appliesTo}`, html: (v, x) => `<span data-tip="${esc(x.target)}">${esc(x.target)}</span>`, csv: (v, x) => x.target },
      { id: 'appliesTo', label: 'S’applique à', width: 150, hidden: true },
      { id: 'origin', label: 'Origine', width: 110 },
      { id: 'scope', label: 'Portée', width: 180, hidden: true },
      { id: 'sid', label: 'SID', mono: true, hidden: true, width: 260 },
    ];
  }

  function viewAcl(p) {
    const r = st.results.acl;
    const idle = emptyMarkup({ icon: 'lock', title: 'Délégations non lues', text: 'Lit le propriétaire et la liste de contrôle d’accès de l’objet (1 000 entrées au plus, sans SACL), sans rien modifier.', tone: 'off' });
    let content = bodyFor('acl', idle);
    if (!content) {
      const risky = r.rows.filter((x) => x.risk).length;
      content = `${statChips([
          { label: 'entrées', value: num(r.total), icon: 'rows', tone: 'info' },
          { label: 'posées sur l’objet', value: num(r.explicit), tone: 'off' },
          { label: 'héritées', value: num(r.inherited), tone: 'off' },
          { label: 'refus', value: num(r.deny), icon: 'x', tone: r.deny ? 'warn' : 'off' },
          { label: 'à examiner', value: num(risky), icon: 'alert', tone: risky ? 'alert' : 'off' },
          r.protected ? { label: 'héritage désactivé', value: '!', icon: 'lock', tone: 'warn' } : null,
        ])}
        ${statusMarkup(r.summary, r.state === 'read' ? 'info' : 'warn')}
        <div class="aud-acl-tools">
          <label class="aud-switch"><input class="switch" type="checkbox" data-acl-explicit${st.aclExplicit ? ' checked' : ''}><span>Entrées posées sur l’objet seulement</span></label>
          <span class="aud-muted">Le filtre rapide de la liste cherche dans le bénéficiaire, le SID, les droits, la cible et les objets visés, même quand leurs colonnes sont repliées.</span>
        </div>
        <div class="aud-acl-split">
          <div class="aud-grid-host" data-grid="acl"></div>
          ${estimatePanel(r)}
        </div>
        <p class="aud-foot-note">Lu sur ${esc(r.controller)} ${when(r.readAt)}. ${esc(r.limit)}</p>`;
    }
    p.innerHTML = `<div class="aud-view">${head('Délégations de l’objet', 'Propriétaire et entrées de la liste de contrôle d’accès : bénéficiaire, droits en français, cible, origine et portée.',
      button('acl', r ? 'Relire les délégations' : 'Lire les délégations', { iconName: 'lock' }))}<div class="aud-view-body">${content}</div></div>`;
    if (r) {
      const grid = viewGrid('acl', p.querySelector('[data-grid="acl"]'), {
        key: 'audit.delegations.v2', label: 'Entrées de la liste de contrôle d’accès', rowId: (x) => String(x.index), selection: 'single',
        columns: aclColumns(),
        empty: { icon: 'filter', title: 'Aucune entrée', text: 'Aucune entrée ne correspond au filtre : rien n’est relu.' },
        onSelectionChange: (rows) => { if (rows[0]) chooseTrustee(rows[0].sid); },
      }, explicitAces(r), 460);
      if (st.sid) {
        const first = r.rows.find((x) => x.sid === st.sid);
        if (first) grid.select([String(first.index)]);
      }
    }
  }

  /** « Posées sur l’objet seulement » (ChkAdAuditAclExplicit); the text filter is the quick filter of the grid (TxtAdAuditAclFilter). */
  const explicitAces = (r) => r.rows.filter((x) => !st.aclExplicit || x.explicit);

  async function chooseTrustee(sid) {
    if (!sid || sid === st.sid) return;
    st.sid = sid;
    st.estimate = null;
    const token = app.guard.next('object:estimate');
    try {
      const e = await app.ctx.call('audit.object.estimate', { dn: dnOf(), sid });
      if (!app.alive() || !app.guard.current(token)) return;
      st.estimate = e;
    } catch (err) {
      if (!app.alive() || !app.guard.current(token)) return;
      app.toast(reported(err), { tone: 'warn' });
    }
    updateEstimate();
  }

  // The estimate panel is refreshed alone: the grid keeps its scroll and selection.
  function updateEstimate() {
    const p = views.get('delegations');
    const old = p?.querySelector('.aud-estimate');
    if (!old || !st.results.acl) return;
    const tmp = document.createElement('div');
    tmp.innerHTML = estimatePanel(st.results.acl);
    const fresh = tmp.firstElementChild;
    old.replaceWith(fresh);
    paint(fresh);
  }

  // ----- Stratégies de groupe (AUD-016, AUD-017)

  function ladderMarkup(r) {
    const byContainer = new Map(r.chain.map((dn) => [dn.toLowerCase(), []]));
    r.rows.forEach((g) => { if (g.linkedToDn) byContainer.get(g.linkedToDn.toLowerCase())?.push(g); });
    const outside = r.rows.filter((g) => !g.linkedToDn);
    const chip = (g) => `<span class="aud-gpo-chip" data-tone="${esc(g.tone)}" data-tip="${esc(`${g.result} · ${g.inheritance}`)}">${g.enforced === 'Oui' ? glyph('pin') : ''}${g.link === 'Désactivé' ? '<s>' : ''}${esc(g.name)}${g.link === 'Désactivé' ? '</s>' : ''}</span>`;
    const levels = r.chain.map((dn, n) => {
      const gpos = byContainer.get(dn.toLowerCase()) ?? [];
      const domain = dn.toUpperCase().startsWith('DC=');
      const name = domain ? 'Domaine' : dn.split(/(?<!\\),/)[0].replace(/^OU=/i, '').replace(/\\(.)/g, '$1');
      return `<li class="aud-rung" data-j="${n}"><div class="aud-rung-head">${glyph(domain ? 'domain' : 'ou')}<b>${esc(name)}</b><small>${n === 0 ? 'au plus près' : ''}</small></div>
        <div class="aud-rung-gpos">${gpos.map(chip).join('') || '<span class="aud-muted">Aucun lien</span>'}</div></li>`;
    }).join('');
    const extra = outside.length ? `<li class="aud-rung site"><div class="aud-rung-head">${glyph('domain')}<b>Hors liens lus</b><small>site, stratégie locale</small></div>
      <div class="aud-rung-gpos">${outside.map(chip).join('')}</div></li>` : '';
    return `<ol class="aud-ladder">${levels}${extra}</ol>`;
  }

  function gpoColumns() {
    return [
      { id: 'name', label: 'GPO', required: true, width: 220 },
      { id: 'result', label: 'Résultat sur le poste', width: 280, html: (v, g) => tonePill(g.tone, v, { fit: true }) },
      { id: 'linkedTo', label: 'Liée à', width: 130 },
      { id: 'link', label: 'Lien', width: 100 },
      { id: 'enforced', label: 'Forcée', width: 100 },
      { id: 'expected', label: 'Attendue', width: 120, tip: 'Attendue par les liens lus dans l’annuaire' },
      { id: 'inheritance', label: 'Héritage', width: 150 },
      { id: 'gpoStatus', label: 'État de la GPO', width: 150 },
      { id: 'guid', label: 'GUID', mono: true, hidden: true, width: 300 },
    ];
  }

  function viewGpo(p) {
    const r = st.results.gpo;
    const isComputer = avail('gpoApplied').allowed;
    const idle = emptyMarkup({ icon: 'layers', title: 'Liens GPO non lus', text: 'Lit gPLink et gPOptions de chaque OU au-dessus de l’objet et du domaine, puis le nom et l’état des GPO. Pour un poste, le résultat appliqué se lit à part (RSoP).', tone: 'off' });
    let content = bodyFor('gpo', idle);
    if (!content) {
      const applied = r.rows.filter((g) => g.outcome === 'applied').length;
      content = `${statChips([
          { label: 'liens lus', value: num(r.rows.filter((g) => g.linkedToDn).length), icon: 'link', tone: 'info' },
          { label: 'conteneurs', value: num(r.chain.length), tone: 'off' },
          { label: 'appliquées selon RSoP', value: r.appliedProven ? num(applied) : '—', icon: 'check', tone: r.appliedProven ? 'ok' : 'off' },
          { label: 'filtrées', value: num(r.rows.filter((g) => g.outcome === 'filtered').length), tone: 'off' },
        ])}
        ${statusMarkup(r.summary, r.appliedProven ? 'ok' : 'info')}
        <div class="aud-gpo-grid"><div class="card aud-ladder-card"><div class="card-head"><span class="card-icon">${glyph('layers')}</span><h3>Chaîne des liens</h3>
          <span class="meta">${glyph('pin')}forcée · <s>désactivé</s></span></div>${ladderMarkup(r)}</div>
          <div class="card aud-gpo-facts"><div class="card-head"><span class="card-icon">${glyph('info')}</span><h3>Ce qui a été lu</h3></div>${factsMarkup(r.facts, { compact: true })}</div></div>
        <div class="aud-grid-host" data-grid="gpo"></div>`;
    }
    const buttons = button('gpoLinks', r?.linksRead ? 'Relire les liens GPO' : 'Lire les liens GPO', { iconName: 'layers', primary: !isComputer || !r?.linksRead })
      + (isComputer ? button('gpoApplied', 'Lire le résultat sur le poste', { iconName: 'monitor', primary: Boolean(r?.linksRead) }) : '');
    p.innerHTML = `<div class="aud-view">${head('Stratégies de groupe', 'GPO liées dans l’annuaire et résultat appliqué sur le poste, présentés séparément : un lien ne prouve pas l’application.', buttons)}
      <div class="aud-view-body">${content}</div></div>`;
    if (r) {
      viewGrid('gpo', p.querySelector('[data-grid="gpo"]'), {
        key: 'audit.gpo.v2', label: 'Liens GPO et résultat', rowId: (g) => `${g.guid}|${g.linkedToDn}`, selection: 'none', columns: gpoColumns(),
      }, r.rows, 420);
    }
  }

  // ----- Identité du poste (AUD-018)

  function viewIdentity(p) {
    const r = st.results.machineIdentity;
    const idle = emptyMarkup({ icon: 'monitor', title: 'Identité non vérifiée', text: 'Résout le nom DNS depuis ce poste, lit le nom inverse et interroge le poste par CIM (Win32_ComputerSystem). Rien n’est attribué, fusionné ni renommé.', tone: 'off' });
    let content = bodyFor('machineIdentity', idle);
    if (!content) {
      const fact = (id) => r.facts.find((f) => f.id === id);
      const side = (title, iconName, f, extra = '') => `<div class="card aud-id-side" data-tone="${f?.state === 'observed' ? 'ok' : 'off'}">
        <span class="aud-id-ico">${glyph(iconName)}</span><h4>${esc(title)}</h4><b class="mono">${esc(f?.value ?? '—')}</b><small>${esc(f?.source ?? '')}</small>${extra}</div>`;
      const reverse = fact('dnsReverse');
      const reverseLine = reverse ? `<p class="aud-id-extra" data-state="${esc(reverse.state)}">${glyph('sync')}<span>Nom inverse : <b class="mono">${esc(reverse.value)}</b></span></p>` : '';
      content = `<div class="aud-verdict" data-tone="${esc(r.tone)}"><span class="aud-verdict-ico">${icon(r.state === 'coherent' ? 'check' : r.state === 'incoherent' ? 'alert' : 'eye')}</span>
          <div><b>${esc(r.stateLabel)}</b><p>${esc(r.summary)}</p></div></div>
        <div class="aud-id-sides">${side('Annuaire', 'database', fact('adName'))}<span class="aud-id-link" aria-hidden="true">${glyph('link')}</span>
          ${side('DNS', 'domain', fact('dnsForward'), reverseLine)}<span class="aud-id-link" aria-hidden="true">${glyph('link')}</span>
          ${side('Poste', 'monitor', fact('reported'))}</div>
        ${r.reasons.length ? `<ul class="aud-reasons" role="list">${r.reasons.map((x) => `<li>${glyph('alert')}${esc(x)}</li>`).join('')}</ul>` : ''}
        ${r.warnings.length ? `<ul class="aud-reasons warn" role="list">${r.warnings.map((x) => `<li>${glyph('eye')}À vérifier : ${esc(x)}</li>`).join('')}</ul>` : ''}
        <details class="aud-more"><summary>${glyph('chevronRight')}Faits détaillés, avec leur source et leur limite (${num(r.facts.length)})</summary>${factsMarkup(r.facts, { compact: true })}</details>
        <p class="aud-foot-note">Lu ${when(r.readAt)}. Rien n’est attribué ni fusionné par cette vérification.</p>`;
    }
    p.innerHTML = `<div class="aud-view">${head('Identité du poste', 'Nom dans l’annuaire, résolution DNS (directe et inverse) et identité renvoyée par le poste, chacun avec sa source.',
      button('machineIdentity', r ? 'Vérifier de nouveau' : 'Vérifier l’identité du poste', { iconName: 'monitor' }))}<div class="aud-view-body">${content}</div></div>`;
  }

  // ----- Postes et utilisateurs (AUD-019, AUD-020)

  const HISTORY_TONES = { declared: 'accent', observed: 'ok', history: 'info', imported: 'warn', clue: 'off' };

  function viewRelations(p) {
    const rel = st.results.relations;
    const hist = st.results.history;
    const relContent = !rel ? skeletonMarkup(3) : !rel.applicable || !rel.lines.length ? `<p class="aud-muted">${esc(rel.text)}</p>`
      : `<ul class="aud-rel-lines" role="list">${rel.lines.map((l, n) => `<li data-badge="${esc(l.badge)}" data-i="${n}"><span class="aud-badge" data-tip="${esc(l.rule)}">${esc(l.badgeLabel)}</span>
          <div><b>${esc(l.fact)}</b><span>${esc(l.value)}</span></div></li>`).join('')}</ul>`;
    let histContent;
    if (st.busy.has('history') && !hist) histContent = skeletonMarkup(5);
    else if (st.errors.history && !hist) histContent = statusMarkup(st.errors.history, 'alert');
    else if (!hist) histContent = '<p class="aud-muted">Historique non lu : lecture de la base locale de Domenia (200 lignes au plus), sans lecture réseau.</p>';
    else if (!hist.rows.length) histContent = statusMarkup(hist.summary, 'off');
    else {
      const sources = [...new Set(hist.rows.map((r) => r.source))];
      if (st.historySource && !sources.includes(st.historySource)) st.historySource = null;
      const rows = hist.rows.filter((r) => !st.historySource || r.source === st.historySource);
      histContent = `${statusMarkup(hist.summary, hist.state === 'read' ? 'info' : 'off')}
        ${sources.length > 1 ? `<div class="aud-cat-chips" role="group" aria-label="Filtrer par source">${sources.map((s) => `<button type="button" class="chip aud-cat-chip" data-hsource="${esc(s)}" aria-pressed="${st.historySource === s}">${esc(s)}</button>`).join('')}</div>` : ''}
        ${timeline(rows.filter((r) => r.at).map((r) => ({
          when: r.at, title: `${r.user} · ${r.computer}`, text: r.details || r.source, tone: HISTORY_TONES[r.badge] ?? 'info', icon: r.badge === 'observed' ? 'eye' : r.badge === 'declared' ? 'pin' : 'history',
          meta: `${r.nature}${r.verifiedInAd ? ` · vérifié dans AD : ${r.verifiedInAd}` : ''}`,
        })), { label: 'Historique des associations', empty: 'Aucune association enregistrée pour cette source.' })}`;
    }
    p.innerHTML = `<div class="aud-view">${head('Postes et utilisateurs', 'Affectation déclarée, dernière session observée et historique enregistré, chacun avec son origine et sa date. Une observation ne vaut pas affectation.',
      button('history', hist ? 'Relire l’historique' : 'Lire l’historique enregistré', { iconName: 'history', net: false, primary: true, reason: 'Base locale de Domenia : aucune lecture réseau.' }))}
      <div class="aud-view-body"><div class="aud-rel-grid"><div class="card aud-rel-card"><div class="card-head"><span class="card-icon">${glyph('link')}</span><h3>Synthèse des associations</h3><span class="meta">mémoire locale</span></div>${relContent}</div>
        <div class="card aud-hist-card"><div class="card-head"><span class="card-icon">${glyph('history')}</span><h3>Historique enregistré</h3><span class="meta">base locale de Domenia</span></div>${histContent}</div></div></div></div>`;
    bindTimeline(p);
  }

  // ---------- Reads ----------

  const OPS = {
    policy: 'audit.object.policy', groups: 'audit.object.groups', acl: 'audit.object.acl', gpoLinks: 'audit.object.gpoLinks', gpoApplied: 'audit.object.gpoApplied',
    machineIdentity: 'audit.object.machineIdentity', history: 'audit.object.history',
  };
  const RESULT_KEY = { gpoLinks: 'gpo', gpoApplied: 'gpo' };
  const VIEW_OF = { policy: 'motdepasse', groups: 'groupes', acl: 'delegations', gpoLinks: 'gpo', gpoApplied: 'gpo', machineIdentity: 'poste', history: 'relations', membership: 'groupes', tokenGroups: 'delegations' };

  async function read(action) {
    if (!st.target || st.busy.has(action)) return;
    const key = RESULT_KEY[action] ?? action;
    const dn = dnOf();
    const token = app.guard.next(`object:${action}`);
    st.busy.set(action, token);
    delete st.errors[key];
    app.busy(action, true);
    // The groups of a trustee refresh the estimate panel alone: the grid keeps its scroll and its selection.
    if (action === 'tokenGroups') updateEstimate(); else paintView(VIEW_OF[action]);
    try {
      let result;
      if (action === 'membership') result = await app.ctx.call('audit.object.membership', { dn, groupDn: st.groupPick });
      else if (action === 'tokenGroups') result = await app.ctx.call('audit.object.tokenGroups', { dn, sid: st.sid });
      else if (action === 'history') result = await app.ctx.call(OPS.history, { dn, limit: null });
      else result = await app.ctx.call(OPS[action], { dn });
      if (!app.alive() || !app.guard.current(token) || dnOf() !== dn) return;
      if (action === 'membership') st.membership = result;
      else if (action === 'tokenGroups') st.estimate = result;
      else {
        st.results[key] = result;
        if (action === 'acl') { st.sid = null; st.estimate = null; }
        if (action === 'groups') { st.membership = null; st.groupPick = null; }
      }
      app.announce(`${VIEWS.find((v) => v.id === VIEW_OF[action])?.label ?? 'Lecture'} : lecture terminée.`);
    } catch (err) {
      if (!app.alive() || !app.guard.current(token)) return;
      const text = reported(err);
      st.errors[key] = text;
      app.toast(text, { tone: err?.code === 'audit.notApplicable' ? 'warn' : 'alert' });
    } finally {
      // The busy state belongs to this read only: a newer target (or a newer read of the same kind) owns it otherwise.
      if (app.alive() && st.busy.get(action) === token) {
        st.busy.delete(action);
        app.busy(action, false);
        if (app.guard.current(token)) {
          if (action === 'tokenGroups') updateEstimate(); else paintView(VIEW_OF[action]);
        }
      }
    }
  }

  async function runRelations() {
    if (!st.target || st.busy.has('relations')) return;
    const dn = dnOf();
    const token = app.guard.next('object:relations');
    st.busy.set('relations', token);
    try {
      const rel = await app.ctx.call('audit.object.relations', { dn });
      if (!app.alive() || !app.guard.current(token) || dnOf() !== dn) return;
      st.results.relations = rel;
    } catch (err) {
      if (!app.alive() || !app.guard.current(token)) return;
      st.results.relations = { applicable: false, text: reported(err), lines: [] };
    } finally {
      if (app.alive() && st.busy.get('relations') === token) {
        st.busy.delete('relations');
        if (app.guard.current(token)) paintView('relations');
      }
    }
  }

  async function runView(id) {
    const action = { motdepasse: 'policy', groupes: 'groups', delegations: 'acl', gpo: 'gpoLinks', poste: 'machineIdentity', relations: 'history' }[id];
    if (!action || !avail(VIEWS.find((v) => v.id === id).avail).allowed) return;
    const dn = dnOf();
    await read(action);
    if (!app.alive() || dnOf() !== dn) return;
    // A group named by the address (?groupe=<DN>) is explained at once, from the memberships just read (no new read).
    if (action === 'groups' && app.params.groupe && st.results.groups) await pickGroup(app.params.groupe);
    // Group policy of a workstation: the links, then the result applied on it, as the two buttons in a row.
    if (action === 'gpoLinks' && avail('gpoApplied').allowed && st.results.gpo) await read('gpoApplied');
  }

  function retake() {
    const sel = app.selection();
    if (!sel) return;
    // Domenia 1 Sync-DomeniaAdAuditTarget -Force: the same object keeps its results and only says so.
    if (st.target && sameDn(sel.dn, st.target.dn)) {
      app.toast(sel.source === 'subject' ? 'La cible est déjà l’objet choisi dans Rechercher.' : 'La cible est déjà l’objet de la fiche ouverte.', { tone: 'info' });
      return;
    }
    setTarget(sel.dn, { keepView: true });
  }

  // ---------- Events ----------

  const onClick = (e) => {
    const t = e.target instanceof Element ? e.target : null;
    if (!t) return;
    const pick = t.closest('[data-pick]');
    if (pick) { e.preventDefault(); st.hits = []; renderHits(); setTarget(pick.dataset.pick); return; }
    const act = t.closest('[data-act]');
    if (act) {
      if (act.getAttribute('aria-disabled') === 'true') return;
      read(act.dataset.act);
      return;
    }
    if (t.closest('[data-fiche]') && st.target) { app.ctx.navigate('fiche', { dn: st.target.dn }); return; }
    const again = t.closest('[data-retake]');
    if (again) {
      if (again.getAttribute('aria-disabled') !== 'true') retake();
      return;
    }
    const hs = t.closest('[data-hsource]');
    if (hs) { st.historySource = st.historySource === hs.dataset.hsource ? null : hs.dataset.hsource; paintView('relations'); }
  };
  const onChange = (e) => {
    const t = e.target;
    if (t instanceof HTMLSelectElement && t.matches('[data-group-pick]')) pickGroup(t.value);
    if (t instanceof HTMLInputElement && t.matches('[data-acl-explicit]') && st.results.acl) {
      st.aclExplicit = t.checked;
      const grid = viewGrids.get('acl');
      grid?.setRows(explicitAces(st.results.acl), { keepSelection: true });
    }
  };
  // The session selection changed (subject chosen or cleared in Rechercher): the button and the suggestions say it.
  const onSubject = () => {
    if (!app.alive()) return;
    const btn = targetHost.querySelector('[data-retake]');
    if (btn) {
      const tmp = document.createElement('div');
      tmp.innerHTML = retakeButton();
      btn.replaceWith(tmp.firstElementChild);
    }
    if (st.suggestions) renderSuggestions();
  };
  panel.addEventListener('click', onClick);
  panel.addEventListener('change', onChange);
  window.addEventListener('domenia:subject', onSubject);
  cleanups.push(() => {
    panel.removeEventListener('click', onClick);
    panel.removeEventListener('change', onChange);
    window.removeEventListener('domenia:subject', onSubject);
  });

  renderTarget();
  renderMain();
  renderSuggestions();
  loadSuggestions();

  const factColumns = () => [
    { label: 'Élément', get: (f) => f.label }, { label: 'Valeur', get: (f) => f.value }, { label: 'État', get: (f) => f.stateLabel },
    { label: 'Source', get: (f) => f.source ?? '' }, { label: 'Limite', get: (f) => f.limit ?? '' },
  ];
  const groupColumns = () => [
    { label: 'Groupe', get: (g) => g.name }, { label: 'Profondeur', get: (g) => g.depth }, { label: 'Arrive par', get: (g) => g.via },
    { label: 'État de lecture', get: (g) => g.state }, { label: 'Cycle', get: (g) => (g.cycle ? 'Oui' : '') }, { label: 'Privilégié', get: (g) => (g.privileged ? 'Oui' : '') },
    { label: 'Chemin (DN)', get: (g) => g.dn },
  ];
  const aceColumns = () => [
    { label: 'Bénéficiaire', get: (x) => x.trustee }, { label: 'À examiner', get: (x) => x.risk ?? '' }, { label: 'Type', get: (x) => x.type }, { label: 'Droits', get: (x) => x.rights },
    { label: 'Cible', get: (x) => x.target }, { label: 'S’applique à', get: (x) => x.appliesTo }, { label: 'Origine', get: (x) => x.origin }, { label: 'Portée', get: (x) => x.scope }, { label: 'SID', get: (x) => x.sid },
  ];
  const gpoCopyColumns = () => [
    { label: 'GPO', get: (g) => g.name }, { label: 'Résultat sur le poste', get: (g) => g.result }, { label: 'Liée à', get: (g) => g.linkedTo }, { label: 'Lien', get: (g) => g.link },
    { label: 'Forcée', get: (g) => g.enforced }, { label: 'Attendue par les liens', get: (g) => g.expected }, { label: 'Héritage', get: (g) => g.inheritance }, { label: 'État de la GPO', get: (g) => g.gpoStatus },
  ];
  const historyColumns = () => [
    { label: 'Date', get: (h) => h.dateLabel }, { label: 'Utilisateur', get: (h) => h.user }, { label: 'Poste', get: (h) => h.computer }, { label: 'Nature', get: (h) => h.nature },
    { label: 'Source', get: (h) => h.source }, { label: 'Vérifié dans AD', get: (h) => h.verifiedInAd }, { label: 'Détails', get: (h) => h.details },
  ];
  const historyRows = () => (st.results.history?.rows ?? []).filter((r) => !st.historySource || r.source === st.historySource);

  return {
    setTarget,
    runView: () => runView(st.view),
    target: () => st.target,
    /**
     * Sections for « Copier la vue »: the target, then what the current view shows, rows as the grids display them (filters,
     * sort; Domenia 1 Copy-DomeniaAdAuditView, Get-DomeniaAdAuditGridSection).
     */
    sections() {
      const t = st.target;
      if (!t) return [{ title: 'Objet', summary: 'Aucun objet choisi : rien à copier.' }];
      const out = [{ title: `${t.kindLabel} · ${t.name}`, summary: t.dn }];
      const r = st.results;
      switch (st.view) {
        case 'motdepasse':
          if (r.policy) out.push({ title: 'Stratégie de mot de passe', summary: r.policy.summary, columns: factColumns(), rows: r.policy.facts });
          break;
        case 'groupes':
          if (r.groups) {
            out.push({ title: 'Groupes imbriqués', summary: r.groups.summary, columns: groupColumns(), rows: shownRows('groups', r.groups.rows) });
            if (st.membership) out.push({ title: 'Pourquoi membre ?', summary: st.membership.text });
          }
          break;
        case 'delegations':
          if (r.acl) {
            out.push({ title: 'Délégations', summary: `${r.acl.summary}\n${r.acl.limit}`, columns: aceColumns(), rows: shownRows('acl', explicitAces(r.acl)) });
            if (st.estimate) out.push({ title: `Estimation · ${st.estimate.trustee}`, summary: st.estimate.limits, columns: [
              { label: 'Droit', get: (x) => x.label }, { label: 'Résultat estimé', get: (x) => x.resultLabel }, { label: 'Décidé par', get: (x) => x.decidedBy ?? '' },
            ], rows: st.estimate.rows });
          }
          break;
        case 'gpo':
          if (r.gpo) out.push({ title: 'Stratégies de groupe', summary: r.gpo.summary, columns: gpoCopyColumns(), rows: shownRows('gpo', r.gpo.rows) }, { title: 'Ce qui a été lu', columns: factColumns(), rows: r.gpo.facts });
          break;
        case 'poste':
          if (r.machineIdentity) out.push({ title: 'Identité du poste', summary: [r.machineIdentity.summary, ...r.machineIdentity.reasons.map((x) => `• ${x}`), ...r.machineIdentity.warnings.map((x) => `À vérifier : ${x}`)].join('\n'), columns: factColumns(), rows: r.machineIdentity.facts });
          break;
        case 'relations':
          if (r.relations) out.push({ title: 'Synthèse des associations', summary: r.relations.text, columns: [{ label: 'Élément', get: (l) => l.fact }, { label: 'Valeur', get: (l) => l.value }, { label: 'Nature', get: (l) => l.badgeLabel }], rows: r.relations.lines ?? [] });
          if (r.history) out.push({ title: 'Historique enregistré', summary: r.history.summary, columns: historyColumns(), rows: historyRows() });
          break;
        default:
      }
      if (out.length === 1) out.push({ summary: 'Lecture non faite pour cette vue : rien d’autre à copier.' });
      return out;
    },
    /** Main table of the current view, rows as displayed, for « Exporter › Tableau de la vue ». */
    table() {
      const t = st.target;
      const r = st.results;
      if (!t) return null;
      const name = `${t.name}-${VIEWS.find((v) => v.id === st.view)?.label ?? ''}`;
      switch (st.view) {
        case 'motdepasse': return r.policy ? { name, columns: factColumns(), rows: r.policy.facts } : null;
        case 'groupes': return r.groups ? { name, columns: groupColumns(), rows: shownRows('groups', r.groups.rows) } : null;
        case 'delegations': return r.acl ? { name, columns: aceColumns(), rows: shownRows('acl', explicitAces(r.acl)) } : null;
        case 'gpo': return r.gpo ? { name, columns: gpoCopyColumns(), rows: shownRows('gpo', r.gpo.rows) } : null;
        case 'poste': return r.machineIdentity ? { name, columns: factColumns(), rows: r.machineIdentity.facts } : null;
        case 'relations': return r.history ? { name, columns: historyColumns(), rows: historyRows() } : null;
        default: return null;
      }
    },
    destroy() {
      dropObjectReads();
      destroyViewParts();
      tabs?.destroy();
      crumb?.destroy?.();
      cleanups.forEach((fn) => fn());
    },
  };
}
