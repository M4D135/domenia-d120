// Read of the directory for the base (Domenia 1 « Mettre à jour l’OU choisie », « Mettre à jour les changements »): estimate
// confirmed in a panel (nothing is read before), live progress of the read (phases, counters, stop), then the exact preview of
// what storing it changes, and the storage through the write circuit (plan, confirmation, receipt, re-read). The read itself
// never writes anything; a result not stored expires after 15 minutes and is replaced by the next read.
import { onEvent } from '../../bridge.js';
import { openDrawer, statePill } from '../../kit/index.js';
import { runWrite } from '../../write-flow.js';
import { announce, motionReduced } from '../../ui.js';
import {
  esc, icon, glyph, pill, int, count, NBSP, toneOf, button, paint, PHASES, shortHash, ago, errorText, typeGlyph,
} from './common.js';

const CATEGORY = {
  added: { label: 'Ajoutés', tone: 'ok', icon: 'plus' },
  moved: { label: 'Déplacés', tone: 'info', icon: 'split' },
  renamed: { label: 'Renommés', tone: 'info', icon: 'edit' },
  changed: { label: 'Valeurs modifiées', tone: 'accent', icon: 'sliders' },
  refreshed: { label: 'Dates actualisées', tone: 'off', icon: 'clock' },
  conflict: { label: 'Conservés', tone: 'off', icon: 'lock' },
  unseen: { label: 'Non revus', tone: 'warn', icon: 'eyeOff' },
};

function stepsMarkup(phase, done = false, mode = 'ou') {
  const phases = mode === 'ou' ? PHASES.filter((p) => p.id !== 'census') : PHASES;
  const index = phases.findIndex((p) => p.id === phase);
  return `<ol class="sy-steps" data-n="${phases.length}" aria-label="Étapes de la lecture">${phases.map((p, n) => {
    const state = done || n < index ? 'done' : n === index ? 'active' : 'todo';
    return `<li class="sy-step" data-state="${state}" data-i="${n}"><span class="sy-step-dot">${state === 'done' ? glyph('check') : glyph(p.icon)}</span><span class="sy-step-label">${esc(p.label)}</span></li>`;
  }).join('')}</ol>`;
}

function factsMarkup(rows) {
  return `<dl class="sy-facts">${rows.filter(Boolean).map(([k, v, cls]) => `<div${cls ? ` class="${cls}"` : ''}><dt>${esc(k)}</dt><dd>${v}</dd></div>`).join('')}</dl>`;
}

function reconcileMarkup(r) {
  const c = r.reconcile;
  const refreshed = Math.max(0, c.updated - c.moved - c.renamed - c.changed);
  const parts = [
    ['added', c.added], ['moved', c.moved], ['renamed', c.renamed], ['changed', c.changed], ['refreshed', refreshed], ['unseen', c.unseen], ['conflict', c.conflicts],
  ];
  const unchanged = c.unchanged;
  const changes = parts.reduce((s, [, n]) => s + n, 0);
  const total = Math.max(1, changes + unchanged);
  // The bar shows the changes among themselves (the unchanged objects would crush them); without change it stays calm.
  const bar = changes > 0
    ? parts.filter(([, n]) => n > 0).map(([k, n]) => `<span class="sy-bar-seg" data-tone="${CATEGORY[k].tone}" data-grow="${n}" data-tip="${esc(`${CATEGORY[k].label}${NBSP}: ${int(n)}`)}"></span>`).join('')
    : `<span class="sy-bar-seg calm" data-grow="1" data-tip="${esc(`Inchangés${NBSP}: ${int(unchanged)}`)}"></span>`;
  const legend = parts.map(([k, n], i) => `<li data-tone="${CATEGORY[k].tone}" data-i="${i}" class="${n ? '' : 'zero'}"><span class="sy-legend-ico">${glyph(CATEGORY[k].icon)}</span><b>${int(n)}</b><span>${esc(CATEGORY[k].label)}</span></li>`).join('')
    + `<li data-tone="off" class="calm"><span class="sy-legend-ico">${glyph('check')}</span><b>${int(unchanged)}</b><span>Inchangés</span></li>`;
  const samples = (r.samples ?? []).reduce((acc, s) => { (acc[s.category] ??= []).push(s); return acc; }, {});
  const lists = Object.entries(samples).map(([k, list]) => `<div class="sy-sample" data-tone="${CATEGORY[k]?.tone ?? 'off'}"><h4>${esc(CATEGORY[k]?.label ?? k)}</h4><ul>${list.map((s) => `<li>${glyph(typeGlyph(s.type))}<span><b>${esc(s.name)}</b><small>${esc(s.detail)}</small></span></li>`).join('')}</ul></div>`).join('');
  const calm = parts.every(([, n]) => n === 0)
    ? `<p class="sy-uptodate">${glyph('check')}<span>La base locale est déjà à jour pour ce périmètre${NBSP}: l’enregistrement ne fera qu’actualiser la date de couverture et les dates lues dans l’annuaire.</span></p>` : '';
  return `<div class="sy-reconcile">${calm}
      <div class="sy-bar" role="img" aria-label="${esc(`Aperçu de l’enregistrement${NBSP}: ${int(changes)} changements sur ${int(total)} objets`)}">${bar}</div>
      <p class="sy-bar-caption">${esc(`${int(changes)} ${changes > 1 ? 'changements' : 'changement'} · ${int(unchanged)} inchangé${unchanged > 1 ? 's' : ''} · ${count(r.read, 'objet lu', 'objets lus')}${c.unseen ? `, ${count(c.unseen, 'non revu', 'non revus')}` : ''}`)}</p>
      <ul class="sy-legend">${legend}</ul>
      ${lists ? `<details class="sy-samples-wrap" open><summary>${glyph('eye')}Exemples par catégorie</summary><div class="sy-samples">${lists}</div></details>` : ''}
    </div>`;
}

/**
 * The read panel of the screen.
 * @param {HTMLElement} host
 * @param {any} screen  Bus of the screen (synchro.js).
 */
export function createRunPanel(host, screen) {
  const ctx = screen.ctx;
  let state = 'idle'; // idle | running | result | stored | elsewhere
  let runId = null;
  let result = null;
  let stopping = false;
  let poll = 0;
  let unsubscribe = () => {};
  let startedAt = 0;
  let lastPhase = 'backup';
  let alive = true;

  function show(markup) {
    host.innerHTML = markup;
    host.hidden = !markup;
    paint(host);
  }

  function idle(o = screen.overview) {
    state = 'idle';
    const pending = o?.pending;
    if (!pending) { show(''); return; }
    show(`<section class="card sy-run sy-pending reveal in" aria-label="Lecture en attente d’enregistrement">
        <div class="sy-run-head"><span class="sy-run-badge" data-tone="warn">${glyph('download')}</span>
          <div class="sy-run-titles"><h2>Une lecture attend son enregistrement</h2><p>${esc(pending.label)} · ${count(pending.count, 'objet', 'objets')} · gardée jusqu’à ${esc(new Date(pending.expiresAt).toLocaleTimeString('fr-FR', { hour: '2-digit', minute: '2-digit' }))}</p></div>
          <div class="sy-run-actions">${button('Revoir et enregistrer…', { icon: 'database', primary: true, kind: 'write', data: { run: 'store-pending' } })}</div></div>
      </section>`);
  }

  function running(progress) {
    const phase = progress?.phase ?? lastPhase;
    lastPhase = phase;
    const label = progress?.text ?? 'Préparation de la lecture…';
    const known = Number.isFinite(progress?.total) && progress.total > 0;
    const percent = Number.isFinite(progress?.percent) ? progress.percent : null;
    const markup = `<section class="card sy-run is-running" aria-busy="true" aria-label="Lecture de l’annuaire en cours">
        <div class="sy-run-head"><span class="sy-run-badge spin" data-tone="info">${icon('sync')}</span>
          <div class="sy-run-titles"><h2>${esc(screen.runTitle ?? 'Lecture de l’annuaire')}</h2><p class="sy-run-text" aria-live="polite">${esc(label)}</p></div>
          <div class="sy-run-actions">${stopping ? statePill('stopping') : statePill('running')}${button(stopping ? 'Arrêt demandé' : 'Arrêter', { icon: 'pause', data: { run: 'stop' }, disabled: stopping || !runId, tip: 'Les objets déjà lus restent une lecture partielle, à enregistrer ou non.' })}</div></div>
        ${stepsMarkup(phase, false, screen.runMode ?? 'ou')}
        <div class="sy-meter${known ? '' : ' indeterminate'}" role="progressbar" aria-label="Progression de la lecture" ${known && percent !== null ? `aria-valuemin="0" aria-valuemax="100" aria-valuenow="${Math.round(percent)}"` : ''}><span data-fill="${known && percent !== null ? (percent / 100).toFixed(3) : '0.35'}"></span></div>
        <div class="sy-counters">
          <div><span>Objets reçus</span><b class="num">${int(progress?.count ?? 0)}</b></div>
          <div><span>Débit</span><b class="num">${Number.isFinite(progress?.rate) ? `${int(progress.rate)}${NBSP}obj./s` : '—'}</b></div>
          <div><span>Durée de lecture</span><b class="num">${Number.isFinite(progress?.elapsedMs) ? esc(duration(progress.elapsedMs)) : '—'}</b></div>
          <div><span>Total</span><b>${known ? int(progress.total) : 'inconnu avant la fin'}</b></div>
        </div>
      </section>`;
    if (state !== 'running' || !host.querySelector('.sy-run.is-running')) {
      state = 'running';
      show(markup);
      return;
    }
    // Same card: refresh the parts that move (no flicker of the whole card).
    const next = document.createElement('div');
    next.innerHTML = markup;
    for (const sel of ['.sy-run-text', '.sy-steps', '.sy-counters', '.sy-run-actions']) {
      const a = host.querySelector(sel);
      const b = next.querySelector(sel);
      if (a && b) a.replaceWith(b);
    }
    const meter = host.querySelector('.sy-meter');
    const newMeter = next.querySelector('.sy-meter');
    if (meter && newMeter) {
      meter.className = newMeter.className;
      meter.querySelector('span').dataset.fill = newMeter.querySelector('span').dataset.fill;
    }
    paint(host);
  }

  function showResult(r) {
    state = 'result';
    result = r;
    const tone = r.complete ? 'ok' : 'warn';
    const facts = factsMarkup([
      ['Périmètre', esc(r.scope.label)],
      ['Mode', esc(r.modeLabel)],
      ['Contrôleur', `<span class="mono">${esc(r.controller)}</span>`],
      ['Objets lus', r.computers > 0 && r.users > 0 ? `${int(r.read)} <small>(${count(r.computers, 'poste', 'postes')}, ${count(r.users, 'compte', 'comptes')})</small>` : r.computers > 0 ? count(r.computers, 'poste', 'postes') : count(r.users, 'compte', 'comptes')],
      ['Durée de lecture', esc(duration(r.durationMs))],
      ['Empreinte du lot', `<span class="mono" data-tip="${esc(r.sha256)}">${esc(shortHash(r.sha256))}</span>`],
      ['Repère', esc(r.checkpointText), 'wide'],
      ['LAPS', esc(r.lapsText ?? ''), 'wide'],
      r.censusGaps ? ['Recensement', esc(`${count(r.censusGaps, 'identité recensée reste', 'identités recensées restent')} absente${r.censusGaps > 1 ? 's' : ''} de la base après cet enregistrement.`), 'wide'] : null,
    ]);
    const notes = (r.notes ?? []).length ? `<ul class="sy-notes">${r.notes.map((n) => `<li>${icon('info')}<span>${esc(n)}</span></li>`).join('')}</ul>` : '';
    show(`<section class="card sy-run is-result reveal in" aria-label="Résultat de la lecture">
        <div class="sy-run-head"><span class="sy-run-badge pop" data-tone="${tone}">${glyph(r.complete ? 'check' : 'alert')}</span>
          <div class="sy-run-titles"><h2>${r.complete ? 'Lecture terminée' : 'Lecture partielle'} · ${esc(r.scope.label)}</h2><p>${esc(r.summary)}</p></div>
          <div class="sy-run-actions">${pill(tone, r.complete ? 'Complète' : 'Incomplète', { size: 'sm' })}${pill('info', `Gardée jusqu’à ${new Date(r.expiresAt).toLocaleTimeString('fr-FR', { hour: '2-digit', minute: '2-digit' })}`, { size: 'sm', icon: 'clock' })}</div></div>
        ${stepsMarkup('done', true, r.mode)}
        <div class="sy-run-body">
          <div class="sy-run-main"><h3>Ce que l’enregistrement changera</h3>${reconcileMarkup(r)}${notes}</div>
          <aside class="sy-run-side">${facts}</aside>
        </div>
        <footer class="sy-run-foot">
          <p>${icon('shield')}<span>Rien n’est encore écrit. L’enregistrement passe par un plan à confirmer, avec reçu et relecture de la base${NBSP}; Active Directory n’est jamais modifié.</span></p>
          <div class="sy-run-foot-actions">${button('Ignorer cette lecture', { ghost: true, data: { run: 'dismiss' } })}${button('Enregistrer dans la base locale…', { icon: 'database', primary: true, kind: 'write', data: { run: 'store' } })}</div>
        </footer>
      </section>`);
    announce(`${r.complete ? 'Lecture terminée' : 'Lecture partielle'}${NBSP}: ${r.summary}`);
  }

  function stored(receipt) {
    state = 'stored';
    const tone = toneOf(receipt?.tone ?? 'ok');
    show(`<section class="card sy-run is-stored reveal in" aria-label="Lecture enregistrée">
        <div class="sy-run-head"><span class="sy-run-badge pop" data-tone="${tone}">${glyph('shield')}</span>
          <div class="sy-run-titles"><h2>Base locale mise à jour</h2><p>${esc(receipt?.summary ?? 'Enregistrement confirmé et relu.')}</p></div>
          <div class="sy-run-actions">${pill(tone, receipt?.verificationLabel ?? 'Relu', { size: 'sm', icon: 'check' })}<a class="btn sm ghost" href="#/operations?recu=${encodeURIComponent(receipt?.id ?? '')}">${icon('activity')}Voir le reçu</a>${button('Fermer', { sm: true, ghost: true, data: { run: 'dismiss' } })}</div></div>
      </section>`);
  }

  function failed(err) {
    state = 'idle';
    show(`<section class="card sy-run is-failed reveal in" role="alert">
        <div class="sy-run-head"><span class="sy-run-badge" data-tone="alert">${glyph('alert')}</span>
          <div class="sy-run-titles"><h2>Lecture non effectuée</h2><p>${esc(errorText(err))} Rien n’a été écrit dans la base.</p></div>
          <div class="sy-run-actions">${button('Fermer', { sm: true, ghost: true, data: { run: 'dismiss' } })}</div></div>
      </section>`);
  }

  function elsewhere(info) {
    state = 'elsewhere';
    runId = info.runId;
    show(`<section class="card sy-run is-running" aria-busy="true" aria-label="Lecture en cours">
        <div class="sy-run-head"><span class="sy-run-badge spin" data-tone="info">${icon('sync')}</span>
          <div class="sy-run-titles"><h2>Lecture en cours · ${esc(info.scopeLabel)}</h2><p>${esc(info.phaseLabel)}${NBSP}: démarrée ${ago(info.startedAt)}. Son résultat attendra ici son enregistrement.</p></div>
          <div class="sy-run-actions">${info.stopping ? statePill('stopping') : statePill('running')}${button('Arrêter', { icon: 'pause', data: { run: 'stop' }, disabled: info.stopping })}</div></div>
        ${stepsMarkup(info.phase, false, info.target === 'domain' ? 'domain' : 'ou')}
        <div class="sy-meter indeterminate"><span data-fill="0.35"></span></div>
      </section>`);
    clearTimeout(poll);
    poll = setTimeout(() => screen.reload(), 2000);
  }

  /** Estimate panel, confirmed before any read; options of the pass (quota, time budget) can be changed and estimated again. */
  async function estimate(target, options = {}) {
    if (state === 'running') { ctx.toast('Une lecture est déjà en cours.', { tone: 'info' }); return; }
    const body = document.createElement('div');
    body.className = 'sy-estimate';
    body.dataset.page = 'synchro';
    body.innerHTML = `<div class="sk-stack" aria-busy="true"><span class="skeleton sk sk-line w55"></span><span class="skeleton sk sk-block w100"></span><span class="skeleton sk sk-line w85"></span></div>`;
    let current = null;
    const panel = openDrawer({
      title: target === 'domain' ? 'Changements du domaine' : 'Mettre à jour l’OU choisie',
      subtitle: 'Estimation avant toute lecture de l’annuaire',
      icon: target === 'domain' ? 'activity' : 'refresh',
      key: 'synchro.estimate',
      width: 560,
      minWidth: 420,
      body,
      actions: [
        { id: 'cancel', label: 'Annuler', run: (p) => p.close() },
        { id: 'go', label: 'Lancer la lecture', icon: 'play', primary: true, run: (p) => { if (current?.ready) { p.close(); run(current); } } },
      ],
    });
    if (panel.el) panel.el.dataset.page = 'synchro';
    const goButton = () => panel.foot?.querySelector('[data-id="go"]');
    const ask = async (opts) => {
      const b = goButton();
      if (b) b.disabled = true;
      panel.setBusy?.(true);
      try {
        const args = { target, ...screen.scopeArgs() };
        if (Number.isFinite(opts.maxObjects)) args.maxObjects = opts.maxObjects;
        if (Number.isFinite(opts.budgetSeconds)) args.budgetSeconds = opts.budgetSeconds;
        current = await ctx.call('synchro.read.estimate', args);
        if (!panel.el?.isConnected) return;
        panel.setTitle?.(current.confirmTitle, current.modeLabel);
        body.innerHTML = estimateMarkup(current, opts);
        paint(body);
        const go = goButton();
        if (go) {
          go.disabled = !current.ready;
          go.lastChild.textContent = current.confirmLabel;
          go.classList.toggle('danger', current.mode === 'full');
        }
      } catch (err) {
        console.error(err);
        if (!panel.el?.isConnected) return;
        body.innerHTML = `<div class="sy-error" role="alert">${icon('alert')}<div><b>Estimation impossible</b><p>${esc(errorText(err))}</p></div></div>`;
        if (err?.code === 'synchro.scopeRoot') {
          body.insertAdjacentHTML('beforeend', `<div class="sy-estimate-actions">${button('Choisir une OU…', { icon: 'tree', primary: true, data: { est: 'scope' } })}</div>`);
        }
      } finally {
        panel.setBusy?.(false);
      }
    };
    body.addEventListener('click', (e) => {
      const t = e.target instanceof Element ? e.target.closest('[data-est]') : null;
      if (!t) return;
      if (t.dataset.est === 'scope') { panel.close(); screen.chooseScope(); return; }
      if (t.dataset.est === 'recompute') {
        const max = Number(body.querySelector('[name="maxObjects"]')?.value);
        const budget = Number(body.querySelector('[name="budgetMinutes"]')?.value);
        ask({ maxObjects: Number.isFinite(max) && max >= 0 ? Math.round(max) : undefined, budgetSeconds: Number.isFinite(budget) && budget > 0 ? Math.round(Math.min(120, Math.max(0.5, budget)) * 60) : undefined });
      }
    });
    await ask(options);
    return panel;
  }

  function estimateMarkup(e, opts) {
    const warnings = (e.warnings ?? []).map((w) => `<li data-tone="warn">${icon('alert')}<span>${esc(w)}</span></li>`).join('');
    const refusal = e.ready ? '' : `<p class="sy-refusal" role="alert">${icon('lock')}<span>${esc(e.refusal ?? 'Lecture impossible pour l’instant.')}</span></p>`;
    const ratio = e.knownObjects > 0 ? Math.min(1, e.knownObjects / Math.max(1, e.expectedObjects)) : 0;
    return `<div class="sy-est-hero" data-mode="${esc(e.mode)}">
        <span class="sy-est-ico">${glyph(e.mode === 'ou' ? 'ou' : e.mode === 'incremental' ? 'activity' : 'domain')}</span>
        <div><b>${esc(e.scope.label)}</b><span>${esc(e.scope.isDomain ? `Domaine entier · ${e.scope.dn}` : e.scope.path)}</span></div>
        ${pill(e.mode === 'full' ? 'warn' : 'info', e.modeLabel, { size: 'sm' })}
      </div>
      <div class="sy-est-grid">
        <div class="sy-est-big"><span>Objets attendus</span><b class="num">${int(e.expectedObjects)}</b><small>${esc(`${int(e.knownObjects)} déjà dans la base`)}</small><div class="sy-mini-bar"><span data-fill="${ratio.toFixed(3)}"></span></div></div>
        <div class="sy-est-big"><span>Durée estimée</span><b>${esc(e.estimateText)}</b><small>${esc(`budget ${duration(e.budgetMs)}${e.maxObjects > 0 ? `, quota ${int(e.maxObjects)} objets` : ', sans quota'}`)}</small></div>
      </div>
      <p class="sy-est-text">${esc(e.confirmText)}</p>
      ${e.checkpointReason ? `<p class="sy-est-why">${icon('info')}<span>${esc(e.checkpointReason)}</span></p>` : ''}
      ${warnings ? `<ul class="sy-est-warn">${warnings}</ul>` : ''}
      ${refusal}
      <details class="sy-est-options"${opts.maxObjects !== undefined || opts.budgetSeconds !== undefined ? ' open' : ''}><summary>${glyph('sliders')}Limites de cette passe</summary>
        <div class="sy-est-fields">
          <label><span>Quota d’objets <small>(0${NBSP}= sans quota)</small></span><input class="input mono" type="number" name="maxObjects" min="0" max="10000000" step="1" value="${esc(String(opts.maxObjects ?? e.maxObjects))}"></label>
          <label><span>Budget de temps <small>(minutes)</small></span><input class="input mono" type="number" name="budgetMinutes" min="0.5" max="120" step="0.5" value="${esc(String(opts.budgetSeconds ? opts.budgetSeconds / 60 : e.budgetMs / 60000))}"></label>
          ${button('Estimer de nouveau', { icon: 'refresh', sm: true, data: { est: 'recompute' } })}
        </div>
        <p class="sy-est-note">Une passe coupée par une limite ne remplace jamais une base plus complète, ne déplace pas le repère et ne déduit aucune disparition.</p>
      </details>`;
  }

  async function run(e) {
    stopping = false;
    runId = null;
    startedAt = Date.now();
    screen.runTitle = e.confirmTitle;
    screen.runMode = e.mode;
    running(null);
    unsubscribe();
    unsubscribe = onEvent('synchro.read.run:progress', (p) => {
      if (!alive || state !== 'running') return;
      runId = p.runId ?? runId;
      running(p);
    });
    try {
      const r = await ctx.call('synchro.read.run', { estimateId: e.id });
      unsubscribe();
      if (!alive) return;
      runId = null;
      showResult(r);
      screen.emit('read', r);
    } catch (err) {
      unsubscribe();
      console.error(err);
      if (!alive) return;
      failed(err);
    }
  }

  async function stop() {
    if (!runId || stopping) return;
    stopping = true;
    if (state === 'running') running({ phase: lastPhase, text: 'Arrêt demandé\u00A0: la lecture s’arrête au prochain lot…' });
    try {
      const s = await ctx.call('synchro.read.stop', { runId });
      ctx.toast(s.message, { tone: s.stopping ? 'warn' : 'info' });
    } catch (err) {
      console.error(err);
      stopping = false;
    }
  }

  function store(batchId) {
    return runWrite(ctx, {
      plan: 'synchro.store.plan',
      args: { batchId },
      subtitle: 'Base locale · lecture de l’annuaire',
      onDone: (receipt) => {
        if (!alive) return;
        stored(receipt);
        screen.emit('stored', receipt);
      },
    });
  }

  host.addEventListener('click', (e) => {
    const t = e.target instanceof Element ? e.target.closest('[data-run]') : null;
    if (!t || t.disabled) return;
    const act = t.dataset.run;
    if (act === 'stop') stop();
    else if (act === 'store' && result) store(result.batchId);
    else if (act === 'store-pending' && screen.overview?.pending) store(screen.overview.pending.batchId);
    else if (act === 'dismiss') { result = null; idle({ ...screen.overview, pending: null }); }
  });

  const off = screen.on('overview', (o) => {
    if (state === 'elsewhere') {
      if (o.running) elsewhere(o.running); else idle(o);
    } else if (state === 'idle') {
      if (o.running) elsewhere(o.running); else idle(o);
    }
  });

  return {
    estimate,
    /** Shows a read started earlier (screen left and shown again) or a result waiting for its storage. */
    resume(o) {
      if (o?.running) elsewhere(o.running); else idle(o);
    },
    /** Simulation only (captures, demonstration): estimate then read the chosen OU without the confirmation panel. */
    async demo() {
      try {
        const e = await ctx.call('synchro.read.estimate', { target: 'ou', ...screen.scopeArgs() });
        if (e.ready && alive) await run(e);
      } catch (err) {
        console.error(err);
      }
    },
    destroy() {
      alive = false;
      clearTimeout(poll);
      unsubscribe();
      off();
    },
  };
}

/** Duration in plain words (« 850 ms », « 12 s », « 3 min 05 s »). */
export function duration(ms) {
  const n = Math.max(0, Math.round(Number(ms) || 0));
  if (n < 1000) return `${int(n)}${NBSP}ms`;
  const s = Math.floor(n / 1000);
  if (s < 60) return `${int(s)}${NBSP}s`;
  const m = Math.floor(s / 60);
  if (m < 60) return s % 60 ? `${int(m)}${NBSP}min ${String(s % 60).padStart(2, '0')}${NBSP}s` : `${int(m)}${NBSP}min`;
  return m % 60 ? `${int(Math.floor(m / 60))}${NBSP}h ${String(m % 60).padStart(2, '0')}${NBSP}min` : `${int(Math.floor(m / 60))}${NBSP}h`;
}

void motionReduced;
