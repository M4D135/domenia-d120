// Shared UI helpers: escaping, CSS variables, entrances, counters, charts, pointer effects, toasts.
import { icon } from './icons.js';

const root = document.documentElement;
const TONES = {
  ok: 'var(--ok-mark)', warn: 'var(--warn-mark)', alert: 'var(--alert-mark)',
  info: 'var(--info-mark)', off: 'var(--off-mark)', accent: 'var(--accent)',
};
const TONE_ICONS = { ok: 'check', warn: 'alert', alert: 'alert', info: 'info', off: 'info', accent: 'sparkles' };
const TILT_MAX = 5;

// ---------- Text and numbers ----------

export function esc(value) {
  return String(value ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);
}

// Operator-facing text of an error: bridge errors carry a French message and a code; anything else (TypeError,
// failed import…) is a browser message in English, so it is replaced by a French sentence (callers log the detail).
export function errorText(err, fallback = 'Erreur interne de l’interface.') {
  return err && err.code && err.message ? String(err.message) : fallback;
}

// Accent- and case-insensitive form, for filters.
export function fold(text) {
  return String(text ?? '').normalize('NFD').replace(/\p{Diacritic}/gu, '').toLowerCase();
}

const formats = new Map();
export function formatNumber(value, decimals = 0) {
  const key = decimals;
  if (!formats.has(key)) {
    formats.set(key, new Intl.NumberFormat('fr-FR', { minimumFractionDigits: decimals, maximumFractionDigits: decimals }));
  }
  return formats.get(key).format(value);
}

const relative = new Intl.RelativeTimeFormat('fr', { numeric: 'auto', style: 'short' });
// "il y a 12 min", "hier", "il y a 3 j" from an ISO date (or null).
export function relTime(iso, now = Date.now()) {
  if (!iso) return null;
  const t = Date.parse(iso);
  if (Number.isNaN(t)) return null;
  const s = Math.round((t - now) / 1000);
  const abs = Math.abs(s);
  if (abs < 45) return 'à l’instant';
  if (abs < 3600) return relative.format(Math.round(s / 60), 'minute');
  if (abs < 86400) return relative.format(Math.round(s / 3600), 'hour');
  if (abs < 86400 * 30) return relative.format(Math.round(s / 86400), 'day');
  return relative.format(Math.round(s / (86400 * 30)), 'month');
}

const dateTime = new Intl.DateTimeFormat('fr-FR', { dateStyle: 'medium', timeStyle: 'short' });
const timeOnly = new Intl.DateTimeFormat('fr-FR', { hour: '2-digit', minute: '2-digit' });
export function formatDateTime(iso) {
  const t = Date.parse(iso ?? '');
  return Number.isNaN(t) ? null : dateTime.format(t);
}
export function formatTime(iso) {
  const t = Date.parse(iso ?? '');
  return Number.isNaN(t) ? null : timeOnly.format(t);
}

// ---------- Motion preferences ----------

export function motionReduced() {
  const mode = root.dataset.motion;
  if (mode === 'reduced') return true;
  if (mode === 'system') return matchMedia('(prefers-reduced-motion: reduce)').matches;
  return false;
}

// Reads a duration token such as --t-chart ("1200ms" or "1.2s") in milliseconds.
export function cssMs(name, fallback = 0) {
  const raw = getComputedStyle(root).getPropertyValue(name).trim();
  const n = parseFloat(raw);
  if (Number.isNaN(n)) return fallback;
  return raw.endsWith('ms') ? n : raw.endsWith('s') ? n * 1000 : n;
}

// ---------- CSS variables from data attributes (CSP forbids style="…") ----------

function clamp(n, lo, hi) {
  return Math.min(hi, Math.max(lo, Number.isFinite(n) ? n : lo));
}

export function applyVars(scope) {
  const nodes = scope.matches?.('[data-i],[data-j],[data-tone],[data-pct],[data-len],[data-p],[data-grow]')
    ? [scope] : [];
  nodes.push(...scope.querySelectorAll('[data-i],[data-j],[data-tone],[data-pct],[data-len],[data-p],[data-grow]'));
  for (const el of nodes) {
    const d = el.dataset;
    if (d.i !== undefined) el.style.setProperty('--i', d.i);
    if (d.j !== undefined) el.style.setProperty('--j', d.j);
    if (d.tone && TONES[d.tone]) el.style.setProperty('--tone', TONES[d.tone]);
    if (d.pct !== undefined) el.style.setProperty('height', `${clamp(Number(d.pct), 0, 100)}%`);
    if (d.len !== undefined) el.style.setProperty('--len', d.len);
    if (d.p !== undefined) el.style.setProperty('--p', String(clamp(Number(d.p), 0, 1)));
    if (d.grow !== undefined) el.style.setProperty('flex-grow', String(Math.max(0, Number(d.grow) || 0)));
  }
  measureDraw(scope);
}

// Path lengths for .draw strokes (circles use pathLength and carry data-len already).
export function measureDraw(scope) {
  for (const path of scope.querySelectorAll('path.draw')) {
    try {
      path.style.setProperty('--len', String(Math.ceil(path.getTotalLength()) + 1));
    } catch {
      path.style.setProperty('--len', '1000');
    }
  }
}

// ---------- Entrances ----------

// Cascades .reveal elements in as they scroll into view; returns a disconnect function.
export function reveal(scope, { onIn } = {}) {
  const items = [...scope.querySelectorAll('.reveal:not(.in)')];
  const order = new WeakMap();
  items.forEach((el, n) => { order.set(el, n); el.style.setProperty('--i', String(n)); });
  const settle = (el) => {
    el.addEventListener('animationend', function done(e) {
      if (e.target !== el || e.animationName !== 'reveal-in') return;
      el.removeEventListener('animationend', done);
      // Release the transform so .tilt and hover lifts can take over.
      el.classList.remove('reveal', 'in');
      el.classList.add('revealed');
    });
  };
  const show = (list) => {
    list.sort((a, b) => order.get(a) - order.get(b));
    list.forEach((el, n) => {
      el.style.setProperty('--i', String(n));
      settle(el);
      el.classList.add('in');
      if (onIn) onIn(el, n);
    });
  };
  if (!('IntersectionObserver' in window)) {
    show(items);
    return () => {};
  }
  // Threshold 0: a ratio threshold never fires for cards much taller than the viewport (long parity lists).
  const io = new IntersectionObserver((entries) => {
    const visible = entries.filter((e) => e.isIntersecting || e.intersectionRatio > 0).map((e) => e.target);
    visible.forEach((el) => io.unobserve(el));
    if (visible.length) show(visible);
  }, { threshold: 0, rootMargin: '0px 0px -3% 0px' });
  items.forEach((el) => io.observe(el));
  return () => io.disconnect();
}

// Animated number; immediate when motion is reduced.
const counting = new WeakMap();
export function countUp(el, to, { decimals = 0, from = 0, delay = 0, duration, suffix = '' } = {}) {
  if (!el) return;
  const target = Number(to);
  const prev = counting.get(el);
  if (prev) { cancelAnimationFrame(prev.raf); clearTimeout(prev.timer); }
  const job = { raf: 0, timer: 0 };
  counting.set(el, job);
  if (!Number.isFinite(target)) { el.textContent = '—'; return; }
  if (motionReduced()) { el.textContent = formatNumber(target, decimals) + suffix; return; }
  const ms = duration ?? cssMs('--t-chart', 1200);
  el.textContent = formatNumber(from, decimals) + suffix;
  const start = () => {
    const t0 = performance.now();
    const step = (now) => {
      const k = Math.min(1, (now - t0) / ms);
      const eased = 1 - Math.pow(1 - k, 4);
      el.textContent = formatNumber(from + (target - from) * eased, decimals) + suffix;
      if (k < 1) job.raf = requestAnimationFrame(step);
    };
    job.raf = requestAnimationFrame(step);
  };
  if (delay > 0) job.timer = setTimeout(start, delay); else start();
}

// Animates a .progress bar to p (0..1) after the first paint.
export function progressTo(bar, p) {
  if (!bar) return;
  const value = String(clamp(Number(p), 0, 1));
  if (motionReduced()) { bar.style.setProperty('--p', value); return; }
  requestAnimationFrame(() => requestAnimationFrame(() => bar.style.setProperty('--p', value)));
}

// ---------- Charts (SVG strings; call applyVars after insertion) ----------

function smoothPath(points) {
  if (points.length < 2) return points.length ? `M${points[0][0]},${points[0][1]}` : '';
  let d = `M${points[0][0].toFixed(1)},${points[0][1].toFixed(1)}`;
  for (let n = 0; n < points.length - 1; n++) {
    const [x0, y0] = points[Math.max(0, n - 1)];
    const [x1, y1] = points[n];
    const [x2, y2] = points[n + 1];
    const [x3, y3] = points[Math.min(points.length - 1, n + 2)];
    const c1x = x1 + (x2 - x0) / 6; const c1y = y1 + (y2 - y0) / 6;
    const c2x = x2 - (x3 - x1) / 6; const c2y = y2 - (y3 - y1) / 6;
    d += ` C${c1x.toFixed(1)},${c1y.toFixed(1)} ${c2x.toFixed(1)},${c2y.toFixed(1)} ${x2.toFixed(1)},${y2.toFixed(1)}`;
  }
  return d;
}

// values: numbers, or { x, value } where x places the point (e.g. day index; missing days leave a gap in x).
export function sparkline(values, { w = 160, h = 56, pad = 4 } = {}) {
  const pts = values.map((v, n) => (typeof v === 'object' && v !== null ? { x: v.x, y: v.value } : { x: n, y: v }))
    .filter((p) => Number.isFinite(p.y));
  if (pts.length < 2) return '';
  const xs = pts.map((p) => p.x); const ys = pts.map((p) => p.y);
  const x0 = Math.min(...xs); const x1 = Math.max(...xs) || 1;
  const lo = Math.min(...ys); const hi = Math.max(...ys);
  const span = hi - lo || 1;
  const points = pts.map((p) => [
    pad + ((p.x - x0) / (x1 - x0 || 1)) * (w - pad * 2),
    pad + (1 - (p.y - lo) / span) * (h - pad * 2),
  ]);
  const line = smoothPath(points);
  const area = `${line} L${points.at(-1)[0].toFixed(1)},${h} L${points[0][0].toFixed(1)},${h} Z`;
  return `<svg class="spark" viewBox="0 0 ${w} ${h}" preserveAspectRatio="none" aria-hidden="true">`
    + `<path class="area" d="${area}"/><path class="line draw" d="${line}"/></svg>`;
}

const RING_R = 50;
// segments: [{ value, cls?, tone?, key? }]. Returns an SVG ring; total defaults to the sum.
export function donut(segments, { total, center = '', label = '', size = '', single = false } = {}) {
  const sum = total ?? segments.reduce((s, x) => s + (Number(x.value) || 0), 0);
  const gap = single || segments.length < 2 ? 0 : 0.8;
  let start = 0;
  const arcs = segments.map((seg, n) => {
    const pct = sum > 0 ? ((Number(seg.value) || 0) / sum) * 100 : 0;
    const len = Math.max(0, pct - gap);
    const cls = seg.cls ?? `s${(n % 8) + 1}`;
    const tone = seg.tone ? ` data-tone="${esc(seg.tone)}"` : '';
    const key = seg.key ? ` data-key="${esc(seg.key)}"` : '';
    const arc = `<circle class="seg draw ${cls}" cx="60" cy="60" r="${RING_R}" pathLength="100" data-len="${len.toFixed(2)}"`
      + ` data-i="${n}"${tone}${key} transform="rotate(${(start * 3.6).toFixed(2)} 60 60)"/>`;
    start += pct;
    return len > 0 ? arc : '';
  }).join('');
  const aria = label ? ` role="img" aria-label="${esc(label)}"` : ' aria-hidden="true"';
  return `<div class="ring ${single ? 'gauge' : 'donut'} ${size}"${aria}>`
    + `<svg viewBox="0 0 120 120"><circle class="track" cx="60" cy="60" r="${RING_R}"/>${arcs}</svg>`
    + `<div class="center">${center}</div></div>`;
}

// values: numbers or null (null leaves an empty slot, never a zero bar).
export function bars(values, labels, { max, format = (v) => formatNumber(v), partial = [], label = '' } = {}) {
  const top = max ?? Math.max(1, ...values.filter(Number.isFinite));
  const cols = values.map((v, n) => {
    if (!Number.isFinite(v)) return `<div class="bar-gap" title="Aucun relevé">—</div>`;
    const pct = top > 0 ? (v / top) * 100 : 0;
    const cls = partial[n] ? 'bar rise partial' : 'bar rise';
    return `<div class="${cls}" data-pct="${pct.toFixed(1)}" data-v="${esc(format(v))}" data-i="${n}"></div>`;
  }).join('');
  const axis = labels.map((l, n) => `<span class="${partial[n] ? 'today' : ''}">${esc(l)}</span>`).join('');
  const aria = label ? ` role="img" aria-label="${esc(label)}"` : '';
  return `<div class="bars"${aria}>${cols}</div><div class="bars-x" aria-hidden="true">${axis}</div>`;
}

// ---------- Pointer effects: spotlight, tilt, halo, ripple (one delegated listener each) ----------

let pointerReady = false;
let lastEvent = null;
let frame = 0;
let tilted = null;
let heroed = null;
let halo = null;

function resetTilt(el) {
  el.classList.remove('tilting');
  el.style.setProperty('--rx', '0deg');
  el.style.setProperty('--ry', '0deg');
}

function flushPointer() {
  frame = 0;
  const e = lastEvent;
  if (!e) return;
  const target = e.target instanceof Element ? e.target : null;
  const reduced = motionReduced();

  const spot = target?.closest('.spot');
  if (spot) {
    const r = spot.getBoundingClientRect();
    spot.style.setProperty('--mx', `${(e.clientX - r.left).toFixed(0)}px`);
    spot.style.setProperty('--my', `${(e.clientY - r.top).toFixed(0)}px`);
  }

  const tilt = reduced ? null : target?.closest('.tilt');
  if (tilted && tilted !== tilt) resetTilt(tilted);
  tilted = tilt;
  if (tilt) {
    const r = tilt.getBoundingClientRect();
    const nx = (e.clientX - r.left) / r.width - 0.5;
    const ny = (e.clientY - r.top) / r.height - 0.5;
    tilt.classList.add('tilting');
    tilt.style.setProperty('--rx', `${(-ny * 2 * TILT_MAX).toFixed(2)}deg`);
    tilt.style.setProperty('--ry', `${(nx * 2 * TILT_MAX).toFixed(2)}deg`);
  }

  const hero = reduced ? null : target?.closest('.hero');
  if (heroed && heroed !== hero) { heroed.style.setProperty('--px', '0'); heroed.style.setProperty('--py', '0'); }
  heroed = hero;
  if (hero) {
    const r = hero.getBoundingClientRect();
    hero.style.setProperty('--px', (((e.clientX - r.left) / r.width - 0.5) * 2).toFixed(3));
    hero.style.setProperty('--py', (((e.clientY - r.top) / r.height - 0.5) * 2).toFixed(3));
  }

  halo = halo?.isConnected ? halo : document.querySelector('.cursor-halo');
  if (halo && !reduced) {
    halo.style.setProperty('--hx', `${e.clientX}px`);
    halo.style.setProperty('--hy', `${e.clientY}px`);
    halo.classList.add('on');
  }
}

function addRipple(e) {
  const host = e.target instanceof Element ? e.target.closest('.btn') : null;
  if (!host || host.disabled || e.button !== 0 || motionReduced()) return;
  const r = host.getBoundingClientRect();
  const size = Math.max(r.width, r.height);
  const ripple = document.createElement('span');
  ripple.className = 'ripple';
  ripple.setAttribute('aria-hidden', 'true');
  ripple.style.setProperty('width', `${size}px`);
  ripple.style.setProperty('height', `${size}px`);
  ripple.style.setProperty('left', `${e.clientX - r.left - size / 2}px`);
  ripple.style.setProperty('top', `${e.clientY - r.top - size / 2}px`);
  host.appendChild(ripple);
  const drop = () => ripple.remove();
  ripple.addEventListener('animationend', drop, { once: true });
  setTimeout(drop, 1200);
}

export function initPointerEffects() {
  if (pointerReady) return;
  pointerReady = true;
  document.addEventListener('pointermove', (e) => {
    if (e.pointerType === 'touch') return;
    lastEvent = e;
    if (!frame) frame = requestAnimationFrame(flushPointer);
  }, { passive: true });
  document.documentElement.addEventListener('pointerleave', () => {
    if (tilted) resetTilt(tilted);
    tilted = null;
    document.querySelector('.cursor-halo')?.classList.remove('on');
  });
  document.addEventListener('pointerdown', addRipple, { passive: true });
}

// ---------- Sliding indicators (tab ink, segmented thumb) ----------

export function inkFollow(container, selector, activeSelector) {
  const ink = container.querySelector(':scope > .ink, :scope > .thumb');
  const update = () => {
    const active = container.querySelector(activeSelector);
    if (!ink || !active) return;
    ink.style.setProperty('--x', `${active.offsetLeft}px`);
    ink.style.setProperty('--w', `${active.offsetWidth}px`);
    // Width as a ratio of a 100 px base, so the ink can slide and stretch with transform only.
    ink.style.setProperty('--k', String(active.offsetWidth / 100));
  };
  update();
  let ro = null;
  if ('ResizeObserver' in window) {
    ro = new ResizeObserver(update);
    ro.observe(container);
    container.querySelectorAll(selector).forEach((el) => ro.observe(el));
  }
  return { update, stop: () => ro?.disconnect() };
}

// ---------- Busy line ----------

let busyCount = 0;
export function setBusy(on) {
  busyCount = Math.max(0, busyCount + (on ? 1 : -1));
  document.querySelector('.busy-line')?.classList.toggle('on', busyCount > 0);
}

// ---------- Screen reader announcements ----------

// Two hidden live regions (polite, assertive) directly under body, outside the inert shell. Each message is added
// as a new line, so successive messages are all read; lines are removed later (removals are not announced).
const LIVE_KEEP_MS = 10_000;
function liveRegion(assertive) {
  const cls = assertive ? 'live-assertive' : 'live-polite';
  let el = document.querySelector(`.${cls}`);
  if (!el) {
    el = document.createElement('div');
    el.className = `visually-hidden ${cls}`;
    el.setAttribute('aria-live', assertive ? 'assertive' : 'polite');
    document.body.appendChild(el);
  }
  return el;
}

// Creates the regions at boot: a live region must exist before its first change to be announced.
export function initLive() {
  liveRegion(false);
  liveRegion(true);
}

export function announce(text, { assertive = false } = {}) {
  if (!text) return;
  const line = document.createElement('p');
  line.textContent = text;
  liveRegion(assertive).appendChild(line);
  setTimeout(() => line.remove(), LIVE_KEEP_MS);
}

// ---------- Toasts ----------

// The toast itself is not a live region (its close button would be read too): its text goes to announce().
const MAX_TOASTS = 4;
export function toast(message, { tone = 'info', life = 4800 } = {}) {
  const host = document.querySelector('.toasts');
  if (!host) return null;
  while (host.children.length >= MAX_TOASTS) host.firstElementChild.remove();
  const el = document.createElement('div');
  el.className = 'toast';
  el.innerHTML = `<span class="toast-icon">${icon(TONE_ICONS[tone] ?? 'info')}</span>`
    + `<div class="toast-body">${esc(message)}</div>`
    + `<button class="btn ghost icon sm toast-close" type="button" aria-label="Fermer la notification">${icon('x')}</button>`
    + '<span class="bar" aria-hidden="true"></span>';
  el.style.setProperty('--tone', TONES[tone] ?? TONES.info);
  el.style.setProperty('--life', `${life}ms`);
  host.appendChild(el);
  announce(message, { assertive: tone === 'alert' });

  // The countdown pauses while the toast is hovered or holds the keyboard focus.
  let left = life; let started = 0; let timer = 0; let hovered = false; let focused = false;
  const leave = () => {
    clearTimeout(timer);
    timer = 0;
    if (el.classList.contains('leaving')) return;
    if (el.contains(document.activeElement)) document.getElementById('main')?.focus({ preventScroll: true });
    el.classList.add('leaving');
    el.addEventListener('animationend', () => el.remove(), { once: true });
    setTimeout(() => el.remove(), 800);
  };
  const pause = () => {
    if (!timer) return;
    clearTimeout(timer);
    timer = 0;
    left -= performance.now() - started;
  };
  const resume = () => {
    if (timer || hovered || focused || el.classList.contains('leaving')) return;
    started = performance.now();
    timer = setTimeout(leave, Math.max(800, left));
  };
  el.addEventListener('pointerenter', () => { hovered = true; pause(); });
  el.addEventListener('pointerleave', () => { hovered = false; resume(); });
  el.addEventListener('focusin', () => { focused = true; pause(); });
  el.addEventListener('focusout', (e) => {
    if (e.relatedTarget instanceof Node && el.contains(e.relatedTarget)) return;
    focused = false;
    resume();
  });
  el.querySelector('.toast-close').addEventListener('click', leave);
  resume();
  return el;
}

// ---------- Clipboard ----------

export async function copyText(text) {
  try {
    await navigator.clipboard.writeText(text);
    return true;
  } catch {
    const area = document.createElement('textarea');
    area.value = text;
    area.setAttribute('readonly', '');
    area.className = 'visually-hidden';
    document.body.appendChild(area);
    area.select();
    let ok = false;
    try { ok = document.execCommand('copy'); } catch { ok = false; }
    area.remove();
    return ok;
  }
}
