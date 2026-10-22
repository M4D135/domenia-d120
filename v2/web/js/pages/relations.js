// Utilisateurs et postes: associations between users and workstations, in both directions (Domenia 1 Relations, REL-001
// to REL-052, and the comparison of the groups of two users, R40). Hero with the figures of the local store and the main
// actions, then four tabs: the subject (identity, primary relation, statements, animated graph, list, chronology, recent
// logons), every association (facets and grid), the comparison of two users, and the local journal with the removals that
// can be restored. Every change goes through the write circuit (runWrite: plan, confirmation, receipt, re-read); every
// network read starts on an explicit gesture. Contract: docs/ops/relations.md.
//
// Parameters: onglet=sujet|toutes|comparer|journal · sujet=<DN, identifiant ou nom de poste> · vue=graphe|liste|chronologie ·
// panneau=ajouter|rechercher|detecter|session|import|orphelines|moisson|releve|aide · a=<compte A> · b=<compte B>.
import { glyph } from '../kit/glyphs.js';
import { createTabs } from '../kit/tabs.js';
import { writeClipboard } from '../kit/util.js';
import { runWrite } from '../write-flow.js';
import { applyVars, reveal, countUp, donut, sparkline, toast } from '../ui.js';
import { BADGES, BADGE_ORDER, dot, esc, int, nouns, NBSP, errText, cleanRef, sk } from './relations/model.js';
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
const RECENT_KEY = 'domenia.relations.recent.v1';
const ORBS = '<div class="orbs" aria-hidden="true"><span class="orb a"></span><span class="orb b"></span><span class="orb c"></span></div>';

function readRecent() {
  try {
    const list = JSON.parse(localStorage.getItem(RECENT_KEY) ?? '[]');
    return Array.isArray(list) ? list.filter((x) => x && typeof x.dn === 'string' && typeof x.login === 'string').slice(0, 6) : [];
  } catch { return []; }
}

function writeRecent(list) {
  try { localStorage.setItem(RECENT_KEY, JSON.stringify(list.slice(0, 6))); } catch { /* private mode: keep nothing */ }
}

function skeleton() {
  return `<div class="page rel">
    <section class="hero rel-hero reveal" data-slot="hero"><span class="glow-ring hero-ring" aria-hidden="true"></span>${ORBS}
      <div class="rel-hero-grid"><div class="rel-hero-main">${sk('w25')}${sk('rel-sk-title w40')}${sk('w85')}${sk('w70')}</div>
        <div class="rel-mix">${sk('rel-sk-ring')}${sk('w70')}${sk('w55')}</div></div></section>
    <div class="rel-tabs-host"></div>
  </div>`;
}

function heroMarkup(o, sim) {
  const badges = BADGE_ORDER.map((id) => ({ id, ...BADGES[id], value: o.badges.find((b) => b.badge === id)?.value ?? 0 }));
  const segments = badges.filter((b) => b.value > 0).map((b) => ({ value: b.value, cls: `rel-seg-${b.id}`, key: b.id }));
  const max = Math.max(1, ...badges.map((b) => b.value));
  const activity = o.activity.map((d, n) => ({ x: n, value: d.observed + d.history }));
  const lastObserved = o.activity.at(-1);
  const chips = [
    `<span class="chip" data-tip="${esc(o.summary)}">${glyph('link')}${esc(nouns(o.total, 'association', 'associations'))}</span>`,
    `<span class="chip">${glyph('users')}${esc(nouns(o.users, 'utilisateur', 'utilisateurs'))} · ${esc(nouns(o.computers, 'poste', 'postes'))}</span>`,
    o.contradictions > 0 ? `<button class="chip alert" type="button" data-hero="contra" data-tip="Affectation déclarée et session observée divergent : les deux sont conservées.">${glyph('alert')}${esc(nouns(o.contradictions, 'poste contradictoire', 'postes contradictoires'))}</button>` : '',
    o.unverified > 0 ? `<span class="chip warn" data-tip="Liens hérités sans GUID : identité non vérifiable, jamais rattachés par un nom réutilisé.">${glyph('info')}${esc(nouns(o.unverified, 'identité non vérifiable', 'identités non vérifiables'))}</span>` : '',
    o.sessionOnly > 0 ? `<span class="chip info">${glyph('clock')}${esc(nouns(o.sessionOnly, 'observation de session', 'observations de session'))}</span>` : '',
    o.lastImport ? `<span class="chip" data-tip="${esc(o.lastImport.tip)}">${glyph('download')}Import ${esc(o.lastImport.source.replace('Import ', ''))} · ${esc(nouns(o.lastImport.count, 'ligne', 'lignes'))}</span>` : '',
  ].filter(Boolean).map((c, n) => c.replace('class="chip', `data-j="${n}" class="chip`)).join('');
  return `<div class="rel-hero-grid">
    <div class="rel-hero-main">
      <div class="eyebrow">${glyph('link')}<span>Associations utilisateurs ↔ postes</span><span class="rel-eyebrow-store">${glyph(sim ? 'sparkles' : 'database')}${esc(o.storeLabel)}</span></div>
      <h1 class="gradient-text">Utilisateurs et postes</h1>
      <p class="lead">Qui utilise quel poste, et comment on le sait${NBSP}: affectation déclarée, session observée, historique ou indice, chacun avec sa source et sa date. Associations locales à Domenia${NBSP}: Active Directory n’est jamais modifié.</p>
      <div class="chips">${chips}</div>
      <div class="hero-row rel-hero-actions">
        <button class="btn primary" type="button" data-hero="pick">${glyph('search')}Choisir un sujet</button>
        <button class="btn" type="button" data-hero="import">${glyph('download')}Importer</button>
        <button class="btn" type="button" data-hero="harvest" data-tip="Moisson du journal du contrôleur : lecture réseau, sur ce clic">${glyph('history')}Moisson<span class="rel-kind net" aria-hidden="true">${glyph('wifi')}</span></button>
        <button class="btn" type="button" data-hero="sweep" data-tip="Relevé des consoles de l’OU de travail : lecture réseau, sur ce clic">${glyph('monitor')}Relevé<span class="rel-kind net" aria-hidden="true">${glyph('wifi')}</span></button>
        <button class="btn ghost" type="button" data-hero="orphans" data-tip="Associations dont le compte ou le poste n’est plus dans l’annuaire">${glyph('trash')}Orphelines</button>
        <button class="btn ghost icon" type="button" data-hero="help" aria-label="Précautions des relations" data-tip="Précautions des relations">${glyph('info')}</button>
      </div>
    </div>
    <aside class="rel-mix" aria-label="Répartition des qualifications">
      <div class="rel-mix-top">${donut(segments, { total: o.total, center: `<b class="num" data-count="${o.total}">0</b><span>associations</span>`, label: o.summary, size: 'rel-ring' })}
        <ul class="rel-mix-legend">${badges.map((b, j) => `<li data-badge="${b.id}" data-j="${j}" data-tip="${esc(b.tip)}">${dot(b.id)}<span class="name">${esc(b.label)}</span><b class="num">${int(b.value)}</b>
          <span class="rel-meter" aria-hidden="true"><span data-p="${(b.value / max).toFixed(3)}"></span></span></li>`).join('')}</ul></div>
      <div class="rel-activity"><div class="rel-activity-head"><span>${glyph('activity')}Activité · 14 jours</span><b>${esc(nouns((lastObserved?.observed ?? 0) + (lastObserved?.history ?? 0), 'relevé aujourd’hui', 'relevés aujourd’hui'))}</b></div>
        ${sparkline(activity, { w: 300, h: 54 })}<div class="rel-activity-x" aria-hidden="true"><span>${esc(o.activity[0]?.label ?? '')}</span><span>${esc(o.activity.at(-1)?.label ?? '')}</span></div></div>
    </aside>
  </div>`;
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
  let subjectRef = cleanRef(ctx.params.sujet ?? ctx.params.dn);
  let subjectRequest = 0;
  let listLoaded = false;
  let journalLoaded = false;
  let stale = false;
  const routeParams = { ...ctx.params };
  delete routeParams.panneau;

  const app = {
    ctx,
    params: ctx.params,
    alive: true,
    simulated: false,
    select, clear, openPanel, plan, restore, undoImport, rowMenu, compareWith, openFiche, remember, refreshList, touch,
    recent: readRecent,
    scopeLabel: () => session?.scope?.label ?? '',
  };

  // ---------- URL (kept in sync without rendering the screen again) ----------
  function remember(change) {
    Object.assign(routeParams, change);
    for (const [k, v] of Object.entries(routeParams)) if (v === null || v === undefined || v === '') delete routeParams[k];
    try { history.replaceState(null, '', ctx.link('relations', routeParams)); } catch (err) { console.error(err); }
  }

  // ---------- Data ----------
  async function loadOverview() {
    try {
      overview = await ctx.call('relations.overview');
      if (!app.alive) return;
      paintHero();
    } catch (err) {
      if (!app.alive) return;
      const hero = page.querySelector('.rel-hero');
      hero.querySelector('.rel-hero-grid').innerHTML = `<div class="rel-hero-main"><div class="eyebrow">${glyph('link')}<span>Associations utilisateurs ↔ postes</span></div>
        <h1 class="gradient-text">Utilisateurs et postes</h1><p class="lead" role="alert">${glyph('alert')}${esc(errText(err))}</p>
        <div class="hero-row"><button class="btn" type="button" data-retry-hero>${glyph('refresh')}Réessayer</button></div></div>`;
      hero.querySelector('[data-retry-hero]').addEventListener('click', loadOverview);
    }
  }

  function paintHero() {
    const hero = page.querySelector('.rel-hero');
    hero.querySelector('.rel-hero-grid').outerHTML = heroMarkup(overview, app.simulated);
    applyVars(hero);
    hero.querySelectorAll('[data-count]').forEach((el) => countUp(el, Number(el.dataset.count), { delay: 200 }));
    tabs?.setCount('toutes', overview.total, 'off');
    tabs?.setCount('journal', overview.journalEntries, 'off');
  }

  async function select(ref) {
    const clean = cleanRef(ref);
    if (!clean) return;
    subjectRef = clean;
    // First display of the tab: its render reads the subject itself.
    if (!subjectTab) { tabs?.select('sujet'); return; }
    if (tabs && tabs.current() !== 'sujet') tabs.select('sujet');
    const my = ++subjectRequest;
    subjectTab.loading(clean);
    remember({ sujet: clean, onglet: null });
    try {
      const res = await ctx.call('relations.subject', { ref: clean });
      if (!app.alive || my !== subjectRequest) return;
      subjectTab.show(res);
      page.querySelector('.rel-hero')?.classList.add('compact');
      const recent = readRecent().filter((r) => r.dn.toLowerCase() !== res.subject.dn.toLowerCase());
      recent.unshift({ dn: res.subject.dn, login: res.subject.login, kind: res.subject.kind });
      writeRecent(recent);
      subjectTab.paintRecent();
      remember({ sujet: res.subject.kind === 'user' ? res.subject.login : res.subject.name });
    } catch (err) {
      if (!app.alive || my !== subjectRequest) return;
      subjectTab.failed(clean, err);
    }
  }

  function clear() {
    subjectRef = null;
    remember({ sujet: null });
    page.querySelector('.rel-hero')?.classList.remove('compact');
    subjectTab?.landing();
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

  /** After a write: every view reads the store again (nothing is patched locally). */
  function refreshAll() {
    loadOverview();
    if (subjectRef) select(subjectRef);
    if (listLoaded) refreshList();
    if (journalLoaded) refreshJournal();
  }

  /** A network read of a panel added session observations: views are read again when the panel closes. */
  function touch() { stale = true; }

  // ---------- Writes (plan, confirmation, receipt, re-read: docs/WRITES.md § 7) ----------
  function plan(op, args) {
    return runWrite(ctx, { plan: op, args, subtitle: 'Associations locales · Active Directory non modifié', onDone: () => refreshAll() });
  }
  function restore(entryId) { return plan('relations.restore.plan', { entry: entryId ?? null }); }
  function undoImport(batchId) { return plan('relations.import.undo.plan', { batch: batchId ?? null }); }

  // ---------- Panels ----------
  function current() { return subjectTab?.current()?.subject ?? null; }

  async function openPanel(name) {
    let ctl = null;
    if (name === 'import') ctl = openImportPanel(app, overview?.lastImport ?? null);
    else if (name === 'orphelines') ctl = openOrphansPanel(app);
    else if (name === 'moisson') ctl = openHarvestPanel(app);
    else if (name === 'releve') ctl = openSweepPanel(app);
    else if (name === 'aide') ctl = openHelpPanel();
    else if (['ajouter', 'rechercher', 'detecter', 'session'].includes(name)) {
      const s = current();
      if (!s) {
        toast('Choisissez d’abord un utilisateur ou un poste.', { tone: 'info' });
        subjectTab?.focusPicker();
        return;
      }
      const mode = name === 'ajouter' ? (s.kind === 'user' ? 'detecter' : 'session') : name === 'session' && s.kind === 'user' ? 'detecter' : name === 'detecter' && s.kind === 'computer' ? 'session' : name;
      ctl = openAddPanel(app, s, mode);
    }
    ctl?.closed?.then(() => {
      if (stale && app.alive) { stale = false; loadOverview(); if (subjectRef) select(subjectRef); if (listLoaded) refreshList(); }
    });
  }

  function openFiche(dn) {
    if (dn) ctx.navigate('fiche', { dn });
  }

  function compareWith(s) {
    tabs?.select('comparer');
    compareTab?.prefill(s.login, '', false);
  }

  // Context menu of a row (subject list, every association): open either end, its fiche, save or remove, copy.
  function rowMenu(row, mode) {
    const userRef = row.userDn ?? row.userLogin;
    const computerRef = row.computerDn ?? row.computer;
    const items = [{ heading: `${row.userLogin} → ${row.computer}` }];
    if (mode !== 'computer-only') {
      items.push({ label: 'Voir les relations de l’utilisateur', icon: 'user', run: () => select(userRef) });
      items.push({ label: 'Voir les relations du poste', icon: 'monitor', run: () => select(computerRef) });
    }
    items.push({ label: 'Ouvrir la fiche', icon: 'external', items: [
      { label: 'De l’utilisateur', icon: 'user', disabled: !row.userDn, reason: 'DN inconnu : association héritée sans GUID.', run: () => openFiche(row.userDn) },
      { label: 'Du poste', icon: 'monitor', disabled: !row.computerDn, reason: 'DN inconnu : association héritée sans GUID.', run: () => openFiche(row.computerDn) },
    ] });
    items.push({ label: 'Copier', icon: 'copy', items: [
      { label: 'Le couple utilisateur → poste', run: () => writeClipboard(`${row.userLogin} → ${row.computer}`) },
      { label: 'Le DN du poste', disabled: !row.computerDn, run: () => writeClipboard(row.computerDn) },
      { label: 'Le DN de l’utilisateur', disabled: !row.userDn, run: () => writeClipboard(row.userDn) },
    ] });
    items.push('-');
    if (row.persistence === 'session') {
      items.push({ label: 'Enregistrer l’observation…', icon: 'check', run: () => plan('relations.observations.plan', { resultId: SESSION_RESULT, keys: [row.key] }) });
    } else {
      items.push({ label: 'Retirer l’association…', icon: 'trash', danger: true, run: () => plan('relations.remove.plan', { key: row.key, fingerprint: row.fingerprint }) });
    }
    return items;
  }

  // ---------- Tabs ----------
  function buildTabs() {
    const host = page.querySelector('.rel-tabs-host');
    const wanted = TABS.includes(ctx.params.onglet) ? ctx.params.onglet : 'sujet';
    tabs = createTabs(host, {
      label: 'Vues des relations',
      selected: wanted,
      tabs: [
        { id: 'sujet', label: 'Sujet', icon: 'user', render: (panel) => { subjectTab = createSubjectTab(panel, app); if (subjectRef) select(subjectRef); else subjectTab.landing(); return () => subjectTab.destroy(); } },
        { id: 'toutes', label: 'Toutes les associations', icon: 'layers', count: overview?.total ?? null, render: (panel) => { allTab = createAllTab(panel, app); listLoaded = true; refreshList(); return () => allTab.destroy(); } },
        { id: 'comparer', label: 'Comparer deux utilisateurs', icon: 'split', render: (panel) => {
          compareTab = createCompareTab(panel, app);
          const a = cleanRef(ctx.params.a) ?? (current()?.kind === 'user' ? current().login : null);
          compareTab.prefill(a, cleanRef(ctx.params.b), app.simulated && Boolean(cleanRef(ctx.params.a) && cleanRef(ctx.params.b)));
          return () => compareTab.destroy();
        } },
        { id: 'journal', label: 'Journal', icon: 'history', render: (panel) => { journalTab = createJournalTab(panel, app); journalLoaded = true; refreshJournal(); return () => journalTab.destroy(); } },
      ],
      onChange: (id) => remember({ onglet: id === 'sujet' ? null : id }),
    });
  }

  // ---------- Hero actions ----------
  page.addEventListener('click', (e) => {
    const b = e.target instanceof Element ? e.target.closest('[data-hero]') : null;
    if (!b) return;
    const act = b.dataset.hero;
    if (act === 'pick') { tabs?.select('sujet'); setTimeout(() => subjectTab?.focusPicker(), 60); }
    else if (act === 'import') openPanel('import');
    else if (act === 'harvest') openPanel('moisson');
    else if (act === 'sweep') openPanel('releve');
    else if (act === 'orphans') openPanel('orphelines');
    else if (act === 'help') openPanel('aide');
    else if (act === 'contra') { tabs?.select('toutes'); }
  });

  // ---------- Start ----------
  (async () => {
    const info = await Promise.resolve(ctx.app).catch(() => null);
    app.simulated = info?.mode === 'simulation' || info?.webViewRuntime === 'apercu';
    try { session = await ctx.call('session.info'); } catch (err) { console.error(err); }
    if (!app.alive) return;
    buildTabs();
    stops.push(reveal(page));
    await loadOverview();
    if (!app.alive) return;
    const panel = ctx.params.panneau;
    if (panel) {
      const needsSubject = ['ajouter', 'rechercher', 'detecter', 'session'].includes(panel);
      if (needsSubject) {
        // Waits for the subject read of the route, then opens its panel (nothing is read on the network by opening it).
        let tries = 0;
        const wait = () => {
          if (!app.alive) return;
          if (current()) openPanel(panel);
          else if (subjectRef && tries++ < 80) setTimeout(wait, 120);
        };
        wait();
      } else if (['import', 'orphelines', 'moisson', 'releve', 'aide'].includes(panel)) {
        openPanel(panel);
      }
    }
  })();

  return () => {
    app.alive = false;
    stops.forEach((fn) => fn());
    tabs?.destroy();
  };
}
