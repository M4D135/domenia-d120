// Master-detail split view: two panes and a draggable separator (pointer and keyboard), size remembered per key,
// detail pane foldable; below 720 px of width the panes stack (container query, no script).
import { glyph } from './glyphs.js';
import { esc, uid, clamp, fill, setVars, rafThrottle, readLayout, writeLayout, int, announce } from './util.js';

/**
 * @typedef {Object} SplitOptions
 * @property {Node|string} [a]                First pane (master), Node or trusted markup.
 * @property {Node|string} [b]                Second pane (detail).
 * @property {'row'|'column'} [orientation='row']  row: side by side; column: one above the other.
 * @property {'a'|'b'} [fixed='b']            Pane with the set size; the other takes the rest.
 * @property {number} [size=420] @property {number} [min=240] @property {number} [max=900]
 * @property {string} [key]                   Remembers size and folding.
 * @property {string} [label]                 Accessible name of the separator.
 * @property {boolean} [collapsible=true]     Enter or double click folds the fixed pane.
 */

const STEP = 16;
const BIG_STEP = 64;

/**
 * Creates a split view in host (its content is replaced).
 * @param {HTMLElement} host
 * @param {SplitOptions} o
 */
export function createSplit(host, o) {
  const id = uid('split');
  const row = o.orientation !== 'column';
  const fixed = o.fixed === 'a' ? 'a' : 'b';
  const min = o.min ?? 240;
  const max = o.max ?? 900;
  const saved = readLayout(o.key ? `split:${o.key}` : '');
  let size = clamp(saved?.v === 1 && Number.isFinite(saved.size) ? saved.size : (o.size ?? 420), min, max);
  let folded = saved?.v === 1 && saved.folded === true;

  host.innerHTML = `<div class="k-split ${row ? 'row' : 'column'} fixed-${fixed}">
    <div class="k-split-in">
      <div class="k-split-pane a" id="${id}-a"></div>
      <div class="k-split-sep" role="separator" tabindex="0" aria-orientation="${row ? 'vertical' : 'horizontal'}" aria-controls="${id}-${fixed}"
        aria-label="${esc(o.label ?? 'Taille du panneau de détail')}" aria-valuemin="${min}" aria-valuemax="${max}"
        data-tip="Glisser pour redimensionner · double clic pour replier"><span class="k-split-knob" aria-hidden="true">${glyph('grip')}</span></div>
      <div class="k-split-pane b" id="${id}-b"></div>
    </div>
  </div>`;
  const rootEl = /** @type {HTMLElement} */ (host.querySelector('.k-split'));
  const inner = /** @type {HTMLElement} */ (rootEl.querySelector('.k-split-in'));
  const a = /** @type {HTMLElement} */ (rootEl.querySelector('.k-split-pane.a'));
  const b = /** @type {HTMLElement} */ (rootEl.querySelector('.k-split-pane.b'));
  const sep = /** @type {HTMLElement} */ (rootEl.querySelector('.k-split-sep'));
  fill(a, o.a);
  fill(b, o.b);

  const apply = () => {
    setVars(inner, { '--k-split': `${folded ? 0 : size}px` });
    rootEl.classList.toggle('folded', folded);
    const pane = fixed === 'a' ? a : b;
    pane.inert = folded;
    sep.setAttribute('aria-valuenow', String(folded ? 0 : size));
    sep.setAttribute('aria-valuetext', folded ? 'replié' : `${int(size)} pixels`);
  };
  const save = () => { if (o.key) writeLayout(`split:${o.key}`, { v: 1, size, folded }); };

  const sizeFrom = (clientX, clientY) => {
    const r = inner.getBoundingClientRect();
    const pos = row ? clientX - r.left : clientY - r.top;
    const total = row ? r.width : r.height;
    return fixed === 'a' ? pos : total - pos;
  };

  const resize = rafThrottle((x, y) => {
    size = clamp(Math.round(sizeFrom(x, y)), min, max);
    folded = false;
    apply();
  });

  sep.addEventListener('pointerdown', (e) => {
    if (e.button !== 0) return;
    e.preventDefault();
    sep.setPointerCapture(e.pointerId);
    rootEl.classList.add('resizing');
    const move = (ev) => resize(ev.clientX, ev.clientY);
    const up = () => {
      sep.removeEventListener('pointermove', move);
      sep.removeEventListener('pointerup', up);
      sep.removeEventListener('pointercancel', up);
      rootEl.classList.remove('resizing');
      save();
    };
    sep.addEventListener('pointermove', move);
    sep.addEventListener('pointerup', up);
    sep.addEventListener('pointercancel', up);
  });

  const toggle = () => {
    if (o.collapsible === false) return;
    folded = !folded;
    apply();
    save();
    announce(folded ? 'Panneau replié.' : 'Panneau déplié.');
  };
  sep.addEventListener('dblclick', toggle);
  sep.addEventListener('keydown', (e) => {
    const grow = fixed === 'b' ? (row ? 'ArrowLeft' : 'ArrowUp') : (row ? 'ArrowRight' : 'ArrowDown');
    const shrink = fixed === 'b' ? (row ? 'ArrowRight' : 'ArrowDown') : (row ? 'ArrowLeft' : 'ArrowUp');
    const step = e.shiftKey ? BIG_STEP : STEP;
    if (e.key === 'Enter') { e.preventDefault(); toggle(); return; }
    let next = size;
    if (e.key === grow) next += step;
    else if (e.key === shrink) next -= step;
    else if (e.key === 'Home') next = min;
    else if (e.key === 'End') next = max;
    else return;
    e.preventDefault();
    size = clamp(next, min, max);
    folded = false;
    apply();
    save();
  });

  apply();
  return {
    el: rootEl,
    /** Master pane. */
    a,
    /** Detail pane. */
    b,
    setSize(px) { size = clamp(px, min, max); folded = false; apply(); save(); },
    fold(on = true) { folded = !!on; apply(); save(); },
    isFolded: () => folded,
    destroy() { host.replaceChildren(); },
  };
}
