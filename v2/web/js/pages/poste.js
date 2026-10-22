// Poste: the console of one workstation (docs/ops/poste.md). Without a workstation, the picker of the working OU; with one
// (#/poste?dn=… or ?nom=PC-PAR-0001), a hero header that never moves (presence, user, inventory, health, actions), a live
// strip and six views: Vue d’ensemble, Inventaire, Diagnostic, Sondes et relevés, Intervenir, Secrets. Every network read
// starts from a gesture of the operator; every write goes through the write circuit (plan, confirmation, receipt, re-read).
// Route parameters: dn | nom, vue, onglet (Domenia 1 tab names accepted), panneau (opens a panel), verifier=1 (opened from
// the list: one ping, Domenia 1 PST-051), essai (simulation only: runs one read for the captures and the guides; ignored in
// directory mode).
import { createTabs, createCommandBar, startFreshness } from '../kit/index.js';
import { onEvent } from '../bridge.js';
import { esc, ico, rel, chip, scoreRing, paintMeters, tickRelative, sk, skLines, failure, errorText, NBSP, int } from './poste/common.js';
import { renderPicker, openSwitcher } from './poste/picker.js';
import { renderOverview } from './poste/overview.js';
import { renderInventory } from './poste/inventory.js';
import { renderDiagnostic } from './poste/diagnostic.js';
import { renderReadings } from './poste/readings.js';
import { renderAct } from './poste/act.js';
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
  evenements: ['diagnostic', 'evenements'], wmi: ['diagnostic', 'wmi'], sondes: ['releves'], laps: ['secrets'], bitlocker: ['secrets'],
  live: ['ensemble'], detection: ['ensemble'], connexions: ['ensemble'],
};

export function render(main, ctx) {
  const params = ctx.params ?? {};
  if (!params.dn && !params.nom) return renderPicker(main, ctx);
  return renderConsole(main, ctx, params);
}

function skeletonConsole() {
  return `<div class="page ps-page"><section class="ps-hero reveal" aria-busy="true"><div class="ps-hero-grid">
      <div class="ps-hero-main">${skLines('w25', 'w40', 'w55', 'w70')}</div><div class="ps-hero-score">${sk('ps-sk-ring')}</div></div></section>
    <div class="ps-live">${[1, 2, 3, 4].map(() => `<div class="card ps-live-tile" aria-busy="true">${skLines('w40', 'w70', 'w55')}</div>`).join('')}</div>
    <div class="card ps-views" aria-busy="true">${skLines('w100', 'w85', 'w70', 'w85', 'w55')}</div></div>`;
}

async function resolveDn(ctx, params) {
  if (params.dn) return params.dn;
  const name = String(params.nom ?? '').trim();
  const list = await ctx.call('poste.list', { text: name, limit: 50 });
  const row = list.rows.find((r) => r.name.toLowerCase() === name.toLowerCase()) ?? null;
  if (!row) throw Object.assign(new Error(`Aucun poste nommé ${name} dans l’OU de travail : choisissez-le dans la liste.`), { code: 'poste.unknown' });
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
    /** Reads the console again (after a write, a ping, an inventory) and repaints the header. */
    async reload() {
      const data = await ctx.call('poste.open', { dn: this.dn });
      if (!alive) return null;
      this.data = data;
      paintHeader(main, this);
      this.emit('console', data);
      return data;
    },
    go(view, tab) { views?.select(view); if (tab) this.emit('tab', { view, tab }); },
    toast,
    announce,
    alive: () => alive,
  };

  let views = null;
  const start = async () => {
    try {
      const info = await ctx.call('app.info').catch((err) => { console.error(err); return null; });
      app.mode = info?.mode ?? null;
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
    main.innerHTML = `<div class="page ps-page">
      <section class="ps-hero reveal" data-slot="hero"></section>
      <div class="ps-live" data-slot="live"></div>
      <div class="ps-views reveal" data-slot="views"></div>
    </div>`;
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
    if (params.panneau === 'postes') openSwitcher(state);
    if (params.verifier === '1') {
      // Opened from the list (PST-051): one ping, recorded; the address loses the parameter so a reload sends nothing.
      history.replaceState(null, '', `#/poste?${new URLSearchParams({ dn: state.dn, vue: initial }).toString()}`);
      pingRead(main, state);
    }
  };
  start();

  return () => {
    alive = false;
    cleanups.forEach((fn) => { try { fn(); } catch (err) { console.error(err); } });
    state.listeners.clear();
  };
}

// ---------- Header (hero) ----------

const PRESENCE_ICON = { online: 'wifi', offline: 'wifiOff', pending: 'refresh', error: 'alert', unknown: 'ping', remembered: 'history' };

function paintHeader(main, state) {
  const d = state.data;
  const hero = main.querySelector('[data-slot="hero"]');
  if (!hero || !d) return;
  const h = d.header;
  const c = d.computer;
  const health = d.board?.health;
  const presence = h.presence;
  const laptop = c.kind === 'laptop';
  const user = h.user;
  const inv = d.inventory;
  hero.dataset.tone = presence.tone;
  hero.innerHTML = `<span class="glow-ring hero-ring" aria-hidden="true"></span>
    <div class="orbs" aria-hidden="true"><span class="orb a"></span><span class="orb b"></span><span class="orb c"></span></div>
    <div class="ps-hero-grid">
      <div class="ps-hero-main">
        <div class="ps-hero-id">
          <button class="ps-avatar" type="button" data-act="switch" data-tone="${esc(presence.tone)}" aria-label="Changer de poste (postes de l’OU de travail)" data-tip="Changer de poste">
            <span class="ps-avatar-halo" aria-hidden="true"></span>${ico(laptop ? 'laptop' : c.kind === 'server' ? 'server' : 'monitor')}<span class="ps-avatar-dot" aria-hidden="true"></span></button>
          <div class="ps-hero-titles">
            <p class="eyebrow">${ico('sparkles')}${esc(c.kindLabel)} · ${esc(c.ou.path)}</p>
            <h1 class="gradient-text">${esc(h.name)}</h1>
            <p class="ps-hero-sys">${esc(h.systemText)}</p>
          </div>
        </div>
        <div class="ps-hero-chips">
          <span class="ps-presence" data-state="${esc(presence.state)}" data-tone="${esc(presence.tone)}" tabindex="0" data-tip="${esc(presence.help)}">
            <span class="ps-presence-dot${presence.state === 'online' ? ' pulse' : ''}" aria-hidden="true"></span>${ico(PRESENCE_ICON[presence.state] ?? 'ping')}<span>${esc(presence.label)}</span>
            ${presence.checkedAt ? `<span class="ps-presence-age">${rel(presence.checkedAt)}</span>` : ''}<span class="visually-hidden"> · ${esc(presence.help)}</span></span>
          ${user ? `<button class="ps-user" type="button" data-act="user" data-tip="${esc(h.userHelp)}"><span class="avatar" aria-hidden="true">${esc(initials(user.name))}</span><span><b>${esc(user.name)}</b><small>${esc(d.association.badgeLabel)} · ${esc(user.login)}</small></span></button>`
            : `<span class="ps-user none" tabindex="0" data-tip="${esc(h.userHelp)}">${ico('user')}<span><b>Aucun utilisateur associé</b><small>Détecter dans la vue d’ensemble</small></span></span>`}
          <span class="chip ps-inv-chip${inv ? '' : ' warn'}" data-tip="${esc(inv ? `${inv.origin} · ${inv.sources} sources lues${inv.refused ? `, ${inv.refused} refusée(s)` : ''}` : h.inventoryText)}">${ico('layers')}${esc(inv ? `${inv.modeLabel} ${inv.ageText}` : 'Aucun inventaire')}</span>
          <span class="ps-consent" data-slot="consent" hidden></span>
          ${c.enabled === false ? chip('alert', 'Compte désactivé', c.accountText) : ''}
          ${d.simulated ? `<span class="chip info" data-tip="${esc(d.options.simulationNote)}">${ico('sparkles')}Poste fictif</span>` : ''}
        </div>
      </div>
      <div class="ps-hero-score">
        ${scoreRing(health?.score, health?.state, `Santé du poste : ${health?.verdict ?? 'non évaluée'}`)}
        <div class="ps-hero-verdict"><span class="ps-verdict" data-tone="${esc(health?.state ?? 'off')}">${esc(health?.verdict ?? '—')}</span>
          <span class="ps-hero-points">${esc(health?.title ?? '')}</span>
          <button class="btn ghost sm" type="button" data-act="points">${ico('chevronRight')}Points d’attention</button></div>
      </div>
      <div class="ps-hero-bar" data-slot="bar"></div>
    </div>`;
  paintMeters(hero);
  paintConsent(main, state);
  paintLive(main, state);
  const bar = hero.querySelector('[data-slot="bar"]');
  state.bar?.destroy?.();
  state.bar = createCommandBar(bar, {
    label: 'Actions du poste',
    items: [
      { id: 'live', label: 'Actualiser l’état', icon: 'refresh', primary: true, kind: 'network', run: () => liveRead(main, state) },
      { id: 'ping', label: 'Tester la réponse', icon: 'wifi', kind: 'network', run: () => pingRead(main, state) },
      { id: 'inventory', label: 'Inventaire', icon: 'layers', kind: 'network', items: [
        { label: 'Inventaire rapide (≈ 1 min)', icon: 'layers', run: () => { state.go('inventaire', 'materiel'); state.emit('run', { what: 'inventory', deep: false }); } },
        { label: 'Inventaire complet (≈ 3 min)', icon: 'layers', run: () => { state.go('inventaire', 'materiel'); state.emit('run', { what: 'inventory', deep: true }); } },
      ] },
      { id: 'diag', label: 'Diagnostic', icon: 'activity', kind: 'network', run: () => { state.go('diagnostic', 'reseau'); state.emit('run', { what: 'diagnostic' }); } },
      { id: 'slow', label: 'Poste lent ?', icon: 'gauge', kind: 'network', run: () => { state.go('diagnostic', 'lent'); state.emit('run', { what: 'slow' }); } },
      { id: 'restart', label: 'Redémarrer…', icon: 'power', kind: 'write', danger: true, overflow: true, run: () => { state.go('intervenir'); state.emit('run', { what: 'restart' }); } },
      { id: 'switch', label: 'Changer de poste', icon: 'monitor', overflow: true, run: () => openSwitcher(state) },
      { id: 'copy', label: 'Copier le nom du poste', icon: 'copy', overflow: true, run: () => copyName(state) },
    ],
  });
}

function initials(name) {
  return String(name ?? '').split(/[\s-]+/).filter(Boolean).slice(0, 2).map((p) => p[0].toUpperCase()).join('');
}

async function copyName(state) {
  const { writeClipboard } = await import('../kit/index.js');
  await writeClipboard(state.data.computer.name);
  toast(`Nom copié${NBSP}: ${state.data.computer.name}`, { tone: 'ok' });
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

function paintLive(main, state) {
  const host = main.querySelector('[data-slot="live"]');
  const d = state.data;
  if (!host || !d) return;
  const live = d.live;
  const presence = d.header.presence;
  const inv = d.inventory;
  const uptimeFact = d.board?.identity?.lines?.find((l) => l.key === 'computer.uptime');
  const userLine = d.board?.identity?.lines?.find((l) => l.key === 'computer.user');
  const tiles = [
    {
      icon: 'ping', title: 'Présence', tone: presence.tone,
      value: presence.state === 'online' ? (presence.roundTripMs != null ? `${int(presence.roundTripMs)}${NBSP}ms` : 'Répond') : presence.state === 'offline' ? 'Muet' : presence.state === 'error' ? 'Erreur' : 'Non vérifiée',
      sub: presence.checkedAt ? rel(presence.checkedAt, 'Test ') : 'Aucun test dans cette session',
    },
    {
      icon: 'clock', title: 'En service depuis', tone: live?.uptimeText ? 'info' : uptimeFact?.state === 'warn' ? 'warn' : 'info',
      value: live?.uptimeText ?? (uptimeFact && uptimeFact.value !== 'Non lu' ? uptimeFact.value : '—'),
      sub: live ? rel(live.at, 'Lu ') : uptimeFact?.detail ? `${esc(uptimeFact.detail)} · inventaire` : 'Actualisez l’état pour le lire',
    },
    (() => {
      // The account read by the inventory is shown with the name of the associated user when it is the same account.
      const account = userLine && userLine.value !== 'Non lu' ? userLine.value : null;
      const assoc = d.association.user;
      const same = !!(assoc?.login && account && account.toLowerCase().split('\\').pop() === assoc.login.toLowerCase());
      return {
        icon: 'user', title: 'Utilisateur connecté', tone: 'accent',
        value: live ? (live.consoleUser?.name ?? 'Personne') : same ? assoc.name : (account ?? '—'),
        sub: live ? esc(live.sessionsText) : account ? `${esc(account)} · dernier inventaire` : 'Actualisez l’état pour le lire',
      };
    })(),
    {
      icon: 'layers', title: 'Dernier inventaire', tone: inv ? 'ok' : 'warn',
      value: inv ? inv.modeLabel : 'Aucun',
      sub: inv ? rel(inv.at) : 'Lancez un inventaire rapide',
    },
  ];
  host.innerHTML = tiles.map((t, n) => `<div class="card ps-live-tile spot reveal" data-tone="${esc(t.tone)}" data-i="${n}">
    <span class="ps-live-ico">${ico(t.icon)}</span><div class="ps-live-text"><span class="ps-live-title">${esc(t.title)}</span><b class="ps-live-value">${esc(t.value)}</b><span class="ps-live-sub">${t.sub}</span></div></div>`).join('');
  revealCards(host);
}

function bindHeader(main, state, cleanups) {
  const onClick = async (e) => {
    const b = e.target instanceof Element ? e.target.closest('[data-act]') : null;
    if (!b || !main.querySelector('[data-slot="hero"]')?.contains(b)) return;
    const act = b.dataset.act;
    if (act === 'switch') openSwitcher(state);
    else if (act === 'user') {
      const u = state.data.header.user;
      if (u?.dn) state.ctx.navigate('fiche', { dn: u.dn });
    } else if (act === 'points') {
      state.go('ensemble');
      requestAnimationFrame(() => main.querySelector('[data-slot="health"]')?.scrollIntoView({ behavior: 'smooth', block: 'start' }));
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
    toast(r.answered ? `${state.data.computer.name} répond au ping en ${int(r.roundTripMs ?? 0)}${NBSP}ms.` : `${state.data.computer.name} ne répond pas au ping${NBSP}: ce n’est pas une preuve qu’il est éteint.`, { tone: r.answered ? 'ok' : 'warn' });
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
