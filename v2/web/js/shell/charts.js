// Native charts of the boards (TRV-297 to TRV-300, TRV-284): key figure, three-quarter gauge, score card, health card (score
// and points, stacked under 520 px), ring with « Autres », horizontal bars, columns with their values, curve with its area and
// last point, lists, sheets and checklists, and an accessible table for every chart. Graduations are rounded (1, 2, 5 × 10^n,
// whole steps for counts), numbers are French, sizes in Mo/Go/To, ages « il y a N min ». Each mark carries its value in a
// tooltip; the pastel series have a darker edge (3:1 in the light theme). A part is clickable only when it carries a
// criterion (Domenia 1: « partie cliquable seulement si elle porte un critère »), and « Autres » keeps the criteria of the
// categories it gathers, so a selection is never lost. Markup builders only (call paintCharts after).
import { esc } from '../ui.js';
import { icon } from '../icons.js';

const NBSP = ' ';
const nf = new Intl.NumberFormat('fr-FR', { maximumFractionDigits: 1 });

export function num(v) { return Number.isFinite(Number(v)) ? nf.format(Number(v)) : '—'; }

/**
 * Rounded graduations from 0 to the first one at or above the maximum (Domenia 1 Get-DomeniaChartTicks).
 * @returns {{ step: number, top: number, ticks: number[] }}
 */
export function chartTicks(maximum, { integer = false, count = 4 } = {}) {
  let max = Number(maximum);
  if (!(max > 0) || !Number.isFinite(max)) max = 1;
  const raw = max / Math.max(1, count);
  const power = 10 ** Math.floor(Math.log10(raw));
  let step = 10 * power;
  for (const f of [1, 2, 5, 10]) {
    const c = Math.round(f * power * 1e10) / 1e10;
    if (c >= raw) { step = c; break; }
  }
  if (integer && step < 1) step = 1;
  let top = Math.round(Math.ceil(Math.round((max / step) * 1e9) / 1e9) * step * 1e10) / 1e10;
  if (top <= 0) top = step;
  const ticks = [];
  for (let i = 0; i * step <= top + step / 2; i += 1) ticks.push(Math.round(i * step * 1e10) / 1e10);
  return { step, top, ticks };
}

/**
 * Keeps at most `max` categories drawn and gathers the rest into « Autres (N catégories) », which keeps the members of each
 * gathered category (Domenia 1 Get-DomeniaChartCategoryGroups): no category is lost.
 */
export function groupOthers(items, max = 8) {
  const valid = (items ?? []).filter((i) => i && Number(i.value) > 0);
  if (valid.length <= max) return valid;
  const keep = Math.max(0, max - 1);
  const head = valid.slice(0, keep);
  const tail = valid.slice(keep);
  const criteria = tail.flatMap((i) => (i.criteria ?? (i.criterion ? [i.criterion] : [])));
  return [...head, {
    label: `Autres (${tail.length} catégories)`, value: tail.reduce((s, i) => s + Number(i.value), 0), other: true,
    members: tail.map((i) => i.label), items: tail, criteria, criterion: criteria.length ? criteria.join('|') : undefined,
  }];
}

/** « 512 Mo », « 3,4 Go », « 1,2 To ». */
export function sizeText(bytes) {
  const b = Number(bytes);
  if (!Number.isFinite(b)) return '—';
  if (b >= 1024 ** 4) return `${nf.format(b / 1024 ** 4)}${NBSP}To`;
  if (b >= 1024 ** 3) return `${nf.format(b / 1024 ** 3)}${NBSP}Go`;
  return `${Math.round(b / 1024 ** 2)}${NBSP}Mo`;
}

/** « à l’instant », « il y a 5 min », « il y a 3 h », « il y a 2 j » (Domenia 1 Format-DomeniaAge). */
/** Tolerated gap between the clock of the engine and the clock of the page (minutes). */
const CLOCK_SKEW_MINUTES = 5;

export function ageText(iso, now = Date.now()) {
  const t = Date.parse(iso ?? '');
  if (Number.isNaN(t)) return 'non daté';
  const minutes = (now - t) / 60000;
  // A few minutes ahead is a clock gap between the engine and the page, not a date of the future.
  if (minutes < -CLOCK_SKEW_MINUTES) return 'non daté';
  if (minutes < 1) return 'à l’instant';
  if (minutes < 60) return `il y a ${Math.floor(minutes)}${NBSP}min`;
  if (minutes < 1440) return `il y a ${Math.floor(minutes / 60)}${NBSP}h`;
  return `il y a ${Math.floor(minutes / 1440)}${NBSP}j`;
}

/** « 12 postes analysés sur 40, le 21/10 » (Domenia 1 Get-DomeniaCoverageText). */
export function coverageText(analysed, total, lastIso) {
  const a = Number(analysed) || 0;
  let text = `${num(a)} poste${a > 1 ? 's' : ''} analysé${a > 1 ? 's' : ''} sur ${num(total)}`;
  const t = Date.parse(lastIso ?? '');
  if (!Number.isNaN(t)) {
    const d = new Date(t);
    text += `, le ${String(d.getDate()).padStart(2, '0')}/${String(d.getMonth() + 1).padStart(2, '0')}`;
  }
  return text;
}

/**
 * Dates of the data in the foot of a widget (TRV-296), per source family; a failed attempt never rejuvenates a date, a
 * future or missing date says « non daté ».
 * @param {Array<{ family: string, at?: string|null, unread?: number, partial?: string }>} sources
 */
export function dataDates(sources = []) {
  return sources.map((s) => {
    const t = Date.parse(s.at ?? '');
    const when = Number.isNaN(t) || t > Date.now() + CLOCK_SKEW_MINUTES * 60_000 ? 'non daté' : ageText(s.at);
    const unread = s.unread > 0 ? ` · ${num(s.unread)} non lu${s.unread > 1 ? 's' : ''}` : '';
    const partial = s.partial ? ` · ${s.partial}` : '';
    return `<span class="sh-dates-item" data-tip="${esc(Number.isNaN(t) ? 'Date inconnue' : new Date(t).toLocaleString('fr-FR'))}">${esc(s.family)}${NBSP}: ${esc(when)}${esc(unread)}${esc(partial)}</span>`;
  }).join('');
}

const TONES = ['ok', 'warn', 'alert', 'info', 'off'];
const tone = (t) => (TONES.includes(t) ? t : 'info');

/**
 * Part of a chart that matches a selection kept by its label: the part itself, or « Autres » when the category selected is
 * now gathered there (its members are kept). -1 when nothing matches.
 * @param {Array<{ label: string, other?: boolean, members?: string[] }>} parts @param {string|null} label
 */
export function selectedIndex(parts, label) {
  if (!label) return -1;
  const direct = parts.findIndex((p) => p.label === label);
  if (direct >= 0) return direct;
  return parts.findIndex((p) => p.other && (p.members ?? []).includes(label));
}

/** True when a part may be clicked: the board listens for selections and the part carries a criterion. */
const clickable = (part, o) => !!(o?.selectable && (part.criterion || part.criteria?.length));

// ---------- Visuals ----------

export function kpiVisual(e) {
  const unit = e.unit ? `<small>${esc(e.unit)}</small>` : '';
  const max = Number.isFinite(e.maximum) && e.maximum > 0 ? `<span class="sh-kpi-of">/${NBSP}${num(e.maximum)}</span>` : '';
  return `<div class="sh-kpi" data-tone="${tone(e.state)}"><span class="sh-kpi-v">${esc(e.display ?? num(e.number ?? e.value))}${unit}${max}</span>${e.subtitle ? `<span class="sh-kpi-s">${esc(e.subtitle)}</span>` : ''}</div>`;
}

export function gaugeVisual(e) {
  const max = Number(e.maximum) > 0 ? Number(e.maximum) : 100;
  const value = Number(e.number);
  const known = Number.isFinite(value);
  const p = known ? Math.max(0, Math.min(1, value / max)) : 0;
  const len = 75;
  return `<div class="sh-gauge" data-tone="${tone(e.state)}" role="meter" aria-valuemin="0" aria-valuemax="${max}"${known ? ` aria-valuenow="${value}"` : ''} aria-label="${esc(e.title ?? '')}">
    <svg viewBox="0 0 120 120" aria-hidden="true"><circle class="sh-gauge-track" cx="60" cy="60" r="48" pathLength="100" transform="rotate(135 60 60)"/>
      <circle class="sh-gauge-fill" cx="60" cy="60" r="48" pathLength="100" transform="rotate(135 60 60)" data-gauge="${(p * len).toFixed(2)}"/></svg>
    <span class="sh-gauge-v">${known ? esc(e.display ?? `${num(value)}${e.unit ? NBSP + e.unit : ''}`) : '—'}</span>
  </div>`;
}

/** Ring of a score out of 100 (score and health cards): track, arc coloured by the state, value and « sur 100 ». */
function scoreRing(e, size = 'md') {
  const value = Number(e.number);
  const known = Number.isFinite(value);
  const p = known ? Math.max(0, Math.min(1, value / 100)) : 0;
  return `<div class="sh-score-ring ${size}" data-tone="${tone(e.state)}" role="meter" aria-valuemin="0" aria-valuemax="100"${known ? ` aria-valuenow="${Math.round(value)}"` : ''} aria-label="${esc(`${e.title ?? 'Score'}${known ? ` : ${Math.round(value)} sur 100` : ' : non mesuré'}`)}">
    <svg viewBox="0 0 120 120" aria-hidden="true"><circle class="sh-score-track" cx="60" cy="60" r="50"/>${known && p > 0.004 ? `<circle class="sh-score-arc" cx="60" cy="60" r="50" pathLength="100" data-gauge="${(p * 100).toFixed(2)}" transform="rotate(-90 60 60)"/>` : ''}</svg>
    <span class="sh-score-v"><b>${known ? Math.round(value) : '—'}</b><small>sur 100</small></span>
  </div>`;
}

function actionButton(a) {
  return a?.id ? `<button class="btn sm subtle" type="button" data-w-action="${esc(a.id)}"${a.tip ? ` data-tip="${esc(a.tip)}"` : ''}>${a.icon ? icon(a.icon) : ''}${esc(a.label ?? a.text ?? 'Voir')}</button>` : '';
}

/** Score card (Domenia 1 New-DomeniaHealthCard): ring, verdict coloured by the state, detail, warning badge, an action. */
export function scoreVisual(e) {
  const verdictTone = e.state === 'warn' || e.state === 'alert' ? ` data-tone="${tone(e.state)}"` : '';
  return `<div class="sh-score">${scoreRing(e)}
    ${e.verdict ? `<p class="sh-score-verdict"${verdictTone}>${esc(e.verdict)}</p>` : ''}
    ${e.subtitle ? `<p class="sh-score-detail">${esc(e.subtitle)}</p>` : ''}
    ${e.badge ? `<span class="sh-score-badge">${esc(e.badge)}</span>` : ''}
    ${actionButton(e.action)}</div>`;
}

/**
 * Health card (Domenia 1 New-DomeniaHealthSummaryCard): the score on one side, the points to check on the other, most
 * serious first (9 at most); under 520 px the list goes under the score. With nothing to check, one green line, only when
 * the score is established (`reliable`).
 */
export function healthVisual(e) {
  const order = { alert: 0, warn: 1, info: 2, ok: 3 };
  const points = [...(e.items ?? [])].sort((a, b) => (order[a.level] ?? 2) - (order[b.level] ?? 2)).slice(0, 9);
  const more = Math.max(0, (e.items ?? []).length - points.length);
  const list = points.length
    ? `<ul class="sh-points">${points.map((i) => {
      const [t, word] = LEVELS[i.level] ?? LEVELS.info;
      return `<li data-tone="${t}"><span class="sh-point-mark" aria-hidden="true"></span><span class="visually-hidden">${esc(word)}${NBSP}: </span><span>${esc(i.text ?? i.label)}</span>${i.detail ? `<span class="sh-point-d">${esc(i.detail)}</span>` : ''}</li>`;
    }).join('')}${more ? `<li class="sh-points-more">et ${more} autre${more > 1 ? 's' : ''} point${more > 1 ? 's' : ''}</li>` : ''}</ul>`
    : e.reliable !== false ? `<p class="sh-health-clear"><span aria-hidden="true">✓</span>${esc(e.clearText ?? 'Rien à vérifier.')}</p>` : '';
  const verdictTone = e.state === 'warn' || e.state === 'alert' ? ` data-tone="${tone(e.state)}"` : '';
  return `<div class="sh-health">
    <div class="sh-health-score">${scoreRing(e, 'sm')}<div class="sh-health-words">
      ${e.verdict ? `<p class="sh-score-verdict"${verdictTone}>${esc(e.verdict)}</p>` : ''}
      ${e.subtitle ? `<p class="sh-score-detail">${esc(e.subtitle)}</p>` : ''}
      ${e.badge ? `<span class="sh-score-badge">${esc(e.badge)}</span>` : ''}
      ${actionButton(e.action)}</div></div>
    <div class="sh-health-points">${e.pointsTitle ? `<h4 class="sh-health-title">${esc(e.pointsTitle)}</h4>` : ''}${list}</div>
  </div>`;
}

export function donutVisual(e, o = {}) {
  const parts = groupOthers(e.items ?? [], 8);
  const total = parts.reduce((s, i) => s + Number(i.value), 0);
  if (!total) return emptyVisual(e.empty ?? 'Aucune valeur à répartir.', e.emptyAction ? { icon: e.emptyIcon, action: e.emptyAction } : { icon: e.emptyIcon });
  const selected = selectedIndex(parts, o.selected ?? null);
  let start = 0;
  const arcs = parts.map((part, n) => {
    const pct = (Number(part.value) / total) * 100;
    const len = Math.max(0, pct - (parts.length > 1 ? 0.8 : 0));
    const series = part.other ? 'other' : `s${(n % 8) + 1}`;
    const rotate = `rotate(${(start * 3.6).toFixed(2)} 60 60)`;
    start += pct;
    // The darker edge sits under the segment, a little wider: the pastel keeps a 3:1 outline on the light card.
    return `<circle class="seg-edge ${series}" cx="60" cy="60" r="50" pathLength="100" data-len="${len.toFixed(2)}" transform="${rotate}"/>`
      + `<circle class="seg ${series}${n === selected ? ' selected' : ''}" cx="60" cy="60" r="50" pathLength="100" data-len="${len.toFixed(2)}" data-i="${n}" data-key="${n}" transform="${rotate}"/>`;
  }).join('');
  const legend = parts.map((part, n) => {
    const share = Math.round((Number(part.value) / total) * 100);
    const tip = part.other ? `${part.label}${NBSP}: ${part.members.slice(0, 12).join(', ')}${part.members.length > 12 ? '…' : ''}` : `${part.label}${NBSP}: ${num(part.value)} (${share}${NBSP}%)`;
    const inner = `<span class="sh-swatch ${part.other ? 'other' : `s${(n % 8) + 1}`}" aria-hidden="true"></span><span class="sh-legend-l">${esc(part.label)}</span><span class="sh-legend-v">${share}${NBSP}%</span>`;
    return clickable(part, o)
      ? `<li><button type="button" class="sh-legend-item" data-key="${n}" data-seg="${n}" aria-pressed="${n === selected}" data-tip="${esc(`${tip} · cliquez pour ne garder que cette part`)}">${inner}</button></li>`
      : `<li class="sh-legend-item static" data-key="${n}" data-tip="${esc(tip)}">${inner}</li>`;
  }).join('');
  return `<div class="sh-donut${selected >= 0 ? ' has-selection' : ''}"><div class="ring donut sm" role="img" aria-label="${esc(`${e.title ?? 'Répartition'} : ${parts.map((p) => `${p.label} ${num(p.value)}`).join(', ')}`)}"><svg viewBox="0 0 120 120"><circle class="track" cx="60" cy="60" r="50"/>${arcs}</svg><div class="center"><b>${esc(num(total))}</b><span>${esc(e.unit ?? 'au total')}</span></div></div><ul class="sh-legend">${legend}</ul></div>`;
}

export function barsVisual(e, o = {}) {
  const items = (e.items ?? []).slice(0, 12);
  if (!items.length) return emptyVisual(e.empty ?? 'Aucune valeur.', { icon: e.emptyIcon, action: e.emptyAction });
  const max = Math.max(1, ...items.map((i) => Number(i.value) || 0));
  const selected = selectedIndex(items, o.selected ?? null);
  return `<ol class="sh-hbars">${items.map((i, n) => {
    const p = (Number(i.value) || 0) / max;
    const tip = `${i.label}${NBSP}: ${i.display ?? num(i.value)}`;
    const inner = `<span class="sh-hbar-l">${esc(i.label)}</span><span class="sh-hbar-track"><span class="sh-hbar" data-p="${p.toFixed(3)}" data-i="${n}"${i.state ? ` data-tone="${tone(i.state)}"` : ''}></span></span><span class="sh-hbar-v">${esc(i.display ?? num(i.value))}</span>`;
    return clickable(i, o)
      ? `<li><button type="button" class="sh-hbar-row" data-seg="${n}" aria-pressed="${n === selected}" data-tip="${esc(`${tip} · cliquez pour ouvrir`)}">${inner}</button></li>`
      : `<li class="sh-hbar-row static" data-tip="${esc(tip)}">${inner}</li>`;
  }).join('')}</ol>`;
}

export function columnsVisual(e) {
  const items = (e.items ?? []).slice(-12);
  if (!items.length) return emptyVisual(e.empty ?? 'Aucune valeur.', { icon: e.emptyIcon, action: e.emptyAction });
  // Every known value at zero: a row of calm tiles instead of an empty plot with a meaningless axis.
  const isKnown = (i) => i.value !== null && i.value !== undefined && Number.isFinite(Number(i.value));
  if (items.some(isKnown) && items.filter(isKnown).every((i) => Number(i.value) === 0)) {
    return `<div class="sh-zero"><ul class="sh-zero-tiles">${items.map((i, n) => `<li data-i="${n}"><span class="sh-zero-v">${isKnown(i) ? esc(i.display ?? num(0)) : '—'}</span><span class="sh-zero-l">${esc(i.label)}</span></li>`).join('')}</ul>`
      + `<p class="sh-zero-note"><span aria-hidden="true">✓</span>${esc(e.zeroText ?? 'Toutes les valeurs sont à zéro.')}</p></div>`;
  }
  const scale = chartTicks(Math.max(0, ...items.map((i) => Number(i.value) || 0)), { integer: e.integer !== false });
  return `<div class="sh-cols"><div class="sh-cols-axis" aria-hidden="true">${[...scale.ticks].reverse().map((t) => `<span>${esc(num(t))}</span>`).join('')}</div>
    <ol class="sh-cols-plot">${items.map((i, n) => {
      const known = Number.isFinite(Number(i.value)) && i.value !== null;
      const p = known ? (Number(i.value) / scale.top) : 0;
      return `<li data-tip="${esc(`${i.label}${NBSP}: ${known ? (i.display ?? num(i.value)) : 'aucun relevé'}`)}"><span class="sh-col-v">${known ? esc(i.display ?? num(i.value)) : '—'}</span><span class="sh-col-track">${known ? `<span class="sh-col rise" data-p="${p.toFixed(3)}" data-i="${n}"></span>` : '<span class="sh-col-gap"></span>'}</span><span class="sh-col-l">${esc(i.label)}</span></li>`;
    }).join('')}</ol></div>`;
}

export function lineVisual(e) {
  const items = (e.items ?? []).filter((i) => Number.isFinite(Number(i.value)));
  if (items.length < 2) return emptyVisual(e.empty ?? 'Pas assez de points pour une courbe.', { icon: e.emptyIcon ?? 'activity', action: e.emptyAction });
  const w = 300;
  const h = 110;
  const pad = 8;
  const scale = chartTicks(Math.max(...items.map((i) => Number(i.value))), { integer: e.integer !== false });
  const pts = items.map((i, n) => [pad + (n / (items.length - 1)) * (w - pad * 2), pad + (1 - Number(i.value) / scale.top) * (h - pad * 2)]);
  let d = `M${pts[0][0].toFixed(1)},${pts[0][1].toFixed(1)}`;
  for (let n = 0; n < pts.length - 1; n += 1) {
    const [x0, y0] = pts[Math.max(0, n - 1)];
    const [x1, y1] = pts[n];
    const [x2, y2] = pts[n + 1];
    const [x3, y3] = pts[Math.min(pts.length - 1, n + 2)];
    d += ` C${(x1 + (x2 - x0) / 6).toFixed(1)},${(y1 + (y2 - y0) / 6).toFixed(1)} ${(x2 - (x3 - x1) / 6).toFixed(1)},${(y2 - (y3 - y1) / 6).toFixed(1)} ${x2.toFixed(1)},${y2.toFixed(1)}`;
  }
  const last = pts.at(-1);
  const area = `${d} L${last[0].toFixed(1)},${h} L${pts[0][0].toFixed(1)},${h} Z`;
  const marks = items.map((i, n) => `<circle class="sh-line-hit" cx="${pts[n][0].toFixed(1)}" cy="${pts[n][1].toFixed(1)}" r="6"><title>${esc(`${i.label} : ${i.display ?? num(i.value)}`)}</title></circle>`).join('');
  return `<div class="sh-line"><svg viewBox="0 0 ${w} ${h}" preserveAspectRatio="none" role="img" aria-label="${esc(`${e.title ?? 'Courbe'} : ${items.map((i) => `${i.label} ${num(i.value)}`).join(', ')}`)}">
      <path class="sh-line-area" d="${area}"/><path class="sh-line-path" d="${d}"/>${marks}<circle class="sh-line-last" cx="${last[0].toFixed(1)}" cy="${last[1].toFixed(1)}" r="4"/></svg>
    <div class="sh-line-x" aria-hidden="true"><span>${esc(items[0].label)}</span><span>${esc(items.at(-1).label)} · ${esc(items.at(-1).display ?? num(items.at(-1).value))}</span></div></div>`;
}

const LEVELS = { alert: ['alert', 'Critique'], warn: ['warn', 'À surveiller'], info: ['info', 'Information'], ok: ['ok', 'Conforme'] };

export function listVisual(e) {
  const items = (e.items ?? []).slice(0, 20);
  if (!items.length) return emptyVisual(e.empty ?? 'Aucun point à signaler.', { icon: e.emptyIcon ?? 'check', action: e.emptyAction, calm: true });
  return `<ul class="sh-points">${items.map((i) => {
    const [t, word] = LEVELS[i.level] ?? LEVELS.info;
    return `<li data-tone="${t}"><span class="sh-point-mark" aria-hidden="true"></span><span class="visually-hidden">${esc(word)}${NBSP}: </span><span>${esc(i.text ?? i.label)}</span>${i.detail ? `<span class="sh-point-d">${esc(i.detail)}</span>` : ''}</li>`;
  }).join('')}</ul>`;
}

/**
 * « Liste » (Domenia 1 Text, TRV-286): the values written as lines, for any kind of data (a value, the parts of a
 * distribution with their share, the points of a series), 20 lines at most.
 */
export function textVisual(e) {
  const all = e.items ?? [];
  const items = all.slice(0, 20);
  const hasValue = e.value !== undefined && e.value !== null && e.value !== '';
  if (!items.length && !hasValue) return emptyVisual(e.empty ?? 'Aucune valeur.', { icon: e.emptyIcon, action: e.emptyAction });
  const total = e.kind === 'distribution' ? all.reduce((s, i) => s + (Number(i.value) || 0), 0) : 0;
  const shown = (v) => (typeof v === 'number' ? num(v) : String(v ?? '—'));
  const head = hasValue
    ? `<li class="sh-text-main"><span class="sh-text-l">${esc(e.title ?? 'Valeur')}</span><span class="sh-text-v">${esc(e.display ?? shown(e.value))}${e.unit ? ` ${esc(e.unit)}` : ''}</span></li>`
    : '';
  const lines = items.map((i) => {
    const share = total > 0 ? ` (${Math.round(((Number(i.value) || 0) / total) * 100)}${NBSP}%)` : '';
    return `<li${i.state ? ` data-tone="${tone(i.state)}"` : ''}><span class="sh-text-l">${esc(i.label ?? i.text ?? '')}</span><span class="sh-text-v">${esc(i.display ?? shown(i.value))}${esc(share)}</span></li>`;
  }).join('');
  const more = all.length > 20 ? `<p class="sh-text-more faint">et ${num(all.length - 20)} autre${all.length - 20 > 1 ? 's' : ''}</p>` : '';
  return `<ul class="sh-textlist">${head}${lines}</ul>${more}`;
}

export function sheetVisual(e) {
  const items = (e.items ?? []).slice(0, 20);
  if (!items.length) return emptyVisual(e.empty ?? 'Aucune information.', { icon: e.emptyIcon, action: e.emptyAction });
  return `<dl class="sh-sheet">${items.map((i) => `<div><dt>${esc(i.label)}</dt><dd${i.state ? ` data-tone="${tone(i.state)}"` : ''}>${esc(i.display ?? i.value ?? '—')}${i.detail ? `<span class="sh-sheet-d">${esc(i.detail)}</span>` : ''}</dd></div>`).join('')}</dl>`;
}

const MARKS = { ok: ['✓', 'OK'], warn: ['!', 'À vérifier'], alert: ['✕', 'Critique'], off: ['?', 'Non lu'], info: ['i', 'Information'] };

export function checklistVisual(e) {
  const items = (e.items ?? []).slice(0, 20);
  if (!items.length) return emptyVisual(e.empty ?? 'Aucun contrôle.', { icon: e.emptyIcon, action: e.emptyAction });
  return `<ul class="sh-checks">${items.map((i) => {
    const [g, word] = MARKS[i.state] ?? MARKS.info;
    return `<li data-tone="${tone(i.state)}"><span class="sh-check-mark" aria-hidden="true">${g}</span><span class="sh-check-l">${esc(i.label)}<span class="visually-hidden"> (${esc(word)})</span></span><span class="sh-check-v">${esc(i.display ?? i.value ?? '')}</span></li>`;
  }).join('')}</ul>`;
}

/**
 * Empty state of a widget: an illustration, one sentence and, when the screen gives one, the action that fills it
 * (`{ id, label, icon? }`, handled by the board through onAction). `calm`: nothing to report is good news (green mark).
 */
export function emptyVisual(text, { icon: name = '', action = null, calm = false } = {}) {
  return `<div class="sh-chart-empty${calm ? ' calm' : ''}"><span class="sh-empty-art" aria-hidden="true">${icon(name || (calm ? 'check' : 'sparkles'))}</span><p>${esc(text)}</p>${actionButton(action)}</div>`;
}

/** Accessible table of a widget (alternative to its chart). */
export function dataTable(e) {
  const items = e.items ?? [];
  if (!items.length) return `<p class="faint">Aucune ligne.</p>`;
  const total = items.reduce((s, i) => s + (Number(i.value) || 0), 0);
  const share = e.kind === 'distribution' && total > 0;
  return `<table class="table sh-data-table"><caption class="visually-hidden">${esc(e.title ?? 'Données du widget')}</caption>
    <thead><tr><th scope="col">Libellé</th><th scope="col">Valeur</th>${share ? '<th scope="col">Part</th>' : ''}</tr></thead>
    <tbody>${items.map((i) => `<tr><th scope="row">${esc(i.label ?? i.text ?? '')}</th><td>${esc(i.display ?? (i.value !== undefined ? num(i.value) : ''))}</td>${share ? `<td>${Math.round(((Number(i.value) || 0) / total) * 100)}${NBSP}%</td>` : ''}</tr>`).join('')}</tbody></table>`;
}

/**
 * Visual of an entry for a representation. `o.selectable`: the board listens for selections (parts with a criterion become
 * buttons); `o.selected`: label of the part selected.
 */
export function visualMarkup(visual, e, o = {}) {
  switch (visual) {
    case 'kpi': return kpiVisual(e);
    case 'gauge': return gaugeVisual(e);
    case 'score': return scoreVisual(e);
    case 'health': return healthVisual(e);
    case 'donut': return donutVisual(e, o);
    case 'bars': return barsVisual(e, o);
    case 'columns': return columnsVisual(e);
    case 'line': return lineVisual(e);
    case 'list': return listVisual(e);
    case 'text': return textVisual(e);
    case 'sheet': return sheetVisual(e);
    case 'checklist': return checklistVisual(e);
    default: return kpiVisual(e);
  }
}

/** Applies the CSS variables of the marks (CSP: no style attribute) and wires the ring legends. */
export function paintCharts(scope) {
  scope.querySelectorAll('[data-p]').forEach((el) => el.style.setProperty('--p', el.dataset.p));
  scope.querySelectorAll('[data-i]').forEach((el) => el.style.setProperty('--i', el.dataset.i));
  scope.querySelectorAll('[data-len]').forEach((el) => el.style.setProperty('--len', el.dataset.len));
  scope.querySelectorAll('[data-gauge]').forEach((el) => el.style.setProperty('--g', el.dataset.gauge));
  scope.querySelectorAll('.sh-donut').forEach((box) => {
    const ring = box.querySelector('.ring');
    const focus = (key) => {
      ring.classList.toggle('has-focus', key !== null);
      ring.querySelectorAll('circle.seg').forEach((c) => c.classList.toggle('focus', c.dataset.key === key));
      box.querySelectorAll('.sh-legend-item').forEach((b) => b.classList.toggle('dim', key !== null && b.dataset.key !== key));
    };
    box.addEventListener('pointerover', (e) => { const k = e.target instanceof Element ? e.target.closest('[data-key]')?.dataset.key : null; focus(k ?? null); });
    // Hovering a segment shows its share in the legend (and the reverse); the legend line names it for the tooltip.
    ring.querySelectorAll('circle.seg').forEach((c) => {
      const item = box.querySelector(`.sh-legend-item[data-key="${c.dataset.key}"]`);
      if (item?.dataset.tip) c.dataset.tip = item.dataset.tip;
    });
    box.addEventListener('pointerleave', () => focus(null));
    box.addEventListener('focusin', (e) => { const k = e.target instanceof Element ? e.target.closest('[data-key]')?.dataset.key : null; focus(k ?? null); });
    box.addEventListener('focusout', () => focus(null));
  });
}
