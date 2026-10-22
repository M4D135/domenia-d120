# Domenia 2 — coque commune et API des écrans

La coque (`web/js/app.js` et `web/js/shell/*.js`) entoure chaque écran : menu latéral, barre du haut, bandeau du mode,
palette de commandes, raccourcis, centre de notifications, panneau d’aide F1, infobulles, sélecteurs partagés, exports,
tableaux personnalisables. Un écran n’importe **jamais** ces modules directement : il reçoit tout par le contexte `ctx`
passé à `render(main, ctx)` par le routeur. Les opérations du moteur sont décrites dans `docs/ops/shell.md`.

Mise en place le 22 octobre 2026 (lot « shell »). Les fonctions de Domenia 1 reprises sont les `TRV-*` des groupes
Navigation, En-tête, Interface, Sélecteurs, Aide, Apparence, Garde-fous, Mise en page, Accessibilité, Notifications,
Palette, Raccourcis, Interface automatisable, Exports, Feuilles, Démonstration et Tableaux (statut :
`docs/status/shell.json`).

## 1. Aide contextuelle : `ctx.help`

Le catalogue de Domenia 1 (`dev/wad/modules/Domenia-UX.help.json`, 820 sujets) est converti en module web par
`python3 tools/gen_help.py` (contrôle : `--check`). Le module généré `web/js/shell/help-catalog.js` ne se modifie pas à
la main : il porte l’empreinte SHA-256 de la source, la typographie française (apostrophe ’, espaces insécables) et un
classement des sujets par écran (15 domaines). Il n’est chargé qu’à la première demande (import dynamique).

| Appel | Effet |
|---|---|
| `ctx.help.attach(el, clé)` | Pose `data-help="clé"` : infobulle (titre + texte, 350 ms, 20 s au plus), `aria-description` renseignée, panneau F1 « Sur cet élément ». |
| `ctx.help.open(clé?)` | Ouvre le panneau d’aide (F1), sur la clé si elle est donnée. |
| `ctx.help.text(clé)` | Promesse du sujet `{ name, title, text, kind, area }` ou `null`. |
| `ctx.help.topics(texte, { area, limit })` | Recherche plein texte (tous les mots, sans accents ni casse) ; 30 sujets par défaut. |
| `ctx.help.register(clé, { title, text, kind?, area? })` | Ajoute l’aide d’un contrôle propre à Domenia 2. Textes fixes seulement : jamais une valeur lue. |
| `ctx.help.disabled(el, { action, reason, detail? })` | Grise un contrôle **avec son motif** (`aria-disabled`, `data-reason`) ; l’infobulle s’affiche même grisé et un clic ouvre l’explication. |
| `ctx.help.enable(el)` | Retire le motif. |
| `ctx.help.route(code)` | Suit une route du catalogue fermé (navigation seulement). |
| `ctx.help.routes` | Catalogue des routes : `rechercher`, `comptes`, `fiche-droits`, `operations-verifier`, `stockage`, `comparer-saisies`, `assistance-intervenir`, `lecture-seule`, `fiche-relire`, `operations`, `journal`, `apropos`, `parametres`, `aide`. |

Motifs admis (`reason`, catalogue fermé : un code inconnu est refusé) : `readOnly`, `noSelection`, `wrongType`, `busy`,
`refused`, `stale`, `offline`, `prerequisite`, `pending`, `running`. Détails admis (`detail`) : `needsUser`,
`needsWorkstation`, `needsGroup`, `readInProgress`, `writeInProgress`, `receiptToReview`, `cacheOnly`,
`otherAccountNeeded`, `remoteAccessUnavailable`, `toolMissing`, `featureDisabled`, `requiredFieldEmpty`, `simulation`.
Aucun texte libre n’atteint une infobulle.

En HTML, sans code : `data-help="clé"` (sujet du catalogue), `data-tip="texte"` (infobulle simple),
`data-reason="texte"` sur un bouton `aria-disabled="true"`.

```js
export function render(main, ctx) {
  const btn = main.querySelector('[data-act="unlock"]');
  ctx.help.attach(btn, 'UnlockButton');
  if (!selection) ctx.help.disabled(btn, { action: 'Déverrouiller', reason: 'noSelection', detail: 'needsUser' });
}
```

## 2. Notifications : `ctx.notify(message, options)`

Bannières dans la page, gardées dans le centre de notifications (cloche) jusqu’à la fin de la session.

- `tone` : `info`, `ok`, `warn`, `alert`. Information et réussite se ferment après 5 s (jamais sous le pointeur) ;
  avertissement, erreur, message en plusieurs paragraphes ou avec détail restent jusqu’à fermeture.
- Une ligne vide sépare le titre du reste. Un code `INC-XXXX` du message est extrait et affiché à part.
- Même message (ou même `key`) : regroupé avec un compteur ×N. Trois bannières visibles au plus.
- `detail` (replié, « Voir le détail »), `route` + `routeLabel` (bouton « Aller à … »), `folder` + `folderLabel`
  (« Ouvrir le dossier »), `actions: [{ label, icon, run }]`.
- Erreur et avertissement proposent « Copier pour le support » (texte masqué : DN, comptes et secrets protégés).
- `ctx.toast(message, options)` reste disponible (même moteur, renvoie l’élément).

## 3. Commandes et palette : `ctx.commands`

La palette (Ctrl K) liste les écrans, les commandes de l’écran affiché, les 44 commandes du catalogue de Domenia 1, les
actions de la coque, l’aide (catalogue) et, sur Entrée, une recherche d’objets dans l’annuaire. **Elle n’écrit jamais** :
une commande d’écriture amène son bouton à l’écran (focus et halo), l’écriture passe par sa propre confirmation.

```js
ctx.commands.set([
  { id: 'refresh-list', label: 'Actualiser la liste', icon: 'refresh', effect: 'read', keywords: 'relire', run: () => reload() },
  { id: 'unlock', label: 'Déverrouiller le compte', effect: 'write', requires: 'user' }, // amène [data-command="unlock"]
]);
ctx.commands.context({ selectionType: 'user', machineRows: 0, scope: dn });
```

- `effect` : `navigate`, `local`, `read`, `sensitive`, `write`. Sans `run`, la palette cherche le contrôle
  `[data-command="<id>"]` de l’écran : `focus` (écriture, lecture protégée) ou `click` (lecture, action locale) après
  revérification qu’il est visible et actif.
- `requires` : `user`, `computer`, `group`, `selection`, `machines` ; la disponibilité suit `ctx.commands.context`.
- Les commandes d’un écran disparaissent quand il est quitté.

## 4. Sujet, cible et titre

- `ctx.subject.set({ dn, name, kind, guid })` : seul **Rechercher** choisit le sujet global (refusé ailleurs, avec
  trace dans la console) ; la puce du sujet apparaît dans la barre du haut. `ctx.subject.clear()` désélectionne
  partout (événement `domenia:subject`). `ctx.subject.get()`.
- `ctx.setTarget(nom)` : nom affiché dans le titre de la fenêtre (« Fiche · Camille Martin — Domenia »). En mode
  annuaire avec écriture admise, le titre porte `[ÉCRITURE AD ACTIVE]`.

## 5. Garde-fous : `ctx.requests`, `ctx.summary`

- `await ctx.requests.ask({ scope, title, message, danger?, write?: { target, targetKind, typed }, changes?, details?, alternate?, onConfirm?, onAlternate? })`
  : demande dans la page (dialogue du kit) ; la réponse sûre a le focus, Échap annule ; une seule suite, une seule
  fois ; une nouvelle demande retire la précédente ; une réponse donnée après un changement de session expire sans rien
  exécuter. Renvoie `'confirm'`, `'alternate'` ou `null`.
- `ctx.requests.blocks('write'|'edit', scope)` : vrai tant qu’une demande attend sur ce périmètre (sans périmètre :
  toutes les écritures attendent). Navigation, lectures et sélection restent libres.
- `ctx.summary(opération, options)` : résumé lisible d’une opération avant exécution, valeurs sensibles masquées
  (`(masqué)`), options repliées listées.
- Les erreurs non interceptées de l’interface sont comptées, tracées dans le journal technique (nature, écran, nombre
  seulement) et signalées une fois par minute et par écran.

## 6. Exports et fichiers

| Appel | Effet |
|---|---|
| `ctx.exportCsv({ name, headers, rows, secretColumns? })` | CSV UTF-8 avec BOM, `;`, cellules neutralisées (`=`, `+`, `-`, `@`, y compris en pleine chasse et après des espaces : apostrophe ajoutée), colonnes secrètes retirées, textes ressemblant à un secret masqués. Bannière avec « Ouvrir le dossier ». |
| `ctx.exportCsvText(name, csv)` | CSV déjà construit (grille du kit : `grid.toCsv()`), masqué à nouveau par le moteur. |
| `ctx.gridExporter(name)` | Fonction à passer en `onExport` d’une grille du kit. |
| `ctx.exportJson(name, valeur)` | Document JSON dans le dossier des exports. |
| `ctx.importCsv(titre?)` / `ctx.importJson(titre?)` | Sélecteur intégré puis lecture (séparateur détecté, 5 000 lignes, 1 Mo au plus). |

Les fichiers vont dans `%LOCALAPPDATA%\Domenia\Exports` (`Exports-Simulation` en simulation), nommés
`Domenia-<sujet>-AAAAMMJJ-HHmm.<ext>`, jamais écrasés (suffixe `-2`, `-3`…). En capture et E2E, ils restent en mémoire.

## 7. Sélecteurs partagés

- `await ctx.pickOu({ title, effect, subtree: 'choice'|'forced'|'none', initial, allowRoot })` → `{ dn, name, path, subtree }`
  revérifié, ou `null`. Arbre lu à l’ouverture d’une branche, recherche par nom, OU favorites du domaine (étoile),
  résumé avant validation.
- `await ctx.pickObject({ kinds: ['user','computer','ou'], title, effect })` → objet revérifié (DN **et** GUID) ou
  `null` ; recherche lancée par Entrée, 2 caractères au moins, 100 résultats.
- `await ctx.pickFile({ filter: 'csv'|'json'|'all', title })` → `{ path, name }` ou `null` ; dossiers locaux seulement
  (ni partage, ni lecteur réseau, ni lien), 500 entrées. En simulation, seul le dossier des exports de simulation est
  proposé.

## 8. Tableaux personnalisables : `ctx.createBoard(host, options)`

```js
ctx.createBoard(host, {
  id: 'poste', team: 'Poste', title: 'Tableau du poste',
  catalog: [{ key: 'disk.free', title: 'Espace disque', kind: 'distribution', visuals: ['bars', 'donut'], size: 'M', group: 'Santé', icon: 'database', description: '…' }],
  defaults: [{ key: 'disk.free', size: 'M', group: 'Santé' }],
  presets: [{ id: 'support', label: 'Support', keys: ['disk.free'] }],
  load: async () => ({ 'disk.free': { kind: 'distribution', items: [{ label: 'C:', value: 42 }], at: new Date().toISOString() } }),
  refreshItem: async (key) => ({ /* même forme */ }),
  explain: (key, entry) => ({ formula: '…', scope: '…', criteria: '…', exclusions: '…', refresh: '…' }),
});
```

Mode Personnaliser (glisser, clavier, tailles S/M/L, représentation, sections), ajout depuis le catalogue (recherche
avec synonymes), dispositions prêtes, Annuler/Rétablir (Ctrl Z / Ctrl Y), retour à la disposition livrée ou d’équipe
(`Dashboard.DefaultLayout<Équipe>` de `Domenia.config.json`), export/import JSON (`Domenia.BoardLayout.1`), cinq
versions restaurables, copie d’un widget ou du résumé (texte, Markdown, HTML), « Comprendre ce chiffre », dates des
données en pied de widget, table de données alternative pour chaque graphique. Représentations : `kpi`, `gauge`,
`donut`, `bars`, `columns`, `line`, `list`, `sheet`, `checklist`.

## 9. Autres entrées du contexte

`ctx.announce(texte, { key })` (lecteur d’écran, sans répétition), `ctx.statusBadge(état)` (mot + symbole + couleur,
14 états), `ctx.expert` / `ctx.profile` (vue Expert ponctuelle par `?vue=expert`, sans changer le profil),
`ctx.openPalette()`.

## 10. Adresses, paramètres et événements

- `?coque=aide|notifications|journal|operations|session|apropos|raccourcis|palette|audit` sur n’importe quel écran
  ouvre le panneau correspondant (liens des guides, captures) ; `?coque=exemples` affiche les quatre bannières d’exemple
  (textes fixes, aucune donnée réelle) et `?coque=exemples-centre` les garde ouvertes dans le centre de notifications.
- Anciennes adresses redirigées : `journal` → `operations`, `index` et `stockage` → Paramètres › Stockage, `outils`
  et `reglages` → Paramètres, `support` → Assistance, `atelier` → Atelier de requêtes, `parcourir` → Rechercher (vue
  Parcourir), `fiabilite` → Opérations à vérifier, `aide` et `raccourcis` → onglets de l’écran « Aide et interface »
  (`shell`), `coque` et `interface` → cet écran, `tableau-de-bord` et `dashboard` → Accueil.
- Événements de `window` : `domenia:refresh` (F5, annulable : un écran qui le gère appelle `preventDefault()`),
  `domenia:focus-search` (Ctrl F), `domenia:subject` (sujet changé ou effacé).
- Raccourcis : Ctrl K / Ctrl P palette, F1 aide, Maj ? raccourcis, F5 actualiser, Ctrl B menu, Ctrl F rechercher,
  Ctrl D accueil, Ctrl L journal, Ctrl I index, Ctrl T thème, Ctrl Maj C résumé, Alt ← / Alt → historique,
  Alt 1…9 écrans. Un raccourci tapé dans un champ y garde son sens ; un dialogue ouvert garde ses touches.

## 11. Contrat visuel

Thèmes clair, sombre, contraste élevé et « suivre Windows » ; animations riches, réduites ou « suivre Windows »
(`prefers-reduced-motion` respecté). Le contraste WCAG des 29 paires réellement peintes est mesuré sur le thème affiché
(écran « Aide et interface », onglet Apparence). La barre de titre Windows suit le thème (DWM, sans erreur sur un
Windows ancien). Fenêtre courte (< 940 px), basse (< 700 px) ou étroite : la barre du haut se compacte, le menu se
replie de lui-même et revient à la largeur choisie. Le panneau d’aide (F1) se pose à côté du travail : si la colonne du
contenu tombait sous 1 100 px, le menu se replie le temps de l’aide (jamais enregistré) et revient à sa fermeture ; le
bandeau du mode garde son bouton « Détails » visible.

Tableaux (`ctx.createBoard`) : les widgets entrent en cascade une seule fois ; un déplacement, une taille ou une
actualisation les redessine sans rejouer l’entrée. Une série dont toutes les valeurs connues valent zéro s’affiche en
tuiles calmes avec une phrase (`zeroText` de l’entrée), jamais en graphique vide. Une date des données en avance de moins
de 5 minutes sur l’horloge de la page (écart d’horloge entre le moteur et WebView2) se lit « à l’instant » ; au-delà,
« non daté ».
