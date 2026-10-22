// Accueil: helpers shared by the page and its parts (distinguished names, CSS variables set through the CSSOM, small
// markup pieces, drawer bodies scoped to the screen stylesheet). No bridge call here.
import { glyph } from '../../kit/glyphs.js';
import { esc, errorText, applyVars, formatNumber, copyText } from '../../ui.js';

// No-break space before « % » and « : », as in the engine texts (OPERATIONS.md § 1.2).
export const NBSP = ' ';
export const PATH_SEP = `${NBSP}› `;
export const isNum = (v) => typeof v === 'number' && Number.isFinite(v);
// Numbers written into attributes: always a plain number ("NaN" for a missing measure, shown "—").
export const numAttr = (v) => (isNum(v) ? String(v) : 'NaN');
export const plural = (n, one, many) => `${formatNumber(n)}${NBSP}${Math.abs(n) > 1 ? many : one}`;
export const capitalize = (t) => (t ? t[0].toLocaleUpperCase('fr') + t.slice(1) : t);
export const pct = (v) => `${formatNumber(v, 1)}${NBSP}%`;
export const TONES = new Set(['ok', 'warn', 'alert', 'info', 'off', 'accent']);
export const tone = (t) => (TONES.has(t) ? t : '');

// The simulation (and the browser preview) never opens the local base: its figures come from the fictitious directory
// kept in memory (SIMULATION.md § 1), and the texts say so.
export const isSimulated = (s, app) => s?.connection?.state === 'simulated' || app?.mode === 'simulation';

/** Operator text of an error; browser errors (no code) are logged, their English message is never shown. */
export function reported(err) {
  if (!err?.code) console.error(err);
  return errorText(err);
}

// ---------- Distinguished names (RFC 4514) ----------

/** Splits a DN into its RDN; escaped commas stay inside their RDN. */
export function splitDn(dn) {
  const parts = [];
  let cur = '';
  for (let n = 0; n < dn.length; n++) {
    const c = dn[n];
    if (c === '\\' && n + 1 < dn.length) { cur += c + dn[n + 1]; n += 1; continue; }
    if (c === ',') { parts.push(cur.trim()); cur = ''; continue; }
    cur += c;
  }
  if (cur.trim()) parts.push(cur.trim());
  return parts;
}

/** Value of an RDN with its escapes decoded (\, and hexadecimal UTF-8 bytes such as \C3\A9). */
export function rdnValue(rdn) {
  const raw = rdn.slice(rdn.indexOf('=') + 1);
  const bytes = [];
  let out = '';
  const flush = () => { if (bytes.length) { out += new TextDecoder().decode(new Uint8Array(bytes)); bytes.length = 0; } };
  for (let n = 0; n < raw.length; n++) {
    if (raw[n] === '\\' && /^[0-9a-f]{2}$/i.test(raw.slice(n + 1, n + 3))) { bytes.push(parseInt(raw.slice(n + 1, n + 3), 16)); n += 2; continue; }
    flush();
    if (raw[n] === '\\' && n + 1 < raw.length) { out += raw[n + 1]; n += 1; continue; }
    out += raw[n];
  }
  flush();
  return out;
}

export const rdnType = (rdn) => rdn.slice(0, Math.max(0, rdn.indexOf('='))).trim().toUpperCase();
export const sameDn = (a, b) => typeof a === 'string' && typeof b === 'string' && a.toLowerCase() === b.toLowerCase();

/** Root of the domain and chain of the containers of a DN from the top ({ dn, name, type }, the DN itself last). */
export function dnChain(dn, dnsName) {
  const rdns = splitDn(String(dn ?? ''));
  const dcAt = rdns.findIndex((r) => rdnType(r) === 'DC');
  if (dcAt < 0) return null;
  const domain = dnsName || rdns.slice(dcAt).map(rdnValue).join('.');
  const chain = [];
  for (let k = dcAt - 1; k >= 0; k--) chain.push({ dn: rdns.slice(k).join(','), name: rdnValue(rdns[k]), type: rdnType(rdns[k]) });
  return { root: { dn: rdns.slice(dcAt).join(','), name: domain }, chain };
}

export const pathOf = (dn, dnsName) => {
  const c = dnChain(dn, dnsName);
  return c ? [c.root.name, ...c.chain.map((x) => x.name)].join(PATH_SEP) : '';
};

/** True when a scope is the root of its domain (DN made of DC= parts only). */
export const isRootDn = (dn) => {
  const rdns = splitDn(String(dn ?? ''));
  return rdns.length > 0 && rdns.every((r) => rdnType(r) === 'DC');
};

// ---------- CSS variables set through the CSSOM (CSP forbids style="…") ----------

const LOCAL = ['x', 'y', 'h', 'w', 'lvl'];
const LOCAL_SEL = LOCAL.map((k) => `[data-${k}]`).join(',');

/** data-x / data-y / data-h / data-w: positions and sizes in percent; data-lvl: depth (0 to 100). */
function applyLocal(scope) {
  const list = scope.matches?.(LOCAL_SEL) ? [scope] : [];
  list.push(...scope.querySelectorAll(LOCAL_SEL));
  for (const el of list) {
    for (const k of LOCAL) {
      const v = el.dataset[k];
      if (v === undefined) continue;
      const n = Number(v);
      el.style.setProperty(`--${k}`, String(Number.isFinite(n) ? Math.min(100, Math.max(0, n)) : 0));
    }
  }
}

/** Sets every CSS variable carried by data attributes in scope (ui.js applyVars plus the local ones). */
export function paint(scope) {
  if (!scope) return;
  applyVars(scope);
  applyLocal(scope);
}

// ---------- Markup pieces ----------

export const sk = (cls) => `<span class="skeleton sk ${cls}"></span>`;
export const skStack = (...cls) => `<div class="sk-stack">${cls.map(sk).join('')}</div>`;

/** Short note with an icon and an optional button (data-act on the button). */
export function note(iconName, text, action = '') {
  return `<div class="off-note">${glyph(iconName)}<span>${esc(text)}</span>${action}</div>`;
}

/** Error block with its retry button (data attribute given by the caller). */
export function errorBlock(err, retryAttr) {
  return `<div class="acc-err" role="alert">${glyph('alert')}<span>${esc(reported(err))}</span>`
    + `${retryAttr ? `<button class="btn sm" type="button" ${retryAttr}>${glyph('refresh')}Réessayer</button>` : ''}</div>`;
}

/** Hover tip that keyboard users can reach (tabindex) and screen readers hear (hidden copy of the tip). */
export function tipSpan(cls, tip, visible) {
  return `<span class="${cls}" tabindex="0" data-tip="${esc(tip)}">${visible}<span class="visually-hidden"> · ${esc(tip)}</span></span>`;
}

/**
 * Body of a drawer or a dialog of the screen: the kit poses its layers in <body>, outside .main; the data-page
 * attribute keeps the rules of css/pages/accueil.css (all scoped to [data-page="accueil"]) applying inside.
 * @param {string} cls @param {string} [html]
 */
export function surface(cls, html = '') {
  const el = document.createElement('div');
  el.dataset.page = 'accueil';
  el.className = `acc-surface ${cls}`;
  el.innerHTML = html;
  return el;
}

/** Local date and time « 22/10/2026 14:05 » of an ISO instant ('' when absent). */
export function localStamp(iso) {
  const d = iso ? new Date(iso) : null;
  if (!d || Number.isNaN(d.getTime())) return '';
  return new Intl.DateTimeFormat('fr-FR', { day: '2-digit', month: '2-digit', year: 'numeric', hour: '2-digit', minute: '2-digit' }).format(d);
}

/** Local date « 22/10/2026 » of an ISO date or instant. */
export function localDay(iso) {
  if (!iso) return '';
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(String(iso));
  const d = m ? new Date(Number(m[1]), Number(m[2]) - 1, Number(m[3])) : new Date(iso);
  if (Number.isNaN(d.getTime())) return '';
  return new Intl.DateTimeFormat('fr-FR', { day: '2-digit', month: '2-digit', year: 'numeric' }).format(d);
}

/** Copies plain text and says so in a toast (done: the sentence shown once copied). */
export function copyWithToast(ctx, text, done) {
  copyText(text).then((ok) => ctx.toast(ok ? done : 'Copie impossible : le presse-papiers est indisponible.', { tone: ok ? 'ok' : 'warn', life: 2800 }));
}

// ---------- Object chosen from the Accueil (« Objet sélectionné », ACC-019; « Consulter », ACC-018) ----------

const OBJECT_KEY = 'domenia.selection.v1';

/**
 * Remembers the object last opened from the Accueil for this window (sessionStorage: name, DN and kind only, never a secret)
 * and tells the other screens (event « domenia:object-selected »). Storage may be unavailable: then only the event goes out.
 * @param {{ dn: string, name: string, kind: string }} object
 */
export function rememberObject(object) {
  if (!object?.dn) return;
  const value = { dn: String(object.dn).slice(0, 2048), name: String(object.name ?? '').slice(0, 256), kind: String(object.kind ?? 'objet').slice(0, 32), at: new Date().toISOString() };
  try {
    sessionStorage.setItem(OBJECT_KEY, JSON.stringify(value));
  } catch (err) {
    console.warn('Objet sélectionné non mémorisé (stockage de la fenêtre indisponible).', err?.name);
  }
  window.dispatchEvent(new CustomEvent('domenia:object-selected', { detail: value }));
}

/** Object last chosen in this window, or null (unreadable or absent storage). */
export function lastObject() {
  try {
    const v = JSON.parse(sessionStorage.getItem(OBJECT_KEY) ?? 'null');
    return v && typeof v.dn === 'string' && typeof v.name === 'string' ? v : null;
  } catch {
    return null;
  }
}
