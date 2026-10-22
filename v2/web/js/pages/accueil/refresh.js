// Accueil: explicit refresh of the working OU (Domenia 1, ACC-001 to ACC-008, ACC-038), merged into the hero: one primary
// « Tout actualiser » with its menu (local base of the OU, ping then WMI, ping only, resume an interrupted refresh), « Arrêter »
// while it runs, and a status strip under the actions (progress, stages, last report). Planned and frozen at the click
// (accueil.refresh.plan), confirmed in a dialog — « Tout relire » also reads the workstations already up to date —, run once
// (accueil.refresh.run, NetworkRead bounded to the OU, never the domain root), followed stage by stage through the event
// « accueil.refresh.run:progress », stoppable (accueil.refresh.stop). A plan is never replayed.
import { onEvent } from '../../bridge.js';
import { openDialog } from '../../kit/dialog.js';
import { openMenu } from '../../kit/menu.js';
import { glyph } from '../../kit/glyphs.js';
import { pill, statePill } from '../../kit/status.js';
import { esc, progressTo, announce } from '../../ui.js';
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
  skipped: { label: 'Non lancée', tone: 'off' },
  stopped: { label: 'Arrêtée', tone: 'warn' },
};
const OUTCOME = {
  success: { state: 'done', label: 'Terminée' },
  partial: { state: 'check', label: 'Partielle' },
  cancelled: { state: 'stopping', label: 'Arrêtée' },
  error: { state: 'failed', label: 'Échec' },
  running: { state: 'running', label: 'En cours' },
};
const STAGE_ICON = { backup: 'shield', directory: 'database', commit: 'check', presence: 'wifi', inventory: 'chip' };
const stageGlyph = (s) => glyph(s.state === 'done' ? 'check' : s.state === 'failed' ? 'alert' : STAGE_ICON[s.id] ?? 'dot');

/**
 * @param {{
 *   actions: HTMLElement, status: HTMLElement, ctx: any, scopeOk: () => boolean,
 *   onFinished: (report: any) => void, onRunning: (on: boolean) => void,
 * }} o  actions: slot of the hero buttons; status: strip under them.
 */
export function createRefresh(o) {
  const { ctx } = o;
  const st = { running: false, stopping: false, runId: null, stages: [], last: null, alive: true, planning: false, open: false };
  let off = null; // unsubscription of the progress event, released by destroy()

  o.actions.innerHTML = `<div class="split-btn" role="group" aria-label="Actualiser l’OU de travail">
      <button class="btn primary split-main" type="button" data-refresh-mode="all" data-tip="${esc(MODES.all.tip)}">${glyph('refresh')}<span class="label-progress">Tout actualiser</span></button>
      <button class="btn primary split-caret" type="button" data-refresh-menu aria-haspopup="menu" aria-expanded="false" aria-label="Autres actualisations de l’OU" data-tip="Base locale seule, ping et WMI, ping seul, reprise">${glyph('chevronDown')}</button>
    </div>
    <button class="btn danger ctl-stop" type="button" data-refresh-stop hidden>${glyph('x')}<span>Arrêter</span></button>`;
  o.status.innerHTML = `<div class="ctl-run" hidden>
      <div class="ctl-run-head"><span class="ctl-state" aria-live="polite"></span><span class="ctl-run-title"></span></div>
      <div class="ctl-bar" role="progressbar" aria-label="Progression de l’actualisation" aria-valuemin="0" aria-valuemax="100" aria-valuenow="0"><span></span></div>
      <ol class="ctl-stages"></ol>
    </div>
    <div class="ctl-last" hidden></div>`;
  const runEl = o.status.querySelector('.ctl-run');
  const stagesEl = o.status.querySelector('.ctl-stages');
  const barEl = o.status.querySelector('.ctl-bar');
  const lastEl = o.status.querySelector('.ctl-last');
  const stateEl = o.status.querySelector('.ctl-state');
  const titleEl = o.status.querySelector('.ctl-run-title');

  const resumable = () => Boolean(st.last?.resumable) && !st.running;

  function syncButtons() {
    const blocked = st.running || st.planning || !o.scopeOk();
    o.actions.querySelectorAll('[data-refresh-mode], [data-refresh-menu]').forEach((b) => { b.disabled = blocked; });
    const main = o.actions.querySelector('.split-main');
    main.classList.toggle('spinning', st.running);
    main.querySelector('.label-progress').textContent = st.running ? 'Actualisation en cours…' : 'Tout actualiser';
    main.dataset.tip = o.scopeOk() ? MODES.all.tip : 'Choisissez une OU de travail : aucune collecte ne part sur tout le domaine';
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
    o.onRunning?.(on);
  }

  function paintStages(stages, percent) {
    stagesEl.innerHTML = stages.map((s, n) => {
      const ss = STAGE_STATE[s.state] ?? STAGE_STATE.waiting;
      return `<li class="ctl-stage" data-state="${esc(s.state)}" data-j="${n}"><span class="ctl-dot" aria-hidden="true">${s.state === 'running' ? '<span class="k-spin"></span>' : stageGlyph(s)}</span>`
        + `<div class="ctl-st"><b>${esc(s.label)}</b><span>${esc(s.detail ?? '')}</span></div>${pill(ss.tone, ss.label, { size: 'sm', spin: s.state === 'running' })}</li>`;
    }).join('');
    paint(stagesEl);
    barEl.setAttribute('aria-valuenow', String(percent));
    progressTo(barEl.firstElementChild, percent / 100);
  }

  function paintLast(report) {
    st.last = report;
    if (!report) { lastEl.hidden = true; return; }
    const out = OUTCOME[report.status] ?? OUTCOME.success;
    const runs = report.runs?.length ?? 0;
    lastEl.hidden = false;
    lastEl.innerHTML = `${statePill(out.state, { label: out.label, size: 'sm' })}<span class="ctl-last-text"><b>${esc(report.label)}</b>`
      + `${report.finishedAt ? ` · ${esc(localStamp(report.finishedAt))}` : ''}${runs ? ` · ${plural(runs, 'relevé enregistré', 'relevés enregistrés')}` : ''}${report.forced ? ' · tout relu' : ''}</span>`
      + `${report.resumable ? `<button class="btn sm" type="button" data-refresh-mode="resume" data-tip="${esc(MODES.resume.tip)}">${glyph('play')}Reprendre</button>` : ''}`
      + `<button class="btn ghost sm" type="button" data-refresh-details aria-expanded="${st.open}">${glyph('chevronDown')}Étapes</button>`;
    paint(lastEl);
    syncButtons();
  }

  // ---------- Plan, confirmation, run ----------

  async function plan(mode) {
    if (st.running || st.planning) return;
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
      ${p.warnings.map((w) => `<p class="ctl-warn">${glyph('info')}<span>${esc(w)}</span></p>`).join('')}
      <p class="ctl-plan-note">${glyph('shield')}<span>Plan figé au clic, valable cinq minutes et utilisable une seule fois. Aucun objet AD n’est modifié ; une absence de réponse au ping n’est jamais un verdict d’arrêt.</span></p>`);
    paint(body);
    const actions = [{ id: 'cancel', label: 'Annuler', safe: true }];
    if (reuse) actions.push({ id: 'force', label: `Tout relire (${plural(p.online, 'poste', 'postes')})`, icon: 'refresh' });
    actions.push({ id: 'run', label: p.confirm, icon: 'play', primary: true });
    const d = openDialog({ title: p.title, subtitle: `OU${NBSP}${p.scope.label}`, icon: MODES[mode]?.icon ?? 'refresh', size: 'md', body, actions });
    const answer = await d.result;
    if ((answer !== 'run' && answer !== 'force') || !st.alive) return;
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
      st.stages = report.stages.map((s) => ({ id: s.id, label: s.label, detail: s.detail, state: s.state }));
      paintStages(st.stages, 100);
      paintLast(report);
      const out = OUTCOME[report.status] ?? OUTCOME.success;
      ctx.toast(`${report.label}.`, { tone: report.status === 'success' ? 'ok' : report.status === 'error' ? 'alert' : 'warn', life: 5200 });
      announce(`${p.title}${NBSP}: ${out.label.toLowerCase()}.`);
      o.onFinished(report);
    } catch (err) {
      if (!st.alive) return;
      st.stages.forEach((s) => { if (s.state === 'running' || s.state === 'waiting') s.state = 'skipped'; });
      paintStages(st.stages, 100);
      ctx.toast(reported(err), { tone: err?.code === 'refresh.refused' ? 'warn' : 'alert' });
    } finally {
      off?.();
      off = null;
      st.stopping = false;
      setRunning(false);
      if (st.alive) {
        syncButtons();
        setTimeout(() => { if (st.alive && !st.running && !st.open) runEl.hidden = true; }, 2400);
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
      label: MODES[id].label, icon: MODES[id].icon, hint: MODES[id].hint, run: () => plan(id),
      disabled: id === 'resume' && !resumable(), reason: 'Aucune actualisation interrompue à reprendre pour cette OU.',
    });
    openMenu(button, [
      { heading: 'Actualiser l’OU de travail' },
      item('all'), item('directory'), item('inventory'), item('presence'),
      '-',
      item('resume'),
    ], { label: 'Autres actualisations de l’OU', placement: 'bottom-start' });
  }

  // ---------- Restore (refresh still running after a return to the screen) ----------

  async function restore() {
    try {
      const s = await ctx.call('accueil.refresh.state');
      if (!st.alive) return;
      paintLast(s.last ?? null);
      if (s.running && s.current) {
        setRunning(true);
        st.stopping = Boolean(s.current.stopping);
        st.runId = s.current.id;
        st.stages = s.current.stages.map((x) => ({ id: x.id, label: x.label, detail: x.detail, state: x.state }));
        titleEl.textContent = s.current.label;
        runEl.hidden = false;
        paintStages(st.stages, Math.round((100 * st.stages.filter((x) => x.state !== 'running').length) / Math.max(1, st.stages.length)));
        off?.();
        off = onEvent('accueil.refresh.run:progress', (data) => {
          if (!st.alive || data?.runId !== st.runId) return;
          const x = st.stages.find((y) => y.id === data.stage);
          if (x) { x.state = data.state; x.detail = data.detail; } else st.stages.push({ id: data.stage, label: data.label, detail: data.detail, state: data.state });
          paintStages(st.stages, data.percent ?? 0);
          if (data.index === data.count - 1 && data.state !== 'running') {
            off?.();
            off = null;
            setRunning(false);
            syncButtons();
            restore();
            o.onFinished(null);
          }
        });
      }
      syncButtons();
    } catch (err) {
      reported(err);
    }
  }

  const onClick = (e) => {
    const t = e.target instanceof Element ? e.target : null;
    const mode = t?.closest('[data-refresh-mode]');
    if (mode && !mode.disabled) { plan(mode.dataset.refreshMode); return; }
    const caret = t?.closest('[data-refresh-menu]');
    if (caret && !caret.disabled) { menu(caret); return; }
    if (t?.closest('[data-refresh-stop]')) { stop(); return; }
    const details = t?.closest('[data-refresh-details]');
    if (details && st.last) {
      st.open = details.getAttribute('aria-expanded') !== 'true';
      details.setAttribute('aria-expanded', String(st.open));
      runEl.hidden = !st.open;
      if (st.open) {
        titleEl.textContent = st.last.label;
        paintStages(st.last.stages.map((s) => ({ id: s.id, label: s.label, detail: s.detail, state: s.state })), 100);
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
      off?.();
      off = null;
      o.actions.removeEventListener('click', onClick);
      o.status.removeEventListener('click', onClick);
    },
  };
}
