// Rechercher · the result card: header (list, perimeter, breadcrumb, counter, freshness, column set), notices (plan,
// « contient », DNS, view, history, revalidation, survey), filter bar (quick filters with counts, criteria chips with their
// scope, combination sentence), the virtual grid with three column sets, and the footer (explicit continuation, absence
// hint, collective scope). Before any read, a launchpad: recent searches, ready-made views, syntax examples.
// Domenia 1 RCH-040 to RCH-077, RCH-123 to RCH-128.
import { glyph } from '../../kit/glyphs.js';
import { createGrid } from '../../kit/grid.js';
import { createFilterBar } from '../../kit/filterbar.js';
import { createDnBreadcrumb } from '../../kit/breadcrumb.js';
import { pill } from '../../kit/status.js';
import { freshness, startFreshness } from '../../kit/freshness.js';
import { highlight, writeClipboard, readLayout, writeLayout, debounce } from '../../kit/util.js';
import { inkFollow, announce, toast, relTime, countUp } from '../../ui.js';
import {
  esc, fold, int, count, quote, COLON, NBSP, KINDS, typeLabel, ageText, emptyState, scopeSummary, selectionText, dateText, leafOf,
} from './text.js';

const SETS = [
  { id: 'mixed', label: 'Mixte', icon: 'layers', tip: 'Toutes les colonnes utiles à une liste mêlant comptes et postes' },
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

// Quick filters of the list (local, never a read): hidden boolean columns or the presence column.
const FACETS = [
  { id: 'f_locked', label: 'Verrouillés', tone: 'alert', kinds: ['user'], test: (r) => r.flags.locked },
  { id: 'f_disabled', label: 'Désactivés', tone: 'off', kinds: ['user', 'computer'], test: (r) => r.flags.disabled },
  { id: 'f_expired', label: 'Mot de passe expiré', tone: 'warn', kinds: ['user'], test: (r) => r.flags.passwordExpired },
  { id: 'f_inactive', label: 'Inactifs 90 j', tone: 'warn', kinds: ['user', 'computer'], test: (r) => r.flags.inactive },
  { id: 'f_never', label: 'Jamais connectés', tone: 'info', kinds: ['user', 'computer'], test: (r) => r.flags.neverLoggedOn },
  { id: 'f_admin', label: 'Comptes d’administration', tone: 'info', kinds: ['user', 'group'], test: (r) => r.flags.admin },
  { id: 'p_online', label: 'En ligne', tone: 'ok', kinds: ['computer'], presence: 'online', test: (r) => r.presence?.state === 'online' },
  { id: 'p_noReply', label: 'Sans réponse', tone: 'warn', kinds: ['computer'], presence: 'noReply', test: (r) => r.presence?.state === 'noReply' },
  { id: 'p_unknown', label: 'Non vérifiés', tone: 'off', kinds: ['computer'], presence: 'unknown', test: (r) => r.presence?.state === 'unknown' },
];

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
  const display = row.display && row.display !== row.name ? `<span class="rch-sub">${needle ? highlight(row.display, needle) : esc(row.display)}</span>` : '';
  return `<span class="rch-name-cell"><span class="rch-name">${label}</span>${display}${admin}</span>`;
}

function presenceHtml(row) {
  const p = row.presence;
  if (!p) return '';
  const tone = { online: 'ok', noReply: 'warn', error: 'alert' }[p.state] ?? 'off';
  const age = p.checkedAt ? ageText(p.checkedAt) : '';
  const tip = `${p.detail}${p.checkedAt ? ` Relevé ${relTime(p.checkedAt) ?? ''}.` : ''}`;
  return `<span class="rch-presence ${tone}${row._pending ? ' pending' : ''}" data-tip="${esc(tip)}"><span class="rch-dot${p.state === 'online' ? ' pulse' : ''}"></span>${esc(p.label)}${age ? `<span class="rch-age">${esc(age)}</span>` : ''}</span>`;
}

function consoleHtml(row) {
  const c = row.console;
  if (!c) return '';
  if (c.state === 'seen') return `<span class="rch-console seen" data-tip="${esc(`Session à la console${c.at ? ` relevée ${relTime(c.at) ?? ''}` : ''}. Les sessions RDP ne sont pas recensées.`)}">${glyph('user')}${esc(c.user ?? c.label)}</span>`;
  return `<span class="rch-console ${esc(c.state)}">${esc(c.label)}</span>`;
}

function associationHtml(row) {
  const a = row.association;
  if (!a) return '';
  const tone = a.qualification === 'Déclaré' ? 'info' : 'off';
  return `<span class="rch-assoc" data-tip="${esc(`${a.source} · ${a.note}`)}">${esc(a.label)}<span class="rch-qual ${tone}">${esc(a.qualification)}</span></span>`;
}

/** Column definitions; each set shows its own default columns, every column stays available (Domenia 1 RCH-053, RCH-054). */
export function columnsFor(set, mode = {}) {
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
  const needle = mode.needle ? fold(mode.needle) : '';
  const col = (c) => ({ ...c, hidden: !c.required && !visible.has(c.id) });
  const rank = (c) => { const at = order.indexOf(c.id); return at < 0 ? 1000 : at; };
  return all();
  function all() { return list().map((c, n) => ({ c, n })).sort((a, b) => rank(a.c) - rank(b.c) || a.n - b.n).map((x) => x.c); }
  function list() { return [
    col({ id: 'kind', label: 'Type', type: 'enum', options: KIND_OPTIONS, width: 122, get: (r) => r.kind, html: (v, r) => `<span class="rch-kind ${esc(v)}">${kindIcon(v)}${esc(r.kindLabel)}</span>`, csv: (v, r) => r.kindLabel }),
    col({ id: 'name', label: 'Nom', required: true, width: 200, get: (r) => r.name, format: (v, r) => `${r.name}${r.display && r.display !== r.name ? ` ${r.display}` : ''}`, html: (v, r) => nameHtml(r, needle), csv: (v, r) => r.name }),
    col({ id: 'display', label: 'Nom affiché', width: 190, get: (r) => r.display ?? '' }),
    col({ id: 'console', label: 'Utilisateur connecté (console)', width: 200, get: (r) => r.console?.user ?? r.console?.label ?? '', html: (v, r) => consoleHtml(r) }),
    col({ id: 'consoleState', label: 'Vérification utilisateur', width: 150, get: (r) => ({ seen: 'Session vue', none: 'Aucune session', unknown: 'Non déterminé' }[r.console?.state] ?? '') }),
    col({ id: 'freshness', label: 'Fraîcheur AD', type: 'date', width: 130, get: (r) => r.readAt, tip: 'Date de la lecture de l’annuaire qui a produit la ligne' }),
    col({ id: 'login', label: 'Compte', width: 132, mono: true, get: (r) => r.login ?? '' }),
    col({ id: 'upn', label: 'UPN / DNS', width: 230, mono: true, get: (r) => r.upn ?? '' }),
    col({ id: 'association', label: 'Association mémorisée', width: 210, get: (r) => r.association?.label ?? '', html: (v, r) => associationHtml(r), csv: (v, r) => (r.association ? `${r.association.label}␟${r.association.source}␟${r.association.qualification}` : '') }),
    col({ id: 'assocSource', label: 'Source lien', width: 200, get: (r) => r.association?.source ?? '' }),
    col({ id: 'assocQual', label: 'Qualification', width: 120, get: (r) => r.association?.qualification ?? '' }),
    col({ id: 'presence', label: 'Présence réseau', type: 'enum', options: PRESENCE_OPTIONS, width: 172, get: (r) => r.presence?.state ?? null, html: (v, r) => presenceHtml(r), csv: (v, r) => (r.presence ? `${r.presence.label}${r.presence.checkedAt ? ` (${dateText(r.presence.checkedAt)})` : ''}` : '') }),
    col({ id: 'state', label: 'État', type: 'enum', options: STATE_OPTIONS, width: 138, get: (r) => r.state.key, html: (v, r) => pill(r.state.tone, r.state.label, { size: 'sm' }), csv: (v, r) => r.state.label }),
    col({ id: 'os', label: 'Système', width: 170, get: (r) => r.os ?? '', tip: 'Version regroupée (operatingSystem et operatingSystemVersion)' }),
    col({ id: 'lastLogon', label: 'Dernière connexion', type: 'date', width: 150, get: (r) => r.lastLogon, tip: 'lastLogonTimestamp, répliqué à 14 jours près' }),
    col({ id: 'mail', label: 'Mail', width: 220, get: (r) => r.mail ?? '' }),
    col({ id: 'description', label: 'Description', width: 230, get: (r) => r.description ?? '' }),
    col({ id: 'changed', label: 'Modifié', type: 'date', width: 140, get: (r) => r.changed }),
    col({ id: 'created', label: 'Créé', type: 'date', width: 140, get: (r) => r.created }),
    col({ id: 'container', label: 'Emplacement', width: 220, get: (r) => r.container.split(`${NBSP}› `).slice(1).join(' › ') || r.container, tip: 'OU ou conteneur de l’objet' }),
    col({ id: 'dn', label: 'Chemin complet', width: 420, mono: true, get: (r) => r.dn }),
    col({ id: 'groupScope', label: 'Étendue du groupe', width: 170, get: (r) => r.group?.scopeLabel ?? '' }),
    col({ id: 'members', label: 'Membres directs', type: 'number', width: 120, get: (r) => (r.group ? r.group.members : null) }),
    col({ id: 'address', label: 'Adresse relevée', width: 170, mono: true, get: (r) => (mode.mac ? r.address?.mac : r.address?.ip) ?? '', tip: 'Adresse lue dans les relevés locaux, jamais relue dans l’annuaire' }),
    col({ id: 'addressSeen', label: 'Relevée le', type: 'date', dateStyle: 'datetime', width: 150, get: (r) => r.address?.observedAt ?? null }),
    col({ id: 'verdict', label: 'Résultat de la requête', width: 260, get: (r) => r.verdict ?? '', html: (v) => { const [label, value] = String(v ?? '').split(' · '); return label ? `${pill(VERDICT_TONE[label] ?? 'off', label, { size: 'sm' })}<span class="rch-verdict-v">${esc(value ?? '')}</span>` : ''; } }),
    col({ id: 'guid', label: 'GUID', width: 290, mono: true, get: (r) => r.id }),
    ...FACETS.filter((f) => !f.presence).map((f) => col({ id: f.id, label: `Filtre${COLON}${f.label}`, type: 'bool', width: 100, get: (r) => !!f.test(r), filterable: true })),
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
    result: null,
    rows: [],
    facets: new Set(),
    presence: null,
    quick: '',
    scopeMode: 'visible',
    undo: [],
    revalidatedAt: null,
    mode: {},
  };
  // The grid reports its filters as soon as it is built: nothing is painted before the card is complete.
  let ready = false;
  let applying = false;

  host.innerHTML = `<div class="rch-res-in">
    <header class="rch-res-head">
      <div class="rch-res-titles">
        <div class="rch-res-eyebrow"><span class="rch-res-kind">${glyph('search')}<span>Résultats</span></span><span class="rch-res-scope"></span><span class="rch-res-fresh"></span></div>
        <div class="rch-res-titlerow"><h2 class="rch-res-title">Prêt à chercher</h2><div class="rch-res-crumbs" hidden></div></div>
      </div>
      <div class="rch-res-side">
        <div class="rch-count" aria-live="polite"><b class="rch-count-n num">0</b><span class="rch-count-t">ligne</span></div>
        <div class="segmented rch-sets" role="group" aria-label="Jeu de colonnes"><span class="thumb" aria-hidden="true"></span>
          ${SETS.map((s) => `<button type="button" data-set="${s.id}" aria-pressed="${s.id === st.set}" data-tip="${esc(s.tip)}">${glyph(s.icon)}<span>${esc(s.label)}</span></button>`).join('')}
        </div>
      </div>
    </header>
    <div class="rch-actions"></div>
    <div class="rch-notices" aria-live="polite"></div>
    <div class="rch-fbar" hidden></div>
    <div class="rch-gridwrap"><div class="rch-grid"></div><div class="rch-launch"></div></div>
    <footer class="rch-res-foot" hidden>
      <div class="rch-more"></div>
      <p class="rch-counter"></p>
      <div class="segmented rch-scope-mode" role="group" aria-label="Portée des exports et des relevés"><span class="thumb" aria-hidden="true"></span>
        <button type="button" data-mode="visible" aria-pressed="true">Liste affichée</button><button type="button" data-mode="selected" aria-pressed="false">Sélection</button>
      </div>
      <span class="rch-absence" tabindex="0" data-tip="">${glyph('info')}<span class="visually-hidden">Ce que la liste ne prouve pas</span></span>
    </footer>
  </div>`;

  const title = host.querySelector('.rch-res-title');
  const scopeEl = host.querySelector('.rch-res-scope');
  const crumbsEl = host.querySelector('.rch-res-crumbs');
  const freshEl = host.querySelector('.rch-res-fresh');
  const kindEl = host.querySelector('.rch-res-kind span');
  const countN = host.querySelector('.rch-count-n');
  const countT = host.querySelector('.rch-count-t');
  const notices = host.querySelector('.rch-notices');
  const fbarHost = host.querySelector('.rch-fbar');
  const launch = host.querySelector('.rch-launch');
  const gridHost = host.querySelector('.rch-grid');
  const foot = host.querySelector('.rch-res-foot');
  const moreEl = host.querySelector('.rch-more');
  const counterEl = host.querySelector('.rch-counter');
  const absenceEl = host.querySelector('.rch-absence');
  const setsInk = inkFollow(host.querySelector('.rch-sets'), 'button', 'button[aria-pressed="true"]');
  const modeInk = inkFollow(host.querySelector('.rch-scope-mode'), 'button', 'button[aria-pressed="true"]');
  const noticeMap = new Map();
  let crumbs = null;

  // ---------- Grid ----------

  const grid = createGrid(gridHost, {
    key: `rechercher.${st.set}`,
    label: 'Résultats de la recherche',
    rowId: (r) => r.id,
    selection: 'multi',
    height: 'fill',
    columns: columnsFor(st.set),
    quickPlaceholder: 'Filtrer les lignes chargées…',
    empty: emptyState('nothing'),
    onActivate: (row) => o.onOpen(row),
    onActiveChange: (row) => o.onActive(row),
    onSelectionChange: (rows) => { o.onSelection(rows); paintFoot(); },
    contextMenu: (c) => o.contextMenu(c),
    selectionActions: (rows) => o.selectionActions(rows),
    onExport: (csv, info) => exportCsv(csv, info),
    onFilterChange: (info) => onFilter(info),
    onLoadMore: () => { const c = st.result?.continuation; if (c?.allowed) o.onMore(c.nextLimit); },
  });
  grid.el.classList.add('rch-k-grid');

  function exportCsv(csv, info) {
    // The association shown in one cell goes back to three columns in the CSV (Domenia 1 Expand-DomeniaResultExportColumns).
    const out = expandAssociation(csv);
    writeClipboard(out).then((ok) => toast(ok
      ? `CSV copié${COLON}${count(info.rows, 'ligne', 'lignes')} (${info.scope === 'selected' ? 'lignes sélectionnées' : 'liste affichée'}), ${count(info.columns, 'colonne', 'colonnes')}, séparateur point-virgule. Collez-le dans un tableur.`
      : 'Copie impossible : le presse-papiers est indisponible.', { tone: ok ? 'ok' : 'warn', life: 5200 }));
  }

  function onFilter(info) {
    if (!ready || applying) return;
    const before = { quick: st.quick, facets: [...st.facets], presence: st.presence };
    const quick = info.quick ?? '';
    const changed = quick !== st.quick;
    st.quick = quick;
    // The quick filters follow the column filters of the grid (its filter row, « Effacer les filtres »).
    const cols = info.columns ?? {};
    st.facets = new Set(FACETS.filter((f) => !f.presence && cols[f.id] === 'true').map((f) => f.id));
    st.presence = PRESENCE_OPTIONS.some((p) => p.value === cols.presence) ? cols.presence : null;
    if (changed) pushUndo(before);
    paintChips();
    paintFacets();
    paintCount();
    paintFoot();
  }

  // Presentation undo for the filters of the list (Domenia 1 RCH-049; the grid undoes its own layout with Ctrl Z).
  const pushUndo = debounce((state) => {
    st.undo.push(state);
    if (st.undo.length > 10) st.undo.shift();
    paintUndo();
  }, 900);

  function paintUndo() {
    const slot = grid.slot;
    if (!slot) return;
    const last = st.undo.at(-1);
    slot.innerHTML = last ? `<button class="chip rch-undo" type="button" data-tip="Rétablit le filtre précédent de la liste ; n’annule jamais une lecture ni une écriture">${glyph('undo')}Annuler${COLON}filtre de la liste</button>` : '';
  }
  grid.slot?.addEventListener('click', (e) => {
    if (!(e.target instanceof Element) || !e.target.closest('.rch-undo')) return;
    const last = st.undo.pop();
    if (!last) return;
    applyFilters(last);
    paintUndo();
    announce('Filtre précédent rétabli, sans nouvelle lecture.');
  });

  function applyFilters({ quick, facets, presence }) {
    st.facets = new Set(facets);
    st.presence = presence;
    applying = true;
    try {
      for (const f of FACETS.filter((x) => !x.presence)) grid.setColumnFilter(f.id, st.facets.has(f.id) ? 'true' : '');
      grid.setColumnFilter('presence', presence ?? '');
      grid.setQuickFilter(quick ?? '');
    } finally {
      applying = false;
    }
    st.quick = quick ?? '';
    paintFacets();
    paintChips();
    paintCount();
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
        grid.setColumnFilter(id, pressed ? 'true' : '');
      }
    } finally {
      applying = false;
    }
    st.undo.push(before);
    if (st.undo.length > 10) st.undo.shift();
    paintUndo();
    paintFacets();
    paintChips();
    paintCount();
    paintFoot();
  }

  function removeChip(id) {
    if (id === 'local') { grid.setQuickFilter(''); st.quick = ''; }
    else if (id.startsWith('f_') || id.startsWith('p_')) toggleFacet(id, false);
    else o.onRemoveCriterion?.(id);
    paintChips();
  }

  function paintFacets() {
    const kinds = new Set(st.rows.map((r) => r.kind));
    const list = FACETS.filter((f) => f.kinds.some((k) => kinds.has(k))).map((f) => ({
      id: f.id, label: f.label, tone: f.tone, count: st.rows.filter(f.test).length,
      pressed: f.presence ? st.presence === f.presence : st.facets.has(f.id),
    })).filter((f) => f.count > 0 || f.pressed);
    fbar.setFacets(list);
  }

  function paintChips() {
    const r = st.result;
    const chips = [];
    if (r) {
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
    // The perimeter (also on the header line, never removable) closes the row: the criteria the operator can act on come first.
    chips.sort((a, b) => Number(a.id === 'scope') - Number(b.id === 'scope'));
    fbar.setChips(chips);
    // Long values are shortened by the stylesheet: their full text is offered on hover.
    fbarHost.querySelectorAll('.k-chip-text b').forEach((b) => { if ((b.textContent ?? '').length > 24) b.dataset.tip = b.textContent ?? ''; });
  }

  // ---------- Header, notices, footer ----------

  function paintCount() {
    const shown = grid.getVisibleRows().length;
    const total = st.rows.length;
    countUp(countN, shown, { duration: 600 });
    countT.textContent = `${shown >= 2 ? 'lignes' : 'ligne'}${shown !== total ? ` sur ${int(total)}` : ''}`;
    // The combination sentence is said when a criterion of the loaded list hides rows (Domenia 1 RCH-040).
    const filtered = !!(st.quick || st.facets.size || st.presence);
    const summary = st.result && filtered ? `→ ${count(shown, 'ligne affichée', 'lignes affichées')} sur ${int(total)}` : '';
    fbar.setSummary(summary);
    const sumEl = fbarHost.querySelector('.k-fbar-sum');
    if (sumEl) sumEl.dataset.tip = summary ? 'Filtre appliqué aux seules lignes déjà chargées : rien n’est relu' : '';
  }

  /** Shows or replaces a notice band (id → { tone, icon, html, actions: [{id, label, icon, kind}] }), or removes it with null. */
  function setNotice(id, notice) {
    const prev = noticeMap.get(id);
    if (!notice) { if (prev) { prev.classList.add('leaving'); setTimeout(() => prev.remove(), 260); noticeMap.delete(id); } return; }
    const el = document.createElement('div');
    el.className = `rch-notice ${notice.tone ?? 'info'}`;
    el.dataset.id = id;
    el.innerHTML = `<span class="rch-notice-ico">${glyph(notice.icon ?? 'info')}</span><div class="rch-notice-body">${notice.html}</div>`
      + `${(notice.actions ?? []).map((a) => `<button class="btn sm${a.primary ? ' primary' : ''}" type="button" data-act="${esc(a.id)}"${a.kind === 'network' ? ' data-tip="Lecture réseau : part seulement sur ce clic"' : ''}>${a.icon ? glyph(a.icon) : ''}${esc(a.label)}${a.kind === 'network' ? '<span class="rch-net-dot" aria-hidden="true"></span>' : ''}</button>`).join('')}`
      + `${notice.dismiss ? `<button class="btn ghost icon sm rch-notice-x" type="button" data-act="dismiss" aria-label="Masquer ce message">${glyph('x')}</button>` : ''}`;
    el.addEventListener('click', (e) => {
      const b = e.target instanceof Element ? e.target.closest('[data-act]') : null;
      if (!b) return;
      if (b.dataset.act === 'dismiss') { setNotice(id, null); return; }
      notice.run?.(b.dataset.act, b);
    });
    if (prev) prev.replaceWith(el); else notices.appendChild(el);
    noticeMap.set(id, el);
  }

  function paintFoot() {
    const r = st.result;
    foot.hidden = !r;
    if (!r) return;
    const c = r.continuation;
    moreEl.innerHTML = c.allowed
      ? `<button class="btn sm primary rch-more-next" type="button" data-more="${c.nextLimit}" data-tip="${esc(c.reason)}">${glyph('plus')}Charger la suite<span class="rch-more-n">+${int(c.page)}</span><span class="rch-net-dot" aria-hidden="true"></span></button>`
        + (c.jumpLimit ? `<button class="btn sm rch-more-jump" type="button" data-more="${c.jumpLimit}" aria-label="${esc(c.jumpText ?? '')}" data-tip="${esc(c.jumpText ?? '')}${COLON}lit seulement les lignes suivantes, ${int(c.jumpLimit)} lignes en tout">Jusqu’à ${int(c.jumpLimit)}</button>` : '')
      : r.limitReached ? `<span class="rch-more-max">${glyph('alert')}${esc(c.reason)}</span>` : '';
    // The header already gives the number of rows: the footer keeps what the list does not prove, the rest on hover.
    const at = r.counter.indexOf(' · ');
    const tail = at > 0 ? r.counter.slice(at + 3) : r.counter;
    counterEl.textContent = tail.charAt(0).toUpperCase() + tail.slice(1);
    counterEl.dataset.tip = r.counter;
    const sel = grid.getSelection();
    const visible = grid.getVisibleRows();
    const shownIds = new Set(visible.map((v) => v.id));
    const selectedShown = sel.filter((s) => shownIds.has(s.id));
    absenceEl.dataset.tip = `${r.absence} ${scopeSummary({ mode: st.scopeMode, visible: visible.length, loaded: st.rows.length, selected: selectedShown.length, selectedHidden: sel.length - selectedShown.length, complete: r.complete, limit: r.limit })}`;
    modeInk.update();
  }

  moreEl.addEventListener('click', (e) => {
    const b = e.target instanceof Element ? e.target.closest('[data-more]') : null;
    if (b) o.onMore(Number(b.dataset.more));
  });
  host.querySelector('.rch-scope-mode').addEventListener('click', (e) => {
    const b = e.target instanceof Element ? e.target.closest('[data-mode]') : null;
    if (!b) return;
    st.scopeMode = b.dataset.mode;
    host.querySelectorAll('[data-mode]').forEach((x) => x.setAttribute('aria-pressed', String(x === b)));
    paintFoot();
    announce(st.scopeMode === 'selected' ? 'Portée des exports et relevés : lignes sélectionnées.' : 'Portée des exports et relevés : liste affichée.');
  });
  host.querySelector('.rch-sets').addEventListener('click', (e) => {
    const b = e.target instanceof Element ? e.target.closest('[data-set]') : null;
    if (b) setColumnSet(b.dataset.set, true);
  });

  /** Explicit view choice (never automatic, never while typing): columns, widths and sort kept per view. */
  function setColumnSet(set, user = false) {
    if (!SETS.some((s) => s.id === set)) return;
    st.set = set;
    writeLayout('rechercher.results', { set });
    host.querySelectorAll('[data-set]').forEach((x) => x.setAttribute('aria-pressed', String(x.dataset.set === set)));
    setsInk.update();
    grid.setColumns(columnsFor(set, st.mode), { key: `rechercher.${set}${st.mode.address ? '.adresse' : st.mode.verdict ? '.requete' : ''}` });
    applyFilters({ quick: st.quick, facets: [...st.facets], presence: st.presence });
    host.querySelectorAll('[data-set]').forEach((b) => { if (b.dataset.set === set) b.classList.remove('suggest'); });
    if (user) announce(`Vue ${SETS.find((s) => s.id === set).label} : colonnes et tri de cette vue.`);
  }

  // ---------- Launchpad (before any read) ----------

  function paintLaunch(data = {}) {
    const recents = (data.recents ?? []).filter((r) => r.kind === 'search').slice(0, 8);
    const views = (data.views ?? []).slice(0, 6);
    launch.innerHTML = `<div class="rch-launch-in">
      <div class="rch-launch-hero">
        <span class="rch-launch-art" aria-hidden="true"><span class="rch-orbit"></span><span class="rch-orbit b"></span>${glyph('search')}</span>
        <h3>Que cherchez-vous${NBSP}?</h3>
        <p>Rien n’est lu avant votre geste${COLON}tapez un nom puis Entrée, choisissez une OU dans l’arbre, ou une requête prête.</p>
      </div>
      <div class="rch-launch-grid">
        <div class="rch-launch-col">
        <section class="rch-launch-card" data-k="recents"><h4>${glyph('history')}Recherches récentes</h4>
          ${recents.length ? `<div class="rch-launch-chips">${recents.map((r, n) => `<button class="chip rch-lchip" type="button" data-search="${esc(r.text)}" data-j="${n}">${glyph('history')}${esc(r.text)}</button>`).join('')}</div>` : '<p class="rch-launch-none">Vos huit dernières recherches apparaîtront ici, sur ce poste seulement.</p>'}
        </section>
        <section class="rch-launch-card" data-k="syntax"><h4>${glyph('sparkles')}Syntaxe facultative</h4>
          <div class="rch-launch-syntax">${SYNTAX.map((s, n) => `<button class="rch-lsyn" type="button" data-search="${esc(s.text)}" data-tip="${esc(s.tip)}" data-j="${n}">${glyph(s.icon)}<span><code>${esc(s.text)}</code><small>${esc(s.label)}</small></span></button>`).join('')}</div>
        </section>
        </div>
        <section class="rch-launch-card" data-k="views"><h4>${glyph('database')}Requêtes prêtes</h4>
          <div class="rch-launch-views">${views.map((v, n) => `<button class="rch-lview" type="button" data-view="${esc(v.id)}" data-j="${n}" data-tip="${esc(v.name)}"><span class="rch-lview-ico">${glyph(v.local ? 'disk' : v.typeLabel === 'Postes' ? 'monitor' : 'user')}</span><span><b>${esc(v.name)}</b><small>${esc(v.category)} · ${esc(v.typeLabel)}</small></span></button>`).join('')}</div>
          <button class="btn ghost sm rch-launch-all" type="button" data-act="catalog">${glyph('layers')}Toutes les requêtes</button>
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
    fbarHost.hidden = on;
  }

  // ---------- Results ----------

  function headerFor(r) {
    const kindText = { search: 'Recherche', browse: 'Contenu', view: 'Requête prête', address: 'Recherche par adresse', localQuery: 'Requête locale' }[r.kind] ?? 'Liste';
    kindEl.textContent = kindText;
    host.querySelector('.rch-res-kind').dataset.kind = r.kind;
    let text;
    if (r.kind === 'search') text = r.text ? quote(r.text) : 'Recherche';
    else if (r.kind === 'browse') text = r.scope.wholeDomain ? 'Tout le domaine' : r.scope.path.split(`${NBSP}› `).at(-1);
    else if (r.view) text = r.view.name;
    else text = r.text || 'Résultats';
    title.textContent = text;
    title.classList.remove('swap');
    void title.offsetWidth;
    title.classList.add('swap');
    scopeEl.textContent = r.scope.label + (r.type !== 'all' ? ` · ${typeLabel(r.type)}` : '');
    scopeEl.dataset.tip = r.scope.path ? `${r.scope.label} — ${r.scope.path}` : r.scope.label;
    // The path of the OU follows its name on the title line while browsing; lists with a long title keep the scope sentence.
    const showCrumbs = r.kind === 'browse' && !r.scope.wholeDomain;
    crumbsEl.hidden = !showCrumbs;
    if (showCrumbs) {
      if (!crumbs) crumbs = createDnBreadcrumb(crumbsEl, { dn: r.scope.dn, onNavigate: (dn) => o.onBrowseDn(dn), maxVisible: 4 });
      else crumbs.setDn(r.scope.dn);
    }
    freshEl.innerHTML = freshness(r.readAt, { staleAfter: 30 * 60_000, label: r.kind === 'address' || r.kind === 'localQuery' ? 'Relevés lus' : 'Annuaire lu', source: r.sourceLabel });
    startFreshness(freshEl);
  }

  // The three verdicts of a local query are both the totals and the choice of the rows shown (Domenia 1 RCH-102).
  function verdictChoice(v) {
    const shown = { Correspondants: 'match', Inconnus: 'unknown', 'Non correspondants': 'noMatch' }[v.shown] ?? 'all';
    const items = [['match', 'Correspondants', v.match, 'ok'], ['unknown', 'Inconnus', v.unknown, 'off'], ['noMatch', 'Non correspondants', v.noMatch, 'info'], ['all', 'Tous', v.match + v.unknown + v.noMatch, 'all']];
    return `<span class="rch-verdicts" role="group" aria-label="Postes affichés">${items.map(([id, label, n, tone]) => `<button type="button" class="rch-verdict${id === shown ? ' on' : ''}" data-act="${id}" data-tone="${tone}" aria-pressed="${id === shown}"><span class="rch-verdict-dot" aria-hidden="true"></span>${label}<b>${int(n)}</b></button>`).join('')}</span>`;
  }

  function noticesFor(r, restored) {
    const plan = r.plan;
    // The bar already explains its plan; a costly one (leading wildcard, « contient ») stays visible over the list.
    setNotice('plan', plan.hint && plan.costly && (r.kind === 'search' || r.kind === 'address') ? { tone: 'warn', icon: 'alert', html: esc(plan.hint) } : null);
    const first = (text) => { const at = text.search(/[.:](\s|$)/); return at > 0 ? text.slice(0, at + 1) : text; };
    setNotice('view', r.view ? {
      tone: r.view.surveyAllowed ? 'info' : 'warn', icon: r.kind === 'localQuery' ? 'disk' : 'database',
      html: `<details class="rch-note-more"><summary><b>${esc(r.view.name)}</b>${COLON}${esc(first(r.view.note))}${r.view.reason ? ` <span class="rch-notice-warn">${esc(r.view.reason.split(COLON)[0])}.</span>` : ''}</summary><p>${esc(r.view.note)}${r.view.reason ? ` ${esc(r.view.reason)}` : ''}</p></details>${r.verdicts ? verdictChoice(r.verdicts) : ''}`,
      run: (act) => o.onVerdict?.(act),
    } : null);
    setNotice('offer', r.offer ? {
      tone: 'accent', icon: 'sparkles', html: `${esc(r.offer.label)}<span class="rch-notice-sub">${esc(r.offer.tip)}</span>`,
      actions: [{ id: 'contains', label: 'Chercher les noms qui contiennent', icon: 'search', kind: 'network', primary: true }], run: () => o.onContains(r.offer.term),
    } : null);
    setNotice('dns', r.dns ? {
      tone: 'info', icon: 'wifi', html: `Aucun poste n’a relevé l’adresse ${esc(r.dns.ip)} dans la base locale. <span class="rch-notice-sub">${esc(r.dns.tip)}</span>`,
      actions: [{ id: 'dns', label: r.dns.label, icon: 'search', kind: 'network', primary: true }], run: () => o.onDns(r.dns.ip),
    } : null);
    // A list of one kind suggests its column set: its button glows; the view changes only on a click (Domenia 1 RCH-053).
    const kinds = new Set(r.rows.map((x) => x.kind));
    const fit = kinds.size === 1 ? ({ user: 'users', computer: 'computers' }[[...kinds][0]] ?? null) : null;
    host.querySelectorAll('[data-set]').forEach((b) => {
      const on = b.dataset.set === fit && st.set !== fit && r.rows.length > 1;
      b.classList.toggle('suggest', on);
      b.dataset.tip = on ? `Vue conseillée pour cette liste de ${fit === 'users' ? 'comptes' : 'postes'} : un clic l’applique` : SETS.find((x) => x.id === b.dataset.set).tip;
    });
    setNotice('history', restored ? {
      tone: 'warn', icon: 'history', html: `Liste de l’historique, non relue${COLON}${esc(r.counter)}. Relisez-la avec son périmètre, sa vue et ses filtres.`,
      actions: [{ id: 'refresh', label: 'Actualiser', icon: 'refresh', kind: 'network' }], run: () => o.onRefresh(),
    } : null);
  }

  ready = true;

  return {
    grid,
    get state() { return st; },
    get set() { return st.set; },
    get scopeMode() { return st.scopeMode; },
    result: () => st.result,
    rows: () => st.rows,
    setNotice,
    launch(data) { paintLaunch(data); showLaunch(true); title.textContent = 'Prêt à chercher'; scopeEl.textContent = 'Rien n’est lu avant votre geste.'; kindEl.textContent = 'Résultats'; },
    refreshLaunch(data) { if (!launch.hidden) paintLaunch(data); },
    setLoading(label) {
      showLaunch(false);
      grid.setLoading(true);
      grid.setEmpty(emptyState('nothing'));
      host.classList.add('loading');
      if (label) { title.textContent = label; scopeEl.textContent = 'Lecture en cours…'; }
    },
    setError(err, retry) {
      host.classList.remove('loading');
      showLaunch(false);
      const code = err?.code ?? '';
      if (code === 'source.unavailable') { grid.setRows([]); grid.setEmpty({ ...emptyState('nosource'), text: err.message }); }
      else grid.setError(err?.message ?? 'La lecture a échoué.', retry ? { retry } : undefined);
    },
    /** Shows a new list (or a list restored from the history, without any read). */
    show(r, { restored = false, selection = [], quick = '', facets = [], presence = null, scroll = 0, set = null } = {}) {
      host.classList.remove('loading');
      showLaunch(false);
      const mode = { address: r.kind === 'address', mac: r.kind === 'address' && r.plan.address?.kind === 'mac', verdict: r.kind === 'localQuery', needle: r.kind === 'search' && r.match !== 'contains' ? (r.plan.freeText || r.text).replace(/\*/g, '').split(/\s+/)[0] : '' };
      const modeChanged = JSON.stringify(mode) !== JSON.stringify(st.mode);
      st.mode = mode;
      st.result = r;
      st.rows = r.rows.slice();
      st.undo = [];
      paintUndo();
      if (set && set !== st.set) setColumnSet(set);
      else if (modeChanged) grid.setColumns(columnsFor(st.set, mode), { key: `rechercher.${st.set}${mode.address ? '.adresse' : mode.verdict ? '.requete' : ''}` });
      grid.setEmpty(emptyState(st.rows.length ? 'nothing' : 'noresult', { query: r.text, scope: r.scope.label }));
      grid.setRows(st.rows, { hasMore: false, keepSelection: false });
      applyFilters({ quick, facets, presence });
      if (selection.length) grid.select(selection);
      if (scroll) grid.el.querySelector('.k-gscroll')?.scrollTo({ top: scroll });
      headerFor(r);
      noticesFor(r, restored);
      paintFoot();
      paintCount();
      host.classList.remove('arrived');
      void host.offsetWidth;
      host.classList.add('arrived');
    },
    /** Rows of « Charger la suite » (only the following ones). */
    append(r) {
      st.result = { ...r, rows: st.rows.concat(r.rows) };
      st.rows = st.rows.concat(r.rows);
      grid.appendRows(r.rows, { hasMore: false });
      paintFacets();
      paintFoot();
      paintCount();
      announce(`${count(r.rows.length, 'ligne ajoutée', 'lignes ajoutées')}. ${r.counter}.`);
    },
    /** Replaces rows read again (survey, recheck, revalidation): cells change in place with a flash, nothing else moves. */
    updateRows(rows, { pending = false } = {}) {
      const byId = new Map(rows.map((x) => [x.id, x]));
      let changed = 0;
      st.rows = st.rows.map((x) => {
        const y = byId.get(x.id);
        if (!y) return x;
        changed++;
        return pending ? { ...x, _pending: true } : y;
      });
      grid.setRows(st.rows, { keepSelection: true, keepScroll: true });
      for (const id of byId.keys()) grid.updateRow(id);
      paintFacets();
      paintCount();
      return changed;
    },
    /** Marks rows no longer found by a revalidation (« à revérifier »), never removes them. */
    markMissing(ids) {
      const set = new Set(ids);
      st.rows = st.rows.map((x) => (set.has(x.id) ? { ...x, state: { key: x.state.key, label: `${x.state.label} · à revérifier`, tone: 'warn' } } : x));
      grid.setRows(st.rows, { keepSelection: true, keepScroll: true });
    },
    setColumnSet,
    filters: () => ({ quick: st.quick, facets: [...st.facets], presence: st.presence }),
    scrollTop: () => grid.el.querySelector('.k-gscroll')?.scrollTop ?? 0,
    selectionLabel: () => { const sel = grid.getSelection(); return selectionText(sel.length, sel.filter((s) => s.kind === 'computer').length); },
    destroy() { setsInk.stop(); modeInk.stop(); pushUndo.cancel(); crumbs?.destroy(); fbar.destroy(); grid.destroy(); host.replaceChildren(); },
  };
}

/** Splits the association cell of the CSV back into three columns: association, source and qualification. */
export function expandAssociation(csv) {
  const SEP_MARK = '␟';
  if (!csv.includes(SEP_MARK) && !csv.includes('Association mémorisée')) return csv;
  const rows = parseCsv(csv.replace(/^﻿/, ''));
  if (!rows.length) return csv;
  const at = rows[0].indexOf('Association mémorisée');
  if (at < 0) return csv;
  const hasSource = rows[0].includes('Source lien');
  const hasQual = rows[0].includes('Qualification');
  const out = rows.map((cells, n) => {
    const value = cells[at] ?? '';
    const [label, source = '', qual = ''] = n === 0 ? [value] : value.split(SEP_MARK);
    const extra = n === 0 ? [hasSource ? null : 'Source lien', hasQual ? null : 'Qualification'] : [hasSource ? null : source, hasQual ? null : qual];
    const next = cells.slice();
    next.splice(at, 1, label, ...extra.filter((x) => x !== null));
    return next;
  });
  const cell = (v) => (/[;"\r\n]/.test(v) ? `"${v.replace(/"/g, '""')}"` : v);
  return `﻿${out.map((cells) => cells.map(cell).join(';')).join('\r\n')}`;
}

function parseCsv(text) {
  const rows = [];
  let row = [];
  let cur = '';
  let quoted = false;
  for (let n = 0; n < text.length; n++) {
    const c = text[n];
    if (quoted) {
      if (c === '"' && text[n + 1] === '"') { cur += '"'; n++; } else if (c === '"') quoted = false; else cur += c;
    } else if (c === '"') quoted = true;
    else if (c === ';') { row.push(cur); cur = ''; } else if (c === '\n' || c === '\r') {
      if (c === '\r' && text[n + 1] === '\n') n++;
      row.push(cur); rows.push(row); row = []; cur = '';
    } else cur += c;
  }
  if (cur || row.length) { row.push(cur); rows.push(row); }
  return rows;
}
