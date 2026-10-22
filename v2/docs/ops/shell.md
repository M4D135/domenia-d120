# Opérations de la coque (`shell.*`)

Deux modules déclarent l’écran `shell` : `Domenia.Bridge/Operations/ShellOperations.cs` (règles pures et lecteur de
l’écran, testables sans fenêtre) et `Domenia.App/Shell/ShellHostOperations.cs` (ce qui exige le poste : fenêtre, dossier
des exports, Explorateur, registre, PDF). Les modèles sont dans `Domenia.Core/Screens/Shell/`, le lecteur de simulation
dans `Domenia.Simulation/Screens/Shell/SimulatedShellReader.cs`, les fichiers locaux dans `Domenia.Store/Shell/`.

Aucune de ces opérations n’écrit dans l’annuaire : la seule classe `Write` reste `write.execute` (WRITES.md). Les
erreurs suivent OPERATIONS.md (`argument.invalid`, `operation.unknown`, `mode.unavailable`…) ; celles de l’écran sont
dans `ShellErrors` (§ 4). Les textes renvoyés sont en français, avec la typographie de `FrenchText`.

## 1. Préférences, activité, garde-fous (`ShellOperations`)

| Opération | Classe | Arguments | Réponse |
|---|---|---|---|
| `shell.interface.get` | LocalRead | aucun | `{ persistent, interface, layouts, boards, ouFavourites, warning }` |
| `shell.interface.set` | LocalWrite | `interface?`, `layouts?`, `boards?`, `ouFavourites?` (objets ou `null`) | même forme, relue après enregistrement |
| `shell.activity` | LocalRead | aucun | `{ tasks, receipts: { available, total, pending, unreadable }, active, counterText, detail, journal[], at }` |
| `shell.fault` | LocalWrite | `kind` (`error`, `rejection`, `nested`, `swallowed`), `route` (nom d’écran), `count` (1 à 10 000), `place?` (identifiant du code, 64 caractères) | `{ traced, total, swallowed }` |
| `shell.metric` | LocalWrite | `kind` (`sheet`), `route` (nom d’écran), `count` (1 à 1 000), `milliseconds` (0 à 86 400 000) | `{ traced, panels, totalMilliseconds }` |
| `shell.demo.coverage` | LocalRead | aucun | `{ available, mode, fixtures[], present, total, summary }` |

- **Préférences** (`ShellInterfaceRules`) : clés `shell.interface`, `shell.layouts`, `shell.boards` et
  `shell.ouFavourites.<SHA-256 de la racine du domaine>` du magasin de préférences. Champs de l’interface admis et
  bornés : `theme` (`light`, `dark`, `contrast`, `system`), `motion` (`full`, `reduced`, `system`), `profile`
  (`essentiel`, `expert`), `density`, `navWidth` (200 à 360), `navCollapsed`, `helpTips`, `helpIntroSeen`,
  `bannerCompact`, `recentCommands`, `recentPages`, `pinnedCommands` (identifiants vérifiés). Une adresse récente qui
  nomme un objet de l’annuaire ou un texte saisi (`dn`, `ou`, `q`, `guid`… ou un « = » encodé) n’est **jamais
  enregistrée** : elle reste dans la mémoire de la session (comme l’historique de Domenia 1). Dispositions des listes :
  200 au plus, 16 Kio chacune, 256 Kio en tout ; tableaux : 16 au plus, 64 Kio chacun. Une valeur hors bornes est
  refusée et comptée (journal), jamais tronquée en silence. OU favorites : 20 au plus, dans le domaine, jamais la racine.
  Un enregistrement impossible rend un `warning` et une ligne « Préférences non enregistrées » ; l’interface garde la
  valeur dans le profil WebView2. En capture et E2E, `persistent` vaut `false` (mémoire seulement).
- **Activité** (`ShellActivityService`) : tâches de la session (lectures en cours et en attente), reçus d’écriture du
  mode en attente de vérification, 50 dernières lignes du journal des opérations. `counterText` est vide à zéro, le
  nombre jusqu’à 99, puis `99+`. Local seulement.
- **Fautes de l’interface** (`ShellFaultTracer`) : une ligne de journal par nature, par écran, par endroit du code et par
  minute au plus, avec le nombre d’occurrences ; jamais un message ni une pile (ils pourraient contenir une valeur lue).
  `nested` : erreur survenue pendant le traitement d’une autre (annoncée ensuite, jamais perdue) ; `swallowed` : erreur
  volontairement ignorée par la page (Domenia 1 `Write-DomeniaSwallowed`), tracée mais pas comptée parmi les erreurs.
- **Temps bloqué** (`ShellMetricTracer`, TRV-056) : panneaux modaux fermés et temps pendant lequel ils ont bloqué
  l’interface, sommés pour la session et tracés une fois par minute au plus par écran (nombres seulement).
- **Couverture de la démonstration** : 13 cas de l’annuaire fictif (OU, comptes verrouillé et désactivé, admins,
  accents, apostrophes, virgule échappée, LAPS bientôt expiré et expiré, poste sans DNS, groupe vide, groupe « Tous »,
  compte refusé), chacun avec son nombre ; un cas absent est dit absent (`present: false`). En mode annuaire :
  `available: false`, rien n’est compté.

## 2. Recherche d’objets et interface automatisable (`ShellOperations`)

| Opération | Classe | Arguments | Réponse |
|---|---|---|---|
| `shell.lookup` | LocalRead (simulation) · NetworkRead (annuaire) | `text` (2 à 160 caractères ; 1 si seule l’OU est cherchée), `kinds?` (`user`, `computer`, `ou`) | `{ items[], total, truncated, summary }`, 100 objets au plus |
| `shell.lookup.verify` | idem | `dn`, `objectGuid` (8-4-4-4-12) | `{ state, message, item }` avec `state` = `ok`, `moved`, `missing`, `denied` |
| `shell.ou.resolve` | idem | `dn` | `{ state, message, item }` : l’OU de ce DN avec son GUID (`ok`, `missing`, `denied`), pour le sélecteur d’OU |
| `shell.automation.contract` | Local | aucun | contrat `Domenia.Automation/1` |
| `shell.automation.preview` | LocalRead | `command`, `ou?`, `computers?`, `guids?`, `limit?`, `format?` | `{ valid, exitCode, error, request, output, outputFormat, rows, truncated, summary }` |

- `items[]` : `{ kind, kindLabel, name, dn, objectGuid, detail, path, enabled }`, triés par nature puis nom.
  `detail` distingue deux homonymes (compte, UPN ou nom DNS) ; `path` est le chemin lisible du conteneur.
- La revérification compare le DN **et** le GUID : `moved` rend l’objet à son nouveau DN, `missing` dit qu’il
  n’existe plus, `denied` qu’il ne peut pas être choisi avec ce compte. Le sélecteur ne rend jamais un objet non
  revérifié ; un objet `moved` n’est rendu qu’après une confirmation visible de l’opérateur.
- `shell.ou.resolve` : le sélecteur d’OU relit le GUID d’une OU choisie dans l’arbre (l’arbre ne connaît que noms et DN),
  puis revérifie DN et GUID par `shell.lookup.verify` à la validation. Un objet du DN qui n’est pas une OU répond
  `missing`. La recherche d’OU du sélecteur passe par `shell.lookup` (`kinds: ["ou"]`, 100 OU au plus).
- **Contrat d’automatisation** (`ShellAutomation`) : commandes `version`, `etat`, `postes`, `observations`,
  `associations`, `requetes`, `dossier` ; codes de sortie 0 (succès), 2 (argument), 3 (base absente), 4 (périmètre
  exigé), 5 (erreur) ; bornes 1 000 lignes par défaut, 5 000 au plus, 500 noms, OU de 2 048 caractères ; cinq règles
  (lecture seule de la base locale, aucun contact réseau, périmètre explicite, troncature signalée, champs secrets
  exclus) et les options de la ligne de commande (`options[]` : nom, sens, exemple). L’aperçu valide la ligne de commande
  et montre la réponse de `version`, `etat` et `postes` (100 lignes au plus) ; les autres commandes sont validées sans
  aperçu. La ligne de commande elle-même attend `Program.cs` et la base
  SQLite (statut partiel, `docs/status/shell.json`).

## 3. Poste, fichiers et fenêtre (`ShellHostOperations`)

| Opération | Classe | Arguments | Réponse |
|---|---|---|---|
| `shell.about` | LocalRead | aucun | `{ name, version, runtime, webViewRuntime, mode, modeLabel, compatibility, compatibilityTone, facts[] }` |
| `shell.window.chrome` | Local | `title?`, `dark`, `writeActive`, `caption?`, `text?` (couleurs `#rrggbb`) | `{ applied }` |
| `shell.policy` | LocalRead | aucun | `{ expertAllowed, source, problem }` (`UI.AllowExpertProfile` de `Domenia.config.json`) |
| `shell.export.save` | LocalWrite | `kind` (`csv`, `json`), `name`, CSV : `headers`, `rows`, `secretColumns?` ; JSON ou CSV prêt : `text` ; `target?` : `{ folder, fileName, replace? }` | `{ fileName, folder, rows, masked, withheld[], stored, message }` |
| `shell.export.list` | LocalRead | aucun | `{ folder, stored, items[] }` (50 derniers) |
| `shell.export.open` | Local | `fileName?` (nom d’un export de Domenia) | `{ opened }` |
| `shell.files.browse` | LocalRead | `folder?` (absent : emplacements de départ), `filter` (`csv`, `json`, `all`) | `{ folder, label, parent, entries[], truncated, note, share }` |
| `shell.files.read` | LocalRead | `path`, `kind` (`csv`, `json`) | `{ fileName, kind, delimiter, headers, rows, total, truncated, text }` |
| `shell.files.share` | NetworkRead (refusée en simulation) | `folder` (`\\serveur\partage\…`), `filter` | même forme que `shell.files.browse`, `share: true` |
| `shell.files.shareRead` | NetworkRead (refusée en simulation) | `path`, `kind` | même forme que `shell.files.read` |
| `shell.guide.info` | LocalRead | `page` | `{ page, guide, guideTitle, chapter, title, text, file, found, opened, message }` |
| `shell.guide.open` | Local | `page` | idem, `opened` vrai si le lecteur PDF a été lancé |
| `shell.board.team` | LocalRead | `board` (nom de tableau) | `{ board, key, text, problem }` (texte JSON de la disposition, ou motif d’absence) |

- **À propos** : faits locaux lus une fois par session (registre `CurrentVersion`, version de `winsqlite3.dll`,
  architecture, dossier de données) ; compatibilité : Windows 10 2004 (build 19041) au moins. Jamais le réseau.
- **Barre de titre** : DWM (mode sombre, couleurs de légende, de bordure et de texte) ; sans effet et sans erreur sur un
  Windows qui ne connaît pas l’attribut. Le titre suit `ShellTexts.WindowTitle` (écran, cible, `[ÉCRITURE AD ACTIVE]`
  en mode annuaire avec écriture admise).
- **Classes** : `shell.export.open` et `shell.guide.open` sont `Local` (action locale sur le poste : elles lancent
  l’Explorateur ou le lecteur de PDF associé, sans lire ni écrire de données de Domenia).
- **Arguments** : vérifiés par `ShellHostArguments` (`Domenia.Bridge`), avant tout accès au disque, et testés sans fenêtre.
- **Règles de l’administrateur** : `UI.AllowExpertProfile` (noms sans casse comme Domenia 1) ; seul le booléen `false`
  (ou le nombre 0) masque Expert ; un fichier illisible garde la valeur par défaut, avec son motif (`problem`). Lu une fois
  par session.
- **Exports** : `%LOCALAPPDATA%\Domenia\Exports` (`Exports-Simulation` en simulation), écriture dans un fichier
  temporaire puis déplacement sans écrasement ; nom `Domenia-<sujet>-AAAAMMJJ-HHmm.<ext>`, suffixe `-2`, `-3`… si le nom
  existe. CSV : UTF-8 avec BOM, `;`, CRLF, formules neutralisées, colonnes secrètes retirées (`withheld`), textes
  ressemblant à un secret masqués (`masked`). Un CSV déjà construit par la page (`text`) est **relu** (`ShellCsv.Rebuild`)
  puis réécrit cellule par cellule selon les règles du moteur (neutralisation forte, masquage, lignes comptées par
  enregistrement) ; au-delà de 200 000 lignes ou 1 000 colonnes, il est refusé (`export.tooLarge`), jamais tronqué. Un
  nombre écrit en français (« -5 », « −12,5 ») n’est pas neutralisé. Sans dossier de données (capture, E2E), les exports
  restent en mémoire (`stored: "mémoire"`) et `shell.export.open` rend `opened: false`.
- **Emplacement choisi** (`target`, mode enregistrement du sélecteur) : dossier sous un emplacement de départ, local, sans
  lien ; nom de fichier simple (règles de Windows, extension de la nature). Un fichier existant n’est remplacé que si
  `replace` donne sa taille et sa date telles que le sélecteur les a listées (revérifiées juste avant le déplacement :
  sinon `file.changed`) ; sans `replace`, `file.exists`. Écriture à côté puis déplacement, rien de partiel ; le libellé
  rendu (`folder`) est lisible (« Documents › Rapports »), jamais le chemin complet.
- **Sélecteur de fichier** : emplacements de départ Exports, Documents, Bureau, Téléchargements (mode annuaire) ou le
  seul dossier `Exports-Simulation` (simulation : aucun fichier réel du poste n’est montré). Refus d’un chemin UNC,
  d’un lecteur réseau, d’un point d’analyse (lien, jonction) ou d’un fichier hors des emplacements ; 500 entrées au plus,
  fichiers de 1 Mo au plus, CSV de 5 000 lignes et 200 colonnes au plus. Rien n’est jamais créé ni modifié. Les
  emplacements sur un lecteur réseau ou mappé sont écartés dès la construction (le type du lecteur est demandé une fois) :
  aucune liste ne touche le réseau.
- **Partages réseau** : interrogés seulement à la demande de l’opérateur (`shell.files.share`, `NetworkRead`, refusé en
  simulation), 15 s au plus (`share.timeout`), 500 entrées, aucun lien ; chemin `\\serveur\partage\…` (ni
  périphérique, ni « .. » : `share.refused`). Un fichier d’un partage n’est lu (`shell.files.shareRead`) que dans un
  dossier déjà interrogé pendant la session. Jamais d’enregistrement sur un partage.
- **Guides** : `Domenia-2-Guide-<guide>.pdf` puis `Domenia-1.0-Guide-<guide>.pdf` dans un dossier `DOC` à côté de
  l’application, de son parent ou de son grand-parent. Table des chapitres : `GuideChapters`. Le réseau est testé
  d’abord : depuis un partage ou un lecteur mappé, les dossiers sont regardés une fois et la réponse est gardée pour la
  session ; sur un disque local, un guide trouvé est gardé, un guide absent est cherché de nouveau (« réessayez »).
- **Disposition d’équipe** : `Dashboard.DefaultLayout<Tableau>` de `Domenia.config.json` à côté de l’application, lu à
  la demande, validé comme une disposition importée.

## 4. Erreurs de l’écran (`ShellErrors`)

| Code | Message |
|---|---|
| `lookup.denied` | Accès refusé pour ce compte : cet objet ne peut pas être choisi. |
| `export.unavailable` | Export impossible : le dossier des exports n’a pas pu être écrit. Rien n’a été laissé de partiel. |
| `file.refused` | Fichier refusé : choisissez un fichier local de la liste (ni partage réseau, ni lecteur mappé, ni lien). |
| `file.unreadable` | Fichier illisible pour l’instant : il est peut-être ouvert ailleurs ou trop volumineux (1 Mo au plus). |
| `guide.missing` | Réservé : l’absence du PDF est rendue dans la réponse (`found: false`) avec la marche à suivre et le résumé du chapitre. |
| `folder.unavailable` | Dossier indisponible : il n’existe plus ou ne peut pas être lu. |
| `file.exists` | Un fichier de ce nom existe déjà dans ce dossier : choisissez « Remplacer » dans le sélecteur, ou un autre nom. |
| `file.changed` | Le fichier à remplacer a changé depuis votre choix (taille ou date) : rien n’a été écrit. Choisissez-le de nouveau. |
| `export.tooLarge` | Export refusé : la liste dépasse 200 000 lignes ou 1 000 colonnes. Filtrez-la avant d’exporter. |
| `share.timeout` | Le partage n’a pas répondu dans les 15 secondes : il est lent ou injoignable. Rien n’a été relancé. |
| `share.refused` | Partage refusé : saisissez le chemin complet d’un dossier partagé, ni périphérique, ni lien, ni « .. ». |

## 5. Mode annuaire (vague 3)

En mode annuaire, seules `shell.lookup`, `shell.lookup.verify` et `shell.ou.resolve` touchent l’annuaire ; elles passent
en `NetworkRead` (admission, budgets et annulation du moteur). `shell.files.share` et `shell.files.shareRead` lisent un
partage réseau à la demande. Tout le reste de la coque est local. Le lecteur réel
implémentera `IShellReader` dans `Domenia.Directory` ; ce qui suit est le contrat à respecter.

### 5.1 `shell.lookup`

- **Base** : racine du domaine de la session (`defaultNamingContext`), portée `subtree`, **jamais** lancée sans texte
  (2 caractères au moins ; geste explicite : Entrée dans le sélecteur ou la palette).
- **Filtre** (valeur échappée RFC 4515 : `\2a`, `\28`, `\29`, `\5c`, `\00`), par nature demandée :
  - utilisateurs : `(&(objectCategory=person)(objectClass=user)(|(anr=<t>)(sAMAccountName=<t>*)(userPrincipalName=<t>*)(mail=<t>*)))`
  - postes : `(&(objectCategory=computer)(|(cn=<t>*)(dNSHostName=<t>*)(sAMAccountName=<t>*)))`
  - OU : `(&(objectCategory=organizationalUnit)(ou=*<t>*))`
  - plusieurs natures : un `(|…)` des trois branches, une seule requête.
- **Attributs** (projection minimale) : `objectGUID`, `distinguishedName`, `objectClass`, `cn`, `displayName`,
  `name`, `sAMAccountName`, `userPrincipalName`, `dNSHostName`, `userAccountControl`, `ou`. Aucun attribut secret
  (`unicodePwd`, `ms-Mcs-AdmPwd`, `msLAPS-*`, `msFVE-RecoveryInformation`…) n’est demandé.
- **Budget** : `SizeLimit` 101 (le 101ᵉ signale la troncature : `truncated: true`, « affinez la recherche »), page de
  100, `ServerTimeLimit` 10 s, délai client 15 s, annulable. Une seule lecture en cours par sélecteur : une nouvelle
  frappe d’Entrée annule la précédente.
- **Erreurs** : `0x80072030` (introuvable) → liste vide ; `0x80070005` / `insufficientAccessRights` → `lookup.denied` ;
  délai dépassé → `directory.timeout` (« lent », pas « coupé ») ; serveur injoignable → `directory.unreachable`.
  Aucune nouvelle tentative automatique.

### 5.2 `shell.lookup.verify` et `shell.ou.resolve`

- Lecture de base sur `<GUID=…>` (liaison par GUID, portée `base`), attributs `distinguishedName`, `objectGUID`,
  `objectClass`, `name`, `userAccountControl`. DN différent → `moved` avec le nouveau DN ; `0x80072030` → `missing` ;
  refus → `denied`. Une requête, `ServerTimeLimit` 5 s, aucune relance.
- `shell.ou.resolve` : lecture de base sur le DN (portée `base`, filtre `(objectCategory=organizationalUnit)`), attributs
  `objectGUID`, `distinguishedName`, `name`, `ou`. Absent ou pas une OU → `missing` ; refus → `denied`. Une requête,
  `ServerTimeLimit` 5 s, aucune relance.

### 5.3 Interface automatisable

- La ligne de commande lit **la base locale SQLite** (`Domenia.Store`), jamais l’annuaire ni un poste : aucun appel
  LDAP, WMI ou CIM. Ouverture en lecture seule, périmètre explicite obligatoire pour `postes`, `observations`,
  `associations` et `dossier` (OU de 2 048 caractères au plus, 500 noms ou GUID), 5 000 lignes au plus avec troncature
  signalée.

### 5.4 WMI et budgets

- La coque n’emploie **aucune** requête WMI ni CIM. `shell.about` lit le registre local (`HKLM\SOFTWARE\Microsoft\
  Windows NT\CurrentVersion`) et la version de fichier de `winsqlite3.dll`, une fois par session.
- Budget global de la coque en mode annuaire : au plus une lecture `shell.lookup` et une `shell.lookup.verify` en cours
  par sélecteur ouvert ; la palette n’en lance qu’une à la fois.
