// Accueil: « Contrôles du parc » (Domenia 1, ACC-001 to ACC-008): explicit refresh of the working OU — local base of the
// OU, ping, ping then WMI, or all of it — planned and frozen at the click (accueil.refresh.plan), confirmed in a dialog,
// run once (accueil.refresh.run, NetworkRead bounded to the OU, never the domain root), followed stage by stage through the
// event « accueil.refresh.run:progress », stoppable (accueil.refresh.stop). A plan is never replayed.
import { onEvent } from '../../bridge.js';
import { openDialog } from '../../kit/dialog.js';
import { glyph } from '../../kit/glyphs.js';
import { pill, statePill } from '../../kit/status.js';
import { esc, progressTo, announce } from '../../ui.js';
import { plural, paint, reported, surface, localStamp } from './shared.js';

const MODES = [
  { id: 'all', label: 'Tout actualiser', icon: 'refresh', tip: 'Base locale de l’OU, puis ping et WMI des postes actifs (une confirmation).' },
  { id: 'directory', label: 'Mettre à jour la base locale de l’OU', icon: 'database', tip: 'Relit l’annuaire de l’OU après une sauvegarde vérifiée de la base locale.' },
  { id: 'inventory', label: 'Actualiser ping et WMI', icon: 'activity', tip: 'Ping des postes actifs puis WMI sur ceux qui répondent.' },
  { id: 'presence', label: 'Ping seul', icon: 'wifi', tip: 'Un écho par poste actif ; aucune lecture WMI.' },
];
const STAGE_STATE = {
  waiting: { label: 'En attente', tone: 'off' },
  running: { label: 'En cours', tone: 'info' },
  done: { label: 'Terminée', tone: 'ok' },
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

/**
 * @param {HTMLElement} host  Card « Contrôles du parc ».
 * @param {{ ctx: any, scopeOk: () => boolean, onFinished: (report: any) => void, onRunning: (on: boolean) => void }} o
 */
export function createRefresh(host, o) {
  const { ctx } = o;
  const st = { running: false, stopping: false, runId: null, stages: [], last: null, alive: true, planning: false };

  host.innerHTML = `<div class="ctl-head"><span class="card-icon">${glyph('zap')}</span>
      <div class="ctl-titles"><h3>Contrôles du parc</h3><p>Lectures explicites de l’OU de travail, préparées puis confirmées ; jamais sur tout le domaine, jamais rejouées.</p></div>
      <span class="ctl-state" aria-live="polite"></span></div>
    <div class="ctl-actions" role="group" aria-label="Contrôles du parc">${MODES.map((m, n) => `<button class="btn${n === 0 ? ' primary' : n === 3 ? ' ghost' : ''} ctl-btn" type="button" data-refresh-mode="${m.id}" data-tip="${esc(m.tip)}">${glyph(m.icon)}<span>${esc(m.label)}</span></button>`).join('')}
      <button class="btn danger ctl-stop" type="button" data-refresh-stop hidden>${glyph('x')}<span>Arrêter</span></button></div>
    <div class="ctl-run" hidden>
      <div class="ctl-bar" role="progressbar" aria-label="Progression de l’actualisation" aria-valuemin="0" aria-valuemax="100" aria-valuenow="0"><span></span></div>
      <ol class="ctl-stages"></ol>
    </div>
    <div class="ctl-last" hidden></div>`;
  const runEl = host.querySelector('.ctl-run');
  const stagesEl = host.querySelector('.ctl-stages');
  const barEl = host.querySelector('.ctl-bar');
  const lastEl = host.querySelector('.ctl-last');
  const stateEl = host.querySelector('.ctl-state');

  function syncButtons() {
    host.querySelectorAll('[data-refresh-mode]').forEach((b) => { b.disabled = st.running || st.planning || !o.scopeOk(); });
    const stop = host.querySelector('[data-refresh-stop]');
    stop.hidden = !st.running;
    stop.disabled = st.stopping;
    stop.querySelector('span').textContent = st.stopping ? 'Arrêt demandé…' : 'Arrêter';
    host.classList.toggle('running', st.running);
    stateEl.innerHTML = st.running ? statePill(st.stopping ? 'stopping' : 'running') : '';
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
      return `<li class="ctl-stage" data-state="${esc(s.state)}" data-j="${n}"><span class="ctl-dot" aria-hidden="true">${s.state === 'running' ? '<span class="k-spin"></span>' : glyph(s.state === 'done' ? 'check' : s.state === 'failed' ? 'alert' : STAGE_ICON[s.id] ?? 'dot')}</span>`
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
      + `${report.finishedAt ? ` · ${esc(localStamp(report.finishedAt))}` : ''}${runs ? ` · ${plural(runs, 'relevé enregistré', 'relevés enregistrés')}` : ''}</span>`
      + `<button class="btn ghost sm" type="button" data-refresh-details aria-expanded="false">${glyph('chevronDown')}Étapes</button>`;
    paint(lastEl);
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
      ctx.toast(reported(err), { tone: err?.code === 'scope.tooWide' ? 'warn' : 'alert' });
      return;
    } finally {
      st.planning = false;
      if (st.alive) syncButtons();
    }
    if (!st.alive) return;
    const body = surface('ctl-plan', `<p class="ctl-plan-sum">${esc(p.summary)}</p>
      <ol class="ctl-plan-stages">${p.stages.map((s, n) => `<li data-j="${n}"><span class="ctl-dot">${glyph(STAGE_ICON[s.id] ?? 'dot')}</span><div><b>${esc(s.label)}</b><span>${esc(s.detail)}</span></div></li>`).join('')}</ol>
      ${p.probeNames?.length ? `<details class="ctl-probes"><summary>${plural(p.probeNames.length, 'sonde de widget figée dans le plan', 'sondes de widgets figées dans le plan')}</summary><ul>${p.probeNames.map((x) => `<li>${esc(x)}</li>`).join('')}</ul></details>` : ''}
      <div class="ctl-plan-facts"><span>${glyph('ou')}${esc(p.scope.label)}${p.scope.subtree ? ' et ses sous-OU' : ''}</span><span>${glyph('monitor')}${plural(p.targets, 'poste actif', 'postes actifs')}</span><span>${glyph('clock')}${esc(p.estimateText)}</span></div>
      ${p.warnings.map((w) => `<p class="ctl-warn">${glyph('info')}<span>${esc(w)}</span></p>`).join('')}
      <p class="ctl-plan-note">${glyph('shield')}<span>Plan figé au clic, valable cinq minutes et utilisable une seule fois. Aucun objet AD n’est modifié ; une absence de réponse au ping n’est jamais un verdict d’arrêt.</span></p>`);
    paint(body);
    const d = openDialog({
      title: p.title, subtitle: `OU ${p.scope.label}`, icon: MODES.find((m) => m.id === mode)?.icon ?? 'refresh', size: 'md', body,
      actions: [{ id: 'cancel', label: 'Annuler', safe: true }, { id: 'run', label: p.confirm, icon: 'play', primary: true }],
    });
    const answer = await d.result;
    if (answer !== 'run' || !st.alive) return;
    run(p);
  }

  async function run(p) {
    setRunning(true);
    st.stopping = false;
    st.runId = null;
    st.stages = p.stages.map((s) => ({ id: s.id, label: s.label, detail: s.detail, state: 'waiting' }));
    runEl.hidden = false;
    lastEl.hidden = true;
    paintStages(st.stages, 0);
    syncButtons();
    announce(`${p.title} : lancé.`);
    const off = onEvent('accueil.refresh.run:progress', (data) => {
      if (!st.alive || !data) return;
      if (st.runId && data.runId !== st.runId) return;
      st.runId = data.runId;
      const s = st.stages.find((x) => x.id === data.stage);
      if (s) { s.state = data.state; s.detail = data.detail; }
      paintStages(st.stages, data.percent ?? 0);
    });
    try {
      const report = await ctx.call('accueil.refresh.run', { planId: p.id });
      if (!st.alive) return;
      st.stages = report.stages.map((s) => ({ id: s.id, label: s.label, detail: s.detail, state: s.state }));
      paintStages(st.stages, 100);
      paintLast(report);
      const out = OUTCOME[report.status] ?? OUTCOME.success;
      ctx.toast(`${report.label}.`, { tone: report.status === 'success' ? 'ok' : report.status === 'error' ? 'alert' : 'warn', life: 5200 });
      announce(`${p.title} : ${out.label.toLowerCase()}.`);
      o.onFinished(report);
    } catch (err) {
      if (!st.alive) return;
      st.stages.forEach((s) => { if (s.state === 'running' || s.state === 'waiting') s.state = 'skipped'; });
      paintStages(st.stages, 100);
      ctx.toast(reported(err), { tone: 'alert' });
    } finally {
      off();
      st.stopping = false;
      setRunning(false);
      if (st.alive) {
        syncButtons();
        setTimeout(() => { if (st.alive && !st.running) runEl.hidden = true; }, 2400);
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
        runEl.hidden = false;
        paintStages(st.stages, Math.round((100 * st.stages.filter((x) => x.state !== 'running').length) / Math.max(1, st.stages.length)));
        const off = onEvent('accueil.refresh.run:progress', (data) => {
          if (!st.alive || data?.runId !== st.runId) return;
          const x = st.stages.find((y) => y.id === data.stage);
          if (x) { x.state = data.state; x.detail = data.detail; } else st.stages.push({ id: data.stage, label: data.label, detail: data.detail, state: data.state });
          paintStages(st.stages, data.percent ?? 0);
          if (data.index === data.count - 1 && data.state !== 'running') {
            off();
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

  host.addEventListener('click', (e) => {
    const t = e.target instanceof Element ? e.target : null;
    const mode = t?.closest('[data-refresh-mode]');
    if (mode && !mode.disabled) { plan(mode.dataset.refreshMode); return; }
    if (t?.closest('[data-refresh-stop]')) { stop(); return; }
    const details = t?.closest('[data-refresh-details]');
    if (details && st.last) {
      const open = details.getAttribute('aria-expanded') === 'true';
      details.setAttribute('aria-expanded', String(!open));
      runEl.hidden = open;
      if (!open) paintStages(st.last.stages.map((s) => ({ id: s.id, label: s.label, detail: s.detail, state: s.state })), 100);
    }
  });

  syncButtons();
  restore();

  return {
    plan,
    sync: syncButtons,
    running: () => st.running,
    destroy() { st.alive = false; },
  };
}

