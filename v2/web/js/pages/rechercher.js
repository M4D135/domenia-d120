// Rechercher: universal search space of Domenia 2 (docs/ops/rechercher.md). A large bar with suggestions and syntax, the
// OU tree with pinned favourites on the left, the virtual result grid in the middle (three column sets, quick filters,
// criteria chips, explicit continuation), the side preview of the selected object on the right; ready-made views and
// local queries, personal views, back / forward history, surveys of the list, network diagnostic, comparison, copies for a
// ticket, exports. Nothing is read without a gesture: typing never reads the directory, Entrée or a click does.
// Route parameters (captures, links of other screens): q, portee, type, match, ou, sousou, vue, domaine, requete,
// verdict, sel, ouvrir (requetes | vues | syntaxe | comparer | releve | menu | diag | historique).
import { glyph } from '../kit/glyphs.js';
import { createCommandBar } from '../kit/commandbar.js';
import { openMenu } from '../kit/menu.js';
import { isTextEntry } from '../kit/util.js';
import { esc, errorText, toast, announce, reveal } from '../ui.js';
import { createBar } from './rechercher/bar.js';
import { createSide } from './rechercher/side.js';
import { createResults } from './rechercher/results.js';
import { createPreview } from './rechercher/preview.js';
import { createActions } from './rechercher/actions.js';
import { createHistory } from './rechercher/history.js';
import { openCatalog, openViews, openSyntaxHelp, layoutOf } from './rechercher/library.js';
import { quote, COLON, NBSP, int, count, leafOf, typeLabel, pathOf, sameDn, DEFAULT_LIMIT, MAX_LIMIT, dateText } from './rechercher/text.js';

/** The screen has its own stylesheet (css/pages/rechercher.css), loaded by the router. */
export const stylesheet = true;

const REVALIDATE_MS = 180_000;
const PRESENCE_LABELS = { all: 'Toutes', online: 'En ligne', noReply: 'Sans réponse au ping', error: 'Erreur de ping', unknown: 'Non vérifié' };

export function render(main, ctx) {
  const params = ctx.params ?? {};
  main.innerHTML = `<div class="page rch">
    <section class="rch-hero reveal">
      <span class="glow-ring rch-hero-ring" aria-hidden="true"></span>
      <div class="orbs" aria-hidden="true"><span class="orb a"></span><span class="orb b"></span><span class="orb c"></span></div>
      <div class="rch-hero-top">
        <span class="rch-hero-icon" aria-hidden="true">${glyph('search')}</span>
        <div class="rch-hero-titles"><h1 class="gradient-text">Rechercher</h1><p class="rch-hero-sub">Comptes, postes, groupes et OU de l’annuaire</p></div>
        <nav class="rch-nav" aria-label="Historique de l’écran">
          <button class="btn ghost icon sm" type="button" data-nav="back" aria-label="Précédent" aria-keyshortcuts="Alt+ArrowLeft" data-tip="Précédent (Alt ←)" disabled>${glyph('chevronLeft')}</button>
          <button class="btn ghost icon sm" type="button" data-nav="forward" aria-label="Suivant" aria-keyshortcuts="Alt+ArrowRight" data-tip="Suivant (Alt →)" disabled>${glyph('chevronRight')}</button>
          <button class="btn ghost icon sm" type="button" data-nav="list" aria-haspopup="menu" aria-expanded="false" aria-label="Étapes de l’historique" data-tip="Étapes de l’historique" disabled>${glyph('history')}</button>
        </nav>
        <div class="rch-hero-acts">
          <button class="btn subtle" type="button" data-open="catalog">${glyph('database')}<span>Requêtes prêtes</span></button>
          <button class="btn subtle" type="button" data-open="views">${glyph('tag')}<span>Vues</span></button>
        </div>
      </div>
      <div class="rch-bar-host"></div>
    </section>
    <div class="rch-work reveal">
      <aside class="rch-side card glass" aria-label="Unités d’organisation"></aside>
      <section class="rch-results card glass" aria-label="Résultats"></section>
      <aside class="rch-preview card glass" aria-label="Aperçu de l’objet sélectionné"></aside>
    </div>
  </div>`;

  const page = main.querySelector('.page.rch');
  const work = main.querySelector('.rch-work');
  const navBack = main.querySelector('[data-nav="back"]');
  const navForward = main.querySelector('[data-nav="forward"]');
  const navList = main.querySelector('[data-nav="list"]');
  const hist = createHistory();
  const timers = new Set();
  let alive = true;
  let session = null;
  let memory = { recents: [], favorites: [], workspaces: [], queryFavorites: [], maxWorkspaces: 100 };
  let catalogCache = null;
  let generation = 0;
  let revalidate = { on: false, timer: 0 };
  let bar = null;
  let side = null;
  let results = null;
  let preview = null;
  let actions = null;
  let commands = null;
  let ouChoice = null; // OU chosen in the tree: { dn, name, kind, subtree }

  const stopReveal = reveal(main);
  const readOnly = () => !!session?.readOnly;

  // ---------- Shared state for the sub-modules ----------

  const S = {
    lastMode: 'ping',
    readOnly,
    get results() { return results; },
    get preview() { return preview; },
    open: (row) => openObject(row),
    // Each screen names its subject its own way: Assistance takes « poste » (or « compte »), the others « dn ».
    go: (route, row) => { recentObject(row); ctx.navigate(route, route === 'assistance' ? { [row.kind === 'user' ? 'compte' : 'poste']: row.dn } : { dn: row.dn }); },
    browse: (dn) => browse(dn, leafOf(dn), side?.subtree ?? true),
    searchAssociated: (row) => searchAssociated(row),
    pin: (dn) => pin({ data: { kind: 'ou', dn, name: leafOf(dn) } }, true),
    filterPresence: (state) => results.state && filterPresence(state),
  };

  // ---------- Bridge calls of the lists ----------

  async function list(op, args, label, { restore = null, push = true } = {}) {
    const my = ++generation;
    bar?.setBusy(true);
    results.setLoading(label);
    commands?.setBusy('refresh', true);
    try {
      const result = await ctx.call(op, args);
      if (!alive || my !== generation) return null; // an older answer is ignored
      showList(result, op, args, restore, push);
      return result;
    } catch (err) {
      if (!alive || my !== generation) return null;
      results.setError(err, () => list(op, args, label, { restore, push }));
      if (err?.code === 'search.textInvalid') bar.focus();
      toast(errorText(err), { tone: err?.code === 'source.unavailable' ? 'warn' : 'alert' });
      return null;
    } finally {
      if (my === generation) { bar?.setBusy(false); commands?.setBusy('refresh', false); }
    }
  }

  function showList(result, op, args, restore, push) {
    const view = restore?.view ?? {};
    results.setNotice('restore', null);
    results.show(result, { restored: !!restore, selection: view.selection ?? [], quick: view.quick ?? '', facets: view.facets ?? [], presence: view.presence ?? null, scroll: view.scroll ?? 0, set: view.set ?? null });
    if (op === 'search.run') bar.setEnginePlan(result.plan, args.text);
    else bar.setEnginePlan(null);
    if (push) {
      hist.push({ request: { op, ...args }, result, label: listLabel(result), at: Date.now(), view: { set: results.set } });
      paintNav();
    }
    preview.show(null);
    paintCommands();
    // A search typed in the field is remembered; one started while typing is not (Domenia 1 RCH-023).
    if (op === 'search.run' && !typedSearch && (result.kind !== 'address' || result.rows.length)) recentSearch(args.text);
    pendingSelect();
  }

  function listLabel(r) {
    if (r.kind === 'search') return `Recherche ${quote(r.text)} · ${r.scope.chip}`;
    if (r.kind === 'address') return `Adresse ${r.text}`;
    if (r.kind === 'browse') return `Liste de ${r.scope.wholeDomain ? 'tout le domaine' : quote(leafOf(r.scope.dn))}`;
    return `${r.kind === 'localQuery' ? 'Requête locale' : 'Requête'} ${quote(r.view?.name ?? '')}`;
  }

  let typedSearch = false;
  function search({ text, scope = null, type = 'all', match = 'prefix', typed = false, limit = DEFAULT_LIMIT }) {
    typedSearch = typed;
    return list('search.run', { text, scope, type, limit, match }, `Recherche de ${quote(text)}…`).then((r) => { if (r && typed) announce(r.counter); return r; });
  }

  function browse(dn, name, subtree, { type = 'all', limit = DEFAULT_LIMIT } = {}) {
    if (!dn) return null;
    return list('search.browse', { dn, subtree, type, limit }, `Contenu de ${sameDn(dn, session?.domain?.rootDn) ? 'tout le domaine' : quote(name ?? leafOf(dn))}…`);
  }

  function runView(id, { wholeDomain = false, dn = null, subtree = true, limit = DEFAULT_LIMIT } = {}) {
    const ou = dn ?? (ouChoice?.kind === 'ou' ? ouChoice.dn : session?.scope?.dn ?? null);
    return list('search.view', { id, dn: wholeDomain ? null : ou, subtree, wholeDomain, limit }, 'Requête en cours…');
  }

  function runLocalQuery(id, { verdict = 'match', dn = null, subtree = true, limit = DEFAULT_LIMIT } = {}) {
    const ou = dn ?? (ouChoice?.dn ?? session?.scope?.dn ?? session?.domain?.rootDn);
    return list('search.localQuery', { id, dn: ou, subtree, verdict, limit }, 'Requête locale en cours…');
  }

  async function more(limit) {
    const r = results.result();
    if (!r) return;
    commands?.setBusy('refresh', true);
    try {
      const page2 = await ctx.call('search.more', { listId: r.listId, limit: Math.min(MAX_LIMIT, limit) });
      if (!alive || results.result()?.listId !== r.listId) return;
      results.append(page2);
      hist.update({ result: results.result() });
    } catch (err) {
      toast(`Suite non chargée${COLON}${errorText(err)}`, { tone: err?.code === 'search.listUnknown' ? 'warn' : 'alert' });
    } finally {
      commands?.setBusy('refresh', false);
    }
  }

  /** Reads the current list again with its perimeter, view, mode and filters (explicit gesture). */
  function refresh() {
    const place = hist.current();
    if (!place) { bar.focus(); return; }
    const { op, ...args } = place.request;
    const view = { set: results.set, ...results.filters(), selection: results.grid.getSelectedIds(), scroll: results.scrollTop() };
    list(op, args, 'Relecture de la liste…', { push: false }).then((r) => {
      if (r) { results.show(r, { selection: view.selection, quick: view.quick, facets: view.facets, presence: view.presence, scroll: view.scroll }); hist.update({ result: r }); }
    });
  }

  // ---------- Recents, objects, favourites, views (preferences only) ----------

  function recentSearch(text) {
    if (!text || text.trim().length < 2) return;
    ctx.call('search.recent.add', { kind: 'search', text: text.trim(), type: null, dn: null })
      .then((m) => { memory = m; bar.refreshRecents(); results.refreshLaunch(launchData()); }).catch((err) => console.error(err));
  }

  function recentObject(row) {
    if (!row) return;
    ctx.call('search.recent.add', { kind: 'object', text: row.name, type: row.kind, dn: row.dn })
      .then((m) => { memory = m; }).catch((err) => console.error(err));
  }

  function openObject(row) {
    if (!row) return;
    recentObject(row);
    ctx.navigate('fiche', { dn: row.dn });
  }

  function searchAssociated(row) {
    const a = row?.association;
    if (!a) return;
    if (a.dn) { search({ text: a.dn, type: row.kind === 'computer' ? 'users' : 'computers' }); bar.setText(a.dn); return; }
    const first = a.label.split(' + ')[0];
    bar.setText(first);
    search({ text: first, type: 'computers' });
  }

  async function pin(node, pinned) {
    const d = node?.data;
    if (!d?.dn) return;
    try {
      memory = pinned
        ? await ctx.call('search.favorite.pin', { dn: d.dn, name: d.name ?? leafOf(d.dn), subtree: side?.subtree ?? true, type: 'all', term: null })
        : await ctx.call('search.favorite.unpin', { dn: d.dn });
      side.setFavorites(memory.favorites);
      side.refreshStars();
      toast(pinned ? `${quote(d.name ?? leafOf(d.dn))} épinglée dans les favoris.` : `${quote(d.name ?? leafOf(d.dn))} retirée des favoris ; rien n’est changé dans l’annuaire.`, { tone: 'ok', life: 2600 });
      if (memory.warning) toast(memory.warning, { tone: 'warn' });
    } catch (err) {
      toast(errorText(err), { tone: 'warn' });
    }
  }

  async function openFavorite(fav) {
    // A favourite starts the list of its OU, with its depth and type; its term goes to the visible local filter.
    if (!fav) return;
    side.reveal(fav.dn);
    const r = await list('search.browse', { dn: fav.dn, subtree: fav.subtree, type: fav.type ?? 'all', limit: DEFAULT_LIMIT }, `Contenu de ${quote(fav.label)}…`);
    if (r && fav.term) results.show(r, { quick: fav.term });
  }

  function filterPresence(state) {
    const f = results.filters();
    results.show(results.result(), { quick: f.quick, facets: f.facets, presence: state, selection: results.grid.getSelectedIds(), scroll: results.scrollTop() });
    announce(`Liste filtrée sur la présence${COLON}${PRESENCE_LABELS[state] ?? state}. Aucune nouvelle lecture.`);
  }

  // ---------- History ----------

  function paintNav() {
    navBack.disabled = !hist.canBack();
    navForward.disabled = !hist.canForward();
    navList.disabled = hist.list().length < 2;
  }

  function saveView() {
    if (!results?.result()) return;
    hist.update({ view: { set: results.set, ...results.filters(), selection: results.grid.getSelectedIds(), scroll: results.scrollTop() } });
  }

  function restorePlace(place) {
    if (!place?.result) return;
    // Restored exactly as it was, without any read: rows, sort, selection, scroll, filters, column set (Domenia 1 RCH-044).
    results.show(place.result, { restored: true, ...place.view, selection: place.view?.selection ?? [] });
    const req = place.request;
    if (req.op === 'search.run') { bar.setText(req.text); bar.setType(req.type ?? 'all'); bar.setMatch(req.match); }
    // The OU of the step is selected again only if its branch is already read (no read here, RCH-045).
    if (req.dn) side.tree.select(req.dn);
    preview.show(null);
    paintNav();
    paintCommands();
    announce(`${place.label}${COLON}liste de l’historique, non relue.`);
  }

  function step(direction) {
    saveView();
    const place = hist.step(direction);
    if (place) restorePlace(place);
  }

  navBack.addEventListener('click', () => step('back'));
  navForward.addEventListener('click', () => step('forward'));
  navList.addEventListener('click', () => {
    saveView();
    openMenu(navList, [
      { heading: 'Étapes de l’historique' },
      ...hist.list().map((e) => ({ label: e.label, icon: e.kind === 'search.run' ? 'search' : e.kind === 'search.browse' ? 'ou' : 'database', checked: e.current, radio: 'hist', run: () => { const p = hist.jump(e.index); if (p) restorePlace(p); } })),
    ], { label: 'Étapes de l’historique', placement: 'bottom-end' });
  });

  // ---------- Revalidation of the listed objects (explicit, off by default) ----------

  async function revalidateNow(silent = false) {
    const rows = results?.rows() ?? [];
    if (!rows.length || actions?.busy()) return;
    try {
      const res = await ctx.call('search.revalidate', { ids: rows.slice(0, 500).map((r) => r.id) });
      if (!alive) return;
      const changed = res.rows.filter((fresh) => {
        const old = rows.find((r) => r.id === fresh.id);
        return old && (old.dn !== fresh.dn || old.name !== fresh.name || old.state.key !== fresh.state.key || old.presence?.state !== fresh.presence?.state || old.lastLogon !== fresh.lastLogon);
      });
      // A row whose DN changed keeps its place: it is the same object, followed by its GUID (Domenia 1 RCH-057).
      const moved = changed.filter((fresh) => !sameDn(rows.find((r) => r.id === fresh.id)?.dn ?? '', fresh.dn)).length;
      if (changed.length) results.updateRows(changed);
      if (res.missing.length) results.markMissing(res.missing);
      results.setNotice('reval', { tone: changed.length || res.missing.length ? 'warn' : 'ok', icon: 'refresh', html: `${esc(res.summary)}${changed.length ? ` · ${esc(count(changed.length, 'ligne mise à jour', 'lignes mises à jour'))}` : ''}${moved ? ` · ${esc(count(moved, 'objet déplacé ou renommé', 'objets déplacés ou renommés'))}, ${moved > 1 ? 'suivis par leur identifiant' : 'suivi par son identifiant'}` : ''}`, dismiss: true });
      if (!silent) announce(res.summary);
    } catch (err) {
      results.setNotice('reval', { tone: 'warn', icon: 'alert', html: `Revérification non faite${COLON}${esc(errorText(err))} Nouvel essai dans 5${NBSP}minutes.`, dismiss: true });
    }
  }

  function setRevalidate(on) {
    revalidate.on = on;
    clearInterval(revalidate.timer);
    revalidate.timer = 0;
    if (on) {
      // Only the visible list, only while the page is shown, never during a survey: never a hidden sweep.
      revalidate.timer = setInterval(() => { if (document.visibilityState === 'visible' && results?.rows().length) revalidateNow(true); }, REVALIDATE_MS);
      timers.add(revalidate.timer);
    }
    paintCommands();
    announce(on ? 'Revérification de la liste toutes les 3 minutes, tant que la page est affichée.' : 'Revérification périodique arrêtée.');
  }

  // ---------- Command bar of the list ----------

  function exportItems() {
    const grid = results.grid;
    const nSel = grid.getSelection().length;
    return [
      { heading: 'Exporter en CSV (presse-papiers, point-virgule)' },
      { label: `Liste affichée (${int(grid.getVisibleRows().length)})`, icon: 'csv', run: () => grid.exportCsv('visible') },
      { label: `Lignes sélectionnées (${int(nSel)})`, icon: 'csv', disabled: !nSel, reason: 'Aucune ligne sélectionnée.', run: () => grid.exportCsv('selected') },
      '-',
      { label: 'Copier pour un ticket', icon: 'copy', disabled: !nSel && !grid.getVisibleRows().length, reason: 'Liste vide.', run: () => actions.copyTicket(nSel ? grid.getSelection() : grid.getVisibleRows().slice(0, 500)) },
    ];
  }

  function paintCommands() {
    if (!commands) return;
    const r = results.result();
    const has = !!r;
    const pcs = (results.rows() ?? []).some((x) => x.kind === 'computer' && !x.flags.disabled);
    const surveyBlocked = r?.view && !r.view.surveyAllowed;
    commands.setItems([
      { id: 'verify', label: 'Vérifier la liste', icon: 'wifi', kind: 'network', disabled: !has || !pcs || surveyBlocked, reason: surveyBlocked ? r.view.reason : 'Aucun poste actif dans la liste.', items: [{ label: '…' }], run: () => {} },
      { id: 'refresh', label: 'Actualiser', icon: 'refresh', kbd: 'F5', kind: 'network', disabled: !has, reason: 'Aucune liste à relire.', run: () => refresh() },
      { id: 'revalidate', label: revalidate.on ? 'Revérification active' : 'Revérifier la liste', icon: 'sync', kind: 'network', disabled: !has, reason: 'Aucune liste.', items: [{ label: '…' }], run: () => {} },
      { id: 'compare', label: 'Comparer', icon: 'split', disabled: !has, reason: 'Aucune liste.', run: () => actions.compare(results.grid.getSelection()) },
      { id: 'export', label: 'Exporter', icon: 'csv', disabled: !has, reason: 'Aucune liste.', items: [{ label: '…' }], run: () => {} },
      { id: 'saveview', label: 'Enregistrer la vue…', icon: 'tag', overflow: true, run: () => views() },
      { id: 'columns', label: 'Colonnes et affichage', icon: 'columns', overflow: true, disabled: !has, reason: 'Aucune liste.', run: () => results.grid.el.querySelector('.k-gcols')?.click() },
    ]);
  }

  // Menus of the command bar: built at the click, so they always state the current list.
  function onCommandMenu(e) {
    const b = e.target instanceof Element ? e.target.closest('[data-cmd]') : null;
    if (!b || b.getAttribute('aria-disabled') === 'true') return;
    const id = b.dataset.cmd;
    if (id === 'verify') { e.stopImmediatePropagation(); actions.surveyMenu(b); }
    else if (id === 'export') { e.stopImmediatePropagation(); openMenu(b, exportItems(), { label: 'Exporter', placement: 'bottom-end' }); }
    else if (id === 'revalidate') {
      e.stopImmediatePropagation();
      openMenu(b, [
        { heading: 'Revérification de la liste' },
        { label: 'Revérifier maintenant', icon: 'refresh', run: () => revalidateNow() },
        { label: 'Revérifier toutes les 3 minutes', checked: revalidate.on, keepOpen: false, run: (item) => setRevalidate(item.checked) },
        '-',
        { label: 'Relit les objets listés (500 au plus) dans leur périmètre ; une absence ne prouve pas une suppression.', disabled: true, reason: '' },
      ], { label: 'Revérification', placement: 'bottom-end' });
    }
  }

  // ---------- Library ----------

  async function catalog() {
    await openCatalog(ctx, {
      ou: () => (ouChoice && ouChoice.kind !== 'root' ? { dn: ouChoice.dn, name: ouChoice.name, subtree: side?.subtree ?? true } : session?.scope && !sameDn(session.scope.dn, session?.domain?.rootDn) ? { dn: session.scope.dn, name: session.scope.label, subtree: session.scope.subtree } : null),
      onRun: (entry, o) => runEntry(entry, o),
    });
  }

  function runEntry(entry, o = {}) {
    const ou = ouChoice && ouChoice.kind !== 'root' ? ouChoice : null;
    const dn = ou?.dn ?? session?.scope?.dn ?? null;
    const subtree = ou ? (side?.subtree ?? true) : (session?.scope?.subtree ?? true);
    if (entry.local) return runLocalQuery(`local.${entry.id.slice(6)}`, { verdict: o.verdict ?? 'match', dn: o.wholeDomain ? session?.domain?.rootDn : dn, subtree });
    return runView(entry.id.slice(3), { wholeDomain: !!o.wholeDomain || !dn, dn, subtree });
  }

  async function catalogEntry(id) {
    if (!catalogCache) catalogCache = await ctx.call('search.catalog').catch(() => null);
    const entry = catalogCache?.entries.find((e) => e.id === id);
    if (entry) runEntry(entry);
  }

  function currentDraft() {
    const r = results.result();
    const dn = r && r.kind !== 'search' && r.kind !== 'address' && !r.scope.wholeDomain ? r.scope.dn : ouChoice?.kind === 'ou' || ouChoice?.kind === 'container' ? ouChoice.dn : null;
    if (!dn) return null;
    const f = results.filters();
    const set = results.set;
    const layout = layoutOf(set);
    return {
      // A personal view keeps an OU, its filters and its columns (Domenia 1 points 56 to 60), never the text of a global search.
      note: r && (r.kind === 'search' || r.kind === 'address') ? `La recherche ${quote(r.text)} ne fait pas partie de la vue${COLON}elle garde l’OU choisie dans l’arbre, ses filtres et ses colonnes.` : '',
      ouLabel: pathOf(dn, session?.domain?.dnsName), subtree: r?.scope.subtree ?? side?.subtree ?? true, type: r?.type ?? 'all',
      presenceLabel: PRESENCE_LABELS[f.presence ?? 'all'], filter: f.quick, limit: r?.limit ?? DEFAULT_LIMIT,
      columnSetLabel: { mixed: 'Vue mixte', users: 'Vue utilisateurs', computers: 'Vue postes' }[set], layout,
      args: { dn, subtree: r?.scope.subtree ?? side?.subtree ?? true, type: r?.type ?? 'all', presence: f.presence ?? 'all', filter: f.quick.slice(0, 120), limit: Math.max(1, Math.min(MAX_LIMIT, r?.limit ?? DEFAULT_LIMIT)), columnSet: set, layout },
    };
  }

  function views() {
    openViews(ctx, {
      memory: () => memory,
      current: currentDraft,
      proposed: () => {
        const r = results.result();
        const name = r?.view?.name ? `Vue${COLON}${r.view.name}` : `OU${COLON}${leafOf(currentDraft()?.args.dn ?? '') || 'domaine'}${results.filters().quick ? ` · ${results.filters().quick}` : ''}`;
        return name.slice(0, 80);
      },
      onSaved: (m) => { memory = m; },
      onOpen: (v, read) => openWorkspace(v, read),
    });
  }

  async function openWorkspace(v, read) {
    // Prepares OU, filters, columns and sort without any read (Domenia 1 RCH-133); « Ouvrir et lire » reads the OU too.
    if (v.layout) {
      try { localStorage.setItem(`domenia.kit.v1:grid:rechercher.${v.columnSet}`, JSON.stringify({ v: 1, ...v.layout })); } catch { /* per-viewer convenience */ }
    }
    results.setColumnSet(v.columnSet);
    side.reveal(v.ouDn);
    bar.setType(v.type);
    if (read) {
      const r = await list('search.browse', { dn: v.ouDn, subtree: v.subtree, type: v.type, limit: v.limit }, `Vue ${quote(v.name)}…`);
      if (r) results.show(r, { quick: v.filter, presence: v.presence === 'all' ? null : v.presence });
    } else {
      toast(`Vue ${quote(v.name)} prête${COLON}OU, filtres, colonnes et tri appliqués. « Afficher le contenu » lit l’OU.`, { tone: 'info', life: 5200 });
      pendingWorkspace = v;
    }
  }
  let pendingWorkspace = null;

  // ---------- Selection follow-up (route parameter sel) ----------

  let wantSelect = params.sel ?? null;
  function pendingSelect() {
    if (!wantSelect) return;
    const rows = results.grid.getVisibleRows();
    const target = wantSelect === 'first' ? rows[0] : wantSelect === 'pc' ? rows.find((r) => r.kind === 'computer') : wantSelect === 'user' ? rows.find((r) => r.kind === 'user') : rows.find((r) => r.id === wantSelect);
    wantSelect = null;
    if (target) { results.grid.select([target.id]); preview.show(target); }
  }

  // ---------- Build ----------

  function launchData() {
    const favs = memory.queryFavorites ?? [];
    const entries = catalogCache?.entries ?? [];
    const order = ['ad:lockedusers', 'ad:disabled', 'ad:inactiveusers', 'ad:stalecomputers', 'local:lowdisk', 'ad:pwdneverexpires'];
    const views2 = [...entries.filter((e) => favs.includes(e.id)), ...order.map((id) => entries.find((e) => e.id === id)).filter(Boolean)]
      .filter((e, n, all) => all.indexOf(e) === n).slice(0, 6);
    return { recents: memory.recents, views: views2 };
  }

  async function start() {
    try {
      [session, memory, catalogCache] = await Promise.all([
        ctx.call('session.info'),
        ctx.call('search.memory').catch((err) => { console.error(err); return memory; }),
        ctx.call('search.catalog').catch(() => null),
      ]);
    } catch (err) {
      main.querySelector('.rch-results').innerHTML = `<div class="empty">${glyph('alert')}<h2>Rechercher indisponible</h2><p>${esc(errorText(err))}</p></div>`;
      return;
    }
    if (!alive) return;
    const root = session?.domain?.rootDn;
    const dns = session?.domain?.dnsName ?? '';
    if (session?.connection?.state && ctx.showConnection) ctx.showConnection(session);
    main.querySelector('.rch-hero-sub').textContent = root
      ? `${session.connection?.state === 'simulated' ? 'Annuaire fictif' : 'Annuaire'} ${dns} · OU de travail${COLON}${session.scope?.label ?? '—'} · lecture seule par défaut, rien n’est lu sans votre geste`
      : 'Annuaire non connecté : la recherche reprendra à la connexion.';

    bar = createBar(main.querySelector('.rch-bar-host'), {
      onSubmit: (s) => search(s),
      onSuggest: (text, type) => ctx.call('search.suggest', { text, type }),
      getRecents: () => memory.recents ?? [],
      onOpenObject: (dn, kind) => { ctx.call('search.recent.add', { kind: 'object', text: leafOf(dn), type: kind, dn }).catch(() => {}); ctx.navigate('fiche', { dn }); },
      onClearRecents: async () => { try { memory = await ctx.call('search.recent.clear'); bar.refreshRecents(); results.refreshLaunch(launchData()); toast('Recherches récentes effacées sur ce poste.', { tone: 'ok' }); } catch (err) { toast(errorText(err), { tone: 'warn' }); } },
      onSyntaxHelp: () => openSyntaxHelp((ex) => { bar.setText(ex); search({ ...bar.getState(), text: ex }); }),
    });

    results = createResults(main.querySelector('.rch-results'), ctx, {
      onOpen: (row) => openObject(row),
      onActive: (row) => { if (results.grid.getSelection().length <= 1) preview.show(row); },
      onSelection: (rows) => { if (rows.length > 1) preview.showMany(rows); else if (rows.length === 1) preview.show(rows[0]); saveView(); },
      contextMenu: (c) => actions.contextMenu(c),
      selectionActions: (rows) => actions.selectionActions(rows),
      onMore: (limit) => more(limit),
      onContains: (term) => search({ ...bar.getState(), text: term, match: 'contains' }),
      onDns: async (ip) => {
        try {
          const res = await ctx.call('search.dns.reverse', { ip });
          toast(res.message, { tone: res.name ? 'ok' : 'warn', life: 6000 });
          if (res.name) { bar.setText(res.name.split('.')[0]); search({ ...bar.getState(), text: res.name.split('.')[0], match: 'prefix' }); }
        } catch (err) { toast(`Résolution DNS impossible${COLON}${errorText(err)}`, { tone: 'warn' }); }
      },
      onRefresh: () => refresh(),
      onBrowseDn: (dn) => { side.reveal(dn); browse(dn, leafOf(dn), side.subtree); },
      onRemoveCriterion: (id) => {
        const r = results.result();
        if (id === 'type' && r?.kind === 'browse') browse(r.scope.dn, leafOf(r.scope.dn), r.scope.subtree, { type: 'all', limit: r.limit });
        else if (id === 'query') { results.launch(launchData()); results.setNotice('view', null); hist.push({ request: { op: 'none' }, result: null, label: 'Liste effacée', at: Date.now(), view: {} }); paintNav(); paintCommands(); }
      },
      onVerdict: (verdict) => { const r = results.result(); if (r?.kind === 'localQuery') runLocalQuery(r.view.id, { verdict, dn: r.scope.dn, subtree: r.scope.subtree, limit: r.limit }); },
      onExample: (text) => { bar.setText(text); search({ ...bar.getState(), text }); },
      onCatalog: () => catalog(),
      onCatalogEntry: (id) => catalogEntry(id),
    });
    commands = createCommandBar(main.querySelector('.rch-actions'), { label: 'Actions de la liste', items: [], size: 'sm' });
    main.querySelector('.rch-actions').addEventListener('click', onCommandMenu, true);

    preview = createPreview(main.querySelector('.rch-preview'), ctx, {
      onOpen: (row) => openObject(row),
      onGo: (route, row) => S.go(route, row),
      onRecheck: (row) => actions.recheck(row),
      onCompare: (rows) => actions.compare(rows),
      onTicket: (rows) => actions.copyTicket(rows),
      onSurvey: (mode, rows) => actions.survey(mode, rows, 'selection'),
      onBrowse: (dn) => { side.reveal(dn); browse(dn, leafOf(dn), side.subtree); },
      onSearchAssociated: (row) => searchAssociated(row),
      onToggle: (folded) => work.classList.toggle('preview-folded', folded),
      readOnly,
      onUnlock: (row) => actions.unlock(row),
    });
    actions = createActions(ctx, S);

    if (root) {
      side = createSide(main.querySelector('.rch-side'), ctx, {
        root, dns,
        onSelect: (node, how) => {
          if (!node) { results.setNotice('restore', { tone: 'warn', icon: 'alert', html: 'L’OU mémorisée n’apparaît plus sous son parent relu, ou n’a pas pu être relue : aucun autre périmètre n’est appliqué. Choisissez une OU ou relancez la lecture.', dismiss: true, actions: [{ id: 'retry', label: 'Réessayer', icon: 'refresh' }], run: () => side.tree.reload() }); return; }
          const d = node.data ?? {};
          if (!d.dn) return;
          ouChoice = { dn: d.dn, name: d.name, kind: d.kind };
          bar.setOu(d.kind === 'ou' || d.kind === 'container' ? { dn: d.dn, name: d.name } : null);
          // A pointer click lists the OU at once; the keyboard waits 300 ms (the tree does); a restored OU waits for a gesture.
          if (how === 'restore') {
            results.setNotice('restore', { tone: 'info', icon: 'ou', html: `OU mémorisée${COLON}<b>${esc(d.name)}</b>. Rien n’est lu avant votre geste.`, dismiss: true, actions: [{ id: 'browse', label: `Afficher le contenu de ${quote(d.name)}`, icon: 'rows', kind: 'network' }], run: () => browse(d.dn, d.name, side.subtree) });
            return;
          }
          results.setNotice('restore', null);
          if (pendingWorkspace && sameDn(pendingWorkspace.ouDn, d.dn)) return;
          browse(d.dn, d.name, side.subtree);
        },
        onBrowse: (dn, name, subtree) => {
          const w = pendingWorkspace && sameDn(pendingWorkspace.ouDn, dn) ? pendingWorkspace : null;
          pendingWorkspace = null;
          if (w) list('search.browse', { dn, subtree: w.subtree, type: w.type, limit: w.limit }, `Vue ${quote(w.name)}…`).then((r) => r && results.show(r, { quick: w.filter, presence: w.presence === 'all' ? null : w.presence }));
          else browse(dn, name, subtree);
        },
        onFavorite: (fav) => openFavorite(fav),
        onPin: (node, pinned) => pin(node, pinned),
        onUnpin: (dn) => pin({ data: { kind: 'ou', dn, name: memory.favorites.find((f) => sameDn(f.dn, dn))?.label ?? leafOf(dn) } }, false),
        onMove: async (dn, index) => { try { memory = await ctx.call('search.favorite.move', { dn, index }); side.setFavorites(memory.favorites); } catch (err) { toast(errorText(err), { tone: 'warn' }); } },
        isPinned: (dn) => (memory.favorites ?? []).some((f) => sameDn(f.dn, dn)),
        onNavigate: (route, p) => ctx.navigate(route, p),
        readOnly,
      });
      side.setFavorites(memory.favorites ?? []);
    }

    paintCommands();
    results.launch(launchData());
    if (memory.warning) toast(memory.warning, { tone: 'warn' });
    await applyParams();
  }

  async function applyParams() {
    const p = params;
    const type = ['all', 'users', 'computers', 'groups', 'ous'].includes(p.type) ? p.type : 'all';
    const match = p.match === 'contient' || p.match === 'contains' ? 'contains' : 'prefix';
    const limit = Math.max(1, Math.min(MAX_LIMIT, Number.parseInt(p.limite ?? '', 10) || DEFAULT_LIMIT));
    if (side) await side.ready;
    if (!alive) return;
    const q = p.q ?? p.ip ?? '';
    // The OU given by the address becomes the choice of the tree (chip « Dans « X » » of the bar), without a read of its own.
    const choose = async (dn) => {
      if (!dn || !side) return;
      await side.reveal(dn);
      const node = side.selected();
      if (node?.data?.dn) { ouChoice = { dn: node.data.dn, name: node.data.name, kind: node.data.kind }; bar.setOu(node.data.kind === 'ou' || node.data.kind === 'container' ? { dn: node.data.dn, name: node.data.name } : null); }
    };
    if (q) {
      bar.setText(q);
      bar.setType(type);
      bar.setMatch(match);
      if (p.portee) { await choose(p.portee); bar.setScope('ou'); }
      await search({ text: q, scope: p.portee ?? null, type, match, limit });
    } else if (p.requete) {
      await choose(p.ou);
      await runLocalQuery(p.requete.startsWith('local.') ? p.requete : `local.${p.requete}`, { verdict: p.verdict ?? 'match', dn: p.ou ?? null, subtree: p.sousou !== '0', limit });
    } else if (p.vue) {
      await choose(p.ou);
      await runView(p.vue, { wholeDomain: p.domaine === '1', dn: p.ou ?? null, subtree: p.sousou !== '0', limit });
    } else if (p.ou && side) {
      await choose(p.ou);
      await browse(p.ou, leafOf(p.ou), p.sousou !== '0', { type, limit });
    }
    if (!alive) return;
    switch (p.ouvrir) {
      case 'requetes': catalog(); break;
      case 'vues': views(); break;
      case 'syntaxe': openSyntaxHelp((ex) => { bar.setText(ex); search({ ...bar.getState(), text: ex }); }); break;
      case 'comparer': {
        const rows = results.grid.getVisibleRows().filter((r) => r.kind === 'computer').slice(0, 3);
        if (rows.length >= 2) { results.grid.select(rows.map((r) => r.id)); actions.compare(rows); }
        break;
      }
      case 'diag': {
        const rows = results.grid.getVisibleRows().filter((r) => r.kind === 'computer').slice(0, 6);
        if (rows.length) actions.netdiag(rows);
        break;
      }
      case 'releve': actions.survey('ping', null, 'list'); break;
      case 'menu': {
        const row = results.grid.getVisibleRows()[0];
        if (row) {
          results.grid.select([row.id]);
          const cell = results.grid.el.querySelector('.k-gbody .k-gr .k-gc:nth-child(3)');
          if (cell) { cell.dispatchEvent(new MouseEvent('contextmenu', { bubbles: true, clientX: cell.getBoundingClientRect().left + 160, clientY: cell.getBoundingClientRect().top + 18 })); }
        }
        break;
      }
      case 'historique': navList.disabled = false; navList.click(); break;
      default: break;
    }
  }

  // ---------- Page events ----------

  main.querySelector('.rch-hero-acts').addEventListener('click', (e) => {
    const b = e.target instanceof Element ? e.target.closest('[data-open]') : null;
    if (b?.dataset.open === 'catalog') catalog();
    else if (b?.dataset.open === 'views') views();
  });

  const onKey = (e) => {
    if (!alive) return;
    if (e.altKey && !e.ctrlKey && (e.key === 'ArrowLeft' || e.key === 'ArrowRight')) {
      if (isTextEntry(e.target)) return;
      e.preventDefault();
      step(e.key === 'ArrowLeft' ? 'back' : 'forward');
      return;
    }
    if ((e.ctrlKey || e.metaKey) && !e.altKey && e.key.toLowerCase() === 'f') { e.preventDefault(); bar?.focus(); return; }
    if (e.key === '/' && !isTextEntry(e.target) && !e.ctrlKey && !e.altKey) { e.preventDefault(); bar?.focus(); return; }
    if (e.key === 'F5' && main.querySelector('.rch-results')?.contains(e.target)) { e.preventDefault(); refresh(); }
  };
  document.addEventListener('keydown', onKey);

  start().catch((err) => console.error(err));

  return () => {
    alive = false;
    document.removeEventListener('keydown', onKey);
    for (const t of timers) clearInterval(t);
    clearInterval(revalidate.timer);
    stopReveal?.();
    bar?.destroy();
    side?.destroy();
    results?.destroy();
    preview?.destroy();
  };
}

export { typeLabel, dateText };
