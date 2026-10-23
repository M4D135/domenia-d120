// « Diagnostic » of the workstation console: network diagnosis (verdict first, the four layers with the blocking one, rows
// with their raw code and a remedy, report to copy for a colleague), the bounded quick diagnosis, the triage of a slow
// workstation, event presets, the read-only WMI explorer and the analysis of a pasted dsregcmd /status. Each read on its button.
import { createTabs, createGrid, writeClipboard, field } from '../../kit/index.js';
import {
  esc, ico, rel, facts, cardHead, empty, failure, chip, progressMarkup, setProgress, NBSP, int, count, errorText, formatDateTime,
  fitGrid, saveExport, cimDate,
} from './common.js';
import { reveal as revealCards, toast, announce } from '../../ui.js';

const TABS = [
  { id: 'reseau', label: 'Diagnostic réseau', icon: 'wifi' },
  { id: 'rapide', label: 'Diagnostic rapide', icon: 'zap' },
  { id: 'lent', label: 'Poste lent', icon: 'gauge' },
  { id: 'evenements', label: 'Événements', icon: 'clock' },
  { id: 'wmi', label: 'Explorateur WMI', icon: 'database' },
  { id: 'jonction', label: 'Jonction et SSO', icon: 'link' },
];

export function renderDiagnostic(panel, state) {
  panel.classList.add('ps-diagnostic');
  panel.innerHTML = '<div class="ps-subtabs" data-slot="tabs"></div>';
  const renderers = { reseau: network, rapide: quick, lent: slow, evenements: events, wmi, jonction: join };
  const tabs = createTabs(panel.querySelector('[data-slot="tabs"]'), {
    label: 'Outils de diagnostic',
    selected: state.initialTab && renderers[state.initialTab] ? state.initialTab : 'reseau',
    tabs: TABS.map((t) => ({ ...t, render: (host) => renderers[t.id](host, state) })),
  });
  const off = state.on('tab', ({ view, tab }) => { if (view === 'diagnostic' && renderers[tab]) tabs.select(tab); });
  const offRun = state.on('run', (r) => { if (r.what === 'diagnostic') tabs.select('reseau'); else if (r.what === 'slow') tabs.select('lent'); });
  return () => { off(); offRun(); tabs.destroy(); };
}

const SEVERITY = { passed: { tone: 'ok', icon: 'check', label: 'Réussi' }, failed: { tone: 'alert', icon: 'x', label: 'Échec' }, information: { tone: 'info', icon: 'info', label: 'Information' }, notTried: { tone: 'off', icon: 'minus', label: 'Non tenté' } };
const LAYER = { passed: { tone: 'ok', label: 'Réussi' }, failed: { tone: 'alert', label: 'Échec' }, partial: { tone: 'warn', label: 'Partiel' }, notTried: { tone: 'off', label: 'Non tenté' } };

// ---------- Network diagnosis ----------

function network(host, state) {
  let alive = true;
  let report = '';
  host.innerHTML = `<div class="grid ps-grid">
    <section class="card ps-card span-12 reveal">${cardHead('wifi', 'Diagnostic du poste', 'Résolution DNS, ping, ports 135, 445, 3389, 5985, 5986, session CIM, partage C$, WinRM, transports de repli, système et disque', `<button class="btn primary" type="button" data-act="run">${ico('activity')}Lancer le diagnostic</button><button class="btn ghost" type="button" data-act="stop" hidden>${ico('pause')}Arrêter</button><button class="btn ghost" type="button" data-act="copy" disabled data-tip="Copier le rapport avec les codes bruts, pour un collègue">${ico('copy')}Copier pour un collègue</button>`)}
      <div data-slot="body">${empty({ icon: 'activity', title: 'Aucun contrôle exécuté', text: 'Contrôles non modifiants, budget de 45 s ; les tests lents sont ignorés si les ports ne répondent pas.', action: { id: 'run', label: 'Lancer le diagnostic', icon: 'activity' } })}</div></section></div>`;
  const body = host.querySelector('[data-slot="body"]');
  async function run() {
    body.setAttribute('aria-busy', 'true');
    body.innerHTML = progressMarkup();
    host.querySelector('[data-act="stop"]').hidden = false;
    host.querySelector('[data-act="run"]').disabled = true;
    const stop = state.progress('poste.diagnostic', (p) => setProgress(body, p));
    setTimeout(() => state.refreshRunning(), 120);
    try {
      const r = await state.call('poste.diagnostic', { dn: state.dn });
      if (!alive) return;
      report = r.report;
      host.querySelector('[data-act="copy"]').disabled = false;
      body.removeAttribute('aria-busy');
      body.innerHTML = `<div class="ps-verdict-hero" data-tone="${r.failed ? (r.reachable ? 'warn' : 'alert') : 'ok'}">${ico(r.failed ? (r.reachable ? 'eye' : 'wifiOff') : 'check')}<p>${esc(r.verdict)}</p></div>
        <div class="ps-counters">${[['passed', r.passed], ['failed', r.failed], ['information', r.information], ['notTried', r.notTried]].map(([k, v]) => `<span class="ps-counter" data-tone="${v === 0 && k !== 'passed' ? 'off' : SEVERITY[k].tone}"><b>${int(v)}</b>${esc(SEVERITY[k].label)}</span>`).join('')}
          <span class="ps-counter" data-tone="info"><b>${esc((r.durationMs / 1000).toFixed(1).replace('.', ','))}${NBSP}s</b>sur ${int(r.budgetSeconds)}${NBSP}s</span></div>
        <ol class="ps-layers" aria-label="Couches réseau">${r.layers.map((l) => `<li data-tone="${LAYER[l.state].tone}"${r.blockingStep === l.step ? ' data-blocking="1"' : ''}><span class="ps-layer-n">${int(l.step)}</span><div><b>${esc(l.label)}</b><span>${esc(LAYER[l.state].label)}${l.detail ? ` · ${esc(l.detail)}` : ''}</span></div>${r.blockingStep === l.step ? `<span class="chip alert">Étape bloquante</span>` : ''}</li>`).join('')}</ol>
        <ul class="ps-diag-rows">${r.rows.map((x) => `<li data-tone="${SEVERITY[x.severity].tone}"><span class="ps-diag-mark" aria-hidden="true">${ico(SEVERITY[x.severity].icon)}</span><div class="ps-diag-main"><b>${esc(x.label ?? x.check)}</b><span>${esc(x.detail)}</span>${x.remedy ? `<em>${ico('zap')}${esc(x.remedy)}</em>` : ''}</div>
          <span class="ps-diag-meta"><span class="chip ${SEVERITY[x.severity].tone}">${esc(x.statusLabel)}</span><code>${esc(x.status)}</code><small>${esc(x.method)} · ${int(x.durationMs)}${NBSP}ms</small></span></li>`).join('')}</ul>`;
      revealCards(host);
      announce(`Diagnostic terminé : ${r.verdict}`);
    } catch (err) {
      if (alive) { body.removeAttribute('aria-busy'); body.innerHTML = failure(err, { retry: 'run' }); }
    } finally {
      stop();
      state.refreshRunning();
      if (alive) { host.querySelector('[data-act="stop"]').hidden = true; host.querySelector('[data-act="run"]').disabled = false; }
    }
  }
  host.addEventListener('click', (e) => {
    const t = e.target instanceof Element ? e.target.closest('[data-act]') : null;
    if (!t) return;
    if (t.dataset.act === 'run' || t.dataset.act === 'retry') run();
    else if (t.dataset.act === 'copy') writeClipboard(report).then(() => toast('Rapport copié avec les codes bruts.', { tone: 'ok' }));
    else if (t.dataset.act === 'stop') state.stop('diagnostic');
  });
  const off = state.on('run', (r) => { if (r.what === 'diagnostic') run(); });
  if (state.essai === 'diagnostic') run();
  return () => { alive = false; off(); };
}

// ---------- Quick diagnosis ----------

function quick(host, state) {
  let alive = true;
  host.innerHTML = `<div class="grid ps-grid"><section class="card ps-card span-12 reveal">${cardHead('zap', 'Diagnostic rapide borné', 'Système, dernier démarrage, disque C:, ports 135/445/5985, services de gestion : cinq lectures seules, 20 s annoncées, aucun repli', `<button class="btn primary" type="button" data-act="run">${ico('zap')}Lire</button>`)}
    <div data-slot="body">${empty({ icon: 'zap', title: 'Un seul poste, sur votre geste', text: 'Ni PsExec, ni tâche planifiée, ni modification du poste ; un refus ou une indisponibilité ne concluent rien.' })}</div></section></div>`;
  const body = host.querySelector('[data-slot="body"]');
  async function run() {
    body.setAttribute('aria-busy', 'true');
    body.innerHTML = progressMarkup();
    try {
      const r = await state.call('poste.quickDiag', { dn: state.dn });
      if (!alive) return;
      body.removeAttribute('aria-busy');
      body.innerHTML = `<p class="ps-verdict-line" data-tone="${r.complete ? 'ok' : 'warn'}">${ico(r.complete ? 'check' : 'info')}<span>${esc(r.summary)} ${esc(r.durationText)}</span></p>${facts(r.facts)}<p class="ps-faint">${esc(r.costText)} · ${esc(r.fallback)}</p>`;
    } catch (err) {
      if (alive) { body.removeAttribute('aria-busy'); body.innerHTML = failure(err, { retry: 'run' }); }
    }
  }
  host.addEventListener('click', (e) => { const t = e.target instanceof Element ? e.target.closest('[data-act]') : null; if (t && (t.dataset.act === 'run' || t.dataset.act === 'retry')) run(); });
  if (state.essai === 'rapide') run();
  return () => { alive = false; };
}

// ---------- Slow workstation ----------

const LEVEL = { alert: { tone: 'alert', label: 'Critique' }, warn: { tone: 'warn', label: 'À vérifier' }, info: { tone: 'info', label: 'Piste' } };

function slow(host, state) {
  let alive = true;
  host.innerHTML = `<div class="grid ps-grid"><section class="card ps-card span-12 ps-slow reveal">${cardHead('slow', 'Tri d’un poste lent', 'Mémoire, processeur mesuré, disques, redémarrage, démarrage automatique, journaux de 72 h et lien réseau ; seuils des règles de santé', `<button class="btn primary" type="button" data-act="run">${ico('slow')}Analyser la lenteur</button>`)}
    <div data-slot="body">${empty({ icon: 'slow', title: 'L’utilisateur trouve son poste lent ?', text: 'Une lecture rapide du poste désigne la cause la plus probable et l’action utile ; rien n’est lancé sans votre confirmation.', action: { id: 'run', label: 'Analyser la lenteur', icon: 'slow' } })}</div></section></div>`;
  const body = host.querySelector('[data-slot="body"]');
  async function run() {
    body.setAttribute('aria-busy', 'true');
    body.innerHTML = progressMarkup();
    try {
      const r = await state.call('poste.slow', { dn: state.dn });
      if (!alive) return;
      body.removeAttribute('aria-busy');
      const finding = (f, n) => `<li class="ps-finding reveal" data-tone="${esc(f.level ? LEVEL[f.level].tone : 'ok')}" data-i="${n}"><span class="ps-finding-mark" aria-hidden="true">${ico(f.level ? (f.level === 'info' ? 'info' : 'alert') : 'check')}</span>
        <div class="ps-finding-body"><div class="ps-finding-top"><b>${esc(f.title)}</b>${f.level ? `<span class="chip ${LEVEL[f.level].tone}">${esc(LEVEL[f.level].label)}</span>` : ''}</div><span class="ps-finding-ev">${esc(f.evidence)}</span><span class="ps-finding-adv">${esc(f.advice)}</span></div>
        ${f.action ? `<button class="btn sm" type="button" data-slow="${esc(f.action.kind)}|${esc(f.action.view ?? '')}|${esc(f.action.tab ?? '')}">${esc(f.action.label)}${ico('chevronRight')}</button>` : ''}</li>`;
      body.innerHTML = `<div class="ps-verdict-hero" data-tone="${esc(r.tone)}">${ico(r.tone === 'ok' ? 'check' : r.tone === 'off' ? 'info' : 'slow')}<p>${esc(r.verdict)}</p></div>
        ${r.findings.length ? `<h4 class="ps-mini-title">Pistes, de la plus probable à la moins probable</h4><ol class="ps-findings">${r.findings.map(finding).join('')}</ol>` : ''}
        ${r.passed.length ? `<details class="ps-more" open><summary>${esc(count(r.passed.length, 'contrôle sans anomalie', 'contrôles sans anomalie'))}</summary><ul class="ps-findings ok">${r.passed.map(finding).join('')}</ul></details>` : ''}
        ${r.unread.length ? `<details class="ps-more"><summary>${esc(count(r.unread.length, 'contrôle non lu', 'contrôles non lus'))}</summary><ul class="ps-findings">${r.unread.map(finding).join('')}</ul></details>` : ''}
        <p class="ps-faint">${esc(r.method)}</p>`;
      revealCards(host);
    } catch (err) {
      if (alive) { body.removeAttribute('aria-busy'); body.innerHTML = failure(err, { retry: 'run' }); }
    }
  }
  host.addEventListener('click', (e) => {
    const t = e.target instanceof Element ? e.target.closest('[data-act],[data-slow]') : null;
    if (!t) return;
    if (t.dataset.slow) {
      const [kind, view, tab] = t.dataset.slow.split('|');
      if (kind === 'restart') { state.go('intervenir'); state.emit('run', { what: 'restart' }); } else if (view) state.go(view, tab || undefined);
      return;
    }
    if (t.dataset.act === 'run' || t.dataset.act === 'retry') run();
  });
  const off = state.on('run', (r) => { if (r.what === 'slow') run(); });
  if (state.essai === 'lent') run();
  return () => { alive = false; off(); };
}

// ---------- Events ----------

const PRESETS = [
  { id: 'Startup', label: 'Démarrage et arrêt' }, { id: 'Crash', label: 'Plantages' }, { id: 'Disk', label: 'Disque' },
  { id: 'Policy', label: 'Stratégie de groupe' }, { id: 'Updates', label: 'Mises à jour' },
];

function events(host, state) {
  let alive = true;
  let preset = 'Startup';
  host.innerHTML = `<div class="grid ps-grid"><section class="card ps-card span-12 reveal">${cardHead('clock', 'Événements du poste', 'Préréglages bornés : 1 à 720 h, 1 à 200 événements ; un refus ou une lecture partielle ne deviennent jamais « aucun événement »')}
    <div class="ps-ev-bar"><div class="segmented ps-seg" role="group" aria-label="Préréglage">${PRESETS.map((p) => `<button type="button" data-preset="${p.id}" aria-pressed="${p.id === preset}">${esc(p.label)}</button>`).join('')}</div>
      <label class="ps-inline">Fenêtre <input class="input sm" type="number" min="1" max="720" value="72" data-hours> h</label>
      <label class="ps-inline">Au plus <input class="input sm" type="number" min="1" max="200" value="50" data-max> événements</label>
      <button class="btn primary" type="button" data-act="read">${ico('refresh')}Lire les événements</button></div>
    <div data-slot="facts"></div><div data-slot="grid"></div></section></div>`;
  const grid = createGrid(host.querySelector('[data-slot="grid"]'), {
    key: 'poste.evenements',
    label: 'Événements',
    rowId: (r) => `${r.at}|${r.id}|${r.provider}|${r.message.slice(0, 30)}`,
    columns: [
      { id: 'at', label: 'Date', type: 'date', dateStyle: 'datetime', width: 170 },
      { id: 'id', label: 'ID', type: 'number', width: 80 },
      { id: 'provider', label: 'Source', width: 200 },
      { id: 'level', label: 'Niveau', width: 120 },
      { id: 'noise', label: 'Tableau', type: 'enum', width: 140, options: [{ value: 'warn', label: 'À surveiller', tone: 'warn' }, { value: 'info', label: 'Information', tone: 'info' }] },
      { id: 'attribution', label: 'Attribution', width: 130 },
      { id: 'message', label: 'Message', width: 360 },
    ],
    empty: { icon: 'clock', title: 'Événements non lus', text: 'Choisissez un préréglage et une fenêtre, puis « Lire les événements ».' },
  });
  async function read() {
    grid.setLoading(true);
    const hours = Number(host.querySelector('[data-hours]').value) || 72;
    const max = Number(host.querySelector('[data-max]').value) || 50;
    try {
      const r = await state.call('poste.events', { dn: state.dn, preset, hours, max });
      if (!alive) return;
      host.querySelector('[data-slot="facts"]').innerHTML = facts(r.facts, { compact: true });
      // An empty result says what it proves: confirmed absence, or a refused or partial read that concludes nothing.
      grid.setEmpty(r.noEventsConfirmed
        ? { icon: 'check', title: 'Aucun événement', text: `Aucun événement de ce préréglage dans les ${r.query.windowHours} dernières heures.` }
        : { icon: 'alert', title: 'Aucune conclusion', text: 'Lecture refusée ou partielle : l’absence de ligne ne prouve pas l’absence d’événement.' });
      grid.setRows(r.rows);
      fitGrid(grid, r.rows.length, { max: 480 });
    } catch (err) {
      if (alive) grid.setError(errorText(err), { retry: read });
    }
  }
  fitGrid(grid, 0);
  host.addEventListener('click', (e) => {
    const t = e.target instanceof Element ? e.target.closest('[data-act],[data-preset]') : null;
    if (!t) return;
    if (t.dataset.preset) {
      preset = t.dataset.preset;
      t.parentElement.querySelectorAll('button').forEach((b) => b.setAttribute('aria-pressed', String(b === t)));
      return;
    }
    if (t.dataset.act === 'read') read();
  });
  if (state.essai === 'evenements') read();
  return () => { alive = false; grid.destroy(); };
}

// ---------- WMI explorer ----------

function wmi(host, state) {
  let alive = true;
  let ns = 'root\\cimv2';
  let classes = [];
  let last = null;
  host.innerHTML = `<div class="grid ps-grid ps-wmi">
    <section class="card ps-card span-4 reveal">${cardHead('database', 'Espaces et classes', 'Aucune méthode invoquée ; classes du fournisseur MSI bloquées', `<button class="btn sm" type="button" data-act="ns">${ico('refresh')}Charger</button>`)}
      <div class="ps-wmi-ns" data-slot="ns">${empty({ icon: 'database', title: 'Espaces de noms non lus', text: 'Le chargement interroge le poste à votre demande, pendant 30 s au plus.' })}</div>
      <label class="ps-search sm"><span class="visually-hidden">Filtrer les classes</span>${ico('filter')}<input class="input" type="search" data-filter placeholder="Filtrer les classes…" autocomplete="off"></label>
      <p class="ps-faint" data-slot="classes-status" role="status"></p>
      <ul class="ps-wmi-classes" data-slot="classes"></ul></section>
    <section class="card ps-card span-8 reveal">${cardHead('terminal', 'Requête', '<span data-slot="query">Propriétés du schéma · WHERE facultatif · 1 à 500 instances, 25 par défaut · 45 s au plus</span>', `<button class="btn ghost sm" type="button" data-act="copy" disabled>${ico('copy')}Copier</button><button class="btn ghost sm" type="button" data-act="export" disabled>${ico('csv')}Exporter</button>`)}
      <form class="ps-wmi-form" data-form><input class="input mono" data-cls placeholder="Classe (ex. Win32_OperatingSystem)" aria-label="Classe" value="Win32_OperatingSystem">
        <input class="input mono" data-where placeholder="WHERE facultatif (ex. State='Running')" aria-label="Filtre WHERE" maxlength="2048">
        <input class="input" type="number" min="1" max="500" value="25" data-limit aria-label="Limite">
        <button class="btn primary" type="submit">${ico('play')}Interroger</button></form>
      <div data-slot="schema"></div><div data-slot="grid"></div></section></div>`;
  let grid = null;
  const paintClasses = () => {
    const text = host.querySelector('[data-filter]').value.trim().toLowerCase();
    host.querySelector('[data-slot="classes"]').innerHTML = classes.filter((c) => !text || c.name.toLowerCase().includes(text))
      .map((c) => `<li><button type="button" class="ps-wmi-class${c.blocked ? ' blocked' : ''}" data-class="${esc(c.name)}"${c.blocked ? ` disabled data-tip="${esc(c.reason ?? '')}"` : ''}>${ico(c.blocked ? 'lock' : 'database')}<span class="mono">${esc(c.name)}</span></button></li>`).join('');
  };
  async function loadNs(parent = null) {
    const slot = host.querySelector('[data-slot="ns"]');
    slot.setAttribute('aria-busy', 'true');
    try {
      const r = await state.call('poste.wmi.namespaces', { dn: state.dn, parent });
      if (!alive) return;
      slot.removeAttribute('aria-busy');
      slot.innerHTML = `<p class="ps-faint">${esc(r.status)}</p><div class="ps-wmi-nslist">${r.namespaces.map((n) => `<button class="chip${n.path.toLowerCase() === ns.toLowerCase() ? ' info' : ''}" type="button" data-ns="${esc(n.path)}" data-has="${n.hasChildren !== false ? 1 : 0}">${esc(n.path)}</button>`).join('')}</div>`;
      await loadClasses(ns);
    } catch (err) {
      if (alive) { slot.removeAttribute('aria-busy'); slot.innerHTML = failure(err, { retry: 'ns' }); }
    }
  }
  async function loadClasses(path) {
    ns = path;
    try {
      const r = await state.call('poste.wmi.classes', { dn: state.dn, ns: path });
      if (!alive) return;
      classes = r.classes;
      host.querySelector('[data-slot="classes-status"]').textContent = r.status;
      paintClasses();
    } catch (err) {
      if (alive) host.querySelector('[data-slot="classes"]').innerHTML = `<li>${failure(err, { retry: null })}</li>`;
    }
  }
  async function query() {
    const cls = host.querySelector('[data-cls]').value.trim();
    const where = host.querySelector('[data-where]').value.trim();
    const limit = Number(host.querySelector('[data-limit]').value) || 25;
    const gridHost = host.querySelector('[data-slot="grid"]');
    gridHost.innerHTML = progressMarkup();
    gridHost.setAttribute('aria-busy', 'true');
    try {
      const r = await state.call('poste.wmi.query', { dn: state.dn, ns, cls, where: where || null, limit });
      if (!alive) return;
      last = r;
      gridHost.removeAttribute('aria-busy');
      host.querySelector('[data-slot="query"]').textContent = `${r.query} · ${r.status}`;
      host.querySelector('[data-slot="schema"]').innerHTML = r.schema.length
        ? `<details class="ps-more"><summary>Schéma (${int(r.schema.length)} propriétés)</summary><ul class="ps-schema">${r.schema.map((p) => `<li><span class="mono">${esc(p.name)}</span><span${p.qualifiers ? ` data-tip="${esc(`Qualificatifs : ${p.qualifiers}`)}"` : ''}>${esc(p.type)}</span>${p.key ? chip('info', 'clé') : ''}</li>`).join('')}</ul></details>` : '';
      grid?.destroy();
      gridHost.innerHTML = '';
      grid = createGrid(gridHost, {
        key: `poste.wmi.${r.class}`,
        label: `Instances de ${r.class}`,
        rowId: (row) => row.__i,
        // CIM dates (LastBootUpTime, InstallDate…) are shown in local time, the raw value in the tip, the copy and the export.
        columns: r.schema.map((p, n) => ({
          id: `c${n}`, label: p.name, width: p.type.toLowerCase() === 'datetime' ? 190 : 170, mono: p.type.toLowerCase() !== 'string' && p.type.toLowerCase() !== 'datetime', get: (row) => row[`c${n}`],
          html: (v) => { const at = cimDate(v); return at ? `<span data-tip="${esc(`Valeur brute : ${v}`)}">${esc(formatDateTime(at) ?? v)}</span>` : esc(v); },
          csv: (v) => String(v ?? ''),
        })),
        empty: { icon: 'database', title: r.noInstancesConfirmed === false ? 'Lecture non concluante' : 'Aucune instance', text: r.status },
      });
      grid.setRows(r.instances.map((inst, i) => Object.fromEntries([['__i', String(i)], ...inst.map((v, n) => [`c${n}`, v ?? ''])])));
      fitGrid(grid, r.instances.length, { max: 420 });
      host.querySelector('[data-act="copy"]').disabled = false;
      host.querySelector('[data-act="export"]').disabled = false;
    } catch (err) {
      if (alive) { gridHost.removeAttribute('aria-busy'); gridHost.innerHTML = failure(err, { retry: null }); }
    }
  }
  host.addEventListener('click', (e) => {
    const t = e.target instanceof Element ? e.target.closest('[data-act],[data-ns],[data-class]') : null;
    if (!t) return;
    if (t.dataset.ns) { ns = t.dataset.ns; t.parentElement.querySelectorAll('.chip').forEach((c) => c.classList.toggle('info', c === t)); if (t.dataset.has === '1') loadNs(ns); else loadClasses(ns); return; }
    if (t.dataset.class) { host.querySelector('[data-cls]').value = t.dataset.class; query(); return; }
    if (t.dataset.act === 'ns' || t.dataset.act === 'retry') loadNs();
    else if (t.dataset.act === 'copy' && grid) writeClipboard(grid.toCsv({ scope: 'visible' })).then(() => toast(`Instances copiées (réponse de ${last?.computer}).`, { tone: 'ok' }));
    // The file is named after the workstation that answered (Domenia 1 Export-DomeniaWmi).
    else if (t.dataset.act === 'export' && grid) saveExport(state, 'wmi', [{ part: 'liste', csv: grid.toCsv({ scope: 'visible' }) }]);
  });
  host.querySelector('[data-filter]').addEventListener('input', paintClasses);
  host.querySelector('[data-form]').addEventListener('submit', (e) => { e.preventDefault(); query(); });
  if (state.essai === 'wmi') loadNs().then(query);
  return () => { alive = false; grid?.destroy(); };
}

// ---------- dsregcmd ----------

function join(host, state) {
  let alive = true;
  host.innerHTML = `<div class="grid ps-grid"><section class="card ps-card span-6 reveal">${cardHead('link', 'Analyse de dsregcmd /status', 'Collez la sortie complète (128 Kio au plus) : rien n’est exécuté ni réparé')}
      <form class="ps-dsreg" data-form>
        <textarea class="input mono" rows="12" data-text placeholder="+----------------------------------------------------------------------+&#10;| Device State                                                         |&#10;+----------------------------------------------------------------------+&#10;             AzureAdJoined : YES&#10;              DomainJoined : YES" aria-label="Texte de dsregcmd /status"></textarea>
        <fieldset class="ps-radio"><legend>Collecté</legend>
          <label><input type="radio" name="collected" value="endUser"> dans la session de l’utilisateur final, sous son compte</label>
          <label><input type="radio" name="collected" value="admin"> sous un compte d’administration</label>
          <label><input type="radio" name="collected" value="unknown" checked> session non déclarée</label></fieldset>
        <input class="input" data-user placeholder="Utilisateur final (DOMAINE\\identifiant ou UPN)" aria-label="Utilisateur final" value="${esc(state.data.association.user?.login ?? '')}">
        <button class="btn primary" type="submit">${ico('search')}Analyser</button></form></section>
    <section class="card ps-card span-6 reveal">${cardHead('shield', 'Jonction et SSO', 'L’état SSO n’est évaluable que pour un texte collecté dans la session de l’utilisateur final')}<div data-slot="body">${empty({ icon: 'link', title: 'Aucun texte analysé', text: 'Jonction AD, Entra ID, mode hybride, authentification de l’appareil, nom du poste, puis PRT, Windows Hello et Workplace si la session le permet.' })}</div></section></div>`;
  host.querySelector('[data-form]').addEventListener('submit', async (e) => {
    e.preventDefault();
    const body = host.querySelector('[data-slot="body"]');
    const text = host.querySelector('[data-text]').value;
    const collectedAs = host.querySelector('input[name="collected"]:checked')?.value ?? 'unknown';
    const endUser = host.querySelector('[data-user]').value.trim() || null;
    body.setAttribute('aria-busy', 'true');
    try {
      const r = await state.call('poste.dsreg.analyze', { dn: state.dn, text, collectedAs, endUser });
      if (!alive) return;
      body.removeAttribute('aria-busy');
      body.innerHTML = `<p class="ps-verdict-line" data-tone="${r.recognized ? 'info' : 'warn'}">${ico(r.recognized ? 'link' : 'alert')}<span>Mode${NBSP}: ${esc(r.mode)} · SSO${NBSP}: ${esc(r.ssoVerdict === 'NonEvaluable' ? 'non évaluable' : r.ssoVerdict === 'PrtPresent' ? 'jeton présent' : r.ssoVerdict === 'PrtAbsent' ? 'jeton absent' : 'inconnu')}${r.computerMatches === false ? ' · texte d’un autre poste' : ''}</span></p>${facts(r.facts)}`;
    } catch (err) {
      if (alive) { body.removeAttribute('aria-busy'); body.innerHTML = failure(err, { retry: null }); }
    }
  });
  return () => { alive = false; };
}

export { rel, formatDateTime, field };
