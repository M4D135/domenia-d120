// Picker of the workstation console: the workstations of the working OU (poste.list, local base only), searched and
// filtered locally, opened with a click (the click is the gesture: the console then sends one ping, and reads the console
// user when the option is on, Domenia 1 PST-051). Also the side switcher of an open console and the workstations opened
// recently, kept in the memory of the page only (never written to disk, never a user name).
import { createGrid, openDrawer, createFilterBar, debounce } from '../../kit/index.js';
import { esc, ico, empty, failure, sk, skLines, NBSP, int, count, formatNumber, errorText } from './common.js';
import { reveal as revealCards, toast } from '../../ui.js';

const PRESENCE = {
  online: { label: 'Répond', tone: 'ok' }, offline: { label: 'Muet', tone: 'warn' }, error: { label: 'Test impossible', tone: 'alert' },
  unknown: { label: 'Non vérifié', tone: 'off' }, pending: { label: 'Test…', tone: 'info' }, remembered: { label: 'Mémoire', tone: 'info' },
};
const FACETS = [
  { id: 'online', label: 'Répondent' },
  { id: 'watch', label: 'À surveiller' },
  { id: 'noinv', label: 'Sans inventaire' },
  { id: 'laptop', label: 'Portables' },
];

// Workstations opened in this run of the application (memory of the page: DN and computer name only, six at most).
const RECENTS = [];

export function rememberRecent(row) {
  if (!row?.dn) return;
  const at = RECENTS.findIndex((r) => r.dn === row.dn);
  if (at >= 0) RECENTS.splice(at, 1);
  RECENTS.unshift({ dn: row.dn, name: row.name });
  RECENTS.length = Math.min(RECENTS.length, 6);
}

function columns() {
  return [
    { id: 'name', label: 'Poste', required: true, width: 150, mono: true },
    { id: 'presence', label: 'Présence', type: 'enum', width: 120, options: Object.entries(PRESENCE).map(([value, p]) => ({ value, label: p.label, tone: p.tone })) },
    { id: 'health', label: 'Santé', type: 'enum', width: 140, get: (r) => r.health.level, options: [
      { value: 'ok', label: 'Rien à signaler', tone: 'ok' }, { value: 'warn', label: 'À surveiller', tone: 'warn' },
      { value: 'alert', label: 'Critique', tone: 'alert' }, { value: 'off', label: 'Sans inventaire', tone: 'off' }] },
    // No inventory: the points are not known (« — »), never 0.
    { id: 'points', label: 'Points', type: 'number', width: 90, get: (r) => (r.inventoryAt ? r.health.points : null) },
    { id: 'user', label: 'Utilisateur', width: 180, get: (r) => r.user?.name ?? '' },
    { id: 'release', label: 'Système', width: 160, get: (r) => [r.os?.replace('Windows ', 'Win ').replace(' Entreprise', ' Ent.'), r.release].filter(Boolean).join(' · ') },
    { id: 'site', label: 'Site', width: 100 },
    { id: 'kind', label: 'Type', type: 'enum', width: 110, hidden: true, options: [{ value: 'desktop', label: 'Fixe' }, { value: 'laptop', label: 'Portable' }, { value: 'server', label: 'Serveur' }, { value: 'unknown', label: 'Autre' }] },
    { id: 'presenceAt', label: 'Dernier test', type: 'date', width: 130 },
    { id: 'inventoryAt', label: 'Inventaire', type: 'date', width: 130, tip: 'Date du dernier inventaire enregistré' },
    { id: 'dn', label: 'Chemin (DN)', mono: true, hidden: true, width: 420 },
  ];
}

/** Landing page of the screen: hero, search, option, facets, the grid of the workstations of the working OU. */
export function renderPicker(main, ctx) {
  let alive = true;
  main.innerHTML = `<div class="page ps-page ps-picker">
    <section class="ps-hero ps-pick-hero reveal">
      <span class="glow-ring hero-ring" aria-hidden="true"></span>
      <div class="orbs" aria-hidden="true"><span class="orb a"></span><span class="orb b"></span><span class="orb c"></span></div>
      <div class="ps-pick-head">
        <p class="eyebrow">${ico('monitor')}<span>Console d’un poste</span></p>
        <h1 class="gradient-text">Choisir un poste</h1>
        <p class="lead">État en direct, inventaire, logiciels, services, diagnostic, sondes, interventions et secrets d’un poste. Rien n’est lu sur le réseau sans votre geste.</p>
        <label class="ps-search"><span class="visually-hidden">Rechercher un poste</span>${ico('search')}<input class="input" type="search" data-search placeholder="Nom du poste, utilisateur, site, système…" autocomplete="off" spellcheck="false"><kbd>Entrée</kbd></label>
        <label class="ps-check-opt ps-open-opt"><input type="checkbox" data-opt="console" disabled> Lire aussi l’utilisateur connecté à l’ouverture d’un poste <span class="ps-faint">(un ping et une lecture de la console)</span></label>
        <div class="ps-recents" data-slot="recents"></div>
      </div>
      <div class="ps-pick-stats" data-slot="stats">${skLines('w55', 'w70', 'w40')}</div>
    </section>
    <section class="card ps-card ps-pick-list reveal">
      <div class="ps-pick-bar" data-slot="facets"></div>
      <div class="ps-pick-grid" data-slot="grid"></div>
      <p class="ps-pick-note" data-slot="summary">${sk('w55')}</p>
    </section>
  </div>`;
  const facetsHost = main.querySelector('[data-slot="facets"]');
  const gridHost = main.querySelector('[data-slot="grid"]');
  const pressed = new Set();
  let rows = [];
  const grid = createGrid(gridHost, {
    key: 'poste.picker',
    label: 'Postes de l’OU de travail',
    rowId: (r) => r.dn,
    selection: 'single',
    loading: true,
    height: '560px',
    columns: columns(),
    empty: { icon: 'search', title: 'Aucun poste', text: 'Aucun poste de l’OU de travail ne correspond : changez la recherche ou l’OU de travail (Accueil).' },
    onActivate: (row) => open(row),
    contextMenu: ({ row }) => [
      { label: 'Ouvrir la console', icon: 'monitor', kbd: 'Entrée', disabled: !row, run: () => open(row) },
      { label: 'Ouvrir la fiche du compte', icon: 'object', disabled: !row, run: () => ctx.navigate('fiche', { dn: row.dn }) },
      { label: 'Ouvrir la fiche de l’utilisateur', icon: 'user', disabled: !row?.user?.dn, reason: 'Aucun utilisateur associé.', run: () => ctx.navigate('fiche', { dn: row.user.dn }) },
    ],
  });
  const bar = createFilterBar(facetsHost, {
    label: 'Filtres rapides des postes',
    facets: FACETS.map((f) => ({ id: f.id, label: f.label, count: 0, pressed: false })),
    onToggle: (id, on) => { if (on) pressed.add(id); else pressed.delete(id); apply(); },
  });

  const searchInput = main.querySelector('[data-search]');
  const option = main.querySelector('[data-opt="console"]');
  function open(row) {
    rememberRecent(row);
    // Opening from the list is the gesture of Domenia 1 (PST-051): the console then sends one ping, nothing heavier
    // (and reads the console user when the option is on).
    ctx.navigate('poste', { dn: row.dn, verifier: '1' });
  }
  function matches(r) {
    if (pressed.has('online') && r.presence !== 'online') return false;
    if (pressed.has('watch') && !(r.health.level === 'warn' || r.health.level === 'alert')) return false;
    if (pressed.has('noinv') && r.inventoryAt) return false;
    if (pressed.has('laptop') && r.kind !== 'laptop') return false;
    return true;
  }
  function apply() {
    const shown = rows.filter(matches);
    grid.setRows(shown, { keepSelection: true });
    main.querySelector('[data-slot="summary"]').textContent = `${count(shown.length, 'poste affiché', 'postes affichés')} sur ${int(rows.length)} · double-cliquez ou appuyez sur Entrée pour ouvrir la console.`;
  }
  function stats(list) {
    // Same counting as the Accueil: active computer accounts of the working OU, presence read less than 30 days ago.
    const active = list.rows.filter((r) => r.enabled !== false);
    const disabled = list.rows.length - active.length;
    const online = active.filter((r) => r.presence === 'online').length;
    const watch = list.rows.filter((r) => r.health.level === 'warn' || r.health.level === 'alert').length;
    const noinv = active.filter((r) => !r.inventoryAt).length;
    const tile = (icon, value, label, tone) => `<div class="ps-stat" data-tone="${tone}"><span class="ps-stat-ico">${ico(icon)}</span><b>${esc(formatNumber(value))}</b><span>${esc(label)}</span></div>`;
    const scope = list.scope ? ` · OU ${list.scope.label}` : '';
    main.querySelector('[data-slot="stats"]').innerHTML = `${tile('monitor', active.length, `${active.length > 1 ? 'postes actifs' : 'poste actif'}${scope}${disabled ? ` · ${count(disabled, 'désactivé', 'désactivés')}` : ''}`, 'accent')}
      ${tile('wifi', online, `${online > 1 ? 'répondent' : 'répond'} (relevé de moins de 30 jours)`, 'ok')}${tile('alert', watch, 'à surveiller', 'warn')}${tile('layers', noinv, `${noinv > 1 ? 'postes actifs' : 'poste actif'} sans inventaire`, 'off')}`;
    bar.setFacets(FACETS.map((f) => ({ id: f.id, label: f.label, pressed: pressed.has(f.id),
      count: f.id === 'online' ? online : f.id === 'watch' ? watch : f.id === 'noinv' ? noinv : list.rows.filter((r) => r.kind === 'laptop').length })));
  }
  async function load(text) {
    grid.setLoading(true);
    try {
      const list = await ctx.call('poste.list', { text: text || null, limit: 1000 });
      if (!alive) return;
      rows = list.rows;
      apply();
      if (!text) stats(list);
      main.querySelector('[data-slot="summary"]').dataset.engine = list.summary;
    } catch (err) {
      console.error(err);
      if (!alive) return;
      grid.setError(errorText(err, 'Liste indisponible.'), { retry: () => load(text) });
      main.querySelector('[data-slot="stats"]').innerHTML = failure(err, { retry: null });
    }
  }
  const search = debounce(() => load(searchInput.value.trim()), 220);
  searchInput.addEventListener('input', search);
  searchInput.addEventListener('keydown', async (e) => {
    if (e.key !== 'Enter') return;
    e.preventDefault();
    // Reads the list for the text typed so far (the debounced search may not have run yet), then opens its first row.
    await load(searchInput.value.trim());
    const first = grid.getVisibleRows?.()[0];
    if (first && alive) open(first);
  });
  // The option of Domenia 1 (« lire aussi l’utilisateur console ») is a local preference of the application.
  ctx.call('poste.host').then((host) => {
    if (!alive || !host) return;
    option.checked = host.openReadsConsole === true;
    option.disabled = false;
  }).catch((err) => console.error(err));
  option.addEventListener('change', async () => {
    try {
      await ctx.call('poste.option.set', { name: 'openReadsConsole', value: option.checked });
      toast(option.checked ? 'À l’ouverture d’un poste depuis la liste : un ping, puis l’utilisateur connecté.' : 'À l’ouverture d’un poste depuis la liste : un ping seulement.', { tone: 'info' });
    } catch (err) {
      option.checked = !option.checked;
      toast(errorText(err), { tone: 'alert' });
    }
  });
  const recentsHost = main.querySelector('[data-slot="recents"]');
  recentsHost.innerHTML = RECENTS.length
    ? `<span class="ps-recents-label">Ouverts récemment${NBSP}:</span>${RECENTS.map((r) => `<a class="chip ps-recent" href="#/poste?dn=${encodeURIComponent(r.dn)}&verifier=1">${ico('monitor')}${esc(r.name)}</a>`).join('')}`
    : `<span class="ps-recents-label">Astuce${NBSP}: tapez le début du nom puis Entrée pour ouvrir le premier poste trouvé.</span>`;
  load('');
  revealCards(main);
  requestAnimationFrame(() => searchInput.focus({ preventScroll: true }));
  return () => {
    alive = false;
    grid.destroy();
    bar.destroy?.();
  };
}

/** Side panel of an open console: the workstations of the working OU, to switch without leaving the screen. */
export function openSwitcher(state) {
  const body = document.createElement('div');
  body.className = 'poste-drw ps-switcher';
  body.innerHTML = `<label class="ps-search sm"><span class="visually-hidden">Rechercher un poste</span>${ico('search')}<input class="input" type="search" data-search placeholder="Nom, utilisateur, site…" autocomplete="off"></label><div class="ps-switch-list" data-list aria-busy="true">${skLines('w85', 'w70', 'w85', 'w55', 'w70')}</div>`;
  const panel = openDrawer({ title: 'Postes de l’OU de travail', subtitle: 'Liste locale, aucune requête au poste', icon: 'monitor', side: 'left', key: 'poste.switcher', width: 400, minWidth: 320, maxWidth: 640, body });
  const list = body.querySelector('[data-list]');
  const input = body.querySelector('[data-search]');
  let rows = [];
  const paint = () => {
    const text = input.value.trim().toLowerCase();
    const shown = rows.filter((r) => !text || `${r.name} ${r.user?.name ?? ''} ${r.site ?? ''}`.toLowerCase().includes(text)).slice(0, 200);
    list.removeAttribute('aria-busy');
    list.innerHTML = shown.length ? shown.map((r) => `<a class="ps-switch-row${r.dn === state.dn ? ' current' : ''}" href="#/poste?dn=${encodeURIComponent(r.dn)}&verifier=1" data-dn="${esc(r.dn)}">
      <span class="ps-dot" data-tone="${esc(PRESENCE[r.presence]?.tone ?? 'off')}" aria-hidden="true"></span><span class="ps-switch-name mono">${esc(r.name)}</span>
      <span class="ps-switch-user">${esc(r.user?.name ?? '—')}</span>${r.inventoryAt && r.health.points ? `<span class="chip ${esc(r.health.level)}">${int(r.health.points)}</span>` : ''}</a>`).join('')
      : empty({ icon: 'search', title: 'Aucun poste', text: 'Aucun poste ne correspond à la recherche.' });
  };
  state.call('poste.list', { limit: 1000 }).then((r) => {
    rows = r.rows;
    paint();
    // The open workstation is shown in the middle of the list (the list is long, sorted by name).
    list.querySelector('.current')?.scrollIntoView({ block: 'center' });
  }).catch((err) => { list.innerHTML = failure(err, { retry: null }); });
  input.addEventListener('input', paint);
  list.addEventListener('click', (e) => {
    const a = e.target instanceof Element ? e.target.closest('a[data-dn]') : null;
    if (!a) return;
    const row = rows.find((r) => r.dn === a.dataset.dn);
    if (row) rememberRecent(row);
    panel.close();
  });
  setTimeout(() => input.focus(), 60);
  return panel;
}

export { toast };
