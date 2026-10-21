// Command bar: main actions as buttons, the rest in a « Plus » menu; actions that no longer fit move into the menu
// (never by count, always by width: Domenia 1, TRV-092). Keyboard: one Tab stop, arrows between the commands.
import { glyph } from './glyphs.js';
import { openMenu } from './menu.js';
import { esc, uid } from './util.js';

/**
 * @typedef {Object} Command
 * @property {string} id
 * @property {string} label
 * @property {string} [icon]
 * @property {(cmd: Command) => void} [run]
 * @property {boolean} [primary]             The main action of the screen (one at most).
 * @property {boolean} [danger]              Destructive (always confirmed by confirmWrite).
 * @property {'local'|'read'|'network'|'write'} [kind='local']  Shown to the operator (network read, write).
 * @property {boolean} [disabled]
 * @property {string} [reason]               Why it is disabled (tooltip and accessible description).
 * @property {string} [kbd]                  Shortcut shown in the tip.
 * @property {boolean} [iconOnly]            Icon button (the label goes to the tip and the accessible name).
 * @property {boolean} [pinned]              Never moved into « Plus ».
 * @property {boolean} [overflow]            Always in « Plus ».
 * @property {Array<any>} [items]            Dropdown menu instead of a direct action.
 */

const KIND_TIP = { network: 'Lecture réseau : part seulement sur ce clic', write: 'Écriture : plan et confirmation avant tout envoi' };

/**
 * Creates a command bar in host (its content is replaced).
 * @param {HTMLElement} host
 * @param {{ label: string, items: Command[], moreLabel?: string, size?: 'sm'|'md' }} o
 */
export function createCommandBar(host, o) {
  const id = uid('cmd');
  let items = o.items.slice();
  let overflowIds = new Set();
  const widths = new Map();
  let moreWidth = 36;
  const busy = new Set();
  host.innerHTML = `<div class="k-cmdbar${o.size === 'sm' ? ' sm' : ''}" role="toolbar" aria-label="${esc(o.label)}" id="${id}"></div>`;
  const bar = /** @type {HTMLElement} */ (host.querySelector('.k-cmdbar'));

  function tipOf(c) {
    const parts = [];
    if (c.iconOnly) parts.push(c.label);
    if (c.kbd) parts.push(c.kbd);
    if (c.disabled && c.reason) parts.push(c.reason);
    else if (KIND_TIP[c.kind]) parts.push(KIND_TIP[c.kind]);
    return parts.join(' · ');
  }

  function buttonMarkup(c) {
    const cls = ['btn', o.size === 'sm' ? 'sm' : '', c.primary ? 'primary' : '', c.danger ? 'danger' : '', !c.primary && !c.danger ? 'subtle' : '',
      c.iconOnly ? 'icon' : '', c.kind === 'write' ? 'is-write' : '', c.kind === 'network' ? 'is-net' : '', busy.has(c.id) ? 'spinning' : ''].filter(Boolean).join(' ');
    const tip = tipOf(c);
    const dis = c.disabled ? ' aria-disabled="true"' : '';
    const desc = c.disabled && c.reason ? `<span class="visually-hidden">, ${esc(c.reason)}</span>` : '';
    const popup = c.items?.length ? ' aria-haspopup="menu" aria-expanded="false"' : '';
    const label = c.iconOnly ? `<span class="visually-hidden">${esc(c.label)}</span>` : `<span class="k-cmd-label">${esc(c.label)}</span>`;
    const mark = c.kind === 'write' ? `<span class="k-cmd-mark" aria-hidden="true">${glyph('edit')}</span>`
      : c.kind === 'network' ? '<span class="k-cmd-net" aria-hidden="true"></span>' : '';
    return `<button class="${cls}" type="button" tabindex="-1" data-cmd="${esc(c.id)}"${dis}${popup}${tip ? ` data-tip="${esc(tip)}"` : ''}${busy.has(c.id) ? ' aria-busy="true"' : ''}>`
      + `${c.icon ? glyph(c.icon) : ''}${label}${desc}${c.items?.length ? glyph('chevronDown', 'k-cmd-caret') : ''}${mark}</button>`;
  }

  // Key of a button of the bar (its command, or « Plus »), so focus and Tab stop survive a rebuild.
  const MORE = '\u0000more';
  const keyOf = (b) => (b instanceof HTMLElement ? (b.dataset.cmd ?? (b.classList.contains('k-cmd-more') ? MORE : null)) : null);
  const buttonOf = (key) => (key === MORE ? bar.querySelector('.k-cmd-more')
    : key != null ? bar.querySelector(`[data-cmd="${CSS.escape(key)}"]`) : null);

  // Full rebuild (new list of commands). The focused button and the Tab stop are kept when their command still exists.
  function render() {
    const focusKey = bar.contains(document.activeElement) ? keyOf(document.activeElement) : null;
    const stopKey = keyOf([...bar.querySelectorAll('button')].find((b) => b.tabIndex === 0));
    bar.innerHTML = items.map(buttonMarkup).join('')
      + `<button class="btn subtle icon${o.size === 'sm' ? ' sm' : ''} k-cmd-more" type="button" tabindex="-1" aria-haspopup="menu" aria-expanded="false" aria-label="${esc(o.moreLabel ?? 'Plus d’actions')}" data-tip="${esc(o.moreLabel ?? 'Plus d’actions')}">${glyph('more')}</button>`;
    measure();
    const stop = buttonOf(stopKey);
    if (stop instanceof HTMLElement) stop.tabIndex = 0;
    layout();
    if (focusKey == null) return;
    const again = buttonOf(focusKey);
    const target = again instanceof HTMLElement && !again.hidden ? again : bar.querySelector('button[tabindex="0"]');
    if (target instanceof HTMLElement) target.focus({ preventScroll: true });
  }

  // State change of one command (disabled, busy): the button is updated in place, so it keeps the focus and the Tab stop.
  function update(c) {
    const b = buttonOf(c.id);
    if (!(b instanceof HTMLElement)) { render(); return; }
    const tpl = document.createElement('template');
    tpl.innerHTML = buttonMarkup(c);
    const fresh = /** @type {HTMLElement} */ (tpl.content.firstElementChild);
    b.className = fresh.className;
    ['aria-disabled', 'aria-busy', 'data-tip'].forEach((name) => {
      const value = fresh.getAttribute(name);
      if (value == null) b.removeAttribute(name); else b.setAttribute(name, value);
    });
    b.replaceChildren(...fresh.childNodes);
  }

  // Natural widths of the buttons (all shown during the measure). A bar built out of the page measures 0: it is
  // measured again once it has a width.
  function measure() {
    bar.querySelectorAll('button').forEach((b) => { b.hidden = false; });
    widths.clear();
    bar.querySelectorAll('[data-cmd]').forEach((b) => widths.set(b.dataset.cmd, b.offsetWidth));
    moreWidth = bar.querySelector('.k-cmd-more')?.offsetWidth || 36;
  }

  // Decides which commands fit, from the end of the list; primary and pinned ones always stay.
  function layout() {
    if (bar.clientWidth > 0 && [...widths.values()].some((w) => !w)) measure();
    const more = bar.querySelector('.k-cmd-more');
    const gap = parseFloat(getComputedStyle(bar).columnGap) || 8;
    const avail = bar.clientWidth;
    const forced = new Set(items.filter((c) => c.overflow).map((c) => c.id));
    const shown = items.filter((c) => !forced.has(c.id));
    const widthOf = (list) => list.reduce((s, c) => s + (widths.get(c.id) ?? 0) + gap, 0);
    const moreW = moreWidth + gap;
    // Never narrower than its essential commands (primary, pinned, « Plus »), even in a container sized by content.
    const essential = items.filter((c) => (c.primary || c.pinned) && !forced.has(c.id)).reduce((sum, c) => sum + (widths.get(c.id) ?? 0) + gap, 0);
    bar.style.setProperty('--k-cmd-min', `${Math.ceil(essential + moreW + 4)}px`);
    const next = new Set(forced);
    let total = widthOf(shown) + (forced.size ? moreW : 0);
    for (let n = shown.length - 1; n >= 0 && total > avail; n--) {
      const c = shown[n];
      if (c.primary || c.pinned) continue;
      if (!next.size) total += moreW;
      next.add(c.id);
      total -= (widths.get(c.id) ?? 0) + gap;
    }
    overflowIds = next;
    bar.querySelectorAll('[data-cmd]').forEach((b) => { b.hidden = overflowIds.has(b.dataset.cmd); });
    if (more) more.hidden = overflowIds.size === 0;
    roving();
  }

  function roving() {
    const list = [...bar.querySelectorAll('button:not([hidden])')];
    const current = list.find((b) => b.tabIndex === 0) ?? list[0];
    list.forEach((b) => { b.tabIndex = b === current ? 0 : -1; });
  }

  function run(c, anchor) {
    if (!c || c.disabled || busy.has(c.id)) return;
    if (c.items?.length) { openMenu(anchor, c.items, { label: c.label }); return; }
    c.run?.(c);
  }

  bar.addEventListener('click', (e) => {
    const b = e.target instanceof Element ? e.target.closest('button') : null;
    if (!b) return;
    bar.querySelectorAll('button').forEach((x) => { x.tabIndex = x === b ? 0 : -1; });
    if (b.classList.contains('k-cmd-more')) {
      // Same rules as the buttons: a command already running cannot be started again from the menu.
      const list = items.filter((c) => overflowIds.has(c.id)).map((c) => ({
        label: c.label, icon: c.icon, danger: c.danger, disabled: c.disabled || busy.has(c.id),
        reason: busy.has(c.id) ? 'Action en cours' : c.reason, kbd: c.kbd,
        hint: c.kind === 'write' ? 'écriture' : c.kind === 'network' ? 'réseau' : '',
        items: c.items, run: () => run(c, b),
      }));
      openMenu(b, list, { label: o.moreLabel ?? 'Plus d’actions', placement: 'bottom-end' });
      return;
    }
    run(items.find((c) => c.id === b.dataset.cmd), b);
  });

  bar.addEventListener('keydown', (e) => {
    if (!['ArrowLeft', 'ArrowRight', 'Home', 'End'].includes(e.key)) return;
    const list = [...bar.querySelectorAll('button:not([hidden])')];
    const at = list.indexOf(/** @type {HTMLButtonElement} */ (document.activeElement));
    if (at < 0) return;
    e.preventDefault();
    let next = at;
    if (e.key === 'ArrowLeft') next = (at - 1 + list.length) % list.length;
    else if (e.key === 'ArrowRight') next = (at + 1) % list.length;
    else if (e.key === 'Home') next = 0;
    else next = list.length - 1;
    list.forEach((b, n) => { b.tabIndex = n === next ? 0 : -1; });
    list[next].focus();
  });

  const ro = 'ResizeObserver' in window ? new ResizeObserver(() => layout()) : null;
  ro?.observe(bar);
  render();

  return {
    el: bar,
    setItems(next) { items = next.slice(); render(); },
    /** Enables or disables a command; reason says why (tooltip). */
    setDisabled(cmdId, on, reason) {
      const c = items.find((x) => x.id === cmdId);
      if (!c) return;
      c.disabled = !!on;
      c.reason = on ? reason ?? c.reason : c.reason;
      update(c);
    },
    /** Busy state (spinning icon, no second click) while the command runs; the button keeps the focus. */
    setBusy(cmdId, on) {
      if (on) busy.add(cmdId); else busy.delete(cmdId);
      const c = items.find((x) => x.id === cmdId);
      if (c) update(c);
    },
    destroy() { ro?.disconnect(); host.replaceChildren(); },
  };
}
