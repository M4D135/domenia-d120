// Comptes screen: shared helpers (texts, pills, avatars, dates). Local only: nothing here calls the bridge.
import { glyph, pill, NBSP } from '../../kit/index.js';
import { esc, formatNumber, formatDateTime, relTime } from '../../ui.js';

export { NBSP };
export const COLON = `${NBSP}: `;

/** French plural (0 and 1 take the singular), numbers grouped like FrenchText. */
export const plural = (n, one, many) => `${formatNumber(n)} ${Math.abs(n) >= 2 ? many : one}`;

/** Number written into an attribute: a plain number, « NaN » for a missing measure. */
export const isNum = (v) => typeof v === 'number' && Number.isFinite(v);

/** Main status of an account row (AccountsRules.StatusLabel) → icon. */
export const STATUS_ICONS = {
  locked: 'lock', lockToCheck: 'eye', disabled: 'power', accountExpired: 'clock',
  passwordExpired: 'key', mustChange: 'key', expiring: 'clock', ok: 'check',
};

/** Tones of the password classes (AccountsRules.PasswordBlock). */
export const PASSWORD_TONES = { valid: 'ok', expiring: 'warn', expired: 'alert', mustChange: 'info', neverExpires: 'off' };
export const PASSWORD_LABELS = {
  valid: 'Valide', expiring: 'Expire bientôt', expired: 'Expiré', mustChange: 'À changer', neverExpires: 'N’expire jamais',
};
export const LOCK_LABELS = { unlocked: 'Déverrouillé', locked: 'Verrouillé', toCheck: 'À vérifier', expired: 'Verrouillage échu' };
export const LOCK_TONES = { unlocked: 'ok', locked: 'alert', toCheck: 'warn', expired: 'info' };

/** Initials of a display name (« Camille Bernard » → « CB », « Le Gall, Anne » → « LA »). */
export function initials(name) {
  const parts = String(name ?? '').replace(/[,()]/g, ' ').split(/[\s-]+/).filter(Boolean);
  if (!parts.length) return '?';
  const first = parts[0][0] ?? '';
  const last = parts.length > 1 ? parts[parts.length - 1][0] : (parts[0][1] ?? '');
  return (first + last).toLocaleUpperCase('fr');
}

/** Stable hue (0 to 359) of a text: the same account always gets the same avatar colour. */
export function hueOf(text) {
  let h = 2166136261;
  for (const ch of String(text ?? '')) {
    h ^= ch.codePointAt(0);
    h = Math.imul(h, 16777619) >>> 0;
  }
  return h % 360;
}

/** Avatar markup: one of twelve hues chosen by the account key (CSS classes: no style attribute, works in virtual rows). */
export function avatar(name, key, size = '') {
  return `<span class="cpt-avatar hue-${hueOf(key ?? name) % 12}${size ? ` ${size}` : ''}" aria-hidden="true">${esc(initials(name))}</span>`;
}

/** Kept for the callers: the hue is a class, nothing to paint. */
export function paintAvatars() {}

/**
 * Resolves true once a kit drawer is really open (a modal drawer already open makes the request wait), false when it is
 * withdrawn first (screen left, closed while waiting). Same rule as web/js/write-flow.js.
 */
export function whenOpen(panel) {
  if (panel.body) return Promise.resolve(true);
  return new Promise((resolve) => {
    let done = false;
    panel.closed.then(() => { if (!done) { done = true; resolve(false); } });
    const poll = () => {
      if (done) return;
      if (panel.body) { done = true; resolve(true); return; }
      setTimeout(poll, 100);
    };
    poll();
  });
}

/** Pill of the main status of an account. */
export function statusPill(row, size = 'sm') {
  return pill(row.tone, row.statusLabel, { icon: STATUS_ICONS[row.status] ?? 'info', size });
}

/** « 21 oct. 2026, 18:08 » or null. */
export const when = (iso) => formatDateTime(iso);

/** Relative date with the full date in the tip (keyboard reachable). */
export function relSpan(iso, { prefix = '', none = '—' } = {}) {
  if (!iso) return `<span class="cpt-none">${esc(none)}</span>`;
  const rel = relTime(iso);
  return `<span class="cpt-rel" tabindex="0" data-tip="${esc(when(iso) ?? '')}">${esc(prefix + (rel ?? when(iso) ?? ''))}</span>`;
}

/** Local day « 15/11/2026 » of an ISO date. */
export function dayText(iso) {
  const t = Date.parse(iso ?? '');
  if (Number.isNaN(t)) return null;
  const d = new Date(t);
  return `${String(d.getDate()).padStart(2, '0')}/${String(d.getMonth() + 1).padStart(2, '0')}/${d.getFullYear()}`;
}

/** Local « yyyy-MM-dd » of a Date (input type=date). */
export function isoDay(date) {
  return `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, '0')}-${String(date.getDate()).padStart(2, '0')}`;
}

/** Days from now to an ISO date (negative in the past), rounded towards the nearest day. */
export function daysTo(iso) {
  const t = Date.parse(iso ?? '');
  return Number.isNaN(t) ? null : Math.round((t - Date.now()) / 86_400_000);
}

/** Section heading of the screen (same rhythm as the Accueil). */
export function sectionHead(title, note = '', extra = '') {
  return `<div class="cpt-sec reveal"><h2>${esc(title)}</h2>${note ? `<span class="cpt-sec-note">${esc(note)}</span>` : ''}${extra}</div>`;
}

/** Empty state block (illustration, title, text, optional actions markup). */
export function emptyState({ iconName = 'users', title, text = '', actions = '', tone = '' }) {
  return `<div class="cpt-empty ${tone}"><span class="cpt-empty-art">${glyph(iconName)}</span>`
    + `<h3>${esc(title)}</h3>${text ? `<p>${esc(text)}</p>` : ''}${actions ? `<div class="cpt-empty-actions">${actions}</div>` : ''}</div>`;
}

/** Skeleton lines for a loading area (the router waits while a skeleton is shown in .main). */
export function skeletonLines(n = 4) {
  return `<div class="cpt-sk">${Array.from({ length: n }, (_, i) => `<span class="skeleton cpt-sk-line w${[85, 65, 75, 50, 90, 60][i % 6]}"></span>`).join('')}</div>`;
}

/** Glyph with a fixed class (inline SVG, aria-hidden). */
export const g = (name, cls = '') => glyph(name, cls);

/**
 * Password fields with an eye (Domenia 1 TRV-219, Show-DomeniaSecretPeek): a click shows the typed password for a few seconds
 * (5 by default) then hides it; a second click, a keystroke in the field or the end of the delay hides it at once. Nothing is
 * copied anywhere. Returns { show(input), hideAll(), destroy() }.
 * @param {HTMLElement} scope @param {{ seconds?: number }} [o]
 */
export function bindReveal(scope, { seconds = 5 } = {}) {
  const timers = new Map();
  const buttonOf = (input) => input.parentElement?.querySelector('[data-reveal]') ?? null;
  const set = (input, shown) => {
    input.type = shown ? 'text' : 'password';
    const b = buttonOf(input);
    if (b) {
      b.setAttribute('aria-pressed', String(shown));
      b.innerHTML = glyph(shown ? 'eyeOff' : 'eye');
      b.dataset.tip = shown ? 'Masquer' : `Afficher ${seconds}${NBSP}s`;
      b.setAttribute('aria-label', shown ? 'Masquer le mot de passe' : 'Afficher le mot de passe quelques secondes');
    }
    clearTimeout(timers.get(input));
    timers.delete(input);
    if (shown) timers.set(input, setTimeout(() => { if (input.isConnected) set(input, false); }, seconds * 1000));
  };
  const onClick = (e) => {
    const b = e.target instanceof Element ? e.target.closest('[data-reveal]') : null;
    if (!b || !scope.contains(b)) return;
    const input = b.parentElement?.querySelector('input');
    if (input) set(input, input.type === 'password');
  };
  const onKey = (e) => {
    const input = e.target;
    if (input instanceof HTMLInputElement && input.type === 'text' && timers.has(input) && e.key.length === 1) set(input, false);
  };
  scope.addEventListener('click', onClick);
  scope.addEventListener('keydown', onKey, true);
  scope.querySelectorAll('[data-reveal]').forEach((b) => { b.dataset.tip = `Afficher ${seconds}${NBSP}s`; });
  return {
    show: (input) => set(input, true),
    hideAll: () => [...timers.keys()].forEach((input) => set(input, false)),
    destroy: () => {
      timers.forEach((t) => clearTimeout(t));
      timers.clear();
      scope.removeEventListener('click', onClick);
      scope.removeEventListener('keydown', onKey, true);
    },
  };
}

/**
 * Scroll hints of a kit tab strip that may not fit (detail of an account): fading edges and two arrows for the mouse (the
 * keyboard already moves between tabs with ← →). Returns a cleanup function.
 * @param {HTMLElement} host  Element that holds the .k-tabs of createTabs.
 */
export function tabScrollHints(host) {
  const strip = host.querySelector('.k-tabs-scroll');
  if (!strip) return () => {};
  const frame = strip.parentElement;
  frame.classList.add('cpt-tabs-hints');
  const arrow = (side) => {
    const b = document.createElement('button');
    b.type = 'button';
    b.className = `cpt-tabs-arrow ${side}`;
    b.tabIndex = -1;
    b.setAttribute('aria-hidden', 'true');
    b.innerHTML = glyph(side === 'l' ? 'chevronLeft' : 'chevronRight');
    b.addEventListener('click', () => strip.scrollBy({ left: side === 'l' ? -160 : 160, behavior: 'smooth' }));
    frame.insertBefore(b, strip.nextSibling);
    return b;
  };
  const left = arrow('l');
  const right = arrow('r');
  const update = () => {
    const max = strip.scrollWidth - strip.clientWidth;
    frame.classList.toggle('can-l', strip.scrollLeft > 2);
    frame.classList.toggle('can-r', strip.scrollLeft < max - 2);
  };
  strip.addEventListener('scroll', update, { passive: true });
  const ro = 'ResizeObserver' in window ? new ResizeObserver(update) : null;
  ro?.observe(strip);
  requestAnimationFrame(update);
  return () => { ro?.disconnect(); strip.removeEventListener('scroll', update); left.remove(); right.remove(); };
}

/** French long day « jeudi 20 novembre 2026 » of a local « yyyy-MM-dd », or null. */
export function longDay(value) {
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(String(value ?? ''));
  if (!m) return null;
  const d = new Date(Number(m[1]), Number(m[2]) - 1, Number(m[3]));
  return new Intl.DateTimeFormat('fr-FR', { weekday: 'long', day: 'numeric', month: 'long', year: 'numeric' }).format(d);
}

/** Tells the shell badge and the other views that the accesses of Domenia changed (no data in the event). */
export function accessChanged() {
  window.dispatchEvent(new CustomEvent('domenia:access-changed'));
}

/** Error code and message of a bridge error, as a French sentence. */
export function errorSentence(err, fallback = 'Erreur interne de l’interface.') {
  return err && err.code && err.message ? String(err.message) : fallback;
}

/** Tone of an error code: refusals that say nothing was done are warnings, the rest alerts. */
export function errorTone(err) {
  return /^(write\.nothingToDo|accounts\.validationBusy|accounts\.trialBusy|accounts\.requestUnknown|accounts\.batchIssued|accounts\.batchTypedName)$/.test(err?.code ?? '') ? 'warn' : 'alert';
}
