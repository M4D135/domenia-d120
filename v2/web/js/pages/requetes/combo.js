// Field picker of the query builder (local component: the kit has no searchable combobox yet). A text box filters the
// informations by words (accent and case insensitive) over name, category, source, description and technical details
// (namespace, class, properties, LDAP attribute); the list is grouped by category, the informations used recently first,
// navigable with the keyboard (↑ ↓ Début Fin Entrée Échap), and announces the number of matches.
import { esc, glyph, sourcePill } from './shared.js';
import { fold, announce } from '../../ui.js';

let counter = 0;
const RECENT_KEY = 'domenia.requetes.champsRecents';

/** Informations chosen recently (a per-viewer convenience: lost without harm when the browser storage is unavailable). */
function readRecent() {
  try {
    const list = JSON.parse(localStorage.getItem(RECENT_KEY) ?? '[]');
    return Array.isArray(list) ? list.filter((x) => typeof x === 'string').slice(0, 6) : [];
  } catch {
    return [];
  }
}

function keepRecent(id) {
  try {
    localStorage.setItem(RECENT_KEY, JSON.stringify([id, ...readRecent().filter((x) => x !== id)].slice(0, 6)));
  } catch {
    // Storage refused (private window, policy): the suggestion simply does not come back.
  }
}

/**
 * @param {HTMLElement} host
 * @param {{ fields: any[], value?: string|null, label: string, placeholder?: string, onChange: (field: any) => void, onBrowse?: () => void, filter?: (f: any) => boolean }} o
 */
export function createFieldCombo(host, o) {
  const id = `rqcombo${++counter}`;
  let fields = o.fields ?? [];
  let value = o.value ?? null;
  let open = false;
  let active = -1;
  let shown = [];
  host.innerHTML = `<div class="rq-combo">
    <label class="rq-combo-box">${glyph('search')}
      <span class="visually-hidden">${esc(o.label)}</span>
      <input type="text" role="combobox" aria-expanded="false" aria-autocomplete="list" aria-controls="${id}-list" autocomplete="off" spellcheck="false"
        placeholder="${esc(o.placeholder ?? 'Chercher une information…')}" maxlength="120">
      <button type="button" class="rq-combo-toggle" tabindex="-1" aria-label="Ouvrir la liste">${glyph('chevronDown')}</button>
    </label>
    <div class="rq-combo-pop" hidden>
      <div class="rq-combo-list" role="listbox" id="${id}-list" aria-label="${esc(o.label)}"></div>
      <div class="rq-combo-foot"><span class="rq-combo-count" aria-live="polite"></span>${o.onBrowse ? `<button type="button" class="btn ghost xs rq-combo-browse">${glyph('database')}Parcourir le catalogue…</button>` : ''}</div>
    </div>
  </div>`;
  const root = host.firstElementChild;
  const input = root.querySelector('input');
  const pop = root.querySelector('.rq-combo-pop');
  const list = root.querySelector('.rq-combo-list');
  const countEl = root.querySelector('.rq-combo-count');

  const current = () => fields.find((f) => f.id === value) ?? null;
  const showValue = () => { input.value = current()?.name ?? ''; };

  function filtered(text) {
    const terms = fold(text).split(/\s+/).filter(Boolean);
    const pool = o.filter ? fields.filter(o.filter) : fields;
    if (!terms.length) return pool;
    return pool.filter((f) => {
      const hay = fold(`${f.name} ${f.category} ${f.sourceLabel ?? ''} ${f.description ?? ''} ${f.id} ${f.technical ?? ''} ${f.ldapAttribute ?? ''} ${f.probeId ?? ''} ${f.property ?? ''}`);
      return terms.every((t) => hay.includes(t));
    });
  }

  function render(text) {
    const list0 = filtered(text);
    // Without text, the informations used recently come first (then the whole catalog, by category).
    const recent = text.trim() ? [] : readRecent().map((id) => list0.find((f) => f.id === id)).filter(Boolean);
    shown = [...recent.map((f) => ({ ...f, recentGroup: true })), ...list0].slice(0, 450);
    let lastCategory = null;
    let html = '';
    shown.forEach((f, n) => {
      const group = f.recentGroup ? 'Récemment utilisées' : f.category;
      if (group !== lastCategory) {
        lastCategory = group;
        html += `<div class="rq-combo-group${f.recentGroup ? ' recent' : ''}" role="presentation">${esc(group)}</div>`;
      }
      html += `<div class="rq-combo-opt" role="option" id="${id}-o${n}" data-n="${n}" aria-selected="${f.id === value}">
        <span class="rq-combo-name">${esc(f.name)}</span><span class="rq-combo-meta">${sourcePill(f.source)}<span class="rq-combo-unit">${esc(f.typeLabel ?? '')}</span></span></div>`;
    });
    list.innerHTML = html || '<p class="rq-combo-none">Aucune information ne correspond : essayez un autre mot.</p>';
    countEl.textContent = `${list0.length} information${list0.length > 1 ? 's' : ''} sur ${fields.length}`;
    active = Math.max(0, shown.findIndex((f) => f.id === value));
    paintActive();
  }

  function paintActive() {
    list.querySelectorAll('.rq-combo-opt').forEach((el) => el.classList.toggle('active', Number(el.dataset.n) === active));
    const el = list.querySelector(`[data-n="${active}"]`);
    if (el) {
      input.setAttribute('aria-activedescendant', el.id);
      el.scrollIntoView({ block: 'nearest' });
    } else input.removeAttribute('aria-activedescendant');
  }

  function setOpen(on) {
    open = on;
    pop.hidden = !on;
    input.setAttribute('aria-expanded', String(on));
    root.classList.toggle('open', on);
    if (on) render(input.value === (current()?.name ?? '') ? '' : input.value);
  }

  function choose(n) {
    const f = shown[n];
    if (!f) return;
    value = f.id;
    keepRecent(f.id);
    setOpen(false);
    showValue();
    announce(`Information choisie : ${f.name}`);
    o.onChange(f);
  }

  input.addEventListener('focus', () => { input.select(); });
  input.addEventListener('input', () => { if (!open) setOpen(true); render(input.value); announce(countEl.textContent); });
  input.addEventListener('keydown', (e) => {
    if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
      e.preventDefault();
      if (!open) { setOpen(true); return; }
      active = Math.max(0, Math.min(shown.length - 1, active + (e.key === 'ArrowDown' ? 1 : -1)));
      paintActive();
    } else if (e.key === 'Home' && open) { e.preventDefault(); active = 0; paintActive(); } else if (e.key === 'End' && open) { e.preventDefault(); active = shown.length - 1; paintActive(); } else if (e.key === 'Enter') {
      if (open) { e.preventDefault(); choose(active); }
    } else if (e.key === 'Escape') {
      if (open) { e.preventDefault(); e.stopPropagation(); setOpen(false); showValue(); }
    }
  });
  input.addEventListener('blur', () => setTimeout(() => { if (!root.contains(document.activeElement)) { setOpen(false); showValue(); } }, 120));
  root.querySelector('.rq-combo-toggle').addEventListener('click', () => { setOpen(!open); input.focus(); });
  list.addEventListener('pointerdown', (e) => e.preventDefault());
  list.addEventListener('click', (e) => {
    const opt = e.target instanceof Element ? e.target.closest('.rq-combo-opt') : null;
    if (opt) choose(Number(opt.dataset.n));
  });
  root.querySelector('.rq-combo-browse')?.addEventListener('click', () => { setOpen(false); o.onBrowse?.(); });
  showValue();

  return {
    setFields(next, nextValue = value) { fields = next ?? []; value = nextValue; showValue(); if (open) render(input.value); },
    setValue(next) { value = next; showValue(); },
    value: () => value,
    focus() { input.focus(); },
    destroy() { host.replaceChildren(); },
  };
}
