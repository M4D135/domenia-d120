// Floating tooltips of the whole window (one element outside every overflow box). Two sources: data-tip (a short text set by
// the screen or the kit) and data-help (a key of the help catalogue, TRV-004). The catalogue tooltip follows the role of the
// control: none on a container, the first sentence on an icon button, the whole text otherwise; delays 350 / 100 ms,
// 20 s at most, shown on a greyed control with its reason (TRV-006). Elements with data-help also get their accessible
// description from the catalogue.
import { esc } from '../ui.js';
import { state } from './store.js';
import { loadHelp, topicNow, helpRole, presentation, helpLoaded } from './help.js';

const FIRST_DELAY = 350;
const NEXT_DELAY = 100;
const SHOW_FOR = 20_000;

let tip = null;
let owner = null;
let timer = 0;
let lifeTimer = 0;
let navEl = null;

const root = document.documentElement;

function place(el) {
  const r = el.getBoundingClientRect();
  const w = tip.offsetWidth;
  const h = tip.offsetHeight;
  let x;
  let y;
  if (el.closest('.nav')) { x = r.right + 10; y = r.top + r.height / 2 - h / 2; }
  else if (r.top < 140) { x = r.left + r.width / 2 - w / 2; y = r.bottom + 8; }
  else { x = r.left + r.width / 2 - w / 2; y = r.top - h - 8; }
  x = Math.max(8, Math.min(innerWidth - w - 8, x));
  y = Math.max(8, Math.min(innerHeight - h - 8, y));
  tip.style.setProperty('--tx', `${Math.round(x)}px`);
  tip.style.setProperty('--ty', `${Math.round(y)}px`);
}

/** Text of the tooltip of an element: [title, text, reason] or null when it has none. */
function content(el) {
  const disabled = el.getAttribute('aria-disabled') === 'true' || el.disabled === true;
  const reason = disabled ? (el.dataset.reason ?? '') : '';
  const key = el.dataset.help;
  if (key && state.prefs.helpTips !== false) {
    const topic = topicNow(key);
    if (topic) {
      const role = helpRole(el, topic.kind);
      const { tip: text } = presentation(topic.text, role);
      if (!text && !reason) return el.dataset.tip ? [null, el.dataset.tip, null] : null;
      return [role === 'iconButton' ? null : topic.title, text || topic.title, reason || null];
    }
  }
  const text = el.dataset.tip ?? '';
  if (!text && !reason) return null;
  return [null, text || reason, text && reason && text !== reason ? reason : null];
}

// Unfolded menu: its items show their label, so they need no tip.
const wanted = (el) => !(el.closest('.nav-item') && navEl && navEl.getBoundingClientRect().width > 120 && !el.dataset.help);

function show(el) {
  if (!el.isConnected || !wanted(el)) return;
  // An element not laid out yet (a panel still entering, a hidden branch) has no place for a tooltip.
  const box = el.getBoundingClientRect();
  if (box.width === 0 && box.height === 0) return;
  const parts = content(el);
  if (!parts) {
    if (el.dataset.help && !helpLoaded()) loadHelp().then(() => { if (owner === el) show(el); }).catch(() => {});
    return;
  }
  const [title, text, reason] = parts;
  const wasOn = tip.classList.contains('on');
  owner = el;
  tip.innerHTML = `${title ? `<span class="flytip-title">${esc(title)}</span>` : ''}<span class="flytip-text">${esc(text)}</span>${reason ? `<span class="flytip-reason">${esc(reason)}</span>` : ''}`;
  tip.classList.toggle('wide', !!title || String(text).length > 80);
  if (!wasOn) tip.classList.add('jump');
  place(el);
  if (!wasOn) { void tip.offsetWidth; tip.classList.remove('jump'); }
  tip.classList.add('on');
  clearTimeout(lifeTimer);
  lifeTimer = setTimeout(hide, SHOW_FOR);
}

function hide() {
  clearTimeout(timer);
  clearTimeout(lifeTimer);
  owner = null;
  tip?.classList.remove('on');
}

function target(e) {
  return e.target instanceof Element ? e.target.closest('[data-tip], [data-help], [data-reason]') : null;
}

/** Installs the floating tooltips (once). */
export function initTips(nav) {
  if (tip) return;
  navEl = nav;
  root.classList.add('js-tips');
  tip = document.createElement('div');
  tip.className = 'flytip';
  tip.setAttribute('aria-hidden', 'true');
  document.body.appendChild(tip);
  document.addEventListener('pointerover', (e) => {
    const el = target(e);
    if (el === owner) return;
    clearTimeout(timer);
    if (!el) { hide(); return; }
    timer = setTimeout(() => show(el), tip.classList.contains('on') ? NEXT_DELAY : FIRST_DELAY);
  });
  document.addEventListener('focusin', (e) => {
    const el = target(e);
    if (el && el.matches(':focus-visible')) show(el); else hide();
  });
  ['pointerdown', 'focusout', 'wheel'].forEach((t) => document.addEventListener(t, hide, { passive: true }));
  document.addEventListener('keydown', (e) => { if (e.key === 'Escape') hide(); });
  watchDescriptions();
}

// ---------- Accessible descriptions of the catalogued controls ----------

let pendingScan = 0;

function describe(scope) {
  for (const el of scope.querySelectorAll('[data-help]')) {
    if (el.hasAttribute('aria-description') || el.dataset.helpDescribed === '1') continue;
    const topic = topicNow(el.dataset.help);
    if (!topic) continue;
    el.setAttribute('aria-description', topic.text);
    el.dataset.helpDescribed = '1';
  }
}

function watchDescriptions() {
  const scan = () => {
    pendingScan = 0;
    if (!document.querySelector('[data-help]:not([data-help-described])')) return;
    if (helpLoaded()) describe(document);
    else loadHelp().then(() => describe(document)).catch(() => {});
  };
  new MutationObserver(() => {
    if (!pendingScan) pendingScan = setTimeout(scan, 300);
  }).observe(document.body, { childList: true, subtree: true });
  scan();
}
