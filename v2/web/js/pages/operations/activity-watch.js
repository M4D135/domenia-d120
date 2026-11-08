// Activity reads must not wake themselves through their own bridge notifications.
const inspections = new Set(['shell.activity', 'operations.activity', 'operations.center', 'operations.queue.read']);
export const activityInspection = (operation) => inspections.has(operation);

export function watchActivity(onEvent) {
  let dirty = false;
  const task = (event) => { if (!activityInspection(event?.operation)) dirty = true; };
  const queue = (event) => { if (!activityInspection(event?.operation) && !event?.operation?.startsWith('operations.')) dirty = true; };
  // Local inspections have no tracked task; actual diagnostics/writes from this screen still wake the follow-up.
  const offs = [onEvent('bridge.task.started', task), onEvent('bridge.task.ended', task), onEvent('bridge.queue.changed', queue)];
  return { needed: (active = false) => dirty || active, acknowledge: () => { dirty = false; },
    retry: () => { dirty = true; }, dispose: () => offs.forEach((off) => off()) };
}
