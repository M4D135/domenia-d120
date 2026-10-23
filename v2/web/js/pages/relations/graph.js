// Relations graph of a subject: the subject at the centre, its relations on a first ring (edge colour = strongest nature,
// thickness = number of relations, dashes = history, travelling light = observed session, red pulse = contradiction), the
// other relations of those objects on a second ring. The first ring is bounded (MAX_RING1 nodes, the rest gathered in one
// « + n » node that opens the list) and staggered on two tracks beyond six nodes, so labels never pile up. Pure SVG built from
// the engine's graph (relations.subject → graph), positions as SVG attributes (CSP: no style attribute), motion in transform
// and opacity only, final state at once when animations are reduced. Keyboard: every node is a button (Entrée opens the
// card with its associations and their actions, Maj Entrée makes it the subject).
import { glyph } from '../../kit/glyphs.js';
import { esc, setVars, int, NBSP } from '../../kit/util.js';
import { announce } from '../../ui.js';
import { BADGES, NATURES, qualification, shortOs, dateText } from './model.js';

/** Most nodes on the first ring; beyond, one « + n » node stands for the others (the list shows them all). */
const MAX_RING1 = 10;

const W = 860;
const H = 470;
const CX = W / 2;
const CY = H / 2 - 8;
const RX1 = 250;
const RY1 = 126;
const RX2 = 392;
const RY2 = 198;

function nodeIcon(kind, size) {
  const half = size / 2;
  return glyph(kind === 'computer' ? 'monitor' : 'user').replace('<svg class="', `<svg x="${-half}" y="${-half}" width="${size}" height="${size}" class="rel-node-ico `);
}

function shorten(text, max) {
  const t = String(text ?? '').replace(/\s*\([^)]*\)\s*$/, '').trim();
  return t.length > max ? `${t.slice(0, max - 1)}…` : t;
}

/** Keeps the first ring readable: the strongest MAX_RING1 − 1 nodes and one « + n » node for the others. */
function bound(graph) {
  const ring1 = graph.nodes.filter((n) => n.depth === 1);
  if (ring1.length <= MAX_RING1) return { graph, hidden: 0 };
  const kept = new Set(ring1.slice(0, MAX_RING1 - 1).map((n) => n.id));
  const centre = graph.nodes.find((n) => n.depth === 0);
  const hidden = ring1.length - kept.size;
  const more = { id: '__more', kind: ring1[0].kind, label: `+${hidden} autres`, sub: 'voir la liste', dn: null, depth: 1, primary: false, exists: true, tone: 'off', links: hidden, more: true };
  const keepIds = new Set([centre?.id, ...kept]);
  const edges = graph.edges.filter((e) => keepIds.has(e.from) && (keepIds.has(e.to) || graph.nodes.find((n) => n.id === e.to)?.depth === 2));
  const ring2 = new Set(edges.filter((e) => kept.has(e.from)).map((e) => e.to));
  const nodes = graph.nodes.filter((n) => n.depth === 0 || kept.has(n.id) || (n.depth === 2 && ring2.has(n.id))).concat([more]);
  edges.push({ from: centre?.id, to: '__more', badge: 'hint', count: hidden, contradicted: false, label: `${hidden} autres relations`, more: true });
  return { graph: { ...graph, nodes, edges: edges.filter((e) => e.to !== '__more' || e.more) }, hidden };
}

function clampX(x) { return Math.max(70, Math.min(W - 70, x)); }
function clampY(y) { return Math.max(46, Math.min(H - 52, y)); }

/** Positions of the nodes: the centre, the first ring on a stretched ellipse, the second ring fanned out behind its parent. */
function layout(graph) {
  const centre = graph.nodes.find((n) => n.depth === 0);
  const ring1 = graph.nodes.filter((n) => n.depth === 1);
  const ring2 = graph.nodes.filter((n) => n.depth === 2);
  const pos = new Map();
  if (centre) pos.set(centre.id, { x: CX, y: CY, angle: 0 });
  // Half a step of phase keeps three or more nodes off the top, where the second ring would have no room.
  const phase = ring1.length <= 2 ? 0 : -Math.PI / 2 + Math.PI / ring1.length;
  // Beyond six nodes, every other node sits on an inner track: neighbours never share a line of labels.
  const stagger = ring1.length > 6;
  ring1.forEach((n, i) => {
    const angle = phase + (i * 2 * Math.PI) / Math.max(1, ring1.length);
    const k = stagger && i % 2 === 1 ? 0.7 : 1;
    pos.set(n.id, { x: clampX(CX + Math.cos(angle) * RX1 * k), y: clampY(CY + Math.sin(angle) * RY1 * k), angle });
  });
  // The centre writes its name above itself when a node sits below it and none above: no edge crosses the text.
  const near = (p) => Math.abs(p.x - CX) < 90;
  const placed1 = ring1.map((n) => pos.get(n.id));
  pos.centreAbove = placed1.some((p) => near(p) && p.y > CY) && !placed1.some((p) => near(p) && p.y < CY);
  const children = new Map();
  for (const edge of graph.edges) {
    if (!pos.has(edge.from) || !ring2.some((n) => n.id === edge.to)) continue;
    if (!children.has(edge.from)) children.set(edge.from, []);
    if (!children.get(edge.from).includes(edge.to)) children.get(edge.from).push(edge.to);
  }
  const placed = new Set();
  for (const [parent, list] of children) {
    const base = pos.get(parent);
    const spread = Math.min(0.36, 1.1 / Math.max(1, list.length));
    list.forEach((id, j) => {
      if (placed.has(id)) return;
      placed.add(id);
      const angle = base.angle + (j - (list.length - 1) / 2) * spread;
      pos.set(id, { x: clampX(CX + Math.cos(angle) * RX2), y: clampY(CY + Math.sin(angle) * RY2), angle });
    });
  }
  return pos;
}

function edgeMarkup(edge, a, b, n, depth) {
  const width = (depth === 1 ? 1.6 : 1.1) + Math.min(4, edge.count) * (depth === 1 ? 0.7 : 0.35);
  const dashed = edge.badge === 'history' || edge.badge === 'hint';
  const flow = edge.badge === 'observed' && depth === 1
    ? `<circle class="rel-flow" r="3.2" cx="${a.x.toFixed(1)}" cy="${a.y.toFixed(1)}" data-dx="${(b.x - a.x).toFixed(1)}" data-dy="${(b.y - a.y).toFixed(1)}" data-i="${n}"/>`
    : '';
  return `<g class="rel-edge d${depth}${dashed ? ' dashed' : ''}${edge.contradicted ? ' contra' : ''}" data-badge="${esc(edge.badge)}" data-from="${esc(edge.from)}" data-to="${esc(edge.to)}" data-i="${n}">
    <line class="rel-edge-glow" x1="${a.x.toFixed(1)}" y1="${a.y.toFixed(1)}" x2="${b.x.toFixed(1)}" y2="${b.y.toFixed(1)}" stroke-width="${(width + 6).toFixed(1)}"/>
    <line class="rel-edge-line" x1="${a.x.toFixed(1)}" y1="${a.y.toFixed(1)}" x2="${b.x.toFixed(1)}" y2="${b.y.toFixed(1)}" stroke-width="${width.toFixed(1)}"/>${flow}</g>`;
}

function nodeMarkup(node, p, n, badgeOf, centreAbove = false) {
  const size = node.depth === 0 ? 38 : node.depth === 1 ? 27 : 17;
  const label = shorten(node.label, node.depth === 2 ? 18 : 24);
  const rawSub = node.kind === 'computer' ? shortOs(node.sub) : node.sub;
  const sub = node.depth === 2 ? (node.exists ? '' : 'absent de l’annuaire') : shorten(node.exists ? rawSub ?? '' : 'absent de l’annuaire', 26);
  const subClass = node.kind === 'user' && node.exists && !node.more ? ' mono' : '';
  // A node above the centre writes its name above itself: the edge towards the centre never crosses the text.
  const above = node.depth > 0 ? p.y < CY - 30 : centreAbove;
  const gap = node.depth === 0 ? 26 : 16;
  const lift = node.depth === 0 ? 14 : 0; // clears the dashed ring of the centre
  const labelY = above ? -(size + lift + (sub ? 24 : 9)) : size + gap;
  const subY = above ? -(size + lift + 9) : size + gap + 14;
  const badgeId = badgeOf.get(node.id) ?? (node.depth === 0 ? 'centre' : 'hint');
  const aria = `${node.kind === 'computer' ? 'Poste' : 'Utilisateur'} ${node.label}${node.primary ? ', principal' : ''}${node.exists ? '' : ', absent de l’annuaire'}`
    + `${node.depth > 0 ? `, ${BADGES[badgeId]?.label ?? ''}` : ', sujet'}`;
  return `<g class="rel-node d${node.depth}${node.exists ? '' : ' gone'}${node.primary ? ' primary' : ''}${node.more ? ' more' : ''}" data-id="${esc(node.id)}" data-badge="${esc(badgeId)}"
      transform="translate(${p.x.toFixed(1)} ${p.y.toFixed(1)})" tabindex="0" role="button" aria-label="${esc(aria)}">
    <g class="rel-node-in" data-i="${n}">
      ${node.depth === 0 ? `<circle class="rel-core-ring" r="${size + 10}"/><circle class="rel-core-pulse" r="${size + 4}"/>` : ''}
      ${node.primary ? `<circle class="rel-primary-ring" r="${size + 7}"/>` : ''}
      <circle class="rel-node-halo" r="${size + 3}"/>
      <circle class="rel-node-core" r="${size}"/>
      ${node.more ? `<text class="rel-node-more" y="5" text-anchor="middle">+${int(node.links)}</text>` : nodeIcon(node.kind, node.depth === 0 ? 30 : node.depth === 1 ? 22 : 14)}
      ${node.primary ? `<g class="rel-star" transform="translate(${(size * 0.72).toFixed(1)} ${(-size * 0.72).toFixed(1)})"><circle r="8"/>${glyph('star').replace('<svg class="', '<svg x="-5.5" y="-5.5" width="11" height="11" class="')}</g>` : ''}
      <text class="rel-node-label" y="${labelY}" text-anchor="middle">${esc(label)}</text>
      ${sub ? `<text class="rel-node-sub${subClass}" y="${subY}" text-anchor="middle">${esc(sub)}</text>` : ''}
    </g></g>`;
}

/** Vertical frame of the drawing: the nodes and their labels with a margin, 320 units at least (a small ring stays compact). */
function frame(graph, pos) {
  let top = Infinity;
  let bottom = -Infinity;
  for (const node of graph.nodes) {
    const p = pos.get(node.id);
    if (!p) continue;
    const reach = node.depth === 0 ? 48 : node.depth === 1 ? 34 : 22;
    const above = node.depth > 0 ? p.y < CY - 30 : pos.centreAbove;
    top = Math.min(top, p.y - reach - (above ? 46 : 0));
    bottom = Math.max(bottom, p.y + reach + (above ? 0 : 46));
  }
  if (!Number.isFinite(top)) return { y: 0, h: H };
  const min = 320;
  let y = Math.max(0, top - 18);
  let end = Math.min(H, bottom + 18);
  if (end - y < min) {
    const mid = (y + end) / 2;
    y = Math.max(0, Math.min(H - min, mid - min / 2));
    end = y + min;
  }
  return { y: Math.round(y), h: Math.round(end - y) };
}

/**
 * Renders the graph into host.
 * @param {HTMLElement} host
 * @param {{ nodes: any[], edges: any[], truncated: boolean }} source
 * @param {{ onSelect?: (node: any, edges: any[]) => void, onOpen?: (node: any) => void, label?: string,
 *   associationsOf?: (node: any) => any[], onFiche?: (node: any) => void, onRemove?: (row: any) => void, onSave?: (row: any) => void,
 *   onShowList?: () => void }} [o]
 */
export function renderGraph(host, source, o = {}) {
  const { graph, hidden } = bound(source);
  const pos = layout(graph);
  const badgeOf = new Map();
  for (const edge of graph.edges) {
    const strength = (b) => ['hint', 'history', 'imported', 'observed', 'declared', 'contradictory'].indexOf(b);
    const current = badgeOf.get(edge.to);
    const b = edge.contradicted ? 'contradictory' : edge.badge;
    if (!current || strength(b) > strength(current)) badgeOf.set(edge.to, b);
  }
  const edges = [...graph.edges].sort((a, b) => {
    const da = graph.nodes.find((x) => x.id === a.to)?.depth ?? 1;
    const db = graph.nodes.find((x) => x.id === b.to)?.depth ?? 1;
    return db - da;
  });
  let n = 0;
  const edgeHtml = edges.map((e) => {
    const a = pos.get(e.from); const b = pos.get(e.to);
    if (!a || !b) return '';
    const depth = graph.nodes.find((x) => x.id === e.to)?.depth ?? 1;
    return edgeMarkup(e, a, b, n++, depth);
  }).join('');
  const nodes = [...graph.nodes].sort((a, b) => b.depth - a.depth);
  const order = new Map(graph.nodes.map((x, i) => [x.id, i]));
  const nodeHtml = nodes.map((x) => (pos.has(x.id) ? nodeMarkup(x, pos.get(x.id), x.depth === 0 ? 0 : (order.get(x.id) ?? 0) + 1, badgeOf, pos.centreAbove) : '')).join('');
  const centre = graph.nodes.find((x) => x.depth === 0);
  const view = frame(graph, pos);
  host.innerHTML = `<div class="rel-graph" role="group" aria-label="${esc(o.label ?? 'Graphe des relations')}">
    <svg class="rel-graph-svg" viewBox="0 ${view.y} ${W} ${view.h}" preserveAspectRatio="xMidYMid meet" focusable="false">
      <defs>
        <radialGradient id="rel-core-grad" cx="50%" cy="35%" r="70%"><stop class="rel-cg0" offset="0"/><stop class="rel-cg1" offset="1"/></radialGradient>
      </defs>
      <g class="rel-orbits" aria-hidden="true">
        <ellipse class="rel-orbit o1" cx="${CX}" cy="${CY}" rx="${RX1}" ry="${RY1}"/>
        <ellipse class="rel-orbit o2" cx="${CX}" cy="${CY}" rx="${RX2}" ry="${RY2}"/>
      </g>
      <g class="rel-edges" aria-hidden="true">${edgeHtml}</g>
      <g class="rel-nodes">${nodeHtml}</g>
    </svg>
    <div class="rel-graph-pop" hidden></div>
    ${graph.truncated || hidden ? `<p class="rel-graph-more">${glyph('info')}${hidden ? `Premier cercle limité aux ${int(MAX_RING1 - 1)} relations les plus fortes, ${int(hidden)} autres regroupées` : 'Graphe limité aux relations les plus pertinentes'}${graph.truncated && hidden ? ' · graphe partiel' : ''}${NBSP}: la liste montre tout.</p>` : ''}
  </div>`;
  const svg = host.querySelector('svg');
  svg.style.aspectRatio = `${W} / ${view.h}`;
  const pop = host.querySelector('.rel-graph-pop');
  host.querySelectorAll('[data-i]').forEach((el) => setVars(el, { '--i': el.dataset.i }));
  host.querySelectorAll('.rel-flow').forEach((el) => setVars(el, { '--dx': `${el.dataset.dx}px`, '--dy': `${el.dataset.dy}px` }));

  const edgesOf = (id) => graph.edges.filter((e) => e.from === id || e.to === id);
  const nodeOf = (id) => graph.nodes.find((x) => x.id === id);
  let selected = null;

  function light(id) {
    svg.classList.toggle('has-focus', Boolean(id));
    svg.querySelectorAll('.rel-node').forEach((el) => el.classList.toggle('lit', id !== null && (el.dataset.id === id
      || edgesOf(id).some((e) => e.from === el.dataset.id || e.to === el.dataset.id))));
    svg.querySelectorAll('.rel-edge').forEach((el) => el.classList.toggle('lit', id !== null && (el.dataset.from === id || el.dataset.to === id)));
  }

  // Card of a node: its associations with the subject, each with its visible actions (remove, save), then the way to its own
  // relations and its fiche. A write is a plan of the circuit, never done here.
  function showPop(el, node) {
    const list = edgesOf(node.id).filter((e) => e.to === node.id || e.from === node.id);
    const toCentre = list.find((e) => e.from === centre?.id || e.to === centre?.id) ?? list[0];
    const rows = node.depth === 1 ? (o.associationsOf?.(node) ?? []) : [];
    const hr = host.getBoundingClientRect();
    const nr = el.getBoundingClientRect();
    const x = nr.left + nr.width / 2 - hr.left;
    const y = nr.top - hr.top;
    const sub = node.kind === 'computer' ? shortOs(node.sub) : node.sub;
    pop.innerHTML = node.more ? `<div class="rel-pop-card">
        <div class="rel-pop-head"><span class="rel-pop-ico">${glyph('layers')}</span><div><b>${esc(node.label)}</b><span>Relations regroupées pour garder le graphe lisible</span></div></div>
        <button class="btn xs primary" type="button" data-pop-list>${glyph('rows')}Voir la liste complète</button></div>`
      : `<div class="rel-pop-card">
      <div class="rel-pop-head"><span class="rel-pop-ico">${glyph(node.kind === 'computer' ? 'monitor' : 'user')}</span>
        <div><b>${esc(node.label)}</b><span>${esc(sub || (node.kind === 'computer' ? 'Poste' : 'Utilisateur'))}</span></div></div>
      ${rows.length ? `<ul class="rel-pop-rows">${rows.map((r) => `<li><div>${qualification(r)}<span class="rel-pop-when">${esc(r.source)} · ${esc(dateText(r.when, { time: true }) ?? '—')}</span></div>
          ${r.persistence === 'session'
            ? `<button class="rel-act wr" type="button" data-pop-save="${esc(r.key)}" ${r.storageAmbiguous ? 'disabled title="Association ambiguë dans la base"' : ''} data-tip="Enregistrer l’observation (plan, confirmation, reçu)" aria-label="Enregistrer l’observation">${glyph('check')}</button>`
            : `<button class="rel-act danger" type="button" data-pop-remove="${esc(r.key)}" ${r.storageAmbiguous ? 'disabled title="Plusieurs lignes de la base : aucun retrait arbitraire"' : ''} data-tip="Retirer l’association (plan, confirmation, reçu ; restaurable)" aria-label="Retirer l’association">${glyph('trash')}</button>`}</li>`).join('')}</ul>`
        : toCentre ? `<p class="rel-pop-line">${esc(toCentre.label)}${toCentre.whenText ? ` · ${esc(toCentre.whenText)}` : ''}${toCentre.count > 1 ? ` · ${int(toCentre.count)}${NBSP}relations` : ''}</p>` : ''}
      ${node.exists ? '' : `<p class="rel-pop-warn">${glyph('alert')}Identité non vérifiée dans l’index local</p>`}
      <div class="rel-pop-actions">
        ${node.depth > 0 && node.dn ? `<button class="btn xs primary" type="button" data-pop-open>${glyph('link')}Voir ses relations</button>` : ''}
        ${node.depth > 0 ? `<button class="btn xs" type="button" data-pop-fiche ${node.dn ? '' : 'disabled title="Identité non vérifiée"'}>${glyph('external')}Fiche</button>` : ''}
      </div>
    </div>`;
    // The card stays inside the graph: near an edge it slides in instead of being cut.
    const half = Math.min(170, hr.width / 2 - 8);
    const px = Math.max(half + 8, Math.min(hr.width - half - 8, x));
    setVars(pop, { '--px': `${Math.round(px)}px`, '--py': `${Math.round(y)}px` });
    pop.classList.toggle('below', y < 200);
    pop.hidden = false;
    pop.classList.remove('in');
    void pop.offsetWidth;
    pop.classList.add('in');
    pop.querySelector('[data-pop-open]')?.addEventListener('click', () => o.onOpen?.(node));
    pop.querySelector('[data-pop-fiche]')?.addEventListener('click', () => o.onFiche?.(node));
    pop.querySelector('[data-pop-list]')?.addEventListener('click', () => o.onShowList?.());
    pop.querySelectorAll('[data-pop-remove]').forEach((b) => b.addEventListener('click', () => { const r = rows.find((x) => x.key === b.dataset.popRemove); if (r) o.onRemove?.(r); }));
    pop.querySelectorAll('[data-pop-save]').forEach((b) => b.addEventListener('click', () => { const r = rows.find((x) => x.key === b.dataset.popSave); if (r) o.onSave?.(r); }));
  }

  function select(el) {
    const node = nodeOf(el.dataset.id);
    if (!node) return;
    svg.querySelectorAll('.rel-node.selected').forEach((x) => x.classList.remove('selected'));
    if (selected === node.id) { selected = null; pop.hidden = true; light(null); return; }
    selected = node.id;
    el.classList.add('selected');
    light(node.id);
    showPop(el, node);
    announce(`${node.kind === 'computer' ? 'Poste' : 'Utilisateur'} ${node.label} sélectionné.`);
    o.onSelect?.(node, edgesOf(node.id));
  }

  const onOver = (e) => {
    const el = e.target instanceof Element ? e.target.closest('.rel-node') : null;
    if (!selected) light(el ? el.dataset.id : null);
  };
  const onClick = (e) => {
    const el = e.target instanceof Element ? e.target.closest('.rel-node') : null;
    if (el) { select(el); return; }
    if (e.target instanceof Element && !e.target.closest('.rel-graph-pop')) { selected = null; pop.hidden = true; light(null); svg.querySelectorAll('.rel-node.selected').forEach((x) => x.classList.remove('selected')); }
  };
  const onDouble = (e) => {
    const el = e.target instanceof Element ? e.target.closest('.rel-node') : null;
    const node = el ? nodeOf(el.dataset.id) : null;
    if (node?.more) o.onShowList?.();
    else if (node && node.depth > 0 && node.dn) o.onOpen?.(node);
  };
  const onKey = (e) => {
    const el = e.target instanceof Element ? e.target.closest('.rel-node') : null;
    if (!el) return;
    if (e.key === 'Enter' && e.shiftKey) {
      const node = nodeOf(el.dataset.id);
      if (node && node.depth > 0 && node.dn) { e.preventDefault(); o.onOpen?.(node); }
      return;
    }
    if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); select(el); }
    if (e.key === 'Escape' && selected) { e.preventDefault(); selected = null; pop.hidden = true; light(null); }
  };
  const onFocus = (e) => {
    const el = e.target instanceof Element ? e.target.closest('.rel-node') : null;
    if (el && !selected) light(el.dataset.id);
  };
  svg.addEventListener('pointerover', onOver);
  svg.addEventListener('pointerleave', () => { if (!selected) light(null); });
  host.addEventListener('click', onClick);
  svg.addEventListener('dblclick', onDouble);
  svg.addEventListener('keydown', onKey);
  svg.addEventListener('focusin', onFocus);
  return {
    destroy() { host.replaceChildren(); },
  };
}

/**
 * Legend of the graph: the line of each nature present, with the number of associations of the subject (the same figures as
 * the counts above the graph), the contradiction counted apart, and the second ring said in words.
 */
export function graphLegend(graph, counts) {
  const values = { declared: counts.declared, observed: counts.observed, history: counts.history, imported: counts.imported, hint: counts.hints, toCheck: Math.max(0, counts.total - counts.declared - counts.observed - counts.history - counts.imported - counts.hints) };
  const items = NATURES.filter((b) => values[b] > 0);
  const ring2 = graph.nodes.some((n) => n.depth === 2);
  return `<ul class="rel-legend" aria-label="Légende du graphe">${items.map((b, j) => `<li data-badge="${b}" data-j="${j}"><span class="rel-legend-line" aria-hidden="true"></span>${esc(BADGES[b].label)}<b>${int(values[b])}</b></li>`).join('')}
    ${counts.contradicted > 0 ? `<li data-badge="contradictory" data-j="${items.length}" class="contra"><span class="rel-legend-line" aria-hidden="true"></span>Contradiction<b>${int(counts.contradicted)}</b></li>` : ''}
    ${ring2 ? `<li class="rel-legend-ring2" data-j="${items.length + 1}"><span class="rel-legend-dot" aria-hidden="true"></span>Deuxième cercle${NBSP}: autres relations de ses ${graph.nodes.find((n) => n.depth === 0)?.kind === 'user' ? 'postes' : 'utilisateurs'}</li>` : ''}
    <li class="rel-legend-note"><span class="rel-legend-star" aria-hidden="true">${glyph('star')}</span>principal</li></ul>`;
}
