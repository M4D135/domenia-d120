// Groups tab (« Groupes », « Membre de » for a group): direct groups (FIC-023), local filter (FIC-025), nested groups on
// demand (FIC-026, FIC-021), « Pourquoi membre ? » (FIC-027), context menus (FIC-028), add or remove one group (FIC-019),
// several groups as a delta with one plan per group, then each step checked again on the controller (FIC-022), and the
// comparison of two users (FIC-005, FIC-006, FIC-004).
import { createGrid, openDrawer, setVars, confirmDialog, glyph, pill, writeClipboard, debounce, startFreshness, NBSP, int } from '../../kit/index.js';
import { esc, errorText, toast, announce, applyVars } from '../../ui.js';
import { write } from './actions.js';
import { failure, skeleton, emptyNote, plural, freshChip, gridHeight } from './common.js';

/**
 * @param {HTMLElement} panel
 * @param {any} S
 */
export function mountGroups(panel, S) {
  let direct = null;
  let nested = null;
  let grid = null;
  let token = 0;

  panel.innerHTML = `<div class="fi-groups">
    <div class="fi-groups-top"></div>
    <div class="fi-groups-grid card fi-card"></div>
    <div class="fi-why-host"></div>
  </div>`;
  const top = /** @type {HTMLElement} */ (panel.querySelector('.fi-groups-top'));
  const gridHost = /** @type {HTMLElement} */ (panel.querySelector('.fi-groups-grid'));
  const whyHost = /** @type {HTMLElement} */ (panel.querySelector('.fi-why-host'));
  const isGroup = () => S.sheet.identity.kind === 'group';
  const act = (id) => S.sheet.actions.find((a) => a.id === id);

  function topMarkup() {
    const p = direct?.primary;
    const counts = direct
      ? `<span class="fi-count-chip">${glyph('group')}<b>${int(direct.total)}</b> ${direct.total > 1 ? 'directs' : 'direct'}</span>
         ${nested ? `<span class="fi-count-chip accent">${glyph('layers')}<b>${int(nested.nested)}</b> imbriqué${nested.nested > 1 ? 's' : ''} lu${nested.nested > 1 ? 's' : ''}</span>` : ''}
         ${direct.privileged ? `<span class="fi-count-chip alert">${glyph('shield')}<b>${int(direct.privileged)}</b> à privilèges</span>` : ''}`
      : '<span class="skeleton fi-sk-line w40"></span>';
    const primary = p ? `<div class="fi-primary-chip" data-tip="primaryGroupID : ce groupe n’apparaît pas dans memberOf.">${glyph('star')}<span>Groupe principal</span><b>${esc(p.label)}</b></div>` : '';
    return `<div class="fi-groups-head">
        <div class="fi-counts">${counts}</div>${primary}${freshChip(S.sheet, 'attributes')}
      </div>
      <p class="fi-note">${glyph('info')}${esc(direct?.label ?? 'Lecture des appartenances…')}${nested ? ` · ${esc(nested.summary)}` : ' · Les groupes imbriqués se lisent sur demande, jamais sur tout le domaine.'}</p>`;
  }

  // The head (counts, note, freshness chip) and the height of the grid follow every read: no empty band, no hidden row.
  function paintTop() {
    top.innerHTML = topMarkup();
    applyVars(top);
    startFreshness(top);
    if (grid?.el) setVars(grid.el, { '--k-grid-h': gridHeight(rows().length || S.sheet.counts.groups, { max: 560 }) });
  }

  function rows() {
    const list = [...(direct?.rows ?? [])];
    if (nested) list.push(...nested.rows);
    return list;
  }

  // « Via » and « Niveau » only mean something once the nested groups are read: before that they stay out of the grid (no
  // empty columns, no horizontal scroll), and each set of columns keeps its own layout memory. The location column also
  // carries the DN, so that the quick filter (which searches the visible columns) finds it, as Domenia 1 does
  // (Test-DomeniaMembershipRow).
  const layoutKey = () => `fiche.groups.${S.sheet.identity.kind}${nested ? '.nested' : ''}`;
  function columns() {
    return [
      { id: 'name', label: 'Groupe', required: true, width: nested ? 220 : 260, html: (v, r) => `<span class="fi-gname">${r.privileged ? `<span class="fi-priv" data-tip="Groupe à privilèges">${glyph('shield')}</span>` : glyph('group')}${esc(v)}</span>` },
      { id: 'type', label: 'Type', width: nested ? 168 : 196 },
      { id: 'membership', label: 'Appartenance', type: 'enum', width: 140, options: [
        { value: 'Directe', label: 'Directe', tone: 'ok' }, { value: 'Imbriquée', label: 'Imbriquée', tone: 'off' }] },
      ...(nested ? [
        { id: 'via', label: 'Via', width: 150, get: (r) => r.via ?? '' },
        { id: 'depth', label: 'Niveau', type: 'number', width: 88 },
      ] : []),
      { id: 'ou', label: 'Emplacement', width: nested ? 200 : 280, get: (r) => `${r.ou}\u2003${r.dn}`, html: (v, r) => `<span class="fi-path-cell" data-tip="${esc(r.dn)}">${esc(r.ou)}</span>`, csv: (v, r) => r.ou, sortKey: (v, r) => r.ou },
      { id: 'dn', label: 'Chemin (DN)', mono: true, hidden: true, width: 420 },
    ];
  }

  function buildGrid() {
    grid?.destroy();
    grid = createGrid(gridHost, {
      key: layoutKey(),
      label: isGroup() ? 'Groupes dont ce groupe est membre' : 'Groupes de l’objet',
      rowId: (r) => r.dn,
      selection: 'single',
      loading: true,
      height: gridHeight(S.sheet.counts.groups, { max: 520 }),
      quickPlaceholder: `Filtrer${NBSP}: nom, type, appartenance, OU, DN…`,
      columns: columns(),
      empty: { icon: 'group', title: isGroup() ? 'Membre d’aucun groupe' : 'Aucun groupe direct', text: 'Le groupe principal (primaryGroupID) n’apparaît pas dans memberOf : il est affiché au-dessus.' },
      onActivate: (r) => S.open(r.dn),
      contextMenu: ({ row }) => menuFor(row),
    });
    const slot = grid.slot;
    slot.innerHTML = `<div class="fi-grid-actions">
      <button class="btn sm fi-net" type="button" data-g="nested">${glyph('layers')}Groupes imbriqués</button>
      ${act('groupAdd') ? `<button class="btn sm fi-write" type="button" data-g="add"${act('groupAdd').available ? '' : ` aria-disabled="true" data-tip="${esc(act('groupAdd').reason ?? '')}"`}>${glyph('plus')}Ajouter à un groupe…</button>
        <button class="btn sm fi-write" type="button" data-g="delta"${act('groupAdd').available ? '' : ` aria-disabled="true" data-tip="${esc(act('groupAdd').reason ?? '')}"`}>${glyph('sliders')}Plusieurs groupes…</button>` : ''}
      ${S.sheet.identity.kind === 'user' ? `<button class="btn sm ghost fi-net" type="button" data-g="compare">${glyph('split')}Comparer les droits…</button>` : ''}</div>`;
  }

  function menuFor(row) {
    if (!row) return [];
    const canRemove = row.membership === 'Directe' && (act('groupAdd')?.available || (isGroup() && act('edit')?.available));
    return [
      { heading: row.name },
      { label: 'Ouvrir la fiche', icon: 'object', kbd: 'Entrée', run: () => S.open(row.dn) },
      { label: 'Rechercher cet objet', icon: 'search', run: () => S.ctx.navigate('rechercher', { q: row.name }) },
      { label: 'Copier le DN', icon: 'copy', run: () => writeClipboard(row.dn).then((ok) => toast(ok ? 'DN copié.' : 'Copie impossible.', { tone: ok ? 'ok' : 'warn', life: 2400 })) },
      '-',
      { label: 'Pourquoi membre ?', icon: 'info', run: () => why(row) },
      { label: 'Afficher les groupes imbriqués', icon: 'layers', disabled: !!nested, reason: 'Déjà lus.', run: () => readNested() },
      '-',
      { label: 'Retirer du groupe…', icon: 'minus', danger: true, disabled: !canRemove, reason: row.membership !== 'Directe' ? 'Appartenance imbriquée : retirez-la dans le groupe direct « via ».' : 'Écritures indisponibles.',
        run: () => S.act('removeFrom', { group: row.dn, groupName: row.name }) },
    ];
  }

  async function load() {
    const my = ++token;
    paintTop();
    try {
      direct = await S.ctx.call('fiche.groups', { dn: S.sheet.identity.dn });
      if (my !== token || !S.alive) return;
      paintTop();
      grid.setRows(rows(), { keepSelection: true });
      applyVars(top);
      startFreshness(top);
    } catch (err) {
      if (my !== token) return;
      grid.setError(errorText(err), { retry: () => load() });
    }
  }

  async function readNested() {
    const b = /** @type {HTMLButtonElement|null} */ (panel.querySelector('[data-g="nested"]'));
    b?.setAttribute('aria-busy', 'true');
    try {
      nested = await S.ctx.call('fiche.groups.nested', { dn: S.sheet.identity.dn });
      if (!S.alive) return;
      paintTop();
      grid.setColumns(columns(), { key: layoutKey() });
      grid.setRows(rows(), { keepSelection: true, keepScroll: true });
      announce(nested.summary);
      if (b) { b.disabled = true; b.innerHTML = `${glyph('check')}Imbriqués lus`; }
    } catch (err) {
      toast(`Groupes imbriqués non lus : ${errorText(err)}`, { tone: 'warn' });
    } finally {
      b?.removeAttribute('aria-busy');
    }
  }

  async function why(row) {
    whyHost.innerHTML = `<section class="card fi-card fi-why fi-enter">${skeleton(3)}</section>`;
    whyHost.scrollIntoView({ block: 'nearest', behavior: 'smooth' });
    try {
      const r = await S.ctx.call('fiche.groups.why', { dn: S.sheet.identity.dn, group: row.dn });
      const tone = r.member === true ? 'ok' : r.member === false ? 'off' : 'warn';
      const chain = r.path.length ? `<ol class="fi-chain">${r.path.map((p, n) => `<li data-j="${n}"><span class="fi-chain-node${n === 0 ? ' start' : n === r.path.length - 1 ? ' end' : ''}">${glyph(n === 0 ? 'user' : 'group')}${esc(p)}</span></li>`).join('')}</ol>` : '';
      whyHost.innerHTML = `<section class="card fi-card fi-why fi-enter"><div class="card-head"><span class="card-icon" data-tone="${tone}">${glyph('info')}</span>
          <div class="fi-card-titles"><h3>Pourquoi membre de ${esc(r.group)} ?</h3><p class="fi-card-sub">${r.known ? 'Réponse établie' : 'Réponse incomplète'}</p></div>
          <span class="meta">${pill(tone, r.member === true ? 'Membre' : r.member === false ? 'Non membre' : 'Indéterminé', { size: 'sm' })}
          <button class="btn ghost icon xs" type="button" data-g="closeWhy" aria-label="Fermer l’explication">${glyph('x')}</button></span></div>
        ${chain}<p class="fi-why-text">${esc(r.text)}</p>
        ${r.needsRead ? `<button class="btn sm fi-net" type="button" data-g="nested">${glyph('layers')}Lire les groupes imbriqués</button>` : ''}</section>`;
      applyVars(whyHost);
    } catch (err) {
      whyHost.innerHTML = `<section class="card fi-card">${failure(err, { title: 'Explication impossible', retry: false })}</section>`;
    }
  }

  async function delta() {
    const current = (direct?.rows ?? []).filter((r) => r.membership === 'Directe');
    const body = document.createElement('div');
    body.dataset.page = 'fiche';
    body.className = 'fi-delta';
    const adds = new Map();
    body.innerHTML = `<p class="fi-picker-hint">${glyph('info')}Seuls les ajouts et retraits choisis partent, jamais la liste complète. Chaque groupe a son propre plan, sa confirmation et son reçu.</p>
      <h3 class="fi-delta-title">${glyph('minus')}Retirer de</h3>
      <div class="fi-delta-list">${current.length ? current.map((r, n) => `<label class="fi-delta-row" data-j="${n}"><input type="checkbox" data-remove="${esc(r.dn)}"${r.privileged ? ' disabled' : ''}>
        <span>${r.privileged ? glyph('shield') : glyph('group')}${esc(r.name)}</span>${r.privileged ? pill('accent', 'Protégé', { size: 'sm' }) : ''}</label>`).join('') : '<p class="fi-faint">Aucun groupe direct.</p>'}</div>
      <h3 class="fi-delta-title">${glyph('plus')}Ajouter à</h3>
      <label class="fi-picker-search">${glyph('search')}<input class="input" type="search" maxlength="100" placeholder="Nom du groupe…" data-delta-search autocomplete="off"></label>
      <div class="fi-delta-hits" role="listbox" aria-label="Groupes trouvés"></div>
      <div class="fi-delta-chosen"></div>
      <div class="fi-delta-steps" hidden></div>`;
    const panelCtl = openDrawer({
      title: 'Modifier plusieurs groupes', subtitle: `${S.sheet.identity.name} · un plan par groupe`, icon: 'sliders', key: 'fiche.delta', width: 560, body,
      actions: [{ id: 'cancel', label: 'Annuler', run: (p) => p.close() }, { id: 'prepare', label: 'Préparer les plans', primary: true, run: () => prepare() }],
    });
    const hits = body.querySelector('.fi-delta-hits');
    const chosen = body.querySelector('.fi-delta-chosen');
    const steps = body.querySelector('.fi-delta-steps');
    const paintChosen = () => {
      chosen.innerHTML = [...adds.values()].map((g) => `<span class="chip info">${glyph('group')}${esc(g.name)}<button type="button" class="fi-chip-x" data-unadd="${esc(g.dn)}" aria-label="Retirer ${esc(g.name)} des ajouts">${glyph('x')}</button></span>`).join('');
    };
    const search = debounce(async (text) => {
      if (text.length < 2) { hits.innerHTML = ''; return; }
      try {
        const found = await S.ctx.call('fiche.pick', { text, kinds: ['group'] });
        hits.innerHTML = found.slice(0, 8).map((g) => `<button type="button" class="fi-pick" data-add="${esc(g.dn)}" data-name="${esc(g.name)}">${glyph('group')}<span class="fi-pick-body"><span class="fi-pick-name">${esc(g.name)}</span><span class="fi-pick-sub">${esc(g.detail ?? '')}</span></span></button>`).join('')
          || '<p class="fi-faint">Aucun groupe ne correspond.</p>';
      } catch (err) {
        hits.innerHTML = `<p class="fi-faint">${esc(errorText(err))}</p>`;
      }
    }, 180);
    let planned = null;
    // A change of the choices after « Préparer les plans » makes the prepared steps stale: they are computed again.
    const stale = () => {
      if (!planned) return;
      planned = null;
      steps.hidden = true;
      steps.innerHTML = '';
      const b = panelCtl.foot?.querySelector('[data-id="prepare"]');
      if (b) b.textContent = 'Préparer les plans';
      announce('Choix modifiés : les plans seront préparés de nouveau.');
    };
    body.addEventListener('input', (e) => { if (e.target.matches?.('[data-delta-search]')) search(e.target.value.trim()); });
    body.addEventListener('change', (e) => { if (e.target.matches?.('[data-remove]')) stale(); });
    body.addEventListener('click', (e) => {
      const t = e.target instanceof Element ? e.target : null;
      const add = t?.closest('[data-add]');
      if (add) { adds.set(add.dataset.add, { dn: add.dataset.add, name: add.dataset.name }); paintChosen(); stale(); return; }
      const un = t?.closest('[data-unadd]');
      if (un) { adds.delete(un.dataset.unadd); paintChosen(); stale(); }
    });
    async function prepare() {
      if (planned) { panelCtl.close(); run(planned); return; }
      const remove = [...body.querySelectorAll('[data-remove]:checked')].map((b) => b.dataset.remove);
      try {
        planned = await S.ctx.call('fiche.groups.delta', { dn: S.sheet.identity.dn, current: current.map((r) => r.dn), add: [...adds.keys()], remove });
      } catch (err) {
        toast(errorText(err), { tone: 'warn' });
        return;
      }
      steps.hidden = false;
      steps.innerHTML = `<h3 class="fi-delta-title">${glyph('check')}${esc(plural(planned.steps.length, 'plan à confirmer', 'plans à confirmer'))}</h3>
        <ol class="fi-steps">${planned.steps.map((s, n) => `<li data-j="${n}" data-action="${esc(s.action)}">${glyph(s.action === 'add' ? 'plus' : 'minus')}${esc(s.label)}</li>`).join('')}</ol>
        ${planned.notes.length ? `<ul class="fi-delta-notes">${planned.notes.map((n) => `<li>${glyph('info')}${esc(n)}</li>`).join('')}</ul>` : ''}`;
      applyVars(steps);
      const b = panelCtl.foot?.querySelector('[data-id="prepare"]');
      if (b) b.textContent = planned.steps.length ? 'Lancer les plans un par un' : 'Fermer';
      if (!planned.steps.length) planned = { steps: [] };
    }
    // One plan per group, one at a time. A step refused, cancelled or with nothing to do never stops the others silently: the
    // operator chooses to go on or to stop. Then every step is checked again on the controller (Test-DomeniaGroupDeltaPostcondition).
    async function run(p) {
      const outcomes = [];
      const list = p.steps ?? [];
      for (let i = 0; i < list.length; i++) {
        const s = list[i];
        const receipt = await write(S.ctx, 'fiche.membership.plan', { group: s.groupDn, member: s.memberDn, add: s.action === 'add' }, { subtitle: `${s.label} (${i + 1}/${list.length})` });
        outcomes.push({ step: s, receipt });
        if (!S.alive) return;
        if (!receipt && i < list.length - 1) {
          const goOn = await confirmDialog({
            title: 'Étape non envoyée',
            message: `${s.label}${NBSP}: aucune écriture (plan refusé, annulé ou sans objet). ${plural(list.length - i - 1, 'étape reste', 'étapes restent')} à préparer. Continuer avec la suivante${NBSP}?`,
            confirmLabel: 'Continuer', cancelLabel: 'Arrêter ici', icon: 'sliders',
          });
          if (!goOn) {
            for (const rest of list.slice(i + 1)) outcomes.push({ step: rest, receipt: null, skipped: true });
            break;
          }
        }
      }
      let check = null;
      try {
        check = await S.ctx.call('fiche.groups.delta.check', { dn: S.sheet.identity.dn, steps: list.map((s) => ({ action: s.action, group: s.groupDn })) });
      } catch (err) {
        toast(`Vérification des appartenances non aboutie${NBSP}: ${errorText(err)}`, { tone: 'warn' });
      }
      showDeltaResult(outcomes, check);
      await S.reload({ quiet: true });
    }
  }

  /** Synthesis of a delta: per group the receipt and the state read again on the controller, then the overall state. */
  function showDeltaResult(outcomes, check) {
    const RECEIPT = { applied: ['ok', 'Appliqué'], noChange: ['info', 'Déjà en place'], notApplied: ['alert', 'Non appliqué'], unknown: ['warn', 'Issue inconnue'], sent: ['warn', 'Envoyé, sans réponse'] };
    const STATUS = { verified: 'ok', failed: 'alert', toCheck: 'warn' };
    const OVERALL = { verified: 'ok', partial: 'alert', toCheck: 'warn', none: 'off' };
    const rows = outcomes.map(({ step, receipt, skipped }, n) => {
      const r = receipt ? RECEIPT[receipt.result] ?? ['off', receipt.result] : skipped ? ['off', 'Arrêté avant'] : ['off', 'Non envoyé'];
      const c = check?.rows?.find((x) => x.groupDn === step.groupDn && x.action === step.action);
      return `<tr data-j="${n}"><td>${glyph(step.action === 'add' ? 'plus' : 'minus')} ${esc(step.label)}</td><td>${pill(r[0], r[1], { size: 'sm' })}</td>
        <td>${c ? pill(STATUS[c.status] ?? 'off', c.statusLabel, { size: 'sm', dot: true }) : '<span class="fi-faint">Non relu</span>'}</td></tr>`;
    }).join('');
    const body = document.createElement('div');
    body.dataset.page = 'fiche';
    body.className = 'fi-delta-result';
    body.innerHTML = `<div class="fi-delta-overall" data-tone="${OVERALL[check?.overall] ?? 'warn'}">${pill(OVERALL[check?.overall] ?? 'warn', check?.overallLabel ?? 'À vérifier', { icon: check?.overall === 'verified' ? 'check' : 'alert' })}
        <p>${esc(check?.text ?? 'Relecture non aboutie : relisez la fiche pour vérifier les appartenances.')}</p></div>
      <div class="fi-table-wrap"><table class="fi-table"><thead><tr><th>Étape</th><th>Reçu</th><th>Relu sur le contrôleur</th></tr></thead><tbody>${rows}</tbody></table></div>
      <p class="fi-note">${glyph('info')}Rien n’est rejoué automatiquement${NBSP}: une étape en échec se prépare de nouveau, par son propre plan.</p>`;
    openDrawer({ title: 'Modification des groupes', subtitle: `${S.sheet.identity.name} · ${check?.overallLabel ?? 'À vérifier'}`, icon: 'sliders', key: 'fiche.delta', width: 600, body,
      actions: [{ id: 'close', label: 'Fermer', primary: true, run: (pnl) => pnl.close() }] });
    applyVars(body);
    announce(`Modification des groupes${NBSP}: ${check?.overallLabel ?? 'à vérifier'}.`);
  }

  buildGrid();
  load();

  const onClick = (e) => {
    const t = e.target instanceof Element ? e.target : null;
    const b = t?.closest('[data-g]');
    if (!b) return;
    if (b.getAttribute('aria-disabled') === 'true') { toast(b.dataset.tip || 'Indisponible.', { tone: 'info' }); return; }
    const what = b.dataset.g;
    if (what === 'nested') readNested();
    else if (what === 'add') S.act('groupAdd', { exclude: (direct?.rows ?? []).map((r) => r.dn) });
    else if (what === 'delta') delta();
    else if (what === 'compare') openCompare(S);
    else if (what === 'closeWhy') whyHost.innerHTML = '';
  };
  panel.addEventListener('click', onClick);

  // A route state shows the button and the grid; the read runs on `run` only (gesture, or simulation with run=1).
  function focusButton(selector) {
    const b = panel.querySelector(selector);
    b?.scrollIntoView({ block: 'center', behavior: 'smooth' });
    b?.classList.remove('fi-focus');
    void b?.offsetWidth;
    b?.classList.add('fi-focus');
    b?.focus({ preventScroll: true });
  }

  return {
    nested: readNested,
    why: () => { const first = direct?.rows?.[0]; if (first) why(first); },
    focus(what, { run = true } = {}) {
      if (what === 'nested') {
        if (run) readNested();
        else focusButton('[data-g="nested"]');
      } else if (what === 'why') {
        const pickFirst = () => { const first = direct?.rows?.find((r) => r.membership === 'Directe') ?? direct?.rows?.[0]; if (first) why(first); };
        if (run) {
          if (direct) pickFirst();
          else setTimeout(pickFirst, 400);
        } else {
          focusButton('.fi-groups-grid');
        }
      }
    },
    touch() { startFreshness(top); },
    update() {},
    refresh() { nested = null; whyHost.innerHTML = ''; buildGrid(); load(); },
    destroy() { panel.removeEventListener('click', onClick); grid?.destroy(); },
  };
}

/**
 * Comparison of the group access of the user of the fiche with a second account (FIC-005), organisation attributes merged
 * (FIC-004), plain text for a ticket (FIC-006). Read only: nothing is applied.
 * @param {any} S @param {string} [initial]  Second account prefilled (route « other »).
 * @param {{ submit?: boolean }} [o]  submit: compare at once (two network reads); false only shows the prefilled form.
 */
export function openCompare(S, initial = '', { submit = true } = {}) {
  const body = document.createElement('div');
  body.dataset.page = 'fiche';
  body.className = 'fi-cmp';
  body.innerHTML = `<form class="fi-cmp-form" novalidate>
      <label class="fi-field-label" for="fi-cmp-other">Second compte</label>
      <div class="fi-cmp-row"><input id="fi-cmp-other" class="input" type="search" maxlength="256" autocomplete="off" spellcheck="false" placeholder="Identifiant, DOMAINE\\compte, UPN ou DN" value="${esc(initial)}">
        <button class="btn primary fi-net" type="submit">${glyph('split')}Comparer</button></div>
      <div class="fi-cmp-sugg" role="listbox" aria-label="Comptes de la base locale"></div>
      <p class="fi-picker-hint">${glyph('database')}Le second compte est résolu exactement dans la base locale ; deux lectures bornées suivent (2 000 groupes, 16 niveaux). Rien n’est appliqué.</p>
    </form>
    <div class="fi-cmp-result"></div>`;
  openDrawer({ title: 'Comparer les droits', subtitle: `${S.sheet.identity.name} (A) et un second compte (B)`, icon: 'split', key: 'fiche.compare', width: 920, minWidth: 560, maxWidth: 1300, body, focusFirst: true,
    actions: [{ id: 'close', label: 'Fermer', run: (p) => p.close() }] });
  const form = body.querySelector('form');
  const input = /** @type {HTMLInputElement} */ (body.querySelector('#fi-cmp-other'));
  const sugg = body.querySelector('.fi-cmp-sugg');
  const result = body.querySelector('.fi-cmp-result');
  let data = null;
  let filter = 'all';

  const suggest = debounce(async () => {
    const text = input.value.trim();
    if (text.length < 2 || text.includes('=')) { sugg.innerHTML = ''; return; }
    try {
      const found = await S.ctx.call('fiche.pick', { text, kinds: ['user'] });
      sugg.innerHTML = found.filter((u) => u.dn !== S.sheet.identity.dn).slice(0, 6).map((u) => `<button type="button" class="chip" data-sugg="${esc(u.sam ?? u.name)}">${glyph('user')}${esc(u.name)}${u.sam ? ` · <span class="mono">${esc(u.sam)}</span>` : ''}</button>`).join('');
    } catch {
      sugg.innerHTML = '';
    }
  }, 200);

  function paint() {
    if (!data) return;
    const d = data;
    const rows = d.rows.filter((r) => filter === 'all' || (filter === 'left' && r.side === 'left') || (filter === 'right' && r.side === 'right') || (filter === 'both' && r.side === 'both') || (filter === 'priv' && r.privileged));
    result.innerHTML = `<div class="fi-cmp-parties fi-enter">
        <div class="fi-party a"><span class="fi-party-tag">A</span><b>${esc(d.left.name)}</b><span class="mono">${esc(d.left.sam ?? '')}</span></div>
        <span class="fi-party-vs">${glyph('split')}</span>
        <div class="fi-party b"><span class="fi-party-tag">B</span><b>${esc(d.right.name)}</b><span class="mono">${esc(d.right.sam ?? '')}</span></div></div>
      <div class="fi-cmp-chips">
        <button type="button" class="fi-cmp-chip${filter === 'all' ? ' on' : ''}" data-f="all"><b>${int(d.rows.length)}</b>Tous</button>
        <button type="button" class="fi-cmp-chip a${filter === 'left' ? ' on' : ''}" data-f="left"><b>${int(d.leftOnly)}</b>Seulement A</button>
        <button type="button" class="fi-cmp-chip b${filter === 'right' ? ' on' : ''}" data-f="right"><b>${int(d.rightOnly)}</b>Seulement B</button>
        <button type="button" class="fi-cmp-chip both${filter === 'both' ? ' on' : ''}" data-f="both"><b>${int(d.common)}</b>Communs</button>
        <button type="button" class="fi-cmp-chip priv${filter === 'priv' ? ' on' : ''}" data-f="priv"><b>${int(d.rows.filter((r) => r.privileged).length)}</b>À privilèges</button>
        <button type="button" class="btn sm" data-ticket>${glyph('copy')}Copier pour le ticket</button></div>
      <p class="fi-note">${glyph('info')}${esc(d.summary)}</p>
      <div class="fi-table-wrap"><table class="fi-table fi-org"><thead><tr><th>Organisation</th><th>A</th><th>B</th></tr></thead><tbody>
        ${d.organisation.map((o) => `<tr class="${o.same ? '' : 'diff'}"><th scope="row">${esc(o.element)}</th><td>${esc(o.left ?? '—')}</td><td>${esc(o.right ?? '—')}</td></tr>`).join('')}</tbody></table></div>
      <div class="fi-table-wrap fi-cmp-groups"><table class="fi-table"><thead><tr><th>Groupe</th><th>Catégorie</th><th>Chemin</th><th>Origine</th></tr></thead><tbody>
        ${rows.length ? rows.map((r, n) => `<tr data-side="${esc(r.side)}" data-j="${n}"><td><span class="fi-gname">${r.privileged ? `<span class="fi-priv" data-tip="${esc(r.alert ?? 'Groupe à privilèges')}">${glyph('shield')}</span>` : glyph('group')}${esc(r.group)}</span></td>
          <td>${pill(r.side === 'left' ? 'info' : r.side === 'right' ? 'accent' : 'off', r.category, { size: 'sm' })}</td><td class="fi-path">${esc(r.path || '—')}</td><td>${esc(r.origin)}</td></tr>`).join('')
          : '<tr><td colspan="4" class="fi-faint">Aucun groupe dans cette catégorie.</td></tr>'}</tbody></table></div>
      <p class="fi-note">${glyph('shield')}${esc(d.note)}</p>`;
    applyVars(result);
  }

  form.addEventListener('submit', async (e) => {
    e.preventDefault();
    const other = input.value.trim();
    if (!other) { input.focus(); return; }
    result.innerHTML = skeleton(6);
    result.setAttribute('aria-busy', 'true');
    try {
      data = await S.ctx.call('fiche.compare', { dn: S.sheet.identity.dn, other });
      filter = 'all';
      paint();
      announce(data.summary);
    } catch (err) {
      result.innerHTML = failure(err, { title: 'Comparaison impossible', retry: false });
    } finally {
      result.removeAttribute('aria-busy');
    }
  });
  input.addEventListener('input', suggest);
  body.addEventListener('click', async (e) => {
    const t = e.target instanceof Element ? e.target : null;
    const s = t?.closest('[data-sugg]');
    if (s) { input.value = s.dataset.sugg; sugg.innerHTML = ''; form.requestSubmit(); return; }
    const f = t?.closest('[data-f]');
    if (f) { filter = f.dataset.f; paint(); return; }
    if (t?.closest('[data-ticket]') && data) {
      const ok = await writeClipboard(data.ticket);
      toast(ok ? 'Comparaison copiée pour le ticket.' : 'Copie impossible.', { tone: ok ? 'ok' : 'warn', life: 2600 });
    }
  });
  if (initial && submit) setTimeout(() => form.requestSubmit(), 50);
}

export { NBSP, emptyNote };
