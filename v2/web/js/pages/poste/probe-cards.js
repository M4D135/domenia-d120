// Detailed probe widgets use the actual stored probe rows. Only active rendered cards request a local page;
// duplicates share it, at most two reads run together, and a removed/paused card never starts a queued read.
import { esc, ico, cardHead, errorText } from './common.js';
import { createPersonalProbeReads } from './personal-probe-reads.js';

function values(r, visual) {
  if (!r.rows.length) return `<p class="ps-faint">${r.status?.state === 'read' ? 'Aucune instance dans ce relevé.' : 'Aucune valeur disponible dans le cache.'}</p>`;
  const text = (row) => r.columns.map((name, n) => `${name} : ${row[n] ?? 'Non lu'}`).join(' · ');
  if (visual === 'Kpi') return `<p class="ps-layout-number">${esc(text(r.rows[0]))}</p>${r.total > 1 ? `<p>${r.total} lignes conservées ; première ligne affichée. La présentation Tableau montre toutes les valeurs de la page.</p>` : ''}`;
  if (visual === 'Text') return `<ol>${r.rows.map((row) => `<li>${esc(text(row))}</li>`).join('')}</ol>`;
  return `<div class="ps-probe-widget-table"><table><thead><tr>${r.columns.map((c) => `<th scope="col">${esc(c)}</th>`).join('')}</tr></thead>
    <tbody>${r.rows.map((row) => `<tr>${r.columns.map((_, n) => `<td>${esc(row[n] ?? 'Non lu')}</td>`).join('')}</tr>`).join('')}</tbody></table></div>`;
}

export function createProbeCards(host, state) {
  let alive = true;
  let entries = new Map();
  let busy = 0;
  let batch = { queue: [] };
  const slots = (key) => [...host.querySelectorAll('[data-probe-card]')].filter((n) => n.dataset.probeCard === key);
  const card = (key, title, visual = 'Table', widget = '') => {
    const e = entries.get(key);
    const r = e?.result;
    let body = '<p role="status">Lecture des valeurs locales…</p>';
    if (e?.error) body = `<p role="alert">${esc(e.error)}</p><button class="btn sm" type="button" data-probe-retry="${esc(key)}">Relire le cache</button>`;
    else if (r) {
      body = `<p>${esc(r.statusLabel)} · ${esc(r.provenance)}</p>
        ${values(r, visual)}
        <p class="ps-faint">${esc(r.probe.limitations)} ${esc(r.probe.unknownMeaning)}</p>
        <div class="ps-row-actions"><span>${esc(String(r.total))} ligne(s) conservée(s) · page ${r.page} / ${r.pages}</span>
          ${r.pages > 1 ? `<button class="btn xs" type="button" data-probe-page="${r.page - 1}" data-probe-key="${esc(key)}"${r.page <= 1 ? ' disabled' : ''}>Précédente</button><button class="btn xs" type="button" data-probe-page="${r.page + 1}" data-probe-key="${esc(key)}"${r.page >= r.pages ? ' disabled' : ''}>Suivante</button>` : ''}
          <button class="btn xs" type="button" data-probe-retry="${esc(key)}">${ico('refresh')}Relire le cache</button>
          <button class="btn xs" type="button" data-route="releves">Sondes et relevés</button></div>`;
    }
    return `<section class="card ps-card" data-probe-card="${esc(key)}" data-probe-title="${esc(title)}" data-probe-visual="${esc(visual)}" data-probe-widget="${esc(widget)}">${cardHead('filter', title, 'Sonde du catalogue · cache local')}${body}${personal.actions(key, widget)}</section>`;
  };
  const paint = (key) => {
    if (!alive) return;
    for (const slot of slots(key)) slot.outerHTML = card(key, slot.dataset.probeTitle, slot.dataset.probeVisual, slot.dataset.probeWidget);
  };
  function drain(current) {
    while (alive && current === batch && busy < 2 && current.queue.length) {
      const [key, entry] = current.queue.shift();
      if (entries.get(key) !== entry) continue;
      if (!slots(key).length) { entries.delete(key); continue; }
      busy++;
      Promise.resolve().then(() => {
        if (!alive || current !== batch || entries.get(key) !== entry || !slots(key).length) return null;
        return state.call('poste.layout.probe', { dn: state.dn, computer: state.data.computer.guid, probe: key, page: entry.page });
      })
        .then((result) => { if (entries.get(key) === entry) entry.result = result; },
          (err) => { if (entries.get(key) === entry) entry.error = errorText(err); })
        .finally(() => { busy--; if (current === batch && entries.get(key) === entry) paint(key); drain(batch); });
    }
  }
  function refresh() {
    if (!alive) return;
    personal.refresh();
    const active = new Set([...host.querySelectorAll('[data-probe-card]')].map((n) => n.dataset.probeCard));
    for (const key of entries.keys()) if (!active.has(key)) entries.delete(key);
    for (const key of active) {
      if (entries.has(key)) continue;
      const entry = { page: 1 };
      entries.set(key, entry); batch.queue.push([key, entry]);
    }
    drain(batch);
  }
  const reload = (key, page = 1) => {
    const entry = { page };
    entries.set(key, entry); batch.queue.push([key, entry]); paint(key); drain(batch);
  };
  const personal = createPersonalProbeReads(host, state, {
    changed: () => { for (const key of new Set([...host.querySelectorAll('[data-probe-card]')].map(node => node.dataset.probeCard))) paint(key); },
    reload, isAlive: () => alive,
  });
  const clicked = (e) => {
    const button = e.target instanceof Element ? e.target.closest('[data-probe-retry],[data-probe-page]') : null;
    if (!button || button.disabled || !host.contains(button)) return;
    const key = button.dataset.probeRetry ?? button.dataset.probeKey;
    reload(key, Number(button.dataset.probePage ?? entries.get(key)?.result?.page ?? 1));
  };
  host.addEventListener('click', clicked);
  return { render: (item, title) => card(item.key, title, item.visual, item.id), refresh,
    invalidate() { entries = new Map(); batch = { queue: [] }; },
    destroy() { alive = false; personal.destroy(); entries.clear(); batch.queue.length = 0; host.removeEventListener('click', clicked); } };
}
