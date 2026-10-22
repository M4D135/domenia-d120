// Rechercher · the result card: a slim header (history of the list, title, perimeter with its parent, freshness, counter),
// one toolbar line inside the grid bar (commands with one main action, « Filtres et options » and the column sets), the
// panel « Actions, filtres et vues » folded by default (quick filters, criteria chips with their scope, type of the OU
// list, scope of exports and surveys, checks on click, revalidation), one-line notices with their details folded, the
// virtual grid with three column sets shown only when the rows have such data, a single empty-state zone with its next
// steps, and the footer (explicit continuation, completeness). Before any read, a launchpad: recent searches, ready-made
// views, syntax examples. Domenia 1 RCH-040 to RCH-077, RCH-095, RCH-123 to RCH-128.
import { glyph } from '../../kit/glyphs.js';
import { createGrid } from '../../kit/grid.js';
import { createFilterBar } from '../../kit/filterbar.js';
import { createDnBreadcrumb } from '../../kit/breadcrumb.js';
import { openMenu } from '../../kit/menu.js';
import { pill } from '../../kit/status.js';
import { freshness, startFreshness, touchFreshness } from '../../kit/freshness.js';
import { highlight, readLayout, writeLayout, debounce } from '../../kit/util.js';
import { inkFollow, announce, relTime, countUp } from '../../ui.js';
import {
  esc, fold, int, count, quote, COLON, NBSP, KINDS, TYPES, typeLabel, ageText, emptyState, dateText, leafOf, parentDn, associatedAccount,
} from './text.js';

export { expandAssociationColumns } from './text.js';

const SETS = [
  { id: 'mixed', label: 'Mixte', icon: 'layers', tip: 'Colonnes utiles à une liste mêlant comptes et postes' },
  { id: 'users', label: 'Utilisateurs', icon: 'user', tip: 'Colonnes des comptes : ni console ni système' },
  { id: 'computers', label: 'Postes', icon: 'monitor', tip: 'Colonnes des postes : présence, console, association, système ; pas de courriel' },
];

const STATE_OPTIONS = [
  { value: 'active', label: 'Actif', tone: 'ok' },
  { value: 'locked', label: 'Verrouillé', tone: 'alert' },
  { value: 'lockCheck', label: 'Verrouillage à vérifier', tone: 'warn' },
  { value: 'expired', label: 'Mot de passe expiré', tone: 'warn' },
  { value: 'disabled', label: 'Désactivé', tone: 'off' },
  { value: 'group', label: 'Groupe', tone: 'info' },
  { value: 'ou', label: 'Unité d’organisation', tone: 'off' },
];
const PRESENCE_OPTIONS = [
  { value: 'online', label: 'En ligne', tone: 'ok' },
  { value: 'noReply', label: 'Sans réponse au ping', tone: 'warn' },
  { value: 'error', label: 'Erreur de ping', tone: 'alert' },
  { value: 'unknown', label: 'Non vérifié', tone: 'off' },
];
const KIND_OPTIONS = Object.entries(KINDS).map(([value, k]) => ({ value, label: k.label }));
const VERDICT_TONE = { Correspond: 'ok', Inconnu: 'off', 'Ne correspond pas': 'info' };

// Quick filters of the list (local, never a read). Flags filter the rows given to the grid; presence filters its column.
const FACETS = [
  { id: 'f_locked', label: 'Verrouillés', tone: 'alert', kinds: ['user'], test: (r) => r.flags.locked },
  { id: 'f_disabled', label: 'Désactivés', tone: 'off', kinds: ['user', 'computer'], test: (r) => r.flags.disabled },
  { id: 'f_expired', label: 'Mot de passe expiré', tone: 'warn', kinds: ['user'], test: (r) => r.flags.passwordExpired },
  { id: 'f_inactive', label: 'Inactifs 90 j', tone: 'warn', kinds: ['user', 'computer'], test: (r) => r.flags.inactive },
  { id: 'f_never', label: 'Jamais connectés', tone: 'info', kinds: ['user', 'computer'], test: (r) => r.flags.neverLoggedOn },
  { id: 'f_admin', label: 'Comptes d’administration', tone: 'info', kinds: ['user', 'group'], test: (r) => r.flags.admin },
  { id: 'p_online', label: 'En ligne', tone: 'ok', kinds: ['computer'], presence: 'online', test: (r) => r.presence?.state === 'online' },
  { id: 'p_noReply', label: 'Sans réponse', tone: 'warn', kinds: ['computer'], presence: 'noReply', test: (r) => r.presence?.state === 'noReply' },
  { id: 'p_error', label: 'Erreur de ping', tone: 'alert', kinds: ['computer'], presence: 'error', test: (r) => r.presence?.state === 'error' },
  { id: 'p_unknown', label: 'Non vérifiés', tone: 'off', kinds: ['computer'], presence: 'unknown', test: (r) => r.presence?.state === 'unknown' },
];
const FLAG_FACETS = FACETS.filter((f) => !f.presence);

const SYNTAX = [
  { text: 'utilisateur: martin', label: 'Un compte', icon: 'user', tip: 'Préfixe utilisateur:, user: ou u:' },
  { text: 'poste: PC-PAR', label: 'Un poste', icon: 'monitor', tip: 'Préfixe poste:, pc:, machine: ou ordinateur:' },
  { text: 'groupe: GG-Support', label: 'Un groupe', icon: 'group', tip: 'Préfixe groupe:, group: ou g:' },
  { text: 'mail: camille', label: 'Un courriel', icon: 'file', tip: 'Préfixe mail:, email: ou courriel:' },
  { text: '*bernard', label: 'Joker en tête', icon: 'search', tip: 'Sous-chaîne sans index : plus lent' },
  { text: '10.10.1.20', label: 'Une adresse IP', icon: 'wifi', tip: 'Relevés locaux, sans scan réseau' },
];

// ---------- Columns ----------

const kindIcon = (k) => glyph(KINDS[k]?.icon ?? 'object', 'rch-k-ico');

function nameHtml(row, needle) {
  const label = needle ? highlight(row.name, needle) : esc(row.name);
  const admin = row.flags?.admin ? `<span class="rch-badge admin" data-tip="Compte d’administration (adminCount ou nommage adm-)">${glyph('shield')}Admin</span>` : '';
  const cached = row._cached ? `<span class="rch-badge cached" data-tip="${esc(`Ligne de la base locale${row._cachedAt ? ` du ${dateText(row._cachedAt)}` : ''}, remplacée par la lecture de l’annuaire en cours`)}">base locale</span>` : '';
  const fresh = row._new ? '<span class="rch-badge fresh" data-tip="Trouvé par la revérification de la liste">nouveau</span>' : '';
  const display = row.display && row.display !== row.name ? `<span class="rch-sub">${needle ? highlight(row.display, needle) : esc(row.display)}</span>` : '';
  return `<span class="rch-name-cell"><span class="rch-name">${label}</span>${display}${admin}${fresh}${cached}</span>`;
}

function presenceHtml(row) {
  const p = row.presence;
  if (!p) return '';
  const tone = { online: 'ok', noReply: 'warn', error: 'alert' }[p.state] ?? 'off';
  const age = p.checkedAt ? ageText(p.checkedAt) : '';
  const tip = `${p.detail}${p.checkedAt ? ` Relevé ${relTime(p.checkedAt) ?? ''}.` : ''}`;
  return `<span class="rch-presence ${tone}${row._pending ? ' pending' : ''}" data-tip="${esc(tip)}"><span class="rch-dot${p.state === 'online' ? ' pulse' : ''}"></span>${esc(p.label)}${age ? `<span class="rch-age">${esc(age)}</span>` : ''}</span>`;
}

/** Console user; without any observation, the remembered association shows as « compte (historique) » (RCH-081). */
function consoleText(row) {
  const c = row.console;
  if (c?.state === 'seen') return c.user ?? c.label;
  if ((!c || c.state === 'unknown') && row.association) return `${associatedAccount(row) || row.association.label} (historique)`;
  return c?.label ?? '';
}

function consoleHtml(row) {
  const c = row.console;
  if (c?.state === 'seen') return `<span class="rch-console seen" data-tip="${esc(`Session à la console${c.at ? ` relevée ${relTime(c.at) ?? ''}` : ''}. Les sessions RDP ne sont pas recensées.`)}">${glyph('user')}${esc(c.user ?? c.label)}</span>`;
  if ((!c || c.state === 'unknown') && row.association) {
    const a = row.association;
    return `<span class="rch-console history" data-tip="${esc(`Aucune observation de session. Association mémorisée${COLON}${a.source} (${a.qualification}). ${a.note}`)}">${glyph('history')}${esc(associatedAccount(row) || a.label)}<small>historique</small></span>`;
  }
  if (!c) return '';
  return `<span class="rch-console ${esc(c.state)}">${esc(c.label)}</span>`;
}

function associationHtml(row) {
  const a = row.association;
  if (!a) return '';
  const tone = a.qualification === 'Déclaré' ? 'info' : 'off';
  return `<span class="rch-assoc" data-tip="${esc(`${a.source} · ${a.note}`)}">${esc(a.label)}<span class="rch-qual ${tone}">${esc(a.qualification)}</span></span>`;
}

/** What the rows hold: a column whose data no row has is not shown, whatever the choice of « Colonnes… » (RCH-061). */
export function contentOf(rows) {
  const has = (test) => rows.some(test);
  const computer = has((r) => r.kind === 'computer');
  return {
    mixed: new Set(rows.map((r) => r.kind)).size > 1,
    computer,
    userOrComputer: computer || has((r) => r.kind === 'user'),
    group: has((r) => r.kind === 'group'),
    login: has((r) => (r.kind === 'computer' ? !!associatedAccount(r) : !!r.login)),
    mail: has((r) => !!r.mail),
    upn: has((r) => !!r.upn),
    display: has((r) => !!r.display && r.display !== r.name),
    description: has((r) => !!r.description),
  };
}

/** Column definitions; each set shows its own default columns, every column stays available when the rows have such data. */
export function columnsFor(set, mode = {}, content = null) {
  const show = {
    mixed: ['kind', 'name', 'state', 'presence', 'login', 'container'],
    users: ['kind', 'name', 'login', 'state', 'lastLogon', 'mail'],
    computers: ['name', 'console', 'association', 'presence', 'state', 'os'],
  }[set] ?? [];
  const order = [...show];
  if (mode.address) order.splice(order.indexOf('name') + 1, 0, 'address', 'addressSeen');
  if (mode.verdict) order.splice(order.indexOf('name') + 1, 0, 'verdict');
  const visible = new Set(order);
  // Address searches and local queries list workstations only: the type column would repeat « Poste » on every row.
  if (mode.address) { visible.delete('container'); visible.delete('os'); visible.delete('login'); visible.delete('kind'); }
  if (mode.verdict) { visible.delete('container'); visible.delete('login'); visible.delete('kind'); }
  const c = content ?? { mixed: true, computer: true, userOrComputer: true, group: true, login: true, mail: true, upn: true, display: true, description: true };
  const applies = {
    kind: c.mixed, login: c.login, console: c.computer, consoleState: c.computer, presence: c.computer, os: c.computer,
    address: c.computer, addressSeen: c.computer, association: c.userOrComputer, assocSource: c.userOrComputer, assocQual: c.userOrComputer,
    lastLogon: c.userOrComputer, mail: c.mail, upn: c.upn, display: c.display, description: c.description, groupScope: c.group, members: c.group,
  };
  const needle = mode.needle ? fold(mode.needle) : '';
  const col = (x) => ({ ...x, hidden: !x.required && !visible.has(x.id) });
  const rank = (x) => { const at = order.indexOf(x.id); return at < 0 ? 1000 : at; };
  return list().filter((x) => applies[x.id] !== false).map((x, n) => ({ x, n })).sort((a, b) => rank(a.x) - rank(b.x) || a.n - b.n).map((e) => e.x);
  function list() { return [
    col({ id: 'kind', label: 'Type', type: 'enum', options: KIND_OPTIONS, width: 64, minWidth: 48, get: (r) => r.kind, html: (v, r) => `<span class="rch-kind ${esc(v)}" data-tip="${esc(r.kindLabel)}">${kindIcon(v)}<span class="visually-hidden">${esc(r.kindLabel)}</span></span>`, csv: (v, r) => r.kindLabel, format: (v, r) => r.kindLabel }),
    col({ id: 'name', label: 'Nom', required: true, width: 210, get: (r) => r.name, format: (v, r) => `${r.name}${r.display && r.display !== r.name ? ` ${r.display}` : ''}`, html: (v, r) => nameHtml(r, needle), csv: (v, r) => r.name }),
    col({ id: 'display', label: 'Nom affiché', width: 190, get: (r) => r.display ?? '' }),
    col({ id: 'console', label: 'Utilisateur connecté (console)', width: 200, get: (r) => consoleText(r), html: (v, r) => consoleHtml(r) }),
    col({ id: 'consoleState', label: 'Vérification utilisateur', width: 150, get: (r) => ({ seen: 'Session vue', none: 'Aucune session', denied: 'Compte distant refusé', unknown: r.association ? 'Historique' : 'Non déterminé' }[r.console?.state] ?? (r.association ? 'Historique' : '')) }),
    col({ id: 'freshness', label: 'Fraîcheur AD', type: 'date', width: 130, get: (r) => r.readAt, tip: 'Date de la lecture de l’annuaire qui a produit la ligne' }),
    col({ id: 'login', label: 'Compte', width: 118, mono: true, get: (r) => (r.kind === 'computer' ? associatedAccount(r) : r.login ?? ''), tip: 'Compte de connexion ; pour un poste, le compte associé' }),
    col({ id: 'upn', label: 'UPN / DNS', width: 230, mono: true, get: (r) => r.upn ?? '' }),
    col({ id: 'association', label: 'Association mémorisée', width: 210, get: (r) => r.association?.label ?? '', html: (v, r) => associationHtml(r) }),
    col({ id: 'assocSource', label: 'Source lien', width: 200, get: (r) => r.association?.source ?? '' }),
    col({ id: 'assocQual', label: 'Qualification', width: 120, get: (r) => r.association?.qualification ?? '' }),
    col({ id: 'presence', label: 'Présence', tip: 'Présence réseau : dernier ping relevé, daté', type: 'enum', options: PRESENCE_OPTIONS, width: 150, get: (r) => r.presence?.state ?? null, html: (v, r) => presenceHtml(r), csv: (v, r) => (r.presence ? `${r.presence.label}${r.presence.checkedAt ? ` (${dateText(r.presence.checkedAt)})` : ''}` : '') }),
    col({ id: 'state', label: 'État', type: 'enum', options: STATE_OPTIONS, width: 128, get: (r) => r.state.key, html: (v, r) => pill(r.state.tone, r.state.label, { size: 'sm' }), csv: (v, r) => r.state.label }),
    col({ id: 'os', label: 'Système', width: 170, get: (r) => r.os ?? '', tip: 'Version regroupée (operatingSystem et operatingSystemVersion)' }),
    col({ id: 'lastLogon', label: 'Dernière connexion', type: 'date', width: 150, get: (r) => r.lastLogon, tip: 'lastLogonTimestamp, répliqué à 14 jours près' }),
    col({ id: 'mail', label: 'Mail', width: 220, get: (r) => r.mail ?? '' }),
    col({ id: 'description', label: 'Description', width: 230, get: (r) => r.description ?? '' }),
    col({ id: 'changed', label: 'Modifié', type: 'date', width: 140, get: (r) => r.changed }),
    col({ id: 'created', label: 'Créé', type: 'date', width: 140, get: (r) => r.created }),
    col({ id: 'container', label: 'Emplacement', width: 180, get: (r) => r.container.split(`${NBSP}› `).slice(1).join(' › ') || r.container, tip: 'OU ou conteneur de l’objet' }),
    col({ id: 'dn', label: 'Chemin complet', width: 420, mono: true, get: (r) => r.dn }),
    col({ id: 'groupScope', label: 'Étendue du groupe', width: 170, get: (r) => r.group?.scopeLabel ?? '' }),
    col({ id: 'members', label: 'Membres directs', type: 'number', width: 120, get: (r) => (r.group ? r.group.members : null) }),
    col({ id: 'address', label: 'Adresse relevée', width: 160, mono: true, get: (r) => (mode.mac ? r.address?.mac : r.address?.ip) ?? '', tip: 'Adresse lue dans les relevés locaux, jamais relue dans l’annuaire' }),
    col({ id: 'addressSeen', label: 'Relevée le', type: 'date', dateStyle: 'datetime', width: 150, get: (r) => r.address?.observedAt ?? null }),
    col({ id: 'verdict', label: 'Résultat de la requête', width: 250, get: (r) => r.verdict ?? '', html: (v) => { const [label, value] = String(v ?? '').split(' · '); return label ? `${pill(VERDICT_TONE[label] ?? 'off', label, { size: 'sm' })}<span class="rch-verdict-v">${esc(value ?? '')}</span>` : ''; } }),
    col({ id: 'guid', label: 'GUID', width: 290, mono: true, get: (r) => r.id }),
  ]; }
}

/**
 * @param {HTMLElement} host
 * @param {any} ctx
 * @param {object} o  callbacks of the page
 */
export function createResults(host, ctx, o) {
  const pref = readLayout('rechercher.results') ?? {};
  const st = {
    set: SETS.some((s) => s.id === pref.set) ? pref.set : 'mixed',
    toolsOpen: false,
    result: null,
    rows: [],
    facets: new Set(),
    presence: null,
    quick: '',
    scopeMode: 'visible',
    undo: [],
    mode: {},
    content: null,
    empty: null,
    cached: false,
  };
  let ready = false;
  let applying = false;

  host.innerHTML = `<div class="rch-res-in">
    <header class="rch-res-head">
      <nav class="rch-nav" aria-label="Historique des listes">
        <button class="btn ghost icon sm" type="button" data-nav="back" aria-label="Liste précédente" aria-keyshortcuts="Alt+ArrowLeft" data-tip="Liste précédente (Alt ←)" disabled>${glyph('chevronLeft')}</button>
        <button class="btn ghost icon sm" type="button" data-nav="forward" aria-label="Liste suivante" aria-keyshortcuts="Alt+ArrowRight" data-tip="Liste suivante (Alt →)" disabled>${glyph('chevronRight')}</button>
        <button class="btn ghost icon sm" type="button" data-nav="list" aria-haspopup="menu" aria-expanded="false" aria-label="Étapes de l’historique" data-tip="Étapes de l’historique" disabled>${glyph('history')}</button>
      </nav>
      <div class="rch-res-titles">
        <div class="rch-res-titlerow">
          <span class="rch-res-kind" data-kind="none">${glyph('search')}<span>Résultats</span></span>
          <h2 class="rch-res-title">Prêt à chercher</h2>
        </div>
        <p class="rch-res-scopeline"><span class="rch-res-scope"></span><span class="rch-res-crumbs" hidden></span><span class="rch-res-fresh"></span><span class="rch-res-mode k-pill sm info" hidden>${glyph('check')}Portée${COLON}lignes sélectionnées</span></p>
      </div>
      <div class="rch-count"><b class="rch-count-n num" aria-hidden="true">0</b><span class="rch-count-t" aria-hidden="true">ligne</span><span class="visually-hidden rch-count-sr"></span></div>
    </header>
    <div class="rch-cmdrow"><div class="rch-actions"></div></div>
    <div class="rch-notices" aria-live="polite"></div>
    <div class="rch-gridwrap"><div class="rch-grid"></div><div class="rch-launch"></div></div>
    <footer class="rch-res-foot" hidden>
      <div class="rch-more"></div>
      <p class="rch-counter"></p>
      <button class="btn ghost icon sm rch-absence" type="button" aria-label="Ce que la liste ne prouve pas" data-tip="">${glyph('info')}</button>
    </footer>
  </div>`;

  const title = host.querySelector('.rch-res-title');
  const scopeEl = host.querySelector('.rch-res-scope');
  const crumbsEl = host.querySelector('.rch-res-crumbs');
  const freshEl = host.querySelector('.rch-res-fresh');
  const kindChip = host.querySelector('.rch-res-kind');
  const kindEl = kindChip.querySelector('span');
  const countN = host.querySelector('.rch-count-n');
  const countT = host.querySelector('.rch-count-t');
  const notices = host.querySelector('.rch-notices');
  const launch = host.querySelector('.rch-launch');
  const gridHost = host.querySelector('.rch-grid');
  const foot = host.querySelector('.rch-res-foot');
  const moreEl = host.querySelector('.rch-more');
  const counterEl = host.querySelector('.rch-counter');
  const absenceEl = host.querySelector('.rch-absence');
  const noticeMap = new Map();
  let crumbs = null;

  // ---------- Grid ----------

  const grid = createGrid(gridHost, {
    key: `rechercher.${st.set}`,
    label: 'Résultats de la recherche',
    rowId: (r) => r.id,
    selection: 'multi',
    height: 'fill',
    columns: columnsFor(st.set, {}, contentOf([])),
    quickPlaceholder: 'Filtrer les lignes chargées…',
    empty: { icon: 'search', title: '', text: '' },
    onActivate: (row) => o.onOpen(row),
    onActiveChange: (row) => o.onActive(row),
    onSelectionChange: (rows) => { o.onSelection(rows); paintFoot(); },
    selectionActions: (rows) => o.selectionActions(rows),
    onExport: (csv, info) => o.onExport?.(info.scope),
    onFilterChange: (info) => onFilter(info),
    onLoadMore: () => { const c = st.result?.continuation; if (c?.allowed) o.onMore(c.nextLimit); },
  });
  grid.el.classList.add('rch-k-grid');

  // Toolbar line inside the grid bar: commands, « Filtres et options », column sets (one line instead of three bands).
  const toolbar = document.createElement('div');
  toolbar.className = 'rch-toolbar';
  toolbar.innerHTML = `<div class="rch-undo-slot"></div>
    <button class="btn subtle sm rch-tools-toggle" type="button" aria-expanded="${st.toolsOpen}" aria-controls="rch-tools">${glyph('sliders')}<span>Filtres et options</span><span class="rch-tools-n" hidden></span>${glyph('chevronDown', 'rch-tools-chev')}</button>
    <div class="segmented rch-sets" role="group" aria-label="Jeu de colonnes"><span class="thumb" aria-hidden="true"></span>
      ${SETS.map((s) => `<button type="button" data-set="${s.id}" aria-pressed="${s.id === st.set}" aria-label="Vue ${esc(s.label)}" data-tip="${esc(s.tip)}">${glyph(s.icon)}<span>${esc(s.label)}</span></button>`).join('')}
    </div>`;
  grid.slot?.append(toolbar);
  const undoSlot = toolbar.querySelector('.rch-undo-slot');
  const toolsToggle = toolbar.querySelector('.rch-tools-toggle');
  const toolsCount = toolbar.querySelector('.rch-tools-n');

  // The panel « Actions, filtres et vues » of Domenia 1, folded by default so it never covers the rows (RCH-071).
  const tools = document.createElement('section');
  tools.className = 'rch-tools';
  tools.id = 'rch-tools';
  tools.setAttribute('aria-label', 'Filtres et options de la liste');
  tools.hidden = !st.toolsOpen;
  tools.innerHTML = `<div class="rch-fbar"></div>
    <div class="rch-tools-row">
      <div class="rch-opt rch-opt-type" hidden><span class="rch-opt-l">Type de la liste</span>
        <div class="segmented rch-ltypes" role="group" aria-label="Type d’objet de la liste de l’OU"><span class="thumb" aria-hidden="true"></span>
          ${TYPES.map((t) => `<button type="button" data-ltype="${t.id}" aria-pressed="${t.id === 'all'}" data-tip="${esc(t.id === 'all' ? 'Tous les types' : t.label)} : relit l’OU avec ce type">${glyph(t.icon)}<span>${esc(t.id === 'ous' ? 'OU et conteneurs' : t.label)}</span></button>`).join('')}
        </div></div>
      <div class="rch-opt"><span class="rch-opt-l">Portée des exports et relevés</span>
        <div class="segmented rch-scope-mode" role="group" aria-label="Portée des exports et des relevés"><span class="thumb" aria-hidden="true"></span>
          <button type="button" data-mode="visible" aria-pressed="true">Liste affichée</button><button type="button" data-mode="selected" aria-pressed="false">Sélection</button>
        </div></div>
      <div class="rch-opt rch-opt-click"><span class="rch-opt-l">Vérifier au clic</span>
        <label class="rch-check"><input type="checkbox" data-click="ping"><span>Un ping du poste cliqué</span></label>
        <label class="rch-check sub"><input type="checkbox" data-click="console"><span>+ utilisateur connecté</span></label></div>
      <div class="rch-opt"><span class="rch-opt-l">Revérification</span>
        <label class="rch-check"><input class="switch" type="checkbox" role="switch" data-reval><span class="rch-reval-t">Toutes les 3 minutes</span></label></div>
    </div>`;
  grid.el.querySelector('.k-gframe')?.before(tools);
  const fbarHost = tools.querySelector('.rch-fbar');
  const typeOpt = tools.querySelector('.rch-opt-type');

  // One empty-state zone over the rows, with its next steps (RCH-051).
  const emptyEl = document.createElement('div');
  emptyEl.className = 'rch-empty';
  emptyEl.hidden = true;
  grid.el.querySelector('.k-gframe')?.append(emptyEl);

  const inks = [
    inkFollow(toolbar.querySelector('.rch-sets'), 'button', 'button[aria-pressed="true"]'),
    inkFollow(tools.querySelector('.rch-scope-mode'), 'button', 'button[aria-pressed="true"]'),
    inkFollow(tools.querySelector('.rch-ltypes'), 'button', 'button[aria-pressed="true"]'),
  ];

  // ---------- Row menu: the page owns it, so it never repeats the generic entries of the kit ----------

  function openRowMenu(at, rows, row) {
    const items = o.contextMenu({ rows, row });
    if (items?.length) openMenu(at, items, { label: 'Actions de la ligne', restoreFocus: grid.el.querySelector('.k-gscroll') });
  }
  gridHost.addEventListener('contextmenu', (e) => {
    const rowEl = e.target instanceof Element ? e.target.closest('.k-gbody .k-gr') : null;
    if (!rowEl || rowEl.classList.contains('k-skel')) return;
    e.preventDefault();
    e.stopPropagation();
    const row = grid.getVisibleRows()[Number(rowEl.dataset.pos)];
    if (!row) return;
    if (!grid.getSelectedIds().includes(row.id)) grid.select([row.id]);
    openRowMenu(e, grid.getSelection(), row);
  }, true);
  gridHost.addEventListener('keydown', (e) => {
    if (!(e.key === 'ContextMenu' || (e.key === 'F10' && e.shiftKey))) return;
    const scroller = grid.el.querySelector('.k-gscroll');
    if (e.target !== scroller || (scroller.getAttribute('aria-activedescendant') ?? '').includes('-h-')) return;
    const row = grid.getActiveRow();
    if (!row) return;
    e.preventDefault();
    e.stopPropagation();
    if (!grid.getSelectedIds().includes(row.id)) grid.select([row.id]);
    const cell = scroller.querySelector('.k-gr.is-cur') ?? scroller;
    const r = cell.getBoundingClientRect();
    openRowMenu({ x: r.left + 24, y: r.bottom - 4 }, grid.getSelection(), row);
  }, true);

  // Verify on click needs to know a pointer chose the row (never the keyboard nor a restoration).
  let lastPointer = 0;
  gridHost.addEventListener('pointerdown', (e) => { if (e.target instanceof Element && e.target.closest('.k-gbody .k-gr')) lastPointer = Date.now(); }, true);

  // ---------- Filters ----------

  const visibleRows = () => (st.facets.size ? st.rows.filter((r) => FLAG_FACETS.every((f) => !st.facets.has(f.id) || f.test(r))) : st.rows);

  function feedGrid({ keepSelection = true, keepScroll = true } = {}) {
    grid.setRows(visibleRows(), { hasMore: false, keepSelection, keepScroll });
  }

  function onFilter(info) {
    if (!ready || applying) return;
    const before = { quick: st.quick, facets: [...st.facets], presence: st.presence };
    const quick = info.quick ?? '';
    const changed = quick !== st.quick;
    st.quick = quick;
    // The presence quick filters follow the presence column filter of the grid (its filter row, « Effacer les filtres »).
    const cols = info.columns ?? {};
    st.presence = PRESENCE_OPTIONS.some((p) => p.value === cols.presence) ? cols.presence : null;
    if (changed) pushUndo(before);
    paintCriteria();
  }

  // Presentation undo for the filters of the list (Domenia 1 RCH-049; the grid undoes its own layout with Ctrl Z).
  const pushUndo = debounce((state) => {
    st.undo.push(state);
    if (st.undo.length > 10) st.undo.shift();
    paintUndo();
  }, 900);

  function paintUndo() {
    const last = st.undo.at(-1);
    undoSlot.innerHTML = last ? `<button class="chip rch-undo" type="button" data-tip="Rétablit le filtre précédent de la liste ; n’annule jamais une lecture ni une écriture">${glyph('undo')}Filtre précédent</button>` : '';
  }
  undoSlot.addEventListener('click', (e) => {
    if (!(e.target instanceof Element) || !e.target.closest('.rch-undo')) return;
    const last = st.undo.pop();
    if (!last) return;
    applyFilters(last);
    paintUndo();
    announce('Filtre précédent rétabli, sans nouvelle lecture.');
  });

  function applyFilters({ quick, facets, presence }) {
    st.facets = new Set((facets ?? []).filter((id) => FLAG_FACETS.some((f) => f.id === id)));
    st.presence = presence ?? null;
    applying = true;
    try {
      feedGrid();
      grid.setColumnFilter('presence', st.presence ?? '');
      grid.setQuickFilter(quick ?? '');
    } finally {
      applying = false;
    }
    st.quick = quick ?? '';
    paintCriteria();
  }

  function paintCriteria() {
    paintFacets();
    paintChips();
    paintCount();
    paintFoot();
    paintEmpty();
  }

  // ---------- Filter bar: facets and chips ----------

  const fbar = createFilterBar(fbarHost, {
    label: 'Critères de la liste',
    onToggle: (id, pressed) => toggleFacet(id, pressed),
    onRemove: (id) => removeChip(id),
    onClear: () => { applyFilters({ quick: '', facets: [], presence: null }); o.onClearCriteria?.(); },
  });

  function toggleFacet(id, pressed) {
    const before = { quick: st.quick, facets: [...st.facets], presence: st.presence };
    const facet = FACETS.find((f) => f.id === id);
    if (!facet) return;
    applying = true;
    try {
      if (facet.presence) {
        st.presence = pressed ? facet.presence : null;
        grid.setColumnFilter('presence', st.presence ?? '');
      } else {
        if (pressed) st.facets.add(id); else st.facets.delete(id);
        feedGrid();
      }
    } finally {
      applying = false;
    }
    st.undo.push(before);
    if (st.undo.length > 10) st.undo.shift();
    paintUndo();
    paintCriteria();
  }

  function removeChip(id) {
    if (id === 'local') { grid.setQuickFilter(''); st.quick = ''; paintCriteria(); }
    else if (id.startsWith('f_') || id.startsWith('p_')) toggleFacet(id, false);
    else o.onRemoveCriterion?.(id);
  }

  function paintFacets() {
    const kinds = new Set(st.rows.map((r) => r.kind));
    const list = FACETS.filter((f) => f.kinds.some((k) => kinds.has(k))).map((f) => ({
      id: f.id, label: f.label, tone: f.tone, count: st.rows.filter(f.test).length,
      pressed: f.presence ? st.presence === f.presence : st.facets.has(f.id),
    })).filter((f) => f.count > 0 || f.pressed);
    fbar.setFacets(list);
  }

  function activeCount() {
    return st.facets.size + (st.presence ? 1 : 0) + (st.quick ? 1 : 0);
  }

  function paintChips() {
    const r = st.result;
    const chips = [];
    if (r) {
      // The perimeter comes first (never removable); the criteria the operator can act on follow.
      const where = r.scope.mode === 'global' ? r.scope.chip.split(' · ')[0] : r.scope.wholeDomain ? 'Tout le domaine' : `${leafOf(r.scope.dn)} · ${r.scope.subtree ? 'sous-OU' : 'niveau direct'}`;
      chips.push({ id: 'scope', label: 'Périmètre', value: where, scope: r.kind === 'address' || r.kind === 'localQuery' ? 'Base locale' : 'Annuaire', removable: false, icon: r.scope.mode === 'global' ? 'domain' : 'ou' });
      if (r.type !== 'all' && (r.kind === 'browse' || r.kind === 'search')) chips.push({ id: 'type', label: 'Type', value: typeLabel(r.type), scope: 'Annuaire', removable: r.kind === 'browse', removeTip: 'Relit l’OU dans l’annuaire avec tous les types d’objets.' });
      if (r.match === 'contains') chips.push({ id: 'match', label: 'Correspondance', value: 'contient', scope: 'Annuaire', removable: false });
      if (r.view) chips.push({ id: 'query', label: r.kind === 'localQuery' ? 'Requête locale' : 'Requête', value: r.view.name, scope: r.kind === 'localQuery' ? 'Base locale' : 'Annuaire', removable: true, removeTip: 'Efface la liste de cette requête ; aucune autre lecture n’est lancée.' });
      if (r.kind === 'address') chips.push({ id: 'address', label: r.plan.address?.kind === 'mac' ? 'Adresse MAC' : 'Adresse IP', value: r.plan.address?.value ?? r.text, scope: 'Base locale', removable: false });
    }
    for (const f of FACETS) {
      const on = f.presence ? st.presence === f.presence : st.facets.has(f.id);
      if (on) chips.push({ id: f.id, label: f.presence ? 'Ping mémorisé' : 'Filtre rapide', value: f.label, scope: 'Liste chargée', removeTip: f.presence ? 'Retirer ce critère n’envoie aucun ping. Sans réponse ne prouve pas qu’un poste est éteint.' : 'Filtre local ; retirer ce critère n’appelle pas l’annuaire.' });
    }
    if (st.quick) chips.push({ id: 'local', label: 'Contient', value: st.quick, scope: 'Liste chargée', removeTip: 'Filtre local sur les lignes déjà chargées ; le retirer n’appelle pas l’annuaire.' });
    fbar.setChips(chips);
    const n = activeCount();
    toolsCount.hidden = n === 0;
    toolsCount.textContent = int(n);
    toolsToggle.dataset.tip = n ? `${count(n, 'filtre de la liste actif', 'filtres de la liste actifs')} : rien n’est relu` : 'Filtres rapides, critères, type de la liste et options';
  }

  // ---------- Header, notices, footer ----------

  // The animated figure stays out of the reading of a screen reader (it would say the values in between): the final value is
  // in a hidden text and announced once, after the list or its filter settled.
  let countSaid = '';
  const sayCount = debounce((text) => { if (text !== countSaid) { countSaid = text; announce(text); } }, 500);
  function paintCount() {
    const shown = grid.getVisibleRows().length;
    const total = st.rows.length;
    countUp(countN, shown, { duration: 600 });
    countT.textContent = `${shown >= 2 ? 'lignes' : 'ligne'}${shown !== total ? ` sur ${int(total)}` : ''}`;
    const said = `${count(shown, 'ligne', 'lignes')}${shown !== total ? ` sur ${int(total)}` : ''}`;
    host.querySelector('.rch-count-sr').textContent = said;
    if (st.result) sayCount(said);
    // The combination sentence is said when a criterion of the loaded list hides rows (Domenia 1 RCH-040).
    const summary = st.result && activeCount() ? `→ ${count(shown, 'ligne affichée', 'lignes affichées')} sur ${int(total)}` : '';
    fbar.setSummary(summary);
    host.querySelector('.rch-count').dataset.tip = summary ? 'Filtre appliqué aux seules lignes déjà chargées : rien n’est relu' : '';
  }

  /** Shows or replaces a notice band (id → { tone, icon, html, more, actions: [{id, label, icon, kind, primary}], dismiss }), or removes it with null. */
  // Notices never pile up above the grid: the three most important ones are shown (a running survey and a suspension first),
  // the others wait behind « +n messages », which opens them all.
  const NOTICE_MAX = 3;
  const NOTICE_RANK = { survey: 0, suspended: 0, write: 0, resume: 1, reval: 1, restore: 1, dns: 1, listcheck: 2, offer: 2, measures: 2 };
  let noticesOpen = false;
  function arrangeNotices() {
    const list = [...noticeMap.entries()].filter(([, el]) => !el.classList.contains('leaving'))
      .sort((a, b) => (NOTICE_RANK[a[0]] ?? 3) - (NOTICE_RANK[b[0]] ?? 3) || Number(b[1].dataset.at) - Number(a[1].dataset.at));
    list.forEach(([, el], n) => el.classList.toggle('folded', !noticesOpen && n >= NOTICE_MAX));
    const extra = Math.max(0, list.length - NOTICE_MAX);
    let more = notices.querySelector('.rch-notices-more');
    if (!extra) { more?.remove(); noticesOpen = false; return; }
    if (!more) {
      more = document.createElement('button');
      more.type = 'button';
      more.className = 'btn ghost sm rch-notices-more';
      more.addEventListener('click', () => { noticesOpen = !noticesOpen; arrangeNotices(); });
    }
    more.textContent = noticesOpen ? 'Réduire les messages' : `+${int(extra)} message${extra > 1 ? 's' : ''}`;
    more.setAttribute('aria-expanded', String(noticesOpen));
    notices.appendChild(more);
  }

  function setNotice(id, notice) {
    const prev = noticeMap.get(id);
    if (!notice) { if (prev) { prev.classList.add('leaving'); setTimeout(() => prev.remove(), 260); noticeMap.delete(id); arrangeNotices(); } return; }
    const el = document.createElement('div');
    el.className = `rch-notice ${notice.tone ?? 'info'}`;
    el.dataset.id = id;
    const more = notice.more ? `<details class="rch-note-more"><summary>Détails</summary><div class="rch-note-more-in">${notice.more}</div></details>` : '';
    el.innerHTML = `<span class="rch-notice-ico">${glyph(notice.icon ?? 'info')}</span><div class="rch-notice-body"><div class="rch-notice-main">${notice.html}</div>${more}</div>`
      + `<div class="rch-notice-acts">${(notice.actions ?? []).map((a) => `<button class="btn sm${a.primary ? ' accent' : ' subtle'}${a.pressed ? ' on' : ''}" type="button" data-act="${esc(a.id)}"${a.pressed !== undefined ? ` aria-pressed="${!!a.pressed}"` : ''}${a.kind === 'network' ? ' data-tip="Lecture réseau : part seulement sur ce clic"' : a.tip ? ` data-tip="${esc(a.tip)}"` : ''}>${a.icon ? glyph(a.icon) : ''}${esc(a.label)}${a.kind === 'network' ? '<span class="rch-net-dot" aria-hidden="true"></span>' : ''}</button>`).join('')}`
      + `${notice.dismiss ? `<button class="btn ghost icon sm rch-notice-x" type="button" data-act="dismiss" aria-label="Masquer ce message" data-tip="Masquer">${glyph('x')}</button>` : ''}</div>`;
    el.addEventListener('click', (e) => {
      const b = e.target instanceof Element ? e.target.closest('[data-act]') : null;
      if (!b) return;
      if (b.dataset.act === 'dismiss') { setNotice(id, null); return; }
      notice.run?.(b.dataset.act, b);
    });
    el.dataset.at = String(Date.now());
    if (prev) prev.replaceWith(el); else notices.appendChild(el);
    noticeMap.set(id, el);
    arrangeNotices();
  }

  /** Element of a notice, to update it in place (a running survey patches its counter, bar, button and details). */
  function noticeEl(id) { return noticeMap.get(id) ?? null; }

  /** Replaces the « Détails » of a notice in place; an open block stays open (the operator is reading it). */
  function setNoticeMore(id, html) {
    const el = noticeMap.get(id);
    if (!el) return;
    let more = el.querySelector('.rch-note-more');
    if (!html) { more?.remove(); return; }
    if (!more) {
      el.querySelector('.rch-notice-body').insertAdjacentHTML('beforeend', '<details class="rch-note-more"><summary>Détails</summary><div class="rch-note-more-in"></div></details>');
      more = el.querySelector('.rch-note-more');
    }
    const inner = more.querySelector('.rch-note-more-in');
    if (inner.innerHTML !== html) inner.innerHTML = html;
  }

  function paintFoot() {
    const r = st.result;
    foot.hidden = !r;
    if (!r) return;
    const c = r.continuation;
    moreEl.innerHTML = c.allowed
      ? `<button class="btn sm accent rch-more-next" type="button" data-more="${c.nextLimit}" data-tip="${esc(c.reason)}">${glyph('plus')}Charger la suite<span class="rch-more-n">+${int(c.page)}</span><span class="rch-net-dot" aria-hidden="true"></span></button>`
        + (c.jumpLimit ? `<button class="btn sm subtle rch-more-jump" type="button" data-more="${c.jumpLimit}" data-tip="${esc(c.jumpText ?? '')}${COLON}lit seulement les lignes suivantes, ${int(c.jumpLimit)} lignes en tout">Jusqu’à ${int(c.jumpLimit)}</button>` : '')
      : '';
    // The header gives the number of rows: the footer says plainly whether the list is complete, without any cut sentence.
    counterEl.className = `rch-counter${r.limitReached ? ' warn' : ''}`;
    counterEl.innerHTML = r.limitReached
      ? `${glyph('alert')}<span>${esc(c.allowed ? `Liste limitée à ${int(r.limit)} lignes : affinez ou chargez la suite.` : c.reason)}</span>`
      : `${glyph('check')}<span>${esc(`Liste complète dans ce périmètre (${count(r.loaded, 'résultat', 'résultats')}).`)}</span>`;
    const sel = grid.getSelection();
    const visible = grid.getVisibleRows();
    const shownIds = new Set(visible.map((v) => v.id));
    const selectedShown = sel.filter((s) => shownIds.has(s.id));
    absenceEl.dataset.tip = `${r.absence} ${scopeSentence(selectedShown.length, sel.length - selectedShown.length)}`;
  }

  function scopeSentence(selected, selectedHidden) {
    const r = st.result;
    const visible = grid.getVisibleRows().length;
    const note = r?.complete ? 'liste complète' : `liste limitée à ${int(r?.limit ?? 0)} lignes${COLON}les objets au-delà ne sont pas inclus`;
    if (st.scopeMode === 'selected') {
      let t = selected > 0 ? `Lignes sélectionnées${COLON}${count(selected, 'ligne', 'lignes')} sur ${count(visible, 'affichée', 'affichées')}`
        : 'Aucune ligne sélectionnée parmi les lignes affichées.';
      if (selectedHidden > 0) t += ` · ${count(selectedHidden, 'ligne sélectionnée masquée', 'lignes sélectionnées masquées')} par un filtre, exclue${selectedHidden > 1 ? 's' : ''}`;
      return `${t} · ${note}`;
    }
    const hidden = Math.max(0, st.rows.length - visible);
    return `Liste affichée${COLON}${count(visible, 'ligne', 'lignes')}${hidden ? ` · ${count(hidden, 'ligne chargée masquée', 'lignes chargées masquées')} par les filtres, exclue${hidden > 1 ? 's' : ''}` : ''} · ${note}`;
  }

  // ---------- Empty state ----------

  function paintEmpty() {
    let state = st.empty;
    if (!state && st.result) {
      const r = st.result;
      if (!st.rows.length) {
        state = emptyState(st.restored ? 'origin' : 'noresult', { query: r.kind === 'search' ? r.text : '', scope: r.scope.label, type: r.type, limit: r.limit, complete: r.complete,
          global: r.scope.mode === 'global', ou: r.kind === 'search' && r.scope.mode === 'global' && !r.scope.wholeDomain, match: r.match });
      } else if (!grid.getVisibleRows().length) state = emptyState('filter', { scope: r.scope.label, type: r.type, limit: r.limit, complete: r.complete });
    }
    emptyEl.hidden = !state;
    gridHost.classList.toggle('has-empty', !!state);
    if (!state) return;
    emptyEl.dataset.tone = state.tone ?? 'info';
    emptyEl.innerHTML = `<div class="rch-empty-in">
      <span class="rch-empty-art" aria-hidden="true">${glyph(state.icon)}</span>
      <h3>${esc(state.title)}</h3>
      <p>${esc(state.text)}</p>
      ${state.hint ? `<p class="rch-empty-hint">${glyph('info')}${esc(state.hint)}</p>` : ''}
      ${state.actions?.length ? `<div class="rch-empty-acts">${state.actions.map((a, n) => `<button class="btn sm${a.primary ? ' accent' : ''}" type="button" data-empty="${esc(a.id)}" data-j="${n}">${glyph(a.icon ?? 'play')}${esc(a.label)}${a.kind === 'network' ? '<span class="rch-net-dot" aria-hidden="true"></span>' : ''}</button>`).join('')}</div>` : ''}
    </div>`;
    emptyEl.querySelectorAll('[data-j]').forEach((x) => x.style.setProperty('--j', x.dataset.j));
  }
  emptyEl.addEventListener('click', (e) => {
    const b = e.target instanceof Element ? e.target.closest('[data-empty]') : null;
    if (!b) return;
    if (b.dataset.empty === 'clearFilters') { applyFilters({ quick: '', facets: [], presence: null }); grid.clearFilters?.(); announce('Filtres de la liste effacés, sans nouvelle lecture.'); return; }
    o.onEmptyAction?.(b.dataset.empty, st.result);
  });

  // ---------- Toolbar and tools panel ----------

  function setToolsOpen(on, user = false) {
    st.toolsOpen = on;
    tools.hidden = !on;
    toolsToggle.setAttribute('aria-expanded', String(on));
    if (on) { tools.classList.remove('in'); void tools.offsetWidth; tools.classList.add('in'); requestAnimationFrame(() => inks.forEach((i) => i.update())); }
    if (user) announce(on ? 'Filtres et options de la liste affichés.' : 'Filtres et options repliés.');
  }
  toolsToggle.addEventListener('click', () => setToolsOpen(!st.toolsOpen, true));

  moreEl.addEventListener('click', (e) => {
    const b = e.target instanceof Element ? e.target.closest('[data-more]') : null;
    if (b) o.onMore(Number(b.dataset.more));
  });
  tools.querySelector('.rch-scope-mode').addEventListener('click', (e) => {
    const b = e.target instanceof Element ? e.target.closest('[data-mode]') : null;
    if (!b) return;
    st.scopeMode = b.dataset.mode;
    tools.querySelectorAll('[data-mode]').forEach((x) => x.setAttribute('aria-pressed', String(x === b)));
    // The active scope is recalled in the header while the options stay folded (design review, tour 2).
    host.querySelector('.rch-res-mode').hidden = st.scopeMode !== 'selected';
    inks[1].update();
    paintFoot();
    o.onScopeMode?.(st.scopeMode);
    announce(st.scopeMode === 'selected' ? 'Portée des exports et relevés : lignes sélectionnées.' : 'Portée des exports et relevés : liste affichée.');
  });
  // Type of the list of an OU (RCH-018): a click reads the OU again with that type; the keyboard waits 300 ms.
  const typeChange = debounce((type) => o.onListType?.(type), 300);
  tools.querySelector('.rch-ltypes').addEventListener('click', (e) => {
    const b = e.target instanceof Element ? e.target.closest('[data-ltype]') : null;
    if (!b || b.getAttribute('aria-pressed') === 'true') return;
    paintListType(b.dataset.ltype);
    if (e.detail === 0) typeChange(b.dataset.ltype); else { typeChange.cancel(); o.onListType?.(b.dataset.ltype); }
  });
  function paintListType(type) {
    tools.querySelectorAll('[data-ltype]').forEach((x) => x.setAttribute('aria-pressed', String(x.dataset.ltype === type)));
    inks[2].update();
  }
  tools.querySelector('.rch-opt-click').addEventListener('change', () => {
    const ping = tools.querySelector('[data-click="ping"]');
    const cons = tools.querySelector('[data-click="console"]');
    cons.disabled = !ping.checked;
    if (!ping.checked) cons.checked = false;
    o.onClickCheck?.({ ping: ping.checked, console: cons.checked });
  });
  tools.querySelector('[data-reval]').addEventListener('change', (e) => o.onRevalidate?.(e.target.checked));
  toolbar.querySelector('.rch-sets').addEventListener('click', (e) => {
    const b = e.target instanceof Element ? e.target.closest('[data-set]') : null;
    if (b) setColumnSet(b.dataset.set, true);
  });

  const layoutKey = () => `rechercher.${st.set}${st.mode.address ? '.adresse' : st.mode.verdict ? '.requete' : ''}`;

  /** Explicit view choice (never automatic, never while typing): columns, widths and sort kept per view. */
  function setColumnSet(set, user = false) {
    if (!SETS.some((s) => s.id === set)) return;
    st.set = set;
    writeLayout('rechercher.results', { set });
    toolbar.querySelectorAll('[data-set]').forEach((x) => x.setAttribute('aria-pressed', String(x.dataset.set === set)));
    inks[0].update();
    grid.setColumns(columnsFor(set, st.mode, st.content), { key: layoutKey() });
    applyFilters({ quick: st.quick, facets: [...st.facets], presence: st.presence });
    toolbar.querySelectorAll('[data-set]').forEach((b) => { if (b.dataset.set === set) b.classList.remove('suggest'); });
    if (user) announce(`Vue ${SETS.find((s) => s.id === set).label} : colonnes et tri de cette vue.`);
  }

  // ---------- Launchpad (before any read) ----------

  function paintLaunch(data = {}) {
    const recents = (data.recents ?? []).filter((r) => r.kind === 'search').slice(0, 8);
    const views = (data.views ?? []).slice(0, 6);
    launch.innerHTML = `<div class="rch-launch-in">
      <div class="rch-launch-hero">
        <span class="rch-launch-art" aria-hidden="true"><span class="rch-orbit"></span><span class="rch-orbit b"></span>${glyph('search')}</span>
        <div><h3>Que cherchez-vous${NBSP}?</h3>
        <p>Rien n’est lu avant votre geste${COLON}tapez un nom puis Entrée, choisissez une OU dans l’arbre, ou une requête prête.</p></div>
      </div>
      <div class="rch-launch-grid">
        <section class="rch-launch-card" data-k="views"><h4>${glyph('database')}Requêtes prêtes</h4>
          <div class="rch-launch-views">${views.map((v, n) => `<button class="rch-lview" type="button" data-view="${esc(v.id)}" data-j="${n}"><span class="rch-lview-ico">${glyph(v.local ? 'disk' : v.typeLabel === 'Postes' ? 'monitor' : 'user')}</span><span><b>${esc(v.name)}</b><small>${esc(v.category)} · ${esc(v.typeLabel)}${v.local ? ' · base locale' : ''}</small></span></button>`).join('')}</div>
          <button class="btn ghost sm rch-launch-all" type="button" data-act="catalog">${glyph('layers')}Toutes les requêtes</button>
        </section>
        <section class="rch-launch-card" data-k="recents"><h4>${glyph('history')}Recherches récentes</h4>
          ${recents.length ? `<div class="rch-launch-chips">${recents.map((r, n) => `<button class="chip rch-lchip" type="button" data-search="${esc(r.text)}" data-j="${n}">${glyph('history')}${esc(r.text)}</button>`).join('')}</div>` : '<p class="rch-launch-none">Vos huit dernières recherches apparaîtront ici, sur ce poste seulement.</p>'}
        </section>
        <section class="rch-launch-card" data-k="syntax"><h4>${glyph('sparkles')}Syntaxe facultative</h4>
          <div class="rch-launch-syntax">${SYNTAX.map((s, n) => `<button class="rch-lsyn" type="button" data-search="${esc(s.text)}" data-tip="${esc(s.tip)}" data-j="${n}">${glyph(s.icon)}<span><code>${esc(s.text)}</code><small>${esc(s.label)}</small></span></button>`).join('')}</div>
        </section>
      </div>
    </div>`;
    launch.querySelectorAll('[data-j]').forEach((x) => x.style.setProperty('--j', x.dataset.j));
  }

  launch.addEventListener('click', (e) => {
    const t = e.target instanceof Element ? e.target : null;
    const s = t?.closest('[data-search]');
    if (s) { o.onExample(s.dataset.search); return; }
    const v = t?.closest('[data-view]');
    if (v) { o.onCatalogEntry(v.dataset.view); return; }
    if (t?.closest('[data-act="catalog"]')) o.onCatalog();
  });

  function showLaunch(on) {
    host.classList.toggle('launching', on);
    launch.hidden = !on;
    gridHost.hidden = on;
  }

  // ---------- Results ----------

  function headerFor(r) {
    const kindText = { search: 'Recherche', browse: 'Contenu', view: 'Requête prête', address: 'Adresse', localQuery: 'Requête locale' }[r.kind] ?? 'Liste';
    kindEl.textContent = kindText;
    kindChip.dataset.kind = r.kind;
    let text;
    if (r.kind === 'search') text = r.text ? quote(r.text) : 'Recherche';
    else if (r.kind === 'browse') text = r.scope.wholeDomain ? 'Tout le domaine' : leafOf(r.scope.dn);
    else if (r.view) text = r.view.name;
    else text = r.text || 'Résultats';
    title.textContent = text;
    title.dataset.tip = text;
    title.classList.remove('swap');
    void title.offsetWidth;
    title.classList.add('swap');
    // While browsing, the line under the title gives the parent path (« dans example.local › Sites »), never the name twice.
    const showCrumbs = r.kind === 'browse' && !r.scope.wholeDomain && parentDn(r.scope.dn) && !/^DC=/i.test(parentDn(r.scope.dn));
    scopeEl.textContent = r.kind === 'browse'
      ? `${r.scope.wholeDomain ? 'Tout le domaine' : r.scope.subtree ? 'Sous-OU incluses' : 'Enfants directs'}${r.type !== 'all' ? ` · ${typeLabel(r.type)}` : ''}${showCrumbs ? ' · dans' : r.scope.wholeDomain ? '' : ` · dans ${r.scope.path.split(`${NBSP}› `)[0]}`}`
      : r.scope.label + (r.type !== 'all' && r.kind !== 'localQuery' ? ` · ${typeLabel(r.type)}` : '');
    scopeEl.dataset.tip = r.scope.path ? `${r.scope.label} — ${r.scope.path}` : r.scope.label;
    crumbsEl.hidden = !showCrumbs;
    if (showCrumbs) {
      const parent = parentDn(r.scope.dn);
      if (!crumbs) crumbs = createDnBreadcrumb(crumbsEl, { dn: parent, onNavigate: (dn) => o.onBrowseDn(dn), maxVisible: 3 });
      else crumbs.setDn(parent);
    }
    freshEl.innerHTML = freshness(r.readAt, { staleAfter: 30 * 60_000, label: r.kind === 'address' || r.kind === 'localQuery' ? 'Relevés lus' : 'Annuaire lu', source: r.sourceLabel });
    startFreshness(freshEl);
    typeOpt.hidden = r.kind !== 'browse';
    tools.querySelector('.rch-opt-click').hidden = !r.rows.some((x) => x.kind === 'computer');
    if (r.kind === 'browse') paintListType(r.type);
  }

  // The three verdicts of a local query are both the totals and the choice of the rows shown (Domenia 1 RCH-102).
  function verdictChoice(v) {
    const shown = { Correspondants: 'match', Inconnus: 'unknown', 'Non correspondants': 'noMatch' }[v.shown] ?? 'all';
    const items = [['match', 'Correspondants', v.match, 'ok'], ['unknown', 'Inconnus', v.unknown, 'off'], ['noMatch', 'Non correspondants', v.noMatch, 'info'], ['all', 'Tous', v.match + v.unknown + v.noMatch, 'all']];
    return `<span class="rch-verdicts" role="group" aria-label="Postes affichés">${items.map(([id, label, n, tone]) => `<button type="button" class="rch-verdict${id === shown ? ' on' : ''}" data-act="${id}" data-tone="${tone}" aria-pressed="${id === shown}"><span class="rch-verdict-dot" aria-hidden="true"></span>${label}<b>${int(n)}</b></button>`).join('')}</span>`;
  }

  function noticesFor(r, restored) {
    const plan = r.plan;
    // The bar explains its plan; a costly one (leading wildcard, « contient ») stays visible over the list.
    setNotice('plan', plan.hint && plan.costly && (r.kind === 'search' || r.kind === 'address') ? { tone: 'warn', icon: 'alert', html: esc(plan.hint.split(/(?<=\.)\s/)[0]), more: plan.hint.includes('. ') ? esc(plan.hint) : '' } : null);
    const first = (text) => { const at = text.search(/[.:](\s|$)/); return at > 0 ? text.slice(0, at + 1) : text; };
    setNotice('view', r.view ? {
      tone: r.view.surveyAllowed ? 'info' : 'warn', icon: r.kind === 'localQuery' ? 'disk' : 'database',
      // A local query says at once how far its readings cover the perimeter (RCH-120): the date of the last complete read.
      html: `<b>${esc(r.view.name)}</b>${r.view.reason ? ` <span class="rch-notice-warn">${esc(r.view.reason.split(COLON)[0])}${COLON}aucun relevé.</span>` : ''}${r.verdicts ? verdictChoice(r.verdicts) : ''}`
        + (r.verdicts?.coverage ? `<span class="rch-coverage${r.verdicts.completeAt ? ' ok' : ''}">${glyph('clock')}${esc(r.verdicts.coverage)}</span>` : ''),
      more: `<p>${esc(r.view.note)}</p>${r.view.reason ? `<p>${esc(r.view.reason)}</p>` : ''}<p>${glyph('database')}Source${COLON}${esc(r.sourceLabel)} · ${esc(r.scope.label)}.</p>`,
      run: (act) => o.onVerdict?.(act),
    } : null);
    // Few results of a plain text: one line, the explanation folded (RCH-037 offer and FO-01 « contient »).
    setNotice('offer', r.offer ? {
      tone: 'accent', icon: 'sparkles', html: `Peu de résultats${COLON}chercher aussi les noms qui ${r.offer.term.includes(' ') ? 'contiennent ces mots' : `contiennent ${esc(quote(r.offer.term))}`}${NBSP}?`, more: esc(r.offer.tip),
      actions: [{ id: 'contains', label: 'Chercher', icon: 'search', kind: 'network', primary: true }], dismiss: true, run: () => o.onContains(r.offer.term),
    } : null);
    setNotice('dns', r.dns ? {
      tone: 'info', icon: 'wifi', html: `Aucun poste n’a relevé l’adresse ${esc(r.dns.ip)} dans la base locale.`, more: esc(r.dns.tip),
      actions: [{ id: 'dns', label: r.dns.label, icon: 'search', kind: 'network', primary: true }], dismiss: true, run: () => o.onDns(r.dns.ip),
    } : null);
    // A list of one kind suggests its column set: its button glows; the view changes only on a click (Domenia 1 RCH-053).
    const kinds = new Set(r.rows.map((x) => x.kind));
    const fit = kinds.size === 1 ? ({ user: 'users', computer: 'computers' }[[...kinds][0]] ?? null) : null;
    toolbar.querySelectorAll('[data-set]').forEach((b) => {
      const on = b.dataset.set === fit && st.set !== fit && r.rows.length > 1;
      b.classList.toggle('suggest', on);
      b.dataset.tip = on ? `Vue conseillée pour cette liste de ${fit === 'users' ? 'comptes' : 'postes'} : un clic l’applique` : SETS.find((x) => x.id === b.dataset.set).tip;
    });
    setNotice('history', restored ? {
      tone: 'warn', icon: 'history', html: `Liste de l’historique, non relue${COLON}${esc(first(r.counter))}`,
      actions: [{ id: 'refresh', label: 'Actualiser', icon: 'refresh', kind: 'network' }], run: () => o.onRefresh(),
    } : null);
  }

  /** Applies the content of a list to the columns: a column whose data no row has is not shown (RCH-061). */
  function fitColumns(force = false) {
    const content = contentOf(st.rows);
    const changed = force || JSON.stringify(content) !== JSON.stringify(st.content);
    st.content = content;
    if (!changed) return;
    grid.setColumns(columnsFor(st.set, st.mode, content), { key: layoutKey() });
    // A new column list clears the column filters of the grid: the presence filter and the quick filter come back at once.
    applying = true;
    try {
      grid.setColumnFilter('presence', st.presence ?? '');
      grid.setQuickFilter(st.quick ?? '');
    } finally {
      applying = false;
    }
  }

  ready = true;
  paintUndo();

  return {
    grid,
    toolbar,
    tools,
    actionsHost: host.querySelector('.rch-actions'),
    navEls: { back: host.querySelector('[data-nav="back"]'), forward: host.querySelector('[data-nav="forward"]'), list: host.querySelector('[data-nav="list"]') },
    get state() { return st; },
    get set() { return st.set; },
    get scopeMode() { return st.scopeMode; },
    result: () => st.result,
    rows: () => st.rows,
    pointerRecent: () => Date.now() - lastPointer < 500,
    setNotice,
    noticeEl,
    setNoticeMore,
    setToolsOpen,
    setClickCheck({ ping, console: cons }) {
      const a = tools.querySelector('[data-click="ping"]');
      const b = tools.querySelector('[data-click="console"]');
      a.checked = !!ping;
      b.checked = !!ping && !!cons;
      b.disabled = !ping;
    },
    setRevalidate(on, label) { const x = tools.querySelector('[data-reval]'); x.checked = !!on; if (label) tools.querySelector('.rch-reval-t').textContent = label; },
    launch(data) {
      paintLaunch(data);
      showLaunch(true);
      st.result = null;
      st.rows = [];
      st.empty = null;
      grid.setRows([], { hasMore: false });
      title.textContent = 'Prêt à chercher';
      scopeEl.textContent = 'Rien n’est lu avant votre geste.';
      crumbsEl.hidden = true;
      freshEl.innerHTML = '';
      kindEl.textContent = 'Résultats';
      kindChip.dataset.kind = 'none';
      paintEmpty();
      paintFoot();
      countUp(countN, 0, { duration: 300 });
      countT.textContent = 'ligne';
      ['plan', 'view', 'offer', 'dns', 'history', 'cached'].forEach((id) => setNotice(id, null));
    },
    refreshLaunch(data) { if (!launch.hidden) paintLaunch(data); },
    setLoading(label) {
      showLaunch(false);
      st.empty = null;
      paintEmpty();
      grid.setLoading(true);
      host.classList.add('loading');
      if (label) { title.textContent = label; scopeEl.textContent = 'Lecture en cours…'; crumbsEl.hidden = true; }
    },
    /** Rows of the local base shown while the directory read goes on (RCH-055); the fresh rows replace them (RCH-058). */
    showCached(event) {
      if (!host.classList.contains('loading')) return;
      st.cached = true;
      const rows = event.rows.map((x) => ({ ...x, _cached: true, _cachedAt: event.readAt }));
      grid.setLoading(false);
      grid.setRows(rows, { hasMore: false, keepSelection: false });
      setNotice('cached', { tone: 'info', icon: 'database', html: `${esc(count(rows.length, 'ligne de la base locale affichée', 'lignes de la base locale affichées'))} pendant la lecture de l’annuaire${event.readAt ? ` (relevé du ${esc(dateText(event.readAt))})` : ''}.`, more: 'Elles sont remplacées par les lignes fraîches de l’annuaire dès leur arrivée ; à la limite de la liste, les lignes de la base locale cèdent leur place.' });
    },
    /** A read that did not end with a list (RCH-051): refused, partial, sourceless or in error; the title says it. */
    setError(err, retry) {
      host.classList.remove('loading');
      showLaunch(false);
      st.cached = false;
      setNotice('cached', null);
      const code = String(err?.code ?? '');
      const kind = code === 'source.unavailable' ? 'nosource' : /denied|refus|forbidden|auth/i.test(code) ? 'refused' : /timeout|partial|busy|cancel/i.test(code) ? 'partial' : 'error';
      st.result = null;
      st.rows = [];
      grid.setRows([], { hasMore: false });
      st.empty = emptyState(kind, { message: err?.message ?? '' });
      st.retry = retry;
      title.textContent = { nosource: 'Aucune source disponible', refused: 'Lecture refusée', partial: 'Lecture partielle', error: 'Lecture en erreur' }[kind];
      scopeEl.textContent = 'Rien n’est affiché : l’état réel est inconnu.';
      crumbsEl.hidden = true;
      freshEl.innerHTML = '';
      paintEmpty();
      paintFoot();
      paintCount();
    },
    retry: () => st.retry?.(),
    /** Shows a new list (or a list restored from the history, without any read). */
    show(r, { restored = false, selection = [], quick = '', facets = [], presence = null, scroll = 0, scrollLeft = 0, set = null, layout = null } = {}) {
      host.classList.remove('loading');
      showLaunch(false);
      st.cached = false;
      st.empty = null;
      st.restored = restored;
      setNotice('cached', null);
      const mode = { address: r.kind === 'address', mac: r.kind === 'address' && r.plan.address?.kind === 'mac', verdict: r.kind === 'localQuery', needle: r.kind === 'search' && r.match !== 'contains' ? (r.plan.freeText || r.text).replace(/\*/g, '').split(/\s+/)[0] : '' };
      const modeChanged = JSON.stringify(mode) !== JSON.stringify(st.mode);
      st.mode = mode;
      st.result = r;
      st.rows = r.rows.slice();
      st.undo = [];
      paintUndo();
      if (set && set !== st.set) { st.set = set; toolbar.querySelectorAll('[data-set]').forEach((x) => x.setAttribute('aria-pressed', String(x.dataset.set === set))); inks[0].update(); }
      // The step of the history restores its own layout (sort, widths, order) before the columns are set (RCH-044).
      if (layout) writeLayout(`grid:${layoutKey()}`, layout);
      fitColumns(modeChanged || !!set || !!layout);
      st.facets = new Set((facets ?? []).filter((id) => FLAG_FACETS.some((f) => f.id === id)));
      grid.setRows(visibleRows(), { hasMore: false, keepSelection: false });
      applyFilters({ quick, facets: [...st.facets], presence });
      if (selection.length) grid.select(selection);
      const scroller = grid.el.querySelector('.k-gscroll');
      if (scroll || scrollLeft) requestAnimationFrame(() => scroller?.scrollTo({ top: scroll, left: scrollLeft }));
      headerFor(r);
      noticesFor(r, restored);
      paintCriteria();
      host.classList.remove('arrived');
      void host.offsetWidth;
      host.classList.add('arrived');
    },
    /** Rows of « Charger la suite » (only the following ones). */
    append(r) {
      st.result = { ...r, rows: st.rows.concat(r.rows) };
      st.rows = st.rows.concat(r.rows);
      fitColumns();
      feedGrid();
      for (const x of r.rows) grid.updateRow(x.id);
      paintCriteria();
      announce(`${count(r.rows.length, 'ligne ajoutée', 'lignes ajoutées')}. ${r.counter}.`);
    },
    /** Rows found by the revalidation of the list (RCH-048): added at the end with a brief flash, marked « nouveau ». */
    inject(rows) {
      if (!rows.length) return;
      const known = new Set(st.rows.map((x) => x.id));
      const fresh = rows.filter((x) => !known.has(x.id)).map((x) => ({ ...x, _new: true }));
      st.rows = st.rows.concat(fresh);
      if (st.result) st.result = { ...st.result, rows: st.rows, loaded: st.rows.length };
      fitColumns();
      feedGrid();
      for (const x of fresh) grid.updateRow(x.id);
      paintCriteria();
    },
    /** Replaces rows read again (survey, recheck, revalidation, preload): cells change in place with a flash, nothing else moves. */
    updateRows(rows, { pending = false } = {}) {
      const byId = new Map(rows.map((x) => [x.id, x]));
      let changed = 0;
      st.rows = st.rows.map((x) => {
        const y = byId.get(x.id);
        if (!y) return x;
        changed++;
        return pending ? { ...x, _pending: true } : { ...y, _new: x._new };
      });
      if (st.result) st.result = { ...st.result, rows: st.rows };
      feedGrid();
      for (const id of byId.keys()) grid.updateRow(id);
      paintFacets();
      paintCount();
      return changed;
    },
    /** Marks rows no longer found by a revalidation (« à revérifier »), never removes them. */
    markMissing(ids, label = 'à revérifier') {
      const set = new Set(ids);
      st.rows = st.rows.map((x) => (set.has(x.id) ? { ...x, state: { key: x.state.key, label: `${x.state.label.split(' · ')[0]} · ${label}`, tone: 'warn' } } : x));
      feedGrid();
      for (const id of set) grid.updateRow(id);
    },
    /** Freshness of the header after a revalidation: « Annuaire lu il y a 4 s » (RCH-047). */
    touch(at) { const node = freshEl.querySelector('.k-fresh'); if (node) touchFreshness(node, at); },
    setColumnSet,
    filters: () => ({ quick: st.quick, facets: [...st.facets], presence: st.presence }),
    /** Presentation of the list for a history step: filters, selection, both scrolls and the layout of its column set. */
    viewState() {
      const scroller = grid.el.querySelector('.k-gscroll');
      return { set: st.set, ...this.filters(), selection: grid.getSelectedIds(), scroll: scroller?.scrollTop ?? 0, scrollLeft: scroller?.scrollLeft ?? 0, layout: readLayout(`grid:${layoutKey()}`) };
    },
    togglePresence(state) {
      const next = st.presence === state ? null : state;
      applying = true;
      try { st.presence = next; grid.setColumnFilter('presence', next ?? ''); } finally { applying = false; }
      paintCriteria();
      return next;
    },
    scopeSentence: () => { const sel = grid.getSelection(); const shown = new Set(grid.getVisibleRows().map((v) => v.id)); const a = sel.filter((s) => shown.has(s.id)).length; return scopeSentence(a, sel.length - a); },
    destroy() { inks.forEach((i) => i.stop()); pushUndo.cancel(); typeChange.cancel(); crumbs?.destroy(); fbar.destroy(); grid.destroy(); host.replaceChildren(); },
  };
}
