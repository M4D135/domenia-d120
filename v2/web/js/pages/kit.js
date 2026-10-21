// Hidden #/kit screen: living showcase of every kit component, with local fictitious data (example.local, invented
// names). Reference for the screens being ported and control capture. Nothing here calls the bridge: no read, no
// write. Parameters: #/kit?section=<id> scrolls to a section; &open=drawer|dialog|confirm|menu opens a demo.
import { icon } from '../icons.js';
import { esc, applyVars, reveal, toast, motionReduced } from '../ui.js';
import {
  glyph, NBSP, int, count, quote, createGrid, openMenu, bindContextMenu, openDrawer, openDialog, confirmDialog, confirmWrite,
  createTree, createCommandBar, createDnBreadcrumb, field, createForm, createSplit, kvSection, bindKv, timeline,
  bindTimeline, pill, statePill, STATES, gauge, animateGauges, createFilterBar, createTabs, createInfinite, copyButton,
  bindCopy, freshness, startFreshness, touchFreshness,
} from '../kit/index.js';

export const meta = { label: 'Kit d’interface', icon: 'sparkles' };

const MIN = 60_000;
const DAY = 86_400_000;
const ROWS = 12_000;
const MORE_ROWS = 2_000;
const MAX_ROWS = 16_000;
const DOMAIN_DN = 'DC=example,DC=local';

// ---------- Fictitious data (deterministic) ----------

function rng(seed) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6D2B79F5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

const FIRST = ['Camille', 'Léa', 'Hugo', 'Lucas', 'Chloé', 'Manon', 'Louis', 'Emma', 'Jules', 'Inès', 'Nathan', 'Sarah', 'Théo', 'Zoé', 'Arthur',
  'Jade', 'Gabriel', 'Lina', 'Raphaël', 'Alice', 'Noé', 'Rose', 'Adam', 'Anna', 'Paul', 'Juliette', 'Victor', 'Margaux', 'Tom', 'Clara'];
const LAST = ['Martin', 'Bernard', 'Dubois', 'Thomas', 'Robert', 'Richard', 'Petit', 'Durand', 'Leroy', 'Moreau', 'Simon', 'Laurent', 'Lefèvre',
  'Michel', 'Garcia', 'Bertrand', 'Roux', 'Vincent', 'Fournier', 'Morel', 'Girard', 'André', 'Mercier', 'Dupont', 'Lambert', 'Bonnet',
  'François', 'Legrand', 'Garnier', 'Chevalier'];
const SITES = [['PAR', 'Paris'], ['LYO', 'Lyon'], ['LIL', 'Lille'], ['NAN', 'Nantes'], ['MAR', 'Marseille'], ['BOR', 'Bordeaux']];
const SERVICES = ['Direction', 'Comptabilité', 'Ressources humaines', 'Informatique', 'Accueil', 'Logistique', 'Juridique', 'Communication'];
const OSES = ['Windows 11 Entreprise 24H2', 'Windows 11 Entreprise 23H2', 'Windows 10 Entreprise 22H2', 'Windows Server 2022'];
const DESCRIPTIONS = ['Poste d’accueil', 'Portable nomade', 'Salle de réunion', 'Poste partagé', 'Compte de service', 'Stagiaire', 'Prestataire', ''];

const strip = (s) => s.normalize('NFD').replace(/\p{Diacritic}/gu, '').toLowerCase().replace(/[^a-z]/g, '');
const pad = (n, w) => String(n).padStart(w, '0');
const guidOf = (r) => [8, 4, 4, 4, 12].map((w) => Array.from({ length: w }, () => Math.floor(r() * 16).toString(16)).join('')).join('-');

function makeRows(from, n, now) {
  const r = rng(20261021 + from);
  const out = [];
  for (let k = 0; k < n; k++) {
    const i = from + k;
    const [code, city] = SITES[Math.floor(r() * SITES.length)];
    const service = SERVICES[Math.floor(r() * SERVICES.length)];
    const isPc = r() < 0.42;
    const ageDays = r() < 0.06 ? null : Math.floor(Math.pow(r(), 2.2) * 420);
    const last = ageDays === null ? null : new Date(now - ageDays * DAY - Math.floor(r() * DAY)).toISOString();
    const modified = new Date(now - Math.floor(r() * 200) * DAY - Math.floor(r() * DAY)).toISOString();
    if (isPc) {
      const name = `${r() < 0.7 ? 'PC' : 'PT'}-${code}-${pad(i % 10000, 4)}`;
      const ou = `OU=Postes,OU=${city},OU=Sites`;
      const presence = ageDays === null ? 'unchecked' : ageDays < 2 ? (r() < 0.82 ? 'online' : 'silent') : ageDays > 60 ? 'silent' : (r() < 0.5 ? 'online' : 'unchecked');
      out.push({
        guid: guidOf(r), type: 'computer', name, account: `${name}$`, upn: `${name.toLowerCase()}.example.local`,
        state: ageDays !== null && ageDays > 300 ? 'disabled' : 'active', presence, lastLogon: last, os: OSES[Math.floor(r() * OSES.length)],
        ou: `${city} › Postes`, dn: `CN=${name},${ou},${DOMAIN_DN}`, modified, logons: Math.floor(r() * 120),
        description: DESCRIPTIONS[Math.floor(r() * DESCRIPTIONS.length)],
      });
    } else {
      const first = FIRST[Math.floor(r() * FIRST.length)];
      const lastName = LAST[Math.floor(r() * LAST.length)];
      const account = `${strip(first).slice(0, 1)}${strip(lastName)}${i % 97 === 0 ? '' : pad(i % 1000, 3)}`.slice(0, 20);
      const roll = r();
      const state = roll < 0.05 ? 'locked' : roll < 0.12 ? 'disabled' : roll < 0.16 ? 'expired' : 'active';
      out.push({
        guid: guidOf(r), type: 'user', name: `${first} ${lastName}`, account, upn: `${account}@example.local`, state, presence: null,
        lastLogon: last, os: null, ou: `${city} › ${service}`, dn: `CN=${first} ${lastName},OU=${service},OU=${city},OU=Sites,${DOMAIN_DN}`,
        modified, logons: Math.floor(r() * 400), description: roll > 0.9 ? 'Compte temporaire' : '',
      });
    }
  }
  return out;
}

const COLUMNS = [
  { id: 'type', label: 'Type', type: 'enum', width: 130, options: [{ value: 'user', label: 'Utilisateur', tone: 'info' }, { value: 'computer', label: 'Poste', tone: 'accent' }] },
  { id: 'name', label: 'Nom', width: 210, required: true },
  { id: 'account', label: 'Compte', width: 160, mono: true },
  { id: 'upn', label: 'UPN / DNS', width: 250 },
  { id: 'state', label: 'État', type: 'enum', width: 140, options: [
    { value: 'active', label: 'Actif', tone: 'ok' }, { value: 'disabled', label: 'Désactivé', tone: 'off' },
    { value: 'locked', label: 'Verrouillé', tone: 'alert' }, { value: 'expired', label: 'Expiré', tone: 'warn' }] },
  { id: 'presence', label: 'Présence réseau', type: 'enum', width: 160, tip: 'Une absence de réponse au ping n’est jamais un verdict d’arrêt.', options: [
    { value: 'online', label: 'En ligne', tone: 'ok' }, { value: 'silent', label: 'Sans réponse', tone: 'warn' }, { value: 'unchecked', label: 'Non vérifié', tone: 'off' }] },
  { id: 'lastLogon', label: 'Dernière connexion', type: 'date', width: 170 },
  { id: 'logons', label: 'Connexions (30 j)', type: 'number', width: 150 },
  { id: 'os', label: 'Système', width: 220 },
  { id: 'ou', label: 'Emplacement', width: 200 },
  { id: 'modified', label: 'Modifié', type: 'date', width: 150, hidden: true },
  { id: 'description', label: 'Description', width: 200, hidden: true },
  { id: 'dn', label: 'Chemin complet (DN)', width: 380, mono: true, hidden: true },
  { id: 'guid', label: 'GUID', width: 300, mono: true, hidden: true },
];

// Fictitious OU tree: latency, a branch refused, a branch of 900 children (virtualized).
function treeChildren(node) {
  const id = node.id;
  if (id === 'root') {
    return [
      { id: 'sites', label: 'Sites', hint: '6' },
      { id: 'services', label: 'Services centraux', hint: '8' },
      { id: 'groupes', label: 'Groupes', hint: '3' },
      { id: 'archives', label: 'Archives', hint: 'protégée' },
      { id: 'builtin', label: 'Builtin', selectable: false, icon: 'folder', hint: 'conteneur' },
    ];
  }
  if (id === 'archives') throw Object.assign(new Error('denied'), { code: 'demo.denied', message: 'Lecture refusée : droits insuffisants sur cette branche (démonstration).' });
  if (id === 'sites') return SITES.map(([code, city]) => ({ id: `site-${code}`, label: city, hint: code }));
  if (id.endsWith('-postes')) {
    const code = id.slice(5, 8);
    const n = code === 'PAR' ? 900 : 120;
    return Array.from({ length: n }, (_, k) => ({ id: `${id}-${k}`, label: `PC-${code}-${pad(k + 1, 4)}`, leaf: true, icon: 'monitor' }));
  }
  if (id.endsWith('-users')) return SERVICES.map((s, k) => ({ id: `${id}-${k}`, label: s, hint: String(12 + k * 7), leaf: true, icon: 'users' }));
  if (id.startsWith('site-')) {
    const code = id.slice(5);
    return [
      { id: `${id}-postes`, label: 'Postes', hint: code === 'PAR' ? '900' : '120' },
      { id: `${id}-users`, label: 'Utilisateurs', hint: '240' },
      { id: `${id}-imprimantes`, label: 'Imprimantes', leaf: true, icon: 'monitor' },
    ];
  }
  if (id === 'services') return SERVICES.map((s, k) => ({ id: `svc-${k}`, label: s, children: [] }));
  if (id === 'groupes') return [{ id: 'g-1', label: 'Groupes de sécurité', hint: '42' }, { id: 'g-2', label: 'Listes de diffusion', hint: '18' }, { id: 'g-3', label: 'Délégations', hint: '6' }];
  return [];
}

const wait = (ms) => new Promise((resolve) => { setTimeout(resolve, ms); });

// ---------- Page layout ----------

const SECTIONS = [
  { id: 'disposition', title: 'Disposition', icon: 'columns', text: 'Grille de 12 colonnes, espacements de 4 px, hiérarchie des titres et place des actions.' },
  { id: 'grille', title: 'Grille de données', icon: 'rows', text: '12 000 lignes fictives : tri multi-colonnes (Maj clic), filtres par colonne et filtre rapide, colonnes choisies, déplacées (glisser) et redimensionnées, sélection au clavier et à la souris, menu contextuel, double clic, copie et CSV, disposition mémorisée.' },
  { id: 'commandes', title: 'Barre de commandes', icon: 'zap', text: 'Actions principales en boutons, le reste dans « Plus » ; ce qui ne tient pas en largeur y passe tout seul.' },
  { id: 'filtres', title: 'Barre de filtres', icon: 'filter', text: 'Filtres rapides, critères retirables avec leur portée, phrase de combinaison.' },
  { id: 'fil', title: 'Fil d’Ariane de DN', icon: 'ou', text: 'Domaine en texte seul, chaque OU ouvre sa branche, milieu replié pour les chemins longs, copie du DN.' },
  { id: 'arbre', title: 'Arborescence paresseuse', icon: 'tree', text: 'Lecture à l’ouverture d’une branche, une seule à la fois ; recherche dans les branches déjà lues ; clavier complet.' },
  { id: 'panneaux', title: 'Panneau latéral', icon: 'panel', text: 'À droite ou à gauche, redimensionnable, piège de focus ; un seul panneau modal à la fois.' },
  { id: 'dialogues', title: 'Dialogues et confirmation', icon: 'shield', text: 'Toujours dans la page. Les écritures demandent la saisie exacte du nom de la cible.' },
  { id: 'menus', title: 'Menus', icon: 'more', text: 'Menu contextuel (clic droit, Maj F10, touche Menu) et menu déroulant : sous-menus, cases, choix unique, raisons des actions grisées.' },
  { id: 'formulaires', title: 'Formulaires', icon: 'edit', text: 'Champ, liste, case, interrupteur, date, choix ; erreurs, avertissements et confirmations.' },
  { id: 'maitre', title: 'Vue maître-détail', icon: 'split', text: 'Deux volets et un séparateur glissant, mémorisé, repliable ; empilés sous 720 px.' },
  { id: 'fiche', title: 'Fiche clé/valeur', icon: 'object', text: 'Sections repliables, valeurs copiables, absences dites comme telles.' },
  { id: 'chrono', title: 'Chronologie', icon: 'history', text: 'Événements regroupés par jour, ton et icône par événement.' },
  { id: 'etats', title: 'États, fraîcheur et copie', icon: 'activity', text: 'Vocabulaire commun des états, indicateur de fraîcheur, copie en un clic.' },
  { id: 'jauges', title: 'Jauges', icon: 'gauge', text: 'Demi-cadran et barre, tons selon les seuils, mesure absente jamais affichée à 0.' },
  { id: 'onglets', title: 'Onglets', icon: 'layers', text: 'Encre glissante, compteurs, contenu calculé à la première ouverture seulement.' },
  { id: 'suite', title: 'Pagination infinie', icon: 'arrowDown', text: 'La suite se lit sur un clic (lecture réseau) ou à l’approche de la fin (lecture locale seulement).' },
];

const CODE = {
  grille: `import { createGrid } from '../kit/index.js';

const grid = createGrid(host, {
  key: 'rechercher.resultats',          // disposition mémorisée
  label: 'Résultats de la recherche',
  columns: [
    { id: 'name', label: 'Nom', required: true, width: 220 },
    { id: 'state', label: 'État', type: 'enum', options: [
      { value: 'active', label: 'Actif', tone: 'ok' },
      { value: 'locked', label: 'Verrouillé', tone: 'alert' }] },
    { id: 'lastLogon', label: 'Dernière connexion', type: 'date' },
  ],
  rowId: (row) => row.guid,
  loading: true,
  onActivate: (row) => openObject(row),
  contextMenu: ({ rows }) => [{ label: 'Ouvrir la fiche', icon: 'object', run: () => … }],
});
const data = await ctx.call('search.run', { … });   // la page lit, la grille affiche
grid.setRows(data.rows, { hasMore: data.truncated });`,
  commandes: `createCommandBar(host, { label: 'Actions de la liste', items: [
  { id: 'search', label: 'Rechercher', icon: 'search', primary: true, run },
  { id: 'check', label: 'Vérifier la liste', icon: 'wifi', kind: 'network', run },
  { id: 'disable', label: 'Désactiver', icon: 'power', kind: 'write', danger: true,
    disabled: readOnly, reason: 'Lecture seule : activez le mode écriture.', run },
]});`,
  filtres: `const bar = createFilterBar(host, {
  chips: [{ id: 'ou', label: 'Périmètre', value: 'Postes', removable: false },
          { id: 'type', label: 'Type', value: 'Postes', scope: 'Annuaire',
            removeTip: 'Relit l’OU sans ce type' }],
  facets: [{ id: 'online', label: 'En ligne', count: 287 }],
  onRemove: (id) => …, onToggle: (id, pressed) => …,
});
bar.setSummary('→ 245 lignes affichées sur 1 234');`,
  fil: `createDnBreadcrumb(host, {
  dn: 'CN=PC-PAR-0042,OU=Postes,OU=Paris,OU=Sites,DC=example,DC=local',
  onNavigate: (dn) => ctx.navigate('rechercher', { ou: dn }),
});`,
  arbre: `const tree = createTree(host, {
  label: 'Unités d’organisation',
  roots: () => ctx.call('tree.roots'),
  load: (node) => ctx.call('tree.children', { dn: node.id }),
  onSelect: (node, how) => showOu(node),   // clavier : après 300 ms
  contextMenu: (node) => [{ label: 'Copier le chemin (DN)', … }],
});`,
  panneaux: `const panel = openDrawer({
  title: 'PC-PAR-0042', subtitle: 'Poste · Paris', icon: 'monitor',
  side: 'right', key: 'fiche.apercu', body: node,
  actions: [{ id: 'open', label: 'Ouvrir la fiche', primary: true, run: (p) => … }],
});
await panel.closed;`,
  dialogues: `const answer = await confirmWrite({
  title: 'Désactiver le compte',
  message: 'Le compte ne pourra plus ouvrir de session.',
  target: 'cmartin012', targetKind: 'Compte',
  changes: [{ label: 'État', before: 'Activé', after: 'Désactivé' }],
  details: plan.text,
});
if (answer === 'confirm') await ctx.call('account.disable', { plan: plan.id });`,
  menus: `openMenu(anchorOrEvent, [
  { label: 'Ouvrir la fiche', icon: 'object', kbd: 'Entrée', run },
  { label: 'Copier', icon: 'copy', items: [ … ] },
  '-',
  { label: 'Désactiver…', icon: 'power', danger: true, disabled: true,
    reason: 'Lecture seule.' },
]);
bindContextMenu(zone, () => items);`,
  formulaires: `form.innerHTML = field({ name: 'host', label: 'Nom du poste', required: true,
  pattern: '[A-Z0-9-]{3,15}', patternMessage: 'Majuscules, chiffres et tirets.' })
  + field({ name: 'days', label: 'Durée', type: 'number', min: 1, max: 365 });
createForm(form, {
  rules: { days: (v) => (v > 180 ? { warn: 'Durée longue.' } : null) },
  onSubmit: (values) => …,
});`,
  maitre: `const split = createSplit(host, { a: list, b: detail, key: 'comptes.detail', size: 420 });`,
  fiche: `host.innerHTML = kvSection({ id: 'identite', title: 'Identité', icon: 'user', items: [
  { label: 'Compte', value: 'cmartin012', mono: true, copy: true },
  { label: 'Courriel', value: null },
]});
bindKv(host, { key: 'fiche.utilisateur' });`,
  chrono: `host.innerHTML = timeline(events);   // [{ when, title, text, tone, icon, actor }]
bindTimeline(host);`,
  etats: `statePill('running');          // En cours
pill('warn', 'Sans réponse', { pulse: true });
freshness(readAt, { staleAfter: 15 * 60_000, source: 'Annuaire' });
copyButton(dn, { label: 'Copier le DN', done: 'Chemin copié' });`,
  jauges: `host.innerHTML = gauge({ value: 72, label: 'Disque C:', thresholds: { warn: 80, alert: 90 } });
animateGauges(host);`,
  onglets: `createTabs(host, { label: 'Fiche', key: 'fiche.onglet', tabs: [
  { id: 'general', label: 'Général', render: (panel) => … },
  { id: 'membres', label: 'Membres', count: 12, render: (panel) => … },
]});`,
  suite: `createInfinite(host, {
  load: (cursor) => ctx.call('ops.page', { after: cursor }),   // { items, next }
  render: (items, list) => list.insertAdjacentHTML('beforeend', …),
});`,
};

const RULES = {
  grille: [
    'La grille ne lit jamais l’annuaire : trier, filtrer et choisir les colonnes restent locaux.',
    'L’identité d’une ligne est son GUID (rowId) : la sélection survit au tri, au filtre et à la relecture.',
    'Une liste partielle propose « Charger la suite » ; une lecture réseau ne part jamais toute seule.',
    'Les colonnes secrètes (secret: true) ne sont ni copiées ni exportées.',
  ],
  commandes: ['Une seule action primary par écran.', 'Une écriture porte kind: \'write\' et passe toujours par confirmWrite.', 'Une action grisée dit pourquoi (reason).'],
  dialogues: ['Jamais de nouvelle fenêtre : dialogues et panneaux vivent dans la page.', 'Le focus va sur la réponse sûre ; Entrée ne confirme pas une écriture tant que le nom n’est pas saisi.', 'Quitter l’écran retire la demande sans rien exécuter.'],
  arbre: ['Une branche se lit une fois par ouverture ; une ouverture pendant la lecture est sans effet.', 'La recherche ne parcourt que les branches déjà lues et le dit.', 'Le domaine entier n’est jamais une cible.'],
};

function sectionMarkup(s) {
  const code = CODE[s.id] ? `<details class="kit-code"><summary>${glyph('chevronRight')}Voir le code</summary><pre><code>${esc(CODE[s.id])}</code></pre></details>` : '';
  const rules = RULES[s.id] ? `<ul class="kit-rules">${RULES[s.id].map((r) => `<li>${esc(r)}</li>`).join('')}</ul>` : '';
  return `<section class="kit-section reveal" id="kit-${s.id}" aria-labelledby="kit-${s.id}-t">
    <header class="kit-section-head"><span class="card-icon">${glyph(s.icon)}</span>
      <div><h2 id="kit-${s.id}-t" tabindex="-1">${esc(s.title)}</h2><p>${esc(s.text)}</p></div></header>
    <div class="card kit-demo" data-demo="${s.id}"></div>
    ${rules}${code}
  </section>`;
}

function layout() {
  const toc = SECTIONS.map((s) => `<a href="#/kit?section=${s.id}" data-toc="${s.id}" data-tip="${esc(s.title)}">${glyph(s.icon)}<span>${esc(s.title)}</span></a>`).join('');
  return `<div class="page kit-page">
    <header class="page-header reveal">
      <div class="head-row"><span class="page-icon">${icon('sparkles')}</span>
        <div class="titles"><h1 class="gradient-text">Kit d’interface</h1>
          <p class="subtitle">Composants partagés de Domenia 2 · données fictives locales, aucune requête</p></div></div>
      <div class="actions"><button class="btn" type="button" data-act="replay">${icon('refresh')}Rejouer les animations</button></div>
    </header>
    <section class="hero reveal">
      <span class="glow-ring" aria-hidden="true"></span>
      <div class="orbs" aria-hidden="true"><span class="orb a"></span><span class="orb b"></span><span class="orb c"></span></div>
      <p class="eyebrow">${icon('sparkles')}Référence des écrans</p>
      <h2>Un seul kit, treize écrans</h2>
      <p class="lead">Chaque écran de Domenia 2 assemble ces composants : mêmes gestes, mêmes textes, mêmes garde-fous.
        Lecture seule par défaut, aucune lecture réseau sans geste explicite, écritures toujours confirmées dans la page.</p>
      <div class="kit-hero-stats">
        ${pill('accent', `${SECTIONS.length - 1} composants`, { icon: 'layers' })}
        ${pill('info', `${int(ROWS)} lignes fictives`, { icon: 'rows' })}
        ${statePill('readonly')}
        ${pill('ok', 'Clavier et lecteur d’écran', { icon: 'check' })}
      </div>
    </section>
    <div class="kit-layout">
      <nav class="kit-toc" aria-label="Sections du kit"><span class="kit-toc-title">Sections</span>${toc}</nav>
      <div class="kit-sections">${SECTIONS.map(sectionMarkup).join('')}</div>
    </div>
  </div>`;
}

// ---------- Demos ----------

function demoDisposition(host) {
  host.innerHTML = `<div class="kit-stack">
    <span class="kit-label">Grille de 12 colonnes (.grid, .span-3 à .span-12)</span>
    <div class="kit-swatches" aria-hidden="true"><span class="s12">12 · liste principale</span><span class="s8">8 · contenu</span><span class="s4">4 · aperçu</span>
      <span class="s6">6</span><span class="s6">6</span><span class="s3">3</span><span class="s3">3</span><span class="s3">3</span><span class="s3">3</span></div>
    <span class="kit-label">Espacements (grille de 4 px : --s1 à --s12)</span>
    <div class="kit-spacing" aria-hidden="true">${[1, 2, 3, 4, 5, 6, 8, 10, 12].map((n) => `<span><i class="h${n}"></i>s${n}</span>`).join('')}</div>
    <span class="kit-label">Hiérarchie</span>
    <div class="kit-row"><span class="k-pill accent sm">h1 · titre d’écran, un seul</span><span class="k-pill info sm">h2 · section</span>
      <span class="k-pill sm">h3 · titre de carte</span><span class="k-pill sm">h4 · sous-groupe</span></div>
  </div>`;
}

function demoGrid(host, st) {
  host.innerHTML = '<div class="kit-grid-actions"></div><div class="kit-grid-host"></div>';
  const actions = host.querySelector('.kit-grid-actions');
  const now = Date.now();
  let rows = [];
  const grid = createGrid(host.querySelector('.kit-grid-host'), {
    key: 'kit.demo',
    label: 'Objets fictifs de example.local',
    columns: COLUMNS,
    rowId: (row) => row.guid,
    loading: true,
    height: '560px',
    empty: { icon: 'search', title: 'Aucun objet dans cette liste', text: 'Lancez une recherche ou choisissez une OU : rien n’est lu sans votre geste.', action: { label: 'Rétablir les données fictives', icon: 'refresh', run: () => grid.setRows(rows, { hasMore: rows.length < MAX_ROWS }) } },
    onActivate: (row) => openObject(row),
    contextMenu: ({ rows: sel, row }) => [
      { label: 'Ouvrir la fiche', icon: 'object', kbd: 'Entrée', disabled: !row, run: () => openObject(row) },
      { label: 'Vérifier la présence', icon: 'wifi', hint: 'réseau', disabled: !sel.length || sel.some((x) => x.type !== 'computer'), reason: 'Seulement pour des postes.', run: () => toast('Démonstration : aucune requête ne part.', { tone: 'info' }) },
      '-',
      { label: 'Désactiver le compte…', icon: 'power', danger: true, disabled: sel.length !== 1, reason: 'Une seule ligne à la fois.', run: () => demoWrite(sel[0]) },
    ],
    selectionActions: (sel) => [
      { label: 'Vérifier', icon: 'wifi', disabled: sel.some((x) => x.type !== 'computer'), reason: 'Seulement pour des postes.', run: () => toast(`Démonstration${NBSP}: ${count(sel.length, 'poste serait vérifié', 'postes seraient vérifiés')}, aucune requête ne part.`, { tone: 'info' }) },
      { label: 'CSV', icon: 'csv', run: () => grid.exportCsv('selected') },
    ],
    onLoadMore: () => {
      wait(700).then(() => {
        if (!st.alive) return;
        const next = makeRows(rows.length, MORE_ROWS, now);
        rows = rows.concat(next);
        grid.appendRows(next, { hasMore: rows.length < MAX_ROWS });
      });
    },
  });
  st.stops.push(() => grid.destroy());
  wait(650).then(() => {
    if (!st.alive) return;
    rows = makeRows(0, ROWS, now);
    grid.setRows(rows, { hasMore: true });
  });

  const bar = createCommandBar(actions, {
    label: 'Démonstrations de la grille', size: 'sm', items: [
      { id: 'load', label: 'Simuler une lecture', icon: 'refresh', run: () => { grid.setLoading(true); wait(1200).then(() => st.alive && grid.setRows(rows, { hasMore: rows.length < MAX_ROWS })); } },
      { id: 'empty', label: 'Liste vide', icon: 'minus', run: () => grid.setRows([]) },
      { id: 'error', label: 'Erreur', icon: 'alert', run: () => grid.setError('Lecture refusée par le contrôleur (démonstration).', { retry: () => grid.setRows(rows, { hasMore: rows.length < MAX_ROWS }) }) },
      { id: 'filter', label: 'Filtre « verrouillé »', icon: 'filter', run: () => grid.setColumnFilter('state', 'locked') },
      { id: 'reset', label: 'Disposition par défaut', icon: 'columns', run: () => grid.resetLayout() },
    ],
  });
  st.stops.push(() => bar.destroy());
  st.grid = grid;
}

function openObject(row) {
  if (!row) return;
  const isPc = row.type === 'computer';
  const body = document.createElement('div');
  body.className = 'kit-stack';
  body.innerHTML = `<div class="kit-crumb-host"></div>
    <div class="kit-row">${statePill(row.state === 'active' ? 'ready' : 'check', { label: COLUMNS[4].options.find((o) => o.value === row.state)?.label })}
      ${row.presence ? pill(row.presence === 'online' ? 'ok' : row.presence === 'silent' ? 'warn' : 'off', COLUMNS[5].options.find((o) => o.value === row.presence)?.label ?? '') : ''}
      ${freshness(new Date(Date.now() - 4 * MIN).toISOString(), { source: 'Annuaire fictif' })}</div>
    ${kvSection({ id: 'id', title: 'Identité', icon: isPc ? 'monitor' : 'user', items: [
      { label: 'Nom', value: row.name, copy: true },
      { label: 'Compte', value: row.account, mono: true, copy: true },
      { label: isPc ? 'Nom DNS' : 'UPN', value: row.upn, copy: true, wide: true },
      { label: 'Système', value: row.os },
      { label: 'Description', value: row.description },
    ] })}
    ${kvSection({ id: 'ad', title: 'Annuaire', icon: 'database', items: [
      { label: 'Chemin (DN)', value: row.dn, mono: true, copy: true, wide: true },
      { label: 'GUID', value: row.guid, mono: true, copy: true, wide: true },
      { label: 'Connexions (30 j)', value: row.logons },
    ] })}`;
  const crumb = createDnBreadcrumb(body.querySelector('.kit-crumb-host'), { dn: row.dn, maxVisible: 4, onNavigate: (dn) => toast(`Branche demandée${NBSP}: ${dn}`, { tone: 'info' }) });
  const unbind = bindKv(body, { key: 'kit.apercu' });
  startFreshness(body);
  openDrawer({
    title: row.name, subtitle: `${isPc ? 'Poste' : 'Utilisateur'} · ${row.ou}`, icon: isPc ? 'monitor' : 'user', key: 'kit.apercu', body,
    actions: [
      { id: 'close', label: 'Fermer', run: (p) => p.close() },
      { id: 'open', label: 'Ouvrir la fiche', icon: 'object', primary: true, run: (p) => { p.close(); toast('Démonstration : la fiche s’ouvrirait ici (#/fiche?dn=…).', { tone: 'info' }); } },
    ],
    onClose: () => { unbind.destroy(); crumb.destroy(); },
  });
}

function demoWrite(row) {
  const target = row?.account ?? 'PC-PAR-0042$';
  confirmWrite({
    title: 'Désactiver le compte',
    message: 'Le compte ne pourra plus ouvrir de session. Démonstration : rien ne sera envoyé, même après confirmation.',
    target,
    targetKind: row?.type === 'computer' ? 'Compte d’ordinateur' : 'Compte',
    targetDetail: row?.dn ?? `CN=PC-PAR-0042,OU=Postes,OU=Paris,OU=Sites,${DOMAIN_DN}`,
    changes: [
      { label: 'État du compte', before: 'Activé', after: 'Désactivé' },
      { label: 'Description', before: row?.description || '', after: 'Désactivé le 21/10/2026 · ticket 4521' },
    ],
    details: `Plan d’écriture (démonstration)\nCible : ${row?.guid ?? '0f8c…'}\nContrôleur : DC01.example.local\nAttribut : userAccountControl (+ ACCOUNTDISABLE)\nEmpreinte : 7c41 9e02 aa13`,
    alternate: { label: 'Seulement la description' },
  }).then((answer) => {
    if (answer === 'confirm') toast('Confirmé : en vrai, le plan partirait maintenant vers le moteur, puis serait relu. Ici, rien n’est envoyé.', { tone: 'ok' });
    else if (answer === 'alternate') toast('Réponse alternative choisie : rien n’est envoyé (démonstration).', { tone: 'info' });
    else toast('Annulé : rien n’a été envoyé.', { tone: 'info' });
  });
}

function demoCommands(host, st) {
  host.innerHTML = `<div class="kit-stack"><div class="kit-cmd-host"></div>
    <p class="muted">Réduisez la fenêtre : les actions passent dans « Plus » de la fin vers le début ; l’action principale reste.</p>
    <div class="kit-row"><button class="btn sm" type="button" data-busy>${glyph('refresh')}Basculer « Actualiser » occupé</button>
      <button class="btn sm" type="button" data-ro>${glyph('lock')}Basculer la lecture seule</button></div></div>`;
  let readOnly = true;
  let busy = false;
  const items = () => [
    { id: 'search', label: 'Nouvelle recherche', icon: 'search', primary: true, run: () => toast('Nouvelle recherche (démonstration).') },
    { id: 'refresh', label: 'Actualiser', icon: 'refresh', kind: 'read', kbd: 'F5', run: () => toast('Actualiser (démonstration).') },
    { id: 'check', label: 'Vérifier la liste', icon: 'wifi', kind: 'network', run: () => toast('Lecture réseau : en vrai, elle partirait sur ce clic seulement.') },
    { id: 'export', label: 'Exporter', icon: 'csv', items: [{ label: 'CSV des lignes affichées', icon: 'csv', run: () => toast('CSV (démonstration).') }, { label: 'Copier pour un ticket', icon: 'copy', run: () => toast('Copié (démonstration).') }] },
    { id: 'move', label: 'Déplacer…', icon: 'folder', kind: 'write', disabled: readOnly, reason: 'Lecture seule : activez le mode écriture.', run: () => demoWrite(null) },
    { id: 'disable', label: 'Désactiver', icon: 'power', kind: 'write', danger: true, disabled: readOnly, reason: 'Lecture seule : activez le mode écriture.', run: () => demoWrite(null) },
    { id: 'reset', label: 'Réinitialiser le mot de passe…', icon: 'key', kind: 'write', overflow: true, disabled: readOnly, reason: 'Lecture seule : activez le mode écriture.' },
    { id: 'help', label: 'Aide de l’écran', icon: 'info', iconOnly: true, pinned: true, run: () => toast('Aide (démonstration).') },
  ];
  const bar = createCommandBar(host.querySelector('.kit-cmd-host'), { label: 'Actions de la liste', items: items() });
  host.querySelector('[data-busy]').addEventListener('click', () => { busy = !busy; bar.setBusy('refresh', busy); });
  host.querySelector('[data-ro]').addEventListener('click', () => {
    readOnly = !readOnly;
    bar.setItems(items());
    toast(readOnly ? 'Lecture seule rétablie.' : 'Mode écriture (démonstration) : les écritures restent confirmées.', { tone: readOnly ? 'info' : 'warn' });
  });
  st.stops.push(() => bar.destroy());
}

function demoFilters(host, st) {
  host.innerHTML = '<div class="kit-fbar-host"></div>';
  let shown = 245;
  const fb = createFilterBar(host.querySelector('.kit-fbar-host'), {
    label: 'Filtres de la liste',
    chips: [
      { id: 'ou', label: 'Périmètre', value: 'Paris › Postes', icon: 'ou', removable: false },
      { id: 'type', label: 'Type', value: 'Postes', scope: 'Annuaire', removeTip: 'Relirait l’OU sans ce type (lecture sur clic)' },
      { id: 'q', label: 'Contient', value: quote('acc'), scope: 'Liste chargée', removeTip: 'Réaffiche les lignes chargées, sans lecture' },
      { id: 'os', label: 'Système', value: 'Windows 10', scope: 'Base locale', removeTip: 'Sans lecture : base locale seulement' },
    ],
    facets: [
      { id: 'online', label: 'En ligne', count: 287, tone: 'ok' },
      { id: 'silent', label: 'Sans réponse', count: 14, tone: 'warn' },
      { id: 'unchecked', label: 'Non vérifiés', count: 27 },
    ],
    summary: `→ ${int(shown)} lignes affichées sur ${int(1234)}`,
    addItems: [{ label: 'État du compte', icon: 'shield', run: () => fb.setChips([...fb.getChips(), { id: `s${Date.now()}`, label: 'État', value: 'Verrouillé', scope: 'Liste chargée' }]) },
      { label: 'Dernière connexion', icon: 'calendar', run: () => fb.setChips([...fb.getChips(), { id: `d${Date.now()}`, label: 'Connexion', value: 'plus de 90 j', scope: 'Liste chargée' }]) }],
    onRemove: () => { shown = Math.min(1234, shown + 180); fb.setSummary(`→ ${int(shown)} lignes affichées sur ${int(1234)}`); },
    onToggle: (_, pressed) => { shown = Math.max(12, shown + (pressed ? -60 : 60)); fb.setSummary(`→ ${int(shown)} lignes affichées sur ${int(1234)}`); },
  });
  st.stops.push(() => fb.destroy());
}

function demoCrumbs(host, st) {
  host.innerHTML = `<div class="kit-stack"><span class="kit-label">Poste</span><div class="c1"></div>
    <span class="kit-label">Chemin long (milieu replié)</span><div class="c2"></div><p class="muted kit-crumb-out" aria-live="polite"></p></div>`;
  const out = host.querySelector('.kit-crumb-out');
  const go = (dn) => { out.textContent = `Branche demandée${NBSP}: ${dn}`; };
  const a = createDnBreadcrumb(host.querySelector('.c1'), { dn: `CN=PC-PAR-0042,OU=Postes,OU=Paris,OU=Sites,${DOMAIN_DN}`, onNavigate: go });
  const b = createDnBreadcrumb(host.querySelector('.c2'), { dn: `CN=Camille Martin,OU=Équipe 3,OU=Paie,OU=Comptabilité,OU=Services,OU=Lyon,OU=Sites,OU=Ressources,${DOMAIN_DN}`, onNavigate: go, maxVisible: 4 });
  st.stops.push(() => { a.destroy(); b.destroy(); });
}

function demoTree(host, st) {
  host.innerHTML = `<div class="kit-split-host kit-tree-split"></div>`;
  const left = document.createElement('div');
  left.className = 'kit-tree-host';
  const right = document.createElement('div');
  right.className = 'kit-detail';
  right.innerHTML = '<p class="muted">Choisissez une branche : au clavier, la lecture attend 300 ms et seul le dernier arrêt compte.</p>';
  const split = createSplit(host.querySelector('.kit-tree-split'), { a: left, b: right, fixed: 'a', size: 380, min: 260, max: 560, key: 'kit.tree', label: 'Largeur de l’arborescence' });
  const tree = createTree(left, {
    label: 'Unités d’organisation de example.local',
    height: 'fill',
    roots: () => wait(500).then(() => [{ id: 'root', label: 'example.local', icon: 'domain', hint: 'domaine', selectable: false }]),
    load: (node) => wait(350 + Math.random() * 500).then(() => treeChildren(node)),
    onSelect: (node, how) => {
      const path = tree.pathOf(node.id).map((n) => n.label).join(' › ');
      right.innerHTML = `<div class="kit-stack"><span class="kit-label">Branche choisie (${how === 'pointer' ? 'souris' : 'clavier'})</span>
        <b>${esc(node.label)}</b><span class="muted">${esc(path)}</span>${statePill('ready', { label: 'Prête à lire' })}</div>`;
    },
    contextMenu: (node) => [
      { label: 'Afficher le contenu', icon: 'eye', run: () => toast(`Contenu de ${node.label} (démonstration).`) },
      { label: 'Actualiser la branche', icon: 'refresh', kbd: 'F5', run: () => tree.reload(node.id) },
      { label: 'Copier le chemin (DN)', icon: 'copy', run: () => toast('Chemin copié (démonstration).', { tone: 'ok' }) },
      '-',
      { label: 'Nouvelle unité d’organisation…', icon: 'plus', disabled: true, reason: 'Lecture seule : création impossible.' },
    ],
  });
  st.stops.push(() => { tree.destroy(); split.destroy(); });
}

function demoDrawers(host) {
  host.innerHTML = `<div class="kit-row">
    <button class="btn primary" type="button" data-d="right">${glyph('panel')}Panneau à droite</button>
    <button class="btn" type="button" data-d="left">${glyph('tree')}Choisir une OU (à gauche)</button>
    <button class="btn" type="button" data-d="docked">${glyph('split')}Panneau non modal</button>
    <button class="btn ghost" type="button" data-d="queue">${glyph('layers')}Deux demandes de suite</button></div>`;
  host.addEventListener('click', (e) => {
    const b = e.target instanceof Element ? e.target.closest('[data-d]') : null;
    if (!b) return;
    const kind = b.dataset.d;
    if (kind === 'right') openDemoDrawer('right');
    else if (kind === 'left') openOuPicker();
    else if (kind === 'docked') openDrawer({ title: 'Aperçu', subtitle: 'Non modal : la page reste utilisable', icon: 'eye', modal: false, key: 'kit.docked', width: 380, body: '<p class="muted">Ce panneau accompagne le travail : pas de voile, pas de piège de focus. Échap le ferme quand il a le focus.</p>' });
    else if (kind === 'queue') { openDemoDrawer('right'); openDrawer({ title: 'Deuxième demande', icon: 'layers', body: '<p class="muted">Elle a attendu la fermeture du premier panneau.</p>' }); }
  });
}

function openDemoDrawer(side) {
  const body = document.createElement('div');
  body.className = 'kit-stack';
  body.innerHTML = `${kvSection({ id: 'd1', title: 'Résumé', icon: 'monitor', items: [
    { label: 'Nom', value: 'PC-PAR-0042', copy: true }, { label: 'Système', value: 'Windows 11 Entreprise 24H2' },
    { label: 'Dernier ping', value: 'il y a 3 min', tone: 'ok' }, { label: 'Utilisateur connecté', value: null },
  ] })}<form class="k-form kit-drawer-form">${field({ name: 'note', label: 'Note pour le ticket', type: 'textarea', maxLength: 200, hint: '200 caractères au plus.' })}</form>`;
  const unbind = bindKv(body);
  const form = createForm(body.querySelector('form'));
  openDrawer({ title: 'PC-PAR-0042', subtitle: 'Poste · Paris', icon: 'monitor', side, key: 'kit.drawer', body,
    actions: [{ id: 'cancel', label: 'Fermer', run: (p) => p.close() }, { id: 'ok', label: 'Copier la note', icon: 'copy', primary: true, run: () => toast(`Note${NBSP}: ${form.values().note || '(vide)'}`) }],
    onClose: () => { unbind.destroy(); form.destroy(); } });
}

function openOuPicker() {
  const host = document.createElement('div');
  host.className = 'kit-tree-host';
  let chosen = null;
  const panel = openDrawer({ title: 'Choisir l’OU de travail', subtitle: 'Seules les OU se choisissent ; les conteneurs servent à naviguer.', icon: 'tree', side: 'left', key: 'kit.picker', width: 420, body: host,
    actions: [{ id: 'cancel', label: 'Annuler', run: (p) => p.close() }, { id: 'ok', label: 'Choisir cette OU', icon: 'check', primary: true, run: (p) => { p.close(); toast(chosen ? `OU de travail${NBSP}: ${chosen}` : 'Aucune OU choisie.', { tone: chosen ? 'ok' : 'warn' }); } }],
    onClose: () => tree.destroy() });
  const tree = createTree(host, {
    label: 'Unités d’organisation', height: 'fill',
    roots: () => wait(300).then(() => [{ id: 'root', label: 'example.local', icon: 'domain', selectable: false }]),
    load: (node) => wait(300).then(() => treeChildren(node)),
    onSelect: (node) => { chosen = node.label; panel.setTitle('Choisir l’OU de travail', `Choix${NBSP}: ${tree.pathOf(node.id).map((n) => n.label).join(' › ')}`); },
  });
}

function demoDialogs(host) {
  host.innerHTML = `<div class="kit-row">
    <button class="btn" type="button" data-g="info">${glyph('info')}Dialogue d’information</button>
    <button class="btn" type="button" data-g="confirm">${glyph('check')}Confirmation simple</button>
    <button class="btn danger" type="button" data-g="write">${glyph('shield')}Confirmation renforcée (écriture)</button></div>`;
  host.addEventListener('click', (e) => {
    const b = e.target instanceof Element ? e.target.closest('[data-g]') : null;
    if (!b) return;
    if (b.dataset.g === 'info') {
      openDialog({ title: 'Lecture seule', icon: 'lock', body: '<p class="k-dlg-text">Domenia démarre toujours en lecture seule. Le mode écriture se demande, se confirme et revient seul en lecture seule.</p>' });
    } else if (b.dataset.g === 'confirm') {
      confirmDialog({ title: 'Effacer les filtres ?', message: 'Les lignes chargées seront de nouveau toutes affichées, sans nouvelle lecture.', confirmLabel: 'Effacer' })
        .then((ok) => toast(ok ? 'Filtres effacés (démonstration).' : 'Rien n’a changé.', { tone: 'info' }));
    } else {
      demoWrite(null);
    }
  });
}

function menuItems() {
  return [
    { heading: 'Objet' },
    { label: 'Ouvrir la fiche', icon: 'object', kbd: 'Entrée', run: () => toast('Ouvrir (démonstration).') },
    { label: 'Copier', icon: 'copy', items: [
      { label: 'Le nom', run: () => toast('Nom copié (démonstration).', { tone: 'ok' }) },
      { label: 'Le chemin (DN)', run: () => toast('DN copié (démonstration).', { tone: 'ok' }) },
      { label: 'Pour un ticket', kbd: 'Ctrl Maj C', run: () => toast('Résumé copié (démonstration).', { tone: 'ok' }) },
    ] },
    '-',
    { heading: 'Affichage' },
    { label: 'Afficher les comptes désactivés', checked: true, keepOpen: true },
    { label: 'Densité compacte', radio: 'density', checked: false, run: () => {} },
    { label: 'Densité normale', radio: 'density', checked: true, run: () => {} },
    '-',
    { label: 'Vérifier la présence', icon: 'wifi', hint: 'réseau', run: () => toast('Lecture réseau sur clic (démonstration).') },
    { label: 'Désactiver…', icon: 'power', danger: true, disabled: true, reason: 'Lecture seule : activez le mode écriture.' },
  ];
}

function demoMenus(host, st) {
  host.innerHTML = `<div class="kit-row"><button class="btn" type="button" aria-haspopup="menu" aria-expanded="false" data-m>${glyph('more')}Menu déroulant${glyph('chevronDown')}</button>
    <div class="kit-list-card kit-ctx" tabindex="0" role="group" aria-label="Zone de démonstration du menu contextuel" aria-keyshortcuts="Shift+F10">${glyph('monitor')}<div class="body"><b>PC-PAR-0042</b><div class="sub">Clic droit, Maj F10 ou touche Menu</div></div></div></div>`;
  const btn = host.querySelector('[data-m]');
  btn.addEventListener('click', () => openMenu(btn, menuItems(), { label: 'Actions' }));
  st.stops.push(bindContextMenu(host.querySelector('.kit-ctx'), () => menuItems(), { label: 'Actions de PC-PAR-0042' }));
}

function demoForms(host, st) {
  const today = new Date().toISOString().slice(0, 10);
  host.innerHTML = `<form class="k-form" aria-label="Formulaire de démonstration">
    ${field({ name: 'host', label: 'Nom du poste', required: true, width: 'half', mono: true, placeholder: 'PC-PAR-0042', pattern: '[A-Z0-9-]{3,15}', patternMessage: 'Majuscules, chiffres et tirets, 3 à 15 caractères.', hint: 'Nom NetBIOS, sans le domaine.' })}
    ${field({ name: 'ou', label: 'OU de destination', type: 'select', width: 'half', required: true, placeholder: 'Choisir…', options: SITES.map(([c, city]) => ({ value: c, label: `${city} › Postes` })) })}
    ${field({ name: 'expires', label: 'Date d’expiration', type: 'date', width: 'third', min: today, hint: 'Facultative.' })}
    ${field({ name: 'days', label: 'Durée (jours)', type: 'number', width: 'third', min: 1, max: 365, value: 30 })}
    ${field({ name: 'search', label: 'Filtre', type: 'search', width: 'third', placeholder: 'Contient…' })}
    ${field({ name: 'description', label: 'Description', type: 'textarea', maxLength: 200, hint: '200 caractères au plus, visible dans l’annuaire.' })}
    ${field({ name: 'scope', label: 'Portée', type: 'radio', value: 'ou', options: [{ value: 'ou', label: 'Cette OU' }, { value: 'sub', label: 'Avec les sous-OU' }, { value: 'domain', label: 'Tout le domaine', disabled: true }] })}
    ${field({ name: 'notify', label: 'Prévenir l’utilisateur', type: 'checkbox', width: 'half', hint: 'Aucun message ne part en démonstration.' })}
    ${field({ name: 'writes', label: 'Mode écriture', type: 'switch', width: 'half' })}
    <div class="k-form-actions"><button class="btn ghost" type="reset">Rétablir</button><button class="btn primary" type="submit">${glyph('check')}Valider</button></div>
  </form>`;
  const form = createForm(host.querySelector('form'), {
    rules: {
      days: (v) => (v !== null && v > 180 ? { warn: 'Durée longue : plus de six mois.' } : v ? { ok: `Expire dans ${count(v, 'jour', 'jours')}.` } : null),
      host: (v) => (v && !v.startsWith('PC-') && !v.startsWith('PT-') ? { warn: 'Les postes commencent d’habitude par PC- ou PT-.' } : null),
    },
    onSubmit: (values) => wait(600).then(() => toast(`Formulaire valide${NBSP}: rien n’est envoyé (démonstration). Poste ${values.host}.`, { tone: 'ok' })),
  });
  st.stops.push(() => form.destroy());
}

function demoMaster(host, st) {
  host.innerHTML = '<div class="kit-split-host"></div>';
  const objects = makeRows(500, 9, Date.now());
  const list = document.createElement('div');
  list.className = 'kit-master';
  list.setAttribute('role', 'group');
  list.setAttribute('aria-label', 'Objets');
  list.innerHTML = objects.map((o, n) => `<button type="button" aria-pressed="${n === 0}" data-n="${n}"><span class="avatar${o.type === 'computer' ? ' pc' : ''}">${o.type === 'computer' ? icon('monitor') : esc(o.name.split(' ').map((w) => w[0]).join('').slice(0, 2))}</span>`
    + `<span class="body"><b>${esc(o.name)}</b><br><span class="faint">${esc(o.ou)}</span></span></button>`).join('');
  const detail = document.createElement('div');
  detail.className = 'kit-detail';
  const show = (o) => {
    detail.innerHTML = kvSection({ id: 'm', title: o.name, icon: o.type === 'computer' ? 'monitor' : 'user', items: [
      { label: 'Compte', value: o.account, mono: true, copy: true }, { label: 'État', html: statePill(o.state === 'active' ? 'ready' : 'check', { label: o.state === 'active' ? 'Actif' : 'À vérifier' }) },
      { label: 'Emplacement', value: o.ou }, { label: 'Chemin (DN)', value: o.dn, mono: true, copy: true, wide: true },
    ] });
  };
  show(objects[0]);
  const unbind = bindKv(detail);
  list.addEventListener('click', (e) => {
    const b = e.target instanceof Element ? e.target.closest('button[data-n]') : null;
    if (!b) return;
    list.querySelectorAll('button').forEach((x) => x.setAttribute('aria-pressed', String(x === b)));
    show(objects[Number(b.dataset.n)]);
  });
  const split = createSplit(host.querySelector('.kit-split-host'), { a: list, b: detail, key: 'kit.master', size: 440, min: 300, max: 760 });
  st.stops.push(() => { unbind.destroy(); split.destroy(); });
}

function demoSheet(host, st) {
  host.innerHTML = kvSection({ id: 'identite', title: 'Identité', icon: 'user', items: [
    { label: 'Nom affiché', value: 'Camille Martin', copy: true },
    { label: 'Compte', value: 'cmartin012', mono: true, copy: true },
    { label: 'UPN', value: 'cmartin012@example.local', copy: true },
    { label: 'Courriel', value: null },
    { label: 'Service', value: 'Comptabilité', sub: 'Lyon' },
  ] }) + kvSection({ id: 'compte', title: 'Compte', icon: 'key', items: [
    { label: 'État', html: statePill('ready', { label: 'Actif' }) },
    { label: 'Mot de passe', value: 'Expire dans 5 jours', tone: 'warn', sub: 'Changé le 26/07/2026' },
    { label: 'Verrouillage', value: 'Aucun', tone: 'ok' },
    { label: 'Dernière connexion', value: 'il y a 2 h', sub: 'PC-LYO-0117' },
  ] }) + kvSection({ id: 'annuaire', title: 'Annuaire', icon: 'database', open: false, items: [
    { label: 'Chemin (DN)', value: `CN=Camille Martin,OU=Comptabilité,OU=Lyon,OU=Sites,${DOMAIN_DN}`, mono: true, copy: true, wide: true },
    { label: 'GUID', value: '0f8c2a1e-5b7d-4c39-9e21-7a6b3c4d5e6f', mono: true, copy: true, wide: true },
    { label: 'SID', value: 'S-1-5-21-1004336348-1177238915-682003330-1612', mono: true, copy: true, wide: true },
  ] });
  const k = bindKv(host, { key: 'kit.fiche' });
  st.stops.push(() => k.destroy());
}

function demoTimeline(host) {
  const now = Date.now();
  const at = (ms) => new Date(now - ms).toISOString();
  host.innerHTML = timeline([
    { when: at(3 * MIN), title: 'Présence vérifiée', text: '412 postes interrogés, 287 en ligne.', tone: 'ok', icon: 'wifi', actor: 'admin.dupont', meta: 'Paris › Postes' },
    { when: at(48 * MIN), title: 'Compte déverrouillé', text: 'cmartin012 · relu après l’écriture : état confirmé.', tone: 'ok', icon: 'lock', actor: 'admin.dupont', html: statePill('verified', { size: 'sm' }) },
    { when: at(2 * 60 * MIN), title: 'Arrêt demandé', text: 'Relevé WMI de 120 postes : 64 lus avant l’arrêt.', tone: 'warn', icon: 'pause', actor: 'admin.leroy', html: statePill('stopping', { size: 'sm' }) },
    { when: at(26 * 60 * MIN), title: 'Écriture refusée', text: 'Droits insuffisants sur OU=Direction : rien n’a été modifié.', tone: 'alert', icon: 'alert', actor: 'admin.leroy' },
    { when: at(30 * 60 * MIN), title: 'Base locale enregistrée', text: 'Sauvegarde vérifiée avant relecture.', tone: 'info', icon: 'database' },
    { when: at(4 * DAY), title: 'Disposition importée', text: 'Tableau « Support » : 2 widgets inconnus ignorés.', tone: 'off', icon: 'columns' },
  ], { label: 'Dernières opérations (fictives)' });
  bindTimeline(host);
}

function demoStates(host, st) {
  const now = Date.now();
  const iso = (ms) => new Date(now - ms).toISOString();
  host.innerHTML = `<div class="kit-stack">
    <span class="kit-label">Vocabulaire commun (STATES)</span>
    <div class="kit-row">${Object.keys(STATES).map((s) => statePill(s)).join('')}</div>
    <span class="kit-label">Tons</span>
    <div class="kit-row">${pill('ok', 'En ligne')}${pill('warn', 'Sans réponse', { pulse: true })}${pill('alert', 'Verrouillé')}${pill('info', 'Simulation')}${pill('off', 'Non vérifié')}${pill('accent', 'Favori', { icon: 'star' })}${pill('ok', 'Petit', { size: 'sm' })}</div>
    <span class="kit-label">Fraîcheur (périmée après 15 min)</span>
    <div class="kit-row">${freshness(iso(MIN / 2), { source: 'Annuaire' })}${freshness(iso(9 * MIN), { source: 'Ping' })}${freshness(iso(42 * MIN), { source: 'WMI' })}${freshness(null)}
      <button class="btn sm" type="button" data-renew>${glyph('refresh')}Relire (démonstration)</button></div>
    <span class="kit-label">Copie en un clic</span>
    <div class="kit-row"><span class="mono">S-1-5-21-1004336348-1177238915-682003330-1612</span>${copyButton('S-1-5-21-1004336348-1177238915-682003330-1612', { label: 'Copier le SID' })}
      ${copyButton('PC-PAR-0042', { label: 'Copier le nom', text: 'Copier le nom', size: 'sm', done: 'Nom copié' })}</div>
  </div>`;
  startFreshness(host);
  st.stops.push(bindCopy(host));
  host.querySelector('[data-renew]').addEventListener('click', () => {
    host.querySelectorAll('.k-fresh').forEach((n) => touchFreshness(/** @type {HTMLElement} */ (n), new Date().toISOString()));
  });
}

function demoGauges(host) {
  host.innerHTML = `<div class="kit-gauges">
    ${gauge({ value: 72, label: 'Disque C:', caption: '172 Go sur 238', thresholds: { warn: 80, alert: 90 } })}
    ${gauge({ value: 93.4, decimals: 1, label: 'Mémoire', caption: '15 Go sur 16', thresholds: { warn: 80, alert: 90 } })}
    ${gauge({ value: 69.7, decimals: 1, label: 'Postes en ligne', caption: '287 sur 412', thresholds: { warn: 60, alert: 40 }, invert: true })}
    ${gauge({ value: null, label: 'Batterie', caption: 'non mesurée' })}
  </div><div class="kit-stack kit-bars">
    ${gauge({ kind: 'bar', value: 84, label: 'Mesures fraîches', thresholds: { warn: 70, alert: 50 }, invert: true, caption: 'relevées il y a moins de 7 jours' })}
    ${gauge({ kind: 'bar', value: 37, label: 'Quota de lignes de la liste', unit: '%', tone: 'info' })}
    ${gauge({ kind: 'bar', value: 12, max: 20, unit: '', label: 'Relevés en cours', tone: 'accent', caption: '12 sur 20 au plus' })}
  </div><div class="kit-row"><button class="btn sm" type="button" data-replay>${glyph('refresh')}Rejouer</button></div>`;
  animateGauges(host);
  host.querySelector('[data-replay]').addEventListener('click', () => animateGauges(host));
}

function demoTabs(host, st) {
  host.innerHTML = '<div class="kit-tabs-host"></div>';
  const tabs = createTabs(host.querySelector('.kit-tabs-host'), {
    label: 'Fiche de démonstration', key: 'kit.tabs', tabs: [
      { id: 'general', label: 'Général', icon: 'object', render: (p) => { p.innerHTML = '<p class="muted">Contenu calculé à la première ouverture de l’onglet, jamais avant.</p>'; } },
      { id: 'membres', label: 'Membres', icon: 'group', count: 12, render: (p) => { p.innerHTML = `<div class="kit-row">${FIRST.slice(0, 12).map((f) => pill('off', f, { icon: 'user', size: 'sm' })).join('')}</div>`; } },
      { id: 'postes', label: 'Postes associés', icon: 'monitor', count: 3, tone: 'warn', render: (p) => { p.innerHTML = `<div class="kit-row">${pill('ok', 'PC-PAR-0042')}${pill('warn', 'PT-PAR-0007', { pulse: true })}${pill('off', 'PC-PAR-0311')}</div>`; } },
      { id: 'historique', label: 'Historique', icon: 'history', render: (p) => { p.innerHTML = timeline([{ when: new Date().toISOString(), title: 'Fiche ouverte', tone: 'info', icon: 'eye' }]); bindTimeline(p); } },
      { id: 'securite', label: 'Sécurité', icon: 'shield', disabled: true, reason: 'Réservé au profil Expert.' },
    ],
  });
  st.stops.push(() => tabs.destroy());
}

function demoInfinite(host, st) {
  host.innerHTML = `<div class="grid"><div class="span-6"><span class="kit-label">Lecture réseau : suite sur clic</span><div class="i1"></div></div>
    <div class="span-6"><span class="kit-label">Lecture locale : suite automatique</span><div class="i2"></div></div></div>`;
  const all = makeRows(900, 120, Date.now());
  const loader = (delay) => (cursor) => wait(delay).then(() => {
    const from = cursor ?? 0;
    const items = all.slice(from, from + 15);
    return { items, next: from + 15 < all.length ? from + 15 : null, total: all.length };
  });
  const render = (items, list) => list.insertAdjacentHTML('beforeend', items.map((o) => `<li class="kit-list-card">${glyph(o.type === 'computer' ? 'monitor' : 'user')}`
    + `<div class="body"><b>${esc(o.name)}</b><div class="sub">${esc(o.ou)}</div></div>${statePill(o.state === 'active' ? 'ready' : 'check', { size: 'sm', label: o.state === 'active' ? 'Actif' : 'À vérifier' })}</li>`).join(''));
  // Same bounded height for both: the automatic list reads as its own scroller reaches the end, never the page.
  const a = createInfinite(host.querySelector('.i1'), { load: loader(600), render, label: 'Objets (suite sur clic)', listTag: 'ul', noun: ['objet', 'objets'], maxHeight: 420 });
  const b = createInfinite(host.querySelector('.i2'), { load: loader(250), render, label: 'Objets (suite automatique)', listTag: 'ul', noun: ['objet', 'objets'], auto: true, maxHeight: 420 });
  st.stops.push(() => { a.destroy(); b.destroy(); });
}

const DEMOS = {
  disposition: demoDisposition, grille: demoGrid, commandes: demoCommands, filtres: demoFilters, fil: demoCrumbs, arbre: demoTree,
  panneaux: demoDrawers, dialogues: demoDialogs, menus: demoMenus, formulaires: demoForms, maitre: demoMaster, fiche: demoSheet,
  chrono: demoTimeline, etats: demoStates, jauges: demoGauges, onglets: demoTabs, suite: demoInfinite,
};

// ---------- Table of contents (scroll spy) ----------

function bindToc(main, page, st) {
  const links = [...page.querySelectorAll('[data-toc]')];
  const mark = (id) => links.forEach((a) => { if (a.dataset.toc === id) a.setAttribute('aria-current', 'true'); else a.removeAttribute('aria-current'); });
  page.querySelector('.kit-toc').addEventListener('click', (e) => {
    const a = e.target instanceof Element ? e.target.closest('[data-toc]') : null;
    if (!a) return;
    e.preventDefault();
    const target = page.querySelector(`#kit-${CSS.escape(a.dataset.toc)}`);
    target?.scrollIntoView({ block: 'start', behavior: motionReduced() ? 'instant' : 'smooth' });
    // Like an anchor: the keyboard goes on from the section reached (its title), not from the link.
    target?.querySelector('h2')?.focus({ preventScroll: true });
    mark(a.dataset.toc);
    // The address keeps the section (shareable, capture), without a new screen render.
    history.replaceState(null, '', `#/kit?section=${encodeURIComponent(a.dataset.toc)}`);
  });
  if (!('IntersectionObserver' in window)) return;
  const io = new IntersectionObserver((entries) => {
    const visible = entries.filter((x) => x.isIntersecting).sort((x, y) => x.boundingClientRect.top - y.boundingClientRect.top);
    if (visible[0]) mark(visible[0].target.id.replace(/^kit-/, ''));
  }, { root: main, rootMargin: '-15% 0px -70% 0px' });
  page.querySelectorAll('.kit-section').forEach((s) => io.observe(s));
  st.stops.push(() => io.disconnect());
}

// ---------- Render ----------

export function render(main, ctx) {
  const st = { alive: true, stops: [], grid: null };
  main.innerHTML = layout();
  const page = main.querySelector('.kit-page');
  applyVars(main);
  for (const s of SECTIONS) {
    const host = page.querySelector(`[data-demo="${s.id}"]`);
    try {
      DEMOS[s.id]?.(host, st);
    } catch (err) {
      console.error(err);
      host.innerHTML = `<p class="muted" role="alert">Démonstration indisponible.</p>`;
    }
  }
  st.stops.push(reveal(main));
  bindToc(main, page, st);
  page.querySelector('[data-act="replay"]').addEventListener('click', () => ctx.navigate('kit', ctx.params));

  // #/kit?section=grille&open=drawer — for captures and links from the documentation.
  const section = ctx.params?.section;
  if (section && SECTIONS.some((s) => s.id === section)) {
    setTimeout(() => {
      if (!st.alive) return;
      const target = page.querySelector(`#kit-${CSS.escape(section)}`);
      target?.scrollIntoView({ block: 'start', behavior: 'instant' });
    }, 0);
  }
  const open = ctx.params?.open;
  if (open) {
    wait(900).then(() => {
      if (!st.alive) return;
      if (open === 'drawer') openDemoDrawer('right');
      else if (open === 'picker') openOuPicker();
      else if (open === 'dialog') openDialog({ title: 'Lecture seule', icon: 'lock', body: '<p class="k-dlg-text">Démonstration d’un dialogue intégré à la page.</p>' });
      else if (open === 'confirm') demoWrite(null);
      else if (open === 'menu') {
        const btn = page.querySelector('[data-demo="menus"] [data-m]');
        if (btn) openMenu(btn, menuItems(), { label: 'Actions' });
      }
    });
  }

  return () => {
    st.alive = false;
    st.stops.forEach((fn) => { try { fn(); } catch (err) { console.error(err); } });
  };
}
