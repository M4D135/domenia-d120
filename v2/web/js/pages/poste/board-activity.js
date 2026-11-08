// Follow actual calls only. Adding, moving or showing a card never initiates a remote read.
const kinds = new Map([
  ['poste.inventory', 'inventory'], ['poste.software', 'software'], ['poste.probes.collect', 'probes'],
]);
const sameTarget = (a, b) => typeof a === 'string' && a.trim().length > 0 && typeof b === 'string'
  && a.trim().toUpperCase() === b.trim().toUpperCase();

export function createPosteReadActivity(call, publish) {
  let alive = true;
  const active = new Set();
  const changed = () => {
    if (!alive) return;
    try { publish([...active]); } catch { console.warn('Suivi de lecture du poste indisponible.'); }
  };
  return {
    async call(operation, args) {
      const kind = kinds.get(operation);
      if (!alive || !kind || typeof args?.dn !== 'string' || !args.dn.trim()) return call(operation, args);
      const entry = { dn: args.dn, kind, probes: Array.isArray(args.probes) ? [...args.probes] : null };
      active.add(entry); changed();
      try { return await call(operation, args); }
      finally { active.delete(entry); changed(); }
    },
    destroy() { alive = false; active.clear(); },
  };
}

export function boardActivity(item, board, state) {
  if (item.paused || item.source === 'query') return '';
  // Locally observed calls retain their exact probe list. A generic engine "probes" row cannot
  // establish that a given card's probe was requested, so it is never copied onto every probe card.
  const own = (state.reading ?? []).filter(row => sameTarget(row.dn, state.dn));
  const running = (state.running ?? []).filter(row => sameTarget(row.dn, state.dn));
  if (item.source === 'probe') {
    return own.some(row => row.kind === 'probes' && row.probes?.includes(item.key))
      ? 'Sonde WMI du poste en cours · dernières valeurs conservées' : '';
  }
  if (board === 'Software') return own.some(row => row.kind === 'software')
    ? 'Lecture des logiciels de ce poste en cours · dernières valeurs conservées' : '';
  if (item.key === 'computer.adaccount' || item.key.startsWith('computer.ad.')) return '';
  return [...own, ...running].some(row => row.kind === 'inventory')
    ? 'Inventaire WMI de ce poste en cours · dernières valeurs conservées' : '';
}
