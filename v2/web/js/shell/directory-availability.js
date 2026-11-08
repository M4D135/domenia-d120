// Only session.info's native LDAP observations describe reachability. Errors from other providers and successful
// cache reads carry no evidence; they never clear an outage or turn a workstation timeout into a directory fault.
export function nativeDirectoryReach(session) {
  const observation = session?.directoryAvailability;
  const name = observation?.state;
  const at = typeof observation?.observedAt === 'string' ? Date.parse(observation.observedAt) : NaN;
  if (!['online', 'slow', 'offline'].includes(name) || !Number.isFinite(at))
    return { offline: false, slow: false, since: null, observed: false, notice: null };
  return { offline: name === 'offline', slow: name === 'slow', since: name === 'offline' ? at : null, observed: true,
    notice: typeof observation.notice === 'string' && observation.notice.length <= 600 ? observation.notice : null };
}

const directoryFamilies = new Set(['accounts', 'accueil', 'assistance', 'directory', 'fiche', 'machine', 'poste', 'relations', 'requetes', 'schema', 'search', 'synchro']);
export function mayObserveDirectory(operation) {
  if (typeof operation !== 'string') return false;
  return directoryFamilies.has(operation.split('.')[0]) || ['session.connect', 'dashboard.widget.refresh', 'write.execute', 'write.verify'].includes(operation);
}

// A UI operation finishing requests a local status read, never a reconnect, ping or AD query. Overlapping operations
// coalesce; a completion during that read permits one fresh read afterwards. No interval and no retry on failure.
export function followDirectoryAvailability(readSession, report = () => {}) {
  let pending = null, dirty = false;
  function start() {
    pending = Promise.resolve().then(async () => {
      while (dirty) {
        dirty = false;
        try { await readSession(); }
        catch (error) { try { report(error); } catch { /* Optional diagnosis must not affect the completed operation. */ } }
      }
    }).finally(() => { pending = null; if (dirty) start(); });
  }
  return {
    completed(operation) {
      if (!mayObserveDirectory(operation)) return;
      dirty = true;
      if (!pending) start();
    },
  };
}
