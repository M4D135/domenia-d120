// LDAP text editor of the workshop (local component): a plain textarea for typing, under it a highlighted copy of the same
// text (groups, attributes, operators, values, wildcards, escapes, matching rules) and the error mark at the position
// given by the engine. Its height follows the text (3 to 14 lines, no resize handle). The engine parses (RFC 4515); this
// only paints.
import { esc } from './shared.js';

let counter = 0;

/** Highlighted HTML of an LDAP text (exported for the tests of tests/web). */
export function paint(text, errorAt) {
  let html = '';
  let i = 0;
  let state = 'start';
  const mark = (s, cls) => (cls ? `<span class="${cls}">${esc(s)}</span>` : esc(s));
  while (i < text.length) {
    const c = text[i];
    const at = i + 1;
    let token;
    let cls = '';
    if (c === '(' || c === ')') {
      token = c;
      cls = 'l-par';
      state = c === '(' ? 'open' : 'start';
    } else if (state === 'open' && (c === '&' || c === '|' || c === '!')) {
      token = c;
      cls = 'l-op';
      state = 'start';
    } else if (state === 'open' && /[A-Za-z0-9;.:-]/.test(c)) {
      let j = i;
      while (j < text.length && /[A-Za-z0-9;.-]/.test(text[j])) j += 1;
      token = text.slice(i, Math.max(j, i + 1));
      cls = /^[0-9.]+$/.test(token) ? 'l-rule' : 'l-attr';
      state = 'attr';
    } else if (state === 'attr' && /[=<>~:]/.test(c)) {
      let j = i;
      while (j < text.length && /[=<>~:]/.test(text[j]) && j - i < 3) j += 1;
      const seq = text.slice(i, j);
      if (seq.startsWith(':') && seq.length === 1) {
        // Matching rule or :dn
        let k = j;
        while (k < text.length && /[A-Za-z0-9.]/.test(text[k])) k += 1;
        token = text.slice(i, k);
        cls = 'l-rule';
      } else {
        token = seq;
        cls = 'l-eq';
        state = 'value';
      }
    } else if (state === 'value' && c === '*') {
      token = c;
      cls = 'l-star';
    } else if (state === 'value' && c === '\\' && /^[0-9a-fA-F]{2}$/.test(text.slice(i + 1, i + 3))) {
      token = text.slice(i, i + 3);
      cls = 'l-esc';
    } else if (state === 'value') {
      let j = i;
      while (j < text.length && !'()*\\'.includes(text[j])) j += 1;
      token = text.slice(i, Math.max(j, i + 1));
      cls = 'l-val';
    } else {
      token = c;
    }
    if (errorAt && at <= errorAt && errorAt < at + token.length) {
      const k = errorAt - at;
      html += mark(token.slice(0, k), cls) + `<mark class="l-err">${esc(token[k] ?? ' ')}</mark>` + mark(token.slice(k + 1), cls);
    } else {
      html += mark(token, cls);
    }
    i += token.length;
  }
  if (errorAt && errorAt > text.length) html += '<mark class="l-err"> </mark>';
  return `${html}\n`;
}

/**
 * @param {HTMLElement} host
 * @param {{ label: string, onInput: (text: string) => void, placeholder?: string }} o
 */
export function createLdapEditor(host, o) {
  const id = `rqldap${++counter}`;
  host.innerHTML = `<div class="rq-ldap">
    <pre class="rq-ldap-hl" aria-hidden="true"></pre>
    <label class="visually-hidden" for="${id}">${esc(o.label)}</label>
    <textarea id="${id}" class="rq-ldap-input" spellcheck="false" autocomplete="off" autocapitalize="off" maxlength="8192" rows="3"
      placeholder="${esc(o.placeholder ?? '(&(objectCategory=computer)(operatingSystem=*Windows 11*))')}"></textarea>
  </div>`;
  const root = host.firstElementChild;
  const hl = root.querySelector('.rq-ldap-hl');
  const area = root.querySelector('textarea');
  let errorAt = 0;
  let typing = false;
  const repaint = () => {
    hl.innerHTML = paint(area.value, errorAt);
    // Height of the text: wrapped lines counted on the width of the field (about one character per 8 px).
    const perLine = Math.max(20, Math.floor((area.clientWidth || 480) / 8));
    const lines = area.value.split('\n').reduce((n, line) => n + Math.max(1, Math.ceil(line.length / perLine)), 0);
    root.style.setProperty('--rows', String(Math.max(3, Math.min(14, lines + 1))));
  };
  const sync = () => { hl.scrollTop = area.scrollTop; hl.scrollLeft = area.scrollLeft; };
  area.addEventListener('input', () => { typing = true; errorAt = 0; repaint(); o.onInput(area.value); });
  area.addEventListener('scroll', sync);
  area.addEventListener('blur', () => { typing = false; });
  area.addEventListener('keydown', (e) => {
    // Tab inserts two spaces inside the editor (Maj Tab still leaves it).
    if (e.key === 'Tab' && !e.shiftKey && !e.ctrlKey && !e.altKey && !area.readOnly) {
      e.preventDefault();
      const { selectionStart: s, selectionEnd: t } = area;
      area.setRangeText('  ', s, t, 'end');
      area.dispatchEvent(new Event('input'));
    }
  });
  repaint();
  return {
    el: root,
    text: () => area.value,
    typing: () => typing || document.activeElement === area,
    setText(text, { flash = false } = {}) {
      if (area.value === text) return;
      area.value = text;
      errorAt = 0;
      repaint();
      sync();
      if (flash) {
        root.classList.remove('flash');
        void root.offsetWidth;
        root.classList.add('flash');
      }
    },
    setError(position) { errorAt = Number(position) || 0; repaint(); root.classList.toggle('error', errorAt > 0); },
    clearError() { errorAt = 0; repaint(); root.classList.remove('error'); },
    setLocked(on) { area.readOnly = on; root.classList.toggle('locked', on); },
    focus() { area.focus(); },
  };
}
