# Domenia 2 — kit d’interface

Le kit rassemble les composants partagés des treize écrans à porter (Rechercher, Fiche, Comptes, Utilisateurs et postes,
Poste, Assistance, Requêtes, Audit, Schéma, Synchronisation, Comptes machine, Opérations, Paramètres). Chaque écran
assemble ces pièces au lieu de réinventer une grille, un menu ou une confirmation : mêmes gestes, mêmes textes, mêmes
garde-fous partout.

- Code : `web/js/kit/*.js` (modules ES natifs, documentés en JSDoc), point d’entrée unique `web/js/kit/index.js`.
- Styles : `web/css/kit.css` (composants), `web/css/components.css` (primitives : boutons, champs, cases, badges).
- Vitrine vivante : écran caché **`#/kit`** (absent de la navigation), données fictives locales, aucune requête.
  `#/kit?section=grille` ouvre une section ; `&open=drawer|picker|dialog|confirm|menu` ouvre une démonstration
  (captures de contrôle).

```js
import { createGrid, openDrawer, confirmWrite, pill } from '../kit/index.js';
```

## 1. Règles communes

### 1.1 Sécurité (non négociable)

- **Aucun composant ne lit l’annuaire, le réseau ni le disque.** La page appelle le pont (`ctx.call`) et nourrit les
  composants. Trier, filtrer, choisir des colonnes, chercher dans un arbre : tout reste local.
- **Lecture seule par défaut.** Une écriture passe toujours par `confirmWrite` (saisie exacte du nom de la cible), puis
  par l’opération du pont qui revérifie le plan. Le kit ne fait jamais d’écriture lui-même.
- **Aucune lecture réseau sans geste explicite.** La pagination infinie et la grille lisent la suite sur un clic ;
  `auto: true` / `autoLoadMore: true` sont réservés aux lectures locales (base, données déjà chargées).
- **Jamais tout le domaine** : le fil d’Ariane affiche le domaine en texte seul ; l’arbre ne le rend pas sélectionnable.
- **Aucun secret** : une colonne `secret: true` n’est ni copiée, ni exportée, ni parcourue par le filtre rapide. Les
  dispositions mémorisées ne contiennent que des clés de colonnes et des tailles, jamais une ligne.
- **CSP stricte** : aucun attribut `style` ni gestionnaire `on…` dans le balisage ; les variables CSS passent par
  `el.style.setProperty` (`setVars`). Toute donnée insérée en HTML passe par `esc()`.

### 1.2 Texte

- Français soigné : apostrophe typographique ’, guillemets « » avec espaces insécables, espace insécable (U+00A0) avant
  « : », « ; », « ! », « ? », « % ». Les aides `NBSP`, `quote()`, `int()`, `dec()`, `count()` suivent les règles de
  `FrenchText` (milliers séparés par U+202F, virgule décimale, signe moins U+2212, singulier pour 0 et 1).
- Une action grisée dit **pourquoi** (`reason`) : info-bulle et description accessible.
- Une absence de mesure s’écrit « — » (et « non renseigné » pour le lecteur d’écran), **jamais 0**.

### 1.3 Animations

- Seulement `transform`, `opacity`, `filter` (et les propriétés `translate` / `scale` pour les entrées, qui ne
  contrarient pas les `transform` de positionnement). Toutes les durées sont des jetons (`--t-fast`, `--t`, `--t-slow`,
  `--t-chart`) : « Animations réduites » les ramène à 1 ms (`tokens.css`, `motion.css`).
- Les lignes virtuelles sont placées par `transform: translateY()` : jamais de `top` animé.

## 2. Disposition des écrans

### 2.1 Squelette d’un écran

```html
<div class="page">
  <header class="page-header reveal">
    <div class="head-row"><span class="page-icon">…</span>
      <div class="titles"><h1 class="gradient-text">Comptes</h1><p class="subtitle">Pilotage · OU de travail</p></div></div>
    <div class="actions"><!-- barre de commandes de l’écran --></div>
  </header>
  <div class="grid"> … cartes .span-* … </div>
</div>
```

### 2.2 Grille de 12 colonnes

| Classe | Usage |
|---|---|
| `.span-12` | liste principale, grille de données, bandeau |
| `.span-8` + `.span-4` | contenu et aperçu ou contexte |
| `.span-6` + `.span-6` | deux blocs de même poids |
| `.span-3` ×4 | indicateurs (KPI) |

En dessous de 1 400 px, `.span-3` et `.span-4` passent à 6 colonnes ; en dessous de 1 100 px, `.span-6` et `.span-8`
prennent toute la largeur. Une liste et son détail redimensionnable passent par `createSplit` plutôt que par deux
`span`. Les formulaires ont leur propre grille de 6 pistes (`.k-form`, champs `w-full`, `w-half`, `w-third`).

### 2.3 Espacements (grille de 4 px)

`--s1` 4 px · `--s2` 8 · `--s3` 12 · `--s4` 16 · `--s5` 20 · `--s6` 24 · `--s8` 32 · `--s10` 40 · `--s12` 48.

- entre cartes d’une grille : `--s5` (déjà posé par `.grid`) ;
- intérieur d’une carte : `--s5` ; entre un titre de carte et son contenu : `--s4` ;
- entre contrôles d’une même barre : `--s2` ; entre groupes de contrôles : `--s4` ;
- entre sections d’un écran long : `--s10`.

### 2.4 Hiérarchie des titres

| Niveau | Usage | Taille |
|---|---|---|
| `h1` | titre de l’écran, **un seul**, dans `.page-header` | `--fs-page` |
| `h2` | section de l’écran, titre de dialogue ou de panneau | `--fs-title` |
| `h3` | titre de carte, section d’une fiche (`kvSection`) | `--fs-subtitle` |
| `h4` | sous-groupe (jour d’une chronologie) | `--fs-caption` en capitales |

### 2.5 Densité

- Grille : `compact` (32 px), `normal` (40 px, défaut), `confortable` (48 px), au choix de l’opérateur dans
  « Colonnes et affichage », mémorisée avec la disposition.
- Listes de plus de 200 lignes : grille de données, jamais une liste de cartes.

### 2.6 Où placer les actions

1. **Actions de l’écran** : barre de commandes à droite de l’en-tête (`.page-header .actions`). Une seule action
   `primary` par écran.
2. **Actions d’une liste** : dans la barre de la grille (`grid.slot`) ou juste au-dessus, jamais en bas de page.
3. **Actions d’une ligne** : menu contextuel (clic droit, Maj F10, touche Menu) et double clic / Entrée pour ouvrir.
4. **Actions d’une sélection multiple** : barre flottante de la grille (`selectionActions`).
5. **Actions d’un panneau ou d’un dialogue** : pied, réponse sûre à gauche, action principale à droite.
6. Les écritures sont marquées (`kind: 'write'`, `danger: true` si destructrices), jamais en premier dans un menu.

## 3. Routeur et écrans

- Ajouter un écran = créer `web/js/pages/<id>.js` (et, si besoin, `web/css/pages/<id>.css`). **Aucune liste à éditer**
  dans le routeur : la navigation de `app.js` reste la seule liste. Une route sans module retombe sur `pages/_todo.js`.
- Le module exporte `render(main, ctx)` et renvoie une fonction de nettoyage (ou une promesse de cette fonction).
- `ctx.params` : paramètres de l’adresse, gelés (`#/fiche?dn=CN%3D…&tab=membres` → `{ dn, tab }`, 2 048 caractères au
  plus par valeur). `ctx.route` : `{ id, params, hash }`. `ctx.navigate(id, params)` et `ctx.link(id, params)` forment
  l’adresse (encodage compris).
- Feuille de style d’écran : le module la déclare (`export const stylesheet = true;`), le routeur charge alors
  `css/pages/<id>.css` et la désactive quand un autre écran s’affiche ; un écran sans cette déclaration (écran en portage,
  route inconnue, `#/kit`) ne demande aucune feuille (aucune erreur 404). Elle limite ses règles à son écran :
  `.main[data-page="comptes"] …`. Une couche posée dans `<body>` (panneau propre à
  l’écran, hors de `.main`) garde une classe à elle : la feuille n’étant active que sur son écran, ses règles ne
  touchent pas les autres (c’est le cas du panneau « Choisir l’OU » de `css/pages/accueil.css`).
- Écran caché (hors navigation) : le module exporte `meta = { label, icon }` (exemple : `pages/kit.js`).
- Signal de capture (`docs/CAPTURE.md` § 5) inchangé : montrer des squelettes ou `aria-busy="true"` pendant les
  lectures suffit. La grille, l’arbre et la pagination infinie le font d’eux-mêmes.

```js
// web/js/pages/fiche.js
export function render(main, ctx) {
  const dn = ctx.params.dn ?? '';
  main.innerHTML = `<div class="page">…</div>`;
  // …
  return () => { /* arrêter minuteries, détruire les composants */ };
}
```

## 4. Composants

### 4.1 Grille de données — `createGrid(host, options)`

Virtualisée (seules les lignes visibles existent : fluide au-delà de 10 000 lignes). Colonnes déclaratives, tri
multi-colonnes, filtre par colonne et filtre rapide global, choix, ordre et largeur des colonnes, sélection simple ou
multiple, ligne et cellule actives, menu contextuel, double clic, squelette, états vides, compteur « n sur m », copie
tabulée et CSV, disposition mémorisée par clé avec annulation (10 étapes, Ctrl Z).

```js
const grid = createGrid(host, {
  key: 'comptes.liste',                    // mémorise ordre, largeurs, colonnes masquées, tri, densité
  label: 'Comptes de l’OU de travail',
  rowId: (row) => row.guid,                // identité stable : la sélection survit au tri et aux relectures
  selection: 'multi',                      // 'none' | 'single' | 'multi'
  loading: true,                           // squelette jusqu’au premier setRows
  height: '560px',                         // ou 'fill' dans un parent flex
  columns: [
    { id: 'name', label: 'Nom', required: true, width: 220 },
    { id: 'sam', label: 'Compte', mono: true },
    { id: 'state', label: 'État', type: 'enum', options: [
      { value: 'active', label: 'Actif', tone: 'ok' },
      { value: 'locked', label: 'Verrouillé', tone: 'alert' }] },
    { id: 'lastLogon', label: 'Dernière connexion', type: 'date' },          // relative, date complète en info-bulle
    { id: 'logons', label: 'Connexions', type: 'number' },
    { id: 'dn', label: 'Chemin (DN)', mono: true, hidden: true },
  ],
  empty: { icon: 'search', title: 'Aucun compte', text: 'Choisissez une OU : rien n’est lu sans votre geste.' },
  onActivate: (row) => ctx.navigate('fiche', { dn: row.dn }),
  contextMenu: ({ rows, row, column }) => [
    { label: 'Ouvrir la fiche', icon: 'object', kbd: 'Entrée', disabled: !row, run: () => … },
    { label: 'Déverrouiller…', icon: 'lock', danger: true, disabled: readOnly, reason: 'Lecture seule.', run: … },
  ],
  selectionActions: (rows) => [{ label: 'Vérifier', icon: 'wifi', run: (sel) => … }],
  onLoadMore: () => loadNextPage(),        // bouton « Charger la suite »
});
const page = await ctx.call('accounts.list', { ou });
grid.setRows(page.rows, { hasMore: page.truncated });
```

Colonnes (`GridColumn`) : `type` `text` | `number` | `date` | `bool` | `enum` ; `get(row)` (valeur brute),
`format(value, row)` (texte affiché), `html(value, row)` (balisage de confiance, à échapper soi-même),
`csv(value, row)`, `sortKey(value, row)`, `options` (enum), `width` (40 à 1 600), `minWidth`, `maxWidth`, `align`,
`decimals`, `dateStyle` (`relative`, `datetime`, `date`), `sortable`, `filterable`, `hidden`, `required`, `secret`,
`mono`, `tip`. Une date illisible trie comme la plus ancienne ; une valeur vide reste en fin de tri dans les deux sens.

Filtres par colonne : texte (plusieurs mots en ET, sans accents ni casse), nombre (`> 10`, `<= 5`, `5..20`, `=3`),
liste pour `enum` et `bool`, périodes pour `date` (24 h, 7 j, 30 j, plus de 90 j, jamais). Filtre rapide : toutes les
colonnes visibles non secrètes, 180 ms après la frappe. Un filtre qui masque tout le dit et propose « Effacer les
filtres » ; rien n’est relu.

API : `setRows(rows, { hasMore, keepSelection, keepScroll })`, `appendRows(rows, { hasMore })`, `setLoading(on)`,
`setError(message, { retry })`, `setEmpty(empty)`, `setHasMore(on)`, `setQuickFilter(text)`,
`setColumnFilter(id, raw)`, `clearFilters()`, `getSelection()`, `getSelectedIds()`, `select(ids)`, `getVisibleRows()`,
`getActiveRow()`, `updateRow(id)` (cellules repeintes avec un éclat), `refresh()`, `setColumns(columns, { key })`
(autre vue de la même liste), `resetLayout()`, `toCsv({ scope, bom })`, `exportCsv('visible'|'selected')`, `focus()`,
`destroy()`, `slot` (emplacement libre de la barre), `el`.

CSV : point-virgule, en-têtes français, colonnes visibles dans l’ordre, cellules commençant par `= + - @` neutralisées.
Sans `onExport`, le CSV est copié dans le presse-papiers ; avec `onExport(csv, info)`, la page l’envoie au pont
(fichier `Domenia-<…>-AAAAMMJJ-HHmm.csv`, UTF-8 avec BOM). `setClipboardWriter(fn)` branchera la copie sur le pont.

| Clavier (grille) | Effet |
|---|---|
| ↑ ↓, Pg↑ Pg↓, Ctrl Début / Fin | ligne active (et sélection) |
| ← →, Début / Fin | cellule active |
| Maj ↑ ↓ | étend la sélection |
| Ctrl ↑ ↓ | déplace sans sélectionner ; Espace sélectionne ou retire |
| Ctrl A, Échap | tout sélectionner, vider la sélection |
| Entrée / double clic | `onActivate` |
| Maj F10, touche Menu | menu contextuel de la ligne |
| Ctrl C | copie tabulée de la sélection (avec en-têtes si plusieurs lignes) |
| Ctrl Z | annule le dernier changement de disposition |
| ↑ depuis la première ligne | en-têtes : Entrée trie, Maj Entrée ajoute au tri, Alt ← → déplace la colonne, Ctrl ← → change sa largeur |

Souris : clic trie (croissant, décroissant, aucun), Maj clic ajoute au tri, glisser un en-tête le déplace, glisser son
bord le redimensionne, double clic sur le bord ajuste la largeur, flèche d’en-tête ouvre le menu de colonne.

### 4.2 Menus — `openMenu(target, items, opts)`, `bindContextMenu(el, getItems)`

```js
openMenu(button, [
  { heading: 'Objet' },
  { label: 'Ouvrir la fiche', icon: 'object', kbd: 'Entrée', run },
  { label: 'Copier', icon: 'copy', items: [{ label: 'Le DN', run }] },          // sous-menu
  '-',
  { label: 'Afficher les désactivés', checked: true, keepOpen: true, run },     // case
  { label: 'Densité compacte', radio: 'density', checked: false, run },         // choix unique
  { label: 'Désactiver…', icon: 'power', danger: true, disabled: true, reason: 'Lecture seule.' },
], { label: 'Actions', placement: 'bottom-end' });
const unbind = bindContextMenu(zone, (e) => items);   // clic droit, Maj F10, touche Menu
```

Un seul menu à la fois, placé et retourné pour rester dans la fenêtre. Clavier : ↑ ↓ Début Fin, → ouvre un sous-menu,
← le ferme, Entrée ou Espace, Échap, Tab ferme, lettre = saut au libellé. Le focus revient à l’élément d’origine. Un
second clic sur le bouton d’origine referme le menu. L’action s’exécute après la fermeture.

### 4.3 Panneau latéral — `openDrawer(options)`

```js
const panel = openDrawer({
  title: 'PC-PAR-0042', subtitle: 'Poste · Paris', icon: 'monitor',
  side: 'right',                 // ou 'left' (sélecteur d’OU)
  key: 'fiche.apercu',           // mémorise la largeur
  width: 480, minWidth: 320, maxWidth: 1100,
  modal: true,                   // voile, page inerte, piège de focus ; false : panneau d’accompagnement
  body: node,                    // nœud ou balisage de confiance
  actions: [{ id: 'close', label: 'Fermer', run: (p) => p.close() },
            { id: 'open', label: 'Ouvrir la fiche', primary: true, run: (p) => … }],
  onClose: () => cleanup(),
});
panel.setBusy(true); panel.setTitle('…', '…'); await panel.closed;
```

Posé sur la zone de contenu (sous la barre supérieure, à côté du menu). Un seul panneau modal à la fois : une seconde
demande attend la fermeture du premier. Échap ferme, le focus revient ; un champ du panneau qui se sert d’Échap (recherche
d’un arbre, filtre rapide ou sélection d’une grille) le traite d’abord : seul un Échap que personne n’a utilisé ferme le
panneau (de même pour les dialogues). Redimensionnable à la souris et au clavier (← → par 16 px, Maj par 64 px, Début
Fin, double clic = largeur par défaut). Changer d’écran le ferme et retire les demandes en attente derrière lui : aucune
ne s’ouvre sur l’écran suivant. Les raccourcis
de la page (Ctrl K, Ctrl B, Alt chiffre) sont bloqués tant qu’il est ouvert.

### 4.4 Dialogues — `openDialog`, `confirmDialog`, `confirmWrite`

Toujours dans la page, jamais de nouvelle fenêtre. Une nouvelle demande retire la précédente ; quitter l’écran la
retire sans rien exécuter. Le focus va sur la réponse sûre.

```js
const ok = await confirmDialog({ title: 'Effacer les filtres ?', message: '…', confirmLabel: 'Effacer' });

const answer = await confirmWrite({             // 'confirm' | 'alternate' | null
  title: 'Désactiver le compte',
  message: 'Le compte ne pourra plus ouvrir de session.',     // 2 000 caractères au plus
  target: plan.sam, targetKind: 'Compte', targetDetail: plan.dn,
  changes: [{ label: 'État du compte', before: 'Activé', after: 'Désactivé' }],
  details: plan.technical,                                     // replié
  alternate: { label: 'Seulement la description' },            // troisième réponse facultative
});
if (answer === 'confirm') await ctx.call('account.disable', { planId: plan.id });
```

`confirmWrite` exige la saisie exacte du nom (casse comprise, collage refusé) avant d’activer « Confirmer l’écriture » ;
Entrée ne confirme rien tant que le nom ne correspond pas. Il n’envoie rien : la page envoie le plan ensuite, le moteur
le revérifie.

### 4.5 Arborescence paresseuse — `createTree(host, options)`

```js
const tree = createTree(host, {
  label: 'Unités d’organisation',
  roots: () => ctx.call('tree.roots'),                     // ou un tableau
  load: (node) => ctx.call('tree.children', { dn: node.id }),
  onSelect: (node, how) => showOu(node),                   // souris : aussitôt ; clavier : après 300 ms
  onActivate: (node) => …,                                 // Entrée, double clic
  contextMenu: (node) => [ … ],
  height: 'fill',
});
await tree.reveal(['root', 'sites', 'site-PAR']);           // ouvre le chemin, lit ce qui manque
```

Nœud : `{ id, label, icon?, hint?, leaf?, children?, selectable?, data? }`. Une branche se lit à son ouverture, une
seule fois ; une ouverture pendant la lecture est sans effet ; un résultat arrivé après une relecture n’est jamais
rattaché. Erreur par branche avec « Réessayer ». Recherche dans les branches déjà lues seulement (et le dit). Clavier
du motif APG : ↑ ↓, → ouvre puis descend, ← ferme puis remonte, Début Fin, `*` ouvre les sœurs, lettres, Entrée,
Maj F10, F5 relit la branche. Virtualisé (une branche de 900 postes reste fluide). API : `reload(id?)`, `expand`,
`collapse`, `select(id)`, `reveal(path)`, `getSelected()`, `pathOf(id)`, `setFilter(text)`, `size()`, `focus()`,
`destroy()`.

### 4.6 Barre de commandes — `createCommandBar(host, { label, items, size })`

```js
createCommandBar(header.querySelector('.actions'), { label: 'Actions de la liste', items: [
  { id: 'search', label: 'Nouvelle recherche', icon: 'search', primary: true, run },
  { id: 'refresh', label: 'Actualiser', icon: 'refresh', kbd: 'F5', run },
  { id: 'check', label: 'Vérifier la liste', icon: 'wifi', kind: 'network', run },
  { id: 'export', label: 'Exporter', icon: 'csv', items: [ … ] },
  { id: 'disable', label: 'Désactiver', icon: 'power', kind: 'write', danger: true, disabled: readOnly, reason: 'Lecture seule.', run },
  { id: 'reset', label: 'Réinitialiser le mot de passe…', kind: 'write', overflow: true, run },
  { id: 'help', label: 'Aide', icon: 'info', iconOnly: true, pinned: true, run },
]});
```

Ce qui ne tient pas en largeur passe dans « Plus » de la fin vers le début ; `primary` et `pinned` restent, `overflow`
y est toujours. `kind: 'network'` (point bleu) et `kind: 'write'` (crayon) sont signalés. Un seul arrêt de tabulation,
← → entre les commandes. API : `setItems`, `setDisabled(id, on, reason)`, `setBusy(id, on)`, `destroy`.

### 4.7 Fil d’Ariane de DN — `createDnBreadcrumb(host, { dn, onNavigate, copy, maxVisible })`

Domaine (texte seul) › OU › sous-OU › objet ; chaque OU intermédiaire appelle `onNavigate(dn, part)` (une lecture, sur
clic). Au-delà de `maxVisible` niveaux, le milieu se replie dans un menu. Bouton de copie du DN. Aides : `parseDn(dn)`
(échappements RFC 4514), `dnParent(dn)`, `dnDomain(dn)`.

### 4.8 Formulaires — `field(options)`, `createForm(form, { rules, onSubmit, onChange })`

```js
form.innerHTML = field({ name: 'host', label: 'Nom du poste', required: true, mono: true, width: 'half',
    pattern: '[A-Z0-9-]{3,15}', patternMessage: 'Majuscules, chiffres et tirets.', hint: 'Sans le domaine.' })
  + field({ name: 'ou', label: 'OU', type: 'select', options, placeholder: 'Choisir…', width: 'half' })
  + field({ name: 'until', label: 'Expiration', type: 'date', width: 'third' })
  + field({ name: 'days', label: 'Durée (jours)', type: 'number', min: 1, max: 365, width: 'third' })
  + field({ name: 'scope', label: 'Portée', type: 'radio', options: [ … ] })
  + field({ name: 'notify', label: 'Prévenir', type: 'checkbox' })
  + field({ name: 'writes', label: 'Mode écriture', type: 'switch' })
  + '<div class="k-form-actions"><button class="btn ghost" type="reset">Rétablir</button>'
  + '<button class="btn primary" type="submit">Valider</button></div>';
const f = createForm(form, {
  rules: { days: (v) => (v > 180 ? { warn: 'Durée longue.' } : null) },    // texte = erreur ; { error|warn|ok }
  onSubmit: async (values) => ctx.call('…', values),
});
```

Types : `text`, `search`, `number`, `date`, `datetime`, `time`, `select`, `textarea`, `checkbox`, `switch`, `radio`.
Contrôles intégrés en français (obligatoire, longueurs, bornes, date, motif). Un champ est vérifié à la sortie, puis à
chaque frappe une fois en erreur ; la validation finale met le focus sur la première erreur et annonce le nombre de
champs à corriger. Le navigateur n’envoie jamais rien (`form-action 'none'`). Aucun champ n’est prévu pour un mot de
passe : les secrets passent par le moteur (`SecureString`). API : `values()`, `validate()`, `validateField(name)`,
`setMessage(name, text, tone)`, `reset()`, `setDisabled(on)`, `destroy()`.

### 4.9 Vue maître-détail — `createSplit(host, options)`

```js
const split = createSplit(host, { a: listNode, b: detailNode, key: 'comptes.detail', size: 420, min: 280, max: 900 });
split.fold(true);
```

`orientation` `row` (côte à côte) ou `column` ; `fixed` `a` ou `b` (volet de taille fixée). Séparateur à la souris et au
clavier (flèches, Maj, Début Fin, Entrée ou double clic replie). Sous 720 px de largeur, les volets s’empilent.

### 4.10 Fiche clé/valeur — `kvSection(section)`, `bindKv(scope, { key })`

```js
host.innerHTML = kvSection({ id: 'identite', title: 'Identité', icon: 'user', items: [
  { label: 'Compte', value: 'cmartin012', mono: true, copy: true },
  { label: 'Mot de passe', value: 'Expire dans 5 jours', tone: 'warn', sub: 'Changé le 26/07/2026' },
  { label: 'Chemin (DN)', value: dn, mono: true, copy: true, wide: true },
  { label: 'Courriel', value: null },                         // « — », « non renseigné »
]});
const kv = bindKv(host, { key: 'fiche.utilisateur' });       // repli mémorisé, boutons de copie actifs
```

### 4.11 Chronologie — `timeline(events, opts)`, `bindTimeline(scope)`

Événements `{ when, title, text?, tone?, icon?, actor?, meta?, html? }`, regroupés par jour (« Aujourd’hui », « Hier »,
puis la date), plus récents en premier, heure locale et date complète en info-bulle.

### 4.12 États, pastilles et badges — `pill`, `statePill`, `STATES`, `badge`

Vocabulaire commun (kit Domenia 1) : `idle` En attente, `ready` Prêt, `running` En cours, `stopping` Arrêt demandé
(pas une annulation confirmée), `check` À vérifier, `done` Terminé (pas vérifié), `verified` Vérifié, `failed` Échec
(rien n’est rejoué), `readonly` Lecture seule. `pill(tone, label, { icon, pulse, spin, size, tip })` pour le reste ;
tons `ok`, `warn`, `alert`, `info`, `off`, `accent`. Dans une grille, une colonne `enum` avec `tone` produit la pastille
elle-même.

### 4.13 Jauges — `gauge(options)`, `animateGauges(scope)`

```js
host.innerHTML = gauge({ value: 72, label: 'Disque C:', caption: '172 Go sur 238', thresholds: { warn: 80, alert: 90 } })
  + gauge({ kind: 'bar', value: 84, label: 'Mesures fraîches', thresholds: { warn: 70, alert: 50 }, invert: true });
animateGauges(host);
```

Demi-cadran ou barre, `role="meter"`, ton selon les seuils (`invert` : les valeurs basses sont les mauvaises),
`value: null` = non mesuré (jamais 0).

### 4.14 Barre de filtres — `createFilterBar(host, options)`

Filtres rapides (`facets`, boutons à bascule avec compteur), critères en pastilles avec leur portée (`Annuaire`,
`Base locale`, `Liste chargée`) et l’effet de leur retrait (`removeTip`), périmètre non retirable, « Ajouter un
filtre », « Tout effacer », phrase de combinaison (`setSummary('→ 245 lignes affichées sur 1 234')`). Rappels :
`onRemove(id)`, `onClear()`, `onToggle(id, pressed)`. API : `setChips`, `getChips`, `setFacets`, `setSummary`,
`destroy`.

### 4.15 Onglets — `createTabs(host, { label, tabs, selected, key, onChange })`

Onglets `{ id, label, icon?, count?, tone?, disabled?, reason?, render(panel) }` : `render` n’est appelé qu’à la
première ouverture (onglets lourds gratuits tant qu’on ne les ouvre pas). Activation automatique (← → Début Fin),
encre glissante, onglet choisi mémorisé. API : `select(id)`, `current()`, `panel(id)`, `setCount(id, n, tone)`,
`destroy()`.

### 4.16 Pagination infinie — `createInfinite(host, options)`

```js
createInfinite(host, {
  load: (cursor) => ctx.call('ops.page', { after: cursor }),    // { items, next, total? } ; next null = fin
  render: (items, list, first) => list.insertAdjacentHTML('beforeend', items.map(row).join('')),
  listTag: 'ul', noun: ['opération', 'opérations'],
  auto: false,                                                    // true : lecture locale seulement
});
```

États : chargement, « Charger la suite », fin de liste, erreur avec « Réessayer ». Une lecture remplacée (`reset`) ne
s’ajoute jamais à la liste.

### 4.17 Copie en un clic — `copyButton(value, opts)`, `bindCopy(scope)`

L’icône devient une coche avec un éclat, l’info-bulle dit « Copié », le lecteur d’écran l’annonce. Jamais pour un
secret.

### 4.18 Fraîcheur — `freshness(at, { staleAfter, label, source })`, `startFreshness(scope)`, `touchFreshness(node, at)`

« Lu il y a 3 min » (vert), vieillissant à mi-délai (ambre), « Périmé · il y a 44 min » au-delà (rouge), « Jamais
lu ». Une seule minuterie met à jour tous les indicateurs affichés et s’arrête quand il n’y en a plus.

### 4.19 Aides — `util.js`

`uid`, `clamp`, `debounce`, `rafThrottle`, `setVars`, `el`, `fill`, `isTextEntry`, `focusables`, `trapFocus`,
`int`, `dec`, `count`, `quote`, `NBSP`, `NNBSP`, `MINUS`, `highlight`, `writeClipboard` / `setClipboardWriter`,
`readLayout` / `writeLayout` / `setLayoutStore`. Les dispositions vont dans `localStorage` (préfixe
`domenia.kit.v1:`) ; `setLayoutStore({ read, write })` les enverra vers les préférences locales de l’application
(classe `LocalWrite`, décision du 21/10) quand l’opération existera.

## 5. Accessibilité

- Rôles ARIA complets : `grid` (lignes, cellules, `aria-rowcount`, `aria-colindex`, `aria-sort`,
  `aria-activedescendant`), `menu` / `menuitem(checkbox|radio)`, `tree` / `treeitem` (`aria-level`, `aria-setsize`,
  `aria-posinset`, `aria-expanded`), `dialog` / `alertdialog`, `tablist`, `separator` (valeurs), `meter`, `toolbar`.
- Le focus ne se perd jamais : menus, panneaux et dialogues le rendent à l’élément d’origine.
- Les changements utiles sont annoncés (`announce`) : nombre de lignes après filtre, tri, colonne déplacée, branche
  lue, copie, sélection.
- Contraste élevé : chaque composant garde un cadre ou un contour lisible (`:root[data-theme="contrast"]`).

## 6. Tests à écrire (exécutés à la fin, dans la VM)

À placer dans `tests/web` (exécutés par le moteur WebView2 ou Node), quand ce dossier sera ouvert :

1. Routeur : `#/fiche?dn=…` expose `params.dn` décodé ; valeur de plus de 2 048 caractères ignorée ; `#/_todo` et
   `#/../x` ramènent à l’accueil ; une route de la navigation sans module affiche `_todo` ; une route hors navigation
   sans `meta` ramène à l’accueil ; aucune feuille demandée sans `export const stylesheet = true` (ni pour `_todo`, ni
   pour une route inconnue) ; feuille déclarée mais absente : l’écran s’affiche quand même ; seule la feuille de l’écran
   affiché est active ; `data-ready` posé une fois les squelettes disparus (inchangé, `CAPTURE.md` § 14.6).
2. Grille : 12 000 lignes rendues avec moins de 60 nœuds de ligne ; tri multi-colonnes stable, vides en fin dans les deux
   sens, date illisible la plus ancienne ; filtre nombre `5..20`, `>= 3` ; filtre texte sans accents ; sélection
   conservée par `rowId` après `setRows` ; Maj clic, Ctrl clic, Ctrl A, Échap ; CSV : en-têtes, point-virgule,
   guillemets doublés, `=cmd` neutralisé, colonnes `secret` absentes ; disposition relue bornée (largeur 5 000 → 1 600,
   colonne inconnue ignorée, colonne `required` jamais masquée) ; Ctrl Z rétablit l’étape précédente.
3. Menu : flèches, sous-menu → ←, Échap rend le focus, lettre de saut, élément `disabled` sans effet, second clic sur
   le bouton referme.
4. Arbre : une seule lecture par ouverture ; réponse d’une lecture remplacée ignorée ; erreur puis « Réessayer » ;
   recherche limitée aux branches lues ; navigation clavier APG ; `reveal` ouvre le chemin.
5. Dialogue d’écriture : bouton désactivé tant que le nom diffère (casse comprise) ; collage refusé ; Entrée ne
   confirme qu’avec le nom exact ; Échap et changement d’écran répondent `null`.
6. Panneau : focus piégé, Échap, deuxième panneau modal mis en attente, Ctrl K bloqué pendant l’ouverture, page de
   nouveau active à la fermeture ; Échap dans la recherche non vide d’un arbre du panneau vide la recherche sans fermer ;
   demande en attente puis changement d’écran (`hashchange`, ou `close()` suivi de `navigate`) : `closed` résolu, rien
   ne s’ouvre sur le nouvel écran.
6 bis. Barre de commandes : `setBusy` et `setDisabled` gardent le focus et l’arrêt de tabulation du bouton ; une
   commande occupée est grisée dans « Plus » (« Action en cours ») ; barre de filtres : retirer un critère ou « Tout
   effacer » au clavier laisse le focus sur un voisin, jamais sur `body`.
7. Formulaire : messages français des contrôles intégrés ; `rules` erreur / avertissement / confirmation ; « Rétablir »
   efface les messages sans boucle.
8. Textes : aucune chaîne visible du kit ne contient d’espace ordinaire avant « : ; ! ? % » ni après « « ».
