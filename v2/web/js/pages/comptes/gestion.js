// Comptes screen, tab « Comptes de l’OU »: indicators that filter, the list of the accounts of the section scope (kit grid,
// local filters), the detail of the active account (master-detail split) and the collective actions on a selection.
// Reads: accounts.list (fictitious directory in memory in simulation; on the controller in directory mode, only on the
// operator's gesture), accounts.detail. Writes: runWrite (one account) and the batch panel (several), never anything else.
import { createGrid, createSplit, createFilterBar, glyph, pill, setVars, NBSP } from '../../kit/index.js';
import { esc, countUp, formatNumber, announce, copyText, toast } from '../../ui.js';
import { runWrite } from '../../write-flow.js';
import { avatar, plural, emptyState, errorSentence, STATUS_ICONS } from './shared.js';
import { createDetail } from './detail.js';
import { openBatch } from './batch.js';

/** Indicators (tiles): each one toggles the facet of the same id. */
const TILES = [
  { id: 'locked', label: 'Verrouillés', sub: 'Dont verrouillages à vérifier', icon: 'lock', tone: 'alert' },
  { id: 'passwordExpired', label: 'Mots de passe expirés', sub: 'Changement nécessaire', icon: 'key', tone: 'alert' },
  { id: 'expiring', label: 'Expirent sous 14 jours', sub: 'Mot de passe à renouveler', icon: 'clock', tone: 'warn' },
  { id: 'disabled', label: 'Désactivés', sub: 'Ne peuvent pas ouvrir de session', icon: 'power', tone: 'off' },
  { id: 'accountExpired', label: 'Comptes qui expirent', sub: 'Expirés ou sous 30 jours', icon: 'calendar', tone: 'warn' },
];

/** Facets of the list (local filters, combined with OR). */
const FACETS = [
  { id: 'locked', label: 'Verrouillés', tone: 'alert', test: (r) => r.enabled && (r.lock === 'locked' || r.lock === 'toCheck') },
  { id: 'passwordExpired', label: 'Mot de passe expiré', tone: 'alert', test: (r) => r.enabled && r.password === 'expired' },
  { id: 'expiring', label: 'Expire bientôt', tone: 'warn', test: (r) => r.enabled && r.password === 'expiring' },
  { id: 'mustChange', label: 'À changer', tone: 'info', test: (r) => r.enabled && r.password === 'mustChange' },
  { id: 'disabled', label: 'Désactivés', tone: 'off', test: (r) => !r.enabled },
  { id: 'accountExpired', label: 'Comptes qui expirent', tone: 'warn', test: (r) => r.accountExpired || (r.accountExpiresAt && Date.parse(r.accountExpiresAt) - Date.now() <= 30 * 86_400_000) },
  { id: 'privileged', label: 'À privilèges', tone: 'warn', test: (r) => r.privileged },
  { id: 'stale', label: 'Inactifs', tone: 'info', test: (r) => r.enabled && (!r.lastLogon || Date.now() - Date.parse(r.lastLogon) > 90 * 86_400_000) },
];

const STATUS_OPTIONS = [
  { value: 'locked', label: 'Verrouillé', tone: 'alert' },
  { value: 'lockToCheck', label: 'Verrouillage à vérifier', tone: 'warn' },
  { value: 'disabled', label: 'Désactivé', tone: 'off' },
  { value: 'accountExpired', label: 'Compte expiré', tone: 'alert' },
  { value: 'passwordExpired', label: 'Mot de passe expiré', tone: 'alert' },
  { value: 'mustChange', label: 'Mot de passe à changer', tone: 'info' },
  { value: 'expiring', label: 'Expire bientôt', tone: 'warn' },
  { value: 'ok', label: 'Actif', tone: 'ok' },
];
const PASSWORD_OPTIONS = [
  { value: 'valid', label: 'Valide', tone: 'ok' },
  { value: 'expiring', label: 'Expire bientôt', tone: 'warn' },
  { value: 'expired', label: 'Expiré', tone: 'alert' },
  { value: 'mustChange', label: 'À changer', tone: 'info' },
  { value: 'neverExpires', label: 'N’expire jamais', tone: 'off' },
];
const LOT_ACTIONS = { deverrouiller: 'unlock', activer: 'enable', desactiver: 'disable', imposer: 'mustChange', expiration: 'expiration' };

function tileCount(id, c) {
  switch (id) {
    case 'locked': return { value: c.locked + c.lockToCheck, extra: c.lockToCheck ? `dont ${formatNumber(c.lockToCheck)}${NBSP}à vérifier` : (c.lockExpired ? `${formatNumber(c.lockExpired)}${NBSP}verrouillages échus` : 'Aucun à vérifier') };
    case 'passwordExpired': return { value: c.passwordExpired, extra: c.mustChange ? `${formatNumber(c.mustChange)}${NBSP}à changer à la connexion` : 'Aucun changement exigé' };
    case 'expiring': return { value: c.passwordExpiring, extra: c.neverExpires ? `${formatNumber(c.neverExpires)}${NBSP}sans expiration` : 'Tous expirent' };
    case 'disabled': return { value: c.disabled, extra: `${formatNumber(c.enabled)}${NBSP}activés` };
    default: return { value: c.accountExpired + c.accountExpiring, extra: c.accountExpired ? `dont ${formatNumber(c.accountExpired)}${NBSP}expirés` : 'Aucun expiré' };
  }
}

/**
 * Mounts the tab in panel. Returns a cleanup function.
 * @param {HTMLElement} panel
 * @param {any} ctx  Context of the screen.
 * @param {{ simulated: () => boolean, onList: (list: any) => void, onScope: () => void, params: any }} page
 */
export function mountGestion(panel, ctx, page) {
  let list = null;
  let rows = [];
  let pressed = new Set(page.params.filtre && FACETS.some((f) => f.id === page.params.filtre) ? [page.params.filtre] : []);
  let grid = null;
  let split = null;
  let bar = null;
  let detail = null;
  let activeTimer = 0;
  let loading = false;
  let firstLoad = true;
  let alive = true;

  panel.innerHTML = `<div class="cpt-gestion">
    <div class="cpt-tiles-band" role="group" aria-label="Indicateurs des comptes du périmètre">${TILES.map((t, n) => `
      <button class="cpt-ktile spot reveal" type="button" data-tile="${t.id}" data-tone="${t.tone}" aria-pressed="false" data-i="${n}">
        <span class="cpt-ktile-ico">${glyph(t.icon)}</span>
        <span class="cpt-ktile-value num"><span class="skeleton cpt-sk-value"></span></span>
        <span class="cpt-ktile-check" aria-hidden="true">${glyph('filter')}</span>
        <span class="cpt-ktile-label">${esc(t.label)}</span>
        <span class="cpt-ktile-bar" aria-hidden="true"><i></i></span>
        <span class="cpt-ktile-sub">${esc(t.sub)}</span>
      </button>`).join('')}</div>
    <div class="cpt-scope-empty" hidden></div>
    <section class="card cpt-workspace reveal" aria-label="Comptes du périmètre">
      <div class="cpt-ws-head"><div class="cpt-fbar"></div></div>
      <div class="cpt-ws-split"></div>
    </section>
  </div>`;
  panel.querySelectorAll('[data-i]').forEach((el) => setVars(el, { '--i': el.dataset.i }));

  const gridHost = document.createElement('div');
  gridHost.className = 'cpt-grid-host';
  const detailHost = document.createElement('div');
  detailHost.className = 'cpt-detail-host';

  // ---------- Filters ----------

  function facetList() {
    const c = list?.counts;
    return FACETS.map((f) => ({ id: f.id, label: f.label, tone: f.tone, pressed: pressed.has(f.id), count: rows.filter(f.test).length }))
      .filter((f) => f.count > 0 || f.pressed || !c);
  }

  function visibleRows() {
    if (!pressed.size) return rows;
    const tests = FACETS.filter((f) => pressed.has(f.id)).map((f) => f.test);
    return rows.filter((r) => tests.some((t) => t(r)));
  }

  function applyFilters({ keepScroll = false } = {}) {
    const shown = visibleRows();
    grid.setRows(shown, { keepSelection: true, keepScroll });
    bar.setFacets(facetList());
    // The grid already counts its lines: the sentence only appears while a facet narrows the list.
    bar.setSummary(pressed.size ? `→ ${plural(shown.length, 'compte affiché', 'comptes affichés')} sur ${formatNumber(rows.length)}` : '');
    panel.querySelectorAll('[data-tile]').forEach((b) => b.setAttribute('aria-pressed', String(pressed.has(b.dataset.tile))));
  }

  function toggle(id, on) {
    if (on) pressed.add(id); else pressed.delete(id);
    applyFilters();
    announce(pressed.size ? `${plural(visibleRows().length, 'compte affiché', 'comptes affichés')}.` : 'Tous les comptes sont affichés.');
  }

  // ---------- Grid ----------

  const columns = [
    { id: 'name', label: 'Nom', required: true, width: 215, html: (v, r) => `<span class="cpt-cell-name">${avatar(r.name, r.guid, 'sm')}<span class="cpt-cell-n">${esc(v)}</span>${r.privileged ? `<span class="cpt-priv" data-tip="Compte à privilèges (adminCount = 1)">${glyph('shield')}</span>` : ''}</span>` },
    { id: 'status', label: 'État', type: 'enum', width: 155, options: STATUS_OPTIONS },
    { id: 'sam', label: 'Compte', mono: true, width: 125 },
    { id: 'password', label: 'Mot de passe', type: 'enum', width: 150, options: PASSWORD_OPTIONS },
    { id: 'passwordExpiresAt', label: 'Expiration du mot de passe', type: 'date', width: 170, tip: 'Calculée par le contrôleur, sinon estimée par la stratégie' },
    { id: 'lastLogon', label: 'Dernière connexion', type: 'date', width: 150, tip: 'lastLogonTimestamp : à 14 jours près' },
    { id: 'badPasswordCount', label: 'Essais erronés', type: 'number', width: 110, tip: 'Compteur propre au contrôleur lu, non répliqué' },
    { id: 'accountExpiresAt', label: 'Expiration du compte', type: 'date', dateStyle: 'date', width: 150 },
    { id: 'department', label: 'Service', width: 160 },
    { id: 'office', label: 'Site', width: 110 },
    { id: 'ou', label: 'OU', width: 140, hidden: true },
    { id: 'title', label: 'Fonction', width: 180, hidden: true },
    { id: 'lockedAt', label: 'Verrouillé le', type: 'date', width: 150, hidden: true },
    { id: 'passwordLastSet', label: 'Mot de passe changé le', type: 'date', width: 170, hidden: true },
    { id: 'upn', label: 'UPN', mono: true, width: 220, hidden: true },
    { id: 'dn', label: 'Chemin (DN)', mono: true, width: 420, hidden: true },
  ];

  function single(kind, row) {
    const plans = { unlock: 'accounts.unlock.plan', enable: 'accounts.enable.plan', disable: 'accounts.disable.plan', mustChange: 'accounts.mustChange.plan' };
    runWrite(ctx, { plan: plans[kind], args: { dn: row.dn }, subtitle: `Compte utilisateur · ${row.name}`, onDone: () => changed(row.dn) });
  }

  function rowMenu({ rows: sel, row }) {
    if (!row) return [];
    const locked = row.lock !== 'unlocked';
    const items = [
      { label: 'Ouvrir le détail', icon: 'eye', kbd: 'Entrée', run: () => select(row) },
      '-',
      { label: 'Déverrouiller…', icon: 'lock', danger: true, disabled: !locked, reason: 'Ce compte n’est pas verrouillé.', run: () => single('unlock', row) },
      { label: 'Réinitialiser le mot de passe…', icon: 'key', run: () => select(row, 'mdp') },
      row.enabled
        ? { label: 'Désactiver…', icon: 'power', danger: true, run: () => single('disable', row) }
        : { label: 'Activer…', icon: 'power', run: () => single('enable', row) },
      { label: 'Imposer un nouveau mot de passe…', icon: 'refresh', disabled: row.password === 'mustChange' || row.password === 'neverExpires', reason: 'Changement déjà exigé ou mot de passe sans expiration.', run: () => single('mustChange', row) },
      { label: 'Expiration du compte…', icon: 'calendar', run: () => select(row, 'expiration') },
      { label: 'Lire les verrouillages', icon: 'wifi', run: () => select(row, 'verrouillages') },
      '-',
      { label: 'Ouvrir la fiche', icon: 'object', run: () => ctx.navigate('fiche', { dn: row.dn }) },
      { label: 'Copier', icon: 'copy', items: [
        { label: 'Le compte', run: () => copy(row.sam, 'Compte copié.') },
        { label: 'Le DN', run: () => copy(row.dn, 'DN copié.') },
      ] },
    ];
    if (sel.length > 1) items.unshift({ heading: plural(sel.length, 'compte sélectionné', 'comptes sélectionnés') });
    return items;
  }

  async function copy(text, done) {
    if (await copyText(text)) toast(done, { tone: 'ok', life: 2000 });
  }

  function batchActions(sel) {
    const any = (fn) => sel.some(fn);
    return [
      { label: 'Déverrouiller…', icon: 'lock', danger: true, disabled: !any((r) => r.lock !== 'unlocked'), reason: 'Aucun compte verrouillé dans la sélection.', run: (s) => batch('unlock', s) },
      { label: 'Activer…', icon: 'power', disabled: !any((r) => !r.enabled), reason: 'Aucun compte désactivé dans la sélection.', run: (s) => batch('enable', s) },
      { label: 'Désactiver…', icon: 'power', danger: true, disabled: !any((r) => r.enabled), reason: 'Aucun compte activé dans la sélection.', run: (s) => batch('disable', s) },
      { label: 'Imposer un nouveau mot de passe…', icon: 'refresh', run: (s) => batch('mustChange', s) },
      { label: 'Fixer l’expiration…', icon: 'calendar', run: (s) => batch('expiration', s) },
    ];
  }

  function batch(action, sel) {
    openBatch(ctx, { action, rows: sel, onDone: () => load({ keep: true }) });
  }

  function select(row, action = null) {
    grid.select([row.guid]);
    detail.show(row, { action });
  }

  grid = createGrid(gridHost, {
    key: 'comptes.liste',
    label: 'Comptes du périmètre',
    rowId: (r) => r.guid,
    selection: 'multi',
    height: 'fill',
    loading: true,
    columns,
    quickPlaceholder: 'Filtrer : nom, compte, service…',
    empty: { icon: 'search', title: 'Aucun compte', text: 'Aucun compte ne correspond aux filtres : rien n’est relu, effacez les filtres pour tout revoir.' },
    onActivate: (r) => select(r),
    onActiveChange: (r) => {
      clearTimeout(activeTimer);
      if (!r) return;
      activeTimer = setTimeout(() => { if (alive && detail.current()?.guid !== r.guid) detail.show(r); }, 140);
    },
    contextMenu: rowMenu,
    selectionActions: batchActions,
  });

  detail = createDetail(detailHost, ctx, {
    onChanged: (dn) => changed(dn),
    onPick: (dn) => {
      const row = rows.find((r) => r.dn.toLowerCase() === String(dn).toLowerCase());
      if (row) { pressed.clear(); applyFilters(); select(row); } else toast('Ce compte est hors du périmètre de la liste.', { tone: 'info' });
    },
    autoRead: () => page.simulated() && page.params.lire === '1',
  });

  split = createSplit(panel.querySelector('.cpt-ws-split'), {
    a: gridHost, b: detailHost, key: 'comptes.detail', size: 500, min: 400, max: 820, label: 'Taille du détail du compte',
  });

  bar = createFilterBar(panel.querySelector('.cpt-fbar'), {
    label: 'Filtres des comptes',
    facets: facetList(),
    onToggle: (id, on) => toggle(id, on),
    onClear: () => { pressed.clear(); applyFilters(); },
  });

  panel.querySelector('.cpt-tiles-band').addEventListener('click', (e) => {
    const b = e.target.closest('[data-tile]');
    if (!b || !list) return;
    toggle(b.dataset.tile, !pressed.has(b.dataset.tile));
  });

  // ---------- Data ----------

  function paintTiles() {
    const c = list.counts;
    const base = Math.max(1, c.total);
    panel.querySelectorAll('[data-tile]').forEach((b, n) => {
      const { value, extra } = tileCount(b.dataset.tile, c);
      const v = b.querySelector('.cpt-ktile-value');
      v.innerHTML = `<span class="visually-hidden">${esc(formatNumber(value))}</span><span aria-hidden="true" data-count>0</span>`;
      countUp(v.querySelector('[data-count]'), value, { delay: n * 60 });
      b.querySelector('.cpt-ktile-sub').textContent = extra;
      setVars(b.querySelector('.cpt-ktile-bar i'), { '--p': String(Math.min(1, value / base)) });
      b.classList.toggle('zero', value === 0);
      b.disabled = false;
    });
  }

  function showScopeEmpty() {
    const box = panel.querySelector('.cpt-scope-empty');
    const ws = panel.querySelector('.cpt-workspace');
    const empty = list.rows.length === 0;
    box.hidden = !empty;
    ws.hidden = empty;
    panel.querySelector('.cpt-tiles-band').hidden = empty;
    if (!empty) return;
    const suggestions = list.suggestions.map((s, n) => `<button class="cpt-sugg" type="button" data-sugg="${n}" data-i="${n}">${glyph('ou')}<span class="cpt-sugg-main"><b>${esc(s.name)}</b><span>${esc(s.path)}</span></span><span class="cpt-sugg-n" data-tip="${esc(plural(s.users, 'compte utilisateur', 'comptes utilisateurs'))}">${glyph('user')}${esc(formatNumber(s.users))}</span></button>`).join('');
    const title = list.tooWide ? 'Le périmètre est le domaine entier' : `Aucun compte utilisateur dans ${list.scope.label}`;
    const text = list.tooWide
      ? 'La liste des comptes n’est jamais lue sur tout le domaine : choisissez une OU.'
      : `${list.scope.origin === 'working' ? 'L’OU de travail' : 'Cette OU'} ne contient que des postes ou des groupes. Choisissez une OU qui contient des comptes : le choix vaut pour la section Comptes seulement.`;
    box.innerHTML = `<section class="card cpt-scope-card-empty reveal in">${emptyState({ iconName: 'users', title, text })}
      ${suggestions ? `<div class="cpt-suggs" role="group" aria-label="OU qui contiennent des comptes">${suggestions}</div>` : ''}
      <div class="cpt-empty-actions"><button class="btn" type="button" data-pick-scope>${glyph('ou')}Choisir une autre OU…</button></div></section>`;
    box.querySelectorAll('[data-sugg]').forEach((b) => b.addEventListener('click', async () => {
      const s = list.suggestions[Number(b.dataset.sugg)];
      b.disabled = true;
      try {
        await ctx.call('accounts.scope.set', { dn: s.dn, subtree: true });
        page.onScope();
        await load();
      } catch (err) {
        console.error(err);
        b.disabled = false;
        toast(errorSentence(err, 'Périmètre non changé.'), { tone: 'alert' });
      }
    }));
    box.querySelector('[data-pick-scope]').addEventListener('click', () => page.pickScope());
  }

  async function load({ keep = false } = {}) {
    if (loading) return;
    loading = true;
    if (!keep) grid.setLoading(true);
    try {
      const next = await ctx.call('accounts.list');
      if (!alive) return;
      list = next;
      rows = next.rows;
      page.onList(next);
      paintTiles();
      showScopeEmpty();
      grid.setEmpty({ icon: 'search', title: 'Aucun compte', text: 'Aucun compte ne correspond aux filtres : rien n’est relu, effacez les filtres pour tout revoir.' });
      applyFilters({ keepScroll: keep });
      if (next.truncated) toast(`Liste limitée aux ${formatNumber(next.limit)} premiers comptes : choisissez une OU plus précise.`, { tone: 'warn', life: 7000 });
      const current = detail.current();
      if (current) {
        const again = rows.find((r) => r.guid === current.guid);
        if (again) detail.show(again); else detail.show(null);
      } else if (firstLoad) {
        openFromParams();
      }
      firstLoad = false;
    } catch (err) {
      console.error(err);
      if (!alive) return;
      grid.setError(errorSentence(err, 'La liste des comptes n’a pas pu être lue.'), { retry: () => load() });
      panel.querySelectorAll('[data-tile] .cpt-ktile-value').forEach((v) => { v.innerHTML = '<span class="cpt-none">—</span>'; });
    } finally {
      loading = false;
    }
  }

  function openFromParams() {
    const p = page.params;
    if (p.compte) {
      const key = String(p.compte).toLowerCase();
      const row = rows.find((r) => r.sam.toLowerCase() === key || r.dn.toLowerCase() === key);
      if (row) {
        if (!visibleRows().includes(row)) { pressed.clear(); applyFilters(); }
        select(row, p.action ?? null);
      }
    } else if (!pressed.size) {
      // Open the most urgent account so the detail is never empty when something needs attention.
      const urgent = rows.find((r) => r.status === 'locked');
      if (urgent && p.ouvrir !== 'non') select(urgent);
    }
    const lot = LOT_ACTIONS[p.lot];
    if (lot) {
      const sel = visibleRows().filter(FACETS.find((f) => f.id === (lot === 'unlock' ? 'locked' : lot === 'enable' ? 'disabled' : 'stale'))?.test ?? (() => true)).slice(0, 50);
      if (sel.length) { grid.select(sel.map((r) => r.guid)); batch(lot, sel); }
    }
  }

  function changed(dn) {
    load({ keep: true }).then(() => {
      const current = detail.current();
      if (current && current.dn === dn) detail.reload();
    });
  }

  if (page.autoLoad()) {
    load();
  } else {
    grid.setEmpty({ icon: 'wifi', title: 'Liste non lue', text: 'La liste des comptes se lit sur le contrôleur, sur votre geste seulement.', action: { label: 'Lire les comptes de l’OU', icon: 'wifi', run: () => load() } });
    grid.setRows([]);
  }

  return {
    reload: () => load({ keep: true }),
    destroy: () => {
      alive = false;
      clearTimeout(activeTimer);
      detail.destroy();
      grid.destroy();
      split.destroy?.();
      bar.destroy();
    },
  };
}

export { STATUS_ICONS };
