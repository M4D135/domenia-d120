// Command palette (Ctrl+K, Ctrl+P, .search-trigger): pages, actions and directory search, keyboard first.
import { icon } from './icons.js';
import { esc, fold, toast } from './ui.js';

// Results kept per group while typing; with an empty query every command is listed (all the pages, all the actions).
const LIMIT_PER_GROUP = 12;

// Score a label against the query: substring first (word starts win), then loose subsequence.
function score(text, query) {
  if (!query) return 1;
  const t = fold(text);
  const idx = t.indexOf(query);
  if (idx >= 0) return 200 - idx + (idx === 0 || t[idx - 1] === ' ' ? 60 : 0);
  let from = 0; let gaps = 0;
  for (const ch of query.replace(/\s+/g, '')) {
    const at = t.indexOf(ch, from);
    if (at < 0) return 0;
    gaps += at - from;
    from = at + 1;
  }
  return Math.max(1, 80 - gaps);
}

// Highlights the first accent-insensitive occurrence of query in text (escaped output).
function highlight(text, query) {
  if (!query) return esc(text);
  const chars = [...text];
  const folded = chars.map((c) => fold(c));
  const flat = folded.join('');
  const at = flat.indexOf(query);
  if (at < 0) return esc(text);
  let pos = 0; let start = -1; let end = -1;
  folded.forEach((f, n) => {
    if (start < 0 && pos + f.length > at) start = n;
    if (end < 0 && pos + f.length >= at + query.length) end = n + 1;
    pos += f.length;
  });
  if (start < 0 || end < 0) return esc(text);
  return `${esc(chars.slice(0, start).join(''))}<mark>${esc(chars.slice(start, end).join(''))}</mark>${esc(chars.slice(end).join(''))}`;
}

function template() {
  return `<div class="palette" role="dialog" aria-modal="true" aria-label="Palette de commandes">
    <div class="palette-input">${icon('command')}
      <input type="text" role="combobox" aria-expanded="true" aria-controls="palette-results" aria-autocomplete="list"
        aria-label="Rechercher une page, une action ou un objet de l’annuaire" autocomplete="off" spellcheck="false"
        placeholder="Aller à une page, lancer une action, chercher dans l’annuaire…">
      <kbd>Échap</kbd>
    </div>
    <div class="results" id="palette-results" role="listbox" aria-label="Résultats"></div>
    <div class="foot" aria-hidden="true">
      <span><kbd>↑</kbd> <kbd>↓</kbd> naviguer</span><span><kbd>Entrée</kbd> ouvrir</span><span><kbd>Échap</kbd> fermer</span>
    </div>
  </div>`;
}

// getCommands() → { pages: [...], actions: [...] }, each { id, label, icon, hint?, keywords?, active?, run }.
export function createPalette({ getCommands, inertTarget }) {
  const backdrop = document.createElement('div');
  backdrop.className = 'palette-backdrop';
  backdrop.hidden = true;
  backdrop.innerHTML = template();
  document.body.appendChild(backdrop);

  const input = backdrop.querySelector('input');
  const results = backdrop.querySelector('.results');
  let items = [];
  let selected = 0;
  let restoreFocus = null;
  let closing = false;

  const collect = (query) => {
    const { pages, actions } = getCommands();
    const rank = (list) => list
      .map((c) => ({ c, s: Math.max(score(c.label, query), score(c.keywords ?? '', query) * 0.8) }))
      .filter((x) => x.s > 0)
      .sort((a, b) => (query ? b.s - a.s : 0))
      .slice(0, query ? LIMIT_PER_GROUP : undefined)
      .map((x) => x.c);
    const groups = [
      { title: 'Aller à', list: rank(pages), activeText: 'écran affiché' },
      { title: 'Actions', list: rank(actions), activeText: 'actif' },
    ];
    const raw = input.value.trim();
    if (raw) {
      groups.push({
        title: 'Rechercher dans l’annuaire',
        list: [{
          id: 'search', label: `Rechercher « ${raw} »`, icon: 'search', hint: 'Comptes, postes, groupes',
          run: () => toast('La recherche arrive dans une prochaine étape.', { tone: 'info' }),
        }],
      });
    }
    return groups.filter((g) => g.list.length);
  };

  const render = (fresh = false) => {
    const query = fold(input.value.trim());
    const groups = collect(query);
    items = groups.flatMap((g) => g.list);
    selected = Math.min(selected, Math.max(0, items.length - 1));
    let n = 0;
    results.classList.toggle('fresh', fresh);
    // Listbox children must be options or groups: each group is labelled by its (presentational) title.
    results.innerHTML = groups.map((g, gi) => `<div class="pal-group" role="group" aria-labelledby="pal-g-${gi}">`
      + `<div class="group" role="presentation" id="pal-g-${gi}">${esc(g.title)}</div>`
      + g.list.map((c) => {
        const k = n++;
        // The check icon is aria-hidden: the active state is also given as text.
        const mark = c.active ? `${icon('check', 'on-mark')}<span class="visually-hidden">, ${esc(g.activeText ?? 'actif')}</span>` : '';
        const hint = c.hint ? `<span class="hint">${esc(c.hint)}</span>` : '';
        const kbd = c.kbd ? `<kbd>${esc(c.kbd)}</kbd>` : '';
        return `<div class="item" role="option" id="pal-opt-${k}" data-n="${k}" data-j="${k}" aria-selected="${k === selected}">`
          + `${icon(c.icon ?? 'chevronRight')}<span class="label">${highlight(c.label, query)}</span>${hint}${mark}${kbd}</div>`;
      }).join('') + '</div>').join('')
      || '<div class="none" role="presentation">Aucun résultat. Essayez un autre mot.</div>';
    results.querySelectorAll('[data-j]').forEach((el) => el.style.setProperty('--j', el.dataset.j));
    syncSelection();
  };

  // scroll: false when the pointer picks the option (the list must not move under the pointer).
  const syncSelection = (scroll = true) => {
    results.querySelectorAll('.item').forEach((el) => {
      el.setAttribute('aria-selected', String(Number(el.dataset.n) === selected));
    });
    const current = results.querySelector(`#pal-opt-${selected}`);
    if (current) {
      input.setAttribute('aria-activedescendant', current.id);
      if (scroll) current.scrollIntoView({ block: 'nearest' });
    } else {
      input.removeAttribute('aria-activedescendant');
    }
  };

  const move = (delta) => {
    if (!items.length) return;
    selected = (selected + delta + items.length) % items.length;
    syncSelection();
  };

  const runSelected = (n = selected) => {
    const cmd = items[n];
    if (!cmd) return;
    close();
    // Let the closing animation start before heavy work (page render, theme swap).
    requestAnimationFrame(() => cmd.run());
  };

  function open() {
    if (!backdrop.hidden && !closing) { input.select(); return; }
    closing = false;
    backdrop.classList.remove('closing');
    restoreFocus = document.activeElement instanceof HTMLElement ? document.activeElement : null;
    input.value = '';
    selected = 0;
    backdrop.hidden = false;
    if (inertTarget) inertTarget.inert = true;
    render(true);
    input.focus();
  }

  function close() {
    if (backdrop.hidden || closing) return;
    closing = true;
    backdrop.classList.add('closing');
    const done = () => {
      if (!closing) return;
      closing = false;
      backdrop.hidden = true;
      backdrop.classList.remove('closing');
    };
    backdrop.addEventListener('animationend', (e) => { if (e.target === backdrop) done(); }, { once: true });
    setTimeout(done, 400);
    if (inertTarget) inertTarget.inert = false;
    if (restoreFocus?.isConnected) restoreFocus.focus({ preventScroll: true });
  }

  input.addEventListener('input', () => { selected = 0; render(false); });
  backdrop.addEventListener('keydown', (e) => {
    if (e.key === 'ArrowDown') { e.preventDefault(); move(1); }
    else if (e.key === 'ArrowUp') { e.preventDefault(); move(-1); }
    else if (e.key === 'Home' && e.ctrlKey) { e.preventDefault(); selected = 0; syncSelection(); }
    else if (e.key === 'End' && e.ctrlKey) { e.preventDefault(); selected = Math.max(0, items.length - 1); syncSelection(); }
    else if (e.key === 'Enter') { e.preventDefault(); runSelected(); }
    else if (e.key === 'Escape') { e.preventDefault(); e.stopPropagation(); close(); }
    else if (e.key === 'Tab') { e.preventDefault(); input.focus(); } // focus stays in the dialog
  });
  // Only a real pointer movement selects: a list scrolled by the keyboard under a still pointer does not.
  let lastPointer = '';
  results.addEventListener('pointermove', (e) => {
    const at = `${e.clientX},${e.clientY}`;
    if (at === lastPointer) return;
    lastPointer = at;
    const el = e.target instanceof Element ? e.target.closest('.item') : null;
    if (el && Number(el.dataset.n) !== selected) { selected = Number(el.dataset.n); syncSelection(false); }
  });
  results.addEventListener('click', (e) => {
    const el = e.target instanceof Element ? e.target.closest('.item') : null;
    if (el) runSelected(Number(el.dataset.n));
  });
  backdrop.addEventListener('pointerdown', (e) => { if (e.target === backdrop) close(); });
  document.addEventListener('focusin', (e) => {
    if (!backdrop.hidden && !closing && !backdrop.contains(e.target)) input.focus();
  });

  return {
    open,
    close,
    toggle: () => (backdrop.hidden || closing ? open() : close()),
    isOpen: () => !backdrop.hidden && !closing,
  };
}
