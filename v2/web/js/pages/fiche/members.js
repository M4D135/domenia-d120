// Members tab: members of a group (FIC-029, FIC-023, FIC-024, FIC-025) with add and remove, or the content of an OU or a
// container with the creation of an OU (FIC-020) and « Définir comme OU de travail ».
import { createGrid, openDrawer, glyph, pill, writeClipboard, int } from '../../kit/index.js';
import { esc, errorText, toast, applyVars } from '../../ui.js';
import { write } from './actions.js';
import { kindOf } from './common.js';

const TYPE_TONES = { user: 'info', computer: 'accent', group: 'ok', ou: 'warn', contact: 'off', container: 'off', unknown: 'off' };

/**
 * @param {HTMLElement} panel
 * @param {any} S
 */
export function mountMembers(panel, S) {
  let data = null;
  let grid = null;
  let token = 0;
  let typeFilter = '';
  const isGroup = () => S.sheet.identity.kind === 'group';
  const act = (id) => S.sheet.actions.find((a) => a.id === id);

  panel.innerHTML = `<div class="fi-members"><div class="fi-members-top"></div><div class="card fi-card fi-members-grid"></div></div>`;
  const top = /** @type {HTMLElement} */ (panel.querySelector('.fi-members-top'));
  const gridHost = /** @type {HTMLElement} */ (panel.querySelector('.fi-members-grid'));

  function topMarkup() {
    if (!data) return '<div class="fi-type-chips"><span class="skeleton fi-sk-line w55"></span></div>';
    const chips = data.counts.map((c, n) => `<button type="button" class="fi-type-chip${typeFilter === c.type ? ' on' : ''}" data-type="${esc(c.type)}" data-tone="${TYPE_TONES[c.type] ?? 'off'}" data-j="${n}" aria-pressed="${typeFilter === c.type}">
      ${glyph(kindOf(c.type).icon)}<b>${int(c.count)}</b><span>${esc(c.label)}</span></button>`).join('');
    return `<div class="fi-type-chips">${chips || '<span class="fi-faint">Aucun objet.</span>'}</div><p class="fi-note">${glyph('info')}${esc(data.label)}${isGroup() ? ' · Types résolus dans la base locale (jamais devinés d’après un nom).' : ' · Un seul niveau lu, jamais toute l’arborescence.'}</p>`;
  }

  function filtered() {
    return (data?.rows ?? []).filter((r) => !typeFilter || r.type === typeFilter);
  }

  function buildGrid() {
    grid?.destroy();
    grid = createGrid(gridHost, {
      key: `fiche.members.${isGroup() ? 'group' : 'branch'}`,
      label: isGroup() ? 'Membres directs du groupe' : 'Contenu de la branche',
      rowId: (r) => r.dn,
      selection: 'single',
      loading: true,
      // Sized on the count already read by the sheet: a short list does not leave an empty area, a long one scrolls.
      height: `${Math.max(240, Math.min(560, 64 + 40 * ((isGroup() ? S.sheet.counts.members : S.sheet.counts.children) ?? 12)))}px`,
      quickPlaceholder: 'Filtrer : nom, type, OU, DN…',
      columns: [
        { id: 'name', label: 'Nom', required: true, width: 260, html: (v, r) => `<span class="fi-gname"><span class="fi-type-ico" data-kind="${esc(r.type)}">${glyph(kindOf(r.type).icon)}</span>${esc(v)}${r.privileged ? `<span class="fi-priv" data-tip="Objet à privilèges">${glyph('shield')}</span>` : ''}</span>` },
        { id: 'typeLabel', label: 'Type', width: 270 },
        { id: 'detail', label: 'Détail', width: 320, get: (r) => r.detail ?? '' },
        { id: 'disabled', label: 'État', type: 'enum', width: 120, get: (r) => (r.type === 'user' || r.type === 'computer' ? (r.disabled ? 'off' : 'on') : ''), options: [{ value: 'on', label: 'Actif', tone: 'ok' }, { value: 'off', label: 'Désactivé', tone: 'off' }] },
        { id: 'ou', label: 'Emplacement', width: 260, hidden: !isGroup() },
        { id: 'dn', label: 'Chemin (DN)', mono: true, hidden: true, width: 420 },
      ],
      empty: { icon: isGroup() ? 'users' : 'folder', title: isGroup() ? 'Aucun membre direct' : 'Branche vide', text: isGroup() ? 'Les membres par le groupe principal n’apparaissent pas dans member.' : 'Aucun objet directement dans cette branche.' },
      onActivate: (r) => S.open(r.dn),
      contextMenu: ({ row }) => (row ? [
        { heading: row.name },
        { label: 'Ouvrir la fiche', icon: 'object', kbd: 'Entrée', run: () => S.open(row.dn) },
        { label: 'Rechercher cet objet', icon: 'search', run: () => S.ctx.navigate('rechercher', { q: row.name }) },
        { label: 'Copier le DN', icon: 'copy', run: () => writeClipboard(row.dn).then((ok) => toast(ok ? 'DN copié.' : 'Copie impossible.', { tone: ok ? 'ok' : 'warn', life: 2400 })) },
        ...(isGroup() ? ['-', { label: 'Retirer du groupe…', icon: 'minus', danger: true, disabled: !act('memberAdd')?.available, reason: act('memberAdd')?.reason ?? 'Écritures indisponibles.',
          run: () => S.act('removeFrom', { group: S.sheet.identity.dn, member: row.dn, groupName: S.sheet.identity.name }) }] : []),
      ] : []),
    });
    const add = act('memberAdd');
    const ou = act('createOu');
    const scope = act('setScope');
    grid.slot.innerHTML = `<div class="fi-grid-actions">
      ${add ? `<button class="btn sm fi-write" type="button" data-m="add"${add.available ? '' : ` aria-disabled="true" data-tip="${esc(add.reason ?? '')}"`}>${glyph('plus')}Ajouter un membre…</button>` : ''}
      ${ou ? `<button class="btn sm fi-write" type="button" data-m="ou"${ou.available ? '' : ` aria-disabled="true" data-tip="${esc(ou.reason ?? '')}"`}>${glyph('plus')}Créer une OU…</button>` : ''}
      ${scope ? `<button class="btn sm ghost" type="button" data-m="scope">${glyph('pin')}Définir comme OU de travail</button>` : ''}</div>`;
  }

  async function load() {
    const my = ++token;
    top.innerHTML = topMarkup();
    try {
      data = await S.ctx.call('fiche.members', { dn: S.sheet.identity.dn });
      if (my !== token || !S.alive) return;
      top.innerHTML = topMarkup();
      applyVars(top);
      grid.setRows(filtered(), { keepSelection: true });
    } catch (err) {
      if (my !== token) return;
      grid.setError(errorText(err), { retry: () => load() });
    }
  }

  buildGrid();
  load();

  const onClick = (e) => {
    const t = e.target instanceof Element ? e.target : null;
    const chip = t?.closest('[data-type]');
    if (chip) {
      typeFilter = typeFilter === chip.dataset.type ? '' : chip.dataset.type;
      top.innerHTML = topMarkup();
      applyVars(top);
      grid.setRows(filtered());
      return;
    }
    const b = t?.closest('[data-m]');
    if (!b) return;
    if (b.getAttribute('aria-disabled') === 'true') { toast(b.dataset.tip || 'Indisponible.', { tone: 'info' }); return; }
    if (b.dataset.m === 'add') S.act('memberAdd', { exclude: (data?.rows ?? []).map((r) => r.dn) });
    else if (b.dataset.m === 'ou') createOu(S);
    else if (b.dataset.m === 'scope') S.act('setScope');
  };
  panel.addEventListener('click', onClick);

  return {
    update() {},
    refresh() { buildGrid(); load(); },
    destroy() { panel.removeEventListener('click', onClick); grid?.destroy(); },
  };
}

/** Creation of an OU under the branch of the fiche (FIC-020): the parent really targeted is shown, the name is checked by the plan. */
export async function createOu(S) {
  const parent = S.sheet.identity;
  const body = document.createElement('div');
  body.dataset.page = 'fiche';
  body.className = 'fi-newou';
  body.innerHTML = `<div class="fi-newou-parent"><span class="k">Branche parente</span><b>${glyph('ou')}${esc(parent.name)}</b><span class="mono fi-break">${esc(parent.dn)}</span></div>
    <label class="fi-field-label" for="fi-newou-name">Nom de la nouvelle OU</label>
    <input id="fi-newou-name" class="input" type="text" maxlength="64" autocomplete="off" spellcheck="true" placeholder="Par exemple : Accueil">
    <p class="fi-picker-hint">${glyph('info')}De 1 à 64 caractères ; l’unicité est vérifiée par le plan, et le parent est revérifié avant l’envoi.</p>
    <p class="fi-newou-preview fi-faint" aria-live="polite"></p>`;
  let name = '';
  const ctl = openDrawer({
    title: 'Créer une unité d’organisation', subtitle: parent.path, icon: 'plus', key: 'fiche.newou', width: 520, body, focusFirst: true,
    actions: [{ id: 'cancel', label: 'Annuler', run: (p) => p.close() }, { id: 'go', label: 'Préparer la création', primary: true, run: (p) => { name = /** @type {HTMLInputElement} */ (body.querySelector('input')).value.trim(); if (name) p.close(); } }],
  });
  const preview = body.querySelector('.fi-newou-preview');
  const input = /** @type {HTMLInputElement} */ (body.querySelector('input'));
  input.addEventListener('keydown', (e) => {
    if (e.key !== 'Enter' || e.isComposing) return;
    e.preventDefault();
    name = input.value.trim();
    if (name) ctl.close();
  });
  input.addEventListener('input', (e) => {
    const v = /** @type {HTMLInputElement} */ (e.target).value.trim();
    preview.textContent = v ? `Nouvelle OU : ${parent.path} › ${parent.name} › ${v}` : '';
  });
  await ctl.closed;
  if (!name) return;
  await write(S.ctx, 'fiche.createOu.plan', { parent: parent.dn, name }, { subtitle: `Sous ${parent.name}`, onDone: () => S.reload({ quiet: true }) });
}

export { pill };
