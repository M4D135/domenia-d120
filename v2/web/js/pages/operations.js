// Opérations (docs/ops/operations.md): journal of the session — write receipts with their re-read and their manual review, tasks
// in progress and finished, journal, health of the engine, statistics, collection runs and diagnostics — under a hero that says
// at a glance whether a write waits for a check. Read only by default; every write leaves a receipt written before it is sent;
// nothing is ever replayed. Route parameters: onglet (recus, taches, journal, sante, statistiques, releves, diagnostic), recu=<id>
// (opens that receipt: link of the toast of the write circuit), filtre=a-verifier, tache=<id>, exemple=1 (local sample data for
// the captures and the preview), ouvrir=revue|tache (open states for the captures; nothing is ever sent by them).
import { icon } from '../icons.js';
import { esc, errorText, toast, applyVars, reveal, motionReduced } from '../ui.js';
import { createTabs, pill, glyph, writeLayout, NBSP } from '../kit/index.js';
import { TABS, silentCall, duration, int, count, toneMark, touchDates } from './operations/common.js';
import { createReceipts } from './operations/receipts.js';
import { createTasks } from './operations/tasks.js';
import { createJournal } from './operations/journal.js';
import { createHealth } from './operations/health.js';
import { createStats } from './operations/stats.js';
import { createRuns } from './operations/runs.js';
import { createDiagnostics } from './operations/diagnostics.js';
import { createPulse } from './operations/pulse.js';
import { sampleActivity, sampleReceipts } from './operations/demo.js';

export const stylesheet = true;

const ACTIVITY_MS = 2000;
const OVERVIEW_MS = 15_000;
const HEALTH_MS = 5000;
const RUNS_MS = 10_000;
const RUNS_LIVE_MS = 1500;
const longDate = new Intl.DateTimeFormat('fr-FR', { weekday: 'long', day: 'numeric', month: 'long' });
const RING = '<span class="glow-ring hero-ring" aria-hidden="true"></span>';
const PILL_HELP = `Une écriture envoyée attend une relecture ou une revue${NBSP}: les nouvelles écritures sur son objet restent bloquées. Ouvre la liste des reçus${NBSP}; rien n’est rejoué.`;
const KPI_NAMES = { pending: 'Reçus à vérifier : ouvrir les reçus', tasks: 'Tâches en cours : ouvrir les tâches', session: 'Opérations de la session : ouvrir les tâches', pulse: 'Réactivité de l’interface : ouvrir la santé du moteur' };
const ORBS = '<div class="orbs" aria-hidden="true"><span class="orb a"></span><span class="orb b"></span><span class="orb c"></span></div>';

function skeleton(demo) {
  const sk = (cls) => `<span class="skeleton op-sk-line ${cls}"></span>`;
  const kpi = (id) => `<article class="card kpi op-kpi spot tilt reveal" data-kpi="${id}" tabindex="0" role="button" aria-label="${esc(KPI_NAMES[id])}"><div class="op-sk">${sk('w40')}${sk('w55 tall')}${sk('w70')}</div></article>`;
  return `<div class="page op-page">
    <section class="hero op-hero reveal" data-slot="hero">${RING}${ORBS}
      <div class="op-hero-grid">
        <div class="op-hero-main">
          <div class="eyebrow">${icon('activity')}<span>Journal des opérations</span><span class="op-eyebrow-date">${esc(longDate.format(new Date()))}</span></div>
          <h1 class="gradient-text">Opérations</h1>
          <p class="lead">Tâches du moteur, reçus d’écriture et santé de la session. Chaque écriture laisse un reçu écrit avant l’envoi, puis relu${NBSP}; rien n’est jamais rejoué automatiquement.</p>
          <div class="op-hero-chips" data-slot="chips">${demo ? pill('off', 'Exemple local · aucune donnée réelle', { icon: 'info' }) : ''}<span class="skeleton op-sk-chip"></span><span class="skeleton op-sk-chip"></span></div>
          <div class="hero-row op-hero-actions">
            <button class="btn primary" type="button" data-act="refresh">${icon('refresh')}Actualiser</button>
            <button class="btn" type="button" data-act="why">${icon('info')}Pourquoi une action est indisponible${NBSP}?</button>
            <button class="btn" type="button" data-act="check">${icon('shield')}Vérifier l’application</button>
          </div>
        </div>
        <aside class="op-circuit" data-slot="circuit" aria-live="polite"><div class="op-sk">${sk('w40')}${sk('w70 tall')}${sk('w85')}${sk('w55')}</div></aside>
      </div>
    </section>
    <div class="op-offer-banner" data-slot="offer" hidden></div>
    <div class="op-kpis">${['pending', 'tasks', 'session', 'pulse'].map(kpi).join('')}</div>
    <section class="op-workspace reveal"><div class="op-tabs"></div></section>
    <span class="op-auto" hidden></span>
  </div>`;
}

export function render(main, ctx) {
  const params = ctx.params ?? {};
  const demo = params.exemple === '1';
  let alive = true;
  let overview = null;
  let activity = null;
  let simulation = true;
  const timers = [];
  const modules = {};
  const taskHistory = [];
  const blocks = new WeakMap();

  main.innerHTML = skeleton(demo);
  applyVars(main);
  const stopReveal = reveal(main);
  const page = main.querySelector('.op-page');

  // The heartbeat of the page (OPE-030): measured while the screen is shown, drawn by the health tab and the last tile.
  const pulse = createPulse({
    onBeat: (state) => {
      if (!alive) return;
      modules.sante?.beat(state);
      paintPulseTile(state);
    },
  });

  // ---------------------------------------------------------------- tabs

  const wanted = TABS.some((t) => t.id === params.onglet) ? params.onglet
    : params.recu || params.filtre || params.ouvrir === 'revue' ? 'recus'
      : params.tache || params.ouvrir === 'tache' ? 'taches'
        : params.ouvrir === 'verification' || params.ouvrir === 'apercu' ? 'diagnostic' : null;
  if (wanted) writeLayout('tabs:operations.onglet', { v: 1, selected: wanted });
  const env = { ctx, demo, params, silent: silentCall, pulse };
  const factories = {
    recus: (panel) => (modules.recus = createReceipts(panel, { ...env, onCounts: (c) => paintReceiptCounts(c) })),
    taches: (panel) => {
      modules.taches = createTasks(panel, { ...env, onStop: (id) => ctx.call('operations.task.stop', { id }).then((row) => { pollActivity(); return row; }) });
      if (activity) modules.taches.update(activity);
      return modules.taches;
    },
    journal: (panel) => (modules.journal = createJournal(panel, env)),
    sante: (panel) => (modules.sante = createHealth(panel, env)),
    statistiques: (panel) => (modules.statistiques = createStats(panel, env)),
    releves: (panel) => (modules.releves = createRuns(panel, { ...env, onOffer: (offer, current) => paintOffer(offer, current) })),
    diagnostic: (panel) => (modules.diagnostic = createDiagnostics(panel, env)),
  };
  const tabs = createTabs(main.querySelector('.op-tabs'), {
    label: 'Sections de l’écran Opérations',
    key: 'operations.onglet',
    selected: wanted ?? 'recus',
    tabs: TABS.map((t) => ({
      ...t,
      count: null,
      render: (panel) => {
        panel.classList.add('op-panel');
        panel.dataset.tab = t.id;
        const module = pulse.measure(`Affichage de l’onglet ${t.label}`, () => factories[t.id](panel));
        return () => module?.destroy?.();
      },
    })),
    onChange: (id) => {
      // The tab stays in the address (a reload keeps it) without rendering the screen again.
      history.replaceState(null, '', ctx.link('operations', { onglet: id, ...(demo ? { exemple: '1' } : {}) }));
      if (id === 'sante') modules.sante?.refresh(true);
      if (id === 'releves') modules.releves?.refresh(true);
    },
  });

  // ---------------------------------------------------------------- head of the screen

  function loadOverview(silent = false) {
    const read = silent ? silentCall('operations.overview') : ctx.call('operations.overview');
    return read.then((o) => {
      if (!alive) return;
      overview = o;
      simulation = o.simulation;
      if (demo) {
        const sample = sampleReceipts();
        overview = { ...o, receiptsTotal: sample.total, receiptsPending: sample.pending, receiptsSummary: sample.summary,
          pill: { visible: true, text: `${sample.pending} opérations à vérifier`, help: PILL_HELP } };
      }
      paintHero();
      paintKpis();
    }).catch((err) => {
      console.error(err);
      if (!alive) return;
      const host = main.querySelector('[data-slot="circuit"]');
      blocks.delete(host);
      host.innerHTML = `<div class="op-error" role="alert">${glyph('alert')}<span>${esc(errorText(err, 'Tête de l’écran illisible.'))}</span></div>`;
    });
  }

  function paintHero() {
    const o = overview;
    const chips = [
      demo ? pill('off', 'Exemple local · aucune donnée réelle', { icon: 'info' }) : '',
      o.simulation ? pill('accent', 'Simulation · annuaire fictif', { icon: 'sparkles' }) : pill('warn', 'Annuaire Active Directory', { icon: 'zap' }),
      pill(o.receiptsPersistent ? 'ok' : 'info', o.receiptsPersistent ? 'Reçus enregistrés sur le disque' : 'Reçus en mémoire seulement', { icon: 'file', tip: o.receiptsPersistent ? 'Fichier des reçus du mode, ajout atomique.' : 'Mode capture, E2E ou sans dossier de données : les reçus disparaîtront à la fermeture.' }),
      pill(o.writeKinds.length ? 'info' : 'off', o.writeKinds.length ? count(o.writeKinds.length, 'type d’écriture servi', 'types d’écriture servis') : 'Aucune écriture servie', { icon: 'edit', tip: o.writeKinds.join(', ') || 'Les écritures réelles arrivent avec Domenia.Ad (vague 3).' }),
      `<span class="op-chip-live" data-live-tasks>${pill((activity?.summary ?? o.tasks).active > 0 ? 'info' : 'ok', (activity?.summary ?? o.tasks).text, { icon: 'activity' })}</span>`,
    ].filter(Boolean);
    paintBlock(main.querySelector('[data-slot="chips"]'), chips.map((c, n) => `<span class="op-chip" data-j="${n}">${c}</span>`).join(''));
    paintCircuit();
  }

  function paintCircuit() {
    const o = overview;
    const host = main.querySelector('[data-slot="circuit"]');
    const pending = o.receiptsPending;
    let tone; let title; let text; let action = '';
    if (!o.receiptsReadable) {
      tone = 'alert'; title = 'Reçus illisibles'; text = o.receiptsSummary;
    } else if (pending > 0) {
      tone = 'warn'; title = o.pill.text; text = o.pill.help;
      action = `<button class="btn primary sm" type="button" data-act="pending">${glyph('eye')}Voir les reçus à vérifier</button>`;
    } else {
      tone = 'ok'; title = 'Au repos'; text = `Aucune écriture incertaine${NBSP}: rien ne bloque les écritures. Rien n’est jamais rejoué automatiquement.`;
    }
    host.dataset.tone = tone;
    paintBlock(host, `<div class="op-circuit-top"><span class="op-circuit-k">Circuit d’écriture</span>${pill(tone, tone === 'ok' ? 'Au repos' : tone === 'warn' ? 'À vérifier' : 'Bloqué', { size: 'sm', pulse: tone !== 'ok' })}</div>
      <div class="op-circuit-main">
        <span class="op-medal big" data-tone="${tone}" aria-hidden="true"><span class="op-medal-halo"></span><span class="op-medal-ring"></span><span class="op-medal-icon">${glyph(tone === 'ok' ? 'shield' : tone === 'warn' ? 'eye' : 'alert')}</span><span class="op-orbit"><i></i><i></i><i></i></span></span>
        <div class="op-circuit-text"><b>${esc(title)}</b><p>${esc(text)}</p></div>
      </div>
      <ol class="op-circuit-steps" aria-label="Les temps d’une écriture">${['Plan', 'Confirmation', 'Reçu', 'Envoi', 'Relecture'].map((s, n) => `<li data-j="${n}"><span>${n + 1}</span>${esc(s)}</li>`).join('')}</ol>
      <div class="op-circuit-foot"><span>${esc(count(o.receiptsTotal, 'reçu conservé', 'reçus conservés'))}${o.receiptsUnreadable ? ` · ${esc(count(o.receiptsUnreadable, 'illisible', 'illisibles'))}` : ''}</span>${action}</div>`);
  }

  function paintReceiptCounts(c) {
    tabs.setCount('recus', c.pending > 0 ? c.pending : c.total, c.pending > 0 ? 'warn' : 'off');
    if (overview && !demo) {
      overview = {
        ...overview, receiptsPending: c.pending, receiptsTotal: c.total, receiptsUnreadable: c.unreadable, receiptsReadable: c.readable,
        pill: c.pending > 0 ? { visible: true, text: c.pending === 1 ? '1 opération à vérifier' : `${int(c.pending)} opérations à vérifier`, help: PILL_HELP } : { visible: false, text: '', help: '' },
      };
      paintCircuit();
      paintKpis();
    }
  }

  // ---------------------------------------------------------------- tiles

  function tile(id, { iconName, tone, title, value, unit = '', sub = '', foot = '', art = '' }) {
    const el = main.querySelector(`[data-kpi="${id}"]`);
    if (!el) return;
    const before = el.querySelector('.value')?.textContent;
    el.dataset.tone = tone;
    const html = `<div class="op-kpi-top"><span class="card-icon">${glyph(iconName)}</span><h3>${esc(title)}</h3></div>
      <div class="op-kpi-main"><div class="value num">${esc(value)}${unit ? `<small>${esc(unit)}</small>` : ''}</div>${art}</div>
      <p class="op-kpi-sub">${esc(sub)}</p><div class="op-kpi-foot">${foot}</div><span class="op-kpi-line" aria-hidden="true"></span>`;
    // Settled tiles keep still on the 2 s refresh; only a changed figure moves again.
    if (paintBlock(el, html, true) && el.dataset.settled === 'true' && before !== el.querySelector('.value')?.textContent) {
      el.querySelector('.value')?.classList.add('op-bump');
    }
  }

  // Repaints a live block only when its markup changes (the silent refreshes return the same facts most of the
  // time); with `settle`, the later paints skip the entrance animations.
  function paintBlock(host, html, settle = false) {
    if (blocks.get(host) === html) return false;
    if (settle && blocks.has(host)) host.dataset.settled = 'true';
    blocks.set(host, html);
    host.innerHTML = html;
    applyVars(host);
    return true;
  }

  function paintKpis() {
    const o = overview;
    if (!o) return;
    const pending = o.receiptsPending;
    tile('pending', {
      iconName: 'shield', tone: pending > 0 ? 'warn' : 'ok', title: 'Reçus à vérifier', value: int(pending),
      sub: `sur ${count(o.receiptsTotal, 'reçu conservé', 'reçus conservés')}`,
      foot: pending > 0 ? `${glyph('lock')}<span>Bloquent les écritures sur leurs objets</span>` : `${glyph('check')}<span>Aucune écriture bloquée</span>`,
      art: `<span class="op-kpi-badge" aria-hidden="true">${glyph(pending > 0 ? 'eye' : 'check')}</span>`,
    });
    const a = activity;
    const active = a?.summary?.active ?? o.tasks.active;
    tile('tasks', {
      iconName: 'activity', tone: active > 0 ? 'info' : 'ok', title: 'Tâches en cours', value: int(active),
      sub: a?.summary?.text ?? o.tasks.text,
      foot: `${glyph('pause')}<span>Une lecture s’arrête, une écriture jamais</span>`,
      art: taskBars(),
    });
    const sessionCount = a ? a.recent.length + a.open.length : o.sessionTasks;
    const failures = a ? a.recent.filter((r) => ['refused', 'failed', 'unknown', 'timedOut'].includes(r.outcome)).length : o.sessionFailures;
    const success = a && a.recent.length ? (100 * a.recent.filter((r) => r.outcome === 'succeeded').length) / a.recent.length : o.successPercent;
    tile('session', {
      iconName: 'layers', tone: failures > 0 ? 'warn' : 'ok', title: 'Opérations de la session', value: int(sessionCount),
      sub: success == null ? 'Aucune opération terminée' : `${Math.round(success).toLocaleString('fr-FR')}${NBSP}% terminées sans incident`,
      foot: failures > 0 ? `${glyph('alert')}<span>${esc(count(failures, 'opération à revoir', 'opérations à revoir'))}</span>` : `${glyph('check')}<span>Aucune opération à revoir</span>`,
      art: successRing(success),
    });
    paintPulseTile(pulse.state());
  }

  function paintPulseTile(state) {
    const el = main.querySelector('[data-kpi="pulse"]');
    if (!el || !overview) return;
    const value = state.p95 ?? state.p50;
    const tone = value == null ? 'info' : value >= 400 ? 'alert' : value >= 120 ? 'warn' : 'ok';
    const label = state.p95 != null ? '95 % des battements' : 'retard habituel';
    if (!el.querySelector('.op-kpi-spark')) {
      tile('pulse', {
        iconName: 'gauge', tone, title: 'Réactivité de l’interface', value: value == null ? '—' : duration(value),
        sub: `${label} · mesure locale de la page`, foot: `${glyph('info')}<span>Pas un test du réseau</span>`,
        art: `<svg class="op-kpi-spark" viewBox="0 0 120 40" preserveAspectRatio="none" aria-hidden="true"><path class="op-kpi-spark-area" d=""/><path class="op-kpi-spark-line" d=""/></svg>`,
      });
    } else {
      el.dataset.tone = tone;
      el.querySelector('.value').textContent = value == null ? '—' : duration(value);
      el.querySelector('.op-kpi-sub').textContent = `${label} · mesure locale de la page`;
    }
    const values = state.samples.slice(-60);
    if (values.length > 1) {
      const top = Math.max(50, ...values) * 1.15;
      const pts = values.map((v, i) => [(120 * i) / (values.length - 1), 38 - (Math.min(v, top) / top) * 34]);
      const line = pts.map((p, i) => `${i ? 'L' : 'M'}${p[0].toFixed(1)},${p[1].toFixed(1)}`).join(' ');
      el.querySelector('.op-kpi-spark-line')?.setAttribute('d', line);
      el.querySelector('.op-kpi-spark-area')?.setAttribute('d', `${line} L120,40 L0,40 Z`);
    }
  }

  // The last 24 reads of the activity (every 2 s): one slot each, a faint base line when nothing ran.
  function taskBars() {
    const values = taskHistory.slice(-24);
    const slots = [...Array(24 - values.length).fill(null), ...values];
    const top = Math.max(1, ...values);
    const bars = slots.map((v, i) => {
      const h = v ? (v / top) * 34 + 2 : 2;
      return `<rect class="${v ? 'on' : 'base'}" x="${(i * 5).toFixed(1)}" y="${(40 - h).toFixed(1)}" width="3.4" height="${h.toFixed(1)}" rx="1.4"/>`;
    }).join('');
    return `<svg class="op-kpi-bars" viewBox="0 0 120 40" preserveAspectRatio="none" aria-hidden="true">${bars}</svg>`;
  }

  function successRing(p) {
    const pct = p == null ? 0 : Math.max(0, Math.min(100, p));
    return `<svg class="op-kpi-ring" viewBox="0 0 44 44" aria-hidden="true"><circle class="op-kpi-ring-track" cx="22" cy="22" r="18" pathLength="100"/>
      <circle class="op-kpi-ring-fill" cx="22" cy="22" r="18" pathLength="100" stroke-dasharray="${pct.toFixed(1)} 100"/></svg>`;
  }

  // ---------------------------------------------------------------- activity

  function pollActivity(first = false) {
    if (demo) {
      activity = sampleActivity();
      afterActivity();
      return Promise.resolve();
    }
    const read = first ? ctx.call('operations.activity') : silentCall('operations.activity');
    return read.then((a) => {
      if (!alive) return;
      activity = a;
      afterActivity();
    }).catch((err) => {
      if (first) console.error(err);
    });
  }

  function afterActivity() {
    taskHistory.push(activity.summary.active);
    while (taskHistory.length > 60) taskHistory.shift();
    tabs.setCount('taches', activity.summary.active > 0 ? activity.summary.active : null, 'info');
    const live = main.querySelector('[data-live-tasks]');
    if (live) live.innerHTML = pill(activity.summary.active > 0 ? 'info' : 'ok', activity.summary.text, { icon: 'activity', spin: activity.summary.active > 0 && !motionReduced() });
    modules.taches?.update(activity);
    paintKpis();
  }

  // ---------------------------------------------------------------- interrupted survey

  function paintOffer(offer, current) {
    const banner = main.querySelector('[data-slot="offer"]');
    tabs.setCount('releves', offer?.resumable ? offer.remaining : current?.open ? current.done : null, offer?.resumable ? 'warn' : 'info');
    if (!offer?.resumable || offer.offered || demo) { banner.hidden = true; return; }
    banner.hidden = false;
    banner.innerHTML = `${toneMark('warn', 'history')}<div class="op-offer-text"><b>Un relevé interrompu attend sa reprise</b><span>${esc(offer.reason)}</span></div>
      <div class="op-offer-buttons"><button class="btn primary sm" type="button" data-offer="resume">${glyph('play')}Reprendre…</button>
      <button class="btn ghost sm" type="button" data-offer="later">${glyph('clock')}Plus tard</button>
      <button class="btn ghost sm" type="button" data-offer="open">${glyph('wifi')}Voir les relevés</button></div>`;
  }

  function loadOffer() {
    if (demo) return;
    ctx.call('operations.runs').then((view) => { if (alive) paintOffer(view.offer, view.current); }).catch((err) => console.error(err));
  }

  // ---------------------------------------------------------------- events

  page.addEventListener('click', (e) => {
    const b = e.target instanceof Element ? e.target.closest('[data-act],[data-offer],[data-kpi]') : null;
    if (!b) return;
    if (b.dataset.act === 'refresh') refreshAll();
    else if (b.dataset.act === 'why' || b.dataset.act === 'check') {
      tabs.select('diagnostic');
      main.querySelector('.op-workspace')?.scrollIntoView({ behavior: motionReduced() ? 'auto' : 'smooth', block: 'start' });
      if (b.dataset.act === 'check') setTimeout(() => main.querySelector('[data-check="quick"]')?.focus(), 200);
    } else if (b.dataset.act === 'pending' || b.dataset.kpi === 'pending') {
      tabs.select('recus');
      modules.recus?.showPending();
      main.querySelector('.op-workspace')?.scrollIntoView({ behavior: motionReduced() ? 'auto' : 'smooth', block: 'start' });
    } else if (b.dataset.kpi === 'tasks' || b.dataset.kpi === 'session') {
      tabs.select('taches');
    } else if (b.dataset.kpi === 'pulse') {
      tabs.select('sante');
    } else if (b.dataset.offer === 'open') {
      tabs.select('releves');
    } else if (b.dataset.offer === 'later') {
      ctx.call('operations.survey.postpone').then(() => { main.querySelector('[data-slot="offer"]').hidden = true; }).catch((err) => toast(errorText(err), { tone: 'alert' }));
    } else if (b.dataset.offer === 'resume') {
      tabs.select('releves');
      setTimeout(() => modules.releves?.resume(), 350);
    }
  });

  page.addEventListener('keydown', (e) => {
    const kpiTile = e.target instanceof Element ? e.target.closest('[data-kpi]') : null;
    if (kpiTile && e.target === kpiTile && (e.key === 'Enter' || e.key === ' ')) {
      e.preventDefault();
      kpiTile.click();
    }
  });

  function refreshAll() {
    loadOverview(false);
    pollActivity(true);
    const id = tabs.current();
    modules[id]?.refresh?.(false);
    toast('Opérations actualisées.', { tone: 'info', life: 2200 });
  }

  // ---------------------------------------------------------------- start, refreshes, open states

  loadOverview(false);
  pollActivity(true);
  loadOffer();

  timers.push(setInterval(() => { if (alive && !document.hidden && !demo) pollActivity(); }, ACTIVITY_MS));
  timers.push(setInterval(() => { if (alive && !document.hidden) { loadOverview(true); if (tabs.current() === 'recus') modules.recus?.refresh(true); } }, OVERVIEW_MS));
  timers.push(setInterval(() => { if (alive && !document.hidden && tabs.current() === 'sante') modules.sante?.refresh(true); }, HEALTH_MS));
  let runsTick = 0;
  timers.push(setInterval(() => {
    if (!alive || document.hidden || tabs.current() !== 'releves') return;
    runsTick += RUNS_LIVE_MS;
    if (modules.releves?.running() || runsTick >= RUNS_MS) { runsTick = 0; modules.releves?.refresh(true); }
  }, RUNS_LIVE_MS));
  timers.push(setInterval(() => { if (alive) touchDates(main); }, 30_000));

  // Open states asked by the address (captures): the review dialog of a sample receipt, the panel of a task. The marker keeps the
  // readiness signal back until they are open, so the image never shows them half drawn.
  if (['revue', 'tache', 'verification', 'apercu'].includes(params.ouvrir) || params.tache) {
    const marker = main.querySelector('.op-auto');
    marker.setAttribute('aria-busy', 'true');
    const began = performance.now();
    const watch = setInterval(() => {
      if (!alive) { clearInterval(watch); return; }
      let done = false;
      if (params.ouvrir === 'revue' && modules.recus) done = !!modules.recus.openReview();
      else if ((params.ouvrir === 'tache' || params.tache) && modules.taches && activity) done = !!modules.taches.openTrace(params.tache);
      // A check reads the directory: run by the address in simulation only (the fictitious directory), never in directory mode.
      else if (params.ouvrir === 'verification' && modules.diagnostic && overview) { done = true; if (overview.simulation) modules.diagnostic.runQuick(); }
      else if (params.ouvrir === 'apercu' && modules.diagnostic) { done = true; modules.diagnostic.preview(); }
      if (done || performance.now() - began > 8000) {
        clearInterval(watch);
        setTimeout(() => marker.removeAttribute('aria-busy'), 700);
      }
    }, 250);
    timers.push(watch);
  }

  return () => {
    alive = false;
    timers.forEach((t) => clearInterval(t));
    pulse.stop();
    stopReveal();
    tabs.destroy();
  };
}
