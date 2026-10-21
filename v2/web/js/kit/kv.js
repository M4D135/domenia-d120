// Collapsible key/value sheet (object card): sections with a header button, values with one-click copy, empty values
// said as such. The open or folded state of each section is remembered per key.
import { glyph } from './glyphs.js';
import { esc, uid, readLayout, writeLayout, int, quote } from './util.js';
import { copyButton, bindCopy } from './copy.js';

/**
 * @typedef {Object} KvItem
 * @property {string} label
 * @property {any} [value]                   Text (escaped). Empty → « — » and « non renseigné » for screen readers.
 * @property {string} [html]                 Trusted markup instead of value.
 * @property {string} [sub]                  Second line (detail, relative date).
 * @property {boolean} [mono]                Monospace (DN, GUID, SID).
 * @property {boolean|string} [copy]         Copy button (true: copies value; a string: copies that text).
 * @property {'ok'|'warn'|'alert'|'info'} [tone]  Colours the value.
 * @property {boolean} [wide]                Takes the whole row.
 * @property {string} [tip]
 */

/**
 * Markup of one collapsible section.
 * @param {{ id: string, title: string, icon?: string, items: KvItem[], open?: boolean, meta?: string }} s
 * @returns {string}
 */
export function kvSection(s) {
  const bodyId = uid(`kv-${s.id}`);
  const open = s.open !== false;
  const rows = s.items.map((it) => {
    const empty = it.html === undefined && (it.value === null || it.value === undefined || it.value === '');
    const val = it.html !== undefined ? it.html
      : empty ? '<span class="k-kv-none" aria-hidden="true">—</span><span class="visually-hidden">non renseigné</span>'
        : esc(typeof it.value === 'number' ? int(it.value) : it.value);
    const copyText = typeof it.copy === 'string' ? it.copy : (it.copy && !empty ? String(it.value) : '');
    return `<div class="k-kv-row${it.wide ? ' wide' : ''}${it.tone ? ` tone-${esc(it.tone)}` : ''}"${it.tip ? ` data-tip="${esc(it.tip)}"` : ''}>`
      + `<dt>${esc(it.label)}</dt><dd><span class="k-kv-val${it.mono ? ' mono' : ''}">${val}</span>`
      + `${copyText ? copyButton(copyText, { label: `Copier ${quote(it.label)}`, done: 'Copié' }) : ''}`
      + `${it.sub ? `<span class="k-kv-sub">${esc(it.sub)}</span>` : ''}</dd></div>`;
  }).join('');
  return `<section class="k-kv${open ? ' open' : ''}" data-kv="${esc(s.id)}">
    <h3 class="k-kv-head"><button type="button" class="k-kv-toggle" aria-expanded="${open}" aria-controls="${bodyId}">
      <span class="k-kv-chev" aria-hidden="true">${glyph('chevronRight')}</span>${s.icon ? `<span class="k-kv-ico">${glyph(s.icon)}</span>` : ''}
      <span class="k-kv-title">${esc(s.title)}</span><span class="k-kv-count">${s.meta ? esc(s.meta) : int(s.items.length)}</span></button></h3>
    <dl class="k-kv-body" id="${bodyId}"${open ? '' : ' hidden'}>${rows}</dl>
  </section>`;
}

/**
 * Makes the sections inside scope foldable (and their copy buttons work); remembers the state under key.
 * @param {HTMLElement} scope
 * @param {{ key?: string }} [o]
 * @returns {{ expandAll: () => void, collapseAll: () => void, destroy: () => void }}
 */
export function bindKv(scope, o = {}) {
  const storeKey = o.key ? `kv:${o.key}` : '';
  const saved = readLayout(storeKey);
  const state = saved?.v === 1 && saved.open && typeof saved.open === 'object' ? { ...saved.open } : {};
  const unbindCopy = bindCopy(scope);

  const setOpen = (section, open, animate = true) => {
    const btn = section.querySelector('.k-kv-toggle');
    const body = section.querySelector('.k-kv-body');
    btn.setAttribute('aria-expanded', String(open));
    section.classList.toggle('open', open);
    if (open) {
      body.hidden = false;
      if (animate) { body.classList.remove('k-kv-in'); void body.offsetWidth; body.classList.add('k-kv-in'); }
    } else {
      body.hidden = true;
    }
    state[section.dataset.kv] = open;
  };
  const save = () => { if (storeKey) writeLayout(storeKey, { v: 1, open: state }); };

  scope.querySelectorAll('.k-kv[data-kv]').forEach((section) => {
    const id = section.dataset.kv;
    if (typeof state[id] === 'boolean') setOpen(section, state[id], false);
  });

  const onClick = (e) => {
    const btn = e.target instanceof Element ? e.target.closest('.k-kv-toggle') : null;
    if (!btn || !scope.contains(btn)) return;
    const section = btn.closest('.k-kv');
    setOpen(section, btn.getAttribute('aria-expanded') !== 'true');
    save();
  };
  scope.addEventListener('click', onClick);
  const all = (open) => { scope.querySelectorAll('.k-kv[data-kv]').forEach((s) => setOpen(s, open)); save(); };
  return {
    expandAll: () => all(true),
    collapseAll: () => all(false),
    destroy: () => { scope.removeEventListener('click', onClick); unbindCopy(); },
  };
}
