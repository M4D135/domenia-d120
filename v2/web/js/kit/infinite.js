// Infinite pagination for lists and cards. By default the next page is read on an explicit click (« Charger la
// suite »): a network read never starts by itself. auto: true reads when the end comes into view, for local reads
// (base, already loaded data) only. States: loading, end of list, error with retry. maxHeight bounds the list in its
// own scroller: automatic reading then follows that scroller, never the whole page (which would grow without end).
import { glyph } from './glyphs.js';
import { esc, count, int, announce, setVars } from './util.js';
import { errorText } from '../ui.js';

/**
 * @typedef {Object} InfiniteOptions
 * @property {(cursor: any) => Promise<{ items: any[], next?: any, total?: number }>} load  next undefined/null: end.
 * @property {(items: any[], list: HTMLElement, first: boolean) => void} render              Appends the items to list.
 * @property {boolean} [auto=false]          Reads when the end is visible (local reads only).
 * @property {string} [label]                Accessible name of the list region.
 * @property {[string, string]} [noun]       Singular and plural (« élément », « éléments »).
 * @property {string} [empty]                Text when the first page is empty.
 * @property {string} [listTag='div']        'ul' or 'ol' for a list of <li>.
 * @property {number} [maxHeight]            Height in px of its own scroller (recommended with auto).
 */

/**
 * Creates an infinite list in host (its content is replaced). The first page is read at once.
 * @param {HTMLElement} host
 * @param {InfiniteOptions} o
 */
export function createInfinite(host, o) {
  const tag = ['ul', 'ol'].includes(o.listTag) ? o.listTag : 'div';
  const [one, many] = o.noun ?? ['élément', 'éléments'];
  const bounded = Number.isFinite(o.maxHeight) && o.maxHeight > 0;
  host.innerHTML = `<div class="k-inf${bounded ? ' bounded' : ''}" role="region" aria-label="${esc(o.label ?? 'Liste')}"${bounded ? ' tabindex="0"' : ''}>
    <${tag} class="k-inf-list"></${tag}>
    <div class="k-inf-foot"></div>
  </div>`;
  const list = /** @type {HTMLElement} */ (host.querySelector('.k-inf-list'));
  const foot = /** @type {HTMLElement} */ (host.querySelector('.k-inf-foot'));
  const region = /** @type {HTMLElement} */ (host.querySelector('.k-inf'));
  if (bounded) setVars(region, { '--k-inf-max': `${Math.round(o.maxHeight)}px` });
  let cursor = null;
  let hasMore = true;
  let loading = false;
  let error = null;
  let loaded = 0;
  let total = null;
  let gen = 0;
  let io = null;

  function paint() {
    if (loading) {
      foot.innerHTML = `<span class="k-inf-state" aria-busy="true"><span class="k-spin" aria-hidden="true"></span>Chargement…</span>`;
      return;
    }
    if (error) {
      foot.innerHTML = `<span class="k-inf-state err" role="alert">${glyph('alert')}${esc(error)}</span><button class="btn sm" type="button" data-more>${glyph('refresh')}Réessayer</button>`;
      return;
    }
    if (loaded === 0 && !hasMore) {
      foot.innerHTML = `<span class="k-inf-state">${esc(o.empty ?? 'Rien à afficher.')}</span>`;
      return;
    }
    // « 15 objets chargés sur 120 »: the noun once only.
    const of = Number.isFinite(total) && total !== loaded ? ` sur ${int(total)}` : '';
    if (!hasMore) {
      foot.innerHTML = `<span class="k-inf-state end">${glyph('check')}Fin de la liste · ${count(loaded, one, many)}${esc(of)}</span>`;
      return;
    }
    foot.innerHTML = `<span class="k-inf-count">${count(loaded, `${one} chargé`, `${many} chargés`)}${esc(of)}</span>`
      + `<button class="btn sm" type="button" data-more>${glyph('arrowDown')}Charger la suite</button><span class="k-inf-sentinel" aria-hidden="true"></span>`;
    if (o.auto) observe();
  }

  function observe() {
    if (!('IntersectionObserver' in window)) return;
    io?.disconnect();
    const sentinel = foot.querySelector('.k-inf-sentinel');
    if (!sentinel) return;
    io = new IntersectionObserver((entries) => {
      if (entries.some((e) => e.isIntersecting)) more();
    }, { root: bounded ? region : null, rootMargin: '0px 0px 240px 0px' });
    io.observe(sentinel);
  }

  async function more() {
    if (loading || !hasMore) return;
    loading = true;
    error = null;
    io?.disconnect();
    const my = ++gen;
    const first = loaded === 0;
    paint();
    try {
      const page = await o.load(cursor);
      if (my !== gen) return;
      const items = Array.isArray(page?.items) ? page.items : [];
      cursor = page?.next ?? null;
      hasMore = page?.next !== undefined && page?.next !== null;
      if (Number.isFinite(page?.total)) total = page.total;
      const before = list.children.length;
      o.render(items, list, first);
      [...list.children].slice(before).forEach((el, n) => { el.classList.add('k-inf-in'); el.style.setProperty('--j', String(Math.min(n, 14))); });
      loaded += items.length;
      if (!first) announce(`${count(items.length, `${one} ajouté`, `${many} ajoutés`)}.`);
    } catch (err) {
      if (my !== gen) return;
      if (!err?.code) console.error(err);
      error = errorText(err, 'Lecture de la suite impossible.');
    } finally {
      if (my === gen) { loading = false; paint(); }
    }
  }

  foot.addEventListener('click', (e) => {
    if (e.target instanceof Element && e.target.closest('[data-more]')) more();
  });

  more();
  return {
    el: host.firstElementChild,
    list,
    loadMore: more,
    /** Empties the list and reads the first page again (a read in flight is ignored). */
    reset() {
      gen += 1;
      io?.disconnect();
      list.replaceChildren();
      cursor = null; hasMore = true; loading = false; error = null; loaded = 0; total = null;
      more();
    },
    destroy() { gen += 1; io?.disconnect(); host.replaceChildren(); },
  };
}
