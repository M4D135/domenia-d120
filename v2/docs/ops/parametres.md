# Écran « Paramètres » — contrat des opérations

Écran `parametres` (route `#/parametres`, module `web/js/pages/parametres.js` et ses sections dans
`web/js/pages/parametres/`), écran de pont `settings`. Il porte les 51 fonctions PAR de Domenia 1 (`docs/features.json`,
groupes À propos, Apparence et interface, Base locale, Collecte, Configuration, Périmètres par défaut, Préférences),
réparties en neuf sections : Apparence, Connexion et périmètre, Données et cache, Budgets réseau, Journaux, Préférences,
Configuration, Démonstration, À propos. Le statut fonction par fonction est dans `docs/status/parametres.json`.

Adresse : `#/parametres?section=<id>&onglet=<id>&ouvrir=<état>` (sections : `apparence`, `connexion`, `donnees`,
`collecte`, `journaux`, `preferences`, `configuration`, `demonstration`, `apropos` ; noms admis aussi : `stockage`, `base`,
`index`, `cache`, `sauvegardes` → `donnees`, `journal`, `logs` → `journaux`, `interface`, `theme` → `apparence`, `demo`,
`simulation` → `demonstration`, `about`, `a-propos` → `apropos`, etc. : Ctrl I de la coque ouvre `section=stockage` ; onglets
de Données et cache : `apercu`, `sauvegardes`, `conservation`, `diagnostic`, `assistant`, `politique`, `reprise` ; états
ouverts : `ou` (choix de l’OU de travail), `apercu` (prévisualisation de la conservation), `purge`, `diagnostic` (mesure et
intégrité), `plan`, `reprise`, `restaurer`, `copier`, `fenetre`, `import`, `export`). L’écran réécrit l’adresse sans
recharger quand on change de section ou d’onglet ; l’état `ouvrir` est **consommé une fois** puis retiré de l’adresse : un
rechargement ou un retour arrière ne rouvre jamais un plan ni ne relance une mesure.

## 1. Règles communes

- **Lecture seule par défaut.** Aucune opération de l’écran ne lit le réseau : tout vient du moteur, de la base locale
  (fictive en simulation), du fichier de configuration, du journal technique et des préférences du mode.
- **Écritures de la base locale : toujours par le circuit d’écriture** (`docs/WRITES.md`). Chaque geste prépare un plan
  (`settings.storage.<verbe>.plan`, classe `LocalRead` : il ne change rien), l’opérateur relit la cible (« base locale »,
  `target.kind = "localStore"`), les changements, les risques et la réversibilité, confirme une fois (saisie du nom du
  domaine pour une purge, une restauration et la reprise des données de Domenia 1), puis `write.execute` écrit le reçu
  avant d’agir, agit une fois et relit. Un plan n’est jamais rejoué ; un plan périmé (5 min) se prépare de nouveau.
- **Prévisualiser avant d’agir.** Conservation, purge et reprise : la prévisualisation rend une empreinte SHA-256 des
  comptes et de la révision de la base ; le plan exige cette empreinte et refuse (`settings.previewStale`) dès que la base
  ou la politique a changé.
- **Préférences du moteur** (`LocalWrite`) : clés `settings.connection`, `settings.collection`, `settings.storage`,
  `settings.zoom`, `settings.window` et les clés des autres écrans (`dashboard.disabledWidgets`, `session.workingScope.<empreinte>`).
  En capture et en E2E elles restent en mémoire.
- **Préférences de l’interface : un seul magasin, celui de la coque** (`docs/SHELL.md`) : `localStorage`
  `domenia.prefs.v1`, avec son vocabulaire (`theme`, `motion`, `navCollapsed`, `profile` = `essentiel` | `expert`,
  `density` = `compact` | `normal` | `confortable`, `helpTips`). Paramètres les règle par l’API de la coque quand elle la
  donne aux écrans (`ctx.prefs` : `get`, `set`, `on`), sinon par les commandes mêmes de la coque (boutons de thème de la
  barre du haut, bouton du menu) et la même clé, en gardant toutes les autres clés de la coque (`web/js/pages/parametres/interface.js`).
  L’ancienne clé `domenia.ui.v1` est migrée une fois puis retirée. Paramètres n’écrit plus dans `app.js`.
- **Zoom** : zoom natif de WebView2 (toute la fenêtre ; les requêtes média de tous les écrans suivent ; Ctrl + molette,
  Ctrl +, Ctrl − et Ctrl 0 de WebView2 sur tout clavier, AZERTY compris), gardé entre 80 et 150 % par l’hôte et mémorisé
  dans `settings.zoom` ; rendu au démarrage avec la fenêtre (`Domenia.App/Settings/HostWindow.cs`). Jamais en capture ni en E2E.
- **Aucun secret** : aucune opération ne reçoit ni ne rend de mot de passe ; l’identité de connexion n’est jamais exportée
  ni importée ; le journal technique ne reçoit jamais une saisie de la page.
- Texte français, dates UTC à la seconde (`BridgeJson`), tailles et durées déjà mises en mots par le moteur
  (`SettingsFormat` : « 41,2 Mo », « 1 h 30 min », « sans limite »).

### 1.1 Erreurs propres à l’écran

| Code | Quand | Ce que dit la page |
|---|---|---|
| `settings.simulation` | `settings.connection.set` / `.forget` en simulation | Aucune saisie d’identifiants en simulation, rien n’est mémorisé. |
| `settings.windowInvalid` | fenêtre de collecte invalide à l’enregistrement | Chaque jeton fautif est nommé ; rien n’est enregistré. |
| `settings.previewStale` | empreinte d’une prévisualisation dépassée (conservation, purge, reprise, import de préférences) | « Refaites la prévisualisation » ; rien n’est changé. |
| `settings.storeUnavailable` | pas de base locale (mode annuaire de cette version), maintenance en cours, bascule à terminer, sauvegarde non vérifiée | La raison exacte ; aucune écriture préparée. |
| `settings.destinationRefused` | destination d’une copie ou d’un déplacement : partage, chemin relatif, extension autre que `.db`, base active ou ses journaux, espace insuffisant | La règle enfreinte. |
| `settings.folderUnavailable` | ouverture d’un dossier absent, en capture/E2E, ou de la base fictive | Rien à ouvrir. |
| `settings.importInvalid` | texte d’import illisible, format ou version inconnus | La raison ; rien n’est écrit. |
| `settings.windowUnavailable` | zoom demandé en capture, en E2E, avec des préférences en mémoire ou avant que la fenêtre soit prête | La raison ; le zoom reste tel quel. |
| `settings.restorePreferences` | réapplication de l’annexe refusée : reçu qui n’est pas une restauration appliquée et vérifiée, base active différente, annexe absente ou différente de celle du plan | La raison ; aucune préférence changée. |
| `write.nothingToDo` | conservation sans ligne à retirer, purge sans catégorie admise, rien à reprendre ni à annuler | Rien à faire ; aucun plan. |

Les erreurs génériques (`arguments.invalid`, `operation.unknown`, `simulation.unavailable`, `write.*`) suivent
`docs/OPERATIONS.md` et `docs/WRITES.md`.

## 2. Opérations

Module `SettingsOperations` (`src/Domenia.Bridge/Operations/SettingsOperations.cs`, tout ce qui passe par le moteur) et
module hôte `SettingsHostOperations` (`src/Domenia.App/Settings/SettingsHostOperations.cs`, ce que seul l’exécutable connaît :
fichiers, registre, journal, inventaire). Toutes sont servies en simulation (aucune n’est `NetworkRead`).

| Opération | Classe | Arguments | Résultat |
|---|---|---|---|
| `settings.connection` | LocalRead | — | `ConnectionView` : connexion, mode, domaine, contrôleur, compte, authentification, droits, lecture seule, `preferences` (souvenir de l’identifiant, coffre, `editable`, `reason`), `scope` (OU de travail, chemin lisible, tout le domaine, OU par défaut), `sections` (qui suit l’OU de travail), garde-fous. |
| `settings.connection.set` | LocalWrite | `{ rememberLogin: bool }` | `ConnectionView`. Décocher oublie aussi le dernier identifiant. Refusé en simulation. |
| `settings.connection.forget` | LocalWrite | — | `ConnectionView` ; oublie identifiant et compte du coffre. Refusé en simulation. |
| `settings.collection` | LocalRead | — | `CollectionSettingsView` : profil actif et les trois profils, durées de fraîcheur par famille (valeur, défaut du profil, choix), fenêtre (texte, validité, état ouvert/fermé, prochain changement, phrase, grille 7 × 48), budgets (valeur, bornes, choix, effet), règles, avertissements de lecture. |
| `settings.collection.set` | LocalWrite | au moins un de `profile` (`standard`, `slowNetwork`, `troubleshooting`), `freshness` (objet famille → secondes 0 à 7 j, ou `null` par famille ; `null` rétablit le profil), `window` (texte ≤ 400 ou `null`), `budgets` (objet id → entier borné) | `CollectionSettingsView`. Une fenêtre invalide → `settings.windowInvalid`, rien d’enregistré. |
| `settings.collection.window.check` | Local | `{ text }` ou `{ grid: bool[7][48] }` (lundi d’abord) | `CollectionWindowView` sans rien enregistrer (la grille est traduite en texte : « lun-ven 07:30-12:00 13:30-18:00; sam »). |
| `settings.storage` | LocalRead | — | `StorageView` : disponible, simulée, raison, emplacement, tuiles, contenu, révision, schéma, espace, écrivain, maintenance (assistant), sauvegardes, planification, politique, conservation, limites, occupation, intégrité, catégories de purge, ce qui n’est jamais purgé, catalogue du cache, reprise de Domenia 1, exports. |
| `settings.storage.measure` | LocalRead | — | `StorageView` avec l’occupation par catégorie (`dbstat` si présent, sinon lignes), les lectures mesurées et l’espace libre du volume. |
| `settings.storage.integrity` | LocalRead | — | `StorageView` avec neuf contrôles (ouverture, schéma, tables, identité, redirection, reçus, clés étrangères, `quick_check`, journal WAL) et le verdict. Aucune réparation. |
| `settings.storage.retention.set` | LocalWrite | `{ presenceDays, consoleDays, inventoryDays, probeDays, detailDays, linkHistoryDays }` (0 = sans limite, ≤ 36 500) | `StorageView`. N’efface rien. |
| `settings.storage.backup.schedule.set` | LocalWrite | `{ enabled, hours (1 à 720), keep (2 à 30) }` | `StorageView`. |
| `settings.storage.retention.preview` | LocalRead | — | `RetentionPreview` : par famille, date limite et lignes à retirer, lignes en mots, total, `fingerprint`, `nothingToDo`. |
| `settings.storage.purge.preview` | LocalRead | `{ categories: string[1..8], historyDays? (défaut 730) }` | `PurgePreview` : catégories admises, tables touchées, total, refus nommés, garanties, `fingerprint`. |
| `settings.storage.legacy.preview` | LocalRead | — | `LegacyPreview` : données de Domenia 1 trouvées, éléments, refus, `fingerprint`, `nothingToDo`. |
| `settings.storage.backup.plan` | LocalRead (plan) | — | `PlannedWrite` de type `storage.backup` (copie vérifiée, rotation, annexe des préférences approuvées jointe à chaque copie, même vide, liée au SHA-256 de la copie). |
| `settings.storage.backupCopy.plan` | LocalRead (plan) | `{ destination }` (chemin local `.db`, ≤ 260) | `storage.backupCopy` : sauvegarde vérifiée publiée vers le fichier choisi. |
| `settings.storage.retention.plan` | LocalRead (plan) | `{ fingerprint }` | `storage.retention`, lié à sa prévisualisation. |
| `settings.storage.purge.plan` | LocalRead (plan) | `{ categories, historyDays?, fingerprint }` | `storage.purge` ; nom du domaine saisi. |
| `settings.storage.move.plan` | LocalRead (plan) | `{ destination }` | `storage.move` : copie contrôlée, bascule, original gardé en lecture seule. |
| `settings.storage.restore.plan` | LocalRead (plan) | `{ backupId }` (32 hexadécimaux) **ou** `{ file }` (fichier `.db` d’un disque local ou de `%LOCALAPPDATA%`) | `storage.restore` : sauvegarde vérifiée (du registre, copie publiée ou fichier choisi) restaurée dans un nouveau fichier ; le plan dit le dernier lot, la dernière mesure, les écarts et l’annexe réappliquée ; nom du domaine saisi. |
| `settings.storage.resume.plan` | LocalRead (plan) | — | `storage.resume` : reprise d’une bascule interrompue. |
| `settings.storage.rollback.plan` | LocalRead (plan) | — | `storage.rollback` : retour à la base précédente tant que la nouvelle n’a rien reçu. |
| `settings.storage.writerResume.plan` | LocalRead (plan) | — | `storage.writerResume` : reprise des enregistrements locaux suspendus. |
| `settings.storage.legacy.plan` | LocalRead (plan) | `{ fingerprint }` | `storage.legacyImport` : reprise idempotente des données de Domenia 1 (base au schéma 11, réglages, fichiers de l’ancienne version) ; nom du domaine saisi. |
| `settings.storage.restore.preferences` | LocalWrite | `{ receiptId }` (32 hexadécimaux) | `PreferenceApplyResult` : réapplique l’annexe `Domenia.BackupPreferences.1` de la sauvegarde restaurée, reçu de restauration appliquée et vérifiée à l’appui ; jamais l’identité de connexion ni la fenêtre de ce poste. La page l’appelle d’elle-même après le reçu. |
| `settings.demo.scenario.plan` | LocalRead (plan) | `{ scenario }` : `writerSuspended`, `switchInterrupted`, `storeUnreadable`, `lowSpace`, `normal` | `storage.scenario` : met la base fictive dans un état de panne pour essayer reprises et restaurations ; simulation seulement (`settings.simulation` sinon). |
| `settings.preferences.reset` | LocalWrite | `{ group }` : `widgets`, `workingScope`, `collection`, `storage`, `connection`, `all` | `PreferenceApplyResult` (clés, échecs, résumé). Le groupe `interface` est appliqué par la page (shell). |
| `settings.demo` | LocalRead | — | `SimulationView` : mode, raison du démarrage, faits de l’annuaire fictif (graine, date de référence, comptes, surcouche, empreinte), garanties, marche à suivre. |
| `settings.about` | LocalRead | — | `AboutView` : identité (version, .NET, WebView2, système, mode), compatibilité (matrice livrée), composants (version seulement liée au SHA-256 du fichier), emplacements, engagements. |
| `settings.config` | LocalRead | — | `ConfigurationReport` : état du fichier `Domenia.config.json`, sections (valeur en vigueur, défaut, provenance `default`/`file`/`clamped`/`invalid`, bornes, usage dans Domenia 2), politique des éléments d’interface, profil Expert autorisé, sections inconnues, notes. |
| `settings.logs` | LocalRead | — | `LogsView` : fichier (taille, date, tronqué, erreurs et alertes lues, et celles **de cette session** : `sessionStart`, `sessionErrors`, `sessionWarnings`), au plus 600 enregistrements de la fin (256 Ko), journal des opérations de la session, règles. La pastille de l’écran ne compte que les erreurs de la session. |
| `settings.dataPolicy` | LocalRead | — | `DataPolicyView` : chaque donnée gardée sur le poste (contenu, emplacement, durée, export, suppression), engagement « aucune donnée hors de ce poste ». Politique illisible → « durée inconnue », jamais un défaut. |
| `settings.folder.open` | Local | `{ folder }` : `app`, `data`, `logs`, `preferences`, `receipts`, `profile`, `base` | Ouvre l’Explorateur (geste explicite) ; refusé en capture et E2E. |
| `settings.preferences` | LocalRead | — | `PreferencesView` : document du mode (état, taille, date), clés par écran, groupes de réinitialisation. |
| `settings.preferences.export` | LocalRead | — | `PreferenceExport` : texte `domenia.preferencesExport` v1, clés triées, sans `settings.connection`. |
| `settings.preferences.import.preview` | Local | `{ text }` | `PreferenceImportPreview` : changements (ajout, remplacement), refus nommés, inchangés, partie interface, `fingerprint`. |
| `settings.preferences.import` | LocalWrite | `{ text, fingerprint }` | `PreferenceApplyResult`. Empreinte différente → `settings.previewStale`. |
| `settings.window` | LocalRead | — | `WindowSettingsView` : zoom (80 à 150, pas de 10), disponibilité et raison, fenêtre mémorisée. |
| `settings.window.zoom.set` | LocalWrite | `{ percent }` (80 à 150) | `WindowSettingsView` ; zoom natif appliqué à toute la fenêtre et mémorisé (`settings.zoom`). |
| `settings.window.forget` | LocalWrite | — | `WindowSettingsView` ; oublie la taille et la position mémorisées (défaut au prochain démarrage). |
| `settings.storage.destinations` | LocalRead | — | `DestinationProposal` : nom proposé `Domenia-AAAAMMJJ-HHmm.db`, dossier des sauvegardes de la base, dossiers locaux proposés (Documents, Bureau, exports, données). |
| `settings.folders.browse` | LocalRead | `{ path? }` | `FolderListing` : disques locaux fixes (sans chemin) ou sous-dossiers d’un dossier local (500 au plus, ni cachés, ni système, ni liens). |
| `settings.storage.destination.check` | LocalRead | `{ destination, purpose: copy \| move }` | `DestinationCheck` en lecture seule : règles du chemin, disque local fixe, dossier existant, ni lien ni jonction, fichier existant (refusé pour un déplacement, remplacé pour une copie), réserve du volume (copie : base + 32 Mo ; déplacement : deux copies + 32 Mo). |

## 3. Écritures de la base locale

| Type de plan | Confirmation | Préconditions relues avant l’envoi | Relecture après |
|---|---|---|---|
| `storage.backup` | simple | même base, aucune bascule à terminer | la copie **du plan** (par son nom) avec `quick_check`, SHA-256, date de vérification et annexe des préférences liée à son SHA-256 ; sinon elle ne compte pas |
| `storage.backupCopy` | simple | idem, destination admise | copie locale vérifiée et publication enregistrée |
| `storage.retention` | simple | même base à la même révision | plus aucune ligne antérieure aux dates limites du plan |
| `storage.purge` | nom du domaine | même révision | catégories purgées vides ; associations déclarées, reçus, configuration intacts |
| `storage.move` | simple | même révision, destination admise et réserve d’espace (deux copies + 32 Mo) | base active au nouvel emplacement ; retour possible |
| `storage.restore` | nom du domaine | sauvegarde vérifiée (registre, copie publiée ou fichier choisi), aucune bascule à terminer | base active restaurée, révision de la sauvegarde ; la sauvegarde n’est jamais modifiée ; l’annexe est ensuite réappliquée (`settings.storage.restore.preferences`, reçu à l’appui) |
| `storage.resume` / `storage.rollback` / `storage.writerResume` | simple | une bascule interrompue (marqueur relu, même copie) / annulable ou à abandonner / un écrivain suspendu **sans enregistrement actif** | état relu |
| `storage.legacyImport` | nom du domaine | données trouvées, empreinte de la simulation | éléments du plan repris ; une nouvelle simulation ne trouve rien |
| `storage.scenario` (simulation) | simple | même état de la base fictive qu’au plan | base fictive dans l’état du scénario |

Une sauvegarde vérifiée précède toute conservation, purge, restauration ou reprise (hors rotation). Une base déclarée
illisible n’admet que la restauration d’une sauvegarde vérifiée.

## 4. Mémoire de l’écran

- Préférences du moteur : `settings.connection` (souvenir de l’identifiant, jamais de mot de passe), `settings.collection`
  (profil, durées par profil, fenêtre par profil, budgets), `settings.storage` (sauvegarde automatique, six durées),
  `settings.zoom` (80 à 150), `settings.window` (taille, position, état agrandi ; de ce poste seulement).
- Préférences approuvées (`PreferenceApproval`, liste fermée, un validateur par clé) : `dashboard.disabledWidgets`,
  `session.workingScope.<empreinte>`, `settings.collection`, `settings.storage`, `settings.zoom`. Seules elles sont exportées,
  importées, jointes aux sauvegardes et réappliquées par une restauration ; une clé inconnue est refusée par son nom
  (« clé inconnue de cette version de Domenia »). `settings.connection` et `settings.window` ne quittent jamais ce poste.
- Coque (`domenia.prefs.v1`) : thème, animations, menu, profil (`essentiel`, `expert`, si `UI.AllowExpertProfile`), densité
  (`compact`, `normal`, `confortable`), infobulles. Paramètres pose `data-density` et `data-profile` sur sa page : ses
  tableaux et listes suivent la densité, ses parties techniques (`.pr-expert-only` : empreintes, plans SQLite, noms des
  réglages, détails des contrôles, vue brute du journal) n’apparaissent qu’en Expert ou dans la vue Expert ponctuelle de la
  coque (`ctx.expert`) ; une vue experte n’est jamais laissée sélectionnée au retour en Essentiel.
- Lecture du journal (`localStorage` `domenia.parametres.v1`) : retour à la ligne et taille du texte (confort de ce lecteur).
- Section, onglet et état ouvert : dans l’adresse (état ouvert consommé une fois).

## 5. Simulation

### 5.1 Scénarios de démonstration

Dans la section Démonstration, cinq scénarios mettent la base fictive dans un état qu’une vraie panne laisserait, chacun
par le circuit d’écriture (plan `storage.scenario`, confirmation simple, reçu « simulé ») : **Enregistrement suspendu**
(trois échecs, 14 éléments en mémoire : « Reprendre les sauvegardes » devient possible, PAR-010), **Bascule interrompue**
(marqueur vers `Domenia-deplacee.db` : seules la reprise et le retour sont proposés, PAR-012, PAR-018), **Base illisible**
(`quick_check` en échec, `SQLITE_CORRUPT 11` : seule la restauration d’une sauvegarde vérifiée est proposée, PAR-021,
PAR-026), **Disque presque plein** (moins de 512 Mo libres : collectes suspendues, alerte, PAR-011) et **État normal**.
Un avis sous le bandeau annonce l’enregistrement suspendu (avec « Reprendre les sauvegardes »), la base illisible (avec
« Restaurer une sauvegarde… ») ou le manque d’espace.

### 5.2 Base fictive

La base locale de la simulation est **fictive et en mémoire** (`SimulatedLocalStore`) : dérivée une fois du monde généré
et du sous-flux `screen/settings` de la graine (révision 1284, mesures vieillies jour par jour sur 800 jours, neuf
sauvegardes vérifiées, trois périmètres en cache, six éléments de Domenia 1 à reprendre). Aucune base SQLite n’est ouverte,
aucun fichier n’est écrit (`docs/SIMULATION.md` § 1). Les mesures et contrôles prennent des délais réalistes annulables
(`settings/measure` 380 à 760 ms, `settings/integrity` 420 à 880 ms) ; chaque étape d’écriture a les siens
(`settings/write/plan|check|execute|verify`). Les écritures de Paramètres changent cette base fictive pour la session,
par le même circuit et les mêmes règles (`StorageWritePlans`, pur) qu’en mode annuaire. Les préférences de connexion sont
en lecture seule.

### 5.3 Reprise des données de Domenia 1

La reprise (`LegacyRules`, port de `Read-DomeniaLegacySource`, `Get-DomeniaLegacySnapshot` et `Get-DomeniaMigrationPlan`)
examine trois sources : la **base de Domenia 1** (`Domenia.db`, schéma 11, révision 1, même domaine ; chaque partie suit sa
règle : table reprise seulement si celle de Domenia 2 est vide, ajouts des associations et requêtes absentes sans jamais
remplacer l’existant, historique des reçus gardé en lecture seule), les **réglages** de Domenia 1 (`Domenia.settings.json` :
favoris d’OU, dispositions, collecte, seulement ce qui manque) et les **fichiers de l’ancienne version** (`objets.tsv`,
`parc.tsv`, `recherches.tsv`, `secrets-etat.tsv`, liens poste-utilisateur) avec les garde-fous de Domenia 1 : 128 Mo et
250 000 lignes au plus par fichier, lecture sous verrou partagé, un seul domaine et le même que la session, doublon refusé,
quatre tables cibles vides. Tout blocage refuse la reprise entière (rien n’est écrit, chaque écriture prévue est dite
« reportée ») ; une reprise appliquée pose son marqueur et ne se rejoue jamais. En simulation : base de Domenia 1 fictive
trouvée (37 associations, 7 requêtes, 41 reçus, 16 réglages à reprendre), aucun fichier de l’ancienne version.

### 5.4 Sauvegarde automatique

`StorageBackupScheduler` (Domenia.Bridge) contrôle chaque minute, seulement dans une session aux préférences persistantes
(jamais en capture, en E2E ni dans les tests), seulement si l’opérateur l’a activée : différée pendant un enregistrement local
ou une maintenance, 15 min entre deux essais, arrêtée par une copie datée après l’horloge. Chaque copie passe par le circuit
(plan `storage.backup` de la série « planifiée », reçu avant, relecture après, annexe jointe) ; le consentement est
l’activation de la sauvegarde automatique, limitée à une copie vérifiée qui ne modifie jamais la base. Le dernier essai et
son échec éventuel s’affichent dans la planification. Sans base locale (mode annuaire de cette version), rien ne part.

## 6. Mode annuaire

Paramètres ne fait **aucune requête LDAP ni WMI** et n’ouvre aucune connexion distante : ses données sont locales.

### 6.1 Ce qui est lu sur le poste

| Lecture | Source | Budget |
|---|---|---|
| Identité du système | Registre `HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion` : `InstallationType`, `CurrentBuild`, `DisplayVersion` (lecture seule) | 1 lecture au premier affichage |
| SQLite de Windows | présence de `%SystemRoot%\System32\winsqlite3.dll` | 1 test de fichier |
| WebView2 | version du moteur fixe (`runtime/webview2/msedgewebview2.exe`, ressource de version) ou `GetAvailableBrowserVersionString` | 1 lecture |
| Composants livrés | SHA-256 de `Domenia*.dll|exe` et des DLL WebView2 ; dossiers `web/`, `runtime/`, `runtime/webview2` comptés (fichier de référence haché) | une fois par session (paresseux) |
| Configuration | `Domenia.config.json` à côté de l’exécutable, 1 Mo au plus, lu en partage | à chaque affichage de la section |
| Journal technique | fin du fichier, 256 Ko et 600 enregistrements au plus, lu en partage | à l’affichage, puis toutes les 4 s si « Suivre » |
| Préférences | document du mode, lecture seule partagée (`PreferenceDocument.Inspect`) | à l’affichage |

### 6.2 Base locale (vague 3)

Dans cette version, la base SQLite de Domenia 2 n’est pas encore branchée en mode annuaire : `settings.storage` rend
`available = false` avec la raison, les plans répondent `settings.storeUnavailable`, la politique de conservation et de
sauvegarde reste réglable et s’appliquera à la base. Le branchement prévu (`Domenia.Store`, `winsqlite3.dll` de Windows) :

- emplacement `%LOCALAPPDATA%\Domenia\Data\Domains\<domaine>\Domenia.db` (WAL), redirection lisible par marqueur ;
- espace libre du volume par `DriveInfo` : réserve d’écriture 32 Mo, suspension sous 512 Mo, alerte sous 2 Go ;
- sauvegarde par l’API `sqlite3_backup_*` en lecture seule, `PRAGMA quick_check`, SHA-256, rotation ; préférences jointes
  (`.preferences.json`, clés approuvées, sans identité de connexion) ;
- mesure par `dbstat` si disponible (sinon `COUNT(*)` par table), lectures mesurées avec `EXPLAIN QUERY PLAN` ;
- intégrité : neuf contrôles en lecture (`PRAGMA integrity_check` limité, `foreign_key_check`, schéma, identité) ;
- conservation et purge : `DELETE` par tables fermées (jamais de SQL venu de la page), dans des transactions bornées, après
  la sauvegarde vérifiée ; `sync_state` réinitialisé pour l’index ;
- déplacement et restauration : copie contrôlée vers un nouveau fichier, bascule atomique, original gardé en lecture seule ;
- budgets : une seule écriture de maintenance à la fois, file de 32 tâches, 6 lectures simultanées (valeurs `Async` de
  Domenia 1), aucune maintenance sur le fil de l’interface.

### 6.3 Réseau et WMI

Aucun. Les budgets réseau réglés ici (parallélisme 1 à 8, réutilisation 0 à 1 440 min, plafond de cibles 1 à 20 000,
plafond des widgets, essais WMI 0 à 4 espacés de 10 à 120 s, fenêtre de collecte) sont lus par les écrans qui mesurent
(Accueil, Postes, Synchronisation) ; ils ne déclenchent rien eux-mêmes.

## 7. Écran

- Bandeau : titre, puces d’état, recherche des réglages (« / »), quatre tuiles de santé (Apparence, Base locale,
  Compatibilité, Journal) qui mènent à leur section, avis de la base (enregistrement suspendu, base illisible, disque
  presque plein) avec son action.
- Disposition par **requêtes de conteneur** (`pr-page`, `pr-content`) : la page suit la largeur qui lui est donnée (menu,
  panneau d’aide, zoom), jamais la seule largeur de la fenêtre.
- GuiElementPolicy (`Domenia.config.json`) appliquée aux contrôles de Paramètres qui ont un équivalent dans Domenia 1
  (`BtnIndexBackup`, `BtnStorageMove`, `CmbSuiteDensity`…) : « Disabled » grise avec la raison, « Hidden » masque ;
  « Default » n’active jamais ce que les droits ou le mode refusent.
- Choix d’une destination dans la page (jamais une fenêtre de Windows) : nom proposé, dossiers proposés, explorateur des
  dossiers locaux, contrôle en direct du volume. Choix de la sauvegarde à restaurer : registre, copies publiées ou autre
  fichier `.db`.
- Rail des sections avec pastille glissante (clavier : flèches, Début, Fin), contenu en cartes ; animations par
  `transform`, `opacity` et `filter`, réduites avec « Animations réduites » ou le réglage de Windows ; thèmes clair, sombre
  et contraste élevé.
- Captures : `tools/vm.sh parametres capture --routes parametres,…` avec les variantes d’adresse ci-dessus.
- Scénarios E2E : `tests/e2e/parametres/*.json` (thème, sauvegarde par le circuit, fenêtre de collecte, recherche,
  préférences, ancienne adresse `stockage`, densité et profil Expert, enregistrement suspendu repris, base illisible
  restaurée, destination d’une copie). Tests C# : `SettingsRulesTests`, `SettingsOperationsTests`,
  `SettingsCompletionTests` ; tests JavaScript : `tests/web/parametres.test.mjs`. Écrits, non exécutés (décision du 22/10).
