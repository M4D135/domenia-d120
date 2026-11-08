import { esc, int, meter, donut } from './common.js';

/** Alternate views of the same already-read parts. Unknown values never become zero and filter links remain exact. */
export function distributionVisual(parts, visual, { title = '', headline = null } = {}) {
  const known = parts.filter((p) => Number.isFinite(p.value) && p.value >= 0);
  const maximum = Math.max(1, ...known.map((p) => p.value));
  const value = (p) => p.text ?? (Number.isFinite(p.value) ? int(p.value) : 'Non lu');
  const name = (p, n) => { const label = visual === 'Column' ? `${n + 1}. ${p.label}` : p.label; return p.filter ? `<button class="ps-part" type="button" data-part="${esc(p.filter)}">${esc(label)}</button>` : `<span>${esc(label)}</span>`; };
  const list = visual === 'Column' ? 'ol' : 'ul';
  const legend = `<${list} class="ps-layout-values">${parts.map((p, n) => `<li>${name(p, n)}${visual === 'Bar' && Number.isFinite(p.value) ? meter(p.value / maximum, p.tone ?? 'accent') : ''}<b>${esc(value(p))}</b></li>`).join('')}</${list}>`;
  if (!parts.length) return '<p class="ps-faint">Aucune valeur dans le relevé disponible.</p>';
  if (visual === 'Text' || visual === 'Bar') return legend;
  if (visual === 'Kpi') return `${headline == null ? '' : `<p class="ps-layout-number">${esc(headline)}</p>`}${legend}`;
  if (!known.length) return `<p class="ps-faint">Valeurs numériques non lues.</p>${legend}`;
  if (visual === 'Pie') return donut(known.map((p) => ({ value: p.value, tone: p.tone })), { label: title }) + legend;
  if (visual === 'Column') {
    const width = Math.max(60, parts.length * 48);
    return `<div class="ps-layout-columns"><svg viewBox="0 0 ${width} 126" role="img" aria-label="${esc(title)}">${parts.map((p, n) => {
      if (!Number.isFinite(p.value) || p.value < 0) return '';
      const height = p.value / maximum * 100;
      return `<g><title>${esc(p.label)} : ${esc(value(p))}</title><rect x="${n * 48 + 12}" y="${110 - height}" width="28" height="${height}" rx="2" data-c="${n % 8}"/><text x="${n * 48 + 26}" y="122" text-anchor="middle">${n + 1}</text></g>`;
    }).join('')}</svg></div>${legend}`;
  }
  throw new Error('Présentation de répartition inconnue.');
}
