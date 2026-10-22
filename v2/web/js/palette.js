// Command palette (Ctrl+K, Ctrl+P, the search field of the top bar; TRV-175 to TRV-177): screens, commands of the screen
// shown, the closed catalogue of Domenia 1, help topics and objects of the directory, keyboard first. Every typed word must
// appear (accents, case and apostrophes ignored); available commands come first, then the rank of the match and the order
// of the catalogue (40 at most). An unavailable command stays listed with its reason and the palette stays open. The
// palette never writes: a prepared write only brings its button forward (shell/commands.js). Objects are looked for only
// when the operator asks for it (Entrée on « Chercher dans l’annuaire »).
import { icon } from './icons.js';
import { esc, fold, announce, errorText } from './ui.js';
import { selectEntries, EFFECT_TEXTS } from './shell/commands.js';

const LIMIT_PER_GROUP = 12;
const LIMIT_TOTAL = 40;
const NBSP = ' ';

function highlight(text, query) {
  if (!query) return esc(text);
  const chars = [...String(text)];
  const folded = chars.map((c) => fold(c));
  const flat = folded.join('');
  const words = query.split(/\s+/).filter(Boolean);
  const marks = new Array(chars.length).fill(false);
  for (const w of words) {
    const at = flat.indexOf(w);
    if (at < 0) continue;
    let pos = 0;
    folded.forEach((f, n) => {
      if (pos + f.length > at && pos < at + w.length) marks[n] = true;
      pos += f.length;
    });
  }
  let out = '';
  let open = false;
  chars.forEach((c, n) => {
    if (marks[n] && !open) { out += '<mark>'; open = true; }
    if (!marks[n] && open) { out += '</mark>'; open = false; }
    out += esc(c);
  });
  return open ? `${out}</mark>` : out;
}

function template() {
  return `<div class="palette" role="dialog" aria-modal="true" aria-label="Palette de commandes">
    <div class="palette-input">${icon('command')}
      <input type="text" role="combobox" aria-expanded="true" aria-controls="palette-results" aria-autocomplete="list"
        aria-label="Rechercher un écran, une commande, une aide ou un objet de l’annuaire" autocomplete="off" spellcheck="false"
        placeholder="Aller à un écran, lancer une commande, chercher une aide ou un objet…">
      <kbd>Échap</kbd>
    </div>
    <div class="pal-body">
      <div class="results" id="palette-results" role="listbox" aria-label="Résultats"></div>
      <aside class="pal-detail" aria-live="polite"></aside>
    </div>
    <div class="foot" aria-hidden="true">
      <span><kbd>↑</kbd> <kbd>↓</kbd> naviguer</span><span><kbd>Entrée</kbd> ouvrir</span><span><kbd>Échap</kbd> fermer</span>
      <span class="pal-foot-right"><kbd>Maj</kbd> <kbd>?</kbd> raccourcis</span>
    </div>
  </div>`;
}

/**
 * @param {{ sources: () => { pages: object[], screen: object[], commands: object[], recents: string[] },
 *   help: (query: string) => Promise<object[]>, lookup?: (text: string) => Promise<object[]>, openSearch: (text: string) => void,
 *   onRun: (entry: object) => void, inertTarget?: HTMLElement }} o
 */
export function createPalette(o) {
  const backdrop = document.createElement('div');
  backdrop.className = 'palette-backdrop';
  backdrop.hidden = true;
  backdrop.innerHTML = template();
  document.body.appendChild(backdrop);

  const input = backdrop.querySelector('input');
  const results = backdrop.querySelector('.results');
  const detail = backdrop.querySelector('.pal-detail');
  let items = [];
  let selected = 0;
  let restoreFocus = null;
  let closing = false;
  let helpItems = [];
  let objectItems = null;
  let lookupState = '';
  let renderToken = 0;

  function groupsFor(raw) {
    const query = fold(raw.trim());
    const src = o.sources();
    const groups = [];
    if (!query) {
      const recents = src.recents
        .map((id) => [...src.screen, ...src.commands, ...src.pages].find((c) => c.id === id))
        .filter(Boolean).slice(0, 5);
      const places = src.pages.filter((p) => p.recentPlace);
      const all = [...recents, ...places.filter((p) => !recents.includes(p))].slice(0, 6);
      if (all.length) groups.push({ title: 'Récents', list: all });
      groups.push({ title: 'Aller à', list: src.pages.filter((p) => !p.recentPlace) });
      if (src.screen.length) groups.push({ title: 'Sur cet écran', list: src.screen });
      groups.push({ title: 'Commandes', list: selectEntries(src.commands, '', 200) });
      return groups;
    }
    const pages = selectEntries(src.pages, raw, LIMIT_PER_GROUP);
    const screen = selectEntries(src.screen, raw, LIMIT_PER_GROUP);
    const commands = selectEntries(src.commands, raw, Math.max(0, LIMIT_TOTAL - pages.length - screen.length));
    if (pages.length) groups.push({ title: 'Aller à', list: pages });
    if (screen.length) groups.push({ title: 'Sur cet écran', list: screen });
    if (commands.length) groups.push({ title: 'Commandes', list: commands });
    if (helpItems.length) groups.push({ title: 'Aide', list: helpItems });
    if (objectItems?.length) groups.push({ title: 'Objets trouvés', list: objectItems });
    const text = raw.trim();
    const search = [];
    if (o.lookup && text.length >= 2) {
      search.push({
        id: 'lookup', kind: 'lookup', label: lookupState === 'busy' ? `Recherche de « ${text} »…` : `Chercher « ${text} » dans l’annuaire`, icon: 'search',
        group: 'Annuaire', hint: 'Utilisateurs, postes, OU', effect: 'read', available: true, keepOpen: true,
        detailText: 'Lecture lancée par Entrée : utilisateurs, postes et OU dont le nom, le compte, le mail ou le nom DNS contient le texte (100 au plus).',
      });
    }
    search.push({
      id: 'open-search', kind: 'search', label: `Ouvrir Rechercher avec « ${text} »`, icon: 'search', group: 'Annuaire', hint: 'Écran Rechercher',
      effect: 'navigate', available: true, run: () => o.openSearch(text),
      detailText: 'Ouvre l’écran Rechercher avec ce texte ; la recherche part depuis cet écran.',
    });
    groups.push({ title: 'Annuaire', list: search });
    return groups;
  }

  function render(fresh = false) {
    const raw = input.value;
    const query = fold(raw.trim());
    const groups = groupsFor(raw);
    items = groups.flatMap((g) => g.list);
    selected = Math.min(selected, Math.max(0, items.length - 1));
    let n = 0;
    results.classList.toggle('fresh', fresh);
    results.innerHTML = groups.map((g, gi) => `<div class="pal-group" role="group" aria-labelledby="pal-g-${gi}">`
      + `<div class="group" role="presentation" id="pal-g-${gi}">${esc(g.title)}<span class="pal-count">${g.list.length}</span></div>`
      + g.list.map((c) => {
        const k = n++;
        const off = c.available === false;
        const mark = c.active ? `${icon('check', 'on-mark')}<span class="visually-hidden">, ${c.kind === 'page' ? 'écran affiché' : 'actif'}</span>` : '';
        const hint = off ? `<span class="hint pal-reason">${esc(c.reason ?? 'Indisponible')}</span>` : c.hint ? `<span class="hint">${esc(c.hint)}</span>` : '';
        const kbd = c.kbd ? `<kbd>${esc(c.kbd)}</kbd>` : '';
        const effect = c.effect === 'write' ? `<span class="pal-effect" data-effect="write" aria-hidden="true">${icon('lock')}</span>` : c.effect === 'read' && c.kind !== 'help' ? '<span class="pal-effect" data-effect="read" aria-hidden="true"></span>' : '';
        return `<div class="item${off ? ' unavailable' : ''}" role="option" id="pal-opt-${k}" data-n="${k}" data-j="${k}" aria-selected="${k === selected}"${off ? ' aria-disabled="true"' : ''}>`
          + `${icon(c.icon ?? 'chevronRight')}<span class="label">${highlight(c.label, query)}</span>${effect}${hint}${mark}${kbd}</div>`;
      }).join('') + '</div>').join('')
      || '<div class="none" role="presentation">Aucun résultat. Essayez un autre mot.</div>';
    results.querySelectorAll('[data-j]').forEach((el) => el.style.setProperty('--j', String(Math.min(Number(el.dataset.j), 20))));
    syncSelection();
  }

  function detailFor(c) {
    if (!c) { detail.innerHTML = '<p class="faint">Choisissez une entrée pour voir ce qu’elle fait.</p>'; return; }
    const effect = c.detailText ?? (c.kind === 'help' ? c.text : EFFECT_TEXTS[c.effect] ?? '');
    detail.innerHTML = `<div class="pal-detail-head">${icon(c.icon ?? 'chevronRight')}<div><h3>${esc(c.label)}</h3>${c.group ? `<p>${esc(c.group)}</p>` : ''}</div></div>
      ${effect ? `<p class="pal-detail-text">${esc(effect)}</p>` : ''}
      ${c.available === false ? `<p class="pal-detail-reason">${icon('lock')}<span>Indisponible${NBSP}: ${esc(c.reason ?? '')}</span></p>` : ''}
      ${c.kbd ? `<p class="pal-detail-kbd">Raccourci${NBSP}: ${c.kbd.split(' ').map((k) => `<kbd>${esc(k)}</kbd>`).join(' ')}</p>` : ''}
      ${c.path ? `<p class="pal-detail-path mono">${esc(c.path)}</p>` : ''}`;
  }

  const syncSelection = (scroll = true) => {
    results.querySelectorAll('.item').forEach((el) => el.setAttribute('aria-selected', String(Number(el.dataset.n) === selected)));
    const current = results.querySelector(`#pal-opt-${selected}`);
    if (current) {
      input.setAttribute('aria-activedescendant', current.id);
      if (scroll) current.scrollIntoView({ block: 'nearest' });
    } else {
      input.removeAttribute('aria-activedescendant');
    }
    detailFor(items[selected]);
  };

  const move = (delta) => {
    if (!items.length) return;
    selected = (selected + delta + items.length) % items.length;
    syncSelection();
  };

  async function lookup() {
    const text = input.value.trim();
    if (!o.lookup || text.length < 2 || lookupState === 'busy') return;
    lookupState = 'busy';
    render();
    try {
      const found = await o.lookup(text);
      objectItems = found;
      announce(found.length ? `${found.length} objet${found.length > 1 ? 's' : ''} trouvé${found.length > 1 ? 's' : ''}.` : 'Aucun objet ne correspond.');
      if (!found.length) objectItems = [{ id: 'none', kind: 'object', label: 'Aucun objet ne correspond', icon: 'info', available: false, reason: 'Essayez un autre texte.' }];
    } catch (err) {
      objectItems = [{ id: 'error', kind: 'object', label: 'Recherche impossible', icon: 'alert', available: false, reason: errorText(err) }];
    } finally {
      lookupState = '';
    }
    render();
    const first = items.findIndex((i) => i.kind === 'object');
    if (first >= 0) { selected = first; syncSelection(); }
  }

  const runSelected = (n = selected) => {
    const cmd = items[n];
    if (!cmd) return;
    if (cmd.kind === 'lookup') { lookup(); return; }
    if (cmd.available === false) {
      selected = n;
      syncSelection();
      announce(`Indisponible${NBSP}: ${cmd.reason ?? ''}`, { assertive: true });
      detail.classList.remove('shake');
      void detail.offsetWidth;
      detail.classList.add('shake');
      return;
    }
    close();
    // Let the closing animation start before heavy work (page render, theme swap).
    requestAnimationFrame(() => o.onRun(cmd));
  };

  function open(prefill = '') {
    if (!backdrop.hidden && !closing) { input.select(); return; }
    closing = false;
    backdrop.classList.remove('closing');
    restoreFocus = document.activeElement instanceof HTMLElement ? document.activeElement : null;
    input.value = prefill;
    selected = 0;
    helpItems = [];
    objectItems = null;
    backdrop.hidden = false;
    if (o.inertTarget) o.inertTarget.inert = true;
    render(true);
    input.focus();
    if (prefill) refreshHelp();
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
    if (o.inertTarget) o.inertTarget.inert = false;
    if (restoreFocus?.isConnected) restoreFocus.focus({ preventScroll: true });
  }

  let helpTimer = 0;
  function refreshHelp() {
    clearTimeout(helpTimer);
    const q = input.value.trim();
    const my = ++renderToken;
    if (q.length < 2) { helpItems = []; return; }
    helpTimer = setTimeout(() => {
      o.help(q).then((list) => {
        if (my !== renderToken) return;
        helpItems = list;
        render();
      }).catch(() => {});
    }, 180);
  }

  input.addEventListener('input', () => { selected = 0; objectItems = null; render(false); refreshHelp(); });
  backdrop.addEventListener('keydown', (e) => {
    if (e.key === 'ArrowDown') { e.preventDefault(); move(1); }
    else if (e.key === 'ArrowUp') { e.preventDefault(); move(-1); }
    else if (e.key === 'PageDown') { e.preventDefault(); move(8); }
    else if (e.key === 'PageUp') { e.preventDefault(); move(-8); }
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
    refresh: () => { if (!backdrop.hidden) render(); },
  };
}
