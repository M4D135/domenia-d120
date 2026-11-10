// Accueil: explicit refresh of the working OU (Domenia 1, ACC-001 to ACC-008, ACC-038), merged into the hero: one primary
// « Tout actualiser » with its menu (local base of the OU, ping then WMI, ping only, resume an interrupted refresh), « Arrêter »
// while it runs, and a status strip under the actions (progress, stages, last report). Planned and frozen at the click
// (accueil.refresh.plan), confirmed in a dialog — « Tout relire » also reads the workstations already up to date —, run once
// (accueil.refresh.run, NetworkRead bounded to the OU, never the domain root), followed stage by stage through the event
// « accueil.refresh.run:progress », stoppable (accueil.refresh.stop). A plan is never replayed.
import { onEvent } from '../../bridge.js';
import { openDialog } from '../../kit/dialog.js';
import { openMenu } from '../../kit/menu.js';
import { glyph } from '../../kit/glyphs.js';
import { pill, statePill } from '../../kit/status.js';
import { esc, progressTo, announce, copyText } from '../../ui.js';
import { NBSP, plural, paint, reported, surface, localStamp } from './shared.js';

const MODES = {
  all: { label: 'Tout actualiser', icon: 'refresh', tip: 'Base locale de l’OU, puis ping et WMI des postes actifs, avec une seule confirmation' },
  directory: { label: 'Mettre à jour la base locale de l’OU', icon: 'database', hint: 'annuaire', tip: 'Relit l’annuaire de l’OU après une sauvegarde vérifiée de la base locale' },
  inventory: { label: 'Actualiser ping et WMI', icon: 'activity', hint: 'postes', tip: 'Ping des postes actifs puis WMI sur ceux qui répondent et dont une mesure manque' },
  presence: { label: 'Ping seul', icon: 'wifi', hint: 'présence', tip: 'Un écho par poste actif ; aucune lecture WMI' },
  resume: { label: 'Reprendre l’actualisation interrompue', icon: 'play', hint: 'reprise', tip: 'Les étapes non terminées seulement ; WMI sur les postes pas encore relus' },
};
const STAGE_STATE = {
  waiting: { label: 'En attente', tone: 'off' },
  running: { label: 'En cours', tone: 'info' },
  done: { label: 'Terminée', tone: 'ok' },
  na: { label: 'Sans objet', tone: 'off' },
  failed: { label: 'Échec', tone: 'alert' },
  // The stage ran with workstations left to read (transient cause of the ping, or WMI reads incomplete or refused): the refresh
  // is partial and « Reprendre » asks only those again. « failed » is a stage that could not run.
  partial: { label: 'Incomplète', tone: 'warn' },
  skipped: { label: 'Non lancée', tone: 'off' },
  stopped: { label: 'Arrêtée', tone: 'warn' },
};
export const OUTCOME = {
  success: { state: 'done', label: 'Terminée' },
  partial: { state: 'check', label: 'Partielle' },
  cancelled: { state: 'stopping', label: 'Arrêtée' },
  error: { state: 'failed', label: 'Échec' },
  interrupted: { state: 'check', label: 'Interrompue, à vérifier' },
  running: { state: 'running', label: 'En cours' },
};
export const stagePercent = (stages) => Math.round(100 * stages.filter(s => ['done', 'na'].includes(s.state)).length / Math.max(1, stages.length));
const STAGE_ICON = { backup: 'shield', directory: 'database', commit: 'check', presence: 'wifi', inventory: 'chip' };
const PERFORMANCE_METHODS = new Set(['Ping', 'Ldap', 'WmiDcom', 'WinRm', 'Registry', 'ScheduledTask', 'PsExec', 'WindowsSessions', 'SecurityLog', 'WindowsRpc', 'WmiProcess', 'WinRmScript']);
const stageGlyph = (s) => glyph(s.state === 'done' ? 'check' : s.state === 'failed' ? 'alert' : STAGE_ICON[s.id] ?? 'dot');

/**
 * @param {{
 *   actions: HTMLElement, status: HTMLElement, ctx: any, scopeOk: () => boolean,
 *   onFinished: (report: any) => Promise<boolean>, onRunning: (on: boolean) => void,
 * }} o  actions: slot of the hero buttons; status: strip under them.
 */
export function createRefresh(o) {
  const { ctx } = o;
  const st = { running: false, stopping: false, runId: null, stages: [], last: null, alive: true, planning: false, open: false };
  let stopStatusFollow = null;
  let restoring = false;
  let restoringVersion = 0;
  const notifiedReports = new Set();
  let off = null; // unsubscription of the progress event, released by destroy()

  o.actions.innerHTML = `<div class="split-btn" role="group" aria-label="Actualiser l’OU de travail">
      <button class="btn primary split-main is-net" type="button" data-refresh-mode="all" data-tip="${esc(`${MODES.all.tip} · lecture réseau`)}">${glyph('refresh')}<span class="label-progress">Tout actualiser</span><span class="k-cmd-net" aria-hidden="true"></span><span class="visually-hidden">, lecture réseau</span></button>
      <button class="btn primary split-caret is-net" type="button" data-refresh-menu aria-haspopup="menu" aria-expanded="false" aria-label="Autres actualisations de l’OU (lectures réseau)" data-tip="Base locale seule, ping et WMI, ping seul, reprise · lectures réseau">${glyph('chevronDown')}</button>
    </div>
    <button class="btn danger ctl-stop" type="button" data-refresh-stop hidden>${glyph('x')}<span>Arrêter</span></button>`;
  o.status.innerHTML = `<div class="ctl-run" hidden>
      <div class="ctl-run-head"><span class="ctl-state" aria-live="polite"></span><span class="ctl-run-title"></span></div>
      <div class="ctl-bar" role="progressbar" aria-label="Progression de l’actualisation" aria-valuemin="0" aria-valuemax="100" aria-valuenow="0"><span></span></div>
      <ol class="ctl-stages"></ol>
    </div>
    <div class="ctl-last" hidden></div><div class="ctl-performance" hidden></div>`;
  const runEl = o.status.querySelector('.ctl-run');
  const stagesEl = o.status.querySelector('.ctl-stages');
  const barEl = o.status.querySelector('.ctl-bar');
  const lastEl = o.status.querySelector('.ctl-last');
  const stateEl = o.status.querySelector('.ctl-state');
  const titleEl = o.status.querySelector('.ctl-run-title');
  const performanceEl = o.status.querySelector('.ctl-performance');

  function paintPerformance(report) {
    const metrics = report?.performance;
    performanceEl.hidden = !metrics;
    if (!metrics) { performanceEl.replaceChildren(); return; }
    const duration = value => {
      if (Number(value ?? 0) < 1000) return `${Math.max(0, Math.round(Number(value ?? 0)))} ms`;
      const seconds = Math.max(0, Math.round(Number(value ?? 0) / 1000));
      return seconds >= 3600 ? `${Math.floor(seconds / 3600)} h ${Math.floor(seconds % 3600 / 60)} min`
        : seconds >= 60 ? `${Math.floor(seconds / 60)} min ${seconds % 60} s` : `${seconds} s`;
    };
    const methods = (metrics.methods ?? []).filter(m => PERFORMANCE_METHODS.has(m.method)).slice(0, PERFORMANCE_METHODS.size);
    const opened = [...performanceEl.querySelectorAll('details')].map(detail => detail.open);
    performanceEl.innerHTML = `<p>${glyph('clock')} Temps total${NBSP}: <strong>${esc(duration(metrics.totalMs))}</strong>`
      + `${metrics.workstationsReused > 0 ? ` · ${plural(metrics.workstationsReused, 'poste déjà à jour, non contacté par WMI', 'postes déjà à jour, non contactés par WMI')}` : ''}</p>`
      + (methods.length ? `<details><summary>Temps par méthode de lecture</summary><table class="table"><thead><tr><th>Méthode</th><th>Lectures</th><th>Attente cumulée</th><th>Exécution cumulée</th><th>Moyenne par lecture</th><th>Cache</th></tr></thead><tbody>`
        + methods.map(m => `<tr><th scope="row">${esc(m.label)}</th><td>${esc(m.reads)}</td><td>${esc(duration(m.queueMs))}</td><td>${esc(duration(m.executionMs))}</td><td>${m.reads ? esc(duration(m.executionMs / m.reads)) : '—'}</td><td>${esc(m.cacheHits ?? 0)}</td></tr>`).join('')
        + `</tbody></table><p class="faint">Durées cumulées des lectures réellement effectuées, en parallèle. Les méthodes n’effectuent pas nécessairement le même travail. Aucun essai supplémentaire n’est lancé pour comparer.</p></details>` : '');
    if (report.status === 'running') performanceEl.insertAdjacentHTML('beforeend', branchProgress(report));
    performanceEl.querySelectorAll('details').forEach((detail, index) => { detail.open = Boolean(opened[index]); });
    paint(performanceEl);
  }

  function branchProgress(report) {
    const branches = (report?.branches ?? []).slice(0, 128);
    if (!branches.length) return '';
    return `<details class="ctl-branches"><summary>Objectifs par branche · ${branches.length}${report.branchCount > branches.length ? ` sur ${report.branchCount}` : ''}</summary><ul>`
      + branches.map(b => `<li><strong>${esc(b.scope.label)}</strong> · Ping ${esc(b.presenceDone)}/${esc(b.targets)} · WMI ${esc(b.inventoryDone)}/${esc(b.targets)}</li>`).join('')
      + '</ul><p class="faint">Résultats enregistrés localement. WMI concerne les postes admissibles selon la politique réseau dont les données manquent ; une absence de réponse ne devient pas un inventaire terminé.</p></details>';
  }

  const resumable = () => Boolean(st.last?.resumable) && !st.running;

  // A greyed command always says why (KIT § 1.2): a refresh already running, a plan being prepared, no working OU.
  function blockReason() {
    if (st.running) return `Actualisation en cours${NBSP}: attendez sa fin ou arrêtez-la.`;
    if (st.planning) return `Plan de l’actualisation en préparation${NBSP}: un instant.`;
    if (!o.scopeOk()) return `Choisissez une OU de travail${NBSP}: aucune collecte ne part sur tout le domaine.`;
    return '';
  }

  function syncButtons() {
    const reason = blockReason();
    const blocked = Boolean(reason);
    o.actions.querySelectorAll('[data-refresh-mode], [data-refresh-menu]').forEach((b) => {
      b.disabled = blocked;
      if (blocked) b.dataset.reason = reason; else delete b.dataset.reason;
    });
    const caret = o.actions.querySelector('[data-refresh-menu]');
    caret.dataset.tip = blocked ? reason : 'Base locale seule, ping et WMI, ping seul, reprise · lectures réseau';
    const main = o.actions.querySelector('.split-main');
    // One primary action on the screen (KIT § 2.6): without a working OU, « Choisir l’OU » of the OU card is the primary one
    // and the refresh, greyed with its reason, steps back.
    const lead = o.scopeOk();
    [main, caret].forEach((b) => { b.classList.toggle('primary', lead); b.classList.toggle('subtle', !lead); });
    main.classList.toggle('spinning', st.running);
    main.querySelector('.label-progress').textContent = st.running ? 'Actualisation en cours…' : 'Tout actualiser';
    main.dataset.tip = blocked ? reason : `${MODES.all.tip} · lecture réseau`;
    const stop = o.actions.querySelector('[data-refresh-stop]');
    stop.hidden = !st.running;
    stop.disabled = st.stopping;
    stop.querySelector('span').textContent = st.stopping ? 'Arrêt demandé…' : 'Arrêter';
    o.status.classList.toggle('running', st.running);
    stateEl.innerHTML = st.running ? statePill(st.stopping ? 'stopping' : 'running', { size: 'sm' }) : '';
  }

  // The page hears only the changes of the running state (its own repaint calls sync(), never back here).
  function setRunning(on) {
    if (st.running === on) return;
    st.running = on;
    if (on && !stopStatusFollow) stopStatusFollow = ctx.pulse.every('accueil.refresh.state', 1000, restore);
    o.onRunning?.(on);
  }

  // Keep stage nodes (and keyboard focus) across progress events and the one-second follow-up.
  function paintStages(stages, percent) {
    const existing = new Map([...stagesEl.children].map(li => [li.dataset.stage, li]));
    const active = stagesEl.contains(document.activeElement) ? document.activeElement : null;
    stages.forEach((s, n) => {
      let li = existing.get(s.id);
      if (!li) {
        li = document.createElement('li');
        li.className = 'ctl-stage'; li.dataset.stage = s.id;
        li.innerHTML = '<span class="ctl-dot" aria-hidden="true"></span><div class="ctl-st"><b></b><span></span></div>';
      }
      existing.delete(s.id);
      if (li.dataset.state !== s.state) {
        li.dataset.state = s.state;
        li.querySelector('.ctl-dot').innerHTML = s.state === 'running' ? '<span class="k-spin"></span>' : stageGlyph(s);
        const ss = STAGE_STATE[s.state] ?? STAGE_STATE.waiting;
        const badge = pill(ss.tone, ss.label, { size: 'sm', spin: s.state === 'running' });
        const previous = li.querySelector('.k-pill');
        if (previous) previous.outerHTML = badge;
        else li.insertAdjacentHTML('beforeend', badge);
      }
      const label = li.querySelector('.ctl-st b'), detail = li.querySelector('.ctl-st > span');
      if (label.textContent !== s.label) label.textContent = s.label;
      if (detail.textContent !== (s.detail ?? '')) detail.textContent = s.detail ?? '';
      let proof = li.querySelector('[data-copy-proof]');
      if (s.id === 'backup' && s.state === 'done' && s.detail) {
        if (!proof) {
          proof = document.createElement('button'); proof.type = 'button'; proof.className = 'btn ghost xs ctl-proof';
          proof.innerHTML = `${glyph('copy')}Copier la preuve`; li.querySelector('.ctl-st').append(proof);
        }
        proof.dataset.copyProof = String(n);
      } else proof?.remove();
      if (stagesEl.children[n] !== li) stagesEl.insertBefore(li, stagesEl.children[n] ?? null);
    });
    for (const li of existing.values()) li.remove();
    if (active?.isConnected && document.activeElement !== active) active.focus({ preventScroll: true });
    paint(stagesEl);
    barEl.setAttribute('aria-valuenow', String(percent));
    progressTo(barEl.firstElementChild, percent / 100);
  }

  function paintLast(report) {
    st.last = report;
    if (!report) { lastEl.hidden = true; return; }
    if (!st.running) paintPerformance(report);
    const out = OUTCOME[report.status] ?? OUTCOME.interrupted;
    const runs = report.runs?.length ?? 0;
    lastEl.hidden = false;
    lastEl.innerHTML = `${statePill(out.state, { label: out.label, size: 'sm' })}<span class="ctl-last-text"><b>${esc(report.label)}</b>`
      + `${report.finishedAt ? ` · ${esc(localStamp(report.finishedAt))}` : ''}${runs ? ` · ${plural(runs, 'relevé enregistré', 'relevés enregistrés')}` : ''}${report.forced ? ' · tout relu' : ''}</span>`
      + `${report.resumable ? `<button class="btn sm" type="button" data-refresh-mode="resume" data-tip="${esc(MODES.resume.tip)}">${glyph('play')}Reprendre</button>` : ''}`
      + `<button class="btn ghost sm" type="button" data-refresh-details aria-expanded="${st.open || !runEl.hidden}">${glyph('chevronDown')}Étapes</button>${branchProgress(report)}`;
    paint(lastEl);
    syncButtons();
  }

  // ---------- Plan, confirmation, run ----------

  async function plan(mode) {
    if (st.running || st.planning || !o.scopeOk()) return;
    st.planning = true;
    syncButtons();
    let p;
    try {
      p = await ctx.call('accueil.refresh.plan', { mode });
    } catch (err) {
      ctx.toast(reported(err), { tone: ['scope.tooWide', 'refresh.refused', 'refresh.backupUnavailable', 'refresh.nothingToResume'].includes(err?.code) ? 'warn' : 'alert' });
      return;
    } finally {
      st.planning = false;
      if (st.alive) syncButtons();
    }
    if (!st.alive) return;
    const reuse = p.reused > 0;
    const body = surface('ctl-plan', `<p class="ctl-plan-sum">${esc(p.summary)}</p>
      <ol class="ctl-plan-stages">${p.stages.map((s, n) => `<li data-j="${n}"><span class="ctl-dot">${glyph(STAGE_ICON[s.id] ?? 'dot')}</span><div><b>${esc(s.label)}</b><span>${esc(s.detail)}</span></div></li>`).join('')}</ol>
      ${p.probeNames?.length ? `<details class="ctl-probes"><summary>${plural(p.probeNames.length, 'sonde de widget figée dans le plan', 'sondes de widgets figées dans le plan')}</summary><ul>${p.probeNames.map((x) => `<li>${esc(x)}</li>`).join('')}</ul></details>` : ''}
      <div class="ctl-plan-facts"><span>${glyph('ou')}${esc(p.scope.label)}${p.scope.subtree ? ' et ses sous-OU' : ''}</span><span>${glyph('monitor')}${plural(p.targets, 'poste actif', 'postes actifs')}</span>`
      + `${p.online ? `<span>${glyph('wifi')}${plural(p.online - p.reused, 'à relever par WMI', 'à relever par WMI')}${reuse ? ` · ${plural(p.reused, 'déjà à jour', 'déjà à jour')}` : ''}</span>` : ''}<span>${glyph('clock')}${esc(p.estimateText)}</span></div>
      ${mode !== 'directory' && p.availableBranches?.length > 1 ? `<details class="ctl-plan-branches"><summary>Choisir les branches à collecter (${p.branchCount})</summary><p class="faint">Une seule file de collecte pour les branches choisies. La lecture AD préalable conserve la portée de l’OU de travail.</p>${p.branchCount > p.availableBranches.length ? '<p>Liste limitée à 128 branches. Affinez l’OU de travail pour sélectionner un sous-ensemble.</p>' : ''}<ul>${p.availableBranches.map((b, n) => `<li><label><input type="checkbox" data-collect-branch="${n}" ${!p.branches?.length || p.branches.some(s => s.dn === b.scope.dn && s.subtree === b.scope.subtree) ? 'checked' : ''} ${mode === 'resume' || p.branchCount > p.availableBranches.length ? 'disabled' : ''}> ${esc(b.scope.label)} · ${plural(b.targets, 'poste', 'postes')}</label></li>`).join('')}</ul></details>` : ''}
      ${p.warnings.map((w) => `<p class="ctl-warn">${glyph('info')}<span>${esc(w)}</span></p>`).join('')}
      <p class="ctl-plan-note">${glyph('shield')}<span>Plan figé au clic, valable cinq minutes et utilisable une seule fois. Aucun objet AD n’est modifié ; une absence de réponse au ping n’est jamais un verdict d’arrêt.</span></p>`);
    paint(body);
    const actions = [{ id: 'cancel', label: 'Annuler', safe: true }];
    if (reuse) actions.push({ id: 'force', label: `Tout relire (${plural(p.online, 'poste', 'postes')})`, icon: 'refresh' });
    actions.push({ id: 'run', label: p.confirm, icon: 'play', primary: true });
    const d = openDialog({ title: p.title, subtitle: `OU${NBSP}${p.scope.label}`, icon: MODES[mode]?.icon ?? 'refresh', size: 'md', body, actions });
    const editableBranches = [...body.querySelectorAll('[data-collect-branch]:not(:disabled)')];
    const selectionNote = document.createElement('p');
    if (editableBranches.length) {
      body.querySelector('.ctl-plan-branches').append(selectionNote);
      const changed = () => {
        const selected = editableBranches.filter(input => input.checked);
        d.setDisabled('run', !selected.length); d.setDisabled('force', !selected.length);
        const count = selected.reduce((total, input) => total + p.availableBranches[Number(input.dataset.collectBranch)].targets, 0);
        selectionNote.textContent = `${selected.length} branche(s) choisie(s) · ${plural(count, 'poste actif', 'postes actifs')}.`;
      };
      editableBranches.forEach(input => input.addEventListener('change', changed)); changed();
    }
    const answer = await d.result;
    if ((answer !== 'run' && answer !== 'force') || !st.alive) return;
    const branchChoices = [...body.querySelectorAll('[data-collect-branch]:not(:disabled)')];
    if (branchChoices.length && branchChoices.some(input => !input.checked)) {
      const branches = branchChoices.filter(input => input.checked).map(input => p.availableBranches[Number(input.dataset.collectBranch)].scope);
      if (!branches.length) { ctx.toast('Choisissez au moins une branche à collecter.', { tone: 'warn' }); return; }
      try { p = await ctx.call('accueil.refresh.plan', { mode, branches }); }
      catch (err) { ctx.toast(reported(err), { tone: 'alert' }); return; }
      if (!st.alive) return;
    }
    run(p, answer === 'force');
  }

  function listen() {
    off?.();
    off = onEvent('accueil.refresh.run:progress', (data) => {
      if (!st.alive || !data) return;
      if (st.runId && data.runId !== st.runId) return;
      st.runId = data.runId;
      const s = st.stages.find((x) => x.id === data.stage);
      if (s) { s.state = data.state; s.detail = data.detail; } else st.stages.push({ id: data.stage, label: data.label, detail: data.detail, state: data.state });
      paintStages(st.stages, data.percent ?? 0);
    });
  }

  async function run(p, force) {
    restoringVersion += 1;
    setRunning(true);
    st.stopping = false;
    st.runId = null;
    st.stages = p.stages.map((s) => ({ id: s.id, label: s.label, detail: s.detail, state: 'waiting' }));
    titleEl.textContent = force ? `${p.title} · tout relire` : p.title;
    runEl.hidden = false;
    lastEl.hidden = true;
    paintStages(st.stages, 0);
    syncButtons();
    announce(`${p.title}${NBSP}: lancé.`);
    listen();
    try {
      const report = await ctx.call('accueil.refresh.run', { planId: p.id, force });
      if (!st.alive) return;
      paintPerformance(report);
      st.stages = report.stages.map((s) => ({ id: s.id, label: s.label, detail: s.detail, state: s.state }));
      paintStages(st.stages, report.status === 'success' ? 100 : stagePercent(st.stages));
      paintLast(report);
      const out = OUTCOME[report.status] ?? OUTCOME.interrupted;
      if (!notifiedReports.has(report.id)) {
        notifiedReports.add(report.id);
        if (notifiedReports.size > 64) notifiedReports.delete(notifiedReports.values().next().value);
        ctx.toast(/[.!?…]$/.test(report.label) ? report.label : `${report.label}.`, { key: `refresh:${report.id}`, tone: report.status === 'success' ? 'ok' : report.status === 'error' ? 'alert' : 'warn', life: 5200 });
      }
      announce(`${p.title}${NBSP}: ${out.label.toLowerCase()}.`);
      await renderReport(report);
    } catch (err) {
      if (!st.alive) return;
      st.stages.forEach((s) => { if (s.state === 'running' || s.state === 'waiting') s.state = 'skipped'; });
      paintStages(st.stages, stagePercent(st.stages));
      ctx.toast(reported(err), { tone: err?.code === 'refresh.refused' ? 'warn' : 'alert' });
    } finally {
      off?.();
      off = null;
      st.stopping = false;
      setRunning(false);
      if (st.alive) {
        syncButtons();
        await restore();
        setTimeout(() => {
          if (!st.alive || st.running || st.open || st.last?.status !== 'success') return;
          runEl.hidden = true;
          lastEl.querySelector('[data-refresh-details]')?.setAttribute('aria-expanded', 'false');
        }, 2400);
      }
    }
  }

  async function stop() {
    if (!st.running || st.stopping) return;
    st.stopping = true;
    syncButtons();
    try {
      const r = await ctx.call('accueil.refresh.stop');
      ctx.toast(r.label, { tone: 'warn' });
    } catch (err) {
      st.stopping = false;
      syncButtons();
      ctx.toast(reported(err), { tone: 'alert' });
    }
  }

  function menu(button) {
    const item = (id) => ({
      label: MODES[id].label, icon: MODES[id].icon, hint: MODES[id].hint ? `${MODES[id].hint} · réseau` : 'réseau', run: () => plan(id),
      disabled: id === 'resume' && !resumable(), reason: 'Aucune actualisation interrompue à reprendre pour cette OU.',
    });
    openMenu(button, [
      { heading: 'Actualiser l’OU de travail' },
      item('all'), item('directory'), item('inventory'), item('presence'),
      '-',
      item('resume'),
    ], { label: 'Autres actualisations de l’OU', placement: 'bottom-start' });
  }

  async function renderReport(report) {
    try {
      const drawn = await o.onFinished(report);
      if (st.alive && drawn === true) await ctx.call('accueil.refresh.drawn', { id: report.id });
      return drawn === true;
    } catch (err) {
      // A failed rendering is not another directory attempt. Preserve the acquired stages and their evidence.
      reported(err);
      titleEl.textContent = `${report.label} · Affichage local à relire ; le reçu et les étapes sont conservés.`;
      runEl.hidden = false;
      return false;
    }
  }

  // ---------- Restore (refresh still running after a return to the screen) ----------

  async function restore() {
    if (restoring || !st.alive) return;
    restoring = true;
    const version = restoringVersion;
    try {
      const s = await ctx.call('accueil.refresh.state');
      if (!st.alive || version !== restoringVersion) return;
      paintLast(s.last ?? null);
      if (s.running && s.current) {
        paintPerformance(s.current);
        setRunning(true);
        st.stopping = Boolean(s.current.stopping);
        st.runId = s.current.id;
        st.stages = s.current.stages.map((x) => ({ id: x.id, label: x.label, detail: x.detail, state: x.state }));
        titleEl.textContent = s.current.label;
        runEl.hidden = false;
        paintStages(st.stages, stagePercent(st.stages));
        off?.();
        off = onEvent('accueil.refresh.run:progress', (data) => {
          if (!st.alive || data?.runId !== st.runId) return;
          const x = st.stages.find((y) => y.id === data.stage);
          if (x) { x.state = data.state; x.detail = data.detail; } else st.stages.push({ id: data.stage, label: data.label, detail: data.detail, state: data.state });
          paintStages(st.stages, data.percent ?? 0);

        });
        if (!stopStatusFollow) stopStatusFollow = ctx.pulse.every('accueil.refresh.state', 1000, restore);
      } else {
        off?.(); off = null;
        if (st.running) { setRunning(false); st.stopping = false; }
        if (s.awaitingDraw) {
          if (!stopStatusFollow) stopStatusFollow = ctx.pulse.every('accueil.refresh.state', 1000, restore);
          const drawn = s.last ? await renderReport(s.last) : false;
          if (st.alive && drawn === true) {
            stopStatusFollow?.(); stopStatusFollow = null;
          }
        } else {
          stopStatusFollow?.(); stopStatusFollow = null;
        }
      }
      syncButtons();
    } catch (err) {
      reported(err);
    } finally { restoring = false; }
  }

  const onClick = (e) => {
    const t = e.target instanceof Element ? e.target : null;
    const proof = t?.closest('[data-copy-proof]');
    if (proof) {
      const detail = st.stages[Number(proof.dataset.copyProof)]?.detail;
      if (detail) copyText(detail).then(ok => ctx.toast(ok ? 'Preuve de sauvegarde copiée.' : 'Copie impossible ; la preuve reste sélectionnable.', { tone: ok ? 'ok' : 'warn' }));
      return;
    }
    const mode = t?.closest('[data-refresh-mode]');
    if (mode && !mode.disabled) { plan(mode.dataset.refreshMode); return; }
    const caret = t?.closest('[data-refresh-menu]');
    if (caret && !caret.disabled) { menu(caret); return; }
    if (t?.closest('[data-refresh-stop]')) { stop(); return; }
    const details = t?.closest('[data-refresh-details]');
    if (details && st.last) {
      // Follows what is displayed: the stages of a finished run stay visible, so the first click folds them.
      st.open = runEl.hidden;
      details.setAttribute('aria-expanded', String(st.open));
      runEl.hidden = !st.open;
      if (st.open) {
        titleEl.textContent = st.last.label;
        st.stages = st.last.stages.map((s) => ({ id: s.id, label: s.label, detail: s.detail, state: s.state }));
        paintStages(st.stages, st.last.status === 'success' ? 100 : stagePercent(st.stages));
      }
    }
  };
  o.actions.addEventListener('click', onClick);
  o.status.addEventListener('click', onClick);

  syncButtons();
  restore();

  return {
    plan,
    sync: syncButtons,
    running: () => st.running,
    destroy() {
      st.alive = false;
      stopStatusFollow?.(); stopStatusFollow = null;
      off?.();
      off = null;
      o.actions.removeEventListener('click', onClick);
      o.status.removeEventListener('click', onClick);
    },
  };
}
