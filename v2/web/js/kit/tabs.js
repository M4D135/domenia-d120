// Tabs (APG pattern, automatic activation): sliding ink, counts, panels rendered on first display only (heavy tabs
// cost nothing until opened: Domenia 1, TRV-163), selected tab remembered per key.
import { glyph } from './glyphs.js';
import { esc, uid, int, readLayout, writeLayout } from './util.js';
import { inkFollow } from '../ui.js';

/**
 * @typedef {Object} TabDef
 * @property {string} id
 * @property {string} label
 * @property {string} [icon]
 * @property {number|null} [count]           Badge; null hides it.
 * @property {'ok'|'warn'|'alert'|'info'} [tone]  Badge tone.
 * @property {boolean} [disabled]
 * @property {string} [reason]
 * @property {(panel: HTMLElement) => (void | (() => void))} [render]  Called once, on first display; may return a cleanup.
 */

/**
 * Creates tabs in host (its content is replaced).
 * @param {HTMLElement} host
 * @param {{ label: string, tabs: TabDef[], selected?: string, key?: string, onChange?: (id: string) => void }} o
 */
export function createTabs(host, o) {
  const id = uid('tabs');
  const saved = readLayout(o.key ? `tabs:${o.key}` : '');
  const flag = value => typeof value === 'function' ? value() === true : value === true;
  const usable = (t) => t && !flag(t.disabled) && !flag(t.hidden);
  let current = [saved?.v === 1 ? saved.selected : null, o.selected, o.tabs[0]?.id].find((x) => usable(o.tabs.find((t) => t.id === x)))
    ?? o.tabs.find(usable)?.id;
  const cleanups = [];
  const renderedTabs = new Set();

  host.innerHTML = `<div class="k-tabs">
    <div class="k-tabs-scroll"><div class="tabs k-tablist" role="tablist" aria-label="${esc(o.label)}">${o.tabs.map((t) => {
      const sel = t.id === current;
      const badge = Number.isFinite(t.count) ? `<span class="k-badge ${esc(t.tone ?? 'off')}">${int(t.count)}</span>` : '';
      return `<button type="button" role="tab" id="${id}-t-${esc(t.id)}" aria-controls="${id}-p-${esc(t.id)}" aria-selected="${sel}" tabindex="${sel ? 0 : -1}" data-tab="${esc(t.id)}"`
        + `${t.gui ? ` data-gui="${esc(t.gui)}"` : ''}${flag(t.hidden) ? ' hidden' : ''}${flag(t.disabled) ? ` aria-disabled="true" data-tip="${esc(t.reason ?? '')}"` : ''}>${t.icon ? glyph(t.icon) : ''}<span>${esc(t.label)}</span>${badge}</button>`;
    }).join('')}<span class="ink" aria-hidden="true"></span></div></div>
    ${o.tabs.map((t) => `<div class="tab-panel k-tabpanel" role="tabpanel" id="${id}-p-${esc(t.id)}" aria-labelledby="${id}-t-${esc(t.id)}" tabindex="0"${t.id === current ? '' : ' hidden'}></div>`).join('')}
  </div>`;
  const list = /** @type {HTMLElement} */ (host.querySelector('.k-tablist'));
  const ink = inkFollow(list, 'button', 'button[aria-selected="true"]');
  const panelOf = (tabId) => /** @type {HTMLElement} */ (host.querySelector(`#${CSS.escape(`${id}-p-${tabId}`)}`));
  const buttonOf = tabId => list.querySelector(`[data-tab="${CSS.escape(String(tabId))}"]`);
  const available = tab => usable(tab) && buttonOf(tab.id)?.hidden !== true && buttonOf(tab.id)?.disabled !== true && buttonOf(tab.id)?.getAttribute('aria-disabled') !== 'true';

  // Only the tab strip scrolls (horizontally); the page never moves when a tab is chosen.
  const strip = /** @type {HTMLElement} */ (host.querySelector('.k-tabs-scroll'));
  function revealTab(b) {
    const left = b.offsetLeft;
    const right = left + b.offsetWidth;
    if (left < strip.scrollLeft) strip.scrollLeft = left;
    else if (right > strip.scrollLeft + strip.clientWidth) strip.scrollLeft = right - strip.clientWidth;
  }

  function show(tabId, focus = false) {
    const def = o.tabs.find((t) => t.id === tabId);
    if (!def || !available(def)) return;
    const changed = tabId !== current;
    current = tabId;
    list.querySelectorAll('[role="tab"]').forEach((b) => {
      const sel = b.dataset.tab === tabId;
      b.setAttribute('aria-selected', String(sel));
      b.tabIndex = sel ? 0 : -1;
      if (sel && focus) b.focus({ preventScroll: true });
      if (sel) revealTab(b);
    });
    o.tabs.forEach((t) => { panelOf(t.id).hidden = t.id !== tabId; });
    if (!renderedTabs.has(tabId) && typeof def.render === 'function') {
      renderedTabs.add(tabId);
      const out = def.render(panelOf(tabId));
      if (typeof out === 'function') cleanups.push(out);
    }
    ink.update();
    if (changed) {
      if (o.key) writeLayout(`tabs:${o.key}`, { v: 1, selected: tabId });
      o.onChange?.(tabId);
    }
  }

  list.addEventListener('click', (e) => {
    const b = e.target instanceof Element ? e.target.closest('[role="tab"]') : null;
    if (b) show(b.dataset.tab);
  });
  list.addEventListener('keydown', (e) => {
    const tabs = o.tabs.filter(available).map(t => buttonOf(t.id));
    const at = tabs.indexOf(/** @type {HTMLElement} */ (document.activeElement));
    if (at < 0) return;
    let next = -1;
    if (e.key === 'ArrowRight') next = (at + 1) % tabs.length;
    else if (e.key === 'ArrowLeft') next = (at - 1 + tabs.length) % tabs.length;
    else if (e.key === 'Home') next = 0;
    else if (e.key === 'End') next = tabs.length - 1;
    if (next < 0) return;
    e.preventDefault();
    show(tabs[next].dataset.tab, true);
  });

  function reconcile() {
    if (available(o.tabs.find(t => t.id === current))) return;
    const focused = list.contains(document.activeElement);
    const next = o.tabs.find(available);
    if (next) { show(next.id, focused); return; }
    current = undefined;
    for (const tab of o.tabs) {
      panelOf(tab.id).hidden = true;
      const b = buttonOf(tab.id); b.setAttribute('aria-selected', 'false'); b.tabIndex = -1;
    }
    ink.update();
  }
  // GUI policies may arrive after the page. A hidden/disabled selected tab must not leave its panel visible.
  const restrictions = new MutationObserver(reconcile);
  restrictions.observe(list, { subtree: true, attributes: true, attributeFilter: ['hidden', 'disabled', 'aria-disabled'] });
  show(current);
  return {
    el: host.firstElementChild,
    select: (tabId) => show(tabId),
    current: () => current,
    panel: panelOf,
    refresh() {
      for (const tab of o.tabs) {
        const b = buttonOf(tab.id);
        b.hidden = flag(tab.hidden) || b.dataset.guiPolicy === 'Hidden';
        b.setAttribute('aria-disabled', String(flag(tab.disabled) || ['Hidden', 'Disabled'].includes(b.dataset.guiPolicy)));
      }
      reconcile(); ink.update();
    },
    /** Updates a tab badge (null hides it). */
    setCount(tabId, n, tone) {
      const b = list.querySelector(`[data-tab="${CSS.escape(tabId)}"]`);
      if (!b) return;
      b.querySelector('.k-badge')?.remove();
      if (Number.isFinite(n)) b.insertAdjacentHTML('beforeend', `<span class="k-badge ${esc(tone ?? 'off')} bump">${int(n)}</span>`);
      ink.update();
    },
    destroy() {
      restrictions.disconnect();
      ink.stop();
      cleanups.forEach((fn) => { try { fn(); } catch (err) { console.error(err); } });
      host.replaceChildren();
    },
  };
}
