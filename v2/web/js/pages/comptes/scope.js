// Comptes screen: « Périmètre des comptes » side panel. The OU tree is read branch by branch with directory.ou.children
// (a closed branch is never read), the search with directory.ou.search; « Appliquer » calls accounts.scope.set (local
// preferences, never the directory). The domain root itself is never selectable: the list of accounts is never read on
// the whole domain.
import { openDrawer, createTree, glyph, pill, debounce } from '../../kit/index.js';
import { esc, errorText, announce, formatNumber } from '../../ui.js';
import { plural, whenOpen } from './shared.js';

const SEARCH_LIMIT = 50;

/** OU ancestors of a DN from the top of the domain down to the DN itself (escaped commas kept), e.g. for tree.reveal. */
function ouPath(dn) {
  const parts = [];
  let cur = '';
  for (let n = 0; n < dn.length; n++) {
    const c = dn[n];
    if (c === '\\' && n + 1 < dn.length) { cur += c + dn[n + 1]; n++; continue; }
    if (c === ',') { parts.push(cur); cur = ''; continue; }
    cur += c;
  }
  parts.push(cur);
  const out = [];
  for (let n = 0; n < parts.length; n++) {
    if (!/^\s*OU=/i.test(parts[n])) break;
    out.unshift(parts.slice(n).join(','));
  }
  return out;
}

/** Tree node of an OU entry of the contract (OPERATIONS.md § 8). */
function nodeOf(ou) {
  const users = ou?.counts?.users;
  return {
    id: ou.dn,
    label: ou.name,
    icon: 'ou',
    hint: typeof users === 'number' ? (users ? plural(users, 'compte', 'comptes') : '') : '',
    leaf: !ou.hasChildren,
    data: ou,
  };
}

/**
 * Opens the panel. Resolves with the new scope (accounts.scope.set result), or null when nothing changed.
 * @param {{ call: Function }} ctx
 * @param {{ current: any }} o  current: the scope shown (dn, label, path, subtree, origin).
 * @returns {Promise<any|null>}
 */
export function openScopePicker(ctx, { current }) {
  return new Promise((resolve) => {
    let picked = null;
    let subtree = current?.subtree !== false;
    let applied = null;
    let tree = null;
    let token = 0;
    const body = document.createElement('div');
    body.className = 'cpt-scope-panel';
    body.dataset.page = 'comptes';
    body.innerHTML = `<p class="cpt-scope-lead">Choisissez l’OU dont les comptes sont listés. Ce choix vaut pour la section Comptes et reste mémorisé pour ce domaine ; les autres sections gardent l’OU de travail.</p>
      <label class="cpt-scope-search">${glyph('search')}<span class="visually-hidden">Rechercher une OU par son nom ou son chemin</span>
        <input type="search" maxlength="100" autocomplete="off" spellcheck="false" placeholder="Rechercher une OU (nom ou chemin)…"></label>
      <div class="cpt-scope-results" hidden><p class="cpt-scope-count" aria-live="polite"></p><ul class="cpt-scope-list" role="listbox" aria-label="OU trouvées"></ul></div>
      <div class="cpt-scope-tree"></div>
      <div class="cpt-scope-pick" aria-live="polite"><span class="cpt-scope-pick-k">Sélection</span><b class="cpt-scope-pick-name">Aucune OU choisie</b><span class="cpt-scope-pick-path"></span></div>
      <label class="cpt-scope-sub"><input class="switch" type="checkbox" role="switch" ${subtree ? 'checked' : ''}><span>Comprendre les sous-OU</span></label>
      <p class="cpt-scope-note">${glyph('shield')}La racine du domaine n’est jamais proposée : la liste des comptes n’est jamais lue sur tout le domaine.</p>`;
    const panel = openDrawer({
      title: 'Périmètre des comptes',
      subtitle: current ? `Actuel : ${current.label}` : 'Aucun périmètre',
      icon: 'ou',
      side: 'left',
      key: 'comptes.scope',
      width: 480,
      minWidth: 380,
      maxWidth: 760,
      body,
      actions: [
        { id: 'cancel', label: 'Annuler', run: (p) => p.close() },
        { id: 'apply', label: 'Appliquer', icon: 'check', primary: true, run: () => apply() },
      ],
      onClose: () => { tree?.destroy(); resolve(applied); },
    });

    const applyBtn = () => panel.foot?.querySelector('[data-id="apply"]');
    const isCurrent = (ou) => Boolean(ou && current && ou.dn === current.dn);
    const setPick = (ou) => {
      picked = ou;
      body.querySelector('.cpt-scope-pick-k').textContent = isCurrent(ou) ? 'Sélection · périmètre actuel' : 'Sélection';
      body.querySelector('.cpt-scope-pick-name').textContent = ou ? ou.name : 'Aucune OU choisie';
      body.querySelector('.cpt-scope-pick-path').textContent = ou ? ou.path : '';
      body.querySelector('.cpt-scope-pick').classList.toggle('on', Boolean(ou));
      const b = applyBtn();
      if (b) b.disabled = !ou;
    };

    async function apply() {
      if (!picked) return;
      // Same OU, same depth, already the choice of the section: nothing to write.
      if (isCurrent(picked) && current.origin === 'section' && current.subtree === subtree) { panel.close(); return; }
      const b = applyBtn();
      if (b) b.disabled = true;
      panel.setBusy(true);
      try {
        applied = await ctx.call('accounts.scope.set', { dn: picked.dn, subtree });
        announce(`Périmètre des comptes : ${applied.label}.`);
        panel.close();
      } catch (err) {
        console.error(err);
        panel.setBusy(false);
        if (b) b.disabled = false;
        ctx.toast(errorText(err, 'Périmètre non changé.'), { tone: 'alert' });
      }
    }

    // Wait for the panel to open (a modal drawer may be queued) before reading anything.
    const start = async () => {
      if (!(await whenOpen(panel))) return;
      setPick(current?.dn ? { dn: current.dn, name: current.label, path: current.path ?? '' } : null);
      body.querySelector('.cpt-scope-sub input').addEventListener('change', (e) => { subtree = e.target.checked; });
      tree = createTree(body.querySelector('.cpt-scope-tree'), {
        label: 'Unités d’organisation du domaine',
        search: false,
        height: 'fill',
        roots: async () => {
          const level = await ctx.call('directory.ou.children', { dn: null });
          // Once the first level is attached, open the branches down to the current scope (each read once, as a click would).
          if (current?.dn) setTimeout(() => { tree?.reveal(ouPath(current.dn)).catch((err) => console.error(err)); }, 0);
          return (level.children ?? []).map(nodeOf);
        },
        load: async (node) => {
          const level = await ctx.call('directory.ou.children', { dn: node.id });
          return (level.children ?? []).map(nodeOf);
        },
        onSelect: (node) => setPick(node.data),
        onActivate: (node) => { setPick(node.data); apply(); },
      });
      const input = body.querySelector('.cpt-scope-search input');
      const results = body.querySelector('.cpt-scope-results');
      const list = body.querySelector('.cpt-scope-list');
      const countEl = body.querySelector('.cpt-scope-count');
      const search = debounce(async () => {
        const text = input.value.trim();
        const my = ++token;
        if (!text) { results.hidden = true; body.querySelector('.cpt-scope-tree').hidden = false; return; }
        results.hidden = false;
        body.querySelector('.cpt-scope-tree').hidden = true;
        list.setAttribute('aria-busy', 'true');
        try {
          const found = await ctx.call('directory.ou.search', { text });
          if (my !== token) return;
          countEl.textContent = found.length ? `${plural(found.length, 'OU trouvée', 'OU trouvées')}${found.length >= SEARCH_LIMIT ? ' (affinez la recherche)' : ''}` : 'Aucune OU ne correspond.';
          list.innerHTML = found.map((ou, n) => `<li role="option" aria-selected="false" tabindex="0" data-n="${n}" class="cpt-scope-hit">
              ${glyph('ou')}<span class="cpt-scope-hit-main"><b>${esc(ou.name)}</b><span>${esc(ou.path)}</span></span>
              ${ou.counts?.users ? pill('info', `${formatNumber(ou.counts.users)}`, { icon: 'user', size: 'sm', tip: plural(ou.counts.users, 'compte utilisateur', 'comptes utilisateurs') }) : ''}</li>`).join('');
          const choose = (li) => {
            list.querySelectorAll('[aria-selected="true"]').forEach((x) => x.setAttribute('aria-selected', 'false'));
            li.setAttribute('aria-selected', 'true');
            setPick(found[Number(li.dataset.n)]);
          };
          list.onclick = (e) => { const li = e.target.closest('li'); if (li) choose(li); };
          list.ondblclick = (e) => { const li = e.target.closest('li'); if (li) { choose(li); apply(); } };
          list.onkeydown = (e) => {
            const li = e.target.closest('li');
            if (!li) return;
            if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); choose(li); if (e.key === 'Enter') apply(); }
            if (e.key === 'ArrowDown') { e.preventDefault(); li.nextElementSibling?.focus(); }
            if (e.key === 'ArrowUp') { e.preventDefault(); li.previousElementSibling?.focus(); }
          };
        } catch (err) {
          console.error(err);
          if (my === token) countEl.textContent = errorText(err, 'Recherche impossible.');
        } finally {
          if (my === token) list.removeAttribute('aria-busy');
        }
      }, 220);
      input.addEventListener('input', search);
    };
    start();
  });
}
