# Écran « Paramètres » — contrat des opérations

Écran `parametres` (route `#/parametres`, module `web/js/pages/parametres.js` et ses sections dans
`web/js/pages/parametres/`), écran de pont `settings`. Il porte les 51 fonctions PAR de Domenia 1 (`docs/features.json`,
groupes À propos, Apparence et interface, Base locale, Collecte, Configuration, Périmètres par défaut, Préférences),
réparties en neuf sections : Apparence, Connexion et périmètre, Données et cache, Budgets réseau, Journaux, Préférences,
Configuration, Démonstration, À propos. Le statut fonction par fonction est dans `docs/status/parametres.json`.

Adresse : `#/parametres?section=<id>&onglet=<id>&ouvrir=<état>` (sections : `apparence`, `connexion`, `donnees`,
`collecte`, `journaux`, `preferences`, `configuration`, `demonstration`, `apropos` ; onglets de Données et cache :
`apercu`, `sauvegardes`, `conservation`, `diagnostic`, `assistant`, `politique`, `reprise` ; états ouverts : `ou` (choix de
l’OU de travail), `apercu` (prévisualisation de la conservation), `purge`, `diagnostic` (mesure et intégrité), `plan`,
`reprise`, `fenetre`). L’écran réécrit l’adresse sans recharger quand on change de section ou d’onglet.

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
- **Préférences** (`LocalWrite`) : clés `settings.connection`, `settings.collection`, `settings.storage` et les clés des
  autres écrans (`dashboard.disabledWidgets`, `workingScope.<domaine>`). En capture et en E2E elles restent en mémoire.
  Les réglages d’interface (zoom, densité, profil, panneau d’aide, lecture du journal) vivent dans le navigateur de la
  page (`localStorage` `domenia.ui.v1`, appliqués par le shell), le thème, les animations et le menu replié dans les
  préférences du shell.
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
| `settings.storage.backup.plan` | LocalRead (plan) | — | `PlannedWrite` de type `storage.backup` (copie vérifiée, rotation, préférences jointes). |
| `settings.storage.backupCopy.plan` | LocalRead (plan) | `{ destination }` (chemin local `.db`, ≤ 260) | `storage.backupCopy` : sauvegarde vérifiée publiée vers le fichier choisi. |
| `settings.storage.retention.plan` | LocalRead (plan) | `{ fingerprint }` | `storage.retention`, lié à sa prévisualisation. |
| `settings.storage.purge.plan` | LocalRead (plan) | `{ categories, historyDays?, fingerprint }` | `storage.purge` ; nom du domaine saisi. |
| `settings.storage.move.plan` | LocalRead (plan) | `{ destination }` | `storage.move` : copie contrôlée, bascule, original gardé en lecture seule. |
| `settings.storage.restore.plan` | LocalRead (plan) | `{ backupId }` (32 hexadécimaux) | `storage.restore` : sauvegarde vérifiée restaurée dans un nouveau fichier ; nom du domaine saisi. |
| `settings.storage.resume.plan` | LocalRead (plan) | — | `storage.resume` : reprise d’une bascule interrompue. |
| `settings.storage.rollback.plan` | LocalRead (plan) | — | `storage.rollback` : retour à la base précédente tant que la nouvelle n’a rien reçu. |
| `settings.storage.writerResume.plan` | LocalRead (plan) | — | `storage.writerResume` : reprise des enregistrements locaux suspendus. |
| `settings.storage.legacy.plan` | LocalRead (plan) | `{ fingerprint }` | `storage.legacyImport` : reprise idempotente des données de Domenia 1 ; nom du domaine saisi. |
| `settings.preferences.reset` | LocalWrite | `{ group }` : `widgets`, `workingScope`, `collection`, `storage`, `connection`, `all` | `PreferenceApplyResult` (clés, échecs, résumé). Le groupe `interface` est appliqué par la page (shell). |
| `settings.demo` | LocalRead | — | `SimulationView` : mode, raison du démarrage, faits de l’annuaire fictif (graine, date de référence, comptes, surcouche, empreinte), garanties, marche à suivre. |
| `settings.about` | LocalRead | — | `AboutView` : identité (version, .NET, WebView2, système, mode), compatibilité (matrice livrée), composants (version seulement liée au SHA-256 du fichier), emplacements, engagements. |
| `settings.config` | LocalRead | — | `ConfigurationReport` : état du fichier `Domenia.config.json`, sections (valeur en vigueur, défaut, provenance `default`/`file`/`clamped`/`invalid`, bornes, usage dans Domenia 2), politique des éléments d’interface, profil Expert autorisé, sections inconnues, notes. |
| `settings.logs` | LocalRead | — | `LogsView` : fichier (taille, date, tronqué), au plus 600 enregistrements de la fin (256 Ko), journal des opérations de la session, règles. |
| `settings.dataPolicy` | LocalRead | — | `DataPolicyView` : chaque donnée gardée sur le poste (contenu, emplacement, durée, export, suppression), engagement « aucune donnée hors de ce poste ». Politique illisible → « durée inconnue », jamais un défaut. |
| `settings.folder.open` | Local | `{ folder }` : `app`, `data`, `logs`, `preferences`, `receipts`, `profile`, `base` | Ouvre l’Explorateur (geste explicite) ; refusé en capture et E2E. |
| `settings.preferences` | LocalRead | — | `PreferencesView` : document du mode (état, taille, date), clés par écran, groupes de réinitialisation. |
| `settings.preferences.export` | LocalRead | — | `PreferenceExport` : texte `domenia.preferencesExport` v1, clés triées, sans `settings.connection`. |
| `settings.preferences.import.preview` | Local | `{ text }` | `PreferenceImportPreview` : changements (ajout, remplacement), refus nommés, inchangés, partie interface, `fingerprint`. |
| `settings.preferences.import` | LocalWrite | `{ text, fingerprint }` | `PreferenceApplyResult`. Empreinte différente → `settings.previewStale`. |

## 3. Écritures de la base locale

| Type de plan | Confirmation | Préconditions relues avant l’envoi | Relecture après |
|---|---|---|---|
| `storage.backup` | simple | même base, aucune bascule à terminer | nouvelle copie avec `quick_check`, SHA-256 et date de vérification ; sinon elle ne compte pas |
| `storage.backupCopy` | simple | idem, destination admise | copie locale vérifiée et publication enregistrée |
| `storage.retention` | simple | même base à la même révision | plus aucune ligne antérieure aux dates limites du plan |
| `storage.purge` | nom du domaine | même révision | catégories purgées vides ; associations déclarées, reçus, configuration intacts |
| `storage.move` | simple | même révision, destination admise et réserve d’espace (deux copies + 32 Mo) | base active au nouvel emplacement ; retour possible |
| `storage.restore` | nom du domaine | sauvegarde vérifiée, aucune bascule à terminer | base active restaurée, révision de la sauvegarde ; la sauvegarde n’est jamais modifiée |
| `storage.resume` / `storage.rollback` / `storage.writerResume` | simple | une bascule interrompue / annulable / un écrivain suspendu existe | état relu |
| `storage.legacyImport` | nom du domaine | données trouvées, empreinte de la simulation | éléments du plan repris ; une nouvelle simulation ne trouve rien |

Une sauvegarde vérifiée précède toute conservation, purge, restauration ou reprise (hors rotation). Une base déclarée
illisible n’admet que la restauration d’une sauvegarde vérifiée.

## 4. Mémoire de l’écran

- Préférences du moteur : `settings.connection` (souvenir de l’identifiant, jamais de mot de passe), `settings.collection`
  (profil, durées par profil, fenêtre par profil, budgets), `settings.storage` (sauvegarde automatique, six durées).
- Navigateur de la page (`domenia.ui.v1`) : `zoom` (80 à 150), `density` (`confort`, `compact`), `profile` (`essentiel`,
  `expert`, si `UI.AllowExpertProfile`), `helpVisible`, réglages de lecture du journal (taille, retour à la ligne, suivi,
  erreurs seules). Le shell applique zoom, densité (`data-density`) et profil (`data-profile`) au démarrage, et Ctrl +
  molette, Ctrl +, Ctrl −, Ctrl 0.
- Section, onglet et état ouvert : dans l’adresse.

## 5. Simulation

La base locale de la simulation est **fictive et en mémoire** (`SimulatedLocalStore`) : dérivée une fois du monde généré
et du sous-flux `screen/settings` de la graine (révision 1284, mesures vieillies jour par jour sur 800 jours, neuf
sauvegardes vérifiées, trois périmètres en cache, six éléments de Domenia 1 à reprendre). Aucune base SQLite n’est ouverte,
aucun fichier n’est écrit (`docs/SIMULATION.md` § 1). Les mesures et contrôles prennent des délais réalistes annulables
(`settings/measure` 380 à 760 ms, `settings/integrity` 420 à 880 ms) ; chaque étape d’écriture a les siens
(`settings/write/plan|check|execute|verify`). Les écritures de Paramètres changent cette base fictive pour la session,
par le même circuit et les mêmes règles (`StorageWritePlans`, pur) qu’en mode annuaire. Les préférences de connexion sont
en lecture seule.

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
  Compatibilité, Journal) qui mènent à leur section.
- Rail des sections avec pastille glissante (clavier : flèches, Début, Fin), contenu en cartes ; animations par
  `transform`, `opacity` et `filter`, réduites avec « Animations réduites » ou le réglage de Windows ; thèmes clair, sombre
  et contraste élevé.
- Captures : `tools/vm.sh parametres capture --routes parametres,…` avec les variantes d’adresse ci-dessus.
- Scénarios E2E : `tests/e2e/parametres/*.json` (thème, sauvegarde par le circuit, fenêtre de collecte, recherche,
  préférences).
