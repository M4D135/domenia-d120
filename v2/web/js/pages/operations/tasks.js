// Tab « Tâches » (Domenia 1 OPE-012 to OPE-021): tasks in progress with their live duration, their progress, the phases and
// counters of a collection batch, and the stop of a read; then the last operations of the session with their end, their dominant
// phase and their reference, filtered by state; a task opens in a panel with its phases drawn in time order, its total and volume
// given apart, the advice or next step after its end and a masked copy of its detail. The panel is updated in place: it is drawn
// again only when the task changed (no flicker, focus and selection kept). « Arrêt demandé » is not a confirmed cancellation; a
// write is never stopped; nothing is ever relaunched automatically.
import { esc, errorText, toast, announce } from '../../ui.js';
import { createGrid, createFilterBar, openDrawer, pill, glyph, writeClipboard, NBSP } from '../../kit/index.js';
import { duration, count, int, fullDate, emptyState, sectionHead, toneMark, maskSecrets, paintVars } from './common.js';

const KIND_ICONS = { local: 'chip', localRead: 'database', networkRead: 'wifi', localWrite: 'file', write: 'edit', batch: 'layers' };
const OUTCOME_OPTIONS = [
  { value: 'running', label: 'En cours', tone: 'info' },
  { value: 'succeeded', label: 'Terminée', tone: 'ok' },
  { value: 'stopped', label: 'Arrêtée', tone: 'warn' },
  { value: 'timedOut', label: 'Délai dépassé', tone: 'warn' },
  { value: 'refused', label: 'Refusée avant envoi', tone: 'alert' },
  { value: 'failed', label: 'Échec', tone: 'alert' },
  { value: 'unknown', label: 'Résultat inconnu', tone: 'warn' },
  { value: 'superseded', label: 'Remplacée', tone: 'info' },
  { value: 'withdrawn', label: 'Retirée de la file', tone: 'info' },
];
const REVIEW = new Set(['refused', 'failed', 'unknown', 'timedOut']);
const FACETS = [
  { id: 'succeeded', label: 'Terminées', tone: 'ok' },
  { id: 'review', label: 'À revoir', tone: 'alert' },
  { id: 'stopped', label: 'Arrêtées', tone: 'warn' },
  { id: 'writes', label: 'Écritures', tone: 'info' },
];

/** A cell on two lines at most (the row keeps its height), with the whole text in its tip. */
const twoLines = (v) => (v ? `<span class="op-cell-2l" data-tip="${esc(v)}">${esc(v)}</span>` : '<span class="op-none">—</span>');

const COLUMNS = [
  { id: 'outcome', label: 'État', type: 'enum', width: 170, required: true, get: (r) => r.outcome ?? 'running', options: OUTCOME_OPTIONS },
  { id: 'label', label: 'Opération', width: 270, required: true, html: (v, r) => `<span class="op-cell-task"><span class="op-cell-ico" data-kind="${esc(r.kind)}" aria-hidden="true">${glyph(KIND_ICONS[r.kind] ?? 'activity')}</span>${twoLines(v)}</span>` },
  { id: 'kindLabel', label: 'Type', width: 160 },
  { id: 'screen', label: 'Écran', width: 110, hidden: true },
  { id: 'startedAt', label: 'Début', type: 'date', width: 108 },
  { id: 'durationMs', label: 'Durée', type: 'number', width: 100, align: 'end', format: (v) => duration(v), csv: (v) => String(Math.round(v ?? 0)) },
  { id: 'dominantLabel', label: 'Étape dominante', width: 260, html: (v) => twoLines(v) },
  { id: 'volume', label: 'Volume', type: 'number', width: 100, align: 'end', format: (v) => (Number.isFinite(v) ? int(v) : '—') },
  { id: 'reference', label: 'Référence', width: 104, mono: true },
  { id: 'operation', label: 'Code de l’opération', width: 230, mono: true, hidden: true },
  { id: 'category', label: 'Code de fin', width: 200, mono: true, hidden: true },
];

/**
 * @param {HTMLElement} host
 * @param {{ ctx: any, demo: boolean, pulse: any, onStop: (id: string) => Promise<any> }} env
 */
export function createTasks(host, env) {
  const { ctx, demo } = env;
  let alive = true;
  let snapshot = null;
  let receivedAt = performance.now();
  let pressed = new Set();
  let showAutomatic = false;
  let drawer = null;
  let drawerId = null;
  let drawerSig = '';

  host.innerHTML = `<div class="op-tasks">
    ${sectionHead('En cours', '', '<span class="op-sec-live" aria-live="polite"></span>')}
    <div class="op-running" aria-busy="true">${[0, 1].map(() => '<article class="op-task skeleton-card"><span class="skeleton op-sk-line w55"></span><span class="skeleton op-sk-line w85"></span><span class="skeleton op-sk-bar"></span></article>').join('')}</div>
    ${sectionHead('Dernières opérations', 'Session en cours · 64 au plus · rien n’est relancé automatiquement')}
    <div class="op-tk-filters"></div>
    <div class="op-tk-grid"></div>
    <p class="op-note op-tk-note"></p>
  </div>`;
  const running = host.querySelector('.op-running');
  const liveLabel = host.querySelector('.op-sec-live');
  const note = host.querySelector('.op-tk-note');

  const grid = createGrid(host.querySelector('.op-tk-grid'), {
    key: 'operations.taches',
    label: 'Dernières opérations de la session',
    rowId: (r) => r.id,
    selection: 'single',
    loading: true,
    height: '460px',
    columns: COLUMNS,
    quickPlaceholder: 'Filtrer (opération, type, référence…)',
    empty: { icon: 'activity', title: 'Aucune opération terminée', text: 'Les demandes de l’opérateur s’ajoutent ici à leur fin, avec leurs étapes et leur durée.' },
    onActivate: (row) => openTrace(row.id),
    contextMenu: ({ row }) => [
      { label: 'Étapes de l’opération', icon: 'activity', disabled: !row, run: () => openTrace(row.id) },
      { label: 'Copier le détail', icon: 'copy', disabled: !row, run: () => copyTrace(row) },
      { label: 'Copier la référence', icon: 'hash', disabled: !row, run: () => writeClipboard(row.reference).then(() => toast(`Référence copiée${NBSP}: ${row.reference}`, { tone: 'ok', life: 2400 })) },
    ],
    onExport: (csv, info) => {
      if (demo) { writeClipboard(csv).then(() => toast(`Exemple local${NBSP}: CSV copié, rien n’est enregistré.`, { tone: 'info' })); return; }
      ctx.call('operations.export.save', { subject: 'operations', csv }).then((r) => toast(r.saved ? `${count(info.rows, 'opération exportée', 'opérations exportées')}${NBSP}: ${r.name}` : r.message, { tone: r.saved ? 'ok' : 'info', life: 6000 }))
        .catch((err) => toast(`Export impossible${NBSP}: ${errorText(err)}`, { tone: 'alert' }));
    },
  });
  const auto = document.createElement('label');
  auto.className = 'op-switch';
  auto.innerHTML = `<input class="switch" type="checkbox" data-auto><span>Lectures automatiques</span>`;
  auto.dataset.tip = 'Affiche aussi les lectures automatiques terminées sans incident (masquées par défaut, comme dans Domenia 1).';
  grid.slot.append(auto);
  auto.querySelector('input').addEventListener('change', (e) => { showAutomatic = e.target.checked; paint(); });

  const filters = createFilterBar(host.querySelector('.op-tk-filters'), {
    label: 'Filtres des opérations',
    facets: FACETS.map((f) => ({ ...f, count: 0 })),
    onToggle: (id, on) => { if (on) pressed.add(id); else pressed.delete(id); paint(); },
    onClear: () => { pressed = new Set(); paint(); },
  });

  running.addEventListener('click', (e) => {
    const stop = e.target instanceof Element ? e.target.closest('[data-stop]') : null;
    if (stop) { stopTask(stop.dataset.stop, stop); return; }
    const open = e.target instanceof Element ? e.target.closest('[data-open]') : null;
    if (open) openTrace(open.dataset.open);
  });
  running.addEventListener('keydown', (e) => {
    const card = e.target instanceof Element ? e.target.closest('.op-task[data-id]') : null;
    if (!card) return;
    if (e.key === 'Delete') {
      const stop = card.querySelector('[data-stop]');
      if (stop) { e.preventDefault(); stopTask(stop.dataset.stop, stop); }
    } else if (e.key === 'Enter' && e.target === card) {
      e.preventDefault();
      openTrace(card.dataset.id);
    }
  });

  // ---------------------------------------------------------------- painting

  function update(next) {
    if (!alive || !next) return;
    snapshot = next;
    receivedAt = performance.now();
    running.removeAttribute('aria-busy');
    paintRunning();
    paint();
    note.textContent = next.note ?? '';
    if (drawer && drawerId) refreshTrace();
  }

  function paintRunning() {
    const open = snapshot.open ?? [];
    const label = `${glyph('activity')}${esc(snapshot.summary.text)}<span class="op-sec-res">${esc(snapshot.summary.resourcesText)}</span>`;
    if (liveLabel.innerHTML !== label) liveLabel.innerHTML = label;
    const ids = open.map((t) => t.id).join('|');
    if (running.dataset.ids === ids) {
      // Same tasks (or still none): update in place (selection, focus and animations are kept).
      open.forEach((t) => {
        const card = running.querySelector(`.op-task[data-id="${CSS.escape(t.id)}"]`);
        if (!card) return;
        card.dataset.state = t.state;
        const state = card.querySelector('.op-task-state');
        const stateHtml = statePill(t);
        if (state.outerHTML !== stateHtml) state.outerHTML = stateHtml;
        const detail = card.querySelector('.op-task-detail');
        if (detail.textContent !== t.detail) detail.textContent = t.detail;
        const bar = card.querySelector('.op-task-bar i');
        if (t.progress && bar) bar.style.setProperty('--p', String(t.progress.total ? t.progress.done / t.progress.total : 0));
        const head = card.querySelector('.op-task-progress');
        if (t.progress && head && head.textContent !== t.progress.header) head.textContent = t.progress.header;
        const batch = card.querySelector('.op-batch');
        const batchHtml = t.progress ? batchMarkup(t.progress) : '';
        if (batch && batch.dataset.sig !== batchSig(t.progress)) { batch.outerHTML = batchHtml; paintVars(card); }
        const stop = card.querySelector('.op-task-stop');
        const stopHtml = stopMarkup(t);
        if (stop && stop.outerHTML !== stopHtml) stop.outerHTML = stopHtml;
        card.querySelector('[data-live]')?.setAttribute('data-base', String(t.durationMs));
      });
      tick();
      return;
    }
    running.dataset.ids = ids;
    running.innerHTML = open.length
      ? open.map((t, n) => taskCard(t, n)).join('')
      : `<div class="op-running-empty">${emptyState('check', 'Aucune tâche en cours', 'Le moteur est au repos. Une lecture lancée depuis un écran apparaît ici avec sa durée et son arrêt.')}</div>`;
    paintVars(running);
    tick();
  }

  function visibleRows() {
    const all = [...(snapshot?.recent ?? [])];
    return all.filter((r) => {
      if (!showAutomatic && !r.listed) return false;
      if (!pressed.size) return true;
      return (pressed.has('succeeded') && r.outcome === 'succeeded') || (pressed.has('review') && REVIEW.has(r.outcome))
        || (pressed.has('stopped') && r.outcome === 'stopped') || (pressed.has('writes') && (r.kind === 'write' || r.kind === 'localWrite'));
    });
  }

  function paint() {
    if (!snapshot) return;
    const base = (snapshot.recent ?? []).filter((r) => showAutomatic || r.listed);
    filters.setFacets(FACETS.map((f) => ({
      ...f,
      pressed: pressed.has(f.id),
      count: base.filter((r) => (f.id === 'succeeded' ? r.outcome === 'succeeded' : f.id === 'review' ? REVIEW.has(r.outcome) : f.id === 'stopped' ? r.outcome === 'stopped' : r.kind === 'write' || r.kind === 'localWrite')).length,
    })));
    const rows = visibleRows();
    env.pulse?.measure('liste', () => grid.setRows(rows, { keepSelection: true, keepScroll: true }));
    const hidden = (snapshot.recent?.length ?? 0) - base.length;
    filters.setSummary(`${count(rows.length, 'opération affichée', 'opérations affichées')}${hidden > 0 ? ` · ${count(hidden, 'lecture automatique masquée', 'lectures automatiques masquées')}` : ''}`);
  }

  /** Live durations of the tasks in progress (cards and open panel), between two reads of the engine. */
  function tick() {
    const extra = performance.now() - receivedAt;
    running.querySelectorAll('[data-live]').forEach((el) => {
      const base = Number(el.dataset.base);
      el.textContent = duration(base + extra);
    });
    drawer?.body?.querySelectorAll('[data-live-trace]').forEach((el) => {
      const base = Number(el.dataset.base);
      el.textContent = `${duration(base + extra)} (en cours)`;
    });
  }
  const ticker = setInterval(() => { if (alive) tick(); }, 1000);

  // ---------------------------------------------------------------- actions

  async function stopTask(id, button) {
    if (demo) { toast(`Exemple local${NBSP}: rien n’est arrêté.`, { tone: 'info' }); return; }
    button?.setAttribute('aria-busy', 'true');
    try {
      const row = await env.onStop(id);
      toast(`Arrêt demandé${NBSP}: ${row.label}. Ce n’est pas encore une annulation confirmée${NBSP}; la lecture se termine d’elle-même.`, { tone: 'warn', life: 6000 });
      announce('Arrêt demandé.');
    } catch (err) {
      console.error(err);
      toast(errorText(err, 'Arrêt impossible.'), { tone: 'alert', life: 6500 });
      button?.removeAttribute('aria-busy');
    }
  }

  function findTask(id) {
    return [...(snapshot?.open ?? []), ...(snapshot?.recent ?? [])].find((t) => t.id === id) ?? null;
  }

  function openTrace(id) {
    const task = findTask(id);
    if (!task) return null;
    drawerId = id;
    drawerSig = traceSig(task);
    drawer = env.pulse ? env.pulse.measure('panneau', () => open(task)) : open(task);
    bindTrace();
    return drawer;
  }

  function open(task) {
    return openDrawer({
      title: task.label,
      subtitle: `${task.kindLabel} · Réf. ${task.reference}`,
      icon: KIND_ICONS[task.kind] ?? 'activity',
      key: 'operations.tache',
      width: 620, minWidth: 440, maxWidth: 980,
      body: traceMarkup(task, false),
      actions: [
        { id: 'close', label: 'Fermer', run: (p) => p.close() },
        { id: 'copy', label: 'Copier le détail', icon: 'copy', run: () => copyTrace(findTask(drawerId) ?? task) },
      ],
      onClose: () => { drawer = null; drawerId = null; drawerSig = ''; },
    });
  }

  function bindTrace() {
    const body = drawer?.body;
    if (!body) { setTimeout(() => { if (drawer?.body) bindTrace(); }, 150); return; }
    paintVars(body);
    body.querySelector('[data-trace-stop]')?.addEventListener('click', (e) => stopTask(drawerId, e.currentTarget));
    body.querySelector('[data-trace-receipts]')?.addEventListener('click', () => { drawer?.close(); ctx.navigate('operations', { onglet: 'recus', filtre: 'a-verifier' }); });
    tick();
  }

  // The panel is drawn again only when the task itself changed (state, end, phases, advice): a running task keeps its markup and
  // only its live duration moves; a finished one never moves again. The focused control and the scroll are kept.
  function refreshTrace() {
    const task = findTask(drawerId);
    if (!task || !drawer?.body) return;
    const sig = traceSig(task);
    if (sig === drawerSig) {
      drawer.body.querySelectorAll('[data-live-trace]').forEach((el) => el.setAttribute('data-base', String(task.durationMs)));
      tick();
      return;
    }
    drawerSig = sig;
    const body = drawer.body;
    const focused = body.contains(document.activeElement) ? document.activeElement?.getAttribute('data-focus-key') : null;
    const scroll = body.scrollTop;
    body.innerHTML = traceMarkup(task, true);
    bindTrace();
    body.scrollTop = scroll;
    if (focused) body.querySelector(`[data-focus-key="${CSS.escape(focused)}"]`)?.focus({ preventScroll: true });
    announce(`${task.label}${NBSP}: ${task.stateLabel}.`);
  }

  function copyTrace(task) {
    if (!task) return;
    const lines = [
      `${task.label} (${task.operation}) · Réf. ${task.reference}`,
      `${task.stateLabel} · ${task.kindLabel} · ${fullDate(task.startedAt)} · ${task.durationText}`,
      task.text,
      task.advice ?? task.next ?? '',
      task.access,
    ].filter(Boolean);
    writeClipboard(maskSecrets(lines.join('\r\n'))).then((ok) => toast(ok
      ? `Détail de l’opération copié. Le nom d’une cible peut y figurer${NBSP}: relisez avant tout envoi.`
      : `Copie impossible${NBSP}: le presse-papiers est indisponible.`, { tone: ok ? 'ok' : 'warn' }));
  }

  return {
    update,
    openTrace: (id) => openTrace(id ?? snapshot?.recent?.find((r) => r.listed)?.id ?? snapshot?.open?.[0]?.id),
    destroy() {
      alive = false;
      clearInterval(ticker);
      drawer?.close();
      grid.destroy();
      filters.destroy?.();
    },
  };
}

// ---------------------------------------------------------------- markup

/** What makes the panel of a task change (its duration alone does not: it moves live). */
function traceSig(t) {
  return JSON.stringify([t.state, t.outcome, t.stateLabel, t.canStop, t.stopReason, t.advice, t.next, t.volume, t.dropped, t.category,
    (t.phases ?? []).map((p) => [p.phase, p.label, p.durationMs, p.measured, p.detail]), t.progress ? batchSig(t.progress) : null]);
}

function batchSig(p) {
  return p ? [p.done, p.total, p.failed, p.pingErrors, p.inFlight, p.pendingSaves, p.skipped, (p.steps ?? []).map((s) => s.state).join('')].join('|') : '';
}

function statePill(t) {
  const spin = t.state === 'running';
  return `<span class="op-task-state">${pill(t.tone, t.stateLabel, { spin, icon: spin ? undefined : t.icon, size: 'sm', pulse: t.state === 'stopRequested' })}</span>`;
}

function stopMarkup(t) {
  return t.canStop
    ? `<span class="op-task-stop"><button class="btn sm subtle" type="button" data-stop="${esc(t.id)}" aria-keyshortcuts="Delete">${glyph('pause')}Arrêter</button></span>`
    : `<span class="op-task-stop op-task-nostop" data-tip="${esc(t.stopReason ?? '')}">${glyph('lock')}${esc(t.kind === 'write' ? 'Non annulable' : t.state === 'stopRequested' ? 'Arrêt demandé' : 'Sans arrêt')}</span>`;
}

/** Phases of a collection batch and its counters (Domenia 1 OPE-017). */
function batchMarkup(p) {
  const steps = (p.steps ?? []).map((s, n) => `<li data-state="${esc(s.state)}" data-i="${n}"><span class="op-batch-dot" aria-hidden="true">${s.state === 'done' ? glyph('check') : ''}</span><span>${esc(s.label)}</span></li>`).join('');
  const counters = [
    ['Non confirmés', p.failed], ['Erreurs de ping', p.pingErrors], ['En cours', p.inFlight], ['Enregistrements en attente', p.pendingSaves], ['Non relus faute de capacité', p.skipped],
  ].map(([label, value]) => `<li data-zero="${Number(value) === 0}"><b>${esc(Number.isFinite(value) && value >= 0 ? int(value) : 'Non mesuré')}</b><span>${esc(label)}</span></li>`).join('');
  return `<div class="op-batch" data-sig="${esc(batchSig(p))}"><ol class="op-batch-steps" aria-label="Phases du lot">${steps}</ol><ul class="op-batch-counters" aria-label="Compteurs du lot">${counters}</ul></div>`;
}

function taskCard(t, n) {
  const measured = t.progress && t.progress.done >= 0 && t.progress.total >= 0;
  const progress = t.progress
    ? `${measured ? `<div class="op-task-bar determinate" role="progressbar" aria-label="${esc(t.label)}" aria-valuemin="0" aria-valuemax="${t.progress.total}" aria-valuenow="${t.progress.done}"><i data-p="${t.progress.total ? (t.progress.done / t.progress.total).toFixed(3) : '0'}"></i></div>`
      : '<div class="op-task-bar indeterminate" aria-hidden="true"><i></i></div>'}
       <span class="op-task-progress">${esc(t.progress.header)}</span>${batchMarkup(t.progress)}`
    : '<div class="op-task-bar indeterminate" aria-hidden="true"><i></i></div>';
  return `<article class="op-task" data-id="${esc(t.id)}" data-kind="${esc(t.kind)}" data-state="${esc(t.state)}" data-i="${n}" tabindex="0" aria-label="${esc(`${t.label}, ${t.stateLabel}`)}">
    <span class="op-task-glow" aria-hidden="true"></span>
    <header class="op-task-head"><span class="op-task-ico" aria-hidden="true">${glyph(KIND_ICONS[t.kind] ?? 'activity')}<i></i></span>
      <div class="op-task-titles"><b>${esc(t.label)}</b><span>${esc(t.kindLabel)} · Réf. <span class="mono">${esc(t.reference)}</span></span></div>
      <span class="op-task-time" data-live data-base="${t.durationMs}">${esc(t.durationText)}</span></header>
    ${progress}
    <p class="op-task-detail">${esc(t.detail)}</p>
    <footer class="op-task-foot">${statePill(t)}<button class="btn ghost xs" type="button" data-open="${esc(t.id)}">${glyph('eye')}Étapes</button>${stopMarkup(t)}</footer>
  </article>`;
}

/**
 * The panel of a task: its state, the facts, the phases in time order drawn to scale (request, wait of the write channel, stages
 * or processing, publication in the interface, end), the total and the volume given apart, the next step, the access required.
 * `settled`: drawn again after a change, without the entrance animations.
 */
function traceMarkup(t, settled) {
  const open = t.state !== 'completed';
  const total = Math.max(1, t.durationMs);
  const bars = (t.phases ?? []).map((p, n) => {
    const start = Math.max(0, Math.min(1, (p.atMs ?? 0) / total));
    const width = p.durationMs != null ? Math.max(0.012, Math.min(1 - start, p.durationMs / total)) : 0;
    const kind = p.phase === 'end' ? 'end' : p.phase === 'request' ? 'request' : p.phase === 'publish' ? 'publish' : p.measured ? 'measured' : 'open';
    const track = p.phase === 'end' || p.phase === 'request' || p.phase === 'publish'
      ? `<i class="op-wf-tick" data-x="${start.toFixed(4)}"></i>`
      : kind === 'open'
        ? '<i class="op-wf-bar op-wf-run" data-x="0" data-w="1"></i>'
        : `<i class="op-wf-bar" data-x="${start.toFixed(4)}" data-w="${width.toFixed(4)}"></i>`;
    const time = kind === 'open' && p.phase === 'work' ? `<span class="op-wf-time" data-live-trace data-base="${t.durationMs}">${esc(p.durationText)}</span>` : `<span class="op-wf-time">${esc(p.durationText)}</span>`;
    return `<li class="op-wf-row" data-kind="${kind}" data-i="${n}">
      <span class="op-wf-label">${p.phase === 'end' ? `Fin<small>${esc(t.outcomeLabel ?? '')}</small>` : `${esc(p.label)}${p.detail ? `<small>${esc(p.detail)}</small>` : ''}`}</span>
      <span class="op-wf-track" aria-hidden="true">${track}</span>${time}</li>`;
  }).join('');
  const next = t.advice ?? t.next;
  const nextBlock = next ? `<section class="op-advice" data-tone="${esc(t.advice ? t.tone : 'info')}"><span class="op-advice-ico" aria-hidden="true">${glyph(t.advice ? (t.tone === 'ok' ? 'check' : 'info') : 'chevronRight')}</span><div><h4>Suite possible</h4><p>${esc(next)}</p></div></section>` : '';
  const write = t.kind === 'write' && (t.outcome === 'unknown' || open);
  const totalText = open ? `<b data-live-trace data-base="${t.durationMs}">${esc(t.durationText)} (en cours)</b>` : `<b>${esc(t.durationText)}</b>`;
  return `<div class="op-trace" data-page="operations"${settled ? ' data-settled="true"' : ''}>
    <div class="op-trace-top">${toneMark(t.tone, t.icon)}<div><b>${esc(t.stateLabel)}</b><span>${esc(t.detail)}</span></div></div>
    <div class="op-trace-totals">
      <div><span>Total</span>${totalText}<small>${open ? 'mesuré dans le moteur, en cours' : 'mesuré dans le moteur'}</small></div>
      <div><span>Volume</span><b>${esc(t.volumeText ?? '—')}</b><small>${t.volume == null ? 'non mesuré' : open ? 'au moins, à ce stade' : 'éléments rendus'}</small></div>
      <div><span>Étape dominante</span><b>${esc(t.dominantLabel ?? '—')}</b><small>${t.dominantMs != null ? esc(duration(t.dominantMs)) : 'aucune étape mesurée'}</small></div>
    </div>
    <section class="op-wf" aria-label="Étapes dans l’ordre"><h4>Étapes de l’opération</h4><ol class="op-wf-list">${bars}</ol>
      <p class="op-wf-note">Dessinées à l’échelle du total, dans l’ordre${NBSP}; une étape non mesurée est dite non mesurée, jamais comptée comme nulle.</p></section>
    ${nextBlock}
    <dl class="op-facts">
      <div><dt>Début</dt><dd>${esc(fullDate(t.startedAt))}</dd></div>
      <div><dt>${open ? 'Durée en cours' : 'Fin'}</dt><dd>${esc(t.endedAt ? fullDate(t.endedAt) : t.durationText)}</dd></div>
      <div><dt>Référence</dt><dd class="mono">${esc(t.reference)}${t.category ? ` · ${esc(t.category)}` : ''}</dd></div>
      <div><dt>Opération</dt><dd class="mono">${esc(t.operation)}</dd></div>
    </dl>
    <p class="op-trace-access">${glyph('key')}<span>${esc(t.access)}</span></p>
    <p class="op-trace-text mono">${esc(t.text)}</p>
    <div class="op-trace-actions">
      ${t.canStop ? `<button class="btn subtle sm" type="button" data-trace-stop data-focus-key="stop">${glyph('pause')}Arrêter cette lecture</button>` : ''}
      ${write ? `<button class="btn subtle sm" type="button" data-trace-receipts data-focus-key="receipts">${glyph('shield')}Ouvrir les reçus à vérifier</button>` : ''}
    </div>
  </div>`;
}
