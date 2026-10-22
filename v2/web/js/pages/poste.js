// Poste: the console of one workstation (docs/ops/poste.md). Without a workstation, the picker of the working OU; with one
// (#/poste?dn=… or ?nom=PC-PAR-0001), a hero header that never moves (identity, presence, user, inventory, authorization,
// running collections, health score, actions), a strip of four indicators (system disk, memory, uptime, LAPS deadline) and
// six views: Vue d’ensemble, Inventaire, Diagnostic, Sondes et relevés, Intervenir, Secrets. Every network read starts
// from a gesture of the operator; every write goes through the write circuit (plan, confirmation, receipt, re-read).
// Route parameters: dn | nom, vue, onglet (Domenia 1 tab names accepted), panneau (opens a panel), verifier=1 (opened from
// the list: one ping, and the console user when the option is on, Domenia 1 PST-051), essai (simulation only: runs one
// read for the captures and the guides; ignored in directory mode).
import { createTabs, createCommandBar, startFreshness, writeClipboard } from '../kit/index.js';
import { onEvent } from '../bridge.js';
import { esc, ico, rel, chip, scoreRing, paintMeters, tickRelative, sk, skLines, failure, errorText, NBSP, int, pct, freePct } from './poste/common.js';
import { renderPicker, openSwitcher, rememberRecent } from './poste/picker.js';
import { renderOverview } from './poste/overview.js';
import { renderInventory } from './poste/inventory.js';
import { renderDiagnostic } from './poste/diagnostic.js';
import { renderReadings } from './poste/readings.js';
import { renderAct } from './poste/act.js';
import { mountMachineAccount } from './machine/panel.js';
import { renderSecrets } from './poste/secrets.js';
import { reveal as revealCards, toast, announce } from '../ui.js';

/** The screen has its own stylesheet (css/pages/poste.css). */
export const stylesheet = true;

const VIEWS = [
  { id: 'ensemble', label: 'Vue d’ensemble', icon: 'home', render: renderOverview },
  { id: 'inventaire', label: 'Inventaire', icon: 'layers', render: renderInventory },
  { id: 'diagnostic', label: 'Diagnostic', icon: 'activity', render: renderDiagnostic },
  { id: 'releves', label: 'Sondes et relevés', icon: 'gauge', render: renderReadings },
  { id: 'intervenir', label: 'Intervenir', icon: 'tools', render: renderAct },
  { id: 'secrets', label: 'Secrets', icon: 'key', render: renderSecrets },
];

// Former tab names of Domenia 1 (Resolve-DomeniaComputerViewRoute) and the inner tabs of Domenia 2.
const ROUTES = {
  TabComputer: ['ensemble'], TabComputerDashboard: ['ensemble'], TabComputerAdmin: ['intervenir'], TabSessions: ['inventaire', 'sessions'],
  TabComputerServices: ['inventaire', 'services'], TabComputerDetails: ['inventaire'], TabInventory: ['inventaire', 'materiel'],
  TabSoftware: ['inventaire', 'logiciels'], TabComputerHealth: ['diagnostic', 'reseau'], TabComputerChecks: ['diagnostic', 'reseau'],
  TabWmi: ['diagnostic', 'wmi'], TabSecurity: ['secrets'],
  materiel: ['inventaire', 'materiel'], logiciels: ['inventaire', 'logiciels'], services: ['inventaire', 'services'], processus: ['inventaire', 'processus'],
  sessions: ['inventaire', 'sessions'], reseau: ['diagnostic', 'reseau'], rapide: ['diagnostic', 'rapide'], lent: ['diagnostic', 'lent'],
  evenements: ['diagnostic', 'evenements'], wmi: ['diagnostic', 'wmi'], jonction: ['diagnostic', 'jonction'],
};

const ESSAI_VIEW = {
  inventaire: ['inventaire', 'materiel'], logiciels: ['inventaire', 'logiciels'], services: ['inventaire', 'services'], processus: ['inventaire', 'processus'],
  sessions: ['inventaire', 'sessions'], diagnostic: ['diagnostic', 'reseau'], rapide: ['diagnostic', 'rapide'], lent: ['diagnostic', 'lent'],
  evenements: ['diagnostic', 'evenements'], wmi: ['diagnostic', 'wmi'], sondes: ['releves'], laps: ['secrets'], bitlocker: ['secrets'], index: ['secrets'],
  live: ['ensemble'], detection: ['ensemble'], connexions: ['ensemble'],
};

const KIND_LABEL = { inventory: 'Inventaire', diagnostic: 'Diagnostic', probes: 'Relevé des sondes', detection: 'Détection de l’utilisateur' };
const NO_HOST = { secretWindow: false, toolLauncher: false, fileExport: false, simulation: false, openReadsConsole: false };

export function render(main, ctx) {
  const params = ctx.params ?? {};
  if (!params.dn && !params.nom) return renderPicker(main, ctx);
  return renderConsole(main, ctx, params);
}

function skeletonConsole() {
  return `<div class="page ps-page"><section class="ps-hero reveal" aria-busy="true"><div class="ps-hero-grid">
      <div class="ps-hero-main">${skLines('w25', 'w40', 'w55', 'w70')}</div><div class="ps-hero-score">${sk('ps-sk-ring')}</div></div></section>
    <div class="ps-kpis">${[1, 2, 3, 4].map(() => `<div class="card ps-kpi" aria-busy="true">${skLines('w40', 'w70', 'w55')}</div>`).join('')}</div>
    <div class="card ps-views" aria-busy="true">${skLines('w100', 'w85', 'w70', 'w85', 'w55')}</div></div>`;
}

async function resolveDn(ctx, params) {
  if (params.dn) return params.dn;
  const name = String(params.nom ?? '').trim();
  const list = await ctx.call('poste.list', { text: name, limit: 50 });
  const row = list.rows.find((r) => r.name.toLowerCase() === name.toLowerCase()) ?? null;
  if (!row) throw Object.assign(new Error(`Aucun poste nommé ${name} dans l’OU de travail${NBSP}: choisissez-le dans la liste.`), { code: 'poste.unknown' });
  return row.dn;
}

function renderConsole(main, ctx, params) {
  let alive = true;
  const cleanups = [];
  main.innerHTML = skeletonConsole();
  const app = { mode: null };

  const state = {
    ctx,
    dn: null,
    data: null,
    params,
    host: NO_HOST,
    running: [],
    get simulation() { return app.mode === 'simulation' || app.mode === null && this.data?.simulated === true; },
    call: (op, args) => ctx.call(op, args),
    listeners: new Map(),
    on(name, fn) {
      if (!this.listeners.has(name)) this.listeners.set(name, new Set());
      this.listeners.get(name).add(fn);
      return () => this.listeners.get(name)?.delete(fn);
    },
    emit(name, value) { (this.listeners.get(name) ?? []).forEach((fn) => { try { fn(value); } catch (err) { console.error(err); } }); },
    /** Progress events of a long read of this screen. */
    progress(op, fn) { return onEvent(`${op}:progress`, (data) => fn(data)); },
    /** Reads the console again (after a write, a ping, an inventory) and repaints the header, never its command bar. */
    async reload() {
      const data = await ctx.call('poste.open', { dn: this.dn });
      if (!alive) return null;
      this.data = data;
      paintHeader(main, this);
      this.emit('console', data);
      return data;
    },
    /** Running collections of the session (Local, no network): this workstation’s and another one’s (PST-052). */
    async refreshRunning() {
      try {
        const list = await ctx.call('poste.running');
        if (!alive) return;
        const before = JSON.stringify(this.running);
        this.running = Array.isArray(list) ? list : [];
        if (JSON.stringify(this.running) !== before) { paintRunning(main, this); this.emit('running', this.running); }
      } catch (err) { console.error(err); }
    },
    /** True when a collection of this kind runs on the open workstation. */
    isRunning(kind) { return this.running.some((r) => sameDn(r.dn, this.dn) && r.kind === kind); },
    /** Stops one kind of collection of the open workstation (the reader returns what it has read). */
    async stop(kind) {
      try {
        const r = await ctx.call('poste.collect.stop', { dn: this.dn, kind });
        toast(r.text, { tone: 'info' });
      } catch (err) { toast(errorText(err), { tone: 'warn' }); }
      this.refreshRunning();
    },
    go(view, tab) { views?.select(view); if (tab) this.emit('tab', { view, tab }); },
    toast,
    announce,
    alive: () => alive,
  };

  let views = null;
  const start = async () => {
    try {
      const [info, host] = await Promise.all([
        ctx.call('app.info').catch((err) => { console.error(err); return null; }),
        ctx.call('poste.host').catch((err) => { console.error(err); return null; }),
      ]);
      app.mode = info?.mode ?? null;
      state.host = host ?? NO_HOST;
      state.dn = await resolveDn(ctx, params);
      state.data = await ctx.call('poste.open', { dn: state.dn });
    } catch (err) {
      console.error(err);
      if (!alive) return;
      main.innerHTML = `<div class="page ps-page"><section class="card ps-card">${failure(err, { retry: 'retry' })}
        <div class="ps-fail-more"><a class="btn sm" href="#/poste">${ico('search')}Choisir un poste</a></div></section></div>`;
      main.querySelector('[data-act="retry"]')?.addEventListener('click', () => renderConsole(main, ctx, params));
      return;
    }
    if (!alive) return;
    rememberRecent({ dn: state.dn, name: state.data.computer.name });
    main.innerHTML = `<div class="page ps-page">
      <section class="ps-hero reveal" data-slot="hero">
        <span class="glow-ring hero-ring" aria-hidden="true"></span>
        <div class="orbs" aria-hidden="true"><span class="orb a"></span><span class="orb b"></span><span class="orb c"></span></div>
        <div class="ps-hero-grid">
          <div class="ps-hero-main" data-slot="hero-main"></div>
          <div class="ps-hero-score" data-slot="hero-score"></div>
          <div class="ps-hero-bar" data-slot="bar"></div>
          <div class="ps-hero-account" data-slot="machine-account"></div>
        </div>
      </section>
      <div class="ps-kpis" data-slot="kpis" role="list" aria-label="Indicateurs du poste"></div>
      <div class="ps-views reveal" data-slot="views"></div>
    </div>`;
    createBar(main, state, cleanups);
    // MAC-002: the « Compte poste » pill names the account of the next operation on this workstation (machine.account.watch);
    // its slot is never repainted by the header, so the pill keeps its state and its side panel.
    const machineAccount = mountMachineAccount(main.querySelector('[data-slot="machine-account"]'), ctx, { target: state.data.computer.name, show: 'pill' });
    cleanups.push(() => machineAccount.destroy());
    paintHeader(main, state);
    bindHeader(main, state, cleanups);
    const route = ROUTES[params.onglet] ?? null;
    // « essai » runs one read for the captures and the guides: simulation only, ignored against the directory.
    state.essai = params.essai && state.simulation ? params.essai : null;
    const essai = state.essai ? ESSAI_VIEW[state.essai] ?? null : null;
    const initial = VIEWS.some((v) => v.id === params.vue) ? params.vue : route?.[0] ?? essai?.[0] ?? 'ensemble';
    state.initialTab = route?.[1] ?? essai?.[1] ?? null;
    state.panneau = params.panneau ?? null;
    views = createTabs(main.querySelector('[data-slot="views"]'), {
      label: 'Vues du poste',
      selected: initial,
      tabs: VIEWS.map((v) => ({ id: v.id, label: v.label, icon: v.icon, render: (panel) => v.render(panel, state) })),
      onChange: (id) => {
        const q = new URLSearchParams({ dn: state.dn, vue: id });
        history.replaceState(null, '', `#/poste?${q.toString()}`);
        state.emit('viewChange', id);
        requestAnimationFrame(() => revealCards(main));
      },
    });
    cleanups.push(() => views.destroy());
    revealCards(main);
    startFreshness(main);
    const timer = setInterval(() => { if (alive) { tickRelative(main); paintConsent(main, state); } }, 1000);
    cleanups.push(() => clearInterval(timer));
    // Collections of the session (memory of the engine, no network): polled while the console is visible.
    const poll = setInterval(() => { if (alive && !document.hidden) state.refreshRunning(); }, 1500);
    cleanups.push(() => clearInterval(poll));
    state.refreshRunning();
    if (params.panneau === 'postes') openSwitcher(state);
    if (params.verifier === '1') {
      // Opened from the list (PST-051): one ping, and the console user when the option is on; the address loses the
      // parameter so a reload sends nothing.
      history.replaceState(null, '', `#/poste?${new URLSearchParams({ dn: state.dn, vue: initial }).toString()}`);
      pingRead(main, state).then(() => { if (alive && state.host.openReadsConsole) liveRead(main, state); });
    }
  };
  start();

  return () => {
    alive = false;
    // A secret shown in the secure window never outlives the console (another workstation, another screen).
    if (state.host.secretWindow) ctx.call('poste.secret.hide').catch((err) => console.error(err));
    cleanups.forEach((fn) => { try { fn(); } catch (err) { console.error(err); } });
    state.listeners.clear();
  };
}

function sameDn(a, b) {
  return String(a ?? '').trim().toUpperCase() === String(b ?? '').trim().toUpperCase();
}

// ---------- Header (hero) ----------

const PRESENCE_ICON = { online: 'wifi', offline: 'wifiOff', pending: 'refresh', error: 'alert', unknown: 'info', remembered: 'history' };

/** The command bar of the header: built once, so a re-read of the console never steals the keyboard focus. */
function createBar(main, state, cleanups) {
  const host = state.host;
  const noLauncher = 'Aucun lanceur d’outils dans cet affichage : copiez la commande depuis Intervenir.';
  state.bar = createCommandBar(main.querySelector('[data-slot="bar"]'), {
    label: 'Actions du poste',
    items: [
      { id: 'ping', label: 'Tester la réponse', icon: 'wifi', kind: 'network', pinned: true, run: () => pingRead(main, state) },
      { id: 'live', label: 'Actualiser l’état', icon: 'refresh', kind: 'network', run: () => liveRead(main, state) },
      { id: 'rdp', label: 'Bureau à distance', icon: 'monitor', kind: 'network', disabled: !host.toolLauncher, reason: noLauncher, run: () => openTool(state, 'rdp') },
      { id: 'c', label: 'Dossier C$', icon: 'folder', kind: 'network', disabled: !host.toolLauncher, reason: noLauncher, run: () => openTool(state, 'c') },
      { id: 'inventory', label: 'Inventaire', icon: 'layers', kind: 'network', items: [
        { label: 'Inventaire rapide (≈ 1 min)', icon: 'layers', run: () => { state.go('inventaire', 'materiel'); state.emit('run', { what: 'inventory', deep: false }); } },
        { label: 'Inventaire complet (≈ 3 min)', icon: 'layers', run: () => { state.go('inventaire', 'materiel'); state.emit('run', { what: 'inventory', deep: true }); } },
      ] },
      { id: 'diag', label: 'Diagnostic', icon: 'activity', kind: 'network', run: () => { state.go('diagnostic', 'reseau'); state.emit('run', { what: 'diagnostic' }); } },
      { id: 'slow', label: 'Poste lent ?', icon: 'gauge', kind: 'network', run: () => { state.go('diagnostic', 'lent'); state.emit('run', { what: 'slow' }); } },
      { id: 'restart', label: 'Redémarrer…', icon: 'power', kind: 'write', danger: true, overflow: true, run: () => { state.go('intervenir'); state.emit('run', { what: 'restart' }); } },
      { id: 'switch', label: 'Changer de poste', icon: 'monitor', overflow: true, run: () => openSwitcher(state) },
      { id: 'copy', label: 'Copier le nom du poste', icon: 'copy', overflow: true, run: () => copyName(state) },
    ],
  });
  cleanups.push(() => state.bar?.destroy?.());
}

function paintHeader(main, state) {
  const d = state.data;
  const hero = main.querySelector('[data-slot="hero"]');
  if (!hero || !d) return;
  const h = d.header;
  const c = d.computer;
  const health = d.board?.health;
  const presence = h.presence;
  const user = h.user;
  const inv = d.inventory;
  hero.dataset.tone = presence.tone;
  const kindIcon = c.kind === 'laptop' ? 'laptop' : c.kind === 'server' ? 'server' : 'monitor';
  const invTip = inv ? `${inv.origin} · ${inv.sources} sources lues${inv.refused ? ` · ${inv.refused} refusée${inv.refused > 1 ? 's' : ''}` : ''}` : h.inventoryText;
  main.querySelector('[data-slot="hero-main"]').innerHTML = `
    <div class="ps-hero-id">
      <button class="ps-avatar" type="button" data-act="switch" data-tone="${esc(presence.tone)}" aria-label="Changer de poste (postes de l’OU de travail)" data-tip="Changer de poste">
        <span class="ps-avatar-halo" aria-hidden="true"></span>${ico(kindIcon)}<span class="ps-avatar-dot" aria-hidden="true"></span></button>
      <div class="ps-hero-titles">
        <p class="eyebrow">${ico('sparkles')}<span>${esc(c.kindLabel)} · ${esc(c.ou.path)}</span></p>
        <h1 class="gradient-text">${esc(h.name)}</h1>
        <p class="ps-hero-sys">${esc(h.systemText)}</p>
      </div>
    </div>
    <div class="ps-hero-chips">
      <span class="ps-presence" data-state="${esc(presence.state)}" data-tone="${esc(presence.tone)}" tabindex="0" data-tip="${esc(presence.help)}">
        <span class="ps-presence-dot${presence.state === 'online' ? ' pulse' : ''}" aria-hidden="true"></span>${ico(PRESENCE_ICON[presence.state] ?? 'info')}<span>${esc(presence.label)}</span>
        ${presence.checkedAt ? `<span class="ps-presence-age">${rel(presence.checkedAt)}</span>` : ''}<span class="visually-hidden"> · ${esc(presence.help)}</span></span>
      ${user ? `<button class="ps-user" type="button" data-act="user" data-tip="${esc(h.userHelp)}"><span class="avatar" aria-hidden="true">${esc(initials(user.name))}</span><span><b>${esc(user.name)}</b><small>${esc(d.association.badgeLabel)} · ${esc(user.login)}</small></span></button>`
        : `<span class="ps-user none" tabindex="0" data-tip="${esc(h.userHelp)}">${ico('user')}<span><b>Aucun utilisateur associé</b><small>Détection dans la vue d’ensemble</small></span></span>`}
      <span class="chip ps-inv-chip${inv ? '' : ' warn'}" tabindex="0" data-tip="${esc(invTip)}">${ico('layers')}${esc(inv ? `${inv.modeLabel} ${inv.ageText}` : 'Aucun inventaire')}</span>
      <span class="ps-consent" data-slot="consent" hidden></span>
      <span class="ps-running" data-slot="running" hidden></span>
      ${c.enabled === false ? chip('alert', 'Compte désactivé', c.accountText) : ''}
      ${d.simulated ? `<span class="chip info" tabindex="0" data-tip="${esc(d.options.simulationNote)}">${ico('sparkles')}Poste fictif</span>` : ''}
    </div>`;
  main.querySelector('[data-slot="hero-score"]').innerHTML = `
    ${scoreRing(health?.score, health?.state, `Santé du poste : ${health?.verdict ?? 'non évaluée'}`)}
    <div class="ps-hero-verdict"><span class="ps-verdict" data-tone="${esc(health?.state ?? 'off')}">${esc(health?.verdict ?? '—')}</span>
      <span class="ps-hero-points">${esc(health?.title ?? '')}</span>
      <button class="btn ghost sm" type="button" data-act="points">${ico('chevronRight')}Points d’attention</button></div>`;
  paintMeters(hero);
  paintConsent(main, state);
  paintRunning(main, state);
  paintKpis(main, state);
}

function initials(name) {
  return String(name ?? '').split(/[\s-]+/).filter(Boolean).slice(0, 2).map((p) => p[0].toUpperCase()).join('');
}

async function copyName(state) {
  await writeClipboard(state.data.computer.name);
  toast(`Nom copié${NBSP}: ${state.data.computer.name}`, { tone: 'ok' });
}

async function openTool(state, tool) {
  state.bar?.setBusy(tool, true);
  try {
    const r = await state.call('poste.tool.open', { dn: state.dn, tool });
    toast(r.text, { tone: r.launched ? 'ok' : 'info', life: r.simulated ? 7000 : 4800 });
  } catch (err) {
    toast(errorText(err), { tone: 'warn' });
  } finally {
    state.bar?.setBusy(tool, false);
  }
}

function paintConsent(main, state) {
  const slot = main.querySelector('[data-slot="consent"]');
  const consent = state.data?.consent?.intervention;
  if (!slot) return;
  if (!consent?.active || !consent.until) { slot.hidden = true; slot.replaceChildren(); return; }
  const left = Math.max(0, Math.round((Date.parse(consent.until) - Date.now()) / 1000));
  if (left <= 0) {
    slot.hidden = true;
    state.data.consent.intervention = { ...consent, active: false };
    state.emit('consent', state.data.consent);
    return;
  }
  const text = `Intervention autorisée ${Math.floor(left / 60)}:${String(left % 60).padStart(2, '0')}`;
  if (slot.hidden || !slot.querySelector('[data-act="revoke"]')) {
    slot.hidden = false;
    slot.innerHTML = `${ico('zap')}<span data-text>${esc(text)}</span><button class="ps-consent-x" type="button" data-act="revoke" data-tip="Retirer tout de suite l’autorisation">Retirer</button>`;
  } else {
    slot.querySelector('[data-text]').textContent = text;
  }
}

/** Running collections: the ones of this workstation with « Arrêter » (one kind each), another workstation’s named. */
function paintRunning(main, state) {
  const slot = main.querySelector('[data-slot="running"]');
  if (!slot) return;
  const mine = state.running.filter((r) => sameDn(r.dn, state.dn));
  const others = state.running.filter((r) => !sameDn(r.dn, state.dn));
  if (!mine.length && !others.length) { slot.hidden = true; slot.replaceChildren(); return; }
  slot.hidden = false;
  slot.innerHTML = mine.map((r) => `<span class="ps-run" data-kind="${esc(r.kind)}"><span class="ps-run-spin" aria-hidden="true"></span><span>${esc(KIND_LABEL[r.kind] ?? r.label)} en cours</span>
      <button class="ps-consent-x" type="button" data-act="stopRun" data-kind="${esc(r.kind)}" data-tip="Arrêter ce relevé : ce qui est déjà lu est gardé">Arrêter</button></span>`).join('')
    + others.map((r) => `<span class="chip info ps-run-other" tabindex="0" data-tip="${esc(`${r.label} lancé ${rel(r.since).replace(/<[^>]+>/g, '')} sur un autre poste`)}">${ico('activity')}${esc(`${KIND_LABEL[r.kind] ?? r.label} en cours sur ${r.computer}`)}</span>`).join('');
}

/** The strip of four indicators (no repetition of the header): system disk, memory, uptime, LAPS deadline. */
function paintKpis(main, state) {
  const host = main.querySelector('[data-slot="kpis"]');
  const d = state.data;
  if (!host || !d) return;
  const sys = d.board?.disks?.system;
  const mem = d.board?.resources?.memory;
  const uptimeLine = d.board?.identity?.lines?.find((l) => l.key === 'computer.uptime');
  const s = d.secrets;
  const none = 'Lancez un inventaire pour le mesurer';
  const tiles = [
    {
      icon: 'disk', go: 'ensemble/disques', title: sys ? `Disque ${sys.name}` : 'Disque système',
      tone: sys ? sys.state : 'off', value: sys ? `${freePct(sys.freePercent)} libres` : '—', sub: sys ? sys.text : none,
    },
    {
      icon: 'memory', go: 'releves', title: 'Mémoire utilisée',
      tone: mem ? mem.state : 'off', value: mem && Number.isFinite(mem.percent) ? pct(mem.percent, 0) : '—', sub: mem ? mem.detail : none,
    },
    d.live?.uptimeText
      ? { icon: 'clock', go: 'intervenir', title: 'En service depuis', tone: 'info', value: d.live.uptimeText, sub: `État en direct, lu ${rel(d.live.at).replace(/<[^>]+>/g, '')}` }
      : uptimeLine && uptimeLine.value !== 'Non lu'
        ? { icon: 'clock', go: 'intervenir', title: 'En service depuis', tone: uptimeLine.state ?? 'info', value: uptimeLine.value, sub: uptimeLine.detail ? `${uptimeLine.detail} · dernier inventaire` : 'Dernier inventaire' }
        : { icon: 'clock', go: 'intervenir', title: 'En service depuis', tone: 'off', value: '—', sub: 'Actualisez l’état ou lancez un inventaire' },
    s.lapsExpiration
      ? { icon: 'key', go: 'secrets', title: 'Échéance LAPS', tone: s.lapsExpired ? 'warn' : 'ok', value: s.lapsExpired ? 'Échue' : (relLabel(s.lapsExpiration)), sub: `${s.lapsKind} · ${s.lapsExpired ? 'rotation au prochain contact du poste' : 'annuaire, sans valeur'}` }
      : { icon: 'key', go: 'secrets', title: 'Échéance LAPS', tone: 'off', value: '—', sub: 'Aucune expiration LAPS visible dans l’annuaire' },
  ];
  host.innerHTML = tiles.map((t, n) => `<button class="card ps-kpi spot reveal" type="button" role="listitem" data-tone="${esc(t.tone)}" data-go="${esc(t.go)}" data-i="${n}">
    <span class="ps-kpi-ico">${ico(t.icon)}</span><span class="ps-kpi-text"><span class="ps-kpi-title">${esc(t.title)}</span><b class="ps-kpi-value">${esc(t.value)}</b><span class="ps-kpi-sub">${esc(t.sub)}</span></span></button>`).join('');
  revealCards(host);
}

function relLabel(iso) {
  const text = rel(iso).replace(/<[^>]+>/g, '');
  return text || '—';
}

function bindHeader(main, state, cleanups) {
  const onClick = async (e) => {
    const b = e.target instanceof Element ? e.target.closest('[data-act],[data-go]') : null;
    if (!b) return;
    if (b.dataset.go && main.querySelector('[data-slot="kpis"]')?.contains(b)) {
      const [view, section] = b.dataset.go.split('/');
      state.go(view);
      if (section) requestAnimationFrame(() => main.querySelector(`[data-section="${section}"]`)?.scrollIntoView({ behavior: 'smooth', block: 'center' }));
      return;
    }
    if (!main.querySelector('[data-slot="hero"]')?.contains(b)) return;
    const act = b.dataset.act;
    if (act === 'switch') openSwitcher(state);
    else if (act === 'user') {
      const u = state.data.header.user;
      if (u?.dn) state.ctx.navigate('fiche', { dn: u.dn });
    } else if (act === 'points') {
      state.go('ensemble');
      requestAnimationFrame(() => main.querySelector('[data-slot="health"]')?.scrollIntoView({ behavior: 'smooth', block: 'start' }));
    } else if (act === 'stopRun') {
      state.stop(b.dataset.kind);
    } else if (act === 'revoke') {
      try {
        const r = await state.call('poste.consent.revoke', { dn: state.dn, kind: 'intervention' });
        state.data.consent = r.consent;
        paintConsent(main, state);
        state.emit('consent', r.consent);
        toast('Autorisation d’intervention retirée.', { tone: 'info' });
      } catch (err) { toast(errorText(err), { tone: 'alert' }); }
    }
  };
  main.addEventListener('click', onClick);
  cleanups.push(() => main.removeEventListener('click', onClick));
  cleanups.push(state.on('consent', (consent) => { state.data.consent = consent; paintConsent(main, state); }));
}

async function pingRead(main, state) {
  state.bar?.setBusy('ping', true);
  try {
    const r = await state.call('poste.ping', { dn: state.dn });
    const name = state.data.computer.name;
    // An unknown round trip is never written « 0 ms ».
    const answer = r.answered ? (r.roundTripMs > 0 ? `${name} répond au ping en ${int(r.roundTripMs)}${NBSP}ms.` : `${name} répond au ping.`)
      : `${name} ne répond pas au ping${NBSP}: ce n’est pas une preuve qu’il est éteint.`;
    toast(answer, { tone: r.answered ? 'ok' : 'warn' });
    await state.reload();
  } catch (err) {
    toast(errorText(err), { tone: 'warn' });
  } finally {
    state.bar?.setBusy('ping', false);
  }
}

async function liveRead(main, state) {
  state.bar?.setBusy('live', true);
  try {
    const live = await state.call('poste.live', { dn: state.dn });
    state.emit('live', live);
    await state.reload();
    announce('État en direct lu.');
  } catch (err) {
    toast(errorText(err), { tone: 'warn' });
  } finally {
    state.bar?.setBusy('live', false);
  }
}

export { liveRead, pingRead };
