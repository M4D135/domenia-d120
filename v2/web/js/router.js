// Hash router (#/accueil…): loads pages/<id>.js, swaps it in with a view transition, moves the nav pill.
import { icon } from './icons.js';
import { esc, errorText, motionReduced, announce } from './ui.js';

// Pages with a dedicated module; every other route renders the generic "porting in progress" page.
const MODULES = {
  accueil: () => import('./pages/accueil.js'),
};
const fallback = () => import('./pages/_todo.js');

// Readiness signal read by the host in capture mode (docs/CAPTURE.md): <html data-ready="<route>"> once the route is
// mounted, no bridge call is in flight and the screen shows no skeleton nor busy region. Nothing reads it otherwise.
const READY_POLL_MS = 80;
const READY_GIVE_UP_MS = 120_000;
const docRoot = document.documentElement;

function parseHash() {
  const m = /^#\/([a-z0-9-]+)/i.exec(location.hash);
  return m ? m[1].toLowerCase() : '';
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

// pages: [{ id, label, icon, section }]; context(page) → object handed to render(main, ctx);
// isBusy() → true while a bridge call of the page is in flight (readiness signal).
export function createRouter({ main, nav, pages, context, defaultId = 'accueil', onChange, isBusy = () => false }) {
  let cleanup = null;
  let token = 0;
  let currentId = null;

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
  // another one is never taken for the end); a newer render stops the watch.
  function watchReady(id, my) {
    const started = performance.now();
    let calm = 0;
    const check = () => {
      if (my !== token) return;
      const quiet = !isBusy() && !main.querySelector('.skeleton, [aria-busy="true"]');
      calm = quiet ? calm + 1 : 0;
      if (calm >= 2) { docRoot.dataset.ready = id; return; }
      if (performance.now() - started < READY_GIVE_UP_MS) setTimeout(check, READY_POLL_MS);
    };
    setTimeout(check, READY_POLL_MS);
  }

  // first: initial render at start-up (focus stays where the browser put it).
  function mount(mod, page, my, first) {
    runCleanup();
    main.replaceChildren();
    main.scrollTop = 0;
    let out;
    try {
      out = mod.render(main, context(page));
    } catch (err) {
      console.error(err);
      errorPage(err).render(main);
      return;
    } finally {
      if (!first) {
        // Keyboard and screen reader users land on the new screen, which is announced by name.
        main.focus({ preventScroll: true });
        announce(`Écran ${page.label}`);
      }
    }
    if (typeof out === 'function') cleanup = out;
    else if (out && typeof out.then === 'function') {
      out.then((fn) => {
        if (typeof fn !== 'function') return;
        if (my === token) cleanup = fn; else fn();
      }).catch((err) => console.error(err));
    }
  }

  async function render() {
    delete docRoot.dataset.ready; // the previous screen is no longer the one being shown
    const id = parseHash();
    const page = pages.find((p) => p.id === id);
    if (!page) {
      history.replaceState(null, '', `#/${defaultId}`); // no hashchange: render directly
      if (pages.some((p) => p.id === defaultId)) render();
      return;
    }
    const my = ++token;
    markNav(id);
    document.title = `${page.label} · Domenia`;
    let mod;
    try {
      mod = await (MODULES[id] ?? fallback)();
    } catch (err) {
      console.error(err);
      mod = errorPage(err);
    }
    if (my !== token) return;
    const first = currentId === null;
    currentId = id;
    // A view transition skipped by a newer navigation still runs its callback: only the latest one mounts.
    const swap = () => {
      if (my !== token) return;
      mount(mod, page, my, first);
      watchReady(page.id, my);
    };
    if (!first && document.startViewTransition && !motionReduced()) {
      const vt = document.startViewTransition(swap);
      vt.finished.catch(() => {});
      vt.updateCallbackDone.catch((err) => console.error(err));
    } else {
      swap();
    }
    if (onChange) onChange(page);
  }

  window.addEventListener('hashchange', render);

  return {
    start: render,
    go(id) {
      if (parseHash() === id) render(); else location.hash = `#/${id}`;
    },
    current: () => currentId,
    updatePill,
  };
}
