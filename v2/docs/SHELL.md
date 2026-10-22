# Domenia 2 — coque commune et API des écrans

La coque (`web/js/app.js` et `web/js/shell/*.js`) entoure chaque écran : menu latéral, barre du haut, bandeau du mode,
palette de commandes, raccourcis, centre de notifications, panneau d’aide F1, infobulles, sélecteurs partagés, exports,
tableaux personnalisables. Un écran n’importe **jamais** ces modules directement : il reçoit tout par le contexte `ctx`
passé à `render(main, ctx)` par le routeur. Les opérations du moteur sont décrites dans `docs/ops/shell.md`.

Mise en place le 22 octobre 2026 (lot « shell »), complétée le même jour après le premier tour du critique (demande dans
la page non modale, règle `UI.AllowExpertProfile`, contrastes WCAG sans dette, bords des séries, cartes score et santé,
sélection d’une part, mode enregistrement du sélecteur de fichier, emplacements réservés de la barre du haut). Les fonctions de Domenia 1 reprises sont les `TRV-*` des groupes
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
`otherAccountNeeded`, `remoteAccessUnavailable`, `toolMissing`, `featureDisabled`, `requiredFieldEmpty`, `simulation`,
`memoryOnly` (session sans disque : capture, essai), `policyHidden` (masqué par l’administrateur).
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

- `effect` : `navigate`, `local`, `read`, `sensitive`, `write`, **obligatoire** : une commande sans effet (ou avec un effet
  inconnu) est traitée comme une écriture — la palette amène seulement son bouton, son `run` n’est jamais exécuté — et
  l’oubli est signalé dans la console. Sans `run`, la palette cherche le contrôle
  `[data-command="<id>"]` de l’écran : `focus` (écriture, lecture protégée) ou `click` (lecture, action locale) après
  revérification qu’il est visible et actif.
- `requires` : `user`, `computer`, `group`, `selection`, `machines` ; la disponibilité suit `ctx.commands.context`.
- Les commandes d’un écran disparaissent quand il est quitté.
- La commande du catalogue « Annuler la dernière présentation de la liste » (`undo`) émet `domenia:undo-presentation`
  (annulable : un écran qui la gère appelle `preventDefault()`), sinon donne Ctrl Z à la grille du kit ou au tableau qui a eu
  le focus en dernier ; sans liste ni tableau à l’écran, elle est indisponible avec son motif.

## 4. Sujet, cible et titre

- `ctx.subject.set({ dn, name, kind, guid })` : seul **Rechercher** choisit le sujet global (refusé ailleurs, avec
  trace dans la console) ; la puce du sujet apparaît dans la barre du haut. `ctx.subject.clear()` désélectionne
  partout (événement `domenia:subject`). `ctx.subject.get()`.
- `ctx.dirty.set(vrai, libellé)` : l’écran déclare une saisie non enregistrée (`ctx.dirty.set(false)` quand elle est
  enregistrée ou abandonnée). La désélection par la puce passe alors par une demande dans la page (garde-fou de saisie non
  enregistrée, TRV-050). Remis à zéro à chaque changement d’écran.
- `ctx.setTarget(nom)` : nom affiché dans le titre de la fenêtre (« Fiche · Camille Martin — Domenia »). En mode
  annuaire avec écriture admise, le titre porte `[ÉCRITURE AD ACTIVE]`.

## 5. Garde-fous : `ctx.requests`, `ctx.summary`

- `await ctx.requests.ask({ scope, scopeLabel?, title, message, danger?, impact?, write?: { target, targetKind, typed },
  changes?, details?, detailsExpert?, alternate?, onConfirm?, onAlternate? })` : **demande dans la page**, posée en haut
  du contenu sous le bandeau du mode (rangée `request` de la grille de la coque), **sans fenêtre ni boucle modale** : la page
  n’est jamais inerte, la navigation, les lectures, la sélection et les autres cibles restent libres (TRV-058, TRV-059) ;
  la demande reste posée d’un écran à l’autre. Contenu : titre, message (2 000 caractères au plus), cible, changements avant
  et après, détails techniques repliés (`detailsExpert` : réservés à la vue experte), saisie exacte du nom (casse comprise,
  collage refusé), troisième réponse facultative, impact chiffré (`impact` : « 3 objets »), style danger ou normal. La
  réponse sûre a le focus ; Échap annule (focus dans la demande, ou sur la page) ; Entrée ne confirme jamais une demande
  non lue (la confirmation n’a jamais le focus d’abord ; dans le champ du nom, seulement quand il correspond). Une seule
  suite, une seule fois ; une nouvelle demande retire la précédente ; un changement de session la retire ; une réponse
  donnée après un changement de session expire sans rien exécuter. Renvoie `'confirm'`, `'alternate'` ou `null`. Sans la
  coque (échec du démarrage), le dialogue du kit sert de repli.
- `ctx.requests.blocks('write'|'edit', scope)` : vrai tant qu’une demande attend sur ce périmètre (sans périmètre :
  toutes les écritures attendent). Seule barrière des écritures ; navigation, lectures et sélection restent libres.
- `ctx.summary(opération, options)` : résumé lisible d’une opération avant exécution, valeurs sensibles masquées
  (`(masqué)`), options repliées listées.
- Les erreurs non interceptées de l’interface sont comptées, tracées dans le journal technique (nature, écran, nombre
  seulement) et signalées une fois par minute et par écran. Une erreur survenue pendant le traitement d’une autre n’est
  jamais perdue : elle est annoncée ensuite (nature `nested`). `ctx.swallowed(endroit, erreur)` trace une erreur
  volontairement ignorée (identifiant du code, jamais le message), une fois par minute par endroit (Domenia 1
  `Write-DomeniaSwallowed`).

## 6. Exports et fichiers

| Appel | Effet |
|---|---|
| `ctx.exportCsv({ name, headers, rows, secretColumns?, chooseLocation? })` | CSV UTF-8 avec BOM, `;`, cellules neutralisées (`=`, `+`, `-`, `@`, y compris en pleine chasse et après des espaces : apostrophe ajoutée ; un nombre écrit en français, « -5 », reste un nombre), colonnes secrètes retirées, textes ressemblant à un secret masqués. Bannière avec « Ouvrir le dossier ». |
| `ctx.exportCsvText(name, csv, { chooseLocation? })` | CSV déjà construit (grille du kit : `grid.toCsv()`), **relu cellule par cellule par le moteur** et réécrit selon ses règles (neutralisation, masquage, lignes comptées par enregistrement). |
| `ctx.gridExporter(name, { chooseLocation? })` | Fonction à passer en `onExport` d’une grille du kit. |
| `ctx.exportJson(name, valeur, { chooseLocation? })` | Document JSON dans le dossier des exports. |
| `ctx.importCsv(titre?)` / `ctx.importJson(titre?)` | Sélecteur intégré puis lecture (séparateur détecté, 5 000 lignes, 1 Mo au plus), d’un dossier local ou d’un partage interrogé à la demande. |

Les fichiers vont dans `%LOCALAPPDATA%\Domenia\Exports` (`Exports-Simulation` en simulation), nommés
`Domenia-<sujet>-AAAAMMJJ-HHmm.<ext>`, jamais écrasés (suffixe `-2`, `-3`…). En capture et E2E, ils restent en mémoire.
Avec `chooseLocation: true`, le mode enregistrement du sélecteur de fichier place le fichier (§ 7) ; un fichier existant
n’est remplacé que sur « Remplacer », et seulement s’il a gardé la taille et la date listées.

## 7. Sélecteurs partagés

- `await ctx.pickOu({ title, effect, subtree: 'choice'|'forced'|'none', initial, allowRoot })` → `{ dn, name, path, subtree,
  objectGuid }` revérifié, ou `null`. Arbre lu à l’ouverture d’une branche ; recherche par nom (Entrée, 100 OU au plus,
  chemin de chaque OU) ; OU favorites du domaine (étoile) avec un libellé qui distingue deux OU du même nom
  (« Postes (Lyon) », « Postes (Paris) ») ; `initial`, un favori ou un résultat sont **révélés dans l’arbre parent par
  parent** ; le GUID d’une OU choisie dans l’arbre est relu (`shell.ou.resolve`) ; la validation revérifie le DN **et** le
  GUID (`shell.lookup.verify`) : une OU déplacée est montrée avec son nouvel emplacement et n’est rendue que confirmée ;
  le choix est refusé si la session a changé pendant que le sélecteur était ouvert ; résumé avant validation.
- `await ctx.pickObject({ kinds: ['user','computer','ou'], title, effect })` → objet revérifié (DN **et** GUID) ou
  `null` ; recherche lancée par Entrée, 2 caractères au moins, 100 résultats. Un objet **déplacé, renommé ou recréé**
  depuis la recherche est signalé visiblement, avec son nouvel emplacement : « Choisir cet objet à son nouvel
  emplacement » ou « Choisir un autre objet ». Refusé si la session a changé.
- `await ctx.pickFile({ filter: 'csv'|'json'|'all', title })` → `{ path, name, share }` ou `null` ; dossiers locaux (ni
  lecteur réseau mappé, ni lien), 500 entrées. Un **partage réseau** (`\\serveur\partage\…`) n’est interrogé qu’à la
  demande (« Interroger ce partage », 15 s au plus ; refusé en simulation). En simulation, seul le dossier des exports de
  simulation est proposé.
- `await ctx.pickFile({ mode: 'save', filter: 'csv'|'json', name })` → `{ folder, name, replace }` ou `null` : mode
  **emplacement d’enregistrement** (dossiers locaux seulement). Un nom déjà pris demande un clic explicite sur
  « Remplacer », lié à la taille et à la date du fichier listé (`replace: { size, at }`) ; aucun dossier n’est créé.

## 8. Tableaux personnalisables : `ctx.createBoard(host, options)`

```js
ctx.createBoard(host, {
  id: 'poste', team: 'Computer', title: 'Tableau du poste',
  catalog: [{ key: 'disk.free', title: 'Espace disque', kind: 'distribution', visuals: ['bars', 'donut'], size: 'M', group: 'Santé',
    icon: 'database', description: '…', origin: 'builtin', network: true, fleet: false }],
  defaults: [{ key: 'disk.free', size: 'M', group: 'Santé' }],
  presets: [{ id: 'support', label: 'Support', keys: ['disk.free'] }],
  legacyKeys: { DiskSpace: 'disk.free' },                      // clés des dispositions de Domenia 1
  load: async () => ({ 'disk.free': { kind: 'distribution', items: [{ label: 'C:', value: 42, criterion: 'C:' }], at: new Date().toISOString() } }),
  refreshItem: async (key) => ({ /* même forme */ }),
  explain: (key, entry) => ({ formula: '…', scope: '…', criteria: '…', exclusions: '…', refresh: '…' }),
  fleetSize: () => 412,                                        // widget de parc : confirmation au-delà de 200 postes
  onLayout: ({ keys, added, removed }) => suspend(removed),     // un widget retiré suspend ses collectes
  onSegment: (key, part) => filter(part.criteria),              // part choisie (ou « Autres » et ses membres)
  onAction: (key, action) => go(action),                        // bouton d’un widget (carte santé, état vide)
});
```

Mode Personnaliser (glisser, clavier, tailles S/M/L, représentation, sections), ajout depuis le catalogue (recherche
avec synonymes, filtres par origine et par catégorie, badges « Déjà affiché », « Interroge le poste », « Interroge le
parc »), dispositions prêtes, Annuler/Rétablir (Ctrl Z / Ctrl Y, hors champ de saisie), retour à la disposition livrée ou
d’équipe (`Dashboard.DefaultLayout<Équipe>` de `Domenia.config.json`), export/import JSON (`Domenia.BoardLayout.1`, le
tableau répond à son nom d’équipe et à son identifiant), cinq versions restaurables, copie d’un widget (rien n’est copié
pour un widget vide ou suspendu : « Rien à copier ») ou du résumé (texte, Markdown, HTML), « Comprendre ce chiffre »,
dates des données en pied de widget, table de données alternative pour chaque graphique. Représentations : `kpi`,
`gauge`, `score` (carte score), `health` (carte santé : score et points, empilée sous 520 px), `donut`, `bars`, `columns`,
`line`, `list`, `sheet`, `checklist`.

- **Disposition enregistrée** : lue avant toute sauvegarde. Si l’écran se monte avant la réponse de `shell.interface.get`,
  la disposition livrée s’affiche, les commandes de personnalisation attendent (grisées avec leur motif) et la disposition
  enregistrée est adoptée dès qu’elle arrive, tant que l’opérateur n’a rien changé ; copie de secours dans le profil
  WebView2 (`domenia.board.v1:<id>`).
- **Parts cliquables** : seulement quand l’écran écoute (`onSegment`) **et** que la part porte un critère (`criterion`) ;
  sinon la légende est une ligne simple, sans allure de bouton. « Autres » garde les critères de ses membres ; la part
  choisie le reste après une relecture, même si sa catégorie passe dans « Autres ».
- **États vides** : une illustration, une phrase (`empty`) et, si l’écran la donne, l’action qui remplit le widget
  (`emptyAction: { id, label, icon }`, reçue par `onAction`).

## 9. Autres entrées du contexte

`ctx.announce(texte, { key })` (lecteur d’écran, sans répétition), `ctx.statusBadge(état)` (mot + symbole + couleur,
14 états), `ctx.openPalette()`, et :

- `ctx.expert` / `ctx.profile` : vue experte de l’écran **monté** (`?vue=expert` de sa propre adresse, jamais de la
  navigation précédente) ou profil Expert ; toujours faux quand l’administrateur masque Expert
  (`UI.AllowExpertProfile = false` dans `Domenia.config.json`, opération `shell.policy`) : le menu du compte et
  l’onglet Apparence grisent alors Expert avec son motif, le profil Essentiel s’applique et Ctrl L ouvre le journal.
- `ctx.expertView({ applies, reason })` : l’écran dit si sa vue experte s’applique (sinon la palette refuse
  « Afficher la vue experte » avec cette raison, TRV-167). Une puce « Vue experte · cette consultation » apparaît dans la
  barre du haut, avec ✕ pour revenir à la vue Essentiel.
- `ctx.tasks.begin({ label, cancel? })` → `{ progress(part, détail), end(), stopping() }` : tâche montrée dans
  l’emplacement réservé de la barre du haut (progression du premier lot, temps écoulé, « Annuler » quand l’écran donne
  `cancel`) ; un arrêt demandé s’affiche « Arrêt demandé » jusqu’à ce que l’écran termine la tâche.
- `ctx.access.report({ suspended, detail })` : accès suspendus par la garde d’authentification (emplacement « Accès »
  avec compteur, réservé et masqué à zéro).

## 10. Adresses, paramètres et événements

- `?coque=aide|notifications|journal|operations|session|apropos|raccourcis|palette|audit` sur n’importe quel écran
  ouvre le panneau correspondant (liens des guides, captures) ; `?coque=exemples` affiche les quatre bannières d’exemple
  (textes fixes, aucune donnée réelle) et `?coque=exemples-centre` les garde ouvertes dans le centre de notifications.
- Anciennes adresses redirigées : `journal` → `operations`, `index` et `stockage` → Paramètres › Stockage, `outils`
  et `reglages` → Paramètres, `support` → Assistance, `atelier` → Atelier de requêtes, `parcourir` → Rechercher (vue
  Parcourir), `fiabilite` → Opérations à vérifier, `aide` et `raccourcis` → onglets de l’écran « Aide et interface »
  (`shell`), `coque` et `interface` → cet écran, `tableau-de-bord` et `dashboard` → Accueil.
- Événements de `window` : `domenia:refresh` (F5, annulable : un écran qui le gère appelle `preventDefault()`),
  `domenia:focus-search` (Ctrl F, et « Rechercher » du menu, qui met le focus dans la barre de recherche),
  `domenia:subject` (sujet changé ou effacé), `domenia:session` (session lue ou changée ; un changement de compte, de
  domaine ou de racine ferme les panneaux et dialogues, vide les panneaux en attente, retire la demande dans la page et
  redessine l’écran), `domenia:undo-presentation` (palette, annulable).
- Un écran dont le module n’a pas pu s’ouvrir est grisé dans le menu avec son motif ; « Réessayer » de sa notification le
  rend.
- Raccourcis : Ctrl K / Ctrl P palette, F1 aide, Maj ? raccourcis, F5 actualiser, Ctrl B menu, Ctrl F rechercher,
  Ctrl D accueil, Ctrl L journal, Ctrl I index, Ctrl T thème, Ctrl Maj C résumé, Alt ← / Alt → historique,
  Alt 1…9 écrans. Un raccourci tapé dans un champ y garde son sens ; un dialogue ouvert garde ses touches.

## 11. Contrat visuel

Thèmes clair, sombre, contraste élevé et « suivre Windows » ; animations riches, réduites ou « suivre Windows »
(`prefers-reduced-motion` respecté). Les 29 paires de couleurs réellement peintes respectent WCAG 2.x sur les trois
thèmes, **sans dette acceptée** (`tokens.css` corrigé le 22/10, contrôlé par `ShellStaticChecksTests` et mesuré en direct
dans « Aide et interface » › Apparence). Les huit séries pastel des graphiques ont un bord plus foncé (3 : 1 sur la carte
claire). Animations de la coque en `transform`, `opacity` et `filter` seulement (aucune couleur ni trait animé ; un test le
vérifie). La barre de titre Windows suit le thème (DWM, sans erreur sur un Windows ancien). Fenêtre courte (< 940 px) :
l’aide se replie le temps que la fenêtre retrouve sa hauteur ; basse (< 700 px) ou étroite : la barre du haut se compacte,
le menu se replie de lui-même et revient à la largeur choisie. Le panneau d’aide (F1) se pose à côté du travail : si la
colonne du contenu tombait sous 1 280 px (une rangée de cinq indicateurs de l’Accueil), le menu se replie le temps de
l’aide (jamais enregistré), réévalué à chaque changement de taille, et revient à sa fermeture ; le bandeau du mode garde
son bouton « Détails » visible.

Barre du haut à **emplacements réservés** (TRV-053) : tâche en cours (progression, temps écoulé, « Annuler »), état des
écritures (puce Simulation, Aperçu, Lecture seule ou Écriture AD active, présente à toutes les largeurs, TRV-093),
connexion, Accès et son compteur, Opérations et son compteur, thème, notifications, aide : un emplacement vide est masqué
sans être retiré, rien ne bouge. Le bandeau d’information du mode (simulation, aperçu) se replie dans la puce (« Masquer »,
préférence `bannerCompact`) ; l’avertissement des écritures réelles reste affiché ; sous 1 000 px de contenu il tient sur
une ligne et sa phrase entière reste dans l’infobulle.

Tableaux (`ctx.createBoard`) : les widgets entrent en cascade une seule fois ; un déplacement, une taille ou une
actualisation les redessine sans rejouer l’entrée. Une série dont toutes les valeurs connues valent zéro s’affiche en
tuiles calmes avec une phrase (`zeroText` de l’entrée), jamais en graphique vide. Une date des données en avance de moins
de 5 minutes sur l’horloge de la page (écart d’horloge entre le moteur et WebView2) se lit « à l’instant » ; au-delà,
« non daté ».
