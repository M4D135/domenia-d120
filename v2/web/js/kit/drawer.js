// Side panel (drawer), left or right, over the content area: resizable (pointer and keyboard), focus trap when modal,
// width remembered per key. One modal drawer at a time: another request waits until it closes (Domenia 1, TRV-056).
// Leaving the screen withdraws the waiting requests without opening them.
import { glyph } from './glyphs.js';
import {
  esc, uid, clamp, fill, setVars, focusables, trapFocus, pushModal, popModal, leave, readLayout, writeLayout,
  rafThrottle, int, announce,
} from './util.js';

/**
 * @typedef {Object} DrawerOptions
 * @property {string} title
 * @property {string} [subtitle]
 * @property {string} [icon]
 * @property {'right'|'left'} [side='right']
 * @property {Node|string} [body]            Node, or trusted markup.
 * @property {Array<{id: string, label: string, icon?: string, primary?: boolean, danger?: boolean, run?: (ctl: any) => void}>} [actions]  Footer buttons.
 * @property {number} [width=480] @property {number} [minWidth=320] @property {number} [maxWidth=1100]
 * @property {string} [key]                  Remembers the width.
 * @property {boolean} [modal=true]          Backdrop, inert page and focus trap; false: a panel beside the work.
 * @property {boolean} [resizable=true]
 * @property {boolean} [focusFirst=false]    Focus the first field of the body instead of the panel (forms).
 * @property {() => void} [onClose]
 */

/** Waiting modal requests: { start, cancel, screen }. */
const queue = [];
let modalOpenNow = false;

/** Screen part of the address (« #/accueil » of « #/accueil?ou=choisir »): a request belongs to the screen it came from. */
const screenOf = (hash) => String(hash ?? '').split('?')[0];

/** Withdraws every waiting request (screen left): each one resolves `closed` without opening. */
function dropQueue() {
  queue.splice(0).forEach((q) => q.cancel());
}

/** Next waiting request of the screen still shown; requests of a screen that was left are withdrawn. */
function nextInQueue() {
  const here = screenOf(location.hash);
  while (queue.length) {
    const q = queue.shift();
    if (q.screen === here) return q;
    q.cancel();
  }
  return null;
}

const STEP = 16;
const BIG_STEP = 64;

/**
 * Opens a drawer. With a modal drawer already open, the request waits and opens when the first one closes.
 * @param {DrawerOptions} opts
 * @returns {{ el: HTMLElement, body: HTMLElement, foot: HTMLElement, close: () => void, setTitle: (t: string, s?: string) => void, setBusy: (on: boolean) => void, closed: Promise<void> }}
 */
export function openDrawer(opts) {
  const modal = opts.modal !== false;
  let resolveClosed;
  const closed = new Promise((r) => { resolveClosed = r; });
  // Placeholder controller until the drawer really opens (queued request).
  const entry = {
    start: () => build(opts, ctl, resolveClosed),
    cancel: () => { resolveClosed(); opts.onClose?.(); },
    screen: screenOf(location.hash),
  };
  const ctl = {
    el: null, body: null, foot: null, closed,
    close: () => { const at = queue.indexOf(entry); if (at >= 0) { queue.splice(at, 1); entry.cancel(); } },
    setTitle: () => {}, setBusy: () => {},
  };
  if (modal && modalOpenNow) {
    queue.push(entry);
    announce('Un panneau est déjà ouvert : le suivant s’ouvrira à sa fermeture.');
  } else {
    entry.start();
  }
  return /** @type {any} */ (ctl);
}

function build(opts, ctl, resolveClosed) {
  const id = uid('drw');
  const modal = opts.modal !== false;
  const side = opts.side === 'left' ? 'left' : 'right';
  const minW = opts.minWidth ?? 320;
  const maxW = opts.maxWidth ?? 1100;
  const stored = readLayout(opts.key ? `drawer:${opts.key}` : '');
  let width = clamp(stored?.v === 1 && Number.isFinite(stored.width) ? stored.width : (opts.width ?? 480), minW, maxW);
  const layer = document.createElement('div');
  layer.className = `k-surface k-drw-layer ${side}${modal ? ' modal' : ' docked'}`;
  const actions = opts.actions ?? [];
  layer.innerHTML = `${modal ? '<div class="k-drw-backdrop" aria-hidden="true"></div>' : ''}
    <aside class="k-drw" role="${modal ? 'dialog' : 'complementary'}"${modal ? ' aria-modal="true"' : ''} aria-labelledby="${id}-t" tabindex="-1">
      <div class="k-drw-busy" aria-hidden="true"></div>
      ${opts.resizable === false ? '' : `<div class="k-drw-grip" role="separator" aria-orientation="vertical" tabindex="0" aria-label="Largeur du panneau" aria-valuemin="${minW}" aria-valuemax="${maxW}" aria-valuenow="${width}" data-tip="Glisser pour élargir · flèches au clavier"></div>`}
      <header class="k-drw-head">
        ${opts.icon ? `<span class="k-drw-icon">${glyph(opts.icon)}</span>` : ''}
        <div class="k-drw-titles"><h2 id="${id}-t">${esc(opts.title)}</h2><p class="k-drw-sub"${opts.subtitle ? '' : ' hidden'}>${esc(opts.subtitle ?? '')}</p></div>
        <button class="btn ghost icon sm k-drw-x" type="button" aria-label="Fermer le panneau" data-tip="Fermer (Échap)">${glyph('x')}</button>
      </header>
      <div class="k-drw-body"></div>
      <footer class="k-drw-foot"${actions.length ? '' : ' hidden'}>${actions.map((a) => `<button class="btn${a.primary ? ' primary' : ''}${a.danger ? ' danger' : ''}" type="button" data-id="${esc(a.id)}">${a.icon ? glyph(a.icon) : ''}${esc(a.label)}</button>`).join('')}</footer>
    </aside>`;
  const panel = /** @type {HTMLElement} */ (layer.querySelector('.k-drw'));
  const body = /** @type {HTMLElement} */ (layer.querySelector('.k-drw-body'));
  const foot = /** @type {HTMLElement} */ (layer.querySelector('.k-drw-foot'));
  const grip = /** @type {HTMLElement|null} */ (layer.querySelector('.k-drw-grip'));
  fill(body, opts.body);
  const restore = document.activeElement instanceof HTMLElement ? document.activeElement : null;

  // The panel covers the content area (below the top bar, beside the navigation).
  const place = () => {
    const main = document.getElementById('main');
    const r = main ? main.getBoundingClientRect() : { top: 0, left: 0, right: innerWidth };
    setVars(layer, { '--k-top': `${Math.round(r.top)}px`, '--k-left': `${Math.round(r.left)}px`, '--k-right': `${Math.round(innerWidth - r.right)}px` });
  };
  const applyWidth = () => {
    setVars(panel, { '--k-dw': `${width}px` });
    grip?.setAttribute('aria-valuenow', String(width));
    grip?.setAttribute('aria-valuetext', `${int(width)} pixels`);
  };
  const save = () => { if (opts.key) writeLayout(`drawer:${opts.key}`, { v: 1, width }); };

  let release = () => {};
  let done = false;
  const close = () => {
    if (done) return;
    done = true;
    release();
    window.removeEventListener('resize', place);
    window.removeEventListener('hashchange', onHash);
    if (modal) { popModal(layer); modalOpenNow = false; }
    leave(layer, 480).then(() => {
      layer.remove();
      resolveClosed();
      // Only a request of the screen still shown opens; the screen may have changed during the closing animation.
      const next = modal ? nextInQueue() : null;
      if (next) next.start();
    });
    if (restore?.isConnected && (panel.contains(document.activeElement) || document.activeElement === document.body)) restore.focus({ preventScroll: true });
    opts.onClose?.();
  };
  // Bubbling phase on the panel: a field of the body that uses Échap itself (search of a tree, quick filter or selection
  // of a grid) handles it first and stops it; only an Échap nobody used closes the panel.
  const onKey = (e) => {
    if (e.key !== 'Escape' || e.defaultPrevented) return;
    e.preventDefault();
    e.stopPropagation();
    close();
  };
  // Leaving the screen closes the panel and withdraws the requests waiting behind it (none opens on the next screen).
  const onHash = () => {
    if (modal) dropQueue();
    close();
  };

  layer.addEventListener('click', (e) => {
    const t = e.target instanceof Element ? e.target : null;
    if (!t) return;
    if (t.classList.contains('k-drw-backdrop') || t.closest('.k-drw-x')) { close(); return; }
    const b = t.closest('.k-drw-foot button[data-id]');
    if (b) actions.find((a) => a.id === b.dataset.id)?.run?.(ctl);
  });

  if (grip) {
    const resize = rafThrottle((x) => {
      const r = panel.getBoundingClientRect();
      width = clamp(Math.round(side === 'right' ? r.right - x : x - r.left), minW, maxW);
      applyWidth();
    });
    grip.addEventListener('pointerdown', (e) => {
      if (e.button !== 0) return;
      e.preventDefault();
      grip.setPointerCapture(e.pointerId);
      layer.classList.add('resizing');
      const move = (ev) => resize(ev.clientX);
      const up = () => {
        grip.removeEventListener('pointermove', move);
        grip.removeEventListener('pointerup', up);
        grip.removeEventListener('pointercancel', up);
        layer.classList.remove('resizing');
        save();
      };
      grip.addEventListener('pointermove', move);
      grip.addEventListener('pointerup', up);
      grip.addEventListener('pointercancel', up);
    });
    grip.addEventListener('keydown', (e) => {
      const grow = side === 'right' ? 'ArrowLeft' : 'ArrowRight';
      const shrink = side === 'right' ? 'ArrowRight' : 'ArrowLeft';
      const step = e.shiftKey ? BIG_STEP : STEP;
      let next = width;
      if (e.key === grow) next += step;
      else if (e.key === shrink) next -= step;
      else if (e.key === 'Home') next = minW;
      else if (e.key === 'End') next = maxW;
      else return;
      e.preventDefault();
      width = clamp(next, minW, maxW);
      applyWidth();
      save();
    });
    grip.addEventListener('dblclick', () => { width = clamp(opts.width ?? 480, minW, maxW); applyWidth(); save(); });
  }

  Object.assign(ctl, {
    el: panel,
    body,
    foot,
    close,
    setTitle(title, subtitle) {
      panel.querySelector('h2').textContent = title;
      const sub = panel.querySelector('.k-drw-sub');
      sub.textContent = subtitle ?? '';
      sub.hidden = !subtitle;
    },
    setBusy(on) {
      panel.classList.toggle('busy', !!on);
      if (on) body.setAttribute('aria-busy', 'true'); else body.removeAttribute('aria-busy');
    },
  });

  place();
  applyWidth();
  document.body.appendChild(layer);
  window.addEventListener('resize', place);
  window.addEventListener('hashchange', onHash);
  panel.addEventListener('keydown', onKey);
  if (modal) {
    modalOpenNow = true;
    pushModal(layer);
    release = trapFocus(panel);
  }
  // The panel itself takes the focus (its title is announced); Tab then walks its content. focusFirst: the first field.
  (opts.focusFirst ? focusables(body)[0] ?? panel : panel).focus({ preventScroll: true });
}
