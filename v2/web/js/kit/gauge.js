// Gauges: half-dial (rotation only) and bar (horizontal scale only). Tones follow thresholds; a missing measure is
// shown as such, never as 0. Animated with transform after the first paint; immediate when motion is reduced.
import { esc, clamp, dec, int, NBSP, motionReduced } from './util.js';

/**
 * @typedef {Object} GaugeOptions
 * @property {number|null} value             null: not measured.
 * @property {number} [max=100]
 * @property {string} label                  What is measured (accessible name and caption).
 * @property {string} [unit='%']
 * @property {'semi'|'bar'} [kind='semi']
 * @property {'ok'|'warn'|'alert'|'info'|'accent'} [tone]   Fixed tone (else from thresholds).
 * @property {{ warn: number, alert: number }} [thresholds] In value units; with invert, low values are the bad ones.
 * @property {boolean} [invert]
 * @property {number} [decimals=0]
 * @property {string} [caption]              Line under the value (« 412 postes »).
 */

function toneOf(o, v) {
  if (o.tone) return o.tone;
  if (!o.thresholds || v === null) return 'accent';
  const { warn, alert } = o.thresholds;
  if (o.invert) return v <= alert ? 'alert' : v <= warn ? 'warn' : 'ok';
  return v >= alert ? 'alert' : v >= warn ? 'warn' : 'ok';
}

/**
 * Markup of a gauge; call animateGauges() on its container once inserted.
 * @param {GaugeOptions} o
 * @returns {string}
 */
export function gauge(o) {
  const max = o.max ?? 100;
  const v = Number.isFinite(o.value) ? Number(o.value) : null;
  const p = v === null ? 0 : clamp(v / max, 0, 1);
  const tone = toneOf(o, v);
  const unit = o.unit ?? '%';
  const text = v === null ? '—' : (o.decimals ? dec(v, o.decimals) : int(v));
  const spoken = v === null ? `${o.label}${NBSP}: non mesuré` : `${o.label}${NBSP}: ${text}${unit ? `${NBSP}${unit}` : ''} sur ${int(max)}`;
  const valueHtml = `<b class="k-g-val">${esc(text)}${v !== null && unit ? `<small>${NBSP}${esc(unit)}</small>` : ''}</b>`;
  if (o.kind === 'bar') {
    return `<div class="k-gauge bar ${tone}${v === null ? ' none' : ''}" role="meter" aria-label="${esc(o.label)}" aria-valuemin="0" aria-valuemax="${max}"${v === null ? '' : ` aria-valuenow="${v}"`} aria-valuetext="${esc(spoken)}" data-p="${p}">
      <div class="k-g-top"><span class="k-g-label">${esc(o.label)}</span>${valueHtml}</div>
      <div class="k-g-track" aria-hidden="true"><span class="k-g-fill"></span></div>
      ${o.caption ? `<span class="k-g-cap">${esc(o.caption)}</span>` : ''}</div>`;
  }
  return `<div class="k-gauge semi ${tone}${v === null ? ' none' : ''}" role="meter" aria-label="${esc(o.label)}" aria-valuemin="0" aria-valuemax="${max}"${v === null ? '' : ` aria-valuenow="${v}"`} aria-valuetext="${esc(spoken)}" data-p="${p}">
    <div class="k-g-dial" aria-hidden="true"><span class="k-g-arc track"></span><span class="k-g-arc fill"></span><span class="k-g-needle"></span><span class="k-g-hub"></span></div>
    <div class="k-g-read">${valueHtml}<span class="k-g-label">${esc(o.label)}</span>${o.caption ? `<span class="k-g-cap">${esc(o.caption)}</span>` : ''}</div>
  </div>`;
}

/**
 * Sets each gauge of scope to its value (--p) after the first paint, so the fill and the needle travel.
 * @param {HTMLElement} scope
 */
export function animateGauges(scope) {
  const list = [...scope.querySelectorAll('.k-gauge[data-p]')];
  const apply = () => list.forEach((g) => g.style.setProperty('--p', g.dataset.p ?? '0'));
  if (motionReduced()) { apply(); return; }
  list.forEach((g) => g.style.setProperty('--p', '0'));
  requestAnimationFrame(() => requestAnimationFrame(apply));
}
