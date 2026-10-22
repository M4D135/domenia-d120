// Tasks of the screens shown in the reserved strip of the top bar (TRV-049, TRV-053; Domenia 1 Get-DomeniaActivityStripSlots,
// BtnCancelTask, LblTaskElapsed, PbTop): the progress of the first task (determinate when the screen knows it), its elapsed
// time, and « Annuler » when the screen gave a way to stop it. A stop asked is not a confirmed cancellation: the task says
// « Arrêt demandé » until its screen ends it. Nothing here reads or writes: the screen does the work and reports.
import { emit } from './store.js';

const tasks = [];
let seq = 0;

/** Tasks in progress, oldest first: { id, label, started, progress, detail, cancellable, stopping, screen }. */
export function runningTasks() { return tasks.map((t) => ({ ...t })); }

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
export function beginTask({ label, cancel, screen = '' } = {}) {
  const t = {
    id: ++seq, label: String(label ?? 'Tâche').slice(0, 80), started: Date.now(), progress: null, detail: '',
    cancellable: typeof cancel === 'function', stopping: false, screen, cancel,
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

/** Asks the first cancellable task to stop (« Annuler » of the strip); false when there is none. */
export function stopFirstTask() {
  const t = tasks.find((x) => x.cancellable && !x.stopping);
  if (!t) return false;
  t.stopping = true;
  changed();
  try { t.cancel?.(); } catch (err) { console.error(err); }
  return true;
}
