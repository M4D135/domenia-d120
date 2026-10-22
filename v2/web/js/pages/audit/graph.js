// Audit AD: graph of the nested memberships (improvement of AUD-012, « graphe visuel des imbrications »). Local component of
// the screen (the kit has no graph): one column per depth, the object on the left, curves that draw themselves, privileged
// groups and cycles marked, the path from the object lit on hover or focus. SVG only, classes only (CSP: no style
// attribute in the markup); positions are SVG attributes.
import { esc, applyVars } from '../../ui.js';

const NODE_W = 184;
const NODE_H = 40;
const GAP_X = 58;
const GAP_Y = 14;
const PAD = 16;
const MAX_LABEL = 24;
const MAX_NODES = 160;

const cut = (text) => (text.length > MAX_LABEL ? `${text.slice(0, MAX_LABEL - 1)}…` : text);

/**
 * Renders the graph into host. onPick(id) is called when a group is chosen (click or Enter).
 * @param {HTMLElement} host
 * @param {{ nodes: any[], edges: any[] }} graph
 * @param {{ onPick?: (id: string) => void, label?: string }} [o]
 * @returns {{ destroy: () => void, highlight: (id: string|null) => void }}
 */
export function renderGraph(host, graph, o = {}) {
  const nodes = graph.nodes.slice(0, MAX_NODES);
  const known = new Set(nodes.map((n) => n.id));
  const edges = graph.edges.filter((e) => known.has(e.from) && known.has(e.to));
  const columns = new Map();
  for (const n of nodes) {
    if (!columns.has(n.depth)) columns.set(n.depth, []);
    columns.get(n.depth).push(n);
  }
  const depths = [...columns.keys()].sort((a, b) => a - b);
  depths.forEach((d) => columns.get(d).sort((a, b) => (a.kind === 'primary') - (b.kind === 'primary') || a.label.localeCompare(b.label, 'fr')));
  const rows = Math.max(1, ...depths.map((d) => columns.get(d).length));
  const width = PAD * 2 + depths.length * NODE_W + Math.max(0, depths.length - 1) * GAP_X;
  const height = PAD * 2 + rows * NODE_H + (rows - 1) * GAP_Y;
  const pos = new Map();
  depths.forEach((d, c) => {
    const list = columns.get(d);
    const offset = (rows - list.length) * (NODE_H + GAP_Y) / 2;
    list.forEach((n, r) => pos.set(n.id, { x: PAD + c * (NODE_W + GAP_X), y: PAD + offset + r * (NODE_H + GAP_Y) }));
  });

  const edgeMarkup = edges.map((e, n) => {
    const a = pos.get(e.from);
    const b = pos.get(e.to);
    let d;
    if (b.x > a.x) {
      const x1 = a.x + NODE_W; const y1 = a.y + NODE_H / 2; const x2 = b.x; const y2 = b.y + NODE_H / 2;
      const k = (x2 - x1) * 0.5;
      d = `M${x1},${y1} C${x1 + k},${y1} ${x2 - k},${y2} ${x2},${y2}`;
    } else {
      // A link back to an earlier column (a cycle): an arc under the boxes.
      const x1 = a.x + NODE_W / 2; const y1 = a.y + NODE_H; const x2 = b.x + NODE_W / 2; const y2 = b.y + NODE_H;
      const drop = 34 + Math.abs(x1 - x2) * 0.12;
      d = `M${x1},${y1} C${x1},${y1 + drop} ${x2},${y2 + drop} ${x2},${y2}`;
    }
    return `<path class="gedge draw${e.cycle ? ' cycle' : ''}" d="${d}" data-from="${esc(e.from)}" data-to="${esc(e.to)}" data-i="${n % 18}"/>`;
  }).join('');

  const nodeMarkup = nodes.map((n, i) => {
    const p = pos.get(n.id);
    const cls = ['gnode', n.kind, n.privileged ? 'privileged' : '', n.cycle ? 'cycle' : '', n.unread ? 'unread' : ''].filter(Boolean).join(' ');
    const badge = n.privileged ? '<text class="gbadge" x="172" y="16" text-anchor="end">★</text>' : n.cycle ? '<text class="gbadge" x="172" y="16" text-anchor="end">↻</text>' : '';
    const kind = n.kind === 'start' ? 'Objet audité' : n.kind === 'primary' ? 'Groupe principal' : `Profondeur ${n.depth}${n.privileged ? ' · privilégié' : ''}${n.cycle ? ' · dans un cycle' : ''}`;
    const focusable = n.kind !== 'start';
    return `<g class="${cls}" transform="translate(${p.x},${p.y})" data-id="${esc(n.id)}" data-i="${Math.min(i, 24)}"${focusable ? ' tabindex="0" role="button"' : ''} aria-label="${esc(`${n.label}, ${kind}`)}">
      <title>${esc(`${n.label} · ${kind}`)}</title>
      <rect class="gbox" width="${NODE_W}" height="${NODE_H}" rx="11"/>
      <rect class="gbar" width="4" height="${NODE_H - 16}" x="8" y="8" rx="2"/>
      <text class="glabel" x="20" y="${n.kind === 'start' ? 17 : 25}">${esc(cut(n.label))}</text>
      ${n.kind === 'start' ? `<text class="gsub" x="20" y="31">Objet audité</text>` : ''}${badge}
    </g>`;
  }).join('');

  const reduced = graph.nodes.length > MAX_NODES ? `<p class="aud-graph-note">Graphe réduit aux ${MAX_NODES} premiers groupes : la liste complète est dans le tableau.</p>` : '';
  host.innerHTML = `<div class="aud-graph-scroll"><svg class="aud-graph" viewBox="0 0 ${width} ${height}" width="${width}" height="${height}" role="group" aria-label="${esc(o.label ?? 'Graphe des appartenances')}">
    <g class="gedges">${edgeMarkup}</g><g class="gnodes">${nodeMarkup}</g></svg></div>${reduced}`;
  applyVars(host);
  host.querySelectorAll('.gnode[data-i]').forEach((g) => g.style.setProperty('--i', g.dataset.i));

  // Shortest path from the object to each node (first parent of a breadth-first walk), for the lit path.
  const start = nodes.find((n) => n.kind === 'start')?.id;
  const parent = new Map();
  if (start) {
    const queue = [start];
    const seen = new Set([start]);
    while (queue.length) {
      const cur = queue.shift();
      for (const e of edges) {
        if (e.from !== cur || seen.has(e.to)) continue;
        seen.add(e.to);
        parent.set(e.to, cur);
        queue.push(e.to);
      }
    }
  }
  const svg = host.querySelector('svg');
  function highlight(id) {
    svg.classList.toggle('has-lit', Boolean(id));
    svg.querySelectorAll('.lit').forEach((el) => el.classList.remove('lit'));
    if (!id) return;
    let cur = id;
    let guard = 0;
    while (cur && guard++ < 64) {
      svg.querySelector(`.gnode[data-id="${CSS.escape(cur)}"]`)?.classList.add('lit');
      const p = parent.get(cur);
      if (p) svg.querySelector(`.gedge[data-from="${CSS.escape(p)}"][data-to="${CSS.escape(cur)}"]`)?.classList.add('lit');
      cur = p;
    }
  }
  const nodeOf = (e) => (e.target instanceof Element ? e.target.closest('.gnode[tabindex]') : null);
  const onOver = (e) => { const g = nodeOf(e); highlight(g?.dataset.id ?? null); };
  const onOut = (e) => { if (!nodeOf(e)) return; if (!(e.relatedTarget instanceof Element && e.relatedTarget.closest('.gnode'))) highlight(null); };
  const onClick = (e) => { const g = nodeOf(e); if (g) { highlight(g.dataset.id); o.onPick?.(g.dataset.id); } };
  const onKey = (e) => { const g = nodeOf(e); if (g && (e.key === 'Enter' || e.key === ' ')) { e.preventDefault(); highlight(g.dataset.id); o.onPick?.(g.dataset.id); } };
  const onFocus = (e) => { const g = nodeOf(e); if (g) highlight(g.dataset.id); };
  svg.addEventListener('pointerover', onOver);
  svg.addEventListener('pointerout', onOut);
  svg.addEventListener('click', onClick);
  svg.addEventListener('keydown', onKey);
  svg.addEventListener('focusin', onFocus);
  return {
    highlight,
    destroy() {
      svg.removeEventListener('pointerover', onOver);
      svg.removeEventListener('pointerout', onOut);
      svg.removeEventListener('click', onClick);
      svg.removeEventListener('keydown', onKey);
      svg.removeEventListener('focusin', onFocus);
      host.replaceChildren();
    },
  };
}
