// Utilisateurs et postes: associations between users and workstations, in both directions (Domenia 1 Relations, REL-001
// to REL-052, and the comparison of the groups of two users, R40). A header with the figures of the local store and the
// main actions (full on the welcome view, compact everywhere else), the observations still to save, then four tabs: the
// subject (identity, primary relation, statements, animated graph, list, chronology, recent logons), every association
// (facets and grid), the comparison of two users, and the local journal with the removals that can be restored. Every
// change goes through the write circuit (runWrite: plan, confirmation, receipt, re-read); every network read starts on an
// explicit gesture. The work panels are docked beside the page so that the plan of a write opens over them and they carry
// on after its receipt (next batch, next association). Contract: docs/ops/relations.md.
//
// Parameters: onglet=sujet|toutes|comparer|journal · sujet=<DN, identifiant ou nom de poste> · vue=graphe|liste|chronologie ·
// panneau=ajouter|rechercher|detecter|session|import|orphelines|moisson|releve|aide · a=<compte A> · b=<compte B> ·
// filtre=contradictoire · liste=<noms de postes séparés par des virgules, 50 au plus> (liste chargée d’un autre écran).
import { glyph } from '../kit/glyphs.js';
import { createTabs } from '../kit/tabs.js';
import { createCommandBar } from '../kit/commandbar.js';
import { writeClipboard } from '../kit/util.js';
import { onEvent } from '../bridge.js';
import { runWrite } from '../write-flow.js';
import { applyVars, reveal, countUp, donut, sparkline, toast, announce } from '../ui.js';
import { BADGES, NATURES, dot, esc, int, nouns, NBSP, errText, cleanRef, loadedList, sk, dateText, subjectChangeRefusal } from './relations/model.js';
import { createSubjectTab } from './relations/subject.js';
import { createAllTab } from './relations/all.js';
import { createCompareTab } from './relations/compare.js';
import { createJournalTab } from './relations/journal.js';
import {
  openAddPanel, openImportPanel, openOrphansPanel, openHarvestPanel, openSweepPanel, openHelpPanel,
} from './relations/panels.js';

/** The screen has its own stylesheet (css/pages/relations.css), loaded by the router. */
export const stylesheet = true;

const TABS = ['sujet', 'toutes', 'comparer', 'journal'];
const SESSION_RESULT = '0'.repeat(32);
// Recent subjects of this screen, kept apart for the simulation and the directory (a fictitious name never shows in
// directory mode, nor the other way round).
let recentMode = 'annuaire';
const recentKey = () => `domenia.relations.recent.v2.${recentMode}`;
const PART = 500_000;
const ORBS = '<div class="orbs" aria-hidden="true"><span class="orb a"></span><span class="orb b"></span><span class="orb c"></span></div>';
const SUBJECT_PANELS = ['ajouter', 'rechercher', 'detecter', 'session'];
const PAGE_PANELS = ['import', 'orphelines', 'moisson', 'releve', 'aide'];

function readRecent() {
  try {
    const list = JSON.parse(localStorage.getItem(recentKey()) ?? '[]');
    return Array.isArray(list) ? list.filter((x) => x && typeof x.dn === 'string' && typeof x.login === 'string').slice(0, 6) : [];
  } catch { return []; }
}

function writeRecent(list) {
  try { localStorage.setItem(recentKey(), JSON.stringify(list.slice(0, 6))); } catch { /* private mode: keep nothing */ }
}

function newId() {
  return [...crypto.getRandomValues(new Uint8Array(16))].map((b) => b.toString(16).padStart(2, '0')).join('');
}

function skeleton() {
  return `<div class="page rel">
    <section class="hero rel-hero reveal" data-slot="hero"><span class="glow-ring hero-ring" aria-hidden="true"></span>${ORBS}
      <div class="rel-hero-grid"><div class="rel-hero-main">${sk('w25')}${sk('rel-sk-title w40')}${sk('w85')}${sk('w70')}</div>
        <div class="rel-mix">${sk('rel-sk-ring')}${sk('w70')}${sk('w55')}</div></div></section>
    <div class="rel-pending-host" aria-live="polite"></div>
    <div class="rel-tabs-host"></div>
  </div>`;
}

/** Natures of the store (their sum is the total) and the contradiction figures apart (associations and workstations). */
function figures(o) {
  const value = (id) => o.badges.find((b) => b.badge === id)?.value ?? 0;
  const natures = NATURES.map((id) => ({ id, ...BADGES[id], value: value(id) }));
  return { natures, contradicted: value('contradictory') };
}

function heroChips(o, { compact }) {
  const chips = [];
  if (!compact) {
    chips.push(`<span class="chip" data-tip="${esc(o.summary)}">${glyph('link')}${esc(nouns(o.total, 'association', 'associations'))}</span>`);
    chips.push(`<span class="chip">${glyph('users')}${esc(nouns(o.users, 'utilisateur', 'utilisateurs'))} · ${esc(nouns(o.computers, 'poste', 'postes'))}</span>`);
  }
  if (o.contradictions > 0) {
    chips.push(`<button class="chip alert" type="button" data-hero="contra" data-tip="Ouvre « Toutes les associations » filtrée sur les contradictions : affectation déclarée et session observée divergent, les deux sont gardées.">${glyph('alert')}${esc(nouns(o.contradictions, 'poste contradictoire', 'postes contradictoires'))}</button>`);
  }
  if (o.unverified > 0) {
    chips.push(`<span class="chip warn" data-tip="Liens hérités sans GUID : identité non vérifiable, jamais rattachés par un nom réutilisé.">${glyph('info')}${esc(nouns(o.unverified, 'identité non vérifiable', 'identités non vérifiables'))}</span>`);
  }
  if (o.pending?.total > 0) {
    chips.push(`<button class="chip info" type="button" data-hero="pending" data-tip="${esc(o.pending.text)}">${glyph('clock')}${esc(nouns(o.pending.total, 'observation à enregistrer', 'observations à enregistrer'))}</button>`);
  }
  return chips.map((c, n) => c.replace('class="chip', `data-j="${n}" class="chip`)).join('');
}

// The actions of the header are a command bar of the kit (one Tab stop, arrows, « Plus » when the width runs out): the
// network reads carry the network mark of every screen, said to screen readers too. The single primary action of the screen
// lives in the work area (« Rechercher un sujet », then « Ajouter une association »).
const heroCommands = (act) => [
  { id: 'pick', label: 'Choisir un sujet', icon: 'search', pinned: true, run: () => act('pick') },
  { id: 'import', label: 'Importer', icon: 'download', run: () => act('import') },
  { id: 'harvest', label: 'Moisson', icon: 'history', kind: 'network', run: () => act('harvest') },
  { id: 'sweep', label: 'Relevé', icon: 'monitor', kind: 'network', run: () => act('sweep') },
  { id: 'orphans', label: 'Orphelines', icon: 'trash', run: () => act('orphans') },
  { id: 'help', label: 'Précautions des relations', icon: 'info', iconOnly: true, pinned: true, run: () => act('help') },
];

function fullHeroMarkup(o, sim) {
  const { natures, contradicted } = figures(o);
  const segments = natures.filter((b) => b.value > 0).map((b) => ({ value: b.value, cls: `rel-seg-${b.id}`, key: b.id }));
  const max = Math.max(1, ...natures.map((b) => b.value));
  const activity = o.activity.map((d, n) => ({ x: n, value: d.observed + d.history }));
  const today = o.activity.at(-1);
  const last = o.lastImport;
  return `<div class="rel-hero-grid">
    <div class="rel-hero-main">
      <div class="eyebrow">${glyph('link')}<span>Associations utilisateurs ↔ postes</span><span class="rel-eyebrow-store">${glyph(sim ? 'sparkles' : 'database')}${esc(o.storeLabel)}</span></div>
      <h1 class="gradient-text">Utilisateurs et postes</h1>
      <p class="lead">Qui utilise quel poste, et comment on le sait${NBSP}: affectation déclarée, session observée, historique ou indice, chacun avec sa source et sa date. Associations locales à Domenia${NBSP}: Active Directory n’est jamais modifié.</p>
      <div class="chips">${heroChips(o, { compact: false })}</div>
      <div class="hero-row rel-hero-actions"></div>
    </div>
    <aside class="rel-mix" aria-label="Répartition des natures de preuve">
      <div class="rel-mix-top">${donut(segments, { total: o.total, center: `<b class="num" data-count="${o.total}">0</b><span>associations</span>`, label: o.summary, size: 'rel-ring' })}
        <ul class="rel-mix-legend">${natures.map((b, j) => `<li data-badge="${b.id}" data-j="${j}" data-tip="${esc(b.tip)}">${dot(b.id)}<span class="name">${esc(b.label)}</span><b class="num">${int(b.value)}</b>
          <span class="rel-meter" aria-hidden="true"><span data-p="${(b.value / max).toFixed(3)}"></span></span></li>`).join('')}</ul></div>
      ${contradicted > 0 ? `<button class="rel-mix-contra" type="button" data-hero="contra" data-tip="${esc(BADGES.contradictory.tip)}">${glyph('alert')}<span><b>${int(contradicted)}</b> ${esc(contradicted > 1 ? 'associations en contradiction' : 'association en contradiction')} sur <b>${int(o.contradictions)}</b> ${esc(o.contradictions > 1 ? 'postes' : 'poste')}</span>${glyph('chevronRight')}</button>` : ''}
      <div class="rel-activity"><div class="rel-activity-head"><span>${glyph('activity')}Observations et relevés · 14 jours</span><b>${esc(nouns((today?.observed ?? 0) + (today?.history ?? 0), 'aujourd’hui', 'aujourd’hui'))}</b></div>
        ${sparkline(activity, { w: 300, h: 50 })}<div class="rel-activity-x" aria-hidden="true"><span>${esc(o.activity[0]?.label ?? '')}</span><span>${esc(o.activity.at(-1)?.label ?? '')}</span></div></div>
      ${last ? `<p class="rel-mix-import" data-tip="${esc(last.tip)}">${glyph('download')}<span>Dernier import${NBSP}: ${esc(last.source.replace('Import ', ''))} · ${esc(nouns(last.count, 'ligne', 'lignes'))} · ${esc(dateText(last.importedAt) ?? '')}</span></p>` : ''}
    </aside>
  </div>`;
}

function compactHeroMarkup(o) {
  const { natures } = figures(o);
  const segments = natures.filter((b) => b.value > 0).map((b) => ({ value: b.value, cls: `rel-seg-${b.id}`, key: b.id }));
  return `<div class="rel-hero-bar">
    ${donut(segments, { total: o.total, center: `<b class="num">${int(o.total)}</b>`, label: o.summary, size: 'rel-ring-sm' })}
    <div class="rel-hero-id">
      <h1 class="gradient-text">Utilisateurs et postes</h1>
      <p class="rel-hero-stats"><span>${esc(nouns(o.total, 'association', 'associations'))}</span><span>${esc(nouns(o.users, 'utilisateur', 'utilisateurs'))}</span><span>${esc(nouns(o.computers, 'poste', 'postes'))}</span></p>
    </div>
    <div class="chips rel-hero-flags">${heroChips(o, { compact: true })}</div>
    <div class="rel-hero-actions"></div>
  </div>`;
}

function pendingMarkup(p) {
  const session = p.sets.find((s) => s.resultId === SESSION_RESULT);
  const sources = (session?.sources ?? []).slice(0, 4);
  return `<section class="rel-pending" role="region" aria-label="Observations en attente de mémorisation">
    <span class="rel-pending-ico" aria-hidden="true">${glyph('clock')}<span class="rel-pending-pulse"></span></span>
    <div class="rel-pending-text"><b>${esc(nouns(p.total, 'observation en mémoire', 'observations en mémoire'))}, mémorisation automatique en attente</b>
      <span>${sources.map((s) => `<span class="rel-pending-src">${esc(s.source)} · ${int(s.count)}</span>`).join('')}${(session?.sources.length ?? 0) > 4 ? `<span class="rel-pending-src">…</span>` : ''}</span>
      <small>${esc(nouns(p.batches, 'lot', 'lots'))} de 64 au plus, mémorisés dans la base locale sans confirmation et tracés au journal des associations. Active Directory n’est jamais modifié.</small></div>
    <div class="rel-pending-actions">
      <button class="btn sm" type="button" data-pending="all">${glyph('check')}Mémoriser maintenant<span class="k-cmd-mark" aria-hidden="true">${glyph('edit')}</span><span class="visually-hidden">, écriture locale</span></button>
    </div>
  </section>`;
}

export function render(main, ctx) {
  main.innerHTML = skeleton();
  const page = main.querySelector('.page');
  const stops = [];
  let tabs = null;
  let subjectTab = null;
  let allTab = null;
  let compareTab = null;
  let journalTab = null;
  let overview = null;
  let session = null;
  let heroMode = null;
  let heroBar = null;
  let heroKey = '';
  let overviewStamp = 0;
  let subjectRef = cleanRef(ctx.params.sujet ?? ctx.params.dn);
  let subjectRequest = 0;
  let listLoaded = false;
  let journalLoaded = false;
  let work = null; // { name, ctl } — the docked work panel
  let saving = false;
  let autoTimer = 0;
  let autoStuckAt = -1;
  const exportListeners = new Set();
  const handedList = loadedList(ctx.params.liste);
  const routeParams = { ...ctx.params };
  delete routeParams.panneau;

  const app = {
    ctx,
    params: ctx.params,
    alive: true,
    simulated: false,
    lastExport: null,
    select, clear, openPanel, plan, restore, undoImport, rowMenu, compareWith, openFiche, openRelationEnd, remember, refreshList, touch,
    saveBatches, exportCsv, openExport, onExport: (fn) => { exportListeners.add(fn); return () => exportListeners.delete(fn); },
    recent: readRecent,
    scopeLabel: () => session?.scope?.label ?? '',
    scopeDn: () => session?.scope?.dn ?? null,
    /** Workstations of the list loaded elsewhere (route « liste »), or those shown in « Toutes les associations ». */
    loadedComputers: () => {
      if (handedList.length) return { names: handedList, label: `liste reçue de l’écran précédent (${nouns(handedList.length, 'poste', 'postes')})` };
      const shown = allTab?.visibleComputers() ?? [];
      return shown.length ? { names: shown.slice(0, 50), label: `postes affichés dans « Toutes les associations » (${nouns(Math.min(50, shown.length), 'poste', 'postes')}${shown.length > 50 ? ` sur ${int(shown.length)}` : ''})` } : null;
    },
  };

  // ---------- URL (kept in sync without rendering the screen again) ----------
  function remember(change) {
    Object.assign(routeParams, change);
    for (const [k, v] of Object.entries(routeParams)) if (v === null || v === undefined || v === '') delete routeParams[k];
    try { history.replaceState(null, '', ctx.link('relations', routeParams)); } catch (err) { console.error(err); }
  }

  // ---------- Header ----------
  const wantCompact = () => {
    const tab = tabs?.current() ?? (TABS.includes(ctx.params.onglet) ? ctx.params.onglet : 'sujet');
    return !(tab === 'sujet' && !subjectRef);
  };

  /** Paints the header for the current view; figures count up the first time only, a change of view rises in. */
  function paintHero(force = false) {
    if (!overview) return;
    const mode = wantCompact() ? 'compact' : 'full';
    const key = `${mode}|${overviewStamp}`;
    if (!force && key === heroKey) return;
    heroKey = key;
    const hero = page.querySelector('.rel-hero');
    const first = heroMode === null;
    const swap = !first && mode !== heroMode;
    heroMode = mode;
    hero.classList.toggle('compact', mode === 'compact');
    hero.classList.remove('swap');
    if (swap) { void hero.offsetWidth; hero.classList.add('swap'); }
    const body = hero.querySelector('.rel-hero-grid, .rel-hero-bar');
    const markup = mode === 'compact' ? compactHeroMarkup(overview) : fullHeroMarkup(overview, app.simulated);
    if (body) body.outerHTML = markup; else hero.insertAdjacentHTML('beforeend', markup);
    heroBar?.destroy?.();
    heroBar = createCommandBar(hero.querySelector('.rel-hero-actions'), { label: 'Actions des associations', items: heroCommands(heroAct), size: mode === 'compact' ? 'sm' : 'md' });
    applyVars(hero);
    hero.querySelectorAll('[data-count]').forEach((el) => {
      if (first || force) countUp(el, Number(el.dataset.count), { delay: 200 });
      else el.textContent = int(Number(el.dataset.count));
    });
    // After the first entrance, a repaint (new figures, other view) shows its final state without replaying every entrance.
    if (first) setTimeout(() => hero.classList.add('settled'), 1600);
  }

  function paintPending() {
    const host = page.querySelector('.rel-pending-host');
    const p = overview?.pending;
    if (!p || p.total === 0) { host.innerHTML = ''; return; }
    host.innerHTML = pendingMarkup(p);
    host.querySelectorAll('[data-pending]').forEach((b) => { b.disabled = saving; });
    scheduleAutoSave(p.total);
  }

  // Observations handed by another screen wait in the engine: they are memorized after 1.5 s of calm (Domenia 1 REL-014). A
  // memorization that saved nothing is not retried for the same count (the banner keeps « Mémoriser maintenant »).
  function scheduleAutoSave(total) {
    clearTimeout(autoTimer);
    if (saving || total === autoStuckAt) return;
    autoTimer = setTimeout(() => {
      if (!app.alive) return;
      saveBatches(SESSION_RESULT, { origin: 'Observations de la session', quiet: true }).then((saved) => { if (saved === 0) autoStuckAt = total; });
    }, 1500);
  }
  stops.push(() => clearTimeout(autoTimer));

  // ---------- Data ----------
  async function loadOverview() {
    try {
      overview = await ctx.call('relations.overview');
      overviewStamp += 1;
      if (!app.alive) return;
      paintHero();
      paintPending();
      tabs?.setCount('toutes', overview.total, 'off');
      tabs?.setCount('journal', overview.journalEntries, 'off');
    } catch (err) {
      if (!app.alive) return;
      const hero = page.querySelector('.rel-hero');
      const body = hero.querySelector('.rel-hero-grid, .rel-hero-bar');
      const markup = `<div class="rel-hero-grid"><div class="rel-hero-main"><div class="eyebrow">${glyph('link')}<span>Associations utilisateurs ↔ postes</span></div>
        <h1 class="gradient-text">Utilisateurs et postes</h1><p class="lead" role="alert">${glyph('alert')}${esc(errText(err))}</p>
        <div class="hero-row"><button class="btn" type="button" data-retry-hero>${glyph('refresh')}Réessayer</button></div></div></div>`;
      if (body) body.outerHTML = markup; else hero.insertAdjacentHTML('beforeend', markup);
      hero.querySelector('[data-retry-hero]').addEventListener('click', loadOverview);
    }
  }

  /** The operator chooses a subject: the Sujet tab shows it (unless an association in progress keeps the current one). */
  function select(ref) {
    const clean = cleanRef(ref);
    if (!clean) return;
    const current = subjectTab?.current()?.subject;
    const same = current && [current.dn, current.login, current.name].some((x) => x && x.toLowerCase() === clean.toLowerCase());
    if (work && SUBJECT_PANELS.includes(work.name) && !same) {
      const refusal = subjectChangeRefusal(work.ctl.associationState?.() ?? 'idle');
      if (refusal) { toast(refusal, { tone: 'warn' }); announce(refusal); return; }
      // A detection plan or a search belongs to its subject: it is cancelled with the change (Domenia 1 D047).
      work.ctl.close();
    }
    subjectRef = clean;
    remember({ sujet: clean, onglet: null });
    if (!subjectTab) { tabs?.select('sujet'); return; }
    if (tabs && tabs.current() !== 'sujet') tabs.select('sujet');
    refreshSubject();
  }

  /** Reads the subject again without moving the operator (after a write, at the end of a panel’s reads). */
  async function refreshSubject() {
    if (!subjectTab || !subjectRef) return;
    const clean = subjectRef;
    const my = ++subjectRequest;
    const shown = subjectTab.current();
    if (!shown || ![shown.subject.dn, shown.subject.login, shown.subject.name].some((x) => x && x.toLowerCase() === clean.toLowerCase())) subjectTab.loading(clean);
    paintHero();
    try {
      const res = await ctx.call('relations.subject', { ref: clean });
      if (!app.alive || my !== subjectRequest) return;
      subjectTab.show(res);
      const recent = readRecent().filter((r) => r.dn.toLowerCase() !== res.subject.dn.toLowerCase());
      recent.unshift({ dn: res.subject.dn, login: res.subject.login, kind: res.subject.kind });
      writeRecent(recent);
      subjectTab.paintRecent();
      subjectRef = res.subject.kind === 'user' ? res.subject.login : res.subject.name;
      if (tabs?.current() === 'sujet') remember({ sujet: subjectRef });
    } catch (err) {
      if (!app.alive || my !== subjectRequest) return;
      subjectTab.failed(clean, err);
    }
  }

  function clear() {
    subjectRef = null;
    subjectRequest++;
    remember({ sujet: null, vue: null });
    subjectTab?.landing();
    paintHero();
  }

  async function refreshList() {
    if (!allTab) return;
    allTab.loading();
    try {
      const list = await ctx.call('relations.list');
      if (app.alive) allTab.show(list);
    } catch (err) {
      if (app.alive) allTab.failed(err);
    }
  }

  async function refreshJournal() {
    if (!journalTab) return;
    try {
      const journal = await ctx.call('relations.journal');
      if (app.alive) journalTab.show(journal);
    } catch (err) {
      if (app.alive) journalTab.failed(err);
    }
  }

  /** After a write: every view reads the store again (nothing is patched locally); the operator stays where he is. */
  function refreshAll() {
    loadOverview();
    refreshSubject();
    if (listLoaded) refreshList();
    if (journalLoaded) refreshJournal();
    work?.ctl.refresh?.();
  }

  /** A network read of a panel added session observations: the views are read again (the panel stays open). */
  function touch() {
    loadOverview();
    refreshSubject();
    if (listLoaded) refreshList();
  }

  // ---------- Writes (plan, confirmation, receipt, re-read: docs/WRITES.md § 7) ----------
  function plan(op, args, subtitle) {
    return runWrite(ctx, { plan: op, args, subtitle: subtitle ?? 'Associations locales · Active Directory non modifié', onDone: () => refreshAll() });
  }
  function restore(entryId) { return plan('relations.restore.plan', { entry: entryId ?? null }); }
  function undoImport(batchId) { return plan('relations.import.undo.plan', { batch: batchId ?? null }); }

  /**
   * Memorizes the observations kept by the engine (choice of 22/10, Domenia 1 REL-014): the engine saves them into the local
   * base by batches of 64, without confirmation, each change traced in the journal of the associations; Active Directory is
   * never written. Every observation of the session leaves at once (resultId only names the read that asked). Resolves with the
   * number of observations memorized.
   */
  async function saveBatches(resultId, { origin = 'Observations', quiet = false } = {}) {
    if (saving) { if (!quiet) toast('Une mémorisation est déjà en cours.', { tone: 'info' }); return 0; }
    saving = true;
    paintPending();
    let saved = 0;
    try {
      const res = await ctx.call('relations.observations.save');
      saved = res?.saved ?? 0;
      if (!app.alive) return saved;
      if (saved > 0 || !quiet) toast(`${origin}${NBSP}: ${res?.text ?? ''}`, { tone: res?.remaining > 0 ? 'warn' : 'ok' });
      announce(res?.text ?? '');
    } catch (err) {
      console.error(err);
      if (app.alive) toast(`${origin}${NBSP}: mémorisation refusée. Les observations restent en mémoire pour la session.`, { tone: 'warn' });
    } finally {
      saving = false;
      if (app.alive) refreshAll();
    }
    return saved;
  }

  // ---------- Exports (Domenia 1 REL-050: a CSV file and « Ouvrir le CSV ») ----------
  async function exportCsv(subject, csv) {
    const id = newId();
    const parts = Math.max(1, Math.ceil(csv.length / PART));
    try {
      let answer = null;
      for (let i = 0; i < parts; i++) {
        answer = await ctx.call('relations.export.save', { id, part: i, parts, subject, text: csv.slice(i * PART, (i + 1) * PART) });
      }
      const result = answer?.result ?? null;
      if (!result) return null;
      app.lastExport = result;
      exportListeners.forEach((fn) => fn(result));
      toast(result.message, { tone: result.saved ? 'ok' : 'info' });
      return result;
    } catch (err) {
      toast(errText(err), { tone: 'warn' });
      return null;
    }
  }

  async function openExport(fileName) {
    try {
      const res = await ctx.call('relations.export.open', { fileName });
      toast(res.message, { tone: res.opened ? 'ok' : 'warn' });
    } catch (err) {
      toast(errText(err), { tone: 'warn' });
    }
  }

  // ---------- Panels (docked: the plan of a write opens over them, they carry on after its receipt) ----------
  function current() { return subjectTab?.current()?.subject ?? null; }

  function openPanel(name, options = {}) {
    let ctl = null;
    if (name === 'aide') { openHelpPanel(); return; }
    if (SUBJECT_PANELS.includes(name) && !current()) {
      toast('Choisissez d’abord un utilisateur ou un poste.', { tone: 'info' });
      subjectTab?.focusPicker();
      return;
    }
    // One work panel at a time: a new one replaces the previous one (its reads in progress are stopped).
    work?.ctl.close();
    if (name === 'import') ctl = openImportPanel(app, overview?.lastImport ?? null);
    else if (name === 'orphelines') ctl = openOrphansPanel(app);
    else if (name === 'moisson') ctl = openHarvestPanel(app);
    else if (name === 'releve') ctl = openSweepPanel(app);
    else if (SUBJECT_PANELS.includes(name)) {
      const s = current();
      const mode = name === 'ajouter' ? 'rechercher' : name === 'session' && s.kind === 'user' ? 'detecter' : name === 'detecter' && s.kind === 'computer' ? 'session' : name;
      ctl = openAddPanel(app, s, mode, options);
    }
    if (!ctl) return;
    const entry = { name, ctl };
    work = entry;
    ctl.closed?.then(() => {
      if (work === entry) work = null;
    });
  }

  /** Opens the fiche of an object: by its DN, or by its name when the association kept none (Domenia 1 REL-051). */
  function openFiche(target) {
    if (!target) return;
    if (typeof target === 'string') { ctx.navigate('fiche', { dn: target }); return; }
    if (target.dn) ctx.navigate('fiche', { dn: target.dn });
    else if (target.name) ctx.navigate('fiche', { q: target.name });
  }

  function openRelationEnd(row, kind, fiche = false) {
    const dn = kind === 'user' ? row.userTargetDn : row.computerTargetDn;
    const guid = kind === 'user' ? row.userGuid : row.computerGuid;
    const name = kind === 'user' ? row.userLogin : row.computer;
    if (dn) { if (fiche) openFiche({ dn }); else select(dn); return; }
    if (guid) {
      toast('Objet non retrouvé par son GUID dans l’index local. Actualisez l’annuaire avant de l’ouvrir.', { tone: 'warn' });
      return;
    }
    toast('Association ancienne sans GUID : recherche du nom historique, identité à vérifier.', { tone: 'info' });
    openFiche({ name });
  }

  function compareWith(s) {
    tabs?.select('comparer');
    compareTab?.prefill(s.login, '', false);
  }

  // Context menu of a row (subject list, every association): open either end, its fiche, save or remove, copy.
  function rowMenu(row, mode) {
    const userUnknown = !!row.userGuid && !row.userTargetDn;
    const computerUnknown = !!row.computerGuid && !row.computerTargetDn;
    const identityReason = 'GUID non retrouvé dans l’index local ; aucun repli sur un homonyme.';
    const items = [{ heading: `${row.userLogin} → ${row.computer}` }];
    if (mode !== 'computer') items.push({ label: row.userTargetDn ? 'Voir les relations de l’utilisateur' : 'Rechercher l’identifiant historique', icon: 'user', disabled: userUnknown, reason: identityReason, run: () => openRelationEnd(row, 'user') });
    if (mode !== 'user') items.push({ label: row.computerTargetDn ? 'Voir les relations du poste' : 'Rechercher le nom historique du poste', icon: 'monitor', disabled: computerUnknown, reason: identityReason, run: () => openRelationEnd(row, 'computer') });
    items.push({ label: 'Ouvrir la fiche', icon: 'external', items: [
      { label: row.userTargetDn ? 'De l’utilisateur' : 'De l’utilisateur (recherche du nom historique)', icon: 'user', disabled: userUnknown, reason: identityReason, run: () => openRelationEnd(row, 'user', true) },
      { label: row.computerTargetDn ? 'Du poste' : 'Du poste (recherche du nom historique)', icon: 'monitor', disabled: computerUnknown, reason: identityReason, run: () => openRelationEnd(row, 'computer', true) },
    ] });
    items.push({ label: 'Copier', icon: 'copy', items: [
      { label: 'Le couple utilisateur → poste', run: () => writeClipboard(`${row.userLogin} → ${row.computer}`) },
      { label: 'Le DN du poste', disabled: !row.computerDn, reason: 'DN inconnu : association héritée sans GUID.', run: () => writeClipboard(row.computerDn) },
      { label: 'Le DN de l’utilisateur', disabled: !row.userDn, reason: 'DN inconnu : association héritée sans GUID.', run: () => writeClipboard(row.userDn) },
    ] });
    items.push('-');
    if (row.persistence === 'session') {
      items.push({ label: 'Enregistrer l’observation…', icon: 'check', kind: 'write', run: () => plan('relations.observations.plan', { resultId: SESSION_RESULT, keys: [row.key] }) });
    } else {
      items.push({ label: 'Retirer l’association…', icon: 'trash', kind: 'write', danger: true, run: () => plan('relations.remove.plan', { key: row.key, fingerprint: row.fingerprint }) });
    }
    return items;
  }

  // ---------- Session change (Domenia 1 REL-047): everything of the previous session is put down, nothing is saved ----------
  const identity = (s) => (s ? `${s.connection?.state ?? ''}|${s.domain?.dnsName ?? ''}|${s.account?.login ?? ''}` : '');
  function resetForSession() {
    work?.ctl.close();
    work = null;
    subjectRef = null;
    subjectRequest++;
    remember({ sujet: null, vue: null, onglet: null, a: null, b: null });
    subjectTab?.landing();
    compareTab?.reset();
    tabs?.select('sujet');
    loadOverview();
    if (listLoaded) refreshList();
    if (journalLoaded) refreshJournal();
    toast(`Session changée${NBSP}: sujet, recherches et observations de l’ancienne session écartés. Rien n’a été enregistré ni retiré.`, { tone: 'info', life: 8000 });
  }
  async function checkSession() {
    try {
      const next = await ctx.call('session.info');
      if (!app.alive || !session) return;
      if (identity(next) !== identity(session)) { session = next; resetForSession(); } else session = next;
    } catch (err) { console.error(err); }
  }
  stops.push(onEvent('session.changed', () => { if (app.alive) checkSession(); }));
  const onFocus = () => { if (app.alive) checkSession(); };
  window.addEventListener('focus', onFocus);
  stops.push(() => window.removeEventListener('focus', onFocus));

  // ---------- Tabs ----------
  function buildTabs() {
    const host = page.querySelector('.rel-tabs-host');
    const wanted = TABS.includes(ctx.params.onglet) ? ctx.params.onglet : 'sujet';
    tabs = createTabs(host, {
      label: 'Vues des relations',
      selected: wanted,
      tabs: [
        { id: 'sujet', label: 'Sujet', icon: 'user', render: (panel) => { subjectTab = createSubjectTab(panel, app); if (subjectRef) refreshSubject(); else subjectTab.landing(); return () => subjectTab.destroy(); } },
        { id: 'toutes', label: 'Toutes les associations', icon: 'layers', count: overview?.total ?? null, render: (panel) => {
          allTab = createAllTab(panel, app, { facet: ctx.params.filtre === 'contradictoire' ? 'contradictory' : null });
          listLoaded = true; refreshList(); return () => allTab.destroy();
        } },
        { id: 'comparer', label: 'Comparer deux utilisateurs', icon: 'split', render: (panel) => {
          compareTab = createCompareTab(panel, app);
          const a = cleanRef(ctx.params.a) ?? (current()?.kind === 'user' ? current().login : null);
          compareTab.prefill(a, cleanRef(ctx.params.b), app.simulated && Boolean(cleanRef(ctx.params.a) && cleanRef(ctx.params.b)));
          return () => compareTab.destroy();
        } },
        { id: 'journal', label: 'Journal', icon: 'history', render: (panel) => { journalTab = createJournalTab(panel, app); journalLoaded = true; refreshJournal(); return () => journalTab.destroy(); } },
      ],
      onChange: (id) => { remember({ onglet: id === 'sujet' ? null : id }); paintHero(); },
    });
  }

  function showContradictions() {
    tabs?.select('toutes');
    remember({ onglet: 'toutes', filtre: 'contradictoire' });
    allTab?.pressFacet('contradictory');
  }

  // ---------- Header and pending actions ----------
  page.addEventListener('click', (e) => {
    const t = e.target instanceof Element ? e.target : null;
    const pending = t?.closest('[data-pending]');
    if (pending) {
      saveBatches(SESSION_RESULT, { origin: 'Observations de la session' });
      return;
    }
    const b = t?.closest('[data-hero]');
    if (b) heroAct(b.dataset.hero);
  });

  function heroAct(act) {
    if (act === 'pick') { tabs?.select('sujet'); setTimeout(() => subjectTab?.focusPicker(), 60); }
    else if (act === 'import') openPanel('import');
    else if (act === 'harvest') openPanel('moisson');
    else if (act === 'sweep') openPanel('releve');
    else if (act === 'orphans') openPanel('orphelines');
    else if (act === 'help') openPanel('aide');
    else if (act === 'contra') showContradictions();
    else if (act === 'pending') page.querySelector('.rel-pending')?.scrollIntoView({ block: 'nearest', behavior: 'smooth' });
  }

  // ---------- Start ----------
  (async () => {
    const info = await Promise.resolve(ctx.app).catch(() => null);
    app.simulated = info?.mode === 'simulation' || info?.webViewRuntime === 'apercu';
    recentMode = app.simulated ? 'simulation' : 'annuaire';
    try { session = await ctx.call('session.info'); } catch (err) { console.error(err); }
    if (!app.alive) return;
    buildTabs();
    stops.push(reveal(page));
    await loadOverview();
    if (!app.alive) return;
    const panel = ctx.params.panneau;
    if (panel && SUBJECT_PANELS.includes(panel)) {
      // Waits for the subject read of the route, then opens its panel (nothing is read on the network by opening it).
      let tries = 0;
      const wait = () => {
        if (!app.alive) return;
        if (current()) openPanel(panel);
        else if (subjectRef && tries++ < 80) setTimeout(wait, 120);
      };
      wait();
    } else if (panel && PAGE_PANELS.includes(panel)) {
      openPanel(panel);
    }
  })();

  return () => {
    app.alive = false;
    heroBar?.destroy?.();
    stops.forEach((fn) => fn());
    work?.ctl.close();
    tabs?.destroy();
  };
}
