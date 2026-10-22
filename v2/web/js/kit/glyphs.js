// Extra stroke icons for the kit (same 24 px grid and stroke as icons.js); unknown names fall back to icons.js.
import { icon } from '../icons.js';

const paths = {
  chevronDown: '<path d="m6 9 6 6 6-6"/>',
  chevronLeft: '<path d="m15 5-7 7 7 7"/>',
  chevronUp: '<path d="m6 15 6-6 6 6"/>',
  filter: '<path d="M4 5h16l-6.2 7.4V19l-3.6-1.8v-4.8Z"/>',
  columns: '<rect x="3" y="4" width="18" height="16" rx="2.5"/><path d="M9 4v16M15 4v16"/>',
  rows: '<rect x="3" y="4" width="18" height="16" rx="2.5"/><path d="M3 9.5h18M3 14.5h18"/>',
  download: '<path d="M12 4v11M7 10.5l5 5 5-5"/><path d="M4.5 19.5h15"/>',
  csv: '<path d="M14 3H6.5A2.5 2.5 0 0 0 4 5.5v13A2.5 2.5 0 0 0 6.5 21h11a2.5 2.5 0 0 0 2.5-2.5V9Z"/><path d="M14 3v6h6"/><path d="M8 13h8M8 17h8M12 11v8"/>',
  grip: '<circle cx="9" cy="6" r="1"/><circle cx="15" cy="6" r="1"/><circle cx="9" cy="12" r="1"/><circle cx="15" cy="12" r="1"/><circle cx="9" cy="18" r="1"/><circle cx="15" cy="18" r="1"/>',
  plus: '<path d="M12 5v14M5 12h14"/>',
  minus: '<path d="M5 12h14"/>',
  undo: '<path d="M9 14 4 9l5-5"/><path d="M4 9h10.5a5.5 5.5 0 0 1 0 11H11"/>',
  calendar: '<rect x="3.5" y="5" width="17" height="15.5" rx="2.5"/><path d="M3.5 10h17M8 3v4M16 3v4"/>',
  edit: '<path d="M4 20h4L19 9a2.8 2.8 0 0 0-4-4L4 16Z"/><path d="m13.5 6.5 4 4"/>',
  sliders: '<path d="M4 6h10M18 6h2M4 12h4M12 12h8M4 18h12M20 18h0"/><circle cx="16" cy="6" r="2"/><circle cx="10" cy="12" r="2"/><circle cx="18" cy="18" r="2"/>',
  sort: '<path d="M8 4v16M4 8l4-4 4 4"/><path d="M16 20V4M12 16l4 4 4-4"/>',
  external: '<path d="M14 4h6v6M20 4l-9 9"/><path d="M18 14v4.5a1.5 1.5 0 0 1-1.5 1.5h-11A1.5 1.5 0 0 1 4 18.5v-11A1.5 1.5 0 0 1 5.5 6H10"/>',
  history: '<path d="M3.5 12a8.5 8.5 0 1 0 2.5-6L3.5 8.5"/><path d="M3.5 4v4.5H8"/><path d="M12 8v4.5l3 2"/>',
  pin: '<path d="M9 4h6l-1 6 3 3v1.5H7V13l3-3Z"/><path d="M12 14.5V21"/>',
  layers: '<path d="m12 3 9 5-9 5-9-5Z"/><path d="m3 13 9 5 9-5"/>',
  split: '<rect x="3" y="4" width="18" height="16" rx="2.5"/><path d="M12 4v16"/><path d="m8 10-2 2 2 2M16 10l2 2-2 2"/>',
  gauge: '<path d="M4.5 17a8.5 8.5 0 1 1 15 0"/><path d="m12 13 4-5"/><circle cx="12" cy="13.5" r="1.3"/>',
  tag: '<path d="M3.5 12.5V4.5a1 1 0 0 1 1-1h8l8 8a1.5 1.5 0 0 1 0 2.1l-6.9 6.9a1.5 1.5 0 0 1-2.1 0Z"/><circle cx="8" cy="8" r="1.4"/>',
  hash: '<path d="M9 3 7 21M17 3l-2 18M4 8.5h16M3.5 15.5h16"/>',
  ou: '<path d="M3 7.5A2.5 2.5 0 0 1 5.5 5H10l2 2.5h6.5A2.5 2.5 0 0 1 21 10v7.5a2.5 2.5 0 0 1-2.5 2.5h-13A2.5 2.5 0 0 1 3 17.5Z"/><path d="M8.5 13.5h7"/>',
  domain: '<circle cx="12" cy="12" r="9"/><path d="M3 12h18M12 3a14 14 0 0 1 0 18M12 3a14 14 0 0 0 0 18"/>',
  group: '<circle cx="8" cy="9" r="3"/><circle cx="16.5" cy="9" r="3"/><path d="M2.5 19a5.5 5.5 0 0 1 11 0M11 19a5.5 5.5 0 0 1 10.5-2.3"/>',
  dot: '<circle cx="12" cy="12" r="3" fill="currentColor"/>',
  phone: '<path d="M21 16.4v2.8a1.9 1.9 0 0 1-2.1 1.9 18.7 18.7 0 0 1-8.1-2.9 18.4 18.4 0 0 1-5.7-5.7A18.7 18.7 0 0 1 2.2 4.4 1.9 1.9 0 0 1 4.1 2.3h2.8A1.9 1.9 0 0 1 8.8 4c.1.9.4 1.7.7 2.5a1.9 1.9 0 0 1-.4 2L7.9 9.7a15 15 0 0 0 5.7 5.7l1.2-1.2a1.9 1.9 0 0 1 2-.4c.8.3 1.6.6 2.5.7a1.9 1.9 0 0 1 1.7 1.9Z"/>',
  mail: '<rect x="3" y="5" width="18" height="14" rx="2.5"/><path d="m3.5 7 8.5 6 8.5-6"/>',
  building: '<path d="M4 21V5.5A1.5 1.5 0 0 1 5.5 4h8A1.5 1.5 0 0 1 15 5.5V21"/><path d="M15 10h3.5a1.5 1.5 0 0 1 1.5 1.5V21M3 21h18M8 8h3M8 12h3M8 16h3"/>',
};

/**
 * Inline SVG icon (aria-hidden). Kit glyphs first, then the application set (icons.js).
 * @param {string} name @param {string} [cls]
 * @returns {string}
 */
export function glyph(name, cls = '') {
  const body = paths[name];
  if (!body) return icon(name, cls);
  return `<svg class="${cls}" width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${body}</svg>`;
}
