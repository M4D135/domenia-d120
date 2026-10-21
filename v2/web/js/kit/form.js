// Form fields (text, number, date, list, multi-line, checkbox, switch, radio group) and validation with messages:
// errors block, warnings inform, successes confirm. Validation is local; nothing is ever submitted by the browser
// (CSP form-action 'none'): the page reads values() and calls the bridge itself. No field is meant for a secret.
import { glyph } from './glyphs.js';
import { esc, uid, focusables, announce, count, NBSP } from './util.js';

/**
 * @typedef {Object} FieldOptions
 * @property {string} name
 * @property {string} label
 * @property {'text'|'search'|'number'|'date'|'datetime'|'time'|'select'|'textarea'|'checkbox'|'switch'|'radio'} [type='text']
 * @property {any} [value]
 * @property {Array<{value: string, label: string, disabled?: boolean}>} [options]  select and radio.
 * @property {string} [hint]                 Help under the field.
 * @property {string} [placeholder]
 * @property {boolean} [required] @property {boolean} [disabled] @property {boolean} [readonly]
 * @property {number} [minLength] @property {number} [maxLength]
 * @property {number|string} [min] @property {number|string} [max] @property {number} [step]
 * @property {string} [pattern]              Regular expression (whole value).
 * @property {string} [patternMessage]       Message when the pattern does not match.
 * @property {boolean} [mono]                Monospace input (names, DN, filters).
 * @property {'full'|'half'|'third'} [width='full']  Width in a .k-form grid.
 * @property {string} [prefixIcon]
 */

const TYPE_MAP = { datetime: 'datetime-local' };

/**
 * Markup of one field. Use inside a <form class="k-form"> handled by createForm().
 * @param {FieldOptions} f
 * @returns {string}
 */
export function field(f) {
  const id = uid(`f-${f.name}`);
  const type = f.type ?? 'text';
  const hintId = `${id}-h`;
  const msgId = `${id}-m`;
  const described = `${f.hint ? `${hintId} ` : ''}${msgId}`;
  const common = `id="${id}" name="${esc(f.name)}" aria-describedby="${described}"${f.required ? ' required aria-required="true"' : ''}${f.disabled ? ' disabled' : ''}${f.readonly ? ' readonly' : ''}`;
  const hint = f.hint ? `<p class="k-hint" id="${hintId}">${esc(f.hint)}</p>` : '';
  const msg = `<p class="k-msg" id="${msgId}" hidden></p>`;
  const req = f.required ? '<span class="k-req" aria-hidden="true">*</span>' : '';
  const width = ` w-${f.width ?? 'full'}`;

  if (type === 'checkbox' || type === 'switch') {
    const sw = type === 'switch';
    return `<div class="k-field k-field-check${width}" data-name="${esc(f.name)}">
      <label class="k-check-row" for="${id}"><input type="checkbox" class="${sw ? 'switch' : 'k-checkbox'}"${sw ? ' role="switch"' : ''} ${common}${f.value ? ' checked' : ''}>
      <span class="k-check-text">${esc(f.label)}${req}</span></label>${hint}${msg}</div>`;
  }
  if (type === 'radio') {
    const opts = (f.options ?? []).map((o, n) => `<label class="k-radio-row"><input type="radio" class="k-radio" name="${esc(f.name)}" value="${esc(o.value)}" id="${id}-${n}"`
      + `${String(f.value) === String(o.value) ? ' checked' : ''}${o.disabled || f.disabled ? ' disabled' : ''}${n === 0 && f.required ? ' required' : ''}>`
      + `<span>${esc(o.label)}</span></label>`).join('');
    return `<fieldset class="k-field k-field-radio${width}" data-name="${esc(f.name)}" aria-describedby="${described}">
      <legend>${esc(f.label)}${req}</legend><div class="k-radio-group">${opts}</div>${hint}${msg}</fieldset>`;
  }
  let control;
  const ph = f.placeholder ? ` placeholder="${esc(f.placeholder)}"` : '';
  const mono = f.mono ? ' mono' : '';
  if (type === 'select') {
    const opts = (f.options ?? []).map((o) => `<option value="${esc(o.value)}"${String(f.value ?? '') === String(o.value) ? ' selected' : ''}${o.disabled ? ' disabled' : ''}>${esc(o.label)}</option>`).join('');
    control = `<span class="k-select"><select class="input${mono}" ${common}>${f.placeholder ? `<option value="">${esc(f.placeholder)}</option>` : ''}${opts}</select></span>`;
  } else if (type === 'textarea') {
    control = `<textarea class="input k-textarea${mono}" rows="4" ${common}${ph}${f.maxLength ? ` maxlength="${f.maxLength}"` : ''}${f.minLength ? ` minlength="${f.minLength}"` : ''}>${esc(f.value ?? '')}</textarea>`;
  } else {
    const t = TYPE_MAP[type] ?? type;
    const attrs = [
      f.maxLength ? `maxlength="${f.maxLength}"` : '', f.minLength ? `minlength="${f.minLength}"` : '',
      f.min !== undefined ? `min="${esc(f.min)}"` : '', f.max !== undefined ? `max="${esc(f.max)}"` : '',
      f.step !== undefined ? `step="${esc(f.step)}"` : '', f.pattern ? `pattern="${esc(f.pattern)}"` : '',
    ].filter(Boolean).join(' ');
    const input = `<input class="input${mono}" type="${t}" ${common}${ph} ${attrs} value="${esc(f.value ?? '')}" autocomplete="off" spellcheck="false">`;
    control = f.prefixIcon || type === 'search' ? `<span class="k-input-ico">${glyph(f.prefixIcon ?? 'search')}${input}</span>` : input;
  }
  return `<div class="k-field${width}" data-name="${esc(f.name)}"${f.patternMessage ? ` data-pattern-message="${esc(f.patternMessage)}"` : ''}>
    <label for="${id}">${esc(f.label)}${req}</label><div class="k-control">${control}<span class="k-field-state" aria-hidden="true">${glyph('check', 'ok')}${glyph('alert', 'bad')}</span></div>${hint}${msg}</div>`;
}

/**
 * @typedef {string | null | undefined | { error?: string, warn?: string, ok?: string }} RuleResult
 */

/**
 * Wires validation and submission on a form built with field().
 * Fields are checked when they lose the focus, then on each keystroke once they have shown an error.
 * @param {HTMLFormElement} form
 * @param {{ rules?: Object<string, (value: any, values: Object<string, any>) => RuleResult>, onSubmit?: (values: Object<string, any>) => void|Promise<void>, onChange?: (values: Object<string, any>) => void }} [o]
 */
export function createForm(form, o = {}) {
  const touched = new Set();
  form.noValidate = true;
  form.classList.add('k-form-live');

  const fieldEl = (name) => form.querySelector(`.k-field[data-name="${CSS.escape(name)}"]`);
  const names = () => [...form.querySelectorAll('.k-field[data-name]')].map((f) => f.dataset.name);

  function readValue(name) {
    const list = form.elements.namedItem(name);
    if (!list) return null;
    if (list instanceof RadioNodeList) return list.value || null;
    if (list instanceof HTMLInputElement) {
      if (list.type === 'checkbox') return list.checked;
      if (list.type === 'number') return list.value === '' ? null : Number(list.value);
      return list.value;
    }
    if (list instanceof HTMLSelectElement || list instanceof HTMLTextAreaElement) return list.value;
    return null;
  }

  function values() {
    return Object.fromEntries(names().map((n) => [n, readValue(n)]));
  }

  // Built-in checks from the attributes, in French.
  function builtIn(name) {
    const box = fieldEl(name);
    const ctl = form.elements.namedItem(name);
    const input = ctl instanceof RadioNodeList ? /** @type {HTMLInputElement} */ (ctl[0]) : /** @type {HTMLInputElement} */ (ctl);
    if (!input || !box) return null;
    const v = readValue(name);
    const empty = v === null || v === '' || v === false;
    if (input.required && empty) return input.type === 'checkbox' ? 'Cochez cette case pour continuer.' : 'Ce champ est obligatoire.';
    if (empty) return null;
    const min = input.getAttribute('minlength');
    const max = input.getAttribute('maxlength');
    if (typeof v === 'string' && min && v.length < Number(min)) return `Au moins ${count(Number(min), 'caractère', 'caractères')}.`;
    if (typeof v === 'string' && max && v.length > Number(max)) return `Au plus ${count(Number(max), 'caractère', 'caractères')}.`;
    if (input.type === 'number' && typeof v === 'number') {
      if (Number.isNaN(v)) return 'Saisissez un nombre.';
      if (input.min !== '' && v < Number(input.min)) return `Valeur minimale${NBSP}: ${input.min}.`;
      if (input.max !== '' && v > Number(input.max)) return `Valeur maximale${NBSP}: ${input.max}.`;
    }
    if ((input.type === 'date' || input.type === 'datetime-local') && typeof v === 'string') {
      if (input.validity?.badInput) return 'Date incomplète.';
      if (input.min && v < input.min) return 'Date trop ancienne.';
      if (input.max && v > input.max) return 'Date trop lointaine.';
    }
    const pattern = input.getAttribute('pattern');
    if (pattern && typeof v === 'string') {
      let re = null;
      try { re = new RegExp(`^(?:${pattern})$`, 'u'); } catch { re = null; }
      if (re && !re.test(v)) return box.dataset.patternMessage || 'Format non admis.';
    }
    return null;
  }

  /** Shows a message on a field: tone 'error' (blocking), 'warn', 'ok', or null to clear. */
  function setMessage(name, text, tone = 'error') {
    const box = fieldEl(name);
    if (!box) return;
    const msg = box.querySelector('.k-msg');
    const controls = box.querySelectorAll('input, select, textarea');
    box.classList.remove('is-error', 'is-warn', 'is-ok');
    if (!text) {
      msg.hidden = true;
      msg.textContent = '';
      controls.forEach((c) => c.removeAttribute('aria-invalid'));
      return;
    }
    box.classList.add(`is-${tone}`);
    msg.hidden = false;
    msg.className = `k-msg ${tone}`;
    msg.innerHTML = `${glyph(tone === 'ok' ? 'check' : tone === 'warn' ? 'info' : 'alert')}<span>${esc(text)}</span>`;
    controls.forEach((c) => { if (tone === 'error') c.setAttribute('aria-invalid', 'true'); else c.removeAttribute('aria-invalid'); });
  }

  function validateField(name, vals = values()) {
    const base = builtIn(name);
    if (base) { setMessage(name, base, 'error'); return false; }
    const rule = o.rules?.[name];
    const r = typeof rule === 'function' ? rule(vals[name], vals) : null;
    if (typeof r === 'string' && r) { setMessage(name, r, 'error'); return false; }
    if (r && typeof r === 'object') {
      if (r.error) { setMessage(name, r.error, 'error'); return false; }
      if (r.warn) { setMessage(name, r.warn, 'warn'); return true; }
      if (r.ok) { setMessage(name, r.ok, 'ok'); return true; }
    }
    setMessage(name, null);
    return true;
  }

  /** Validates every field; focuses the first error and announces the count. */
  function validate() {
    const vals = values();
    const bad = names().filter((n) => { touched.add(n); return !validateField(n, vals); });
    if (bad.length) {
      const first = fieldEl(bad[0]);
      const ctl = first ? focusables(first)[0] : null;
      ctl?.focus();
      announce(`${count(bad.length, 'champ à corriger', 'champs à corriger')}.`, { assertive: true });
    }
    return bad.length === 0;
  }

  const nameOf = (t) => (t instanceof Element ? t.closest('.k-field')?.dataset.name : undefined);
  const onBlur = (e) => {
    const name = nameOf(e.target);
    if (!name) return;
    if (e.relatedTarget instanceof Element && fieldEl(name)?.contains(e.relatedTarget)) return;
    touched.add(name);
    validateField(name);
  };
  const onInput = (e) => {
    const name = nameOf(e.target);
    if (name && touched.has(name)) validateField(name);
    o.onChange?.(values());
  };
  const onSubmit = async (e) => {
    e.preventDefault();
    if (!validate()) return;
    const submit = form.querySelector('[type="submit"]');
    try {
      submit?.classList.add('spinning');
      submit?.setAttribute('aria-busy', 'true');
      await o.onSubmit?.(values());
    } finally {
      submit?.classList.remove('spinning');
      submit?.removeAttribute('aria-busy');
    }
  };
  // Native reset (button type="reset" or reset()): values go back, messages and « touched » states go away.
  const onReset = () => {
    touched.clear();
    names().forEach((n) => setMessage(n, null));
  };
  form.addEventListener('reset', onReset);
  form.addEventListener('focusout', onBlur);
  form.addEventListener('input', onInput);
  form.addEventListener('change', onInput);
  form.addEventListener('submit', onSubmit);

  return {
    values,
    validate,
    validateField: (name) => validateField(name),
    setMessage,
    /** Resets the values to their initial state and clears every message. */
    reset() {
      form.reset();
    },
    setDisabled(on) {
      form.querySelectorAll('input, select, textarea, button').forEach((c) => { c.disabled = !!on; });
    },
    destroy() {
      form.removeEventListener('reset', onReset);
      form.removeEventListener('focusout', onBlur);
      form.removeEventListener('input', onInput);
      form.removeEventListener('change', onInput);
      form.removeEventListener('submit', onSubmit);
    },
  };
}
