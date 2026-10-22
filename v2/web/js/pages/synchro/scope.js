// OU picker of the screen: the update scope of the base (Domenia 1 BtnIndexScopePick). The OU tree is read on opening (the
// gesture), branch by branch; the domain root only serves to navigate (never selectable: « jamais tout le domaine »). The
// choice stays in the address of the screen; nothing is written.
import { openDrawer, createTree } from '../../kit/index.js';
import { esc, glyph, count, NBSP, pill } from './common.js';

/** Counts of a branch, naming only what it holds. */
function hintOf(c) {
  const parts = [];
  if (c.computers > 0) parts.push(count(c.computers, 'poste', 'postes'));
  if (c.users > 0) parts.push(count(c.users, 'compte', 'comptes'));
  return parts.length ? parts.join(' · ') : 'ni poste ni compte';
}

const toNode = (o, root = false) => ({
  id: o.dn,
  label: o.name,
  icon: root ? 'domain' : 'ou',
  hint: o.counts ? hintOf(o.counts) : '',
  leaf: !root && !o.hasChildren,
  selectable: !root,
  data: o,
});

/** DNs of the OU chain of a DN, from the top OU down (the domain components are not part of it). */
function chainOf(dn) {
  const chain = [];
  let current = dn ?? '';
  while (current && /^ou=/i.test(current)) {
    chain.unshift(current);
    const cut = current.search(/(?<!\\),/);
    current = cut < 0 ? '' : current.slice(cut + 1);
  }
  return chain;
}

/**
 * Opens the picker; resolves the OU chosen ({ dn, name, path }) or null.
 * @param {{ call: Function }} ctx
 * @param {{ current: any, sim: boolean }} o
 */
export function openScopePicker(ctx, o = {}) {
  return new Promise((resolve) => {
    let chosen = null;
    let tree = null;
    let done = false;
    const finish = (value) => { if (!done) { done = true; resolve(value); } };
    const body = document.createElement('div');
    body.className = 'sy-picker';
    body.dataset.page = 'synchro';
    body.innerHTML = `<p class="sy-picker-intro">${glyph('info')}<span>Choisissez l’OU à mettre à jour${NBSP}: ses sous-OU sont incluses, les autres branches de la base sont conservées. Le domaine entier n’est jamais une OU de mise à jour.</span></p>
      <div class="sy-picker-tree"></div>
      <div class="sy-picker-pick" aria-live="polite"><span class="sy-picker-none">Aucune OU choisie.</span></div>`;
    const panel = openDrawer({
      title: 'Choisir l’OU de mise à jour',
      subtitle: o.current ? `Actuellement${NBSP}: ${o.current.label}` : 'Base autonome',
      icon: 'tree',
      key: 'synchro.scope',
      width: 520,
      minWidth: 380,
      body,
      actions: [
        { id: 'cancel', label: 'Annuler', run: (p) => p.close() },
        { id: 'apply', label: 'Choisir cette OU', icon: 'check', primary: true, run: (p) => { if (chosen) { finish(chosen); p.close(); } } },
      ],
      onClose: () => { tree?.destroy(); finish(null); },
    });
    if (panel.el) panel.el.dataset.page = 'synchro';
    panel.closed?.then(() => finish(null));
    const setApply = (on) => {
      const b = panel.foot?.querySelector('[data-id="apply"]');
      if (b) { b.disabled = !on; b.setAttribute('aria-disabled', String(!on)); }
    };
    setApply(false);
    const pick = body.querySelector('.sy-picker-pick');
    if (o.current && !o.current.isDomain) {
      pick.innerHTML = `<span class="sy-picker-ico">${glyph('ou')}</span><div><b>${esc(o.current.label)}</b><span>${esc(o.current.path ?? '')}</span><small>OU actuelle${NBSP}: choisissez-en une autre dans l’arbre.</small></div>${pill('info', 'Actuelle', { size: 'sm' })}`;
    }
    tree = createTree(body.querySelector('.sy-picker-tree'), {
      label: 'Unités d’organisation du domaine',
      height: 'fill',
      searchPlaceholder: 'Filtrer les branches déjà lues',
      roots: async () => {
        const r = await ctx.call('directory.ou.children', { dn: null });
        const root = toNode({ dn: r.parent.dn, name: r.parent.name, path: r.parent.path }, true);
        root.children = (r.children ?? []).map((c) => toNode(c));
        // The tree keeps these roots as soon as this promise settles (a microtask): a task scheduled now runs after it.
        setTimeout(() => openAt(root.id), 0);
        return [root];
      },
      load: async (node) => {
        const r = await ctx.call('directory.ou.children', { dn: node.id });
        return (r.children ?? []).map((c) => toNode(c));
      },
      onSelect: (node) => {
        const ou = node.data;
        chosen = { dn: ou.dn, name: ou.name, path: ou.path };
        const counts = ou.counts ? `${count(ou.counts.computers, 'poste', 'postes')}, ${count(ou.counts.users, 'compte', 'comptes')}, ${count(ou.counts.groups, 'groupe', 'groupes')}` : '';
        pick.innerHTML = `<span class="sy-picker-ico">${glyph('ou')}</span><div><b>${esc(ou.name)}</b><span>${esc(ou.path ?? '')}</span>${counts ? `<small>${esc(counts)} (sous-OU comprises)</small>` : ''}</div>`
          + (o.current && o.current.dn?.toLowerCase() === ou.dn.toLowerCase() ? pill('info', 'Actuelle', { size: 'sm' }) : '');
        setApply(true);
      },
      onActivate: (node) => {
        if (node.selectable === false) return;
        chosen = { dn: node.data.dn, name: node.data.name, path: node.data.path };
        finish(chosen);
        panel.close();
      },
    });
    // Once the first level is read, the current OU is shown open (its branches are read once, like any opening); without
    // one, the domain root is opened so the first level shows at once. A branch that cannot be read shows its own error.
    function openAt(rootId) {
      if (done || !tree) return;
      const chain = o.current && !o.current.isDomain ? chainOf(o.current.dn) : [];
      if (chain.length) tree.reveal([rootId, ...chain]).catch((err) => console.error(err));
      else tree.expand?.(rootId);
    }
  });
}
