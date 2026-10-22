// Rechercher · the bar: large field with suggestions (recent entries, then objects of the local base: never a directory
// request), perimeter chip (Partout / Dans « OU »), type selector, « commence par » or « contient », row limit, live
// analysis of the text and, after a search, the plan the engine applied with the LDAP filter it sends in directory mode.
// Once a list is shown the hero becomes a slim sticky bar: the analysis then shows as chips inside the field. Only Entrée
// or « Rechercher » interrogate the directory (Domenia 1 RCH-022 to RCH-039, RCH-066).
import { glyph } from '../../kit/glyphs.js';
import { openMenu } from '../../kit/menu.js';
import { highlight, debounce, readLayout, writeLayout } from '../../kit/util.js';
import { inkFollow, announce } from '../../ui.js';
import {
  esc, fold, quote, int, COLON, NBSP, TYPES, KINDS, analyse, barText, words, DEFAULT_LIMIT, MAX_LIMIT,
} from './text.js';

const SUGGEST_DELAY = 300;
const TYPED_DELAY = 650;
const MAX_TEXT = 256;
const PREF = 'rechercher.bar';

/**
 * @param {HTMLElement} host
 * @param {{ onSubmit: (s: object) => void, onSuggest: (text: string, type: string) => Promise<any[]>, getRecents: () => any[],
 *   onOpenObject: (dn: string, kind: string) => void, onClearRecents: () => void, onSyntaxHelp: () => void, onInput?: (text: string) => void }} o
 */
export function createBar(host, o) {
  const saved = readLayout(PREF) ?? {};
  const st = {
    scope: 'everywhere',
    type: TYPES.some((t) => t.id === saved.type) ? saved.type : 'all',
    match: 'prefix',
    typed: saved.typed === true,
    limit: DEFAULT_LIMIT,
    ou: null,
    items: [],
    active: -1,
    gen: 0,
    open: false,
    busy: false,
    compact: false,
  };
  host.innerHTML = `<form class="rch-bar" role="search" aria-label="Recherche dans l’annuaire" novalidate>
    <div class="rch-field">
      <span class="rch-field-ring" aria-hidden="true"></span>
      <span class="rch-field-ico" aria-hidden="true">${glyph('search')}</span>
      <input class="rch-input" type="text" maxlength="${MAX_TEXT}" autocomplete="off" spellcheck="false" role="combobox"
        aria-expanded="false" aria-controls="rch-sugg" aria-autocomplete="list" aria-describedby="rch-hint" aria-label="Rechercher un compte, un poste, un groupe, une OU, une adresse IP ou MAC">
      <span class="rch-inline" aria-hidden="true"></span>
      <button class="rch-clear" type="button" aria-label="Effacer la saisie" data-tip="Effacer la saisie" hidden>${glyph('x')}</button>
      <span class="rch-kbd" aria-hidden="true"><kbd>Entrée</kbd></span>
      <button class="btn primary rch-go" type="submit"><span class="rch-go-ico">${glyph('search')}</span><span class="rch-go-t">Rechercher</span></button>
      <div class="rch-sugg" id="rch-sugg" role="listbox" aria-label="Suggestions" hidden></div>
    </div>
    <div class="rch-opts">
      <div class="segmented rch-seg rch-scope" role="group" aria-label="Périmètre de la recherche"><span class="thumb" aria-hidden="true"></span>
        <button type="button" data-scope="everywhere" aria-pressed="true" data-tip="Tout le domaine">${glyph('domain')}<span>Partout</span></button>
        <button type="button" data-scope="ou" aria-pressed="false" disabled data-tip="Choisissez une OU dans l’arbre">${glyph('ou')}<span class="rch-scope-ou">Dans l’OU</span></button>
      </div>
      <div class="segmented rch-seg rch-types" role="group" aria-label="Type d’objet"><span class="thumb" aria-hidden="true"></span>
        ${TYPES.map((t) => `<button type="button" data-type="${t.id}" aria-pressed="${t.id === st.type}" aria-label="${esc(t.label)}" data-tip="${esc(t.label)}">${glyph(t.icon)}<span>${esc(t.label)}</span></button>`).join('')}
      </div>
      <div class="segmented rch-seg rch-match" role="group" aria-label="Correspondance des mots"><span class="thumb" aria-hidden="true"></span>
        <button type="button" data-match="prefix" aria-pressed="true" data-tip="Début des noms, comptes, courriels et noms DNS (indexé, rapide)">Commence par</button>
        <button type="button" data-match="contains" aria-pressed="false" data-tip="Noms qui contiennent les mots (plus lent : l’annuaire parcourt le périmètre)">Contient</button>
      </div>
      <label class="rch-limit" data-tip="Nombre de lignes lues au plus (1 à ${int(MAX_LIMIT)}) ; « Charger la suite » lit les suivantes">
        <span>Limite</span><input class="input mono" type="number" min="1" max="${MAX_LIMIT}" step="1" value="${DEFAULT_LIMIT}" inputmode="numeric" aria-label="Nombre de lignes lues au plus">
      </label>
      <button class="btn ghost icon sm rch-optmenu" type="button" aria-haspopup="menu" aria-expanded="false" aria-label="Options de la recherche" data-tip="Options de la recherche">${glyph('sliders')}</button>
    </div>
    <div class="rch-hint" id="rch-hint" aria-live="polite"></div>
  </form>`;

  const form = /** @type {HTMLFormElement} */ (host.querySelector('.rch-bar'));
  const field = form.querySelector('.rch-field');
  const input = /** @type {HTMLInputElement} */ (form.querySelector('.rch-input'));
  const inline = form.querySelector('.rch-inline');
  const clear = form.querySelector('.rch-clear');
  const go = form.querySelector('.rch-go');
  const list = form.querySelector('.rch-sugg');
  const hint = form.querySelector('.rch-hint');
  const limitInput = /** @type {HTMLInputElement} */ (form.querySelector('.rch-limit input'));
  const scopeSeg = form.querySelector('.rch-scope');
  const ouBtn = scopeSeg.querySelector('[data-scope="ou"]');
  const inks = [...form.querySelectorAll('.rch-seg')].map((seg) => inkFollow(seg, 'button', 'button[aria-pressed="true"]'));
  let engine = null;

  const persist = () => writeLayout(PREF, { type: st.type, typed: st.typed });

  function paintSegments() {
    form.querySelectorAll('[data-scope]').forEach((b) => b.setAttribute('aria-pressed', String(b.dataset.scope === st.scope)));
    form.querySelectorAll('[data-type]').forEach((b) => b.setAttribute('aria-pressed', String(b.dataset.type === st.type)));
    form.querySelectorAll('[data-match]').forEach((b) => b.setAttribute('aria-pressed', String(b.dataset.match === st.match)));
    inks.forEach((i) => i.update());
    input.placeholder = barText(st.scope === 'ou' ? 'ou' : 'everywhere', st.ou?.name, st.type).placeholder;
  }

  // ---------- Live analysis (no request) ----------

  function paintHint() {
    const value = input.value;
    clear.hidden = value.length === 0;
    const a = analyse(value, { match: st.match });
    field.classList.toggle('invalid', !a.valid && !a.empty);
    const plan = engine && engine.text === value.trim() ? engine : null;
    const chips = a.chips.map((c, n) => `<span class="chip rch-tok ${esc(c.tone)}" data-j="${n}">${c.icon ? glyph(c.icon) : ''}${esc(c.label)}</span>`).join('');
    const note = a.valid ? a.notes.join(' ') : a.reason;
    const filter = plan?.ldap ? `<details class="rch-ldap"><summary>${glyph('hash')}Filtre LDAP envoyé en mode annuaire</summary><code>${esc(plan.ldap)}</code></details>` : '';
    if (value.trim() || plan) {
      // After a search the line says what the engine did with the very text in the field (its plan), then its filter.
      const lead = plan ? `<span class="rch-hint-k">${glyph('check')}Plan appliqué</span>` : `<span class="rch-hint-lead">${glyph(a.valid ? 'info' : 'alert')}</span>`;
      hint.innerHTML = `${lead}${chips}<span class="rch-hint-text">${esc(plan?.hint || note)}</span>${filter}`;
    } else {
      hint.innerHTML = `<span class="rch-hint-lead">${glyph('sparkles')}</span><span class="rch-hint-text">Nom, compte, poste, groupe, GUID, SID, nom distinctif, adresse IP ou MAC. Syntaxe facultative${COLON}<code>utilisateur:</code> <code>poste:</code> <code>groupe:</code> <code>mail:</code>.</span>
        <button class="rch-hint-help" type="button" data-help>${glyph('info')}Aide sur la syntaxe</button>`;
    }
    hint.querySelectorAll('[data-j]').forEach((c) => c.style.setProperty('--j', c.dataset.j));
    // Slim bar: the same analysis as chips inside the field (two at most), the whole sentence on hover.
    const shown = a.valid ? a.chips.slice(0, 2) : value.trim() ? [{ label: a.reason.split(COLON)[0], tone: 'warn', icon: 'alert' }] : [];
    inline.innerHTML = shown.map((c) => `<span class="chip rch-tok ${esc(c.tone)}">${c.icon ? glyph(c.icon) : ''}${esc(c.label)}</span>`).join('')
      + (a.valid && a.chips.length > 2 ? `<span class="chip rch-tok off">+${int(a.chips.length - 2)}</span>` : '');
    inline.dataset.tip = value.trim() ? (plan?.hint || note) : '';
    return a;
  }

  // ---------- Suggestions ----------

  const kindIcon = (k) => (KINDS[k] ? KINDS[k].icon : 'search');

  function itemMarkup(item, n, needle) {
    const icon = item.source === 'recent' ? 'history' : kindIcon(item.objectKind);
    const label = needle ? highlight(item.label, needle) : esc(item.label);
    const action = item.objectKind ? `<kbd class="rch-sg-kbd" data-tip="Ouvrir la fiche (lecture explicite)">Ctrl Entrée</kbd>` : '';
    return `<div class="rch-sg" role="option" id="rch-sg-${n}" data-n="${n}" aria-selected="${n === st.active}" data-j="${Math.min(n, 9)}">`
      + `<span class="rch-sg-ico ${item.source}">${glyph(icon)}</span><span class="rch-sg-main"><span class="rch-sg-label">${label}</span>`
      + `<span class="rch-sg-detail">${esc(item.detail)}</span></span>${action}</div>`;
  }

  function paintList() {
    if (!st.items.length) { closeList(); return; }
    const needle = fold(input.value.trim());
    const recents = st.items.filter((i) => i.source === 'recent');
    const local = st.items.filter((i) => i.source !== 'recent');
    let n = 0;
    const group = (title, items) => (items.length ? `<div class="rch-sg-group" role="presentation">${esc(title)}</div>${items.map((i) => itemMarkup(i, n++, needle)).join('')}` : '');
    list.innerHTML = group('Récents sur ce poste', recents) + group('Base locale · aucune requête d’annuaire', local)
      + `<div class="rch-sg-foot" role="presentation"><span><kbd>↑</kbd><kbd>↓</kbd> choisir</span><span><kbd>Entrée</kbd> rechercher</span><span><kbd>Ctrl</kbd> <kbd>Entrée</kbd> ouvrir la fiche</span><span><kbd>Échap</kbd> fermer</span></div>`;
    list.querySelectorAll('[data-j]').forEach((c) => c.style.setProperty('--j', c.dataset.j));
    if (!st.open) {
      st.open = true;
      form.classList.add('sugg-open');
      list.hidden = false;
      list.classList.remove('in');
      void list.offsetWidth;
      list.classList.add('in');
    }
    input.setAttribute('aria-expanded', 'true');
    paintActive();
  }

  function paintActive() {
    list.querySelectorAll('.rch-sg').forEach((el) => el.setAttribute('aria-selected', String(Number(el.dataset.n) === st.active)));
    if (st.active >= 0) {
      input.setAttribute('aria-activedescendant', `rch-sg-${st.active}`);
      list.querySelector(`#rch-sg-${st.active}`)?.scrollIntoView({ block: 'nearest' });
    } else input.removeAttribute('aria-activedescendant');
  }

  function closeList() {
    st.open = false;
    form.classList.remove('sugg-open');
    st.active = -1;
    list.hidden = true;
    input.setAttribute('aria-expanded', 'false');
    input.removeAttribute('aria-activedescendant');
  }

  function recentItems(text) {
    const needle = fold(text.trim());
    return (o.getRecents() ?? [])
      .filter((r) => !needle || fold(r.text).includes(needle))
      .slice(0, 8)
      .map((r) => ({
        source: 'recent', kind: r.kind, text: r.text, label: r.text, objectKind: r.kind === 'object' ? (r.type ?? null) : null, dn: r.dn ?? null,
        detail: r.kind === 'object' ? `Fiche récente${r.type && KINDS[r.type] ? ` · ${KINDS[r.type].label}` : ''}` : 'Recherche récente',
      }));
  }

  const suggest = debounce(async () => {
    const text = input.value;
    const my = ++st.gen;
    const recents = recentItems(text);
    let local = [];
    if (fold(text.trim()).length >= 2) {
      try {
        const found = await o.onSuggest(text.trim(), st.type);
        if (my !== st.gen) return; // an older answer is ignored (generation, text)
        local = found.map((s) => ({ source: 'local', text: s.text, label: s.label, detail: s.detail, objectKind: s.kind, dn: s.dn }));
      } catch (err) {
        console.error(err);
      }
    }
    if (my !== st.gen || document.activeElement !== input) return;
    const seen = new Set();
    st.items = [...recents, ...local].filter((i) => { const k = fold(i.text); if (seen.has(k)) return false; seen.add(k); return true; }).slice(0, 8);
    st.active = -1;
    paintList();
  }, SUGGEST_DELAY);

  function pick(n, open) {
    const item = st.items[n];
    if (!item) return;
    if (open && item.dn && item.objectKind) { closeList(); o.onOpenObject(item.dn, item.objectKind); return; }
    input.value = item.text;
    closeList();
    paintHint();
    input.focus();
    announce(`${item.text} recopié dans le champ. Entrée lance la recherche.`);
  }

  // ---------- Submit (the only door to the directory) ----------

  function submit() {
    suggest.cancel();
    closeList();
    const a = paintHint();
    if (!a.valid) {
      field.classList.remove('shake');
      void field.offsetWidth;
      field.classList.add('shake');
      announce(a.reason, { assertive: true });
      return;
    }
    o.onSubmit(state());
  }

  const typedSearch = debounce(() => {
    if (!st.typed || document.activeElement !== input) return;
    // Guard of the search while typing (Domenia 1 Test-DomeniaTypedSearchAllowed): 3 significant characters, no leading wildcard.
    const v = input.value.trim();
    const significant = v.replace(/[\s*]/g, '').length;
    if (significant < 3 || words(v).some((w) => w.startsWith('*')) || !analyse(v, { match: st.match }).valid) return;
    o.onSubmit({ ...state(), typed: true });
  }, TYPED_DELAY);

  function readLimit() {
    const n = Number.parseInt(limitInput.value, 10);
    return Number.isFinite(n) ? Math.max(1, Math.min(MAX_LIMIT, n)) : DEFAULT_LIMIT;
  }

  function state() {
    return { text: input.value.trim(), scope: st.scope === 'ou' && st.ou ? st.ou.dn : null, scopeName: st.ou?.name ?? null, type: st.type, match: st.match, limit: (st.limit = readLimit()) };
  }

  // ---------- Events ----------

  form.addEventListener('submit', (e) => { e.preventDefault(); submit(); });
  input.addEventListener('input', () => {
    engine = null;
    paintHint();
    suggest();
    typedSearch();
    o.onInput?.(input.value.trim());
  });
  input.addEventListener('focus', () => { field.classList.add('focus'); });
  input.addEventListener('blur', () => {
    field.classList.remove('focus');
    setTimeout(() => { if (!form.contains(document.activeElement)) closeList(); }, 120);
  });
  input.addEventListener('click', () => { if (!st.open) { st.items = recentItems(input.value); if (input.value.trim().length >= 2) suggest(); else paintList(); } });
  input.addEventListener('keydown', (e) => {
    if (e.key === 'ArrowDown') {
      e.preventDefault();
      if (!st.open) { st.items = recentItems(input.value); suggest(); paintList(); return; }
      st.active = Math.min(st.items.length - 1, st.active + 1);
      paintActive();
    } else if (e.key === 'ArrowUp' && st.open) {
      e.preventDefault();
      st.active = Math.max(-1, st.active - 1);
      paintActive();
    } else if (e.key === 'Enter') {
      if (st.open && st.active >= 0) { e.preventDefault(); pick(st.active, e.ctrlKey || e.metaKey); }
    } else if (e.key === 'Escape') {
      if (st.open) { e.preventDefault(); e.stopPropagation(); closeList(); }
      else if (input.value) { e.preventDefault(); e.stopPropagation(); input.value = ''; engine = null; paintHint(); o.onInput?.(''); }
    } else if (e.key === 'Tab') closeList();
  });
  list.addEventListener('pointerdown', (e) => e.preventDefault());
  list.addEventListener('click', (e) => {
    const item = e.target instanceof Element ? e.target.closest('.rch-sg') : null;
    if (item) pick(Number(item.dataset.n), e.ctrlKey || e.metaKey || !!e.target.closest('.rch-sg-kbd'));
  });
  clear.addEventListener('click', () => { input.value = ''; engine = null; paintHint(); closeList(); input.focus(); o.onInput?.(''); });
  hint.addEventListener('click', (e) => { if (e.target instanceof Element && e.target.closest('[data-help]')) o.onSyntaxHelp(); });
  limitInput.addEventListener('change', () => {
    st.limit = readLimit();
    limitInput.value = String(st.limit);
    announce(`Limite de la liste${COLON}${int(st.limit)} lignes. Elle vaut pour la prochaine lecture.`);
  });
  form.querySelector('.rch-opts').addEventListener('click', (e) => {
    const b = e.target instanceof Element ? e.target.closest('button') : null;
    if (!b || b.disabled) return;
    if (b.dataset.scope) { st.scope = b.dataset.scope; paintSegments(); announce(b.dataset.scope === 'ou' ? `Périmètre${COLON}${st.ou?.name ?? 'OU'} et ses sous-OU.` : 'Périmètre : tout le domaine.'); }
    else if (b.dataset.type) { st.type = b.dataset.type; persist(); paintSegments(); }
    else if (b.dataset.match) { st.match = b.dataset.match; paintSegments(); paintHint(); }
    else if (b.classList.contains('rch-optmenu')) {
      openMenu(b, [
        { heading: 'Recherche' },
        { label: 'Rechercher pendant la saisie', checked: st.typed, keepOpen: true, run: (item) => { st.typed = item.checked; persist(); announce(st.typed ? 'Recherche à la frappe activée : 3 caractères significatifs au moins, jamais de joker en tête.' : 'Recherche à la frappe désactivée.'); } },
        { label: 'Aide sur la syntaxe', icon: 'info', run: () => o.onSyntaxHelp() },
        '-',
        { label: 'Effacer les recherches récentes', icon: 'trash', run: () => o.onClearRecents() },
      ], { label: 'Options de la recherche', placement: 'bottom-end' });
    }
  });

  paintSegments();
  paintHint();

  return {
    el: form,
    focus() { input.focus(); input.select(); },
    getState: state,
    setText(text) { input.value = String(text ?? '').slice(0, MAX_TEXT); engine = null; paintHint(); },
    setType(type) { if (TYPES.some((t) => t.id === type)) { st.type = type; paintSegments(); } },
    setMatch(match) { st.match = match === 'contains' ? 'contains' : 'prefix'; paintSegments(); paintHint(); },
    /** Row limit of the next reads (RCH-066), kept by the history and the views. */
    setLimit(n) { st.limit = Math.max(1, Math.min(MAX_LIMIT, Number(n) || DEFAULT_LIMIT)); limitInput.value = String(st.limit); },
    getLimit: () => st.limit,
    /** OU chosen in the tree: the chip « Dans « X » » becomes available (never the root nor another domain). */
    setOu(ou) {
      st.ou = ou && ou.dn ? ou : null;
      ouBtn.disabled = !st.ou;
      ouBtn.dataset.tip = st.ou ? `Chercher dans ${quote(st.ou.name)} et ses sous-OU` : 'Choisissez une OU dans l’arbre';
      ouBtn.querySelector('.rch-scope-ou').textContent = st.ou ? `Dans ${quote(st.ou.name)}` : 'Dans l’OU';
      if (!st.ou && st.scope === 'ou') st.scope = 'everywhere';
      paintSegments();
    },
    setScope(choice) { st.scope = choice === 'ou' && st.ou ? 'ou' : 'everywhere'; paintSegments(); },
    setBusy(on) {
      st.busy = !!on;
      field.classList.toggle('busy', st.busy);
      go.classList.toggle('busy', st.busy);
      input.setAttribute('aria-busy', String(st.busy));
    },
    /** Slim sticky bar once a list is shown: the analysis moves into the field. */
    setCompact(on) { st.compact = !!on; form.classList.toggle('compact', st.compact); requestAnimationFrame(() => inks.forEach((i) => i.update())); },
    /** Plan the engine applied for the text now in the field (hint and LDAP filter), or null. */
    setEnginePlan(plan, text) {
      engine = plan ? { hint: plan.hint || '', ldap: plan.ldapFilter || '', text: String(text ?? '').trim() } : null;
      paintHint();
    },
    refreshRecents() { if (st.open) { st.items = recentItems(input.value); paintList(); } },
    destroy() { suggest.cancel(); typedSearch.cancel(); inks.forEach((i) => i.stop()); host.replaceChildren(); },
  };
}

export { NBSP };
