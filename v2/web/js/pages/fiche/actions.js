// Pickers and write helpers of the « Fiche » screen: object picker (manager, group, member, second account), destination picker
// of a move (OUs and default containers, read level by level), and the write circuit (runWrite of write-flow.js: plan,
// confirmation, receipt). Nothing here writes by itself: every write is a plan the engine seals, then write.execute once
// (docs/WRITES.md).
import { openDrawer, createTree, glyph, debounce, NBSP } from '../../kit/index.js';
import { esc, errorText, announce } from '../../ui.js';
import { runWrite } from '../../write-flow.js';
import { kindOf } from './common.js';

const KIND_IDS = ['user', 'computer', 'group', 'ou', 'contact', 'container'];

/**
 * Object picker in a side panel: local search (fiche.pick, the local index only, nothing on the network), keyboard list.
 * @param {any} ctx
 * @param {{ title: string, subtitle?: string, kinds?: string[], placeholder?: string, exclude?: string[], hint?: string, initial?: string }} o
 * @returns {Promise<any|null>} The chosen object ({ dn, name, kind, detail… }) or null.
 */
export function pickObject(ctx, o) {
  return new Promise((resolve) => {
    let chosen = null;
    let token = 0;
    let results = [];
    let active = -1;
    const kinds = (o.kinds ?? KIND_IDS).filter((k) => KIND_IDS.includes(k));
    const body = document.createElement('div');
    body.className = 'fi-picker';
    body.dataset.page = 'fiche';
    body.innerHTML = `<label class="fi-picker-search">${glyph('search')}<span class="visually-hidden">${esc(o.placeholder ?? 'Rechercher')}</span>
        <input class="input" type="search" maxlength="100" autocomplete="off" spellcheck="false" placeholder="${esc(o.placeholder ?? 'Nom, identifiant ou UPN…')}" aria-controls="fi-picker-list"></label>
      <p class="fi-picker-hint">${glyph('database')}${esc(o.hint ?? 'Recherche dans la base locale seulement : aucune requête ne part sur le réseau.')}</p>
      <div class="fi-picker-list" id="fi-picker-list" role="listbox" aria-label="Résultats"></div>`;
    const input = /** @type {HTMLInputElement} */ (body.querySelector('input'));
    const list = /** @type {HTMLElement} */ (body.querySelector('.fi-picker-list'));
    const panel = openDrawer({
      title: o.title, subtitle: o.subtitle ?? 'Sélecteur d’objets', icon: 'search', key: 'fiche.picker', width: 520, minWidth: 380, maxWidth: 820,
      body, focusFirst: true,
      actions: [{ id: 'cancel', label: 'Annuler', run: (p) => p.close() }],
      onClose: () => resolve(chosen),
    });
    const excluded = new Set((o.exclude ?? []).map((d) => d.toLowerCase()));
    const paint = () => {
      if (input.value.trim().length < 2) {
        list.innerHTML = `<div class="fi-picker-empty">${glyph('search')}<span>Tapez au moins deux caractères.</span></div>`;
        return;
      }
      if (!results.length) {
        list.innerHTML = `<div class="fi-picker-empty">${glyph('info')}<span>Aucun objet ne correspond dans la base locale.</span></div>`;
        return;
      }
      list.innerHTML = results.map((r, n) => {
        const k = kindOf(r.kind);
        const off = excluded.has(String(r.dn).toLowerCase());
        return `<button type="button" class="fi-pick${n === active ? ' active' : ''}" role="option" aria-selected="${n === active}" data-n="${n}" data-j="${n}"${off ? ' aria-disabled="true" data-tip="Déjà présent"' : ''}>
          <span class="fi-pick-ico" data-kind="${esc(r.kind)}">${glyph(k.icon)}</span>
          <span class="fi-pick-body"><span class="fi-pick-name">${esc(r.name)}${r.sam ? `<span class="fi-pick-sam mono">${esc(r.sam)}</span>` : ''}</span>
          <span class="fi-pick-sub">${esc(r.detail ?? k.label)}</span></span>
          ${r.disabled ? '<span class="fi-pick-off">Désactivé</span>' : ''}</button>`;
      }).join('');
    };
    const search = debounce(async () => {
      const text = input.value.trim();
      const my = ++token;
      if (text.length < 2) { results = []; active = -1; paint(); return; }
      list.setAttribute('aria-busy', 'true');
      try {
        const found = await ctx.call('fiche.pick', { text, kinds });
        if (my !== token) return;
        results = Array.isArray(found) ? found : [];
        active = results.length ? 0 : -1;
        paint();
        announce(results.length ? `${results.length} résultat${results.length > 1 ? 's' : ''}` : 'Aucun résultat');
      } catch (err) {
        if (my !== token) return;
        list.innerHTML = `<div class="fi-picker-empty alert">${glyph('alert')}<span>${esc(errorText(err))}</span></div>`;
      } finally {
        if (my === token) list.removeAttribute('aria-busy');
      }
    }, 180);
    const choose = (n) => {
      const r = results[n];
      if (!r || excluded.has(String(r.dn).toLowerCase())) return;
      chosen = r;
      panel.close();
    };
    input.addEventListener('input', search);
    input.addEventListener('keydown', (e) => {
      if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
        if (!results.length) return;
        e.preventDefault();
        active = (active + (e.key === 'ArrowDown' ? 1 : -1) + results.length) % results.length;
        paint();
        list.querySelector('.fi-pick.active')?.scrollIntoView({ block: 'nearest' });
      } else if (e.key === 'Enter') {
        e.preventDefault();
        if (active >= 0) choose(active);
      }
    });
    list.addEventListener('click', (e) => {
      const b = e.target instanceof Element ? e.target.closest('.fi-pick') : null;
      if (b) choose(Number(b.dataset.n));
    });
    if (o.initial) { input.value = o.initial; search(); } else paint();
  });
}

// A destination of the move picker (fiche.destinations): an OU, or a default container such as CN=Users or CN=Computers.
const ouNode = (item) => ({
  id: item.dn,
  label: item.name,
  icon: item.kind === 'ou' ? 'ou' : 'folder',
  leaf: !item.hasChildren,
  hint: Number.isFinite(item.objects) ? `${item.objects}` : '',
  data: item,
});

/** DNs from the top OU down to <dn> (the domain components excluded): the path the tree reveals. */
export function ouPath(dn) {
  const parts = [];
  let rest = dn;
  while (rest && !/^DC=/i.test(rest)) {
    parts.unshift(rest);
    const cut = rest.search(/(?<!\\),/);
    if (cut < 0) break;
    rest = rest.slice(cut + 1);
  }
  return parts;
}

/**
 * Destination picker (FIC-018: opened on the current OU): OUs and default containers of the domain, read level by level
 * (fiche.destinations, one level per opening), a closed branch is never read, the domain itself is never selectable.
 * @param {any} ctx
 * @param {{ title: string, subtitle?: string, current?: string, confirm?: string, note?: string }} o
 * @returns {Promise<{ dn: string, name: string, path: string }|null>}
 */
export function pickOu(ctx, o) {
  return new Promise((resolve) => {
    let chosen = null;
    let selected = null;
    const body = document.createElement('div');
    body.className = 'fi-oupick';
    body.dataset.page = 'fiche';
    body.innerHTML = `${o.note ? `<p class="fi-picker-hint">${glyph('info')}${esc(o.note)}</p>` : ''}
      <div class="fi-oupick-tree"></div>
      <div class="fi-oupick-sel" aria-live="polite"><span class="k">Destination</span><b>Aucune destination choisie</b></div>`;
    const sel = /** @type {HTMLElement} */ (body.querySelector('.fi-oupick-sel b'));
    let tree = null;
    const panel = openDrawer({
      title: o.title, subtitle: o.subtitle ?? 'Choisir une OU', icon: 'ou', key: 'fiche.oupicker', width: 520, minWidth: 380, maxWidth: 860, body,
      actions: [
        { id: 'cancel', label: 'Annuler', run: (p) => p.close() },
        { id: 'ok', label: o.confirm ?? 'Choisir', primary: true, run: (p) => { if (!selected) return; chosen = selected; p.close(); } },
      ],
      onClose: () => { tree?.destroy(); resolve(chosen); },
    });
    const okButton = () => panel.foot?.querySelector('[data-id="ok"]');
    const sync = () => {
      const b = okButton();
      if (b) { b.disabled = !selected; }
      sel.textContent = selected ? selected.path : 'Aucune destination choisie';
    };
    tree = createTree(body.querySelector('.fi-oupick-tree'), {
      label: 'Unités d’organisation et conteneurs',
      height: '440px',
      roots: async () => {
        const r = await ctx.call('fiche.destinations', { dn: null });
        return (Array.isArray(r) ? r : []).map(ouNode);
      },
      load: async (node) => {
        const r = await ctx.call('fiche.destinations', { dn: node.id });
        return (Array.isArray(r) ? r : []).map(ouNode);
      },
      onSelect: (node) => {
        selected = { dn: node.id, name: node.label, path: node.data?.path ?? node.label };
        sync();
      },
      onActivate: (node) => {
        selected = { dn: node.id, name: node.label, path: node.data?.path ?? node.label };
        chosen = selected;
        panel.close();
      },
    });
    sync();
    if (o.current) {
      const path = ouPath(o.current);
      tree.reveal(path).catch((err) => console.error(err));
    }
  });
}

/**
 * Runs one write of the fiche through the circuit (plan, confirmation, receipt, re-read). Resolves with the receipt or null.
 * @param {any} ctx @param {string} plan @param {object} args @param {{ subtitle?: string, onDone?: (r: any) => void }} [o]
 */
export function write(ctx, plan, args, o = {}) {
  return runWrite(ctx, { plan, args, subtitle: o.subtitle, onDone: o.onDone });
}

/** Text of an amount with a non-breaking space (« 3 groupes »). */
export const countText = (n, one, many) => `${n}${NBSP}${n >= 2 ? many : one}`;
