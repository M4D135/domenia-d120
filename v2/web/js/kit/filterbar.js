// Filter bar: removable criteria chips with their scope ([Annuaire], [Base locale], [Liste chargée]), quick facets
// that toggle, a « Ajouter un filtre » menu and the combination sentence (« → 245 lignes affichées sur 1 234 »).
// Each × says what its removal does; the perimeter chip has none (Domenia 1, RCH-040 and RCH-041).
import { glyph } from './glyphs.js';
import { openMenu } from './menu.js';
import { esc, uid, motionReduced, announce } from './util.js';

/**
 * @typedef {Object} FilterChip
 * @property {string} id
 * @property {string} label                  Criterion (« Type »).
 * @property {string} [value]                Value (« Postes »).
 * @property {'Annuaire'|'Base locale'|'Liste chargée'|string} [scope]
 * @property {boolean} [removable=true]
 * @property {string} [removeTip]            Effect of the removal (« Relit l’OU sans ce type »).
 * @property {string} [icon]
 */

/**
 * @typedef {Object} Facet
 * @property {string} id
 * @property {string} label
 * @property {number} [count]
 * @property {boolean} [pressed]
 * @property {'ok'|'warn'|'alert'|'info'|'off'} [tone]
 */

/**
 * Creates a filter bar in host (its content is replaced).
 * @param {HTMLElement} host
 * @param {{ label?: string, chips?: FilterChip[], facets?: Facet[], summary?: string, addItems?: any[], onRemove?: (id: string) => void, onClear?: () => void, onToggle?: (id: string, pressed: boolean) => void }} o
 */
export function createFilterBar(host, o) {
  const id = uid('fbar');
  let chips = o.chips ?? [];
  let facets = o.facets ?? [];
  let summary = o.summary ?? '';
  host.innerHTML = `<div class="k-fbar" role="group" aria-label="${esc(o.label ?? 'Filtres')}" id="${id}">
    <div class="k-fbar-facets" role="group" aria-label="Filtres rapides"></div>
    <ul class="k-fbar-chips" aria-label="Critères appliqués"></ul>
    <div class="k-fbar-tail">
      ${o.addItems?.length ? `<button class="btn ghost sm k-fbar-add" type="button" aria-haspopup="menu" aria-expanded="false">${glyph('plus')}Ajouter un filtre</button>` : ''}
      <button class="btn ghost sm k-fbar-clear" type="button" hidden>${glyph('x')}Tout effacer</button>
      <span class="k-fbar-sum" aria-live="polite"></span>
    </div>
  </div>`;
  const facetsEl = host.querySelector('.k-fbar-facets');
  const chipsEl = host.querySelector('.k-fbar-chips');
  const clearBtn = host.querySelector('.k-fbar-clear');
  const sumEl = host.querySelector('.k-fbar-sum');
  const groupEl = /** @type {HTMLElement} */ (host.querySelector('.k-fbar'));

  // Where the focus goes when the focused control disappears: the × of a neighbour chip, else « Ajouter un filtre »,
  // else the group itself (made focusable for the occasion), never the body.
  function landFocus(except) {
    const xs = [...chipsEl.querySelectorAll('.k-chip-x')].filter((b) => !except?.contains(b));
    const at = except ? [...chipsEl.querySelectorAll('.k-chip')].indexOf(except) : -1;
    const after = xs.find((b) => except && (except.compareDocumentPosition(b) & Node.DOCUMENT_POSITION_FOLLOWING));
    const target = after ?? (at > 0 ? xs.at(-1) : xs[0]) ?? host.querySelector('.k-fbar-add');
    if (target instanceof HTMLElement) { target.focus({ preventScroll: true }); return; }
    groupEl.tabIndex = -1;
    groupEl.focus({ preventScroll: true });
  }

  function chipMarkup(c, n) {
    const removable = c.removable !== false;
    const scope = c.scope ? `<span class="k-chip-scope">${esc(c.scope)}</span>` : '';
    const x = removable ? `<button class="k-chip-x" type="button" aria-label="Retirer ${esc(c.label)}${c.value ? ` ${esc(c.value)}` : ''}" data-tip="${esc(c.removeTip ?? 'Retirer ce critère')}" data-remove="${esc(c.id)}">${glyph('x')}</button>` : '';
    return `<li class="k-chip${removable ? '' : ' fixed'}" data-id="${esc(c.id)}" data-j="${n}">${c.icon ? glyph(c.icon, 'k-chip-ico') : ''}`
      + `<span class="k-chip-text"><span class="k-chip-label">${esc(c.label)}</span>${c.value ? `<b>${esc(c.value)}</b>` : ''}</span>${scope}${x}</li>`;
  }

  function renderChips(animateIn = new Set()) {
    chipsEl.innerHTML = chips.map(chipMarkup).join('');
    chipsEl.querySelectorAll('.k-chip').forEach((li) => {
      li.style.setProperty('--j', li.dataset.j);
      if (animateIn.has(li.dataset.id)) li.classList.add('k-chip-in');
    });
    clearBtn.hidden = !chips.some((c) => c.removable !== false);
  }

  function renderFacets() {
    facetsEl.hidden = facets.length === 0;
    facetsEl.innerHTML = facets.map((f) => `<button class="k-facet${f.tone ? ` ${esc(f.tone)}` : ''}" type="button" aria-pressed="${!!f.pressed}" data-facet="${esc(f.id)}">`
      + `<span class="k-facet-check" aria-hidden="true">${glyph('check')}</span>${esc(f.label)}${Number.isFinite(f.count) ? `<span class="k-facet-n">${esc(f.count)}</span>` : ''}</button>`).join('');
  }

  // Removing a chip: it leaves, the others slide into place (FLIP, transform only).
  function removeChip(chipId) {
    const li = chipsEl.querySelector(`.k-chip[data-id="${CSS.escape(chipId)}"]`);
    const chip = chips.find((c) => c.id === chipId);
    if (!li || !chip) return;
    const others = [...chipsEl.querySelectorAll('.k-chip')].filter((x) => x !== li);
    const before = others.map((x) => x.getBoundingClientRect().left);
    // The × that had the focus leaves with its chip: the focus moves to a neighbour first.
    if (li.contains(document.activeElement)) landFocus(li);
    const finish = () => {
      chips = chips.filter((c) => c.id !== chipId);
      li.remove();
      if (!motionReduced() && typeof Element.prototype.animate === 'function') {
        others.forEach((x, n) => {
          const dx = before[n] - x.getBoundingClientRect().left;
          if (Math.abs(dx) > 0.5) x.animate([{ transform: `translateX(${dx}px)` }, { transform: 'none' }], { duration: 320, easing: 'cubic-bezier(.16, 1, .3, 1)' });
        });
      }
      clearBtn.hidden = !chips.some((c) => c.removable !== false);
      announce(`Critère ${chip.label} retiré.`);
      o.onRemove?.(chipId);
    };
    if (motionReduced()) { finish(); return; }
    li.classList.add('leaving');
    li.addEventListener('animationend', finish, { once: true });
    setTimeout(() => { if (li.isConnected) finish(); }, 400);
  }

  host.addEventListener('click', (e) => {
    const t = e.target instanceof Element ? e.target : null;
    if (!t) return;
    const x = t.closest('[data-remove]');
    if (x) { removeChip(x.dataset.remove); return; }
    const f = t.closest('[data-facet]');
    if (f) {
      const facet = facets.find((v) => v.id === f.dataset.facet);
      if (!facet) return;
      facet.pressed = !facet.pressed;
      f.setAttribute('aria-pressed', String(facet.pressed));
      o.onToggle?.(facet.id, facet.pressed);
      return;
    }
    if (t.closest('.k-fbar-clear')) {
      const removable = chips.filter((c) => c.removable !== false).map((c) => c.id);
      const hadFocus = host.contains(document.activeElement);
      chips = chips.filter((c) => c.removable === false);
      renderChips();
      // « Tout effacer » hides itself: the focus goes to « Ajouter un filtre » (or the group).
      if (hadFocus) landFocus(null);
      announce('Critères retirés.');
      if (o.onClear) o.onClear(); else removable.forEach((r) => o.onRemove?.(r));
      return;
    }
    const add = t.closest('.k-fbar-add');
    if (add && o.addItems?.length) openMenu(add, o.addItems, { label: 'Ajouter un filtre' });
  });

  renderFacets();
  renderChips();
  sumEl.textContent = summary;

  return {
    el: host.firstElementChild,
    /** Replaces the chips; new ones pop in. */
    setChips(next) {
      const known = new Set(chips.map((c) => c.id));
      chips = next.slice();
      renderChips(new Set(chips.filter((c) => !known.has(c.id)).map((c) => c.id)));
    },
    setFacets(next) { facets = next.slice(); renderFacets(); },
    /** Current chips (copies). */
    getChips: () => chips.map((c) => ({ ...c })),
    /** Combination sentence, e.g. « → 245 lignes affichées sur 1 234 ». */
    setSummary(text) {
      summary = text ?? '';
      if (sumEl.textContent === summary) return;
      sumEl.textContent = summary;
      sumEl.classList.remove('bump');
      void sumEl.offsetWidth;
      sumEl.classList.add('bump');
    },
    destroy() { host.replaceChildren(); },
  };
}
