// Timeline: events grouped by day (« Aujourd’hui », « Hier », then the date), tone and icon per event, local time with
// the full date in the tip. Newest first.
import { glyph } from './glyphs.js';
import { esc } from './util.js';
import { formatDateTime } from '../ui.js';

/**
 * @typedef {Object} TimelineEvent
 * @property {string} when                   ISO 8601 date and time.
 * @property {string} title
 * @property {string} [text]
 * @property {'ok'|'warn'|'alert'|'info'|'off'|'accent'} [tone='info']
 * @property {string} [icon]
 * @property {string} [actor]                Who (account), shown in the meta line.
 * @property {string} [meta]                 Free detail (« 3 postes », « reçu 42 »).
 * @property {string} [html]                 Trusted extra markup under the text (pills, buttons).
 */

const dayFmt = new Intl.DateTimeFormat('fr-FR', { weekday: 'long', day: 'numeric', month: 'long' });
const yearFmt = new Intl.DateTimeFormat('fr-FR', { weekday: 'long', day: 'numeric', month: 'long', year: 'numeric' });
const timeFmt = new Intl.DateTimeFormat('fr-FR', { hour: '2-digit', minute: '2-digit' });

function dayKey(d) {
  return `${d.getFullYear()}-${d.getMonth()}-${d.getDate()}`;
}

function dayLabel(d, now) {
  const today = new Date(now);
  const yesterday = new Date(now);
  yesterday.setDate(today.getDate() - 1);
  if (dayKey(d) === dayKey(today)) return 'Aujourd’hui';
  if (dayKey(d) === dayKey(yesterday)) return 'Hier';
  const text = (d.getFullYear() === today.getFullYear() ? dayFmt : yearFmt).format(d);
  return text.charAt(0).toUpperCase() + text.slice(1);
}

/**
 * Markup of a timeline (sorted newest first). Entrances cascade (.reveal parents gate them).
 * @param {TimelineEvent[]} events
 * @param {{ group?: boolean, now?: number, label?: string, empty?: string }} [o]
 * @returns {string}
 */
export function timeline(events, o = {}) {
  const now = o.now ?? Date.now();
  const list = events
    .map((e) => ({ e, t: Date.parse(e.when) }))
    .filter((x) => !Number.isNaN(x.t))
    .sort((x, y) => y.t - x.t);
  if (!list.length) return `<p class="k-tl-empty">${esc(o.empty ?? 'Aucun événement.')}</p>`;
  let html = '';
  let lastDay = '';
  let j = 0;
  for (const { e, t } of list) {
    const d = new Date(t);
    if (o.group !== false && dayKey(d) !== lastDay) {
      if (lastDay) html += '</ol>';
      lastDay = dayKey(d);
      html += `<h4 class="k-tl-day">${esc(dayLabel(d, now))}</h4><ol class="k-tl-list">`;
    } else if (!lastDay) {
      lastDay = 'all';
      html += '<ol class="k-tl-list">';
    }
    const tone = e.tone ?? 'info';
    const meta = [e.actor ? `${glyph('user')}${esc(e.actor)}` : '', e.meta ? esc(e.meta) : ''].filter(Boolean).join('<span class="k-tl-dot" aria-hidden="true">·</span>');
    html += `<li class="k-tl-ev ${esc(tone)}" data-j="${Math.min(j, 16)}">
      <span class="k-tl-mark" aria-hidden="true">${glyph(e.icon ?? 'dot')}</span>
      <div class="k-tl-card"><div class="k-tl-row"><b class="k-tl-title">${esc(e.title)}</b>
        <time class="k-tl-time" datetime="${esc(e.when)}" data-tip="${esc(formatDateTime(e.when) ?? '')}">${esc(timeFmt.format(d))}</time></div>
        ${e.text ? `<p class="k-tl-text">${esc(e.text)}</p>` : ''}${e.html ?? ''}
        ${meta ? `<p class="k-tl-meta">${meta}</p>` : ''}</div></li>`;
    j += 1;
  }
  html += '</ol>';
  return `<div class="k-tl" role="group" aria-label="${esc(o.label ?? 'Chronologie')}">${html}</div>`;
}

/** Applies the cascade order (--j) of the events inside scope (CSP: no style attribute in markup). */
export function bindTimeline(scope) {
  scope.querySelectorAll('.k-tl-ev[data-j]').forEach((li) => li.style.setProperty('--j', li.dataset.j));
}
