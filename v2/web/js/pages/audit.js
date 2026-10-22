// Audit AD: security findings of the domain by severity, controllers, identities of an OU and the detailed reads on one
// object (Domenia 1, Outils > Audit AD and the « Domaine » tab: 23 functions AUD-001 to AUD-023). Read only: no write, no
// password read; every network read leaves on the operator's gesture (a button, or an explicit address such as
// #/audit?lancer=analyse from a link of another screen or the captures) and stays bounded. Data contract: docs/ops/audit.md.
//
// Parameters: tab (synthese, objet, controleurs, identites), dn (object audited), vue (motdepasse, groupes, delegations, gpo,
// poste, relations), lancer (analyse | 1 | diagnostic | liste: runs the read of the tab, as its button would), constat (finding
// explored after the analysis), ou (OU of the identities).
import { icon } from '../icons.js';
import { glyph } from '../kit/glyphs.js';
import { createTabs } from '../kit/tabs.js';
import { createCommandBar } from '../kit/commandbar.js';
import { openDrawer } from '../kit/drawer.js';
import { freshness, startFreshness } from '../kit/freshness.js';
import { esc, reveal, donut, applyVars, announce, copyText, countUp, formatDateTime } from '../ui.js';
import { SEVERITIES, createGuard, ticketText, markdownText, csvText, num, plural, reported } from './audit/shared.js';
import { createOverview } from './audit/overview.js';
import { createObjectTab } from './audit/object.js';
import { createControllersTab } from './audit/controllers.js';
import { createIdentitiesTab } from './audit/identities.js';

/** The screen has its own stylesheet (css/pages/audit.css), loaded by the router. */
export const stylesheet = true;

const TABS = [
  { id: 'synthese', label: 'Synthèse', icon: 'shield' },
  { id: 'objet', label: 'Objet', icon: 'object' },
  { id: 'controleurs', label: 'Contrôleurs', icon: 'server' },
  { id: 'identites', label: 'Identités', icon: 'users' },
];
const RING = '<span class="glow-ring hero-ring" aria-hidden="true"></span>';
const ORBS = '<div class="orbs" aria-hidden="true"><span class="orb a"></span><span class="orb b"></span><span class="orb c"></span></div>';

export function render(main, ctx) {
  let alive = true;
  const stops = [];
  const params = { ...ctx.params };
  const guard = createGuard();
  const modules = {};
  let tabs = null;
  let bar = null;
  let overview = null;
  let session = null;
  const busyKeys = new Set();

  const initialTab = TABS.some((t) => t.id === params.tab) ? params.tab : params.dn ? 'objet' : 'synthese';

  main.innerHTML = `<div class="page aud">
    <section class="hero aud-hero reveal" aria-labelledby="aud-title">${RING}${ORBS}
      <div class="aud-hero-grid">
        <div class="aud-hero-main">
          <div class="eyebrow">${icon('shield')}<span>Sécurité de l’annuaire · lectures à la demande</span></div>
          <h1 id="aud-title" class="gradient-text">Audit AD</h1>
          <p class="lead">Constats par gravité, contrôleurs, identités et lectures détaillées d’un objet. Aucune écriture et aucun mot de passe lu : chaque lecture part sur votre geste et reste bornée.</p>
          <div class="chips aud-chips"></div>
          <div class="aud-bar"></div>
        </div>
        <aside class="aud-score" data-state="idle" aria-live="polite"></aside>
      </div>
    </section>
    <div class="aud-tabs"></div>
  </div>`;
  const chips = main.querySelector('.aud-chips');
  const scoreHost = main.querySelector('.aud-score');

  // ---------- Page context given to the tabs ----------

  const app = {
    ctx,
    params,
    guard,
    alive: () => alive,
    toast: (text, o) => ctx.toast(text, o),
    announce,
    reveal(scope) { stops.push(reveal(scope)); },
    busy(key, on) {
      if (on) busyKeys.add(key); else busyKeys.delete(key);
      bar?.setBusy('analyse', busyKeys.has('analyse'));
    },
    setParams(next) {
      Object.assign(params, next);
      Object.keys(params).forEach((k) => { if (params[k] === null || params[k] === undefined || params[k] === '') delete params[k]; });
      try { history.replaceState(null, '', ctx.link('audit', params)); } catch (err) { console.error(err); }
    },
    /** Audit one object: the « Objet » tab, its target replaced (results of the previous one cleared). */
    target(dn) {
      tabs?.select('objet');
      modules.objet?.setTarget(dn);
    },
    targetChanged(target) {
      modules.controleurs?.refreshTarget();
      renderChips();
      if (target) tabs?.setCount('objet', null);
    },
    currentTarget: () => modules.objet?.target() ?? null,
    routeDn: () => ctx.params.dn ?? null,
    overviewChanged(view) {
      renderScore(view);
      renderChips(view);
      const open = view.counts.critical + view.counts.high + view.counts.medium + view.counts.low;
      tabs?.setCount('synthese', open, view.counts.critical || view.counts.high ? 'alert' : open ? 'warn' : 'ok');
    },
  };

  // ---------- Hero: chips, command bar, score ----------

  function renderChips(view = overview?.state().view) {
    const s = session;
    const items = [
      s?.domain?.dnsName ? `<span class="chip">${glyph('domain')}${esc(s.domain.dnsName)}</span>` : '',
      s?.controller?.dnsName ? `<span class="chip">${icon('server')}${esc(s.controller.dnsName)}</span>` : '',
      `<span class="chip info">${icon('lock')}Lecture seule · aucune écriture</span>`,
      s?.connection?.state === 'simulated' ? `<span class="chip warn">${icon('sparkles')}Annuaire fictif</span>` : '',
      view ? `<span class="chip">${freshness(view.readAt, { label: 'Analysé', staleAfter: 60 * 60_000 })}</span>` : '',
    ].filter(Boolean);
    chips.innerHTML = items.join('');
    chips.querySelectorAll('.chip').forEach((c, n) => c.style.setProperty('--j', String(n)));
    if (view) startFreshness(chips);
  }

  function renderScore(view) {
    if (!view) {
      scoreHost.dataset.state = 'idle';
      scoreHost.innerHTML = `${donut([{ value: 0 }], { total: 100, single: true, size: 'lg', center: '<div class="aud-ring-c"><b>—</b><span>sur 100</span></div>', label: 'Score de santé non calculé' })}
        <div class="aud-score-text"><span class="aud-k">Score de santé</span><b>Non analysé</b>
        <p>Lancez l’analyse du domaine : le score résume les constats lus, du critique au faible.</p></div>
        <ul class="aud-score-legend" role="list">${SEVERITIES.slice(0, 4).map((s) => `<li data-tone="${s.tone}"><span class="dot"></span>${esc(s.plural)}<b>—</b></li>`).join('')}</ul>`;
      applyVars(scoreHost);
      return;
    }
    const sc = view.score;
    scoreHost.dataset.state = 'ready';
    scoreHost.dataset.tone = sc.tone;
    const prev = view.previous;
    scoreHost.innerHTML = `${donut([{ value: sc.value, tone: sc.tone, cls: 'toned' }], { total: 100, single: true, size: 'lg', center: `<div class="aud-ring-c"><b data-count="${sc.value}">${num(sc.value)}</b><span>sur 100</span></div>`, label: `Score de santé : ${sc.value} sur 100, ${sc.label}` })}
      <div class="aud-score-text"><span class="aud-k">Score de santé</span><b class="aud-score-label">${esc(sc.label)}</b>
        <p>${esc(sc.detail)}</p>${prev ? `<p class="aud-score-prev" data-trend="${prev.delta > 0 ? 'up' : prev.delta < 0 ? 'down' : 'flat'}">${icon(prev.delta > 0 ? 'arrowUp' : prev.delta < 0 ? 'arrowDown' : 'check')}${esc(prev.label)}</p>` : ''}</div>
      <ul class="aud-score-legend" role="list">${SEVERITIES.slice(0, 4).map((s) => `<li data-tone="${s.tone}"><span class="dot"></span>${esc(view.counts[s.id] > 1 ? s.plural : s.label)}<b>${num(view.counts[s.id])}</b></li>`).join('')}</ul>`;
    applyVars(scoreHost);
    const b = scoreHost.querySelector('[data-count]');
    if (b) countUp(b, sc.value, { delay: 200 });
    scoreHost.classList.remove('bump');
    void scoreHost.offsetWidth;
    scoreHost.classList.add('bump');
  }

  function currentModule() {
    return modules[tabs?.current() ?? 'synthese'];
  }

  function title() {
    const tab = TABS.find((t) => t.id === (tabs?.current() ?? 'synthese'));
    return `Audit AD · ${tab?.label ?? ''} · ${session?.domain?.dnsName ?? ''} · ${formatDateTime(new Date().toISOString()) ?? ''}`;
  }

  async function copy(kind) {
    const mod = currentModule();
    if (!mod) return;
    let text;
    let what;
    if (kind === 'csv') {
      const view = overview?.state().view;
      if (!view) { ctx.toast('Analysez d’abord le domaine : aucun constat à exporter.', { tone: 'warn' }); return; }
      text = csvText(overview.findingColumns(), view.findings);
      what = `${plural(view.findings.length, 'constat', 'constats')} en CSV`;
    } else {
      const sections = mod.sections();
      text = kind === 'markdown' ? markdownText(title(), sections) : ticketText(title(), sections);
      what = kind === 'markdown' ? 'Vue copiée en Markdown' : 'Vue copiée';
    }
    const ok = await copyText(text);
    ctx.toast(ok ? `${what} dans le presse-papiers (données déjà affichées, aucune relecture).` : 'Copie impossible : le presse-papiers est indisponible.', { tone: ok ? 'ok' : 'warn' });
  }

  function help() {
    const node = document.createElement('div');
    node.className = 'aud-help';
    node.dataset.page = 'audit';
    node.innerHTML = `<p>L’audit lit l’annuaire pour vous montrer ce qui mérite votre attention. Il ne modifie jamais rien.</p>
      <ul role="list">
        <li>${glyph('lock')}<div><b>Lecture seule</b><span>Aucune écriture, aucun service démarré ni arrêté, aucun mot de passe ni secret lu : seules des dates circulent.</span></div></li>
        <li>${glyph('wifi')}<div><b>Sur votre geste</b><span>Chaque lecture réseau part sur un clic (ou une adresse explicite) et porte sur le domaine, l’objet, l’OU ou les contrôleurs choisis.</span></div></li>
        <li>${glyph('gauge')}<div><b>Toujours bornée</b><span>Recherches limitées (60 à 500 objets par contrôle, 2 000 groupes, 1 000 entrées, 10 contrôleurs, 5 000 objets par OU) : une lecture bornée ne prouve jamais une absence.</span></div></li>
        <li>${glyph('eye')}<div><b>Des faits, pas des verdicts</b><span>Chaque constat dit sa source et sa limite. Un contrôleur injoignable est « Non lu », jamais « en panne » ; une entrée d’accès n’est pas un droit effectif.</span></div></li>
        <li>${glyph('copy')}<div><b>Pour un ticket</b><span>« Copier la vue » reprend ce qui est affiché, sans relecture, en texte ou en Markdown.</span></div></li>
      </ul>`;
    openDrawer({ title: 'Ce que lit l’audit', subtitle: 'Garanties de Domenia 1, reprises telles quelles', icon: 'shield', width: 520, body: node, actions: [{ id: 'close', label: 'Fermer', primary: true, run: (p) => p.close() }] });
  }

  bar = createCommandBar(main.querySelector('.aud-bar'), {
    label: 'Actions de l’audit',
    items: [
      { id: 'analyse', label: 'Analyser le domaine', icon: 'shield', primary: true, kind: 'network', run: () => { tabs?.select('synthese'); overview?.run(); } },
      { id: 'copy', label: 'Copier la vue', icon: 'copy', run: () => copy('text') },
      { id: 'export', label: 'Exporter', icon: 'download', items: [
        { label: 'Texte pour un ticket', icon: 'file', run: () => copy('text') },
        { label: 'Markdown (ticket, wiki)', icon: 'file', run: () => copy('markdown') },
        { label: 'Constats en CSV', icon: 'csv', run: () => copy('csv') },
      ] },
      { id: 'help', label: 'Ce que lit l’audit', icon: 'info', iconOnly: true, pinned: true, run: help },
    ],
  });

  // ---------- Tabs ----------

  tabs = createTabs(main.querySelector('.aud-tabs'), {
    label: 'Vues de l’audit AD',
    selected: initialTab,
    tabs: TABS.map((t) => ({
      id: t.id,
      label: t.label,
      icon: t.icon,
      render: (panel) => {
        panel.classList.add('aud-panel');
        if (t.id === 'synthese') overview = modules.synthese = createOverview(panel, app);
        if (t.id === 'objet') modules.objet = createObjectTab(panel, app);
        if (t.id === 'controleurs') modules.controleurs = createControllersTab(panel, app);
        if (t.id === 'identites') modules.identites = createIdentitiesTab(panel, app);
        stops.push(() => modules[t.id]?.destroy());
        app.reveal(panel);
      },
    })),
    onChange: (id) => { app.setParams({ tab: id }); compact(id); },
  });

  // Outside the synthesis, the hero folds into a slim band: the tab content comes up, the score stays in sight.
  function compact(id) {
    main.querySelector('.aud-hero')?.classList.toggle('compact', id !== 'synthese');
  }
  compact(tabs.current());

  renderScore(null);
  stops.push(reveal(main));

  // ---------- Session, then the gesture carried by the address ----------

  (async () => {
    try {
      session = await ctx.call('session.info');
    } catch (err) {
      reported(err);
    }
    if (!alive) return;
    renderChips();
    const launch = params.lancer;
    if (tabs.current() === 'objet' && params.dn) {
      await modules.objet?.setTarget(params.dn, { keepView: true, launch: launch === '1' });
    } else if (tabs.current() === 'synthese' && launch === 'analyse') {
      await overview?.run();
      if (alive && params.constat) overview?.explore(params.constat);
    } else if (tabs.current() === 'controleurs' && (launch === 'diagnostic' || launch === 'liste')) {
      await modules.controleurs?.launch(launch);
    } else if (tabs.current() === 'identites' && launch === '1') {
      await modules.identites?.launch(params.ou ?? null);
    }
    if (alive && launch) app.setParams({ lancer: null });
  })();

  return () => {
    alive = false;
    guard.reset();
    stops.forEach((fn) => { try { fn(); } catch (err) { console.error(err); } });
    bar?.destroy();
    tabs?.destroy();
  };
}

