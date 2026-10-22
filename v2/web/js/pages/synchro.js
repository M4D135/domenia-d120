// « Synchronisation et base autonome » (docs/ops/synchro.md): the local copy of the directory that Domenia works with
// without the network. Hero with the freshness of the chosen scope, four tiles, the read in progress or its result, then five
// workspaces: update, data, controls, snapshots, park. Local reads load on display; every read of the directory and every
// change of the base starts from an explicit gesture (estimate confirmed, plan confirmed through the write circuit).
import { createTabs, openMenu } from '../kit/index.js';
import { reveal, countUp, motionReduced } from '../ui.js';
import {
  esc, icon, glyph, pill, int, count, NBSP, toneOf, sk, skStack, errorBlock, button, paint, ago, setVars,
} from './synchro/common.js';
import { createRunPanel } from './synchro/run.js';
import { openScopePicker } from './synchro/scope.js';
import { renderUpdate } from './synchro/update.js';
import { renderData } from './synchro/data.js';
import { renderControls } from './synchro/controls.js';
import { renderSnapshots } from './synchro/snapshots.js';
import { renderPark } from './synchro/park.js';

export const stylesheet = true;

const TABS = [
  { id: 'mise-a-jour', label: 'Mise à jour', icon: 'refresh', render: renderUpdate },
  { id: 'donnees', label: 'Données', icon: 'database', render: renderData },
  { id: 'controles', label: 'Contrôles', icon: 'shield', render: renderControls },
  { id: 'releves', label: 'Relevés', icon: 'layers', render: renderSnapshots },
  { id: 'parc', label: 'Parc', icon: 'monitor', render: renderPark },
];
const TAB_KEY = 'domenia.synchro.tab.v1';
const TILE_ICONS = { accounts: 'users', computers: 'monitor', links: 'link', updated: 'clock' };
const COVERAGE_LABELS = { complete: 'Lecture complète', partial: 'Tentative incomplète', unknownDepth: 'Profondeur inconnue', missing: 'Jamais lu en entier' };
const SOURCE_LABELS = { working: 'OU de travail', chosen: 'Choisie ici', domain: 'Domaine entier' };
const DAY = 86_400_000;

function savedTab() {
  try { return localStorage.getItem(TAB_KEY); } catch { return null; }
}
function saveTab(id) {
  try { localStorage.setItem(TAB_KEY, id); } catch { /* private mode: keep in memory */ }
}

// ---------------------------------------------------------------- markup

function skeletonPage() {
  const tile = () => `<article class="card sy-tile reveal">${skStack('sk-line w40', 'sk-value w55', 'sk-line w70')}</article>`;
  return `<div class="page sy-page"><div class="grid">
    <section class="hero sy-hero span-12 reveal" aria-busy="true">
      <span class="glow-ring hero-ring" aria-hidden="true"></span>
      <div class="sy-hero-grid"><div class="sy-hero-main">${skStack('sk-line w25', 'sk-title w55', 'sk-line w85', 'sk-line w70')}</div>
      <div class="sy-dial-card">${sk('sk-ring')}${skStack('sk-line w40', 'sk-line w70')}</div></div>
    </section>
    <div class="sy-tiles span-12">${tile()}${tile()}${tile()}${tile()}</div>
    <section class="card sy-tabs-card span-12 reveal">${skStack('sk-line w40', 'sk-block w100')}</section>
  </div></div>`;
}

function dialMarkup(o) {
  const cov = o.coverage;
  const tile = o.tiles.find((t) => t.key === 'updated');
  const tone = toneOf(tile?.tone ?? 'warn');
  const at = Date.parse(cov.at ?? '');
  const p = Number.isNaN(at) ? 0 : Math.max(0.05, Math.min(1, 1 - (Date.now() - at) / (7 * DAY)));
  const value = tile?.value ?? '—';
  const caption = COVERAGE_LABELS[cov.status] ?? 'Couverture';
  const label = `Fraîcheur du périmètre ${o.scope.label}${NBSP}: ${caption.toLowerCase()}, ${value}.`;
  return `<div class="sy-dial" data-tone="${tone}" role="img" aria-label="${esc(label)}">
      <span class="sy-dial-glow" aria-hidden="true"></span>
      <span class="sy-dial-track" aria-hidden="true"></span>
      <span class="sy-dial-arc" data-dial="${p.toFixed(3)}" aria-hidden="true"></span>
      <span class="sy-dial-ticks" aria-hidden="true">${Array.from({ length: 28 }, (_, n) => `<i data-i="${n}"></i>`).join('')}</span>
      <span class="sy-dial-orbit" aria-hidden="true"><span class="sy-dial-dot"></span></span>
      <span class="sy-dial-center"><span class="sy-dial-kicker">${esc(caption)}</span><b class="sy-dial-value">${esc(value)}</b><span class="sy-dial-cap">${esc(tile?.detail ?? '')}</span></span>
    </div>`;
}

function scopeMarkup(o) {
  const s = o.scope;
  const parts = String(s.path ?? '').split(/\s*›\s*/).filter(Boolean);
  const crumbs = parts.map((p, n) => `<span class="sy-crumb${n === parts.length - 1 ? ' last' : ''}">${esc(p)}</span>`).join(`<span class="sy-crumb-sep" aria-hidden="true">${glyph('chevronRight')}</span>`);
  const back = s.source === 'chosen' ? button('OU de travail', { icon: 'home', sm: true, ghost: true, data: { act: 'scope-reset' }, tip: 'Revenir à l’OU de travail de la session' }) : '';
  return `<div class="sy-scope">
      <span class="sy-scope-kicker" data-tip="Périmètre de mise à jour de la base">${glyph(s.isDomain ? 'domain' : 'ou')}Périmètre</span>
      <div class="sy-scope-name"><b>${esc(s.label)}</b>${pill(s.isDomain ? 'warn' : s.source === 'chosen' ? 'accent' : 'info', s.isDomain ? SOURCE_LABELS.domain : SOURCE_LABELS[s.source] ?? 'OU', { size: 'sm' })}</div>
      <div class="sy-crumbs" aria-label="Chemin">${crumbs}</div>
      <div class="sy-scope-actions">${button('Choisir une OU', { icon: 'tree', sm: true, data: { act: 'scope' } })}${back}</div>
      ${s.isDomain ? `<p class="sy-scope-note">${icon('info')}<span>Domaine entier${NBSP}: la mise à jour par OU demande une OU. Les changements du domaine ont leur propre geste.</span></p>` : ''}
    </div>`;
}

function heroMarkup(o, sim) {
  const chips = [
    `<span class="sy-chip" data-tip="${esc(o.details)}">${glyph('database')}${esc(o.storeLabel)}</span>`,
    o.checkpoint ? `<span class="sy-chip" data-tip="Contrôleur et repère de la dernière lecture des changements du domaine">${glyph('server')}${esc(o.checkpoint.controller)}</span>` : '',
    o.checkpoint ? `<span class="sy-chip mono" data-tip="Repère de synchronisation (USN)\u00A0: il n’avance qu’avec les données qu’il décrit">${glyph('hash')}USN ${int(o.checkpoint.usn)}</span>` : '',
    `<span class="sy-chip" data-tip="Chaque enregistrement confirmé fait avancer la génération de la base">${glyph('layers')}Génération ${int(o.generation)}</span>`,
    sim ? `<span class="sy-chip sim">${glyph('sparkles')}Simulation · en mémoire</span>` : '',
  ].join('');
  const ready = o.readiness.ready;
  const reason = o.readiness.reason ?? '';
  return `<span class="glow-ring hero-ring" aria-hidden="true"></span>
    <div class="orbs" aria-hidden="true"><span class="orb a"></span><span class="orb b"></span><span class="orb c"></span></div>
    <div class="sy-hero-grid">
      <div class="sy-hero-main">
        <p class="eyebrow">${icon('sync')}Base autonome · copie locale de l’annuaire</p>
        <h1>Synchronisation <span class="gradient-text">et base autonome</span></h1>
        <p class="lead">${esc(o.lead)}</p>
        <div class="sy-chips">${chips}</div>
        <div class="sy-hero-actions" role="group" aria-label="Lectures de l’annuaire">
          ${button(o.scope.isDomain ? 'Mettre à jour une OU…' : `Mettre à jour l’OU ${o.scope.label}`, { icon: 'refresh', primary: true, kind: 'network', data: { act: 'read-ou' }, disabled: !ready, tip: ready ? 'Relit l’OU choisie et ses sous-OU après une estimation à confirmer\u00A0; la base n’est modifiée qu’après votre confirmation de l’enregistrement.' : reason })}
          ${button('Changements du domaine', { icon: 'activity', kind: 'network', data: { act: 'read-domain' }, disabled: !ready, tip: ready ? 'Lit les objets modifiés depuis le repère (USN) et recense les identités, après estimation.' : reason })}
          <button class="btn ghost icon" type="button" data-act="more" aria-label="Autres gestes" data-tip="Autres gestes">${icon('more')}</button>
        </div>
      </div>
      <aside class="sy-dial-card" aria-label="Fraîcheur du périmètre">${dialMarkup(o)}${scopeMarkup(o)}</aside>
    </div>`;
}

function tilesMarkup(o) {
  return o.tiles.map((t, n) => {
    const tone = toneOf(t.tone);
    const number = Number.isFinite(t.number) ? t.number : null;
    let extra = '';
    if (t.key === 'computers' && number) {
      const rows = [...String(t.detail).matchAll(/(\d[\d\u202f\u00a0]*)/g)].map((m) => Number(m[1].replace(/\D/g, '')));
      const [active, disabled] = [rows[0] ?? 0, rows[1] ?? 0];
      extra = `<div class="sy-split" role="img" aria-label="${esc(t.detail)}"><span class="ok" data-grow="${active}"></span><span class="off" data-grow="${disabled}"></span></div>`;
    }
    if (t.key === 'updated') {
      extra = `<div class="sy-tile-pulse" data-tone="${tone}" aria-hidden="true"><span></span></div>`;
    }
    const value = number === null ? `<span class="sy-tile-value txt">${esc(t.value)}</span>`
      : `<span class="sy-tile-value num"><span class="visually-hidden">${esc(t.value)}</span><span data-count="${number}" aria-hidden="true">0</span></span>`;
    return `<article class="card sy-tile spot tilt reveal" data-tile="${esc(t.key)}" data-i="${n}">
      <div class="sy-tile-top"><span class="card-icon" data-tone="${tone === 'off' ? 'info' : tone}">${icon(TILE_ICONS[t.key] ?? 'info')}</span><h3>${esc(t.caption)}</h3></div>
      ${value}<p class="sy-tile-detail">${esc(t.detail)}</p>${extra}
    </article>`;
  }).join('');
}

function noticesMarkup(o) {
  const list = o.notices ?? [];
  if (!list.length) return '';
  return `<div class="sy-notices span-12 reveal" role="list" aria-label="Avis sur la base">${list.map((n, i) => `<div class="sy-notice" role="listitem" data-tone="${toneOf(n.tone)}" data-i="${i}">${icon(n.tone === 'warn' || n.tone === 'alert' ? 'alert' : 'info')}<span>${esc(n.text)}</span></div>`).join('')}</div>`;
}

// ---------------------------------------------------------------- screen

export function render(main, ctx) {
  const cleanups = [];
  const listeners = new Map();
  let alive = true;
  let overview = null;
  let scopeDn = typeof ctx.params.ou === 'string' && ctx.params.ou ? ctx.params.ou : null;
  let tabs = null;
  let runPanel = null;
  let sim = false;
  let disconnectReveal = () => {};
  const wanted = TABS.some((t) => t.id === ctx.params.onglet) ? ctx.params.onglet : (TABS.some((t) => t.id === savedTab()) ? savedTab() : TABS[0].id);

  main.innerHTML = skeletonPage();
  disconnectReveal = reveal(main);

  /** Small event bus between the hero, the run panel and the workspaces. */
  const screen = {
    ctx,
    params: ctx.params,
    get overview() { return overview; },
    get sim() { return sim; },
    get scopeDn() { return scopeDn; },
    scopeArgs: () => (scopeDn ? { dn: scopeDn } : {}),
    on(event, fn) {
      if (!listeners.has(event)) listeners.set(event, new Set());
      listeners.get(event).add(fn);
      return () => listeners.get(event)?.delete(fn);
    },
    emit(event, data) {
      (listeners.get(event) ?? []).forEach((fn) => {
        try { fn(data); } catch (err) { console.error(err); }
      });
    },
    alive: () => alive,
    reload: () => loadOverview(),
    setScope: (dn) => applyScope(dn),
    chooseScope: () => chooseScope(),
    startRead: (target) => runPanel?.estimate(target),
    showTab: (id) => tabs?.select(id),
    addCleanup: (fn) => cleanups.push(fn),
  };

  ctx.app?.then((info) => { sim = info?.mode === 'simulation'; }).catch(() => {});

  async function loadOverview(first = false) {
    try {
      const o = await ctx.call('synchro.overview', screen.scopeArgs());
      if (!alive) return;
      overview = o;
      if (first) mount(o); else update(o);
      screen.emit('overview', o);
    } catch (err) {
      if (!alive) return;
      console.error(err);
      if (first) {
        main.innerHTML = `<div class="page sy-page"><section class="card sy-fatal">${errorBlock(err)}</section></div>`;
        main.querySelector('[data-retry]')?.addEventListener('click', () => { main.innerHTML = skeletonPage(); loadOverview(true); });
      } else {
        ctx.toast(`Base locale non relue${NBSP}: ${err?.message ?? 'erreur inconnue.'}`, { tone: 'warn' });
      }
    }
  }

  function mount(o) {
    const app = ctx.app ?? Promise.resolve(null);
    main.innerHTML = `<div class="page sy-page"><div class="grid">
      <section class="hero sy-hero span-12 reveal" data-slot="hero"></section>
      <div class="sy-tiles span-12" data-slot="tiles"></div>
      <div class="sy-notices-slot span-12" data-slot="notices"></div>
      <div class="sy-run-slot span-12" data-slot="run"></div>
      <section class="card sy-tabs-card span-12 reveal" data-slot="tabs" aria-label="Espaces de travail de la base"></section>
    </div></div>`;
    paintHero(o);
    paintTiles(o, true);
    paintNotices(o);
    runPanel = createRunPanel(main.querySelector('[data-slot="run"]'), screen);
    cleanups.push(() => runPanel.destroy());
    const host = main.querySelector('[data-slot="tabs"]');
    tabs = createTabs(host, {
      label: 'Espaces de travail de la base autonome',
      selected: wanted,
      tabs: TABS.map((t) => ({ id: t.id, label: t.label, icon: t.icon, render: (panel) => t.render(panel, screen) })),
      onChange: (id) => saveTab(id),
    });
    cleanups.push(() => tabs?.destroy());
    if (tabs.current() !== wanted) tabs.select(wanted);
    disconnectReveal();
    disconnectReveal = reveal(main);
    app.then(() => runPanel?.resume(o)).catch(() => {});
    openFromParams();
  }

  function update(o) {
    paintHero(o);
    paintTiles(o, false);
    paintNotices(o);
  }

  function paintHero(o) {
    const hero = main.querySelector('[data-slot="hero"]');
    if (!hero) return;
    hero.removeAttribute('aria-busy');
    hero.innerHTML = heroMarkup(o, sim);
    paint(hero);
    const arc = hero.querySelector('[data-dial]');
    if (arc) setVars(arc, { '--p': arc.dataset.dial });
  }

  function paintTiles(o, first) {
    const host = main.querySelector('[data-slot="tiles"]');
    if (!host) return;
    const before = new Map([...host.querySelectorAll('[data-count]')].map((n) => [n.closest('[data-tile]')?.dataset.tile, Number(n.dataset.count)]));
    host.innerHTML = tilesMarkup(o);
    paint(host);
    host.querySelectorAll('[data-count]').forEach((n, k) => {
      const key = n.closest('[data-tile]')?.dataset.tile;
      const from = first ? 0 : (before.get(key) ?? 0);
      countUp(n, Number(n.dataset.count), { from, delay: first ? 120 + k * 70 : 0 });
    });
    if (!first) host.querySelectorAll('.reveal').forEach((n) => { n.classList.remove('reveal'); n.classList.add('revealed', 'sy-bump'); });
  }

  function paintNotices(o) {
    const host = main.querySelector('[data-slot="notices"]');
    if (!host) return;
    host.innerHTML = noticesMarkup(o);
    paint(host);
  }

  async function chooseScope() {
    const picked = await openScopePicker(ctx, { current: overview?.scope ?? null, sim });
    if (picked && alive) applyScope(picked.dn);
  }

  function applyScope(dn) {
    scopeDn = dn || null;
    const params = { ...ctx.params };
    if (scopeDn) params.ou = scopeDn; else delete params.ou;
    // The address keeps the choice (shareable, captured); the screen reads again locally, nothing from the directory.
    history.replaceState(null, '', ctx.link('synchro', params));
    loadOverview().then(() => {
      screen.emit('scope', scopeDn);
      ctx.toast(scopeDn ? `Périmètre${NBSP}: ${overview?.scope?.label ?? 'OU choisie'} et ses sous-OU.` : 'Périmètre\u00A0: OU de travail de la session.', { tone: 'info', life: 3200 });
    });
  }

  function moreMenu(target) {
    const o = overview;
    openMenu(target, [
      { heading: 'Base autonome' },
      { label: 'Relire l’état de la base', icon: 'refresh', run: () => loadOverview() },
      { label: 'Choisir une OU…', icon: 'tree', run: () => chooseScope() },
      '-',
      { label: 'Vérifier les disparitions…', icon: 'eye', run: () => { tabs?.select('controles'); screen.emit('ask', 'check'); } },
      { label: 'Enregistrer un relevé du périmètre…', icon: 'layers', run: () => { tabs?.select('releves'); screen.emit('ask', 'capture'); } },
      { label: 'Relevé du parc', icon: 'monitor', run: () => tabs?.select('parc') },
      '-',
      { label: o?.scope?.isDomain ? 'Lecture de l’OU\u00A0: choisissez une OU' : 'Relire l’OU choisie en entier…', icon: 'download', disabled: Boolean(o?.scope?.isDomain), reason: 'Choisissez une OU\u00A0: jamais tout le domaine sans garde.', run: () => runPanel?.estimate('ou') },
    ], { label: 'Autres gestes', placement: 'bottom-end' });
  }

  function openFromParams() {
    const p = ctx.params;
    if (p.choisir === '1') chooseScope();
    else if (p.lecture === 'ou' || p.lecture === 'domaine') runPanel?.estimate(p.lecture === 'domaine' ? 'domain' : 'ou');
    else if (p.apercu === 'lecture') {
      // Captures and demonstrations: in simulation only (no network exists), the read of the chosen OU runs on its own.
      (ctx.app ?? Promise.resolve(null)).then((info) => { if (info?.mode === 'simulation' && alive) runPanel?.demo(); }).catch(() => {});
    }
  }

  main.addEventListener('click', (e) => {
    const t = e.target instanceof Element ? e.target.closest('[data-act]') : null;
    if (!t || t.disabled || !main.contains(t)) return;
    const act = t.dataset.act;
    if (act === 'scope') chooseScope();
    else if (act === 'scope-reset') applyScope(null);
    else if (act === 'read-ou') {
      if (overview?.scope?.isDomain) chooseScope(); else runPanel?.estimate('ou');
    } else if (act === 'read-domain') runPanel?.estimate('domain');
    else if (act === 'more') moreMenu(t);
  });

  screen.on('stored', () => loadOverview());
  loadOverview(true);

  return () => {
    alive = false;
    disconnectReveal();
    cleanups.splice(0).forEach((fn) => { try { fn(); } catch (err) { console.error(err); } });
    listeners.clear();
  };
}

// Used by the workspaces: number of a count text, « — » otherwise.
export const fmt = { int, count };
void motionReduced;
