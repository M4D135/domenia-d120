// Hash router (#/accueil, #/fiche?dn=…): loads pages/<id>.js, and css/pages/<id>.css only when the module declares it
// (export const stylesheet = true), swaps the screen with a view transition, moves the nav pill. No list of pages here: the navigation of app.js is the only one. A route without
// its own module shows pages/_todo.js; a route outside the navigation exists only if its module exports `meta`
// (hidden screens such as #/kit).
import { icon } from './icons.js';
import { createPageLoader, validatePages } from './shell/page-preflight.js';
import { esc, errorText, motionReduced, announce } from './ui.js';

const fallback = () => import('./pages/_todo.js');

// Readiness signal read by the host in capture mode (docs/CAPTURE.md): <html data-ready="<route>"> once the route is
// mounted, no bridge call is in flight and the screen shows no skeleton nor busy region. Nothing reads it otherwise.
const READY_POLL_MS = 80;
const READY_GIVE_UP_MS = 120_000;
// A declared stylesheet is required: a missing or unreadable file must not qualify an unstyled page.
const CSS_WAIT_MS = 10_000;
const MAX_PARAM_LENGTH = 2048;
const docRoot = document.documentElement;

// Route ids are lower-case words with dashes: they become file names, so nothing else is accepted (no « _todo », no
// path). The query string carries the parameters: #/fiche?dn=CN%3D…&tab=membres.
function parseHash(hash = location.hash) {
  const m = /^#\/([a-z0-9]+(?:-[a-z0-9]+)*)(?:\?(.*))?$/i.exec(hash);
  if (!m) return { id: '', params: {} };
  const params = {};
  if (m[2]) {
    for (const [k, v] of new URLSearchParams(m[2])) {
      if (k && !(k in params) && v.length <= MAX_PARAM_LENGTH) params[k] = v;
    }
  }
  return { id: m[1].toLowerCase(), params: Object.freeze(params) };
}

/**
 * Hash of a route: link('fiche', { dn }) → '#/fiche?dn=…'.
 * @param {string} id @param {Object<string, string|number|boolean|null|undefined>} [params]
 */
export function link(id, params = {}) {
  const q = new URLSearchParams();
  for (const [k, v] of Object.entries(params)) if (v !== null && v !== undefined && v !== '') q.set(k, String(v));
  const s = q.toString();
  return `#/${id}${s ? `?${s}` : ''}`;
}

function errorPage(err) {
  return {
    render(main) {
      main.innerHTML = `<div class="page"><section class="card error-card" role="alert"><div class="empty">
        <div class="art">${icon('alert')}</div><h2>Cet écran n’a pas pu s’ouvrir</h2>
        <p>${esc(errorText(err, 'Le module de cet écran n’a pas pu être chargé.'))}</p>
        <button class="btn primary" type="button" data-retry>${icon('refresh')}Réessayer</button>
      </div></section></div>`;
      main.querySelector('[data-retry]').addEventListener('click', () => location.reload());
    },
  };
}

// A missing module (404) is « not ported yet »; a module that exists but fails (syntax, evaluation) is an error.
function isMissingModule(err) {
  if (!(err instanceof TypeError)) return false;
  return /dynamically imported module|Importing a module script failed|error loading dynamically imported module/i.test(String(err.message));
}

// ---------- Page modules ----------

const loadVerifiedPage = createPageLoader();
async function loadModule(id, required = false) {
  try { return { mod: await loadVerifiedPage(id), own: true }; }
  catch (err) {
    if (required || !isMissingModule(err)) throw err;
    return { mod: await fallback(), own: false };
  }
}

// ---------- Page stylesheets (css/pages/<id>.css, declared by the module) ----------

const sheets = new Map(); // id → { link: HTMLLinkElement|null, ready: Promise<void> }

function loadSheet(id) {
  let entry = sheets.get(id);
  if (!entry) {
    const linkEl = document.createElement('link');
    linkEl.rel = 'stylesheet';
    linkEl.href = `css/pages/${id}.css`;
    linkEl.dataset.page = id;
    entry = { link: linkEl, ready: null };
    entry.ready = new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error(`Styles de l’écran ${id} hors délai.`)), CSS_WAIT_MS);
      linkEl.addEventListener('load', () => { clearTimeout(timer); resolve(); }, { once: true });
      linkEl.addEventListener('error', () => { clearTimeout(timer); reject(new Error(`Styles de l’écran ${id} indisponibles.`)); }, { once: true });
    });
    entry.ready.catch(() => { linkEl.remove(); if (sheets.get(id) === entry) sheets.delete(id); });
    document.head.appendChild(linkEl);
    sheets.set(id, entry);
  }
  return entry.ready;
}

// Only the stylesheet of the screen shown applies (screens never style each other).
function activateSheet(id) {
  for (const [key, entry] of sheets) if (entry.link) entry.link.disabled = key !== id;
}

/**
 * @param {{ main: HTMLElement, nav: HTMLElement, pages: Array<{id: string, label: string, icon?: string, section?: string|null}>,
 *   context: (page: any) => Object, defaultId?: string, onChange?: (page: any) => void, onReady?: (page: any) => void, onError?: (error: any, id: string) => void, isBusy?: () => boolean }} opts
 * context(page) → object handed to render(main, ctx); the router adds ctx.params (frozen), ctx.route, ctx.link,
 * ctx.navigate(id, params) and ctx.guardLeave(fn). isBusy() → true while a bridge call of the page is in flight (readiness
 * signal). guardLeave(fn): fn({ hash, same }) → Promise<boolean> is asked before the screen is left or rendered again (unsaved
 * input, Domenia 1 Test-DomeniaDraftNavigation); false keeps the screen and puts its address back. One guard per screen,
 * removed when the screen changes.
 */
export function createRouter({ main, nav, pages, context, defaultId = 'accueil', onChange, onReady, onError, beforeNavigate, isBusy = () => false, loadPage = loadModule }) {
  const requiredPages = validatePages(pages);
  let cleanup = null;
  let token = 0;
  let currentId = null;
  let currentParams = {};
  let currentHash = location.hash;
  let leaveGuard = null;
  let guarding = false;

  const runCleanup = () => {
    const fn = cleanup;
    cleanup = null;
    if (typeof fn === 'function') {
      try { fn(); } catch (err) { console.error(err); }
    }
  };

  function updatePill() {
    const pill = nav.querySelector('.nav-pill');
    const item = nav.querySelector('.nav-item[aria-current="page"]');
    if (!pill) return;
    if (!item) { pill.style.setProperty('--y', '-100px'); return; }
    pill.style.setProperty('--y', `${item.offsetTop}px`);
    pill.style.setProperty('--h', `${item.offsetHeight}px`);
  }

  function markNav(id) {
    nav.querySelectorAll('.nav-item[data-id]').forEach((el) => {
      if (el.dataset.id === id) el.setAttribute('aria-current', 'page');
      else el.removeAttribute('aria-current');
    });
    updatePill();
  }

  // Sets data-ready once the screen of render `my` is quiet on two checks in a row (a call chained right after
  // another one is never taken for the end) and its view transition has finished, so a click right after ready reaches the
  // page and not the transition overlay; a newer render stops the watch.
  function watchReady(id, my, settled = Promise.resolve(), healthy = true) {
    const started = performance.now();
    let calm = 0;
    const check = () => {
      if (my !== token) return;
      const quiet = !isBusy() && !main.querySelector('.skeleton, [aria-busy="true"]');
      calm = quiet ? calm + 1 : 0;
      if (calm >= 2) {
        settled.then(() => {
          if (my !== token) return;
          docRoot.dataset.ready = id;
          if (healthy) onReady?.(pages.find(page => page.id === id) ?? { id });
        });
        return;
      }
      if (performance.now() - started < READY_GIVE_UP_MS) setTimeout(check, READY_POLL_MS);
      else onError?.(new Error('Écran encore occupé après deux minutes.'), id);
    };
    setTimeout(check, READY_POLL_MS);
  }

  function navigate(id, params = {}) {
    const target = link(id, params);
    if (location.hash === target) render(); else location.hash = target;
  }

  // first: initial render at start-up (focus stays where the browser put it).
  async function mount(mod, page, params, my, first) {
    runCleanup();
    const pageHost = document.createElement('div');
    pageHost.className = 'main';
    pageHost.dataset.page = page.id;
    // Keep the shell's scroll/focus element stable while each async render owns a disposable DOM subtree.
    // display:contents preserves the existing layout boxes and page-scoped selectors.
    pageHost.style.display = 'contents';
    main.replaceChildren(pageHost);
    main.scrollTop = 0;
    // Page stylesheets scope their rules under [data-page="<id>"] (docs/KIT.md).
    main.dataset.page = page.id;
    activateSheet(page.id);
    let out;
    const route = Object.freeze({ id: page.id, params, hash: link(page.id, params) });
    leaveGuard = null;
    const guardLeave = (fn) => {
      if (my !== token) return () => {};
      const mine = my;
      leaveGuard = typeof fn === 'function' ? fn : null;
      return () => { if (mine === token && leaveGuard === fn) leaveGuard = null; };
    };
    try {
      out = await mod.render(pageHost, { ...context(page), viewport: main, params, route, link, navigate: (id, next) => { if (my === token) navigate(id, next); }, guardLeave });
    } catch (err) {
      console.error(err);
      if (my === token) { errorPage(err).render(pageHost); onError?.(err, page.id); }
      return false;
    } finally {
      if (!first && my === token) {
        // Keyboard and screen reader users land on the new screen, which is announced by name.
        main.focus({ preventScroll: true });
        announce(`Écran ${page.label}`);
      }
    }
    if (typeof out === 'function') { if (my === token) cleanup = out; else out(); }
    return true;
  }

  async function render(event) {
    // Unsaved input of the screen shown: its guard is asked first; a refusal keeps the screen and its address.
    const previous = currentId === null ? location.hash : currentHash;
    if (guarding) {
      if (location.hash !== previous) history.replaceState(null, '', previous);
      return;
    }
    if ((leaveGuard || beforeNavigate) && currentId !== null) {
      const fn = leaveGuard;
      const guardedGeneration = token;
      guarding = true;
      let ok = true;
      try {
        ok = beforeNavigate ? await beforeNavigate(parseHash().id) : true;
        if (ok && fn) ok = await fn({ hash: location.hash, same: location.hash === previous });
      } catch (err) {
        console.error(err);
        ok = false;
      } finally {
        if (guardedGeneration === token) guarding = false;
      }
      if (guardedGeneration !== token) return;
      if (!ok) {
        if (location.hash !== previous) history.replaceState(null, '', previous);
        return;
      }
      if (leaveGuard === fn) leaveGuard = null;
    }
    delete docRoot.dataset.ready; // the previous screen is no longer the one being shown
    const { id, params } = parseHash();
    const listed = pages.find((p) => p.id === id);
    const my = ++token;
    if (!id) {
      history.replaceState(null, '', `#/${defaultId}`); // no hashchange: render directly
      if (pages.some((p) => p.id === defaultId)) render();
      return;
    }
    let loaded;
    try {
      loaded = await loadPage(id, requiredPages.has(id));
      // Only a screen whose own module declares a stylesheet asks for one: no request (and no 404) for the others, for
      // a screen being ported, nor for an unknown route.
      if (loaded.own && loaded.mod?.stylesheet === true) await loadSheet(id);
    } catch (err) {
      if (my !== token) return;
      console.error(err);
      onError?.(err, id);
      loaded = { mod: errorPage(err), own: true, failed: true };
    }
    if (my !== token) return;
    // A route outside the navigation needs its own module declaring itself (export const meta = { label, icon }).
    const meta = loaded.own && loaded.mod?.meta && typeof loaded.mod.meta.label === 'string' ? loaded.mod.meta : null;
    const page = listed ?? (meta ? { id, label: meta.label, icon: meta.icon ?? 'sparkles', section: null, hidden: true } : null);
    if (!page) {
      if (!loaded.own) console.warn(`Route inconnue : #/${id}`);
      history.replaceState(null, '', `#/${defaultId}`);
      if (id !== defaultId) render();
      return;
    }
    markNav(id);
    document.title = `${page.label} · Domenia`;
    const first = currentId === null;
    currentId = id;
    currentParams = params;
    currentHash = location.hash;
    // A view transition skipped by a newer navigation still runs its callback: only the latest one mounts.
    // The update callback runs after startViewTransition returns, so `settled` is already the transition's end.
    let settled = Promise.resolve();
    const swap = () => {
      if (my !== token) return;
      void mount(loaded.mod, page, params, my, first).then(healthy => {
        if (my === token) watchReady(page.id, my, settled, healthy && !loaded.failed);
      });
    };
    if (!first && document.startViewTransition && !motionReduced()) {
      const vt = document.startViewTransition(swap);
      settled = vt.finished.catch(() => {});
      vt.updateCallbackDone.catch((err) => console.error(err));
    } else {
      swap();
    }
    if (onChange) onChange(page);
  }

  const invalidateSession = () => {
    ++token;
    leaveGuard = null;
    guarding = false;
    currentId = null;
    runCleanup();
    main.replaceChildren();
    delete docRoot.dataset.ready;
  };
  window.addEventListener('domenia:session-invalidating', invalidateSession);
  window.addEventListener('hashchange', render);

  return {
    start: render,
    preload: id => loadPage(id, true),
    destroy() { ++token; runCleanup(); window.removeEventListener('hashchange', render); window.removeEventListener('domenia:session-invalidating', invalidateSession); },
    /** Goes to a screen; params become the query string of the hash. Same hash: renders again. */
    go(id, params) {
      navigate(id, params ?? {});
    },
    navigate,
    link,
    current: () => currentId,
    params: () => currentParams,
    updatePill,
  };
}
