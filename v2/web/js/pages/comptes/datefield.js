// Comptes screen: French date field (JJ/MM/AAAA) with its month calendar. The native date control follows the language of
// the browser engine, not the page: in the VM it showed 11/21/2026 next to a French sentence, a source of error on a write
// (critique of the expiration). This field always reads and writes the French day, keeps the value as « yyyy-MM-dd » (local
// day, the format of accounts.expiration.plan) and offers a calendar: Monday first, today and the chosen day marked, keyboard
// of the APG date picker (arrows, Pg↑ Pg↓, Début Fin, Entrée, Échap). Local component: nothing is read or sent.
import { glyph } from '../../kit/index.js';
import { esc, announce } from '../../ui.js';
import { frenchDay, parseFrenchDay, isoOfDate as isoOf, dateOfIso as dateOf } from './rules.js';

export { frenchDay, parseFrenchDay };

const MONTHS = ['janvier', 'février', 'mars', 'avril', 'mai', 'juin', 'juillet', 'août', 'septembre', 'octobre', 'novembre', 'décembre'];
const DAYS = [['L', 'lundi'], ['M', 'mardi'], ['M', 'mercredi'], ['J', 'jeudi'], ['V', 'vendredi'], ['S', 'samedi'], ['D', 'dimanche']];

/**
 * Creates the field in host (replaces its content).
 * @param {HTMLElement} host
 * @param {{ id: string, value?: string|null, describedBy?: string, onChange?: (iso: string|null) => void }} o
 * @returns {{ value: () => string|null, set: (iso: string|null) => void, disable: (on: boolean) => void, focus: () => void, destroy: () => void }}
 */
export function createDateField(host, { id, value = null, describedBy = '', onChange } = {}) {
  host.classList.add('cpt-date');
  host.innerHTML = `<input class="input mono cpt-date-input" id="${esc(id)}" type="text" inputmode="numeric" autocomplete="off" spellcheck="false"
      maxlength="10" placeholder="JJ/MM/AAAA" value="${esc(frenchDay(value))}"${describedBy ? ` aria-describedby="${esc(describedBy)}"` : ''}>
    <button class="btn ghost icon sm cpt-date-btn" type="button" aria-haspopup="dialog" aria-expanded="false" aria-label="Choisir dans le calendrier" data-tip="Calendrier">${glyph('calendar')}</button>
    <div class="cpt-cal" role="dialog" aria-modal="false" aria-label="Calendrier" hidden></div>`;
  const input = host.querySelector('input');
  const button = host.querySelector('.cpt-date-btn');
  const cal = host.querySelector('.cpt-cal');
  let current = dateOf(value) ? value : null;
  let view = dateOf(current) ?? new Date();
  let focusDay = dateOf(current) ?? new Date();
  let open = false;

  const emit = () => onChange?.(current);

  function paint() {
    const first = new Date(view.getFullYear(), view.getMonth(), 1);
    const offset = (first.getDay() + 6) % 7; // Monday first
    const start = new Date(first);
    start.setDate(1 - offset);
    const today = isoOf(new Date());
    const cells = [];
    for (let i = 0; i < 42; i++) {
      const d = new Date(start);
      d.setDate(start.getDate() + i);
      const iso = isoOf(d);
      const out = d.getMonth() !== view.getMonth();
      const label = `${DAYS[(d.getDay() + 6) % 7][1]} ${d.getDate()} ${MONTHS[d.getMonth()]} ${d.getFullYear()}`;
      cells.push(`<button type="button" role="gridcell" class="cpt-cal-day${out ? ' out' : ''}${iso === today ? ' today' : ''}${iso === current ? ' on' : ''}"
        data-iso="${iso}" tabindex="${iso === isoOf(focusDay) ? '0' : '-1'}" aria-selected="${iso === current}" aria-label="${esc(label)}">${d.getDate()}</button>`);
    }
    const rows = [];
    for (let r = 0; r < 6; r++) rows.push(`<div role="row" class="cpt-cal-row">${cells.slice(r * 7, r * 7 + 7).join('')}</div>`);
    cal.innerHTML = `<div class="cpt-cal-head"><button class="btn ghost icon xs" type="button" data-move="-1" aria-label="Mois précédent">${glyph('chevronLeft')}</button>
        <b aria-live="polite">${esc(MONTHS[view.getMonth()])} ${view.getFullYear()}</b>
        <button class="btn ghost icon xs" type="button" data-move="1" aria-label="Mois suivant">${glyph('chevronRight')}</button></div>
      <div role="grid" class="cpt-cal-grid" aria-label="${esc(`${MONTHS[view.getMonth()]} ${view.getFullYear()}`)}">
        <div role="row" class="cpt-cal-row head">${DAYS.map(([s, l]) => `<span role="columnheader" aria-label="${l}">${s}</span>`).join('')}</div>${rows.join('')}</div>
      <div class="cpt-cal-foot"><button class="btn xs subtle" type="button" data-today>Aujourd’hui</button></div>`;
  }

  function focusCurrent() {
    cal.querySelector(`[data-iso="${isoOf(focusDay)}"]`)?.focus({ preventScroll: true });
  }

  function show() {
    if (open || input.disabled) return;
    open = true;
    view = new Date((dateOf(current) ?? new Date()).getFullYear(), (dateOf(current) ?? new Date()).getMonth(), 1);
    focusDay = dateOf(current) ?? new Date();
    paint();
    cal.hidden = false;
    host.classList.add('open');
    button.setAttribute('aria-expanded', 'true');
    requestAnimationFrame(focusCurrent);
    document.addEventListener('pointerdown', outside, true);
  }

  function hide(refocus = false) {
    if (!open) return;
    open = false;
    cal.hidden = true;
    host.classList.remove('open');
    button.setAttribute('aria-expanded', 'false');
    document.removeEventListener('pointerdown', outside, true);
    if (refocus) button.focus({ preventScroll: true });
  }

  function outside(e) {
    if (!host.contains(e.target)) hide(false);
  }

  function choose(iso) {
    current = iso;
    input.value = frenchDay(iso);
    input.removeAttribute('aria-invalid');
    hide(true);
    announce(`Date choisie${' '}: ${frenchDay(iso)}.`);
    emit();
  }

  function moveFocus(days, months = 0) {
    const next = new Date(focusDay);
    if (months) next.setMonth(next.getMonth() + months); else next.setDate(next.getDate() + days);
    focusDay = next;
    if (next.getMonth() !== view.getMonth() || next.getFullYear() !== view.getFullYear()) {
      view = new Date(next.getFullYear(), next.getMonth(), 1);
    }
    paint();
    focusCurrent();
  }

  const onInput = () => {
    const iso = parseFrenchDay(input.value);
    if (iso === current) return;
    current = iso;
    emit();
  };
  const onBlur = () => {
    const iso = parseFrenchDay(input.value);
    if (iso) { input.value = frenchDay(iso); input.removeAttribute('aria-invalid'); } else if (input.value.trim()) input.setAttribute('aria-invalid', 'true');
  };
  const onFieldKey = (e) => {
    if ((e.key === 'ArrowDown' && e.altKey) || e.key === 'F4') { e.preventDefault(); show(); }
  };
  const onCalClick = (e) => {
    const t = e.target instanceof Element ? e.target.closest('button') : null;
    if (!t) return;
    if (t.dataset.iso) choose(t.dataset.iso);
    else if (t.dataset.move) {
      const dir = t.dataset.move;
      view = new Date(view.getFullYear(), view.getMonth() + Number(dir), 1);
      focusDay = new Date(view);
      paint();
      cal.querySelector(`[data-move="${dir}"]`)?.focus({ preventScroll: true });
    }
    else if (t.dataset.today !== undefined) choose(isoOf(new Date()));
  };
  const onCalKey = (e) => {
    const onDay = e.target instanceof Element && e.target.matches('[data-iso]');
    if (e.key === 'Escape') { e.preventDefault(); e.stopPropagation(); hide(true); return; }
    if (!onDay) return;
    const moves = { ArrowLeft: -1, ArrowRight: 1, ArrowUp: -7, ArrowDown: 7 };
    if (moves[e.key]) { e.preventDefault(); moveFocus(moves[e.key]); } else if (e.key === 'PageUp' || e.key === 'PageDown') {
      e.preventDefault();
      moveFocus(0, (e.key === 'PageUp' ? -1 : 1) * (e.shiftKey ? 12 : 1));
    } else if (e.key === 'Home' || e.key === 'End') {
      e.preventDefault();
      const dow = (focusDay.getDay() + 6) % 7;
      moveFocus(e.key === 'Home' ? -dow : 6 - dow);
    }
  };
  input.addEventListener('input', onInput);
  input.addEventListener('blur', onBlur);
  input.addEventListener('keydown', onFieldKey);
  button.addEventListener('click', () => (open ? hide(true) : show()));
  cal.addEventListener('click', onCalClick);
  cal.addEventListener('keydown', onCalKey);

  return {
    value: () => current,
    set: (iso) => {
      current = dateOf(iso) ? iso : null;
      input.value = frenchDay(current);
      input.removeAttribute('aria-invalid');
      emit();
    },
    disable: (on) => { input.disabled = !!on; button.disabled = !!on; if (on) hide(false); },
    focus: () => input.focus(),
    destroy: () => { hide(false); document.removeEventListener('pointerdown', outside, true); },
  };
}
