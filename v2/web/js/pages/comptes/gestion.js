// Comptes screen, tab « Comptes de l’OU »: compact indicators that filter, the list of the accounts of the section scope
// (kit grid, local filters), the detail of the active account (master-detail split, foldable) and the collective actions on
// a selection. Reads: accounts.list (fictitious directory in memory in simulation; on the controller in directory mode, only
// on the operator's gesture), accounts.detail (on a double click or Entrée in directory mode). Writes: runWrite (one account) and
// the batch panel (several), never anything else.
import { createGrid, createSplit, createFilterBar, glyph, setVars, NBSP } from '../../kit/index.js';
import { esc, countUp, formatNumber, announce, copyText, toast, reveal } from '../../ui.js';
import { runWrite } from '../../write-flow.js';
import { avatar, plural, emptyState, errorSentence, STATUS_ICONS } from './shared.js';
import { createDetail } from './detail.js';
import { openBatch, MAX_BATCH } from './batch.js';

/** Indicators (tiles): each one toggles the facet of the same id; counted like AccountsRules.Counts (enabled accounts). */
const TILES = [
  { id: 'locked', label: 'Verrouillés', icon: 'lock', tone: 'alert' },
  { id: 'passwordExpired', label: 'Mots de passe expirés', icon: 'key', tone: 'alert' },
  { id: 'expiring', label: 'Expirent sous 14 jours', icon: 'clock', tone: 'warn' },
  { id: 'disabled', label: 'Désactivés', icon: 'power', tone: 'off' },
  { id: 'accountExpired', label: 'Comptes qui expirent', icon: 'calendar', tone: 'warn' },
];

const DAY = 86_400_000;

/**
 * Facets of the list (local filters, combined with OR). The states count enabled accounts only, like the tiles and the
 * engine (AccountsRules.Counts): a tile and its facet always show the same number.
 */
const FACETS = [
  { id: 'locked', label: 'Verrouillés', tone: 'alert', test: (r) => r.enabled && (r.lock === 'locked' || r.lock === 'toCheck') },
  { id: 'passwordExpired', label: 'Mot de passe expiré', tone: 'alert', test: (r) => r.enabled && r.password === 'expired' },
  { id: 'expiring', label: 'Expire bientôt', tone: 'warn', test: (r) => r.enabled && r.password === 'expiring' },
  { id: 'mustChange', label: 'À changer', tone: 'info', test: (r) => r.enabled && r.password === 'mustChange' },
  { id: 'disabled', label: 'Désactivés', tone: 'off', test: (r) => !r.enabled },
  { id: 'accountExpired', label: 'Comptes qui expirent', tone: 'warn', test: (r) => r.enabled && (r.accountExpired || (r.accountExpiresAt && Date.parse(r.accountExpiresAt) - Date.now() <= 30 * DAY)) },
  { id: 'privileged', label: 'À privilèges', tone: 'warn', test: (r) => r.privileged },
  { id: 'stale', label: 'Inactifs', tone: 'info', test: (r) => r.enabled && (!r.lastLogon || Date.now() - Date.parse(r.lastLogon) > 90 * DAY) },
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
/** Accounts preselected by a link « ?lot= »: only targets coherent with the action (none for a forced change or an expiration). */
const LOT_FACETS = { unlock: 'locked', enable: 'disabled', disable: 'stale' };

function tileCount(id, c) {
  switch (id) {
    case 'locked': return { value: c.locked + c.lockToCheck, extra: c.lockToCheck ? `dont ${formatNumber(c.lockToCheck)}${NBSP}à vérifier` : (c.lockExpired ? `${formatNumber(c.lockExpired)}${NBSP}verrouillages échus` : 'Aucun à vérifier') };
    case 'passwordExpired': return { value: c.passwordExpired, extra: c.mustChange ? `${formatNumber(c.mustChange)}${NBSP}à changer à la connexion` : 'Aucun changement exigé' };
    case 'expiring': return { value: c.passwordExpiring, extra: c.neverExpires ? `${formatNumber(c.neverExpires)}${NBSP}sans expiration` : 'Tous expirent' };
    case 'disabled': return { value: c.disabled, extra: `${formatNumber(c.enabled)}${NBSP}activés` };
    default: return { value: c.accountExpired + c.accountExpiring, extra: c.accountExpired ? `dont ${formatNumber(c.accountExpired)}${NBSP}expirés` : 'Sous 30 jours, activés' };
  }
}

/**
 * Mounts the tab in panel. Returns { reload, destroy }.
 * @param {HTMLElement} panel
 * @param {any} ctx  Context of the screen.
 * @param {{ simulated: () => boolean, onList: (list: any) => void, onScope: () => void, pickScope: () => void, params: any }} page
 */
export function mountGestion(panel, ctx, page) {
  let list = null;
  let rows = [];
  const pressed = new Set(page.params.filtre && FACETS.some((f) => f.id === page.params.filtre) ? [page.params.filtre] : []);
  let grid = null;
  let split = null;
  let bar = null;
  let detail = null;
  let activeTimer = 0;
  let loading = false;
  let again = null;
  let firstLoad = true;
  let alive = true;

  panel.innerHTML = `<div class="cpt-gestion">
    <div class="cpt-tiles-band" role="group" aria-label="Indicateurs des comptes du périmètre (un clic filtre la liste)">${TILES.map((t, n) => `
      <button class="cpt-ktile spot reveal" type="button" data-tile="${t.id}" data-tone="${t.tone}" aria-pressed="false" data-i="${n}">
        <span class="cpt-ktile-ico">${glyph(t.icon)}</span>
        <span class="cpt-ktile-text"><span class="cpt-ktile-value num"><span class="skeleton cpt-sk-value"></span></span>
          <span class="cpt-ktile-label">${esc(t.label)}</span></span>
        <span class="cpt-ktile-check" aria-hidden="true">${glyph('filter')}</span>
        <span class="cpt-ktile-sub"></span>
        <span class="cpt-ktile-bar" aria-hidden="true"><i></i></span>
      </button>`).join('')}</div>
    <div class="cpt-scope-empty" hidden></div>
    <section class="card cpt-workspace reveal" aria-label="Comptes du périmètre">
      <div class="cpt-ws-head"><div class="cpt-fbar"></div>
        <div class="cpt-ws-tools">
          <button class="btn sm" type="button" data-reload data-tip="Relit la liste du périmètre${page.simulated() ? '' : ' sur le contrôleur'}">${glyph('refresh')}Actualiser</button>
          <button class="btn sm ghost" type="button" data-fold aria-pressed="false" data-tip="Masquer ou afficher le détail du compte">${glyph('split')}<span>Masquer le détail</span></button>
        </div></div>
      <div class="cpt-ws-split"></div>
    </section>
  </div>`;
  // The tab is mounted after the page cascaded its own cards in: its tiles and its workspace are observed here, or they
  // would stay invisible (.reveal without .in).
  const stopReveal = reveal(panel);
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

  // Few columns by default (the detail holds the rest); every column stays available in « Colonnes et affichage ».
  const columns = [
    { id: 'name', label: 'Nom', required: true, width: 230, html: (v, r) => `<span class="cpt-cell-name">${avatar(r.name, r.guid, 'sm')}<span class="cpt-cell-n">${esc(v)}</span>${r.privileged ? `<span class="cpt-priv" data-tip="Compte à privilèges (adminCount = 1)">${glyph('shield')}</span>` : ''}</span>` },
    { id: 'status', label: 'État', type: 'enum', width: 170, options: STATUS_OPTIONS },
    { id: 'sam', label: 'Compte', mono: true, width: 130 },
    { id: 'password', label: 'Mot de passe', type: 'enum', width: 150, options: PASSWORD_OPTIONS },
    { id: 'lastLogon', label: 'Dernière connexion', type: 'date', width: 160, tip: 'lastLogonTimestamp : à 14 jours près' },
    { id: 'passwordExpiresAt', label: 'Expiration du mot de passe', type: 'date', width: 200, hidden: true, tip: 'Calculée par le contrôleur, sinon estimée par la stratégie' },
    { id: 'badPasswordCount', label: 'Essais erronés', type: 'number', width: 130, hidden: true, tip: 'Compteur propre au contrôleur lu, non répliqué' },
    { id: 'accountExpiresAt', label: 'Expiration du compte', type: 'date', dateStyle: 'date', width: 170, hidden: true },
    { id: 'department', label: 'Service', width: 160, hidden: true },
    { id: 'office', label: 'Site', width: 110, hidden: true },
    { id: 'ou', label: 'OU', width: 140, hidden: true },
    { id: 'title', label: 'Fonction', width: 180, hidden: true },
    { id: 'lockedAt', label: 'Verrouillé le', type: 'date', width: 150, hidden: true },
    { id: 'passwordLastSet', label: 'Mot de passe changé le', type: 'date', width: 190, hidden: true },
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
      { label: 'Déverrouiller…', icon: 'lock', hint: 'écriture', disabled: !locked, reason: 'Ce compte n’est pas verrouillé.', run: () => single('unlock', row) },
      { label: 'Réinitialiser le mot de passe…', icon: 'key', hint: 'écriture', run: () => select(row, 'mdp') },
      { label: 'Imposer un nouveau mot de passe…', icon: 'refresh', hint: 'écriture', disabled: row.password === 'mustChange' || row.password === 'neverExpires', reason: row.password === 'mustChange' ? 'Le changement est déjà exigé à la prochaine connexion.' : 'Le mot de passe de ce compte n’expire jamais : un changement imposé resterait sans effet.', run: () => single('mustChange', row) },
      { label: 'Expiration du compte…', icon: 'calendar', hint: 'écriture', run: () => select(row, 'expiration') },
      row.enabled
        ? { label: 'Désactiver…', icon: 'power', hint: 'écriture', danger: true, run: () => single('disable', row) }
        : { label: 'Activer…', icon: 'power', hint: 'écriture', run: () => single('enable', row) },
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
      { label: 'Déverrouiller…', icon: 'lock', disabled: !any((r) => r.lock !== 'unlocked'), reason: 'Aucun compte verrouillé dans la sélection.', run: (s) => batch('unlock', s) },
      { label: 'Activer…', icon: 'power', disabled: !any((r) => !r.enabled), reason: 'Aucun compte désactivé dans la sélection.', run: (s) => batch('enable', s) },
      { label: 'Imposer un nouveau mot de passe…', icon: 'refresh', run: (s) => batch('mustChange', s) },
      { label: 'Fixer l’expiration…', icon: 'calendar', run: (s) => batch('expiration', s) },
      { label: 'Désactiver…', icon: 'power', danger: true, disabled: !any((r) => r.enabled), reason: 'Aucun compte activé dans la sélection.', run: (s) => batch('disable', s) },
    ];
  }

  function batch(action, sel) {
    openBatch(ctx, { action, rows: sel, onDone: () => load({ keep: true }) });
  }

  /** Shows a row in the detail; scroll: false keeps the list where it is (automatic opening, never a half-hidden first row). */
  function select(row, action = null, { scroll = true } = {}) {
    grid.select([row.guid], { scroll });
    if (split.isFolded?.()) setFold(false);
    detail.show(row, { action });
  }

  grid = createGrid(gridHost, {
    key: 'comptes.liste.v2',
    label: 'Comptes du périmètre',
    rowId: (r) => r.guid,
    selection: 'multi',
    height: 'fill',
    loading: true,
    columns,
    quickPlaceholder: `Filtrer${NBSP}: nom, compte, service…`,
    empty: { icon: 'search', title: 'Aucun compte', text: 'Aucun compte ne correspond aux filtres : rien n’est relu, effacez les filtres pour tout revoir.' },
    onActivate: (r) => select(r, null, { scroll: false }),
    onActiveChange: (r) => {
      clearTimeout(activeTimer);
      // Directory mode: accounts.detail reads the controller, so it waits for a double click or Entrée (onActivate).
      if (!r || !page.simulated()) return;
      activeTimer = setTimeout(() => { if (alive && detail.current()?.guid !== r.guid) detail.show(r); }, 220);
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
    simulated: () => page.simulated(),
  });

  split = createSplit(panel.querySelector('.cpt-ws-split'), {
    a: gridHost, b: detailHost, key: 'comptes.detail.v2', size: 460, min: 380, max: 820, label: 'Taille du détail du compte',
  });

  bar = createFilterBar(panel.querySelector('.cpt-fbar'), {
    label: 'Filtres des comptes',
    facets: facetList(),
    onToggle: (id, on) => toggle(id, on),
    onClear: () => { pressed.clear(); applyFilters(); },
  });

  function setFold(on) {
    split.fold(on);
    const b = panel.querySelector('[data-fold]');
    b.setAttribute('aria-pressed', String(on));
    b.querySelector('span').textContent = on ? 'Afficher le détail' : 'Masquer le détail';
    announce(on ? 'Détail du compte masqué : la liste prend toute la largeur.' : 'Détail du compte affiché.');
  }

  panel.querySelector('.cpt-tiles-band').addEventListener('click', (e) => {
    const b = e.target instanceof Element ? e.target.closest('[data-tile]') : null;
    if (!b || !list) return;
    toggle(b.dataset.tile, !pressed.has(b.dataset.tile));
  });
  panel.querySelector('.cpt-ws-tools').addEventListener('click', (e) => {
    const b = e.target instanceof Element ? e.target.closest('button') : null;
    if (!b) return;
    if (b.matches('[data-reload]')) { load({ keep: true }); announce('Liste des comptes relue.'); }
    if (b.matches('[data-fold]')) setFold(!split.isFolded());
  });
  if (split.isFolded?.()) {
    const b = panel.querySelector('[data-fold]');
    b.setAttribute('aria-pressed', 'true');
    b.querySelector('span').textContent = 'Afficher le détail';
  }

  // ---------- Data ----------

  function paintTiles() {
    const c = list.counts;
    const base = Math.max(1, c.enabled);
    panel.querySelectorAll('[data-tile]').forEach((b, n) => {
      const { value, extra } = tileCount(b.dataset.tile, c);
      const v = b.querySelector('.cpt-ktile-value');
      v.innerHTML = `<span class="visually-hidden">${esc(formatNumber(value))}</span><span aria-hidden="true" data-count>0</span>`;
      countUp(v.querySelector('[data-count]'), value, { delay: n * 60 });
      b.querySelector('.cpt-ktile-sub').textContent = extra;
      b.dataset.tip = extra;
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
    panel.classList.toggle('cpt-is-empty', empty);
    if (!empty) return;
    const suggestions = list.suggestions.map((s, n) => `<button class="cpt-sugg" type="button" data-sugg="${n}" data-i="${n}">${glyph('ou')}<span class="cpt-sugg-main"><b>${esc(s.name)}</b><span>${esc(s.path)}</span></span><span class="cpt-sugg-n" data-tip="${esc(plural(s.users, 'compte utilisateur', 'comptes utilisateurs'))}">${glyph('user')}${esc(formatNumber(s.users))}</span></button>`).join('');
    const title = list.tooWide ? 'Le périmètre est le domaine entier' : `Aucun compte utilisateur dans ${list.scope.label}`;
    const text = list.tooWide
      ? 'La liste des comptes n’est jamais lue sur tout le domaine : choisissez une OU.'
      : `${list.scope.origin === 'working' ? 'L’OU de travail' : 'Cette OU'} ne contient que des postes ou des groupes. Choisissez une OU qui contient des comptes : le choix vaut pour la section Comptes seulement.`;
    box.innerHTML = `<section class="card cpt-scope-card-empty reveal in">${emptyState({ iconName: 'users', title, text })}
      ${suggestions ? `<div class="cpt-suggs" role="group" aria-label="OU qui contiennent des comptes">${suggestions}</div>` : ''}
      <div class="cpt-empty-actions"><button class="btn" type="button" data-pick-scope>${glyph('ou')}Choisir une autre OU…</button></div></section>`;
    box.querySelectorAll('[data-i]').forEach((el) => setVars(el, { '--i': el.dataset.i }));
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

  /**
   * Reads the list. A read asked while another one runs is queued (never dropped): a receipt that arrives during a read still
   * gets a list read after its write.
   */
  async function load({ keep = false } = {}) {
    if (loading) {
      again = { keep: (again?.keep ?? true) && keep };
      return;
    }
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
      if (next.truncated) toast(`Liste limitée aux ${formatNumber(next.limit)} premiers comptes${NBSP}: choisissez une OU plus précise.`, { tone: 'warn', life: 7000 });
      const current = detail.current();
      if (current) {
        const same = rows.find((r) => r.guid === current.guid);
        if (same) detail.show(same); else detail.show(null);
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
      if (alive && again) {
        const queued = again;
        again = null;
        load(queued);
      }
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
    } else if (!pressed.size && page.simulated()) {
      // Open the most urgent account so the detail is never empty when something needs attention. The list does not scroll
      // to it (simulation only: in directory mode, the detail is read on a gesture).
      const urgent = rows.find((r) => r.status === 'locked');
      if (urgent && p.ouvrir !== 'non') select(urgent, null, { scroll: false });
    }
    const lot = LOT_ACTIONS[p.lot];
    if (lot) {
      const facet = FACETS.find((f) => f.id === LOT_FACETS[lot]);
      const selected = grid.getSelection?.() ?? [];
      const candidates = facet ? rows.filter(facet.test) : selected;
      if (!candidates.length) {
        toast(facet ? `Aucun compte «${NBSP}${facet.label.toLocaleLowerCase('fr')}${NBSP}» dans le périmètre${NBSP}: rien à préparer.` : 'Sélectionnez les comptes dans la liste, puis l’action dans la barre de sélection.', { tone: 'info', life: 6000 });
        return;
      }
      if (facet) { pressed.clear(); pressed.add(facet.id); applyFilters(); }
      const sel = candidates.slice(0, MAX_BATCH);
      if (candidates.length > MAX_BATCH) toast(`Lot limité aux ${formatNumber(MAX_BATCH)} premiers comptes sur ${formatNumber(candidates.length)}${NBSP}: les autres ne sont pas proposés.`, { tone: 'warn', life: 8000 });
      grid.select(sel.map((r) => r.guid), { scroll: false });
      batch(lot, sel);
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
      stopReveal();
      clearTimeout(activeTimer);
      detail.destroy();
      grid.destroy();
      split.destroy?.();
      bar.destroy();
    },
  };
}

export { STATUS_ICONS };
