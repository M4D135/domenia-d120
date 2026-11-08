// Tasks of the screens shown in the reserved strip of the top bar (TRV-049, TRV-053; Domenia 1 Get-DomeniaActivityStripSlots,
// BtnCancelTask, LblTaskElapsed, PbTop): the progress of the first task (determinate when the screen knows it), its elapsed
// time, and « Annuler » when the screen gave a way to stop it. A stop asked is not a confirmed cancellation: the task says
// « Arrêt demandé » until its screen ends it. Nothing here reads or writes: the screen does the work and reports.
import { emit } from './store.js';

const tasks = [];
let seq = 0;
const priorities = { write: 0, explicit: 1, selection: 2, background: 3 };

/** Tasks in progress, priority then newest first: { id, label, started, progress, detail, cancellable, stopping, screen }. */
export function runningTasks() { return [...tasks].sort((a, b) => priorities[a.priority] - priorities[b.priority] || b.id - a.id).map((t) => ({ ...t })); }
export function activityStripTasks() { return runningTasks().filter((t) => t.priority !== 'background'); }

/** « 0:07 », « 2:15 », « 1:02:03 » (elapsed time of the strip, Domenia 1 LblTaskElapsed). */
export function elapsedText(ms) {
  const s = Math.max(0, Math.floor(Number(ms) / 1000) || 0);
  const h = Math.floor(s / 3600);
  const m = Math.floor((s % 3600) / 60);
  const sec = String(s % 60).padStart(2, '0');
  return h > 0 ? `${h}:${String(m).padStart(2, '0')}:${sec}` : `${m}:${sec}`;
}

/** Share of a progress, bounded to 0..1; null when unknown (the ring turns instead of filling). */
export function progressShare(value) {
  const n = Number(value);
  return value === null || value === undefined || !Number.isFinite(n) ? null : Math.max(0, Math.min(1, n));
}

function changed() { emit('tasks', runningTasks()); }

/**
 * Starts a task shown in the strip.
 * @param {{ label: string, cancel?: () => unknown, screen?: string }} o
 * @returns {{ progress: (share: number|null, detail?: string) => void, end: () => void, stopping: () => boolean }}
 */
export function beginTask({ label, cancel, screen = '', priority = 'explicit' } = {}) {
  if (!Object.hasOwn(priorities, priority)) priority = 'explicit';
  const t = {
    id: ++seq, label: String(label ?? 'Tâche').slice(0, 80), started: Date.now(), progress: null, detail: '',
    cancellable: priority !== 'write' && typeof cancel === 'function', stopping: false, screen, cancel, priority,
  };
  tasks.push(t);
  changed();
  return {
    progress(share, detail = '') {
      if (!tasks.includes(t)) return;
      t.progress = progressShare(share);
      t.detail = String(detail ?? '').slice(0, 120);
      changed();
    },
    end() {
      const at = tasks.indexOf(t);
      if (at < 0) return;
      tasks.splice(at, 1);
      changed();
    },
    stopping: () => t.stopping,
  };
}

/** Stops only the task actually presented in the strip. A write or pending stop must not cancel a different read. */
export function stopFirstTask() {
  const first = activityStripTasks()[0];
  const t = first && tasks.find((x) => x.id === first.id);
  if (!t?.cancellable || t.stopping) return false;
  t.stopping = true;
  changed();
  try { t.cancel?.(); } catch (err) { console.error(err); }
  return true;
}

/** Production adapter: start/end notifications are correlated by the bridge to an outstanding request. */
export function followBridgeTasks(onEvent, call, reportError = console.error) {
  const observed = new Map();
  const shared = new Map();
  const offStart = onEvent('bridge.task.started', (value, requestId) => {
    if (observed.has(requestId)) return;
    let group = shared.get(value.taskId);
    if (!group) {
      group = { requests: new Set(), handle: beginTask({ label: value.label, priority: value.priority, screen: value.operation.split('.')[0],
        cancel: value.cancellable === true && value.priority !== 'write'
          ? () => Promise.resolve(call('operations.task.stop', { id: value.taskId })).catch(reportError) : undefined }) };
      shared.set(value.taskId, group);
    }
    group.requests.add(requestId); observed.set(requestId, value.taskId);
  });
  const offEnd = onEvent('bridge.task.ended', (_, requestId) => {
    const taskId = observed.get(requestId); const group = shared.get(taskId); observed.delete(requestId);
    if (!group) return;
    group.requests.delete(requestId);
    if (group.requests.size === 0) { group.handle.end(); shared.delete(taskId); }
  });
  return () => { offStart(); offEnd(); shared.forEach((g) => g.handle.end()); observed.clear(); shared.clear(); };
}
