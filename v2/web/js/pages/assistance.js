// Assistance: guided support paths and support workshop (Domenia 1 Domenia-Assistance, Domenia-Support, Insight, Dossier and
// Automation). The hero holds the session of assistance (the account and the workstation concerned); once a subject is chosen
// or another view is open it folds into a compact session bar. A vertical rail is the only navigation of the screen: Guider
// (guided paths), Comprendre (findings, A/B comparison, incidents), Garder (pins), Transmettre (support dossier and ticket,
// offline dossier). Data contract: docs/ops/assistance.md (assistance.*). Nothing here reads the network on its own: every
// read follows a click, a subject named exactly in the address (a navigation from another screen, read once, then taken out
// of the address) or, in simulation only, a demonstration parameter of the address used by the captures.
import { esc, errorText, reveal, applyVars, announce, motionReduced } from '../ui.js';
import { call as backgroundCall } from '../bridge.js';
import { bindCopy, openDrawer, confirmDialog, startFreshness } from '../kit/index.js';
import { ico, chip, tone, button, plural, COLON, NBSP } from './assistance/common.js';
import { renderSession, resolveSubject } from './assistance/subjects.js';
import { renderRecipes } from './assistance/recipes.js';
import { renderFindings, renderCompare, renderIncidents, renderPins } from './assistance/workshop.js';
import { renderDossier, renderOffline } from './assistance/documents.js';

/** The screen has its own stylesheet (css/pages/assistance.css), loaded by the router. */
export const stylesheet = true;

const VIEWS = [
  { id: 'parcours', group: 'Guider', label: 'Parcours guidés', icon: 'route', render: renderRecipes, hint: 'Pas à pas, par symptôme' },
  { id: 'constats', group: 'Comprendre', label: 'Constats', icon: 'bulb', render: renderFindings, hint: 'Analyse locale de la fiche' },
  { id: 'comparer', group: 'Comprendre', label: 'Comparer A / B', icon: 'compare', render: renderCompare, hint: 'Deux captures côte à côte' },
  { id: 'incidents', group: 'Comprendre', label: 'Incidents expliqués', icon: 'alert', render: renderIncidents, hint: 'Erreurs de la session' },
  { id: 'reperes', group: 'Garder', label: 'Repères', icon: 'pin', render: renderPins, hint: 'Fiches épinglées' },
  { id: 'dossier', group: 'Transmettre', label: 'Dossier et ticket', icon: 'ticket', render: renderDossier, hint: 'Texte relu, pseudonymes' },
  { id: 'horsligne', group: 'Transmettre', label: 'Dossier hors ligne', icon: 'archive', render: renderOffline, hint: 'Manifeste et SHA-256' },
];

const POLL_MS = 1000;

const defaults = () => ({
  report: { kind: 'support', ticket: '', template: 'text', subject: 'user', subjectChosen: false, incident: null, pseudonymize: false, sections: null },
  offline: { scope: 'subject', scopeChosen: false, sections: ['observations', 'associations', 'requetes'], ou: null, names: '' },
});

// The session of assistance survives a visit to another screen of the same session (the engine keeps the workshop; the
// page keeps its choices). It is forgotten as soon as the engine reports another session (TRV-185).
const memory = {
  session: null, // fingerprint of the session of the workshop (WorkshopView.session)
  user: null, // SubjectView of the account
  computer: null, // SubjectView of the workstation
  focus: 'user',
  view: 'parcours',
  recipe: 'logon',
  ...defaults(),
  diffOnly: true,
  incidentFilter: '',
};

function forgetSession() {
  Object.assign(memory, { user: null, computer: null, focus: 'user', incidentFilter: '', diffOnly: true, ...defaults() });
}

export function render(main, ctx) {
  const params = ctx.params ?? {};
  const listeners = new Map();
  const cleanups = [];
  let disposed = false;
  let viewCleanup = null;
  let pollTimer = 0;
  let polling = false;

  const app = {
    ctx,
    memory,
    simulation: false,
    overview: null,
    recipes: null,
    workshop: null,
    load: { running: 0, queued: 0 },
    running: new Set(),
    call: (op, args) => ctx.call(op, args),
    toast: (message, opts) => ctx.toast(message, opts),
    disposed: () => disposed,
    on(event, fn) {
      if (!listeners.has(event)) listeners.set(event, new Set());
      listeners.get(event).add(fn);
      return () => listeners.get(event)?.delete(fn);
    },
    emit(event) {
      if (disposed) return;
      for (const fn of [...(listeners.get(event) ?? [])]) {
        try { fn(); } catch (err) { console.error(err); }
      }
    },
    subject: (kind) => (kind === 'computer' ? memory.computer : memory.user),
    dnOf: (kind) => app.subject(kind)?.card?.dn ?? null,
    /** Keeps the freshness indicators of a newly painted scope up to date (one shared ticker of the kit). */
    freshen(scope) { startFreshness(scope); },
    /** Reads a subject (an explicit gesture or the address) and makes it the account or the workstation of the session. */
    async readSubject(kind, dn, { quiet = false } = {}) {
      app.setBusy(kind, true);
      try {
        const view = await app.call('assistance.subject.read', { dn });
        if (disposed) return null;
        const actual = view?.card?.kind === 'computer' ? 'computer' : 'user';
        memory[actual] = view;
        if (actual === kind || !app.subject(kind)) memory.focus = actual;
        app.emit('subjects');
        paintMode();
        await app.refreshRecipes();
        if (!quiet) announce(`${actual === 'computer' ? 'Poste' : 'Compte'} choisi${COLON}${view.card.name}.`);
        return view;
      } catch (err) {
        console.error(err);
        app.toast(`Lecture impossible${COLON}${errorText(err)}`, { tone: err?.code === 'assistance.sessionChanged' ? 'info' : 'alert' });
        if (err?.code === 'assistance.sessionChanged') checkSession(true);
        return null;
      } finally {
        app.setBusy(kind, false);
      }
    },
    clearSubject(kind) {
      memory[kind] = null;
      if (memory.focus === kind) memory.focus = kind === 'user' ? 'computer' : 'user';
      app.emit('subjects');
      paintMode();
      app.refreshRecipes();
    },
    busy: { user: false, computer: false },
    setBusy(kind, on) {
      app.busy[kind] = on;
      app.emit('busy');
    },
    async refreshRecipes() {
      try {
        app.recipes = await app.call('assistance.recipes', { user: app.dnOf('user'), computer: app.dnOf('computer') });
        app.emit('recipes');
      } catch (err) {
        console.error(err);
        app.toast(`Recettes indisponibles${COLON}${errorText(err)}`, { tone: 'alert' });
      }
    },
    setWorkshop(view) {
      if (!view) return;
      adoptSession(view.session);
      app.workshop = view;
      app.emit('workshop');
      updateCounts();
    },
    async refreshWorkshop({ background = false } = {}) {
      try {
        app.setWorkshop(await (background ? backgroundCall('assistance.workshop.get') : app.call('assistance.workshop.get')));
      } catch (err) {
        console.error(err);
      }
    },
    /** Runs a workshop operation and shows its refusal as a toast (the workshop stays as it was). */
    async workshopCall(op, args, success) {
      try {
        const view = await app.call(op, args);
        app.setWorkshop(view);
        if (success) app.toast(success, { tone: 'ok' });
        return view;
      } catch (err) {
        app.toast(errorText(err), { tone: err?.code === 'arguments.invalid' ? 'alert' : 'warn' });
        return null;
      }
    },
    go(view, extra = {}) {
      showView(view, extra);
    },
    keepAddress,
  };

  main.innerHTML = layout();
  const page = main.querySelector('.assist');
  const rail = page.querySelector('.as-rail');
  const viewHost = page.querySelector('.as-view');
  cleanups.push(bindCopy(page));
  // Hero and rail enter once (the views reveal their own cards).
  cleanups.push(reveal(page));
  // A greyed action stays focusable to say why (aria-disabled); its clicks never reach the handlers of the views.
  page.addEventListener('click', (e) => {
    const off = e.target instanceof Element ? e.target.closest('[aria-disabled="true"]') : null;
    if (off && page.contains(off)) { e.preventDefault(); e.stopPropagation(); }
  }, true);

  // ---------- Hero: the session of assistance, compact once at work ----------
  cleanups.push(renderSession(page.querySelector('[data-slot="session"]'), app));
  function paintMode() {
    const compact = memory.view !== 'parcours' || Boolean(memory.user || memory.computer);
    if (page.classList.contains('compact') === compact) return;
    page.classList.toggle('compact', compact);
    const hero = page.querySelector('.as-hero');
    hero.classList.remove('morph');
    if (!motionReduced()) { void hero.offsetWidth; hero.classList.add('morph'); }
  }

  // ---------- Rail ----------
  rail.addEventListener('click', (e) => {
    const b = e.target instanceof Element ? e.target.closest('[data-view]') : null;
    if (b) showView(b.dataset.view);
    const action = e.target instanceof Element ? e.target.closest('[data-rail-action]') : null;
    if (action?.dataset.railAction === 'engine') openEngine();
    if (action?.dataset.railAction === 'accounts') ctx.navigate('comptes');
    if (action?.dataset.railAction === 'reset') resetWorkshop();
  });
  rail.addEventListener('keydown', (e) => {
    if (!['ArrowDown', 'ArrowUp', 'Home', 'End'].includes(e.key)) return;
    const items = [...rail.querySelectorAll('[data-view]')];
    const at = items.indexOf(document.activeElement);
    if (at < 0) return;
    e.preventDefault();
    const next = e.key === 'Home' ? 0 : e.key === 'End' ? items.length - 1 : (at + (e.key === 'ArrowDown' ? 1 : -1) + items.length) % items.length;
    items[next].focus();
    showView(items[next].dataset.view);
  });

  function updateCounts() {
    const ws = app.workshop;
    const findings = app.subject(memory.focus)?.findings?.filter((f) => f.level !== 'information').length;
    const counts = {
      parcours: app.recipes?.recipes?.length ?? 7,
      constats: Number.isFinite(findings) ? findings : null,
      comparer: ws ? (ws.a ? 1 : 0) + (ws.b ? 1 : 0) : null,
      incidents: ws?.incidents?.total ?? null,
      reperes: ws?.pins?.length ?? null,
    };
    for (const [id, n] of Object.entries(counts)) {
      const badge = rail.querySelector(`[data-view="${id}"] .as-rail-count`);
      if (!badge) continue;
      const text = n === null || n === undefined ? '' : String(n);
      if (badge.textContent !== text) {
        badge.textContent = text;
        badge.hidden = text === '';
        badge.classList.remove('bump');
        if (!motionReduced()) { void badge.offsetWidth; badge.classList.add('bump'); }
      }
    }
    const summary = rail.querySelector('[data-rail-summary]');
    if (summary && ws) summary.textContent = ws.summary;
    const load = rail.querySelector('[data-rail-load]');
    if (load) {
      const busy = app.load.running + app.load.queued;
      load.hidden = busy === 0;
      load.innerHTML = busy ? chip('info', `${plural(app.load.running, 'lecture en cours', 'lectures en cours')}${app.load.queued ? `, ${app.load.queued}${NBSP}en attente` : ''}`, { icon: 'activity' }) : '';
    }
  }
  cleanups.push(app.on('subjects', updateCounts), app.on('recipes', updateCounts));

  // ---------- Session of the workshop (TRV-185) ----------
  function adoptSession(token) {
    if (!token) return;
    if (memory.session && memory.session !== token) {
      // Another session (domain, account or a new connection with the same account): nothing of the former one is kept.
      forgetSession();
      app.suggestions = null;
      app.suggestionsPromise = null;
      memory.session = token;
      app.emit('subjects');
      app.emit('reset');
      paintMode();
      app.refreshRecipes();
      app.toast(`Nouvelle session${COLON}la session d’assistance et l’atelier repartent de zéro.`, { tone: 'info' });
      return;
    }
    memory.session = token;
  }

  // While the screen is shown, the workshop is compared every second (Domenia 1 timer of the support view): new incidents of
  // the session and the reads in progress appear without a click. A background call: no busy line, nothing read from the
  // directory (assistance.workshop.poll is a Local operation).
  async function checkSession(force = false) {
    if (disposed || polling || (!force && document.visibilityState !== 'visible')) return;
    polling = true;
    try {
      const p = await backgroundCall('assistance.workshop.poll');
      if (disposed) return;
      const loadChanged = p.running !== app.load.running || p.queued !== app.load.queued;
      app.load = { running: p.running, queued: p.queued };
      if (p.session !== memory.session || p.revision !== app.workshop?.revision) await app.refreshWorkshop({ background: true });
      else if (loadChanged) updateCounts();
    } catch (err) {
      console.error(err);
    } finally {
      polling = false;
    }
  }

  // ---------- Views ----------
  function keepAddress(extra = {}) {
    // The address follows the screen without a new render (the router only renders on hashchange). The subjects are never
    // written in it: a reload never reads again without a new gesture.
    const query = new URLSearchParams();
    query.set('vue', memory.view);
    if (memory.view === 'parcours') query.set('recette', memory.recipe);
    for (const [k, v] of Object.entries(extra)) if (v) query.set(k, v);
    const hash = `#/assistance?${query}`;
    if (location.hash !== hash) history.replaceState(null, '', hash);
  }

  function showView(id, extra = {}) {
    const def = VIEWS.find((v) => v.id === id) ?? VIEWS[0];
    memory.view = def.id;
    rail.querySelectorAll('[data-view]').forEach((b) => {
      const on = b.dataset.view === def.id;
      b.setAttribute('aria-selected', String(on));
      b.tabIndex = on ? 0 : -1;
    });
    moveInk();
    paintMode();
    if (typeof viewCleanup === 'function') { try { viewCleanup(); } catch (err) { console.error(err); } }
    viewCleanup = null;
    viewHost.setAttribute('aria-labelledby', `as-tab-${def.id}`);
    viewHost.classList.remove('entering');
    viewHost.replaceChildren();
    if (!motionReduced()) { void viewHost.offsetWidth; viewHost.classList.add('entering'); }
    const out = def.render(viewHost, app, extra);
    viewCleanup = typeof out === 'function' ? out : null;
    applyVars(viewHost);
    reveal(viewHost);
    startFreshness(viewHost);
    keepAddress();
  }

  function moveInk() {
    const ink = rail.querySelector('.as-rail-ink');
    const current = rail.querySelector('[data-view][aria-selected="true"]');
    if (!ink || !current) return;
    ink.style.setProperty('--y', `${current.offsetTop}px`);
    ink.style.setProperty('--h', `${current.offsetHeight}px`);
  }
  const onResize = () => moveInk();
  window.addEventListener('resize', onResize);
  cleanups.push(() => window.removeEventListener('resize', onResize));

  // ---------- Engine state (no probe) and workshop reset ----------
  function tile(label, value, t, sub = '') {
    return `<div class="as-kpi ${tone(t)}"><span>${esc(label)}</span><b>${esc(value)}</b>${sub ? `<small>${esc(sub)}</small>` : ''}</div>`;
  }

  async function openEngine() {
    const panel = openDrawer({
      title: 'État du moteur', subtitle: 'Lu sans aucune sonde réseau', icon: 'activity', key: 'assistance.moteur', width: 500,
      body: '<div class="as-engine" aria-busy="true"><span class="skeleton as-sk w85"></span><span class="skeleton as-sk w70"></span><span class="skeleton as-sk w55"></span></div>',
      actions: [
        { id: 'accounts', label: 'Voir les comptes', run: (p) => { p.close(); ctx.navigate('comptes'); } },
        { id: 'close', label: 'Fermer', primary: true, run: (p) => p.close() },
      ],
    });
    panel.setBusy(true);
    try {
      const s = await app.call('assistance.engine.state');
      const body = document.createElement('div');
      body.className = 'as-engine';
      body.innerHTML = `<p class="as-engine-lead">${ico('activity')}<span>${esc(s.summary)}</span></p>
        <div class="as-kpis">
          ${tile('Lectures en cours', `${s.readsRunning} / ${s.readsLimit}`, s.readsRunning ? 'info' : 'off', 'une à la fois par objet')}
          ${tile('En attente', String(s.readsQueued), s.readsQueued ? 'warn' : 'off', 'rien ne part seul')}
          ${tile('Avertissements', String(s.incidentWarnings), s.incidentWarnings ? 'warn' : 'ok', 'incidents de la session')}
          ${tile('Erreurs', String(s.incidentErrors), s.incidentErrors ? 'alert' : 'ok', 'incidents de la session')}
        </div>
        <section class="as-engine-block"><h3>${ico('server')}Mode${COLON}${esc(s.modeLabel)}</h3><p>${esc(s.source)}</p></section>
        <section class="as-engine-block"><h3>${ico('check')}Ce que le moteur sert</h3>
          <ul class="as-caps">${s.capabilities.map((c) => `<li class="${c.available ? 'ok' : 'off'}">${ico(c.available ? 'check' : 'x')}<div><b>${esc(c.label)}</b><small>${esc(c.detail)}</small></div></li>`).join('')}</ul></section>
        <section class="as-engine-block"><h3>${ico('lifebuoy')}Atelier de la session</h3>
          <div class="as-mini">${[['Captures', s.captures], ['Repères', s.pins], ['Étapes lues', s.stepsRead], ['Journal', s.journalEntries]].map(([k, v]) => `<div><b>${esc(String(v))}</b><span>${esc(k)}</span></div>`).join('')}</div></section>
        <section class="as-engine-block"><h3>${ico('shield')}Écritures et documents</h3>
          <p class="as-inline">${s.writes.length ? s.writes.map((w) => chip('accent', w, { icon: 'lock' })).join('') : chip('off', 'Aucune écriture dans ce mode')}</p>
          <p>${esc(s.exportsLabel)}</p>
          <p class="as-faint">Mesures de l’Accueil${COLON}${esc(plural(s.measuresRunning, 'en cours', 'en cours'))}, ${esc(plural(s.measuresQueued, 'en attente', 'en attente'))}.</p></section>`;
      panel.body.replaceChildren(body);
    } catch (err) {
      app.toast(`État du moteur indisponible${COLON}${errorText(err)}`, { tone: 'warn' });
      panel.close();
    } finally {
      panel.setBusy(false);
    }
  }

  async function resetWorkshop() {
    const ok = await confirmDialog({
      title: 'Vider l’atelier ?',
      message: 'Les captures A et B, les repères et les incidents de l’atelier seront effacés. Aucune donnée de la base de Domenia ni de l’annuaire ne sera supprimée.',
      confirmLabel: 'Vider l’atelier', icon: 'trash',
    });
    if (!ok) return;
    const view = await app.workshopCall('assistance.workshop.reset', {}, `Atelier vidé${COLON}captures, repères et incidents effacés.`);
    if (view) app.emit('reset');
  }

  // ---------- Start ----------
  async function start() {
    try {
      const [info, overview] = await Promise.all([ctx.app?.catch?.(() => null) ?? ctx.app, app.call('assistance.overview')]);
      if (disposed) return;
      app.simulation = info?.mode === 'simulation' || info?.webViewRuntime === 'apercu';
      app.overview = overview;
      app.recipes = { recipes: overview.recipes };
      app.setWorkshop(overview.workshop);
      if (!overview.readerAvailable) page.classList.add('no-reader');
      page.querySelector('[data-hero-mode]')?.replaceWith(heroModeChip(app));
    } catch (err) {
      console.error(err);
      viewHost.innerHTML = `<div class="card as-error" role="alert">${ico('alert')}<div><h2>L’Assistance n’a pas pu démarrer</h2><p>${esc(errorText(err))}</p>`
        + '<button class="btn" type="button" data-retry>Réessayer</button></div></div>';
      viewHost.querySelector('[data-retry]')?.addEventListener('click', () => ctx.navigate('assistance', params));
      return;
    }
    if (VIEWS.some((v) => v.id === params.vue)) memory.view = params.vue;
    if (params.recette) memory.recipe = params.recette;
    showView(memory.view);
    await subjectsFromAddress();
    if (disposed) return;
    await app.refreshRecipes();
    await demonstration();
    if (params.etat === 'moteur') openEngine();
    pollTimer = setInterval(() => checkSession(), POLL_MS);
  }

  // A subject named in the address comes from a navigation (another screen, a link): it is read when it names exactly one
  // object of the local index, then the address forgets it, so that a reload reads nothing without a new gesture.
  async function subjectsFromAddress() {
    for (const [kind, value] of [['user', params.compte], ['computer', params.poste]]) {
      if (!value || disposed) continue;
      try {
        const found = await resolveSubject(app, kind, value);
        if (disposed) return;
        if (found.dn) {
          if (app.dnOf(kind) !== found.dn) await app.readSubject(kind, found.dn, { quiet: true });
        } else {
          app.offerSubject?.(kind, value);
          app.toast(found.candidates.length
            ? `${kind === 'computer' ? 'Poste' : 'Compte'} «${NBSP}${value}${NBSP}»${COLON}${plural(found.candidates.length, 'correspondance', 'correspondances')}, aucune exacte. Choisissez dans la liste${NBSP}; rien n’a été lu.`
            : `${kind === 'computer' ? 'Poste' : 'Compte'} introuvable${COLON}${value}. Rien n’a été lu.`, { tone: 'warn' });
        }
      } catch (err) {
        app.toast(`Recherche impossible${COLON}${errorText(err)}`, { tone: 'alert' });
      }
    }
    keepAddress();
  }

  // Demonstration of the address, honoured in simulation only (captures): run steps, capture A and B, pin, prepare. In
  // directory mode these parameters are ignored: a read never starts without a click.
  async function demonstration() {
    if (!app.simulation || disposed) return;
    for (const slot of ['a', 'b']) {
      const value = params[slot];
      if (!value) continue;
      try {
        const found = await resolveSubject(app, null, value);
        if (!found.dn) continue;
        await app.call('assistance.subject.read', { dn: found.dn });
        app.setWorkshop(await app.call('assistance.capture.take', { slot, dn: found.dn }));
      } catch (err) { console.error(err); }
    }
    if (params.epingler) {
      for (const kind of ['user', 'computer']) {
        const dn = app.dnOf(kind);
        if (dn) await app.workshopCall('assistance.pin.add', { dn });
      }
    }
    if (params.lancer) {
      const recipe = app.recipes?.recipes?.find((r) => r.id === memory.recipe);
      for (const id of params.lancer.split(',')) {
        const step = recipe?.stepList?.find((s) => s.id === id);
        if (step && step.state.canRun) await app.runStep?.(recipe.id, step.id);
      }
    }
    if (params.document === 'ticket') { memory.report.kind = 'ticket'; if (memory.view === 'dossier') showView('dossier'); }
    if (params.preparer && memory.view === 'horsligne') app.prepareDossier?.({ demonstration: true });
    if (params.vue === 'dossier' || params.vue === 'constats') app.emit('subjects');
  }

  const onVisible = () => { if (document.visibilityState === 'visible') checkSession(); };
  document.addEventListener('visibilitychange', onVisible);
  cleanups.push(() => document.removeEventListener('visibilitychange', onVisible));

  paintMode();
  start();

  return () => {
    disposed = true;
    clearInterval(pollTimer);
    if (typeof viewCleanup === 'function') { try { viewCleanup(); } catch (err) { console.error(err); } }
    cleanups.forEach((fn) => { try { fn(); } catch (err) { console.error(err); } });
    listeners.clear();
  };
}

function heroModeChip(app) {
  const span = document.createElement('span');
  span.innerHTML = app.simulation
    ? chip('info', 'Simulation', { icon: 'sparkles', tip: 'Les lectures portent sur l’annuaire fictif en mémoire ; aucune requête ne part.' })
    : chip('ok', 'Annuaire de la session', { icon: 'server' });
  return span.firstElementChild;
}

function layout() {
  const groups = [...new Set(VIEWS.map((v) => v.group))];
  const rail = groups.map((g) => `<div class="as-rail-group"><span class="as-rail-title">${esc(g)}</span>${VIEWS.filter((v) => v.group === g).map((v) => `
      <button type="button" role="tab" class="as-rail-item" id="as-tab-${v.id}" data-view="${v.id}" aria-selected="false" aria-controls="as-view" tabindex="-1">
        <span class="as-rail-ico">${ico(v.icon)}</span>
        <span class="as-rail-text"><b>${esc(v.label)}</b><small>${esc(v.hint)}</small></span>
        <span class="as-rail-count k-badge" hidden></span>
      </button>`).join('')}</div>`).join('');
  return `<div class="page assist">
    <section class="hero as-hero reveal" data-slot="hero">
      <span class="glow-ring" aria-hidden="true"></span>
      <div class="orbs" aria-hidden="true"><span class="orb a"></span><span class="orb b"></span><span class="orb c"></span></div>
      <div class="as-hero-grid">
        <div class="as-hero-main">
          <div class="eyebrow as-eyebrow">${ico('lifebuoy')}Support guidé${NBSP}· lecture seule</div>
          <div class="as-title-row"><h1 class="gradient-text">Assistance</h1><span data-hero-mode></span></div>
          <p class="lead as-lead">Parcours guidés par symptôme, atelier de diagnostic et dossiers de ticket. Chaque étape dit ce qu’elle lit, pourquoi et à quel coût${NBSP}; rien ne part sans votre clic, rien n’écrit dans l’annuaire.</p>
          <div class="as-hero-chips">
            ${chip('accent', 'Lecture seule', { icon: 'shield', tip: 'Aucune étape n’écrit dans l’annuaire ni sur un poste.', size: 'md' })}
            ${chip('off', 'Une lecture par clic', { icon: 'play', tip: 'Chaque lecture part sur un clic, pour l’objet choisi seulement.', size: 'md' })}
            ${chip('off', 'Atelier en mémoire', { icon: 'layers', tip: 'Captures, repères et incidents restent en mémoire et disparaissent à la fermeture.', size: 'md' })}
          </div>
        </div>
        <div class="as-session" data-slot="session"></div>
      </div>
    </section>
    <div class="as-layout">
      <nav class="as-rail card reveal" aria-label="Vues de l’Assistance">
        <div class="as-rail-tabs" role="tablist" aria-orientation="vertical" aria-label="Vues de l’Assistance">
          <span class="as-rail-ink" aria-hidden="true"></span>
          ${rail}
        </div>
        <div class="as-rail-foot">
          <div class="as-rail-load" data-rail-load hidden></div>
          <p class="as-rail-summary" data-rail-summary>Atelier en mémoire${NBSP}: rien n’est écrit sur le disque.</p>
          <div class="as-rail-actions">
            ${button({ label: 'État du moteur', icon: 'activity', cls: 'subtle sm', data: { 'rail-action': 'engine' } })}
            ${button({ label: 'Voir les comptes', icon: 'users', cls: 'subtle sm', data: { 'rail-action': 'accounts' } })}
            ${button({ label: 'Vider l’atelier', icon: 'trash', cls: 'ghost sm as-danger-ghost', data: { 'rail-action': 'reset' } })}
          </div>
        </div>
      </nav>
      <section class="as-view" id="as-view" role="tabpanel" tabindex="-1"></section>
    </div>
  </div>`;
}
