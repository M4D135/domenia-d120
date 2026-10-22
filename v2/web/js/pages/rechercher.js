// Rechercher: universal search space of Domenia 2 (docs/ops/rechercher.md). A large bar with suggestions and syntax that
// becomes a slim sticky bar once a list is shown, the OU tree with pinned favourites on the left (foldable into a rail), the
// virtual result grid in the middle (history of the lists, one toolbar line, folded filters and options, three column sets
// fitted to the rows), the preview of the selected object on the right (a rail while nothing is selected); ready-made views
// and local queries, personal views, surveys of the list planned by the engine, network diagnostic, comparison, copies for a
// ticket, confirmed exports. Nothing is read without a gesture: typing never reads the directory, Entrée or a click does.
// Route parameters (captures, links of other screens): q, portee, type, match, limite, ou, sousou, vue, domaine, requete,
// verdict, sel, largeur (capture of a narrower window), ouvrir (requetes | vues | syntaxe | comparer | releve | menu | diag |
// historique | outils | suggestions | arbre | exporter | deverrouiller).
import { glyph } from '../kit/glyphs.js';
import { createCommandBar } from '../kit/commandbar.js';
import { openMenu } from '../kit/menu.js';
import { openDialog } from '../kit/dialog.js';
import { isTextEntry, readLayout, writeLayout, writeClipboard, rafThrottle } from '../kit/util.js';
import { onEvent } from '../bridge.js';
import { esc, errorText, toast, announce, reveal } from '../ui.js';
import { createBar } from './rechercher/bar.js';
import { createSide } from './rechercher/side.js';
import { createResults, expandAssociationColumns } from './rechercher/results.js';
import { createPreview } from './rechercher/preview.js';
import { createActions, MODES, modeLabel } from './rechercher/actions.js';
import { createHistory } from './rechercher/history.js';
import { openCatalog, openViews, openSyntaxHelp, layoutOf } from './rechercher/library.js';
import { quote, COLON, NBSP, int, count, leafOf, typeLabel, pathOf, sameDn, DEFAULT_LIMIT, MAX_LIMIT, dateText, selectionText, csvRecords } from './rechercher/text.js';

/** The screen has its own stylesheet (css/pages/rechercher.css), loaded by the router. */
export const stylesheet = true;

const PRESENCE_LABELS = { all: 'Toutes', online: 'En ligne', noReply: 'Sans réponse au ping', error: 'Erreur de ping', unknown: 'Non vérifié' };
const INTERVALS = [120, 180, 300, 600, 900];
const PRELOAD_DELAY = 450;

export function render(main, ctx) {
  const params = ctx.params ?? {};
  main.innerHTML = `<div class="page rch">
    <section class="rch-hero reveal">
      <span class="glow-ring rch-hero-ring" aria-hidden="true"></span>
      <div class="orbs" aria-hidden="true"><span class="orb a"></span><span class="orb b"></span><span class="orb c"></span></div>
      <div class="rch-hero-top">
        <span class="rch-hero-icon" aria-hidden="true">${glyph('search')}</span>
        <div class="rch-hero-titles"><h1 class="gradient-text">Rechercher</h1><p class="rch-hero-sub">Comptes, postes, groupes et OU de l’annuaire</p></div>
        <div class="rch-hero-acts">
          <button class="btn subtle" type="button" data-open="catalog" data-tip="Vues prêtes de l’annuaire et requêtes locales">${glyph('database')}<span>Requêtes prêtes</span></button>
          <button class="btn subtle" type="button" data-open="views" data-tip="Vues personnelles : OU, filtres et colonnes">${glyph('tag')}<span>Vues</span></button>
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
  const hero = main.querySelector('.rch-hero');
  const work = main.querySelector('.rch-work');
  let hist = createHistory();
  const timers = new Set();
  const offs = [];
  let alive = true;
  let session = null;
  let memory = { recents: [], favorites: [], workspaces: [], queryFavorites: [], maxWorkspaces: 100 };
  let catalogCache = null;
  let generation = 0;
  let revalidate = { on: false, timer: 0, interval: 180 };
  let clickCheck = readLayout('rechercher.clic') ?? { ping: false, console: false };
  let resume = null;
  let cleared = false;
  let previewForced = false;
  let preloadTimer = 0;
  let preloadGen = 0;
  let bar = null;
  let side = null;
  let results = null;
  let preview = null;
  let actions = null;
  let commands = null;
  let ouChoice = null; // OU chosen in the tree: { dn, name, kind }

  const stopReveal = reveal(main);
  const readOnly = () => !!session?.readOnly;
  const rootDn = () => session?.domain?.rootDn ?? '';

  // A narrower window for the captures (« largeur=1280 »): the screen lays itself out as in that window (container queries).
  const simulated = Number.parseInt(params.largeur ?? '', 10);
  if (simulated >= 900 && simulated <= 2400) {
    requestAnimationFrame(() => {
      const chrome = window.innerWidth - main.clientWidth;
      page.style.setProperty('--rch-sim-w', `${Math.max(640, simulated - chrome)}px`);
      page.classList.add('simw');
    });
  }

  // ---------- Shared state for the sub-modules ----------

  const S = {
    lastMode: 'ping',
    chosen: false,
    readOnly,
    get results() { return results; },
    get preview() { return preview; },
    open: (row) => openObject(row),
    // Each screen names its subject its own way: Assistance takes « poste » (or « compte »), the others « dn ».
    go: (route, row, extra = {}) => { recentObject(row); ctx.navigate(route, route === 'assistance' ? { [row.kind === 'user' ? 'compte' : 'poste']: row.dn, ...extra } : { dn: row.dn, ...extra }); },
    // ASS-012: the computers of the rows (500 at most) open the offline dossier of the Assistance with their names; nothing is
    // read nor written before « Préparer le dossier… » there.
    offlineDossier: (rows) => {
      const names = [...new Set(rows.filter((r) => r.kind === 'computer' && r.name).map((r) => String(r.name).replace(/\$$/, '')))].slice(0, 500);
      if (names.length) ctx.navigate('assistance', { postes: names.join(','), vue: 'horsligne' });
    },
    browse: (dn) => browse(dn, leafOf(dn), side?.subtree ?? true),
    searchAssociated: (row) => searchAssociated(row),
    pin: (dn) => pin({ data: { kind: 'ou', dn, name: leafOf(dn) } }, true),
    filterPresence: (state) => filterPresence(state),
    exportList: (scope) => exportList(scope),
    rereadMeasures: () => rereadMeasures(),
    onRunChange: () => paintCommandsSoon(),
    onSuspended: (reason) => showSuspended(reason),
    setResume: (r) => setResume(r),
    actionMode: (id) => actionMode(id),
  };

  // ---------- Settings of the administrator (search.policy: Domenia.config.json and Paramètres) ----------

  // RCH-067: an action an administrator hides (UI.Elements « rechercher.<id> »: Hidden) is never shown, a greyed one says why.
  // RCH-073: the revalidation of the listed objects, off unless an administrator turned it on (Streaming.RevalidateListedObjects),
  // every 60 s by default (30 to 600); the page can stop it for the session.
  let policy = { revalidateListed: false, revalidateSeconds: 60, hiddenActions: [], disabledActions: [], problems: [] };
  const DISABLED_BY_ADMIN = 'Fonction désactivée dans la configuration de l’application.';
  function actionMode(id) {
    const key = `rechercher.${id}`;
    if ((policy.hiddenActions ?? []).includes(key)) return 'hidden';
    if ((policy.disabledActions ?? []).includes(key)) return 'disabled';
    return 'default';
  }
  function applyPolicy(items) {
    return items.filter((c) => actionMode(c.id) !== 'hidden').map((c) => (actionMode(c.id) === 'disabled' ? { ...c, disabled: true, reason: DISABLED_BY_ADMIN } : c));
  }

  const listCheck = { on: true, timer: 0 };
  function stopListCheck() {
    clearInterval(listCheck.timer);
    timers.delete(listCheck.timer);
    listCheck.timer = 0;
  }
  function startListCheck() {
    stopListCheck();
    if (!policy.revalidateListed || !listCheck.on || !results?.result()) return;
    listCheck.timer = setInterval(() => { if (document.visibilityState === 'visible') checkListed(); }, Math.max(30, Math.min(600, policy.revalidateSeconds)) * 1000);
    timers.add(listCheck.timer);
  }
  /** Reads again the objects listed in their own perimeter: moves and renames under the same GUID; an absence is never a deletion. */
  async function checkListed() {
    const r = results?.result();
    const rows = results?.rows() ?? [];
    if (!r || !rows.length) return;
    const my = r.listId;
    try {
      const res = await ctx.call('search.revalidate', { ids: rows.slice(0, 500).map((x) => x.id) });
      // Another list shown meanwhile: the answer belongs to the previous one and is ignored (Domenia 1).
      if (!alive || results.result()?.listId !== my) return;
      if (res.rows.length) results.updateRows(res.rows);
      results.setNotice('listcheck', {
        tone: res.missing.length ? 'warn' : 'info', icon: 'sync', html: esc(res.summary), dismiss: true,
        actions: [{ id: 'off', label: 'Arrêter pour la session', icon: 'pause' }],
        run: (act) => { if (act === 'off') setListCheck(false); },
      });
    } catch (err) {
      console.error(err);
    }
  }
  function setListCheck(on) {
    listCheck.on = !!on;
    if (on) startListCheck(); else { stopListCheck(); results?.setNotice('listcheck', null); }
    announce(on ? `Revalidation des objets listés toutes les ${int(policy.revalidateSeconds)} secondes, tant que la page est affichée.` : 'Revalidation des objets listés arrêtée pour cette session.');
    paintCommandsSoon();
  }

  // ---------- Bridge calls of the lists ----------

  function compact(on) {
    hero.classList.toggle('compact', on);
    bar?.setCompact(on);
  }

  async function list(op, args, label, { restore = null, push = true } = {}) {
    const my = ++generation;
    cleared = false;
    compact(true);
    bar?.setBusy(true);
    results.setLoading(label);
    commands?.setBusy('refresh', true);
    // A simple search shows the rows of the local base while the directory read goes on (RCH-055).
    const offCached = op === 'search.run' ? onEvent('search.run:cached', (e) => { if (alive && my === generation && e?.text === String(args.text ?? '').trim()) results.showCached(e); }) : null;
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
      paintCommands();
      return null;
    } finally {
      offCached?.();
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
      hist.push({ request: { op, ...args }, result, label: listLabel(result), at: Date.now(), view: results.viewState(), tree: side?.expandedSnapshot() ?? [], ou: ouChoice?.dn ?? null });
      paintNav();
    }
    preview.show(null);
    previewForced = false;
    dock();
    paintCommands();
    paintResume();
    // A search typed in the field is remembered; one started while typing is not (Domenia 1 RCH-023).
    if (op === 'search.run' && !typedSearch && (result.kind !== 'address' || result.rows.length)) recentSearch(args.text);
    pendingSelect();
    results.setNotice('listcheck', null);
    startListCheck();
  }

  function listLabel(r) {
    if (r.kind === 'search') return `Recherche ${quote(r.text)} · ${r.scope.chip}`;
    if (r.kind === 'address') return `Adresse ${r.text}`;
    if (r.kind === 'browse') return `Liste de ${r.scope.wholeDomain ? 'tout le domaine' : quote(leafOf(r.scope.dn))}${r.type !== 'all' ? ` · ${typeLabel(r.type)}` : ''}`;
    return `${r.kind === 'localQuery' ? 'Requête locale' : 'Requête'} ${quote(r.view?.name ?? '')}`;
  }

  let typedSearch = false;
  function search({ text, scope = null, type = 'all', match = 'prefix', typed = false, limit = bar?.getLimit() ?? DEFAULT_LIMIT }) {
    typedSearch = typed;
    return list('search.run', { text, scope, type, limit, match }, `Recherche de ${quote(text)}…`).then((r) => { if (r && typed) announce(r.counter); return r; });
  }

  function browse(dn, name, subtree, { type = 'all', limit = bar?.getLimit() ?? DEFAULT_LIMIT } = {}) {
    if (!dn) return null;
    return list('search.browse', { dn, subtree, type, limit }, `Contenu de ${sameDn(dn, rootDn()) ? 'tout le domaine' : quote(name ?? leafOf(dn))}…`);
  }

  /** The working OU of the session when it is an OU (never the domain root): default of the sections without a choice. */
  function workingOu() {
    if (session?.scope?.dn && !sameDn(session.scope.dn, rootDn())) return { dn: session.scope.dn, name: session.scope.label, subtree: session.scope.subtree !== false };
    return null;
  }

  /** The OU of the tree becomes the choice of the page and of the bar (chip « Dans « X » »), without any read. */
  function takeOu(node) {
    const d = node?.data ?? {};
    if (!d.dn) return;
    ouChoice = { dn: d.dn, name: d.name, kind: d.kind };
    bar.setOu(d.kind === 'ou' || d.kind === 'container' ? { dn: d.dn, name: d.name } : workingOuChip());
    results.setNotice('defaultScope', null);
  }
  const workingOuChip = () => { const w = workingOu(); return w ? { dn: w.dn, name: w.name } : null; };

  /** The OU a view or a query runs on: the OU of the tree, else the working OU; never the domain root by default. */
  function chosenOu() {
    if (ouChoice && (ouChoice.kind === 'ou' || ouChoice.kind === 'container')) return { dn: ouChoice.dn, name: ouChoice.name, subtree: side?.subtree ?? true };
    if (session?.scope?.dn && !sameDn(session.scope.dn, rootDn())) return { dn: session.scope.dn, name: session.scope.label, subtree: session.scope.subtree !== false };
    return null;
  }

  function runView(id, { wholeDomain = false, dn = null, subtree = true, limit = bar?.getLimit() ?? DEFAULT_LIMIT } = {}) {
    if (!wholeDomain && !dn) { needOu(); return null; }
    return list('search.view', { id, dn: wholeDomain ? null : dn, subtree, wholeDomain, limit }, 'Requête en cours…');
  }

  function runLocalQuery(id, { verdict = 'match', dn = null, subtree = true, wholeDomain = false, limit = bar?.getLimit() ?? DEFAULT_LIMIT } = {}) {
    const target = wholeDomain ? rootDn() : dn;
    if (!target) { needOu(); return null; }
    return list('search.localQuery', { id, dn: target, subtree, verdict, limit }, 'Requête locale en cours…');
  }

  function needOu() {
    toast(`Choisissez une OU dans l’arbre${COLON}tout le domaine reste un choix explicite du catalogue des requêtes.`, { tone: 'warn', life: 6000 });
    catalog();
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
      paintCommands();
    } catch (err) {
      toast(`Suite non chargée${COLON}${errorText(err)}`, { tone: err?.code === 'search.listUnknown' || err?.code === 'search.listBusy' ? 'warn' : 'alert' });
    } finally {
      commands?.setBusy('refresh', false);
    }
  }

  /** Reads the current list again with its perimeter, view, mode and filters (explicit gesture). */
  function refresh() {
    const place = hist.current();
    if (!place || cleared || !results.result()) { if (results.state.empty) results.retry(); else bar.focus(); return; }
    const { op, ...args } = place.request;
    const view = results.viewState();
    list(op, args, 'Relecture de la liste…', { push: false }).then((r) => {
      if (r) { results.show(r, { ...view, layout: null }); hist.update({ result: r }); }
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
    const r = await list('search.browse', { dn: fav.dn, subtree: fav.subtree, type: fav.type ?? 'all', limit: bar.getLimit() }, `Contenu de ${quote(fav.label)}…`);
    if (r && fav.term) results.show(r, { quick: fav.term });
  }

  /** Outcome pills and quick filters of presence: a second click removes the filter (RCH-095). */
  function filterPresence(state) {
    if (!results.result()) return;
    const next = results.togglePresence(state);
    announce(next ? `Liste filtrée sur la présence${COLON}${PRESENCE_LABELS[state] ?? state}. Aucune nouvelle lecture.` : 'Filtre de présence retiré, sans nouvelle lecture.');
  }

  // ---------- History ----------

  function paintNav() {
    const n = results?.navEls;
    if (!n) return;
    n.back.disabled = !hist.canBack() && !(cleared && hist.current());
    n.forward.disabled = !hist.canForward();
    n.list.disabled = hist.list().length < 2;
  }

  function saveView() {
    if (!results?.result() || cleared) return;
    hist.update({ view: results.viewState(), tree: side?.expandedSnapshot() ?? [], ou: ouChoice?.dn ?? null });
  }

  function restorePlace(place) {
    if (!place?.result) return;
    cleared = false;
    compact(true);
    // Restored exactly as it was, without any read: rows, sort, selection, both scrolls, filters, column set (RCH-044).
    results.show(place.result, { restored: true, ...place.view, selection: place.view?.selection ?? [] });
    const req = place.request;
    if (req.op === 'search.run') { bar.setText(req.text); bar.setType(req.type ?? 'all'); bar.setMatch(req.match); }
    if (req.limit) bar.setLimit(req.limit);
    // The branches of the step reopen when already read, those opened since fold, its OU is selected: no read (RCH-045).
    const missing = side?.applyExpanded(place.tree ?? [], place.ou ?? req.dn ?? null) ?? 0;
    preview.show(null);
    dock();
    paintNav();
    paintCommands();
    announce(`${place.label}${COLON}liste de l’historique, non relue.${missing ? ` ${count(missing, 'branche de l’arbre non lue ou disparue', 'branches de l’arbre non lues ou disparues')}.` : ''}`);
  }

  function step(direction) {
    if (direction === 'back' && cleared && hist.current()) { restorePlace(hist.current()); return; }
    saveView();
    const place = hist.step(direction);
    if (place) restorePlace(place);
  }

  function historyMenu(anchor) {
    saveView();
    openMenu(anchor, [
      { heading: 'Étapes de l’historique' },
      ...hist.list().map((e) => ({ label: e.label, icon: e.kind === 'search.run' ? 'search' : e.kind === 'search.browse' ? 'ou' : 'database', hint: dateText(new Date(e.at).toISOString()).slice(11), checked: e.current, radio: 'hist', run: () => { const p = hist.jump(e.index); if (p) restorePlace(p); } })),
    ], { label: 'Étapes de l’historique', placement: 'bottom-start' });
  }

  // ---------- Revalidation of the list (explicit, off by default) ----------

  /** Reads the last explicit list again with its filter and perimeter (RCH-047): new objects added, absent ones marked. */
  async function revalidateNow(silent = false) {
    const r = results?.result();
    if (!r || actions?.busy()) return;
    const before = new Map(results.rows().map((x) => [x.id, x]));
    try {
      const res = await ctx.call('search.reconcile', { listId: r.listId });
      if (!alive || results.result()?.listId !== r.listId) return;
      const added = new Set(res.added);
      const moved = new Set(res.moved);
      const changed = res.rows.filter((fresh) => {
        const old = before.get(fresh.id);
        return old && !added.has(fresh.id) && (old.dn !== fresh.dn || old.name !== fresh.name || old.login !== fresh.login || old.upn !== fresh.upn || old.state.key !== fresh.state.key
          || old.os !== fresh.os || old.lastLogon !== fresh.lastLogon || old.description !== fresh.description || old.changed !== fresh.changed || moved.has(fresh.id));
      });
      if (changed.length) results.updateRows(changed);
      if (res.added.length) results.inject(res.rows.filter((x) => added.has(x.id)));
      if (res.moved.length) results.markMissing(res.moved, 'hors du périmètre relu');
      if (res.missing.length) results.markMissing(res.missing);
      results.touch(res.readAt);
      hist.update({ result: results.result() });
      const tone = res.added.length || res.missing.length || res.moved.length ? 'warn' : 'ok';
      results.setNotice('reval', { tone, icon: 'refresh', html: `${esc(res.summary)}${changed.length ? ` · ${esc(count(changed.length, 'ligne mise à jour', 'lignes mises à jour'))}` : ''}`, more: `<p>${esc(res.checkpoint)}.</p><p>Un objet absent du dernier retour est marqué « à revérifier », jamais retiré ; un objet déplacé garde sa ligne, suivi par son identifiant.</p>`, dismiss: true });
      if (!silent) announce(res.summary);
      paintCommands();
    } catch (err) {
      const minutes = Math.round(revalidate.interval / 60);
      results.setNotice('reval', { tone: 'warn', icon: 'alert', html: `Revérification non faite${COLON}${esc(errorText(err))}${revalidate.on ? ` Nouvel essai dans ${count(minutes, 'minute', 'minutes')}.` : ''}`, dismiss: true });
    }
  }

  function setRevalidate(on, interval = revalidate.interval) {
    revalidate.on = on;
    revalidate.interval = INTERVALS.includes(interval) ? interval : 180;
    clearInterval(revalidate.timer);
    timers.delete(revalidate.timer);
    revalidate.timer = 0;
    if (on) {
      // Only the visible list, only while the page is shown, never during a survey: never a hidden sweep.
      revalidate.timer = setInterval(() => { if (document.visibilityState === 'visible' && results?.result()) revalidateNow(true); }, revalidate.interval * 1000);
      timers.add(revalidate.timer);
    }
    const label = `Toutes les ${revalidate.interval < 60 ? `${revalidate.interval} s` : `${Math.round(revalidate.interval / 60)}${NBSP}minutes`}`;
    results?.setRevalidate(on, label);
    paintCommands();
    announce(on ? `Revérification de la liste ${label.toLowerCase()}, tant que la page est affichée ; la première dans ${count(Math.round(revalidate.interval / 60), 'minute', 'minutes')}.` : 'Revérification périodique arrêtée.');
  }

  /** Stored measures of the list read again from the local base, by pages of 250 (RCH-083). */
  async function rereadMeasures() {
    const r = results.result();
    if (!r) return;
    let offset = 0;
    let done = 0;
    try {
      for (;;) {
        const pageOf = await ctx.call('search.measures', { listId: r.listId, offset });
        if (!alive || results.result()?.listId !== r.listId) return;
        done += results.updateRows(pageOf.rows);
        results.setNotice('measures', { tone: 'info', icon: 'database', html: `Mesures enregistrées relues${COLON}${esc(count(done, 'ligne', 'lignes'))} sur ${esc(int(pageOf.total))} (base locale, aucune lecture réseau).`, dismiss: true });
        if (pageOf.next == null) break;
        offset = pageOf.next;
      }
      announce(`Mesures enregistrées relues pour ${count(done, 'ligne', 'lignes')}.`);
    } catch (err) {
      toast(`Mesures non relues${COLON}${errorText(err)}`, { tone: 'warn' });
    }
  }

  // ---------- Checks on click, preload, suspension, resume ----------

  /** Sentence of the selection bar, the same as the preview and the confirmations (RCH-127): visible rows, hidden ones excluded. */
  function paintSelectionLabel(rows) {
    const label = results?.grid.el.querySelector('.k-gselbar .k-gsel-n');
    if (!label) return;
    const shown = new Set(results.grid.getVisibleRows().map((v) => v.id));
    const visible = rows.filter((r) => shown.has(r.id));
    const hidden = rows.length - visible.length;
    label.textContent = selectionText(visible.length, visible.filter((r) => r.kind === 'computer').length)
      + (hidden ? ` · ${count(hidden, 'masquée par un filtre, exclue', 'masquées par un filtre, exclues')}` : '');
  }

  function onRowSelection(rows) {
    paintSelectionLabel(rows);
    if (rows.length > 1) preview.showMany(rows);
    else if (rows.length === 1) preview.show(rows[0]);
    else preview.show(null);
    if (!rows.length) previewForced = false;
    dock();
    saveView();
    paintCommandsSoon();
    clearTimeout(preloadTimer);
    preloadGen++;
    if (rows.length !== 1 || !results.pointerRecent()) return;
    const row = rows[0];
    if (clickCheck.ping && row.kind === 'computer' && !row.flags.disabled) actions.checkOnClick(row, clickCheck.console);
    else schedulePreload(row);
  }

  /** A click on one row reads its fiche again (RCH-129); its row follows the fiche read (RCH-077). Older reads are dropped. */
  function schedulePreload(row) {
    const my = ++preloadGen;
    preloadTimer = setTimeout(() => preload(row, my), PRELOAD_DELAY);
  }

  async function preload(row, my = ++preloadGen) {
    preview.setBusy(true);
    try {
      const res = await ctx.call('search.preload', { id: row.id });
      if (!alive || my !== preloadGen) return;
      const old = results.rows().find((x) => x.id === row.id);
      const fresh = { ...res.row, presence: old?.presence ?? res.row.presence, console: old?.console ?? res.row.console };
      if (old && (old.dn !== fresh.dn || old.name !== fresh.name || old.state.key !== fresh.state.key || old.lastLogon !== fresh.lastLogon || old.description !== fresh.description
        || old.association?.label !== fresh.association?.label || old.mail !== fresh.mail)) {
        results.updateRows([fresh]);
        preview.update(fresh);
        announce(`${fresh.name}${COLON}la ligne suit la fiche relue.`);
      }
      preview.setFresh(fresh, res.readAt, res.sourceLabel);
    } catch (err) {
      if (my === preloadGen && err?.code !== 'search.objectUnknown') console.error(err);
      if (my === preloadGen && err?.code === 'search.objectUnknown') toast(err.message, { tone: 'warn' });
    } finally {
      if (my === preloadGen) preview.setBusy(false);
    }
  }

  function showSuspended(reason) {
    results.setNotice('suspended', {
      tone: 'warn', icon: 'pause', html: esc(reason || 'Vérifications sur sélection suspendues : un poste a rejeté le compte distant.'),
      more: 'Les relevés confirmés restent possibles ; les vérifications au clic attendent votre reprise, après contrôle du compte utilisé.',
      actions: [{ id: 'resume', label: 'Reprendre les vérifications', icon: 'play' }],
      run: async () => {
        try { await ctx.call('search.checks.resume'); results.setNotice('suspended', null); announce('Vérifications sur sélection reprises.'); } catch (err) { toast(errorText(err), { tone: 'warn' }); }
      },
    });
  }

  function setResume(next) {
    resume = next;
    paintResume();
    paintCommands();
  }

  function paintResume() {
    if (!results) return;
    if (!resume) { results.setNotice('resume', null); return; }
    const same = results.result()?.listId === resume.listId;
    results.setNotice('resume', {
      tone: 'warn', icon: 'pause', html: esc(resume.text), more: same ? 'Reprendre relit seulement les postes restants, avec une nouvelle confirmation ; les mesures déjà validées sont gardées.' : 'Ce relevé interrompu concerne une autre liste : revenez-y par l’historique pour le reprendre.',
      actions: [...(same ? [{ id: 'resume', label: `Reprendre (${int(resume.remaining)})`, icon: 'play', kind: 'network', primary: true }] : []), { id: 'forget', label: 'Abandonner', icon: 'x' }],
      run: async (act) => {
        if (act === 'resume') actions.survey(resume.mode, null, 'list', { resume: true });
        else if (act === 'forget') { try { await ctx.call('search.survey.forget'); setResume(null); announce('Plan de reprise abandonné ; les mesures déjà validées restent.'); } catch (err) { toast(errorText(err), { tone: 'warn' }); } }
      },
    });
  }

  // ---------- Preview dock and tree rail ----------

  // A narrow screen folds the tree into its rail while the operator never chose (and unfolds it when room comes back).
  let autoFolded = false;
  function fitSide() {
    if (!side || !side.auto) return;
    const narrow = page.clientWidth < 900;
    if (narrow && !side.folded) { side.setFolded(true, false, false); autoFolded = true; }
    else if (!narrow && side.folded && autoFolded) { side.setFolded(false, false, false); autoFolded = false; }
  }
  const pageSize = 'ResizeObserver' in window ? new ResizeObserver(() => fitSide()) : null;
  pageSize?.observe(page);

  function dock() {
    const sel = results?.grid.getSelection().length ?? 0;
    const rail = !!preview?.folded() || (!sel && !previewForced);
    work.classList.toggle('preview-folded', rail);
    work.dataset.preview = rail ? 'rail' : 'open';
  }

  // ---------- Exports (RCH-069) ----------

  /** Selected rows that are shown (RCH-126): a selected row hidden by a filter is never exported nor surveyed. */
  function selectedVisible() {
    const shown = new Set(results.grid.getVisibleRows().map((v) => v.id));
    return results.grid.getSelection().filter((r) => shown.has(r.id));
  }

  /** CSV of exactly these rows, in the order and with the columns of the grid (neutralisation of the kit kept). */
  function csvOf(rows) {
    const grid = results.grid;
    const visible = grid.getVisibleRows();
    const records = csvRecords(grid.toCsv({ scope: 'visible', bom: true }));
    const wanted = new Set(rows.map((r) => r.id));
    const kept = [records[0]];
    visible.forEach((row, n) => { if (wanted.has(row.id) && records[n + 1] !== undefined) kept.push(records[n + 1]); });
    return `${kept.join('\r\n')}\r\n`;
  }

  async function exportList(scope) {
    const grid = results.grid;
    const r = results.result();
    if (!r) return;
    const rows = scope === 'selected' ? selectedVisible() : grid.getVisibleRows();
    const selectedHidden = scope === 'selected' ? grid.getSelection().length - rows.length : 0;
    if (!rows.length) { toast(scope === 'selected' ? (selectedHidden ? `Les lignes sélectionnées sont masquées par un filtre${COLON}rien à exporter.` : 'Aucune ligne sélectionnée à exporter.') : 'Aucune ligne affichée à exporter.', { tone: 'warn' }); return; }
    const loaded = results.rows().length;
    const hidden = scope === 'visible' ? Math.max(0, loaded - rows.length) : Math.max(0, grid.getVisibleRows().length - rows.length);
    const columns = grid.el.querySelectorAll('.k-ghrow .k-gh:not(.sel)').length;
    const facts = [
      ['Portée', scope === 'selected' ? `Lignes sélectionnées${COLON}${count(rows.length, 'ligne', 'lignes')}` : `Liste affichée${COLON}${count(rows.length, 'ligne', 'lignes')}`],
      ['Exclu', [hidden ? (scope === 'visible' ? `${count(hidden, 'ligne chargée masquée', 'lignes chargées masquées')} par les filtres` : `${count(hidden, 'ligne affichée non sélectionnée', 'lignes affichées non sélectionnées')}`) : '', selectedHidden ? `${count(selectedHidden, 'ligne sélectionnée masquée', 'lignes sélectionnées masquées')} par un filtre` : '', 'colonnes masquées', r.complete ? '' : `objets au-delà de la limite de ${int(r.limit)} lignes`].filter(Boolean).join(' · ')],
      ['Complétude', r.complete ? `Liste complète dans ce périmètre (${r.scope.label}).` : `Liste limitée à ${int(r.limit)} lignes${COLON}les objets au-delà ne sont pas inclus.`],
      ['Format', `${count(columns, 'colonne visible', 'colonnes visibles')} dans l’ordre affiché, association en trois colonnes ; point-virgule, UTF-8, formules neutralisées.`],
    ];
    const answer = await openDialog({
      title: `Exporter ${count(rows.length, 'ligne', 'lignes')} en CSV`, subtitle: listLabel(r), icon: 'csv', size: 'md',
      body: `<div data-page="rechercher" class="rch-export"><dl class="rch-export-facts">${facts.map(([k, v]) => `<dt>${esc(k)}</dt><dd>${esc(v)}</dd>`).join('')}</dl>
        <p class="rch-dlg-note">${glyph('info')}${esc(r.absence)}</p>
        <p class="rch-dlg-note">${glyph('copy')}Le CSV part dans le presse-papiers, prêt à coller dans un tableur ; l’enregistrement direct en fichier viendra avec l’opération de sauvegarde de l’hôte.</p></div>`,
      actions: [{ id: 'cancel', label: 'Annuler', safe: true }, { id: 'copy', label: 'Copier le CSV', icon: 'copy', primary: true }],
    }).result;
    if (answer !== 'copy') return;
    const csv = expandAssociationColumns(scope === 'selected' ? csvOf(rows) : grid.toCsv({ scope, bom: true }), rows);
    const ok = await writeClipboard(csv);
    toast(ok ? `CSV copié${COLON}${count(rows.length, 'ligne', 'lignes')}, séparateur point-virgule. Collez-le dans un tableur.` : 'Copie impossible : le presse-papiers est indisponible.', { tone: ok ? 'ok' : 'warn', life: 5200 });
  }

  function exportItems() {
    const grid = results.grid;
    const nSel = selectedVisible().length;
    const nVis = grid.getVisibleRows().length;
    return [
      { heading: 'Exporter en CSV (avec confirmation)' },
      { label: `Liste affichée (${int(nVis)})…`, icon: 'csv', disabled: !nVis, reason: 'Aucune ligne affichée.', run: () => exportList('visible') },
      { label: `Lignes sélectionnées (${int(nSel)})…`, icon: 'csv', disabled: !nSel, reason: 'Aucune ligne sélectionnée.', run: () => exportList('selected') },
      '-',
      { label: 'Copier pour un ticket', icon: 'copy', disabled: !nSel && !nVis, reason: 'Liste vide.', run: () => actions.copyTicket(nSel ? selectedVisible() : grid.getVisibleRows().slice(0, 500)) },
    ];
  }

  // ---------- Command bar of the list ----------

  function paintCommands() {
    if (!commands) return;
    const r = cleared ? null : results.result();
    const has = !!r;
    const rows = has ? results.rows() : [];
    const pcs = rows.some((x) => x.kind === 'computer' && !x.flags.disabled);
    const blocked = actions?.blocked() ?? '';
    const runState = actions?.runState();
    const sel = results.grid.getSelection();
    const comparable = sel.length >= 2 && sel.length <= 8 && new Set(sel.map((x) => x.kind)).size === 1 && ['computer', 'user'].includes(sel[0]?.kind);
    const items = [];
    if (runState) {
      // While a survey reads, the main button stops it and says where it is (RCH-086).
      items.push({ id: 'verify', label: runState.stopAsked ? 'Arrêt demandé…' : `Arrêter (${int(runState.done)}/${int(runState.total)})`, icon: 'pause', pinned: true, run: () => actions.stopRun() });
    } else if (has && rows.some((x) => x.kind === 'computer')) {
      // The main action launches the last reading chosen in the session, the chevron opens the choices.
      const last = S.chosen ? S.lastMode : null;
      items.push({ id: 'verify', label: last ? `Vérifier · ${modeLabel(last)}` : 'Vérifier la liste', icon: 'wifi', kind: 'network', pinned: true, disabled: !pcs || !!blocked,
        reason: blocked || 'Aucun poste actif dans la liste.', run: () => (last ? actions.survey(last, null, 'list') : openSurveyMenu()) });
      items.push({ id: 'verifyMenu', label: 'Choisir le relevé', icon: 'chevronDown', iconOnly: true, pinned: true, disabled: !pcs || !!blocked, reason: blocked || 'Aucun poste actif dans la liste.', items: actions.surveyItems() });
    }
    items.push(
      { id: 'refresh', label: 'Actualiser', icon: 'refresh', kbd: 'F5', kind: 'network', disabled: !has, reason: 'Aucune liste à relire.', run: () => refresh() },
      { id: 'export', label: 'Exporter', icon: 'csv', disabled: !has, reason: 'Aucune liste.', items: has ? exportItems() : [{ label: 'Aucune liste', disabled: true }] },
      { id: 'compare', label: comparable ? `Comparer (${int(sel.length)})` : 'Comparer', icon: 'split', disabled: !comparable, reason: 'Sélectionnez de deux à huit objets d’un même type (postes ou comptes).', run: () => actions.compare(sel) },
      { id: 'revalidate', label: revalidate.on ? 'Revérification active' : 'Revérifier', icon: 'sync', kind: 'network', disabled: !has, reason: 'Aucune liste.', items: [
        { heading: 'Revérification de la liste' },
        { label: 'Revérifier maintenant', icon: 'refresh', run: () => revalidateNow() },
        { label: 'Revérifier en arrière-plan', checked: revalidate.on, run: (item) => setRevalidate(item.checked) },
        { label: 'Intervalle', icon: 'clock', items: INTERVALS.map((s) => ({ label: s < 600 ? `${Math.round(s / 60)}${NBSP}minutes${s === 180 ? ' (par défaut)' : ''}` : `${Math.round(s / 60)}${NBSP}minutes`, radio: 'interval', checked: revalidate.interval === s, run: () => setRevalidate(revalidate.on, s) })) },
        ...(policy.revalidateListed ? [{ label: `Revalider les objets listés (toutes les ${int(policy.revalidateSeconds)}${NBSP}s, réglage de l’administrateur)`, checked: listCheck.on, run: (item) => setListCheck(item.checked) }] : []),
        '-',
        { label: 'Relit la dernière liste avec son filtre et sa portée ; une absence ne prouve pas une suppression.', disabled: true, reason: '' },
      ] },
      { id: 'measures', label: 'Relire les mesures enregistrées', icon: 'database', overflow: true, disabled: !has, reason: 'Aucune liste.', run: () => rereadMeasures() },
      { id: 'saveview', label: 'Enregistrer la vue…', icon: 'tag', overflow: true, run: () => views() },
      { id: 'columns', label: 'Colonnes et affichage', icon: 'columns', overflow: true, disabled: !has, reason: 'Aucune liste.', run: () => results.grid.el.querySelector('.k-gcols')?.click() },
    );
    commands.setItems(applyPolicy(items));
  }
  const paintCommandsSoon = rafThrottle(() => paintCommands());

  function openSurveyMenu() {
    const anchor = results.actionsHost.querySelector('[data-cmd="verify"]') ?? results.actionsHost;
    openMenu(anchor, actions.surveyItems(), { label: 'Vérifier la liste', placement: 'bottom-start' });
  }

  // ---------- Library ----------

  async function catalog() {
    await openCatalog(ctx, {
      ou: () => chosenOu(),
      onRun: (entry, o) => runEntry(entry, o),
    });
  }

  function runEntry(entry, o = {}) {
    const ou = chosenOu();
    // The whole domain is the secondary, explicit choice of the catalog: never the fallback of a missing OU (RCH-117).
    if (entry.local) return runLocalQuery(`local.${entry.id.slice(6)}`, { verdict: o.verdict ?? 'match', dn: ou?.dn ?? null, subtree: ou?.subtree ?? true, wholeDomain: !!o.wholeDomain });
    return runView(entry.id.slice(3), { wholeDomain: !!o.wholeDomain, dn: ou?.dn ?? null, subtree: ou?.subtree ?? true });
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
      presenceLabel: PRESENCE_LABELS[f.presence ?? 'all'], filter: f.quick, limit: r?.limit ?? bar.getLimit(),
      columnSetLabel: { mixed: 'Vue mixte', users: 'Vue utilisateurs', computers: 'Vue postes' }[set], layout,
      args: { dn, subtree: r?.scope.subtree ?? side?.subtree ?? true, type: r?.type ?? 'all', presence: f.presence ?? 'all', filter: f.quick.slice(0, 120), limit: Math.max(1, Math.min(MAX_LIMIT, r?.limit ?? bar.getLimit())), columnSet: set, layout },
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
    if (v.layout) writeLayout(`grid:rechercher.${v.columnSet}`, { v: 1, ...v.layout });
    results.setColumnSet(v.columnSet);
    side.reveal(v.ouDn);
    bar.setType(v.type);
    bar.setLimit(v.limit);
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
    const target = wantSelect === 'first' ? rows[0] : wantSelect === 'pc' ? rows.find((r) => r.kind === 'computer') : wantSelect === 'user' ? rows.find((r) => r.kind === 'user') : wantSelect === 'locked' ? rows.find((r) => r.flags?.locked) : rows.find((r) => r.id === wantSelect);
    wantSelect = null;
    if (target) { results.grid.select([target.id]); preview.show(target); dock(); }
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

  function clearList() {
    // Back to the launchpad: the list, its commands and its footer go; no fake step is stacked, F5 reads nothing (RCH-051).
    cleared = true;
    generation++;
    compact(false);
    results.launch(launchData());
    results.setNotice('view', null);
    results.setNotice('reval', null);
    results.setNotice('survey', null);
    preview.show(null);
    dock();
    paintNav();
    paintCommands();
  }

  async function start() {
    try {
      [session, memory, catalogCache, policy] = await Promise.all([
        ctx.call('session.info'),
        ctx.call('search.memory').catch((err) => { console.error(err); return memory; }),
        ctx.call('search.catalog').catch(() => null),
        ctx.call('search.policy').catch((err) => { console.error(err); return policy; }),
      ]);
      listCheck.on = true;
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
      // The DNS offer belongs to the address typed: another text withdraws it at once (RCH-037).
      onInput: (text) => { const r = results?.result(); if (r?.dns && text !== r.dns.ip) results.setNotice('dns', null); },
    });


    results = createResults(main.querySelector('.rch-results'), ctx, {
      onOpen: (row) => openObject(row),
      onActive: (row) => { if (results.grid.getSelection().length <= 1 && row) { preview.show(row); dock(); } },
      onSelection: (rows) => onRowSelection(rows),
      contextMenu: (c) => actions.contextMenu(c),
      selectionActions: (rows) => actions.selectionActions(rows),
      onExport: (scope) => exportList(scope),
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
        else if (id === 'query') clearList();
      },
      onListType: (type) => { const r = results.result(); if (r?.kind === 'browse') browse(r.scope.dn, leafOf(r.scope.dn), r.scope.subtree, { type, limit: r.limit }); },
      onVerdict: (verdict) => { const r = results.result(); if (r?.kind === 'localQuery') runLocalQuery(r.view.id, { verdict, dn: r.scope.dn, subtree: r.scope.subtree, limit: r.limit }); },
      onExample: (text) => { bar.setText(text); search({ ...bar.getState(), text }); },
      onCatalog: () => catalog(),
      onCatalogEntry: (id) => catalogEntry(id),
      onEmptyAction: (act, r) => {
        if (act === 'retry') { if (r) refresh(); else results.retry(); }
        else if (act === 'everywhere' && r) { bar.setScope('everywhere'); search({ ...bar.getState(), text: r.text, scope: null, type: r.type, match: r.match }); }
        else if (act === 'contains' && r) { bar.setMatch('contains'); search({ ...bar.getState(), text: r.text, scope: r.scope.mode === 'global' && !r.scope.wholeDomain ? r.scope.dn : null, type: r.type, match: 'contains' }); }
        else if (act === 'allTypes' && r) { bar.setType('all'); if (r.kind === 'browse') browse(r.scope.dn, leafOf(r.scope.dn), r.scope.subtree, { type: 'all', limit: r.limit }); else search({ ...bar.getState(), text: r.text, type: 'all', match: r.match }); }
        else if (act === 'clear') { bar.setText(''); clearList(); bar.focus(); }
      },
      onClickCheck: (c) => { clickCheck = c; writeLayout('rechercher.clic', c); announce(c.ping ? `Vérifier au clic activé${c.console ? ', avec l’utilisateur connecté' : ''} : un clic sur un poste envoie un ping.` : 'Vérifier au clic désactivé : un clic relit seulement la fiche.'); },
      onRevalidate: (on) => setRevalidate(on),
      onScopeMode: () => paintCommandsSoon(),
    });
    results.setClickCheck(clickCheck);
    results.setRevalidate(false);
    // RCH-005 (Domenia 1 Test-DomeniaSearchUsesRootDefault): while no branch nor favourite is chosen, the bar searches in the
    // working OU, with one message; « Partout » stays an explicit choice of the operator.
    const work = workingOu();
    if (work) {
      bar.setOu({ dn: work.dn, name: work.name });
      bar.setScope('ou');
      results.setNotice('defaultScope', { tone: 'info', icon: 'ou', dismiss: true,
        html: `Périmètre par défaut${COLON}<b>OU ${esc(work.name)}</b>, l’OU de travail${work.subtree ? ' et ses sous-OU' : ''}. «${NBSP}Partout${NBSP}» cherche dans tout le domaine.` });
    }
    commands = createCommandBar(results.actionsHost, { label: 'Actions de la liste', items: [], size: 'sm', moreLabel: 'Plus d’actions de la liste' });
    const nav = results.navEls;
    nav.back.addEventListener('click', () => step('back'));
    nav.forward.addEventListener('click', () => step('forward'));
    nav.list.addEventListener('click', () => historyMenu(nav.list));

    preview = createPreview(main.querySelector('.rch-preview'), ctx, {
      onOpen: (row) => openObject(row),
      onGo: (route, row) => S.go(route, row),
      onRecheck: (row) => actions.recheck(row),
      onCompare: (rows) => actions.compare(rows),
      onTicket: (rows) => actions.copyTicket(rows),
      onSurvey: (mode, rows) => actions.survey(mode, rows, 'selection'),
      onBrowse: (dn) => { side.reveal(dn); browse(dn, leafOf(dn), side.subtree); },
      onSearchAssociated: (row) => searchAssociated(row),
      onToggle: () => dock(),
      onRail: () => { previewForced = true; dock(); },
      onReread: (row) => preload(row),
      readOnly,
      onUnlock: (row) => actions.unlock(row),
    });
    actions = createActions(ctx, S);

    if (root) {
      side = createSide(main.querySelector('.rch-side'), ctx, {
        root, dns,
        defaultOu: () => workingOu(),
        // A reveal (favourite, personal view, OU parente) selects the OU without listing it: the choice of the page follows.
        onReveal: (node) => takeOu(node),
        onSelect: (node, how) => {
          const d = node?.data ?? {};
          if (!d.dn) return;
          takeOu(node);
          // A pointer click lists the OU at once; the keyboard waits 300 ms (the tree does); a restored OU waits for a gesture.
          if (how === 'restore') {
            results.setNotice('restore', { tone: 'info', icon: 'ou', html: `OU mémorisée${COLON}<b>${esc(d.name)}</b>. Rien n’est lu avant votre geste.`, dismiss: true, actions: [{ id: 'browse', label: 'Afficher son contenu', icon: 'rows', kind: 'network', primary: true }], run: () => browse(d.dn, d.name, side.subtree) });
            return;
          }
          results.setNotice('restore', null);
          if (pendingWorkspace && sameDn(pendingWorkspace.ouDn, d.dn)) return;
          browse(d.dn, d.name, side.subtree);
        },
        onRestoreIssue: (issue) => {
          // An OU absent from its parent read again is not a read that failed (RCH-015): two notices, the right next step each.
          const absent = issue.kind === 'absent';
          results.setNotice('restore', {
            tone: 'warn', icon: absent ? 'ou' : 'alert',
            html: absent
              ? `L’OU mémorisée <b>${esc(issue.name)}</b> n’apparaît plus sous ${esc(quote(issue.parentName))} relue${COLON}supprimée ou déplacée. Aucun autre périmètre n’est appliqué.`
              : `L’OU mémorisée <b>${esc(issue.name)}</b> n’a pas pu être vérifiée${COLON}la lecture de ${esc(quote(issue.parentName))} n’a pas abouti${issue.message ? ` (${esc(issue.message)})` : ''}. Ce n’est pas une absence.`,
            actions: absent ? [{ id: 'search', label: 'Chercher une OU…', icon: 'search' }, { id: 'forget', label: 'Ignorer', icon: 'x' }] : [{ id: 'retry', label: 'Réessayer', icon: 'refresh', kind: 'network', primary: true }, { id: 'forget', label: 'Ignorer', icon: 'x' }],
            run: (act) => {
              if (act === 'retry') { results.setNotice('restore', null); side.retryRestore(); }
              else if (act === 'forget') { side.forgetRestore(); results.setNotice('restore', null); announce('OU mémorisée oubliée ; la branche et la liste restent telles quelles.'); }
              else if (act === 'search') main.querySelector('.rch-side-menu')?.click();
            },
          });
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
        onFold: (folded) => work.classList.toggle('side-folded', folded),
        readOnly,
      });
      work.classList.toggle('side-folded', side.folded);
      fitSide();
      side.setFavorites(memory.favorites ?? []);
    }

    paintCommands();
    dock();
    results.launch(launchData());
    if (memory.warning) toast(memory.warning, { tone: 'warn' });
    if (memory.imported > 0) toast(`Recherches enregistrées de Domenia 1 reprises${COLON}${count(memory.imported, 'OU en favori', 'OU en favoris')}, une seule fois ; la liste d’origine est conservée.`, { tone: 'info', life: 7000 });
    ctx.call('search.survey.state').then((s) => { if (!alive) return; if (s.resume) setResume(s.resume); if (s.checksSuspended) showSuspended(s.suspendedReason); }).catch((err) => console.error(err));
    await applyParams();
  }

  async function applyParams() {
    const p = params;
    const type = ['all', 'users', 'computers', 'groups', 'ous'].includes(p.type) ? p.type : 'all';
    const match = p.match === 'contient' || p.match === 'contains' ? 'contains' : 'prefix';
    const limit = Math.max(1, Math.min(MAX_LIMIT, Number.parseInt(p.limite ?? '', 10) || DEFAULT_LIMIT));
    bar.setLimit(limit);
    if (side) await side.ready;
    if (!alive) return;
    const q = p.q ?? p.ip ?? '';
    // The OU given by the address becomes the choice of the tree (chip « Dans « X » » of the bar), without a read of its own.
    const choose = async (dn) => {
      if (!dn || !side) return;
      await side.reveal(dn);
      const node = side.selected();
      if (node?.data?.dn) takeOu(node);
    };
    if (q) {
      bar.setText(q);
      bar.setType(type);
      bar.setMatch(match);
      if (p.portee) { await choose(p.portee); bar.setScope('ou'); }
      await search({ text: q, scope: p.portee ?? null, type, match, limit });
    } else if (p.requete === 'selection') {
      // REQ-048: the frozen selection of the query workshop (GUID, date, fingerprint), read in the memory of the session, shown
      // from the local data only; nothing is read on the network.
      let selection = null;
      try { selection = await ctx.call('requetes.search.selection'); } catch (err) { console.warn(err); }
      if (!alive) return;
      if (selection?.ids?.length) await list('search.selection', { ids: selection.ids, label: selection.recipeName || 'Requête', at: selection.at }, 'Sélection de l’atelier de requêtes…');
      else toast(`Aucune sélection figée dans cette session${COLON}figez d’abord les correspondants depuis l’aperçu de l’atelier de requêtes.`, { tone: 'info', life: 6000 });
    } else if (p.requete) {
      await choose(p.ou);
      await runLocalQuery(p.requete.startsWith('local.') ? p.requete : `local.${p.requete}`, { verdict: p.verdict ?? 'match', dn: p.ou ?? null, subtree: p.sousou !== '0', wholeDomain: p.domaine === '1', limit });
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
      case 'outils': results.setToolsOpen(true); break;
      case 'exporter': exportList('visible'); break;
      case 'arbre': {
        const node = side?.selected();
        const el = main.querySelector('.rch-tree .k-ti.is-sel') ?? main.querySelector('.rch-tree .k-ti');
        if (el) el.dispatchEvent(new MouseEvent('contextmenu', { bubbles: true, clientX: el.getBoundingClientRect().left + 60, clientY: el.getBoundingClientRect().top + 14 }));
        else if (node) announce(node.label);
        break;
      }
      case 'suggestions': {
        const input = main.querySelector('.rch-input');
        input?.focus();
        input?.dispatchEvent(new KeyboardEvent('keydown', { key: 'ArrowDown', bubbles: true }));
        break;
      }
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
      case 'releve': actions.survey(MODES[0].id, null, 'list'); break;
      case 'deverrouiller': {
        const row = results.grid.getVisibleRows().find((r) => r.flags?.locked);
        if (row) { results.grid.select([row.id]); preview.show(row); dock(); actions.unlock(row); }
        break;
      }
      case 'menu': {
        const row = results.grid.getVisibleRows()[0];
        if (row) {
          results.grid.select([row.id]);
          const cell = results.grid.el.querySelector('.k-gbody .k-gr .k-gc:nth-child(3)');
          if (cell) { cell.dispatchEvent(new MouseEvent('contextmenu', { bubbles: true, cancelable: true, clientX: cell.getBoundingClientRect().left + 160, clientY: cell.getBoundingClientRect().top + 18 })); }
        }
        break;
      }
      case 'historique': historyMenu(results.navEls.list); break;
      default: break;
    }
  }

  // ---------- Session change (RCH-136) ----------

  /**
   * A change of session or domain abandons what belonged to the previous one: pending reads, history, filter undo, pending
   * selection and preview; the views of the new domain are read again (the page restarts on the new session).
   */
  async function checkSession() {
    if (!alive || !session) return;
    try {
      const now = await ctx.call('session.info');
      if (!alive) return;
      // A change of session, domain or account restarts the page (RCH-136); a mere change of the connection state does not.
      const same = now?.domain?.rootDn === session?.domain?.rootDn && now?.account?.login === session?.account?.login;
      if (same) return;
      generation++;
      hist = createHistory();
      wantSelect = null;
      pendingWorkspace = null;
      clearTimeout(preloadTimer);
      setRevalidate(false);
      stopListCheck();
      actions?.stopRun();
      commands?.destroy();
      commands = null;
      bar?.destroy(); side?.destroy(); results?.destroy(); preview?.destroy();
      main.querySelector('.rch-side').replaceChildren();
      ouChoice = null;
      cleared = false;
      compact(false);
      toast('Session changée : vues, historique et aperçu de la session précédente abandonnés ; rien n’est relu sans votre geste.', { tone: 'info', life: 6000 });
      await start();
    } catch (err) {
      console.error(err);
    }
  }
  const onVisible = () => { if (document.visibilityState === 'visible') checkSession(); };
  document.addEventListener('visibilitychange', onVisible);
  window.addEventListener('focus', checkSession);
  offs.push(onEvent('session.changed', () => checkSession()));

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
    pageSize?.disconnect();
    document.removeEventListener('visibilitychange', onVisible);
    window.removeEventListener('focus', checkSession);
    offs.forEach((off) => off());
    for (const t of timers) clearInterval(t);
    clearInterval(revalidate.timer);
    clearTimeout(preloadTimer);
    paintCommandsSoon.cancel?.();
    stopReveal?.();
    stopListCheck();
    actions?.stopRun();
    commands?.destroy();
    bar?.destroy();
    side?.destroy();
    results?.destroy();
    preview?.destroy();
  };
}

export { typeLabel, dateText };
