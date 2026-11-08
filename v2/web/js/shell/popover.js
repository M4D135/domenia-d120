// Anchored popovers of the top bar (notifications, operations, session, overflow): one at a time, under their button,
// non modal (the page stays usable), Échap and an outside click close them, the focus returns to the button.
import { esc, motionReduced } from '../ui.js';
import { focusables } from '../kit/util.js';

let current = null;

/** True while a popover of the shell is open. */
export function popoverOpen() { return !!current; }

/** Closes the popover shown, if any. */
export function closePopover() { current?.close(); }

/**
 * Opens a popover under an anchor (a second call on the same anchor closes it).
 * @param {HTMLElement} anchor
 * @param {{ id: string, title: string, icon?: string, width?: number, render: (body: HTMLElement, ctl: object) => (void|(() => void)), head?: string }} o
 */
export function openPopover(anchor, o) {
  if (current?.id === o.id) { current.close(); return null; }
  current?.close();
  const el = document.createElement('div');
  el.className = 'sh-pop';
  el.dataset.pop = o.id;
  el.setAttribute('role', 'dialog');
  el.setAttribute('aria-modal', 'false');
  el.setAttribute('aria-label', o.title);
  el.tabIndex = -1;
  el.innerHTML = `<div class="sh-pop-head"><h2>${esc(o.title)}</h2>${o.head ?? ''}</div><div class="sh-pop-body"></div>`;
  if (o.width) el.style.setProperty('--pop-w', `${o.width}px`);
  document.body.appendChild(el);
  const body = el.querySelector('.sh-pop-body');
  let cleanup = null;
  const place = () => {
    const r = anchor.getBoundingClientRect();
    const w = el.offsetWidth;
    const x = Math.max(8, Math.min(innerWidth - w - 8, r.right - w + 6));
    el.style.setProperty('--px', `${Math.round(x)}px`);
    el.style.setProperty('--py', `${Math.round(r.bottom + 8)}px`);
    el.style.setProperty('--origin', `${Math.round(Math.min(w - 18, Math.max(18, r.left + r.width / 2 - x)))}px`);
  };
  const onKey = (e) => {
    if (e.key === 'Escape' && !e.defaultPrevented) { e.preventDefault(); e.stopPropagation(); ctl.close(true); }
  };
  const onDown = (e) => {
    if (!(e.target instanceof Node)) return;
    if (el.contains(e.target) || anchor.contains(e.target)) return;
    if (e.target instanceof Element && e.target.closest('.k-menu, .k-surface, .flytip')) return;
    ctl.close(false);
  };
  const ctl = {
    id: o.id, el, body, anchor,
    close(focusBack = false) {
      if (current !== ctl) return;
      current = null;
      anchor.setAttribute('aria-expanded', 'false');
      document.removeEventListener('pointerdown', onDown, true);
      window.removeEventListener('resize', place);
      el.removeEventListener('keydown', onKey);
      try { cleanup?.(); } catch (err) { console.error(err); }
      if (focusBack || el.contains(document.activeElement)) anchor.focus({ preventScroll: true });
      if (motionReduced()) { el.remove(); return; }
      el.classList.add('leaving');
      el.addEventListener('animationend', () => el.remove(), { once: true });
      setTimeout(() => el.remove(), 400);
    },
    place,
    focusFirst() { (focusables(el).find((x) => x.getAttribute('aria-disabled') !== 'true') ?? el).focus({ preventScroll: true }); },
  };
  current = ctl;
  anchor.setAttribute('aria-expanded', 'true');
  cleanup = o.render(body, ctl) ?? null;
  place();
  el.addEventListener('keydown', onKey);
  document.addEventListener('pointerdown', onDown, true);
  window.addEventListener('resize', place);
  // Like the panels of the kit, the popover itself takes the focus (its name is announced); Tab then walks its content.
  requestAnimationFrame(() => { if (current === ctl) el.focus({ preventScroll: true }); });
  return ctl;
}
