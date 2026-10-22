// Assistance: guided support paths and support workshop (Domenia 1 Domenia-Assistance, Domenia-Support, Insight, Dossier and
// Automation). A hero holds the session of assistance (the account and the workstation concerned); a vertical rail groups
// the views: Guider (guided paths), Comprendre (findings, A/B comparison, incidents), Garder (pins), Transmettre (support
// dossier and ticket, offline dossier). Data contract: docs/ops/assistance.md (assistance.*). Nothing here reads the network
// on its own: every read follows a click, the subject named in the address (a navigation from another screen) or, in
// simulation only, a demonstration parameter of the address used by the captures.
import { esc, errorText, reveal, applyVars, announce, motionReduced } from '../ui.js';
import { bindCopy, openDrawer, kvSection, bindKv, confirmDialog } from '../kit/index.js';
import { ico, chip, COLON, NBSP } from './assistance/common.js';
import { renderSession, resolveSubject } from './assistance/subjects.js';
import { renderRecipes } from './assistance/recipes.js';
import { renderFindings, renderCompare, renderIncidents, renderPins } from './assistance/workshop.js';
import { renderDossier, renderOffline } from './assistance/documents.js';

/** The screen has its own stylesheet (css/pages/assistance.css), loaded by the router. */
export const stylesheet = true;

const VIEWS = [
  { id: 'parcours', group: 'Guider', label: 'Parcours guidés', icon: 'route', render: renderRecipes, hint: 'Pas à pas, par symptôme' },
  { id: 'constats', group: 'Comprendre', label: 'Constats', icon: 'bulb', render: renderFindings, hint: 'Analyse locale de la fiche' },
  { id: 'comparer', group: 'Comprendre', label: 'Comparer A / B', icon: 'compare', render: renderCompare, hint: 'Deux captures, attribut par attribut' },
  { id: 'incidents', group: 'Comprendre', label: 'Incidents expliqués', icon: 'alert', render: renderIncidents, hint: 'Avertissements et erreurs de la session' },
  { id: 'reperes', group: 'Garder', label: 'Repères', icon: 'pin', render: renderPins, hint: 'Fiches épinglées de la session' },
  { id: 'dossier', group: 'Transmettre', label: 'Dossier et ticket', icon: 'ticket', render: renderDossier, hint: 'Texte relisible, pseudonymes au choix' },
  { id: 'horsligne', group: 'Transmettre', label: 'Dossier hors ligne', icon: 'archive', render: renderOffline, hint: 'Manifeste et empreintes SHA-256' },
];

// The session of assistance survives a visit to another screen (the engine keeps the workshop; the page keeps its choices).
const memory = {
  user: null, // SubjectView of the account
  computer: null, // SubjectView of the workstation
  focus: 'user',
  view: 'parcours',
  recipe: 'logon',
  report: { kind: 'support', ticket: '', template: 'text', subject: 'user', incident: null, pseudonymize: false, sections: null },
  offline: { scope: 'subject', sections: ['observations', 'associations', 'requetes'] },
  diffOnly: true,
  incidentFilter: '',
  visited: new Set(),
  transmitted: false,
};

const FLOW = [
  { id: 'sujet', title: 'Choisir le sujet', sub: 'Compte et poste concernés' },
  { id: 'parcours', title: 'Suivre un parcours', sub: 'Une lecture par clic' },
  { id: 'comprendre', title: 'Comprendre', sub: 'Constats, A / B, incidents' },
  { id: 'transmettre', title: 'Transmettre', sub: 'Dossier et ticket' },
];

export function render(main, ctx) {
  const params = ctx.params ?? {};
  const listeners = new Map();
  const cleanups = [];
  let disposed = false;
  let viewCleanup = null;

  const app = {
    ctx,
    memory,
    simulation: false,
    overview: null,
    recipes: null,
    workshop: null,
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
        await app.refreshRecipes();
        if (!quiet) announce(`${actual === 'computer' ? 'Poste' : 'Compte'} choisi${COLON}${view.card.name}.`);
        return view;
      } catch (err) {
        console.error(err);
        app.toast(`Lecture impossible${COLON}${errorText(err)}`, { tone: 'alert' });
        return null;
      } finally {
        app.setBusy(kind, false);
      }
    },
    clearSubject(kind) {
      memory[kind] = null;
      if (memory.focus === kind) memory.focus = kind === 'user' ? 'computer' : 'user';
      app.emit('subjects');
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
      app.workshop = view;
      app.emit('workshop');
      updateCounts();
    },
    async refreshWorkshop() {
      try {
        app.setWorkshop(await app.call('assistance.workshop.get'));
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

  // ---------- Hero: the session of assistance ----------
  cleanups.push(renderSession(page.querySelector('[data-slot="session"]'), app));

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
  }
  cleanups.push(app.on('subjects', updateCounts), app.on('recipes', updateCounts));

  // ---------- Hero flow: where the assistance stands ----------
  const flow = page.querySelector('[data-flow]');
  function paintFlow() {
    const ws = app.workshop;
    const done = {
      sujet: Boolean(app.subject('user') || app.subject('computer')),
      parcours: (app.recipes?.recipes ?? []).some((r) => r.done > 0),
      comprendre: ['constats', 'comparer', 'incidents'].some((v) => memory.visited.has(v)) || Boolean(ws?.a || ws?.b || ws?.pins?.length),
      transmettre: memory.transmitted,
    };
    const current = FLOW.find((f) => !done[f.id])?.id ?? null;
    flow.querySelectorAll('[data-flow-step]').forEach((li) => {
      const id = li.dataset.flowStep;
      li.classList.toggle('done', done[id]);
      li.classList.toggle('current', id === current);
      li.querySelector('button').setAttribute('aria-label', `${FLOW.find((f) => f.id === id).title}${COLON}${done[id] ? 'fait' : id === current ? 'en cours' : 'à venir'}`);
    });
  }
  flow.addEventListener('click', (e) => {
    const b = e.target instanceof Element ? e.target.closest('[data-flow-go]') : null;
    if (!b) return;
    const go = b.dataset.flowGo;
    if (go === 'sujet') {
      const input = page.querySelector('.as-slot input');
      if (input) input.focus(); else showView('parcours');
      return;
    }
    showView(go === 'parcours' ? 'parcours' : go === 'comprendre' ? 'constats' : 'dossier');
  });
  for (const event of ['subjects', 'recipes', 'workshop', 'flow']) cleanups.push(app.on(event, paintFlow));

  // ---------- Views ----------
  function keepAddress(extra = {}) {
    // The address follows the screen without a new render (the router only renders on hashchange).
    const query = new URLSearchParams();
    query.set('vue', memory.view);
    if (memory.view === 'parcours') query.set('recette', memory.recipe);
    const user = app.subject('user')?.card?.login;
    const computer = app.subject('computer')?.card?.login?.replace(/\$$/, '');
    if (user) query.set('compte', user);
    if (computer) query.set('poste', computer);
    for (const [k, v] of Object.entries(extra)) if (v) query.set(k, v);
    const hash = `#/assistance?${query}`;
    if (location.hash !== hash) history.replaceState(null, '', hash);
  }

  function showView(id, extra = {}) {
    const def = VIEWS.find((v) => v.id === id) ?? VIEWS[0];
    memory.view = def.id;
    memory.visited.add(def.id);
    app.emit('flow');
    rail.querySelectorAll('[data-view]').forEach((b) => {
      const on = b.dataset.view === def.id;
      b.setAttribute('aria-selected', String(on));
      b.tabIndex = on ? 0 : -1;
    });
    moveInk();
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
  async function openEngine() {
    const panel = openDrawer({
      title: 'État du moteur', subtitle: 'Lu sans aucune sonde réseau', icon: 'activity', key: 'assistance.moteur', width: 460,
      body: '<div class="k-kv-skeleton" aria-busy="true"><span class="skeleton"></span><span class="skeleton"></span><span class="skeleton"></span></div>',
      actions: [
        { id: 'accounts', label: 'Voir les comptes', run: (p) => { p.close(); ctx.navigate('comptes'); } },
        { id: 'close', label: 'Fermer', primary: true, run: (p) => p.close() },
      ],
    });
    panel.setBusy(true);
    try {
      const s = await app.call('assistance.engine.state');
      const body = document.createElement('div');
      body.innerHTML = `<p class="k-drawer-lead">${esc(s.summary)}</p>`
        + kvSection({ id: 'mode', title: 'Mode et source', icon: 'server', items: [
          { label: 'Mode', value: s.modeLabel },
          { label: 'Source', value: s.source },
          { label: 'Lecteurs d’écran', value: s.readers.join(', ') || 'Aucun dans ce mode', wide: true },
          { label: 'Écritures servies', value: s.writers.join(', ') || 'Aucune dans ce mode', wide: true },
        ] })
        + kvSection({ id: 'tasks', title: 'Tâches et journal', icon: 'activity', items: [
          { label: 'Lectures en cours', value: s.tasksRunning },
          { label: 'En attente', value: s.tasksQueued },
          { label: 'Entrées du journal', value: s.journalEntries },
          { label: 'Avertissements', value: s.journalWarnings, tone: s.journalWarnings ? 'warn' : undefined },
          { label: 'Erreurs', value: s.journalAlerts, tone: s.journalAlerts ? 'alert' : undefined },
        ] })
        + kvSection({ id: 'workshop', title: 'Atelier d’assistance', icon: 'lifebuoy', items: [
          { label: 'Captures', value: s.captures },
          { label: 'Repères', value: s.pins },
          { label: 'Incidents', value: s.incidents },
          { label: 'Étapes lues', value: s.stepsRead },
          { label: 'Reçus d’écriture', value: s.receiptsPersistent ? 'Enregistrés sur le disque' : 'En mémoire seulement' },
          { label: 'Documents', value: s.exportsPersistent ? 'Enregistrés dans Exports' : 'En mémoire seulement' },
        ] });
      panel.body.replaceChildren(body);
      bindKv(body, { key: 'assistance.moteur' });
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
    const view = await app.workshopCall('assistance.workshop.reset', {}, 'Atelier vidé : captures, repères et incidents effacés.');
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
    const wanted = [];
    if (params.compte) wanted.push(['user', params.compte]);
    if (params.poste) wanted.push(['computer', params.poste]);
    showView(memory.view);
    for (const [kind, value] of wanted) {
      // A subject named in the address comes from a navigation (another screen, a bookmark): it is the operator's gesture.
      const dn = await resolveSubject(app, kind, value);
      if (disposed) return;
      if (dn && app.dnOf(kind) !== dn) await app.readSubject(kind, dn, { quiet: true });
    }
    if (wanted.length) app.emit('subjects');
    await app.refreshRecipes();
    await demonstration();
    if (params.etat === 'moteur') openEngine();
  }

  // Demonstration of the address, honoured in simulation only (captures): run steps, capture A and B. In directory mode these
  // parameters are ignored: a read never starts without a click.
  async function demonstration() {
    if (!app.simulation || disposed) return;
    if (params.a || params.b) {
      for (const slot of ['a', 'b']) {
        const value = params[slot];
        if (!value) continue;
        const kind = /^(PC|PT)-/i.test(value) ? 'computer' : 'user';
        const dn = await resolveSubject(app, kind, value);
        if (!dn) continue;
        try {
          await app.call('assistance.subject.read', { dn });
          app.setWorkshop(await app.call('assistance.capture.take', { slot, dn }));
        } catch (err) { console.error(err); }
      }
      app.emit('workshop');
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
    if (params.preparer && memory.view === 'horsligne') page.querySelector('[data-prepare]')?.click();
    if (params.vue === 'dossier' || params.vue === 'constats') app.emit('subjects');
  }

  start();

  return () => {
    disposed = true;
    if (typeof viewCleanup === 'function') { try { viewCleanup(); } catch (err) { console.error(err); } }
    cleanups.forEach((fn) => { try { fn(); } catch (err) { console.error(err); } });
    listeners.clear();
  };
}

function heroModeChip(app) {
  const span = document.createElement('span');
  span.innerHTML = app.simulation
    ? chip('info', 'Simulation : annuaire fictif', { icon: 'sparkles', tip: 'Les lectures portent sur l’annuaire fictif en mémoire ; aucune requête ne part.' })
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
          <div class="eyebrow">${ico('lifebuoy')}Assistance${NBSP}· support guidé</div>
          <h1 class="gradient-text">Assistance</h1>
          <p class="lead">Parcours guidés par symptôme, atelier de diagnostic et dossiers de ticket. Chaque étape dit ce qu’elle lit, pourquoi et à quel coût${NBSP}; rien ne part sans votre clic, rien n’écrit dans l’annuaire.</p>
          <div class="as-hero-chips">
            ${chip('accent', 'Lecture seule', { icon: 'shield', tip: 'Aucune étape n’écrit dans l’annuaire ni sur un poste.' })}
            ${chip('off', 'Aucune étape ne part seule', { icon: 'play', tip: 'Chaque lecture part sur un clic, pour l’objet choisi seulement.' })}
            ${chip('off', 'Atelier en mémoire', { icon: 'layers', tip: 'Captures, repères et incidents restent en mémoire et disparaissent à la fermeture.' })}
            <span data-hero-mode></span>
          </div>
          <ol class="as-flow" data-flow aria-label="Déroulé d’une assistance">${FLOW.map((f, n) => `
            <li class="as-flow-step" data-flow-step="${f.id}"><button type="button" data-flow-go="${f.id}">
              <span class="as-flow-dot" aria-hidden="true"><b>${n + 1}</b>${ico('check')}</span>
              <span class="as-flow-text"><b>${esc(f.title)}</b><small>${esc(f.sub)}</small></span></button></li>`).join('')}
          </ol>
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
          <p class="as-rail-summary" data-rail-summary>Atelier en mémoire${NBSP}: rien n’est écrit sur le disque.</p>
          <div class="as-rail-actions">
            <button class="btn subtle sm" type="button" data-rail-action="engine">${ico('activity')}État du moteur</button>
            <button class="btn subtle sm" type="button" data-rail-action="accounts">${ico('users')}Voir les comptes</button>
            <button class="btn ghost sm as-danger-ghost" type="button" data-rail-action="reset">${ico('trash')}Vider l’atelier</button>
          </div>
        </div>
      </nav>
      <section class="as-view" id="as-view" role="tabpanel" tabindex="-1"></section>
    </div>
  </div>`;
}

