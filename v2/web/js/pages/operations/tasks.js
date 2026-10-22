// Tab « Tâches » (Domenia 1 OPE-012 to OPE-021): tasks in progress with their live duration, their progress and the stop of a
// read, then the last operations of the session with their end, their dominant phase and their reference, filtered by state;
// a task opens in a panel with its phases drawn as a waterfall, the advice that follows its end and a masked copy of its detail.
// « Arrêt demandé » is not a confirmed cancellation; a write is never stopped; nothing is ever relaunched automatically.
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

const COLUMNS = [
  { id: 'outcome', label: 'État', type: 'enum', width: 165, required: true, get: (r) => r.outcome ?? 'running', options: OUTCOME_OPTIONS },
  { id: 'label', label: 'Opération', width: 222, required: true, html: (v, r) => `<span class="op-cell-task"><span class="op-cell-ico" data-kind="${esc(r.kind)}" aria-hidden="true">${glyph(KIND_ICONS[r.kind] ?? 'activity')}</span><span>${esc(v)}</span></span>` },
  { id: 'kindLabel', label: 'Type', width: 178 },
  { id: 'screen', label: 'Écran', width: 110, hidden: true },
  { id: 'startedAt', label: 'Début', type: 'date', width: 104 },
  { id: 'durationMs', label: 'Durée', type: 'number', width: 100, align: 'end', format: (v) => duration(v), csv: (v) => String(Math.round(v ?? 0)) },
  { id: 'dominantLabel', label: 'Étape dominante', width: 206 },
  { id: 'volume', label: 'Volume', type: 'number', width: 108, align: 'end', format: (v) => (Number.isFinite(v) ? int(v) : '—') },
  { id: 'reference', label: 'Référence', width: 100, mono: true },
  { id: 'operation', label: 'Code de l’opération', width: 230, mono: true, hidden: true },
  { id: 'category', label: 'Code de fin', width: 200, mono: true, hidden: true },
];

/**
 * @param {HTMLElement} host
 * @param {{ ctx: any, demo: boolean, onStop: (id: string) => Promise<any> }} env
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
    height: '440px',
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
    liveLabel.innerHTML = `${glyph('activity')}${esc(snapshot.summary.text)}<span class="op-sec-res">${esc(snapshot.summary.resourcesText)}</span>`;
    const ids = open.map((t) => t.id).join('|');
    if (running.dataset.ids === ids) {
      // Same tasks (or still none): update in place (selection, focus and animations are kept).
      open.forEach((t) => {
        const card = running.querySelector(`.op-task[data-id="${CSS.escape(t.id)}"]`);
        if (!card) return;
        card.dataset.state = t.state;
        card.querySelector('.op-task-state').outerHTML = statePill(t);
        card.querySelector('.op-task-detail').textContent = t.detail;
        const bar = card.querySelector('.op-task-bar i');
        if (t.progress && bar) bar.style.setProperty('--p', String(t.progress.total ? t.progress.done / t.progress.total : 0));
        const head = card.querySelector('.op-task-progress');
        if (t.progress && head) head.textContent = t.progress.header;
        const stop = card.querySelector('.op-task-stop');
        if (stop) stop.outerHTML = stopMarkup(t);
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
    grid.setRows(rows, { keepSelection: true, keepScroll: true });
    const hidden = (snapshot.recent?.length ?? 0) - base.length;
    filters.setSummary(`${count(rows.length, 'opération affichée', 'opérations affichées')}${hidden > 0 ? ` · ${count(hidden, 'lecture automatique masquée', 'lectures automatiques masquées')}` : ''}`);
  }

  /** Live durations of the tasks in progress, between two reads of the engine. */
  function tick() {
    const extra = performance.now() - receivedAt;
    running.querySelectorAll('[data-live]').forEach((el) => {
      const base = Number(el.dataset.base);
      el.textContent = duration(base + extra);
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
    if (!task) return;
    drawerId = id;
    drawer = openDrawer({
      title: task.label,
      subtitle: `${task.kindLabel} · Réf. ${task.reference}`,
      icon: KIND_ICONS[task.kind] ?? 'activity',
      key: 'operations.tache',
      width: 600, minWidth: 440, maxWidth: 980,
      body: traceMarkup(task),
      actions: [
        { id: 'close', label: 'Fermer', run: (p) => p.close() },
        { id: 'copy', label: 'Copier le détail', icon: 'copy', run: () => copyTrace(findTask(drawerId) ?? task) },
      ],
      onClose: () => { drawer = null; drawerId = null; },
    });
    bindTrace();
    return drawer;
  }

  function bindTrace() {
    const body = drawer?.body;
    if (!body) { setTimeout(() => { if (drawer?.body) bindTrace(); }, 150); return; }
    paintVars(body);
    body.querySelector('[data-trace-stop]')?.addEventListener('click', (e) => stopTask(drawerId, e.currentTarget));
    body.querySelector('[data-trace-receipts]')?.addEventListener('click', () => { drawer?.close(); ctx.navigate('operations', { onglet: 'recus', filtre: 'a-verifier' }); });
  }

  function refreshTrace() {
    const task = findTask(drawerId);
    if (!task || !drawer?.body) return;
    drawer.body.innerHTML = traceMarkup(task);
    bindTrace();
  }

  function copyTrace(task) {
    if (!task) return;
    const lines = [
      `${task.label} (${task.operation}) · Réf. ${task.reference}`,
      `${task.stateLabel} · ${task.kindLabel} · ${fullDate(task.startedAt)} · ${task.durationText}`,
      task.text,
      task.advice ?? '',
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

function statePill(t) {
  const spin = t.state === 'running';
  return `<span class="op-task-state">${pill(t.tone, t.stateLabel, { spin, icon: spin ? undefined : t.icon, size: 'sm', pulse: t.state === 'stopRequested' })}</span>`;
}

function stopMarkup(t) {
  return t.canStop
    ? `<span class="op-task-stop"><button class="btn sm subtle" type="button" data-stop="${esc(t.id)}" aria-keyshortcuts="Delete">${glyph('pause')}Arrêter</button></span>`
    : `<span class="op-task-stop op-task-nostop" data-tip="${esc(t.stopReason ?? '')}">${glyph('lock')}${esc(t.kind === 'write' ? 'Non annulable' : t.state === 'stopRequested' ? 'Arrêt demandé' : 'Sans arrêt')}</span>`;
}

function taskCard(t, n) {
  const progress = t.progress
    ? `<div class="op-task-bar determinate" role="progressbar" aria-label="${esc(t.label)}" aria-valuemin="0" aria-valuemax="${t.progress.total}" aria-valuenow="${t.progress.done}"><i data-p="${t.progress.total ? (t.progress.done / t.progress.total).toFixed(3) : '0'}"></i></div>
       <span class="op-task-progress">${esc(t.progress.header)}</span>`
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

function traceMarkup(t) {
  const total = Math.max(1, t.durationMs);
  const bars = (t.phases ?? []).map((p, n) => {
    const start = Math.max(0, Math.min(1, (p.atMs ?? 0) / total));
    const width = p.durationMs != null ? Math.max(0.012, Math.min(1 - start, p.durationMs / total)) : 0;
    const kind = p.phase === 'end' ? 'end' : p.phase === 'request' ? 'request' : p.measured ? 'measured' : 'open';
    return `<li class="op-wf-row" data-kind="${kind}" data-i="${n}">
      <span class="op-wf-label">${p.phase === 'end' ? `Fin<small>${esc(t.outcomeLabel ?? '')}</small>` : `${esc(p.label)}${p.detail ? `<small>${esc(p.detail)}</small>` : ''}`}</span>
      <span class="op-wf-track" aria-hidden="true">${p.phase === 'end' || p.phase === 'request' ? `<i class="op-wf-tick" data-x="${start.toFixed(4)}"></i>` : `<i class="op-wf-bar" data-x="${start.toFixed(4)}" data-w="${width.toFixed(4)}"></i>`}</span>
      <span class="op-wf-time">${esc(p.durationText)}</span></li>`;
  }).join('');
  const advice = t.advice ? `<p class="op-advice" data-tone="${esc(t.tone)}">${glyph(t.tone === 'ok' ? 'check' : 'info')}<span>${esc(t.advice)}</span></p>` : '';
  const write = t.kind === 'write' && (t.outcome === 'unknown' || t.state !== 'completed');
  return `<div class="op-trace" data-page="operations">
    <div class="op-trace-top">${toneMark(t.tone, t.icon)}<div><b>${esc(t.stateLabel)}</b><span>${esc(t.detail)}</span></div></div>
    <dl class="op-facts">
      <div><dt>Début</dt><dd>${esc(fullDate(t.startedAt))}</dd></div>
      <div><dt>${t.state === 'completed' ? 'Fin' : 'Durée en cours'}</dt><dd>${esc(t.endedAt ? fullDate(t.endedAt) : t.durationText)}</dd></div>
      <div><dt>Durée</dt><dd>${esc(t.durationText)}</dd></div>
      <div><dt>Volume</dt><dd>${esc(t.volumeText ?? '—')}</dd></div>
      <div><dt>Étape dominante</dt><dd>${esc(t.dominantLabel ?? '—')}</dd></div>
      <div><dt>Référence</dt><dd class="mono">${esc(t.reference)}${t.category ? ` · ${esc(t.category)}` : ''}</dd></div>
    </dl>
    <section class="op-wf" aria-label="Étapes mesurées"><h4>Étapes de l’opération</h4><ol class="op-wf-list">${bars}</ol>
      <p class="op-wf-note">Seules les durées mesurées à la source sont dessinées${NBSP}: une étape non mesurée n’est jamais comptée comme nulle.</p></section>
    ${advice}
    <p class="op-trace-access">${glyph('key')}<span>${esc(t.access)}</span></p>
    <p class="op-trace-text mono">${esc(t.text)}</p>
    <div class="op-trace-actions">
      ${t.canStop ? `<button class="btn subtle sm" type="button" data-trace-stop>${glyph('pause')}Arrêter cette lecture</button>` : ''}
      ${write ? `<button class="btn subtle sm" type="button" data-trace-receipts>${glyph('shield')}Ouvrir les reçus à vérifier</button>` : ''}
    </div>
  </div>`;
}
