// Breadcrumb of a distinguished name: domain › OU › sub-OU › object. Each intermediate OU opens that branch; the
// domain is text only (never a shortcut to the whole domain: Domenia 1, RCH-012). Long paths fold their middle.
import { glyph } from './glyphs.js';
import { openMenu } from './menu.js';
import { esc, uid, writeClipboard, announce } from './util.js';
import { copyButton, bindCopy } from './copy.js';

/**
 * @typedef {Object} DnPart
 * @property {string} type     Attribute type in upper case (CN, OU, DC, O, L…).
 * @property {string} value    Unescaped value.
 * @property {string} rdn      Raw relative name, as written in the DN.
 * @property {string} dn       DN from this part to the end (the part's own DN).
 */

/**
 * Splits a DN into its parts (RFC 4514 escapes: \, \+ \" \\ \< \> \; \= \# and \XX hex).
 * @param {string} dn
 * @returns {DnPart[]}
 */
export function parseDn(dn) {
  const text = String(dn ?? '').trim();
  if (!text) return [];
  const raws = [];
  let cur = '';
  for (let n = 0; n < text.length; n++) {
    const ch = text[n];
    if (ch === '\\' && n + 1 < text.length) { cur += ch + text[n + 1]; n += 1; continue; }
    if (ch === ',') { raws.push(cur.trim()); cur = ''; continue; }
    cur += ch;
  }
  raws.push(cur.trim());
  return raws.filter(Boolean).map((rdn, n) => {
    const eq = rdn.indexOf('=');
    const type = (eq > 0 ? rdn.slice(0, eq) : '').trim().toUpperCase();
    const value = unescapeValue(eq > 0 ? rdn.slice(eq + 1) : rdn);
    return { type, value, rdn, dn: raws.slice(n).join(',') };
  });
}

function unescapeValue(v) {
  const bytes = [];
  let out = '';
  const flush = () => {
    if (!bytes.length) return;
    try { out += new TextDecoder().decode(new Uint8Array(bytes)); } catch { out += '�'; }
    bytes.length = 0;
  };
  for (let n = 0; n < v.length; n++) {
    const ch = v[n];
    if (ch === '\\' && n + 2 < v.length + 1 && /^[0-9a-f]{2}$/i.test(v.slice(n + 1, n + 3))) {
      bytes.push(parseInt(v.slice(n + 1, n + 3), 16));
      n += 2;
      continue;
    }
    flush();
    if (ch === '\\' && n + 1 < v.length) { out += v[n + 1]; n += 1; continue; }
    out += ch;
  }
  flush();
  return out.trim();
}

/** DN of the parent container (empty for a domain root). */
export function dnParent(dn) {
  const parts = parseDn(dn);
  return parts.length > 1 ? parts[1].dn : '';
}

/** DNS name of the domain of a DN: « example.local ». */
export function dnDomain(dn) {
  return parseDn(dn).filter((p) => p.type === 'DC').map((p) => p.value).join('.');
}

/**
 * Creates a DN breadcrumb in host.
 * @param {HTMLElement} host
 * @param {{ dn: string, onNavigate?: (dn: string, part: DnPart) => void, copy?: boolean, maxVisible?: number, label?: string }} o
 */
export function createDnBreadcrumb(host, o) {
  const id = uid('crumb');
  let dn = o.dn;
  let hiddenParts = [];
  const unbindCopy = bindCopy(host);

  function render() {
    const parts = parseDn(dn);
    const domain = parts.filter((p) => p.type === 'DC').map((p) => p.value).join('.');
    const path = parts.filter((p) => p.type !== 'DC').reverse(); // top OU first
    const max = Math.max(3, o.maxVisible ?? 5);
    let shown = path;
    hiddenParts = [];
    if (path.length > max) {
      hiddenParts = path.slice(1, path.length - (max - 2));
      shown = [path[0], null, ...path.slice(path.length - (max - 2))];
    }
    const sep = `<span class="k-crumb-sep" aria-hidden="true">${glyph('chevronRight')}</span>`;
    const items = shown.map((p, n) => {
      if (p === null) {
        return `<li>${sep}<button class="k-crumb k-crumb-fold" type="button" aria-haspopup="menu" aria-expanded="false" aria-label="${hiddenParts.length} niveaux masqués" data-tip="Niveaux intermédiaires">…</button></li>`;
      }
      const last = n === shown.length - 1;
      const icon = p.type === 'OU' ? 'ou' : p.type === 'CN' && last ? 'object' : 'folder';
      if (last) return `<li>${sep}<span class="k-crumb current" aria-current="location" data-tip="${esc(p.dn)}">${glyph(icon)}${esc(p.value)}</span></li>`;
      const can = typeof o.onNavigate === 'function';
      return `<li>${sep}${can ? `<button class="k-crumb" type="button" data-dn="${esc(p.dn)}" data-tip="Ouvrir cette branche · ${esc(p.dn)}">${glyph(icon)}${esc(p.value)}</button>`
        : `<span class="k-crumb" data-tip="${esc(p.dn)}">${glyph(icon)}${esc(p.value)}</span>`}</li>`;
    }).join('');
    host.innerHTML = `<nav class="k-crumbs" aria-label="${esc(o.label ?? 'Emplacement dans l’annuaire')}" id="${id}">
      <ol><li><span class="k-crumb domain" data-tip="Domaine : le parcourir en entier n’est jamais proposé">${glyph('domain')}${esc(domain || '—')}</span></li>${items}</ol>
      ${o.copy === false ? '' : copyButton(dn, { label: 'Copier le chemin LDAP (DN)', done: 'Chemin copié' })}
    </nav>`;
  }

  host.addEventListener('click', (e) => {
    const t = e.target instanceof Element ? e.target : null;
    if (!t) return;
    const fold = t.closest('.k-crumb-fold');
    if (fold) {
      openMenu(fold, hiddenParts.map((p) => ({ label: p.value, icon: 'ou', hint: p.type, run: () => o.onNavigate?.(p.dn, p) })), { label: 'Niveaux intermédiaires' });
      return;
    }
    const b = t.closest('button[data-dn]');
    if (b) {
      const part = parseDn(dn).find((p) => p.dn === b.dataset.dn);
      o.onNavigate?.(b.dataset.dn, part);
    }
  });

  render();
  return {
    el: host,
    setDn(next) { dn = next; render(); },
    copy() { writeClipboard(dn).then((ok) => announce(ok ? 'Chemin copié.' : 'Copie impossible.')); },
    destroy() { unbindCopy(); host.replaceChildren(); },
  };
}
