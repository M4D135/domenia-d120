// Only local packaged modules. Importing validates a page; it never calls render or a data provider.
const routeId = /^[a-z0-9]+(?:-[a-z0-9]+)*$/;
export function validatePages(pages) {
  if (!Array.isArray(pages) || !pages.length || pages.length > 64) throw new Error('Inventaire des écrans invalide.');
  const ids = new Set();
  for (const page of pages) {
    if (typeof page?.id !== 'string' || page.id.length > 64 || !routeId.test(page.id) || ids.has(page.id) || typeof page.label !== 'string' || !page.label.trim())
      throw new Error('Déclaration d’écran invalide ou répétée.');
    ids.add(page.id);
  }
  return ids;
}

export function createPageLoader(importPage = id => import(`../pages/${id}.js`)) {
  const accepted = new Map();
  return function load(id) {
    if (typeof id !== 'string' || id.length > 64 || !routeId.test(id)) return Promise.reject(new Error('Identifiant d’écran invalide.'));
    if (!accepted.has(id)) {
      const pending = Promise.resolve().then(() => importPage(id)).then(mod => {
        if (typeof mod?.render !== 'function' || (mod.stylesheet !== undefined && typeof mod.stylesheet !== 'boolean'))
          throw new Error(`Écran ${id} : contrat de présentation invalide.`);
        return mod;
      });
      accepted.set(id, pending);
      // Rejected content is never treated as accepted on a subsequent visit.
      pending.catch(() => { if (accepted.get(id) === pending) accepted.delete(id); });
    }
    return accepted.get(id);
  };
}

const critical = ['.shell', '.nav', '.nav-toggle', '.nav-foot', '.topbar', 'main#main', '.sh-activity', '.notif', '.sh-help-btn'];
export function checkShell(host) {
  if (!host) throw new Error('Interface : conteneur principal absent.');
  for (const selector of critical) {
    const found = host.querySelectorAll(selector);
    if (found.length !== 1) throw new Error(`Interface : contrôle critique ${selector} absent ou répété.`);
    const element = found[0];
    if (element.tagName === 'BUTTON' && !element.getAttribute('aria-label')?.trim() && !element.textContent.trim())
      throw new Error(`Interface : contrôle critique ${selector} sans nom accessible.`);
  }
  const ids = new Set();
  for (const element of host.querySelectorAll('[id]')) {
    if (ids.has(element.id)) throw new Error('Interface : identifiant de contrôle répété.');
    ids.add(element.id);
  }
}

// Yield between pages so the first input/navigation wins. No tree, directory or inventory is read.
export async function preparePages(pages, load, { skip, stopped = () => false, yieldTurn = () => new Promise(resolve => setTimeout(resolve, 150)), report = () => {} } = {}) {
  for (const page of pages) {
    if (page.id === skip) continue;
    await yieldTurn();
    if (stopped()) return;
    const start = performance.now();
    try { await load(page.id); report({ id: page.id, ok: true, milliseconds: performance.now() - start }); }
    catch { report({ id: page.id, ok: false, milliseconds: performance.now() - start }); }
  }
}
