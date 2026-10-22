# Catalogue des fonctions de Domenia 1 pour Domenia 2

Ce catalogue est la liste de contrôle de la réécriture : chaque fonction de Domenia 1 y figure une seule fois, avec son statut dans Domenia 2. Il a été établi le 21 octobre 2026 à partir du code de Domenia 1 (`dev/wad`, cœur, 157 modules, XAML, catalogue d'aide) et du code de Domenia 2 (`v2/src`, `v2/web`). La version lisible par programme est `features.json`, dans ce même dossier : un objet par fonction, avec les mêmes identifiants.

## Statuts

| Statut | Sens |
|---|---|
| `a-faire` | Statut par défaut : la fonction existe dans Domenia 1 et n'est pas encore reprise dans Domenia 2. |
| `fait` | Domenia 2 fait déjà ce que faisait Domenia 1 ; vérifié dans `v2/src` ou `v2/web` (la preuve est donnée plus bas). |
| `ameliore` | Domenia 2 fait la fonction et l'améliore (réservé aux fonctions livrées avec une amélioration de la liste « Nouveautés »). |
| `partiel` | Domenia 2 fait une partie de la fonction ; ce qui reste à faire est écrit sous la fonction (« Reste à faire », repris de `docs/status/<page>.json`). |
| `abandonne` | La fonction n'est pas reprise. Ce statut n'est posé que sur une décision écrite et datée de David : PST-001 (WAPT, décision du 22/10/2026). |

Classe d'une fonction : **locale** (aucune lecture : règle, affichage, préférence), **lecture locale** (base SQLite, fichier, mémoire), **lecture réseau** (annuaire, poste, DNS, contrôleur), **écriture** (annuaire, poste ou base locale). Une fonction qui réunit plusieurs fiches prend la classe la plus engageante.

## Méthode

1. **Extraction.** Huit lecteurs ont lu chacun un périmètre du code de Domenia 1 et produit 1 181 fiches : annuaire 232, comptes et écritures 91, postes et inventaire 167, tableaux de bord 113, requêtes et audit 116, assistance et expérience 123, infrastructure 151, cœur 188.
2. **Dédoublonnage.** Les fiches qui décrivent la même fonction ont été repérées par leurs références communes (contrôles XAML, fonctions PowerShell, opérations) et par la proximité des titres, puis vérifiées une à une. 168 fonctions réunissent plusieurs fiches ; 192 fiches ont disparu dans ces fusions ou ont été réparties (les fiches de simple inventaire d'écran du cœur, dont chaque contrôle est décrit ailleurs). Une fusion garde la description la plus complète et réunit références, opérations, garde-fous et améliorations.
3. **Complétude.** Le résultat a été comparé à l'inventaire des 1 164 contrôles WPF (`dev/web/PARITE.json`), à la table des 111 opérations (`Get-DomeniaOperationTable`) et aux 820 sujets du catalogue d'aide (`Domenia-UX.help.json`). Les contrôles non référencés ont été rattachés à la fonction qui les porte et 4 fonctions manquantes ont été ajoutées après lecture du code. Les chiffres sont dans la dernière section.
4. **Identifiants.** Chaque page a son préfixe (ACC, RCH, FIC, CPT, REL, PST, MAC, ASS, REQ, AUD, SCH, SYN, OPE, PAR, TRV). Les numéros suivent l'ordre alphabétique des groupes, puis l'ordre de lecture. Ils sont attribués une fois pour toutes : une fonction ajoutée plus tard prend le numéro libre suivant de sa page, sans renuméroter les autres.
5. **Statut.** Tout est `a-faire` par défaut. 13 fonctions sont `fait` après vérification du code de Domenia 2 ; aucune n'est `abandonne`. À l'intégration de la vague 2 (22/10/2026), les statuts des fonctions des écrans ont été repris des fichiers `docs/status/<page>.json` (le fichier de la page propriétaire l'emporte quand deux écrans citent la même fonction) ; PST-001 est `abandonne` sur décision de David du 22/10/2026.
6. **Pages.** Les pages sont celles de la navigation de Domenia 2 (`web/js/app.js`). Une fonction utilisée par plusieurs écrans est rangée dans « Transverse ». La page « Comptes machine » correspond à la vue `MachineAccount` de Domenia 1, le panneau « Compte poste ».

## Synthèse par page

| Page | Préfixe | Fonctions | Faites | Améliorées | Partielles | À faire | Abandonnées |
|---|---|---:|---:|---:|---:|---:|---:|
| [Accueil](#acc) | ACC | 64 | 46 | 8 | 10 | 0 | 0 |
| [Rechercher](#rch) | RCH | 137 | 116 | 14 | 7 | 0 | 0 |
| [Fiche](#fic) | FIC | 50 | 23 | 27 | 0 | 0 | 0 |
| [Comptes](#cpt) | CPT | 21 | 9 | 7 | 5 | 0 | 0 |
| [Utilisateurs et postes](#rel) | REL | 52 | 33 | 13 | 6 | 0 | 0 |
| [Poste](#pst) | PST | 117 | 81 | 31 | 4 | 0 | 1 |
| [Comptes machine (panneau Compte poste)](#mac) | MAC | 3 | 0 | 2 | 1 | 0 | 0 |
| [Assistance](#ass) | ASS | 16 | 5 | 9 | 2 | 0 | 0 |
| [Atelier de requêtes](#req) | REQ | 69 | 29 | 37 | 3 | 0 | 0 |
| [Audit AD](#aud) | AUD | 23 | 14 | 9 | 0 | 0 | 0 |
| [Schéma de l'annuaire](#sch) | SCH | 8 | 2 | 6 | 0 | 0 | 0 |
| [Synchronisation et base autonome](#syn) | SYN | 30 | 17 | 13 | 0 | 0 | 0 |
| [Opérations](#ope) | OPE | 36 | 16 | 10 | 10 | 0 | 0 |
| [Paramètres](#par) | PAR | 51 | 5 | 9 | 37 | 0 | 0 |
| [Transverse : moteur, sécurité, stockage, interface commune](#trv) | TRV | 316 | 66 | 21 | 5 | 224 | 0 |
| **Total** | | **993** | **462** | **216** | **90** | **224** | **1** |

## Fonctions déjà faites dans Domenia 2

Ce tableau date de l'établissement du catalogue (21/10/2026). Depuis l'intégration de la vague 2 (22/10/2026), les preuves des fonctions des écrans sont dans leurs contrats `docs/ops/<page>.md` et dans les notes de `docs/status/<page>.json`.

| ID | Fonction | Preuve dans Domenia 2 |
|---|---|---|
| PAR-006 | Menu replié en icônes | `web/js/app.js` : Ctrl+B et préférence `navCollapsed` mémorisée ; `web/css/layout.css` : repli automatique sous 900 px. |
| PAR-008 | Thème clair, sombre ou automatique | `web/js/app.js` : thèmes clair, sombre, contraste élevé et « suivre Windows », mémorisés, réappliqués quand Windows change (`prefers-color-scheme`). |
| TRV-001 | Contraste élevé Windows | `web/js/app.js` (`forced-colors`, `prefers-contrast`) et `web/css/tokens.css` : le contraste élevé de Windows bascule sur le thème contrasté. |
| TRV-002 | Annonces au lecteur d'écran | `web/js/ui.js` (`announce`, régions polies et assertives créées au démarrage) ; `web/js/router.js` annonce l'écran ouvert. |
| TRV-017 | Chargement différé des vues optionnelles | `web/js/router.js` : chaque écran est un module chargé à sa première ouverture, avec écran d'erreur et « Réessayer ». |
| TRV-047 | Annuaire de démonstration en mémoire | `src/Domenia.Simulation/SimulatedWorldGenerator.cs` et `SimulatedDirectorySource.cs` : annuaire fictif `example.local` en mémoire, lecture seule, sans réseau ni disque. |
| TRV-168 | Menu de navigation latéral | `web/js/app.js` (liste `PAGES`, `aria-current`, pastille animée) et `web/js/router.js` (routes fermées, écran annoncé). |
| TRV-177 | Palette de commandes (Ctrl+K) | `web/js/palette.js` : panneau dans la page (Ctrl+K, Ctrl+P), recherche sans accents ni casse, flèches, Entrée, Échap, focus rendu ; commandes de pages et d'actions fournies par `web/js/app.js`. |
| TRV-209 | Démarrage toujours en lecture seule sur Accueil | `web/js/router.js` (route par défaut `accueil`) ; `DashboardService.GetSummaryAsync` ne mesure rien au démarrage ; aucune écriture n'existe encore. |
| TRV-289 | Actualiser un seul widget | `web/js/pages/accueil.js` (« Actualiser ce widget ») et `src/Domenia.Core/Dashboard/DashboardService.cs` (`RefreshAsync` : une seule famille de mesures, widget désactivé refusé). Reste : F5 et info-bulle de ce qui est relu. |
| TRV-294 | Copier le résumé du tableau | `web/js/pages/accueil.js` (`copySummary`) : date, domaine, contrôleur, compte, OU puis chaque widget en texte. |
| TRV-297 | Animations d'entrée respectueuses du réglage Windows | `web/js/ui.js` (`reveal`, `countUp`), `web/css/motion.css` ; réglage « Animations riches, réduites, suivre Windows » (`web/js/app.js`). |
| TRV-304 | Redessin au changement de thème | `web/css/tokens.css` : thèmes par variables CSS, les widgets se repeignent sans relecture ni recalcul. |

L'Accueil de Domenia 2 affiche déjà dix widgets calculés par `src/Domenia.Core/Dashboard/DashboardCalculator.cs` (postes en ligne, comptes actifs, comptes verrouillés, mots de passe expirant sous 7 jours, alertes disque, systèmes d'exploitation, activité des postes sur 7 jours, fraîcheur des mesures, postes à surveiller, dernières opérations), chacun actualisable et désactivable. Ils couvrent en partie ACC-043, ACC-047, ACC-046, ACC-041, ACC-053, ACC-021, ACC-015, ACC-019, OPE-012, qui restent `a-faire` jusqu'à la parité complète (en particulier la lecture réelle de l'annuaire et de la base locale, absente hors simulation).

<a id="acc"></a>

## Accueil (ACC)

64 fonctions : 46 faites, 8 améliorées, 10 partielles.

### Actualiser l'OU

#### ACC-001 · Actualiser le périmètre depuis l'accueil (Objets AD, Ping, WMI, Tout)

`ameliore` · lecture réseau

Boutons qui relisent l'annuaire de l'OU (puis enregistrent la copie locale), mesurent la présence par ping, relisent console, inventaire léger et sondes des widgets sur les comptes actifs, ou enchaînent le tout ; bouton Arrêter et ligne de progression.

- Garde-fous : Sauvegarde vérifiée de la base avant toute lecture AD, puis revérification (OU, base, session attendues) ; plan des sondes figé au clic ; refus pendant maintenance ou disque presque plein ; Arrêter garde les données déjà enregistrées ; aucun objet AD modifié. OU explicite à l'intérieur du domaine (jamais la racine) ; refus en démonstration, si une actualisation, un relevé, une lecture AD ou une maintenance est en cours, si des écritures locales attendent ou si le disque est presque plein.
- Opérations : `IndexBuild`, `StorageBackup`, `ParkPing`, `ParkSweep`, `LiveConsole`, `LocalIndexRead`
- Références D1 : `BtnFleetIndexScope`, `BtnFleetRefreshPostes`, `BtnFleetRefreshBoth`, `BtnFleetRefreshAll`, `BtnFleetRefreshStop`, `LblFleetOuRefreshStatus`, `Domenia-Refresh.UI.ps1:Invoke-DomeniaOuRefresh`, `Domenia-Refresh.UI.ps1:Get-DomeniaOuRefreshContext`, `Domenia-Refresh.UI.ps1:Update-DomeniaOuRefreshUi`, `Domenia-Refresh.UI.ps1:Invoke-DomeniaOuRefreshTick`, `Domenia-Refresh.UI.ps1:Complete-DomeniaOuRefreshTargets`, `BtnSearchRefreshBase`, `BtnSearchRefreshPostes`, `BtnSearchRefreshBoth`, `BtnIndexScopeUpdate`, `UxOuRefreshExpander`, `LblSearchOuRefreshStatus`, `LblIndexOuRefreshStatus`, `Domenia-Main.xaml:BtnFleetRefreshAll`, `Domenia-Main.xaml:UxOuRefreshExpander`, `XAML:UxSearchOuRefreshTitle`, `XAML:LblSearchOuRefreshScope`

#### ACC-002 · Relever ce périmètre (lien sous section vide)

`fait` · lecture réseau

Lien proposé sous les sections Répartition et Relevés des postes quand elles sont vides : prépare la collecte ping puis inventaire léger des postes actifs de l'OU choisie.

- Garde-fous : OU explicite obligatoire (jamais la racine du domaine) ; instantané local courant, même OU, même profondeur, même session ; au moins un poste actif ; confirmation du relevé ; ping avant WMI.
- Opérations : `ParkPing`, `ParkSweep`
- Références D1 : `Domenia-BoardFleet.Model.ps1:Get-DomeniaFleetBoardData (HintActions CollectFleet)`, `Domenia-Widgets.UI.ps1:Invoke-DomeniaBoardEntryAction`, `Domenia-Widgets.UI.ps1:Get-DomeniaFleetCollectionContext`

#### ACC-003 · Sauvegarde vérifiée avant relecture AD

> Reste à faire : Sauvegarde vérifiée réelle de la base locale avant la relecture AD, avec Domenia.Store (vague 3). D’ici là, le mode annuaire refuse toute relecture AD (refresh.backupUnavailable : aucune lecture AD sans sauvegarde) ; en simulation, le plan et l’étape disent « sans objet » (état na), jamais « sauvegardée ».

`partiel` · écriture

Une relecture AD de l'OU (qui réécrit l'OU dans la base) est précédée d'une sauvegarde vérifiée ; l'actualisation repart de son reçu et revérifie OU, base et session confirmées au clic.

- Garde-fous : OU changée pendant la sauvegarde = jamais lue sans son propre clic ; plan de sondes figé au clic conservé.
- Opérations : `StorageBackup`, `IndexBuild`
- Références D1 : `Domenia-Refresh.UI.ps1:Invoke-DomeniaOuRefresh`, `Invoke-DomeniaGestureBackup`

#### ACC-004 · Ping puis WMI des seuls postes en ligne

`fait` · lecture réseau

« Tout actualiser » et WMI pingent d'abord chaque poste une fois puis lisent WMI uniquement sur ceux qui ont répondu, sans nouvel écho ni seconde confirmation.

- Garde-fous : Une confirmation unique annonce l'enchaînement ; ping arrêté ou stockage suspendu → pas de WMI.
- Opérations : `ParkPing`, `LiveConsole`
- Références D1 : `Domenia-Refresh.UI.ps1:Complete-DomeniaOuRefreshTargets`, `Domenia-Refresh.UI.ps1:Update-DomeniaOuRefreshFromPark`

#### ACC-005 · Repli quand la lecture AD échoue

`fait` · lecture réseau

Si la lecture AD de « Tout actualiser » échoue ou est partielle, ping et WMI partent sur les postes déjà connus de la base locale ; l'échec AD reste enregistré et affiché.

- Garde-fous : Le dernier repère AD complet est conservé.
- Opérations : `ParkPing`, `LiveConsole`
- Références D1 : `Domenia-Refresh.UI.ps1:Fail-DomeniaOuRefresh`

#### ACC-006 · Reçu d'enregistrement avant collecte

> Reste à faire : Reçu IndexBulk réel de Domenia.Store (OU, base, session, complétude) avant la collecte (vague 3) ; l’étape « Reçu d’enregistrement local », l’attente et l’échec d’une lecture partielle sont en place, servis par l’annuaire fictif en simulation.

`partiel` · lecture locale

La fin de la lecture AD n'est pas un reçu : la collecte des postes attend le reçu IndexBulk de la base (OU, base, session, complétude) avant de lire les postes actifs depuis la base locale.

- Garde-fous : Lecture partielle = échec ; aucun poste interrogé tant que l'enregistrement n'est pas validé.
- Opérations : `IndexBuild`, `LocalIndexRead`
- Références D1 : `Domenia-Refresh.UI.ps1:Complete-DomeniaOuRefreshCommit`, `Domenia-Refresh.UI.ps1:Set-DomeniaOuRefreshAwaitingCommit`

#### ACC-007 · Plan des sondes figé au clic

> Reste à faire : Sondes des widgets du tableau Poste (écran Poste, autre lot) et de leurs requêtes enregistrées (atelier, autre lot) à ajouter au plan figé quand ces écrans exposeront leur disposition ; les sondes des widgets actifs du tableau du parc sont figées au clic et un widget de requête refuse le relevé WMI (refresh.queryMissing).

`partiel` · lecture locale

Les sondes lues par l'actualisation WMI sont celles des widgets actifs des tableaux Parc et Poste et de leurs requêtes enregistrées, figées au moment du clic.

- Garde-fous : Widgets en pause exclus ; requête absente ou ambiguë → refus explicite plutôt qu'omission silencieuse.
- Références D1 : `Domenia-Refresh.UI.ps1:Get-DomeniaOuRefreshProbePlan`

#### ACC-008 · Arrêter l'actualisation de l'OU

`fait` · locale (aucune lecture)

Arrête la lecture AD, la préparation et le relevé en cours ; un changement d'OU, de base ou de session arrête aussi l'actualisation.

- Garde-fous : Les écritures locales engagées se terminent ; aucune nouvelle collecte.
- Références D1 : `Domenia-Refresh.UI.ps1:Stop-DomeniaOuRefresh`, `Domenia-Refresh.UI.ps1:Test-DomeniaOuRefreshCurrent`, `BtnFleetRefreshStop`, `BtnSearchRefreshStop`

### Analyse du parc

#### ACC-009 · Analyser la vue : comparer deux relevés

`fait` · lecture locale

Compare deux relevés quotidiens (ou la vue actuelle) et sépare les causes d'une variation : périmètre (empreinte des GUID), couverture (postes et familles évalués), règles (seuils, contrôles, suspensions actives) et état observé ; verdict Stable, Réel, Périmètre, Couverture, Règles, Mixte ou Limitée, tableau des compteurs avec variation.

- Garde-fous : Empreintes SHA-256 ; formats différents jamais comparés par empreinte ; relevés remis dans l'ordre chronologique ; aucune cause déduite d'un compteur seul ; aucun relevé réseau. seul un état observé sur la même base est un changement réel.
- Références D1 : `Domenia-Boards.Model.ps1:Compare-DomeniaHealthSnapshots`, `Domenia-Boards.Model.ps1:Set-DomeniaHealthSnapshotMetadata`, `Domenia-Boards.Model.ps1:Get-DomeniaHealthFingerprint`, `Domenia-HealthRules.UI.ps1:Show-DomeniaFleetAnalysis`, `Compare-DomeniaHealthSnapshots`

#### ACC-010 · Analyser la vue : tableaux croisés

`ameliore` · lecture locale

Tableaux OU × version de Windows, modèle × RAM, OU/site × couverture ping et inventaire WMI, modèle × version de BIOS, en matrice avec totaux ou en liste des cellules ; filtre texte ; chaque cellule ou total ouvre ses postes exacts dans l'atelier.

- Garde-fous : Chaque poste dans une seule cellule (totaux cohérents) ; catégories non lues explicites (« BIOS non relevé ») ; colonnes au-delà de 24 repliées, jamais supprimées. Catégories non renseignées incluses ; vue recalculée → refus.
- Références D1 : `Domenia-Boards.Model.ps1:Get-DomeniaFleetPivots`, `Domenia-Boards.Model.ps1:ConvertTo-DomeniaPivotMatrix`, `Domenia-HealthRules.UI.ps1:Show-DomeniaFleetAnalysis`

### Périmètre

#### ACC-011 · Choisir l'OU du tableau de bord (périmètre propre)

`ameliore` · lecture locale

Sélecteur d'OU partagé (arbre, recherche, favoris, profondeur avec ou sans sous-OU) qui fixe le périmètre de l'accueil et de l'atelier, indépendamment de Rechercher et de ses filtres ; recalcul depuis la base locale sans collecte.

- Garde-fous : OU refusée si hors du domaine courant ; domaine entier = clé « \* », toujours lu avec sous-OU ; aucune lecture d'annuaire ni ping.
- Références D1 : `Domenia-Dashboard.UI.ps1:Show-DomeniaFleetScopeSource`, `Domenia-Dashboard.UI.ps1:Get-DomeniaFleetScope`, `BtnFleetScope`

#### ACC-012 · Mémoriser l'OU du tableau de bord par domaine

`fait` · écriture

Enregistre l'OU, la profondeur et le choix explicite « tout le domaine » dans une préférence propre au domaine (Fleet.Scope.&lt;SHA-256 du DN de base>) et la restaure une fois par connexion.

- Garde-fous : OU restaurée seulement si elle appartient au domaine connecté ; lecture du périmètre ne réécrit jamais la profondeur choisie.
- Références D1 : `Domenia-Dashboard.UI.ps1:Save-DomeniaFleetScopeChoice`, `Domenia-Dashboard.UI.ps1:Restore-DomeniaFleetScopeChoice`, `Domenia-Dashboard.UI.ps1:Get-DomeniaFleetScopeSettingKey`

#### ACC-013 · Fil d'Ariane de l'OU affichée

`fait` · locale (aucune lecture)

Affiche le chemin d'OU du domaine vers l'OU courante (« Postes › Lyon ») ; chaque segment est un lien qui choisit cette OU comme périmètre, en gardant la profondeur.

- Garde-fous : Virgules échappées respectées ; reste dans le périmètre autonome du tableau.
- Références D1 : `Domenia-Dashboard.UI.ps1:Update-DomeniaFleetScopeText`, `Domenia-Dashboard.UI.ps1:Select-DomeniaFleetScopeOu`, `PnlFleetCrumbs`

#### ACC-014 · Revenir à l'OU racine sur le tableau de bord

`fait` · écriture

Remet le périmètre du tableau de bord sur l'OU racine enregistrée (ou le domaine entier) et recalcule depuis la base locale.

- Garde-fous : Aucune collecte.
- Opérations : `LocalIndexRead`
- Références D1 : `Domenia-Dashboard.UI.ps1:Reset-DomeniaFleetScopeToRoot`

### Premiers pas et session

#### ACC-015 · Premiers pas de l'accueil

`ameliore` · écriture

Guide du premier usage : connexion à l'annuaire, choix de l'OU de travail, première lecture de cette OU dans la base locale, puis vue d'ensemble calculée localement. Chaque étape dit si elle est faite ou disponible et indique la suivante. Une lecture interrompue ou incomplète, ou le mode hors ligne, sont signalés. Le compte poste et les sauvegardes sont reportés au moment où ils servent.

- Garde-fous : Préférences Home.FirstStepsDone et Home.DashboardSeen ; dessiner la carte ne lance jamais de calcul ; lecture interrompue ou profondeur inconnue non comptée comme faite. La couverture de l'OU prouve la lecture, pas le nombre global d'objets. Les boutons ouvrent l'écran sans rien lancer.
- Références D1 : `Domenia-Dashboard.UI.ps1:Get-DomeniaFirstStepsState`, `Domenia-Dashboard.UI.ps1:Update-DomeniaFirstSteps`, `Domenia-Dashboard.UI.ps1:Open-DomeniaFirstStep`, `Domenia-FirstRun.Model.ps1:Get-DomeniaFirstRunPlan`, `CardFirstSteps`, `BtnFirstStepConnection`, `BtnFirstStepOu`, `BtnFirstStepBase`, `BtnFirstStepDashboard`, `LblFirstStepsDeferred`, `Domenia-Main.xaml:BtnFirstStepConnection`, `XAML:LblFirstStepConnectionMark`, `XAML:LblFirstStepConnection`, `XAML:LblFirstStepOuMark`, `XAML:LblFirstStepOu`, `XAML:LblFirstStepBaseMark`, `XAML:LblFirstStepBase`, `XAML:LblFirstStepDashboardMark`, `XAML:LblFirstStepDashboard`

#### ACC-016 · Première vue d'ensemble préparée automatiquement

`fait` · lecture locale

Après la première lecture de base, lance le premier calcul local de la vue d'ensemble et suit son état (en cours, prête avec N postes, erreur avec Réessayer) dans le bouton de la dernière étape.

- Garde-fous : Calcul local seul, collecte réseau toujours explicite ; lié à la session, à la base et à l'OU.
- Opérations : `LocalIndexRead`
- Références D1 : `Domenia-Dashboard.UI.ps1:Start-DomeniaFirstDashboard`, `Domenia-Dashboard.UI.ps1:Complete-DomeniaFirstDashboard`

#### ACC-017 · Pastille « Nouveau » sur l'aide au premier lancement

`fait` · locale (aucune lecture)

Au premier lancement, tant que l'aide est fermée, un point sur ? signale les explications (statut « Nouveau : aide disponible »). Il est marqué vu dans les préférences (UxHelpIntroSeen) et disparaît à la première ouverture de l'aide.

- Références D1 : `Domenia-Shell.Model.ps1:Get-DomeniaHelpBadgeState`, `Domenia-UX.UI.ps1:Initialize-DomeniaUxHelpBadge`, `Domenia-UX.UI.ps1:Set-DomeniaUxHelpBadge`, `Domenia-UX.UI.ps1:Hide-DomeniaUxHelpBadge`, `UxHelpBadge`

#### ACC-018 · Raccourcis « 1. Trouver, 2. Consulter, 3. Préparer »

`fait` · locale (aucune lecture)

Trois boutons d'étapes : ouvrir la recherche, ouvrir la fiche déjà chargée, ouvrir l'Atelier pour comparer ou préparer un dossier. Ils ne lancent aucun scan.

- Garde-fous : Navigation seulement.
- Références D1 : `BtnUxStep1`, `BtnUxStep2`, `BtnUxStep3`, `Domenia-UX.UI.ps1:Initialize-DomeniaUxShell`, `Domenia-Main.xaml:BtnUxStep1`

#### ACC-019 · Détails de la session

`fait` · locale (aucune lecture)

Repli « Détails de la session et outils de vérification » : domaine, serveur/DC, compte d'exécution AD, mode, base DN, branche, résultats affichés, module AD, droits, tâches, cache, self-check, liens user-machine, statistiques de la liste, objet sélectionné ; Copier, Vérifier l'application, Vider le cache, Ouvrir le journal.

- Garde-fous : Reconstruit seulement quand le repli est ouvert.
- Références D1 : `Domenia-Core.ps1:Update-Dashboard`, `Domenia-Core.ps1:Copy-DashboardSummary`, `Domenia-Main.xaml:UxSessionDetails`, `Domenia-Main.xaml:BtnDashCopy`, `Domenia-Main.xaml:BtnDashSelfCheck`, `Domenia-Main.xaml:BtnDashClearCache`, `Domenia-Main.xaml:BtnDashOpenLog`, `XAML:TxtDashDomain`, `XAML:TxtDashServer`, `XAML:TxtDashUser`, `XAML:TxtDashMode`, `XAML:TxtDashBaseDn`, `XAML:TxtDashBranch`, `XAML:TxtDashRows`, `XAML:TxtDashModule`, `XAML:TxtDashRights`, `XAML:TxtDashTasks`, `XAML:TxtDashCache`, `XAML:TxtDashSelfCheck`, `XAML:TxtDashLinks`, `XAML:TxtDashStats`, `XAML:TxtDashSelected`

### Provenance et horloges

#### ACC-020 · Libellé périmètre et fraîcheur AD

`fait` · lecture locale

Nomme l'OU (et sous-OU ou non), le nombre de postes recensés et la date de la dernière lecture AD complète couvrant cette branche ; signale tentative partielle, profondeur historique inconnue ou date future (horloge à vérifier). Info-bulle : DN, source de la lecture, rappel que le nombre inclut les désactivés.

- Garde-fous : Seule une couverture complète validée date la base ; une lecture partielle ne remplace jamais la date ; anciens marqueurs sans profondeur ne prouvent rien.
- Références D1 : `Domenia-Dashboard.UI.ps1:Update-DomeniaFleetScopeText`, `Domenia-BoardFleet.Model.ps1:Get-DomeniaFleetFreshness`, `Domenia-BoardFleet.Model.ps1:Format-DomeniaOuFreshnessSummary`, `LblFleetScope`

#### ACC-021 · Trois horloges de provenance des mesures

`fait` · lecture locale

Sous le tableau : mesures des postes actifs (ping N/M et inventaire WMI N/M avec intervalle du… au…, raisons des postes sans mesure, mesures conservées après échec), horloges des collectes d'OU (dernier succès et échec plus récent), puis date du calcul local qui ne date jamais les données ; l'info-bulle ajoute la provenance des relevés.

- Garde-fous : Aucune date de calcul substituée à une date de mesure ; date future jamais utilisable ; aide catalogue conservée comme base de l'info-bulle.
- Références D1 : `Domenia-Dashboard.UI.ps1:Complete-DomeniaFleetDashboard`, `Domenia-Dashboard.UI.ps1:Set-DomeniaFleetDashboardToolTip`, `Domenia-BoardFleet.Model.ps1:Get-DomeniaOuObservationFreshness`, `Domenia-BoardFleet.Model.ps1:Format-DomeniaOuFreshnessSummary`, `LblFleetDashboard`

#### ACC-022 · Enregistrement des horloges de collecte

`fait` · écriture

Pour chaque OU et chaque famille (annuaire, ping, WMI) : dernière tentative, dernière réussite et erreur. Elles sont admises par le stockage (statut Success, Partial, Error ou Cancelled, fin postérieure au début) et listées dans Outils > Relevés, 300 lignes au plus, la plus récente en premier.

- Garde-fous : Refus ou annulation avant toute action réseau = rien d'enregistré ; jamais dans une autre base ou session ; refus d'admission jamais rejoué. Un succès ne porte jamais d'erreur ; périmètre recalculé, il ne peut pas dater un autre périmètre ; description de 16 Ko au plus.
- Opérations : `LocalStore`, `LocalIndexRead`
- Références D1 : `Domenia-Refresh.UI.ps1:Submit-DomeniaOuRefreshRuns`, `Domenia-Refresh.UI.ps1:Complete-DomeniaOuRefreshRunsStored`, `Domenia-Collection.Model.ps1:New-DomeniaCollectionRunChange`, `Domenia-Collection.Model.ps1:New-DomeniaRefreshRunChanges`, `Domenia-Store.Model.ps1:ConvertTo-DomeniaStoreCollectionRun`, `Domenia-Engine.Worker.ps1:Get-DomeniaLocalIndexReadWorkerCode (CollectionRuns)`, `Domenia-Storage.Worker.ps1:Read-StoreWCollectionRuns`

#### ACC-023 · Horloges AD, ping et WMI d'une vue

`fait` · lecture locale

Pour l'OU affichée : dernière réussite et dernière tentative de chaque famille, héritées d'une OU englobante en sous-arbre, avec provenance en infobulle.

- Garde-fous : Un échec ne masque ni ne vieillit une réussite ; dates incohérentes signalées, jamais corrigées ; un relevé enfants directs ne date pas les descendants.
- Opérations : `LocalIndexRead`
- Références D1 : `Domenia-Collection.Model.ps1:Get-DomeniaCollectionClock`, `Domenia-Collection.Model.ps1:Get-DomeniaCollectionClocks`, `Domenia-Collection.Model.ps1:Format-DomeniaCollectionClock`, `Domenia-Collection.Model.ps1:Format-DomeniaCollectionClocks`, `Domenia-Collection.Model.ps1:Test-DomeniaCollectionClock`, `Domenia-Collection.Model.ps1:Get-DomeniaCollectionRunKeys`, `Domenia-Collection.Model.ps1:Format-DomeniaCollectionCounts`

### Santé du parc

#### ACC-024 · Éditeur des règles de santé

`fait` · écriture

Onglets Contrôles (25 règles : fin de service, connexion ancienne, LAPS, BitLocker, Secure Boot, certificats, disque, redémarrage, mémoire, batterie, pare-feu, services, pilotes, correctifs, événements…), Seuils (7 seuils bornés), Mes alertes, Suspensions, Exceptions par OU ; Appliquer ou Annuler.

- Garde-fous : Préférence locale par domaine (clé SHA-256), aucune collecte ; validation stricte (disque critique ≤ surveillance) ; reprise unique de l'ancien réglage global.
- Références D1 : `Domenia-HealthRules.UI.ps1:Show-DomeniaHealthRulesEditor`, `Domenia-HealthRules.UI.ps1:Save-DomeniaHealthPolicy`, `Domenia-HealthRules.UI.ps1:Get-DomeniaStoredHealthPolicyBook`, `Domenia-HealthRules.Model.ps1:Get-DomeniaHealthRuleCatalog`, `Domenia-HealthRules.Model.ps1:Get-DomeniaHealthThresholdCatalog`, `Domenia-HealthRules.Model.ps1:ConvertTo-DomeniaHealthPolicy`

#### ACC-025 · Portée et héritage des règles par OU

`fait` · écriture

Règles par défaut du domaine, OU ancêtres et OU courante ; seule la différence avec le parent est stockée, chaque réglage montre son origine ; « Revenir aux règles héritées ».

- Garde-fous : Seuils et états hérités un par un ; alertes et suspensions héritées en listes entières.
- Références D1 : `Domenia-HealthRules.Model.ps1:Resolve-DomeniaHealthPolicy`, `Domenia-HealthRules.Model.ps1:Set-DomeniaHealthScopePolicy`, `Domenia-HealthRules.Model.ps1:ConvertTo-DomeniaHealthPolicyBook`, `Domenia-HealthRules.Model.ps1:Get-DomeniaHealthPolicyOrigins`, `Domenia-HealthRules.Model.ps1:Get-DomeniaHealthEditorScopes`, `Domenia-HealthRules.Model.ps1:Format-DomeniaHealthScopeLabel`, `Domenia-HealthRules.Model.ps1:Test-DomeniaHealthScope`

#### ACC-026 · Exceptions par OU

`fait` · lecture locale

Liste toutes les exceptions locales du domaine avec leurs différences lisibles ; « Modifier cette exception » ouvre l'OU comme portée.

- Garde-fous : OU disparue signalée.
- Références D1 : `Domenia-HealthRules.Model.ps1:Get-DomeniaHealthPolicyExceptions`

#### ACC-027 · Alertes personnalisées

> Reste à faire : Alertes sur une requête enregistrée figée à sa révision, quand l’atelier de requêtes sera porté ; les 32 alertes sur mesures du poste (disque, démarrage, mémoire) sont en place.

`partiel` · écriture

Jusqu'à 32 alertes sur une mesure du poste (espace disque, jours depuis démarrage, mémoire utilisée ; inférieur ou supérieur à un seuil ; à surveiller ou critique) ou sur une requête enregistrée figée à sa révision.

- Garde-fous : Révision figée par SHA-256, requête archivée refusée ; mêmes trois états (correspond, ne correspond pas, inconnu) que la recherche ; aucune collecte lancée.
- Références D1 : `Domenia-HealthRules.Model.ps1:ConvertTo-DomeniaHealthPolicy`, `Domenia-HealthRules.Model.ps1:New-DomeniaHealthQueryRule`, `Domenia-HealthRules.Model.ps1:Get-DomeniaHealthQueryStates`, `Domenia-HealthRules.Model.ps1:Add-DomeniaCustomHealthAttention`

#### ACC-028 · Suspensions temporaires avec motif

`fait` · écriture

Suspendre un contrôle 1 h, 24 h, 7 j ou 30 j avec motif obligatoire (3 à 240 caractères) ; « Réactiver maintenant » termine la suspension et garde la trace 30 jours.

- Garde-fous : Hors score mais postes toujours affichés comme masqués ; 64 entrées max ; reprise automatique à l'échéance ; une règle désactivée et suspendue reste désactivée.
- Références D1 : `Domenia-HealthRules.Model.ps1:ConvertTo-DomeniaHealthSuspensions`, `Domenia-HealthRules.Model.ps1:Get-DomeniaHealthSuspension`, `Domenia-HealthRules.Model.ps1:Optimize-DomeniaHealthSuspensions`, `Domenia-HealthRules.Model.ps1:ConvertTo-DomeniaEndedHealthSuspension`, `Domenia-HealthRules.Model.ps1:New-DomeniaHealthEditorPolicy`, `Domenia-HealthRules.Model.ps1:Format-DomeniaHealthSuspensionText`, `Domenia-HealthRules.Model.ps1:Get-DomeniaHealthRuleState`

#### ACC-029 · Score de santé par OU

`fait` · locale (aucune lecture)

Évalue chaque poste avec la politique héritée de son OU : score parc = postes évalués sans point ÷ postes évalués ; score poste = 100 − 25 par critique − 10 par point à surveiller.

- Garde-fous : Postes incomplets retirés du dénominateur ; règles désactivées ou suspendues évaluées seulement pour la liste masquée ; disque critique compté une fois (lowdisk avant disk.tight).
- Opérations : `LocalQuery`
- Références D1 : `Domenia-HealthRules.Model.ps1:Update-DomeniaFleetScopedHealth`, `Domenia-HealthRules.Model.ps1:Update-DomeniaFleetHealthPopulation`, `Domenia-HealthRules.Model.ps1:Test-DomeniaHealthRuleEnabled`

#### ACC-030 · Comprendre le score

`fait` · lecture locale

Par contrôle : état de la règle, constat, postes évaluables, postes signalés (uniques), effet sur le score, ce qu'une règle masquée aurait signalé ; onglet des règles appliquées par OU ; boutons Afficher les postes signalés/masqués et Voir la collecte manquante.

- Garde-fous : « Voir la collecte manquante » ne lance aucune collecte ; vue recalculée pendant la consultation → refus de l'action.
- Références D1 : `Domenia-HealthRules.UI.ps1:Show-DomeniaHealthExplanation`, `Domenia-HealthRules.Model.ps1:Get-DomeniaHealthExplanation`, `Domenia-HealthRules.Model.ps1:Get-DomeniaFleetRuleEligibility`, `Domenia-HealthRules.Model.ps1:Get-DomeniaComputerRuleEvidence`, `Domenia-HealthRules.Model.ps1:Get-DomeniaHealthRuleEvidenceDetail`

### Vue d'ensemble · actions

#### ACC-031 · Ouvrir les postes de l'OU dans Rechercher

> Reste à faire : Rechercher (autre lot) doit reprendre la liste exacte transmise (révision et clé de l’ensemble) ; le bouton direct de Domenia 1 « Ouvrir les postes dans Rechercher » est dans la barre du tableau du parc (barre de commandes du kit), et les trois liens vers Rechercher passent ses paramètres à lui (ou, sousou, type = computers) : jamais le domaine entier.

`partiel` · lecture locale

Transfère tous les postes recensés de l'OU de l'accueil (désactivés compris) comme liste de Rechercher depuis la base locale, sans requête ; Pinger, Détecter ou Analyser la liste se lancent ensuite à la main.

- Garde-fous : Refusé pendant un recalcul, sur données périmées ou d'une autre session ; jamais pour le domaine entier ; réinitialise filtres texte/présence/requête cachés ; libellé nomme la révision locale (population).
- Références D1 : `Domenia-Dashboard.UI.ps1:Show-DomeniaFleetAnalyzeSource`, `Domenia-Dashboard.UI.ps1:Show-DomeniaFleetTargetsInSearch`, `BtnFleetOpenSearch`

### Vue d'ensemble · calcul

#### ACC-032 · Recalculer la vue d'ensemble depuis la base locale

`ameliore` · lecture locale

Les agrégats de l'accueil sont calculés dans le worker depuis l'index local : OU filtrée en SQL, faits des postes et présence BitLocker joints par GUID et par nom, postes regroupés selon le plan reçu. Seules les observations des postes actifs de l'OU sont analysées. Une métadonnée BitLocker écrite avant la création du poste reste inconnue.

- Garde-fous : ReplaceKey fleet:stats, délai 120 s, classe Background pour l'automatique (ne prend pas le bouton Annuler global) ; résultat ignoré si autre session, autre base ou autre OU ; base occupée = message, pas de chiffres faux ; refus de budget (Concurrence maximale, Budget du site, Reprise progressive) = « Recalcul différé », derniers chiffres gardés ; échec = libellé « chiffres peuvent dater de la lecture précédente » ; fonction absente détectée et journalisée comme défaut de chargement. Aucune date inventée ; dates et population viennent du même instantané.
- Opérations : `LocalIndexRead`
- Références D1 : `Domenia-Dashboard.UI.ps1:Start-DomeniaFleetDashboard`, `Domenia-Dashboard.UI.ps1:Complete-DomeniaFleetDashboard`, `Domenia-Dashboard.UI.ps1:Fail-DomeniaFleetDashboard`, `Domenia-BoardFleet.Model.ps1:Get-DomeniaFleetBoardData`, `BtnFleetDashboardRefresh`, `PnlFleetDashboard`, `LblFleetDashboard`, `Domenia-Engine.Worker.ps1:Get-DomeniaLocalIndexReadWorkerCode (FleetStats)`, `Domenia-Main.xaml:BtnFleetDashboardRefresh`

#### ACC-033 · Recalcul automatique quand les données changent

`fait` · locale (aucune lecture)

Marque la vue périmée (analyse terminée, base enregistrée, nouvelle session, OU changée) et la recalcule seulement si l'accueil (ou l'atelier) est affiché ; sinon au prochain affichage. Un calcul terminé pendant qu'une écriture est survenue est relancé au lieu d'afficher des chiffres obsolètes.

- Garde-fous : Jamais deux calculs pour la même OU (FleetPendingKey/FleetJobId) ; -Force vide l'état de l'atelier de requêtes ; pas d'attente de l'OU de Rechercher (décision 2026-10-19).
- Opérations : `LocalIndexRead`
- Références D1 : `Domenia-Dashboard.UI.ps1:Request-DomeniaFleetRefresh`, `Domenia-Dashboard.UI.ps1:Test-DomeniaFleetDashboardShown`, `Domenia-Dashboard.UI.ps1:Test-DomeniaFleetAwaitingScope`

#### ACC-034 · Plan de requête du parc (bornes des règles)

`fait` · locale (aucune lecture)

Fournit au worker les bornes de regroupement SQL : tranches lastLogonTimestamp (7/30/90/180 j), créés depuis 30 j, mot de passe au-delà du seuil de la politique, âge maximal des observations, historique sur 400 j. Le worker ne fait que grouper ; aucune règle n'est copiée dans son corps épinglé.

- Garde-fous : Âge des observations borné 1 à 3650 j ; dates UTC ISO comparées en texte.
- Opérations : `LocalIndexRead`
- Références D1 : `Domenia-BoardFleet.Model.ps1:Get-DomeniaFleetQueryPlan`

#### ACC-035 · Dernière vue enregistrée au démarrage (cache d'abord)

`ameliore` · écriture

Au démarrage, avant tout calcul, affiche le résumé daté de la dernière vue calculée pour la même base et la même OU (postes actifs, à traiter, ligne de mesures), présenté comme non recalculé avec invitation à « Recalculer la vue ».

- Garde-fous : Préférence Fleet.LastView.&lt;hex> ; liée au StoreId (chemin + domaine) et à la clé d'OU ; aucun nom de poste ni secret ; format versionné ; date future ou non UTC refusée ; textes bornés (2000/256 caractères).
- Références D1 : `Domenia-BoardFleet.Model.ps1:ConvertTo-DomeniaFleetLastView`, `Domenia-BoardFleet.Model.ps1:Get-DomeniaFleetLastViewNotice`, `Domenia-Dashboard.UI.ps1:Save-DomeniaFleetLastView`, `Domenia-Dashboard.UI.ps1:Show-DomeniaFleetOverviewIdle`, `Domenia-Dashboard.UI.ps1:Get-DomeniaFleetLastViewStoreId`

#### ACC-036 · Population de référence et ensembles exacts par chiffre

`fait` · locale (aucune lecture)

Chaque calcul conserve la population (domaine, OU, profondeur, révision de la base, StoreId) et, pour chaque tuile et chaque part de graphique, la liste exacte des postes (GUID) qu'ils comptent, utilisée par les clics, exports et « Afficher les postes ».

- Garde-fous : Lignes du worker gardées sans copie (milliers de postes) ; même instantané pour tous les chiffres.
- Références D1 : `Domenia-BoardFleet.Model.ps1:Get-DomeniaFleetBoardData (Last.WidgetTargets, Population)`

#### ACC-037 · Vue recalculée pendant un relevé

`fait` · lecture locale

Pendant un relevé, la vue d'ensemble et ses widgets sont recalculés depuis les mesures déjà enregistrées toutes les 15 s au plus.

- Garde-fous : Un calcul à la fois.
- Opérations : `LocalIndexRead`
- Références D1 : `Domenia-Park.UI.ps1:Invoke-DomeniaParkLiveUpdates`, `Request-DomeniaFleetRefresh`

### Widgets · collecte

#### ACC-038 · Collecter seulement ce qui manque

`fait` · lecture locale

Avant tout réseau, vérifie par tranches les mesures enregistrées de chaque poste et ne contacte que ceux dont une mesure manque, est en erreur ou plus vieille que l'âge de réutilisation (« déjà à jour, non contactés »).

- Garde-fous : Même identité (GUID et DN) et même définition de sonde ; actualisation forcée relit tout ; sonde non applicable datée par sa tentative.
- Opérations : `LocalIndexRead`
- Références D1 : `Domenia-Park.Model.ps1:New-DomeniaCollectionPlan`, `Domenia-Park.Model.ps1:Test-DomeniaParkTargetAnswered`, `Domenia-Park.Model.ps1:Get-DomeniaProbeAnswerUtc`, `Domenia-Park.Model.ps1:Test-DomeniaProbeNotApplicable`, `Domenia-Park.UI.ps1:Invoke-DomeniaParkPlanStep`

### Widgets · détail

#### ACC-039 · Ouvrir un chiffre dans l'atelier

> Reste à faire : Ouvrir un chiffre dans l’atelier avec sa recette quand l’atelier de requêtes sera porté ; chaque chiffre ouvre déjà sa liste exacte de postes (grille, filtres, CSV, fiche, Rechercher), et sur board.replaced le tableau est redessiné de lui-même, le message restant affiché (point 73 de Domenia 1).

`partiel` · lecture locale

Un clic sur un widget ou une de ses parts ouvre l'atelier avec la recette équivalente (inactifs, LAPS, BitLocker, cycle, disque, RAM, OS, OU, modèles…) ou la liste exacte de GUID calculée, puis lance l'aperçu.

- Garde-fous : Chiffre issu d'un calcul remplacé : refus, tableau redessiné, message (point 73). Regroupement sans tous ses détails refusé ; les tendances quotidiennes n'ont pas d'identités conservées (message). Refusé si un calcul plus récent remplace celui du chiffre.
- Opérations : `LocalQuery`
- Références D1 : `Domenia-Widgets.UI.ps1:Invoke-DomeniaBoardAction (Details)`, `Domenia-Query.UI.ps1:Show-DomeniaFleetWidgetDetails`, `Domenia-WidgetCollect.Model.ps1:Test-DomeniaWidgetSnapshotCurrent`, `Format-DomeniaWidgetDetailLabel`, `Domenia-WidgetCollect.Model.ps1:Format-DomeniaWidgetDetailLabel`

### Widgets · évolution

#### ACC-040 · Instantané quotidien local du parc

`ameliore` · écriture

Au premier calcul du jour pour une OU, enregistre localement les chiffres (postes, sains, à traiter, inactifs et seuil utilisé, fin de service, désactivés, Windows 10, disques presque pleins) qui alimentent courbes et comparaisons.

- Garde-fous : Une seule mise en file par OU et par jour ; LowDisk seulement si une taille de disque a été lue (jamais 0 inventé) ; aucun réseau. Pas de réseau ; seules les valeurs de comptage sont gardées ; purgé avec l'historique.
- Opérations : `LocalStore`
- Références D1 : `Domenia-Dashboard.UI.ps1:Save-DomeniaFleetSnapshot`, `Domenia-BoardFleet.Model.ps1:Get-DomeniaFleetBoardData`, `Domenia-Storage.UI.ps1:Queue-DomeniaMetadata (FleetSnapshot)`, `Domenia-Storage.Worker.ps1:Get-DomeniaStorageWorkerCode`

#### ACC-041 · Évolution sur 90 jours

`fait` · lecture locale

Courbes quotidiennes des postes à traiter, Windows 10, inactifs et disques presque pleins à partir des instantanés locaux de l'OU, à partir de deux jours relevés.

- Garde-fous : Jour manquant jamais remplacé par 0 ; jours futurs, doublons et valeurs négatives écartés ; mélange de seuils d'inactivité signalé.
- Références D1 : `Domenia-BoardFleet.Model.ps1:Get-DomeniaFleetBoardData`, `Domenia-BoardFleet.Model.ps1:Get-DomeniaStaleTrendNote`, `fleet.trend`, `fleet.trend.win10`, `fleet.trend.stale`, `fleet.trend.lowdisk`

### Widgets · inventaire du périmètre

#### ACC-042 · Inventaire des comptes ordinateur du périmètre

`fait` · lecture locale

Tuiles et anneau : tous les comptes (activés, désactivés, état inconnu), activés (sans déduction de présence), état AD inconnu, répartition des états, sans connexion AD au-delà du seuil (dates inconnues à part), désactivés encore dans l'OU, créés ces 30 j, mot de passe machine au-delà du seuil, serveurs/postes.

- Garde-fous : Attributs non lus = « Non lu » ou « À relire » (base remise à jour sans ces attributs), jamais 0 ; lastLogonTimestamp annoncé à 14 jours près ; seuils lus dans la politique de santé.
- Références D1 : `Domenia-BoardFleet.Model.ps1:Get-DomeniaFleetBoardData`, `fleet.machines`, `fleet.enabled`, `fleet.accountunknown`, `fleet.accountstatus`, `fleet.stale`, `fleet.disabled`, `fleet.created`, `fleet.pwdold`, `fleet.servers`

### Widgets · relevés des postes

#### ACC-043 · Présence réseau et dernier ping

`fait` · lecture locale

Anneau En ligne / Sans réponse / Non vérifié sur les comptes actifs, tuile Dernier ping et tuile Utilisateurs distincts vus en session console ; couverture « N analysés sur M ».

- Garde-fous : Seule la date propre du ping date la présence (un WMI récent ne rajeunit pas un vieux ping) ; ping expiré = Non vérifié ; grisé au-delà de 7 jours ; utilisateurs comptés sans casse.
- Références D1 : `Domenia-BoardFleet.Model.ps1:Get-DomeniaFleetBoardData`, `fleet.presence`, `fleet.lastcheck`, `fleet.users`

#### ACC-044 · Réponse WMI indépendante du ping

`fait` · lecture locale

Anneau WMI a répondu / non confirmé / non relevé à partir des familles CIM datées (console, inventaire, sondes), avec raisons des postes sans réponse utilisable (refusé, erreur, expiré, non lu, absent).

- Garde-fous : Échec dans les 15 min d'un succès = même collecte ; date future ou illisible = erreur (horloge), jamais réponse fraîche ; refus distingué de l'erreur ; jamais « éteint ».
- Références D1 : `Domenia-BoardFleet.Model.ps1:Get-DomeniaFleetWmiResponse`, `fleet.wmi`

#### ACC-045 · Ping et WMI comparés

`fait` · lecture locale

Barres par combinaison : ping et WMI répondent, WMI sans ping (ICMP probablement filtré), ping sans WMI confirmé, ni l'un ni l'autre, un seul canal relevé, aucun relevé.

- Garde-fous : Aucun canal ne décide seul de la joignabilité ; grisé si l'une des mesures a plus de 7 jours.
- Références D1 : `Domenia-BoardFleet.Model.ps1:Get-DomeniaFleetReachLabel`, `fleet.reach`

#### ACC-046 · Inventaire léger des postes (modèles, versions, mémoire, disque, redémarrage)

`fait` · lecture locale

Modèles, versions relevées par WMI, postes par mémoire (≤4, 5-8, 9-16, 17-32, >32 Go), par espace libre de C: selon les seuils, tuile C: presque plein (&lt;10 %) et tuile non redémarrés au-delà du seuil.

- Garde-fous : Taille de disque 0 ou libre incohérent ignorés (jamais « 0 disque plein ») ; date de démarrage future ignorée ; marge d'un demi-Go sur la mémoire ; grisé si relevé de plus de 7 jours.
- Références D1 : `Domenia-BoardFleet.Model.ps1:Get-DomeniaFleetBoardData`, `fleet.models`, `fleet.releases`, `fleet.ram`, `fleet.diskfree`, `fleet.lowdisk`, `fleet.uptime`

### Widgets · répartition

#### ACC-047 · Répartition des systèmes, connexions et OU

`fait` · lecture locale

Systèmes d'exploitation (6 premiers + Autres), ancienneté de la dernière connexion au domaine (6 tranches, vides comprises), postes par OU ou par sous-OU de l'OU choisie.

- Garde-fous : Tri stable (égalités par libellé) ; section vide = indication « mettez à jour la base autonome ».
- Références D1 : `Domenia-BoardFleet.Model.ps1:Get-DomeniaFleetBoardData`, `fleet.os`, `fleet.lastlogon`, `fleet.ou`

### Widgets · requêtes

#### ACC-048 · Sondes WMI et requêtes enregistrées sur l'accueil

> Reste à faire : Widgets issus de « Mes requêtes » quand l’atelier de requêtes sera porté ; les widgets de sondes WMI (catalogue, « À relever », couverture) sont en place.

`partiel` · lecture locale

Widgets issus du catalogue de sondes ou de « Mes requêtes » évalués localement en arrière-plan sur l'instantané de l'OU (« À calculer » en attendant), avec sous-titre de couverture.

- Garde-fous : Requête gardée sur contrôleur de domaine signalée « ignorée » ; requête inconnue = « Retirez ce widget » ; calcul lié à la clé d'instantané courante.
- Références D1 : `Domenia-Widgets.UI.ps1:Resolve-DomeniaBoardEntry`, `Domenia-Boards.Model.ps1:ConvertFrom-DomeniaProbeMeasure`, `Domenia-Boards.Model.ps1:Get-DomeniaProbeKind`, `Domenia-Boards.Model.ps1:Get-DomeniaProbeUnit`

#### ACC-049 · Widget de requête du tableau de bord général

> Reste à faire : Widget de requête enregistrée (10 premières valeurs, « Autres valeurs », « Valeur inconnue ») : dépend de la bibliothèque de requêtes de l’atelier, non portée ; la clé query:<id> est réservée et un widget de requête affiche « Requête absente ».

`partiel` · lecture locale

Affiche le compte ou la répartition d'une requête enregistrée sur l'OU (10 premières valeurs, « Autres valeurs » exact, « Valeur inconnue »), avec détail correspondants/inconnus/non correspondants et dates des sources.

- Garde-fous : États explicites : requête absente, à calculer, calcul à préciser ; avertissement si des inconnus existent.
- Opérations : `LocalQuery`
- Références D1 : `Domenia-Query.UI.ps1:Get-DomeniaQueryBoardEntry`, `Domenia-QueryTargets.UI.ps1:ConvertTo-DomeniaQueryCountEntry`, `Domenia-Query.Model.ps1:Measure-DomeniaQueryWidget`, `Domenia-Query.Model.ps1:ConvertTo-DomeniaQueryGroupItems`

#### ACC-050 · Révision évaluée affichée sur le widget

> Reste à faire : Révision évaluée et avertissements de lien sur le widget de requête : dépend de l’atelier de requêtes ; le refus d’un relevé WMI avec un widget de requête actif (refresh.queryMissing) est en place.

`partiel` · locale (aucune lecture)

Le widget dit quelle révision il évalue et avertit si son lien est en retard, si la requête est archivée, modifiée, absente de la bibliothèque ou si la bibliothèque n'est pas lue.

- Garde-fous : Ne fait jamais échouer un widget ; état d'avertissement.
- Références D1 : `Domenia-Query.Model.ps1:Format-DomeniaQueryWidgetRevision`, `Domenia-Query.UI.ps1:Get-DomeniaQueryWidgetRevision`

#### ACC-051 · Points d'attention vers une sélection figée

> Reste à faire : Ouvrir la sélection figée des GUID dans l’atelier, nommée avec le compte et la date, quand l’atelier sera porté ; « Points d’attention », « Sans problème » et « Non évalués » ouvrent déjà leurs postes exacts.

`partiel` · lecture locale

« Postes concernés par les points d'attention » et « Sans point détecté » ouvrent l'atelier sur la sélection figée des GUID concernés, nommée avec le compte et la date.

- Garde-fous : Sélection validée (GUID) avant l'aperçu.
- Opérations : `LocalQuery`
- Références D1 : `Domenia-Query.UI.ps1:Show-DomeniaAttentionInWorkshop`, `Get-DomeniaAttentionTargets`

### Widgets · santé

#### ACC-052 · Santé du parc (score et points)

`fait` · lecture locale

Carte Santé : part des postes évalués sans point critique ni à surveiller (Bon état ≥90 %, À surveiller ≥75 %, Dégradé sinon, Critique dès un point critique) à côté de la liste des points ; postes non évalués comptés à part, couverture affichée.

- Garde-fous : Score retenu sous 50 % de couverture (« Couverture insuffisante ») ; « Évaluation partielle » si incomplets ou badge ; jamais de score rassurant sur périmètre vide ; arrondi inférieur (49,9 % ≠ 50 %).
- Références D1 : `Domenia-Boards.Model.ps1:Get-DomeniaFleetHealth`, `Domenia-Boards.Model.ps1:Get-DomeniaHealthCoverage`, `Domenia-Boards.Model.ps1:Complete-DomeniaBoardData`, `fleet.health`

#### ACC-053 · Points d'attention du parc

`fait` · lecture locale

Liste triée du plus grave au moins grave : fin de service dépassée/proche, inactifs au-delà du seuil, jamais connectés, base incomplète, mot de passe machine ancien, LAPS absent ou expiré, BitLocker absent, disques C: critiques ou serrés, non redémarrés, créés récemment, désactivés encore dans l'OU, sans réponse ping, WMI non confirmé, relevés ignorés ; informations comptées à part (« 4 points à vérifier · 1 information »).

- Garde-fous : Règles désactivées ou suspendues jamais comptées mais gardées pour l'explication ; absence de ping ou WMI jamais présentée comme poste éteint ; LAPS/BitLocker comptés seulement si au moins une valeur est visible avec ce compte.
- Références D1 : `Domenia-BoardFleet.Model.ps1:Get-DomeniaFleetBoardData`, `Domenia-Boards.Model.ps1:Add-DomeniaBoardAttention`, `Domenia-Boards.Model.ps1:Get-DomeniaHealthPointsTitle`, `fleet.attention`

#### ACC-054 · Déplier les postes d'un point d'attention

`ameliore` · locale (aucune lecture)

Un clic sur un point affiche jusqu'à 20 postes concernés (nom, OU, date de connexion ou de relevé) depuis la mémoire, avec Copier (noms, un par ligne) et Détailler les postes (sélection complète dans l'atelier avec filtres, export et fiche).

- Garde-fous : Aucune requête ; message si postes absents de la mémoire (« actualisez la vue d'ensemble »).
- Références D1 : `Domenia-Widgets.UI.ps1:Switch-DomeniaAttentionDetails`, `Domenia-Dashboard.UI.ps1:Get-DomeniaAttentionTargets`, `Domenia-BoardFleet.Model.ps1:Get-DomeniaFleetPointTargets`, `Domenia-Dashboard.UI.ps1:Copy-DomeniaFleetTargets`, `Domenia-Query.UI.ps1:Show-DomeniaAttentionInWorkshop`, `Domenia-Charts.UI.ps1:Add-DomeniaAttentionRows`

#### ACC-055 · Base locale incomplète signalée

`fait` · lecture locale

Quand la dernière lecture du périmètre s'est arrêtée à sa limite, badge « Base AD incomplète : couverture partielle » sous le score et point « chiffres peut-être sous-estimés : Mettre à jour cette OU ».

- Garde-fous : Score retenu tant que le badge est présent.
- Références D1 : `Domenia-BoardFleet.Model.ps1:Get-DomeniaFleetBoardData`, `Domenia-Dashboard.UI.ps1:Start-DomeniaFleetDashboard`

#### ACC-056 · Relevés invalides écartés

`fait` · lecture locale

Compte les relevés ignorés (contenu illisible ou identité AD différente) et le signale comme point à surveiller ; les postes restent dans la base et peuvent être relevés à nouveau.

- Garde-fous : Observation rattachée par GUID ; DN identique mais GUID différent = rejet.
- Références D1 : `Domenia-BoardFleet.Model.ps1:Get-DomeniaFleetBoardData (ObservationRejected, point cache.invalid)`

### Widgets · sécurité

#### ACC-057 · Présence des clés BitLocker des postes d'une OU

`fait` · lecture réseau

Sur geste explicite depuis l'accueil, compte par poste les objets de récupération BitLocker d'une OU et la date du plus récent, en distinguant « classe absente du domaine » et « aucun objet visible avec ce compte ».

- Garde-fous : Refusé à la racine du domaine et hors domaine ; une OU attendue ; recherche paginée (500), 100 000 objets max, troncature signalée ; ne demande jamais msFVE-RecoveryPassword ni msFVE-KeyPackage ; refus attribués à la ressource BitLocker. Refusé à la racine du domaine ; compte Secrets et refus propres à BitLocker ; récupération d'accès proposée sur refus ; limite 100 000 ; lecture tronquée n'écrit jamais « pas de clé » ; rien vu = KeepKnown ne remplace pas un compte déjà lu ; ReplaceKey fleet:bitlocker, 180 s.
- Opérations : `BitLockerPresence`, `LocalStore`
- Références D1 : `modules/Domenia-Secrets.Worker.ps1:Get-DomeniaBitLockerPresenceWorkerCode`, `modules/Domenia-Dashboard.UI.ps1 l.996`, `Domenia-Dashboard.UI.ps1:Start-DomeniaFleetBitLockerPresence`, `Domenia-Dashboard.UI.ps1:Complete-DomeniaFleetBitLockerPresence`, `Domenia-Dashboard.UI.ps1:Fail-DomeniaFleetBitLockerPresence`

#### ACC-058 · Tuile LAPS du parc

`fait` · lecture locale

Compte les postes actifs sans expiration LAPS visible (et ceux expirés), lue avec la base, jamais le mot de passe ; états Non lu, À relire, Non disponible (schéma sans LAPS) ou Non déterminé (rien de visible avec ce compte).

- Garde-fous : Ne compte rien tant qu'aucune expiration n'est visible : distingue « pas de LAPS » de « non lisible ».
- Références D1 : `Domenia-BoardFleet.Model.ps1:Get-DomeniaFleetBoardData`, `fleet.laps`

#### ACC-059 · Tuile BitLocker du parc

`fait` · lecture locale

Compte les postes actifs sans clé de récupération visible avec couverture « N postes analysés sur M, le jj/MM » ; états Non lu (avec bouton de lecture), Non disponible, Non déterminé ; refus à la racine du domaine expliqué.

- Garde-fous : Bouton porté par l'entrée, exécuté seulement au clic ; jamais la clé.
- Références D1 : `Domenia-BoardFleet.Model.ps1:Get-DomeniaFleetBoardData`, `fleet.bitlocker`

### Widgets · sondes

#### ACC-060 · Catalogue des sondes WMI

`fait` · locale (aucune lecture)

77 sondes intégrées (matériel, système, disques, sécurité, réseau, logiciels et services, utilisateurs, événements) et 33 sondes détaillées documentées du fichier JSON, chacune avec classe, propriétés, filtre, mode First/Count/All, transformation et représentation.

- Garde-fous : Le catalogue est la liste des classes autorisées ; drapeaux Slow (collecte explicite) et NoDC (jamais sur un contrôleur).
- Références D1 : `Domenia-Probes.Model.ps1:Get-DomeniaProbeCatalog`, `Domenia-Probes.Model.ps1:Get-DomeniaProbe`, `Domenia-ProbeCatalog.Model.ps1:Get-DomeniaExtendedProbeCatalog`, `Domenia-ProbeCatalog.Model.ps1:Add-DomeniaProbeMetadata`, `Domenia-ProbeCatalog.json`

#### ACC-061 · Représentations proposées par sonde

`fait` · locale (aucune lecture)

Un poste seul : chiffre ou texte ; une mesure numérique sur le parc : colonnes, chiffre, texte ; une valeur textuelle : camembert, barres, texte, chiffre.

- Références D1 : `Domenia-Probes.Model.ps1:Get-DomeniaProbeVisuals`

#### ACC-062 · Agrégation d'une sonde sur le parc

`fait` · locale (aucune lecture)

Valeurs transformées (Go, Mo, Mbit/s, jours depuis, année, % libre, version commerciale, table de correspondance) puis catégories comptées (8 + Autres) ou tranches avec unités (≤ 4 Go, 5 à 8 Go, > 512 Go), résumé moyenne/min/max et couverture.

- Garde-fous : GUID de l'observation = GUID AD ; relevés > 30 jours exclus ; erreur, contrôleur ignoré ou lecture tronquée non comptés (jamais zéro) ; état Off si la plus vieille mesure > 7 jours.
- Opérations : `LocalQuery`
- Références D1 : `Domenia-Probes.Model.ps1:Get-DomeniaProbeValues`, `Domenia-Probes.Model.ps1:ConvertTo-DomeniaProbeNumber`, `Domenia-Probes.Model.ps1:Measure-DomeniaWidgetData`, `Domenia-Probes.Model.ps1:Measure-DomeniaFleetProbeEntries`, `Domenia-Probes.Model.ps1:New-DomeniaObservationReader`

#### ACC-063 · Résumé du contrat d'une sonde

`fait` · locale (aucune lecture)

Une ligne dans l'éditeur de widget et un volet détaillé dans les détails de sonde : droits, coût, comportement, entrées, types, limites, sources, tests attendus, isolement, avertissements et refus.

- Références D1 : `Domenia-ProbeContract.Model.ps1:Get-DomeniaProbeContractSummary`, `Domenia-ProbeContract.Model.ps1:Get-DomeniaProbeContractLines`

### Widgets · versions de Windows

#### ACC-064 · Versions de Windows et fin de service

`fait` · lecture locale

Anneau des versions commerciales (operatingSystemVersion, édition Pro/Entreprise précisée), tuile Fin de service (dépassée = critique, à 90 j = à surveiller), tuile Windows 10 hors LTSC/LTSB/IoT avec sa date de fin.

- Garde-fous : Sans table, date inconnue jamais critique ; serveurs distingués des builds client partagés (cas réel DC 2025/26100) ; build non lu : fin « au plus tard » seulement si toute la famille est terminée.
- Références D1 : `Domenia-BoardFleet.Model.ps1:Get-DomeniaFleetBoardData`, `Domenia-Boards.Model.ps1:Get-DomeniaWindowsRelease`, `Domenia-Boards.Model.ps1:Get-DomeniaWindowsFamily`, `Domenia-Boards.Model.ps1:ConvertFrom-DomeniaOsVersion`, `fleet.versions`, `fleet.eos`, `fleet.win10`

<a id="rch"></a>

## Rechercher (RCH)

137 fonctions : 116 faites, 14 améliorées, 7 partielles.

### Aperçu et comparaison

#### RCH-001 · Aperçu local latéral de la fiche enregistrée

`ameliore` · lecture locale

Panneau de 400 px montrant la fiche de la ligne courante lue dans la base locale : champs AD datés, 80 attributs max, familles Présence/Utilisateur connecté/Inventaire d'un poste.

- Garde-fous : Aucune collecte ; lecture confirmée par SQLite (StoreId, chemin) ; « Non lu » / « Date non confirmée » jamais inventés ; ligne sans GUID refusée.
- Opérations : `LocalIndexRead`
- Références D1 : `Domenia-SearchWorkspace.UI.ps1:Switch-DomeniaSearchPreview`, `Domenia-SearchWorkspace.UI.ps1:Request-DomeniaSearchPreview`, `Domenia-SearchWorkspace.UI.ps1:Complete-DomeniaSearchPreview`, `Domenia-SearchWorkspace.Model.ps1:Get-DomeniaSearchPreviewRows`, `XAML:BtnSearchPreview`, `XAML:PnlSearchPreview`, `XAML:DgSearchPreview`, `XAML:BtnSearchPreviewClose`, `Domenia-Main.xaml:DgSearchPreview`, `XAML:LblSearchPreview`

#### RCH-002 · Comparer deux à huit postes

`ameliore` · lecture locale

Tableau propriété × poste (valeur et date UTC) depuis la base locale : identité, système, création, mot de passe machine, présence, console, inventaire ; Identique, Différent, Dates seules, Incomplet ; case « Différences seulement ».

- Garde-fous : Postes seulement, GUID confirmé, pas de doublon ; « Non lu » jamais identique ; aucune relecture.
- Opérations : `LocalIndexRead`
- Références D1 : `Domenia-SearchWorkspace.UI.ps1:Show-DomeniaSearchComparison`, `Domenia-SearchWorkspace.Model.ps1:Get-DomeniaComputerComparison`, `Domenia-SearchWorkspace.Model.ps1:ConvertTo-DomeniaComparisonText`, `Domenia-SearchWorkspace.Model.ps1:Get-DomeniaObservationFields`, `Domenia-SearchWorkspace.Model.ps1:Get-DomeniaFileTimeAttributeNames`, `Domenia-SearchWorkspace.UI.ps1:Get-DomeniaComparisonRowStyle`, `XAML:BtnSearchCompare`, `Domenia-Main.xaml:BtnSearchCompare`

### Arbre des OU et parcours

#### RCH-003 · Favoris d'OU épinglés au-dessus de l'arborescence

`ameliore` · lecture réseau

« Épingler cette OU » / « Retirer des favoris » ; section des favoris au-dessus de l'arbre avec étoile dans l'arbre, bouton × pour retirer et libellés distingués par leurs parents quand deux OU portent le même nom ; un clic affiche l'OU (sous-arborescence, type, terme en filtre local visible), lance la recherche de cette OU et révèle l'arbre.

- Garde-fous : Préférence locale par domaine (OuFavouritesJson), jamais de résultat, compte, droit ni mode ; refus si saisies de fiche non enregistrées ou écriture à vérifier ; le terme filtre seulement les lignes lues (limite rappelée), pas l'annuaire. DN hors du domaine refusé ; un favori ne garde jamais résultat, compte, droit ni mode écriture ; le clic sur l'étoile ne sélectionne pas la branche.
- Opérations : `GlobalSearch`
- Références D1 : `modules/Domenia-Guard.UI.ps1:Save-DomeniaFavouriteSearch`, `modules/Domenia-Guard.UI.ps1:Remove-DomeniaFavouriteSearch`, `modules/Domenia-Guard.UI.ps1:Load-DomeniaFavouriteSearch`, `modules/Domenia-Guard.UI.ps1:Update-DomeniaOuFavouritesUi`, `modules/Domenia-Guard.UI.ps1:Get-DomeniaFavouriteSearches`, `modules/Domenia-Guard.UI.ps1:Test-DomeniaOuFavourite`, `modules/Domenia-Guard.UI.ps1:Read-DomeniaOuFavouriteStore`, `modules/Domenia-Guard.UI.ps1:Write-DomeniaOuFavouriteStore`, `BtnOuFavouriteToggle`, `PnlOuFavourites`, `UxOuFavourites`, `Domenia-Search.Model.ps1:ConvertTo-DomeniaOuFavourite`, `Domenia-Search.Model.ps1:Set-DomeniaOuFavouriteState`, `Domenia-Search.Model.ps1:Get-DomeniaDnDomainKey`, `Domenia-Guard.UI.ps1:Save-DomeniaFavouriteSearch`, `Domenia-DirectoryTree.UI.ps1:Get-DomeniaDirectoryTreeHeaderTemplate`, `XAML:BtnOuFavouriteToggle`, `XAML:OuStar`, `Domenia-Main.xaml:BtnOuFavouriteToggle`

#### RCH-004 · Reprise unique des anciennes recherches enregistrées

> Reste à faire : Reprise branchée : au premier affichage d’un domaine, search.memory transforme une seule fois les recherches enregistrées d’OU en favoris (règle ImportLegacy, drapeau par domaine, journal, liste d’origine intacte), lues par ISearchReader.LegacySavedSearchesAsync (échantillon fixe en simulation). Reste la lecture du fichier Domenia.settings.json de Domenia 1 par le lecteur du mode annuaire (Domenia.Ad, vague 3).

`partiel` · locale (aucune lecture)

Au premier affichage, les anciennes recherches enregistrées (bloc Fiabilité retiré) deviennent des favoris d'OU une seule fois ; les recherches texte sur tout le domaine, sans OU, ne sont pas reprises et la liste d'origine est conservée.

- Garde-fous : Drapeau OuFavouritesImported ; validation (nom 1–80, requête ≤ 256, DN dans le domaine, type connu, limite 1–20 000) ; journalisé. Aucune donnée source modifiée.
- Références D1 : `modules/Domenia-Guard.UI.ps1:Import-DomeniaFavouriteSearchesOnce`, `modules/Domenia-Guard.Model.ps1:ConvertTo-DomeniaSavedSearch`, `Import-DomeniaOuFavourites`, `Domenia-Search.Model.ps1:Import-DomeniaOuFavourites`

#### RCH-005 · Défaut de Rechercher depuis l'OU racine

`fait` · lecture locale

Tant que l'opérateur n'a pas choisi de branche ni de signet, recherches et actualisation d'OU utilisent l'OU racine ; l'arbre reste sur le domaine ; message unique en barre d'état.

- Garde-fous : Un clic dans l'arbre (même sur le domaine) est un choix propre qui l'emporte ; aucune recherche lancée.
- Références D1 : `Domenia-Dashboard.UI.ps1:Test-DomeniaSearchUsesRootDefault`, `Domenia-Dashboard.UI.ps1:Set-DomeniaSearchDefaultFromRootOu`, `Domenia-Dashboard.UI.ps1:Get-DomeniaSectionOuDn`

#### RCH-006 · Arbre des OU virtualisé à chargement paresseux

`fait` · lecture réseau

L'arbre lit un niveau à la fois en arrière-plan, rend les grandes branches par lots (16 éléments / 20 ms, quota partagé), regroupe les conteneurs système sous la racine, se virtualise et se rafraîchit par F5 ou Actualiser.

- Garde-fous : ExpansionReadHandled : une seule lecture par dépliage ; sélection programmée sans lecture automatique. Second dépliage pendant la lecture sans effet ; rendu annulé ne s'ajoute jamais à l'ancien parent.
- Opérations : `TreeChildren`
- Références D1 : `Domenia-DirectoryTree.Types.cs:DomeniaTreeItem`, `Domenia-DirectoryTree.UI.ps1:Initialize-DomeniaDirectoryTree`, `Domenia-DirectoryTree.UI.ps1:New-DomeniaTreeStatusItem`, `Domenia-DirectoryTree.UI.ps1:Set-DomeniaTreeItemExpanded`, `Domenia-Core.ps1:Load-TreeChildren`, `XAML:TvDirectory`, `XAML:BtnTreeRefresh`, `Domenia-Core.ps1:Load-TreeRoot`, `Domenia-Core.ps1:Queue-DomeniaTreeRowsToNode`, `Domenia-Core.ps1:Initialize-DomeniaTreeRenderTimer`, `Domenia-Core.ps1:Get-DomeniaTreeRenderRows`, `Domenia-Core.ps1:New-DomeniaTreeSystemGroup`, `Domenia-Main.xaml:TvDirectory`, `Domenia-Main.xaml:BtnTreeRefresh`

#### RCH-007 · Sous-branches publiées depuis la base locale

> Reste à faire : Publication des sous-branches dans la base locale SQLite (pages de 250, OU et conteneurs) puis relecture : la base locale arrive avec la vague 3. L’arbre lit directory.ou.children ; les conteneurs de la racine ne sont plus comptés sans demande (search.containers, counts).

`partiel` · lecture locale

Les enfants lus dans l'AD sont enregistrés puis relus en SQLite (pages de 250, types OU/Conteneur) avant affichage ; une énumération vide réussie reste vide.

- Garde-fous : Jamais d'anciens enfants SQL substitués ; retour d'une autre session ou lecture ignoré.
- Opérations : `TreeChildren`, `LocalStore`
- Références D1 : `Domenia-DirectoryStore.UI.ps1:Submit-DomeniaDirectoryTreeRead`, `Domenia-DirectoryStore.UI.ps1:Complete-DomeniaDirectoryTreeRead`, `Domenia-DirectoryStore.UI.ps1:Request-DomeniaDirectoryTreeSnapshot`, `Domenia-DirectoryStore.UI.ps1:Complete-DomeniaDirectoryTreeSnapshot`, `Domenia-DirectoryStore.UI.ps1:Test-DomeniaDirectoryTreeCurrent`

#### RCH-008 · Conteneurs système regroupés

`fait` · locale (aucune lecture)

Sous la racine, System, Program Data, ForeignSecurityPrincipals, LostAndFound, Infrastructure, NTDS Quotas, TPM Devices, Keys, Managed Service Accounts et Builtin sont repliés sous « Conteneurs système » ; Users et Computers restent visibles.

- Garde-fous : Une OU n'est jamais classée système.
- Références D1 : `Domenia-Search.Model.ps1:Get-DomeniaSystemContainerNames`, `Domenia-Search.Model.ps1:Test-DomeniaSystemContainer`, `Domenia-Search.Model.ps1:Split-DomeniaTreeRows`

#### RCH-009 · Filtre local de l'arbre des OU

`fait` · locale (aucune lecture)

Filtre littéral insensible à la casse et aux accents sur le nom des branches déjà lues, parents conservés, branches correspondantes dépliées ; traitement par tranches de 8 ms.

- Garde-fous : Ne lit jamais l'annuaire ; message « branches déjà lues seulement ».
- Références D1 : `Domenia-Search.Model.ps1:Test-DomeniaOuTreeMatch`, `Domenia-Search.UI.ps1:Update-DomeniaOuTreeFilter`, `Domenia-Search.UI.ps1:Invoke-DomeniaOuTreeFilterSlice`, `Domenia-Search.UI.ps1:Stop-DomeniaOuTreeFilter`, `XAML:TxtOuFilter`, `XAML:LblTreeStatus`, `Domenia-Main.xaml:TxtOuFilter`

#### RCH-010 · Temporisation clavier de l'arbre

`fait` · locale (aucune lecture)

Un clic souris lit l'OU aussitôt ; un parcours au clavier ou un changement de type attend 300 ms et seul le dernier arrêt est lu.

- Garde-fous : Une autre OU ou une recherche lancée entre-temps l'emporte ; rien pendant une restauration.
- Opérations : `GlobalSearch`
- Références D1 : `Domenia-Search.Model.ps1:Get-DomeniaTreeSelectionDelay`, `Domenia-Search.UI.ps1:Request-DomeniaSearchFilterChanged`, `Domenia-Search.UI.ps1:Invoke-DomeniaPendingFilterChange`, `Domenia-Search.UI.ps1:Stop-DomeniaPendingFilterChange`

#### RCH-011 · Révélation d'une branche dans l'arbre

`fait` · locale (aucune lecture)

Fait défiler et sélectionne un nœud déjà lu niveau par niveau (tic 35 ms, 8 ms de budget, 60 s max), interrompu par toute action souris/clavier.

- Garde-fous : Annulé au changement de session, génération ou compte ; message si la branche est masquée par le filtre.
- Références D1 : `Domenia-DirectoryTree.UI.ps1:Start-DomeniaTreeItemReveal`, `Domenia-DirectoryTree.UI.ps1:Invoke-DomeniaTreeItemRevealTick`, `Domenia-DirectoryTree.UI.ps1:Stop-DomeniaTreeItemReveal`, `Domenia-DirectoryTree.Types.cs:DomeniaVirtualizingStackPanel`

#### RCH-012 · Fil d'Ariane de l'OU

`fait` · lecture réseau

Affiche domaine › OU › sous-OU ; chaque niveau intermédiaire est un bouton qui ouvre cette branche (une lecture) ; info-bulle du chemin complet.

- Garde-fous : Le domaine n'est qu'un texte (pas de raccourci domaine entier) ; refusé pendant une écriture ou avec brouillon non tranché ; cible d'une autre session ignorée.
- Opérations : `GlobalSearch`
- Références D1 : `Domenia-Search.UI.ps1:Update-DomeniaOuBreadcrumb`, `Domenia-Search.UI.ps1:Open-DomeniaOuBreadcrumb`, `Domenia-Continuity.Model.ps1:Get-DomeniaTreeRevealPath`, `XAML:PnlOuBreadcrumb`

#### RCH-013 · Copier le chemin LDAP de l'OU

`fait` · locale (aucune lecture)

Le DN devient un nom lisible, un fil d'Ariane (« … / a / b / c ») et un chemin complet, en décodant les octets UTF-8 et les séparateurs échappés. Le périmètre affiche « Dans : OU (dans parent) · Sous-OU incluses / Enfants directs ». Le DN exact se copie dans le presse-papiers.

- Garde-fous : Rien n'est lu ni modifié. Le libellé ne sert jamais à reconstruire une racine LDAP. La copie ne change ni le filtre ni les résultats. Si le presse-papiers est occupé, une alternative manuelle est proposée.
- Références D1 : `Domenia-Search.UI.ps1:Update-DomeniaOuBreadcrumb`, `Domenia-UX.UI.ps1:Copy-DomeniaUxOuPath`, `XAML:BtnUxCopyOuPath`, `XAML:UxOuPathDetails`, `XAML:TxtBranchDn`, `Domenia-UX.UI.ps1:Get-DomeniaUxOuDisplay`, `Domenia-UX.UI.ps1:Update-DomeniaUxOuScope`, `LblOuScopeName`, `LblOuScopePath`, `LblSearchScope`, `UxOuPathDetails`, `BtnUxCopyOuPath`, `TxtBranchDn`

#### RCH-014 · Menu d'en-tête de l'arbre

`fait` · locale (aucune lecture)

Regroupe profondeur, domaine entier, épinglage et chemin LDAP pour laisser toute la hauteur à l'arbre.

- Garde-fous : Ouvrir le menu ne lit rien.
- Références D1 : `Domenia-Search.UI.ps1:Switch-DomeniaOuMenu`, `XAML:BtnOuMenu`, `XAML:UxOuMenuPanel`

#### RCH-015 · Restauration d'une OU mémorisée sans substitution

`fait` · lecture réseau

Si le parent est chargé sans l'OU mémorisée, l'avis dit qu'elle est absente (supprimée ou déplacée). Un délai, un refus ou une branche non lue donnent au contraire une lecture à refaire. L'avis s'affiche dans la page avec « Réessayer » et « Ignorer », sans toucher à la branche ni aux résultats affichés.

- Garde-fous : Échec de lecture ≠ absence ; choix explicite requis. Un nouvel essai seulement sur geste explicite.
- Opérations : `TreeChildren`
- Références D1 : `Domenia-Search.Model.ps1:Resolve-DomeniaOuRestore`, `XAML:LblOuRestoreMessage`, `XAML:BtnOuRestoreRetry`, `XAML:BtnOuRestoreDismiss`, `LblOuRestoreMessage`, `BtnOuRestoreRetry`, `BtnOuRestoreDismiss`, `Domenia-Continuity.UI.ps1:Get-DomeniaOuRestoreDecision`, `Domenia-Continuity.UI.ps1:Show-DomeniaOuRestoreNotice`, `Domenia-Continuity.UI.ps1:Hide-DomeniaOuRestoreNotice`, `Domenia-Continuity.UI.ps1:Invoke-DomeniaOuRestoreRetry`, `XAML:OuRestoreBanner`

#### RCH-016 · Parcours d'OU séparé de la recherche globale

`fait` · lecture réseau

Choisir une OU démarre un parcours avec son propre filtre vide ; le texte global est conservé mais non appliqué ; libellé « Dans cette OU : X · Sous-OU incluses / Enfants directs ».

- Garde-fous : Aucun terme caché (TxtBranchSearch vidé, terme vers le filtre local visible).
- Opérations : `GlobalSearch`
- Références D1 : `Domenia-Search.Model.ps1:New-DomeniaSearchState`, `Domenia-Search.Model.ps1:Set-DomeniaBrowseOu`, `Domenia-Search.Model.ps1:Get-DomeniaScopeLabel`, `XAML:LblSearchScope`, `Domenia-Core.ps1:Set-SelectedBranch`, `Domenia-Core.ps1:Load-BranchObjects`, `Domenia-Core.ps1:Get-BranchQueryData`, `Domenia-Core.ps1:Invoke-DomeniaSearchFilterChanged`, `Domenia-Core.ps1:Clear-DomeniaGlobalSearch`, `Domenia-Main.xaml:CmbObjectFilter`, `Domenia-Main.xaml:TxtBranchSearch`, `Domenia-Main.xaml:TxtBranchLimit`, `Domenia-Main.xaml:BtnClearBranch`

#### RCH-017 · Profondeur de lecture de l'OU

`fait` · locale (aucune lecture)

Case « Inclure les sous-OU » : sous-arbre ou enfants directs, mémorisée par l'historique et les vues.

- Opérations : `GlobalSearch`
- Références D1 : `XAML:ChkSubtree`, `Domenia-Main.xaml:ChkSubtree`

#### RCH-018 · Type d'objet de la liste d'OU

`fait` · lecture réseau

Filtre Tous, Utilisateurs, Machines, Groupes, OU et conteneurs, traduit en filtre LDAP et retrouvé à partir du filtre pour l'historique.

- Garde-fous : Changement temporisé 300 ms.
- Opérations : `GlobalSearch`
- Références D1 : `Domenia-Search.Model.ps1:Get-DomeniaTypeFilter`, `Domenia-Search.UI.ps1:Get-DomeniaTypeLabelOfFilter`, `XAML:CmbGlobalType`, `Domenia-Main.xaml:CmbGlobalType`

#### RCH-019 · Mémoire de l'arbre de l'annuaire

`fait` · lecture réseau

Mémorise l'OU sélectionnée, les branches dépliées (128 au plus) et l'option sous-arbre, puis les restaure au démarrage avec la recherche de contenu de l'OU. Le tableau de bord attend la fin de cette restauration, OU trouvée ou non.

- Garde-fous : Seuls les DN du domaine courant sont acceptés ; enregistrement borné ; un clic ou une touche de l'opérateur arrête la restauration.
- Opérations : `TreeChildren`, `GlobalSearch`
- Références D1 : `TvDirectory`, `ChkSubtree`, `Domenia-Continuity.UI.ps1:Save-DomeniaTreeBookmark`, `Domenia-Continuity.UI.ps1:Start-DomeniaTreeBookmarkRestore`, `Domenia-Continuity.UI.ps1:Invoke-DomeniaTreeBookmarkRestore`, `Domenia-Continuity.UI.ps1:Invoke-DomeniaRestoredOuSearch`, `Domenia-Continuity.UI.ps1:Get-DomeniaTreeContextKey`, `Domenia-Continuity.UI.ps1:Get-DomeniaRealizedTreeNodes`, `Domenia-Continuity.Model.ps1:ConvertTo-DomeniaTreeBookmark`, `Domenia-Continuity.Model.ps1:ConvertTo-DomeniaStateMap`, `Domenia-Continuity.Model.ps1:Get-DomeniaTreeRevealPath`, `Domenia-Continuity.UI.ps1:Initialize-DomeniaContinuity`

#### RCH-020 · Révéler un favori dans l'arbre

`fait` · lecture réseau

À l'ouverture d'un favori, sa recherche de contenu a déjà été lancée ; l'arbre est ensuite déplié pas à pas jusqu'à l'élément, en suivant les frontières de RDN, échappements compris.

- Garde-fous : S'arrête à toute interaction de l'opérateur, avec le message dans LblTreeStatus.
- Opérations : `TreeChildren`
- Références D1 : `Domenia-Continuity.UI.ps1:Start-DomeniaFavouriteTreeReveal`, `Domenia-Continuity.UI.ps1:Invoke-DomeniaFavouriteTreeReveal`, `Domenia-Continuity.UI.ps1:Stop-DomeniaFavouriteTreeReveal`, `Domenia-Continuity.Model.ps1:Get-DomeniaTreeRevealPath`

#### RCH-021 · Menu contextuel de l'arborescence

`fait` · locale (aucune lecture)

Afficher le contenu de la branche, Actualiser l'arborescence, Copier le chemin (DN), Nouveau > Unité d'organisation (amène sur l'onglet de création), Analyser les droits sur cette branche.

- Garde-fous : Création grisée en lecture seule ; aucune saisie de nom en fenêtre modale.
- Opérations : `PermissionAnalysis`
- Références D1 : `Domenia-Core.ps1:New-DomeniaTreeContextMenu`, `Domenia-Core.ps1:Build-DomeniaTreeContextMenu`

### Barre de recherche

#### RCH-022 · Barre de recherche : récents et suggestions locales

`ameliore` · lecture locale

Bouton ✕ pour vider. Un clic ou la flèche bas affiche les 8 dernières recherches et fiches. Pendant la saisie, après 300 ms de pause et à partir de 2 caractères, des objets de la base locale sont suggérés (8 au plus, source indiquée). Les flèches choisissent, Échap ferme, un clic recopie le texte. Seule Entrée ou Rechercher interroge l'annuaire.

- Garde-fous : Taper ne lit jamais AD. SQLite est lu en lecture seule (busy 50 ms, délai 10 s). Une réponse obsolète (génération, époque, texte) est ignorée. Une base verrouillée n'empêche pas la recherche.
- Opérations : `LocalIndexRead`
- Références D1 : `Domenia-UX.UI.ps1:Initialize-DomeniaUxSearchBar`, `Domenia-UX.UI.ps1:Update-DomeniaUxSearchClear`, `Domenia-UX.UI.ps1:Update-DomeniaUxSearchSuggestions`, `Domenia-UX.UI.ps1:Set-DomeniaUxSuggestionItems`, `Domenia-UX.UI.ps1:Hide-DomeniaUxSearchSuggestions`, `Domenia-UX.UI.ps1:Request-DomeniaUxLocalSuggestions`, `Domenia-UX.UI.ps1:Start-DomeniaUxLocalSuggestions`, `Domenia-UX.UI.ps1:Complete-DomeniaUxLocalSuggestionsUi`, `Domenia-UX.UI.ps1:Invoke-DomeniaUxSearchKey`, `Domenia-UX.UI.ps1:Select-DomeniaUxSuggestion`, `Domenia-UX.UI.ps1:Register-DomeniaUxSearchGesture`, `Domenia-Shell.Model.ps1:Get-DomeniaSearchSuggestionItems`, `TxtGlobalSearch`, `BtnGlobalSearchClear`, `BtnGlobalSearch`, `LstSearchSuggest`, `UxSearchSuggest`, `LblSearchSuggestTitle`, `Domenia-Main.xaml:LstSearchSuggest`, `XAML:UxSearchPlaceholder`, `XAML:UxSearchGlyph`, `XAML:UxSearchSuggestHost`, `XAML:LblSearchSuggestHint`

#### RCH-023 · Mémoire des recherches et fiches récentes

`fait` · locale (aucune lecture)

Les 8 dernières recherches (au moins 2 caractères) et les 8 dernières fiches réellement chargées (une par DN) sont gardées dans les préférences locales de ce poste. Le JSON illisible ou étranger est ignoré.

- Garde-fous : Valeurs bornées : texte 80, type 20, DN 400. Une ligne simplement cliquée n'est pas enregistrée.
- Références D1 : `Domenia-Shell.Model.ps1:ConvertFrom-DomeniaRecentJson`, `Domenia-Shell.Model.ps1:Add-DomeniaRecentEntry`, `Domenia-Shell.Model.ps1:Select-DomeniaRecentEntries`, `Domenia-UX.UI.ps1:Get-DomeniaUxRecentEntries`, `Domenia-UX.UI.ps1:Add-DomeniaUxRecentEntry`, `Domenia-UX.UI.ps1:Add-DomeniaUxRecentObject`

#### RCH-024 · Recherche globale de la barre du haut

`fait` · lecture réseau

Barre du haut : passe d'identité exacte, préfixe sur nom, displayName, prénom, nom, sAMAccountName, dNSHostName, mail, puis ANR ; jokers seulement s'ils sont saisis ; texte fait de seuls astérisques refusé ; limite 100 par défaut jusqu'à 20 000, budget d'inactivité 120 s et plafond 900 s.

- Garde-fous : Geste explicite (Entrée ou Rechercher) ; contrat vérifié (base = domaine ou OU explicite du domaine, Subtree, aucun filtre hérité) ; génération de recherche pour ignorer les retours périmés. Résultat affiché seulement après relecture depuis SQLite ; résultat obsolète ignoré (génération, texte changé, périmètre) ; aucune ligne sélectionnée à la place de l'opérateur.
- Opérations : `GlobalSearch`
- Références D1 : `Domenia-Search.Model.ps1:New-DomeniaGlobalSearchRequest`, `Domenia-Search.Model.ps1:Test-DomeniaGlobalSearchRequest`, `Domenia-Search.Model.ps1:Get-DomeniaGlobalSearchPlan`, `Domenia-Core.ps1:Invoke-GlobalSearch`, `XAML:TxtGlobalSearch`, `XAML:BtnGlobalSearch`, `Domenia-Core.ps1:Complete-DomeniaGlobalSearchUi`, `Domenia-Core.ps1:Fail-DomeniaGlobalSearchUi`, `Domenia-Main.xaml:TxtGlobalSearch`, `Domenia-Main.xaml:BtnGlobalSearch`, `Domenia-Main.xaml:TxtGlobalLimit`, `XAML:BtnGlobalClear`

#### RCH-025 · Longueur minimale et refus de l'étoile seule

`fait` · locale (aucune lecture)

Avant tout envoi, refuse un texte fait uniquement d'étoiles (il listerait tout le domaine) ou plus court que le minimum (2 par défaut) ; en mode OU, vide ou \* liste l'OU.

- Garde-fous : Rien n'est envoyé si Valid=false ; message affiché avant Entrée.
- Références D1 : `Domenia-Search.Model.ps1:Get-DomeniaSearchTextCheck`, `Domenia-Search.Model.ps1:Test-DomeniaWildcardOnly`, `Réglage:Browser.GlobalSearchMinChars`

#### RCH-026 · Indice de lecture de la saisie

`ameliore` · locale (aucune lecture)

Sous la barre, explique à chaque frappe ce qui sera cherché : jetons reconnus, identifiant collé, adresse IP/MAC, joker en tête, refus de l'étoile. Analyse de texte seulement.

- Garde-fous : Aucune requête, aucun filtre caché.
- Références D1 : `Domenia-Search.UI.ps1:Update-DomeniaSearchHint`, `XAML:LblSearchHint`

#### RCH-027 · Syntaxe explicite optionnelle par préfixes

`fait` · locale (aucune lecture)

Préfixes utilisateur:/user:/u:, poste:/pc:/machine:/ordinateur:, groupe:/group:/g:, mail:/email:/courriel: (valeurs entre guillemets possibles) ; un préfixe inconnu reste du texte et est signalé, plusieurs types cherchent chacun dans son type.

- Garde-fous : Aucun filtre caché ajouté ; jeton vide ignoré avec note ; désactivable par drapeau.
- Opérations : `GlobalSearch`
- Références D1 : `Domenia-Search.Model.ps1:ConvertFrom-DomeniaSearchSyntax`, `Domenia-Search.Model.ps1:ConvertTo-DomeniaSearchFilter`, `Réglage:Features.SearchSyntax`

#### RCH-028 · Filtre LDAP par mots en début de valeur

`fait` · locale (aucune lecture)

Chaque mot doit correspondre (ET) au début d'un des attributs cn, sAMAccountName, displayName, sn, givenName, userPrincipalName, mail, dNSHostName (OU) ; joker en tête seulement s'il est tapé. Filtre multi-mots dédié construit sans appel.

- Garde-fous : Mot trop court refusé (parcourrait le domaine) ; indicateur Costly pour un joker en tête.
- Opérations : `GlobalSearch`
- Références D1 : `Domenia-Search.Model.ps1:Get-DomeniaWordFilter`, `Domenia-Search.Model.ps1:ConvertTo-DomeniaSearchFilter`, `Domenia-Search.Model.ps1:Get-DomeniaGlobalSearchPlan`

#### RCH-029 · Avertissement de joker en tête

`fait` · locale (aucune lecture)

Un mot commençant par \* déclenche une note : recherche par sous-chaîne sans index, potentiellement longue sur un grand domaine.

- Garde-fous : Information avant l'envoi.
- Références D1 : `Domenia-Search.Model.ps1:Get-DomeniaGlobalSearchPlan`

#### RCH-030 · Reconnaissance d'identifiants collés

`fait` · locale (aucune lecture)

GUID, SID et DN (RDN par RDN, virgules échappées) deviennent une recherche exacte ; DOMAINE\compte, UPN/adresse et FQDN sont reconnus et expliqués mais cherchés avec les autres correspondances.

- Garde-fous : AutoOpen toujours faux : aucun résultat n'est ouvert automatiquement.
- Opérations : `GlobalSearch`
- Références D1 : `Domenia-Search.Model.ps1:Get-DomeniaPastedIdentifier`, `Domenia-Search.Model.ps1:ConvertTo-DomeniaGuidFilterValue`

#### RCH-031 · Puce de périmètre Partout / Dans l'OU

`fait` · locale (aucune lecture)

Choisit entre tout le domaine et l'OU sélectionnée dans l'arbre (sous-OU incluses) ; revient à Partout si l'OU n'est plus utilisable (aucune, racine, autre domaine).

- Garde-fous : Le choix ne lit rien ; la liste affichée garde la description de la recherche qui l'a produite.
- Références D1 : `Domenia-Search.Model.ps1:Get-DomeniaSearchBarScope`, `Domenia-Search.UI.ps1:Set-DomeniaSearchBarChoice`, `Domenia-Search.UI.ps1:Update-DomeniaSearchBarUi`, `Domenia-Search.UI.ps1:Get-DomeniaSearchBarState`, `XAML:LstSearchBarScope`, `XAML:ItmSearchBarScopeOu`, `Domenia-Core.ps1:Update-DomeniaSearchScopeUi`, `Domenia-Core.ps1:Get-GlobalSelectedTypeFilter`, `Domenia-Main.xaml:LstSearchBarScope`, `XAML:LblSearchBarScopeOu`, `XAML:UxSearchBarScope`

#### RCH-032 · Sélecteur de type de la barre

`fait` · locale (aucune lecture)

Restreint la barre à Tout, Personnes, Postes ou Groupes, avec les mêmes filtres LDAP que la liste d'OU.

- Garde-fous : Aucune lecture au changement.
- Références D1 : `Domenia-Search.Model.ps1:Get-DomeniaSearchBarTypes`, `Domenia-Search.Model.ps1:Get-DomeniaTypeFilter`, `XAML:LstSearchBarType`, `Domenia-Main.xaml:LstSearchBarType`

#### RCH-033 · Texte d'attente et résumé de la barre

`fait` · locale (aucune lecture)

Le champ vide annonce ce qui sera cherché (« Poste, dans « Postes » et ses sous-OU… ») ; un résumé « Recherche · Partout · Tous les types » et un nom accessible de la puce sont produits.

- Références D1 : `Domenia-Search.Model.ps1:Get-DomeniaSearchBarText`

#### RCH-034 · Chercher aussi les noms qui contiennent

`fait` · lecture réseau

Pour une recherche globale terminée et complète de texte simple avec 5 résultats ou moins, une puce propose de relancer en « contient » (1 à 4 mots de 2 caractères min) sur name, displayName, sAMAccountName, dNSHostName, même périmètre, type et limite.

- Garde-fous : Lecture au clic seulement ; puce périmée (autre session/génération/texte) refusée ; étoile traitée comme caractère. Aucune lecture sans clic. Geste explicite uniquement.
- Opérations : `GlobalSearch`
- Références D1 : `Domenia-Search.Model.ps1:Get-DomeniaContainsSearchOffer`, `Domenia-Search.Model.ps1:New-DomeniaContainsFilter`, `Domenia-Search.UI.ps1:Update-DomeniaSearchContainsOffer`, `Domenia-Search.UI.ps1:Invoke-DomeniaSearchContains`, `XAML:BtnSearchContains`, `Domenia-Live.UI.ps1:Begin-DomeniaLiveSearch`, `Update-DomeniaSearchContainsOffer`, `Domenia-Core.ps1:Invoke-GlobalSearch (-Contains)`, `Domenia-Main.xaml:BtnSearchContains`

#### RCH-035 · Recherche par adresse IP ou MAC dans les relevés locaux

`fait` · lecture locale

Retrouve un poste par une adresse IPv4 ou MAC dans les relevés réseau stockés. Le SQL préfiltre, puis chaque candidat est analysé et l'adresse comparée exactement. Base locale seulement, sans appel réseau.

- Garde-fous : Aucun scan réseau, ping ni DNS ; base occupée = liste partielle déclarée ; une liste vide ne prouve pas l'absence. DNS uniquement sur geste explicite. Valeur non relue dans AD, dite comme telle. Une correspondance LIKE seule n'est jamais présentée comme un résultat.
- Opérations : `LocalIndexRead`, `LocalQuery`, `DnsReverseLookup`
- Références D1 : `Domenia-Search.Model.ps1:Get-DomeniaAddressQuery`, `Domenia-Search.Model.ps1:Get-DomeniaAddressSearchHint`, `Domenia-Search.UI.ps1:Start-DomeniaAddressSearch`, `Domenia-Search.UI.ps1:Complete-DomeniaAddressSearchUi`, `Domenia-Search.UI.ps1:Fail-DomeniaAddressSearchUi`, `Domenia-Core.ps1:Invoke-GlobalSearch (R40)`, `Domenia-Main.xaml:BtnAddressDns`, `Domenia-Live.UI.ps1:Begin-DomeniaLiveSearch`, `Domenia-Live.UI.ps1:Add-DomeniaLiveRow`, `Domenia-Engine.Worker.ps1:Get-DomeniaLocalIndexReadWorkerCode (AddressSearch)`

#### RCH-036 · Date du relevé sur les postes trouvés par adresse

`fait` · locale (aucune lecture)

La cellule Description affiche « adresse relevée le jj/mm/aaaa · adresse IP … » (date inconnue dite comme telle) et la colonne est révélée pour cette liste seulement.

- Garde-fous : Choix de colonne non sauvegardé.
- Références D1 : `Domenia-Search.Model.ps1:Get-DomeniaAddressNotice`, `Domenia-Search.UI.ps1:Show-DomeniaAddressNoticeColumn`

#### RCH-037 · Repli DNS inverse explicite

`fait` · lecture réseau

Si une IPv4 ne donne aucun poste local, le bouton « Chercher dans le DNS » fait une résolution inverse (15 s), place le nom trouvé dans la barre puis lance une recherche normale.

- Garde-fous : Aucun paquet avant le clic ; offre retirée dès qu'un autre texte est saisi ; échec sans autre effet. Aucun identifiant ; jamais automatique.
- Opérations : `DnsReverseLookup`, `GlobalSearch`
- Références D1 : `Domenia-Search.UI.ps1:Update-DomeniaAddressDnsOffer`, `Domenia-Search.UI.ps1:Invoke-DomeniaAddressDnsLookup`, `Domenia-Search.UI.ps1:Complete-DomeniaAddressDnsUi`, `Domenia-Search.UI.ps1:Fail-DomeniaAddressDnsUi`, `XAML:BtnAddressDns`, `Domenia-Engine.Worker.ps1:Get-DomeniaDnsReverseWorkerCode`

#### RCH-038 · Garde de la recherche à la frappe

`fait` · lecture réseau

Recherche automatique pendant la saisie (option, désactivée par défaut) refusée sous 3 caractères significatifs ou avec un joker en tête.

- Garde-fous : Une lecture large exige un Rechercher explicite. Désactivée par défaut ; jamais de lecture large ('\*', joker en tête, texte court) à la frappe.
- Opérations : `GlobalSearch`
- Références D1 : `Domenia-DirectorySchema.Model.ps1:Test-DomeniaTypedSearchAllowed`, `Domenia-Core.ps1`, `Domenia-Core.ps1:Queue-LiveGlobalSearch`

#### RCH-039 · Identifiants collés et syntaxe explicite

`fait` · lecture réseau

Un DN, GUID ou SID collé est cherché comme identifiant exact sans être coupé ; une syntaxe explicite optionnelle et un repli multi-mots s'appliquent à la barre globale.

- Opérations : `GlobalSearch`
- Références D1 : `Domenia-Core.ps1:Invoke-GlobalSearch`, `Domenia-Core.ps1:Start-DomeniaSearchFor`

### Filtres et critères

#### RCH-040 · Pastilles des critères de la liste

`fait` · locale (aucune lecture)

Chaque critère (périmètre, type, requête, sélection d'atelier, ping mémorisé, « contient ») est une pastille avec sa portée [Annuaire]/[Base locale]/[Liste chargée] et une phrase de combinaison « → N lignes affichées sur M ».

- Garde-fous : Le périmètre n'a pas de × ; pastilles reconstruites seulement si un critère change.
- Références D1 : `Domenia-SearchWorkspace.Model.ps1:Get-DomeniaSearchFilterChips`, `Domenia-SearchWorkspace.UI.ps1:Get-DomeniaSearchFilterState`, `Domenia-SearchWorkspace.UI.ps1:Update-DomeniaSearchFilterChips`, `XAML:PnlSearchFilterChips`, `XAML:LblSearchFilterSummary`

#### RCH-041 · Retirer un critère par sa pastille

`fait` · locale (aucune lecture)

Le × d'une pastille passe par le contrôle visible : filtre local et présence sans réseau, type relit l'OU (dit), requête efface sa liste, sélection d'atelier réaffiche tout.

- Garde-fous : L'effet de chaque retrait est annoncé dans l'info-bulle.
- Opérations : `GlobalSearch`
- Références D1 : `Domenia-SearchWorkspace.UI.ps1:Remove-DomeniaSearchFilterChip`

#### RCH-042 · Filtre de présence mémorisée

`fait` · locale (aucune lecture)

Filtre les listes d'OU par état de présence (en ligne, sans réponse, erreur de ping, non vérifié) par clés d'état, y compris pour les lignes anciennes au libellé texte.

- Garde-fous : Retirer n'envoie aucun ping ; « sans réponse » ne prouve pas un poste éteint. Une recherche globale n'est jamais filtrée par présence.
- Références D1 : `XAML:CmbPresenceFilter`, `Domenia-SearchWorkspace.Model.ps1:Get-DomeniaSearchFilterChips`, `CmbPresenceFilter`, `Domenia-Live.Model.ps1:Test-DomeniaPresenceMatch`, `Domenia-Live.Model.ps1:ConvertTo-DomeniaPresenceStateKey`, `Domenia-Live.Model.ps1:Get-DomeniaRowPresenceState`, `Domenia-Core.ps1:Get-TypeLdapFilter`, `Domenia-Core.ps1:Get-SearchLdapFilter`, `Domenia-Main.xaml:CmbPresenceFilter`

### Historique de navigation

#### RCH-043 · Précédent / Suivant

`ameliore` · locale (aucune lecture)

Historique de 40 lieux (page, onglet, mode, texte, OU, vue, puce, type, mode « contient ») ; boutons et Alt+Gauche / Alt+Droite.

- Garde-fous : Refusé pendant une écriture ou avec une saisie non tranchée ; ne lance jamais de balayage.
- Références D1 : `Domenia-Search.Model.ps1:New-DomeniaNavHistory`, `Domenia-Search.Model.ps1:Push-DomeniaNavState`, `Domenia-Search.Model.ps1:Step-DomeniaNavHistory`, `Domenia-Search.Model.ps1:Get-DomeniaNavStateKey`, `Domenia-Search.UI.ps1:Invoke-DomeniaNavStep`, `Domenia-Search.UI.ps1:Update-DomeniaNavButtons`, `XAML:BtnNavBack`, `XAML:BtnNavForward`, `Raccourci:Alt+Gauche`, `Raccourci:Alt+Droite`, `Domenia-Main.xaml:BtnNavBack`

#### RCH-044 · Retour exact à une étape

`fait` · locale (aucune lecture)

Restaure lignes, tri, sélection (500 lignes par GUID/DN), défilements vertical et horizontal, onglet interne, type, présence, filtre local, limite et puce, sans lecture.

- Garde-fous : Fiche non rechargée automatiquement (message) ; compteur marqué « historique, non relu ».
- Références D1 : `Domenia-Search.UI.ps1:Get-DomeniaNavSnapshot`, `Domenia-Search.UI.ps1:Restore-DomeniaNavState`, `Domenia-Search.Model.ps1:Get-DomeniaNavRowKey`, `Domenia-Search.Model.ps1:Get-DomeniaNavSelectionKeys`, `Domenia-Search.Model.ps1:Get-DomeniaNavSortState`, `Domenia-Search.Model.ps1:Get-DomeniaNavLimit`, `Domenia-Search.UI.ps1:Get-DomeniaGridSort`, `Domenia-Search.UI.ps1:Set-DomeniaGridSort`, `Domenia-Search.UI.ps1:Select-DomeniaGridRowsByKey`, `Domenia-Search.UI.ps1:Get-DomeniaGridScrollViewer`

#### RCH-045 · Branches de l'arbre rouvertes sans lecture

> Reste à faire : Une étape de l’historique rouvre sans lecture les branches qu’elle avait lues, replie celles lues depuis, sélectionne son OU et compte les branches non lues ou disparues. Le kit ne publie pas l’état replié d’une branche déjà lue : une branche lue puis repliée avant l’étape est rouverte (demande au kit : état déplié et rappel d’ouverture ou de fermeture).

`partiel` · locale (aucune lecture)

Rouvre les branches ouvertes à l'étape si déjà lues, replie celles ouvertes depuis, sélectionne l'OU ; compte les branches non lues ou disparues de leur parent.

- Garde-fous : Aucune lecture ; index borné à 100 000 nœuds.
- Références D1 : `Domenia-Search.UI.ps1:Restore-DomeniaTreeNavState`, `Domenia-Search.Model.ps1:Get-DomeniaNavTreePlan`, `Domenia-Search.UI.ps1:Get-DomeniaRealizedTreeIndex`, `Domenia-Search.UI.ps1:Find-DomeniaRealizedTreeNode`, `Domenia-Search.UI.ps1:Get-DomeniaTreeExpandedDns`, `Domenia-Search.UI.ps1:Select-DomeniaRealizedTreeNode`, `Domenia-Search.UI.ps1:Get-DomeniaOpenTreeNodes`

#### RCH-046 · Bandeau « Liste de l'historique · Actualiser »

`fait` · lecture réseau

Tant que la liste restaurée est affichée, un bandeau permet de la relire avec son périmètre, sa vue, son mode et ses filtres (requête locale incluse).

- Garde-fous : Relecture explicite, sans ping ni relevé.
- Opérations : `GlobalSearch`, `LocalIndexRead`, `LocalQuery`
- Références D1 : `Domenia-Search.UI.ps1:Test-DomeniaHistoryListShown`, `Domenia-Search.UI.ps1:Update-DomeniaHistoryBanner`, `Domenia-Search.UI.ps1:Invoke-DomeniaHistoryRefresh`, `XAML:UxHistoryBanner`, `XAML:BtnHistoryRefresh`

### Liste de résultats

#### RCH-047 · Revérification du périmètre consulté en arrière-plan

`ameliore` · lecture réseau

Case « Revérifier le périmètre consulté en arrière-plan » : relit périodiquement (180 s par défaut, 120 à 900, première après 3 min) la dernière recherche explicite, avec le même filtre et la même portée, et met à jour la liste.

- Garde-fous : Jamais de balayage caché : listes de 500 lignes max, filtre ≤ 32 768, base dans le domaine, OneLevel/Subtree ; pages de 40, limites 8 s serveur / 12 s client, délai 20 s ; seulement fenêtre active, liste visible, aucune écriture, aucune purge, aucun compte annuaire en pause, moins de 4 tâches, politique d'inactivité ; échec = cache conservé, nouvel essai dans 5 min, proposition d'un autre compte.
- Opérations : `ScopeReconcile`
- Références D1 : `modules/Domenia-Reconcile.UI.ps1:Initialize-DomeniaReconcile`, `modules/Domenia-Reconcile.UI.ps1:Invoke-DomeniaReconcileTick`, `modules/Domenia-Reconcile.UI.ps1:Get-DomeniaReconcileWorkerCode`, `modules/Domenia-Reconcile.UI.ps1:Fail-DomeniaReconcile`, `ChkGuardReconcile`, `Streaming.ReconcileSeconds`, `Timer:Reconcile`, `Domenia-Main.xaml:ChkGuardReconcile`

#### RCH-048 · Application des changements détectés par la revérification

> Reste à faire : search.reconcile relit la liste avec son filtre, sa portée et sa taille : nouvelles lignes injectées et marquées « nouveau » avec un éclat, lignes changées repeintes, objets sortis du périmètre suivis par leur GUID, absents « à revérifier », point de reprise numéroté. Reste le point de reprise incrémental réel du mode annuaire (contrôleur, invocationId, USN : ne relire que les changements), avec Domenia.Ad.

`partiel` · locale (aucune lecture)

Seules les lignes nouvelles ou changées (nom, login, UPN, état, OS, dernière connexion, description, modification, DN) sont réinjectées ; un objet déplacé garde sa ligne par GUID, un objet absent du dernier retour est marqué « à revérifier » sans suppression, et un point de reprise incrémental (DC, invocationId) est tenu.

- Garde-fous : Résultat ignoré si la recherche, l'identité, la session ou la mutation a changé ; aucune suppression automatique ; au plus 8 événements par tic et 5 ms ; un rafraîchissement demandé n'est jamais annulé ; message d'état récapitulatif.
- Opérations : `ScopeReconcile`
- Références D1 : `modules/Domenia-Reconcile.UI.ps1:Complete-DomeniaReconcile`, `Get-DomeniaRowUpdatePlan`, `Resolve-DomeniaIncrementalSync`, `Add-DomeniaLiveRow`, `Set-DomeniaLiveRowValue`

#### RCH-049 · Annuler la présentation de la liste de résultats

`fait` · locale (aucune lecture)

Historique de 10 étapes de la présentation (ordre et largeur des colonnes, tri, filtre local après 900 ms sans frappe, filtre de présence) ; Ctrl+Z dans la liste ou la puce « ↶ Annuler : &lt;colonnes, tri…> » rétablit l'étape précédente et enregistre la disposition des colonnes ; une nouvelle liste devient la référence sans effacer l'historique.

- Garde-fous : N'annule jamais une lecture, une écriture ni une opération sur l'annuaire (dit dans le message) ; repeinte filtrée de la même liste non comptée comme nouvelle liste.
- Références D1 : `modules/Domenia-Commands.Model.ps1:New-DomeniaPresentationHistory`, `modules/Domenia-Commands.Model.ps1:Add-DomeniaPresentationState`, `modules/Domenia-Commands.Model.ps1:Undo-DomeniaPresentationState`, `modules/Domenia-Commands.Model.ps1:Get-DomeniaPresentationChangeText`, `modules/Domenia-Commands.Model.ps1:Test-DomeniaPresentationUndoKey`, `modules/Domenia-Commands.Model.ps1:Reset-DomeniaPresentationCurrent`, `modules/Domenia-Commands.UI.ps1:Initialize-DomeniaPresentationUndo`, `modules/Domenia-Commands.UI.ps1:Undo-DomeniaResultPresentation`, `modules/Domenia-Commands.UI.ps1:New-DomeniaPresentationUndoChip`, `modules/Domenia-Commands.UI.ps1:Request-DomeniaPresentationRebase`, `modules/Domenia-Commands.UI.ps1:Save-DomeniaPresentationStep`, `DgObjects`, `TxtSuiteResultFilter`, `CmbPresenceFilter`, `Timer:PresentationUndo`, `Domenia-SearchWorkspace.UI.ps1:Update-DomeniaSearchFilterChips`, `Initialize-DomeniaPresentationUndo`, `Get-DomeniaPresentationUndoText`, `New-DomeniaPresentationUndoChip`

#### RCH-050 · Filtre local de la liste de résultats

`fait` · locale (aucune lecture)

Filtre les lignes déjà chargées, plusieurs mots en ET, sur les champs Type, Nom, Login, UPN, Association, Présence et utilisateur console. Texte limité à 120 caractères, champs à 2048. Le filtre s'applique 180 ms après la saisie et un bouton l'efface.

- Garde-fous : Ni regex ni joker, aucun secret parcouru. Le filtre n'agit pas pendant un verrou d'écriture. N'appelle jamais l'annuaire. Une nouvelle recherche repart sans filtre. Aucune requête réseau ni base ; une sélection de requête sans GUID reste vide.
- Références D1 : `Domenia-Experience.Model.ps1:Test-DomeniaExperienceRow`, `Domenia-Experience.UI.ps1:Initialize-DomeniaExperience`, `TxtSuiteResultFilter`, `BtnSuiteResultClear`, `LblSuiteResultCount`, `Apply-DomeniaPresenceFilter`, `XAML:TxtSuiteResultFilter`, `XAML:BtnSuiteResultClear`, `XAML:LblSuiteResultCount`, `Domenia-Core.ps1:Set-DomeniaItemsSource`, `Domenia-Main.xaml:TxtSuiteResultFilter`, `Domenia-Main.xaml:BtnSuiteResultClear`, `Domenia-Live.UI.ps1:Update-DomeniaLiveFilter`, `Update-DomeniaFilteredEmptyState`

#### RCH-051 · État vide de la liste de résultats

`fait` · locale (aucune lecture)

Une seule zone explique pourquoi la liste est vide : rien interrogé, lecture en cours, aucun résultat dans le périmètre, filtre local, lecture refusée, partielle ou sans source, ou liste d'une autre origine. Elle ajoute un indice sur le périmètre, le type, la complétude et la limite, et propose une action suivante (Effacer le filtre, Élargir, Comptes, Relire les sources) qui ne se lance que sur clic.

- Garde-fous : Aucun texte n'affirme qu'un objet ou une session n'existe pas (contrôle accent-insensible). Aucune action automatique. « Relire » n'utilise que le bouton existant s'il est actif.
- Références D1 : `Domenia-Shell.Model.ps1:Get-DomeniaEmptyState`, `Domenia-Shell.Model.ps1:Resolve-DomeniaSearchEmptyKind`, `Domenia-Shell.Model.ps1:Test-DomeniaNoAbsenceClaim`, `Domenia-UX.UI.ps1:Get-DomeniaSearchEmptyInputs`, `Domenia-UX.UI.ps1:Update-DomeniaSearchEmptyState`, `Domenia-UX.UI.ps1:Invoke-DomeniaSearchEmptyAction`, `Domenia-UX.UI.ps1:Initialize-DomeniaSearchEmptyState`, `UxSearchEmpty`, `LblSearchEmptyTitle`, `LblSearchEmptyText`, `BtnSearchEmptyNext`, `Get-DomeniaSearchAbsenceHint`, `Initialize-DomeniaSearchEmptyState`, `XAML:LblSearchEmptyTitle`, `XAML:LblSearchEmptyText`, `XAML:BtnSearchEmptyNext`

#### RCH-052 · « Le filtre masque N lignes » et Effacer le filtre

`fait` · locale (aucune lecture)

Quand le filtre texte ou le filtre de présence masque toutes les lignes chargées, la liste indique combien et quel filtre. « Effacer le filtre » remet le texte et la présence à « Tous » et réaffiche les lignes sans requête, en gardant la recherche.

- Garde-fous : Aucune requête AD. La recherche globale n'applique jamais le filtre de présence.
- Références D1 : `Domenia-Experience.Model.ps1:Get-DomeniaFilteredEmptyState`, `Domenia-Experience.UI.ps1:Update-DomeniaFilteredEmptyState`, `Domenia-Experience.UI.ps1:Clear-DomeniaResultFilters`, `CmbPresenceFilter`

#### RCH-053 · Vues de colonnes explicites (mixte, utilisateurs, postes)

`ameliore` · locale (aucune lecture)

Trois vues de la grille, chacune avec ses colonnes : pas de colonnes de console ni d'OS pour une liste d'utilisateurs, pas de mail pour une liste de postes. Largeur (40 à 1600), ordre et tri sont mémorisés par colonne et conservés pour la vue suivante. On ne change de vue qu'explicitement, et jamais pendant une saisie ou l'arrivée d'un lot (la demande est alors différée).

- Garde-fous : Aucune bascule automatique. Une colonne n'est jamais retirée de la grille, seulement masquée.
- Références D1 : `Domenia-Shell.Model.ps1:Get-DomeniaResultColumns`, `Domenia-Shell.Model.ps1:Get-DomeniaResultProfileLabels`, `Domenia-Shell.Model.ps1:Resolve-DomeniaColumnPreferences`, `Domenia-Shell.Model.ps1:Test-DomeniaProfileChangeAllowed`, `DgObjects`

#### RCH-054 · Choix des colonnes affichées

`fait` · locale (aucune lecture)

Catalogue de 16 colonnes, dont 6 affichées par défaut (Type, Nom, Utilisateur connecté, Association mémorisée, Présence réseau, État). Nom ne peut pas être masqué. Une colonne n'apparaît que si elle concerne la liste (poste, associable, compte). Le choix est stocké en JSON {Version:1;Visible} avec migration des anciennes clés (LinkSource, LinkConfidence, LastLogon, Changed).

- Garde-fous : Les clés inconnues sont ignorées. Une préférence illisible ramène les colonnes par défaut. Seules des clés de colonnes sont stockées, aucune donnée. Colonnes poste/association/compte affichées seulement si pertinentes ; clés inconnues ignorées, anciennes clés converties.
- Références D1 : `Domenia-Shell.Model.ps1:Get-DomeniaResultColumnCatalog`, `Domenia-Shell.Model.ps1:Resolve-DomeniaResultColumnChoice`, `Domenia-Shell.Model.ps1:Set-DomeniaResultColumnChoice`, `Domenia-Shell.Model.ps1:ConvertTo-DomeniaResultColumnChoiceText`, `Domenia-Shell.Model.ps1:Test-DomeniaResultColumnShown`, `Domenia-Search.UI.ps1:Initialize-DomeniaResultColumns`, `Domenia-Search.UI.ps1:Get-DomeniaResultColumnMenuEntries`, `Domenia-Search.UI.ps1:Add-DomeniaResultColumnMenuItems`, `Domenia-Search.UI.ps1:Set-DomeniaResultColumnVisible`, `Domenia-Search.UI.ps1:Reset-DomeniaResultColumns`, `Réglage:Search.ResultColumnsJson`

#### RCH-055 · Chargement progressif des résultats

`fait` · lecture réseau

Pour une recherche simple (préfixe sans espace, \*, ( ou ), type connu), les lignes de la base SQLite locale sont injectées progressivement pendant que la lecture AD se poursuit. Elles sont marquées Cached et SQLite avec leur date d'observation.

- Garde-fous : Type LDAP inattendu ou DN absent = résultat partiel ; lecture interrompue conserve les objets récoltés ; erreur de lecture garde l'aperçu. Un aperçu local ne confirme jamais la fraîcheur AD et n'autorise aucune écriture. Les filtres complexes gardent leur sémantique LDAP. Limite de 5000 lignes. Le magasin doit correspondre (StoreId, chemin). Un échec n'arrête pas la lecture AD.
- Opérations : `GlobalSearch`, `LocalIndexRead`, `LocalStore`
- Références D1 : `Domenia-Live.UI.ps1:Begin-DomeniaLiveSearch`, `Domenia-Live.UI.ps1:Add-DomeniaLiveRow`, `Domenia-Live.UI.ps1:Complete-DomeniaLiveSearch`, `Domenia-Live.UI.ps1:Fail-DomeniaLiveSearch`, `Domenia-Live.UI.ps1:Invoke-DomeniaLiveTick`, `DgObjects`, `LblBranchCount`, `LblSuiteResultCount`, `Domenia-LocalPreview.UI.ps1:Get-DomeniaLocalSearchPreviewQuery`, `Domenia-LocalPreview.UI.ps1:Request-DomeniaLocalSearchPreview`, `Domenia-LocalPreview.UI.ps1:Complete-DomeniaLocalSearchPreview`, `Domenia-LocalPreview.UI.ps1:Fail-DomeniaLocalSearchPreview`

#### RCH-056 · Lignes hors périmètre écartées

`fait` · locale (aucune lecture)

Une ligne (cache ou résultat tardif) n'est affichée que si son DN appartient à la base et à la profondeur de la recherche (OneLevel avec virgules échappées).

- Garde-fous : Journalisé une fois par recherche.
- Références D1 : `Domenia-Live.Model.ps1:Test-DomeniaLiveRowInScope`

#### RCH-057 · Objet déplacé ou renommé suivi par GUID

`fait` · locale (aucune lecture)

Une ligne AD dont le GUID est déjà listé sous un autre DN met à jour la ligne existante (état de déplacement affiché), sans doublon et en gardant présence et session.

- Garde-fous : Un aperçu tardif ne ramène jamais l'ancien DN ; type différent sous même GUID ≠ déplacement.
- Opérations : `GlobalSearch`
- Références D1 : `Domenia-Live.UI.ps1:Add-DomeniaLiveRow`, `Get-DomeniaMoveStateText`

#### RCH-058 · Quota de lignes : le cache cède la place

`fait` · locale (aucune lecture)

À la limite de la liste, les lignes venues du cache sont retirées pour laisser entrer les lignes fraîches d'AD.

- Références D1 : `Domenia-Live.UI.ps1:Add-DomeniaLiveRow`

#### RCH-059 · Charger la suite / jusqu'à 1 000, 5 000, 20 000

`fait` · lecture réseau

« Charger la suite » et « Charger jusqu'à 1 000 » lisent seulement les lignes suivantes du même filtre, triées par nom depuis le dernier lu, sans doublon ni nouvelle entrée d'historique, en gardant sélection et filtre.

- Garde-fous : Liste courante, terminée et limitée seulement ; rien n'est rejoué automatiquement ; écriture en cours = désactivé. Refusé pendant la lecture, après erreur ou au maximum ; page d'un autre compte/génération/périmètre écartée ; filtre inconnu = relecture complète. Même contrat que Charger la suite. Une ligne LDAP de plus prouve la troncature ; périmètre de la liste relu ou rien.
- Opérations : `GlobalSearch`
- Références D1 : `Domenia-Live.UI.ps1:Update-DomeniaSearchMoreButton`, `Domenia-Live.UI.ps1:Invoke-DomeniaSearchMore`, `Domenia-Live.UI.ps1:Resume-DomeniaLiveSearch`, `BtnSearchMore`, `BtnSearchMoreJump`, `Domenia-Search.Model.ps1:Get-DomeniaContinuationDecision`, `Domenia-Search.Model.ps1:New-DomeniaContinuation`, `Domenia-Search.Model.ps1:New-DomeniaContinuationRequest`, `Domenia-Search.Model.ps1:Test-DomeniaContinuationCurrent`, `XAML:BtnSearchMore`, `XAML:BtnSearchMoreJump`, `Domenia-Core.ps1:Invoke-GlobalSearch (-Continuation)`, `Domenia-Main.xaml:BtnSearchMore`, `Domenia-Main.xaml:BtnSearchMoreJump`

#### RCH-060 · Sélection conservée après relecture

`fait` · locale (aucune lecture)

Après rechargement, la ligne du DN précédemment sélectionné est resélectionnée ; si elle a disparu, la sélection est effacée partout.

- Références D1 : `Domenia-Live.UI.ps1:Add-DomeniaLiveRow`, `Clear-DomeniaSelectionEverywhere`

#### RCH-061 · Colonnes conditionnelles de la liste

`fait` · locale (aucune lecture)

La colonne Compte n'apparaît que si une ligne a un compte (login, compte associé d'un poste) ; colonnes poste seulement avec un poste, colonnes association et connexion avec utilisateurs ou postes, toujours selon le choix « Colonnes… ».

- Références D1 : `Domenia-Live.UI.ps1:Set-DomeniaLoginColumnVisible`, `Domenia-Live.UI.ps1:Update-DomeniaLoginColumnFromRows`, `Domenia-Live.UI.ps1:Set-DomeniaResultColumns`, `Domenia-Live.UI.ps1:Test-DomeniaRowHasAccount`, `Test-DomeniaResultColumnShown`

#### RCH-062 · Actions poste grisées hors poste

`fait` · locale (aucune lecture)

« Revérifier ce poste » n'est actif que pour une seule ligne de type poste ; les autres actions de relevé suivent la liste.

- Références D1 : `Domenia-Live.UI.ps1:Update-DomeniaSearchActionStates`, `BtnLiveRecheck`

#### RCH-063 · Classement de pertinence et dédoublonnage

`fait` · locale (aucune lecture)

Rangs : identifiant exact, nom exact, préfixe d'identifiant, mot entier du nom, préfixe du nom, préfixe de mot, sous-chaîne, reste ; dédoublonnage par GUID sinon DN, jamais par libellé.

- Références D1 : `Domenia-Search.Model.ps1:Get-DomeniaSearchRank`, `Domenia-Search.Model.ps1:Sort-DomeniaSearchResults`, `Domenia-Live.UI.ps1`

#### RCH-064 · Repérage des comptes d'administration

`fait` · locale (aucune lecture)

Une ligne avec adminCount=1 ou un identifiant adm-, -adm, admin… est reconnue comme compte d'administration dans la liste.

- Garde-fous : Motifs configurables.
- Références D1 : `Domenia-Search.Model.ps1:Test-DomeniaAdminAccountRow`, `Domenia-Live.UI.ps1`

#### RCH-065 · Compteur complet / limité / en cours

`fait` · locale (aucune lecture)

Indique « N résultat(s) · liste complète », « liste limitée à N : affinez ou chargez la suite », « lecture en cours » et le nombre visible après filtre local.

- Garde-fous : Au maximum de sécurité, seule l'action « affiner » est proposée.
- Références D1 : `Domenia-Search.Model.ps1:Get-DomeniaResultCounterText`, `XAML:LblBranchCount`, `XAML:LblSearchCardCount`

#### RCH-066 · Limite de lignes de la liste

`fait` · locale (aucune lecture)

Nombre maximum de lignes lues (100 par défaut, 1 à 20 000), mémorisé par l'historique et les vues.

- Garde-fous : Bornée à 20 000.
- Références D1 : `XAML:TxtGlobalLimit`, `Domenia-Search.Model.ps1:Get-DomeniaNavLimit`, `XAML:LblGlobalLimitUnit`

#### RCH-067 · Menu « ⋯ » de la liste

`fait` · locale (aucune lecture)

Regroupe Actualiser, Exporter CSV et Colonnes… en déclenchant les boutons d'origine (états et politique d'affichage conservés).

- Garde-fous : Une action masquée par l'administrateur (GuiElementPolicy) reste masquée.
- Références D1 : `Domenia-Search.UI.ps1:Get-DomeniaSearchResultMenuEntries`, `Domenia-Search.UI.ps1:New-DomeniaSearchResultMenu`, `Domenia-Search.UI.ps1:Open-DomeniaSearchResultMenu`, `XAML:BtnSearchResultMenu`

#### RCH-068 · Actualiser la liste

`fait` · lecture réseau

Relit la liste courante avec ses critères.

- Garde-fous : Geste explicite.
- Opérations : `GlobalSearch`
- Références D1 : `XAML:BtnLoadBranch`

#### RCH-069 · Exporter la liste en CSV

> Reste à faire : Export CSV de la liste affichée ou de la sélection (portée choisie, colonnes visibles, association éclatée en trois colonnes, formules neutralisées) après une confirmation qui dit la portée, ce qui est exclu et la complétude ; il part dans le presse-papiers. L’enregistrement en fichier (CSV, XLSX) attend une opération hôte de sauvegarde (demande à la plateforme).

`partiel` · locale (aucune lecture)

Exporte la liste affichée après filtres ou les seules lignes sélectionnées selon la portée choisie à côté des résultats, avec les colonnes visibles ; la confirmation rappelle ce qui est exclu et la complétude connue de la liste.

- Garde-fous : Portée annoncée avant export ; aucun secret exporté. Colonne d'association fusionnée ré-exportée en colonnes séparées.
- Références D1 : `XAML:BtnExportResults`, `Domenia-Access.Model.ps1:Protect-DomeniaExportRows`, `Domenia-SearchWorkspace.UI.ps1:Get-DomeniaResultScopePlan`, `Domenia-Core.ps1:Export-CurrentResults`, `Domenia-Core.ps1:Get-DomeniaSearchExportSubject`, `Domenia-Main.xaml:CmbResultScope`, `Domenia-Main.xaml:BtnSelectionExport`, `Domenia-Main.xaml:BtnExportResults`

#### RCH-070 · Colonne Association mémorisée des résultats

`fait` · lecture locale

Enrichit chaque ligne poste/utilisateur avec l'utilisateur ou les postes associés, la source et la qualification du meilleur lien, avec note d'identité non vérifiable.

- Garde-fous : Enrichissement facultatif : une erreur n'empêche jamais l'affichage AD (3 journalisées).
- Références D1 : `Domenia-AssociationRows.UI.ps1:Set-RowAssociationMetadata`, `Domenia-Relations.UI.ps1:Get-DomeniaLinkQualification`, `Domenia-Relations.UI.ps1:Select-DomeniaBestLink`

#### RCH-071 · Panneau « Actions, filtres et vues » replié

`fait` · locale (aucune lecture)

Le panneau d'outils de la liste démarre replié pour ne plus couvrir les résultats.

- Références D1 : `Domenia-Search.UI.ps1:Initialize-DomeniaSearchUi`, `XAML:UxResultToolsExpander`

#### RCH-072 · Ligne d'affichage canonique d'un objet

`fait` · locale (aucune lecture)

Type, nom, compte (sans $), UPN ou DNS, mail, description, modifié, DN, état (Actif/Désactivé, Verrouillé, MDP expiré, Verrouillage à vérifier), système, dernière connexion, GUID, adminCount.

- Garde-fous : Anciennes lignes sans Details complétées par leurs colonnes.
- Références D1 : `Domenia-DirectoryStore.Model.ps1:ConvertTo-DomeniaDirectoryDisplayRow`, `Domenia-DirectoryStore.Model.ps1:ConvertFrom-DomeniaDirectoryCommittedRow`, `Domenia-DirectoryStore.Model.ps1:Get-DomeniaDirectoryStoredType`, `Domenia-DirectoryStore.Model.ps1:ConvertTo-DomeniaDirectoryPropertyMap`, `XAML:DirectoryFreshGlyph`

#### RCH-073 · Revalidation des changements de la liste

`fait` · lecture réseau

Désactivée par défaut. Un administrateur peut l'activer (Streaming.RevalidateListedObjects), et l'interrupteur de la page peut ensuite l'arrêter pour la session. Elle relit les GUID listés dans leur propre périmètre toutes les 60 s (30 à 600), met à jour déplacements et renommages sous le même GUID et affiche « Liste vérifiée à HH:mm ».

- Garde-fous : Ignoré si la liste, l'identité ou la mutation a changé. Une absence n'est jamais une preuve de suppression. Rien en démonstration ; la politique de repos s'applique. Une liste globale n'hérite jamais de l'OU sélectionnée.
- Opérations : `ObjectChanges`, `LocalStore`, `LiveDirectoryCheck`
- Références D1 : `Domenia-DirectoryStore.UI.ps1:Test-DomeniaDirectoryChangesCurrent`, `Domenia-DirectoryStore.UI.ps1:Complete-DomeniaDirectoryChangesCommit`, `Domenia-DirectoryStore.UI.ps1:Complete-DomeniaDirectoryChangesRead`, `Update-DomeniaListRevalidationUi`, `XAML:ChkListRevalidation`, `XAML:LblListRevalidation`, `ChkListRevalidation`, `LblListRevalidation`, `DgObjects`, `Domenia-Continuity.UI.ps1:Test-DomeniaListRevalidationEnabled`, `Domenia-Continuity.UI.ps1:Update-DomeniaListRevalidationUi`, `Domenia-Continuity.UI.ps1:Invoke-DomeniaObjectChanges`, `Domenia-Continuity.UI.ps1:Complete-DomeniaObjectChanges`, `Domenia-Continuity.UI.ps1:Fail-DomeniaObjectChanges`, `Domenia-Continuity.UI.ps1:Test-DomeniaContinuityTickNeeded`, `Domenia-Continuity.Model.ps1:Get-DomeniaChangeWorkerCode`

#### RCH-074 · Mise à jour des grilles cellule par cellule

`fait` · locale (aucune lecture)

Un lot entrant est fusionné avec les lignes affichées par GUID : seules les cellules changées sont mises à jour et les nouvelles lignes ajoutées. Tri, position de défilement et sélection survivent. La liste n'est remplacée que si le contexte de recherche a changé.

- Garde-fous : Une identité n'apparaît jamais deux fois dans un lot.
- Références D1 : `Domenia-Cache.Model.ps1:Get-DomeniaRowUpdatePlan`, `Domenia-Reconcile.UI.ps1`

#### RCH-075 · Grille de résultats

`fait` · locale (aucune lecture)

Colonnes Type, Nom, Utilisateur connecté (console), Vérification utilisateur, Fraîcheur AD, Compte, UPN/DNS, Association mémorisée, Présence réseau, État, OS, Dernière connexion, Mail, Description, Modifié, Chemin complet ; tri, redimensionnement, sélection multiple, virtualisation, dates triées par clé et affichées en relatif.

- Garde-fous : Afficher une liste ne lance jamais de scan réseau ; une date illisible trie comme la plus ancienne.
- Références D1 : `Domenia-Main.xaml:DgObjects`, `Domenia-Core.ps1:Show-ObjectRows`, `Domenia-Core.ps1:Set-DomeniaItemsSource`, `Domenia-Core.ps1:Add-DomeniaGridDateKeys`, `Domenia-Core.ps1:Get-DomeniaGridDateSortKey`, `Domenia-Core.ps1:Get-DomeniaGridDateShortText`, `Domenia-Core.ps1:Get-ObjectsStatsText`

#### RCH-076 · Menu contextuel des résultats

`ameliore` · locale (aucune lecture)

Ouvrir la fiche, Assistance poste (vue Intervenir), Revérifier ce poste (un ping), Rechercher l'utilisateur ou le poste associé, Ouvrir l'OU parente, Copier (pour un ticket, nom, compte, UPN/DNS, DN, toutes les valeurs, résumé de fiche), Exporter en CSV selon la portée.

- Garde-fous : Aucune écriture dans ce menu ; entrées grisées si plusieurs lignes ou valeur vide.
- Opérations : `LiveSelectedPing`
- Références D1 : `Domenia-Core.ps1:New-DomeniaObjectsContextMenu`, `Domenia-Core.ps1:Build-DomeniaObjectsContextMenu`, `Domenia-Core.ps1:Start-DomeniaSearchAssociated`, `Domenia-Core.ps1:Start-DomeniaSearchFor`, `Domenia-Core.ps1:Open-DomeniaResultRowParentOu`, `Domenia-Core.ps1:Open-DomeniaResultRowSupport`, `Domenia-Core.ps1:Copy-DomeniaRowProperty`, `Domenia-Core.ps1:Copy-DomeniaGridSelection`

#### RCH-077 · Synchronisation fiche vers ligne de résultats

`fait` · locale (aucune lecture)

Quand une fiche est relue depuis AD, ses valeurs visibles et son association sont recopiées dans la ligne déjà affichée sans relancer de recherche ni changer la sélection.

- Garde-fous : Pas de réaffectation d'ItemsSource (évite la purge de la fiche).
- Références D1 : `Domenia-Core.ps1:Sync-DomeniaResultRowFromEntry`, `Domenia-Core.ps1:Refresh-AssociationContext`

### Présence et vérification

#### RCH-078 · Vérifier au clic (+ utilisateur connecté)

`fait` · locale (aucune lecture)

Deux cases mémorisées : un clic sur un poste envoie un ping (et lit l'utilisateur console si la sous-option est cochée) ; sans case, le clic précharge seulement la fiche AD.

- Garde-fous : Désactivé par défaut ; une seule intention non envoyée (180 ms) ; décocher abandonne l'intention ; liste d'historique non suivie (message).
- Opérations : `LiveConsole`, `LiveSelectedPing`
- Références D1 : `ChkLiveVerifyOnClick`, `ChkLiveUsersOnClick`, `Domenia-Live.UI.ps1:Set-DomeniaLiveClickOptions`, `Domenia-Live.UI.ps1:Select-DomeniaLiveResult`, `Domenia-Live.UI.ps1:Initialize-DomeniaLive`, `Domenia-Main.xaml:ChkLiveVerifyOnClick`

#### RCH-079 · Revérifier ce poste

`fait` · lecture réseau

Ping et lecture de l'utilisateur console du seul poste sélectionné, une tentative par geste.

- Garde-fous : Jamais tous les résultats ; délai dépassé non rejoué ; cache négatif (sauf geste manuel, mais pas après refus d'identifiants) ; AD doit confirmer la cible avant CIM.
- Opérations : `LiveConsole`, `LiveSelectedPing`
- Références D1 : `BtnLiveRecheck`, `Domenia-Live.UI.ps1:Request-DomeniaLiveRecheck`, `Domenia-Live.UI.ps1:Request-DomeniaLiveProbe`, `Domenia-Live.UI.ps1:Start-DomeniaLiveBackgroundWork`

#### RCH-080 · Colonnes Présence et Session avec âge

`fait` · lecture locale

Chaque poste montre sa présence (pastille par clé d'état, « il y a 2 h ») et son compte console, avec infobulle : dernière tentative non confirmée à côté de la dernière réussite, transport réel, source, identité, fraîcheur selon le profil.

- Garde-fous : Sans réponse ICMP ≠ éteint ; observation historique dite « pas un état actuel » ; console uniquement, sessions RDP non recensées.
- Références D1 : `Domenia-Live.UI.ps1:Set-DomeniaLiveObservationOnRow`, `Domenia-Live.Model.ps1:Get-DomeniaLiveObservationView`, `Domenia-Live.Model.ps1:Get-DomeniaLivePresenceView`, `Domenia-Live.Model.ps1:Get-DomeniaLiveAgeText`, `Domenia-Live.Model.ps1:Test-DomeniaLiveAttemptAfter`, `Get-DomeniaRecordFreshness`, `PresenceDot`, `XAML:PresenceAgeText`

#### RCH-081 · Association historique dans la liste

`fait` · lecture locale

Sans observation, un poste associé affiche « compte (historique) » avec l'origine de l'association.

- Garde-fous : Le compte console reste « à vérifier ».
- Références D1 : `Domenia-Live.UI.ps1:Add-DomeniaLiveRow`, `Set-RowAssociationMetadata`

#### RCH-082 · Suspension après rejet d'un compte

`fait` · locale (aucune lecture)

Un compte distant rejeté suspend les vérifications sur sélection ; des identifiants AD refusés à la validation du compte console suspendent la validation AD ; la ligne d'état le dit.

- Garde-fous : Aucune reprise avant correction du compte dans Comptes (pas de verrouillage par rejeu).
- Opérations : `LiveConsole`
- Références D1 : `Domenia-Live.UI.ps1:Complete-DomeniaLiveProbe`, `Domenia-Live.UI.ps1:Complete-DomeniaLiveStored`, `Domenia-Live.UI.ps1:Invoke-DomeniaLiveTick`, `LblLiveState`

#### RCH-083 · Relecture paginée des mesures de la liste

`fait` · lecture locale

Pour la liste courante, relit les observations enregistrées du périmètre par pages de 250 et rafraîchit les lignes concernées.

- Garde-fous : Une révision plus ancienne ne remplace jamais une plus récente ; GUID vérifié.
- Opérations : `LocalIndexRead`
- Références D1 : `Domenia-Live.UI.ps1:Start-DomeniaLiveBackgroundWork`, `Domenia-Live.UI.ps1:Complete-DomeniaLiveObservationRead`, `Domenia-Live.UI.ps1:Fail-DomeniaLiveObservationRead`

#### RCH-084 · Présence colorée par clé d'état

`fait` · locale (aucune lecture)

Couleur verte en ligne, rouge sans réponse, ambre en cours ou erreur de ping, grise sinon ou pour une valeur d'une session antérieure ; l'âge de la mesure remplace « (cache) » et la couleur est recalculée au changement de thème.

- Garde-fous : Contraste 4,5:1 des jetons ; le rendu ne crée jamais d'observation.
- Références D1 : `Domenia-Core.ps1:Get-DomeniaPresenceColor`, `Domenia-Core.ps1:Set-DomeniaPresenceText`, `Domenia-Core.ps1:Update-DomeniaObjectPresence`, `Domenia-Core.ps1:Get-DomeniaCachedPresenceState`, `Domenia-Core.ps1:Set-DomeniaResultRowPresence`

#### RCH-085 · Présence de liste héritée non appelée

`fait` · lecture réseau

Ancienne fonction qui pingait chaque machine nouvellement listée (un écho ICMP) ; elle n'a plus d'appelant (un test vérifie l'absence d'appel) et ne doit pas être reprise telle quelle.

- Garde-fous : Aucune sonde réseau sans geste (règle 4 du dépôt).
- Opérations : `PresenceScan`
- Références D1 : `Domenia-Core.ps1:Start-DomeniaResultPresenceScan`, `tests/Test-DomeniaCollectCircuit.ps1`

### Relevé de la liste

#### RCH-086 · Vérifier la liste ▾ (trois lectures graduées)

`ameliore` · lecture réseau

Bouton unique qui lance la dernière lecture choisie dans la session ou ouvre les choix « Qui répond ? » (ping), « Qui est connecté ? » (ping + console CIM), « Matériel et widgets » ; il devient « Arrêter (12/48) » pendant le relevé et s'applique aux lignes sélectionnées si cette portée est choisie.

- Garde-fous : Choix mémorisé pour la session seulement ; confirmation chiffrée avant toute lecture.
- Opérations : `ParkPing`, `LiveConsole`, `LocalIndexRead`
- Références D1 : `Domenia-Park.Model.ps1:Get-DomeniaParkVerifyModes`, `Domenia-Park.UI.ps1:Invoke-DomeniaParkVerify`, `Domenia-Park.UI.ps1:Open-DomeniaParkVerifyMenu`, `Domenia-Park.UI.ps1:Get-DomeniaParkVerifyButtonText`, `BtnParkVerify`, `BtnParkVerifyMenu`, `BtnParkModePing`, `BtnParkModeConsole`, `BtnParkModeAnalyse`, `Domenia-Main.xaml:BtnParkVerify`

#### RCH-087 · Analyser la liste (matériel et widgets)

`fait` · lecture réseau

Ping, utilisateur console, relevé WMI léger et requêtes des widgets des tableaux de bord pour les postes affichés ou sélectionnés, WMI seulement sur les postes qui répondent.

- Garde-fous : Sondes lentes, Win32_Process, QFE, Win32_Product et journaux exclus d'un relevé de masse.
- Opérations : `ParkPing`, `LiveConsole`
- Références D1 : `Domenia-Park.UI.ps1:Start-DomeniaParkAnalysis`, `Get-DomeniaBoardProbeIds`

#### RCH-088 · Relevé complet de la liste (correctifs)

`fait` · lecture réseau

Relevé léger plus correctifs, démarrage, services automatiques arrêtés, TPM, BIOS et numéro de série des postes affichés.

- Garde-fous : Aucun Win32_Product ni liste de processus.
- Opérations : `ParkPing`, `LiveConsole`
- Références D1 : `Domenia-Park.UI.ps1:Start-DomeniaCompleteSurvey`, `BtnParkModeComplet`

#### RCH-089 · Relire les postes sans adresse

`fait` · lecture réseau

Relevé qui ne vise que les postes sans adresse connue, laissés après les autres dans un relevé normal.

- Garde-fous : Mêmes confirmation et plafond.
- Opérations : `ParkPing`, `LiveConsole`
- Références D1 : `Domenia-Park.UI.ps1:Start-DomeniaUnaddressedSurvey`, `BtnParkRetryUnaddressed`

#### RCH-090 · Garde de périmètre d'un relevé

`fait` · locale (aucune lecture)

Refuse un relevé au-delà du plafond (Park.MaxTargets, 500 par défaut, 5 000 max), d'une liste de la racine du domaine sans autre filtre, d'une recherche globale sans terme, ou d'une vue de travail listée sur tout le domaine.

- Garde-fous : Une sélection de toute la liste (Ctrl+A) suit les règles de la liste ; jamais un relevé déguisé de tout le domaine.
- Références D1 : `Domenia-Park.Model.ps1:Test-DomeniaParkTargetAdmission`, `Domenia-Park.UI.ps1:Get-DomeniaParkMaxTargets`, `Domenia-Park.UI.ps1:Get-DomeniaParkListContext`, `Domenia-Park.UI.ps1:Start-DomeniaOnlinePark`

#### RCH-091 · Confirmation chiffrée et aperçu exact

`ameliore` · lecture locale

Avant toute lecture : trois lignes (quels postes et pourquoi le nombre diffère, ce qui sera lu, durée estimée et parallélisme), liste exacte des postes à lire et des lignes écartées avec leur motif, bouton chiffré « Pinger 48 postes ».

- Garde-fous : Au-delà d'un seuil, le nombre doit être saisi ; hors fenêtre de collecte, confirmation obligatoire ; mention du plan interrompu remplacé ; profil, regroupement CIM et budgets annoncés.
- Opérations : `ParkSweep`, `LocalIndexRead`
- Références D1 : `Domenia-Park.Model.ps1:New-DomeniaParkConfirmationText`, `Domenia-Park.Model.ps1:Get-DomeniaParkDurationEstimate`, `Domenia-Park.Model.ps1:Format-DomeniaParkDuration`, `Domenia-Park.UI.ps1:Request-DomeniaParkAdmission`, `Domenia-Park.UI.ps1:Complete-DomeniaParkTargets`, `New-DomeniaCollectivePreview`

#### RCH-092 · Ping massif par lots

`fait` · lecture réseau

Échos ICMP en parallèle par lots de 192 (256 max), délai 1 s (250 à 3 000 ms), résolution DNS parallèle bornée à 2,5 s en IPv4 d'abord, résultats remontés par lot et enregistrés par transactions de 32 (4 lots en vol).

- Garde-fous : Aucun compte, aucun CIM ; nom invalide ou non résolu = erreur, jamais « sans réponse » ; budget moteur ≤ 30 min ; postes jamais rapportés restent non vérifiés.
- Opérations : `ParkPing`, `LocalStore`
- Références D1 : `Domenia-Park.Worker.ps1:Get-DomeniaParkPingWorkerCode`, `Domenia-Park.UI.ps1:Start-DomeniaParkPingJob`, `Domenia-Park.UI.ps1:Select-DomeniaParkPingBatch`, `Domenia-Park.UI.ps1:Receive-DomeniaParkPingQueue`, `Domenia-Park.UI.ps1:Submit-DomeniaParkPingResults`, `Domenia-Park.Model.ps1:Get-DomeniaParkPingTimeoutSeconds`

#### RCH-093 · Lecture console et WMI des postes de la liste

`fait` · lecture réseau

Lecture CIM des postes, 4 à la fois par défaut (Collection.Concurrency 1 à 8), éventuellement après ping obligatoire, avec délai d'inactivité et durée totale bornés.

- Garde-fous : Moteur saturé ≠ échec ; postes sans adresse proposés en dernier ; lecture arrêtée classée selon l'étape ping rapportée.
- Opérations : `LiveConsole`
- Références D1 : `Domenia-Park.UI.ps1:Invoke-DomeniaParkRunTick`, `Domenia-Park.UI.ps1:Select-DomeniaParkNextTarget`, `Domenia-Park.UI.ps1:Test-DomeniaParkEngineAvailable`, `Domenia-Park.UI.ps1:Complete-DomeniaParkSession`, `Domenia-Park.UI.ps1:Fail-DomeniaParkSession`

#### RCH-094 · Barre et compteur court du relevé

`fait` · locale (aucune lecture)

Barre fine et texte « 12/48 · 9 joignables » puis « 48/48 · 30 en ligne · 15 sans réponse · 3 erreurs » ; un relevé WMI compte des postes lus.

- Garde-fous : Lectures non confirmées et postes non vérifiés comptés à part ; « Arrêté à … ».
- Références D1 : `PbParkProgress`, `Domenia-Park.Model.ps1:Get-DomeniaParkProgressText`, `Domenia-Park.Model.ps1:Get-DomeniaParkOutcomeKind`, `Domenia-Park.UI.ps1:Update-DomeniaParkRunStatus`, `XAML:LblParkProgress`, `XAML:UxParkProgress`

#### RCH-095 · Pastilles de résultat qui filtrent

`fait` · locale (aucune lecture)

En fin de ping, trois pastilles (en ligne, sans réponse, erreurs) filtrent la liste par présence ; second clic pour retirer.

- Garde-fous : Filtre local des lignes chargées, aucune nouvelle recherche.
- Références D1 : `Domenia-Park.UI.ps1:Update-DomeniaParkOutcomePills`, `Domenia-Park.UI.ps1:Set-DomeniaParkOutcomeFilter`, `BtnParkOutcomeOnline`, `BtnParkOutcomeNoReply`, `BtnParkOutcomeError`, `XAML:PnlParkOutcome`

#### RCH-096 · Lignes « relevé en cours »

`fait` · locale (aucune lecture)

Chaque ligne lue porte la marque « relevé en cours » jusqu'à l'enregistrement de sa mesure, puis reçoit la valeur relue après COMMIT.

- Garde-fous : Aucune date régénérée dans la vue ; vue rafraîchie par lot, jamais par ligne.
- Références D1 : `Domenia-Park.UI.ps1:Set-DomeniaParkPendingRows`, `Domenia-Park.UI.ps1:Clear-DomeniaParkPendingRow`, `Domenia-Park.UI.ps1:Update-DomeniaParkResultRows`, `Domenia-Park.UI.ps1:Sync-DomeniaParkGrid`, `Domenia-Park.UI.ps1:Get-DomeniaParkResultRowIndex`

#### RCH-097 · Barre de sélection multiple

`fait` · lecture réseau

À partir de deux lignes sélectionnées : « n postes sélectionnés : Pinger · Qui est connecté ? · Copier · Exporter », relevés limités aux lignes sélectionnées visibles.

- Garde-fous : Même confirmation et plafond que la liste ; lignes sans identité comptées.
- Opérations : `ParkPing`, `LiveConsole`
- Références D1 : `Domenia-Park.UI.ps1:Update-DomeniaParkSelectionBar`, `Domenia-Park.UI.ps1:Start-DomeniaParkSelectionSurvey`, `Domenia-Park.UI.ps1:Get-DomeniaParkSelectionTargets`, `Domenia-Main.xaml:BtnSelectionPing`, `XAML:BtnSelectionConsole`, `XAML:UxSelectionBar`

#### RCH-098 · Arrêter un relevé

`fait` · locale (aucune lecture)

Arrête le relevé de la liste (ou d'une portée) : les mesures déjà reçues sont enregistrées, une demande de confirmation encore affichée est retirée.

- Garde-fous : Rien n'est rejoué ; le plan durable garde les postes restants.
- Références D1 : `Domenia-Park.UI.ps1:Stop-DomeniaOnlinePark`, `Domenia-Park.UI.ps1:Stop-DomeniaParkPingWorker`, `Domenia-Park.UI.ps1:Close-DomeniaParkPingJobTargets`, `Domenia-Park.UI.ps1:Test-DomeniaParkListStoppable`

#### RCH-099 · Détail de l'état d'un relevé

`fait` · locale (aucune lecture)

Texte détaillé : résultats validés et attente réelle, sources ralenties ou suspendues, nouveaux essais, capacités mémorisées, requêtes CIM évitées, plan de reprise.

- Garde-fous : Valeurs inconnues non affichées.
- Références D1 : `Domenia-Park.UI.ps1:Get-DomeniaParkRunDetailText`, `Domenia-Park.UI.ps1:Update-DomeniaParkHeldStatus`, `Domenia-Park.UI.ps1:Add-DomeniaParkHeldTime`

### Requêtes

#### RCH-100 · Effacer la requête appliquée à Recherche

`fait` · locale (aucune lecture)

Retire le filtre de requête des résultats affichés dans Rechercher.

- Références D1 : `BtnQueryClearSearch`, `Domenia-Query.UI.ps1:Invoke-DomeniaQueryAction`, `Clear-DomeniaSearchQuery`, `Domenia-Search.UI.ps1:Clear-DomeniaSearchQuery`, `XAML:BtnQueryClearSearch`

#### RCH-101 · Filtrer les lignes de Recherche par la sélection de requête

> Reste à faire : Filtre des lignes par la sélection d’une requête de l’Atelier (par GUID) : l’écran Atelier de requêtes n’existe pas encore et ne publie pas sa sélection ; Rechercher filtre déjà par verdict les requêtes locales livrées.

`partiel` · locale (aucune lecture)

Règle invisible : quand une requête est appliquée, seules les lignes de type Machine dont le GUID figure dans la sélection restent visibles.

- Garde-fous : Correspondance par GUID uniquement.
- Références D1 : `Domenia-Query.UI.ps1:Test-DomeniaSearchQueryRow`, `Apply-DomeniaPresenceFilter`

#### RCH-102 · Exécuter une requête dans Recherche

> Reste à faire : Les requêtes locales livrées (9) s’exécutent dans Rechercher sur l’OU choisie (ou, explicitement, sur tout le domaine), avec leurs trois verdicts, « Tous » triés correspondants d’abord, et leur couverture ; restent les requêtes enregistrées de l’Atelier (SELECT mémorisés) quand l’écran Requêtes les publiera.

`partiel` · lecture locale

Le moteur de requêtes sert aussi Recherche (mode SearchOutput) sur l'OU de Recherche, jusqu'à 20 000 postes en deux pages de la même population, avec les SELECT mémorisés et verdicts de collection.

- Garde-fous : Limite 1 à 20 000 ; observations revalidées par GUID et date.
- Opérations : `LocalQuery`, `LocalIndexRead`
- Références D1 : `Domenia-Query.Worker.ps1:Get-DomeniaQueryWorkerCode`, `Domenia-QueryDetails.UI.ps1:Start-DomeniaQueryDetailRead`

#### RCH-103 · Modèles livrés dans les vues de Recherche

`fait` · locale (aucune lecture)

Les modèles livrés, préparés une fois hors interface, alimentent la liste des vues de Recherche dès qu'ils sont prêts.

- Garde-fous : Jamais construits sur le fil d'interface.
- Opérations : `QueryLibrary`
- Références D1 : `Domenia-Query.UI.ps1:Get-DomeniaPreparedQueryTemplates`, `Domenia-Query.UI.ps1:Set-DomeniaPreparedQueryTemplateRows`, `Update-DomeniaWorkViewList`

#### RCH-104 · Requête : comptes expirant sous 30 jours

`fait` · lecture réseau

Utilisateurs dont accountExpires tombe dans les 30 prochains jours (date d'expiration du compte, pas du mot de passe).

- Garde-fous : Lecture seule, OU choisie par défaut.
- Opérations : `GlobalSearch`
- Références D1 : `Domenia-Search.Model.ps1:Get-DomeniaWorkViews#expiring`

#### RCH-105 · Requête : comptes désactivés

`fait` · lecture réseau

Utilisateurs avec le bit 2 de userAccountControl.

- Garde-fous : Lecture seule.
- Opérations : `GlobalSearch`
- Références D1 : `Domenia-Search.Model.ps1:Get-DomeniaWorkViews#disabled`

#### RCH-106 · Requête : comptes à expiration dépassée

`fait` · lecture réseau

accountExpires passé (0 et valeur maximale exclus) ; rappel que l'expiration bloque l'ouverture sans désactiver.

- Garde-fous : Lecture seule.
- Opérations : `GlobalSearch`
- Références D1 : `Domenia-Search.Model.ps1:Get-DomeniaWorkViews#expiredaccounts`

#### RCH-107 · Requête : verrouillage enregistré

`fait` · lecture réseau

lockoutTime non nul ; avertit qu'un verrouillage échu peut figurer et que l'état réel se confirme sur la fiche.

- Garde-fous : Lecture seule.
- Opérations : `GlobalSearch`
- Références D1 : `Domenia-Search.Model.ps1:Get-DomeniaWorkViews#lockedusers`

#### RCH-108 · Requête : comptes actifs sans connexion depuis 90 jours

`fait` · lecture réseau

Comptes activés dont lastLogonTimestamp (à 14 jours près) date d'au moins 90 jours ; aucun compte déclaré supprimable.

- Garde-fous : Lecture seule.
- Opérations : `GlobalSearch`
- Références D1 : `Domenia-Search.Model.ps1:Get-DomeniaWorkViews#inactiveusers`

#### RCH-109 · Requête : comptes actifs jamais connectés

`fait` · lecture réseau

Comptes activés sans lastLogonTimestamp : neuf, de service ou oublié, sans conclusion.

- Garde-fous : Lecture seule.
- Opérations : `GlobalSearch`
- Références D1 : `Domenia-Search.Model.ps1:Get-DomeniaWorkViews#neverloggedusers`

#### RCH-110 · Requête : mots de passe sans expiration

`fait` · lecture réseau

Option « Le mot de passe n'expire jamais » (bit 65536) ; option à revoir, pas une compromission.

- Garde-fous : Aucun mot de passe lu.
- Opérations : `GlobalSearch`
- Références D1 : `Domenia-Search.Model.ps1:Get-DomeniaWorkViews#pwdneverexpires`

#### RCH-111 · Requête : mot de passe non exigé

`fait` · lecture réseau

Option PASSWD_NOTREQD (bit 32) de userAccountControl.

- Garde-fous : Aucun mot de passe lu.
- Opérations : `GlobalSearch`
- Références D1 : `Domenia-Search.Model.ps1:Get-DomeniaWorkViews#pwdnotrequired`

#### RCH-112 · Requête : mots de passe inchangés depuis un an

`fait` · lecture réseau

Comptes activés dont pwdLastSet a au moins 365 jours ; renvoie vers Audit AD pour la stratégie.

- Garde-fous : Lecture seule.
- Opérations : `GlobalSearch`
- Références D1 : `Domenia-Search.Model.ps1:Get-DomeniaWorkViews#pwdold`

#### RCH-113 · Requête : changement de mot de passe demandé

`fait` · lecture réseau

pwdLastSet = 0 : changement imposé à la prochaine ouverture de session.

- Garde-fous : Lecture seule.
- Opérations : `GlobalSearch`
- Références D1 : `Domenia-Search.Model.ps1:Get-DomeniaWorkViews#pwdmustchange`

#### RCH-114 · Requête : objets modifiés depuis 7 jours

`fait` · lecture réseau

whenChanged des 7 derniers jours (valeur propre à chaque contrôleur).

- Garde-fous : Lecture seule.
- Opérations : `GlobalSearch`
- Références D1 : `Domenia-Search.Model.ps1:Get-DomeniaWorkViews#recent`, `Domenia-Search.Model.ps1:ConvertTo-DomeniaLdapTime`

#### RCH-115 · Requête : postes de cette OU

`fait` · lecture réseau

Tous les objets ordinateur du périmètre choisi.

- Garde-fous : Lecture seule.
- Opérations : `GlobalSearch`
- Références D1 : `Domenia-Search.Model.ps1:Get-DomeniaWorkViews#oucomputers`

#### RCH-116 · Requête : postes sans connexion depuis 90 jours

`fait` · lecture réseau

Ordinateurs dont lastLogonTimestamp a 90 jours ou plus, jamais connectés inclus (« Jamais »).

- Garde-fous : Aucun objet déclaré supprimable.
- Opérations : `GlobalSearch`
- Références D1 : `Domenia-Search.Model.ps1:Get-DomeniaWorkViews#stalecomputers`

#### RCH-117 · Périmètre des requêtes : OU ou domaine entier

`fait` · locale (aucune lecture)

Une requête s'applique à l'OU de l'arbre (« Requêtes · Postes ») ; le domaine entier est un choix secondaire explicite qui bloque tout relevé des postes (ping, détection, analyse).

- Garde-fous : SurveyAllowed=false sur tout le domaine : pas de scan du parc.
- Références D1 : `Domenia-Search.Model.ps1:Get-DomeniaWorkViewPlan`, `Domenia-Search.UI.ps1:Get-DomeniaWorkViewScopeChoice`, `Domenia-Search.UI.ps1:Update-DomeniaOuScopeChoices`, `XAML:CmbWorkViewScope`

#### RCH-118 · Catalogue unifié des requêtes

`ameliore` · lecture locale

Une liste réunit les requêtes Annuaire, les modèles livrés (préparés en arrière-plan à l'ouverture) et les requêtes locales personnelles par catégorie ; filtre texte et case Favoris.

- Garde-fous : Choisir ne lance rien ; bibliothèque illisible ou non confirmée signalée.
- Opérations : `QueryLibrary`
- Références D1 : `Domenia-Search.Model.ps1:Get-DomeniaSearchQueryCatalog`, `Domenia-Search.Model.ps1:Find-DomeniaSearchQuery`, `Domenia-Search.UI.ps1:Update-DomeniaWorkViewList`, `Domenia-Search.UI.ps1:Update-DomeniaSearchQueryList`, `Domenia-Search.UI.ps1:Initialize-DomeniaSearchQuerySelector`, `XAML:CmbWorkView`, `XAML:TxtSearchQueryFilter`, `XAML:ChkSearchQueryFavorites`, `Domenia-Main.xaml:CmbWorkView`

#### RCH-119 · Favoris de requête

`fait` · locale (aucune lecture)

Étoile ☆/★ pour épingler une requête, 200 favoris au plus, enregistrés immédiatement.

- Garde-fous : Retour à la valeur précédente si l'enregistrement échoue ; identifiants validés par motif.
- Références D1 : `Domenia-Search.UI.ps1:Switch-DomeniaSearchQueryFavorite`, `Domenia-Search.UI.ps1:Get-DomeniaSearchQueryFavorites`, `XAML:BtnSearchQueryFavorite`, `Réglage:Search.QueryFavorites`

#### RCH-120 · Détail d'une requête : source, périmètre, coût, couverture

`fait` · lecture locale

Indique la source (annuaire ou base locale), le type, l'OU et la profondeur, le coût LDAP estimé avec le schéma lu, et pour une requête locale la date de la dernière lecture complète couvrante.

- Garde-fous : Sans schéma lu, l'usage d'index reste inconnu et le dit.
- Références D1 : `Domenia-Search.UI.ps1:Update-DomeniaSearchQueryDetails`, `Domenia-Search.UI.ps1:Get-DomeniaSearchQueryLdapCostText`, `Domenia-Search.UI.ps1:Get-DomeniaSearchQueryCoverageText`, `XAML:LblSearchQueryDetails`

#### RCH-121 · Exécuter une requête Annuaire

`fait` · lecture réseau

Lance la vue choisie après réinitialisation des filtres de liste (présence, type, filtre local, sélection d'atelier).

- Garde-fous : Geste explicite ; une vue ne porte ni compte, ni droit, ni mode écriture ; identifiant inconnu refusé.
- Opérations : `GlobalSearch`
- Références D1 : `Domenia-Search.UI.ps1:Invoke-DomeniaWorkView`, `Domenia-Search.UI.ps1:Reset-DomeniaSearchQueryFilters`, `XAML:BtnWorkView`

#### RCH-122 · Exécuter une requête locale sur les postes

`fait` · lecture locale

Évalue une recette sur les postes recensés de l'OU dans la base locale et affiche Correspondants, Inconnus ou Non correspondants avec totaux et limite.

- Garde-fous : Aucune lecture AD, ping ni relevé ; résultat hors périmètre rejeté ; refusé pendant une écriture ; valeurs manquantes restent inconnues.
- Opérations : `LocalIndexRead`, `LocalQuery`
- Références D1 : `Domenia-Search.UI.ps1:Start-DomeniaSearchLocalQuery`, `Domenia-Search.UI.ps1:Complete-DomeniaSearchLocalRead`, `Domenia-Search.UI.ps1:Start-DomeniaSearchLocalCompute`, `Domenia-Search.UI.ps1:Complete-DomeniaSearchLocalQuery`, `Domenia-Search.UI.ps1:Fail-DomeniaSearchLocalQuery`, `Domenia-Search.Model.ps1:ConvertTo-DomeniaSearchQueryRows`, `XAML:CmbSearchQueryResult`, `XAML:LblSearchQuery`

### Sélection et portée

#### RCH-123 · Export CSV avec colonnes d'association détaillées

`fait` · locale (aucune lecture)

L'association affichée en une seule cellule redevient trois colonnes dans le CSV : Association mémorisée, Source lien et Qualification. Elles suivent la position choisie pour l'association, sans doublon.

- Garde-fous : Seules des colonnes déjà présentes sont exportées. L'ancienne règle « sélection d'au moins 2 lignes, sinon liste visible » ne sert plus qu'à l'aperçu de maintenance.
- Références D1 : `Domenia-Shell.Model.ps1:Expand-DomeniaResultExportColumns`, `Domenia-Experience.UI.ps1:Get-DomeniaExperienceExportRows`

#### RCH-124 · Aperçu de la ligne sélectionnée

`fait` · locale (aucune lecture)

Ligne fixe sous les résultats et infobulle détaillée : type et nom, état de lecture (non lue, chargement, lue, erreur, refusée), lignes lues (identifiant, système, état, emplacement, présence) et destinations Fiche, Utilisateurs et postes, Poste avec la raison de chaque indisponibilité. Le détail d'une autre sélection ou d'une autre génération n'est jamais affiché.

- Garde-fous : GUID et génération sont contrôlés. Un affichage issu du cache reste « chargement ». Un refus d'accès est « Refusée », jamais une absence. Les erreurs sont masquées.
- Références D1 : `Domenia-Shell.Model.ps1:Get-DomeniaSelectionPreview`, `Domenia-Shell.Model.ps1:ConvertTo-DomeniaPreviewLoadState`, `Domenia-Shell.Model.ps1:ConvertTo-DomeniaSelectionPreviewText`

#### RCH-125 · Copier la sélection pour un ticket

`fait` · locale (aucune lecture)

Une ligne lisible par objet sélectionné : type, nom, compte, présence et son âge, utilisateur console, OU lisible (« Lyon / Postes »). Ni GUID ni DN, aucune valeur sur plusieurs lignes, masquage des secrets.

- Garde-fous : Projection en liste blanche, Protect-DomeniaSecretText. Masquage des secrets avant le presse-papiers.
- Références D1 : `Domenia-Shell.Model.ps1:ConvertTo-DomeniaTicketOuPath`, `Domenia-Shell.Model.ps1:ConvertTo-DomeniaTicketLine`, `Domenia-Shell.Model.ps1:ConvertTo-DomeniaTicketText`, `BtnSelectionCopy`, `Domenia-Core.ps1:Copy-DomeniaSelectedRowsForTicket`, `Domenia-Main.xaml:BtnSelectionCopy`

#### RCH-126 · Portée collective explicite des exports et relevés

`fait` · locale (aucune lecture)

Choix Liste affichée / Lignes sélectionnées ; la phrase dit les lignes traitées, celles masquées par filtre exclues et la complétude (complète, limitée, partielle, en cours, inconnue).

- Garde-fous : Jamais « complète » sans lecture finie et non limitée ; lignes au-delà de la limite jamais impliquées.
- Références D1 : `Domenia-SearchWorkspace.Model.ps1:Get-DomeniaSearchSelectionPlan`, `Domenia-SearchWorkspace.Model.ps1:Get-DomeniaSearchScopeSummary`, `Domenia-SearchWorkspace.UI.ps1:Get-DomeniaResultScopeMode`, `Domenia-SearchWorkspace.UI.ps1:Get-DomeniaSearchListCompleteness`, `Domenia-SearchWorkspace.UI.ps1:Update-DomeniaResultScopeUi`, `Domenia-SearchWorkspace.UI.ps1:Get-DomeniaResultScopePlan`, `XAML:CmbResultScope`, `XAML:LblResultScope`

#### RCH-127 · Énoncé de la sélection multiple

`fait` · locale (aucune lecture)

« 3 postes sélectionnés », « 3 lignes sélectionnées dont 1 poste », identique dans la barre de sélection et avant un export ou un relevé.

- Références D1 : `Domenia-SearchWorkspace.Model.ps1:Get-DomeniaSearchSelectionText`, `XAML:LblSelectionBar`

#### RCH-128 · Avertissement d'absence dans une liste

`fait` · locale (aucune lecture)

Info-bulle : portée, type retenu, filtre local actif et couverture ; une absence de résultat ne prouve pas l'absence dans l'annuaire.

- Références D1 : `Domenia-SearchWorkspace.Model.ps1:Get-DomeniaSearchAbsenceHint`

#### RCH-129 · Préchargement de la fiche à la sélection

`fait` · lecture réseau

Un clic sur une ligne unique précharge sa fiche AD (aperçu d'état dans la barre), double-clic ouvre ; les lectures liées à l'ancienne sélection (fiche, secrets, diagnostic, permissions, présence, inventaire, logiciels, WMI, dernier utilisateur) sont arrêtées.

- Garde-fous : Écritures jamais interrompues ; anciennes données masquées ; secrets effacés à chaque sélection. Rappel d'une ancienne sélection rejeté (Test-DomeniaObjectCallbackIsCurrent).
- Opérations : `OpenAdObject`
- Références D1 : `Domenia-Selection.UI.ps1:Enter-DomeniaSelectionContext`, `Domenia-Selection.UI.ps1:Get-DomeniaSelectionContext`, `Domenia-Selection.UI.ps1:Update-DomeniaSelectionReadUi`, `Domenia-Selection.UI.ps1:Initialize-DomeniaSelectionPreload`, `XAML:LblSelectionReadState`, `Domenia-Core.ps1:Queue-DomeniaSelectedObjectOpen`, `Domenia-Core.ps1:Invoke-DomeniaPendingSelectionOpen`, `Domenia-Core.ps1:Open-SelectedObject`, `Domenia-Core.ps1:Set-DomeniaGridRows`, `Domenia-Core.ps1:Wire-Events (DgObjects)`

#### RCH-130 · Rétablir la sélection après un refus

`fait` · locale (aucune lecture)

Si un changement de sélection est refusé (brouillon, écriture), la ligne d'origine est resélectionnée sans événement.

- Références D1 : `Domenia-Selection.UI.ps1:Restore-DomeniaRefusedSelection`

#### RCH-131 · Diagnostic réseau groupé

`ameliore` · lecture réseau

Pour les postes sélectionnés (50 max), un écho ICMP puis les ports TCP 445, 135, 5985 et 5986, poste après poste ; aperçu des cibles exactes et des lignes exclues avec motif, confirmation en page, rapport tabulé copié et synthèse.

- Garde-fous : Aucun compte envoyé, rien modifié ; arrêt au délai sans résultat partiel ; noms invalides exclus.
- Opérations : `BatchNetworkDiag`
- Références D1 : `Domenia-Core.ps1:Show-DomeniaBatchNetworkReport`, `Domenia-Core.ps1:Complete-DomeniaBatchNetworkReportUi`, `Domenia-Core.ps1:Fail-DomeniaBatchNetworkReportUi`, `Domenia-Core.ps1:Get-DomeniaSelectedMachineRows`

### Vues personnelles

#### RCH-132 · Enregistrer une vue personnelle

`fait` · locale (aucune lecture)

Mémorise OU, profondeur, type, présence, filtre local, limite, colonnes (ordre, largeur) et tri sous un nom unique par domaine (100 vues, 1 Mio).

- Garde-fous : Ni résultats ni mots de passe ; validation stricte (GUID, domaine par RDN, limites) ; retour arrière si l'écriture échoue.
- Références D1 : `Domenia-SearchWorkspace.UI.ps1:Save-DomeniaSearchWorkspace`, `Domenia-SearchWorkspace.Model.ps1:ConvertTo-DomeniaSearchWorkspace`, `Domenia-SearchWorkspace.Model.ps1:Add-DomeniaSearchWorkspaceRecord`, `Domenia-SearchWorkspace.UI.ps1:Get-DomeniaResultPresentation`, `XAML:BtnSearchWorkspaceSave`, `XAML:CmbSearchWorkspace`, `Réglage:Search.WorkspacesJson`, `Domenia-Main.xaml:CmbSearchWorkspace`

#### RCH-133 · Ouvrir une vue personnelle

`fait` · locale (aucune lecture)

Prépare OU, filtres, colonnes et tri sans rien lire ; le tri s'applique à la prochaine liste ; l'opérateur lance ensuite Actualiser ou une requête.

- Garde-fous : Refusé pendant une écriture ou avec une fiche modifiée ; vue inerte.
- Références D1 : `Domenia-SearchWorkspace.UI.ps1:Open-DomeniaSearchWorkspace`, `Domenia-SearchWorkspace.UI.ps1:Restore-DomeniaResultPresentation`, `XAML:BtnSearchWorkspaceOpen`

#### RCH-134 · Retirer une vue et annuler le retrait

`fait` · locale (aucune lecture)

Retire la vue choisie du domaine ; Annuler la restaure tant que les vues n'ont pas changé.

- Garde-fous : Annulation abandonnée si le magasin a changé ; échec d'écriture conserve l'annulation.
- Références D1 : `Domenia-SearchWorkspace.UI.ps1:Remove-DomeniaSearchWorkspace`, `Domenia-SearchWorkspace.UI.ps1:Undo-DomeniaSearchWorkspace`, `Domenia-SearchWorkspace.Model.ps1:Remove-DomeniaSearchWorkspaceRecord`, `XAML:BtnSearchWorkspaceRemove`, `XAML:BtnSearchWorkspaceUndo`

#### RCH-135 · Libellé distinctif des vues

`fait` · locale (aucune lecture)

Chaque vue est listée « nom · OU et sous-OU/seulement · type ».

- Références D1 : `Domenia-SearchWorkspace.Model.ps1:Get-DomeniaSearchWorkspaceLabel`, `Domenia-SearchWorkspace.UI.ps1:Update-DomeniaSearchWorkspaces`

#### RCH-136 · Vues par session et domaine

`fait` · locale (aucune lecture)

Au changement de session, les vues du nouveau domaine sont relues, l'annulation et le tri en attente sont abandonnés, l'aperçu est vidé.

- Références D1 : `Domenia-SearchWorkspace.UI.ps1:Reset-DomeniaSearchWorkspaceSession`

#### RCH-137 · Nom de favori et vue enregistrée en liste blanche (règles non raccordées)

`ameliore` · locale (aucune lecture)

Construit le nom d'une recherche enregistrée à partir de ce qui est visible (« Vue : … », « Domaine entier : … », « OU : texte ») et réduit une vue enregistrée à une liste blanche de champs (nom, texte, type, OU, sous-arbre, limite de 1 à 20 000). Règles écrites et testées, sans appelant dans l'interface de Domenia 1.

- Garde-fous : Aucune fenêtre, aucun compte, aucun droit ni mode écriture dans une vue ; textes aplatis et bornés (80 et 256 caractères).
- Références D1 : `Domenia-Search.Model.ps1:Get-DomeniaFavouriteName`, `Domenia-Search.Model.ps1:ConvertTo-DomeniaSavedView`

<a id="fic"></a>

## Fiche (FIC)

50 fonctions : 23 faites, 27 améliorées.

### Attributs et droits

#### FIC-001 · Écriture brute d'un attribut

`ameliore` · écriture

Une écriture d'attribut brut exige Security.AllowRawAttributeWrite, un nom LDAP valide et, avec Security.BlockSensitiveRawAttributes, que l'attribut ne soit pas dans la liste des attributs sensibles ; la même règle est appliquée par l'interface puis par le worker WriteAttributes.

- Garde-fous : Double contrôle interface + worker ; désactivé par défaut ; raison explicite du refus. La règle est réappliquée dans le worker quoi que fasse l'interface.
- Opérations : `WriteAttributes`
- Références D1 : `modules/Domenia-Safety.Model.ps1:Test-DomeniaRawAttributeAllowed`, `Test-WRawAttributeAllowed (worker)`, `Domenia-Core.ps1:Set-OrClearRawAttribute`, `Domenia-Core.ps1:$script:RawAttributeBlockList`, `Domenia-Core.ps1:Assert-WAttributeChangesAllowed`, `Domenia-Core.ps1:Test-WRawAttributeAllowed`, `Domenia-Main.xaml:BtnRawSet`, `Domenia-Main.xaml:BtnRawClear`, `XAML:TxtRawAttrName`, `XAML:TxtRawAttrValue`

#### FIC-002 · Attributs bruts de l'objet

`fait` · locale (aucune lecture)

Grille Attribut/Valeur de tous les attributs lus, dates converties, binaires en hexadécimal, attributs sensibles exclus, calculée seulement quand l'onglet est affiché ; Copier tout.

- Garde-fous : Test-DomeniaSensitiveAttributeName exclut mots de passe, LAPS, BitLocker, clés.
- Références D1 : `Domenia-Core.ps1:Entry-ToRawAttributes`, `Domenia-Core.ps1:Ensure-DomeniaRawAttributes`, `Domenia-Core.ps1:Copy-RawAttributesToClipboard`, `Domenia-Main.xaml:TabRaw`, `Domenia-Main.xaml:DgRawAttrs`, `Domenia-Main.xaml:BtnRawCopyAll`

#### FIC-003 · Estimation des droits effectifs

`ameliore` · lecture réseau

Lit la DACL et le propriétaire, compare aux SID du jeton (objectSid, tokenGroups, Everyone, Authenticated Users) et rend dix capacités (lecture, modifier, gestion compte, reset mot de passe, groupes, déplacer/renommer, supprimer, créer enfant, secrets, ACL) en Autorisé/Refusé/Indéterminé ; aussi pour une branche ; copie du rapport.

- Garde-fous : Estimation seulement : le DC reste l'autorité finale ; par défaut seul un refus réel du DC verrouille une action.
- Opérations : `PermissionAnalysis`
- Références D1 : `Domenia-Core.ps1:Start-PermissionAnalysis`, `Domenia-Core.ps1:Copy-PermissionReport`, `Domenia-Core.ps1:Ensure-DomeniaPermissions`, `Domenia-Core.ps1:Get-WActiveDirectorySecurity`, `Domenia-Main.xaml:TabPermissions`, `Domenia-Main.xaml:DgPermissions`, `Domenia-Main.xaml:BtnPermissionRefresh`, `Domenia-Main.xaml:BtnPermissionCopy`, `XAML:LblPermissionSummary`

### Droits comparés

#### FIC-004 · Comparaison simple de deux utilisateurs (règle non raccordée)

`ameliore` · locale (aucune lecture)

Compare service, fonction, société, bureau, responsable et groupes directs, avec alerte sur les groupes à privilèges. Règle écrite et testée, non branchée dans l'interface D1.

- Garde-fous : Lecture seule, CanApply=false.
- Références D1 : `Domenia-Directory.Model.ps1:Compare-DomeniaUserAccess`

#### FIC-005 · Droits comparés de deux utilisateurs

`ameliore` · lecture réseau

Compare les groupes directs, imbriqués et principal de l'utilisateur de la fiche et d'un second (identifiant, DOMAINE\compte, UPN ou DN) : seulement chez A, seulement chez B, communs, avec chemin, origine et alerte de privilège.

- Garde-fous : Second compte résolu exactement dans la copie locale ; deux lectures successives bornées ; retour d'une autre fiche/session ignoré ; rien n'est appliqué.
- Opérations : `LocalIndexRead`, `GroupPathRead`
- Références D1 : `Domenia-Membership.UI.ps1:Start-DomeniaUserAccessDiff`, `Domenia-Membership.UI.ps1:Complete-DomeniaUserAccessDiffResolve`, `Domenia-Membership.UI.ps1:Start-DomeniaUserAccessDiffRead`, `Domenia-Membership.UI.ps1:Start-DomeniaUserAccessDiffRight`, `Domenia-Membership.UI.ps1:Complete-DomeniaUserAccessDiffRight`, `Domenia-Directory.Model.ps1:Compare-DomeniaUserGroupAccess`, `Domenia-Directory.Model.ps1:Get-DomeniaUserGroupAccessMap`, `XAML:TxtAccessDiffOther`, `XAML:BtnAccessDiffCompare`, `XAML:DgAccessDiff`, `XAML:LblAccessDiffStatus`, `Domenia-Main.xaml:TabUserAccessDiff`, `Domenia-Main.xaml:DgAccessDiff`

#### FIC-006 · Copier la comparaison pour le ticket

`fait` · locale (aucune lecture)

Texte prêt à coller : deux DN, date, groupes par catégorie avec DN, chemin, principal, privilège, limites.

- Garde-fous : Répète seulement ce qui a été lu, aucun secret.
- Références D1 : `Domenia-Membership.UI.ps1:Copy-DomeniaUserAccessDiffTicket`, `Domenia-Directory.Model.ps1:Format-DomeniaUserAccessDiffTicket`, `XAML:BtnAccessDiffCopy`

### Édition et écritures

#### FIC-007 · Comparer les saisies d'une fiche (brouillon protégé)

`ameliore` · locale (aucune lecture)

À l'ouverture d'une fiche éditable, mémorise ses 29 champs texte et 11 options ; changer de fiche ou la recharger avec des saisies non enregistrées demande confirmation ; si une relecture plus récente arrive, les saisies sont conservées et un bandeau propose « Comparer les saisies » (valeur lue, votre saisie, nouvelle lecture).

- Garde-fous : Aucune saisie remplacée automatiquement ; mots de passe signalés comme modifiés mais jamais reproduits ; brouillon effacé au changement de session et à la fermeture.
- Références D1 : `modules/Domenia-Guard.UI.ps1:Save-DomeniaDraftBaseline`, `modules/Domenia-Guard.UI.ps1:Get-DomeniaDirtyFields`, `modules/Domenia-Guard.UI.ps1:Test-DomeniaDraftNavigation`, `modules/Domenia-Guard.UI.ps1:Keep-DomeniaDraftOnResult`, `modules/Domenia-Guard.UI.ps1:Show-DomeniaDraftComparison`, `modules/Domenia-Guard.Model.ps1:Get-DomeniaDraftFieldMap`, `LblGuardDraft`, `BtnGuardDraft`

#### FIC-008 · Supprimer l'objet

`ameliore` · écriture

Dans « Plus… », suppression non récursive après deux confirmations en page (nom de l'objet puis SUPPRIMER) ; racine du domaine et OU/conteneurs interdits par défaut ; absence relue ; associations locales de l'objet retirées.

- Garde-fous : Capacité Delete, plan confirmé, objet frais et non protégé, Security.AllowContainerDelete=false, RequireTypedDeleteConfirmation, nombre exact d'enfants dans le refus.
- Opérations : `WriteDeleteObject`
- Références D1 : `Domenia-Core.ps1:Delete-SelectedObject`, `Domenia-Core.ps1:Remove-LinksForDeletedObject`, `Domenia-Core.ps1:Get-WChildCount`, `Domenia-Main.xaml:BtnObjectMore`

#### FIC-009 · Édition de fiche avec crayon

`ameliore` · locale (aucune lecture)

« Modifier » ouvre la saisie des seuls champs enregistrables, surligne chaque champ modifié, « Annuler » remet les valeurs lues ; quitter une fiche modifiée signale une fois sur la suivante que les saisies ne sont pas parties.

- Garde-fous : Comparaison sensible à la casse ; comparaison en échec = champs modifiés inconnus.
- Références D1 : `Domenia-Core.ps1:Get-DomeniaFicheEditControls`, `Domenia-Core.ps1:Get-DomeniaFicheDirtyControls`, `Domenia-Core.ps1:Set-DomeniaFicheFieldLock`, `Domenia-Core.ps1:Update-DomeniaFicheEditUi`, `Domenia-Core.ps1:Start-DomeniaFicheEdit`, `Domenia-Core.ps1:Stop-DomeniaFicheEdit`, `Domenia-Core.ps1:Snapshot-DomeniaFicheEdit`, `Domenia-Core.ps1:Register-DomeniaFicheEditWatch`, `Domenia-Main.xaml:BtnUserEdit`, `Domenia-Main.xaml:BtnCompEdit`, `XAML:BtnUserCancelEdit`, `XAML:BtnCompCancelEdit`, `XAML:LblUserEditState`, `XAML:LblCompEditState`

#### FIC-010 · Enregistrer la fiche utilisateur

`fait` · écriture

Écrit givenName, sn, displayName, userPrincipalName, mail, telephoneNumber, physicalDeliveryOfficeName, description, title, department, company et manager ; seuls les champs changés partent, un champ vidé est un effacement explicite.

- Garde-fous : Confirmation en page avec changements en clair, précondition relue sur le DC prévu, écriture conditionnelle, reçu.
- Opérations : `WriteAttributes`
- Références D1 : `Domenia-Core.ps1:Save-UserProfile`, `Domenia-Core.ps1:Start-DomeniaAttributeWrite`, `Domenia-Core.ps1:New-DomeniaAttributeChange`, `Domenia-Core.ps1:Get-DomeniaAttributeWriteStrategy`, `Domenia-Main.xaml:BtnUserSave`

#### FIC-011 · Choisir le responsable

`fait` · lecture réseau

Responsable (manager) d'un utilisateur ou managedBy d'un poste choisi par le sélecteur d'objets du domaine ; la fiche montre un nom, le DN reste interne ; Ouvrir et Retirer apparaissent quand un responsable est posé.

- Garde-fous : Choix local ; écriture seulement à l'enregistrement avec contrôle de fraîcheur.
- Opérations : `EmbeddedDirectoryLookup`
- Références D1 : `Domenia-Core.ps1:Show-DomeniaManagerPicker`, `Domenia-Core.ps1:Set-DomeniaManagerField`, `Domenia-Core.ps1:Clear-DomeniaManagerSelection`, `Domenia-Core.ps1:Open-DomeniaManagerObject`, `Domenia-Core.ps1:Get-DomeniaManagerControls`, `Domenia-Main.xaml:BtnUserManagerPick`, `Domenia-Main.xaml:BtnCompManagedByPick`, `XAML:BtnUserManagerOpen`, `XAML:BtnUserManagerClear`, `XAML:BtnCompManagedByOpen`, `XAML:BtnCompManagedByClear`

#### FIC-012 · Déverrouiller le compte

`fait` · écriture

Remet lockoutTime à zéro et vérifie que le compte n'est plus verrouillé.

- Garde-fous : Capacité Account, plan confirmé, vérification post-écriture.
- Opérations : `WriteUnlock`
- Références D1 : `Domenia-Core.ps1:Unlock-UserAccount`, `Domenia-Main.xaml:BtnUserUnlock`, `Domenia-Main.xaml:BtnUserSupportUnlock`

#### FIC-013 · Activer ou désactiver un compte

`fait` · écriture

Bascule l'état Enabled/Disabled d'un utilisateur ou d'un ordinateur, confirmation renforcée (risque Danger) pour la désactivation, état relu après écriture.

- Garde-fous : Plan, confirmation en page, objets protégés bloqués, vérification.
- Opérations : `WriteAccountDisabled`
- Références D1 : `Domenia-Core.ps1:Set-AccountDisabled`, `Domenia-Main.xaml:BtnUserEnable`, `Domenia-Main.xaml:BtnUserDisable`, `Domenia-Main.xaml:BtnCompEnable`, `Domenia-Main.xaml:BtnCompDisable`

#### FIC-014 · Réinitialiser le mot de passe

`ameliore` · écriture

Nouveau mot de passe et confirmation (révélables), « Déverrouiller ensuite » et « Changement obligatoire » (coché par Security.ForcePasswordChangeOnReset) ; le mot de passe est relu des champs à la confirmation puis effacé.

- Garde-fous : Capacité Password, jamais journalisé ni conservé pendant l'attente, confirmation en page.
- Opérations : `WriteResetPassword`
- Références D1 : `Domenia-Core.ps1:Reset-UserPassword`, `Domenia-Core.ps1:Get-PasswordPair`, `Domenia-Core.ps1:Toggle-PasswordBox`, `Domenia-Main.xaml:PwdUserNew`, `Domenia-Main.xaml:PwdUserConfirm`, `Domenia-Main.xaml:ChkUnlockAfterReset`, `Domenia-Main.xaml:ChkMustChangeAtLogon`, `Domenia-Main.xaml:BtnUserResetPwd`, `XAML:TxtUserNewVisible`, `XAML:BtnRevealUserNew`, `XAML:TxtUserConfirmVisible`, `XAML:BtnRevealUserConfirm`

#### FIC-015 · Options de sécurité du compte (UAC)

`ameliore` · écriture

Mot de passe sans expiration, carte à puce, non délégable ; options avancées : mot de passe non requis, chiffrement réversible, sans pré-authentification, DES, délégation approuvée, délégation contrainte ; seuls les bits changés partent.

- Garde-fous : Options à haut risque : confirmation dédiée et saisie RISQUE (RequireTypedHighRiskConfirmation) ; UAC relu.
- Opérations : `WriteAccountOptions`
- Références D1 : `Domenia-Core.ps1:Apply-UserAccountOptions`, `Domenia-Main.xaml:BtnApplyAccountOptions`, `Domenia-Main.xaml:ExpAccountSecurityOptions`, `XAML:LblAccountSecurityWarning`, `XAML:ChkPwdNeverExpires`, `XAML:ChkSmartcardRequired`, `XAML:ChkAccountNotDelegated`, `XAML:ChkPwdNotRequired`, `XAML:ChkReversiblePwd`, `XAML:ChkNoPreAuth`, `XAML:ChkUseDesOnly`, `XAML:ChkTrustedForDelegation`, `XAML:ChkTrustedToAuthDelegation`

#### FIC-016 · Expiration du compte

`fait` · écriture

Fixer une date d'expiration ou « Jamais », date relue et comparée au jour local.

- Garde-fous : Plan, confirmation, vérification.
- Opérations : `WriteExpiration`
- Références D1 : `Domenia-Core.ps1:Set-UserExpiration`, `Domenia-Main.xaml:DpAccountExpires`, `Domenia-Main.xaml:BtnSetExpiration`, `Domenia-Main.xaml:BtnNeverExpires`

#### FIC-017 · Imposer un nouveau mot de passe

`fait` · écriture

« Expirer le mot de passe » met pwdLastSet à zéro : l'utilisateur devra en choisir un nouveau, l'actuel n'est pas modifié.

- Garde-fous : Plan, confirmation, pwdLastSet relu à zéro.
- Opérations : `WriteExpirePassword`
- Références D1 : `Domenia-Core.ps1:Expire-UserPasswordNow`, `Domenia-Main.xaml:BtnExpirePwdNow`

#### FIC-018 · Déplacer un objet vers une OU

`ameliore` · écriture

Sélecteur d'OU ouvert sur l'OU actuelle, pour un utilisateur, un poste ou une ligne de résultats sans fiche ; cible OU/conteneur du domaine connecté, nouveau DN relu.

- Garde-fous : Identité (DN+GUID) capturée avant le choix et revérifiée, partitions configuration/DNS refusées, capacité Move.
- Opérations : `WriteMoveObject`
- Références D1 : `Domenia-Core.ps1:Move-SelectedObject`, `Domenia-Core.ps1:Move-DomeniaSelectedUserWithOuPicker`, `Domenia-Core.ps1:Move-DomeniaSelectedComputerWithOuPicker`, `Domenia-Core.ps1:Show-DomeniaOuPicker`, `Domenia-Core.ps1:Search-DomeniaOuPickerObjects`, `Domenia-Core.ps1:Get-DomeniaRowMoveSafety`, `Domenia-Main.xaml:BtnUserMove`, `Domenia-Main.xaml:BtnCompMove`

#### FIC-019 · Ajouter ou retirer d'un groupe

`fait` · écriture

Depuis la fiche utilisateur ou poste, ajoute ou retire l'appartenance directe à un groupe saisi (nom ou DN), vérifiée après écriture.

- Garde-fous : Groupe protégé bloqué, DN du domaine connecté, ambiguïté refusée (2 résultats), retrait en risque Danger.
- Opérations : `WriteObjectGroup`
- Références D1 : `Domenia-Core.ps1:AddOrRemoveObjectGroup`, `Domenia-Core.ps1:Resolve-WGroupDn`, `Domenia-Core.ps1:Test-WDirectMembership`, `Domenia-Main.xaml:TxtUserGroupTarget`, `Domenia-Main.xaml:BtnUserAddGroup`, `Domenia-Main.xaml:TxtCompGroupTarget`, `XAML:BtnUserRemoveGroup`

#### FIC-020 · Créer une unité d'organisation

`fait` · écriture

Onglet OU : la branche parente réellement visée est affichée, le nom est validé et l'unicité vérifiée ; la protection contre la suppression accidentelle n'est posée que par la voie module AD.

- Garde-fous : DN parent figé avant confirmation et revérifié à l'envoi, capacité Create.
- Opérations : `WriteCreateOu`
- Références D1 : `Domenia-Core.ps1:Create-OuUnderSelected`, `Domenia-Core.ps1:Update-DomeniaNewOuParentUi`, `Domenia-Core.ps1:Fill-ContainerObject`, `Domenia-Main.xaml:TabContainer`, `Domenia-Main.xaml:BtnCreateOu`, `XAML:TxtNewOuParent`, `XAML:TxtNewOuName`

### Groupes et appartenances

#### FIC-021 · Chemin et réponse d'appartenance

`fait` · locale (aucune lecture)

Parcours en largeur des arêtes memberOf (16 niveaux, 5 000 nœuds, cycles) et réponse : membre confirmé par le contrôleur, chemin trouvé, indéterminé si tronqué, ou aucun chemin dans les lectures.

- Garde-fous : Une lecture tronquée ne conclut jamais à l'absence.
- Opérations : `GroupPathRead`
- Références D1 : `Domenia-Directory.Model.ps1:Find-DomeniaMembershipPath`, `Domenia-Directory.Model.ps1:Resolve-DomeniaMembershipAnswer`, `Domenia-Directory.Model.ps1:Get-DomeniaPrimaryGroupSid`

#### FIC-022 · Modification des groupes en delta (règle non raccordée)

`ameliore` · écriture

Ne produit que les ajouts et retraits choisis (contradictions ignorées, déjà membre ou non membre revérifiés), puis vérifie chaque effet relu sur le contrôleur (Vérifié, Échec, À vérifier, Partiel).

- Garde-fous : Jamais de réécriture de la liste complète ; post-condition relue.
- Opérations : `WriteObjectGroup`, `WriteGroupMember`
- Références D1 : `Domenia-Directory.Model.ps1:New-DomeniaGroupDelta`, `Domenia-Directory.Model.ps1:Test-DomeniaGroupDeltaPostcondition`

#### FIC-023 · Grilles d'appartenance lisibles

`ameliore` · locale (aucune lecture)

Groupes de l'objet et membres d'un groupe en Nom, Type, OU (DN en info-bulle), 2 000 lignes max avec total et note de lecture partielle.

- Garde-fous : Type jamais deviné d'après un nom ; nouvel objet = filtre et groupes imbriqués réinitialisés.
- Références D1 : `Domenia-Membership.UI.ps1:Set-DomeniaMembershipList`, `Domenia-Membership.UI.ps1:Clear-DomeniaMembershipLists`, `Domenia-Directory.Model.ps1:ConvertTo-DomeniaMembershipRows`, `XAML:DgMemberOf`, `XAML:DgGroupMembers`, `XAML:LblMemberOf`, `XAML:LblGroupMembers`, `Domenia-Main.xaml:TabMemberOf`, `Domenia-Main.xaml:DgMemberOf`

#### FIC-024 · Type des membres depuis la copie locale

`fait` · lecture locale

Le type et le nom des membres d'un groupe affiché dans une fiche sont résolus par DN exact dans l'index local : 2000 au plus, par paquets de 200.

- Garde-fous : Aucune requête AD ; 2 000 DN, 30 s. Lecture seule.
- Opérations : `LocalIndexRead`
- Références D1 : `Domenia-Membership.UI.ps1:Start-DomeniaMembershipTypes`, `Domenia-Membership.UI.ps1:Complete-DomeniaMembershipTypes`, `Domenia-Membership.UI.ps1:Fail-DomeniaMembershipTypes`, `Domenia-Engine.Worker.ps1:Get-DomeniaLocalIndexReadWorkerCode (ResolveNames)`

#### FIC-025 · Filtre local des appartenances

`ameliore` · locale (aucune lecture)

Chaque mot doit figurer dans nom, type, OU, DN, appartenance ou via ; compteur directs, imbriqués lus, affichés après filtre.

- Garde-fous : Aucune requête ; 120 caractères.
- Références D1 : `Domenia-Membership.UI.ps1:Update-DomeniaMembershipFilter`, `Domenia-Directory.Model.ps1:Test-DomeniaMembershipRow`, `XAML:TxtMemberOfFilter`, `XAML:TxtGroupMembersFilter`

#### FIC-026 · Groupes imbriqués à la demande

`fait` · lecture réseau

Lit les groupes atteints par imbrication (2 000 groupes, 16 niveaux, 10 s, 40 DN par requête) et les ajoute avec profondeur et groupe direct « via » ; groupes non lus et groupe principal expliqués.

- Garde-fous : Geste explicite ; fiche changée = refus ; jamais de recherche sur tout le domaine.
- Opérations : `GroupPathRead`
- Références D1 : `Domenia-Membership.UI.ps1:Start-DomeniaMembershipPathRead`, `Domenia-Membership.UI.ps1:Complete-DomeniaMembershipPathRead`, `Domenia-Membership.UI.ps1:Add-DomeniaNestedMembershipRows`, `Domenia-Membership.UI.ps1:Format-DomeniaNestedMembershipSummary`, `Domenia-Directory.Model.ps1:Get-DomeniaNestedMembershipRows`, `Domenia-Directory.Model.ps1:ConvertTo-DomeniaGroupPathEdges`, `Domenia-Directory.Model.ps1:ConvertTo-DomeniaMembershipEdges`, `XAML:BtnMemberOfNested`, `Domenia-Main.xaml:BtnMemberOfNested`

#### FIC-027 · Pourquoi membre ?

`ameliore` · lecture réseau

Explique l'appartenance à un groupe : directe (attribut member), chemin d'imbrication « A → B → C (n niveaux) », ou réponse transitive du contrôleur ; indéterminé si lecture incomplète.

- Garde-fous : Lecture seulement si nécessaire ; groupe principal et autres domaines non couverts signalés.
- Opérations : `GroupPathRead`
- Références D1 : `Domenia-Membership.UI.ps1:Invoke-DomeniaMembershipWhy`, `Domenia-Membership.UI.ps1:Show-DomeniaMembershipWhy`, `Domenia-Directory.Model.ps1:Get-DomeniaMembershipWhy`, `XAML:LblMembershipWhy`

#### FIC-028 · Menus contextuels des appartenances

`fait` · locale (aucune lecture)

Rechercher cet objet, Copier le DN, Pourquoi membre ?, Afficher les groupes imbriqués.

- Opérations : `GlobalSearch`, `GroupPathRead`
- Références D1 : `Domenia-Membership.UI.ps1:Register-DomeniaMembershipUi`, `Domenia-Membership.UI.ps1:Get-DomeniaSelectedMembershipRow`, `Start-DomeniaSearchFor`

#### FIC-029 · Fiche groupe et membres

`ameliore` · écriture

Nom, description enregistrable, membres lus par plages (jusqu'à 50 000, 2 000 affichés avec le total et le motif d'une lecture partielle), ajout et retrait de membre.

- Garde-fous : Membre DN du domaine, groupe protégé bloqué, vérification d'appartenance directe.
- Opérations : `OpenAdObject`, `WriteAttributes`, `WriteGroupMember`
- Références D1 : `Domenia-Core.ps1:Fill-GroupObject`, `Domenia-Core.ps1:Save-GroupProfile`, `Domenia-Core.ps1:AddOrRemoveGroupMember`, `Domenia-Core.ps1:Get-DomeniaMembershipLabel`, `Domenia-Main.xaml:TabGroup`, `Domenia-Main.xaml:DgGroupMembers`, `XAML:TxtGroupName`, `XAML:TxtGroupDescription`, `XAML:BtnGroupSave`, `XAML:TxtGroupMemberTarget`, `XAML:BtnGroupAddMember`, `XAML:BtnGroupRemoveMember`

### Lecture de la fiche

#### FIC-030 · Aperçu local d'une fiche

`fait` · lecture locale

À l'ouverture d'une fiche, la version stockée dans la base locale est affichée tout de suite, sans sondes distantes, avec sa date. La lecture AD la remplace ensuite. Une erreur de lecture différée n'est présentée qu'après la fin de l'aperçu.

- Garde-fous : Identité vérifiée (DN, GUID attendu) et une ligne exactement. Marquée ShowingCachedObject : aucune écriture ni sonde.
- Opérations : `LocalStore`
- Références D1 : `Domenia-LocalPreview.UI.ps1:Request-DomeniaLocalObjectPreview`, `Domenia-LocalPreview.UI.ps1:Complete-DomeniaLocalObjectPreview`, `Domenia-LocalPreview.UI.ps1:Complete-DomeniaLocalObjectPreviewWait`, `Domenia-LocalPreview.UI.ps1:Fail-DomeniaLocalObjectPreview`

#### FIC-031 · Rafraîchissement partiel de la fiche

`ameliore` · locale (aucune lecture)

À la relecture, si seuls des champs d'affichage simples ont changé (prénom, nom, mail, téléphone, bureau, adresse, description, OS…), seuls ces champs sont mis à jour. Si rien n'a changé, la fiche n'est pas redessinée. L'identité, l'état du compte, les appartenances et les liens prennent toujours le chemin complet.

- Garde-fous : Une forme inconnue entraîne un rendu complet. Les propriétés sensibles sont retirées avant la comparaison.
- Références D1 : `Domenia-LocalPreview.UI.ps1:Get-DomeniaObjectPresentationDelta`, `Domenia-LocalPreview.UI.ps1:Test-DomeniaObjectPresentationUnchanged`, `Remove-DomeniaSensitiveProperties`

#### FIC-032 · Pages Fiche et Poste vides

`ameliore` · locale (aucune lecture)

Sans sujet, Fiche et Poste restent ouvertes et proposent un champ de recherche et les dernières fiches (ou les derniers postes) de la mémoire locale. Un clic recopie le nom, et Entrée lance la recherche globale.

- Garde-fous : Rien n'est lu avant Entrée.
- Références D1 : `Domenia-UX.UI.ps1:Initialize-DomeniaUxEmptyStates`, `Domenia-UX.UI.ps1:Update-DomeniaUxEmptyStates`, `Domenia-UX.UI.ps1:Invoke-DomeniaUxEmptySearch`, `ObjectEmptyState`, `ComputerEmptyState`, `TxtObjectEmptySearch`, `LstObjectEmptyRecent`, `LblObjectEmptyRecentNone`, `TxtComputerEmptySearch`, `LstComputerEmptyRecent`, `Domenia-Main.xaml:LstComputerEmptyRecent`, `XAML:LblObjectEmptyTitle`, `XAML:LblComputerEmptyTitle`, `XAML:LblComputerEmptyRecentNone`

#### FIC-033 · Contrôle d'identité du résultat lu

`ameliore` · locale (aucune lecture)

La fiche lue doit avoir le DN et le GUID attendus et celui capturé à la sélection ; sinon « objet remplacé depuis la recherche, actualisez la liste ».

- Garde-fous : Fiche indisponible sans GUID valide.
- Opérations : `OpenAdObject`
- Références D1 : `Domenia-Selection.UI.ps1:Assert-DomeniaObjectResultIdentity`, `Domenia-Selection.UI.ps1:Get-DomeniaObjectResultGuid`, `Domenia-Selection.UI.ps1:Test-DomeniaSelectionLoadCurrent`

#### FIC-034 · Réessayer la lecture AD de la fiche

`fait` · lecture réseau

Relance seulement la lecture AD de l'objet sélectionné après un échec.

- Garde-fous : Ne répète ni ping, ni CIM, ni écriture ; désactivé pendant une écriture.
- Opérations : `OpenAdObject`
- Références D1 : `Domenia-Selection.UI.ps1:Retry-DomeniaSelectedObjectRead`, `XAML:BtnObjectReadRetry`, `XAML:BtnComputerReadRetry`, `XAML:LblObjectReadStatus`, `XAML:LblComputerReadStatus`

#### FIC-035 · Fiche affichée depuis la relecture locale

`fait` · lecture locale

La fiche s'affiche à partir de la ligne relue en SQLite (révision, source démo signalée), avec contrôle d'identité.

- Garde-fous : Échec d'affichage ne laisse pas la requête « en cours » ni les contrôles d'écriture actifs.
- Opérations : `OpenAdObject`, `LocalStore`
- Références D1 : `Domenia-DirectoryStore.UI.ps1:Submit-DomeniaDirectoryObjectRead`, `Domenia-DirectoryStore.UI.ps1:Complete-DomeniaDirectoryObjectCommit`, `Domenia-DirectoryStore.UI.ps1:Fail-DomeniaDirectoryObjectCommit`

#### FIC-036 · Fraîcheur par nature de donnée

`ameliore` · locale (aucune lecture)

Chaque nature a sa durée de validité : identité AD 24 h, attributs AD 15 min, présence réseau 2 min, session console 5 min, historique sans expiration. Le libellé donne la date, « (à relire) » ou « jamais observé », et la dernière tentative si elle est plus récente. Les durées peuvent venir du profil d'usage, et une tentative échouée ne rajeunit jamais une observation.

- Garde-fous : Une date illisible donne un état inconnu, jamais frais.
- Références D1 : `Domenia-Cache.Model.ps1:Get-DomeniaDataNatures`, `Domenia-Cache.Model.ps1:Get-DomeniaFreshnessPolicy`, `Domenia-Cache.Model.ps1:Get-DomeniaFreshness`, `Domenia-Cache.Model.ps1:Get-DomeniaObservationTimes`, `Domenia-Cache.Model.ps1:Copy-DomeniaObservationTimes`, `Domenia-Cache.Model.ps1:Set-DomeniaObservationTime`, `Domenia-Cache.Model.ps1:Get-DomeniaRecordFreshness`

#### FIC-037 · Invalidation ciblée du cache de visite

`ameliore` · locale (aucune lecture)

Quand un objet change, seules ses lectures en cache sont oubliées : toutes les clés portant son GUID (avec ou sans tirets), ou son DN à défaut de GUID. Les autres objets et listes restent en cache.

- Garde-fous : Renvoie le nombre d'entrées retirées.
- Références D1 : `Domenia-Continuity.UI.ps1:Clear-DomeniaVisitCacheForObject`

#### FIC-038 · Ouverture d'un objet AD

`ameliore` · lecture réseau

Lit l'objet dans un worker avec une liste d'attributs sûrs, affiche d'abord la projection locale SQLite puis la lecture fraîche, choisit les onglets selon le type et la page d'atterrissage (Utilisateur, Vue d'ensemble poste, Groupe, OU, Résumé).

- Garde-fous : Identité du résultat vérifiée (GUID attendu) ; lecture partagée si identique ; brouillon de fiche en cours protégé avant navigation.
- Opérations : `OpenAdObject`, `LocalIndexRead`
- Références D1 : `Domenia-Core.ps1:Open-AdObject`, `Domenia-Core.ps1:Show-AdObjectResult`, `Domenia-Core.ps1:Complete-DomeniaOpenObjectUi`, `Domenia-Core.ps1:Fail-DomeniaOpenObjectUi`, `Domenia-Core.ps1:Get-DomeniaSafeObjectPropertyNames`, `Domenia-Core.ps1:Set-VisibleTabsForType`, `Domenia-Core.ps1:Get-DomeniaLandingView`, `Domenia-Core.ps1:Select-DomeniaWorkspace`, `XAML:DetailTabs`, `XAML:WsObject`, `XAML:TabUserAdmin`

#### FIC-039 · Onglet Résumé

`ameliore` · lecture réseau

Type, Nom, Classe, GUID, Créé, Modifié, DN, Présence et cible de présence ; menu du DN (Copier le DN, Copier le nom, Ouvrir le parent), Copier le résumé, Ouvrir le parent, Relire depuis l'annuaire.

- Garde-fous : Relire ne vide que le cache de cet objet (GUID ou DN), jamais la liste.
- Opérations : `OpenAdObject`
- Références D1 : `Domenia-Main.xaml:TabGeneric`, `Domenia-Core.ps1:Fill-GenericObject`, `Domenia-Core.ps1:Copy-ObjectSummary`, `Domenia-Core.ps1:Open-SelectedParentBranch`, `Domenia-Core.ps1:Refresh-SelectedObject`, `Domenia-Core.ps1:Wire-Events (TxtObjDn)`, `XAML:TxtObjType`, `XAML:TxtObjName`, `XAML:TxtObjClass`, `XAML:TxtObjGuid`, `XAML:TxtObjCreated`, `XAML:TxtObjChanged`, `XAML:TxtObjPresenceTarget`, `XAML:BtnCopyObjectSummary`, `XAML:BtnOpenParentBranch`, `XAML:BtnObjectReread`, `XAML:LblObjClass`, `XAML:LblObjGuid`

### Utilisateur

#### FIC-040 · Lire les verrouillages du compte (événements 4740)

`ameliore` · lecture réseau

Sur geste explicite, lit dans le journal Sécurité de l'émulateur PDC (résolu par fSMORoleOwner, sinon le contrôleur lié, ce qui est dit) les événements 4740 du seul SID du compte sur 7 jours, puis affiche chaque verrouillage (heure, poste à l'origine, refus de Domenia juste avant) et les faits « Postes à l'origine » et « Refus de Domenia avant un verrouillage ». Bouton dans la fiche Utilisateur.

- Garde-fous : Jamais de balayage du domaine ; SID validé (S-1-5-21…) ; fenêtre 1–720 h (168 par défaut), 200 événements max (≤ 500), troncature signalée ; un refus de lecture ne prouve pas l'absence de verrouillage (droit « Lecteurs des journaux d'événements » rappelé) ; résultat d'un autre compte ou d'une fiche rechargée ignoré ; refus d'authentification enregistrés par la garde. Journal lu sur demande explicite ; refus ou indisponibilité ≠ aucun verrouillage.
- Opérations : `LockoutDiagnosis`
- Références D1 : `modules/Domenia-Lockout.UI.ps1:Start-DomeniaLockoutEventRead`, `modules/Domenia-Lockout.UI.ps1:Complete-DomeniaLockoutEventRead`, `modules/Domenia-Lockout.UI.ps1:Fail-DomeniaLockoutEventRead`, `modules/Domenia-Lockout.UI.ps1:Format-DomeniaLockoutReport`, `modules/Domenia-Lockout.UI.ps1:Show-DomeniaLockoutText`, `modules/Domenia-Lockout.Worker.ps1:Get-DomeniaLockoutEventWorkerCode`, `modules/Domenia-Directory.Model.ps1:Get-DomeniaLockoutDiagnosis`, `BtnUserSupportLockouts`, `TxtUserSupportLockouts`, `palette:lockouts`, `Domenia-Directory.Model.ps1:Get-DomeniaLockoutDiagnosis`, `Domenia-Lockout.UI.ps1`

#### FIC-041 · Activité de connexion approximative expliquée (utilisateur)

`fait` · locale (aucune lecture)

À l'ouverture de la fiche, explique lastLogonTimestamp déjà chargé : date approximative répliquée, mise à jour seulement quand elle a plus de « intervalle − 5 jours » (14 jours par défaut), ne prouve pas une présence ; une valeur vide ne prouve pas l'absence de connexion ; une date future signale une horloge à vérifier.

- Garde-fous : Aucune lecture : seule la valeur déjà chargée est expliquée.
- Références D1 : `modules/Domenia-LogonActivity.UI.ps1:Update-DomeniaLogonActivityPanel`, `modules/Domenia-LogonActivity.Model.ps1:Get-DomeniaLogonActivitySummary`, `modules/Domenia-LogonActivity.Model.ps1:Get-DomeniaLogonLagText`, `modules/Domenia-LogonActivity.Model.ps1:Get-DomeniaLogonSyncInterval`, `TxtUserLogonByDc`, `TxtUserLastLogon`

#### FIC-042 · Lire la connexion exacte sur chaque contrôleur (utilisateur)

`ameliore` · lecture réseau

Sur geste explicite et pour l'objet ouvert seulement, lit lastLogon (et logonCount) sur chaque contrôleur du domaine (RWDC et RODC) et msDS-LogonTimeSyncInterval sur la tête du domaine, puis donne la connexion la plus récente, la couverture « n lus sur m recensés », les contrôleurs non lus et le retard de lastLogonTimestamp.

- Garde-fous : 50 contrôleurs max, budget 75 s (10–120), limites 8 s serveur / 12 s client par DC, délai global 150 s ; un bail d'authentification par bind ; « dernière connexion du domaine » affirmée seulement si tous les DC recensés ont répondu ; indisponible en démonstration ; objet recherché par GUID ; résultat d'une fiche rechargée ignoré ; 50 lignes affichées max.
- Opérations : `LogonByDcRead`
- Références D1 : `modules/Domenia-LogonActivity.UI.ps1:Start-DomeniaLogonByDcRead`, `modules/Domenia-LogonActivity.UI.ps1:Complete-DomeniaLogonByDcRead`, `modules/Domenia-LogonActivity.UI.ps1:Fail-DomeniaLogonByDcRead`, `modules/Domenia-LogonActivity.Worker.ps1:Get-DomeniaLogonByDcWorkerCode`, `modules/Domenia-LogonActivity.Model.ps1:Merge-DomeniaLogonReadings`, `modules/Domenia-LogonActivity.Model.ps1:Format-DomeniaLogonReadingsText`, `BtnUserLogonByDc`, `TxtUserLogonByDc`

#### FIC-043 · État du compte calculé

`fait` · locale (aucune lecture)

Désactivé, verrouillé et mot de passe expiré selon msDS-User-Account-Control-Computed ; « verrouillage à vérifier » si seul lockoutTime est lu ; options n'expire jamais, carte à puce, mot de passe non requis.

- Garde-fous : État non déterminé si userAccountControl illisible.
- Références D1 : `Domenia-Directory.Model.ps1:Get-DomeniaAccountState`

#### FIC-044 · Résumé support d'un utilisateur

`ameliore` · locale (aucune lecture)

Faits datés par rubrique : identité, service (service, fonction, société, bureau, responsable), contact, état et expiration du compte, création, mot de passe, dernière ouverture approximative.

- Garde-fous : Chaque fait porte source, lecteur, date et limite (réplication 14 jours).
- Opérations : `OpenAdObject`
- Références D1 : `Domenia-Directory.Model.ps1:Get-DomeniaUserSupportSummary`, `Domenia-Core.ps1`

#### FIC-045 · Refus Domenia juste avant un verrouillage

`fait` · locale (aucune lecture)

Rapproche chaque événement 4740 des refus d'authentification enregistrés par Domenia pour ce compte (120 s, 5 s de décalage toléré) : piste à vérifier.

- Garde-fous : Jamais une preuve ; refus non attribué signalé comme tel.
- Opérations : `LockoutDiagnosis`
- Références D1 : `Domenia-Directory.Model.ps1:Get-DomeniaLockoutTimeline`, `Domenia-Directory.Model.ps1:ConvertTo-DomeniaLockoutUtc`

#### FIC-046 · Présence d'un utilisateur via son poste associé

`ameliore` · lecture réseau

Un compte n'ayant pas d'adresse, la présence est testée sur le poste associé le plus fiable (affectation déclarée puis relation la plus récente), sans pinger les postes d'un ancien titulaire du login ; le résultat est stocké sous le GUID du poste.

- Garde-fous : Associations illisibles : présence inconnue, pas « aucun poste ».
- Opérations : `SelectedPresence`
- Références D1 : `Domenia-Core.ps1:Update-DomeniaSelectedUserPresence`, `Domenia-Core.ps1:Start-DomeniaSelectedMachinePresence`, `Domenia-Core.ps1:Get-DomeniaSelectedPresenceWorkerCode`

#### FIC-047 · Fiche utilisateur

`fait` · lecture réseau

Prénom, nom, nom affiché, sAMAccountName, UPN, mail, téléphone, bureau, description, fonction, service, société, responsable, présence, état, dernière connexion (approximative, lecture par contrôleur proposée), dernier changement de mot de passe, expiration, options UAC lisibles, postes associés avec « Ouvrir le poste ».

- Garde-fous : Un compte recréé sous un ancien login n'hérite pas des postes de l'ancien ; bits UAC inconnus montrés en hexadécimal.
- Opérations : `OpenAdObject`, `LogonByDcRead`
- Références D1 : `Domenia-Core.ps1:Fill-UserObject`, `Domenia-Core.ps1:Get-UacStatusLabel`, `Domenia-Core.ps1:Get-UacFlagsLabel`, `Domenia-Core.ps1:Open-LinkedComputerFromUser`, `Domenia-Main.xaml:TabUser`, `Domenia-Main.xaml:TxtUserLinkedComputers`, `Domenia-Main.xaml:BtnOpenLinkedComputer`, `Domenia-Main.xaml:BtnUserLogonByDc`, `XAML:LblUserLinkSummary`, `XAML:TxtUserGivenName`, `XAML:TxtUserSurname`, `XAML:TxtUserDisplayName`, `XAML:TxtUserSam`, `XAML:TxtUserUpn`, `XAML:TxtUserMail`, `XAML:TxtUserPhone`, `XAML:TxtUserOffice`, `XAML:TxtUserDescription`, `XAML:TxtUserTitle`, `XAML:TxtUserDepartment`, `XAML:TxtUserCompany`, `XAML:TxtUserManager`, `XAML:TxtUserState`, `XAML:TxtUserPwdLastSet`, `XAML:TxtUserExpires`, `XAML:TxtUserUac`

#### FIC-048 · Bandeau support du compte

`ameliore` · lecture réseau

Annonce uniquement ce que le contrôleur a répondu : verrouillé depuis, état non confirmé, mot de passe expiré ou expirant sous 14 jours, mauvais mots de passe, verrouillage récent levé ; boutons « Déverrouiller maintenant » et « Lire les verrouillages (4740) » quand pertinent.

- Garde-fous : Limites dites (compteur non répliqué, stratégie non lue) ; bandeau masqué s'il ne peut se construire.
- Opérations : `LockoutDiagnosis`
- Références D1 : `Domenia-Core.ps1:Update-DomeniaUserSupportBand`, `Domenia-Main.xaml:PnlUserSupportBand`, `Domenia-Main.xaml:BtnUserSupportUnlock`, `Domenia-Main.xaml:BtnUserSupportLockouts`, `XAML:TxtUserSupportBand`, `XAML:TxtUserSupportDetail`

#### FIC-049 · Coordonnées et profil utilisateur

`fait` · écriture

Onglet Coordonnées : adresse, ville, région, code postal, pays, téléphones domicile/mobile/fax/IP, page web, matricule, chemin de profil, script de connexion, dossier de base et lecteur, postes autorisés ; enregistrement par le même canal.

- Garde-fous : Capacité Edit, plan et confirmation.
- Opérations : `WriteAttributes`
- Références D1 : `Domenia-Core.ps1:Fill-DomeniaUserContact`, `Domenia-Core.ps1:Save-DomeniaUserContact`, `Domenia-Main.xaml:TabUserContact`, `Domenia-Main.xaml:BtnUserSaveContact`, `XAML:TxtUserStreet`, `XAML:TxtUserCity`, `XAML:TxtUserState2`, `XAML:TxtUserPostalCode`, `XAML:TxtUserCountry`, `XAML:TxtUserHomePhone`, `XAML:TxtUserMobile`, `XAML:TxtUserFax`, `XAML:TxtUserIpPhone`, `XAML:TxtUserWebPage`, `XAML:TxtUserEmployeeId`, `XAML:TxtUserProfilePath`, `XAML:TxtUserScriptPath`, `XAML:TxtUserHomeDirectory`, `XAML:TxtUserHomeDrive`, `XAML:TxtUserWorkstations`

#### FIC-050 · Générer un mot de passe temporaire

`fait` · locale (aucune lecture)

Mot de passe de 16 caractères (14 à 64) tiré par générateur cryptographique, quatre classes obligatoires, sans caractères ambigus (0/O, 1/l/I), mélangé, injecté dans les champs existants pour être lu une fois.

- Garde-fous : Passe par la même confirmation que la saisie.
- Références D1 : `Domenia-Core.ps1:New-DomeniaTemporaryPassword`, `Domenia-Core.ps1:Get-DomeniaRandomBelow`, `Domenia-Core.ps1:Show-DomeniaGeneratedPassword`, `Domenia-Main.xaml:BtnUserGenPassword`

<a id="cpt"></a>

## Comptes (CPT)

21 fonctions : 9 faites, 7 améliorées, 5 partielles.

### Accès

#### CPT-001 · Bouton Accès et accès à revoir

> Reste à faire : Emplacement « Accès » de la barre du haut alimenté par ctx.access.report (docs/SHELL.md § 9) à chaque relecture de l’écran Comptes, clic vers Comptes ; pastille de l’en-tête de l’écran (badge, info-bulle, clic qui ouvre la plus ancienne demande) et onglet Accès faits. Reste au shell, à l’intégration : relire accounts.access.revision (local, 2 s) hors de l’écran Comptes.

`partiel` · locale (aucune lecture)

Badge du nombre d'accès refusés en attente (16 max, un par ressource et cible) et info-bulle ; clic pour traiter la plus ancienne demande.

- Garde-fous : Aucune erreur brute, charge utile ni compte stockés ; refus local (fichier) non proposé.
- Références D1 : `Domenia-Access.UI.ps1:Update-DomeniaAccessButton`, `Domenia-Access.UI.ps1:Request-DomeniaAccessRecovery`, `Domenia-Access.UI.ps1:Initialize-DomeniaAccess`, `XAML:BtnAccessRecovery`, `XAML:LblAccessRecoveryCount`, `XAML:BadgeAccessRecovery`, `Domenia-Main.xaml:BtnAccessRecovery`

#### CPT-002 · Utiliser un autre compte après un refus

`ameliore` · lecture réseau

Question puis panneau « Utiliser un autre compte » : DOMAINE\compte ou compte@domaine, ou POSTE\compte pour le poste ; un seul essai de validation (AD ou CIM/DCOM, 14 s).

- Garde-fous : Refusé pendant une écriture ; annulation garde le compte actuel ; mot de passe ni journalisé ni enregistré ; validation ≠ droits garantis.
- Opérations : `RemoteCredentialCheck`
- Références D1 : `Domenia-Access.UI.ps1:Invoke-DomeniaAccessRecovery`, `Domenia-Access.UI.ps1:Show-DomeniaAlternateCredential`, `Start-DomeniaRemoteCredentialSession`, `Start-DomeniaLoginAuthRunspace`

#### CPT-003 · Contrôle du contexte d'un compte proposé

`fait` · locale (aucune lecture)

Un compte local n'est accepté que pour son poste et jamais pour l'annuaire, LAPS ou BitLocker ; un compte d'un autre poste ou domaine inconnu est refusé avant tout appel.

- Garde-fous : Aucun essai envoyé si invalide.
- Références D1 : `Domenia-Access.Model.ps1:Test-DomeniaCredentialContext`, `Domenia-Access.Model.ps1:Get-DomeniaCredentialScope`, `Domenia-Access.Model.ps1:ConvertTo-DomeniaMachineKey`, `Domenia-Access.Model.ps1:Test-DomeniaLocalAccountName`, `Domenia-Access.Model.ps1:Set-DomeniaScopeAccount`

#### CPT-004 · Durée de vie des comptes temporaires

`fait` · locale (aucune lecture)

Bail par inactivité (30 min par défaut, 1 à 480, mesuré depuis le dernier départ de worker), par session ou à usage unique ; balayage régulier.

- Garde-fous : Expiration appliquée même pendant une écriture ; un travail parti garde sa copie ; une lecture passive ne prolonge pas.
- Références D1 : `Domenia-Access.Model.ps1:New-DomeniaCredentialLease`, `Domenia-Access.Model.ps1:Test-DomeniaCredentialLease`, `Domenia-Access.Model.ps1:Use-DomeniaCredentialLease`, `Domenia-Access.Model.ps1:Clear-DomeniaCredentialLease`, `Domenia-Access.UI.ps1:Invoke-DomeniaAccessLeaseSweep`, `Domenia-Access.UI.ps1:Test-DomeniaAccessLeaseUsable`, `Domenia-Access.UI.ps1:Use-DomeniaAccessLease`, `Domenia-Access.UI.ps1:Get-DomeniaAccessIdleMinutes`, `Réglage:Security.AlternateCredentialIdleMinutes`

#### CPT-005 · Consulter et oublier les comptes temporaires

`fait` · locale (aucune lecture)

Sans demande en attente, le bouton Accès liste les comptes temporaires actifs et propose de les oublier tous.

- Garde-fous : Confirmation ; refusé pendant une écriture ; génération de compte incrémentée.
- Références D1 : `Domenia-Access.UI.ps1:Initialize-DomeniaAccess`, `Domenia-Access.UI.ps1:Clear-DomeniaAccessAccounts`, `Domenia-Access.UI.ps1:Remove-DomeniaAccessCredential`

### Compte de connexion

#### CPT-006 · Carte Annuaire en lecture seule

`ameliore` · locale (aucune lecture)

Affiche l'identité qui s'est réellement liée (BindUser), le mode (session Windows, compte saisi, démonstration), le contrôleur et le domaine ; sans connexion, « Aucune identité active » et renvoi vers « Changer de compte ». Aucun champ n'est éditable.

- Garde-fous : Identité en lecture seule : un autre compte passe obligatoirement par « Changer de compte ». Ne réécrit jamais les champs en cours de saisie.
- Références D1 : `modules/Domenia-Accounts.Model.ps1:Get-DomeniaDirectoryAccountText`, `LblAccountAdIdentity`, `LblAccountAdStatus`, `Domenia-Core.ps1 l.18371`, `Domenia-Core.ps1:Update-DomeniaAccountUi`, `Domenia-Core.ps1:Initialize-DomeniaAccountPanel`, `Domenia-Main.xaml:TabAccounts`, `Domenia-Main.xaml:BtnAccountAdCorrect`, `Domenia-Main.xaml:PwdAccountAdCorrection`

#### CPT-007 · Changer de compte sans fermer Domenia

> Reste à faire : Changer de compte fait en simulation (validation unique, nouvelle époque, comptes, accès, pauses et refus oubliés, formulaire prérempli, écran relu). Relecture de la barre supérieure sur domenia:session-changed par le shell ; ouverture réelle de la session par Domenia.Ad (IAccountsAccessReader.OpenSessionAsync, vague 3).

`partiel` · lecture réseau

Sauvegarde les données en attente, purge vues, grilles, observations et cibles de la session, rouvre le formulaire prérempli avec le compte courant puis ouvre la base du domaine de la nouvelle session.

- Garde-fous : Annulation sans effet ; nouvelle époque de session à la validation (tout résultat ancien ignoré). Aucune référence de l'ancienne base ne survit ; rien n'est écrit dans les réglages.
- Opérations : `LocalIndexRead`
- Références D1 : `BtnAccountAdRelogin`, `BtnUxNavAccount`, `modules/Domenia-Accounts.Model.ps1:Get-DomeniaLoginChoice (PreferForm)`, `Domenia-Core.ps1:Start-DomeniaAccountRelogin`, `Domenia-Main.xaml:BtnAccountAdRelogin`, `Domenia-Main.xaml:BtnAccountsHeader`

#### CPT-008 · Corriger le mot de passe du compte de connexion sans reconnecter

> Reste à faire : Règles et contrat faits (même identité, pause du seul compte levée sauf autre copie du mot de passe refusé, refus en simulation et en session Windows) ; remplacement réel du secret de la session et arrêt des lectures parties avec l’ancien par Domenia.Ad (SwapConnectionPasswordAsync, vague 3).

`partiel` · lecture réseau

Après un changement de mot de passe dans l'annuaire, l'opérateur saisit le mot de passe actuel ; une seule validation du même compte est faite puis le nouveau mot de passe remplace l'ancien en mémoire, les lectures parties avec l'ancien sont arrêtées et la protection levée pour ce compte seulement. Refusé en démonstration, en session Windows (à corriger dans Windows) ou si l'identité validée diffère de celle de la session.

- Garde-fous : Même identité exigée (clé de compte comparée) ; si une autre copie du mot de passe refusé subsiste, la suspension est restaurée telle quelle ; message rappelant de ressaisir le mot de passe du coffre à la prochaine connexion ; champ vidé après usage.
- Références D1 : `modules/Domenia-Accounts.Async.ps1:Start-DomeniaDirectoryCorrection`, `modules/Domenia-Accounts.Async.ps1:Complete-DomeniaAccountValidation (scope Directory)`, `PwdAccountAdCorrection`, `BtnAccountAdCorrect`

#### CPT-009 · Route « compte de connexion refusé » vers la correction

`fait` · locale (aucune lecture)

Quand le compte de connexion est refusé, ouvre la page Comptes, place le curseur dans le champ de correction et affiche la consigne (saisir le mot de passe actuel puis « Corriger le mot de passe », ou « Changer de compte »).

- Garde-fous : Navigation seule, jamais de nouvelle fenêtre ni de tentative.
- Références D1 : `modules/Domenia-Accounts.Async.ps1:Show-DomeniaDirectoryCorrection`

### Comptes en service

#### CPT-010 · « En ce moment » : compte utilisé par chaque ressource

`ameliore` · locale (aucune lecture)

Grille Ressource / Compte / Origine / État : Annuaire, chaque opération annuaire ayant son compte temporaire (recherche, arborescence, fiches…), Postes (WMI, C$, consoles), Secrets LAPS et Secrets BitLocker. L'état dit « Aucun refus enregistré », « En pause après un refus : &lt;où le corriger> » ou « Même compte que … (SID confirmé par l'annuaire) » ; rien n'y est testé.

- Garde-fous : Noms et clés seulement, jamais de secret ni d'objet d'identification ; lu sous le verrou de la protection ; rafraîchi chaque seconde seulement si la page est visible et le contenu changé ; un compte sans refus n'est pas déclaré valide.
- Références D1 : `modules/Domenia-Accounts.Model.ps1:Get-DomeniaAccountsInUseRows`, `modules/Domenia-Accounts.Model.ps1:Get-DomeniaAccessScopeLabel`, `modules/Domenia-Accounts.UI.ps1:Update-DomeniaAccountsInUse`, `modules/Domenia-Accounts.UI.ps1:Initialize-DomeniaAccountsUi`, `DgAccountsInUse`, `LblAccountRule`, `Timer:Accounts`

#### CPT-011 · Comptes gardés en mémoire et « Oublier »

`ameliore` · locale (aucune lecture)

Liste le compte poste saisi et les comptes temporaires acceptés après un refus (y compris compte local d'un poste) avec leur durée restante (« une seule utilisation », « jusqu'à la fin de la session », « encore N min sans utilisation », « expiré ») et leur état ; « Oublier » rend la main au compte configuré et efface les refus liés.

- Garde-fous : Refusé pendant une écriture active ou à vérifier ; une opération déjà envoyée garde sa copie et n'est jamais interrompue ; un affichage ne prolonge jamais un bail ; clé revérifiée au clic.
- Références D1 : `modules/Domenia-Accounts.UI.ps1:Invoke-DomeniaAccountInMemoryForget`, `modules/Domenia-Accounts.UI.ps1:Get-DomeniaUsableTemporaryAccounts`, `modules/Domenia-Accounts.Model.ps1:Get-DomeniaLeaseRemainingText`, `DgAccountsInMemory`, `LblAccountsInMemory`

#### CPT-012 · Comptes utilisés (AD, postes, secrets)

> Reste à faire : Les trois identités sont dans l’écran Comptes (accounts.access.state.identities) ; leur rappel dans le panneau d’aide du shell (F1), avec le raccourci vers Comptes, reste au shell à l’intégration (ctx.help.register n’admet que des textes fixes).

`partiel` · locale (aucune lecture)

Le panneau d'aide affiche les noms des trois identités : AD courante, compte pour les postes, compte pour les secrets (« Compte AD courant » par défaut). Un raccourci ouvre la page Comptes.

- Garde-fous : Noms seulement, jamais de secret. Une identité active ne confirme pas ses droits.
- Références D1 : `Domenia-Experience.UI.ps1:Update-DomeniaExperienceIdentity`, `UxSuiteIdentities`, `LblSuiteIdentityAd`, `LblSuiteIdentityRemote`, `LblSuiteIdentitySecrets`, `BtnUxHelpAccounts`

### Comptes secondaires

#### CPT-013 · Compte Postes (compte secondaire des opérations distantes)

`fait` · lecture réseau

Saisie d'un identifiant administrateur des postes et de son mot de passe, « Activer » après validation AD, « Effacer » pour revenir au compte de connexion ; l'activation remplace seulement les comptes temporaires de la ressource Postes et leurs refus, puis passe par la correction centralisée (génération, protection de ce compte seul).

- Garde-fous : Validation AD obligatoire avant activation ; droits sur la ressource non certifiés par ce test (dit explicitement) ; mot de passe jamais sur disque hors coffre volontaire ; champ vidé.
- Références D1 : `TxtAccountRemoteUser`, `PwdAccountRemote`, `BtnAccountRemoteSave`, `BtnAccountRemoteClear`, `LblAccountRemoteIdentity`, `LblAccountRemoteStatus`, `modules/Domenia-Accounts.Async.ps1:Complete-DomeniaAccountValidation (scope Remote)`, `Domenia-Core.ps1:Save-DomeniaSecondaryCredential`, `Domenia-Core.ps1:Clear-DomeniaSecondaryCredential`, `Domenia-Core.ps1:Test-DomeniaCredentialBind`, `Domenia-Main.xaml:BtnAccountRemoteSave`

#### CPT-014 · Compte Secrets (LAPS et BitLocker)

`fait` · lecture réseau

Identifiant autorisé à lire LAPS et BitLocker, avec « Tester » (validation seule), « Activer » et « Effacer » ; l'activation ne remplace que les comptes temporaires LAPS/BitLocker (D051) et efface les refus laps|/bitlocker| enregistrés pour l'identité précédente, le compte annuaire et le compte poste restent.

- Garde-fous : Un compte Secrets refusé ne suspend jamais le canal annuaire de la session ; validation avant activation.
- Références D1 : `TxtAccountSecretsUser`, `PwdAccountSecrets`, `BtnAccountSecretsTest`, `BtnAccountSecretsSave`, `BtnAccountSecretsClear`, `LblAccountSecretsIdentity`, `LblAccountSecretsStatus`, `modules/Domenia-Accounts.Async.ps1:Complete-DomeniaAccountValidation (scope Secrets)`, `Domenia-Main.xaml:BtnAccountSecretsTest`, `Domenia-Main.xaml:BtnAccountSecretsSave`

#### CPT-015 · Essayer le compte poste sur le poste sélectionné

`fait` · lecture réseau

Sur clic explicite, une seule lecture CIM/DCOM légère (Win32_OperatingSystem.Caption) du poste ouvert dans Assistance poste, avec le compte que prendront les opérations poste ; verdict : accès administrateur OK (avec le système), accès refusé, identifiants refusés, compte verrouillé/expiré, poste injoignable ou essai non concluant. Bouton grisé sans poste ouvert ou pendant un essai.

- Garde-fous : Un seul poste, pas de balayage, ni ping, ni console, ni LDAP, aucun repli intrusif ; méthode 6 s, délai 30 s ; résultat d'un autre poste ou d'une autre session rejeté ; seul un succès explicite dit « OK » ; consigné dans le journal UI « Comptes ». Lecture seule.
- Opérations : `LiveConsole`, `RemoteCredentialCheck`
- Références D1 : `modules/Domenia-Accounts.UI.ps1:Start-DomeniaRemoteAccountTrial`, `modules/Domenia-Accounts.UI.ps1:Complete-DomeniaRemoteAccountTrial`, `modules/Domenia-Accounts.UI.ps1:Fail-DomeniaRemoteAccountTrial`, `modules/Domenia-Accounts.UI.ps1:Update-DomeniaRemoteTrialUi`, `modules/Domenia-Accounts.Model.ps1:Get-DomeniaRemoteAccessTrialVerdict`, `BtnAccountRemoteTry`, `LblAccountRemoteTry`, `Domenia-Core.ps1:Wire-Events (BtnAccountRemoteTry)`, `Domenia-Main.xaml:BtnAccountRemoteTry`

#### CPT-016 · Mémoriser l'identifiant (nom seulement) dans la base locale

`ameliore` · locale (aucune lecture)

Après activation, le nom du compte (jamais le mot de passe) est enregistré par usage (Directory, Remote, Laps, BitLocker, AD:&lt;opération>, RemoteLocal:&lt;poste>) et par domaine dans SQLite, puis relu pour préremplir les champs Postes et Secrets. Une lecture asynchrone n'écrase jamais un texte tapé entre-temps.

- Garde-fous : File bornée à 64 lots ; lot validé (champs permis) avant d'être retenu ; reçu de sauvegarde contrôlé (SQLite, StoreId, chemin, domaine, révision) ; même ID réessayé par l'écrivain central, jamais de copie ; relecture retentée toutes les 30 s ; message « identifiant non mémorisé » si échec.
- Opérations : `LocalStore`, `LocalIndexRead`
- Références D1 : `modules/Domenia-Accounts.Store.UI.ps1:Save-DomeniaAccountPreference`, `modules/Domenia-Accounts.Store.UI.ps1:Sync-DomeniaAccountPreferences`, `modules/Domenia-Accounts.Store.UI.ps1:Get-DomeniaRememberedAccount`, `modules/Domenia-Accounts.Store.UI.ps1:Update-DomeniaRememberedAccountFields`, `modules/Domenia-Accounts.Store.UI.ps1:Get-DomeniaAccountPreferenceScope`, `modules/Domenia-Accounts.Store.UI.ps1:Set-DomeniaCommittedAccountPreferences`

#### CPT-017 · Coffre Windows pour les comptes Postes et Secrets

> Reste à faire : Coffre Windows (Gestionnaire d’identification) : question posée à David dans REPRISE.md (§ 4) ; branchement natif (CredRead, CredWrite, CredDelete) ensuite ; indisponible en simulation comme dans Domenia 1 (case grisée avec sa raison).

`partiel` · lecture locale

Case « Mémoriser sur ce PC » (enregistre après validation), « Utiliser le coffre » (lit le mot de passe pour l'identifiant affiché puis lance une seule validation) et « Oublier le mot de passe » (supprime l'entrée pour cet usage) ; le compte Secrets est enregistré et oublié pour LAPS et BitLocker à la fois.

- Garde-fous : Gestes explicites seulement ; jamais lu au démarrage ni en arrière-plan ; enregistrement refusé sans authentification manuelle confirmée ; aucun secret placé dans un champ ; indisponible en démonstration ; compte rendu « n/m usages enregistrés » en cas d'échec partiel ; aucune copie dans la base Domenia. Coffre non validé bloqué jusqu'à nouvelle saisie ; jamais de mot de passe dans la base Domenia.
- Références D1 : `modules/Domenia-Accounts.Vault.UI.ps1:Save-DomeniaSecondaryVault`, `modules/Domenia-Accounts.Vault.UI.ps1:Invoke-DomeniaSecondaryVaultLogin`, `modules/Domenia-Accounts.Vault.UI.ps1:Remove-DomeniaSecondaryVault`, `modules/Domenia-Accounts.Vault.UI.ps1:Initialize-DomeniaAccountVaultUi`, `ChkAccountRemoteRemember`, `ChkAccountSecretsRemember`, `BtnAccountRemoteVault`, `BtnAccountSecretsVault`, `BtnAccountRemoteForgetVault`, `BtnAccountSecretsForgetVault`, `Domenia-Access.UI.ps1:Show-DomeniaAlternateCredential`, `Save-DomeniaSecondaryVault`, `Get-DomeniaCredentialVaultCredential`, `Remove-DomeniaCredentialVaultCredential`, `Get-DomeniaRememberedAccount`

#### CPT-018 · Vérification d'un compte poste

`fait` · lecture réseau

Valide un compte pour un poste précis en ouvrant une session CIM DCOM (5 s) et en lisant Win32_ComputerSystem.Name ; « .\compte » est complété par le nom du poste.

- Garde-fous : Poste cible obligatoire et nom validé ; secret copié en lecture seule et détruit ; session CIM fermée.
- Opérations : `RemoteCredentialCheck`
- Références D1 : `Domenia-Sessions.UI.ps1:Start-DomeniaRemoteCredentialSession`, `Domenia-Sessions.UI.ps1:Get-DomeniaRemoteCredentialCheckCode`

### Droits et transports

#### CPT-019 · Droits, comptes et ports requis par opération

`ameliore` · locale (aucune lecture)

Pour chaque opération : ressource, compte utilisé, droit nécessaire et accès réseau (LDAP 389, CIM/DCOM 135+RPC, WSMan, SMB 445, journal distant, ICMP) ; opération inconnue = droit non documenté.

- Garde-fous : Jamais de droit deviné.
- Opérations : `ReadLaps`, `ReadBitLocker`, `ReadBitLockerKey`, `BitLockerPresence`, `LockoutDiagnosis`, `LogonHarvest`, `PermissionAnalysis`, `UserComputerProbe`, `RemoteCredentialCheck`, `SessionsList`, `ComputerAdminShare`, `ComputerGpUpdate`, `ComputerRestart`, `ComputerServiceControl`, `RimotteRun`, `BatchNetworkDiag`, `WakeOnLanSend`, `ParkSharedSync`, `ConnectorRead`, `ReceiptStore`, `WriteAttributes`, `WriteResetPassword`, `WriteUnlock`, `WriteAccountDisabled`, `WriteAccountOptions`, `WriteExpiration`, `WriteExpirePassword`, `WriteGroupMember`, `WriteObjectGroup`, `WriteMoveObject`, `WriteRenameComputer`, `WriteCreateOu`, `WriteDeleteObject`
- Références D1 : `Domenia-Access.Model.ps1:Get-DomeniaOperationRequirement`

#### CPT-020 · Politique de transport visible

`fait` · locale (aucune lecture)

Tableau LDAP, CIM/DCOM, CIM/WSMan, WTS, ADMIN$, Planificateur, PsExec : usage, ports, état selon configuration et consentement, règle, intrusif ; note du consentement en cours (un poste, 5 min).

- Garde-fous : Aucun réglage Windows modifié.
- Références D1 : `Domenia-Access.Model.ps1:Get-DomeniaTransportPolicy`, `Domenia-Access.UI.ps1:Get-DomeniaTransportPolicyRows`, `Domenia-Access.UI.ps1:Update-DomeniaTransportPolicyView`, `XAML:DgTransportPolicy`, `XAML:LblTransportPolicy`, `Réglage:Remote.UseCim`, `Réglage:Remote.UseWinRM`, `Réglage:Remote.UsePsExecFallback`, `Réglage:Remote.UseTaskFallback`

### Validation des comptes

#### CPT-021 · Validation asynchrone d'un compte (une à la fois)

`ameliore` · lecture réseau

Valide un identifiant/mot de passe dans un runspace d'authentification dédié, sans attente du Dispatcher, avec un délai de 12 s ; les champs et boutons de la page Comptes sont occupés pendant la validation et la fenêtre reste utilisable. Le résultat doit être une authentification explicite, avec BindUser et le même domaine ; sinon « Identité AD non confirmée ».

- Garde-fous : Refus si une écriture est active ou à vérifier ; une seule validation à la fois ; abandon si la session ou le domaine change ou à la fermeture ; copie SecureString en lecture seule détruite à la fin ; aucune variante d'identité silencieuse ; « droits poste et secrets non testés ».
- Références D1 : `modules/Domenia-Accounts.Async.ps1:Start-DomeniaAccountValidation`, `modules/Domenia-Accounts.Async.ps1:Complete-DomeniaAccountValidation`, `modules/Domenia-Accounts.Async.ps1:Stop-DomeniaAccountValidation`, `Start-DomeniaLoginAuthRunspace (Core)`, `Timer:AccountValidation`

<a id="rel"></a>

## Utilisateurs et postes (REL)

52 fonctions : 33 faites, 13 améliorées, 6 partielles.

### Association manuelle

#### REL-001 · Recherche manuelle d'une cible

`fait` · lecture réseau

Cherche un poste (ou un utilisateur pour un sujet poste) dans tout le domaine par nom, identifiant ou DNS (2 caractères min, Entrée).

- Garde-fous : Un nouveau terme invalide les résultats et l'association préparée ; limite atteinte signalée.
- Opérations : `EmbeddedDirectoryLookup`
- Références D1 : `Domenia-Relations.UI.ps1:Start-DomeniaRelationComputerSearch`, `Domenia-Relations.UI.ps1:Complete-DomeniaRelationComputerSearch`, `Domenia-Relations.UI.ps1:Fail-DomeniaRelationComputerSearch`, `Domenia-Relations.UI.ps1:Clear-DomeniaRelationManualResults`, `XAML:TxtRelationComputerSearch`, `XAML:BtnRelationComputerSearch`, `XAML:DgRelationComputerSearch`, `XAML:LblRelationComputerSearchStatus`

#### REL-002 · Association manuelle confirmée et revérifiée

`fait` · écriture

Après choix d'une ligne, panneau « utilisateur → poste » ; Associer revérifie la cible dans l'AD puis enregistre une affectation déclarée (Saisie manuelle).

- Garde-fous : Sujet, cible, session et compte de lecture revérifiés ; types opposés exigés ; association locale, AD non modifié.
- Opérations : `EmbeddedDirectoryLookup`, `LinkHistoryStore`
- Références D1 : `Domenia-Relations.UI.ps1:Set-DomeniaRelationPendingAssociation`, `Domenia-Relations.UI.ps1:Request-DomeniaRelationManualAssociation`, `Domenia-Relations.UI.ps1:Confirm-DomeniaRelationAssociation`, `Domenia-Relations.UI.ps1:Complete-DomeniaRelationAssociationVerify`, `Domenia-Relations.UI.ps1:Cancel-DomeniaRelationAssociation`, `Domenia-Relations.Model.ps1:Test-DomeniaRelationConfirmation`, `Add-UserMachineLinkIfMissing`, `XAML:BtnRelationAssociateSearchResult`, `XAML:BtnRelationConfirmApply`, `XAML:BtnRelationConfirmCancel`, `XAML:LblRelationConfirm`, `XAML:RelationConfirmPanel`

#### REL-003 · États de l'association et refus expliqués

`ameliore` · locale (aucune lecture)

Parcours Idle → Recherche → Candidat → En attente → Vérification → Enregistrée/Échec ; chaque étape refusée est expliquée en une phrase.

- Garde-fous : Noms internes au journal seulement.
- Références D1 : `Domenia-Relations.Model.ps1:Step-DomeniaAssociationState`, `Domenia-Relations.Model.ps1:Get-DomeniaAssociationRefusal`, `Domenia-Relations.UI.ps1:Step-DomeniaRelationsAssociation`

### Associations

#### REL-004 · Associer un utilisateur sans fenêtre

`fait` · locale (aucune lecture)

L'association se fait désormais dans Relations, panneau Ajouter > Rechercher, à partir du poste sélectionné. Il n'y a plus de fenêtre séparée et rien n'est sondé à cette étape.

- Garde-fous : Aucune sonde à cette étape.
- Références D1 : `Domenia-Embedded.UI.ps1:Select-DomeniaRelationsUser`

#### REL-005 · Relations rattachées au GUID du poste

`fait` · locale (aucune lecture)

Ne reprend pour un poste que les relations de son GUID ; même adresse ou même nom sur un autre objet = exclu, sans GUID = à vérifier. Règle écrite, non raccordée.

- Garde-fous : Sans GUID cible, rien n'est gardé.
- Références D1 : `Domenia-Workstation.Model.ps1:Select-DomeniaRelationsForMachine`

#### REL-006 · Associations de la sélection

`fait` · lecture locale

Grille des associations du sujet avec qualification, date locale triable, provenance et persistance (Enregistrée / Session uniquement) ; contexte chiffré et contradictions comptées.

- Garde-fous : Un lien d'un autre GUID n'est jamais rattaché par un nom réutilisé.
- Références D1 : `Domenia-Relations.UI.ps1:Refresh-DomeniaRelationViews`, `Domenia-Relations.UI.ps1:Get-DomeniaRelationsSelectedLinks`, `Domenia-Relations.UI.ps1:Update-DomeniaRelationEvidence`, `XAML:DgLinks`, `XAML:LblLinkContext`, `XAML:LblLinkEmpty`, `XAML:TabLinksSelected`

#### REL-007 · Synthèse déclaré / observé / historique

`ameliore` · locale (aucune lecture)

Trois énoncés séparés avec origine et date : affectation déclarée, dernière session observée, historique des ouvertures anciennes, plus le nombre d'autres indices.

- Garde-fous : Une observation ne devient jamais une affectation.
- Références D1 : `Domenia-Relations.Model.ps1:Get-DomeniaRelationOverview`, `Domenia-Relations.UI.ps1:Update-DomeniaLinkOverview`, `XAML:LblLinkOverview`

#### REL-008 · Supprimer une association locale

`fait` · écriture

Retire l'association choisie du stockage local ou de la session après confirmation en page.

- Garde-fous : Journalisée et restaurable ; AD jamais modifié ; refusée pendant une écriture ; refus de stockage nommé.
- Opérations : `LinkHistoryStore`
- Références D1 : `Domenia-Relations.UI.ps1:Request-DomeniaRelationRemoval`, `Domenia-Relations.UI.ps1:Complete-DomeniaRelationRemoval`, `Domenia-Relations.UI.ps1:Cancel-DomeniaRelationRemoval`, `Domenia-Relations.UI.ps1:Remove-DomeniaRelation`, `Domenia-Relations.UI.ps1:Remove-DomeniaRelations`, `Domenia-Relations.UI.ps1:Find-DomeniaRelationInstance`, `XAML:BtnRemoveLink`, `Domenia-Core.ps1:Remove-SelectedLink`, `Domenia-Main.xaml:BtnRemoveLink`

#### REL-009 · Restaurer la dernière suppression

`ameliore` · écriture

Bouton nommé « Restaurer jdupont → PC01 » qui remet la dernière association supprimée non encore restaurée, depuis la mémoire ou le journal disque.

- Garde-fous : Une association par clic ; déjà existante = refus expliqué.
- Opérations : `LinkHistoryStore`
- Références D1 : `Domenia-Relations.UI.ps1:Restore-DomeniaRemovedLink`, `Domenia-Relations.UI.ps1:Get-DomeniaRelationsRestoreCandidate`, `Domenia-Relations.UI.ps1:Get-DomeniaRelationsRestorableEntry`, `Domenia-Relations.UI.ps1:Reset-DomeniaRelationsRestoreCache`, `Domenia-Relations.Model.ps1:Get-DomeniaLinkRestoreCandidate`, `Domenia-Relations.Model.ps1:Get-DomeniaRelationRestoreLabel`, `XAML:BtnRestoreLink`, `XAML:BtnRestoreLinkAll`, `Domenia-Main.xaml:BtnRestoreLink`

#### REL-010 · Journal local des relations

`ameliore` · écriture

Historique en mémoire (500 entrées) des ajouts, retraits, restaurations, rafraîchissements ; retraits et restaurations aussi écrits en JSONL à côté de la base.

- Garde-fous : Échec disque signalé, entrée gardée en mémoire ; journal filtré par domaine.
- Opérations : `LinkHistoryStore`
- Références D1 : `Domenia-Relations.UI.ps1:Add-DomeniaRelationHistory`, `Domenia-Relations.UI.ps1:Get-DomeniaRelationsJournalPath`, `Domenia-Relations.Model.ps1:New-DomeniaLinkHistoryEntry`

#### REL-011 · Garde de stockage des associations

`fait` · locale (aucune lecture)

Avant tout changement, vérifie que l'enregistrement précédent est terminé et qu'au plus 64 postes changent ; sinon raison nommée, rien n'est appliqué à moitié.

- Garde-fous : Retour arrière mémoire si le stockage refuse.
- Références D1 : `Domenia-Relations.UI.ps1:Get-DomeniaRelationSaveRefusal`, `Domenia-Relations.UI.ps1:Get-DomeniaRelationRefusalText`

#### REL-012 · Conflits d'associations entre consoles

`fait` · écriture

Une association modifiée par une autre console n'est pas écrasée : la version du disque est gardée, la nôtre reste en mémoire avec le message « Association modifiée ailleurs… Rechargez les associations ». Le chemin d'arrière-plan ne resoumet jamais une clé en conflit, et le rechargement (Comptes > Changer de compte, ou un redémarrage) clôt le conflit. La file d'écriture abstraite D028 (New-DomeniaWriteQueue, Add-DomeniaWriteRequest, Resolve-DomeniaWriteConflict) existe mais n'est pas branchée.

- Garde-fous : Contrôle optimiste par empreinte de l'association attendue.
- Opérations : `LocalStore`
- Références D1 : `Domenia-Storage.UI.ps1:Reset-DomeniaLinkBaseline`, `Domenia-Storage.UI.ps1:Queue-DomeniaLinkChanges`, `Domenia-Cache.Model.ps1:Get-DomeniaPersistenceLabel`, `Domenia-Cache.Model.ps1:New-DomeniaWriteQueue`, `Domenia-Cache.Model.ps1:Add-DomeniaWriteRequest`, `Domenia-Cache.Model.ps1:Get-DomeniaWriteBatch`, `Domenia-Cache.Model.ps1:Resolve-DomeniaWriteConflict`

#### REL-013 · Associations chargées depuis la base

> Reste à faire : Lecture et migration de la table SQLite user_machine_links de Domenia 1 (schéma 11) par Domenia.Store, mode annuaire (contrat au § 6.1 de docs/ops/relations.md) ; la simulation lit son magasin en mémoire au premier usage.

`partiel` · lecture locale

Les associations poste-utilisateur de la base sont lues par worker au démarrage, au changement de compte et après une bascule de base. Une modification faite pendant la lecture reste en mémoire et s'enregistre à la fin, car la référence de l'écrivain doit être le contenu de la base, jamais une liste vide.

- Garde-fous : Une modification différée d'une session précédente n'est pas reportée.
- Opérations : `LocalIndexRead`
- Références D1 : `Domenia-Engine.UI.ps1:Request-DomeniaUserMachineLinks`, `Domenia-Engine.UI.ps1:Complete-DomeniaUserMachineLinksUi`, `Domenia-Engine.UI.ps1:Fail-DomeniaUserMachineLinksUi`, `Domenia-Storage.UI.ps1:Queue-DomeniaLinkChanges`

#### REL-014 · Enregistrement groupé des associations

> Reste à faire : Décision de David attendue (REPRISE.md § 4) : mémorisation automatique sans confirmation comme Domenia 1, ou un plan confirmé par lot de 64 comme aujourd’hui (ou un plan collectif scellé, TRV-229). Fait : observations visibles tout de suite (« Session uniquement »), comptées, enregistrées lot par lot par le circuit des écritures.

`partiel` · écriture

Les changements d'associations sont comparés à leur dernier état connu et envoyés par lots de 64 au plus. Les observations d'arrière-plan sont regroupées après 1,5 s de calme, et la suite d'un lot partiel part au tour suivant. Un geste explicite de plus de 64 changements est refusé.

- Garde-fous : Un seul enregistrement de liens à la fois (« Attendez son résultat »). Refus sous maintenance. Message « n lien(s) en mémoire, enregistrement en arrière-plan en attente ».
- Opérations : `LocalStore`, `LinkHistoryStore`
- Références D1 : `Domenia-Storage.UI.ps1:Queue-DomeniaLinkChanges`, `Domenia-Storage.UI.ps1:Request-DomeniaLinkPersistence`, `Domenia-Storage.UI.ps1:Reset-DomeniaLinkBaseline`, `Domenia-Storage.Worker.ps1:Invoke-DomeniaLinkWrite`

#### REL-015 · Associations utilisateur-poste mémorisées

`fait` · lecture locale

Index en mémoire des liens, lu par poste ou par utilisateur avec la règle d'identité par GUID et date de création ; badge de qualification (jamais un pourcentage), date en heure locale, statistiques ; ouverture de l'objet associé.

- Garde-fous : Un nom recyclé ne montre jamais les liens d'un autre objet ; lien hérité sans GUID annoncé comme non prouvé.
- Opérations : `OpenLinkedObject`
- Références D1 : `Domenia-Core.ps1:Rebuild-UserMachineLinkIndex`, `Domenia-Core.ps1:Ensure-UserMachineLinkIndex`, `Domenia-Core.ps1:Get-LinksForComputer`, `Domenia-Core.ps1:Get-LinksForUser`, `Domenia-Core.ps1:Get-AssociationForRow`, `Domenia-Core.ps1:Get-SelectedAssociationSummary`, `Domenia-Core.ps1:Get-AssociationSummaryForObject`, `Domenia-Core.ps1:Get-AssociationStatsText`, `Domenia-Core.ps1:Get-DomeniaLinkIdentityNote`, `Domenia-Core.ps1:Start-OpenLinkedObject`, `Domenia-Main.xaml:DgLinks`, `Domenia-Main.xaml:DgAllLinks`

#### REL-016 · Ajouter une association

`fait` · écriture

Depuis un utilisateur ou un poste sélectionné, ouvre le panneau Ajouter de Relations (recherche du poste ou de l'utilisateur) ; une relation par utilisateur, poste et nature, une affectation déclarée n'est jamais remplacée par une observation.

- Garde-fous : Écriture locale uniquement, AD jamais modifié ; date UTC ISO ; pas de score inventé.
- Opérations : `LocalStore`
- Références D1 : `Domenia-Core.ps1:Add-SelectedLink`, `Domenia-Core.ps1:Add-UserMachineLinkIfMissing`, `Domenia-Core.ps1:ConvertTo-DomeniaCanonicalLinks`, `Domenia-Core.ps1:Save-UserMachineLinks`, `XAML:BtnRelationSelectUser`, `XAML:BtnLinkSelected`

### Détection

#### REL-017 · Association mémorisée du compte console

> Reste à faire : Décision de David attendue (REPRISE.md § 4) : mémorisation automatique sans confirmation comme Domenia 1, ou un plan confirmé par lot de 64 comme aujourd’hui (ou un plan collectif scellé, TRV-229). Fait : observations visibles tout de suite (« Session uniquement »), comptées, enregistrées lot par lot par le circuit des écritures.

`partiel` · écriture

Un compte console observé et validé dans AD rejoint les relations du poste (source « Console CIM/DCOM », date UTC) par la règle d'upsert.

- Garde-fous : Seulement si le compte a un DN AD ; compte local ou nom nu jamais réinterprété ; écrivain unique.
- Opérations : `LocalStore`
- Références D1 : `Domenia-Live.UI.ps1:Merge-DomeniaLiveLinkMemory`, `Add-DomeniaRelation`

#### REL-018 · Association console créée par un relevé

> Reste à faire : Décision de David attendue (REPRISE.md § 4) : mémorisation automatique sans confirmation comme Domenia 1, ou un plan confirmé par lot de 64 comme aujourd’hui (ou un plan collectif scellé, TRV-229). Fait : observations visibles tout de suite (« Session uniquement »), comptées, enregistrées lot par lot par le circuit des écritures.

`partiel` · écriture

Le compte console observé par un relevé devient une association utilisateur-poste, enregistrée par lots.

- Garde-fous : Seulement un compte trouvé dans AD ; jamais une affectation déclarée ou importée remplacée ; poste déjà associé au même compte laissé tel quel.
- Opérations : `LocalStore`
- Références D1 : `Domenia-Park.UI.ps1:Register-DomeniaParkConsoleLink`

#### REL-019 · Détecter les postes d'un utilisateur : lecture annuaire

`fait` · lecture réseau

Phase 1 sans contact de poste : relit le compte exact, puis les associations connues, les postes dont il est managedBy et ceux qui le mentionnent (description, location).

- Garde-fous : Compte recréé ou renommé détecté ; canal AD suspendu après rejet ; budget 45 s.
- Opérations : `UserComputerProbe`
- Références D1 : `Domenia-Relations.UI.ps1:Start-DomeniaRelationsSearch`, `Domenia-Relations.UI.ps1:Submit-DomeniaRelationsQuery`, `Domenia-Relations.UI.ps1:Complete-DomeniaRelationsSearch`, `Domenia-Relations.UI.ps1:Get-DomeniaRelationsWorkerCode`, `XAML:BtnDetectUserComputers`

#### REL-020 · Périmètre de détection confirmé avant toute sonde

`ameliore` · locale (aucune lecture)

Candidats connus, liste chargée ou OU explicite ; limite 1 à 50 ; la liste exacte des postes à interroger est montrée, puis « Lancer la détection » ou « Annuler ».

- Garde-fous : Domaine entier jamais substitué ; plan annulé si sujet ou session change ; « zéro candidat » ne veut pas dire aucun poste.
- Références D1 : `Domenia-Relations.Model.ps1:Get-DomeniaDetectionScopePlan`, `Domenia-Relations.UI.ps1:Show-DomeniaRelationDetectionPlan`, `Domenia-Relations.UI.ps1:Confirm-DomeniaRelationDetectionPlan`, `Domenia-Relations.UI.ps1:Cancel-DomeniaRelationDetectionPlan`, `Domenia-Relations.UI.ps1:Get-DomeniaRelationScopeCandidates`, `XAML:CmbRelationScanScope`, `XAML:TxtRelationScanLimit`, `XAML:LblRelationPlan`, `XAML:BtnRelationPlanRun`, `XAML:BtnRelationPlanCancel`, `Domenia-Main.xaml:CmbRelationScanScope`, `XAML:ExpRelationOptions`, `XAML:RelationPlanPanel`

#### REL-021 · Sonde des consoles bornée avec compteurs

`ameliore` · lecture réseau

Lit l'utilisateur console (Win32_ComputerSystem par CIM/DCOM, 4 s) des seuls postes confirmés ; compteurs interrogés, confirmés, refusés, injoignables, restants en direct.

- Garde-fous : Seul un geste explicite sonde ; liste sondée hors plan = rien enregistré ; nom reçu différent rejeté ; arrêt au premier rejet d'identifiants ; budget 120 s.
- Opérations : `UserComputerProbe`
- Références D1 : `Domenia-Relations.UI.ps1:Submit-DomeniaRelationsQuery`, `Domenia-Relations.UI.ps1:Invoke-DomeniaRelationsTick`, `Domenia-Relations.UI.ps1:Update-DomeniaRelationDetectionCounters`, `Domenia-Relations.Model.ps1:Test-DomeniaDetectionWithinPlan`, `Domenia-Relations.Model.ps1:Test-DomeniaDetectionMatchesPlan`, `Domenia-Relations.Model.ps1:New-DomeniaDetectionCounters`, `Domenia-Relations.Model.ps1:Add-DomeniaDetectionOutcome`, `Domenia-Relations.Model.ps1:ConvertTo-DomeniaDetectionOutcome`, `Domenia-Relations.Model.ps1:Get-DomeniaDetectionCounterText`, `Domenia-Relations.Model.ps1:Test-DomeniaProbeAllowed`, `XAML:ChkUserScanPark`, `XAML:ChkRelationRdp`

#### REL-022 · Indices Kerberos du contrôleur (7 jours)

`fait` · lecture réseau

Option : lit jusqu'à 100 événements 4768 du SID sur le contrôleur et liste les adresses IP comme indices.

- Garde-fous : Une IP n'est jamais associée automatiquement ; un seul contrôleur ; bail d'authentification.
- Opérations : `UserComputerProbe`
- Références D1 : `Domenia-Relations.UI.ps1:Get-DomeniaRelationsWorkerCode`, `XAML:ChkRelationEvents`, `Domenia-Main.xaml:ChkRelationEvents`

#### REL-023 · Arrêter la détection

`fait` · locale (aucune lecture)

Arrête la recherche inverse en cours, résultat partiel déclaré.

- Garde-fous : Liens enregistrés conservés ; résultats provisoires non enregistrés.
- Opérations : `UserComputerProbe`
- Références D1 : `Domenia-Relations.UI.ps1:Stop-DomeniaRelationsSearch`, `XAML:BtnRelationsStop`

#### REL-024 · Enregistrement des consoles confirmées

`ameliore` · écriture

Les consoles confirmées (50 max) s'ajoutent aux relations sans en retirer ; une affectation déclarée reste enregistrée et l'observation reste visible pour la session.

- Garde-fous : Stockage local seulement ; retour arrière complet si l'enregistrement échoue ; différé si la file est occupée.
- Opérations : `LinkHistoryStore`
- Références D1 : `Domenia-Relations.UI.ps1:Save-DomeniaRelationConfirmations`, `Domenia-Relations.UI.ps1:Add-DomeniaRelation`, `Domenia-Relations.Model.ps1:Resolve-DomeniaRelationUpsert`, `Domenia-Relations.Model.ps1:Resolve-DomeniaRelationStoragePlacement`, `Domenia-Relations.Model.ps1:Select-DomeniaPrimaryRelation`, `Save-UserMachineLinks`

#### REL-025 · Candidats construits à partir de plusieurs preuves

`fait` · locale (aucune lecture)

Regroupe association connue, observation, indice AD et inventaire par GUID ; chaque candidat dit pourquoi il est proposé et s'il est associable.

- Garde-fous : IP ou nom partiel jamais associables.
- Références D1 : `Domenia-Relations.Model.ps1:Merge-DomeniaRelationCandidates`, `Domenia-Relations.UI.ps1:Update-DomeniaRelationCandidateEvidence`, `XAML:DgRelationCandidates`

#### REL-026 · Ouvrir ou associer un poste candidat

`fait` · locale (aucune lecture)

Ouvre la fiche du poste candidat ou prépare son association déclarée.

- Garde-fous : Candidat sans GUID refusé avec raison.
- Opérations : `OpenAdObject`
- Références D1 : `Domenia-Relations.UI.ps1:Use-DomeniaRelationCandidate`, `XAML:BtnRelationOpenCandidate`, `XAML:BtnRelationAdopt`

#### REL-027 · Contrôle d'identité du compte observé

`fait` · locale (aucune lecture)

Compare le compte lu à la cible : SID identique, compte local du poste, autre autorité, nom non qualifié, UPN, domaine et identifiant.

- Garde-fous : Un homonyme d'un autre domaine n'est jamais le compte AD.
- Références D1 : `Domenia-Relations.Model.ps1:Test-DomeniaAccountIdentityMatch`, `Domenia-Relations.Model.ps1:ConvertTo-DomeniaAccountIdentity`

#### REL-028 · Détail des tentatives de recherche

`fait` · locale (aucune lecture)

Grille des méthodes essayées (compte, associations, indices, journal, consoles) avec statut, cible, durée, détail et ressource.

- Opérations : `UserComputerProbe`
- Références D1 : `XAML:DgLinkAttempts`, `Domenia-Relations.UI.ps1:Get-DomeniaRelationsWorkerCode`, `Domenia-Main.xaml:TabLinksAttempts`

#### REL-029 · Reprise d'accès après refus pendant la détection

> Reste à faire : Demande d’un autre compte pour la ressource refusée : le canal existe dans l’écran Comptes (demandes d’accès, « Utiliser un autre compte », accounts.access.*) ; brancher les refus de la détection sur ces demandes à l’intégration, les lectures réelles en vague 3. Fait : arrêt au premier refus d’identifiants (RelationProbeLoop), ressources refusées nommées et copiables dans la carte « Reprise d’accès », jamais rejouées.

`partiel` · locale (aucune lecture)

Un rejet ou refus de l'annuaire ou d'un poste ouvre une demande d'autre compte pour la ressource concernée, sans rejouer la recherche.

- Garde-fous : Aucun rejeu automatique.
- Opérations : `UserComputerProbe`, `ComputerInventory`
- Références D1 : `Domenia-Relations.UI.ps1:Complete-DomeniaRelationsSearch`, `Domenia-Access.UI.ps1:Request-DomeniaAccessRecovery`

#### REL-030 · Moisson du journal du contrôleur

> Reste à faire : Décision de David attendue (REPRISE.md § 4) : mémorisation automatique sans confirmation comme Domenia 1, ou un plan confirmé par lot de 64 comme aujourd’hui (ou un plan collectif scellé, TRV-229). Fait : observations visibles tout de suite (« Session uniquement »), comptées, enregistrées lot par lot par le circuit des écritures.

`partiel` · lecture réseau

Une requête sur le journal Sécurité du DC de la session (événements 4768, 4769, 4624, 7 jours par défaut, 1 à 30 ; 5 000 événements, 200 à 20 000) rend des milliers de couples utilisateur-poste sans contacter de poste ; comptes machines ignorés.

- Garde-fous : Estimation d'impact confirmée en page ; refus d'identifiants remonté au disjoncteur ; association existante jamais écrasée.
- Opérations : `LogonHarvest`
- Références D1 : `Domenia-Core.ps1:Start-DomeniaLogonHarvest`, `Domenia-Core.ps1:Get-DomeniaLogonHarvestWorkerCode`, `Domenia-Core.ps1:Complete-DomeniaLogonHarvestUi`, `Domenia-Core.ps1:Fail-DomeniaLogonHarvestUi`, `Domenia-Main.xaml:BtnParkHarvest`

#### REL-031 · Relevé incrémentiel du parc

`fait` · lecture réseau

File de priorité : postes jamais relevés, puis relevés périmés du plus ancien ; un poste non réauthentifié (lastLogonTimestamp) depuis le dernier relevé n'est pas redemandé ; ping parallèle par lots avant toute session ; « Oublier les relevés » après sauvegarde vérifiée.

- Garde-fous : Plus de détection sur tout le parc : seulement les lignes affichées de Rechercher ; budget, report au lancement suivant.
- Opérations : `ParkSweep`, `LocalIndexRead`
- Références D1 : `Domenia-Core.ps1:Get-DomeniaParkPriority`, `Domenia-Core.ps1:Get-DomeniaParkCoverage`, `Domenia-Core.ps1:Get-DomeniaParkCoverageText`, `Domenia-Core.ps1:Get-DomeniaParkSweepWorkerCode`, `Domenia-Core.ps1:Complete-DomeniaParkSweepUi`, `Domenia-Core.ps1:Save-DomeniaParkState`, `Domenia-Main.xaml:BtnParkReset`, `XAML:ChkParkSweepEnabled`, `XAML:LblParkDetectionStatus`

### Import

#### REL-032 · Correspondance d'identité des lignes importées

`fait` · locale (aucune lecture)

Rejette un compte d'un autre domaine, un suffixe UPN différent, un poste FQDN d'un autre domaine, une adresse IP ou un UUID matériel à la place d'un nom.

- Garde-fous : Domaine inconnu → rejet plutôt que devinette.
- Références D1 : `Domenia-InventoryImport.Model.ps1:Test-DomeniaInventoryIdentity`

#### REL-033 · Dates et priorité dans un fichier importé

`fait` · locale (aucune lecture)

Lit les dates ISO ou Unix (date future au-delà de 60 min ignorée), garde le plus récent par poste, et décide Retenue, Doublon, Remplacée ou Conflit (aucune des lignes en conflit importée).

- Garde-fous : Date ambiguë (08/10/2026) non lue ; enregistrements écartés comptés, jamais perdus en silence.
- Références D1 : `Domenia-InventoryImport.Model.ps1:ConvertTo-DomeniaInventoryWhen`, `Domenia-InventoryImport.Model.ps1:Select-DomeniaLatestInventoryRecords`, `Domenia-InventoryImport.Model.ps1:Resolve-DomeniaInventoryPriority`

#### REL-034 · Lots d'import réversibles

`fait` · écriture

Chaque import porte un jeton de lot (horodatage + 8 hex) dans les détails des associations, ce qui permet de lister les lots et d'annuler un import après redémarrage.

- Garde-fous : Lot identifié par son jeton, jamais par le nom de fichier.
- Opérations : `LocalStore`
- Références D1 : `Domenia-InventoryImport.Model.ps1:New-DomeniaImportBatchId`, `Domenia-InventoryImport.Model.ps1:Get-DomeniaImportBatchToken`, `Domenia-InventoryImport.Model.ps1:Get-DomeniaImportBatches`

#### REL-035 · Import d'associations avec aperçu

`ameliore` · écriture

Trois adaptateurs pour importer des associations utilisateur-poste : CSV générique, export GLPI (Usager/Login, date du dernier inventaire, série, entité), résultats osquery logged_in_users (journal ou tableau JSON).

- Garde-fous : Taille de fichier bornée ; séparateur détecté ; aucun poste déjà associé remplacé ; priorité de date dans le fichier ; rien n'est enregistré avant « Importer ». Aucune modification avant confirmation ; source imposée par le format. Provenance imposée par l'adaptateur ; CSV ≤ 8 Mio, JSON ≤ 2 Mio, 20 000 enregistrements, aperçu 1 000 lignes, 64 changements par requête ; nom affiché GLPI jamais pris pour un login ; sessions sans personne ignorées et comptées.
- Opérations : `LocalStore`
- Références D1 : `Domenia-Relations.UI.ps1:Show-DomeniaLinkImportPreview`, `Domenia-Relations.UI.ps1:New-DomeniaLinkImportPlan`, `Domenia-Relations.UI.ps1:Update-DomeniaLinkImportUi`, `Domenia-Relations.UI.ps1:Get-DomeniaLinkImportAdapterChoice`, `Domenia-Relations.Model.ps1:Get-DomeniaLinkImportStatus`, `Domenia-Relations.Model.ps1:ConvertFrom-DomeniaLinkCsvRow`, `Domenia-InventoryImport.Model.ps1`, `XAML:CmbLinkImportFormat`, `XAML:BtnImportLinks`, `XAML:DgLinkImportPreview`, `XAML:LblLinkImportSummary`, `Domenia-Core.ps1:Import-LinksCsv`, `Domenia-Main.xaml:CmbLinkImportFormat`, `Domenia-Main.xaml:BtnImportLinks`, `Domenia-Main.xaml:DgLinkImportPreview`, `Domenia-Main.xaml:BtnUndoImport`, `Domenia-InventoryImport.Model.ps1:Get-DomeniaInventoryAdapters`, `Domenia-InventoryImport.Model.ps1:Get-DomeniaInventoryAdapter`, `Domenia-InventoryImport.Model.ps1:ConvertFrom-DomeniaCsvInventoryRow`, `Domenia-InventoryImport.Model.ps1:ConvertFrom-DomeniaGlpiRow`, `Domenia-InventoryImport.Model.ps1:ConvertFrom-DomeniaOsqueryText`, `Domenia-InventoryImport.Model.ps1:Get-DomeniaInventoryColumnValue`, `Domenia-InventoryImport.Model.ps1:ConvertTo-DomeniaInventoryHeaderKey`, `Domenia-InventoryImport.Model.ps1:Get-DomeniaInventoryLimits`

#### REL-036 · Vérification de l'import dans l'index local

`fait` · lecture locale

Avant un import, vérifie en lecture seule que les comptes et postes du fichier existent dans l'index local : noms exacts (login, poste ou compte), 1000 de chaque au plus, interrogés par paquets de 200.

- Garde-fous : Aucun accès réseau ; bouton Importer bloqué pendant la vérification. Aucune écriture.
- Opérations : `LocalIndexRead`
- Références D1 : `Domenia-Relations.UI.ps1:Start-DomeniaLinkImportIndexCheck`, `Domenia-Relations.UI.ps1:Complete-DomeniaLinkImportIndexCheck`, `Domenia-Relations.UI.ps1:Fail-DomeniaLinkImportIndexCheck`, `Domenia-Relations.UI.ps1:Test-DomeniaLinkImportIndexState`, `Domenia-Engine.Worker.ps1:Get-DomeniaLocalIndexReadWorkerCode (ResolveNames)`

#### REL-037 · Confirmer l'import

`fait` · écriture

Ajoute au plus 64 associations par import avec la source forcée (Import CSV/GLPI/osquery, badge Importé), date ISO du fichier ou de l'import, lot de retour arrière.

- Garde-fous : Sauvegarde vérifiée de la base d'abord ; aperçu changé pendant la sauvegarde = rien importé ; session changée = abandon ; Source/Confidence du fichier jamais reprises.
- Opérations : `StorageBackup`, `LinkHistoryStore`
- Références D1 : `Domenia-Relations.UI.ps1:Confirm-DomeniaLinkImport`, `Domenia-Relations.Model.ps1:New-DomeniaImportedRelation`, `Invoke-DomeniaGestureBackup`, `XAML:BtnLinkImportApply`, `XAML:BtnLinkImportCancel`

#### REL-038 · Annuler l'import

`fait` · écriture

Retire les associations ajoutées par le dernier import (lot retrouvé même après redémarrage), après confirmation nommant le nombre.

- Garde-fous : Confirmation niveau Danger ; chaque retrait journalisé et restaurable.
- Opérations : `LinkHistoryStore`
- Références D1 : `Domenia-Relations.UI.ps1:Request-DomeniaLinkImportUndo`, `Domenia-Relations.UI.ps1:Undo-DomeniaLinkImport`, `Domenia-Relations.UI.ps1:Get-DomeniaRelationsLatestImportBatch`, `Domenia-Relations.UI.ps1:Update-DomeniaLinkImportUndo`, `XAML:BtnUndoImport`

### Qualification et identité

#### REL-039 · Empreinte d'une association utilisateur-poste

`fait` · locale (aucune lecture)

Calcule l'empreinte et l'enregistrement normalisé d'une association utilisateur-poste (login, poste, source, confiance, vérifiée dans AD, date, détails, GUID et DN des deux objets) pour détecter un changement ou un doublon.

- Garde-fous : Règle pure, sans réseau.
- Références D1 : `modules/Domenia-Guard.Model.ps1:Get-DomeniaLinkFingerprint`, `modules/Domenia-Guard.Model.ps1:ConvertTo-DomeniaLinkRecord`

#### REL-040 · Qualification explicable des liens

`ameliore` · locale (aucune lecture)

Badges Déclaré, Observé, Historique, Importé, Indice, Contradictoire, À vérifier avec la règle qui les produit et la provenance ; jamais de pourcentage.

- Garde-fous : Clé interne stable, libellé affiché distinct.
- Références D1 : `Domenia-Relations.Model.ps1:Get-DomeniaRelationKind`, `Domenia-Relations.Model.ps1:Get-DomeniaEvidenceKind`, `Domenia-Relations.Model.ps1:Get-DomeniaEvidenceLabel`, `Domenia-Relations.Model.ps1:Get-DomeniaEvidenceBadge`, `Domenia-Relations.UI.ps1:Get-DomeniaLinkQualification`

#### REL-041 · Contradictions affectation / session observée

`fait` · locale (aucune lecture)

Signale les postes dont l'affectation déclarée et une session observée désignent des comptes différents ; les deux sont conservées.

- Garde-fous : Aucune fusion ni suppression ; l'historique ne contredit jamais une affectation.
- Références D1 : `Domenia-Relations.Model.ps1:Get-DomeniaLinkConflicts`

#### REL-042 · Identité des liens à travers renommages et noms recyclés

`fait` · locale (aucune lecture)

Un lien porteur de GUID n'appartient qu'à cet objet ; même nom autre GUID ou lien antérieur à la création = autre détenteur, historique non repris ; sans GUID = identité non vérifiable.

- Garde-fous : Aussi appliqué aux métadonnées BitLocker/LAPS indexées par nom.
- Références D1 : `Domenia-Relations.Model.ps1:Test-DomeniaLinkIdentity`, `Domenia-Relations.Model.ps1:Select-DomeniaLinksForIdentity`, `Domenia-Relations.Model.ps1:Test-DomeniaRecordPredatesObject`, `Domenia-Relations.Model.ps1:Get-DomeniaLinkLookupName`, `Get-DomeniaLinkIdentityNote`

#### REL-043 · Sources d'association protégées

`fait` · locale (aucune lecture)

Les associations déclarées ou importées (Manual, Saisie manuelle, Import CSV, Import GLPI, Import osquery) ne sont jamais retirées par un contrôle automatique (orphelins) ni remplacées par une détection. Ni la purge de l'historique ni la conservation ne les touchent.

- Garde-fous : Même liste dans les workers, vérifiée par un test de règles.
- Opérations : `StoragePurge`, `StorageRetention`, `PruneLinks`
- Références D1 : `Domenia-Cache.Model.ps1:Get-DomeniaProtectedAssociationSources`, `Domenia-Cache.Model.ps1:Test-DomeniaProtectedAssociationSource`

### Sujet

#### REL-044 · Sujet des relations dans les deux sens

`ameliore` · locale (aucune lecture)

Un utilisateur ou un poste choisi dans Rechercher devient le sujet ; les libellés et actions s'adaptent (Associer ce poste / Associer cet utilisateur, Détecter les postes / Lire la session).

- Garde-fous : Identité de sélection exigée (session, lecteur).
- Références D1 : `Domenia-Relations.Model.ps1:Get-DomeniaRelationDirection`, `Domenia-Relations.Model.ps1:ConvertTo-DomeniaRelationType`, `Domenia-Relations.UI.ps1:Set-DomeniaRelationsSelection`, `Domenia-Relations.UI.ps1:Set-DomeniaRelationsGridSelection`, `Domenia-Relations.UI.ps1:Get-DomeniaRelationsSubject`, `Domenia-Relations.UI.ps1:Clear-DomeniaRelationsSelection`, `XAML:LblRelationsSelection`, `Domenia-Core.ps1:Start-DomeniaUserComputerProbe`

#### REL-045 · Sujet conservé pendant une recherche de cible

`fait` · locale (aucune lecture)

Tant qu'une cible est cherchée ou qu'une association attend confirmation, une nouvelle sélection ne remplace pas le sujet ; la raison est affichée.

- Références D1 : `Domenia-Relations.Model.ps1:Resolve-DomeniaRelationSubjectChange`, `Domenia-Relations.Model.ps1:Test-DomeniaSameSubject`, `XAML:LblRelationAssociateHint`

#### REL-046 · Page Relations rafraîchie seulement visible

`fait` · locale (aucune lecture)

Tant que la page est masquée, rien n'est lié ni qualifié ; le rafraîchissement noté s'exécute à son ouverture ; qualification mémoïsée par contenu.

- Références D1 : `Domenia-Relations.UI.ps1:Test-DomeniaRelationsPageVisible`, `Domenia-Relations.UI.ps1:Open-DomeniaRelationsPage`, `Domenia-Relations.UI.ps1:Update-DomeniaRelationEvidence`

#### REL-047 · Réinitialisation des relations au changement de session

`fait` · locale (aucune lecture)

Arrête les recherches, vide sujet, observations de session et journal mémoire, ferme aperçu d'import, annulation d'import et orphelines avec message.

- Garde-fous : Rien n'est enregistré ni retiré.
- Références D1 : `Domenia-Relations.UI.ps1:Initialize-DomeniaRelationsState`

#### REL-048 · Aide et panneau Ajouter des relations

`fait` · locale (aucune lecture)

Bouton « ? » qui affiche les précautions ; panneau Ajouter avec sélecteur Détecter | Rechercher.

- Références D1 : `Domenia-Relations.UI.ps1:Switch-DomeniaRelationsHelp`, `Domenia-Relations.UI.ps1:Show-DomeniaRelationsAddPanel`, `Domenia-Relations.UI.ps1:Update-DomeniaRelationsActions`, `XAML:BtnRelationsHelp`, `XAML:RelationAssociateModeTabs`, `Domenia-Main.xaml:TabRelationDetect`, `Domenia-Main.xaml:TabRelationSearch`, `XAML:RelationAddPanel`

### Toutes les associations

#### REL-049 · Toutes les associations filtrables

`ameliore` · lecture locale

Grille complète filtrée par texte (utilisateur, poste, source, détail, libellé) et puces Déclaré, Observé, Historique, Contradictoire, avec compteur.

- Références D1 : `Domenia-Relations.UI.ps1:Update-DomeniaAllLinksView`, `Domenia-Relations.UI.ps1:Get-DomeniaAllLinksBadgeFilter`, `Domenia-Relations.Model.ps1:Test-DomeniaRelationMatchesFilter`, `XAML:DgAllLinks`, `XAML:TxtAllLinksFilter`, `XAML:ChkAllLinksDeclared`, `XAML:ChkAllLinksObserved`, `XAML:ChkAllLinksHistory`, `XAML:ChkAllLinksConflict`, `XAML:LblAllLinksCount`, `Domenia-Main.xaml:TabLinksAll`, `Domenia-Main.xaml:ChkAllLinksDeclared`

#### REL-050 · Exporter les associations

`ameliore` · lecture locale

« Exporter tout » efface d'abord visiblement filtres et puces puis exporte toutes les associations ; « Exporter » exporte les liens visibles du sujet.

- Références D1 : `Domenia-Relations.UI.ps1:Clear-DomeniaAllLinksFilter`, `Export-DomeniaLinksCsv`, `XAML:BtnExportAllLinks`, `XAML:BtnOpenLinksCsv`, `Domenia-Core.ps1:Export-DomeniaLinksCsv`, `Domenia-Core.ps1:Get-LinkCsvPath`, `Domenia-Main.xaml:BtnOpenLinksCsv`, `Domenia-Main.xaml:BtnExportAllLinks`

#### REL-051 · Ouvrir la fiche depuis une association

`ameliore` · lecture réseau

Double-clic sur la colonne utilisateur ou poste, ou clic droit « Ouvrir l'utilisateur / Ouvrir le poste » ; DN gardé ou recherche par nom.

- Garde-fous : Geste explicite.
- Opérations : `OpenAdObject`, `OpenLinkedObject`
- Références D1 : `Domenia-Relations.UI.ps1:Open-DomeniaAllLinksCell`, `Domenia-Relations.UI.ps1:Open-DomeniaRelationEnd`, `Domenia-Relations.UI.ps1:New-DomeniaAllLinksContextMenu`, `Domenia-Relations.UI.ps1:Get-DomeniaGridHit`

#### REL-052 · Nettoyer les associations orphelines

`fait` · écriture

Contrôle les liens contre l'annuaire et liste les orphelins avec leur motif et une case chacun ; le retrait est confirmé en page, journalisé et restaurable.

- Garde-fous : Associations déclarées et importées jamais proposées ; sauvegarde vérifiée avant ; seules les lignes cochées au clic retirées ; journalisé et restaurable. Rien n'est retiré par l'analyse elle-même ; un lien à GUID n'est jamais adopté par un homonyme.
- Opérations : `PruneLinks`, `StorageBackup`, `LinkHistoryStore`
- Références D1 : `Domenia-Relations.UI.ps1:Show-DomeniaOrphanLinks`, `Domenia-Relations.UI.ps1:Request-DomeniaOrphanRemoval`, `Domenia-Relations.UI.ps1:Complete-DomeniaOrphanRemoval`, `Domenia-Relations.UI.ps1:Cancel-DomeniaOrphanRemoval`, `Domenia-Relations.UI.ps1:Select-DomeniaOrphanBatch`, `Domenia-Relations.UI.ps1:Close-DomeniaOrphanLinks`, `Domenia-Relations.UI.ps1:Update-DomeniaOrphanUi`, `Domenia-Relations.Model.ps1:Get-DomeniaOrphanReason`, `Test-DomeniaProtectedAssociationSource`, `XAML:BtnPruneLinks`, `XAML:DgLinkOrphans`, `XAML:BtnLinkOrphanRemove`, `XAML:BtnLinkOrphanConfirmApply`, `XAML:BtnLinkOrphanConfirmCancel`, `XAML:BtnLinkOrphanClose`, `Domenia-Core.ps1:Start-PruneOrphanLinks`, `Domenia-Core.ps1:Sync-DomeniaLinksAgainstIndex`, `Domenia-Main.xaml:BtnPruneLinks`, `Domenia-Main.xaml:DgLinkOrphans`, `XAML:LblLinkOrphanSummary`, `XAML:LblLinkOrphanConfirm`

<a id="pst"></a>

## Poste (PST)

117 fonctions : 81 faites, 31 améliorées, 4 partielles, 1 abandonnée.

### Connecteurs

#### PST-001 · Connecteurs en lecture seule (WAPT)

> Abandonnée sur décision de David du 22/10/2026 (« vire cette histoire de WAPT »).

`abandonne` · lecture réseau

Sources de lecture optionnelles ; seul WAPT est prévu, en lecture seule, depuis la section WAPT de la configuration (Enabled, ServerUrl). La fiche lit toujours l'annuaire d'abord : un connecteur absent, refusé ou injoignable ne retire que sa propre ligne. Un enregistrement WAPT n'est « Constaté » que s'il est récent et correspond au poste AD, sinon « Estimé ».

- Garde-fous : https seulement, sans user:password@, requête ni fragment ; seule l'origine est affichée. Lecture uniquement sur geste explicite (jamais sur sélection, minuterie ni démarrage) ; aucun connecteur n'écrit.
- Opérations : `ConnectorRead`
- Références D1 : `Domenia-Release.Model.ps1:ConvertTo-DomeniaConnectorEndpoint`, `Domenia-Release.Model.ps1:Get-DomeniaConnectorCatalog`, `Domenia-Release.Model.ps1:Test-DomeniaConnectorAvailable`, `Domenia-Release.Model.ps1:Get-DomeniaSourceReadPlan`, `Domenia-Release.Model.ps1:ConvertFrom-DomeniaWaptHost`

### Diagnostic

#### PST-002 · Verdict du diagnostic du poste

`ameliore` · lecture réseau

Transforme les lignes du diagnostic (Résolution DNS, Ping, TCP 135/445/3389/5985/5986, Session CIM, Partage C$, WinRM, transports PsExec et planificateur) en une phrase de verdict et en compteurs réussis/échecs/informations/non tentés. Un transport de repli absent ou WinRM fermé est classé Information, pas échec ; le code brut reste dans la ligne et le rapport copié.

- Garde-fous : Lancement explicite ; lecture seule ; un code inconnu ressort tel quel, aucun libellé inventé ; poste injoignable annoncé en première phrase.
- Opérations : `ComputerDiagnostics`
- Références D1 : `Domenia-Workstation.Model.ps1:ConvertTo-DomeniaDiagVerdict`, `Domenia-Workstation.Model.ps1:Get-DomeniaDiagSeverity`, `Domenia-Workstation.Model.ps1:Get-DomeniaDiagStatusLabel`, `BtnRunComputerDiag`, `BtnCompOpenDiag`, `DgComputerDiag`, `BtnCopyComputerDiag`

#### PST-003 · Diagnostic par couche réseau

`ameliore` · locale (aucune lecture)

Lit les contrôles couche par couche (nom, ICMP, transport TCP, protocole utile CIM/C$) et désigne la première étape bloquante avec une phrase explicative (pare-feu probable, RPC dynamiques filtrés, CIM refusée au compte). Un ping filtré avec un port de gestion ouvert reste un poste joignable.

- Garde-fous : ICMP seul ne bloque jamais ; une couche non tentée ne prouve rien.
- Opérations : `ComputerDiagnostics`
- Références D1 : `Domenia-Workstation.Model.ps1:Get-DomeniaNetworkLayerDiagnosis`

#### PST-004 · Diagnostic rapide borné (5 contrôles)

`fait` · lecture réseau

Plan fixe de cinq lectures seules (système, dernier démarrage, disque C:, ports 135/445/5985 sans envoi de données, services Winmgmt/RpcSs/WinRM/LanmanServer/WAPTService) avec un budget annoncé de 20 s et des faits datés (alerte sous 10 % libre, horloge postérieure). Règle écrite et testée, non raccordée à l'interface D1.

- Garde-fous : Uniquement par bouton explicite sur un seul poste ; aucun repli (ni PsExec, ni tâche planifiée) ; refus et indisponibilité ne concluent rien ; dépassement de budget signalé.
- Opérations : `ComputerQuickDiag`
- Références D1 : `Domenia-Workstation.Model.ps1:Get-DomeniaQuickDiagPlan`, `Domenia-Workstation.Model.ps1:Test-DomeniaQuickDiagAllowed`, `Domenia-Workstation.Model.ps1:ConvertTo-DomeniaQuickDiagFacts`

#### PST-005 · Diagnostic du poste

`ameliore` · lecture réseau

Résolution DNS, ping, ports 445/135/5985/5986/3389, transport PsExec (sonde SYSTEM), Task Scheduler (/query), partage C$ ouvert avec le compte poste, WinRM, session CIM, système, OS, disque système, redémarrage en attente, service de déploiement (WAPT) ; lignes classées réussi, échec, facultatif, non tenté avec verdict ; copie du rapport.

- Garde-fous : Contrôles non modifiants, tests lents ignorés si les ports ne répondent pas, budget de temps.
- Opérations : `ComputerDiagnostics`
- Références D1 : `Domenia-Core.ps1:Start-ComputerDiagnostics`, `Domenia-Core.ps1:Publish-DomeniaComputerDiagnostics`, `Domenia-Core.ps1:Fail-DomeniaComputerDiagnostics`, `Domenia-Core.ps1:Copy-ComputerDiagnostics`, `Domenia-Main.xaml:BtnRunComputerDiag`, `Domenia-Main.xaml:BtnCompOpenDiag`, `Domenia-Main.xaml:DgComputerDiag`, `BtnCompOpenDiag`, `XAML:LblComputerDiag`

#### PST-006 · Explorateur WMI en lecture seule

`fait` · lecture réseau

Charge root et ses espaces enfants directs, liste les classes d'un espace (filtrables), interroge une classe en SELECT avec WHERE optionnel et limite 1 à 500 (25 par défaut), affiche schéma (type, clé, qualificateurs) et instances ; copie et export CSV au nom du poste qui a répondu.

- Garde-fous : Aucune méthode WMI invoquée ; classes du fournisseur MSI bloquées ; noms de classe/espace validés ; filtre ≤ 2048 caractères ; ping préalable.
- Opérations : `WmiNamespaces`, `WmiClasses`, `WmiQuery`
- Références D1 : `Domenia-Core.ps1:Start-DomeniaWmiNamespaces`, `Domenia-Core.ps1:Start-DomeniaWmiClasses`, `Domenia-Core.ps1:Start-DomeniaWmiQuery`, `Domenia-Core.ps1:Apply-DomeniaWmiClassFilter`, `Domenia-Core.ps1:Copy-DomeniaWmi`, `Domenia-Core.ps1:Export-DomeniaWmi`, `Domenia-Core.ps1:Assert-DomeniaWmiReadQuery`, `Domenia-Main.xaml:TabWmi`, `Domenia-Main.xaml:LstWmiNamespaces`, `Domenia-Main.xaml:LstWmiClasses`, `Domenia-Main.xaml:TxtWmiWhere`, `Domenia-Main.xaml:TxtWmiLimit`, `XAML:BtnWmiNamespaces`, `XAML:BtnWmiClasses`, `XAML:BtnWmiQuery`, `XAML:BtnWmiCopy`, `XAML:BtnWmiExport`, `XAML:TxtWmiClassFilter`, `XAML:DgWmiSchema`, `XAML:DgWmiInstances`, `XAML:LblWmiStatus`, `XAML:LblWmiNamespaceCount`, `XAML:LblWmiClassCount`

### En-tête

#### PST-007 · En-tête fixe du poste

`ameliore` · lecture locale

Bandeau commun aux cinq vues : nom, système et version, pastille de présence, utilisateur associé (bouton ou « aucun ») et âge du dernier inventaire. Il est construit à partir des champs de la fiche et de la mémoire de session, sans lecture ni sonde, et chaque texte dit quand il ne sait pas.

- Garde-fous : Aucune sonde. « Système non renseigné dans l'annuaire » ou « Aucun inventaire dans cette session » quand l'information manque.
- Références D1 : `Domenia-Assist.Model.ps1:Get-DomeniaComputerHeaderView`, `Domenia-Assist.UI.ps1:Update-DomeniaComputerHeader`, `LblCompHeaderName`, `LblCompHeaderSystem`, `LblCompHeaderInventory`, `LblCompHeaderUser`, `LblCompHeaderNoUser`

#### PST-008 · Pastille de présence avec heure et état mémorisé

`ameliore` · locale (aucune lecture)

Pastille colorée qui traduit l'état de présence : répond au ping, ne répond pas, test en cours, test impossible, non vérifiée. Elle indique l'heure du dernier test (le plus récent entre la tentative et la réponse) et « (mémoire) » pour un état repris du cache, sans heure. L'infobulle rappelle qu'une absence d'ICMP ne prouve pas que le poste est éteint.

- Garde-fous : Un état mémorisé n'a jamais d'heure. Sans date lisible, aucune heure n'est inventée.
- Références D1 : `Domenia-Assist.Model.ps1:Get-DomeniaComputerPresenceBadge`, `Domenia-Assist.Model.ps1:Get-DomeniaPresenceObservationTime`, `Domenia-Assist.UI.ps1:Update-DomeniaComputerHeaderPresence`, `Domenia-Assist.UI.ps1:Set-DomeniaComputerHeaderPresenceTime`, `Domenia-Assist.UI.ps1:Set-DomeniaAssistTone`, `UxCompPresencePill`, `TxtCompPresence`, `XAML:LblCompHeaderPresence`

#### PST-009 · Actions rapides de l'en-tête (RDP, C$, ping, utilisateur)

`fait` · lecture réseau

Boutons de l'en-tête : Bureau à distance (mstsc), ouverture du partage C$ avec le compte des opérations poste, « Tester la réponse » (un seul ping, qui met la pastille à jour), et ouverture de la fiche de l'utilisateur associé sans écriture ni sonde.

- Garde-fous : Le ping est un seul écho ICMP. L'ouverture de l'utilisateur ne sonde pas le poste.
- Opérations : `ComputerPing`
- Références D1 : `Domenia-Assist.UI.ps1:Initialize-DomeniaAssist`, `BtnCompHeaderRdp`, `BtnCompHeaderC`, `BtnCompHeaderPing`, `BtnCompHeaderUser`, `Invoke-ComputerTool`, `Open-LinkedUserFromMachine`

### Intervenir

#### PST-010 · Autoriser une intervention sur ce poste (5 min)

`ameliore` · locale (aucune lecture)

Après confirmation, autorise pendant 5 minutes, sur le seul poste ouvert (nom DNS et nom court), les transports qui déposent un script, un service ou une tâche, pour les actions volontaires suivantes ; une pastille « Intervention autorisée m:ss · Retirer » décompte le temps, et « Retirer » révoque tout de suite.

- Garde-fous : Ne lance rien ; refusé pendant une écriture à vérifier ; vaut pour la session courante uniquement ; autorisation sur un autre poste signalée ; sondes déjà envoyées peuvent finir ; Planificateur via API, PsExec seulement en session Windows intégrée autorisée ; aucun secret en argument ; effacée au changement de session et à la fermeture.
- Opérations : `RimotteRun`
- Références D1 : `modules/Domenia-Guard.UI.ps1:Set-DomeniaArtifactConsent`, `modules/Domenia-Guard.UI.ps1:Clear-DomeniaArtifactConsent`, `modules/Domenia-Guard.UI.ps1:Update-DomeniaInterventionPill`, `modules/Domenia-Guard.UI.ps1:Get-DomeniaOpenMachineConsentTarget`, `modules/Domenia-Accounts.Model.ps1:Get-DomeniaInterventionPillState`, `modules/Domenia-Accounts.Model.ps1:Test-DomeniaConsentCovers`, `BtnCompInterventionGrant`, `BtnCompInterventionRevoke`, `UxCompInterventionPill`, `LblCompIntervention`, `LblCompInterventionState`, `BtnGuardRemote`, `BtnGuardRemoteOff`, `LblGuardRemote`, `Update-DomeniaRunProgramConsent`, `Domenia-Core.ps1:Assert-DomeniaReadFallbackPermission`, `Domenia-Core.ps1:Assert-WRemoteArtifactPermission`, `Domenia-Main.xaml:BtnCompInterventionGrant`, `Domenia-Main.xaml:BtnCompInterventionRevoke`

#### PST-011 · Autoriser une seule lecture par tâche planifiée

`fait` · locale (aucune lecture)

Quand CIM ne répond pas, l'opérateur autorise explicitement la prochaine lecture de ce poste par PsExec ou tâche planifiée (5 min, une seule lecture) ; sans cette demande, le worker rend « non lu » au lieu de basculer.

- Garde-fous : Distincte de l'autorisation d'intervention ; retirée après la lecture ; confirmation ; refusée pendant une écriture à vérifier.
- Références D1 : `modules/Domenia-Guard.UI.ps1:Set-DomeniaReadFallbackConsent`, `BtnCompReadFallback`, `BtnGuardReadFallback`, `LblGuardReadFallback`, `Domenia-Main.xaml:BtnCompReadFallback`

#### PST-012 · Carte du compte AD du poste (activer ou désactiver)

`fait` · écriture

Un seul bouton est proposé selon userAccountControl lu avec la fiche : Activer si le compte est désactivé, Désactiver sinon. Si l'UAC est illisible, aucun des deux boutons n'est montré et la carte demande de relire la fiche.

- Garde-fous : L'état du compte n'est jamais deviné. L'écriture passe par ses propres confirmations et par le mode écriture.
- Références D1 : `Domenia-Assist.Model.ps1:Get-DomeniaComputerAccountAction`, `Domenia-Assist.UI.ps1:Update-DomeniaComputerAccountCard`, `BtnCompEnable`, `BtnCompDisable`, `LblCompAccountState`

#### PST-013 · Redémarrage du poste préparé dans la page

`ameliore` · écriture

Le panneau de redémarrage s'ouvre dans Intervenir. Deux choix : différé avec message à l'utilisateur (délai Restart.DefaultDelaySeconds, borné de 1 à 60 min, 5 min par défaut) ou immédiat forcé sans message. Les sessions ouvertes sont lues d'abord, puis la confirmation dans la page affiche le plan et ces sessions.

- Garde-fous : Le redémarrage différé passe par WinRM : il est refusé et grisé si Remote.UseWinRM est faux, et « Maintenant » n'est jamais choisi d'office. Le message tient sur une ligne de 400 caractères, sans guillemets ni caractères de contrôle. L'envoi attend la lecture des sessions. Confirmation à risque Danger, envoi unique, refus si le poste, la session ou la génération ont changé, bloqué en lecture seule ou en démonstration. Poste re-vérifié identique au plan, code 1190 (arrêt déjà programmé) et 5 (accès refusé) expliqués, jamais rejoué.
- Opérations : `SessionsList`, `ComputerRestart`
- Références D1 : `Domenia-Assist.Model.ps1:Get-DomeniaRestartPlan`, `Domenia-Assist.Model.ps1:Get-DomeniaRestartDelaySeconds`, `Domenia-Assist.Model.ps1:Get-DomeniaRestartDefaultMessage`, `Domenia-Assist.UI.ps1:Request-DomeniaComputerRestart`, `Domenia-Assist.UI.ps1:Update-DomeniaComputerRestartChoice`, `Domenia-Assist.UI.ps1:Submit-DomeniaComputerRestart`, `Domenia-Assist.UI.ps1:Confirm-DomeniaComputerRestart`, `Domenia-Assist.UI.ps1:Close-DomeniaComputerRestartPanel`, `UxCompRestartPanel`, `RbCompRestartDelayed`, `RbCompRestartNow`, `TxtCompRestartMessage`, `BtnCompRestartSend`, `BtnCompRestartCancel`, `Domenia-Core.ps1:Invoke-ComputerTool (Restart)`, `Domenia-Main.xaml:BtnCompRestart`, `Domenia-Main.xaml:RbCompRestartDelayed`, `Domenia-Main.xaml:RbCompRestartNow`, `Domenia-Main.xaml:TxtCompRestartMessage`, `Domenia-Main.xaml:BtnCompRestartSend`, `XAML:LblCompRestartTitle`

#### PST-014 · Sessions lues avant le redémarrage

`ameliore` · lecture réseau

Le panneau résume les sessions lues juste avant : aucune, 1 ou N sessions (utilisateur, protocole, état, heure d'ouverture, inactivité), les sessions dont le compte n'a pas été lu et une lecture partielle. Une lecture refusée ou en échec ne conclut rien et recommande le redémarrage différé.

- Garde-fous : Seule la lecture du même poste, de la même session et de la même sélection remplit le panneau. Sans nom de poste dans la fiche, le panneau le dit au lieu d'attendre. Sessions non lues : le délai reste recommandé.
- Opérations : `SessionsList`
- Références D1 : `Domenia-Assist.Model.ps1:Get-DomeniaRestartSessionSummary`, `Domenia-Assist.UI.ps1:Update-DomeniaRestartSessions`, `LblCompRestartSessions`, `LblCompRestartSessionLines`, `Start-DomeniaSessionsRead`, `Domenia-Sessions.UI.ps1:Complete-DomeniaSessionsRead`, `Domenia-Sessions.UI.ps1:Fail-DomeniaSessionsRead`, `Update-DomeniaRestartSessions`

#### PST-015 · Actualisation des stratégies (GPUpdate) confirmée dans la page

`fait` · écriture

gpupdate /force est demandé une seule fois, par WinRM, après une confirmation dans la page qui remplace l'ancienne fenêtre. Il n'y a ni redémarrage ni fermeture de session.

- Garde-fous : Le bouton est grisé, avec son motif, si Remote.UseWinRM est faux. Rien ne part si la sélection a changé. Bloqué en lecture seule. Lecture seule levée, Remote.UseWinRM requis, un seul transport sans repli, jamais rejoué, effet « à vérifier ».
- Opérations : `ComputerGpUpdate`
- Références D1 : `Domenia-Assist.UI.ps1:Request-DomeniaComputerToolConfirmation`, `Domenia-Assist.UI.ps1:Confirm-DomeniaComputerToolRequest`, `Domenia-Assist.UI.ps1:Update-DomeniaComputerAssistPermissions`, `BtnCompGpUpdate`, `Domenia-Core.ps1:Invoke-ComputerTool (GpUpdate)`, `Domenia-Core.ps1:Complete-DomeniaComputerToolUi`, `Domenia-Core.ps1:Fail-DomeniaComputerToolUi`, `Domenia-Core.ps1:Get-DomeniaRemotePostconditionText`, `Domenia-Main.xaml:BtnCompGpUpdate`

#### PST-016 · Exécuter un programme sur le poste

`ameliore` · écriture

Lancement d'un programme du poste soit en arrière-plan sous SYSTEM sans fenêtre, soit dans la session ouverte d'un utilisateur, avec ou sans le niveau le plus élevé. Il passe par une tâche planifiée unique, créée puis supprimée. Le compte de session est prérempli avec l'utilisateur associé (DOMAINE\identifiant), et l'exécution réelle du programme n'est pas vérifiée.

- Garde-fous : Exige l'autorisation d'intervention de 5 minutes pour ce poste précis. Programme limité à 260 caractères et arguments à 1024, sans retour à la ligne ni caractère de contrôle. Le compte est validé (DOMAINE\id). Confirmation Danger, envoi unique, commande effacée à la fermeture, refusé si la sélection a changé. Autorisation d'intervention requise (Assert-WRemoteArtifactPermission), lecture seule levée, XML échappé, tâche supprimée dans tous les cas.
- Opérations : `RimotteRun`
- Références D1 : `Domenia-Assist.Model.ps1:Get-DomeniaRunProgramPlan`, `Domenia-Assist.UI.ps1:Show-DomeniaRunProgramPanel`, `Domenia-Assist.UI.ps1:Update-DomeniaRunProgramMode`, `Domenia-Assist.UI.ps1:Submit-DomeniaRunProgram`, `Domenia-Assist.UI.ps1:Confirm-DomeniaRunProgram`, `Domenia-Assist.UI.ps1:Close-DomeniaRunProgramPanel`, `UxCompRunPanel`, `RbCompRunSystem`, `RbCompRunUser`, `TxtCompRunUser`, `TxtCompRunCommand`, `TxtCompRunArguments`, `ChkCompRunElevated`, `BtnCompRunStart`, `BtnCompRunCancel`, `Start-DomeniaRimotteRun`, `Domenia-Core.ps1:Get-DomeniaRimotteWorkerCode`, `Domenia-Core.ps1:Start-DomeniaRimotteRun`, `Domenia-Core.ps1:Complete-DomeniaRimotteUi`, `Domenia-Core.ps1:Fail-DomeniaRimotteUi`, `Domenia-Main.xaml:BtnCompRimotte`, `Domenia-Main.xaml:RbCompRunSystem`, `Domenia-Main.xaml:RbCompRunUser`, `Domenia-Main.xaml:TxtCompRunCommand`, `Domenia-Main.xaml:TxtCompRunArguments`, `Domenia-Main.xaml:ChkCompRunElevated`, `XAML:LblCompRunTitle`, `XAML:LblCompRunState`

#### PST-017 · État de l'autorisation d'intervention dans le panneau d'exécution

`fait` · locale (aucune lecture)

Le panneau d'exécution affiche l'état de l'autorisation d'intervention de 5 minutes : active jusqu'à HH:mm, ou absente avec l'endroit où l'accorder. Sans elle, le bouton amène à l'écran « Autoriser une intervention (5 min) » mais n'accorde jamais l'autorisation lui-même.

- Garde-fous : L'autorisation est liée à l'époque de session, à une échéance et aux alias du poste visé.
- Références D1 : `Domenia-Assist.UI.ps1:Test-DomeniaRunProgramConsent`, `Domenia-Assist.UI.ps1:Update-DomeniaRunProgramConsent`, `LblCompRunConsent`, `BtnCompInterventionGrant`, `UxCompInterventionPill`

#### PST-018 · Copier la commande PowerShell à distance

`ameliore` · locale (aucune lecture)

Produit la commande Enter-PSSession -ComputerName 'poste', complétée de -Credential 'compte' quand un compte poste est configuré, à coller dans la console du technicien. Le mot de passe n'y figure jamais.

- Garde-fous : Les valeurs sont échappées entre apostrophes. Aucun secret dans le texte copié.
- Références D1 : `Domenia-Assist.Model.ps1:Get-DomeniaPsRemoteCommand`

#### PST-019 · Wake-on-LAN volontaire

`fait` · écriture

Envoi d'un paquet magique (102 octets, port 9) vers la diffusion dirigée du sous-réseau connu d'un seul poste, et texte d'état qui ne prétend jamais que le poste est allumé. Règle écrite, non raccordée.

- Garde-fous : Désactivé par défaut (Features.WakeOnLan) ; geste explicite ; un seul poste ; MAC valide (ni nulle, ni diffusion, ni multicast) ; sous-réseau /8 à /30 entièrement dans un périmètre autorisé.
- Opérations : `WakeOnLanSend`
- Références D1 : `Domenia-Workstation.Model.ps1:Test-DomeniaMacAddress`, `Domenia-Workstation.Model.ps1:New-DomeniaWakePacket`, `Domenia-Workstation.Model.ps1:Get-DomeniaBroadcastAddress`, `Domenia-Workstation.Model.ps1:Test-DomeniaWakeIpv4InNetwork`, `Domenia-Workstation.Model.ps1:Test-DomeniaWakeAllowed`, `Domenia-Workstation.Model.ps1:Get-DomeniaWakeState`

#### PST-020 · Ouvrir Pesto ou FILPRO avec le contexte

`fait` · locale (aucune lecture)

Lit le contrat suite-contract.json (DomeniaSuiteContract/1) de l'outil et ne transmet que les champs déclarés et validés (nom et GUID du poste, login et GUID de l'utilisateur, domaine) ; sans contrat, ouverture sans argument.

- Garde-fous : Geste explicite seulement ; jamais de shell ni de secret ; option en double, champ ou valeur non autorisés refusés ; contrat ≤ 16 Kio. Chemin absolu .exe exigé ; aucun point d'analyse sur la chaîne ; empreinte différente = aucune exécution ; configuration requise sinon message.
- Références D1 : `Domenia-Workstation.Model.ps1:Test-DomeniaSuiteContract`, `Domenia-Workstation.Model.ps1:Get-DomeniaSuiteLaunchPlan`, `Domenia-Workstation.Model.ps1:Get-DomeniaSuiteContextFields`, `BtnGuardPesto`, `BtnGuardFilPro`, `modules/Domenia-Guard.UI.ps1:Open-DomeniaSuiteTool`

#### PST-021 · Enregistrer la fiche poste

`ameliore` · écriture

Écrit description, location et managedBy du compte ordinateur.

- Garde-fous : Plan, confirmation, précondition relue.
- Opérations : `WriteAttributes`
- Références D1 : `Domenia-Core.ps1:Save-ComputerProfile`, `Domenia-Main.xaml:BtnCompSave`

#### PST-022 · Outils Windows ouverts sur le poste

`fait` · lecture réseau

Bureau à distance (mstsc /v), Ouvrir le disque C (connexion SMB préalable avec le compte des opérations poste), Gestion de l'ordinateur, Observateur d'événements et Services (via IPC$), Copier la commande PowerShell distante.

- Garde-fous : Nom de poste validé (NetBIOS/DNS) ; mot de passe transmis à l'API Windows seulement ; indisponible en démonstration.
- Opérations : `ComputerAdminShare`
- Références D1 : `Domenia-Core.ps1:Invoke-ComputerTool`, `Domenia-Core.ps1:Start-DomeniaAdminShareOpen`, `Domenia-Core.ps1:Complete-DomeniaAdminShareOpen`, `Domenia-Core.ps1:Fail-DomeniaAdminShareOpen`, `Domenia-Core.ps1:Start-DomeniaComputerToolProcess`, `Domenia-Core.ps1:Get-DomeniaNetUseSource`, `Domenia-Main.xaml:BtnCompRdp`, `Domenia-Main.xaml:BtnCompC`, `Domenia-Main.xaml:BtnCompManage`, `Domenia-Main.xaml:BtnCompEvents`, `Domenia-Main.xaml:BtnCompServices`, `Domenia-Main.xaml:BtnCompPSRemote`, `Domenia-Main.xaml:BtnCompHeaderRdp`, `Domenia-Main.xaml:BtnCompHeaderC`, `BtnCompServices`

#### PST-023 · Replis distants PsExec puis tâche planifiée

> Reste à faire : PsExec portable non livré (aucune dépendance sans accord de David) et transports réels (tâche planifiée RunOnce par l’API COM, ADMIN$) avec Domenia.Inventory en vague 3 ; la lecture de repli autorisée une fois, consommée par l’inventaire, les logiciels, le diagnostic ou la détection de l’utilisateur, et « non lu » sans elle, sont en place (simulation).

`partiel` · lecture réseau

Quand WMI/WinRM échouent : d'abord PsExec portable (≈35 % du budget, 10–15 s), puis tâche planifiée RunOnce via l'API COM du planificateur et ADMIN$ authentifié ; le budget total couvre les deux et l'échec cite les trois méthodes.

- Garde-fous : Une lecture ne bascule jamais seule sur un transport intrusif : autorisation propre à la lecture, consommée une fois ; artefacts nettoyés ; permissions du dépôt seulement.
- Opérations : `ComputerInventory`, `SoftwareInventory`, `ComputerDiagnostics`, `ComputerLastUser`
- Références D1 : `Domenia-Core.ps1:Invoke-WRemoteTaskScript`, `Domenia-Core.ps1:Invoke-WRemotePsExecScript`, `Domenia-Core.ps1:Invoke-WRemoteScheduledTaskScript`, `Domenia-Core.ps1:Invoke-WSchtasksRemote`, `Domenia-Core.ps1:New-WRunOnceTaskXml`, `Domenia-Core.ps1:New-WAdminShareDrive`, `Domenia-Core.ps1:Get-WPsExecPath`, `Domenia-Core.ps1:Get-WSchtasksHint`

#### PST-024 · Compte ordinateur dans AD

`fait` · écriture

Activer/désactiver, ajouter/retirer à un groupe, renommer l'objet dans AD (nom 1 à 63 caractères alphanumériques et tirets, le poste Windows n'est pas renommé), déplacer vers une OU.

- Garde-fous : Capacité Move pour renommer, identité exacte exigée, nom relu.
- Opérations : `WriteRenameComputer`, `WriteAccountDisabled`, `WriteObjectGroup`, `WriteMoveObject`
- Références D1 : `Domenia-Core.ps1:Rename-ComputerObject`, `Domenia-Core.ps1:Set-AccountDisabled`, `Domenia-Core.ps1:AddOrRemoveObjectGroup`, `Domenia-Core.ps1:Move-DomeniaSelectedComputerWithOuPicker`, `Domenia-Main.xaml:TxtCompNewName`, `Domenia-Main.xaml:BtnCompRename`, `Domenia-Main.xaml:BtnCompAddGroup`, `Domenia-Main.xaml:BtnCompRemoveGroup`

### Inventaire

#### PST-025 · Logiciels tirés de l'inventaire déjà lu

`fait` · lecture locale

Remplit l'onglet Logiciels avec les noms et versions déjà lus par l'inventaire rapide, avec un texte de provenance et une synthèse déclarée non calculée.

- Garde-fous : Aucune lecture réseau à l'ouverture de l'onglet. Éditeur, date, taille et désinstallation jamais inventés ; « Charger les logiciels » relit le poste en complet.
- Opérations : `ComputerInventory`
- Références D1 : `Domenia-Assist.UI.ps1:Initialize-DomeniaAssist`, `ComputerDetailTabs`, `TabSoftware`, `Show-DomeniaSoftwareFromInventory`, `Domenia-Workstation.Model.ps1:ConvertTo-DomeniaSoftwareFromInventory`, `DgSoftware`, `BtnLoadSoftware`

#### PST-026 · Libellés lisibles de l'inventaire

`fait` · locale (aucune lecture)

Traduit les codes CIM de la colonne Valeur : rôle dans le domaine, type de châssis (liste), langue (LANGID), état et vitesse des cartes réseau (« Connectée, 1 Gb/s »), méthode BitLocker, état SMART, résultat des tâches planifiées.

- Garde-fous : Table fermée : valeur inconnue rendue brute ; valeur brute conservée dans l'infobulle, le presse-papiers et l'export.
- Opérations : `ComputerInventory`
- Références D1 : `Domenia-Workstation.Model.ps1:Get-DomeniaInventoryValueText`, `Domenia-Workstation.Model.ps1:Get-DomeniaInventoryMapText`, `DgInventory`

#### PST-027 · Décodage des tâches planifiées

`fait` · locale (aucune lecture)

Interprète le dernier résultat d'une tâche (codes SCHED_S_\* : prête, en cours, désactivée, jamais exécutée…) et décode les dates d'enregistrement et de dernier démarrage du cache registre DynamicInfo quand WinRM manque.

- Garde-fous : Seules deux dates communes à toutes les versions sont décodées (2000-2100) ; le dernier résultat n'est jamais deviné.
- Opérations : `ComputerInventory`
- Références D1 : `Domenia-Workstation.Model.ps1:ConvertFrom-DomeniaTaskResultCode`, `Domenia-Workstation.Model.ps1:ConvertFrom-DomeniaTaskCacheDynamicInfo`

#### PST-028 · Démarrage automatique sans arguments

`fait` · locale (aucune lecture)

Ne conserve que l'exécutable d'une commande de démarrage (premier jeton ou chemin entre guillemets), jamais ses arguments.

- Garde-fous : Protection des secrets passés en arguments ; copie identique dans le worker d'inventaire.
- Opérations : `ComputerInventory`
- Références D1 : `Domenia-Workstation.Model.ps1:Get-DomeniaCommandExecutable`

#### PST-029 · Relecture de l'inventaire mémorisé

`fait` · lecture locale

À l'ouverture du poste, réaffiche le dernier inventaire classique validé en base locale avec sa date de collecte.

- Garde-fous : Une lecture tardive du cache ne remplace jamais un inventaire plus récent déjà affiché ; GUID et DN du poste vérifiés.
- Opérations : `LocalIndexRead`
- Références D1 : `Domenia-Park.UI.ps1:Complete-DomeniaCachedInventoryRead`, `Domenia-Park.UI.ps1:Test-DomeniaClassicResultCurrent`

#### PST-030 · Détection inventaire rapide ou complet

`fait` · locale (aucune lecture)

Reconnaît un inventaire complet aux catégories qu'il est seul à lire (Processus, Événements système, Tâches planifiées, Certificats machine) pour signaler les widgets qui exigent l'inventaire complet.

- Opérations : `ComputerInventory`
- Références D1 : `Domenia-WidgetCollect.Model.ps1:Test-DomeniaComputerInventoryDeep`, `BtnRunInventory`, `BtnRunInventoryDeep`, `BtnDashboardInventory`, `BtnDashboardInventoryDeep`

#### PST-031 · Préréglages d'événements bornés

`fait` · lecture réseau

Cinq préréglages (démarrage/arrêt 6005/6006/6008/41/1074, plantages 1000/1001, disque 7/11/51/153, stratégie de groupe 1085/1125/7016, mises à jour 19/20/43), fenêtre 1 à 720 h, 1 à 200 événements, attribution à l'utilisateur par SID ou au poste par nom. Règle écrite, non raccordée en D1.

- Garde-fous : Refus, réponse sans liste, lecture partielle ou volume plafonné ne deviennent jamais « aucun événement » ; valeurs bornées signalées (Clamped).
- Opérations : `ComputerEventsRead`
- Références D1 : `Domenia-Workstation.Model.ps1:Get-DomeniaEventPresets`, `Domenia-Workstation.Model.ps1:New-DomeniaEventQuery`, `Domenia-Workstation.Model.ps1:ConvertTo-DomeniaEventFacts`

#### PST-032 · Bruit des erreurs système du tableau du poste

`fait` · locale (aucune lecture)

Règles en données : DCOM 10016 ignoré, disque, NTFS et Kernel-Power 41 en point à surveiller, toute autre erreur du journal Système en information.

- Garde-fous : Décision David 2026-10-08 (MO-06), aucun fichier runtime.
- Opérations : `ComputerInventory`
- Références D1 : `Domenia-Workstation.Model.ps1:Get-DomeniaWorkstationNoiseRules`, `Domenia-Workstation.Model.ps1:Get-DomeniaSystemEventLevel`

#### PST-033 · Analyse de dsregcmd /status

`fait` · locale (aucune lecture)

Analyse un texte dsregcmd collé (128 Kio max) : jonction AD, Entra ID, mode hybride, authentification de l'appareil, nom du poste du texte ; état SSO (PRT, Windows Hello, Workplace) seulement si collecté dans la session de l'utilisateur final sous son compte. Règle écrite, non raccordée.

- Garde-fous : Rien n'est exécuté ni réparé ; texte d'un autre poste signalé ; session admin ou non déclarée → SSO non évaluable.
- Opérations : `JoinStateRead`
- Références D1 : `Domenia-Workstation.Model.ps1:ConvertFrom-DomeniaDsregStatus`, `Domenia-Workstation.Model.ps1:Get-DomeniaJoinStateFacts`, `Domenia-Workstation.Model.ps1:Test-DomeniaDsregAccountMatch`

#### PST-034 · Faits de mise à jour par fournisseur

`fait` · locale (aucune lecture)

Pour Windows Update, l'agent WAPT ou un autre fournisseur : date, source et résultat de la dernière information, marquée ancienne au-delà de 30 jours (1 à 3650). Règle écrite, non raccordée.

- Garde-fous : Fournisseur absent = non détecté, jamais panne ; rien n'est installé ni relancé ; date future signalée.
- Opérations : `UpdateStateRead`
- Références D1 : `Domenia-Workstation.Model.ps1:ConvertTo-DomeniaUpdateFacts`

#### PST-035 · Charge processeur par processus

`ameliore` · locale (aucune lecture)

Part du processeur de chaque processus entre deux lectures de Win32_Process espacées (temps CPU / intervalle × processeurs logiques).

- Garde-fous : Processus démarré, terminé ou PID réutilisé : aucune part ; pseudo-processus inactif exclu ; rien n'est extrapolé.
- Opérations : `ComputerInventory`
- Références D1 : `Domenia-Readings.Model.ps1:Measure-DomeniaProcessLoad`

#### PST-036 · Reprise de l'inventaire déjà lu du poste

`fait` · locale (aucune lecture)

À la sélection d'un poste déjà inventorié dans la session, sa dernière lecture est réaffichée avec son âge.

- Garde-fous : Lignes du nouvel objet seulement.
- Références D1 : `Domenia-Selection.UI.ps1:Enter-DomeniaSelectionContext`, `Show-DomeniaCachedInventory`

#### PST-037 · Inventaire rapide ou complet du poste

`ameliore` · lecture réseau

Ping d'abord, sonde TCP DCOM/WinRM, puis sources isolées : système, BIOS et Secure Boot, carte mère, processeur, mémoire, OS, site AD et proxy, disques logiques et physiques, BitLocker, TPM, réseau, pare-feu, antivirus, correctifs, WSUS, logiciels, démarrage auto, services en défaut, périphériques en erreur, affichage, batterie, pilotes non signés, sessions, administrateurs locaux, partages, imprimantes, redémarrage en attente ; le complet ajoute processus, événements système, tâches planifiées, certificats machine et connexions réseau.

- Garde-fous : Budgets internes 55 s / 150 s sous le délai de tâche (110 / 260 s), résultat partiel plutôt que perte ; poste muet au ping : WMI non lancé ; arguments de commande retirés.
- Opérations : `ComputerInventory`
- Références D1 : `Domenia-Core.ps1:Start-DomeniaComputerInventory`, `Domenia-Core.ps1:Get-DomeniaInventoryWorkerCode`, `Domenia-Core.ps1:Invoke-Collector`, `Domenia-Core.ps1:Invoke-InventoryTaskFallback`, `Domenia-Core.ps1:Get-InventoryControllerClockOffset`, `Domenia-Core.ps1:ConvertFrom-DomeniaTaskCacheDynamicInfo`, `Domenia-Main.xaml:BtnRunInventory`, `Domenia-Main.xaml:BtnRunInventoryDeep`, `Domenia-Main.xaml:BtnDashboardInventory`

#### PST-038 · Rapport d'accès par source d'inventaire

`fait` · locale (aucune lecture)

Chaque source rend OK, VIDE, PARTIEL, REFUSE, INDISPONIBLE, INJOIGNABLE, IGNORE ou ERREUR avec détail, durée, nombre d'éléments et transport (DCOM, WinRM, PsExec, tâche).

- Garde-fous : Un refus sur une source n'empêche pas les autres.
- Références D1 : `Domenia-Core.ps1:Add-Access`, `Domenia-Core.ps1:Get-FailureStatus`, `Domenia-Core.ps1:Get-DomeniaInventorySummaryText`, `Domenia-Main.xaml:DgInventoryAccess`

#### PST-039 · Affichage, copie et export de l'inventaire

`fait` · locale (aucune lecture)

Filtre par catégorie, valeurs CIM traduites en libellés (valeur brute en info-bulle et à l'export), ligne d'âge « Inventaire d'il y a n », reprise de la dernière lecture de la session, copie texte, export CSV (deux fichiers nommés avec le poste).

- Garde-fous : Cache de session jamais écrit sur disque (droits de lecture de l'opérateur).
- Références D1 : `Domenia-Core.ps1:Apply-DomeniaInventoryFilter`, `Domenia-Core.ps1:Update-DomeniaInventoryCategories`, `Domenia-Core.ps1:Complete-DomeniaInventoryUi`, `Domenia-Core.ps1:Update-DomeniaInventoryAgeLine`, `Domenia-Core.ps1:Show-DomeniaCachedInventory`, `Domenia-Core.ps1:Get-DomeniaInventoryReportText`, `Domenia-Core.ps1:Copy-DomeniaInventory`, `Domenia-Core.ps1:Export-DomeniaInventory`, `Domenia-Core.ps1:Get-DomeniaInventoryAgeLabel`, `Domenia-Main.xaml:CmbInventoryCategory`, `Domenia-Main.xaml:DgInventory`, `XAML:BtnCopyInventory`, `XAML:BtnExportInventory`, `XAML:LnkInventoryRefresh`, `XAML:LblInventoryStatus`, `XAML:LblInventoryAge`

### Logiciels

#### PST-040 · Synthèse des logiciels du poste

`ameliore` · locale (aucune lecture)

Tuiles : nombre de logiciels et d'éditeurs, taille déclarée totale, installés ces 30 jours (dernier nommé), installés en plusieurs versions, en double (même nom et version sur plusieurs architectures/portées/profils), sans éditeur, composants d'exécution (Visual C++, .NET, WebView2), navigateurs et versions majeures.

- Garde-fous : Sans date = « Sans date » (jamais 0 rassurant) ; aucune famille = « Aucun » grisé ; rien n'est fusionné pour les doublons.
- Opérations : `SoftwareInventory`
- Références D1 : `Domenia-Dashboard.UI.ps1:Update-DomeniaSoftwareDashboard`, `Domenia-BoardSoftware.Model.ps1:Get-DomeniaSoftwareBoardData`, `Domenia-BoardSoftware.Model.ps1:Get-DomeniaSoftwareFamily`, `LblSoftwareDashboard`, `PnlSoftwareDashboard`, `software.count`, `software.size`, `software.recent`, `software.multiversion`, `software.duplicates`, `software.nopublisher`, `software.runtime`, `software.browsers`

#### PST-041 · Répartition des logiciels

`ameliore` · locale (aucune lecture)

Anneaux éditeurs (6 + Autres), architecture 32/64 bits, portée machine/utilisateur, et barres des 8 plus gros logiciels (libellés distingués par version, portée puis architecture, taille lisible).

- Garde-fous : Tri entièrement départagé (Sort-Object instable en 5.1).
- Références D1 : `Domenia-BoardSoftware.Model.ps1:Get-DomeniaSoftwareBoardData`, `software.publishers`, `software.architecture`, `software.scope`, `software.largest`

#### PST-042 · Filtrer la liste des logiciels par clic sur un graphique

`ameliore` · locale (aucune lecture)

Un clic sur une part (éditeur, architecture) ou une barre (nom) filtre la liste ; second clic sur la même part le retire ; la portée pilote son sélecteur ; pastille « Filtré : … » avec bouton ✕.

- Garde-fous : Champ inconnu ou vide ne garde rien ; parts « Autres » et « non renseigné » non cliquables ; filtre perdu à une nouvelle lecture.
- Références D1 : `Domenia-BoardSoftware.Model.ps1:Test-DomeniaSoftwareRowMatchesSelect`, `Domenia-BoardSoftware.Model.ps1:Get-DomeniaSoftwareSelectToggle`, `Domenia-BoardSoftware.Model.ps1:Get-DomeniaSoftwareSelectLabel`, `Domenia-Core.ps1:Request-DomeniaSoftwareChartFilter`, `Domenia-Widgets.UI.ps1:Get-DomeniaBoardSelectHandler`, `LblSoftwareFilterChip`, `BtnSoftwareFilterClear`, `CmbSoftwareScope`

#### PST-043 · Colonnes de la grille Logiciels

`fait` · locale (aucune lecture)

Une table unique décide les colonnes visibles : colonnes techniques (Emplacement, Désinstallation, Source) derrière « Colonnes », colonnes non lues masquées quand la liste vient de l'inventaire.

- Garde-fous : Une colonne vide n'est pas affichée (elle se lirait « pas de désinstallation ») ; en-tête inconnu laissé visible.
- Références D1 : `Domenia-Workstation.Model.ps1:Get-DomeniaSoftwareColumnVisibility`, `BtnSoftwareColumns`

#### PST-044 · Détail par portée de lecture des logiciels

`fait` · locale (aucune lecture)

Résume en une ligne ce qui a été lu par portée (Machine, Utilisateur, Store) : lu, lu rien trouvé, partiel, refusé, injoignable, avec le nombre d'éléments.

- Garde-fous : État inconnu rendu tel quel ; portée non rapportée non mentionnée.
- Opérations : `SoftwareInventory`
- Références D1 : `Domenia-Workstation.Model.ps1:Get-DomeniaSoftwareAccessSummary`, `ExpSoftwareAccess`, `DgSoftwareAccess`, `ChkSoftwarePerUser`, `ChkSoftwareStore`, `ChkSoftwareUpdates`, `XAML:LblSoftwareAccessSummary`

#### PST-045 · Sources et couverture de l'inventaire logiciel

`fait` · locale (aucune lecture)

Catalogue des sources admises (Uninstall 64 et 32 bits, SCCM Win32Reg_AddRemovePrograms, ruches HKU chargées, Appx par WinRM) et calcul des catégories non couvertes après lecture. Règle écrite, raccordement partiel.

- Garde-fous : Aucune classe du fournisseur MSI n'est une source ; source inconnue refusée ; deux lignes d'une source gardent le statut le moins concluant.
- Opérations : `SoftwareInventory`
- Références D1 : `Domenia-Workstation.Model.ps1:Get-DomeniaSoftwareSources`, `Domenia-Workstation.Model.ps1:ConvertFrom-DomeniaSoftwareAccess`

#### PST-046 · Logiciels installés

`fait` · lecture réseau

Portée machine (registre Uninstall x64/x86 via WinRM, inventaire SCCM, registre unitaire StdRegProv), portée utilisateur (ruches HKU chargées), applications Store (Appx via WinRM), option mises à jour ; une ligne par entrée, profils par SID, déduplication SCCM ; repli tâche locale seulement si l'inventaire machine est vide.

- Garde-fous : Jamais Win32_Product ; 400 clés max ; délai 130 / 200 s ; lecture ratée jamais masquée par l'inventaire.
- Opérations : `SoftwareInventory`
- Références D1 : `Domenia-Core.ps1:Start-DomeniaSoftwareInventory`, `Domenia-Core.ps1:Get-DomeniaSoftwareWorkerCode`, `Domenia-Core.ps1:Add-Software`, `Domenia-Core.ps1:Complete-DomeniaSoftwareUi`, `Domenia-Core.ps1:Fail-DomeniaSoftwareUi`, `Domenia-Main.xaml:BtnLoadSoftware`, `Domenia-Main.xaml:ChkSoftwarePerUser`, `Domenia-Main.xaml:ChkSoftwareStore`, `Domenia-Main.xaml:ChkSoftwareUpdates`, `XAML:LblSoftwareStatus`

#### PST-047 · Vues et filtres des logiciels

`fait` · locale (aucune lecture)

Affichage Liste ou Synthèse (graphiques), clic sur une part filtrant la liste avec pastille et ✕, colonnes techniques à la demande, filtre texte, portée (Toutes, Machine, Utilisateur, Store), détail par portée, reprise de la liste de l'inventaire à l'ouverture de l'onglet, copie et export (fichier nommé selon la provenance).

- Garde-fous : Provenance de la liste toujours dite ; filtre graphique effacé à une nouvelle lecture.
- Références D1 : `Domenia-Core.ps1:Apply-DomeniaSoftwareFilter`, `Domenia-Core.ps1:Update-DomeniaSoftwareColumnVisibility`, `Domenia-Core.ps1:Update-DomeniaSoftwareSyntheseVisibility`, `Domenia-Core.ps1:Update-DomeniaSoftwareAccessSummary`, `Domenia-Core.ps1:Update-DomeniaSoftwareFilterChip`, `Domenia-Core.ps1:Request-DomeniaSoftwareChartFilter`, `Domenia-Core.ps1:Clear-DomeniaSoftwareChartFilter`, `Domenia-Core.ps1:Show-DomeniaSoftwareFromInventory`, `Domenia-Core.ps1:Copy-DomeniaSoftware`, `Domenia-Core.ps1:Export-DomeniaSoftware`, `Domenia-Main.xaml:CmbSoftwareView`, `Domenia-Main.xaml:CmbSoftwareScope`, `Domenia-Main.xaml:BtnSoftwareColumns`, `Domenia-Main.xaml:DgSoftware`, `XAML:BtnCopySoftware`, `XAML:BtnExportSoftware`, `XAML:TxtSoftwareFilter`

### Navigation et garde-fous

#### PST-048 · Cinq vues du poste et anciennes routes

`ameliore` · locale (aucune lecture)

Assistance poste est organisée en cinq vues (Vue d'ensemble, Intervenir, Détails, Diagnostic, Secrets). Les anciens noms d'onglets (TabSessions, TabComputerServices, TabInventory, TabSoftware, TabWmi, TabComputerChecks, TabComputerDashboard) mènent à la bonne vue, au bon onglet interne et à la bonne section. Un nom inconnu laisse la vue actuelle.

- Garde-fous : Un nom inconnu ne fait rien (Known=false). Un sous-onglet masqué n'est jamais sélectionné.
- Références D1 : `Domenia-Assist.Model.ps1:Get-DomeniaComputerViewNames`, `Domenia-Assist.Model.ps1:Resolve-DomeniaComputerViewRoute`, `Domenia-Assist.UI.ps1:Select-DomeniaComputerView`, `Domenia-Assist.UI.ps1:Show-DomeniaAssistSection`, `ComputerTabs`, `ComputerDetailTabs`, `ComputerDiagTabs`, `Domenia-Main.xaml:WsComputer`, `Domenia-Main.xaml:ComputerTabs`, `Domenia-Main.xaml:ComputerDetailTabs`, `XAML:TabComputerAdmin`, `XAML:TabComputerHealth`, `XAML:TabInventory`, `XAML:TabSecurity`, `XAML:TabComputerDetails`, `XAML:TabComputerChecks`

#### PST-049 · Retrait des actions préparées au changement de poste

`fait` · locale (aucune lecture)

À chaque nouvelle sélection, les panneaux de redémarrage et d'exécution du poste précédent sont fermés, les demandes en attente (GPUpdate, service) sont retirées et la liste des services est vidée.

- Garde-fous : Une action préparée pour un poste ne peut pas partir sur un autre.
- Références D1 : `Domenia-Assist.UI.ps1:Reset-DomeniaComputerAssistViews`

### Présence

#### PST-050 · Tester la réponse du poste (ping enregistré)

`fait` · lecture réseau

Ping sans compte du poste sélectionné (ou du poste associé depuis la fiche utilisateur), enregistré en base avant affichage ; la pastille d'en-tête prend l'heure de l'observation.

- Garde-fous : Identité AD (GUID) requise ; valeurs affichées gardent leur date jusqu'à l'enregistrement. Geste explicite.
- Opérations : `LiveSelectedPing`, `LocalStore`, `ComputerPing`
- Références D1 : `Domenia-Park.UI.ps1:Start-DomeniaCommittedPresence`, `Domenia-Park.UI.ps1:Complete-DomeniaCommittedPresence`, `Domenia-Park.UI.ps1:Publish-DomeniaCommittedPresence`, `BtnCompHeaderPing`, `BtnCompPing`, `TxtCompPresence`, `TxtUserPresence`, `TxtObjPresence`, `Domenia-Core.ps1:Invoke-ComputerTool (Ping)`, `Domenia-Main.xaml:BtnCompPing`, `Domenia-Main.xaml:BtnCompHeaderPing`

#### PST-051 · Vérification à l'ouverture de la fiche du poste

`fait` · lecture réseau

Ouvrir la fiche d'un poste sélectionné dans la liste lance son ping (et l'utilisateur console si l'option est cochée) et met à jour présence, utilisateur associé, origine et date de l'association.

- Garde-fous : Aucune seconde sonde plus lourde à la réouverture ; observations précédentes restent datées.
- Opérations : `LiveConsole`, `LiveSelectedPing`
- Références D1 : `Domenia-Live.UI.ps1:Request-DomeniaLiveSelectedProbe`, `Domenia-Live.UI.ps1:Complete-DomeniaLiveStored`, `LblLinkProbeStatus`, `TxtCompLinkedUser`, `TxtCompLinkSource`, `TxtCompLinkWhen`

#### PST-052 · Relevé du poste ouvert et son arrêt

`ameliore` · lecture réseau

Le poste ouvert dans Poste a sa propre portée de relevé (requêtes de son tableau), avec état et bouton Arrêter, indépendante du relevé de la liste.

- Garde-fous : Un relevé d'une portée ne bloque jamais l'autre ; relevé d'un autre poste nommé.
- Opérations : `LiveConsole`
- Références D1 : `Domenia-Park.UI.ps1:Get-DomeniaParkRunSlot`, `Domenia-Park.UI.ps1:Test-DomeniaParkRunOnOpenComputer`, `Domenia-Park.UI.ps1:Update-DomeniaParkControls`, `BtnComputerParkStop`, `Domenia-Main.xaml:BtnComputerParkStop`, `XAML:LblComputerParkStatus`, `XAML:UxComputerParkRun`

### Secrets

#### PST-053 · Lister les clés BitLocker (métadonnées seulement)

`fait` · lecture réseau

Liste les objets de récupération sous le poste (nom, DN, identifiant de récupération, date de création) sans demander msFVE-RecoveryPassword ; aucune clé n'est lue ni affichée, la ligne indique « Métadonnées : clé non lue ».

- Garde-fous : 256 objets max, OneLevel ; aucun résultat ne prouve pas l'absence de clé ; refus mémorisé pour ce poste, refus d'authentification limité à la ressource BitLocker (jamais au canal annuaire) ; proposition d'un autre compte ; résultat obsolète ignoré ; index local des secrets (compte, verdict) sans valeur ; Features.BitLockerKeySelection et SecretSingleCopy. Métadonnées seulement ; clé demandée uniquement pour un enfant direct du poste.
- Opérations : `ReadBitLockerList`
- Références D1 : `modules/Domenia-Secrets.Worker.ps1:Get-DomeniaBitLockerListWorkerCode`, `modules/Domenia-Secrets.UI.ps1:Complete-DomeniaBitLockerListUi`, `modules/Domenia-Secrets.UI.ps1:Test-DomeniaBitLockerKeySelection`, `BtnLoadBitLocker`, `DgSecrets`, `LblSecretsStatus`, `Domenia-Access.Model.ps1:ConvertTo-DomeniaBitLockerKeyList`, `Domenia-Access.Model.ps1:Test-DomeniaDirectChildDn`, `Domenia-Core.ps1:Update-SecretsGrid`, `Domenia-Core.ps1:Toggle-SecretsVisibility`, `Domenia-Main.xaml:BtnLoadBitLocker`

#### PST-054 · Retrouver une clé par son identifiant de récupération

`fait` · locale (aucune lecture)

Champ de saisie des premiers caractères de l'identifiant affiché par le poste (8 suffisent) : filtre local sur les métadonnées déjà lues, et sélection automatique de la ligne si la correspondance est unique.

- Garde-fous : Aucun appel réseau, rien révélé par la recherche.
- Références D1 : `modules/Domenia-Secrets.UI.ps1:Invoke-DomeniaBitLockerRecoveryIdFilter`, `Find-DomeniaBitLockerKey`, `TxtBitLockerRecoveryId`, `LblBitLockerRecoveryHint`, `Domenia-Access.Model.ps1:Find-DomeniaBitLockerKey`, `Domenia-Main.xaml:TxtBitLockerRecoveryId`

#### PST-055 · Lire une seule clé BitLocker choisie

`ameliore` · lecture réseau

Sur geste explicite (« Lire et afficher cette clé » ou « Copier la clé BitLocker »), lit uniquement la clé sélectionnée par une recherche Base sur son DN, après avoir vérifié qu'elle est un enfant direct du poste sélectionné et porte l'identifiant attendu ; les autres clés ne sont pas lues.

- Garde-fous : Jamais à l'ouverture de l'onglet ; sélection et génération de la fiche revérifiées ; contrôle enfant direct côté interface et worker ; identifiant différent (Mismatch) = aucune valeur ; clé illisible = AccessDenied ; refus/défaut connu = proposition d'un autre compte sans lecture ; boutons secrets désactivés pendant 40 s max ; valeurs des réponses obsolètes effacées.
- Opérations : `ReadBitLockerKey`
- Références D1 : `modules/Domenia-Secrets.UI.ps1:Request-DomeniaBitLockerKey`, `modules/Domenia-Secrets.UI.ps1:Complete-DomeniaBitLockerKeyUi`, `modules/Domenia-Secrets.UI.ps1:Fail-DomeniaBitLockerKeyUi`, `modules/Domenia-Secrets.Worker.ps1:Get-DomeniaBitLockerKeyWorkerCode`, `BtnToggleSecrets`, `BtnCopySecret`

#### PST-056 · Carte de la clé BitLocker (8 blocs, compte à rebours)

`ameliore` · lecture réseau

La clé révélée s'affiche seule dans une carte en huit blocs numérotés avec son identifiant de récupération (et GUID) à comparer avec l'écran du poste avant de dicter, un anneau et un compte à rebours de 30 s, « Prolonger 30 s » une seule fois et « Masquer maintenant ».

- Garde-fous : Une seule prolongation ; la minuterie d'expiration reste seule à masquer (le compte à rebours masque aussi si l'échéance est dépassée) ; rien n'est relu ni copié par ces boutons. Valeur ni gardée ni écrite.
- Opérations : `ReadBitLockerKey`
- Références D1 : `modules/Domenia-Secrets.UI.ps1:Update-DomeniaSecretsView`, `modules/Domenia-Secrets.UI.ps1:Get-DomeniaRevealedBitLockerKey`, `modules/Domenia-Secrets.UI.ps1:Update-DomeniaSecretRevealCountdown`, `modules/Domenia-Secrets.UI.ps1:Invoke-DomeniaSecretRevealExtension`, `modules/Domenia-Access.Model.ps1:Get-DomeniaSecretRevealCountdown`, `BitLockerKeyCard`, `BitLockerKeyBlocks`, `BitLockerKeyRing`, `LblBitLockerKeyCountdown`, `LblBitLockerKeyCardId`, `BtnBitLockerKeyExtend`, `BtnBitLockerKeyHide`, `Timer:SecretCountdown`, `Domenia-Access.Model.ps1:ConvertTo-DomeniaBitLockerKeyBlocks`, `Domenia-Main.xaml:BtnBitLockerKeyExtend`, `Domenia-Main.xaml:BtnBitLockerKeyHide`

#### PST-057 · Révélation d'une seule valeur à la fois

`fait` · locale (aucune lecture)

Révèle une seule valeur LAPS ou BitLocker choisie pendant la durée de la politique (30 s), la masque à l'échéance, sur « Masquer », à une autre sélection, à la désactivation de la fenêtre ou sur « Vider » ; la ligne reste sélectionnée, masquée, pour la réafficher d'un clic sans nouvelle lecture. « Copier tout » est désactivé.

- Garde-fous : Minuterie protégée active même fenêtre réduite ; valeur jamais journalisée, mise en cache, exportée ni dans un reçu ; durée de vie mémoire limitée (Restart-DomeniaSecretLifetime). Ouvrir un onglet ou sélectionner ne révèle rien ; geste explicite sur une seule valeur. Limite de l'historique du presse-papiers rappelée à chaque copie ; aucun menu de copie générique sur la grille ; copie journalisée sans valeur.
- Références D1 : `modules/Domenia-Secrets.UI.ps1:Start-DomeniaSecretReveal`, `modules/Domenia-Secrets.UI.ps1:Start-DomeniaSecretRevealExpiry`, `modules/Domenia-Secrets.UI.ps1:Hide-DomeniaRevealedSecret`, `modules/Domenia-Secrets.UI.ps1:Test-DomeniaSecretSingleExposure`, `modules/Domenia-Secrets.UI.ps1:Select-DomeniaSecretRow`, `modules/Domenia-Secrets.UI.ps1:Get-DomeniaSelectedSecretIndex`, `modules/Domenia-Access.Model.ps1:Get-DomeniaSecretExposurePolicy`, `BtnToggleSecrets`, `BtnCopyAllSecrets`, `BtnClearSecrets`, `LblSecretsExposure`, `Timer:SecretReveal`, `Domenia-Access.Model.ps1:Get-DomeniaSecretRevealCountdown`, `Domenia-Access.Model.ps1:Get-DomeniaSecretExposurePolicy`, `Domenia-Access.Model.ps1:Test-DomeniaSecretRevealAllowed`, `Domenia-Core.ps1:Restart-DomeniaSecretLifetime`, `Domenia-Core.ps1:Copy-SelectedSecret`, `Domenia-Core.ps1:Copy-AllSecrets`, `Domenia-Core.ps1:Start-SecretClipboardAutoClear`, `Domenia-Core.ps1:Clear-DomeniaSecretClipboard`, `Domenia-Core.ps1:Clear-Secrets`, `Domenia-Core.ps1:Update-DomeniaSecretActionUi`, `Domenia-Core.ps1:Register-DomeniaReliabilityUi`, `Domenia-Main.xaml:BtnToggleSecrets`, `Domenia-Main.xaml:BtnCopySecret`, `Domenia-Main.xaml:BtnClearSecrets`, `Domenia-Main.xaml:DgSecrets`

#### PST-058 · Copier la clé BitLocker

`fait` · lecture réseau

« Copier la clé BitLocker » lit la seule clé choisie puis la place dans le presse-papiers protégé avec effacement automatique ; le journal note la copie avec l'identifiant de récupération, jamais la valeur.

- Garde-fous : 1024 caractères max ; limite des gestionnaires tiers affichée ; variable effacée après copie.
- Opérations : `ReadBitLockerKey`
- Références D1 : `modules/Domenia-Secrets.UI.ps1:Complete-DomeniaBitLockerKeyUi (ExplicitCopy)`, `modules/Domenia-Guard.UI.ps1:Set-DomeniaProtectedClipboard`, `BtnCopySecret`

#### PST-059 · Identité utilisée pour une lecture LAPS ou BitLocker

`fait` · locale (aucune lecture)

Indique quelle identité servira à la lecture (jeton Windows courant tant qu'il n'est pas refusé, compte temporaire ou compte Secrets) et si un autre compte sera demandé après un refus ; aucun compte privilégié n'est exigé d'avance.

- Garde-fous : Un compte alternatif refusé ne redevient jamais utilisable de lui-même. Aucun compte privilégié exigé d'avance.
- Opérations : `ReadLaps`, `ReadBitLocker`
- Références D1 : `modules/Domenia-Secrets.UI.ps1:Get-DomeniaSecretIdentityReason`, `modules/Domenia-Access.Model.ps1:Get-DomeniaOperationAuthNeed`, `BtnLoadLaps`, `BtnLoadBitLocker`, `Domenia-Access.Model.ps1:Get-DomeniaOperationAuthNeed`, `Domenia-Secrets.UI.ps1`

#### PST-060 · Boutons Secrets expliqués et route vers le prérequis

`fait` · locale (aucune lecture)

Les boutons « Lire le mot de passe LAPS » et « Lister les clés BitLocker » disent leur état (pas de poste sélectionné, lecture en cours, écriture à vérifier, refusé : cliquer propose un autre compte, droit estimé refusé mais le DC décide, disponible même en lecture seule) avec l'identité utilisée ; un bouton « Ouvrir : &lt;prérequis> » mène à la page qui manque.

- Garde-fous : Une estimation d'ACL ne désactive jamais le bouton ; la route est une navigation seule.
- Opérations : `ReadLaps`, `ReadBitLockerList`
- Références D1 : `modules/Domenia-Secrets.UI.ps1:Get-DomeniaSecretButtonExplanation`, `modules/Domenia-Secrets.UI.ps1:Update-DomeniaSecretsPrerequisite`, `modules/Domenia-Secrets.UI.ps1:Invoke-DomeniaSecretsPrerequisite`, `modules/Domenia-Secrets.UI.ps1:Initialize-DomeniaSecretsUi`, `BtnSecretsPrerequisite`, `BtnLoadLaps`, `BtnLoadBitLocker`

#### PST-061 · Colonne d'identité adaptée aux secrets

`fait` · locale (aucune lecture)

L'en-tête de la colonne d'identité de la grille des secrets devient « identifiant de récupération » pour BitLocker ou « compte » pour LAPS selon les lignes affichées.

- Références D1 : `modules/Domenia-Secrets.UI.ps1:Update-DomeniaSecretsView`, `Get-DomeniaSecretColumnHeader`, `Domenia-Access.Model.ps1:Get-DomeniaSecretColumnHeader`

#### PST-062 · Refus LAPS/BitLocker mémorisés par objet

`fait` · locale (aucune lecture)

Un refus de lecture LAPS ou BitLocker est mémorisé par poste et levé quand un autre compte est accepté pour cette ressource.

- Opérations : `ReadLaps`, `ReadBitLocker`
- Références D1 : `Domenia-Access.UI.ps1:Test-DomeniaSecretDenied`, `Domenia-Access.UI.ps1:Set-DomeniaSecretDenied`, `Domenia-Access.UI.ps1:Test-DomeniaSecretOperation`

#### PST-063 · Vue LAPS : lecture et déchiffrement distincts

`fait` · lecture réseau

Source (Windows LAPS ou historique), publication, expiration (échue), compte géré, déchiffreur autorisé ; états refus de lecture, prérequis, non confirmé, non publié, disponible, déchiffrement refusé, en attente.

- Garde-fous : Le mot de passe ne passe jamais par cette règle ; attribut illisible ≠ absent ; autre compte proposé sur refus. Estimation ACL défavorable n'empêche pas l'essai réel ; refus LAPS n'affecte pas BitLocker ; jamais persisté.
- Opérations : `ReadLaps`
- Références D1 : `Domenia-Access.Model.ps1:ConvertTo-DomeniaLapsView`, `Domenia-Core.ps1:Start-LoadComputerSecrets`, `Domenia-Core.ps1:Complete-DomeniaSecretLoadUi`, `Domenia-Core.ps1:Fail-DomeniaSecretLoadUi`, `Domenia-Main.xaml:BtnLoadLaps`

#### PST-064 · Boutons Afficher / Copier une valeur à la fois

`fait` · locale (aucune lecture)

Libellés, disponibilité et info-bulles décidés en un point (« Lire et afficher cette clé », « Copier la clé BitLocker ») ; copie suivie de l'effacement programmé du presse-papiers ; copie groupée masquée par défaut.

- Garde-fous : Limite des presse-papiers tiers rappelée.
- Opérations : `ReadBitLockerKey`
- Références D1 : `Domenia-Access.Model.ps1:Get-DomeniaSecretActionView`, `Réglage:Features.SecretSingleCopy`

#### PST-065 · Résumé non secret de BitLocker et LAPS du poste

`fait` · lecture locale

Sur la fiche d'un poste, LblSecretsStatus résume la dernière lecture enregistrée : nombre de clés BitLocker et date, schéma LAPS et expiration, verdict d'accès. Les métadonnées écrites avant la création du poste actuel (ancien détenteur du même nom, contrôlé par la date de création lue par GUID) sont écartées.

- Garde-fous : Jamais une clé ni un mot de passe ; un échec ne va qu'au niveau Trace de Domenia.log.
- Opérations : `LocalIndexRead`
- Références D1 : `LblSecretsStatus`, `Domenia-Engine.UI.ps1:Request-DomeniaSecretIndexSummary`, `Domenia-Engine.UI.ps1:Complete-DomeniaSecretIndexSummaryUi`, `Domenia-Engine.UI.ps1:Fail-DomeniaSecretIndexSummaryUi`, `Domenia-Cache.Model.ps1:Format-DomeniaSecretIndexSummary`

#### PST-066 · Index des secrets sans secret

> Reste à faire : Enregistrement durable de l’index dans la base locale (Domenia.Store) avec le mode annuaire en vague 3 ; l’index de l’OU de travail (50 000 postes au plus, aucune valeur), l’index par poste et l’écart d’un ancien détenteur du nom sont en place, sur la base fictive de la session en simulation.

`partiel` · écriture

Enregistre pour un poste, ou pour toute une OU (présence BitLocker, 50 000 lignes au plus), le nombre de clés BitLocker, les dates et le schéma LAPS. Un compte déjà lu n'est jamais remplacé par le zéro d'une lecture qui ne voit rien, et une lecture LAPS seule garde le compte BitLocker connu.

- Garde-fous : Le champ valeur n'est jamais consulté ; aucun détail d'erreur de fournisseur stocké. Métadonnées seulement, jamais une clé ni un mot de passe.
- Opérations : `LocalStore`, `BitLockerPresence`, `ReadLaps`, `ReadBitLocker`
- Références D1 : `Domenia-Core.ps1:Save-DomeniaSecretIndexEntry`, `Domenia-Core.ps1:Update-DomeniaSecretIndexFromRows`, `Domenia-Core.ps1:Reset-DomeniaSelectionBoundViews`, `Domenia-Storage.UI.ps1:Queue-DomeniaMetadata (SecretMeta)`, `Domenia-Storage.Worker.ps1:Get-DomeniaStorageWorkerCode`

### Services

#### PST-067 · Lire les services du poste

`fait` · lecture réseau

Win32_Service est lu au clic, en lecture seule, limité à 500 instances, puis mis en forme : libellés français de l'état et du type de démarrage (dont « Automatique (différé) »), automatiques arrêtés en tête. Le résumé donne le nombre lu, l'heure, les automatiques arrêtés, le plafond atteint et les valeurs écartées comme secrets.

- Garde-fous : La requête WMI est validée (Assert-DomeniaWmiReadQuery). Délai de 90 s, tâche Explicit, réponse ignorée si la sélection ou la session ont changé. Un échec ne remplace pas la liste affichée.
- Opérations : `WmiQuery`
- Références D1 : `Domenia-Assist.UI.ps1:Start-DomeniaComputerServicesRead`, `Domenia-Assist.UI.ps1:Complete-DomeniaComputerServicesUi`, `Domenia-Assist.UI.ps1:Fail-DomeniaComputerServicesUi`, `Domenia-Assist.Model.ps1:ConvertTo-DomeniaServiceRows`, `Domenia-Assist.Model.ps1:Get-DomeniaServiceStateLabel`, `Domenia-Assist.Model.ps1:Get-DomeniaServiceStartLabel`, `Domenia-Assist.Model.ps1:Get-DomeniaServiceListSummary`, `BtnCompServicesRead`, `DgCompServices`, `LblCompServicesState`, `Domenia-Main.xaml:BtnCompServicesRead`, `Domenia-Main.xaml:DgCompServices`

#### PST-068 · Filtrer la liste des services

`fait` · locale (aucune lecture)

Filtre local sur la liste déjà lue : « automatiques arrêtés seulement » et texte cherché dans le nom ou le libellé, sans tenir compte de la casse. Rien n'est relu.

- Garde-fous : Filtre local uniquement.
- Références D1 : `Domenia-Assist.Model.ps1:Test-DomeniaServiceRowMatch`, `Domenia-Assist.UI.ps1:Update-DomeniaComputerServicesView`, `ChkCompServicesAutoStopped`, `TxtCompServicesFilter`

#### PST-069 · Démarrer ou redémarrer un service

`ameliore` · écriture

Démarre un service arrêté ou redémarre un service en cours, par CIM. Le plan est confirmé dans la page, puis l'état est relu (preuve : Running). Les codes de retour du gestionnaire de services sont traduits en français et la ligne reprend l'état relu.

- Garde-fous : Le type de démarrage n'est jamais modifié : un service désactivé est refusé avant et dans le worker. Le nom est filtré par liste blanche (pas d'injection WQL). L'état requis est contrôlé avant l'envoi. Le redémarrage est classé Danger. Si la session CIM est refusée, rien n'est envoyé (NotSent). Tâche IsWrite non annulable, CorrelationId de reçu, postcondition attendue Running, jamais rejouée. Un arrêt sans redémarrage en 30 s laisse un reçu « à vérifier ».
- Opérations : `ComputerServiceControl`
- Références D1 : `Domenia-Assist.Model.ps1:Get-DomeniaServiceControlPlan`, `Domenia-Assist.Model.ps1:Test-DomeniaServiceName`, `Domenia-Assist.Model.ps1:Get-DomeniaServiceRowWithState`, `Domenia-Assist.UI.ps1:Request-DomeniaComputerServiceControl`, `Domenia-Assist.UI.ps1:Confirm-DomeniaComputerServiceControl`, `Domenia-Assist.UI.ps1:Complete-DomeniaComputerServiceControlUi`, `Domenia-Assist.UI.ps1:Fail-DomeniaComputerServiceControlUi`, `Domenia-Assist.UI.ps1:Update-DomeniaComputerServiceButtons`, `Domenia-Assist.Worker.ps1:Get-DomeniaServiceControlWorkerCode`, `BtnCompServiceStart`, `BtnCompServiceRestart`

#### PST-070 · Services automatiques arrêtés attendus

`fait` · locale (aucune lecture)

Liste des services à démarrage différé ou sur déclencheur (gupdate, edgeupdate, sppsvc, RemoteRegistry, BITS, wuauserv, DoSvc, UsoSvc, OneSyncSvc_\*…) qui ne sont pas comptés comme arrêtés en faute.

- Garde-fous : Jokers par nom court uniquement.
- Opérations : `ComputerInventory`
- Références D1 : `Domenia-Workstation.Model.ps1:Test-DomeniaServiceStopExpected`

### Sessions

#### PST-071 · Lecture des sessions Windows (WTS)

`fait` · lecture réseau

Lit à la demande les sessions du poste sélectionné par l'API WTS (Id, station, compte, domaine, état, protocole Console/RDP, heure d'ouverture locale, inactivité « 12 min »), sous le compte poste par LogonUser si fourni, puis les enregistre durablement avant affichage.

- Garde-fous : Consultation seule (aucune déconnexion, fermeture ou message) ; projection fermée des champs ; résultat d'une autre cible refusé ; échec → récupération d'accès proposée et texte « absence de résultat ne signifie pas absence de sessions ».
- Opérations : `SessionsList`, `LocalStore`
- Références D1 : `Domenia-Sessions.UI.ps1:Start-DomeniaSessionsRead`, `Domenia-Sessions.UI.ps1:Get-DomeniaSessionsWorkerCode`, `Domenia-Sessions.Native.cs:Reader.Read`, `Domenia-Sessions.UI.ps1:Complete-DomeniaSessionsCollected`, `Domenia-Sessions.UI.ps1:Complete-DomeniaSessionsRead`, `Domenia-Workstation.Model.ps1:Get-DomeniaSessionOpenedText`, `Domenia-Workstation.Model.ps1:Get-DomeniaSessionIdleText`, `BtnSessionsRead`, `DgSessions`, `LblSessionsState`, `Domenia-Main.xaml:BtnSessionsRead`, `Domenia-Main.xaml:DgSessions`

#### PST-072 · Interprétation honnête des sessions

`fait` · locale (aucune lecture)

Vue des sessions qui masque les lignes sans compte (services, écran de connexion, écouteur RDP) en les comptant, distingue refus, injoignable, lecture partielle, réponse sans liste et statut inconnu, et produit une ligne d'état « Lu à … · n session(s) · lu par … ».

- Garde-fous : Une console vide ne prouve jamais l'absence de session RDP ; un refus ne prouve pas l'absence de session.
- Références D1 : `Domenia-Workstation.Model.ps1:ConvertTo-DomeniaSessionView`, `Domenia-Workstation.Model.ps1:Get-DomeniaSessionEmptyText`

#### PST-073 · Ouvrir la fiche du compte d'une session

`fait` · lecture réseau

Double-clic ou menu contextuel « Ouvrir la fiche du compte » sur une ligne de session : cherche le compte AD par sAMAccountName (domaine WTS retiré).

- Garde-fous : Ligne sans compte : message, aucune recherche lancée ; menu grisé sans compte.
- Opérations : `OpenLinkedObject`
- Références D1 : `Domenia-Sessions.UI.ps1:Open-DomeniaSessionFiche`, `Domenia-Sessions.UI.ps1:New-DomeniaSessionsContextMenu`, `Domenia-Workstation.Model.ps1:Get-DomeniaSessionAccountName`

### Sondes et lectures

#### PST-074 · Détails d'une sonde du poste

`fait` · lecture locale

Fenêtre qui lit seulement les familles enregistrées de la sonde et de sa lecture pour le GUID du poste : lecture interprétée (Point, Valeur, État, Date, Source, Limite, Piste), contrat de la sonde, valeurs brutes « Dernière réussite » ou « Dernière tentative », pagination par 100, provenance.

- Garde-fous : N'interroge jamais le poste ; poste sans GUID refusé ; famille ambiguë refusée ; ancienne ligne sans schéma étiquetée « Valeur n ».
- Opérations : `LocalIndexRead`
- Références D1 : `Domenia-ProbeDetails.UI.ps1:Show-DomeniaProbeDetails`, `Domenia-ProbeDetails.UI.ps1:New-DomeniaProbeReadingGrid`, `Domenia-ProbeDetails.UI.ps1:Update-DomeniaProbeReading`, `Domenia-ProbeDetails.UI.ps1:Update-DomeniaProbeDetailsPage`, `Domenia-ProbeDetails.UI.ps1:Complete-DomeniaProbeDetailsRead`

#### PST-075 · Catalogue des lectures interprétées

`fait` · locale (aucune lecture)

Quinze lectures qui combinent des sondes : mémoire, volumes, stockage, batteries, BIOS, processeurs, écrans, réseau, périphériques, services, tâches, antivirus, pare-feu, protection, processus ; chaque sonde historique ouvre sa lecture.

- Garde-fous : Non lu, refusé, fournisseur absent, non applicable ou en échec restent nommés ; lecture partielle annoncée sur chaque fait.
- Références D1 : `Domenia-Readings.Model.ps1:Get-DomeniaReadingCatalog`, `Domenia-Readings.Model.ps1:Get-DomeniaReadingForProbe`, `Domenia-Readings.Model.ps1:Invoke-DomeniaReading`, `Domenia-Readings.Model.ps1:ConvertTo-DomeniaReadingSource`, `Domenia-Readings.Model.ps1:ConvertTo-DomeniaReadingRows`

#### PST-076 · Lecture Mémoire

`fait` · locale (aucune lecture)

Capacité installée par barrettes (emplacement, taille, fréquence), emplacements occupés/libres, capacité maximale déclarée, mémoire visible et utilisée au relevé.

- Garde-fous : VM sans barrette exposée : capacité inconnue ; ≥ 90 % utilisée = indice à confirmer, pas une conclusion.
- Opérations : `LiveConsole`
- Références D1 : `Domenia-Readings.Model.ps1:Get-DomeniaMemoryReading`

#### PST-077 · Volumes et prévision de saturation

`ameliore` · locale (aucune lecture)

Espace libre de chaque volume fixe avec seuils de la politique, puis prévision par régression linéaire sur l'historique (≥ 4 relevés sur ≥ 14 jours, taille constante, R² ≥ 0,6, horizon 730 jours).

- Garde-fous : Aucun chiffre sans historique suffisant ; baisse &lt; 1 Mo/j = stable ; alerte si saturation &lt; 30 jours.
- Opérations : `LiveConsole`
- Références D1 : `Domenia-Readings.Model.ps1:Get-DomeniaVolumeReading`, `Domenia-Readings.Model.ps1:Get-DomeniaVolumeSaturationForecast`

#### PST-078 · Santé du stockage

`fait` · locale (aucune lecture)

Disques physiques (type, bus, taille, santé déclarée) et compteurs de fiabilité (température, usure, erreurs non corrigées).

- Garde-fous : Inconnu, disque virtuel ou compteur absent jamais présenté sain ; usure ≥ 90 % → remplacement à prévoir.
- Opérations : `LiveConsole`
- Références D1 : `Domenia-Readings.Model.ps1:Get-DomeniaStorageHealthReading`

#### PST-079 · Batteries

`fait` · locale (aucune lecture)

Charge, état, capacité nominale, capacité à pleine charge, usure estimée et cycles (classes du pilote root\wmi jointes par instance).

- Garde-fous : Usure calculée seulement avec deux capacités valides ; pleine charge > nominale +5 % = non estimable ; usure ≥ 40 % signalée.
- Opérations : `LiveConsole`
- Références D1 : `Domenia-Readings.Model.ps1:Get-DomeniaBatteryReading`

#### PST-080 · BIOS et référence approuvée par modèle

`fait` · écriture

Version, date et spécification SMBIOS du BIOS, modèle du poste, comparaison à la version approuvée pour le modèle ; boutons « Approuver cette version pour ce modèle » et « Retirer la référence du modèle ».

- Garde-fous : Réglage local par domaine (clé SHA-256 du DN), 500 modèles max ; aucune action sur le poste ; sans référence, aucune conclusion sur une version ou une date ; formats non ordonnables = « différent ».
- Références D1 : `Domenia-Readings.Model.ps1:Get-DomeniaBiosReading`, `Domenia-Readings.Model.ps1:Compare-DomeniaBiosVersion`, `Domenia-Readings.Model.ps1:ConvertTo-DomeniaBiosReferenceBook`, `Domenia-Readings.Model.ps1:Set-DomeniaBiosReference`, `Domenia-Readings.Model.ps1:Remove-DomeniaBiosReference`, `Domenia-ProbeDetails.UI.ps1:Invoke-DomeniaBiosReferenceAction`, `Domenia-ProbeDetails.UI.ps1:Get-DomeniaBiosReferenceSettingKey`

#### PST-081 · Processeurs et virtualisation

`fait` · locale (aucune lecture)

Processeurs (architecture, cœurs, logiques, capacités), charge instantanée datée et estimation machine physique ou virtuelle (signature d'hyperviseur dans le modèle).

- Garde-fous : Physique/virtuel est une estimation, jamais une preuve.
- Opérations : `LiveConsole`
- Références D1 : `Domenia-Readings.Model.ps1:Get-DomeniaProcessorReading`, `Domenia-Readings.Model.ps1:Get-DomeniaVirtualPlatform`

#### PST-082 · Écrans, raccordements et stations d'accueil

`fait` · locale (aucune lecture)

Écrans identifiés par EDID (nom, fabricant, produit, n° de série, année), raccordement interne/externe (technologie de sortie), changements d'écrans entre relevés, indices de station d'accueil parmi les périphériques PnP.

- Garde-fous : Station d'accueil jamais affirmée (indices seulement) ; absence d'indice ne prouve rien.
- Opérations : `LiveConsole`
- Références D1 : `Domenia-Readings.Model.ps1:Get-DomeniaDisplayReading`, `Domenia-Readings.Model.ps1:Get-DomeniaDockHintFacts`, `Domenia-Readings.Model.ps1:Get-DomeniaVideoOutputText`, `Domenia-Probes.Model.ps1:Get-DomeniaMonitorIdentity`, `Domenia-Probes.Model.ps1:ConvertFrom-DomeniaEdidText`

#### PST-083 · Interfaces réseau

`fait` · locale (aucune lecture)

Cartes physiques d'abord (état, vitesse, MAC, configuration IP jointe par index), cartes virtuelles à part.

- Garde-fous : Rien ne prouve qu'un service est joignable.
- Opérations : `LiveConsole`
- Références D1 : `Domenia-Readings.Model.ps1:Get-DomeniaNetworkReading`, `Domenia-Readings.Model.ps1:Test-DomeniaVirtualAdapterName`

#### PST-084 · Imprimantes et périphériques en erreur

`fait` · locale (aucune lecture)

Imprimantes hors ligne ou en erreur (pilote, port, réseau/locale, par défaut) et périphériques avec code du gestionnaire (désactivé/déconnecté distingués d'une anomalie), 25 listés au plus.

- Garde-fous : Imprimantes d'une autre session possiblement absentes.
- Opérations : `LiveConsole`
- Références D1 : `Domenia-Readings.Model.ps1:Get-DomeniaDeviceReading`, `Domenia-Readings.Model.ps1:Get-DomeniaDeviceErrorText`

#### PST-085 · Services et profil attendu

`fait` · locale (aucune lecture)

Compare état et mode de démarrage à un profil de 15 services attendus sur un poste du domaine (Winmgmt, RpcSs, Netlogon, gpsvc, mpssvc…) et liste les automatiques arrêtés avec code d'erreur.

- Garde-fous : Code 1077 normal pour un démarrage sur déclencheur ; un écart est une piste, aucun service n'est modifié.
- Opérations : `LiveConsole`
- Références D1 : `Domenia-Readings.Model.ps1:Get-DomeniaServiceProfile`, `Domenia-Readings.Model.ps1:Get-DomeniaServiceReading`

#### PST-086 · Tâches planifiées et démarrage automatique

`fait` · locale (aucune lecture)

Inventaire des tâches (auteur, état), tâches hors Microsoft listées, entrées de démarrage par emplacement.

- Garde-fous : Commandes, arguments et comptes principaux jamais lus ; dernier résultat non déduit.
- Opérations : `LiveConsole`
- Références D1 : `Domenia-Readings.Model.ps1:Get-DomeniaTaskReading`

#### PST-087 · Antivirus et Defender

`fait` · locale (aucune lecture)

Produits déclarés au Centre de sécurité (état estimé par productState) et état détaillé Defender (protections, âge des signatures, analyses).

- Garde-fous : Décodage non documenté = estimation ; Defender passif possible ; serveurs sans Centre de sécurité.
- Opérations : `LiveConsole`
- Références D1 : `Domenia-Readings.Model.ps1:Get-DomeniaAntivirusReading`, `Domenia-Readings.Model.ps1:ConvertFrom-DomeniaAvProductState`

#### PST-088 · Pare-feu et profils réseau

`fait` · locale (aucune lecture)

Configuration des profils du magasin local et profil appliqué à chaque connexion active.

- Garde-fous : Origine GPO lue par l'inventaire complet, pas par cette classe.
- Opérations : `LiveConsole`
- Références D1 : `Domenia-Readings.Model.ps1:Get-DomeniaFirewallReading`

#### PST-089 · BitLocker, TPM et sécurité du démarrage

`fait` · locale (aucune lecture)

Chiffrement et protection de chaque volume, états initiaux du TPM, VBS et services Device Guard.

- Garde-fous : Chiffré + protection suspendue ≠ protégé ; Secure Boot non lisible par ces classes, renvoyé à l'inventaire.
- Opérations : `LiveConsole`
- Références D1 : `Domenia-Readings.Model.ps1:Get-DomeniaProtectionReading`

#### PST-090 · Processus au relevé

`fait` · locale (aucune lecture)

Plus gros ensembles de travail au moment du relevé.

- Garde-fous : Aucune charge CPU déduite d'une photographie unique.
- Opérations : `LiveConsole`
- Références D1 : `Domenia-Readings.Model.ps1:Get-DomeniaProcessSnapshotReading`

#### PST-091 · Historique borné des volumes et des écrans

`fait` · locale (aucune lecture)

Conserve dans la dernière mesure réussie un historique : disk.volumes en série (un relevé / 6 h, 60 au plus, 400 jours), hw.monitors en changements (20 au plus).

- Garde-fous : Échantillon endommagé, partiel ou postérieur écarté, jamais réordonné.
- Opérations : `LocalStore`
- Références D1 : `Domenia-Probes.Model.ps1:Get-DomeniaProbeHistoryPolicy`, `Domenia-Probes.Model.ps1:Add-DomeniaProbeHistory`, `Domenia-Probes.Model.ps1:Get-DomeniaProbeHistorySample`, `Domenia-Probes.Model.ps1:ConvertTo-DomeniaProbeHistoryItem`

### Tableau de bord du poste

#### PST-092 · Tableau de bord du poste depuis l'inventaire

`ameliore` · lecture réseau

Remplit le tableau du poste sélectionné à partir de l'inventaire rapide (~1 min) ou complet (~3 min : processus, erreurs système, tâches, certificats, connexions) et des attributs de sa fiche, sans nouvelle requête ; résumé daté.

- Garde-fous : Lecture seule CIM ; mesures indisponibles (tâche distante) annoncées ; politique de santé de l'OU du poste.
- Opérations : `ComputerInventory`
- Références D1 : `Domenia-Dashboard.UI.ps1:Update-DomeniaComputerDashboard`, `Domenia-BoardComputer.UI.ps1:Get-DomeniaComputerBoardData`, `BtnDashboardInventory`, `BtnDashboardInventoryDeep`, `LblComputerDashboard`, `PnlComputerDashboard`

#### PST-093 · Score de santé du poste

`ameliore` · locale (aucune lecture)

Score 100 − 25 par point critique − 10 par point à surveiller, verdict Bon état / À surveiller / Dégradé / Critique ; badge « Partiel : antivirus, pare-feu ou BitLocker non lu » avec bouton Inventaire complet.

- Garde-fous : Badge sans point = « Données insuffisantes » (score retenu) ; aucun contrôle activé = pas de score ; règles suspendues annoncées.
- Références D1 : `Domenia-Boards.Model.ps1:Get-DomeniaBoardHealth`, `Domenia-Boards.Model.ps1:Complete-DomeniaBoardData`, `computer.health`

#### PST-094 · Points d'attention du poste avec lien vers l'action utile

`ameliore` · locale (aucune lecture)

Fin de service, mot de passe machine ancien, inactivité AD, compte désactivé (critique), LAPS expiré, horloge décalée (>5 min avec le DC = critique Kerberos), redémarrage long ou en attente, mémoire, batterie, disques, erreurs système, pare-feu, BitLocker, services, périphériques, pilotes, certificats, correctif ancien (>60 j), Secure Boot ; certains points ouvrent l'onglet Intervenir ou Secrets sans rien lancer.

- Garde-fous : Lien = navigation seule ; poste non sélectionné = message ; horloge comparée au poste d'administration annoncée comme telle.
- Références D1 : `Domenia-BoardComputer.UI.ps1:Get-DomeniaComputerBoardData`, `Domenia-BoardComputer.UI.ps1:Add-DomeniaComputerBoardAdEntries`, `Domenia-Dashboard.UI.ps1:Invoke-DomeniaBoardRoute`, `Domenia-Dashboard.UI.ps1:Get-DomeniaBoardRouteTarget`, `computer.attention`

#### PST-095 · Fiche identité du poste

`fait` · locale (aucune lecture)

Fiche (et tuiles séparées au catalogue) : version commerciale et build avec fin de service, fabricant/modèle/numéro de série, processeur cœurs/threads, mémoire avec barrettes/emplacements (VM signalée), durée de fonctionnement, utilisateur console, première IPv4 et passerelle, domaine et rôle.

- Garde-fous : Valeur absente = « Non lu » grisé ; fiche ne liste que ce qui a été lu.
- Références D1 : `Domenia-BoardComputer.UI.ps1:Get-DomeniaComputerBoardData`, `Domenia-Boards.Model.ps1:Add-DomeniaComputerSheetEntries`, `computer.identity`, `computer.os`, `computer.model`, `computer.cpu`, `computer.memory`, `computer.uptime`, `computer.user`, `computer.ip`, `computer.domain`

#### PST-096 · Fiche compte machine dans AD

`fait` · locale (aucune lecture)

État du compte et date de création, OU, âge du mot de passe machine, dernière connexion (±14 j), expiration LAPS (Windows LAPS ou legacy), managedBy, écart d'horloge avec le contrôleur ou le poste d'administration.

- Garde-fous : Attributs déjà lus avec la fiche ; jamais le mot de passe LAPS ; userAccountControl illisible = État inconnu.
- Références D1 : `Domenia-BoardComputer.UI.ps1:Add-DomeniaComputerBoardAdEntries`, `Domenia-Dashboard.UI.ps1:Get-DomeniaEntryFileTimeUtc`, `computer.adaccount`, `computer.ad.password`, `computer.ad.lastlogon`, `computer.ad.account`, `computer.ad.ou`, `computer.ad.laps`, `computer.ad.managedby`, `computer.ad.clock`

#### PST-097 · Ressources : mémoire, processeur, batterie

`fait` · locale (aucune lecture)

Jauges mémoire utilisée (sur total CIM), charge processeur et batterie au moment de l'inventaire, colorées par l'état des seuils ; « Aucune batterie » en clair pour un poste fixe.

- Garde-fous : Pas de jauge sans total CIM ; jamais 0 % de batterie inventé.
- Références D1 : `Domenia-BoardComputer.UI.ps1:Get-DomeniaComputerBoardData`, `computer.memory.usage`, `computer.cpu.load`, `computer.battery`

#### PST-098 · Disques du poste

`ameliore` · locale (aucune lecture)

Anneau du disque système (C:, sinon premier volume) utilisé/libre et barres d'espace libre des autres volumes (le moins libre en valeur), ou « Aucun autre volume ».

- Garde-fous : Seuils partagés avec le parc ; volume critique = point d'attention.
- Références D1 : `Domenia-BoardComputer.UI.ps1:Get-DomeniaComputerBoardData`, `computer.disk.system`, `computer.disk.volumes`

#### PST-099 · Activité : services, processus, journal Système

`fait` · locale (aucune lecture)

Anneau des services (en cours, automatiques arrêtés, déclencheur ou différé attendus, manuels, désactivés), processus les plus actifs en % processeur mesuré sur intervalle (sinon mémoire en Mo), erreurs du journal Système sur 3 jours par source.

- Garde-fous : Table de bruit MO-06 : services sur déclencheur et erreurs connues ignorés et comptés à part ; disque, NTFS et Kernel-Power 41 à surveiller.
- Références D1 : `Domenia-BoardComputer.UI.ps1:Get-DomeniaComputerBoardData`, `computer.services`, `computer.processes`, `computer.events`

#### PST-100 · Liste d'état de la protection du poste

`ameliore` · locale (aucune lecture)

Une ligne par contrôle (BitLocker, Démarrage sécurisé, Pare-feu, Antivirus, Redémarrage en attente, Dernier correctif) marquée OK, À vérifier, Critique ou Non lu, avec « N contrôles lus sur M ».

- Garde-fous : Un contrôle non lu n'est jamais compté comme conforme (« Rien à signaler sur ce qui est lu »).
- Références D1 : `Domenia-Boards.Model.ps1:Add-DomeniaComputerSheetEntries`, `Domenia-Boards.Model.ps1:Get-DomeniaComputerSheetSources`, `computer.status`

#### PST-101 · Pare-feu par profil effectif

`fait` · locale (aucune lecture)

Un état par profil (domaine, privé, public), la stratégie primant sur la clé locale, avec les connexions actives auxquelles chaque profil est appliqué ; profil désactivé appliqué nommé en premier.

- Garde-fous : Valeurs comparées exactement ; valeur inconnue non comptée.
- Références D1 : `Domenia-BoardComputer.UI.ps1:Get-DomeniaComputerBoardData (Get-DomeniaAppliedFirewallProfiles)`, `computer.firewall`

#### PST-102 · BitLocker du volume système et suspension

`fait` · locale (aucune lecture)

État de protection et de chiffrement du volume C: en premier ; volume chiffré avec protection désactivée signalé comme suspendu, pas comme non chiffré ; lien vers Secrets.

- Garde-fous : Le mot « Protection » seul ne prouve rien.
- Références D1 : `Domenia-BoardComputer.UI.ps1:Get-DomeniaComputerBoardData (Get-DomeniaBitLockerInventoryState)`, `computer.bitlocker`

#### PST-103 · Windows Update, WSUS, correctifs et build

`fait` · locale (aucune lecture)

Serveur WSUS réellement utilisé (adresse sans UseWUServer=1 non retenue), build/révision/dernier correctif CBS et source des mises à jour sans verdict de conformité, ancienneté du dernier correctif QFE.

- Garde-fous : « Conformité non évaluée » explicite : QFE ne liste pas toutes les mises à jour. Conformité jamais conclue (QFE ne liste pas tout) ; configuration lue, pas un contact serveur.
- Opérations : `ComputerInventory`
- Références D1 : `Domenia-BoardComputer.UI.ps1:Get-DomeniaComputerBoardData (Get-DomeniaUpdateReading)`, `computer.wsus`, `computer.updates`, `computer.hotfix`, `Domenia-Readings.Model.ps1:Get-DomeniaUpdateReading`, `Domenia-Readings.Model.ps1:Get-DomeniaInventoryCategoryRows`

#### PST-104 · Redémarrage en attente confirmé

`fait` · locale (aucune lecture)

Classe les indicateurs du registre en obligation confirmée (CBS, Windows Update…), indice partiel ou absent, avec reclassement des inventaires anciens.

- Garde-fous : Indices partiels jamais comptés comme obligation. Un indice partiel n'est pas une obligation ; non lu = inconnu.
- Opérations : `ComputerInventory`
- Références D1 : `Domenia-BoardComputer.UI.ps1:Get-DomeniaComputerBoardData (Get-DomeniaPendingRebootReading)`, `computer.reboot`, `Domenia-Readings.Model.ps1:Get-DomeniaPendingRebootReading`

#### PST-105 · Démarrage sécurisé (Secure Boot)

`fait` · locale (aucune lecture)

État Secure Boot lu dans le registre et type de micrologiciel ; point d'attention seulement s'il est désactivé sur UEFI.

- Garde-fous : BIOS hérité ou valeur absente = non mesuré.
- Références D1 : `Domenia-BoardComputer.UI.ps1:Get-DomeniaComputerBoardData (Get-DomeniaSecureBootInventoryState)`, `computer.secureboot`

#### PST-106 · Certificats machine

`fait` · locale (aucune lecture)

Classe les certificats du magasin Personnel de l'ordinateur : expirés, expirant sous 30 jours, valides, avec émetteur et usages ; lecture partielle au-delà de 50 certificats signalée.

- Garde-fous : Lecture partielle jamais montrée en bon état ; clé privée jamais lue. Clé privée jamais lue, rien n'est exporté.
- Opérations : `ComputerInventory`
- Références D1 : `Domenia-BoardComputer.UI.ps1:Get-DomeniaComputerBoardData (Get-DomeniaCertificateReading)`, `computer.certificates`, `Domenia-Readings.Model.ps1:Get-DomeniaCertificateReading`

#### PST-107 · Tuiles de comptage de l'inventaire

`fait` · locale (aucune lecture)

Périphériques en erreur et pilotes non signés (à surveiller), administrateurs locaux, comptes et sessions locaux, programmes au démarrage, partages, imprimantes, affichage, disque physique, services automatiques arrêtés (attendus exclus).

- Garde-fous : Source qui a répondu sans élément = lecture « 0 », pas widget non lu.
- Références D1 : `Domenia-BoardComputer.UI.ps1:Get-DomeniaComputerBoardData`, `computer.devices`, `computer.drivers`, `computer.admins`, `computer.sessions`, `computer.autostart`, `computer.shares`, `computer.printers`, `computer.display`, `computer.physicaldisk`, `computer.services.stopped`

#### PST-108 · Indications et bouton sous une section vide

`fait` · locale (aucune lecture)

Une section sans donnée affiche pourquoi et le bouton de l'action existante qui la remplit (Inventaire rapide, Inventaire complet, Ouvrir la fiche, lien Rechercher sur l'accueil).

- Garde-fous : Rien ne part sans clic ; le bouton passe par le contrôle existant (mêmes vérifications, même confirmation).
- Références D1 : `Domenia-BoardComputer.UI.ps1:Get-DomeniaComputerBoardData (Hints, HintActions)`, `Domenia-Widgets.UI.ps1:New-DomeniaBoardHint`, `Domenia-Widgets.UI.ps1:Get-DomeniaBoardHintAction`, `Domenia-Widgets.UI.ps1:Get-DomeniaBoardActionControl`

#### PST-109 · Observation stockée du poste sélectionné

`fait` · lecture locale

Un poste hors de l'OU de l'accueil reçoit ses propres observations (ping, console, inventaire, sondes) depuis la base locale, une fois par poste, session et révision.

- Garde-fous : GUID valide requis ; StoreId, chemin, génération de sélection et révision d'instantané vérifiés ; révision plus ancienne relancée ; absence canonique retire l'ancienne ligne ; une observation plus récente n'est jamais écrasée.
- Opérations : `LocalIndexRead`
- Références D1 : `Domenia-Dashboard.UI.ps1:Request-DomeniaSelectedObservation`, `Domenia-Dashboard.UI.ps1:Complete-DomeniaSelectedObservation`, `Domenia-Dashboard.UI.ps1:Fail-DomeniaSelectedObservation`, `Domenia-Dashboard.UI.ps1:Merge-DomeniaFleetObservations`

#### PST-110 · Actualiser les requêtes du poste

`fait` · lecture réseau

Bouton de la barre d'outils du tableau poste : collecte seulement les champs distants requis par les sondes et requêtes enregistrées placées sur le tableau, une fois pour le poste.

- Garde-fous : Widgets suspendus exclus ; uniquement local = message sans collecte ; poste sélectionné requis ; lecture seule avec confirmation ; ping avant WMI.
- Opérations : `LiveConsole`, `ParkSweep`
- Références D1 : `Domenia-Widgets.UI.ps1:Start-DomeniaWidgetProbe`, `Domenia-Widgets.UI.ps1:New-DomeniaBoardToolbar`

#### PST-111 · Atelier et détails enregistrés depuis le tableau poste

> Reste à faire : L’atelier de requêtes est l’écran Requêtes (autre lot) : les boutons « Atelier » (vue Sondes et relevés) et « Ouvrir dans l’atelier » (détails d’une sonde) y mènent avec le poste et la sonde en paramètres (#/requetes?cible=poste&dn=…&sonde=…) ; la destination d’affichage reste à brancher de ce côté.

`partiel` · locale (aucune lecture)

Bouton Atelier (requête réutilisable et destination d'affichage) et bouton rond « Détails enregistrés » d'une sonde ou « Ouvrir dans l'atelier » d'une requête enregistrée.

- Références D1 : `Domenia-Widgets.UI.ps1:Invoke-DomeniaBoardAction (Workshop, Details)`, `Show-DomeniaComputerQueryWorkshop`, `Domenia-ProbeDetails.UI.ps1:Show-DomeniaProbeDetails`, `Domenia-QueryTargets.UI.ps1:Show-DomeniaComputerQueryWorkshop`

#### PST-112 · Oubli des tableaux au changement d'objet

`fait` · locale (aucune lecture)

Quand un autre objet est sélectionné, les tableaux poste et logiciels oublient leurs données et leur pile d'annulation et affichent l'invitation à lancer un inventaire ou charger les logiciels.

- Garde-fous : Seul moment où l'annulation de disposition du poste est effacée (FI-11).
- Références D1 : `Domenia-Dashboard.UI.ps1:Clear-DomeniaDashboards`

#### PST-113 · Widget de requête sur le tableau du poste

> Reste à faire : Widget d’une requête enregistrée évalué sur ce seul poste : dépend du moteur et du stockage des requêtes enregistrées de l’écran Requêtes (autre lot), absents de cet arbre.

`partiel` · locale (aucune lecture)

Évalue une requête enregistrée sur le seul poste de la fiche ouverte à partir de l'instantané du parc, des attributs de la fiche et des observations en mémoire.

- Garde-fous : Aucune lecture annuaire ou poste ; cache de correspondance borné invalidé à chaque changement de session, base, instantané ou identité ; état AD inconnu laissé inconnu.
- Références D1 : `Domenia-QueryTargets.UI.ps1:Get-DomeniaComputerQueryBoardEntry`, `Domenia-QueryTargets.UI.ps1:Get-DomeniaComputerQueryRecords`

### Vue d'ensemble

#### PST-114 · Activité de connexion du compte ordinateur (approx. et par contrôleur)

`ameliore` · lecture réseau

Même explication de lastLogonTimestamp pour le compte ordinateur du poste ouvert, et même lecture explicite de lastLogon sur chaque contrôleur, avec couverture et contrôleurs non lus.

- Garde-fous : Mêmes bornes que pour l'utilisateur ; une connexion ne prouve pas une présence actuelle.
- Opérations : `LogonByDcRead`
- Références D1 : `modules/Domenia-LogonActivity.UI.ps1:Update-DomeniaLogonActivityPanel (Kind Computer)`, `modules/Domenia-LogonActivity.UI.ps1:Start-DomeniaLogonByDcRead (Kind Computer)`, `BtnCompLogonByDc`, `TxtCompLogonByDc`, `TxtCompLastLogon`, `Domenia-Main.xaml:BtnCompLogonByDc`

#### PST-115 · Ligne d'association d'un poste

`ameliore` · lecture locale

Résumé sur une ligne de l'association mémorisée : utilisateur, source, date, badge (Déclaré, Observé, Historique, Contradictoire) et règle qui le produit. Elle signale une détection en cours et une identité non vérifiable (lien hérité sans GUID qui ne précède pas le poste, point 9). Source : la mémoire locale seulement.

- Garde-fous : Le lien d'un ancien détenteur du nom est écarté par le GUID. Un historique s'affiche en ton neutre, jamais comme une observation actuelle.
- Références D1 : `Domenia-Relations.Model.ps1:Get-DomeniaLinkSummaryText`, `Domenia-Assist.UI.ps1:Update-DomeniaComputerLinkLine`, `LblCompLinkSummary`, `LblCompLinkBadge`, `UxCompLinkBadge`, `BtnOpenLinkedUser`, `Get-DomeniaLinkSummaryText`, `Test-DomeniaLinkIdentity`

#### PST-116 · Vue d'ensemble du poste

`ameliore` · lecture réseau

Nom, DNS, présence, OS et version, description, emplacement, géré par, état, dernière connexion, UAC, utilisateur associé avec badge, source et date locale, identité non prouvée signalée ; Ouvrir la fiche utilisateur, Détecter à nouveau, tableau de bord du dernier inventaire.

- Garde-fous : L'association d'un ancien titulaire du nom (autre GUID ou antérieure à la création) n'est pas montrée.
- Opérations : `OpenAdObject`
- Références D1 : `Domenia-Core.ps1:Fill-ComputerObject`, `Domenia-Core.ps1:Open-LinkedUserFromMachine`, `Domenia-Core.ps1:Start-ProbeForSelectedComputer`, `Domenia-Main.xaml:TabComputer`, `Domenia-Main.xaml:BtnOpenLinkedUser`, `Domenia-Main.xaml:BtnRefreshMachineLink`, `XAML:TxtCompName`, `XAML:TxtCompDns`, `XAML:TxtCompOs`, `XAML:TxtCompOsVersion`, `XAML:TxtCompDescription`, `XAML:TxtCompLocation`, `XAML:TxtCompManagedBy`, `XAML:TxtCompState`, `XAML:TxtCompUac`, `XAML:TxtCompLinkConfidence`

#### PST-117 · Détection du dernier utilisateur d'un poste

`ameliore` · lecture réseau

Local d'abord (association connue immédiatement), puis pipeline : CIM utilisateur courant et LogonUI, WinRM si plausible, registre distant si autorisé, profils CIM, journal 4624 si activé, enfin tâche SYSTEM unique ; candidat vérifié par identité AD exacte, association existante jamais écrasée.

- Garde-fous : Geste explicite ou poste sélectionné uniquement ; budget 25 s et 3 s par méthode ; une fois par session ; double verrou contre un résultat obsolète ; compte local refusé. Résultat obsolète ignoré ; lecture distante indisponible = association conservée ; compte local, autre domaine ou non qualifié refusé.
- Opérations : `ComputerLastUser`
- Références D1 : `Domenia-Core.ps1:Start-ComputerUserLinkProbe`, `Domenia-Core.ps1:Complete-DomeniaComputerUserProbeUi`, `Domenia-Core.ps1:Fail-DomeniaComputerUserProbeUi`, `Domenia-Core.ps1:Receive-DomeniaComputerUserProbeProgress`, `Domenia-Core.ps1:Stop-DomeniaComputerUserProbeUi`, `Domenia-Core.ps1:Start-ProbeForSelectedComputer`, `Domenia-Main.xaml:DgLinkAttempts`, `Domenia-Relations.UI.ps1:Start-DomeniaRelationsComputerDetect`, `Domenia-Relations.UI.ps1:Complete-DomeniaRelationsComputerProbe`, `Domenia-Relations.UI.ps1:Fail-DomeniaRelationsComputerProbe`, `Start-ComputerUserLinkProbe`

<a id="mac"></a>

## Comptes machine (panneau Compte poste) (MAC)

3 fonctions : 2 améliorées, 1 partielle.

### Panneau Compte poste

#### MAC-001 · Ordre de choix du compte des opérations poste

`ameliore` · locale (aucune lecture)

Règle unique, identique au contexte des workers : compte local accepté pour ce poste, puis compte temporaire Postes accepté après un refus, compte poste saisi, compte Postes de la page Comptes, compte de connexion, enfin session Windows ; pour les secrets : temporaire, compte Secrets, sinon compte de l'annuaire.

- Garde-fous : Lecture seule : aucun bail utilisé ni retiré ; bail vérifié sur la session et le domaine courants.
- Références D1 : `modules/Domenia-Accounts.UI.ps1:Get-DomeniaMachineAccountInUse`, `modules/Domenia-Accounts.Model.ps1:Get-DomeniaMachineAccountLabel`, `LblAccountRule`

#### MAC-002 · Pastille « Compte poste : … ▾ » d'Assistance poste

> Reste à faire : Pastille « Compte poste : … ▾ » (couleur et glyphe de pause après un refus compris) et phrase « Opérations poste : … » faites, tenues à jour par la veille du moteur (machine.account.watch, équivalent de Timer:Accounts, repeintes seulement quand le texte change) et livrées prêtes à poser : mountMachineAccount(hôte, ctx, { target, show: 'pill' | 'sentence' | 'both' }) dans web/js/pages/machine/panel.js. Reste leur pose dans l’en-tête de l’écran Poste et dans la carte « Se connecter » d’Intervenir : ces écrans appartiennent aux équipes Poste et Assistance et n’existent pas sur cette branche.

`partiel` · locale (aucune lecture)

Dans l'en-tête d'Assistance poste, une pastille nomme le compte que prendra la prochaine opération sur le poste ouvert (court) avec son origine en infobulle ; la même phrase « Opérations poste : … » s'affiche dans le panneau et dans la carte « Se connecter » d'Intervenir. Un clic ouvre le panneau Compte poste.

- Garde-fous : Noms seulement, jamais de mot de passe ; mise à jour seulement quand le texte change. Aucun mot de passe affiché.
- Références D1 : `modules/Domenia-Accounts.UI.ps1:Update-DomeniaMachineAccountUi`, `modules/Domenia-Accounts.Model.ps1:Get-DomeniaMachineAccountLabel`, `BtnCompAccountPill`, `LblCompOperationAccount`, `LblMachineCredential`, `Timer:Accounts`, `Domenia-Assist.UI.ps1:Update-DomeniaComputerOperationAccount`, `Get-DomeniaMachineOperationAccountText`

#### MAC-003 · Panneau latéral Compte poste

`ameliore` · locale (aucune lecture)

Panneau dans la page (pas de fenêtre) : identifiant DOMAINE\nom ou POSTE\nom, mot de passe avec œil 5 s, « Utiliser ce compte » (Entrée) en mémoire seulement, « Revenir au compte de connexion », « Fermer » ; Échap ou un clic à côté ferment sans rien changer.

- Garde-fous : Jamais enregistré sur disque ; mot de passe effacé à la fermeture ; ouverture refusée si une feuille attend une réponse ; ferme le panneau des opérations ; politique d'affichage de la configuration appliquée aux champs ; noms de contrôles uniques vérifiés au chargement. Jamais enregistré ; construit depuis la SecureString ; ordre : compte poste, compte Postes, compte de connexion, session Windows.
- Références D1 : `modules/Domenia-MachineAccount.xaml`, `modules/Domenia-Accounts.UI.ps1:Initialize-DomeniaMachineAccountPanel`, `modules/Domenia-Accounts.UI.ps1:Show-DomeniaMachineAccountPanel`, `modules/Domenia-Accounts.UI.ps1:Hide-DomeniaMachineAccountPanel`, `modules/Domenia-Accounts.UI.ps1:Switch-DomeniaMachineAccountPanel`, `TxtMachineAdminUser`, `PwdMachineAdmin`, `BtnSetMachineCredential`, `BtnClearMachineCredential`, `BtnMachineAccountClose`, `Set-MachineCredentialFromUi (Core)`, `Clear-MachineCredential (Core)`, `Domenia-Core.ps1:Set-MachineCredentialFromUi`, `Domenia-Core.ps1:Clear-MachineCredential`, `Domenia-Core.ps1:Get-DomeniaMachineOperationCredential`, `Domenia-Core.ps1:Get-DomeniaMachineOperationAccountText`, `Domenia-Main.xaml:BtnCompAccountPill`

<a id="ass"></a>

## Assistance (ASS)

16 fonctions : 5 faites, 9 améliorées, 2 partielles.

### Atelier support

#### ASS-001 · Captures historiques A/B : enregistrer et charger

`fait` · écriture

Enregistre la capture A ou B dans un fichier JSON (format Domenia.Capture.1) après confirmation, ou recharge une capture du même domaine dans un emplacement. Une capture chargée reste historique et ne devient jamais une lecture AD actuelle.

- Garde-fous : Confirmation (noms et appartenances internes, pas les champs secrets) ; seuls les champs de la liste blanche, 128 valeurs max ; même domaine ; dates futures refusées ; couverture non fournie = partielle ; format Domenia.Capture.1 contrôlé ; un document à la fois, 30 s, non annulable. Confirmation avant l'écriture. Format et domaine contrôlés au chargement. Un seul document à la fois. Les champs secrets dédiés sont exclus.
- Opérations : `DocumentStore`
- Références D1 : `Domenia-Dossier.UI.ps1:Use-DomeniaCaptureFile`, `Domenia-Dossier.UI.ps1:Start-DomeniaDocumentTask`, `Domenia-Dossier.UI.ps1:Complete-DomeniaDocumentTask`, `Domenia-Dossier.UI.ps1:Fail-DomeniaDocumentTask`, `Domenia-Dossier.Model.ps1:ConvertTo-DomeniaStoredCapture`, `CmbSupportFileSlot`, `BtnSupportSaveCapture`, `BtnSupportLoadCapture`

#### ASS-002 · Compte rendu de ticket pseudonymisé (modèle)

`ameliore` · locale (aucune lecture)

Produit un compte rendu relisible des étapes tentées, confirmées, refusées et non testées pour un objet identifié par GUID, sections au choix, pseudonymes HMAC-SHA256 sous clé de l'opérateur, table de correspondance hors du texte.

- Garde-fous : Clé ≥ 8 caractères sinon refus (jamais d'aperçu en clair à la place) ; étapes d'un autre objet ou non rattachées écartées et comptées ; détail sensible retiré ; noms masqués avant coupe ; secrets masqués deux fois ; « envoyé » n'est pas « fait ».
- Références D1 : `Domenia-Insight.Model.ps1:New-DomeniaTicketReport`, `Domenia-Insight.Model.ps1:ConvertTo-DomeniaPseudonym`, `Domenia-Insight.Model.ps1:ConvertTo-DomeniaInsightText`, `Domenia-Insight.Model.ps1:ConvertTo-DomeniaInsightMaskedNames`, `Domenia-Insight.Model.ps1:ConvertTo-DomeniaInsightStepStatus`, `Domenia-Insight.Model.ps1:ConvertTo-DomeniaInsightOutcomeText`

#### ASS-003 · Atelier support : comprendre la fiche (constats)

`ameliore` · locale (aucune lecture)

Analyse locale de la fiche déjà chargée. Règles appliquées : données non fraîches, lecture de plus de 15 min, UAC inconnu, compte désactivé, verrouillé, mot de passe expiré, trace de verrouillage, changement de mot de passe exigé, pwdLastSet à zéro, non-expiration, compte expiré ou expirant sous 7 jours, date illisible, DNS absent, adminCount=1, capture partielle, aucun signal. Chaque constat porte un niveau, un indice, une vérification proposée et une nature (Observation, Couverture, Limite).

- Garde-fous : Aucun accès AD. Une donnée absente reste indéterminée. Aucune réparation automatique. Pendant le chargement d'une autre fiche, la capture est refusée.
- Références D1 : `Domenia-Support.Model.ps1:Get-DomeniaSupportFindings`, `Domenia-Support.Model.ps1:New-DomeniaSupportFinding`, `Domenia-Support.Model.ps1:Get-DomeniaSupportInt64`, `Domenia-Support.UI.ps1:Update-DomeniaSupportAnalysis`, `BtnSupportAnalyse`, `DgSupportFindings`, `TxtSupportFindingDetail`, `LblSupportContext`, `LblSupportCoverage`, `SupportAnalysisTab`, `XAML:SupportTabs`

#### ASS-004 · Capture d'une fiche filtrée et masquée

`fait` · locale (aucune lecture)

La capture fige une liste fermée de 30 attributs (sans secrets, certificats ni notes) avec leur couverture (fourni, partiel, non fourni). Chaque valeur est limitée à 1024 caractères et 128 valeurs. Mots de passe, jetons, Bearer et clés de récupération sont masqués, et un memberOf ranged ou incomplet est marqué partiel. L'identité repose sur le GUID, sinon sur le DN.

- Garde-fous : Liste blanche positive, masquage défensif, source Live, Cache ou Unknown déclarée.
- Références D1 : `Domenia-Support.Model.ps1:Get-DomeniaSupportFieldNames`, `Domenia-Support.Model.ps1:ConvertTo-DomeniaSupportText`, `Domenia-Support.Model.ps1:New-DomeniaSupportSnapshot`, `Domenia-Support.UI.ps1:Get-DomeniaSupportCurrentSnapshot`, `Domenia-Support.UI.ps1:Set-DomeniaSupportObjectSource`

#### ASS-005 · Comparer deux captures A et B

`fait` · locale (aucune lecture)

Compare deux captures du même périmètre et du même type d'objet, attribut par attribut : Identique, Différent ou Indéterminé. Pour memberOf, affiche les groupes directs présents seulement en A ou en B. On peut capturer la fiche actuelle vers A ou B, inverser, effacer, et choisir « différences et inconnues seulement ». La comparaison distingue un même objet avant/après et deux objets différents (référence, pas un historique).

- Garde-fous : Refus si le périmètre ou le type diffèrent. Un attribut manquant n'est jamais compté comme une suppression. La casse et l'ordre de memberOf sont ignorés.
- Références D1 : `Domenia-Support.Model.ps1:Compare-DomeniaSupportSnapshots`, `Domenia-Support.UI.ps1:Set-DomeniaSupportCapture`, `Domenia-Support.UI.ps1:Update-DomeniaSupportComparison`, `BtnSupportCaptureA`, `BtnSupportCaptureB`, `BtnSupportSwap`, `BtnSupportClearCompare`, `ChkSupportDiffOnly`, `DgSupportDiff`, `TxtSupportDiffDetail`, `LblSupportA`, `LblSupportB`, `LblSupportComparison`, `SupportCompareTab`

#### ASS-006 · Incidents expliqués de la session

> Reste à faire : Les refus de l’écran Assistance entrent tous dans Incidents (journal de session, AssistanceOperations.Journaled, « Moteur occupé » reconnu) ; ceux des autres écrans n’y entrent que s’ils écrivent au journal : les journaliser tous demande un ajout dans BridgeDispatcher (fichier partagé), à l’intégration.

`partiel` · locale (aucune lecture)

Collecte les avertissements et erreurs de la session et les classe par règles fixes : conflit SMB 1219, annulation, authentification refusée, accès refusé, RPC indisponible, délai dépassé, nom DNS ou chemin non résolu, moteur occupé, PsExec. Chaque piste propose une vérification. La liste est plafonnée à 200, les doublons adjacents de moins de 2 s sont ignorés, et un filtre littéral porte sur le titre, le code et la zone.

- Garde-fous : Expressions régulières fixes sur un texte borné à 8192 caractères, avec un délai maximal de 100 ms. Aucun rattachement automatique à la fiche. Aucune collecte avant l'installation de la vue ni hors du Dispatcher.
- Références D1 : `Domenia-Support.Model.ps1:Get-DomeniaSupportIncidentRules`, `Domenia-Support.Model.ps1:Get-DomeniaSupportIncidentHints`, `Domenia-Support.Model.ps1:New-DomeniaSupportIncident`, `Domenia-Support.Model.ps1:Add-DomeniaSupportBoundedItem`, `Domenia-Support.Model.ps1:Test-DomeniaSupportLiteralMatch`, `Domenia-Support.UI.ps1:Add-DomeniaSupportIncidentFromLog`, `Domenia-Support.UI.ps1:Update-DomeniaSupportIncidents`, `DgSupportIncidents`, `TxtSupportIncidentFilter`, `TxtSupportIncidentDetail`, `BtnSupportClearIncidents`, `LblSupportIncidents`, `SupportIncidentsTab`

#### ASS-007 · Repères de session (fiches épinglées)

`ameliore` · lecture réseau

Épingle jusqu'à 24 fiches en mémoire (type, nom, DN mémorisé), sans doublon d'identité. On les rouvre par double-clic ou par bouton, avec les lectures habituelles de la fiche, et on peut les retirer. Elles sont vidées à la fermeture ou à la reconnexion.

- Garde-fous : Un repère d'un autre périmètre est refusé. Rien n'est écrit sur disque.
- Opérations : `OpenAdObject`
- Références D1 : `Domenia-Support.UI.ps1:Add-DomeniaSupportPin`, `Domenia-Support.UI.ps1:Open-DomeniaSupportPin`, `BtnSupportPin`, `BtnSupportPinCurrent`, `BtnSupportOpenPin`, `BtnSupportRemovePin`, `DgSupportPins`, `SupportPinsTab`

#### ASS-008 · Dossier support et ticket

`ameliore` · locale (aucune lecture)

Compose un texte : référence de ticket facultative (80 caractères), objet observé, constats, attributs fournis, comparaison A/B, explications d'un incident choisi (sans son message brut) et limites. On peut le prévisualiser ou le copier dans le presse-papiers.

- Garde-fous : Le message brut et la pile ne sont jamais exportés. Le texte avertit qu'il contient des métadonnées internes. La référence de ticket est filtrée.
- Références D1 : `Domenia-Support.Model.ps1:New-DomeniaSupportReport`, `Domenia-Support.UI.ps1:New-DomeniaSupportUiReport`, `TxtSupportTicket`, `BtnSupportPreview`, `BtnSupportCopyReport`, `ChkSupportIncludeIncident`, `TxtSupportReport`, `SupportReportTab`, `Set-ClipboardSafe`

#### ASS-009 · Export HTML autonome du dossier support

`ameliore` · locale (aucune lecture)

Après confirmation, écrit le dossier dans un fichier HTML autonome (CSP stricte, sans script ni ressource externe, thème clair et sombre) nommé Domenia-Support-AAAAMMJJ-HHmmss.html.

- Garde-fous : Confirmation, encodage HTML, demande d'écrasement, aucun envoi.
- Opérations : `DocumentStore`
- Références D1 : `Domenia-Support.Model.ps1:ConvertTo-DomeniaSupportHtml`, `Domenia-Support.UI.ps1:Export-DomeniaSupportHtml`, `BtnSupportExportHtml`

#### ASS-010 · Raccourcis de l'atelier (comptes, état du moteur)

`ameliore` · locale (aucune lecture)

« Voir les comptes » ouvre la page Comptes. « État moteur » affiche les tâches et l'état de fonctionnement, sans sonde réseau.

- Garde-fous : Aucun test de connexion.
- Références D1 : `BtnSupportAccounts`, `BtnSupportEngine`, `Get-DomeniaRuntimeHealthText`

#### ASS-011 · Vider l'atelier

`fait` · locale (aucune lecture)

Après confirmation, efface les captures, repères et incidents de l'atelier. Domenia.db et AD ne sont pas touchés.

- Garde-fous : Confirmation, effet limité à la mémoire.
- Références D1 : `Domenia-Support.UI.ps1:Reset-DomeniaSupportSession`, `BtnSupportClearSession`

### Dossier hors ligne

#### ASS-012 · Dossier de diagnostic hors ligne

> Reste à faire : Contrat d’arrivée défini et branché (#/assistance?postes=…, 500 noms, périmètre « Liste de postes » rempli, rien lu ni écrit avant la confirmation) ; reste aux écrans de liste (Rechercher, Comptes machine) à poser le lien « Dossier hors ligne de ces postes » avec leurs résultats affichés, à l’intégration.

`partiel` · écriture

Écrit un nouveau dossier daté dans Exports pour une intervention sans Domenia, sur un périmètre au choix : poste sélectionné, postes des résultats affichés (500 au plus) ou OU sélectionnée. Options : observations, associations, requêtes enregistrées. Le dossier contient un manifeste et des empreintes SHA-256 ; il s'obtient aussi en ligne de commande (Domenia-Automate.ps1 dossier).

- Garde-fous : Lecture seule de la base, sans réseau ni identifiant ; jamais tout le domaine implicitement ; 500 postes affichés max ; 64 Mio ; secrets, BitLocker, LAPS (métadonnées incluses), secret_state, détails bruts, journaux et comptes exclus ; un dossier à la fois ; 300 s ; réponse tardive d'une autre session ignorée. Base lue en lecture seule, aucun accès réseau ni à l'annuaire. Mots de passe, BitLocker, LAPS et champs secrets exclus. Données datées, non revérifiées.
- Opérations : `OfflineDossier`
- Références D1 : `CmbSupportOfflineScope`, `ChkSupportOfflineObservations`, `ChkSupportOfflineLinks`, `ChkSupportOfflineQueries`, `BtnSupportOfflineDossier`, `LblSupportOfflineStatus`, `Domenia-Automation.UI.ps1:Start-DomeniaOfflineDossier`, `Domenia-Automation.UI.ps1:Complete-DomeniaOfflineDossier`, `Domenia-Automation.Model.ps1:Get-DomeniaOfflineDossierPerimeter`, `Domenia-Automation.Model.ps1:New-DomeniaOfflineDossier`, `Domenia-Automation.Model.ps1:Get-DomeniaOfflineDossierName`, `Domenia-Automation.Worker.ps1:Get-DomeniaOfflineDossierWorkerCode`, `SupportOfflineTab`

### Recettes

#### ASS-013 · Recettes d'assistance guidées

`ameliore` · locale (aucune lecture)

Quatre parcours par symptôme : Connexion impossible (6 étapes), Poste lent (4), Manque d'espace (3), Logiciel absent (5). Chaque étape indique ce qu'elle lit, pourquoi, son coût, si elle est facultative et si elle demande les droits d'administration du poste. Avant le premier clic, un texte de plan résume la recette entière.

- Garde-fous : Aucune étape ne s'enchaîne seule et aucune n'écrit. Choisir une recette ne lit rien.
- Références D1 : `Domenia-Assistance.Model.ps1:Get-DomeniaAssistanceRecipes`, `Domenia-Assistance.Model.ps1:New-DomeniaAssistanceStep`, `Domenia-Assistance.Model.ps1:Get-DomeniaAssistanceRecipe`, `Domenia-Assistance.Model.ps1:Get-DomeniaAssistancePlanText`, `Domenia-Assistance.UI.ps1:Update-DomeniaAssistanceView`, `CmbAssistanceRecipe`, `LblAssistanceRecipe`, `LblAssistanceSubject`, `WsAssistance`

#### ASS-014 · Grille des étapes de recette

`ameliore` · locale (aucune lecture)

Grille aux colonnes N°, Étape (marquée facultatif), Pour (Poste ou Utilisateur), Ce qui est lu, Pourquoi, Coût et État. L'état vaut « Sélectionnez le poste/compte concerné », « À lancer », « Sans lecture : ouvrir la vue » ou « Lancée à HH:mm : résultat dans sa vue ». Le détail de l'étape choisie s'affiche en dessous.

- Garde-fous : Une étape lancée affiche son heure de lancement, jamais un succès. Les marques sont propres à la session et au DN.
- Références D1 : `Domenia-Assistance.Model.ps1:Get-DomeniaAssistanceStepState`, `Domenia-Assistance.Model.ps1:ConvertTo-DomeniaAssistanceStepRows`, `Domenia-Assistance.Model.ps1:Get-DomeniaAssistanceSubjectLabel`, `Domenia-Assistance.UI.ps1:Update-DomeniaAssistanceStepDetail`, `Domenia-Assistance.UI.ps1:Get-DomeniaAssistanceLaunchedMap`, `Domenia-Assistance.UI.ps1:Get-DomeniaAssistanceSelection`, `DgAssistanceSteps`, `LblAssistanceStep`

#### ASS-015 · Lancer une étape de recette

`ameliore` · lecture réseau

Un clic sur une étape ouvre sa vue puis démarre sa seule lecture explicite pour l'objet sélectionné. La lecture doit faire partie de la liste fermée : verrouillages 4740, stratégie de mot de passe, groupes, liens GPO, GPO appliquées, identité machine, diagnostic, inventaire rapide ou complet, logiciels, sessions. Le lancement n'est marqué que si une tâche du moteur est réellement partie (nouvelle tâche ou abonné de plus).

- Garde-fous : Liste blanche d'actions liées à des opérations de lecture. L'opération vient de la liste, jamais de la ligne. Le type de sujet est contrôlé. Si la vue cible refuse ou si le moteur est saturé, « rien n'a été lancé ».
- Opérations : `LockoutDiagnosis`, `PasswordPolicyRead`, `GroupPathRead`, `GpoLinksRead`, `GpoAppliedRead`, `MachineIdentityRead`, `ComputerDiagnostics`, `ComputerInventory`, `SoftwareInventory`, `SessionsList`
- Références D1 : `Domenia-Assistance.Model.ps1:Get-DomeniaAssistanceActions`, `Domenia-Assistance.Model.ps1:Test-DomeniaAssistanceDispatched`, `Domenia-Assistance.UI.ps1:Invoke-DomeniaAssistanceStep`, `Domenia-Assistance.UI.ps1:Get-DomeniaAssistanceTaskMarks`, `BtnAssistanceRun`

#### ASS-016 · Ouvrir la vue d'une étape

`fait` · locale (aucune lecture)

Ouvre la vue où l'étape présente ses informations (fiche, Audit AD et son onglet interne, vues du poste), sans rien lire. Une vue absente de cette version est signalée.

- Garde-fous : Une route inconnue n'est jamais devinée.
- Références D1 : `Domenia-Assistance.UI.ps1:Open-DomeniaAssistanceRoute`, `Domenia-Assistance.UI.ps1:Open-DomeniaAssistanceStepView`, `BtnAssistanceOpen`, `Show-DomeniaAdAuditTool`

<a id="req"></a>

## Atelier de requêtes (REQ)

69 fonctions : 29 faites, 37 améliorées, 3 partielles.

### 1. Créer

#### REQ-001 · Recherche d'une information à filtrer

`ameliore` · locale (aucune lecture)

Filtre la liste des informations interrogeables par mots, sans tenir compte de la casse ni des accents (fr-FR), sur le nom, la source, la catégorie, la description et les détails techniques.

- Garde-fous : Conserve le champ sélectionné s'il reste dans la liste filtrée.
- Références D1 : `TxtQueryFieldSearch`, `CmbQueryField`, `Domenia-Query.Model.ps1:Find-DomeniaQueryCatalogEntries`

#### REQ-002 · Condition typée : champ, opérateur, valeur

`ameliore` · locale (aucune lecture)

Construit un critère avec opérateurs adaptés au type : texte (égal, différent, contient, commence par, se termine par), nombre (>, >=, &lt;, &lt;=), oui/non, plus « est absent » / « est renseigné ». Les valeurs codées (LAPS O/E/N/X, BitLocker K/N/X, cycle Windows, présence, famille OS, sondes à correspondance) sont proposées en liste.

- Garde-fous : Saisie désactivée pour absent/renseigné ; Oui/Non validé (oui, vrai, 1…) ; opérateur incompatible refusé par le compilateur.
- Références D1 : `CmbQueryField`, `CmbQueryOperator`, `TxtQueryValue`, `CmbQueryValueChoice`, `Domenia-Query.Model.ps1:Get-DomeniaQueryOperators`, `Domenia-Query.UI.ps1:Update-DomeniaQueryOperators`

#### REQ-003 · Conversion d'unités en direct

`ameliore` · locale (aucune lecture)

Montre avant l'ajout la valeur retenue après conversion (8192 Mo = 8 Go, 48 h = 2 j) ou le motif du refus. Accepte Go/Mo/To/Ko, jours/heures/minutes, %, Mbit/s-Gbit/s-kbit/s, MHz/GHz et la virgule décimale.

- Garde-fous : Unité incompatible refusée avec l'unité attendue ; division sur décimal exact (pas d'arrondi).
- Références D1 : `LblQueryValueConversion`, `Domenia-Query.UI.ps1:Update-DomeniaQueryValuePreview`, `Domenia-Query.Model.ps1:Get-DomeniaQueryNumberPreview`, `Domenia-Query.Model.ps1:ConvertTo-DomeniaQueryNumber`

#### REQ-004 · Aide contextuelle du champ choisi

`ameliore` · locale (aucune lecture)

Affiche sous l'éditeur la source (AD, calcul local, relevé, sonde WMI), l'unité, la description, le coût de lecture et la règle de fraîcheur de l'information sélectionnée.

- Références D1 : `LblQueryFieldHelp`, `Domenia-Query.UI.ps1:Update-DomeniaQueryOperators`

#### REQ-005 · Ajouter ou retirer un critère simple

`fait` · locale (aucune lecture)

Ajoute le critère courant à la liste « Vos critères » (Champ, Condition, Valeur) ou retire la ligne sélectionnée ; combinaison ET (toutes) ou OU (au moins une).

- Garde-fous : Chaque modification est recompilée ; 64 conditions au plus (simples + segment + arbre).
- Références D1 : `BtnQueryAddCondition`, `BtnQueryRemoveCondition`, `DgQueryConditions`, `CmbQueryJunction`, `Domenia-Query.UI.ps1:Invoke-DomeniaQueryAction`

#### REQ-006 · Nouvelle requête, nom et chargement rapide

`fait` · locale (aucune lecture)

« Nouvelle » repart d'un brouillon vide, le nom se saisit librement et « Charger » reprend une des 100 requêtes enregistrées les plus récentes (date de révision UTC) ou le brouillon courant.

- Garde-fous : Nom 1 à 120 caractères ; identifiant [a-zA-Z0-9_.-]{1,80} ; changer de brouillon efface résultats, couverture, plan et revue d'impact.
- Références D1 : `BtnQueryNew`, `BtnQueryLoad`, `CmbFleetQuery`, `TxtFleetQueryName`, `Domenia-Query.UI.ps1:Update-DomeniaQueryLibraryControls`, `Domenia-Query.UI.ps1:Set-DomeniaQueryDraft`

#### REQ-007 · Répartition (compteur ou regroupement)

`ameliore` · locale (aucune lecture)

Choisit si la requête produit un simple compteur de postes ou une répartition par une information (OS, version, OU, modèle, sonde…), réutilisée par l'aperçu et par le widget.

- Garde-fous : Champ de répartition inconnu refusé.
- Références D1 : `CmbQueryGroupField`

### 1. Créer · conditions avancées

#### REQ-008 · Arbre de conditions ET / OU / NON

`ameliore` · locale (aucune lecture)

Ajoute des groupes imbriqués combinés en ET avec les critères simples, y insère le critère choisi, réordonne (↑ ↓), retire un nœud ou efface l'arbre ; l'arbre s'affiche indenté avec un libellé français par nœud.

- Garde-fous : 8 niveaux et 256 éléments au plus ; retirer l'enfant obligatoire d'un NON ou d'une collection est refusé sans modifier le brouillon.
- Références D1 : `ExpQueryAdvanced`, `BtnQueryGroupAll`, `BtnQueryGroupAny`, `BtnQueryGroupNot`, `BtnQueryTreeCondition`, `BtnQueryTreeRemove`, `BtnQueryTreeUp`, `BtnQueryTreeDown`, `BtnQueryTreeClear`, `LstQueryExpression`, `Domenia-Query.Model.ps1:Edit-DomeniaQueryExpression`, `Domenia-Query.Model.ps1:Get-DomeniaQueryExpressionOutline`, `Domenia-Query.UI.ps1:Invoke-DomeniaQueryAdvancedAction`

#### REQ-009 · Condition sur une collection d'instances

`ameliore` · locale (aucune lecture)

Vérifie plusieurs propriétés sur une même instance d'une sonde (disque, service, carte…) avec le quantificateur « au moins une », « toutes » ou « aucune », via des critères d'instance typés.

- Garde-fous : Pas de collection imbriquée ; propriétés de la même sonde uniquement ; 10 000 instances par poste ; collecte partielle ou valeur tronquée = Inconnu.
- Opérations : `LocalQuery`
- Références D1 : `CmbQueryCollectionProbe`, `CmbQueryQuantifier`, `BtnQueryCollectionAdd`, `CmbQueryInstanceField`, `CmbQueryInstanceOperator`, `TxtQueryInstanceValue`, `BtnQueryInstanceAdd`, `Domenia-Query.Model.ps1:Get-DomeniaQueryInstanceFields`, `Domenia-Query.Model.ps1:ConvertTo-DomeniaQueryInstances`

#### REQ-010 · Paramètres réutilisables de requête

`ameliore` · locale (aucune lecture)

Transforme un critère simple en paramètre nommé, dont la valeur se change dans un formulaire typé (liste pour Oui/Non et codes, texte contrôlé en direct sinon) puis « Appliquer la valeur », sans recréer la requête.

- Garde-fous : 32 paramètres au plus, nom unique [A-Za-z][A-Za-z0-9_]{0,63}, libellé 80 caractères, bornes min/max numériques, texte 4 096 caractères, jamais évalué comme du code.
- Références D1 : `TxtQueryParameterName`, `BtnQueryParameterAdd`, `DgQueryParameters`, `TxtQueryParameterValue`, `CmbQueryParameterChoice`, `BtnQueryParameterApply`, `LblQueryParameterEdit`, `LblQueryParameterCheck`, `Domenia-Query.Model.ps1:Get-DomeniaQueryParameterRows`, `Domenia-Query.Model.ps1:ConvertTo-DomeniaQueryParameterValue`, `Domenia-Query.Model.ps1:Resolve-DomeniaQueryParameters`

#### REQ-011 · Paramètre rempli avec l'OU du tableau de bord

`ameliore` · locale (aucune lecture)

Pour un paramètre portant sur le chemin AD ou l'OU, « OU du tableau de bord » insère le DN ou le nom de l'OU suivie.

- Garde-fous : Refusé si aucune OU n'est suivie : le domaine entier ne sert pas de paramètre.
- Références D1 : `BtnQueryParameterScope`, `Domenia-Query.UI.ps1:Invoke-DomeniaQueryAdvancedAction`

#### REQ-012 · Figer les valeurs des paramètres

`fait` · locale (aucune lecture)

« Fixer les valeurs actuelles » remplace chaque paramètre par sa valeur courante et retire le formulaire de paramètres du brouillon.

- Garde-fous : Paramètre lié à un autre champ que sa condition refusé.
- Références D1 : `BtnQueryParameterFreeze`, `Domenia-Query.Model.ps1:Resolve-DomeniaQueryParameters`

#### REQ-013 · Fenêtre de cohérence des dates sources

`ameliore` · locale (aucune lecture)

Écart maximal en heures entre les dates des informations d'un poste ; au-delà, ou si une date manque, le verdict devient Inconnu.

- Garde-fous : Valeur strictement positive et ≤ 8 760 h, ou vide (aucune contrainte).
- Références D1 : `TxtQueryCoherenceHours`, `Domenia-Query.Model.ps1:ConvertTo-DomeniaCompiledQuery`

### 1. Créer · couverture et dates

#### REQ-014 · Vérifier la couverture des informations

`ameliore` · lecture locale

Compte, pour chaque information demandée, les postes où elle est disponible, expirée, en erreur, incomplète ou non lue, et combien de postes ont tout ; aucune collecte n'est lancée.

- Garde-fous : Calcul hors fil d'interface ; résultat écarté si session, génération, instantané ou périmètre ont changé.
- Opérations : `LocalQuery`
- Références D1 : `BtnQueryCoverage`, `ExpQueryCoverage`, `DgQueryCoverage`, `LblQueryCoverage`, `Domenia-Query.Model.ps1:Measure-DomeniaQueryCoverage`

#### REQ-015 · Dates de chaque source

`ameliore` · lecture locale

Tableau des horloges distinctes (annuaire, ping, console, inventaire, chaque sonde, SELECT mémorisé) avec les informations concernées, postes datés/sans date, date la plus ancienne et la plus récente.

- Garde-fous : Un ping ne rajeunit jamais l'inventaire ni une sonde : chaque canal garde sa date.
- Opérations : `LocalQuery`
- Références D1 : `DgQueryCoherenceSources`, `Domenia-Query.Model.ps1:Get-DomeniaQueryTimestampSource`, `Domenia-Query.Model.ps1:Get-DomeniaQueryTimestampKey`

#### REQ-016 · Proposition de fenêtre commune

`ameliore` · locale (aucune lecture)

Propose la plus petite fenêtre usuelle (1 h à 1 an) couvrant au moins 90 % des postes entièrement datés, limitée à 24 h si une mesure instantanée est en jeu ; un bouton l'applique au brouillon.

- Garde-fous : Rien n'est enregistré ni collecté ; bouton désactivé si la fenêtre est déjà celle du brouillon.
- Références D1 : `LblQueryCoherenceProposal`, `BtnQueryApplyCoherence`, `Domenia-Query.Model.ps1:Get-DomeniaQueryCoherenceProposal`, `Domenia-Query.UI.ps1:Use-DomeniaQueryCoherenceProposal`

#### REQ-017 · Collecter seulement les données manquantes

`ameliore` · lecture réseau

Prépare localement un plan listant les postes actifs dont les mesures demandées manquent, sont en erreur, incomplètes ou trop anciennes, les familles (ping, console, inventaire, sondes) et le coût compté (Faible/Modéré/Élevé selon 100/500 postes et sondes lentes), puis lance le relevé ciblé.

- Garde-fous : Refusé si la requête n'utilise que la base AD ; comptes désactivés ou d'état inconnu exclus ; console lue seulement si nécessaire ; le relevé revérifie chaque poste avant lecture et demande confirmation ; SELECT WMI avancés jamais collectés en masse ; 256 informations au plus ; aucune durée inventée.
- Opérations : `LocalQuery`, `ParkSweep`, `ComputerPing`
- Références D1 : `BtnQueryCollect`, `ExpQueryCollectionPlan`, `LblQueryCollectionPlan`, `Domenia-Query.Model.ps1:New-DomeniaQueryMissingCollectionPlan`, `Domenia-Query.Model.ps1:New-DomeniaMissingCollectionPlan`, `Domenia-Query.Model.ps1:Measure-DomeniaCollectionPlanWorkload`, `Domenia-Query.Model.ps1:Format-DomeniaQueryCollectionPlanText`, `Domenia-Query.UI.ps1:Complete-DomeniaQueryEvaluation`, `Start-DomeniaOnlinePark`

#### REQ-018 · Fenêtres de réutilisation des mesures

`fait` · locale (aucune lecture)

Règle invisible : une mesure est réutilisée si elle a moins de 1 min (volatile), 5 min (inventaire léger) ou la durée de cache choisie (24 h max), ou moins de N jours en mode « âge de réutilisation ».

- Garde-fous : Mesure marquée expirée/erreur/incomplète, non datée ou datée dans le futur (+1 min) jamais considérée fraîche.
- Références D1 : `Domenia-Query.Model.ps1:Get-DomeniaCollectionMaxAgeSeconds`, `Domenia-Query.Model.ps1:Test-DomeniaQueryVolatileKey`, `Domenia-Query.Model.ps1:Get-DomeniaCollectionFieldFamily`

### 2. Aperçu

#### REQ-019 · Liste locale des postes du périmètre

`fait` · lecture locale

Grille des comptes ordinateur du dernier calcul (nom, état Activé/Désactivé/État inconnu, dernière connexion, DN) avec filtre texte sur nom ou DN, filtre d'état et compteur « N affichés sur M — base locale ». Bascule sur l'évaluation de l'atelier quand une requête est liée.

- Garde-fous : Jamais de requête AD ni poste ; inclut les désactivés.
- Références D1 : `Domenia-Dashboard.UI.ps1:Update-DomeniaFleetMachineList`, `DgFleetMachines`, `TxtFleetMachineFilter`, `CmbFleetMachineState`, `LblFleetMachineCount`, `XAML:BtnFleetShowMachines`

#### REQ-020 · Aperçu local de la requête

`ameliore` · lecture locale

Évalue la requête sur les données locales du périmètre et affiche correspondants, inconnus, non correspondants, postes filtrés et recensés, par pages de 200, avec la définition (révision) évaluée et la population décrite.

- Garde-fous : Si la base de l'OU est périmée ou en calcul, actualisation demandée puis recalcul ; résultat ignoré si session/génération/instantané/périmètre ont changé ; clé de remplacement query:local ; re-calcul anti-rebond 350 ms.
- Opérations : `LocalQuery`, `LocalIndexRead`
- Références D1 : `BtnQueryRun`, `BtnQueryPreview`, `TabQueryResults`, `LblQueryStatus`, `LblFleetMachineCount`, `Domenia-Query.UI.ps1:Start-DomeniaQueryEvaluation`, `Domenia-Query.UI.ps1:Complete-DomeniaQueryEvaluation`, `Domenia-Query.Worker.ps1:Get-DomeniaQueryWorkerCode`, `Domenia-QueryDetails.UI.ps1:Start-DomeniaQueryCompute`

#### REQ-021 · Filtres d'affichage de l'aperçu

`ameliore` · lecture locale

Restreint la liste par texte (nom ou DN), par état de compte (tous, actifs, désactivés) et par verdict (correspondants, inconnus, non correspondants).

- Garde-fous : Les filtres d'affichage ne changent pas la répartition ni le widget.
- Opérations : `LocalQuery`
- Références D1 : `TxtFleetMachineFilter`, `CmbFleetMachineState`, `CmbQueryResult`

#### REQ-022 · Colonnes, tri et pagination des résultats

`ameliore` · lecture locale

Grille des postes : présence (●/○/?), poste, état, système AD, version AD, connexion AD (jours), âge du relevé, valeurs interrogées, chemin AD ; tri serveur par colonne et pages précédente/suivante de 200.

- Garde-fous : Tri limité aux champs connus ; boutons de page désactivés aux bornes.
- Opérations : `LocalQuery`
- Références D1 : `DgFleetMachines`, `BtnQueryPrevious`, `BtnQueryNext`, `Domenia-Query.Model.ps1:ConvertTo-DomeniaQueryGridRows`

#### REQ-023 · Segment actif et retrait du segment

`fait` · locale (aucune lecture)

Indique le segment qui restreint la requête (conditions de raffinement ET, segment de sonde ou sélection figée de GUID) et le retire d'un clic.

- Références D1 : `LblQuerySegment`, `BtnQueryClearSegment`, `Domenia-Query.UI.ps1:Invoke-DomeniaQueryAction`

#### REQ-024 · Fiche locale du poste sélectionné

`fait` · locale (aucune lecture)

Pour la ligne choisie (ou double-clic), liste chaque information du parc avec sa valeur locale, sa disponibilité et la date du relevé, plus GUID, DN et date de calcul.

- Garde-fous : Aucune relecture : données de l'aperçu calculé.
- Références D1 : `ExpQueryObject`, `DgQueryObjectFields`, `LblQueryObject`, `Domenia-Query.UI.ps1:Show-DomeniaQueryObjectDetails`, `Domenia-Query.Model.ps1:Get-DomeniaQueryValuePresentation`

#### REQ-025 · Pourquoi ce résultat ?

`ameliore` · locale (aucune lecture)

Explique le verdict du poste choisi : chaque condition, segment, nœud d'arbre, collection et contrainte de cohérence avec sa valeur, son verdict (Vrai/Faux/Inconnu), sa disponibilité et la date de la source.

- Garde-fous : Évalue la définition figée de l'aperçu, pas le brouillon modifié depuis.
- Références D1 : `DgQueryExplanation`, `Domenia-Query.Model.ps1:Get-DomeniaQueryExplanation`

#### REQ-026 · Ouvrir la fiche AD depuis l'aperçu

`fait` · lecture réseau

« Fiche AD et actions… » ouvre l'objet sélectionné par son DN et son GUID, sans lancer de sonde distante automatique.

- Garde-fous : Exige un aperçu à jour (même instantané) et une ligne sélectionnée ; -SuppressRemoteProbes.
- Opérations : `OpenAdObject`
- Références D1 : `BtnQueryObjectOpen`, `Domenia-Query.UI.ps1:Get-DomeniaQuerySelectedRow`, `Open-AdObject`

#### REQ-027 · Actualiser ce poste

`fait` · lecture réseau

Lance un relevé explicite du seul poste sélectionné pour rafraîchir ses mesures.

- Garde-fous : Exige un aperçu à jour ; relevé borné à une cible.
- Opérations : `ParkSweep`
- Références D1 : `BtnQueryObjectCollect`, `Start-DomeniaOnlinePark`

#### REQ-028 · Copier le chemin AD

`fait` · locale (aucune lecture)

Copie dans le presse-papiers le DN du poste sélectionné.

- Garde-fous : Exige une ligne valide de l'aperçu à jour.
- Références D1 : `BtnQueryObjectCopy`

#### REQ-029 · Répartition complète et exacte

`ameliore` · lecture locale

Liste toutes les valeurs de la répartition (rang, valeur, postes, part en %) pour tout le périmètre, filtrable par libellé et paginée par 100, avec la catégorie « Valeur inconnue ».

- Garde-fous : 100 000 valeurs distinctes au plus, refus sans répartition partielle ; total vérifié égal au nombre de correspondants ; filtre 256 caractères.
- Opérations : `LocalQuery`
- Références D1 : `ExpQueryGroups`, `DgQueryGroups`, `TxtQueryGroupFilter`, `BtnQueryGroupsPrevious`, `BtnQueryGroupsNext`, `LblQueryGroups`, `Domenia-Query.Model.ps1:Get-DomeniaQueryGroupSummary`, `Domenia-Query.Model.ps1:Get-DomeniaQueryGroupPage`

#### REQ-030 · Afficher les postes d'une valeur de répartition

`fait` · lecture locale

Crée un segment pour la valeur choisie (ou « Valeur inconnue », ou « Autres valeurs » par exclusions) et relance l'aperçu sur ces postes.

- Garde-fous : Refusé si la répartition ne correspond plus à la requête affichée.
- Opérations : `LocalQuery`
- Références D1 : `BtnQueryGroupsShow`, `Domenia-Query.UI.ps1:Show-DomeniaQueryGroupMachines`, `Domenia-Query.Model.ps1:New-DomeniaQuerySegmentRecipe`

#### REQ-031 · Exporter tous les résultats en CSV

`ameliore` · écriture

Écrit dans Exports un CSV (UTF-8 BOM, « ; ») de tous les postes du verdict choisi, rejouant l'instantané figé de l'aperçu, et un fichier .metadata.json (population, critères, horloges des données, révision, SHA-256).

- Garde-fous : Nombre de lignes vérifié égal à l'aperçu sinon aucun fichier ; 200 000 lignes max ; secrets masqués (compteur) ; formules neutralisées ; écriture temporaire puis déplacement ; nom unique ; un export à la fois ; note si la vue a été recalculée depuis.
- Opérations : `QueryExport`
- Références D1 : `BtnQueryExport`, `Domenia-Query.UI.ps1:Start-DomeniaQueryExport`, `Domenia-Query.UI.ps1:Complete-DomeniaQueryExport`, `Domenia-Query.Worker.ps1:Get-DomeniaQueryExportWorkerCode`, `Domenia-Query.UI.ps1:Get-DomeniaQueryExportClocks`

#### REQ-032 · Population décrite de l'aperçu

`ameliore` · locale (aucune lecture)

Le résumé de publication nomme la population comptée : domaine, OU, profondeur, types, requête et empreinte de définition, verdict, filtres, révision locale, et la date du calcul.

- Garde-fous : Population non décrite signalée comme telle, jamais comparée à un autre chiffre.
- Références D1 : `LblQueryPublishSummary`, `Domenia-Query.UI.ps1:Get-DomeniaQueryExportPopulation`, `New-DomeniaPopulationDescriptor`, `Compare-DomeniaPopulation`

#### REQ-033 · Journal des aperçus

`fait` · locale (aucune lecture)

Chaque aperçu calculé laisse une ligne « Requêtes » dans le journal de l'interface (nom, compteurs, date du calcul local).

- Références D1 : `Domenia-Query.UI.ps1:Complete-DomeniaQueryEvaluation`, `Add-DomeniaUiLog`

### 3. Enregistrer

#### REQ-034 · Enregistrer la requête (révision SQLite)

> Reste à faire : Fait : bibliothèque dans son propre fichier par domaine (verrou machine, relecture sous le verrou, révision vérifiée sur le disque, écriture atomique, reçu « relue » seulement après relecture du disque, 16 Mio et 5 000 requêtes, enregistrements illisibles conservés), brouillon repris avec sa révision, brouillon modifié pendant l’écriture jamais écrasé. Reste : la migration de la bibliothèque SQLite de Domenia 1 (domenia_query_recipes, révisions, provenance, dépendances) passe par Domenia.Store (vague 3) ; d’ici là, un pack exporté par Domenia 1 s’importe sans perte (examen, provenance, point de restauration).

`partiel` · écriture

Enregistre la définition dans la bibliothèque locale du domaine avec une nouvelle révision ; un modèle livré est d'abord copié en requête personnelle.

- Garde-fous : Boutons désactivés tant que la bibliothèque n'est pas lue et confirmée ; révision attendue vérifiée ; reçu SQLite exigé (source, StoreId, révision supérieure) ; liste blanche des propriétés ; 1 Mio par définition ; un enregistrement à la fois ; refus en maintenance de la base ; un brouillon modifié pendant l'écriture n'est pas écrasé.
- Opérations : `LocalStore`
- Références D1 : `BtnQuerySave`, `TabQueryPublish`, `Domenia-QueryLibrary.Store.UI.ps1:Save-DomeniaQueryRecipe`, `Domenia-QueryLibrary.Store.UI.ps1:Complete-DomeniaQueryRecipeStore`, `Domenia-QueryLibrary.Model.ps1:New-DomeniaQueryLibraryRecord`

#### REQ-035 · Catégorie de rangement

`fait` · locale (aucune lecture)

Choisit ou saisit la catégorie de la bibliothèque personnelle (« Mes requêtes » par défaut) ; laisser la catégorie affichée garde celle déjà enregistrée.

- Garde-fous : 80 caractères, sans caractère de contrôle.
- Références D1 : `CmbQuerySaveCategory`, `Domenia-Query.UI.ps1:Get-DomeniaQuerySaveCategory`

#### REQ-036 · Revue d'impact avant modification

`ameliore` · locale (aucune lecture)

Avant d'enregistrer une définition modifiée ou d'archiver, liste les éléments qui l'utilisent : widgets des tableaux général et poste avec leur révision liée, liens orphelins, favori de Recherche, règles de santé (qui gardent leur révision).

- Garde-fous : Rien n'est écrit avant le choix ; inutile si la définition est inchangée (même SHA) ou nouvelle.
- Références D1 : `PnlQueryImpact`, `DgQueryImpact`, `LblQueryImpact`, `Domenia-Query.UI.ps1:Get-DomeniaQueryDraftImpact`, `Domenia-Query.UI.ps1:Show-DomeniaQueryImpact`, `Domenia-QueryLibrary.Model.ps1:Get-DomeniaQueryRecipeImpact`

#### REQ-037 · Mettre à jour, garder une copie, archiver ou annuler

`ameliore` · écriture

Choix de la revue : lier les éléments à la nouvelle définition, garder l'ancienne intacte et enregistrer une copie « (nouvelle version) », archiver et retirer les widgets, ou annuler.

- Garde-fous : Refusé si le brouillon ou la révision ont changé depuis la revue ; recette + liens dans un même lot atomique (249 dépendances max).
- Opérations : `LocalStore`
- Références D1 : `BtnQueryImpactMigrate`, `BtnQueryImpactKeep`, `BtnQueryImpactArchive`, `BtnQueryImpactCancel`, `Domenia-Query.UI.ps1:Invoke-DomeniaQueryImpactAction`, `Domenia-QueryLibrary.Model.ps1:New-DomeniaQueryRecipeVersion`

#### REQ-038 · Archiver une requête

`fait` · écriture

Archive la définition (révisions et données conservées) et retire ses widgets des tableaux de bord avec possibilité d'annulation de disposition.

- Garde-fous : Revue d'impact ; liens détachés dans le même lot ; modèles livrés non archivables ; recette non enregistrée refusée ; Undo de disposition.
- Opérations : `LocalStore`
- Références D1 : `BtnQueryDelete`, `Domenia-Query.UI.ps1:Request-DomeniaQueryRecipeSave`, `Domenia-QueryLibrary.Store.UI.ps1:Complete-DomeniaQueryRecipeArchiveUi`

#### REQ-039 · Créer une sonde (widget) de tableau de bord

> Reste à faire : Fait : recette et widget dans la même écriture, revue d’impact exigée par le moteur (jamais de migration imposée), plan de collecte ouvert aussitôt le widget ajouté (confirmé avant toute lecture), requetes.widget.evaluate (révision liée, chiffres, répartition, verdict d’un poste) et aperçu vivant des widgets dans l’atelier. Reste : l’affichage sur l’Accueil et la Fiche, écrans d’autres lots, qui liront requetes.widget.list puis requetes.widget.evaluate (docs/ops/requetes.md § 6.4).

`partiel` · écriture

Enregistre la requête et l'ajoute (ou met à jour) en widget du tableau général ou du tableau du poste, en indicateur, texte, barres, camembert ou colonnes ; un widget ajouté collecte aussitôt ses données manquantes.

- Garde-fous : Revue d'impact si la définition enregistrée change ; recette et lien widget écrits ensemble ; widget installé seulement après reçu ; disposition conservée avec Undo.
- Opérations : `LocalStore`, `ParkSweep`
- Références D1 : `BtnQueryWidget`, `CmbQueryWidgetDestination`, `CmbQueryWidgetVisual`, `Domenia-QueryTargets.UI.ps1:Add-DomeniaWorkshopWidget`, `Domenia-QueryTargets.UI.ps1:Complete-DomeniaWorkshopWidgetSave`, `Start-DomeniaWidgetRefresh`

#### REQ-040 · Tester la requête sur le poste sélectionné

`fait` · locale (aucune lecture)

Évalue le brouillon sur le seul poste de la fiche ouverte et dit s'il correspond, ne correspond pas, reste inconnu ou est hors sélection.

- Garde-fous : Aucune lecture réseau ni collecte.
- Références D1 : `BtnQueryPreviewComputer`, `LblQueryComputerPreview`, `Domenia-QueryTargets.UI.ps1:Show-DomeniaWorkshopComputerPreview`, `Domenia-QueryTargets.UI.ps1:Get-DomeniaComputerQueryRecords`

### Bibliothèque

#### REQ-041 · Bibliothèque de requêtes paginée

`ameliore` · lecture locale

Liste modèles livrés, requêtes personnelles et archives (colonnes Requête, Catégorie, Informations nécessaires), recherche sans accents, filtres de catégorie et de source, pages de 100.

- Garde-fous : Préparée à l'ouverture de l'onglet, hors fil d'interface ; archives visibles seulement sous « Archives » ; définitions archivées illisibles rejetées et comptées.
- Opérations : `QueryLibrary`
- Références D1 : `TabQueryLibrary`, `DgQueryLibrary`, `TxtQueryLibrarySearch`, `CmbQueryLibraryCategory`, `CmbQueryLibrarySource`, `BtnQueryLibraryPrevious`, `BtnQueryLibraryNext`, `LblQueryLibraryCount`, `Domenia-Query.UI.ps1:Start-DomeniaQueryLibraryLoad`, `Domenia-Query.UI.ps1:Update-DomeniaQueryLibrary`, `Domenia-Query.Worker.ps1:Get-DomeniaQueryLibraryWorkerCode`

#### REQ-042 · Détail d'usage d'une requête

`ameliore` · locale (aucune lecture)

Affiche description, source des données (base AD locale, relevé, inventaire, nombre de sondes), nécessité éventuelle de collecte et provenance déclarée (pack, version, recette source, définition modifiée localement).

- Garde-fous : Provenance présentée comme déclarée, jamais comme éditeur vérifié.
- Références D1 : `LblQueryLibraryDescription`, `LblQueryLibraryCollection`, `Domenia-Query.UI.ps1:Show-DomeniaQueryLibraryDetails`

#### REQ-043 · Utiliser une requête de la bibliothèque

`fait` · locale (aucune lecture)

Charge la requête choisie dans le compositeur pour l'adapter, la prévisualiser ou en faire un widget, sans collecte.

- Garde-fous : Désactivé pour une requête archivée.
- Références D1 : `BtnQueryLibraryUse`, `Domenia-Query.UI.ps1:Use-DomeniaQueryLibrarySelection`

#### REQ-044 · Restaurer une requête archivée

`fait` · écriture

Réactive une définition archivée avec une nouvelle révision dans sa catégorie ; les révisions précédentes restent conservées.

- Garde-fous : Révision vérifiée par SQLite.
- Opérations : `LocalStore`
- Références D1 : `BtnQueryLibraryRestore`, `Domenia-Query.UI.ps1:Restore-DomeniaQueryLibrarySelection`, `Domenia-QueryLibrary.Store.UI.ps1:Complete-DomeniaQueryRecipeRestoreUi`

#### REQ-045 · Catalogue de modèles livrés

`ameliore` · locale (aucune lecture)

Plus de 120 filtres simples (comptes AD, LAPS, BitLocker, cycle Windows, matériel, disques, Defender/TPM, réseau, services, utilisateurs, événements, qualité des données), 25 répartitions, 4 vérifications croisées, modèles générés (couverture, répartitions détaillées, états codés, seuils sur 19 informations) et 7 modèles paramétrés (disque, RAM, connexion, inventaire, OU, version, service).

- Garde-fous : Doublons de définition ou de titre écartés ; chaque description rappelle les limites (valeur non lue = inconnue).
- Opérations : `QueryLibrary`
- Références D1 : `Domenia-Query.Model.ps1:Get-DomeniaQueryTemplates`

### Catalogue d'informations

#### REQ-046 · Catalogue des informations interrogeables

`ameliore` · locale (aucune lecture)

Onglet « Informations » : chaque champ du parc et chaque sonde WMI avec source, type, unité, description, exemples/codes, comment l'obtenir, disponibilité, coût, fraîcheur et détails techniques (espace de noms, classe, propriétés, filtre, mode, conversion), filtrable par texte, source et catégorie.

- Garde-fous : Consultation locale : ne découvre jamais de classe distante ; mentions sonde lente et ignorée sur contrôleur.
- Références D1 : `TabQueryCatalog`, `DgQueryCatalog`, `TxtQueryCatalogSearch`, `CmbQueryCatalogSource`, `CmbQueryCatalogCategory`, `LblQueryCatalogCount`, `PnlQueryCatalogDetail`, `LblQueryCatalogTitle`, `LblQueryCatalogDescription`, `LblQueryCatalogValue`, `LblQueryCatalogCollection`, `LblQueryCatalogAvailability`, `LblQueryCatalogTechnical`, `BtnQueryBrowseCatalog`, `Domenia-Query.Model.ps1:Get-DomeniaQueryCatalog`, `Domenia-Query.Model.ps1:Get-DomeniaQueryFields`

#### REQ-047 · Utiliser une information du catalogue

`fait` · locale (aucune lecture)

Prépare l'éditeur de condition avec l'information choisie et place le focus sur la valeur, sans toucher aux conditions existantes.

- Garde-fous : Aucune collecte lancée.
- Références D1 : `BtnQueryCatalogUse`, `Domenia-Query.UI.ps1:Use-DomeniaQueryCatalogField`

### Liens avec Recherche

#### REQ-048 · Appliquer la requête aux résultats de Recherche

> Reste à faire : Fait : sélection figée des correspondants (GUID, date, empreinte, inconnus exclus), puis ouverture de Rechercher comme Domenia 1 (#/rechercher?requete=selection), favoris déclarables par requetes.consumer.bind. Reste : l’écran Rechercher (autre lot) doit lire requetes.search.selection pour filtrer ses résultats ; la sélection reste en mémoire de session, comme dans Domenia 1.

`partiel` · locale (aucune lecture)

Fige les GUID des postes correspondants (inconnus exclus) de l'aperçu courant comme filtre daté des résultats de Recherche, puis ouvre Rechercher.

- Garde-fous : Exige des données locales de moins d'une minute et un aperçu terminé ; la sélection ne change pas silencieusement ensuite.
- Références D1 : `BtnQueryApplySearch`, `LblSearchQuery`, `Domenia-Query.UI.ps1:Invoke-DomeniaQueryAction`, `Domenia-Query.Model.ps1:Get-DomeniaQueryMatchIds`, `Domenia-Query.UI.ps1:Test-DomeniaSearchQueryRow`

### Moteur de requêtes

#### REQ-049 · Lecture paginée des SELECT mémorisés et verdicts de collection

`fait` · lecture locale

Avant chaque calcul, lit dans la base les résumés des SELECT WMI mémorisés et projette les verdicts de collections par pages de 250 pour l'atelier et Recherche.

- Garde-fous : 64 définitions max ; 200 000 identités par définition ; 128 Mio ; identité répétée refusée ; redémarrage (2 max) si la révision de la base change ; chargement massif des détails bruts refusé.
- Opérations : `LocalIndexRead`, `LocalQuery`
- Références D1 : `Domenia-QueryDetails.UI.ps1:Start-DomeniaQueryDetailRead`, `Domenia-QueryDetails.UI.ps1:Request-DomeniaQueryDetailPage`, `Domenia-QueryDetails.UI.ps1:Complete-DomeniaQueryDetailPage`, `Domenia-QueryDetails.UI.ps1:Complete-DomeniaQueryCollectionPage`, `Domenia-QuerySchema.Model.ps1:Add-DomeniaQueryDetailRecords`, `Domenia-Query.Model.ps1:ConvertTo-DomeniaQueryCollectionProjections`, `Domenia-Query.Model.ps1:Add-DomeniaQueryCollectionProjectionRecords`

### Navigation et périmètre

#### REQ-050 · Ouvrir l'atelier de requêtes avec retour à l'origine

`fait` · locale (aucune lecture)

Ouvre l'atelier (Outils > Atelier de requêtes) en mémorisant la page, l'onglet et le contrôle d'origine ; « Retour » y revient et rend le focus. La vue XAML est chargée à la première ouverture et réaffiche le périmètre à chaque retour visible.

- Garde-fous : Noms de contrôles uniques vérifiés au chargement ; aucune évaluation lancée par la navigation seule.
- Références D1 : `Domenia-Query.UI.ps1:Show-DomeniaQueryWorkshop`, `Domenia-Query.UI.ps1:Initialize-DomeniaQueryView`, `BtnQueryBack`, `QueryWorkshopHost`, `WsQueryWorkshop`, `Domenia-Main.xaml:WsQueryWorkshop`

#### REQ-051 · Périmètre de l'atelier = OU du tableau de bord

`ameliore` · locale (aucune lecture)

L'atelier évalue l'OU suivie par le tableau de bord (ou tout le domaine indexé en consultation), affichée en tête, et la change avec le même sélecteur d'OU partagé. Il est indépendant de l'OU utilisée par Rechercher.

- Garde-fous : Si le périmètre a changé, l'aperçu est refusé et le recalcul de l'OU est demandé (Request-DomeniaFleetRefresh -Force).
- Références D1 : `Domenia-Query.UI.ps1:Update-DomeniaQueryScopeLabel`, `BtnQueryScope`, `LblQueryScope`, `Show-DomeniaFleetScopeSource`

#### REQ-052 · Modifier la requête dans l'atelier

`fait` · locale (aucune lecture)

Ouvre l'atelier de requêtes sur le compositeur (requête locale) ou la bibliothèque (requête Annuaire, filtre LDAP dédié).

- Références D1 : `Domenia-Search.UI.ps1:Open-DomeniaSearchQueryWorkshop`, `XAML:BtnSearchQueryWorkshop`

#### REQ-053 · Parcours en trois étapes : Créer, Aperçu, Enregistrer

`ameliore` · locale (aucune lecture)

L'atelier se parcourt en trois onglets numérotés (1. Créer, 2. Aperçu, 3. Enregistrer) ; « Enregistrer ou réutiliser → » passe de l'aperçu à l'enregistrement et « Modifier les critères » revient au compositeur, sans perdre le brouillon.

- Garde-fous : Changer d'étape ne lance aucun calcul, aucune requête ni aucune collecte.
- Références D1 : `XAML:QueryWorkspaceTabs`, `XAML:BtnQueryContinueSave`, `XAML:BtnQueryRevise`, `Domenia-Query.UI.ps1:Initialize-DomeniaQueryView (Add_Click des deux boutons)`

### Partage et import

#### REQ-054 · Exporter la bibliothèque en pack versionné

`ameliore` · écriture

Exporte les requêtes personnelles en pack JSON Domenia.QueryPack/2 nommé et versionné (identité stable, empreinte de contenu) ; la version proposée s'incrémente après l'export.

- Garde-fous : Nom 1-80 caractères, version 1-1 000 000 ; 5 000 recettes et 16 Mio max ; fichier existant refusé ; écriture temporaire puis déplacement ; données seulement.
- Opérations : `QueryTransfer`
- Références D1 : `ExpQueryTransfer`, `TxtQueryPackName`, `TxtQueryPackVersion`, `BtnQueryPackExport`, `Domenia-QueryTransfer.UI.ps1:Invoke-DomeniaQueryTransfer`, `Domenia-QueryLibrary.Model.ps1:New-DomeniaQueryPack`, `Domenia-QueryTransfer.Worker.ps1:Get-DomeniaQueryTransferWorkerCode`

#### REQ-055 · Exporter une requête en script PowerShell

`ameliore` · écriture

Génère un script commenté (conditions, sources, paramètres, limites) qui évalue la requête sur un instantané fourni, avec -Selection, -ParameterValues et -ShowDefinition.

- Garde-fous : Jamais exécuté par l'export ; aucun secret, aucune connexion ; recette en littéral JSON ASCII ; commentaires assainis.
- Opérations : `QueryTransfer`
- Références D1 : `BtnQueryScriptExport`, `Domenia-QueryLibrary.Model.ps1:ConvertTo-DomeniaQueryPowerShell`, `Domenia-QueryLibrary.Model.ps1:Get-DomeniaQueryRecipeOutline`

#### REQ-056 · Examiner un pack avant import

`ameliore` · lecture locale

Lit un pack et affiche provenance, version, intégrité vérifiée, version déjà importée, et pour chaque recette son état (Nouvelle, Identique, Conflit, Archivée localement, Domaine différent) avec ses différences avant/après.

- Garde-fous : Aucune écriture à l'aperçu ; 16 Mio, 5 000 recettes ; format plus récent refusé ; empreinte ou identité incohérente : rien importé ; sélection figée d'un autre domaine seulement ignorable.
- Opérations : `QueryTransfer`
- Références D1 : `BtnQueryPackImport`, `DgQueryImport`, `DgQueryImportChanges`, `LblQueryImportPack`, `LblQueryImportStatus`, `Domenia-QueryLibrary.Model.ps1:New-DomeniaQueryPackImportPlan`, `Domenia-QueryTransfer.UI.ps1:Format-DomeniaQueryImportPackText`, `Domenia-QueryTransfer.UI.ps1:Show-DomeniaQueryImportChanges`

#### REQ-057 · Choisir et appliquer l'import

`ameliore` · écriture

Choisit par recette Ignorer, Créer, Nouvelle copie ou Remplacer (« Choisir les nouvelles » coche toutes les nouvelles), puis applique ; les créations vont dans « Import · &lt;pack> » avec la provenance.

- Garde-fous : Confirmation ; actions limitées à celles autorisées ; écritures une à une avec vérification de révision ; arrêt propre et journalisé ; un import à la fois.
- Opérations : `LocalStore`
- Références D1 : `BtnQueryImportNew`, `BtnQueryImportApply`, `Domenia-QueryTransfer.UI.ps1:Start-DomeniaQueryImport`, `Domenia-QueryTransfer.UI.ps1:Submit-DomeniaQueryImportNext`, `Domenia-QueryTransfer.UI.ps1:Complete-DomeniaQueryImportItem`

#### REQ-058 · Historique des imports et retour arrière

`ameliore` · écriture

Liste les imports restaurables de cette base et « Restaurer avant cet import… » remet les définitions remplacées (ou retire les créations), y compris la reprise d'une restauration interrompue.

- Garde-fous : Journal .query-imports.jsonl à côté de la base (40 lignes, 3 Mio/ligne, écriture atomique) ; restauration refusée si une recette a été modifiée depuis ; ligne altérée (SHA) non restaurable ; disponible en session seulement si le journal ne s'écrit pas.
- Opérations : `QueryTransfer`, `LocalStore`
- Références D1 : `CmbQueryImportHistory`, `BtnQueryImportRollback`, `Domenia-QueryTransfer.UI.ps1:Request-DomeniaQueryImportHistory`, `Domenia-QueryTransfer.UI.ps1:Save-DomeniaQueryImportJournal`, `Domenia-QueryLibrary.Model.ps1:New-DomeniaQueryImportJournalEntry`, `Domenia-QueryLibrary.Model.ps1:ConvertFrom-DomeniaQueryImportJournal`, `Domenia-QueryLibrary.Model.ps1:New-DomeniaQueryImportRestorePoint`

### Référence PowerShell

#### REQ-059 · Référence des cmdlets AD et LAPS (onglet masqué)

`ameliore` · lecture locale

Charge les cmdlets des modules ActiveDirectory et LAPS (type, paramètre Credential, nombre et liste des paramètres, synopsis), filtre texte et module, aide détaillée à la sélection, copie de la commande, de la syntaxe ou de l'aide ; onglet retiré de l'interface (décision du 07/10/2026) mais code actif.

- Garde-fous : Lecture locale du poste opérateur seulement.
- Opérations : `CmdletInventory`, `CmdletHelp`
- Références D1 : `Domenia-Core.ps1:Load-AdCmdlets`, `Domenia-Core.ps1:Filter-AdCmdletReference`, `Domenia-Core.ps1:Clear-AdCmdletFilter`, `Domenia-Core.ps1:Start-SelectedCmdletHelp`, `Domenia-Core.ps1:Join-HelpText`, `Domenia-Core.ps1:Copy-SelectedCmdlet`, `Domenia-Core.ps1:Copy-SelectedCmdletSyntax`, `Domenia-Core.ps1:Copy-SelectedCmdletHelp`, `Domenia-Main.xaml:TabCmdlets`, `XAML:BtnLoadCmdlets`, `XAML:TxtCmdletFilter`, `XAML:CmbCmdletModule`, `XAML:BtnCmdletClearFilter`, `XAML:DgCmdlets`, `XAML:BtnCopyCmdlet`, `XAML:BtnCopyCmdletSyntax`, `XAML:BtnCopyCmdletHelp`, `XAML:TxtCmdletHelp`, `XAML:LblCmdletCount`

### Widgets de requêtes

#### REQ-060 · Relecture WMI mémorisée d'une requête enregistrée

`fait` · lecture réseau

Relit la lecture WMI unique enregistrée avec une requête (jamais un WQL arbitraire) sur la population du tableau, une tâche bornée par poste ; valeurs enregistrées en base avant affichage, puis date réelle annoncée.

- Garde-fous : Définition revalidée (RequestKey 64 hex, empreinte) ; confirmation sauf ajout direct ; admission/plafond ; délais 65/80 s, annulable ; identité et définition de la réponse revérifiées ; échec = valeurs précédentes conservées, aucune ligne d'erreur ; une campagne à la fois (file).
- Opérations : `WidgetWmiDetail`
- Références D1 : `Domenia-Widgets.UI.ps1:Start-DomeniaWidgetDetailCollect`, `Domenia-Widgets.UI.ps1:Complete-DomeniaWidgetDetailCollected`, `Domenia-Widgets.UI.ps1:Fail-DomeniaWidgetDetailCollected`, `Domenia-Widgets.UI.ps1:Complete-DomeniaWidgetDetailStored`, `Domenia-Widgets.UI.ps1:Fail-DomeniaWidgetDetailStored`, `Domenia-WidgetCollect.Model.ps1:Get-DomeniaWidgetDetailClocks`

### WMI avancé

#### REQ-061 · Explorer les espaces de noms WMI d'un poste

`fait` · lecture réseau

Liste les espaces de noms enfants directs d'un espace (un seul niveau) sur le poste de la fiche ouverte.

- Garde-fous : 500 espaces au plus ; espace de noms validé (root\…) ; indisponible en démonstration ; confirmation avant lecture distante.
- Opérations : `QuerySchema`, `LocalIndexRead`
- Références D1 : `TabQueryWmi`, `BtnQueryWmiNamespaces`, `TxtQueryWmiNamespace`, `LstQueryWmiNamespaces`, `Domenia-QuerySchema.UI.ps1:Invoke-DomeniaQuerySchemaAction`, `Domenia-QuerySchema.Worker.ps1:Get-DomeniaQuerySchemaWorkerCode`

#### REQ-062 · Lister les classes d'un espace WMI

`fait` · lecture réseau

Liste les définitions de classes (nom, nombre de propriétés et de clés, remarque : fournisseur MSI refusé, abstraite, association), filtrables par un nom éventuellement terminé par \*.

- Garde-fous : Définitions seulement, aucune instance ; 2 000 classes et 1 Mio ; filtre jamais traité comme fragment WQL.
- Opérations : `QuerySchema`, `LocalIndexRead`
- Références D1 : `BtnQueryWmiClasses`, `TxtQueryWmiClassFilter`, `DgQueryWmiClasses`, `Domenia-QuerySchema.Model.ps1:Assert-DomeniaQuerySchemaClassFilter`

#### REQ-063 · Lire le schéma d'une classe WMI

`fait` · lecture réseau

Affiche les propriétés (type CIM, clé, unité, description localisée) et la description de la classe ; double-clic sur une classe pour la lire ; les propriétés se cochent pour préparer un SELECT.

- Garde-fous : Propriétés au nom de secret écartées ; 1 024 propriétés max ; classe MSI refusée.
- Opérations : `QuerySchema`, `LocalIndexRead`
- Références D1 : `BtnQuerySchemaRead`, `TxtQueryWmiClass`, `DgQuerySchema`, `LblQueryWmiClassDescription`

#### REQ-064 · Métadonnées WMI en cache ou relues

`fait` · lecture locale

Espaces, classes et schémas déjà lus pour ce poste sont repris de la base avec leur date ; « Relire sur le poste » force une lecture et « Lire sur le poste… » est proposé s'il n'existe rien.

- Garde-fous : Aucune lecture distante ne part d'un rappel : bouton explicite ; offre invalidée si poste ou demande changent.
- Opérations : `LocalIndexRead`, `QuerySchema`
- Références D1 : `ChkQueryWmiForceRead`, `BtnQueryWmiRemoteRead`, `Domenia-QuerySchema.UI.ps1:Complete-DomeniaQuerySchemaCacheRead`, `Domenia-QuerySchema.UI.ps1:Show-DomeniaQuerySchemaRemoteOffer`, `Domenia-QuerySchema.UI.ps1:Start-DomeniaQuerySchemaRemoteRead`

#### REQ-065 · Préparer un SELECT depuis les propriétés cochées

`fait` · locale (aucune lecture)

Écrit « SELECT p1, p2 FROM Classe » à partir des propriétés cochées du schéma enregistré.

- Garde-fous : Exige un schéma relu et confirmé par la base.
- Références D1 : `BtnQueryWqlBuild`, `TxtQueryWql`

#### REQ-066 · Analyse locale d'un SELECT WQL

`ameliore` · locale (aucune lecture)

Analyse sans réseau le SELECT : classe, propriétés et clés ajoutées, condition WHERE, préconditions (poste, CIM, droits, schéma), limites, prudence sur fournisseurs coûteux et état « testé sur ce poste ».

- Garde-fous : Grammaire fermée (SELECT propriétés FROM classe WHERE =, &lt;>, &lt;, >, LIKE, IS NULL, AND/OR/NOT ; 8 niveaux, 512 jetons, 64 propriétés, 8 192 caractères) ; propriétés de secret refusées ; MSI interdit ; classes énumérant le domaine refusées ; Win32_UserAccount/Group/Account exigent LocalAccount = TRUE dans chaque branche.
- Références D1 : `TxtQueryWql`, `TxtQueryWmiLimit`, `LblQueryWqlPlan`, `Domenia-QuerySchema.Model.ps1:Get-DomeniaWqlPlanReport`, `Domenia-QuerySchema.Model.ps1:ConvertFrom-DomeniaWqlSelect`, `Domenia-QuerySchema.Model.ps1:Get-DomeniaWqlProviderWarnings`, `Domenia-QuerySchema.UI.ps1:Update-DomeniaQueryWqlPlan`

#### REQ-067 · Exécuter le SELECT sur le poste

`ameliore` · lecture réseau

Lit les instances sur le poste de la fiche, enregistre le résultat dans la base avant affichage (identité fournisseur, valeurs, couverture) et marque la requête testée pour cette identité AD.

- Garde-fous : Confirmation ; 1 à 2 000 instances, 1 Mio, 50 s ; annulable ; résultat partiel marqué ; garde d'authentification distante ; test lié au GUID du poste.
- Opérations : `QuerySchema`, `LocalStore`
- Références D1 : `BtnQueryWqlRun`, `DgQueryWmiRows`, `LblQueryWmiStatus`, `Domenia-QuerySchema.UI.ps1:Complete-DomeniaQuerySchemaCollected`, `Domenia-QuerySchema.UI.ps1:Complete-DomeniaQuerySchemaStored`, `Submit-DomeniaRemoteDetail`

#### REQ-068 · Lire une relation d'instance WMI

`fait` · lecture réseau

Depuis une instance enregistrée, lit une association déclarée (disque↔partition, partition↔volume, carte↔configuration IP, services dépendants) ou une référence prévue (service→processus hôte, processus→services), ou une association saisie librement.

- Garde-fous : Instance du dernier résultat du même poste uniquement ; association vérifiée comme déclarée par le fournisseur ; référence par identifiant numérique non nul ; aucune jointure libre.
- Opérations : `QuerySchema`, `LocalStore`
- Références D1 : `BtnQueryAssociations`, `CmbQueryAssociationPreset`, `TxtQueryAssociationClass`, `TxtQueryAssociationResult`, `Domenia-QuerySchema.Model.ps1:Get-DomeniaWmiRelationPresets`, `Domenia-QuerySchema.Model.ps1:Get-DomeniaWmiRelationPreset`, `Domenia-QuerySchema.Model.ps1:ConvertTo-DomeniaWmiReferenceValue`, `Domenia-QuerySchema.UI.ps1:Update-DomeniaQueryRelationPresets`

#### REQ-069 · Recette locale depuis un SELECT testé

`fait` · locale (aucune lecture)

Transforme un SELECT testé sous cette forme sur ce poste en recette « WMI · Classe » dont les champs « au moins une instance » et « nombre » portent sur les résultats mémorisés.

- Garde-fous : Bouton actif seulement après test ; aperçu et widgets n'utilisent que les SELECT déjà mémorisés, la lecture distante restant explicite.
- Références D1 : `BtnQueryWqlRecipe`, `Domenia-QuerySchema.Model.ps1:New-DomeniaQueryReadDefinition`, `Domenia-QuerySchema.Model.ps1:Get-DomeniaQueryReadDefinitionFields`

<a id="aud"></a>

## Audit AD (AUD)

23 fonctions : 14 faites, 9 améliorées.

### Commun à l'audit

#### AUD-001 · Copier la vue d'audit pour un ticket

`ameliore` · locale (aucune lecture)

Copie en texte la vue affichée (titre, résumé, colonnes et lignes séparées par tabulation) de l'onglet courant, sans aucune relecture.

- Garde-fous : 2 000 lignes par section (lignes non copiées comptées) ; cellules aplaties à 400 caractères.
- Références D1 : `BtnAdAuditCopy`, `Domenia-AdAudit.UI.ps1:Copy-DomeniaAdAuditView`, `Domenia-AdAudit.UI.ps1:Get-DomeniaAdAuditGridSection`, `Domenia-AdAudit.Model.ps1:ConvertTo-DomeniaAdAuditCopyText`

#### AUD-002 · Faits explicables de l'audit

`fait` · locale (aucune lecture)

Chaque constat est un fait avec valeur, état (Constaté, Estimé, Refusé, Indisponible, Inconnu), source, limite et date, textes historiques remis en français accentué.

- Garde-fous : Une valeur non lue reste inconnue.
- Références D1 : `Domenia-AdAudit.Model.ps1:ConvertTo-DomeniaAdAuditFactRows`, `Domenia-AdAudit.Model.ps1:Get-DomeniaFactStateLabel`, `Domenia-AdAudit.Model.ps1:Format-DomeniaLegacyFactText`, `New-DomeniaFact`

#### AUD-003 · Garde des lectures concurrentes de l'audit

`fait` · locale (aucune lecture)

Compteur par type de demande (liste, diagnostic, services, analyse) : une lecture plus récente ne remplace que celle de même type, et une nouvelle session les annule toutes.

- Garde-fous : Une lecture qui ne démarre pas ne laisse pas de « Lecture… ».
- Références D1 : `Domenia-AdAudit.UI.ps1:New-DomeniaAdAuditRequestState`, `Domenia-AdAudit.UI.ps1:Test-DomeniaAdAuditRequestCurrent`, `Domenia-AdAudit.UI.ps1:Invoke-DomeniaAdAuditStart`, `Domenia-AdAudit.UI.ps1:Reset-DomeniaAdAuditData`

### Contrôleurs

#### AUD-004 · Lister les contrôleurs du domaine

`fait` · lecture réseau

Liste les contrôleurs (nom DNS, site, système, rôle émulateur PDC ou RODC), à sélectionner (Ctrl/Maj) pour le diagnostic.

- Garde-fous : 100 contrôleurs max (borne dite) ; une liste plus récente remplace seulement la précédente.
- Opérations : `AdHealthRead`
- Références D1 : `TabAdAuditDcs`, `BtnAdAuditDcList`, `DgAdAuditDcList`, `LblAdAuditDc`, `Domenia-AdAudit.UI.ps1:Start-DomeniaAdAuditDcList`, `Domenia-AdAudit.Worker.ps1:Get-DomeniaAdHealthReadWorkerCode`

#### AUD-005 · Diagnostic des contrôleurs choisis

`fait` · lecture réseau

Pour 1 à 10 contrôleurs : résolution DNS, ports LDAP 389 et Kerberos 88, heure du RootDSE comparée au poste et à l'émulateur PDC, isSynchronized, réplication entrante, présence dans les SRV ; verdict Sans écart / À vérifier / Non lu.

- Garde-fous : 10 contrôleurs max, noms validés ; délai de port 0,5 à 3 s ; seuils 300 s et 24 h ; injoignable = « Non lu », jamais « en panne » ; rien n'est exécuté sur les contrôleurs.
- Opérations : `AdHealthRead`
- Références D1 : `BtnAdAuditDcProbe`, `AdAuditDcResultTabs`, `TabAdAuditDcHealth`, `DgAdAuditHealth`, `DgAdAuditDcFacts`, `Domenia-AdAudit.UI.ps1:Start-DomeniaAdAuditDcProbe`, `Domenia-AdAudit.Model.ps1:Get-DomeniaAdHealthView`, `Domenia-AdAudit.Model.ps1:ConvertFrom-DomeniaGeneralizedTime`

#### AUD-006 · Réplication par partenaire

`fait` · lecture réseau

Détaille chaque lien entrant : contrôleur, partenaire, partition, dernier succès, dernière tentative, résultat traduit, échecs consécutifs.

- Garde-fous : XML analysé sans DTD ni entité externe ; 1601 = « Jamais » ; refus de lecture ≠ panne.
- Opérations : `AdHealthRead`
- Références D1 : `TabAdAuditDcRepl`, `DgAdAuditRepl`, `Domenia-AdAudit.Model.ps1:ConvertFrom-DomeniaReplNeighbor`, `Domenia-AdAudit.Model.ps1:Get-DomeniaReplResultText`, `Domenia-AdAudit.Model.ps1:Get-DomeniaDurationText`

#### AUD-007 · Services des contrôleurs

`fait` · lecture réseau

Lit par CIM l'état et le démarrage de NTDS, Netlogon, KDC, W32Time, ADWS, DNS, DFSR et NtFrs et rend un constat (conforme, à vérifier, DNS hébergé ailleurs, réplication SYSVOL).

- Garde-fous : Confirmation (droits d'administration requis) ; 10 contrôleurs ; budget 60 s + 25 s/contrôleur (300 s max), contrôleurs non interrogés dits ; aucun service modifié ; refus = manque de droits.
- Opérations : `DcServicesRead`
- Références D1 : `BtnAdAuditDcServices`, `TabAdAuditDcServices`, `DgAdAuditServices`, `Domenia-AdAudit.UI.ps1:Start-DomeniaAdAuditDcServices`, `Domenia-AdAudit.Model.ps1:Get-DomeniaDcServiceView`, `Domenia-AdAudit.Worker.ps1:Get-DomeniaDcServicesReadWorkerCode`

#### AUD-008 · Comparaison d'un objet entre contrôleurs (règle non raccordée)

`ameliore` · lecture réseau

Valeurs par contrôleur avec version, date et contrôleur d'origine (msDS-ReplAttributeMetaData), contrôleurs injoignables listés.

- Garde-fous : USN locaux jamais comparés ; XML lu sans DTD ni entité externe.
- Opérations : `DcCompareRead`
- Références D1 : `Domenia-Directory.Model.ps1:Compare-DomeniaDcReadings`, `Domenia-Directory.Model.ps1:ConvertFrom-DomeniaReplMetadata`

### Identités

#### AUD-009 · Analyse des identités d'une OU

`ameliore` · lecture réseau

Sur l'OU de l'arbre de Rechercher (sous-OU en option), relève doublons (mail, UPN, matricule), noms DNS partagés, nom AD et DNS divergents et noms recyclés ou objets recréés par rapport à la base locale ; chaque constat est « À revoir ».

- Garde-fous : 5 000 objets (100 à 20 000) ; domaine entier en sous-arbre refusé ; 1 000 noms de chaque type comparés (dit) ; aucune fusion, correction ni suppression ; base locale occupée/absente dite. Tout constat est « à revoir », rien n'est déclaré supprimable ; périmètre tronqué signalé.
- Opérations : `AdConsistencyScan`, `LocalIndexRead`
- Références D1 : `TabAdAuditIdentity`, `LblAdAuditScope`, `ChkAdAuditScanSubtree`, `BtnAdAuditScan`, `DgAdAuditScan`, `LblAdAuditScan`, `Domenia-AdAudit.UI.ps1:Start-DomeniaAdAuditScan`, `Domenia-AdAudit.UI.ps1:Update-DomeniaAdAuditScanFindings`, `Domenia-AdAudit.Model.ps1:Find-DomeniaIdentityConflicts`, `Domenia-AdAudit.Worker.ps1:Get-DomeniaAdConsistencyScanWorkerCode`, `Domenia-Directory.Model.ps1:Find-DomeniaDirectoryInconsistencies`, `Domenia-AdAudit.Model.ps1`

### Objet sélectionné

#### AUD-010 · Cible de l'audit = objet de la fiche

`ameliore` · locale (aucune lecture)

L'audit porte sur l'objet de la fiche ouverte, figé au geste ; « Reprendre la sélection » la resynchronise et chaque lecture n'est proposée que pour les types concernés, avec le motif sinon.

- Garde-fous : Nouvel objet ou nouvelle session : résultats précédents effacés ; un résultat n'est appliqué qu'à la cible, la session et la génération d'origine.
- Références D1 : `LblAdAuditTarget`, `BtnAdAuditUseSelection`, `AdAuditObjectTabs`, `Domenia-AdAudit.UI.ps1:Sync-DomeniaAdAuditTarget`, `Domenia-AdAudit.UI.ps1:Update-DomeniaAdAuditTargetUi`, `Domenia-AdAudit.Model.ps1:New-DomeniaAdAuditTarget`, `Domenia-AdAudit.Model.ps1:Get-DomeniaAdAuditAvailability`, `Domenia-AdAudit.Model.ps1:Test-DomeniaAdAuditStateCurrent`, `Domenia-Main.xaml:WsAdAudit`, `XAML:AdAuditTabs`, `XAML:TabAdAuditObject`

#### AUD-011 · Stratégie de mot de passe applicable

`fait` · lecture réseau

Pour un utilisateur, lit msDS-ResultantPSO, l'expiration calculée, la stratégie fine désignée (priorité), le nombre de stratégies fines visibles et la stratégie du domaine, et dit laquelle s'applique ou pourquoi c'est inconnu.

- Garde-fous : Aucun mot de passe ni attribut secret lu ; domaine présenté en référence seulement si non prouvé ; garde d'authentification annuaire. Stratégie illisible = inconnue, rien n'est déduit du domaine ; durée absente ≠ sans limite.
- Opérations : `PasswordPolicyRead`
- Références D1 : `TabAdAuditPolicy`, `BtnAdAuditPolicy`, `DgAdAuditPolicy`, `LblAdAuditPolicy`, `Domenia-AdAudit.UI.ps1:Start-DomeniaAdAuditPolicyRead`, `Domenia-AdAudit.Model.ps1:ConvertTo-DomeniaPasswordPolicyView`, `Domenia-AdAudit.Worker.ps1:Get-DomeniaPasswordPolicyReadWorkerCode`, `Domenia-Directory.Model.ps1:Resolve-DomeniaPasswordPolicy`, `Domenia-AdAudit.Model.ps1`, `Domenia-Core.ps1`

#### AUD-012 · Groupes imbriqués et cycles

`ameliore` · lecture réseau

Liste les groupes de l'objet avec profondeur, chemin d'arrivée, état de lecture, appartenance à un cycle et caractère privilégié, plus le groupe principal et les cycles détectés.

- Garde-fous : 2 000 groupes, 16 niveaux, 10 s ; 20 cycles max ; groupe à plus de 1 500 membres marqué partiel ; une lecture bornée ne prouve jamais une absence.
- Opérations : `GroupPathRead`
- Références D1 : `TabAdAuditGroups`, `BtnAdAuditGroups`, `DgAdAuditGroups`, `LblAdAuditGroups`, `Domenia-AdAudit.UI.ps1:Start-DomeniaAdAuditGroupRead`, `Domenia-AdAudit.Model.ps1:ConvertTo-DomeniaNestedGroupView`, `Domenia-AdAudit.Model.ps1:Find-DomeniaGroupCycles`, `Get-DomeniaGroupPathWorkerCode`

#### AUD-013 · Pourquoi membre de ce groupe ?

`fait` · lecture réseau

Pour un groupe choisi, montre le plus court chemin d'appartenance lu (ou l'appartenance par groupe principal) et permet de faire confirmer l'appartenance imbriquée par le contrôleur.

- Garde-fous : Réponse appliquée seulement au groupe demandé ; limites dites (autres domaines, groupe principal).
- Opérations : `GroupPathRead`
- Références D1 : `CmbAdAuditGroupTarget`, `BtnAdAuditGroupConfirm`, `LblAdAuditGroupPath`, `Domenia-AdAudit.UI.ps1:Update-DomeniaAdAuditGroupPath`, `Domenia-AdAudit.UI.ps1:Start-DomeniaAdAuditGroupConfirm`, `Domenia-AdAudit.Model.ps1:Get-DomeniaGroupMembershipExplanation`

#### AUD-014 · Estimation des droits d'un bénéficiaire

`fait` · locale (aucune lecture)

Pour l'entrée choisie, estime neuf droits (contrôle total, lire, modifier des attributs, réinitialiser le mot de passe, modifier les membres, créer, supprimer, modifier les autorisations, changer le propriétaire) avec l'entrée qui décide.

- Garde-fous : Ordre canonique (posées puis héritées, refus prioritaire) ; limites affichées (propriétaire, privilèges, groupes non lus) ; une estimation, jamais un droit effectif.
- Références D1 : `DgAdAuditAclEstimate`, `LblAdAuditAclEstimate`, `Domenia-AdAudit.UI.ps1:Update-DomeniaAdAuditEstimate`, `Domenia-AdAudit.Model.ps1:Get-DomeniaAccessEstimate`, `Domenia-AdAudit.Model.ps1:Get-DomeniaAdRightCategories`, `Domenia-AdAudit.Model.ps1:Test-DomeniaAceAppliesToObject`

#### AUD-015 · Inclure les groupes du bénéficiaire

`fait` · lecture réseau

Lit les groupes de sécurité transitifs (tokenGroups) du bénéficiaire choisi pour affiner l'estimation.

- Garde-fous : SID de domaine uniquement (pas d'identité intégrée) ; refus ou absence dits.
- Opérations : `DelegationRead`
- Références D1 : `BtnAdAuditAclToken`, `Domenia-AdAudit.UI.ps1:Start-DomeniaAdAuditTokenRead`

#### AUD-016 · Liens GPO de l'objet

`ameliore` · lecture réseau

Lit gPLink et gPOptions de chaque niveau d'OU jusqu'à la racine, puis noms et états des GPO, et affiche GPO, liée à, lien, forcée, héritage, attendue par les liens, état de la GPO.

- Garde-fous : 40 conteneurs, 200 GPO ; conteneur hors domaine refusé ; niveau refusé signalé ; liens de site non lus (dit).
- Opérations : `GpoLinksRead`
- Références D1 : `TabAdAuditGpo`, `BtnAdAuditGpoLinks`, `DgAdAuditGpo`, `DgAdAuditGpoFacts`, `LblAdAuditGpo`, `Domenia-AdAudit.UI.ps1:Start-DomeniaAdAuditGpoLinks`, `Domenia-AdAudit.Model.ps1:Get-DomeniaGpoContainerChain`, `Domenia-AdAudit.Model.ps1:ConvertTo-DomeniaGpoAuditView`, `Domenia-AdAudit.Model.ps1:Get-DomeniaGpoStatusText`, `Domenia-AdAudit.Worker.ps1:Get-DomeniaGpoLinksReadWorkerCode`, `Domenia-Workstation.Model.ps1:ConvertFrom-DomeniaGpLink`, `Domenia-Workstation.Model.ps1:Get-DomeniaRsopGpoGuid`, `Domenia-Workstation.Model.ps1:Get-DomeniaRsopGpoOutcome`, `Domenia-Workstation.Model.ps1:Resolve-DomeniaGpoView`

#### AUD-017 · Résultat GPO appliqué sur le poste (RSoP)

`fait` · lecture réseau

Lit par CIM le dernier résultat appliqué (RSOP_GPO, RSOP_GPLink) et le confronte aux liens attendus dans la colonne « Résultat sur le poste ».

- Garde-fous : Poste seulement ; pas de gpresult, d'appel de méthode ni de rafraîchissement ; réponse vide ou partielle jamais lue comme « rien appliqué » ; 30 s.
- Opérations : `GpoAppliedRead`
- Références D1 : `BtnAdAuditGpoApplied`, `Domenia-AdAudit.UI.ps1:Start-DomeniaAdAuditGpoApplied`, `Domenia-AdAudit.UI.ps1:Update-DomeniaAdAuditGpoView`, `Domenia-AdAudit.Worker.ps1:Get-DomeniaGpoAppliedReadWorkerCode`

#### AUD-018 · Identité du poste (AD, DNS, poste)

`fait` · lecture réseau

Confronte sAMAccountName/dNSHostName, la résolution DNS (et l'inverse) et l'identité renvoyée par le poste : cohérente, non vérifiée ou incohérente (DNS périmé, adresse réattribuée, poste renommé, homonyme d'un autre domaine).

- Garde-fous : Nom validé ; rien n'est attribué, fusionné ni renommé ; accès refusé distingué. Incohérente → aucune observation ni relation attribuée.
- Opérations : `MachineIdentityRead`
- Références D1 : `TabAdAuditMachine`, `BtnAdAuditMachineIdentity`, `DgAdAuditMachineIdentity`, `LblAdAuditMachineIdentity`, `Domenia-AdAudit.UI.ps1:Start-DomeniaAdAuditMachineIdentity`, `Domenia-AdAudit.Worker.ps1:Get-DomeniaMachineIdentityReadWorkerCode`, `Test-DomeniaMachineIdentityCoherence`, `Domenia-Workstation.Model.ps1:Test-DomeniaMachineIdentityCoherence`

#### AUD-019 · Synthèse des relations poste ↔ utilisateur

`fait` · locale (aucune lecture)

Résume les associations en mémoire (stockées et de la session) de l'utilisateur ou du poste ciblé.

- Garde-fous : Jamais de jointure entre GUID différents.
- Références D1 : `TabAdAuditHistory`, `LblAdAuditRelationOverview`, `Domenia-AdAudit.UI.ps1:Get-DomeniaAdAuditRelations`, `Domenia-AdAudit.UI.ps1:Update-DomeniaAdAuditRelationOverview`, `Get-DomeniaRelationOverview`

#### AUD-020 · Historique enregistré des associations

`ameliore` · lecture locale

Lit dans la base locale l'historique user_machine_history du sujet : date, utilisateur, poste, nature de la preuve (badge), source, vérifié dans AD, détails.

- Garde-fous : Lecture seule avec attente courte (occupée dit) ; 200 lignes (1 000 max) ; base réseau refusée ; aucun pourcentage de fiabilité ; présence ≠ session actuelle.
- Opérations : `RelationHistoryRead`
- Références D1 : `BtnAdAuditHistory`, `DgAdAuditHistory`, `LblAdAuditHistory`, `Domenia-AdAudit.UI.ps1:Start-DomeniaAdAuditHistoryRead`, `Domenia-AdAudit.Model.ps1:ConvertTo-DomeniaRelationHistoryRows`, `Domenia-AdAudit.Worker.ps1:Get-DomeniaRelationHistoryReadWorkerCode`

#### AUD-021 · Lecture des délégations (ACE)

`ameliore` · lecture réseau

Lit propriétaire et DACL (sans SACL) et liste chaque entrée : bénéficiaire nommé, autoriser/refuser, droits en français, cible (propriété, droit étendu, classe), objets visés, origine héritée ou posée, portée ; filtrable par texte et « posées sur l'objet seulement ».

- Garde-fous : Une ACE observée n'est pas un droit effectif vérifié (limite affichée). Lecture seule ; 1 000 entrées (10 à 5 000) ; noms de SID par lots de 40 (400 max), GUID par lots de 20 (120 max) ; refus de lecture dit sans déduire d'absence.
- Opérations : `DelegationRead`, `PermissionAnalysis`
- Références D1 : `Domenia-Directory.Model.ps1:ConvertTo-DomeniaAceView`, `Domenia-AdAudit.Model.ps1`, `TabAdAuditAcl`, `BtnAdAuditAcl`, `DgAdAuditAcl`, `ChkAdAuditAclExplicit`, `TxtAdAuditAclFilter`, `LblAdAuditAcl`, `Domenia-AdAudit.UI.ps1:Start-DomeniaAdAuditAclRead`, `Domenia-AdAudit.Model.ps1:ConvertTo-DomeniaDelegationView`, `Domenia-AdAudit.Model.ps1:Select-DomeniaDelegationRows`, `Domenia-AdAudit.Model.ps1:Get-DomeniaWellKnownSidName`, `Domenia-AdAudit.Model.ps1:Get-DomeniaAdGuidLabel`, `Domenia-AdAudit.Worker.ps1:Get-DomeniaDelegationReadWorkerCode`

### Vue du domaine

#### AUD-022 · Totaux de la copie locale du domaine

`fait` · lecture locale

Au geste « Analyser le domaine », affiche les totaux par type de la copie locale avec la date de sa dernière synchronisation, jamais un dénombrement de l'annuaire.

- Garde-fous : Partie postes limitée à un niveau sous la racine ; ReplaceKey domain:totals, 60 s ; base absente ou occupée dite en clair. Aucun dénombrement de l'annuaire ; copie vide dite comme telle.
- Opérations : `LocalIndexRead`
- Références D1 : `Domenia-Dashboard.UI.ps1:Start-DomeniaDomainLocalTotals`, `Domenia-Dashboard.UI.ps1:Complete-DomeniaDomainLocalTotals`, `Domenia-Dashboard.UI.ps1:Fail-DomeniaDomainLocalTotals`, `Domenia-Dashboard.UI.ps1:Test-DomeniaDomainLocalTotalsCurrent`, `Domenia-Directory.Model.ps1:Get-DomeniaLocalTotalsSummary`, `LblDomainLocalTotals`, `Domenia-Dashboard.UI.ps1`

#### AUD-023 · Vue du domaine

`ameliore` · lecture réseau

Analyse en lecture seule, section par section : annuaire (contextes, DC, niveaux fonctionnels, heure, USN), contrôleurs, rôles FSMO et RID restants, stratégie de mot de passe, stratégies affinées, comptes à surveiller (désactivés, sans expiration, sans pré-auth, SPN, délégation non contrainte, krbtgt), groupes privilégiés, corbeille AD, approbations, sites et sous-réseaux, GPO ; totaux pris dans la copie locale datée ; copie du rapport.

- Garde-fous : Un refus sur une section n'empêche pas les autres ; l'annuaire n'est jamais compté en entier.
- Opérations : `DomainOverview`
- Références D1 : `Domenia-Core.ps1:Start-DomeniaDomainOverview`, `Domenia-Core.ps1:Get-DomeniaDomainWorkerCode`, `Domenia-Core.ps1:Complete-DomeniaDomainUi`, `Domenia-Core.ps1:Fail-DomeniaDomainUi`, `Domenia-Core.ps1:Copy-DomeniaDomainReport`, `Domenia-Main.xaml:TabDomain`, `Domenia-Main.xaml:BtnLoadDomain`, `Domenia-Main.xaml:DgDomain`, `XAML:BtnCopyDomain`, `XAML:LblDomainStatus`

<a id="sch"></a>

## Schéma de l'annuaire (SCH)

8 fonctions : 2 faites, 6 améliorées.

### Catalogue

#### SCH-001 · Catalogue des classes et attributs filtrable

`ameliore` · locale (aucune lecture)

Liste Classes ou Attributs filtrée sur nom ou description (pause 250 ms), 500 lignes affichées, total exact.

- Garde-fous : Filtre local, aucune lecture réseau ; entrées obsolètes marquées.
- Références D1 : `Domenia-DirectorySchema.Model.ps1:Find-DomeniaAdSchemaEntries`, `Domenia-DirectorySchema.Model.ps1:ConvertTo-DomeniaAdSchemaCatalog`, `Domenia-DirectorySchema.UI.ps1:Update-DomeniaAdSchemaList`, `Domenia-DirectorySchema.UI.ps1:Request-DomeniaAdSchemaListUpdate`, `XAML:CmbAdSchemaKind`, `XAML:TxtAdSchemaFilter`, `XAML:DgAdSchemaEntries`

#### SCH-002 · Détail d'un attribut

`ameliore` · locale (aucune lecture)

Syntaxe en clair, une ou plusieurs valeurs, index (sous-chaîne), catalogue global, confidentiel, calculé, non répliqué, lié, obsolète, description.

- Références D1 : `Domenia-DirectorySchema.UI.ps1:Format-DomeniaAdSchemaAttributeDetail`, `Domenia-DirectorySchema.Model.ps1:Get-DomeniaAdSyntaxLabel`, `Domenia-DirectorySchema.Model.ps1:Get-DomeniaAdSyntaxKind`, `Domenia-DirectorySchema.Model.ps1:ConvertFrom-DomeniaAdSearchFlags`, `Domenia-DirectorySchema.Model.ps1:ConvertFrom-DomeniaAdSystemFlags`, `Domenia-DirectorySchema.Model.ps1:Get-DomeniaAdAttributeIndexText`, `Domenia-DirectorySchema.Model.ps1:Get-DomeniaAdSchemaAttribute`, `XAML:LblAdSchemaDetail`

#### SCH-003 · Attributs possibles d'une classe

`ameliore` · locale (aucune lecture)

mustContain et mayContain de la classe, de ses superclasses jusqu'à top et des auxiliaires, obligatoires d'abord, avec chaîne d'héritage et absents du schéma lu ; conseil objectClass vs objectCategory.

- Garde-fous : Parcours borné à 256 classes (boucle de schéma).
- Références D1 : `Domenia-DirectorySchema.Model.ps1:Get-DomeniaAdClassAttributes`, `Domenia-DirectorySchema.Model.ps1:ConvertTo-DomeniaAdAttributeRow`, `Domenia-DirectorySchema.Model.ps1:Get-DomeniaAdClassCategoryLabel`, `Domenia-DirectorySchema.UI.ps1:Show-DomeniaAdSchemaSelection`, `Domenia-DirectorySchema.UI.ps1:Show-DomeniaAdSchemaClassAttribute`, `XAML:DgAdSchemaClassAttributes`

### Filtres LDAP

#### SCH-004 · Exemple de critère et conseils par attribut

`ameliore` · locale (aucune lecture)

Exemple de clause selon la syntaxe (booléen, DN, entier, FILETIME, date, SID, octets) et notes : indexé ou non, joker en tête, multivalué, confidentiel, non répliqué, lié, obsolète, calculé non filtrable.

- Références D1 : `Domenia-DirectorySchema.Model.ps1:Get-DomeniaAdAttributeQueryHint`

#### SCH-005 · Ajouter l'attribut choisi au filtre

`ameliore` · locale (aucune lecture)

Insère l'exemple de critère dans le filtre en cours (dans le ET existant ou en créant un ET), à compléter par l'opérateur, puis l'analyse.

- Garde-fous : Brouillon seulement, rien n'est exécuté ; désactivé pour un attribut calculé ou obsolète.
- Références D1 : `Domenia-DirectorySchema.UI.ps1:Add-DomeniaAdSchemaAttributeToFilter`, `Domenia-DirectorySchema.UI.ps1:Get-DomeniaAdSchemaSelectedAttribute`, `XAML:BtnAdSchemaInsert`

#### SCH-006 · Analyse locale du coût d'un filtre LDAP

`ameliore` · locale (aucune lecture)

Analyse un filtre RFC 4515 (32 768 caractères, 64 niveaux, 2 000 éléments) : ciblé, large ou inconnu selon les index du schéma lu ; joker en tête, négation, règle extensible, attribut calculé ou confidentiel.

- Garde-fous : Rien n'est envoyé au contrôleur ; ne lève jamais d'exception (erreur de syntaxe positionnée).
- Références D1 : `Domenia-DirectorySchema.Model.ps1:Get-DomeniaLdapFilterAnalysis`, `Domenia-DirectorySchema.Model.ps1:ConvertFrom-DomeniaLdapFilter`, `Domenia-DirectorySchema.Model.ps1:Read-DomeniaLdapFilterNode`, `Domenia-DirectorySchema.Model.ps1:ConvertFrom-DomeniaLdapFilterItem`, `Domenia-DirectorySchema.Model.ps1:Get-DomeniaLdapNodeIndexUse`, `Domenia-DirectorySchema.Model.ps1:Get-DomeniaLdapFilterLeaves`, `Domenia-DirectorySchema.UI.ps1:Invoke-DomeniaAdSchemaFilterAnalysis`, `XAML:TxtAdSchemaLdapFilter`, `XAML:BtnAdSchemaAnalyze`, `XAML:LblAdSchemaAnalysis`

### Lecture

#### SCH-007 · Lecture du schéma AD sur geste explicite

`fait` · lecture réseau

Lit une fois les définitions attributeSchema et classSchema du contrôleur de session (8 000 attributs, 3 000 classes, 90 s) et les garde en mémoire avec serveur et date.

- Garde-fous : Indisponible en démonstration ; contexte de schéma vérifié ; aucune valeur d'objet ; jamais d'écriture ; lecture tronquée signalée.
- Opérations : `AdSchemaRead`
- Références D1 : `Domenia-DirectorySchema.UI.ps1:Start-DomeniaAdSchemaRead`, `Domenia-DirectorySchema.UI.ps1:Complete-DomeniaAdSchemaRead`, `Domenia-DirectorySchema.UI.ps1:Fail-DomeniaAdSchemaRead`, `Domenia-DirectorySchema.Worker.ps1:Get-DomeniaAdSchemaWorkerCode`, `Domenia-DirectorySchema.UI.ps1:Initialize-DomeniaDirectorySchemaUi`, `XAML:BtnAdSchemaRead`, `XAML:DomeniaAdSchemaView`

#### SCH-008 · Statut du schéma lu

`fait` · locale (aucune lecture)

« Schéma lu le … sur DC : N classes, M attributs », lecture incomplète signalée ; schéma d'une autre session ou domaine jamais utilisé.

- Références D1 : `Domenia-DirectorySchema.UI.ps1:Update-DomeniaAdSchemaStatus`, `Domenia-DirectorySchema.UI.ps1:Get-DomeniaAdSchemaCatalogForAnalysis`, `XAML:LblAdSchemaStatus`

<a id="syn"></a>

## Synchronisation et base autonome (SYN)

30 fonctions : 17 faites, 13 améliorées.

### Base autonome · données

#### SYN-001 · Recherche dans l'index local

`ameliore` · lecture locale

Saisie dans TxtIndexSearch avec un délai de 250 ms : aucun accès SQLite à la frappe elle-même. La requête part dans le worker LocalIndexRead (correspondance exacte, préfixe ou contenu, dans le périmètre de l'OU). Elle cherche dans les noms, identifiants, descriptions et services, et une demande plus récente remplace l'ancienne.

- Garde-fous : Terme lié en paramètre, jamais inséré dans le SQL ; un ancien rappel ne remplace jamais la liste.
- Opérations : `LocalIndexRead`
- Références D1 : `TxtIndexSearch`, `LblIndexStatus`, `DgIndex`, `Domenia-Engine.UI.ps1:Request-DomeniaIndexSearch`, `Domenia-Engine.UI.ps1:Start-DomeniaIndexSearch`, `Domenia-Engine.UI.ps1:Complete-DomeniaIndexSearchUi`, `Domenia-Engine.UI.ps1:Fail-DomeniaIndexSearchUi`, `Domenia-Core.ps1:Search-DomeniaIndexUi`, `Domenia-Core.ps1:Search-DomeniaDatabaseRows`, `Domenia-Core.ps1:Open-DomeniaIndexSelection`, `Domenia-Core.ps1:Get-DomeniaIndexAssociationText`, `Domenia-Main.xaml:TxtIndexSearch`, `Domenia-Main.xaml:DgIndex`

#### SYN-002 · Pagination de l'index local

`ameliore` · lecture locale

Pages de 200 lignes (500 au plus) avec Page précédente et Page suivante. Le total et la page viennent du même instantané SQLite : la pagination borne l'affichage, pas la population.

- Garde-fous : Si le terme, le périmètre ou le tri changent, la recherche repart de la première page.
- Opérations : `LocalIndexRead`
- Références D1 : `BtnIndexPrevious`, `BtnIndexNext`, `Domenia-Engine.UI.ps1:Move-DomeniaIndexSearchPage`, `Domenia-Main.xaml:BtnIndexPrevious`, `Domenia-Main.xaml:BtnIndexNext`

#### SYN-003 · Tri de l'index sur toute la population

`fait` · lecture locale

Le clic sur un en-tête trie toute la population filtrée avant LIMIT et OFFSET, avec une identité stable pour départager, et les dates françaises ou ISO sont comparées comme des dates. « Tri par pertinence » revient à l'ordre de correspondance.

- Garde-fous : Seules des expressions SQL figées peuvent être choisies par un en-tête.
- Opérations : `LocalIndexRead`
- Références D1 : `DgIndex`, `BtnIndexResetSort`, `Domenia-Engine.UI.ps1:Get-DomeniaIndexSearchSort`, `Domenia-Engine.UI.ps1:Set-DomeniaIndexSearchSort`, `Domenia-Main.xaml:BtnIndexResetSort`, `Domenia-Main.xaml:DgIndex`

#### SYN-004 · Base occupée pendant une recherche locale

`fait` · lecture locale

Une base verrouillée n'est pas un résultat vide : un nouvel essai court est fait (« Base locale occupée : nouvel essai dans un instant »), puis un message demande de réessayer.

- Garde-fous : Un seul essai automatique, en lecture seule.
- Opérations : `LocalIndexRead`
- Références D1 : `Domenia-Engine.UI.ps1:Complete-DomeniaIndexSearchUi`, `LblIndexStatus`

#### SYN-005 · Ouvrir ou exporter depuis l'index local

`ameliore` · lecture locale

Un double-clic ou « Ouvrir l'objet » ouvre la fiche de l'objet dans l'annuaire, et « Exporter CSV » exporte les résultats. Le branchement de ces boutons est dans le cœur (hors périmètre de cette liste).

- Garde-fous : L'ouverture relit l'annuaire ; l'export écrit dans le dossier Exports.
- Opérations : `OpenAdObject`, `QueryExport`
- Références D1 : `BtnIndexOpen`, `BtnIndexExport`, `BtnIndexBrowse`, `DgIndex`, `Domenia-Main.xaml:BtnIndexBrowse`, `Domenia-Main.xaml:BtnIndexOpen`, `Domenia-Main.xaml:BtnIndexExport`, `Domenia-Main.xaml:DgIndex`

### Disparitions

#### SYN-006 · Liste des objets disparus du périmètre

`ameliore` · lecture locale

Objets qu'une lecture complète n'a pas revus : état, nom, type, dernier emplacement connu (→ nouveau), non revu le, vérifié le, détail ; totaux par état, les plus récents affichés.

- Garde-fous : Ouvrir l'onglet lit seulement la base locale ; réponse confirmée par SQLite ; base occupée signalée.
- Opérations : `LocalIndexRead`
- Références D1 : `Domenia-DirectorySync.UI.ps1:Request-DomeniaDirectorySyncRead`, `Domenia-DirectorySync.UI.ps1:Complete-DomeniaDirectorySyncRead`, `Domenia-DirectorySync.Model.ps1:ConvertTo-DomeniaAbsenceRow`, `Domenia-DirectorySync.Model.ps1:Get-DomeniaAbsenceSummary`, `Domenia-DirectorySync.Model.ps1:Get-DomeniaAbsenceStatusLabel`, `XAML:DgSyncAbsences`, `XAML:BtnSyncAbsencesRefresh`, `XAML:LblSyncAbsences`

#### SYN-007 · Vérifier les disparitions

`fait` · lecture réseau

Relit jusqu'à 200 objets non revus par GUID dans le domaine (lots de 24, 60 s) puis parmi les objets supprimés visibles : de nouveau visible, déplacé, suppression constatée (date, dernier parent, recyclé), introuvable, invisible pour ce compte, vérification impossible.

- Garde-fous : Confirmation ; seule une entrée isDeleted lue par GUID prouve une suppression ; sonde de visibilité de Deleted Objects ; objet retrouvé reprend son emplacement sous le même GUID.
- Opérations : `DirectoryAbsenceCheck`, `LocalStore`
- Références D1 : `Domenia-DirectorySync.UI.ps1:Request-DomeniaAbsenceCheck`, `Domenia-DirectorySync.UI.ps1:Start-DomeniaAbsenceCheck`, `Domenia-DirectorySync.UI.ps1:Complete-DomeniaAbsenceCheck`, `Domenia-DirectorySync.Model.ps1:Resolve-DomeniaDirectoryAbsence`, `Domenia-DirectorySync.Model.ps1:Select-DomeniaAbsencesToCheck`, `Domenia-DirectorySync.Model.ps1:New-DomeniaAbsenceStoreRow`, `Domenia-DirectorySync.Worker.ps1:Get-DomeniaAbsenceCheckWorkerCode`, `XAML:BtnSyncAbsencesCheck`

#### SYN-008 · Interprétation des déplacements et renommages

`fait` · locale (aucune lecture)

Qualifie un changement de DN : inchangé, renommé au même endroit, déplacé dans le périmètre, sorti, entré, déplacé hors périmètre ; emplacement lisible « Lyon › Postes » ; aussi utilisé pour l'état des lignes de la liste.

- Garde-fous : Appartenance au périmètre par frontière de RDN ; un déplacement ne crée jamais un second objet.
- Références D1 : `Domenia-DirectorySync.Model.ps1:Get-DomeniaDirectoryMove`, `Domenia-DirectorySync.Model.ps1:Get-DomeniaMoveStateText`, `Domenia-DirectorySync.Model.ps1:Test-DomeniaDnInScope`, `Domenia-DirectorySync.Model.ps1:Get-DomeniaDnLocation`, `Domenia-DirectorySync.Model.ps1:Get-DomeniaDnBreadcrumb`, `Domenia-DirectorySync.Model.ps1:Get-DomeniaDnPath`

### Mise à jour de la base

#### SYN-009 · Oublier les relevés

`ameliore` · écriture

« Oublier les relevés » efface l'état de balayage du parc de cette base (dernière sonde, statut, tentatives), après la sauvegarde vérifiée prise avant le geste. Associations, observations et historique ne sont pas touchés.

- Garde-fous : Confirmation dans la page ; sauvegarde vérifiée d'abord ; file pleine signalée (effacé en mémoire seulement). Sauvegarde vérifiée préalable.
- Opérations : `StorageBackup`, `LocalStore`
- Références D1 : `Domenia-Park.UI.ps1:Request-DomeniaParkReset`, `Domenia-Park.UI.ps1:Invoke-DomeniaParkReset`, `Domenia-Park.UI.ps1:Clear-DomeniaParkRecords`, `BtnParkReset`, `Domenia-Storage.UI.ps1:Queue-DomeniaMetadata (ParkReset)`, `Domenia-Storage.Worker.ps1:Get-DomeniaStorageWorkerCode`

#### SYN-010 · Reçu de stockage puis relecture des contrôles

`ameliore` · lecture locale

Après un lot (vérification, relevé, mise à jour d'index), la liste est relue depuis la base, jamais corrigée en mémoire ; échec explicité et rien relancé automatiquement.

- Garde-fous : Session et base vérifiées.
- Opérations : `LocalStore`, `LocalIndexRead`
- Références D1 : `Domenia-DirectorySync.UI.ps1:Complete-DomeniaDirectorySyncStorage`, `Queue-DomeniaMetadata`, `Request-DomeniaIndexMetadata`

#### SYN-011 · Tuiles de la base locale

`ameliore` · lecture locale

Quatre tuiles : Comptes (comptes utilisateurs), Postes (actifs et désactivés), Associations (liens utilisateur-poste) et Dernière mise à jour du périmètre choisi (« il y a 2 h », date, ou « Jamais »). Chiffres au format français ; « — » et « base illisible » si la lecture échoue.

- Garde-fous : Une base illisible n'affiche jamais de zéros. Chiffres lus hors Dispatcher ; « non lu » distinct de « vide ».
- Opérations : `LocalIndexRead`
- Références D1 : `LblIndexTileAccounts`, `LblIndexTileAccountsDetail`, `LblIndexTileComputers`, `LblIndexTileComputersDetail`, `LblIndexTileLinks`, `LblIndexTileLinksDetail`, `LblIndexTileUpdated`, `LblIndexTileUpdatedDetail`, `Domenia-Storage.UI.ps1:Set-DomeniaIndexTiles`, `Domenia-Cache.Model.ps1:Get-DomeniaIndexTiles`, `Domenia-Core.ps1:Update-DomeniaIndexStats`, `Domenia-Core.ps1:Get-DomeniaDatabaseObjectCount`, `Domenia-Core.ps1:Set-DomeniaIndexProgress`, `Domenia-Core.ps1:New-DomeniaIndexProgressChannel`, `XAML:PbIndexProgress`, `XAML:LblIndexProgress`

#### SYN-012 · Métadonnées de l'index et avis de démarrage

`ameliore` · lecture locale

Le point de reprise de l'annuaire, la couverture et les échecs par OU, les compteurs de la page et les identités du recensement encore absentes sont lus par worker. Ils sont relus seulement si la dernière lecture a échoué ou n'a jamais répondu, y compris au retour sur Outils (Ctrl+I). Au démarrage, ils servent aux avis sur l'âge de la base et à la première construction.

- Garde-fous : Chiffres à -1 (inconnus) jusqu'à la réponse ; une lecture de l'ancienne base est écartée par génération. Toute opération longue passe par estimation et confirmation.
- Opérations : `LocalIndexRead`
- Références D1 : `Domenia-Engine.UI.ps1:Request-DomeniaIndexMetadata`, `Domenia-Engine.UI.ps1:Request-DomeniaIndexMetadataIfNeeded`, `Domenia-Engine.UI.ps1:Complete-DomeniaIndexMetadataUi`, `Domenia-Engine.UI.ps1:Fail-DomeniaIndexMetadataUi`, `Domenia-Engine.UI.ps1:Reset-DomeniaIndexMetadataState`, `Domenia-Cache.Model.ps1:ConvertTo-DomeniaIndexMetadataState`, `LblIndexFreshness`, `LblIndexStats`, `Domenia-Core.ps1:Request-DomeniaIndexAutoRefresh`, `Domenia-Core.ps1:Request-DomeniaIndexFirstBuild`, `Domenia-Core.ps1:Flush-DomeniaIndex`, `Domenia-Core.ps1:Sync-DomeniaIndexEntry`

#### SYN-013 · Lot d'index transféré sur disque et réconcilié

`ameliore` · écriture

Une lecture d'OU ou du domaine arrive sous forme de fichier .jsonl haché, relu et vérifié avant l'enregistrement, puis réconcilié en une transaction. Les objets absents d'une lecture complète sortent de la copie locale comme non revus, et les lignes modifiées plus récemment ailleurs ne sont jamais écrasées.

- Garde-fous : Fichier modifié depuis la lecture refusé ; nombre de lignes et d'identités vérifié, sinon transaction annulée. Recensement vide refusé ; une reconstruction complète exige une lecture complète du domaine.
- Opérations : `IndexBuild`, `LocalStore`
- Références D1 : `Domenia-Storage.UI.ps1:Queue-DomeniaMetadata (IndexBulk)`, `Domenia-Storage.Worker.ps1:Get-DomeniaStorageWorkerCode (IndexBulk)`

#### SYN-014 · Mise à jour de la base autonome par OU

`ameliore` · lecture réseau

« Mettre à jour l'OU choisie » relit l'OU et ses sous-OU, les autres branches sont conservées ; une portée vide ou la racine sont refusées, la date de couverture de l'OU est propre et ne déplace pas le repère du domaine.

- Garde-fous : Jamais d'élargissement silencieux au domaine.
- Opérations : `IndexBuild`
- Références D1 : `Domenia-Core.ps1:Start-DomeniaSelectedIndexScopeBuild`, `Domenia-Core.ps1:Start-DomeniaIndexScopeBuild`, `Domenia-Core.ps1:Complete-DomeniaIndexScopeUi`, `Domenia-Core.ps1:Get-DomeniaIndexScope`, `Domenia-Main.xaml:BtnIndexScopePick`, `Domenia-Main.xaml:BtnIndexScopeUpdate`, `XAML:IndexWorkspaceTabs`, `XAML:LblIndexScopeChoice`

#### SYN-015 · Mise à jour incrémentielle du domaine

`fait` · lecture réseau

Le point de reprise (contrôleur, invocationID, USN, périmètre) n'avance qu'avec les données qu'il décrit, jamais après une réponse partielle ou sans invocationID. Il n'est réutilisé que sur la même instance, avec un USN réellement validé et une base qui contient encore ce qu'il comptait. Une absence dans une réponse ne devient jamais une suppression AD.

- Garde-fous : Estimation confirmée en page ; aucun USN extrapolé ; reçu de stockage (hash et nombre) vérifié avant commit. En cas de doute, lecture complète ; un USN n'est jamais reporté sur un autre contrôleur.
- Opérations : `IndexBuild`, `IndexOuList`, `IndexRefresh`, `ScopeReconcile`
- Références D1 : `Domenia-Core.ps1:Start-DomeniaIndexRefresh`, `Domenia-Core.ps1:Complete-DomeniaIndexRefreshUi`, `Domenia-Core.ps1:Start-DomeniaIndexBuild`, `Domenia-Core.ps1:Complete-DomeniaIndexBuildUi`, `Domenia-Core.ps1:Start-DomeniaIndexWalkStep`, `Domenia-Core.ps1:Complete-DomeniaIndexWalkUi`, `Domenia-Core.ps1:Get-DomeniaIndexOuListWorkerCode`, `Domenia-Core.ps1:Get-DomeniaIndexWorkerCode`, `Domenia-Core.ps1:Merge-DomeniaIndexRows`, `Domenia-Core.ps1:Update-DomeniaIndexDatabaseRows`, `Domenia-Cache.Model.ps1:Resolve-DomeniaIncrementalSync`, `Domenia-Cache.Model.ps1:Test-DomeniaSyncCheckpoint`, `Domenia-Core.ps1`, `Domenia-Reconcile.UI.ps1`

#### SYN-016 · Budgets et coupures d'une passe d'index

`ameliore` · locale (aucune lecture)

Index.MaxObjects (0 = sans quota) et Index.BudgetMs (20 min, partagé entre plans) ; une passe coupée par volume, temps ou ServerTimeLimit du DC ne remplace jamais une base plus complète, ne déplace pas le repère et l'Accueil avertit en nommant la limite.

- Garde-fous : Échec d'une classe = passe incomplète, jamais un annuaire vide ; un domaine vide après repère exige une reconstruction explicite.
- Opérations : `IndexBuild`
- Références D1 : `Domenia-Core.ps1:Get-DomeniaIndexLimits`, `Domenia-Core.ps1:Get-DomeniaIndexCut`, `Domenia-Core.ps1:Set-DomeniaIndexPartial`, `Domenia-Core.ps1:Get-DomeniaIndexPartialText`

#### SYN-017 · Garde d'écriture de la base avant passe

`fait` · locale (aucune lecture)

Une nouvelle passe annuaire attend le repère validé de la précédente et est refusée pendant une maintenance, un writer suspendu ou un disque presque plein.

- Garde-fous : Branches déjà sauvegardées conservées.
- Références D1 : `Domenia-Core.ps1:Test-DomeniaIndexWriteReady`

#### SYN-018 · Expiration LAPS lue avec les ordinateurs

`fait` · lecture réseau

La date d'expiration LAPS (hérité et Windows LAPS) est indexée avec les postes, jamais le mot de passe ; une lecture du schéma distingue « absent du domaine » de « non visible avec ce compte ».

- Garde-fous : Aucun secret indexé.
- Opérations : `IndexBuild`
- Références D1 : `Domenia-Core.ps1:Get-DomeniaIndexWorkerCode`, `Domenia-Core.ps1:Complete-DomeniaIndexBuildUi`

### Recensement

#### SYN-019 · Conseil de recensement complet du périmètre

`fait` · lecture locale

Dit si l'OU ou le domaine choisi a besoin d'une lecture complète : récent, dû (seuil Index.FullRebuildDays, 7 j), partiel, absent, horloge douteuse, ou identités manquantes du dernier recensement du domaine.

- Garde-fous : Ne lance jamais rien ; un point daté dans le futur fait vérifier l'horloge.
- Références D1 : `Domenia-DirectorySync.Model.ps1:Get-DomeniaCensusAdvice`, `Domenia-DirectorySync.UI.ps1:Get-DomeniaCensusAdviceForScope`, `Domenia-DirectorySync.UI.ps1:Update-DomeniaCensusAdviceUi`, `Domenia-DirectorySync.UI.ps1:Get-DomeniaCensusMaxAgeDays`, `XAML:LblSyncCensus`, `Réglage:Index.FullRebuildDays`, `XAML:DomeniaDirectorySyncView`

#### SYN-020 · Relire l'OU choisie en entier

`fait` · lecture réseau

Lecture complète des utilisateurs et postes de l'OU et de ses sous-OU, comme « Mettre à jour l'OU choisie » ; seule une lecture complète repère disparus et déplacés.

- Garde-fous : Demande une OU si aucune n'est choisie ; aucune modification de l'annuaire.
- Opérations : `IndexBuild`
- Références D1 : `XAML:BtnSyncCensusRun`, `Start-DomeniaSelectedIndexScopeBuild`

#### SYN-021 · Lire les objets manquants du recensement

`fait` · lecture réseau

Les identités vues par le dernier recensement du domaine mais absentes de la base sont relues par GUID (200 au plus) ; trouvées : ajoutées ; absentes : retirées de la liste sans conclusion ; non lues : restent.

- Garde-fous : Confirmation en page ; lecture seule de l'AD ; objets supprimés non lus ; indisponible en démo ; une seule lecture à la fois.
- Opérations : `DirectoryAbsenceCheck`, `LocalStore`
- Références D1 : `Domenia-DirectorySync.UI.ps1:Request-DomeniaCensusGapRead`, `Domenia-DirectorySync.UI.ps1:Start-DomeniaCensusGapRead`, `Domenia-DirectorySync.UI.ps1:Complete-DomeniaCensusGapRead`, `Domenia-DirectorySync.Model.ps1:New-DomeniaCensusGapStoreRow`, `Domenia-DirectorySync.Model.ps1:Get-DomeniaCensusGapSummary`, `XAML:BtnSyncGapRead`, `XAML:LblSyncGaps`

### Relevés datés de l'annuaire

#### SYN-022 · Enregistrer un relevé daté du périmètre

`fait` · écriture

Copie datée de la base locale pour le périmètre (identité, emplacement, quelques attributs) avec preuve de couverture ; nom facultatif ; 50 relevés par domaine, 300 000 objets.

- Garde-fous : Aucune lecture AD ; périmètre hors domaine refusé ; prise effective confirmée par relecture de la base.
- Opérations : `LocalStore`
- Références D1 : `Domenia-DirectorySync.UI.ps1:Start-DomeniaSnapshotCapture`, `Domenia-DirectorySync.Model.ps1:New-DomeniaSnapshotRequest`, `Domenia-DirectorySync.Model.ps1:ConvertTo-DomeniaSnapshotCoverage`, `XAML:BtnSnapshotCapture`, `XAML:TxtSnapshotLabel`

#### SYN-023 · Liste des relevés enregistrés

`fait` · lecture locale

Nom, date, nombre d'objets, périmètre, couverture ; empreinte SHA-256 des lignes conservée.

- Opérations : `LocalIndexRead`
- Références D1 : `Domenia-DirectorySync.Model.ps1:ConvertTo-DomeniaSnapshotRow`, `XAML:DgSnapshots`, `XAML:LblSnapshots`

#### SYN-024 · Supprimer un relevé

`fait` · écriture

Supprime le relevé choisi de la base locale après confirmation.

- Garde-fous : Confirmation niveau Danger ; identifiant validé ; annuaire non concerné.
- Opérations : `LocalStore`
- Références D1 : `Domenia-DirectorySync.UI.ps1:Request-DomeniaSnapshotDelete`, `Domenia-DirectorySync.UI.ps1:Remove-DomeniaSnapshot`, `XAML:BtnSnapshotDelete`

#### SYN-025 · Comparer deux relevés

`ameliore` · lecture locale

Ajouts, disparitions, déplacements, renommages et valeurs modifiées (type, nom, identifiant, UPN/DNS, nom affiché, description, service/système, état) ; totaux exacts, 500 lignes par catégorie.

- Garde-fous : Même domaine et même périmètre exigés ; couverture incomplète ou ordre inversé signalés ; disparition non prouvée.
- Opérations : `LocalIndexRead`
- Références D1 : `Domenia-DirectorySync.UI.ps1:Start-DomeniaSnapshotCompare`, `Domenia-DirectorySync.UI.ps1:Complete-DomeniaSnapshotCompare`, `Domenia-DirectorySync.UI.ps1:Update-DomeniaSnapshotChoices`, `Domenia-DirectorySync.Model.ps1:Test-DomeniaSnapshotComparable`, `Domenia-DirectorySync.Model.ps1:ConvertTo-DomeniaSnapshotReport`, `Domenia-DirectorySync.Model.ps1:Get-DomeniaSnapshotFields`, `XAML:CmbSnapshotBefore`, `XAML:CmbSnapshotAfter`, `XAML:BtnSnapshotCompare`, `XAML:DgSnapshotDiff`, `XAML:LblSnapshotCompare`

#### SYN-026 · Notice des relevés

`fait` · locale (aucune lecture)

Rappelle qu'un relevé ne contient ni mot de passe, ni droit, ni appartenance, ne restaure pas l'annuaire et qu'une disparition n'est pas une preuve de suppression.

- Références D1 : `Domenia-DirectorySync.Model.ps1:Get-DomeniaSnapshotNotice`, `XAML:LblSnapshotNotice`

#### SYN-027 · Recensement, objets non revus et relevés d'annuaire

`fait` · écriture

Stocke les objets qu'une lecture complète n'a pas rendus (enregistrés comme non revus, jamais comme supprimés), les écarts du recensement relus par GUID et les relevés datés d'un périmètre (capture SQL en une instruction, empreinte SHA-256, état de couverture). Les worker DirectorySync et SnapshotCompare listent ces éléments et comparent deux relevés, totaux exacts et lignes bornées.

- Garde-fous : Une suppression n'est retenue qu'avec sa preuve. Un relevé ne copie ni mot de passe, ni droit, ni appartenance, et rien ne peut être réécrit depuis lui. Domaine et périmètre sont vérifiés ; un lot rejoué ne copie pas deux fois.
- Opérations : `LocalStore`, `LocalIndexRead`, `DirectoryAbsenceCheck`
- Références D1 : `Domenia-Storage.UI.ps1:Queue-DomeniaMetadata (DirectoryAbsence, DirectorySnapshot)`, `Domenia-Storage.Worker.ps1:Get-DomeniaStorageWorkerCode`, `Domenia-Engine.Worker.ps1:Get-DomeniaLocalIndexReadWorkerCode (DirectorySync, SnapshotCompare)`

### Relevés du parc

#### SYN-028 · Couverture du relevé du parc

`ameliore` · lecture locale

Le texte de LblParkStatus donne la couverture du relevé stocké sans comptage synchrone. Le nombre de postes actifs vient de l'index en mémoire, des chiffres de la base ou du relevé stocké, et un texte d'attente est remplacé à l'arrivée des chiffres.

- Garde-fous : Un relevé en cours ou une erreur gardent leur propre texte.
- Opérations : `LocalIndexRead`
- Références D1 : `LblParkStatus`, `Domenia-Engine.UI.ps1:Get-DomeniaParkStatusTextSafe`, `Domenia-Engine.UI.ps1:Get-DomeniaParkMachineCount`, `Domenia-Engine.UI.ps1:Get-DomeniaParkCoverageWaitingText`, `Domenia-Engine.UI.ps1:Update-DomeniaParkCoverageAfterCount`, `Domenia-Cache.Model.ps1:Get-DomeniaParkCoverageFigures`

#### SYN-029 · Relevé partagé du parc entre consoles

`fait` · écriture

Un fichier de relevé partagé, éventuellement en UNC, est lu, fusionné (la ligne la plus récente gagne par poste) puis réécrit dans le worker ParkSharedSync, sous un fichier .lock avec 12 essais. Une demande pendant une synchronisation en cours est faite à la suite.

- Garde-fous : Rien sans chemin configuré. Si le partage est inaccessible, Domenia travaille en local (journal Parc) ; verrou retiré dans le finally. Verrou non obtenu : travail en local et nouvel essai.
- Opérations : `ParkSharedSync`
- Références D1 : `Domenia-Engine.UI.ps1:Start-DomeniaParkSharedSync`, `Domenia-Engine.UI.ps1:Complete-DomeniaParkSharedSyncUi`, `Domenia-Engine.UI.ps1:Fail-DomeniaParkSharedSyncUi`, `Domenia-Engine.Worker.ps1:Get-DomeniaParkSharedSyncWorkerCode`, `Domenia-Core.ps1:Get-DomeniaParkSharedPath`, `Domenia-Core.ps1:Merge-DomeniaParkState`, `Domenia-Core.ps1:Sync-DomeniaParkShared`

#### SYN-030 · Rechargement de l'état du parc stocké

`fait` · lecture locale

L'état du relevé du parc est relu depuis la base par worker. Un résultat de poste arrivé avant la fin de cette lecture est appliqué ensuite, pour que ses compteurs de tentatives partent des compteurs stockés.

- Garde-fous : L'état en mémoire reste utilisable pendant la lecture.
- Opérations : `LocalIndexRead`
- Références D1 : `Domenia-Engine.UI.ps1:Request-DomeniaParkStateReload`, `Domenia-Engine.UI.ps1:Add-DomeniaParkDeferredResult`, `Domenia-Engine.UI.ps1:Invoke-DomeniaParkDeferredResults`, `Domenia-Engine.UI.ps1:Complete-DomeniaParkStateReloadUi`, `Domenia-Engine.UI.ps1:Fail-DomeniaParkStateReloadUi`

<a id="ope"></a>

## Opérations (OPE)

36 fonctions : 16 faites, 10 améliorées, 10 partielles.

### Charge et statistiques

#### OPE-001 · Indicateurs de collecte du moteur

> Reste à faire : Indicateurs par classe de demande (actions explicites, lectures automatiques, écritures, sélection, promotions) en place, sans file inventée pour les lectures. Lectures identiques partagées et requêtes WMI évitées : à compter par l’ordonnanceur de Domenia.Engine et la collecte de Domenia.Inventory (vague 3).

`partiel` · locale (aucune lecture)

Attente en file médiane et P95 par classe (actions explicites, sélection, fond), promotions après longue attente, lectures identiques partagées, requêtes WMI évitées, état des fournisseurs, profil et fenêtre de collecte.

- Garde-fous : Mesures locales de la session seulement.
- Références D1 : `Domenia-Collection.UI.ps1:Get-DomeniaCollectionHealthLines`

#### OPE-002 · Statistiques des opérations

`fait` · lecture locale

Chaque opération enregistre une mesure (éléments, durée, octets estimés, tentatives distantes, replis, réussites) ; l'onglet Charge & stats affiche moyenne par élément, durée, réseau, débit, % de repli, % de réussite et dernière mesure, exportable en CSV.

- Garde-fous : La grille n'exécute aucune action ; un échec garde le dernier historique lu pour les estimations. Mesures lues hors Dispatcher ; rétention LocalStore.TelemetryRetentionDays 365.
- Opérations : `LocalIndexRead`, `LocalStore`
- Références D1 : `DgOperationStats`, `LblOperationStats`, `BtnOperationStatsRefresh`, `BtnOperationStatsExport`, `Domenia-Engine.UI.ps1:Request-DomeniaOperationStats`, `Domenia-Engine.UI.ps1:Complete-DomeniaOperationStatsUi`, `Domenia-Engine.UI.ps1:Fail-DomeniaOperationStatsUi`, `Domenia-Cache.Model.ps1:ConvertTo-DomeniaOperationHistoryModels`, `Domenia-Core.ps1:Register-DomeniaOperationSample`, `Domenia-Core.ps1:Get-DomeniaOperationHistoryModel`, `Domenia-Core.ps1:Export-DomeniaOperationStatsCsv`, `Domenia-Main.xaml:TabOperationStats`, `Domenia-Main.xaml:DgOperationStats`, `Domenia-Main.xaml:BtnOperationStatsRefresh`, `Domenia-Main.xaml:BtnOperationStatsExport`

### Diagnostic

#### OPE-003 · Pourquoi une action est indisponible ?

`ameliore` · locale (aucune lecture)

Une ligne par blocage commun (lecture seule, reçus non confirmés, opération à vérifier, écriture active, sans sélection, secrets, boutons clés) avec route, plus l'identité des lectures LAPS/BitLocker et les transports.

- Garde-fous : Ne teste ni ne modifie aucun droit. Faits de session seulement, rien n'est testé.
- Références D1 : `modules/Domenia-Guard.UI.ps1:Show-DomeniaUnavailableReasons`, `BtnGuardWhy`, `Get-DomeniaUnavailableReasonLines`, `Resolve-DomeniaCapabilityRoute`, `Invoke-DomeniaCapabilityRoute`, `Domenia-Access.UI.ps1:Get-DomeniaUnavailableReasonLines`, `Get-DomeniaSecretButtonExplanation`, `Get-DomeniaSecretIdentityReason`, `Domenia-Main.xaml:BtnGuardWhy`

#### OPE-004 · Diagnostic expurgé

`fait` · écriture

Diagnostic de support au format Domenia.Diagnostic.2, construit sur liste blanche : versions, compatibilité du poste, jusqu'à 200 séries de mesures, 200 codes d'erreur (nombre, type .NET, ligne de script), 64 traces et 16 lenteurs expliquées. Un aperçu dit ce qu'il contient et ce qu'il ne contient jamais avant l'enregistrement.

- Garde-fous : Confirmation ; aucun envoi ; cibles retirées. Expurgé ; montré avant enregistrement. Aperçu complet avant confirmation ; aucun envoi automatique ; fichier .json, écrasement demandé. Une valeur n'est gardée que si elle a la forme d'une version, d'un code ou d'un nombre. Jamais de mot de passe, clé, message d'erreur, nom de compte, poste ou groupe, chemin AD, adresse ou contenu du journal.
- Opérations : `DocumentStore`
- Références D1 : `BtnOperationsDiagnostic`, `Start-DomeniaOperationsDiagnostic`, `BtnGuardExport`, `Export-DomeniaTechnicalDossier (Core)`, `palette:diagnostic`, `Domenia-Dossier.UI.ps1:Export-DomeniaTechnicalDossier`, `Domenia-Observability.UI.ps1:Start-DomeniaOperationsDiagnostic`, `Domenia-Observability.UI.ps1:New-DomeniaSessionDiagnostic`, `Domenia-Observability.UI.ps1:Get-DomeniaDiagnosticInputs`, `Domenia-Observability.Model.ps1:New-DomeniaRedactedDiagnostic`, `Domenia-Observability.Model.ps1:Get-DomeniaDiagnosticPreviewText`, `Domenia-Compatibility.UI.ps1:Get-DomeniaCompatibilitySupportFields`

#### OPE-005 · Santé du moteur

`ameliore` · locale (aucune lecture)

Mesures locales de la session : mémoire du processus, réactivité de l'interface (p50/p95), temps de réponse par catégorie (512 dernières mesures, p95 à partir de 20 mesures), trois dernières lenteurs expliquées, incidents de trace, dernière sauvegarde locale, files d'attente, lectures partagées, requêtes CIM évitées, sources en pause, attentes de verrou SQLite.

- Garde-fous : Mesures locales seulement. Aucune sonde réseau. Le texte précise que ce n'est pas un test du réseau. Rien ne quitte le processus.
- Références D1 : `LblOperationsHealth`, `Get-DomeniaOperationsHealthText`, `Domenia-Experience.UI.ps1:Get-DomeniaOperationsHealthText`, `Get-DomeniaRuntimeMetricSummary`, `Get-DomeniaResponseTimeSummaries`, `Get-DomeniaSlowEventLines`, `Get-DomeniaCollectionHealthLines`, `Get-DomeniaSqliteBusyStatusText`, `Domenia-Engine.UI.ps1:Get-DomeniaPulseState`, `Domenia-Engine.UI.ps1:Get-DomeniaResponseTimeSummaries`, `Domenia-Observability.UI.ps1 ($script:DomeniaTraceFaults)`

#### OPE-006 · État du moteur

`fait` · locale (aucune lecture)

Version, build, PowerShell, mémoire privée, lecture seule et état d'écriture, base active, tâches actives et détachées avec une phrase par tâche (lecture/écriture, âge, arrêt demandé, référence courte du journal).

- Garde-fous : Texte masqué par la règle des secrets.
- Références D1 : `Domenia-Core.ps1:Get-DomeniaRuntimeHealthText`, `Domenia-Core.ps1:Register-DomeniaReliabilityUi`, `Domenia-Main.xaml:BtnRuntimeHealth`

#### OPE-007 · Vérification de l'application

`fait` · lecture réseau

Vérification rapide ou complète : PowerShell 5.1+, thread STA, contrôles WPF collectés et critiques, fonctions critiques, politique d'écriture, audit statique, self-check non destructif, source du module AD, moteur user-machine, runspaces, stockage local, bind RootDSE, lecture de base, recherches utilisateur/machine/groupe, arborescence, DACL de base, outils Windows, wapt-get ; benchmark LDAP répété en complet ; copie du rapport.

- Garde-fous : Aucune cmdlet Set/Add/Remove/New/Enable/Disable/Unlock/Move/Rename-AD invoquée ; SelfCheck.AutoQuickAfterLogin=false.
- Opérations : `SelfCheck`
- Références D1 : `Domenia-Core.ps1:Start-SelfCheck`, `Domenia-Core.ps1:Add-Check`, `Domenia-Core.ps1:Copy-SelfCheckReport`, `Domenia-Main.xaml:TabSelfCheck`, `Domenia-Main.xaml:BtnSelfCheckQuick`, `Domenia-Main.xaml:BtnSelfCheckFull`, `Domenia-Main.xaml:DgSelfCheck`, `XAML:BtnSelfCheckCopy`, `XAML:LblSelfCheckStatus`

#### OPE-008 · Export du diagnostic ZIP

`ameliore` · lecture locale

Archive avec runtime.json (build, version, OS, dossiers, identités, domaine, DC, lecture seule, moteur, sources du module, intégrité), configuration expurgée et self-check.csv, sans journaux bruts.

- Garde-fous : Avertit que noms et chemins ne sont pas anonymisés ; écriture atomique.
- Références D1 : `Domenia-Core.ps1:Export-SelfCheckReport`, `Domenia-Core.ps1:ConvertTo-DomeniaSafeValue`, `Domenia-Main.xaml:BtnSelfCheckExport`

### Écritures

#### OPE-009 · Postconditions : preuve par relecture de chaque opération

`ameliore` · écriture

Une règle par opération dit quelle relecture prouve son effet (membres d'un groupe, emplacement par GUID, attributs, userAccountControl, lockoutTime, pwdLastSet, accountExpires, OU créée, absence par GUID, dernier démarrage, dernière application des stratégies, état d'un service, présence après réveil) et donne un statut Vérifié / Partiel / À vérifier avec la preuve rédigée.

- Garde-fous : Le retour du processus n'est jamais une preuve ; un attribut absent de la relecture est « non relu », jamais « vide » ; un refus de lecture ne prouve rien ; relecture sur un autre DC signalée (réplication) ; deux horloges et marge d'horloge dites ; une présence après réveil ne dépasse jamais « Partiel ».
- Opérations : `WriteGroupMember`, `WriteObjectGroup`, `WriteMoveObject`, `WriteRenameComputer`, `WriteAttributes`, `WriteExpiration`, `WriteExpirePassword`, `WriteAccountDisabled`, `WriteUnlock`, `WriteAccountOptions`, `WriteResetPassword`, `WriteCreateOu`, `WriteDeleteObject`, `ComputerRestart`, `ComputerGpUpdate`, `RimotteRun`, `ComputerServiceControl`, `WakeOnLanSend`
- Références D1 : `modules/Domenia-Safety.Model.ps1:Get-DomeniaPostconditionRule`, `modules/Domenia-Safety.Model.ps1:Resolve-DomeniaPostcondition`, `modules/Domenia-Safety.Model.ps1:Test-DomeniaMemberPresent`

#### OPE-010 · Compensation limitée et honnête

> Reste à faire : Changements inverses confirmés puis fiche ouverte avec compenser=<reçu> ; le pré-remplissage du plan inverse revient à l’écran Fiche (lecture de operations.receipts.detail).

`partiel` · écriture

Après une écriture vérifiée ou partielle, propose une compensation (nouvelle écriture inverse avec son propre plan, confirmation, reçu et vérification) seulement pour modification de fiche, membres/groupes, déplacement, activation, expiration et options du compte, et seulement si la relecture montre que les valeurs sont encore celles de l'opération.

- Garde-fous : Jamais pour mot de passe, suppression (corbeille AD), création d'OU, déverrouillage, renommage, actions distantes ; une opération à la fois ; issue d'origine à vérifier = refus ; GUID relu différent, valeur non relue ou modifiée ailleurs, conteneur d'origine absent = refus ; jamais automatique ; code et cache non concernés.
- Opérations : `WriteAttributes`, `WriteGroupMember`, `WriteObjectGroup`, `WriteMoveObject`, `WriteAccountDisabled`, `WriteExpiration`, `WriteAccountOptions`
- Références D1 : `modules/Domenia-Safety.Model.ps1:Get-DomeniaCompensation`, `Domenia-Core.ps1 l.22698-22710`

#### OPE-011 · Plans de cycle de vie d'un compte (règle non raccordée)

> Reste à faire : Règles des séquences Arrivée, Changement de service et Suspension portées et affichées avec la disponibilité de chaque étape (comme en Domenia 1, règle non raccordée). Exécution étape par étape quand les écritures groupes, attributs, déplacement et activation seront servies.

`partiel` · écriture

Séquences Arrivée, Changement de service, Suspension (vérifier, groupes du modèle, activer/désactiver, attributs, déplacement) ; une étape incertaine ou en échec bloque la suite, jamais rejouée.

- Garde-fous : Confirmation par étape sensible ; ni suppression ni migration.
- Opérations : `WriteAccountDisabled`, `WriteAttributes`, `WriteMoveObject`, `WriteObjectGroup`
- Références D1 : `Domenia-Directory.Model.ps1:New-DomeniaLifecyclePlan`, `Domenia-Directory.Model.ps1:Set-DomeniaLifecycleStep`, `Domenia-Directory.Model.ps1:Get-DomeniaLifecycleNextStep`

### Historique de session

#### OPE-012 · Dernières opérations et leurs étapes

`ameliore` · locale (aucune lecture)

Une ligne par requête suivie, la plus récente en haut : état lisible par un glyphe et un mot (Terminée, Remplacée, Retirée de la file, Arrêtée, Délai dépassé, Refusée avant envoi, Échec, Résultat inconnu, En cours), nom, type, durée, phase dominante et référence courte. Les demandes de l'opérateur sont toutes listées, les automatiques seulement si elles finissent mal ; 64 traces au plus, lignes mises à jour en place chaque seconde.

- Garde-fous : En mémoire seulement ; aucune relance automatique. Sélection, défilement et focus préservés ; une issue inconnue n'est jamais affichée comme un succès.
- Références D1 : `DgOperationsRecent`, `LblOperationsTrace`, `Update-DomeniaOperationsTraceDetail`, `Domenia-Observability.UI.ps1:Sync-DomeniaOperationsRecent`, `Domenia-Observability.UI.ps1:Get-DomeniaRecentTraceRows`, `Domenia-Observability.UI.ps1:Register-DomeniaTrace`, `Domenia-Observability.UI.ps1:Get-DomeniaTraceRing`, `Domenia-Observability.Model.ps1:Test-DomeniaTraceListed`, `Domenia-Observability.Model.ps1:Select-DomeniaTraceEviction`, `Domenia-Observability.Model.ps1:Get-DomeniaTraceOutcomes`, `Domenia-Observability.Model.ps1:Get-DomeniaTraceOutcome`, `Domenia-Live.Types.cs:Domenia.Live.OperationRow`

#### OPE-013 · Copier le détail d'une opération

`fait` · locale (aucune lecture)

Copie le détail de l'opération sélectionnée, masqué par Protect-DomeniaLogText, avec l'avertissement que le nom de la cible peut y figurer.

- Garde-fous : Avertit que le nom de la cible peut y figurer. Masquage avant copie ; « relisez avant envoi ».
- Références D1 : `BtnOperationsCopyTrace`, `Copy-DomeniaOperationsTrace`, `Domenia-Observability.UI.ps1:Copy-DomeniaOperationsTrace`

#### OPE-014 · Ouvrir le journal depuis les opérations

> Reste à faire : Onglet Journal ouvert par onglet=journal. Le raccourci Ctrl L depuis n’importe quel écran relève de l’écran shell (app.js) : il doit viser operations?onglet=journal en profil expert.

`partiel` · locale (aucune lecture)

Ferme le panneau et suit la même route que Ctrl+L : le journal de session en mode Essentiel, Outils > Journal en mode Expert.

- Références D1 : `BtnOperationsJournal`, `Open-DomeniaOperationsJournal`, `Domenia-Observability.UI.ps1:Open-DomeniaOperationsJournal`

### Panneau des opérations

#### OPE-015 · Panneau des opérations en cours

> Reste à faire : Tâches en cours dans l’onglet Tâches (durée vivante, phases et compteurs des lots, arrêt d’une lecture) et operations.center prêt pour le panneau déroulant de la barre supérieure ; ce panneau (Échap, clic à côté) relève de l’écran shell (app.js).

`partiel` · locale (aucune lecture)

Panneau déroulant sous le bouton Opérations. Il liste les tâches en cours, en attente (rien n'est encore envoyé), avec arrêt demandé, à vérifier et en nettoyage, ainsi que les lots de collecte. Pour chaque ligne : type (Lecture, Écriture, Cache local), état, durée rafraîchie chaque seconde sans perdre la sélection, détail et accès requis. Jusqu'à 64 lignes.

- Garde-fous : Échap ou clic à côté ferme sans arrêter les opérations ; une ligne disparue ne prouve pas un résultat. Aucune donnée sensible copiée : pas de payload, de credential ni de code. Une écriture à délai dépassé est « à vérifier », jamais réussie. Le panneau se ferme par Échap ou par un clic à côté.
- Références D1 : `OperationsPanel`, `BtnSuiteActivity`, `DgSuiteActivity`, `LblSuiteActivityState`, `BtnOperationsClose`, `Initialize-DomeniaOperationsPanel`, `Switch-DomeniaOperationsPanel`, `Domenia-Experience.UI.ps1:Initialize-DomeniaOperationsPanel`, `Domenia-Experience.UI.ps1:Show-DomeniaOperationsPanel`, `Domenia-Experience.UI.ps1:Hide-DomeniaOperationsPanel`, `Domenia-Experience.UI.ps1:Switch-DomeniaOperationsPanel`, `Domenia-Experience.UI.ps1:Set-DomeniaOperationsPanelPosition`, `Domenia-Experience.UI.ps1:Sync-DomeniaOperationRows`, `Domenia-Experience.UI.ps1:Update-DomeniaExperienceActivity`, `Domenia-Experience.Model.ps1:Get-DomeniaExperienceTaskRow`, `Domenia-Operations.xaml`

#### OPE-016 · Arrêter une lecture

`fait` · locale (aucune lecture)

Bouton Arrêter sur chaque ligne ou touche Suppr sur la ligne choisie. Le droit d'arrêter est revérifié sur la vraie tâche : jamais une écriture AD envoyée, jamais un enregistrement local protégé, jamais une tâche d'une autre session. Un lot de collecte (relevé ou actualisation d'OU) s'arrête en bloc.

- Garde-fous : Tâche revérifiée au clic ; une écriture AD envoyée ou un enregistrement local ne s'arrêtent pas ; tâche d'une autre session ignorée. « Arrêt demandé » ne vaut pas confirmation d'annulation. Une écriture n'est jamais annulable.
- Références D1 : `DgSuiteActivity`, `Stop-DomeniaOperationRow`, `Stop-DomeniaExperienceSelectedRead`, `Request-UiTaskStop`, `Domenia-Experience.UI.ps1:Stop-DomeniaOperationRow`, `Domenia-Experience.UI.ps1:Stop-DomeniaExperienceSelectedRead`, `Domenia-Experience.Model.ps1:Test-DomeniaExperienceCanCancel`, `Stop-DomeniaOuRefresh`, `Stop-DomeniaOnlinePark`

#### OPE-017 · Lots de collecte visibles

`fait` · locale (aucune lecture)

Les lots de ping, de WMI, de postes et d'objets AD restent visibles entre deux workers et jusqu'à la dernière sauvegarde locale. Chaque lot affiche sa phase (Préparation, Lecture AD, À confirmer, En cours, Enregistrement), sa progression et ses compteurs (non confirmés, erreurs de ping, en cours, enregistrements en attente, postes non relus faute de capacité).

- Garde-fous : Projection limitée à des champs scalaires : aucune cible ni credential.
- Opérations : `ParkPing`, `LiveSelectedPing`
- Références D1 : `Domenia-Experience.Model.ps1:Get-DomeniaExperienceBatchRows`, `LblSuiteBatchProgress`

#### OPE-018 · États exacts d'annulation

`fait` · locale (aucune lecture)

Les états possibles sont En attente, En cours, Arrêt demandé, Nettoyage (lecture détachée dont l'appel natif vit encore) et Terminé. Un job dont l'appel natif est vivant n'est jamais dit terminé. Les textes d'annulation sont fixes : « Demande retirée de la file avant tout envoi », « Arrêt demandé… La lecture est encore active », « Écriture … non annulable après envoi. Attente de la relecture de vérification ».

- Garde-fous : Un arrêt demandé n'est pas une annulation confirmée (règle du kit de suite).
- Références D1 : `Domenia-Engine.Model.ps1:Get-DomeniaTaskState`, `Domenia-Engine.Model.ps1:Get-DomeniaCancelStatusText`, `Domenia-Engine.Model.ps1:Get-DomeniaTaskStateSummary`

#### OPE-019 · Étapes détaillées d'une opération

> Reste à faire : Étapes dans l’ordre, total, volume et étape dominante à part, suite possible, panneau mis à jour en place. La publication dans l’interface est dite « non mesurée » : la mesurer par tâche demande un point d’accroche dans bridge.js (fichier partagé).

`partiel` · locale (aucune lecture)

Pour l'opération choisie, les phases s'affichent dans l'ordre avec leur mesure propre : Demande, File d'attente, Lecture partagée, Collecte, Validation, Lecture locale, Publication dans l'interface, Fin. S'y ajoutent le total, le volume (« au moins » si incomplet) et la suite possible. Une phase non mesurée est dite non mesurée.

- Garde-fous : 32 événements par trace, les lots consécutifs fusionnés. Région live polie, annoncée seulement au changement d'opération ou d'état.
- Références D1 : `LblOperationsTrace`, `Domenia-Observability.UI.ps1:Update-DomeniaOperationsTraceDetail`, `Domenia-Observability.UI.ps1:Start-DomeniaJobTrace`, `Domenia-Observability.UI.ps1:Add-DomeniaJobTraceEvent`, `Domenia-Observability.UI.ps1:Add-DomeniaRequestTraceEvent`, `Domenia-Observability.UI.ps1:Join-DomeniaPipeTrace`, `Domenia-Observability.UI.ps1:Complete-DomeniaRequestTrace`, `Domenia-Observability.UI.ps1:Complete-DomeniaJobTrace`, `Domenia-Observability.UI.ps1:Get-DomeniaJobPhaseMeasures`, `Domenia-Observability.UI.ps1:Get-DomeniaTraceContextHint`, `Domenia-Observability.UI.ps1:Get-DomeniaTraceNow`, `Domenia-Observability.Model.ps1:Get-DomeniaTracePhases`, `Domenia-Observability.Model.ps1:New-DomeniaOperationTrace`, `Domenia-Observability.Model.ps1:Add-DomeniaTraceJob`, `Domenia-Observability.Model.ps1:Add-DomeniaOperationTraceEvent`, `Domenia-Observability.Model.ps1:Complete-DomeniaTraceJob`, `Domenia-Observability.Model.ps1:Get-DomeniaOperationTraceSummary`, `Domenia-Observability.Model.ps1:Resolve-DomeniaTraceId`, `Domenia-Observability.Model.ps1:Get-DomeniaTraceReference`, `Domenia-Observability.Model.ps1:Format-DomeniaDurationText`, `Domenia-Observability.Model.ps1:Format-DomeniaVolumeText`, `Domenia-Observability.Model.ps1:Get-DomeniaOutputVolume`, `Domenia-Observability.Model.ps1:Get-DomeniaTraceLimits`

#### OPE-020 · Conseil après la fin d'une opération

`fait` · locale (aucune lecture)

Une phrase dit quoi faire selon l'issue et la catégorie (compte refusé, droit insuffisant, cible injoignable, prérequis absent…), avec la référence à chercher dans Domenia.log. Pour une écriture non confirmée, elle renvoie à « opérations à vérifier » et rappelle que Domenia ne rejoue jamais une écriture.

- Garde-fous : Jamais de nouvelle tentative automatique proposée.
- Références D1 : `Domenia-Observability.Model.ps1:Get-DomeniaTraceAdvice`

#### OPE-021 · Résumé des tâches et des ressources

`fait` · locale (aucune lecture)

Résumé du type « 2 en cours · 1 en attente · 1 arrêt demandé · 1 nettoyage », ou « Aucune tâche », avec le nombre de ressources détenues par type (minuteries, pools, jobs).

- Garde-fous : Une lecture détachée reste comptée jusqu'à la fin réelle de son appel natif.
- Références D1 : `Domenia-Engine.Model.ps1:Get-DomeniaTaskStateSummary`, `Domenia-Engine.Model.ps1:Get-DomeniaResourceSummary`, `DgSuiteActivity`, `LblSuiteActivityState`

### Reçus d'écriture

#### OPE-022 · Liste des reçus d'opérations

`ameliore` · lecture locale

Liste des reçus du domaine en mots clairs (étape avec pastille de ton, opération, objet par son nom, DN en infobulle, compte, contrôleur, date), ceux à vérifier d'abord ; une phrase de synthèse dit combien restent à vérifier et que les nouvelles écritures sont bloquées. Actualisée au démarrage et automatiquement, ou par « Actualiser les reçus ».

- Garde-fous : Lecture sans rejeu ; tâche non annulable, 25 s ; refusée pendant une écriture ; nouvel essai 15 s (30 s après échec) ; reçus illisibles = aucune écriture autorisée ; sélection conservée ; job orphelin libéré.
- Opérations : `ReceiptStore`
- Références D1 : `modules/Domenia-Guard.UI.ps1:Start-DomeniaReceiptRefresh`, `modules/Domenia-Guard.UI.ps1:Complete-DomeniaReceiptRefresh`, `modules/Domenia-Guard.UI.ps1:Fail-DomeniaReceiptRefresh`, `modules/Domenia-Guard.UI.ps1:Show-DomeniaGuard`, `modules/Domenia-Safety.Model.ps1:Get-DomeniaReceiptView`, `modules/Domenia-Safety.Model.ps1:Get-DomeniaReceiptStageView`, `modules/Domenia-Safety.Model.ps1:Get-DomeniaReceiptSummary`, `modules/Domenia-Safety.Model.ps1:Get-DomeniaOperationDisplayName`, `DgGuardReceipts`, `LblGuardReceipts`, `BtnGuardReceiptRefresh`, `BtnGuardOpen`, `Domenia-Main.xaml:TabGuard`, `Domenia-Main.xaml:DgGuardReceipts`

#### OPE-023 · Vérifier un reçu par relecture

`ameliore` · lecture réseau

Après confirmation dans la page (« Relire maintenant »), relit sur le contrôleur initial et sous verrou l'état attendu : valeurs d'attributs (par empreinte, GUID vérifié) ou, pour les autres écritures, options userAccountControl, lockoutTime à 0, pwdLastSet à 0 ou postérieur à l'envoi (marge 120 s), jour d'expiration, conteneur parent, nouveau nom, appartenance directe, OU présente, absence par GUID ; le reçu passe à « Vérifié » ou reste à vérifier avec la raison.

- Garde-fous : Seule une lecture part, aucune commande renvoyée ; jeton par demande (une demande remplacée ne déclenche rien) ; session vérifiée ; reçu relu sous writer.lock, jamais d'écrasement d'un reçu déjà résolu ; refus ou attribut absent ne prouve rien ; résultat lu sur le reçu lui-même.
- Opérations : `ReceiptStore`
- Références D1 : `modules/Domenia-Guard.UI.ps1:Invoke-DomeniaReceiptChoice`, `modules/Domenia-Guard.UI.ps1:Complete-DomeniaReceiptChoice`, `modules/Domenia-Guard.UI.ps1:Cancel-DomeniaReceiptChoice`, `modules/Domenia-Receipts.Worker.ps1:Read-WReceiptObservation`, `modules/Domenia-Safety.Model.ps1:Resolve-DomeniaReceiptCheck`, `modules/Domenia-Safety.Model.ps1:Get-DomeniaReceiptActionView`, `BtnGuardReceiptVerify`, `LblGuardReceiptSelection`, `Domenia-Main.xaml:BtnGuardReceiptVerify`

#### OPE-024 · Consigner une revue manuelle d'un reçu

`ameliore` · locale (aucune lecture)

L'opérateur décrit le contrôle réalisé avec un autre outil (12 à 240 caractères, compteur en direct), confirme dans la page, et le reçu devient « Revue manuelle » avec ce motif, jamais un succès automatique.

- Garde-fous : Motif ressemblant à un secret refusé ; bornes revérifiées par le magasin ; indisponible pendant une lecture ou écriture des reçus ; reçu déjà résolu non modifiable.
- Opérations : `ReceiptStore`
- Références D1 : `modules/Domenia-Guard.UI.ps1:Invoke-DomeniaReceiptChoice (Review)`, `modules/Domenia-Guard.UI.ps1:Update-DomeniaReceiptActionUi`, `modules/Domenia-Safety.Model.ps1:Test-DomeniaReceiptReviewReason`, `modules/Domenia-Safety.Model.ps1:Get-DomeniaReceiptActionView`, `TxtGuardReceiptReason`, `LblGuardReceiptReasonCount`, `BtnGuardReceiptReview`

#### OPE-025 · Levée de l'incertitude d'écriture et pastille « opérations à vérifier »

> Reste à faire : Blocage de toutes les nouvelles écritures restauré dans WriteCircuit (write.receiptsPending), levée par relecture conclusive ou revue seulement, tracée en WARN, visible dans l’écran (circuit, tuile, onglet, bilan). Le bouton du panneau Opérations de la barre supérieure relève de l’écran shell (operations.center).

`partiel` · écriture

L'état d'écriture inconnu ne redevient « au repos » qu'après vérification ou revue explicite de tous les reçus en attente ; la pastille d'en-tête et le bouton du panneau Opérations comptent les reçus à vérifier, et les droits d'interface sont recalculés.

- Garde-fous : Incertitude jamais levée par le temps ou un redémarrage ; journalisée en WARN.
- Opérations : `ReceiptStore`
- Références D1 : `modules/Domenia-Guard.UI.ps1:Complete-DomeniaReceiptRefresh`, `Update-DomeniaPendingOperationsPill (Core)`, `Apply-CurrentPermissionUi (Core)`, `BtnOperationsReceipts`

#### OPE-026 · Opérations à vérifier (reçus d'écriture)

> Reste à faire : Pastille « N opérations à vérifier » (jamais « 0 opération »), aide de Domenia 1 et reçu le plus ancien au survol dans l’en-tête de l’écran, la tuile, l’onglet et operations.center. La pastille de la barre supérieure relève de l’écran shell (app.js).

`partiel` · lecture locale

Pastille d'en-tête visible seulement quand un reçu durable attend une vérification ou une revue (jamais « 0 opération »). Un clic ouvre la liste des reçus (route TabGuard) et ne rejoue rien. Tant qu'elle est visible, les nouvelles écritures restent bloquées.

- Garde-fous : Rien n'est rejoué ; même compte que la pastille de l'en-tête. Rien n'est rejoué. Les écritures sont bloquées tant qu'un reçu est en attente.
- Opérations : `ReceiptStore`
- Références D1 : `BtnOperationsReceipts`, `BtnPendingOperations`, `Invoke-DomeniaCapabilityRoute`, `Domenia-Assist.Model.ps1:Get-DomeniaPendingOperationsView`, `Domenia-Assist.UI.ps1:Update-DomeniaPendingOperationsPill`

### Relevés

#### OPE-027 · Relevé en cours (Outils > Relevés)

`fait` · locale (aucune lecture)

Montre l'actualisation d'OU ou le relevé de liste en cours avec son état et un bouton Arrêter.

- Garde-fous : Mesures reçues conservées, rien n'est rejoué.
- Références D1 : `Domenia-Collection.UI.ps1:Update-DomeniaRunsPanel`, `Domenia-Collection.UI.ps1:Stop-DomeniaRunsPanelSurvey`, `LblRunsCurrent`, `BtnRunsStop`

#### OPE-028 · Derniers relevés par OU

`ameliore` · lecture locale

Grille des relevés enregistrés du domaine, le plus récent en haut : date, OU (et sous-OU), type (Objets AD, Ping, WMI), état, postes lus, dernière réussite, motif.

- Garde-fous : Enregistrement sans date lisible écarté ; base occupée signalée.
- Opérations : `LocalIndexRead`
- Références D1 : `Domenia-Collection.Model.ps1:ConvertTo-DomeniaCollectionRunListRows`, `Domenia-Collection.Model.ps1:ConvertFrom-DomeniaCollectionRunRecord`, `Domenia-Collection.UI.ps1:Request-DomeniaCollectionRunsList`, `Domenia-Collection.UI.ps1:Complete-DomeniaCollectionRunsListUi`, `DgRuns`, `BtnRunsRefresh`, `LblRunsList`, `Domenia-Main.xaml:TabCollectionLimits`, `Domenia-Main.xaml:DgRuns`

#### OPE-029 · Reprise d'un relevé interrompu

`fait` · lecture réseau

Propose une fois par session de reprendre (ou abandonner, ou plus tard) un relevé interrompu du domaine ; « Reprendre » ne lit que les postes restants après la confirmation habituelle.

- Garde-fous : Même domaine et même base locale ; indisponible en démonstration ou pendant un autre relevé ; abandonner garde les mesures validées.
- Opérations : `ParkPing`, `LiveConsole`
- Références D1 : `Domenia-Collection.UI.ps1:Request-DomeniaCampaignResumeOffer`, `Domenia-Collection.UI.ps1:Start-DomeniaCampaignResume`, `Domenia-Collection.UI.ps1:Clear-DomeniaCampaignPlan`, `Domenia-Collection.UI.ps1:Update-DomeniaCampaignResumeUi`, `Domenia-Collection.UI.ps1:Get-DomeniaCampaignReplacementNote`, `BtnRunsResume`, `BtnRunsResumeDiscard`, `BtnCollectionResume`, `BtnCollectionResumeDiscard`, `XAML:LblRunsResume`

### Santé du moteur

#### OPE-030 · Mesures de réactivité de l'interface

> Reste à faire : Battement de toute l’interface, continu dès le premier affichage d’Opérations (pulse.js, startPulse). Le démarrer dès le lancement de l’application revient à l’écran shell (une ligne dans app.js).

`partiel` · locale (aucune lecture)

Un battement de cœur d'une seconde mesure le retard du Dispatcher (240 derniers échantillons, p50/p95), l'attribue au travail d'interface qui l'a chevauché, et affiche dans Fiabilité le p50/p95, le nombre de tâches et l'état de l'enregistrement local.

- Garde-fous : Mesure indicative locale, pas un benchmark réseau ; une erreur d'affichage n'arrête jamais les reçus.
- Références D1 : `modules/Domenia-Guard.UI.ps1:Initialize-DomeniaGuard (Timer:Guard)`, `modules/Domenia-Guard.Model.ps1:Get-DomeniaPercentile`, `LblGuardMetrics`, `Add-DomeniaRuntimeMetric`, `Register-DomeniaDispatcherLateness`, `Get-DomeniaPersistenceState`

#### OPE-031 · Temps de réponse par catégorie

`ameliore` · locale (aucune lecture)

Médiane, 95e centile (affiché à partir de 20 mesures) et maximum pour six catégories : Recherche locale, Traitement des résultats dans l'interface, Autres lectures et écritures de la base locale, Lectures de l'annuaire, Collecte sur les postes, Écritures dans l'annuaire et actions sur les postes. Une catégorie sans mesure le dit, sans inventer 0 ms ; le recalcul n'a lieu que si une série a bougé.

- Garde-fous : Une mesure n'est jamais comptée dans deux catégories.
- Références D1 : `Domenia-Engine.Model.ps1:Get-DomeniaResponseTimeCategories`, `Domenia-Engine.Model.ps1:Select-DomeniaResponseTimeSamples`, `Domenia-Engine.Model.ps1:Get-DomeniaLatencySummary`, `Domenia-Engine.Model.ps1:Format-DomeniaLatencySummaryText`, `Domenia-Engine.UI.ps1:Get-DomeniaResponseTimeSummaries`, `LblOperationsHealth`

#### OPE-032 · Attente de verrou SQLite bornée et comptée

> Reste à faire : Règle, phrase et compteur (OperationActivity.RecordSqliteBusy : nombre et heure de la dernière attente) en place et affichés ; la base locale SQLite n’existe pas encore dans Domenia 2 : Domenia.Store appellera le compteur (vague 3).

`partiel` · locale (aucune lecture)

Attente de verrou SQLite LocalStore.DatabaseBusyTimeoutMs : 2500 ms par défaut, bornée de 100 à 5000 ms, commune à l'interface et aux workers. Chaque fin de worker dont l'attente a expiré (SQLITE_BUSY ou LOCKED, lecture locale répondue Busy) est comptée, et le panneau Opérations affiche le nombre et l'heure de la dernière.

- Garde-fous : Compteurs de session seulement : rien n'est rejoué.
- Opérations : `LocalStore`, `LocalIndexRead`, `RelationHistoryRead`
- Références D1 : `Domenia-Cache.Model.ps1:Get-DomeniaSqliteBusyTimeoutMs`, `Domenia-Cache.Model.ps1:Test-DomeniaSqliteBusyText`, `Domenia-Cache.Model.ps1:Format-DomeniaSqliteBusySummary`, `Domenia-Storage.UI.ps1:Register-DomeniaSqliteBusyOutcome`, `Domenia-Storage.UI.ps1:Get-DomeniaSqliteBusyStatusText`

#### OPE-033 · État d'enregistrement local en une phrase

`fait` · locale (aucune lecture)

Une seule phrase décrit l'enregistrement local, sans jamais annoncer une sauvegarde qui n'a pas eu lieu : stockage indisponible, suspendu, conflits, échecs, en attente (éléments en file, changements collectés et taille) ou enregistré (dernière fois). Elle est affichée dans Fiabilité et sur la ligne d'état Live.

- Garde-fous : Les lots déjà envoyés et non confirmés comptent encore.
- Références D1 : `Domenia-Storage.UI.ps1:Get-DomeniaPersistenceState`, `Domenia-Cache.Model.ps1:Get-DomeniaPersistenceLabel`, `Domenia-Store.Model.ps1:Format-DomeniaStorageUnsaved`

#### OPE-034 · Lenteurs expliquées

`fait` · locale (aucune lecture)

Une lenteur est expliquée par l'opération, ses phases mesurées, son volume et le traitement dans l'interface. Une opération de plus de 5 s ou un traitement d'interface au-dessus de son seuil entrent dans la liste des 16 dernières lenteurs, affichées dans le bloc Santé, la plus récente en premier.

- Garde-fous : Une phase non mesurée n'est jamais comptée comme zéro.
- Références D1 : `Domenia-Observability.Model.ps1:Get-DomeniaSlownessVerdict`, `Domenia-Observability.UI.ps1:Register-DomeniaJobPublication`, `Domenia-Observability.UI.ps1:Add-DomeniaSlowEvent`, `Domenia-Observability.UI.ps1:Get-DomeniaSlowEventLines`

#### OPE-035 · Blocages de l'interface attribués

`fait` · locale (aucune lecture)

Un battement en retard de 400 ms ou plus est expliqué par le travail d'interface suivi qui chevauche la fenêtre de retard (rappels, ticks), au plus une explication toutes les 5 s. Sans chevauchement, la cause est déclarée non attribuée (mise en page, rendu ou appel hors moteur).

- Garde-fous : Jamais de cause devinée ; ligne écrite dans Domenia.log.
- Références D1 : `Domenia-Observability.UI.ps1:Register-DomeniaDispatcherLateness`, `Domenia-Observability.UI.ps1:Register-DomeniaUiWork`, `Domenia-Observability.Model.ps1:Get-DomeniaStallAttribution`

#### OPE-036 · Sources suspendues et reprises progressives

`fait` · locale (aucune lecture)

Lignes en clair pour chaque source qui n'est pas saine : « annuaire · site X : lectures de fond suspendues jusqu'à HH:mm:ss », « WMI · 12 cibles (…) : reprise progressive », « identifiants rejetés, reprise après un changement de compte explicite ». Les postes isolés sont comptés par fournisseur et par état, avec quelques noms.

- Garde-fous : Aucune ligne ne dit que tout l'annuaire est injoignable ; les sources saines ne sont pas listées.
- Références D1 : `Domenia-Engine.Model.ps1:Get-DomeniaProviderStateSummary`, `Domenia-Collection.UI.ps1`

<a id="par"></a>

## Paramètres (PAR)

51 fonctions : 5 faites, 9 améliorées, 37 partielles.

### À propos

#### PAR-001 · Compatibilité du poste dans À propos

`ameliore` · lecture locale

Une matrice livrée, jamais téléchargée, est comparée aux faits du poste lus dans le registre et le processus : Windows (build, client ou serveur), PowerShell (édition, version, 64 bits), .NET Framework, winsqlite3.dll ; annuaire et CIM sont documentés. Statuts Qualifié, Testé, Attendu ou Non pris en charge, sinon Inconnu. La phrase d'À propos donne le statut global, l'infobulle le détail par dimension.

- Garde-fous : Un fait non lu ou un environnement hors matrice donne Inconnu, jamais compatible. « Qualifié » exige un rapport lié au ZIP livré ; ne bloque jamais le panneau.
- Références D1 : `LblUxAboutCompatibility`, `modules/Domenia-Compatibility.json`, `Domenia-Compatibility.UI.ps1:Get-DomeniaCompatibilityMatrix`, `Domenia-Compatibility.UI.ps1:Read-DomeniaLocalRegistryValue`, `Domenia-Compatibility.UI.ps1:Get-DomeniaEnvironmentFacts`, `Domenia-Compatibility.UI.ps1:Get-DomeniaLocalCompatibility`, `Domenia-Compatibility.UI.ps1:Update-DomeniaAboutCompatibility`, `Domenia-Compatibility.Model.ps1:Get-DomeniaCompatibilityStatuses`, `Domenia-Compatibility.Model.ps1:Get-DomeniaCompatibilityStatusLabel`, `Domenia-Compatibility.Model.ps1:Test-DomeniaCompatibilityMatch`, `Domenia-Compatibility.Model.ps1:Test-DomeniaCompatibilityMatrix`, `Domenia-Compatibility.Model.ps1:Get-DomeniaCompatibilityVerdict`, `Domenia-Compatibility.Model.ps1:Get-DomeniaCompatibilityText`

#### PAR-002 · Inventaire des composants livrés

`ameliore` · lecture locale

Une ligne par fichier livré. Une version n'est affichée que si elle est liée à ce fichier précis : ressource de version d'un fichier au même SHA-256, version déclarée par le contrat pour ce SHA-256, ou build du manifeste pour les fichiers texte produits par le build.

- Garde-fous : Une version liée au seul nom d'un paquet n'est pas affichée.
- Références D1 : `Domenia-Release.Model.ps1:Get-DomeniaComponentInventory`, `Domenia-Release.Model.ps1:Test-DomeniaReleaseMapKey`, `Domenia-Release.Model.ps1:Get-DomeniaReleaseMapValue`

### Apparence et interface

#### PAR-003 · Réglages de lecture du journal

`ameliore` · locale (aucune lecture)

Options : Suivre (défilement automatique), Erreurs seulement (vue lisible), retour à la ligne (vue brute), taille du texte 10, 11, 12, 14, 16 ou 18. Le retour à la ligne et la taille sont mémorisés.

- Garde-fous : Affichage seulement : tous les niveaux restent enregistrés.
- Références D1 : `Domenia-Experience.UI.ps1:Apply-DomeniaExperienceLogReading`, `Domenia-Experience.UI.ps1:Set-DomeniaExperienceLogFilter`, `ChkUiLogFollow`, `ChkUiLogErrorsOnly`, `ChkSuiteLogWrap`, `CmbSuiteLogSize`

#### PAR-004 · Densité des résultats

> Reste à faire : Densité compacte, normale ou confort dans le magasin de la coque (domenia.prefs.v1, valeurs alignées sur le lot shell), appliquée aux tableaux et listes de Paramètres ; la grille du kit (createGrid) doit prendre cette densité par défaut pour les listes sans choix propre (demande au kit et à la coque).

`partiel` · locale (aucune lecture)

Deux réglages mémorisés : Confort (lignes de 36 unités) ou Compact (28 unités).

- Garde-fous : Ne change ni les filtres AD ni les droits.
- Références D1 : `Domenia-Experience.UI.ps1:Apply-DomeniaExperienceDensity`, `CmbSuiteDensity`, `Domenia-Main.xaml:CmbSuiteDensity`

#### PAR-005 · Profil Essentiel ou Expert

> Reste à faire : Profil Essentiel ou Expert dans le magasin de la coque, soumis à UI.AllowExpertProfile ; parties expertes de Paramètres (vue brute du journal, empreintes, plans SQLite, noms des réglages, détails des contrôles) masquées en Essentiel et jamais laissées sélectionnées ; les vues Brut, Permissions, WMI, Autodiagnostic, Classe et GUID des autres écrans suivent ctx.expert de la coque.

`partiel` · locale (aucune lecture)

Sélecteur au pied du menu. Expert affiche Brut, Permissions, WMI (postes), Autodiagnostic, Journal, les options de compte à haut risque, Classe et GUID, la colonne Source de l'inventaire, Méthode et Durée du diagnostic, Score et Correspondance de la base autonome. L'administrateur peut masquer Expert (UI.AllowExpertProfile=false), ce qui force Essentiel.

- Garde-fous : Ce choix ne donne aucun droit. Une page masquée n'est jamais laissée sélectionnée. Le profil ne modifie aucun droit.
- Références D1 : `Domenia-UX.UI.ps1:Update-DomeniaUxProfileVisibility`, `Domenia-UX.UI.ps1:Update-DomeniaUxProfileSwitch`, `Domenia-UX.UI.ps1:Test-DomeniaUxExpertAllowed`, `LstUiProfile`, `LstUiProfileTech`, `LstUiProfileExpert`, `TabRaw`, `TabPermissions`, `TabWmi`, `TabSelfCheck`, `TabLog`, `ExpAccountSecurityOptions`, `DgInventory`, `DgComputerDiag`, `DgIndex`, `Domenia-Core.ps1:Load-DomeniaUiProfile`, `Domenia-Core.ps1:Save-DomeniaUiProfile`, `Domenia-Core.ps1:Apply-DomeniaUiProfile`, `Domenia-Main.xaml:LstUiProfile`

#### PAR-006 · Menu replié en icônes

> Réévaluée à l’intégration (22/10/2026) : le reste déclaré par Paramètres (repli temporaire du menu sur un écran étroit, dépliage pour la session sans changer la préférence) est fait par la coque fusionnée (`web/js/app.js`, `foldNavigation`, `autoReleased`).

`fait` · locale (aucune lecture)

Replie le menu en icônes (68 unités au lieu de 204), choix mémorisé. Sur un écran étroit (moins de 1280) ou court et étroit, le menu se replie temporairement, et l'opérateur peut le déplier pour la session sans changer sa préférence.

- Garde-fous : Ne modifie ni IsEnabled ni les routes.
- Références D1 : `Domenia-UX.UI.ps1:Switch-DomeniaUxSidebar`, `Domenia-UX.UI.ps1:Update-DomeniaUxSidebar`, `Domenia-UX.UI.ps1:Test-DomeniaUxNavFolded`, `Domenia-UX.UI.ps1:Save-DomeniaUxLayoutSettings`, `BtnUxSidebarToggle`, `UxSidebar`, `UxNavColumn`, `UxBrandCompact`, `UxBrandExpanded`, `XAML:UxSidebarToggleGlyph`

#### PAR-007 · Panneau d'aide à droite

> Reste à faire : Infobulles d’aide (helpTips de la coque) et bouton « Ouvrir l’aide » raccordés à ctx.help ; la colonne de 300, la superposition sous 1 040 et le retour du focus sur « ? » sont ceux du panneau F1 de la coque (lot shell, absent de cette branche avant fusion).

`partiel` · locale (aucune lecture)

Colonne d'aide de 300 unités, à afficher ou masquer, choix mémorisé. Quand la zone utile fait moins de 1040 unités, elle s'ouvre en superposition. Sur un écran court, elle s'ouvre pour la session seulement. Le focus revient au bouton ? quand elle se ferme.

- Garde-fous : Un redimensionnement n'annule pas un choix volontaire.
- Références D1 : `Domenia-UX.UI.ps1:Switch-DomeniaUxHelp`, `Domenia-UX.UI.ps1:Get-DomeniaUxLayoutPlan`, `Domenia-UX.UI.ps1:Update-DomeniaUxLayout`, `BtnUxHelpToggle`, `BtnUxHelpClose`, `UxHelpPanel`, `UxHelpColumn`

#### PAR-008 · Thème clair, sombre ou automatique

> Réévaluée à l’intégration (22/10/2026) : le reste déclaré par Paramètres (Ctrl T, listé dans les raccourcis) est fait par la coque fusionnée (`web/js/app.js`, `toggleTheme`, liste des raccourcis).

`fait` · locale (aucune lecture)

Choix Light, Dark ou Auto (suit le réglage Windows AppsUseLightTheme, contraste élevé pris en compte) partagé par le login, le moniteur et la fenêtre principale ; bouton de thème et Ctrl+T ; les graphiques et pastilles de présence sont repeints depuis leurs données.

- Garde-fous : Si le choix Windows est illisible, le thème clair s'applique. Une seule valeur du registre est lue. Échec d'enregistrement annoncé, thème conservé pour la session.
- Références D1 : `Domenia-Experience.Model.ps1:ConvertTo-DomeniaThemePreference`, `Domenia-Experience.Model.ps1:Resolve-DomeniaEffectiveTheme`, `Domenia-Experience.Model.ps1:Get-DomeniaThemeChoices`, `Domenia-Shell.Model.ps1:Get-DomeniaThemeToggleIcon`, `Domenia-UX.UI.ps1:Initialize-DomeniaUxThemeMenu`, `Domenia-UX.UI.ps1:Update-DomeniaAutoTheme`, `Domenia-UX.UI.ps1:Update-DomeniaUxThemeToggle`, `BtnThemeToggle`, `ThemeIconSun`, `ThemeIconMoon`, `Set-DomeniaThemePreference`, `Get-DomeniaWindowsAppTheme`, `Domenia-Core.ps1:Get-DomeniaThemePreference`, `Domenia-Core.ps1:Get-DomeniaWindowsAppTheme`, `Domenia-Core.ps1:Get-DomeniaStoredTheme`, `Domenia-Core.ps1:Get-DomeniaBootThemePalette`, `Domenia-Core.ps1:Apply-DomeniaTheme`, `Domenia-Core.ps1:Set-DomeniaThemePreference`, `Domenia-Core.ps1:Toggle-DomeniaTheme`, `Domenia-Main.xaml:BtnThemeToggle`

#### PAR-009 · Zoom de l'interface

`ameliore` · locale (aucune lecture)

Zoom de 80 à 150 % par pas de 10, avec retour à 100 %, mémorisé (Ui.ZoomPercent). Les dimensions sont alignées sur la grille de pixels pour éviter l'oscillation des barres de défilement, et réajustées après un changement de DPI ou de taille de fenêtre.

- Garde-fous : Bornes 80–150. Le texte saisi et le focus ne sont pas touchés.
- Références D1 : `Domenia-UX.UI.ps1:Get-DomeniaUiZoomLayoutSize`, `Domenia-UX.UI.ps1:Set-DomeniaUiZoom`, `Domenia-UX.UI.ps1:Update-DomeniaUiZoomForDpi`, `Domenia-UX.UI.ps1:Initialize-DomeniaUiZoom`, `BtnUiZoomOut`, `BtnUiZoomReset`, `BtnUiZoomIn`, `UxShellGrid`, `RootScroll`, `Domenia-Main.xaml:BtnUiZoomIn`

### Base locale

#### PAR-010 · Reprendre les sauvegardes locales

> Reste à faire : Écrivain suspendu (trois échecs, manque d’espace), avis sous le bandeau et « Reprendre les sauvegardes » par le circuit, refusé tant qu’un enregistrement est actif ; démontré par le scénario « Enregistrement suspendu ». Simulation seulement (base fictive en mémoire, par le circuit d’écriture) ; en mode annuaire la base SQLite de Domenia 2 n’est pas encore branchée (Domenia.Store, vague 3) : settings.storeUnavailable.

`partiel` · écriture

Après trois échecs ou un manque d'espace, l'écrivain est suspendu et un avis l'annonce avec le bouton « Reprendre les sauvegardes » (BtnGuardStoreResume), qui réarme la file sans rien perdre de la mémoire.

- Garde-fous : Refusé si un enregistrement est encore actif ; aucune écriture AD. Aucune reprise automatique en boucle.
- Opérations : `LocalStore`
- Références D1 : `modules/Domenia-Guard.UI.ps1:Resume-DomeniaStorage`, `BtnGuardStoreResume`, `Request-DomeniaStorageWork`, `Domenia-Storage.UI.ps1:Fail-DomeniaStorageWork`, `Domenia-Storage.UI.ps1:Test-DomeniaStorageWorkPending`

#### PAR-011 · Réserve d'espace disque de la base

> Reste à faire : Seuils de 32 Mo, 512 Mo et 2 Go relevés de quatre fois la file, état et alerte ; scénario « Disque presque plein ». Simulation seulement (base fictive en mémoire, par le circuit d’écriture) ; en mode annuaire la base SQLite de Domenia 2 n’est pas encore branchée (Domenia.Store, vague 3) : settings.storeUnavailable.

`partiel` · lecture locale

Les écritures sont refusées sous 32 Mio libres plus quatre fois le lot entrant. Les nouvelles collectes sont suspendues sous 512 Mio plus quatre fois la file, ce qui est déjà collecté continuant de s'écrire, et une alerte apparaît sous 2 Gio. LblStorageSpace donne l'état (Ok, À surveiller, Insuffisant, Critique, Non mesuré) et signale une mesure de plus de 30 min.

- Garde-fous : StorageInsufficientSpace : le lot reste non enregistré, en mémoire. Le passage en suspension est annoncé une fois, avec une route vers « Reprendre les sauvegardes ».
- Opérations : `LocalStore`, `StorageUsage`
- Références D1 : `Domenia-Store.Model.ps1:Get-DomeniaStorageSpaceState`, `Domenia-Storage.UI.ps1:Get-DomeniaCurrentStorageSpace`, `Domenia-Storage.UI.ps1:Update-DomeniaStorageSpace`, `Domenia-Storage.UI.ps1:Update-DomeniaStorageSpaceUi`, `LblStorageSpace`

#### PAR-012 · Reprise d'une maintenance interrompue au démarrage

> Reste à faire : Bascule interrompue ou base illisible : seules reprise, retour ou restauration vérifiée proposées (scénarios « Bascule interrompue » et « Base illisible ») ; la détection au démarrage par lecture du marqueur de redirection attend Domenia.Store. Simulation seulement (base fictive en mémoire, par le circuit d’écriture) ; en mode annuaire la base SQLite de Domenia 2 n’est pas encore branchée (Domenia.Store, vague 3) : settings.storeUnavailable.

`partiel` · lecture locale

Au démarrage, une bascule interrompue (marqueur de redirection) ou une base illisible est détectée par une lecture seule (ReadRedirect). L'assistant ne propose alors que la reprise ou le retour arrière, ou la restauration d'une sauvegarde vérifiée, et les collectes restent suspendues.

- Garde-fous : Un marqueur ambigu ou dont l'identité est incohérente est refusé, et les fichiers sont conservés.
- Opérations : `StorageMaintenance`
- Références D1 : `Domenia-Storage.UI.ps1:Request-DomeniaStorageRecovery`, `Domenia-Storage.UI.ps1:Complete-DomeniaStorageRecovery`, `Domenia-Storage.UI.ps1:Fail-DomeniaStorageRecovery`, `Domenia-Storage.Worker.ps1:Get-DomeniaStorageMaintenanceWorkerCode`

#### PAR-013 · Emplacement lisible de la base locale

> Reste à faire : Ligne de l’emplacement, même total partout (base et journal), alerte douce sans sauvegarde ou au-delà de 7 jours. Simulation seulement (base fictive en mémoire, par le circuit d’écriture) ; en mode annuaire la base SQLite de Domenia 2 n’est pas encore branchée (Domenia.Store, vague 3) : settings.storeUnavailable.

`partiel` · lecture locale

Une ligne remplace le chemin : « Base du domaine X · 4,2 Mo · sauvegardée il y a 2 h », ou « Base de démonstration », ou « Aucune base locale pour ce domaine ». Le chemin reste dans l'infobulle. Une alerte douce s'affiche s'il n'y a aucune sauvegarde ou si la dernière date de plus de 7 jours.

- Garde-fous : Métadonnées de fichier locales seulement, aucune lecture SQLite sur le fil d'interface.
- Références D1 : `Domenia-Storage.UI.ps1:Update-DomeniaIndexLocation`, `Domenia-Cache.Model.ps1:Get-DomeniaDatabaseLocationSummary`, `Domenia-Cache.Model.ps1:Get-DomeniaElapsedText`, `LblIndexLocation`, `LblIndexBackupStatus`

#### PAR-014 · Copier le chemin de la base

> Reste à faire : Copie du chemin de la base. Simulation seulement (base fictive en mémoire, par le circuit d’écriture) ; en mode annuaire la base SQLite de Domenia 2 n’est pas encore branchée (Domenia.Store, vague 3) : settings.storeUnavailable.

`partiel` · locale (aucune lecture)

Copie dans le presse-papiers le chemin complet de la base du contexte actif.

- Garde-fous : Bouton actif seulement avec une base active ; « Aucune base active : aucun chemin à copier ».
- Références D1 : `BtnIndexCopyPath`, `Domenia-Storage.UI.ps1:Copy-DomeniaIndexLocationPath`

#### PAR-015 · Ouvrir l'emplacement de la base

> Reste à faire : Ouverture du dossier par l’Explorateur pour les données, journaux, préférences, reçus et profil ; « Ouvrir l’emplacement » de la base grisé avec sa raison tant que la base n’a pas de fichier (base fictive, mode annuaire de cette version).

`partiel` · locale (aucune lecture)

Ouvre l'Explorateur sur le dossier de la base, fichier sélectionné.

- Garde-fous : Refus si la base n'existe pas.
- Références D1 : `BtnIndexOpenFolder`, `Domenia-Storage.UI.ps1:Open-DomeniaIndexLocation`

### Base locale · assistant

#### PAR-016 · Déplacer la base locale

> Reste à faire : Assistant : destination choisie dans la page (dossiers proposés, explorateur des dossiers locaux, contrôle en direct du disque, du dossier, des liens et de la réserve), copie vérifiée, bascule et retour. L’exécution réelle (vidage de 120 s, test d’écriture réel, copie SQLite) attend Domenia.Store. Simulation seulement (base fictive en mémoire, par le circuit d’écriture) ; en mode annuaire la base SQLite de Domenia 2 n’est pas encore branchée (Domenia.Store, vague 3) : settings.storeUnavailable.

`partiel` · écriture

Assistant en étapes : suspension des nouvelles collectes, vidage de la file (120 s au plus), inspection en lecture seule de la source et de la destination (nouveau .db local, dossier existant, test d'écriture réel, réserve de deux fois la base plus 32 Mo), aperçu détaillé, confirmation « Copier, vérifier puis utiliser la nouvelle base », copie, vérification et bascule. L'original est gardé en lecture seule avec un marqueur.

- Garde-fous : Destination réseau refusée, aucun original écrasé, empreinte de l'aperçu revérifiée. Une copie non confirmée laisse la session sur la base courante, les deux fichiers gardés. Indisponible en démonstration.
- Opérations : `StorageMaintenance`
- Références D1 : `BtnStorageMove`, `Domenia-Storage.UI.ps1:Request-DomeniaStorageMaintenance`, `Domenia-Storage.UI.ps1:Start-DomeniaStorageMaintenanceInspect`, `Domenia-Storage.UI.ps1:Start-DomeniaStorageMaintenanceDrain`, `Domenia-Storage.UI.ps1:Invoke-DomeniaStorageMaintenanceDrainTick`, `Domenia-Storage.UI.ps1:Complete-DomeniaStorageMaintenancePreview`, `Domenia-Storage.UI.ps1:Start-DomeniaStorageMaintenanceApply`, `Domenia-Storage.UI.ps1:Complete-DomeniaStorageMaintenanceApply`, `Domenia-Storage.UI.ps1:Invoke-DomeniaStorageMaintenanceSwitch`, `Domenia-Storage.UI.ps1:Complete-DomeniaStorageMaintenanceSwitchConfirm`, `Domenia-Storage.UI.ps1:Fail-DomeniaStorageMaintenanceSwitch`, `Domenia-Storage.UI.ps1:Fail-DomeniaStorageMaintenanceSwitchConfirm`, `Domenia-Storage.UI.ps1:Fail-DomeniaStorageMaintenance`, `Domenia-Storage.UI.ps1:Get-DomeniaStorageMaintenanceMarkerPath`, `Domenia-Store.Model.ps1:Get-DomeniaStorageMaintenancePreview`, `Domenia-Store.Model.ps1:Get-DomeniaStorageCopyReserve`, `Domenia-Storage.Worker.ps1:Test-MaintWTarget`, `Domenia-Main.xaml:BtnStorageMove`

#### PAR-017 · Restaurer une sauvegarde

> Reste à faire : Restauration d’une sauvegarde du registre, d’une copie publiée ou d’un fichier .db choisi (dossier Backups proposé), aperçu du dernier lot, de la dernière mesure, du contenu et des écarts ; annexe des préférences réappliquée après la bascule vérifiée. Simulation seulement (base fictive en mémoire, par le circuit d’écriture) ; en mode annuaire la base SQLite de Domenia 2 n’est pas encore branchée (Domenia.Store, vague 3) : settings.storeUnavailable.

`partiel` · écriture

Choix d'une sauvegarde .db (dossier Backups proposé), puis restauration dans un nouveau fichier local. L'aperçu montre la date d'écriture, le dernier lot, la dernière mesure, le contenu et les écarts de volume avec la base active (objets, mesures, associations). La sauvegarde n'est jamais modifiée et la base active jamais écrasée ; les préférences jointes sont réappliquées après la bascule.

- Garde-fous : La sauvegarde doit passer le schéma, quick_check et l'identité du domaine. Une base active illisible reste en place, intacte et sans marqueur.
- Opérations : `StorageMaintenance`
- Références D1 : `BtnStorageRestore`, `Domenia-Storage.UI.ps1:Request-DomeniaStorageMaintenance`, `Domenia-Store.Model.ps1:Get-DomeniaStorageMaintenancePreview`, `Domenia-Store.Model.ps1:Format-DomeniaStorageContent`, `Domenia-Storage.Worker.ps1:Read-MaintWInfo`, `Domenia-Main.xaml:BtnStorageRestore`

#### PAR-018 · Reprendre une bascule interrompue

> Reste à faire : « Reprendre la bascule » termine le passage vers la copie désignée par le marqueur relu (scénario « Bascule interrompue »). Simulation seulement (base fictive en mémoire, par le circuit d’écriture) ; en mode annuaire la base SQLite de Domenia 2 n’est pas encore branchée (Domenia.Store, vague 3) : settings.storeUnavailable.

`partiel` · écriture

Si une bascule a été interrompue (marqueur présent), « Reprendre la bascule » termine le passage vers la copie vérifiée désignée par le marqueur.

- Garde-fous : Aucun fichier supprimé ; identité de la cible revérifiée.
- Opérations : `StorageMaintenance`
- Références D1 : `BtnStorageResume`, `Domenia-Storage.UI.ps1:Resume-DomeniaStorageMaintenance`, `Domenia-Storage.Worker.ps1:Get-DomeniaStorageMaintenanceWorkerCode`

#### PAR-019 · Revenir à la base précédente

> Reste à faire : Retour à la base précédente tant que la nouvelle n’a rien reçu, ou abandon d’une bascule interrompue. Simulation seulement (base fictive en mémoire, par le circuit d’écriture) ; en mode annuaire la base SQLite de Domenia 2 n’est pas encore branchée (Domenia.Store, vague 3) : settings.storeUnavailable.

`partiel` · écriture

Annule une bascule terminée dans la session (déplacement, restauration ou reprise), tant que la nouvelle base n'a reçu aucune écriture. Le worker retire le marqueur de l'original et la session y revient.

- Garde-fous : Refusé si quelque chose est en file ou en cours, ou si la nouvelle base a changé ; aucun fichier supprimé.
- Opérations : `StorageMaintenance`
- Références D1 : `BtnStorageRollback`, `Domenia-Storage.UI.ps1:Get-DomeniaStorageMaintenanceUndo`, `Domenia-Storage.UI.ps1:Start-DomeniaStorageMaintenanceUndo`, `Domenia-Main.xaml:BtnStorageRollback`

#### PAR-020 · État et texte de l'assistant de stockage

> Reste à faire : Quatre actions suivant l’état de la maintenance, chaque refus expliqué ; base illisible : restauration seule. Simulation seulement (base fictive en mémoire, par le circuit d’écriture) ; en mode annuaire la base SQLite de Domenia 2 n’est pas encore branchée (Domenia.Store, vague 3) : settings.storeUnavailable.

`partiel` · locale (aucune lecture)

Les quatre boutons (Déplacer, Restaurer, Reprendre, Revenir) suivent l'état de la maintenance, et LblStorageMaintenance l'explique : base locale par défaut, démonstration, aucune base, copie en attente, étape en cours, base illisible, bascule à terminer, retour possible. Une annulation à la confirmation ne copie rien et relance les collectes.

- Garde-fous : Une vidange ou une étape en cours bloque tout le reste.
- Références D1 : `LblStorageMaintenance`, `ExpStorageMaintenance`, `Domenia-Store.Model.ps1:Get-DomeniaStorageMaintenanceControlState`, `Domenia-Storage.UI.ps1:Update-DomeniaStorageMaintenanceControls`, `Domenia-Storage.UI.ps1:Stop-DomeniaStorageMaintenanceRequest`

#### PAR-021 · Base déclarée illisible : restauration seule

> Reste à faire : Base déclarée illisible : toute écriture refusée sauf la restauration d’une sauvegarde vérifiée (scénario « Base illisible », quick_check SQLITE_CORRUPT 11) ; la preuve réelle viendra de la base SQLite (vague 3). Simulation seulement (base fictive en mémoire, par le circuit d’écriture) ; en mode annuaire la base SQLite de Domenia 2 n’est pas encore branchée (Domenia.Store, vague 3) : settings.storeUnavailable.

`partiel` · lecture locale

Seule une corruption prouvée (SQLITE_CORRUPT 11, NOTADB 26, quick_check échoué) rend la base illisible ; un verrou, un schéma ou un domaine différent ne le font pas. La seule action proposée est alors la restauration d'une sauvegarde vérifiée, les collectes et les saisies restant refusées.

- Garde-fous : Aucune réparation automatique. Aucun déplacement automatique de données ; restauration sur décision explicite.
- Opérations : `StorageMaintenance`
- Références D1 : `Domenia-Store.Model.ps1:Test-DomeniaStorageUnreadableMessage`, `Domenia-Storage.Worker.ps1:Test-MaintWUnreadable`, `Domenia-Core.ps1:Initialize-Window`, `Domenia-Core.ps1:Recover-DomeniaDatabase`

### Base locale · conservation

#### PAR-022 · Réglages de conservation des mesures

`ameliore` · écriture

Âge maximal par famille, de 0 (sans limite) à 36 500 jours : présence ping (30), utilisateur connecté (90), inventaire (180), sondes WMI (90), détails (30), historique des associations (0, conservé en entier). Ils sont enregistrés dans Storage.PolicyJson avec les réglages de sauvegarde.

- Garde-fous : Enregistrer ne supprime rien : « La conservation ne s'applique qu'après prévisualisation et confirmation ». En cas d'échec, l'ancienne politique est rétablie.
- Références D1 : `TxtStoragePresenceDays`, `TxtStorageConsoleDays`, `TxtStorageInventoryDays`, `TxtStorageProbeDays`, `TxtStorageDetailDays`, `TxtStorageLinkHistoryDays`, `BtnStoragePolicySave`, `Domenia-Storage.UI.ps1:Save-DomeniaStoragePolicy`, `Domenia-Storage.UI.ps1:Get-DomeniaCurrentStoragePolicy`, `Domenia-Storage.UI.ps1:Initialize-DomeniaStoragePolicy`, `Domenia-Store.Model.ps1:ConvertTo-DomeniaStoragePolicy`

#### PAR-023 · Prévisualiser la conservation

> Reste à faire : Prévisualisation par famille, ce qui part et ce qui reste, empreinte exigée par le plan. Simulation seulement (base fictive en mémoire, par le circuit d’écriture) ; en mode annuaire la base SQLite de Domenia 2 n’est pas encore branchée (Domenia.Store, vague 3) : settings.storeUnavailable.

`partiel` · lecture locale

Simulation dans une transaction annulée : pour chaque famille, le nombre de mesures antérieures à la date limite, ce que les postes perdront (dernier état de présence, dernier utilisateur, dernier inventaire…) et ce qui est toujours gardé (objets AD, comptes, associations actuelles et déclarées, requêtes, journaux, reçus, dates illisibles, tentatives récentes).

- Garde-fous : Refusée si une maintenance est en attente ; anciens relevés non migrés comptés et gardés.
- Opérations : `StorageRetention`
- Références D1 : `BtnStorageRetentionPreview`, `LblStorageRetention`, `Domenia-Storage.UI.ps1:Start-DomeniaStorageRetention`, `Domenia-Store.Model.ps1:Get-DomeniaStorageRetentionFamilies`, `Domenia-Store.Model.ps1:Get-DomeniaStorageRetentionCutoffs`, `Domenia-Store.Model.ps1:Get-DomeniaStorageRetentionLines`, `Domenia-Storage.Worker.ps1:Get-DomeniaStorageRetentionWorkerCode`

#### PAR-024 · Appliquer la conservation

> Reste à faire : Conservation après sauvegarde vérifiée préalable, compaction de l’historique, relecture. Simulation seulement (base fictive en mémoire, par le circuit d’écriture) ; en mode annuaire la base SQLite de Domenia 2 n’est pas encore branchée (Domenia.Store, vague 3) : settings.storeUnavailable.

`partiel` · écriture

Après confirmation, une sauvegarde vérifiée préalable est faite (copie autonome, quick_check, identité de la base et révision contrôlées), puis les mesures trop anciennes sont retirées. L'historique des associations est compacté : seules les observations identiques répétées partent, chaque changement d'utilisateur et la première et dernière observation de chaque période restent. La place libérée est réutilisable mais le fichier ne rétrécit pas.

- Garde-fous : Confirmation en ligne, empreinte de la prévisualisation exigée (sinon « refaire la prévisualisation »), refus si des déclencheurs SQLite existent. Les associations déclarées ne sont jamais touchées ; une famille absente du comptage arrête tout.
- Opérations : `StorageRetention`
- Références D1 : `BtnStorageRetentionApply`, `Domenia-Storage.UI.ps1:Request-DomeniaStorageRetention`, `Domenia-Storage.UI.ps1:Complete-DomeniaStorageRetention`, `Domenia-Storage.UI.ps1:Fail-DomeniaStorageRetention`, `Domenia-Storage.Worker.ps1:Copy-RetentionWBackup`, `Domenia-Main.xaml:BtnStorageRetentionApply`

### Base locale · diagnostic

#### PAR-025 · Mesurer le stockage local

> Reste à faire : Mesure en lecture seule : fichier, journal WAL, total, catégories, lectures types (plans SQLite en Expert). Simulation seulement (base fictive en mémoire, par le circuit d’écriture) ; en mode annuaire la base SQLite de Domenia 2 n’est pas encore branchée (Domenia.Store, vague 3) : settings.storeUnavailable.

`partiel` · lecture locale

Mesure en lecture seule : taille de la base et de son journal WAL, lignes et octets par catégorie (octets par table si le module dbstat existe, sinon inconnus) et temps de lectures types sur cette base (page d'index par type, postes actifs triés, page de mesures, recherche de texte), avec le plan SQLite (index, tri en mémoire, parcours complet).

- Garde-fous : Base réseau ou redirigée refusée, aucune base créée, schéma 11/1 exigé ; une seule mesure ou purge à la fois ; indisponible en démonstration.
- Opérations : `StorageUsage`
- Références D1 : `BtnStorageUsage`, `LblStorageUsage`, `Domenia-Storage.UI.ps1:Start-DomeniaStorageUsage`, `Domenia-Storage.UI.ps1:Complete-DomeniaStorageUsage`, `Domenia-Storage.UI.ps1:Fail-DomeniaStorageUsage`, `Domenia-Storage.UI.ps1:Format-DomeniaStorageUsage`, `Domenia-Store.Model.ps1:Format-DomeniaStorageReadProbes`, `Domenia-Storage.Worker.ps1:Get-DomeniaStorageUsageWorkerCode`

#### PAR-026 · Contrôler l'intégrité de la base

> Reste à faire : Neuf contrôles, verdict, et en cas de défaut le bouton « Restaurer une sauvegarde… » dans la carte. Simulation seulement (base fictive en mémoire, par le circuit d’écriture) ; en mode annuaire la base SQLite de Domenia 2 n’est pas encore branchée (Domenia.Store, vague 3) : settings.storeUnavailable.

`partiel` · lecture locale

Neuf contrôles en lecture seule : ouverture, schéma, tables et colonnes, identité de la base, bascule en attente, reçus, références (clés étrangères), quick_check, journal SQLite. Verdict Sain, À surveiller, Incomplet ou Défaut, avec détail par contrôle ; en cas de défaut, renvoi vers « Restaurer une sauvegarde… ».

- Garde-fous : Aucune réparation ni écriture. Une base occupée arrête le contrôle (à relancer). Refusé pendant une purge, une maintenance ou une conservation.
- Opérations : `StorageIntegrity`
- Références D1 : `BtnStorageIntegrity`, `LblStorageIntegrity`, `Domenia-Storage.UI.ps1:Start-DomeniaStorageIntegrity`, `Domenia-Storage.UI.ps1:Complete-DomeniaStorageIntegrity`, `Domenia-Storage.UI.ps1:Fail-DomeniaStorageIntegrity`, `Domenia-Store.Model.ps1:Get-DomeniaStorageIntegrityVerdict`, `Domenia-Storage.Worker.ps1:Get-DomeniaStorageIntegrityWorkerCode`, `Domenia-Main.xaml:BtnStorageIntegrity`

#### PAR-027 · Limites déclarées du stockage local

`fait` · locale (aucune lecture)

Énonce les bornes : file d'écriture de 4096 changements ou 32 Mo, lots de 250 changements ou 4 Mo, 256 éléments en attente, recherches de 20 000 lignes, concurrence du moteur, seuils d'espace, conservation par famille, 10 000 mesures de performance, 400 jours d'instantanés du parc, cache de recherche (20 requêtes par périmètre) et nombre de sauvegardes. S'y ajoutent les trois collections les plus volumineuses à la dernière mesure.

- Garde-fous : Aucune promesse de stockage illimité ; ce qui n'est pas mesuré est dit non mesuré.
- Références D1 : `LblStorageLimits`, `Domenia-Storage.UI.ps1:Update-DomeniaStorageLimitsUi`, `Domenia-Store.Model.ps1:Get-DomeniaStorageLimitLines`

### Base locale · migration

#### PAR-028 · Reprendre les anciennes données

> Reste à faire : Reprise de la base de Domenia 1 (schéma 11, révision 1, même domaine, règle par partie), de ses réglages et des fichiers de l’ancienne version (objets.tsv, parc.tsv, recherches.tsv, secrets-etat.tsv, liens) avec les garde-fous de Domenia 1 (128 Mo, 250 000 lignes, lecture sous verrou, quatre tables vides, un seul domaine, doublons refusés), idempotente par marqueur, sauvegarde de migration avant. La lecture réelle des fichiers et de la base attend Domenia.Store. Simulation seulement (base fictive en mémoire, par le circuit d’écriture) ; en mode annuaire la base SQLite de Domenia 2 n’est pas encore branchée (Domenia.Store, vague 3) : settings.storeUnavailable.

`partiel` · écriture

Bouton « Reprendre les anciennes données » : simulation des anciens fichiers (objets.tsv, parc.tsv, recherches.tsv, secrets-etat.tsv, liens poste-utilisateur) affichée dans LblGuardMigration, confirmation « Oui, reprendre », sauvegarde de migration puis import par la file unique. Les quatre tables cibles doivent être vides, les associations existantes ne sont jamais remplacées et la reprise est idempotente.

- Garde-fous : Fichiers de 128 Mo et 250 000 lignes au plus, lus verrouillés (hash et lignes du même fichier). Un seul domaine, identique au contexte ; doublons refusés. Empreinte de simulation exigée ; refus si des liens sont en attente ou sous maintenance ; jamais rejoué automatiquement ; la colonne de détail libre n'est jamais importée. Simulation avant confirmation ; domaine vérifié.
- Opérations : `LegacyMigration`, `LocalStore`
- Références D1 : `BtnGuardLegacyImport`, `LblGuardMigration`, `Domenia-Migration.UI.ps1:Read-DomeniaLegacySource`, `Domenia-Migration.UI.ps1:Get-DomeniaLegacySnapshot`, `Domenia-Migration.UI.ps1:New-DomeniaLegacyImportPlan`, `Domenia-Migration.UI.ps1:Invoke-DomeniaLegacyImport`, `Domenia-Migration.UI.ps1:Show-DomeniaLegacyImportPlan`, `Domenia-Migration.UI.ps1:Request-DomeniaLegacyImport`, `Domenia-Migration.UI.ps1:Start-DomeniaLegacyImportWork`, `Domenia-Migration.UI.ps1:Complete-DomeniaLegacyImportWork`, `Domenia-Migration.UI.ps1:Fail-DomeniaLegacyImportWork`, `Domenia-Migration.Worker.ps1:Get-DomeniaMigrationWorkerCode`, `Domenia-Storage.Worker.ps1:Import-DomeniaLegacy`, `Request-DomeniaLegacyImport (Core)`

### Base locale · politique des données

#### PAR-029 · Politique des données locales

`ameliore` · locale (aucune lecture)

Tableau en lecture seule, une ligne par type de donnée gardée sur le poste (index de l'annuaire, relevés de l'annuaire, horloges de collecte, présence, utilisateur connecté, inventaire, sondes, détails, associations, bibliothèque de requêtes, instantanés, sauvegardes, journaux, exports CSV, dossiers hors ligne, diagnostics, anciennes données, reçus, préférences, comptes mémorisés) : contenu, emplacement, durée, export et suppression. S'y ajoute l'engagement : aucune donnée envoyée hors du poste, ni télémétrie ni service en ligne.

- Garde-fous : Un dossier inconnu est dit non déterminé, jamais inventé ; des réglages illisibles donnent une durée inconnue, jamais une valeur par défaut. Rafraîchi à l'ouverture et après chaque enregistrement.
- Références D1 : `ExpStorageDataPolicy`, `DgStorageDataPolicy`, `LblStorageDataPolicy`, `Domenia-DataPolicy.UI.ps1:Update-DomeniaDataPolicyView`, `Domenia-DataPolicy.UI.ps1:Initialize-DomeniaDataPolicyView`, `Domenia-DataPolicy.Model.ps1:Get-DomeniaLocalDataPolicy`, `Domenia-DataPolicy.Model.ps1:Get-DomeniaDataRetentionText`, `Domenia-Main.xaml:DgStorageDataPolicy`

#### PAR-030 · Catalogue du cache par périmètre (règle non raccordée)

> Reste à faire : Catalogue du cache par périmètre (source, contrôleur, compte, objets, âge, usage permis). Simulation seulement (base fictive en mémoire, par le circuit d’écriture) ; en mode annuaire la base SQLite de Domenia 2 n’est pas encore branchée (Domenia.Store, vague 3) : settings.storeUnavailable.

`partiel` · locale (aucune lecture)

Produit une ligne lisible par périmètre conservé en cache : périmètre, source, contrôleur, compte lecteur, nombre d'objets, date et âge de l'observation, et l'usage permis (« Consultation historique. Aucune modification sans relecture AD. »). Règle écrite, sans appelant dans l'interface de Domenia 1.

- Garde-fous : Lecture seule ; date absente affichée « inconnu », jamais inventée.
- Références D1 : `Domenia-Cache.Model.ps1:Get-DomeniaCacheCatalogRows`

### Base locale · purge

#### PAR-031 · Simuler puis purger des données locales

> Reste à faire : Purge par catégories fermées, lignes comptées pour chaque table, simulation exigée, nom du domaine saisi, sauvegarde vérifiée avant. Simulation seulement (base fictive en mémoire, par le circuit d’écriture) ; en mode annuaire la base SQLite de Domenia 2 n’est pas encore branchée (Domenia.Store, vague 3) : settings.storeUnavailable.

`partiel` · écriture

Purge volontaire par catégories fermées : toutes les observations et relevés du parc, tous les instantanés de recherche, tout l'index local de l'annuaire (objets, faits, relevés et horloges d'annuaire ; le point de reprise du domaine est réinitialisé), ou l'historique plus ancien que N jours (730 par défaut, de 1 à 36 500). La simulation compte les lignes par table ; la purge exige une confirmation et la même empreinte. Les vues concernées sont ensuite invalidées.

- Garde-fous : Aucun SQL fourni par l'interface ; tables autorisées en double liste. Refus si un travail, un relevé de postes ou un enregistrement est en cours, en démonstration, ou si des déclencheurs SQLite existent ; « Refaites la simulation » si les comptes ont changé.
- Opérations : `StoragePurge`
- Références D1 : `ChkStoragePurgeObservations`, `ChkStoragePurgeSnapshots`, `ChkStoragePurgeIndex`, `ChkStoragePurgeHistory`, `TxtStorageHistoryDays`, `BtnStoragePurgePreview`, `BtnStoragePurge`, `LblStoragePurge`, `Domenia-Storage.UI.ps1:Get-DomeniaStoragePurgeChoice`, `Domenia-Storage.UI.ps1:Reset-DomeniaStoragePurgePreview`, `Domenia-Storage.UI.ps1:Assert-DomeniaStoragePurgeReady`, `Domenia-Storage.UI.ps1:Format-DomeniaStoragePurge`, `Domenia-Storage.UI.ps1:Start-DomeniaStoragePurge`, `Domenia-Storage.UI.ps1:Request-DomeniaStoragePurge`, `Domenia-Storage.UI.ps1:Complete-DomeniaStoragePurge`, `Domenia-Storage.UI.ps1:Fail-DomeniaStoragePurge`, `Domenia-Cache.Model.ps1:Get-DomeniaPurgePlan`, `Domenia-Cache.Model.ps1:Get-DomeniaPurgeTargets`, `Domenia-Storage.Worker.ps1:Get-DomeniaStoragePurgeWorkerCode`, `Domenia-Main.xaml:BtnStoragePurge`

#### PAR-032 · Ce qu'une purge ne touche jamais

`fait` · locale (aucune lecture)

Le journal d'audit, la configuration et les préférences, les associations déclarées et leur historique, et les reçus d'opérations ne sont jamais purgeables. La purge de l'historique garde l'historique complet d'un poste dont l'association actuelle est déclarée. Les métadonnées BitLocker et LAPS (secret_state) ne sont jamais une cible de l'index.

- Garde-fous : Le plan prouve KeepsUnresolvedReceipts, KeepsConfiguration et KeepsManualLinks.
- Opérations : `StoragePurge`
- Références D1 : `Domenia-Cache.Model.ps1:Get-DomeniaRetentionPolicy`, `Domenia-Cache.Model.ps1:Get-DomeniaPurgeTargets`, `Domenia-Cache.Model.ps1:Get-DomeniaPurgePlan`, `Domenia-Cache.Model.ps1:Format-DomeniaSize`

### Base locale · sauvegardes

#### PAR-033 · Sauvegarder maintenant

> Reste à faire : Copie vérifiée (quick_check, SHA-256, date de vérification) relue par son nom, rotation. Simulation seulement (base fictive en mémoire, par le circuit d’écriture) ; en mode annuaire la base SQLite de Domenia 2 n’est pas encore branchée (Domenia.Store, vague 3) : settings.storeUnavailable.

`partiel` · écriture

Copie à chaud cohérente par l'API de sauvegarde SQLite dans le worker StorageBackup, budget LocalStore.BackupTimeoutSeconds (30 s). La copie publiée est autonome (journal en mode delete), passe quick_check et reçoit son SHA-256. Elle est rangée dans Backups\Domenia-\*.db avec rotation (« Copies à conserver ») et joint les préférences approuvées.

- Garde-fous : Original ouvert en lecture seule et jamais modifié, copie partielle supprimée en cas d'échec. Un reçu sans fichier, quick_check, SHA-256 et date de vérification compte comme un échec. Original intact en cas d'interruption ; fichiers partiels supprimés ; sauvegardes de migration jamais purgées.
- Opérations : `StorageBackup`
- Références D1 : `BtnIndexBackup`, `Domenia-Storage.UI.ps1:Invoke-DomeniaIndexBackup`, `Domenia-Storage.UI.ps1:New-DomeniaBackupPayload`, `Domenia-Storage.UI.ps1:Complete-DomeniaIndexBackupUi`, `Domenia-Storage.UI.ps1:Fail-DomeniaIndexBackupUi`, `Domenia-Storage.UI.ps1:Register-DomeniaVerifiedBackup`, `Domenia-Storage.UI.ps1:Register-DomeniaBackupFailure`, `Domenia-Store.Model.ps1:Test-DomeniaBackupReceiptVerified`, `Domenia-Storage.Worker.ps1:Get-DomeniaStorageBackupWorkerCode`, `Domenia-Core.ps1:Backup-DomeniaDatabase`, `Domenia-Main.xaml:BtnIndexBackup`

#### PAR-034 · Préférences jointes aux sauvegardes

> Reste à faire : Annexe Domenia.BackupPreferences.1 des préférences approuvées jointe à chaque sauvegarde (même vide), liée au SHA-256 de la copie, exigée par la relecture, réappliquée après une restauration vérifiée (reçu à l’appui), sans identité de connexion ni fenêtre de ce poste. Simulation seulement (base fictive en mémoire, par le circuit d’écriture) ; en mode annuaire la base SQLite de Domenia 2 n’est pas encore branchée (Domenia.Store, vague 3) : settings.storeUnavailable.

`partiel` · écriture

Les sauvegardes faites depuis l'interface emportent un instantané des préférences approuvées (choix de requêtes, dispositions) au format Domenia.BackupPreferences.1, lié au SHA-256 de la base. Les chemins de base, les reçus de sauvegarde et les noms de comptes distants ou secrets en sont exclus. À la restauration, elles ne sont réappliquées qu'après la bascule vérifiée.

- Garde-fous : 4 Mo et 8 niveaux JSON au plus ; sans annexe autonome, la copie est refusée. Si l'enregistrement échoue, les préférences précédentes sont rétablies et une copie .bak gardée.
- Opérations : `StorageBackup`, `StorageMaintenance`
- Références D1 : `Domenia-Storage.UI.ps1:Get-DomeniaBackupPreferencesJson`, `Domenia-Storage.UI.ps1:Restore-DomeniaBackupPreferences`, `Domenia-Storage.Worker.ps1:Write-WBackupPreferences`, `Domenia-Storage.Worker.ps1:Read-MaintWPreferences`

#### PAR-035 · Copier une sauvegarde vers un fichier choisi

> Reste à faire : Sauvegarde vérifiée publiée vers un fichier choisi dans la page, nom proposé Domenia-AAAAMMJJ-HHmm.db, copie locale gardée si la publication échoue. Simulation seulement (base fictive en mémoire, par le circuit d’écriture) ; en mode annuaire la base SQLite de Domenia 2 n’est pas encore branchée (Domenia.Store, vague 3) : settings.storeUnavailable.

`partiel` · écriture

Fait une sauvegarde vérifiée puis la publie atomiquement vers un fichier .db choisi (nom proposé Domenia-AAAAMMJJ-HHmm.db). Si l'export échoue, la sauvegarde locale vérifiée reste disponible.

- Garde-fous : Refus de la base active et de ses journaux comme destination, des liens ou jonctions et d'un dossier absent ; interdit pour une copie avant geste.
- Opérations : `StorageBackup`
- Références D1 : `BtnIndexBackupTo`, `Domenia-Storage.UI.ps1:Invoke-DomeniaIndexBackup`, `Domenia-Storage.UI.ps1:Assert-DomeniaBackupDestination`, `Domenia-Storage.Worker.ps1:Get-WBackupSafePath`, `Domenia-Main.xaml:BtnIndexBackupTo`

#### PAR-036 · Sauvegarde automatique planifiée

> Reste à faire : Réglage, échéance et raison du report affichés ; contrôle chaque minute dans une session persistante, différé pendant un enregistrement, 15 min entre deux essais, arrêté par une date future ; chaque copie planifiée passe par le circuit avec son reçu. Simulation seulement (base fictive en mémoire, par le circuit d’écriture) ; en mode annuaire la base SQLite de Domenia 2 n’est pas encore branchée (Domenia.Store, vague 3) : settings.storeUnavailable.

`partiel` · écriture

Case « Sauvegarder automatiquement pendant que Domenia est ouvert », intervalle de 1 à 720 h (24 par défaut), 2 à 30 copies conservées (7). Le contrôle a lieu chaque minute. La copie est différée tant qu'une opération ou un enregistrement local est en cours, 15 min séparent deux essais et une date future arrête la planification. LblStorageBackupSchedule donne la prochaine échéance, la dernière sauvegarde vérifiée (taille, début du SHA-256) et le dernier échec de la session.

- Garde-fous : Désactivée par défaut. L'absence de changement n'est jamais déduite d'un indicateur partiel, et tout succès passe par le reçu vérifié.
- Opérations : `StorageBackup`
- Références D1 : `ChkStorageAutoBackup`, `TxtStorageBackupHours`, `TxtStorageBackupKeep`, `LblStorageBackupSchedule`, `Domenia-Store.Model.ps1:Get-DomeniaStorageBackupDecision`, `Domenia-Store.Model.ps1:Get-DomeniaStorageBackupSchedule`, `Domenia-Storage.UI.ps1:Invoke-DomeniaScheduledBackup`, `Domenia-Storage.UI.ps1:Test-DomeniaStorageBackupBusy`, `Domenia-Storage.UI.ps1:Update-DomeniaStorageBackupScheduleUi`, `Domenia-Storage.UI.ps1:Get-DomeniaStorageBackupKey`, `Domenia-Main.xaml:ChkStorageAutoBackup`

### Collecte

#### PAR-037 · Plafond des widgets

> Reste à faire : Plafond des widgets, essais WMI et premier délai réglables, bornés et enregistrés (settings.collection) ; les relevés de l’Accueil et des postes doivent les lire au début de chaque relevé (CollectionSettingsRules.Read), non raccordé hors de Paramètres.

`partiel` · écriture

Réglages « Plafond des widgets » (0 = aucun), « Nouveaux essais WMI » (0 à 4, défaut 2) et « Premier délai » (10 à 120 s, défaut 30, puis ×4 jusqu'à 5 min).

- Garde-fous : La confirmation au-delà de 200 postes reste active même sans plafond. Lus au début de chaque relevé ; affichage sans réécriture.
- Références D1 : `CmbCollectionWidgetMax`, `Domenia-Park.UI.ps1:Get-DomeniaWidgetMaxTargets`, `Domenia-WidgetCollect.Model.ps1:Get-DomeniaWidgetCollectAdmission`, `Domenia-Park.UI.ps1:Initialize-DomeniaCollectionLimitsUi`, `Domenia-Park.UI.ps1:Update-DomeniaCollectionLimitsUi`, `Domenia-Park.UI.ps1:Get-DomeniaCollectionRetrySettings`, `CmbCollectionWmiRetries`, `CmbCollectionWmiRetryDelay`, `Domenia-Main.xaml:CmbCollectionWidgetMax`

#### PAR-038 · Profil de collecte

> Reste à faire : Trois profils de Domenia 1 avec leurs durées et leur fenêtre, enregistrés ; la collecte des autres écrans doit lire le profil actif (non raccordé hors de Paramètres).

`partiel` · locale (aucune lecture)

Trois profils : Standard, Réseau lent ou site distant (heures creuses par défaut), Dépannage en direct, chacun avec ses durées de réutilisation des mesures.

- Garde-fous : Identifiant inconnu → Standard.
- Références D1 : `Domenia-Collection.Model.ps1:Get-DomeniaCollectionProfiles`, `Domenia-Collection.Model.ps1:Get-DomeniaCollectionProfile`, `Domenia-Collection.UI.ps1:Get-DomeniaCollectionProfileId`, `Domenia-Collection.UI.ps1:Initialize-DomeniaCollectionSettingsUi`, `CmbCollectionProfile`, `LblCollectionProfile`, `Domenia-Query.UI.ps1:Initialize-DomeniaQueryWorkshop`

#### PAR-039 · Durées de fraîcheur par famille

> Reste à faire : Durées par famille et par profil, bornées de 0 à 7 jours, retour aux durées du profil ; à lire par la collecte des autres écrans pour réutiliser les mesures (non raccordé).

`partiel` · locale (aucune lecture)

Durée de réutilisation de la présence, de l'utilisateur console, des attributs AD, de l'inventaire léger, des sondes stables et variables, modifiable par profil, avec retour aux durées du profil.

- Garde-fous : Bornes 0 à 7 jours par famille ; valeur invalide écartée et signalée ; seules les familles réellement appliquées sont proposées.
- Références D1 : `Domenia-Collection.Model.ps1:Get-DomeniaFreshnessFamilies`, `Domenia-Collection.Model.ps1:Get-DomeniaFreshnessDurationChoices`, `Domenia-Collection.Model.ps1:Format-DomeniaCollectionDuration`, `Domenia-Collection.Model.ps1:ConvertFrom-DomeniaFreshnessOverrides`, `Domenia-Collection.Model.ps1:ConvertTo-DomeniaFreshnessOverridesText`, `Domenia-Collection.Model.ps1:Resolve-DomeniaFreshnessTable`, `Domenia-Collection.UI.ps1:Get-DomeniaActiveFreshnessTable`, `Domenia-Collection.UI.ps1:Set-DomeniaFreshnessOverride`, `Domenia-Collection.UI.ps1:Get-DomeniaProfileSetting`, `Domenia-Collection.UI.ps1:Set-DomeniaProfileSetting`, `DgCollectionFreshness`, `CmbCollectionFreshnessValue`, `BtnCollectionFreshnessReset`

#### PAR-040 · Fenêtre de collecte

> Reste à faire : Fenêtre analysée en direct (jetons fautifs nommés), état et prochain changement, éditeur graphique de la semaine aligné sur son échelle ; les travaux de fond des autres écrans doivent la respecter (non raccordé hors de Paramètres).

`partiel` · locale (aucune lecture)

Syntaxe « lun-ven 07:30-12:00 13:30-18:00; sam », « toujours » ou « jamais » ; les travaux de fond (réconciliation, changements d'objets, parc, index) ne lisent le réseau que fenêtre ouverte, avec phrase d'état et prochain changement.

- Garde-fous : Enregistrée seulement si elle s'analyse ; fenêtre invalide = travaux de fond suspendus ; une campagne explicite reste possible avec mention dans sa confirmation.
- Références D1 : `Domenia-Collection.Model.ps1:ConvertFrom-DomeniaCollectionWindowText`, `Domenia-Collection.Model.ps1:Test-DomeniaCollectionWindowRule`, `Domenia-Collection.Model.ps1:Test-DomeniaCollectionWindowOpen`, `Domenia-Collection.Model.ps1:Format-DomeniaCollectionWindowState`, `Domenia-Collection.Model.ps1:Test-DomeniaCollectionWindowAllows`, `Domenia-Collection.Model.ps1:Get-DomeniaCollectionWindowSources`, `Domenia-Collection.UI.ps1:Set-DomeniaCollectionWindowText`, `Domenia-Collection.UI.ps1:Test-DomeniaCollectionWindowAllowsSource`, `Domenia-Collection.UI.ps1:Get-DomeniaCollectionWindowStatusText`, `Domenia-Collection.UI.ps1:Get-DomeniaCollectionWindowCampaignNote`, `TxtCollectionWindow`, `BtnCollectionWindowApply`, `LblCollectionWindow`

#### PAR-041 · Parallélisme, réutilisation et plafond des relevés

> Reste à faire : Parallélisme (1 à 8), réutilisation (0 à 1 440 min) et plafond de cibles (1 à 20 000) enregistrés ; à appliquer par les relevés des autres écrans (non raccordé).

`partiel` · locale (aucune lecture)

Postes lus en même temps (Collection.Concurrency 1 à 8, défaut 4), réutilisation des mesures fraîches (Collection.CacheMinutes 0 à 1 440, défaut 15), plafond d'un relevé de liste (Park.MaxTargets, défaut 500).

- Garde-fous : La durée retenue est la plus courte entre profil et réutilisation ; 0 force la relecture.
- Références D1 : `CmbCollectionConcurrency`, `CmbCollectionCache`, `Domenia-Park.UI.ps1:Get-DomeniaParkMaxTargets`, `Domenia-Park.Model.ps1:New-DomeniaCollectionPlan`

### Configuration

#### PAR-042 · Configuration livrée et réglages avancés

`ameliore` · lecture locale

Domenia.config.json livre Auth.LoginWindowMode=Standard, Streaming.VerifyUserOnSelection=true et Streaming.AutoDetectLoggedUser=false. Les modules lisent aussi Async (MaxThreads 6, MaxOutstandingWorkers 12, MaxQueued 32, ReservedForeground 2, MaxQueueWaitSeconds 120, TickBudgetMs 25, BackgroundAgingSeconds 30, TreeTimeoutSeconds 30), LocalStore (DatabaseBusyTimeoutMs 2500, BackupTimeoutSeconds 30, DatabaseBackupCount 7) et Streaming (RevalidateListedObjects=false, RevalidateIntervalSeconds 60), chaque valeur bornée.

- Garde-fous : Valeurs bornées (ex. MaxThreads 1..32, MaxQueued 0..256, busy timeout 100..5000 ms). Problème de lecture tracé et montré au démarrage.
- Références D1 : `Domenia.config.json`, `Domenia-Engine.UI.ps1:Get-DomeniaEngineLimits`, `Domenia-Cache.Model.ps1:Get-DomeniaSqliteBusyTimeoutMs`, `Domenia-Continuity.UI.ps1:Test-DomeniaListRevalidationEnabled`, `Domenia-Core.ps1:New-DefaultConfig`, `Domenia-Core.ps1:Load-AppConfig`, `Domenia-Core.ps1:Get-CfgValue`

#### PAR-043 · Commutateurs de fonctionnalités

> Reste à faire : Commutateurs Features.* lus, bornés et montrés avec leur défaut, leur provenance et leur usage ; les comportements qu’ils commandent ne sont pas encore portés en Domenia 2.

`partiel` · locale (aucune lecture)

Features.\* active ou désactive des comportements de remplacement : ordonnanceur, politique d'inactivité, sélection d'une clé BitLocker, copie unique de secret, verrous ciblés, syntaxe et classement de recherche, profils de colonnes, confirmation en page ; lectures isolées, Wake-on-LAN, assistant local et trace de lecture sont désactivés par défaut.

- Garde-fous : Une valeur illisible garde le défaut. Nouvelles fonctions intrusives désactivées par défaut.
- Opérations : `IsolatedRead`, `WakeOnLanSend`, `LocalAssistant`
- Références D1 : `Domenia-Common.Model.ps1:Get-DomeniaFeatureFlag`, `Domenia-Engine.UI.ps1:Test-DomeniaSchedulerEnabled`, `Domenia-Engine.UI.ps1:Test-DomeniaIdlePolicyEnabled`, `Domenia-Core.ps1:New-DefaultConfig (Features)`

#### PAR-044 · Politique centrale des éléments d'interface

> Reste à faire : GuiElementPolicy lue, validée et appliquée aux contrôles de Paramètres qui ont un équivalent dans Domenia 1 (Disabled grise avec sa raison, Hidden masque, Default n’active rien) ; les autres écrans l’appliqueront à leurs contrôles (convention partagée à porter dans le kit).

`partiel` · locale (aucune lecture)

Table GuiElementPolicy indexée par x:Name (Default, Disabled, Hidden) appliquée à la fenêtre et au login : un administrateur peut griser ou masquer un contrôle sans toucher au code ; Visible ne force jamais l'activation.

- Garde-fous : Les droits AD et la lecture seule restent prioritaires ; valeur inconnue journalisée.
- Références D1 : `Domenia-Core.ps1:$script:GuiElementPolicy`, `Domenia-Core.ps1:Apply-DomeniaGuiElementPolicy`

#### PAR-045 · Réglages de sécurité configurables

> Reste à faire : Réglages de sécurité lus, bornés et montrés (provenance, bornes, usage) ; BlockProtectedObjects et la confirmation saisie s’appliquent, les autres seront lus par les écrans de secrets et de mots de passe quand ils seront portés.

`partiel` · locale (aucune lecture)

Security.\* : droits évalués à l'ouverture, contrôles refusés grisés, durée en mémoire des secrets (300 s), effacement du presse-papiers (30 s), changement de mot de passe imposé, longueur du mot de passe généré (16), retour en lecture seule (15 min), objets protégés bloqués, suppression de conteneur interdite, écriture d'attribut brut interdite, confirmations saisies, canal d'écriture unique, jamais de persistance LAPS/BitLocker.

- Garde-fous : Valeurs prudentes par défaut.
- Références D1 : `Domenia-Core.ps1:New-DefaultConfig (Security)`

#### PAR-046 · Réglages réseau, accès distant et budgets

> Reste à faire : Réglages réseau, accès distant et budgets lus, bornés et montrés ; appliqués par les lectures réseau de la vague 3.

`partiel` · locale (aucune lecture)

Remote.\* (PortTimeoutMs 1200, WinRM, CIM, registre distant, partage profils, journal Sécurité, replis tâche/PsExec, artefacts distants), Async.\* (2 à 6 threads, file 32, 2 places réservées, timeouts recherche 120 s, objet 35 s, distant 45 s, écriture 90/300 s), Cache.\*, Browser.\*, Index.\*, LocalStore.\*, UserMachineLink.\*.

- Garde-fous : Bornes appliquées à la lecture (clamp) dans les fonctions consommatrices.
- Références D1 : `Domenia-Core.ps1:New-DefaultConfig`

### Périmètres par défaut

#### PAR-047 · OU racine du domaine

`fait` · écriture

Choisit l'OU de travail du domaine (avec ou sans sous-OU), défaut du tableau de bord, de Rechercher, de l'explorateur d'OU et des périmètres sans choix propre ; Revenir au domaine la retire ; libellé du choix courant.

- Garde-fous : Préférence Directory.RootOu.&lt;hex> par domaine ; OU= du domaine courant seulement ; aucune lecture d'annuaire ni ping ; connexion requise.
- Références D1 : `Domenia-Dashboard.UI.ps1:Show-DomeniaRootOuSource`, `Domenia-Dashboard.UI.ps1:Save-DomeniaRootOuChoice`, `Domenia-Dashboard.UI.ps1:Clear-DomeniaRootOuChoice`, `Domenia-Dashboard.UI.ps1:Get-DomeniaRootOuChoice`, `Domenia-Dashboard.UI.ps1:Update-DomeniaRootOuTools`, `BtnRootOuChoose`, `BtnRootOuReset`, `LblRootOuChoice`, `Domenia-Main.xaml:BtnRootOuChoose`

#### PAR-048 · Propagation de l'OU racine aux sections

> Reste à faire : OU de travail mémorisée par domaine (session.setScope), suivie par l’Accueil ; les sections qui la prennent par défaut sont listées. Le remplacement confirmé (Remplacer / Conserver) d’une OU propre plus étroite viendra quand une section aura sa propre OU.

`partiel` · écriture

Les sections qui suivaient l'ancienne racine (tableau de bord, Rechercher, base autonome) suivent la nouvelle ; celles qui ont une OU plus étroite sont listées et remplacées seulement après confirmation dans la page (Remplacer / Conserver).

- Garde-fous : Sans page de confirmation disponible, l'OU étroite est conservée (jamais de boîte de dialogue) ; signet de recherche réécrit sans déplier ni chercher.
- Références D1 : `Domenia-Dashboard.UI.ps1:Publish-DomeniaRootOuChoice`, `Domenia-Dashboard.UI.ps1:Invoke-DomeniaRootOuNarrowedReplace`, `Domenia-Dashboard.UI.ps1:Test-DomeniaSectionFollowsRoot`, `Domenia-Dashboard.UI.ps1:Set-DomeniaSectionWorkingOu`, `Domenia-Dashboard.UI.ps1:Clear-DomeniaSectionFollow`, `Domenia-Dashboard.UI.ps1:Update-DomeniaSearchBookmarkDn`

### Préférences

#### PAR-049 · Préférences de connexion HKCU

> Reste à faire : « Se souvenir de mon identifiant » (décoché par défaut, jamais de mot de passe) et « Oublier » faits, refusés en simulation ; le dernier identifiant et le compte du coffre seront écrits par la connexion explicite (vague 3), dans les préférences de Domenia 2 et non plus HKCU.

`partiel` · locale (aucune lecture)

Mémorise dans HKCU\Software\DOMENIA le choix « se souvenir de mon identifiant », le dernier identifiant et l'identité du coffre (domaine, compte) ; jamais de mot de passe.

- Garde-fous : Rien n'est mémorisé en démonstration ; RememberLogin décoché par défaut.
- Références D1 : `Domenia-Core.ps1:Load-AppConfig`, `Domenia-Core.ps1:Save-AppConfig`

#### PAR-050 · Préférences utilisateur persistées

`ameliore` · lecture locale

Domenia.settings.json garde favoris d'OU, mises en page de grilles et colonnes, état du menu et de l'aide, journal (hauteur, police, retour ligne), densité, 8 récents, thème, profil, type et limite de recherche, portées logiciels, limite WMI, zoom, géométrie, noms des comptes secondaires, tableaux de bord, widgets, bibliothèque de requêtes, réglages de collecte, avis Accueil, vérification au clic.

- Garde-fous : La lecture seule et les filtres de présence/type ne sont jamais restaurés ; anciens fichiers en lecture seule seulement ; aucun secret.
- Références D1 : `Domenia-Core.ps1:Get-DomeniaDefaultSettings`, `Domenia-Core.ps1:Load-DomeniaSettings`, `Domenia-Core.ps1:Save-DomeniaSettings`, `Domenia-Core.ps1:Get-DomeniaPreferencePath`, `Domenia-Core.ps1:Read-DomeniaPreference`, `Domenia-Core.ps1:Write-DomeniaPreference`, `Domenia-Core.ps1:Register-DomeniaSettingsWatchers`

#### PAR-051 · Restauration de l'interface et de la géométrie

`ameliore` · locale (aucune lecture)

Réapplique les réglages aux contrôles sans déclencher de recherche ni de collecte, et restaure taille, position et état maximisé en ramenant la fenêtre sur l'écran si un moniteur a disparu.

- Garde-fous : Événements neutralisés pendant la restauration (RestoringSettings).
- Références D1 : `Domenia-Core.ps1:Restore-DomeniaUiSettings`, `Domenia-Core.ps1:Restore-DomeniaWindowGeometry`, `Domenia-Core.ps1:Save-DomeniaWindowGeometry`, `Domenia-Core.ps1:Set-DomeniaComboByContent`

<a id="trv"></a>

## Transverse : moteur, sécurité, stockage, interface commune (TRV)

316 fonctions : 66 faites, 21 améliorées, 5 partielles, 224 à faire.

### Accessibilité

#### TRV-001 · Contraste élevé Windows

`fait` · locale (aucune lecture)

Avec un thème Windows à contraste élevé, chaque jeton de la palette prend la couleur système de son rôle (Window, WindowText, Highlight…). Le passage d'un thème contrasté à un autre (Noir vers Blanc) est détecté par la signature des couleurs système. Catégories et états se lisent alors par leurs mots et symboles.

- Garde-fous : Une couleur de rôle manquante ou invalide laisse la couleur d'origine : rien n'est deviné.
- Références D1 : `Domenia-Experience.Model.ps1:Get-DomeniaHighContrastRoles`, `Domenia-Experience.Model.ps1:ConvertTo-DomeniaHighContrastPalette`, `Domenia-UX.UI.ps1:Get-DomeniaSystemColorTable`, `Domenia-UX.UI.ps1:Get-DomeniaSystemColorSignature`, `Domenia-UX.UI.ps1:Set-DomeniaUxPalette`

#### TRV-002 · Annonces au lecteur d'écran

`fait` · locale (aucune lecture)

Régions dites polies : titre de page, dernière ligne du journal (avertissements et erreurs), état de l'interrupteur d'écriture, badge de session, état vide de la liste, état du panneau des opérations. Le changement est annoncé une seule fois, et seulement si un client d'accessibilité écoute.

- Garde-fous : Un texte inchangé n'est pas réannoncé.
- Références D1 : `Domenia-UX.UI.ps1:Send-DomeniaUxLiveChange`, `Domenia-UX.UI.ps1:Set-DomeniaLiveText`

#### TRV-003 · Noms accessibles des contrôles dynamiques

`ameliore` · locale (aucune lecture)

Puces, pastilles, fil d'Ariane, menus de colonnes, onglets Schéma et Contrôles, étoiles de favoris reçoivent nom, aide et statut d'automatisation (« Menu ouvert », « Favori »).

- Références D1 : `Domenia-Search.UI.ps1:Update-DomeniaSearchBarUi`, `Domenia-SearchWorkspace.UI.ps1:Update-DomeniaSearchFilterChips`, `Domenia-DirectoryTree.UI.ps1:New-DomeniaDirectoryTreeContainerStyle`

### Aide et explications

#### TRV-004 · Catalogue d'aide des contrôles

`ameliore` · locale (aucune lecture)

Le catalogue JSON compte 820 entrées (Name, Title, Text, Kind, Source, Shortcut, Sensitive) et sert de source unique des infobulles, des noms d'accessibilité, des textes d'aide et du panneau d'aide au survol ou au focus clavier. L'infobulle dépend du rôle : aucune sur un conteneur, première phrase pour un bouton icône, texte entier sinon. Elle reste visible désactivée, avec délais 350/100 ms et durée 20 s. Les motifs de sécurité de l'infobulle existante sont conservés en complément.

- Garde-fous : L'aide ne reflète jamais une valeur de contrôle (Text, Password, SelectedItem…). Un contrôle inconnu reçoit un texte neutre. Le catalogue est rejeté s'il est incomplet ou contient un doublon. La fenêtre de connexion n'envoie rien au panneau principal. Les gestionnaires sont partagés (performance au démarrage). Libellés statiques uniquement.
- Références D1 : `Domenia-UX.help.json`, `Domenia-UX.UI.ps1:Import-DomeniaUxHelpCatalogue`, `Domenia-UX.UI.ps1:Get-DomeniaUxHelpEntry`, `Domenia-UX.UI.ps1:Get-DomeniaUxControlHelpText`, `Domenia-UX.UI.ps1:Show-DomeniaUxControlHelp`, `Domenia-UX.UI.ps1:Get-DomeniaUxHelpRole`, `Domenia-UX.UI.ps1:Set-DomeniaUxCatalogueToolTip`, `Domenia-UX.UI.ps1:Initialize-DomeniaUxControlHelp`, `Domenia-UX.UI.ps1:Initialize-DomeniaUxWindowHelp`, `Domenia-UX.UI.ps1:Restore-DomeniaUxBaseToolTip`, `Domenia-Shell.Model.ps1:Get-DomeniaHelpPresentation`, `Set-DomeniaContextHint`, `Domenia-Core.ps1:Set-DomeniaContextHint`, `Domenia-Core.ps1:Get-DomeniaFriendlyControlLabel`, `Domenia-Core.ps1:Get-DomeniaDefaultToolTip`, `Domenia-Core.ps1:Apply-AutoTooltips`, `Domenia-Core.ps1:Enable-DomeniaUxHints`, `Domenia-Main.xaml:BtnUxHelpToggle`, `Domenia-Main.xaml:BtnUxHelpGuide`, `XAML:LblContextTitle`, `XAML:LblContextHint`

#### TRV-005 · Chapitre du guide et ouverture du PDF

`fait` · lecture locale

Le panneau d'aide indique le chapitre du guide (technicien ou administrateur) qui décrit la page affichée, y compris l'Atelier de requêtes dans Outils. « Ouvrir le guide » cherche le PDF dans un dossier DOC à côté de Domenia, de son parent ou du dossier de livraison, et l'ouvre avec le lecteur associé. Si le fichier manque, l'aide dit où le placer.

- Garde-fous : Aucun accès réseau ni téléchargement.
- Références D1 : `Domenia-Shell.Model.ps1:Get-DomeniaHelpGuideChapter`, `Domenia-UX.UI.ps1:Get-DomeniaUxHelpGuidePage`, `Domenia-UX.UI.ps1:Update-DomeniaUxHelpGuide`, `Domenia-UX.UI.ps1:Open-DomeniaHelpGuide`, `LblUxHelpGuide`, `BtnUxHelpGuide`

#### TRV-006 · Pourquoi ce bouton est grisé

`ameliore` · locale (aucune lecture)

Chaque contrôle grisé donne un motif court, visible en infobulle (ShowOnDisabled) et dans le panneau d'aide (F1). Le motif vient d'un catalogue fermé (lecture seule, aucune sélection, mauvais type, occupé, refusé, périmé, hors ligne, prérequis, reçu en attente, en cours), éventuellement précisé par un code de détail, avec une route vers l'endroit qui débloque.

- Garde-fous : Une estimation ACL n'est jamais présentée comme définitive ; protection voulue sans route. Aucun texte libre : un code hors catalogue est refusé, donc aucune valeur de champ ne peut fuiter dans une infobulle. Un contrôle grisé sans motif est détecté.
- Références D1 : `Domenia-Access.UI.ps1:Get-DomeniaControlCapabilityExplanation`, `Domenia-Access.Model.ps1:Get-DomeniaCapabilityExplanation`, `Get-DomeniaReadOnlyState`, `Get-DomeniaWriteGuardSubject`, `Get-WriteControlMap`, `Domenia-Shell.Model.ps1:Get-DomeniaDisabledHelpDetails`, `Domenia-Shell.Model.ps1:Get-DomeniaDisabledHelp`, `Domenia-Shell.Model.ps1:Get-DomeniaMissingDisabledHelp`, `Get-DomeniaCapabilityExplanation`

#### TRV-007 · Routes vers le réglage concerné

`fait` · locale (aucune lecture)

Navigation sûre depuis une explication vers Rechercher, Comptes, Fiche > Permissions, Opérations à vérifier, Base autonome > Stockage, Comparer les saisies, Assistance poste > Intervenir, lecture seule, Relire, panneau Opérations.

- Garde-fous : Navigation seulement : aucun droit, réglage ni protection changé.
- Références D1 : `Domenia-Access.UI.ps1:Resolve-DomeniaCapabilityRoute`, `Domenia-Access.UI.ps1:Invoke-DomeniaCapabilityRoute`

### Apparence et contrat visuel

#### TRV-008 · Glyphes d'état (mot, symbole, couleur)

`fait` · locale (aucune lecture)

14 états normalisés (Confirmé, Constaté, Estimé, Attention, Partiel, Erreur, Refusé, À vérifier, En cours, Inconnu, Indisponible, Vide, Aucun changement, Information), chacun avec un glyphe Segoe UI Symbol, un mot et une couleur de renfort. Les alias FR et EN sont reconnus sans tenir compte de la casse ni des accents ; un état non reconnu devient Inconnu, jamais un succès.

- Garde-fous : La couleur n'est jamais seule porteuse du sens.
- Références D1 : `Domenia-Shell.Model.ps1:Get-DomeniaStatusGlyph`

#### TRV-009 · Palette unique validée et contraste WCAG

`ameliore` · locale (aucune lecture)

SupportSuite.UI.json est l'unique source des couleurs (deux palettes, métriques d'espacement et de rayon). Il est rejeté s'il dépasse 32 KiB, si sa version n'est pas prise en charge, si une couleur n'est pas au format #RRGGBB ou si un jeton requis manque. Une quarantaine de paires texte/fond réellement peintes sont testées selon WCAG 2.x (4,5:1 pour le texte, 3:1 pour le grand texte et le graphique), avec ratio tronqué.

- Garde-fous : Un jeton inconnu renvoie une chaîne vide, jamais une couleur devinée. Un fond translucide est refusé au test.
- Références D1 : `SupportSuite.UI.json`, `Domenia-Experience.Model.ps1:Get-SuiteDesign`, `Domenia-Experience.Model.ps1:Get-SuitePalette`, `Domenia-Experience.Model.ps1:Get-DomeniaThemeColor`, `Domenia-Experience.Model.ps1:Get-DomeniaActiveThemeName`, `Domenia-Shell.Model.ps1:ConvertFrom-DomeniaHexColor`, `Domenia-Shell.Model.ps1:Get-DomeniaRelativeLuminance`, `Domenia-Shell.Model.ps1:Get-DomeniaContrastRatio`, `Domenia-Shell.Model.ps1:Test-DomeniaPaletteContrast`, `Domenia-Shell.Model.ps1:Get-DomeniaSuiteContrastPairs`

#### TRV-010 · Couleurs des séries de graphiques

`fait` · locale (aucune lecture)

Huit séries pastel (bleu, violet, sarcelle, rose, ciel, pêche, lilas, sauge), chacune avec un bord plus foncé. Elles évitent les teintes d'état (jaune, vert, rouge), qui ne désignent jamais une catégorie.

- Garde-fous : Contraste de 3:1 assuré par le bord en thème clair.
- Références D1 : `Domenia-Experience.Model.ps1:Get-DomeniaChartSeriesNames`, `Domenia-Experience.Model.ps1:Get-DomeniaChartSeries`

#### TRV-011 · Application de la palette et barre de titre

`fait` · locale (aucune lecture)

La palette est peinte dans les ressources de la fenêtre, y compris les couleurs système locales des listes déroulantes et le journal. La barre de titre Windows suit le thème (DWM), appliquée dès que la fenêtre possède son handle.

- Garde-fous : Aucun changement système global. Ne lève jamais d'erreur sur un Windows ancien.
- Références D1 : `Domenia-UX.UI.ps1:Set-DomeniaUxPalette`, `Domenia-UX.UI.ps1:Set-DomeniaWindowFrameTheme`, `Domenia.WindowFrame`, `Domenia-Identity.Types.cs:WindowFrame`

### Connexion

#### TRV-012 · Message de refus de connexion en clair

`a-faire` · locale (aucune lecture)

Traduit un refus d'authentification en une phrase polie et une étape suivante (compte inconnu, mot de passe refusé, restriction, horaires, poste interdit, mot de passe expiré ou à changer, compte désactivé/expiré/verrouillé, DC injoignable, délai, erreur interne, saisie incomplète, démonstration). Le code AD (525, 52e, 52f, 530, 531, 532, 533, 701, 773, 775 ou 0x8007xxxx) est gardé à part pour le diagnostic, jamais dans le texte ; détection ancrée (un DC nommé dc775 ne devient pas un compte verrouillé).

- Garde-fous : Une erreur interne ne prouve jamais un mauvais mot de passe ; code technique séparé du message. Un délai ou une panne n'est jamais présenté comme un mauvais mot de passe.
- Références D1 : `modules/Domenia-Accounts.Model.ps1:Get-DomeniaLoginFailureText`, `Domenia-Core.ps1 (fenêtre de connexion, LblLoginError)`, `Domenia-Core.ps1:Invoke-DomeniaInProcessAuthProbe`, `Domenia-Core.ps1:Update-DomeniaFastLoginAttempt`

#### TRV-013 · Connexion « Continuer en tant que DOMAINE\nom » (session Windows d'abord)

`a-faire` · lecture réseau

En session de domaine, le bouton principal ouvre Domenia avec le compte Windows sans mot de passe ; le formulaire identifiant/mot de passe est replié sous « Utiliser un autre compte ». Hors domaine, en démonstration ou si Auth.AllowWindowsSession est faux, le bouton est masqué ou grisé avec la raison ; « Changer de compte » ouvre directement le formulaire (PreferForm).

- Garde-fous : Aucun droit ajouté ; seule la présentation change, aucune tentative ne part de cette mise en page ; comptes ordinateur/local/système exclus de la proposition. Negotiate sans mot de passe explicite.
- Références D1 : `modules/Domenia-Accounts.Model.ps1:Get-DomeniaLoginChoice`, `modules/Domenia-Accounts.UI.ps1:Set-DomeniaLoginChoicePresentation`, `modules/Domenia-Accounts.UI.ps1:Set-DomeniaLoginWindowsFirst`, `BtnLogin`, `BtnLoginOtherAccount`, `LoginFormScroll`, `Get-DomeniaProcessWindowsIdentity (Core)`, `Domenia-Core.ps1:Show-LoginWindow`, `Domenia-Core.ps1:Get-DomeniaProcessWindowsIdentity`, `Domenia-Core.ps1:Test-DomeniaComputerAccountIdentity`, `XAML:BtnWindowsLogin`

#### TRV-014 · Mode diagnostic de la connexion

`a-faire` · lecture locale

En mode Debug, la fenêtre de connexion standard affiche en plus un panneau vivant avec l'étape en cours et la trace technique, et son titre reçoit « · diagnostic ». La trace est exactement le texte de « Copier le diagnostic » ; aucun mot de passe n'y est jamais ajouté.

- Garde-fous : Trace sans secret ; panneau en lecture seule. Même moteur d'authentification dans les deux modes.
- Références D1 : `modules/Domenia-Accounts.UI.ps1:Show-DomeniaLoginDiagnosticPanel`, `LoginDiagnosticBuffer`, `TxtLoginTechnical`, `LblLoginStage`, `BtnLoginLog`, `LblLoginWait`, `BtnLoginWaitCancel`, `Domenia-Core.ps1:Get-DomeniaLoginWindowMode`, `Domenia-Core.ps1:Get-DomeniaStandardLoginXaml`, `Domenia-Core.ps1:Show-LoginWindow`, `XAML:BtnCopyLoginDiag`, `XAML:UxLoginDiagnostics`

#### TRV-015 · Coffre Windows à la connexion

`a-faire` · lecture locale

Case « Mémoriser sur ce PC » après une connexion réussie, boutons « Utiliser le coffre » et « Oublier » ; le compte mémorisé est comparé sans sa partie domaine (CNAMTS\compte, compte@cnamts.local et compte sont le même, décision du 19/10/2026) tandis que l'entrée du coffre reste liée au compte exact. Une règle explique pourquoi le coffre est indisponible (démonstration, rien de mémorisé, autre compte saisi, autre domaine).

- Garde-fous : Coffre jamais lu au démarrage ni en arrière-plan ; indisponible en démonstration ; enregistrement seulement après authentification réussie.
- Références D1 : `modules/Domenia-CredentialVault.Model.ps1:ConvertTo-DomeniaVaultLoginKey`, `modules/Domenia-CredentialVault.Model.ps1:Get-DomeniaVaultLoginReason`, `ChkLoginVaultRemember`, `BtnLoginVaultUse`, `BtnLoginVaultForget`, `Domenia-Core.ps1 l.25163`

#### TRV-016 · Connexion explicite à tentative unique

`a-faire` · lecture réseau

Découvre RootDSE avec l'identité Windows sans utiliser le mot de passe, qualifie une seule identité canonique, puis fait un seul bind sur un seul contrôleur (4 candidats max, 30 s au total, 6 s par serveur) dans un runspace dédié sans bloquer l'interface ; l'identité qui a réellement réussi devient celle de tous les workers.

- Garde-fous : Aucune variante DOMAINE\user/UPN essayée ; jamais un second DC après envoi du mot de passe (anti-verrouillage) ; SecureString de bout en bout.
- Références D1 : `Domenia-Core.ps1:Invoke-DomeniaInProcessAuthProbe`, `Domenia-Core.ps1:Start-DomeniaLoginAuthRunspace`, `Domenia-Core.ps1:Read-DomeniaAuthRunspaceResult`, `Domenia-Core.ps1:Stop-DomeniaLoginAuth`, `Domenia-Core.ps1:New-DomeniaFastLoginSession`, `Domenia-Core.ps1:Start-DomeniaFastLoginAttempt`, `Domenia-Core.ps1:Complete-DomeniaFastLoginSuccess`, `XAML:TxtLogin`, `XAML:PwdLogin`, `XAML:PbLogin`, `XAML:BtnCancel`

### Démarrage

#### TRV-017 · Chargement différé des vues optionnelles

`fait` · locale (aucune lecture)

Les vues Assistance, Atelier support, Opérations et Demande dans la page sont chargées depuis leur XAML à la première ouverture. Les noms de contrôles sont contrôlés : un doublon ou un contrôle introuvable fait échouer le chargement. En cas d'échec, l'Atelier support est restauré et propose « Réessayer ».

- Garde-fous : Rollback des seuls contrôles ajoutés par la tentative.
- Références D1 : `Domenia-Assistance.UI.ps1:Register-DomeniaAssistanceTool`, `Domenia-Assistance.UI.ps1:Initialize-DomeniaAssistanceView`, `Domenia-Support.UI.ps1:Initialize-DomeniaSupportUi`, `Domenia-Support.UI.ps1:Invoke-DomeniaSupportLoad`, `Domenia-Experience.UI.ps1:Initialize-DomeniaOperationsPanel`, `Domenia-Inline.UI.ps1:Initialize-DomeniaInlineUi`

#### TRV-018 · Restauration bornée de la fenêtre

`a-faire` · locale (aucune lecture)

La position et la taille enregistrées sont ramenées dans la zone de travail d'un écran encore présent : écran débranché, trou d'une disposition en L, taille plus grande que l'écran. Sinon, la fenêtre est centrée sur l'écran principal, avec des minimums de 640 × 420.

- Garde-fous : La barre de titre reste toujours atteignable, y compris à 200 %.
- Références D1 : `Domenia-Shell.Model.ps1:Get-DomeniaBoundedWindowRect`, `Domenia-Shell.Model.ps1:ConvertTo-DomeniaShellRect`

#### TRV-019 · Écran de connexion : thème, Verr. Maj, annulation

`a-faire` · locale (aucune lecture)

Bouton de thème sur la connexion, mémorisé, qui ne lance ni ne modifie la connexion. L'indicateur Verr. Maj est actif. « Annuler la connexion » et Échap pendant l'attente demandent l'arrêt de la validation. La fenêtre est bornée à la zone de travail (800 au plus) et la barre de titre suit le thème.

- Garde-fous : Seuls les pinceaux changent, jamais l'état d'authentification. « Thème non enregistré » est signalé en cas d'échec d'écriture. Aucun appel Windows n'est arrêté de force. Validation jamais lancée mot de passe affiché ; coffre lu seulement sur geste ; aucun repli fichier/SQLite pour un secret.
- Références D1 : `Domenia-Experience.UI.ps1:Initialize-DomeniaExperienceLogin`, `Domenia-Experience.UI.ps1:Switch-DomeniaExperienceLoginTheme`, `Domenia-Experience.UI.ps1:Update-DomeniaExperienceLoginThemeIcon`, `Domenia-Experience.UI.ps1:Update-DomeniaExperienceCapsLock`, `Domenia-UX.UI.ps1:Initialize-DomeniaUxLoginPresentation`, `BtnSuiteLoginTheme`, `LblSuiteCapsLock`, `LblSuiteThemeSave`, `BtnLoginWaitCancel`, `PanelSplash`, `LoginThemeSun`, `LoginThemeMoon`, `Domenia-Core.ps1:Show-LoginWindow`, `Domenia-Core.ps1:Get-DomeniaFastLoginVaultIdentity`, `Domenia-Core.ps1:Update-DomeniaFastLoginVaultUi`, `Domenia-Core.ps1:Remove-DomeniaFastLoginVault`, `Domenia-Core.ps1:Save-DomeniaFastLoginVaultPreference`, `Domenia-Core.ps1:Set-DomeniaFastLoginBusy`, `XAML:ChkRemember`

#### TRV-020 · Mode démonstration

`a-faire` · locale (aucune lecture)

Activé seulement par Auth.DemoProvider à true (booléen JSON), décidé une fois par session. La connexion se fait avec une identité DEMO\nom (Demo.Identity), sans mot de passe ni session Windows ni mémorisation, et une latence simulée de 0 à 5000 ms (Demo.LatencyMs). La bannière « DÉMONSTRATION — aucune connexion AD » est permanente, la lecture seule est verrouillée, le relevé des postes et l'entretien du stockage sont désactivés, et une base locale séparée est utilisée.

- Garde-fous : Le texte « false » n'active pas le mode. L'identité est validée avant toute authentification. Les écritures sont impossibles, y compris par la palette et l'interrupteur. Résultat démo refusé hors démo et inversement ; rien en HKCU.
- Opérations : `DemoDirectory`
- Références D1 : `Domenia-Demo.Model.ps1:Test-DomeniaDemoProviderEnabled`, `Domenia-Demo.Model.ps1:Test-DomeniaDemoIdentity`, `Domenia-Demo.Model.ps1:Get-DomeniaDemoBannerText`, `Domenia-Demo.UI.ps1:Initialize-DomeniaDemoMode`, `Domenia-Demo.UI.ps1:Get-DomeniaDemoConfiguredIdentity`, `Domenia-Demo.UI.ps1:Initialize-DomeniaDemoLoginPresentation`, `Domenia-Demo.UI.ps1:Set-DomeniaDemoShellPresentation`, `ChkReadOnlyMode`, `BtnParkVerify`, `BtnStorageUsage`, `Domenia-Core.ps1:Assert-WriteAllowed`, `Domenia-Core.ps1:Get-DomeniaDatabasePath`, `Domenia-Core.ps1:New-DomeniaAccountAuthRequest`, `Domenia-Core.ps1:Invoke-ComputerTool`, `Domenia-Core.ps1:Wire-Events (ChkReadOnlyMode)`

#### TRV-021 · Validation du catalogue détaillé

`a-faire` · lecture locale

Au chargement : fichier ≤ 1 Mio, version 1, ≤ 256 sondes, identifiants uniques, classes et champs typés, documentation complète, références seulement learn.microsoft.com ou GitHub Microsoft ; les sondes intégrées héritent des métadonnées de leur classe.

- Garde-fous : Toute anomalie lève une erreur ; type non documenté gardé en texte.
- Références D1 : `Domenia-ProbeCatalog.Model.ps1:Get-DomeniaExtendedProbeCatalog`, `Domenia-ProbeCatalog.Model.ps1:Add-DomeniaProbeMetadata`

#### TRV-022 · Lignes de résultat compilées

`a-faire` · locale (aucune lecture)

Type C# Domenia.Live.ResultRow qui notifie WPF cellule par cellule ; repli sur objets PowerShell si la compilation est bloquée.

- Garde-fous : Aucune protection Windows contournée (avertissement journal).
- Références D1 : `Domenia-Live.Types.cs`, `Domenia-Live.Model.ps1:New-DomeniaLiveResultRow`, `Domenia-Live.Model.ps1:Set-DomeniaLiveRowValue`, `Domenia-Live.Model.ps1:Get-DomeniaLiveField`

#### TRV-023 · Fermeture sans attente

`a-faire` · locale (aucune lecture)

À la fermeture, arrête minuteur, vérifications et recherche sans attendre LDAP/CIM/SQLite et journalise les observations éventuellement non enregistrées ; l'avancement du relevé en cours est sauvé.

- Garde-fous : Dernier cache validé conservé ; appel natif en cours jamais prétendu arrêté.
- Références D1 : `Domenia-Live.UI.ps1:Stop-DomeniaLive`, `Domenia-Live.UI.ps1:Stop-DomeniaLiveSearch`, `Domenia-Live.UI.ps1:Stop-DomeniaLiveProbes`, `Domenia-Live.UI.ps1:Stop-DomeniaLiveJob`, `Domenia-Collection.UI.ps1:Register-DomeniaCampaignCloseHook`

#### TRV-024 · Lanceur limité à Windows PowerShell 5.1 x64 STA

`a-faire` · locale (aucune lecture)

Domenia-Start.ps1 refuse tout hôte autre que Windows PowerShell 5.1 Desktop 64 bits en mode STA (« Lancez Domenia.exe ») et refuse un dossier logiciel redirigé (jonction ou lien) sur toute la chaîne jusqu'à la racine.

- Garde-fous : Refus avant tout chargement ; message rouge, boîte « Domenia | Démarrage » et code de sortie 1.
- Références D1 : `Domenia-Start.ps1`

#### TRV-025 · Contrôle d'intégrité du paquet à chaque lancement

`a-faire` · lecture locale

Chaque fichier runtime de wad/package-manifest.json (format 1, 2 Mo au plus) est haché en SHA-256 et comparé au manifeste. Les chemins doivent être relatifs, sans « .. », « : » ni wad/data, sans doublon ni redirection. Seule une différence de fin de ligne CRLF/LF est tolérée, et elle est comptée. Le nombre de fichiers est borné de 10 à 1000, avec un plafond lu dans wad/Domenia.release.json (RuntimeFileLimit, 250 par défaut).

- Garde-fous : Refus « Composant modifié ou versions mélangées » avec le hash attendu, le hash lu et la taille ; chaque dossier est vérifié une fois contre la redirection ; un seul SHA-256 et des lectures séquentielles. Refus du démarrage sur empreinte différente, fichier redirigé ou mise à jour incomplète ; seule la différence CRLF/LF est tolérée et comptée.
- Références D1 : `Domenia-Start.ps1`, `wad/package-manifest.json`, `wad/Domenia.release.json`

#### TRV-026 · Liste des composants requis tirée du plan des modules

`a-faire` · lecture locale

Les fichiers indispensables (Domenia.exe, Core, Main.xaml, Start, Modules, release.json, CommonLibrary.json, .lifecycle.lock) et chaque fichier des plans de modules et de types doivent figurer au manifeste. Ces plans sont lus dans l'arbre syntaxique de Domenia-Modules.ps1, sans l'exécuter.

- Garde-fous : « Manifeste incomplet » ou « Plan des modules illisible/vide » : lancement refusé.
- Références D1 : `Domenia-Start.ps1`, `Domenia-Modules.ps1:Get-DomeniaRuntimeModulePlan`, `Domenia-Modules.ps1:Get-DomeniaRuntimeTypePlan`

#### TRV-027 · Blocage d'une mise à jour interrompue

`a-faire` · lecture locale

Si Support\.update.pending existe, le lancement est refusé. Le message donne la commande de restauration : RESTAURER-CODE.ps1 -RestoreBackup de la sauvegarde nommée dans le marqueur, ou INSTALLER-MISE-A-JOUR.ps1 -RestoreLatest.

- Garde-fous : Aucun code mélangé n'est exécuté ; la sauvegarde du code reste la référence de retour.
- Références D1 : `Domenia-Start.ps1`

#### TRV-028 · Verrou de cycle de vie pendant l'exécution

`a-faire` · locale (aucune lecture)

Support\.lifecycle.lock reste ouvert en lecture partagée pendant tout le lancement. L'installateur, qui le prend en exclusif, ne peut donc pas remplacer le code d'une instance qui démarre.

- Garde-fous : Verrou libéré dans le finally du lanceur.
- Références D1 : `Domenia-Start.ps1`, `Support/.lifecycle.lock`

#### TRV-029 · Autotest sans lancement (-CheckOnly)

`a-faire` · lecture locale

Vérifie l'intégrité, analyse chaque .ps1 et importe réellement les modules dans une portée jetable, sans fenêtre, minuterie ni accès AD. Résultat : « Runtime &lt;build> : n fichiers vérifiés en x ms (plafond) ; m modules chargés… Aucun accès AD. », avec le nombre de fichiers aux fins de ligne différentes. Le paramètre -Diagnostic est déclaré mais n'est pas utilisé.

- Garde-fous : Aucune connexion, aucune écriture ; code de sortie 0 ou 1.
- Références D1 : `Domenia-Start.ps1`

#### TRV-030 · Journal des échecs de démarrage

`a-faire` · écriture

Toute erreur de lancement est ajoutée à %TEMP%\Domenia-startup-error.log, avec horodatage ISO. Hors -CheckOnly, une boîte « Domenia | Démarrage » affiche le message et le chemin de ce diagnostic.

- Garde-fous : Écriture best-effort ; une erreur du journal n'en masque pas la cause.
- Références D1 : `Domenia-Start.ps1`

#### TRV-031 · Chronométrage du démarrage (R40)

`a-faire` · locale (aucune lecture)

Le lanceur et le cœur partagent une horloge de processus. Sont mesurés l'âge du processus, la durée du contrôle d'intégrité, chaque étape du chargeur (Fichiers et analyse syntaxique, Types C#, Socle, Import des modules, Contrôle des exports) et les sous-étapes Detail/&lt;nom>. Ces mesures vont dans Domenia-startup.log et ne servent jamais à décider.

- Garde-fous : Un échec de trace n'arrête jamais le démarrage. Mesure uniquement : jamais une entrée de décision ; une trace en échec n'arrête pas le démarrage.
- Références D1 : `Domenia-Start.ps1:$DomeniaStartClock`, `Domenia-Start.ps1:$DomeniaStartIntegrity`, `Domenia-Modules.ps1:$script:DomeniaRuntimeImportTimings`, `Domenia-Engine.UI.ps1:Write-DomeniaStartupSplit`, `Domenia-Core.ps1:Write-StartupTrace`, `Domenia-Core.ps1:Add-DomeniaStartupMark`, `Domenia-Core.ps1:Write-DomeniaStartupMarks`, `Domenia-Core.ps1:Write-DomeniaStartupMilestone`, `Domenia-Core.ps1:Write-DomeniaStartupTimings`, `Domenia-Core.ps1:Get-DomeniaLaunchElapsedMs`

#### TRV-032 · Plan de modules fermé, phasé et ordonné

`a-faire` · locale (aucune lecture)

La liste des modules est close : aucun script voisin n'est chargé. Chaque module déclare sa phase (Bootstrap, Resources, Modules, Authentication, Interface), ses dépendances et ses fonctions. Test-DomeniaStartupPlan refuse une phase inconnue, une dépendance absente ou chargée plus tard, un cycle et une fonction fournie deux fois, puis calcule l'ordre d'import.

- Garde-fous : DOMENIA_MODULE_PLAN avant le premier module métier. Échec explicite au démarrage plutôt que fonctionnement partiel.
- Références D1 : `Domenia-Modules.ps1:Get-DomeniaRuntimeModulePlan`, `Domenia-Engine.Model.ps1:Get-DomeniaStartupPhases`, `Domenia-Engine.Model.ps1:Test-DomeniaStartupPlan`, `Domenia-Engine.Model.ps1:Test-DomeniaPhaseCall`, `Domenia-Modules.ps1`, `Domenia-Core.ps1:Get-DomeniaWorkerRulesCommon`

#### TRV-033 · Pré-contrôle syntaxique et contrôle des exports

`a-faire` · lecture locale

Avant le premier import, chaque module déclaré doit exister et s'analyser sans erreur (DOMENIA_MODULE_MISSING, DOMENIA_MODULE_PARSE avec la ligne) ; l'analyse est ensuite réutilisée par l'import. Après l'import, chaque fonction déclarée doit exister et venir exactement de son fichier (DOMENIA_MODULE_EXPORT, DOMENIA_MODULE_ORIGIN).

- Garde-fous : Une fonction plus ancienne d'une portée parente ne peut pas masquer un oubli d'import.
- Références D1 : `Domenia-Modules.ps1:Get-DomeniaRuntimeModuleParseError`, `Domenia-Modules.ps1:Assert-DomeniaRuntimeImports`, `Domenia-Modules.ps1:Get-DomeniaRuntimeModuleValue`

#### TRV-034 · Types natifs compilés et bibliothèques épinglées

`a-faire` · lecture locale

Les types C# (Live, Identity) sont compilés en un seul appel du compilateur ; les types de l'arbre WPF sont différés après l'authentification. M4D.Admin.Common.Query.dll et Domenia.Native.dll ne sont chargées que si leur SHA-256 correspond, et le démarrage est refusé si une autre version est déjà chargée dans le processus.

- Garde-fous : DOMENIA_LIBRARY_HASH, DOMENIA_LIBRARY_VERSION, DOMENIA_MODULE_TYPES.
- Références D1 : `Domenia-Modules.ps1:Get-DomeniaRuntimeTypePlan`, `modules/M4D.Admin.Common.Query.dll`, `Domenia-Identity.Types.cs`, `Domenia-Live.Types.cs`, `Domenia-DirectoryTree.Types.cs`

#### TRV-035 · Provenance déclarée de la bibliothèque commune M4D

`a-faire` · locale (aucune lecture)

Domenia-CommonLibrary.json décrit le moteur de requêtes partagé QueryEngine : dépôt m4d-admin-common, commit, version 0.1.1-domenia.1, SHA-256 de la source et de la DLL, modification locale par rapport à l'amont et RuntimeDownload=false (jamais téléchargée).

- Garde-fous : Hash de la DLL revérifié au chargement.
- Références D1 : `modules/Domenia-CommonLibrary.json`, `modules/M4D.Admin.Common.Query.dll`

#### TRV-036 · Activation de la fenêtre au premier plan maîtrisée

`a-faire` · locale (aucune lecture)

Le premier plan n'est demandé qu'au lancement explicite (fenêtre de connexion, moniteur de démarrage) et au passage de la connexion à la fenêtre principale, une fois par moment. La fenêtre ne passe jamais en Topmost et rien n'est demandé après une tâche. Un Alt-Tab de l'opérateur vers une autre application est respecté, et chaque décision est journalisée.

- Garde-fous : Un refus de Windows est définitif ; le signal de la barre des tâches reste au système. Un compteur illisible vaut une tentative déjà faite.
- Références D1 : `Domenia-Startup.UI.ps1:Get-DomeniaActivationState`, `Domenia-Startup.UI.ps1:Register-DomeniaUserSwitchWatch`, `Domenia-Startup.UI.ps1:Test-DomeniaOwnWindowActive`, `Domenia-Startup.UI.ps1:Write-DomeniaActivationLog`, `Domenia-Startup.UI.ps1:Request-DomeniaWindowActivation`, `Domenia-Startup.UI.ps1:Test-DomeniaUserSwitchedAway`, `Domenia-Shell.Model.ps1:Get-DomeniaActivationDecision`

#### TRV-037 · Migration des préférences vers le dossier Preferences

`a-faire` · écriture

Au démarrage, après validation du stockage, Domenia.settings.json est copié une seule fois de DataRoot vers DataRoot\Preferences si la cible est absente. La copie est vérifiée octet par octet et l'original conservé. Aucun écrasement, suppression, migration de configuration ni destination alternative.

- Garde-fous : Refus sans stockage valide (DOMENIA_STORE_LAYOUT), des dossiers redirigés et du JSON invalide ; le diagnostic du parseur ne sort jamais du bloc.
- Références D1 : `Domenia-Storage.UI.ps1:Invoke-DomeniaPreferenceMigration`, `Domenia-Storage.UI.ps1:Get-DomeniaUserLocalRoot`, `Domenia-Release.Model.ps1:Get-DomeniaPreferenceMigrationPlan`

#### TRV-038 · Paramètres de lancement du cœur

`a-faire` · locale (aucune lecture)

Le cœur accepte -Server, -SearchBase, -DefaultLimit, -NoAutoConnect et -DomeniaSelfTest/-DomeniaSelfTestResultPath (alias MegAD\*). Ils surchargent Conf.Server, Conf.SearchBase et Browser.DefaultLimit de la configuration.

- Garde-fous : Aucune connexion lancée par les paramètres eux-mêmes.
- Références D1 : `Domenia-Core.ps1:param()`, `Domenia-Core.ps1:Load-AppConfig`

#### TRV-039 · Trace d'amorçage et refus de relance cachée

`a-faire` · locale (aucune lecture)

Écrit Domenia-bootstrap.log (LOCALAPPDATA ou TEMP, DOMENIA\Logs) avec PID, hôte, version et 64 bits avant tout module ; sous PowerShell ISE, avertit sans jamais relancer un processus enfant caché.

- Garde-fous : Détail masqué par Protect-DomeniaLogText ; aucun processus PowerShell enfant.
- Références D1 : `Domenia-Core.ps1:Write-DomeniaBootstrapTrace`, `Domenia-Core.ps1:(bloc ISE)`

#### TRV-040 · Résolution du dossier d'installation

`a-faire` · locale (aucune lecture)

Détermine la racine de Domenia depuis DOMENIA_ROOT, MEGAD_ROOT (compatibilité), l'EXE compilé, le chemin du script ou le dossier courant, et en déduit Domenia.config.json, l'icône et la clé HKCU.

- Garde-fous : Premier candidat existant uniquement ; icône régénérée depuis la base64 embarquée si absente.
- Références D1 : `Domenia-Core.ps1:Get-RootDir`, `Domenia-Core.ps1:Ensure-AppIconFile`, `Domenia-Core.ps1:Set-AppWindowIcon`

#### TRV-041 · Préflight et compatibilité XAML

`a-faire` · locale (aucune lecture)

Avant d'afficher une fenêtre, vérifie le XAML (Content en double sur Button, ToolTip de colonne, ComboBox.IsReadOnly, RowHeight=Auto, x:Name dupliqués) puis demande au moteur WPF réel de résoudre types et membres ; un diagnostic XAML est sauvegardé en cas d'échec.

- Garde-fous : Un texte refusé n'est jamais mémorisé comme accepté.
- Références D1 : `Domenia-Core.ps1:Assert-DomeniaXamlPreflight`, `Domenia-Core.ps1:Test-DomeniaXamlRuntimeCompatibility`, `Domenia-Core.ps1:Save-DomeniaXamlDiagnostic`, `Domenia-Core.ps1:ConvertFrom-DomeniaXaml`, `Domenia-Core.ps1:Get-MainXaml`

#### TRV-042 · Collecte des contrôles et contrôles/fonctions critiques

`a-faire` · locale (aucune lecture)

Tous les x:Name du XAML principal sont collectés automatiquement ; une liste de contrôles critiques et de fonctions critiques fait échouer explicitement le démarrage si l'un manque.

- Garde-fous : Régression silencieuse transformée en échec de démarrage.
- Références D1 : `Domenia-Core.ps1:Load-XamlWindow`, `Domenia-Core.ps1:Get-DomeniaXamlControlNames`, `Domenia-Core.ps1:Get-DomeniaCriticalControlNames`, `Domenia-Core.ps1:Get-DomeniaCriticalFunctionNames`, `Domenia-Core.ps1:Get-DomeniaIntegritySnapshot`

#### TRV-043 · Moniteur de démarrage

`a-faire` · locale (aucune lecture)

Fenêtre d'étapes de démarrage (Startup.ShowMonitor, KeepMonitorUntilReady, WarnStageSeconds 8) jamais au premier plan forcé ; un Alt-Tab volontaire de l'opérateur est respecté à l'ouverture de la fenêtre principale.

- Garde-fous : Jamais Topmost ; une seule demande d'activation journalisée.
- Références D1 : `Domenia-Core.ps1:Get-DomeniaStartupXaml`, `Domenia-Core.ps1:New-DomeniaStartupWindow`, `Domenia-Core.ps1:Set-DomeniaStartupStage`, `Domenia-Core.ps1:Close-DomeniaStartupWindow`, `Domenia-Core.ps1:Invoke-DomeniaStartupStage`, `Domenia-Core.ps1:Set-DomeniaWindowActivationPolicy`, `XAML:TxtStartupDetail`, `XAML:BtnStartupLog`, `XAML:BtnStartupCancel`

#### TRV-044 · Étapes différées après l'affichage d'Accueil

`a-faire` · locale (aucune lecture)

Les préparations des pages hors premier écran (arbre de Rechercher, Stockage, figures de la base) sont exécutées une par une juste après le premier rendu d'Accueil, avant toute saisie, puis le jalon « Accueil disponible » est tracé.

- Garde-fous : Un échec d'étape différée est tracé et annoncé sans casser l'ouverture déjà affichée.
- Références D1 : `Domenia-Core.ps1:Register-DomeniaDeferredStartupStep`, `Domenia-Core.ps1:Invoke-DomeniaNextDeferredStartupStep`, `Domenia-Core.ps1:Start-DomeniaDeferredStartup`, `Domenia-Core.ps1:Complete-DomeniaStartupAvailability`

#### TRV-045 · Rapport d'arrêt fatal

`a-faire` · locale (aucune lecture)

Distingue un échec d'initialisation d'un arrêt inattendu d'une session déjà affichée, avec code incident et chemins des journaux ; le texte .NET brut n'apparaît qu'en profil Expert ou si aucun journal n'a pu l'écrire.

- Garde-fous : Lignes en file de Domenia.log écrites avant la fin du processus.
- Références D1 : `Domenia-Core.ps1:Get-DomeniaFatalMessage`, `Domenia-Core.ps1:Register-DomeniaSessionShownHook`

#### TRV-046 · Auto-test intégré en ligne de commande

`a-faire` · locale (aucune lecture)

Le mode -DomeniaSelfTest exécute les auto-tests du moteur (chargeur, ordonnanceur, annulation, budgets, inactivité, activation, fournisseur de démonstration) et écrit le résultat dans le fichier demandé.

- Garde-fous : Aucun contact AD ni poste.
- Opérations : `EngineSelfTest`, `DemoDirectory`
- Références D1 : `Domenia-Core.ps1:Invoke-DomeniaSelfTest`, `Domenia-Core.ps1:Get-DomeniaWorkerEngineSelfTestCode`

### Démonstration

#### TRV-047 · Annuaire de démonstration en mémoire

`fait` · locale (aucune lecture)

Une trentaine d'objets fidèles aux types AD (GUID et SID en octets, dates, Int64, objectClass multivalué, member et memberOf cohérents) : OU Siège, Agences et Restreint, utilisateurs dont un verrouillé, un désactivé, un admin, des noms à caractères spéciaux (Démo, O'Brien, virgule échappée), trois postes avec LAPS bientôt expiré ou déjà expiré et un sans DNS, des groupes vide, comptable et « Tous », et un compte refusé pour l'opérateur de démonstration.

- Garde-fous : Domaine demo.invalid : aucune collision avec un vrai domaine.
- Opérations : `DemoDirectory`
- Références D1 : `Domenia-Demo.Model.ps1:New-DomeniaDemoDirectory`, `Domenia-Demo.Model.ps1:New-DomeniaDemoGuidBytes`, `Domenia-Demo.Model.ps1:New-DomeniaDemoSidBytes`

#### TRV-048 · Worker de démonstration

`fait` · locale (aucune lecture)

Il répond aux opérations TreeChildren, GlobalSearch (analyse de filtres LDAP), OpenAdObject, IndexBuild, BitLockerPresence, StartupWarmCache et ReceiptStore List, dans les formes exactes des lecteurs réels. Il simule la latence annulable, les refus d'accès (0x80070005) et les objets introuvables (0x80072030). Toute autre opération est refusée explicitement.

- Garde-fous : Le contexte ne reçoit jamais de credential et ReadOnlyMode est forcé. Le contexte invalide est refusé. Il ne lit jamais le vrai dossier des reçus. Lecture BitLocker refusée à la racine du domaine. Seules les opérations locales listées gardent leur worker réel. Aucune écriture tentée.
- Opérations : `DemoDirectory`, `LiveCache`, `LocalStore`, `DocumentStore`, `EngineSelfTest`, `EmbeddedPathBrowse`, `LocalIndexRead`
- Références D1 : `Domenia-Demo.Worker.ps1:Get-DomeniaDemoDirectoryWorkerCode`, `Domenia-Demo.Model.ps1:ConvertTo-DomeniaDemoWorkerContext`, `Domenia-Demo.Model.ps1:Get-DomeniaDemoPassThroughOperations`, `Domenia-Engine.UI.ps1:Invoke-DomeniaUiTaskDispatch`

### En-tête

#### TRV-049 · Bouton Opérations avec compteur

`fait` · locale (aucune lecture)

Bouton icône de l'en-tête avec un compteur en pastille (99+ au-delà, masqué à zéro) et une progression du premier lot. Son infobulle donne les nombres d'actives, en attente et en nettoyage, les lots et les reçus à vérifier.

- Garde-fous : Aucun accès AD supplémentaire.
- Références D1 : `Domenia-Experience.UI.ps1:Open-DomeniaExperienceActivity`, `Domenia-Experience.UI.ps1:Update-DomeniaExperienceActivity`, `BtnSuiteActivity`, `LblSuiteActivityCount`, `BadgeSuiteActivity`

#### TRV-050 · Titre de page, titre de fenêtre et puce du sujet

`fait` · locale (aucune lecture)

Le titre suit la forme « Page · cible » (« Fiche · Camille Martin »), et le titre de fenêtre « … — Domenia », complété de [ÉCRITURE AD ACTIVE] quand les écritures sont autorisées. Sans cible, le titre l'indique (« Aucun poste sélectionné ») et ne garde jamais l'ancien nom. Une puce « Poste · nom » avec ✕ désélectionne sans rien relire.

- Garde-fous : Un utilisateur sélectionné n'est jamais présenté comme la cible de Poste. Le garde-fou de saisie non enregistrée s'applique à la désélection.
- Références D1 : `Domenia-Shell.Model.ps1:Get-DomeniaShellPages`, `Domenia-Shell.Model.ps1:Get-DomeniaPageTitle`, `Domenia-UX.UI.ps1:Update-DomeniaUxPageTitle`, `Domenia-UX.UI.ps1:Get-DomeniaUxSubject`, `Domenia-UX.UI.ps1:Clear-DomeniaUxSubject`, `LblUxPageTitle`, `LblUxSubject`, `UxSubjectChip`, `BtnUxSubjectClear`, `Domenia-Main.xaml:UxPageHeader`

#### TRV-051 · Badge de session AD

`ameliore` · locale (aucune lecture)

Badge « Connecté à domaine » avec le contrôleur interrogé en infobulle. « AD injoignable depuis HH:mm · données déjà lues seulement » s'affiche en cas de coupure, « Dernière requête AD : délai dépassé » quand une requête est lente, et la bannière s'affiche en démonstration. Le badge revient seul à la prochaine lecture réussie.

- Garde-fous : Un délai dépassé n'est pas présenté comme une coupure. Aucune relance automatique.
- Références D1 : `Domenia-Shell.Model.ps1:Get-DomeniaSessionBadge`, `Domenia-UX.UI.ps1:Update-DomeniaUxSessionBadge`, `LblUxDomain`, `UxDomainBadge`, `Domenia-Main.xaml:UxDomainBadge`

#### TRV-052 · Compte connecté et À propos au pied du menu

`fait` · lecture locale

Le pied du menu affiche le compte et le domaine utilisés. Son menu propose « Changer de compte » (page Comptes) et « À propos de Domenia » : version, compatibilité du poste (Windows, PowerShell, .NET, SQLite) lue localement une fois par session.

- Garde-fous : Seuls des faits locaux sont lus (registre, version de winsqlite3.dll).
- Références D1 : `Domenia-UX.UI.ps1:Update-DomeniaUxAccountFooter`, `Domenia-UX.UI.ps1:Show-DomeniaUxAccountMenu`, `Domenia-UX.UI.ps1:Switch-DomeniaUxAbout`, `BtnUxNavAccount`, `LblUxNavAccount`, `LblUxNavDomain`, `UxAboutPanel`, `LblUxAboutCompatibility`, `Update-DomeniaAboutCompatibility`

#### TRV-053 · Bandeau d'activité à emplacements fixes

`fait` · locale (aucune lecture)

Les emplacements de l'en-tête sont réservés : barre de progression, Annuler, temps écoulé, bandeau d'écriture, Accès, Opérations et leurs compteurs. Un emplacement vide est Hidden et non Collapsed : 0, 1, 10 ou 100 tâches ou un long message ne déplacent rien. Compteurs : vide à zéro, 99+ au-delà.

- Garde-fous : Un contrôle vérifie que la déclaration XAML correspond aux emplacements réservés.
- Références D1 : `Domenia-Shell.Model.ps1:Get-DomeniaActivityStripSlots`, `Domenia-Shell.Model.ps1:Compare-DomeniaReservedSlots`, `Domenia-Shell.Model.ps1:Get-DomeniaCounterText`, `UxPageHeaderBar`, `UxActivityStrip`, `PbTop`, `BtnCancelTask`, `LblTaskElapsed`, `WriteModeBanner`, `BtnAccessRecovery`, `BadgeAccessRecovery`, `Domenia-Main.xaml:BtnAccessRecovery`

### Exports

#### TRV-054 · Moteur d'export CSV commun

`fait` · locale (aucune lecture)

Point-virgule, UTF-8 avec BOM, colonnes visibles dans l'ordre avec en-têtes français, cellules de type formule neutralisées, nom Domenia-&lt;OU ou poste>-AAAAMMJJ-HHmm.csv dans Exports, jamais écrasé, nombre de lignes et valeurs masquées annoncés avec « Ouvrir le dossier ».

- Garde-fous : Colonnes secrètes retenues, textes ressemblant à un secret masqués (Protect-DomeniaExportRows).
- Références D1 : `Domenia-Core.ps1:Export-DomeniaCsv`, `Domenia-Core.ps1:Get-DomeniaGridExportColumns`, `Domenia-Core.ps1:ConvertTo-DomeniaExportRows`, `Domenia-Core.ps1:ConvertTo-DomeniaSpreadsheetSafeRow`, `Domenia-Core.ps1:ConvertTo-DomeniaSpreadsheetCell`, `Domenia-Core.ps1:Get-DomeniaExportFileName`, `Domenia-Core.ps1:Get-DomeniaExportDirectory`, `Domenia-Core.ps1:Show-DomeniaExportResult`

#### TRV-055 · Import de CSV à séparateur détecté

`fait` · lecture locale

Détecte le séparateur (point-virgule de Domenia ou virgule d'un autre outil) sur la première ligne avant import.

- Références D1 : `Domenia-Core.ps1:Get-DomeniaCsvDelimiter`

### Feuilles

#### TRV-056 · Panneaux intégrés à la place des fenêtres

`fait` · locale (aucune lecture)

Toute fenêtre métier s'affiche comme une feuille posée à droite sur un voile, dans la fenêtre principale. Une seule à la fois : une autre demande est reportée. Tab circule dans la feuille, Échap annule, Entrée active le bouton par défaut hors texte multiligne. Les raccourcis de la page dessous sont bloqués hors champs texte. Le focus est restauré, les mots de passe sont effacés à la fermeture, et le temps bloqué est mesuré.

- Garde-fous : Une minuterie de 150 ferme la feuille si la fenêtre se ferme, si la session change ou si la BaseDn change. La feuille doit être demandée sur le Dispatcher. Majuscules et AltGr sont préservés dans les champs.
- Références D1 : `Domenia-Embedded.UI.ps1:Show-DomeniaEmbeddedWindow`, `Domenia-Embedded.UI.ps1:Test-DomeniaEmbeddedHost`, `Domenia-Embedded.UI.ps1:Get-DomeniaSurfaceRecord`, `Domenia-Embedded.UI.ps1:Register-DomeniaSurfaceReady`, `Domenia-Embedded.UI.ps1:Register-DomeniaSurfaceKeys`, `Domenia-Embedded.UI.ps1:Get-DomeniaOwningDialog`, `Domenia-Embedded.UI.ps1:Set-DomeniaSurfaceResult`, `DomeniaDialogLayer`

#### TRV-057 · Thème et accessibilité des panneaux intégrés

`fait` · locale (aucune lecture)

Les contrôles d'une feuille prennent les couleurs de la palette (styles RunButton et BaseButton, couleurs locales anciennes retirées). Infobulles par défaut selon le type (mot de passe jamais enregistré, Annuler ne valide rien…), affichées même désactivées (délai 350 ms), nom et aide d'accessibilité renseignés.

- Références D1 : `Domenia-Embedded.UI.ps1:Set-DomeniaEmbeddedTheme`, `Domenia-Embedded.UI.ps1:Get-DomeniaLogicalControls`

### Garde-fous de l'interface

#### TRV-058 · Confirmation dans la page (demande avec suite)

`fait` · locale (aucune lecture)

Panneau posé en haut du contenu, sans fenêtre ni boucle modale. Il contient : titre, message (2000 caractères au plus), changements avant et après en puces, détails techniques repliés (réservables à Expert), confirmation par texte exact, troisième réponse facultative, style Danger ou Normal. Le focus est sur la réponse sûre et Échap annule. Une seule suite s'exécute une seule fois ; une nouvelle demande retire la précédente. Sans fenêtre principale, une boîte classique sert de repli.

- Garde-fous : Les réponses sûre et de confirmation sont nommées, jamais déduites de leur position. Une demande d'une autre session expire sans rien exécuter. La saisie typée est sensible à la casse. Entrée ne confirme jamais une demande non lue. Fermer la fenêtre retire la demande.
- Références D1 : `Domenia-Inline.UI.ps1:Request-DomeniaInlineConfirmation`, `Domenia-Inline.UI.ps1:Complete-DomeniaInlineRequest`, `Domenia-Inline.UI.ps1:Update-DomeniaInlineTypedState`, `Domenia-Inline.UI.ps1:Get-DomeniaInlinePendingRequest`, `Domenia-Shell.Model.ps1:New-DomeniaInlineRequest`, `Domenia-Shell.Model.ps1:Resolve-DomeniaInlineRequest`, `InlineRequestPanel`, `LblInlineRequestTitle`, `LblInlineRequestMessage`, `LblInlineRequestChanges`, `InlineRequestChangesHost`, `InlineRequestDetails`, `TxtInlineRequestDetails`, `InlineRequestTypedPanel`, `TxtInlineRequestTyped`, `BtnInlineRequestAlternate`, `BtnInlineRequestCancel`, `BtnInlineRequestConfirm`, `XAML:LblInlineRequestTyped`

#### TRV-059 · Blocage limité au périmètre de la demande

`fait` · locale (aucune lecture)

Pendant qu'une demande attend, la navigation, les lectures, la sélection et les autres cibles restent disponibles. Seules les écritures et modifications de son périmètre attendent ; une demande sans périmètre les bloque toutes.

- Garde-fous : Échec fermé sans périmètre.
- Références D1 : `Domenia-Shell.Model.ps1:Test-DomeniaInlineRequestBlocks`, `Domenia-Inline.UI.ps1:Test-DomeniaInlineBlocks`

#### TRV-060 · Contrôle statique des gestionnaires (pas de fenêtre modale)

`ameliore` · locale (aucune lecture)

Analyse un code de gestionnaire à la recherche de fenêtres WPF ou WinForms, de fenêtres XAML, de boucles modales, de MessageBox, de Get-Credential ou d'Out-GridView, et des enveloppes modales de Domenia. Sert aux tests du contrat « aucune fenêtre ».

- Garde-fous : Règle de qualité vérifiée par les tests.
- Références D1 : `Domenia-Shell.Model.ps1:Test-DomeniaInlineCodeSafe`

#### TRV-061 · Résumé de l'opération avant exécution

`fait` · locale (aucune lecture)

Liste chaque option qui change l'effet d'une opération, y compris les options avancées repliées, avec sa valeur en clair (Oui/Non, dates, listes). Les valeurs sensibles affichent « (masqué) » même si l'appelant ne les a pas signalées : détection par nom ou libellé (passe, clé, PIN, LAPS, BitLocker…).

- Garde-fous : Masquage par défaut des secrets. Replier une option change le formulaire, jamais le résumé.
- Références D1 : `Domenia-Shell.Model.ps1:Get-DomeniaOperationSummary`, `Domenia-Shell.Model.ps1:Test-DomeniaShellSensitiveOption`, `Domenia-Shell.Model.ps1:ConvertTo-DomeniaShellValueText`

### Interface

#### TRV-062 · Disposition des colonnes mémorisée

`ameliore` · locale (aucune lecture)

Pour chaque DataGrid de l'application, l'ordre et la largeur des colonnes (100 colonnes au plus, unités Pixel 32..2000 ou Star 0,1..20, Auto, SizeToCells, SizeToHeader) sont mémorisés dans les préférences et restaurés.

- Garde-fous : Valeurs bornées ; aucune ligne de résultat ni secret sérialisé.
- Références D1 : `GridLayoutsJson`, `Domenia-Continuity.UI.ps1:Get-DomeniaGridColumnKey`, `Domenia-Continuity.UI.ps1:Register-DomeniaGridLayout`, `Domenia-Continuity.UI.ps1:Save-DomeniaGridLayout`, `Domenia-Continuity.Model.ps1:ConvertTo-DomeniaColumnLayout`

#### TRV-063 · Kit d'interface partagé de la suite

`fait` · locale (aucune lecture)

SupportSuite.UI.json, commun à DOMENIA, GP et RBP, définit les palettes sombre et claire (tokens de fond, texte, accent, danger, états, graphiques, pastilles, infobulles), les métriques (espacements 8/12/18, champs 40, boutons 36, rayon 12) et le vocabulaire d'état (Prêt, En cours, Arrêt demandé, À vérifier, Échec, Vérifié). Il pose cinq règles : l'apparence ne donne aucun droit, aucun mot de passe dans l'aide, les journaux ou les préférences, un arrêt demandé n'est pas une annulation confirmée, terminé ne veut pas dire vérifié, aucune mutation rejouée automatiquement.

- Garde-fous : Les deux thèmes doivent définir les mêmes tokens en #RRGGBB. Un changement du kit n'est diffusé qu'après validation dans chaque produit avec cette version exacte. Règles de conception opposables.
- Références D1 : `modules/SupportSuite.UI.json`, `Domenia-Release.Model.ps1:Get-DomeniaSuiteKitManifest`, `Domenia-Release.Model.ps1:Test-DomeniaSuiteKitDiffusion`, `SupportSuite.UI.json`

#### TRV-064 · Gestionnaire global des exceptions d'interface

`fait` · locale (aucune lecture)

Toute exception du Dispatcher est journalisée et comptée ; une exception levée pendant l'affichage d'une erreur est annoncée ensuite ; une erreur répétée n'ouvre pas de nouvelle boîte modale ; les erreurs volontairement avalées sont tracées une fois par minute.

- Références D1 : `Domenia-Core.ps1:Register-DomeniaDispatcherExceptionHandler`, `Domenia-Core.ps1:Invoke-DomeniaDispatcherFault`, `Domenia-Core.ps1:Invoke-DomeniaSafeUiAction`, `Domenia-Core.ps1:Write-DomeniaSwallowed`

#### TRV-065 · Menus de copie des grilles de rapport

`fait` · locale (aucune lecture)

Clic droit sur les grilles associations, tentatives, attributs, diagnostic, droits, vérification, inventaire, accès, logiciels, WMI, domaine, base, commandes : copier les lignes sélectionnées ou une colonne précise ; grilles d'appartenance : rechercher l'objet, copier le DN, pourquoi membre.

- Garde-fous : Aucun menu de copie générique sur la grille des secrets.
- Références D1 : `Domenia-Core.ps1:Register-DomeniaContextMenus`, `Domenia-Core.ps1:New-DomeniaCopyContextMenu`, `Domenia-Core.ps1:New-DomeniaMenuItem`, `Domenia-Core.ps1:Get-DomeniaRowText`

#### TRV-066 · Navigation entre espaces et onglets

`ameliore` · locale (aucune lecture)

Amène sur l'espace et l'onglet demandés (anciens noms d'onglets redirigés), affiche les onglets selon le type d'objet, bascule sur le premier espace visible si l'actif est masqué ; Fiabilité et Opérations n'apparaissent que sur route explicite.

- Garde-fous : Une vue Expert demandée depuis Essentiel est montrée pour cette navigation seulement.
- Références D1 : `Domenia-Core.ps1:Select-DomeniaWorkspace`, `Domenia-Core.ps1:Set-VisibleTabsForType`, `Domenia-Core.ps1:Assert-DomeniaWorkspaceSelection`, `Domenia-Core.ps1:Set-TabVisibility`, `Domenia-Main.xaml:TabDashboard`, `Domenia-Main.xaml:TabRelations`, `Domenia-Main.xaml:RelationTabs`, `Domenia-Main.xaml:TabIndexStorage`, `Domenia-Main.xaml:WorkspaceTabs`, `Domenia-Main.xaml:WsSearch`, `XAML:ApplicationToolTabs`, `XAML:TabApplicationTools`, `XAML:TabIndex`, `XAML:TabSupport`

### Interface automatisable

#### TRV-067 · Interface automatisable locale (ligne de commande)

> Reste à faire : Contrat Domenia.Automation/1 (commandes, options, bornes, codes de sortie), validation de la ligne de commande et aperçu en place (shell.automation.contract, shell.automation.preview) ; reste l’entrée en ligne de commande de Domenia.exe (Program.cs, fichier partagé de la composition) et la lecture de la base SQLite locale de Domenia 1 (Domenia.Store, schéma 11).

`partiel` · lecture locale

Domenia-Automate.ps1 (contrat Domenia.Automation/1) : commandes version, etat (identité, révision, synchronisations, volumes), postes, observations (familles Presence, Console, Inventory, Probe:\*), associations et requetes, sur la base SQLite locale en lecture seule ; JSON ou CSV, sur la sortie ou dans un fichier.

- Garde-fous : Aucun port, service, liaison annuaire ni écriture dans la base ; périmètre obligatoire et unique (OU, -Computers, -Guids) ; 500 postes, 1 000 lignes par défaut (5 000 max), une ligne de plus pour signaler la troncature ; codes de sortie 0/2/3/4/5 ; valeurs SQL échappées, OU en GLOB insensible à la casse Unicode ; CSV neutralisé. Aucun port, service, liaison AD ni contact poste ; réponse datée puis arrêt ; 1 000 lignes par défaut, 5 000 max, 500 noms, troncature toujours signalée.
- Références D1 : `Domenia-Automate.ps1`, `Domenia-Automation.Model.ps1:Get-DomeniaAutomationContract`, `Domenia-Automation.Model.ps1:Test-DomeniaAutomationRequest`, `Domenia-Automation.Model.ps1:Get-DomeniaAutomationQuery`, `Domenia-Automation.Model.ps1:Get-DomeniaAutomationPerimeterSql`, `Domenia-Automation.Model.ps1:ConvertTo-DomeniaAutomationItems`, `Domenia-Automation.Model.ps1:New-DomeniaAutomationEnvelope`, `Domenia-Automation.Model.ps1:ConvertTo-DomeniaAutomationCsv`, `Domenia-Automation.Model.ps1:Get-DomeniaAutomationLimits`, `Domenia-Automate.ps1:Get-DomeniaAutomationSection`, `Domenia-Automate.ps1:Import-DomeniaAutomationSqlite`, `modules/Domenia-Automation.Model.ps1:Get-DomeniaAutomationContract`

#### TRV-068 · Dossier de diagnostic hors ligne (CLI)

> Reste à faire : Règles du dossier de diagnostic écrites (dossier daté jamais réutilisé, empreintes SHA-256, écriture à côté puis renommage) ; reste la commande « dossier » de la ligne de commande, qui attend Program.cs (fichier partagé) et la base locale.

`partiel` · lecture locale

Commande dossier : écrit dans un nouveau dossier daté (jamais réutilisé) l'état, les postes, observations, associations et requêtes du périmètre (OU, noms ou GUID) avec empreintes SHA-256, écrit à côté puis renommé.

- Garde-fous : Aucune copie partielle laissée, même sur pipeline interrompu.
- Opérations : `OfflineDossier`
- Références D1 : `Domenia-Automate.ps1 (dossier)`, `modules/Domenia-Automation.Model.ps1:New-DomeniaOfflineDossier`

#### TRV-069 · Garde-fous de l'interface automatisable

> Reste à faire : Codes de sortie, bornes, refus des partages, lecteurs mappés et liens, et champs secrets exclus en place dans ShellAutomation et ShellLocalFiles ; reste la vérification de l’empreinte des modules contre le manifeste du pack au lancement en ligne de commande (avec Program.cs, fichier partagé).

`partiel` · locale (aucune lecture)

Exige Windows PowerShell 5.1 64 bits, vérifie l'empreinte du cœur et des modèles contre le manifeste, réutilise le lecteur SQLite du cœur extrait par arbre syntaxique, refuse une base ou une destination sur partage réseau, lecteur mappé ou lien ; codes de sortie 0, 2, 3, 4, 5 ; écriture atomique UTF-8 (BOM pour CSV).

- Garde-fous : Base occupée annoncée (code 3) ; extension de fichier vérifiée.
- Références D1 : `Domenia-Automate.ps1:Assert-DomeniaAutomationIntegrity`, `Domenia-Automate.ps1:Test-DomeniaAutomationLocalPath`, `Domenia-Automate.ps1:Stop-DomeniaAutomation`, `Domenia-Automate.ps1:Write-DomeniaAutomationText`

### Journal technique

#### TRV-070 · Journal de session lisible (Essentiel) ou brut (Expert)

`a-faire` · locale (aucune lecture)

En Essentiel, chaque entrée tient sur une ligne : HH:mm, icône de niveau, phrase bornée à 280 caractères. Les avertissements et erreurs de Write-AppLog sont gardés. En Expert, le format brut et le bouton État du moteur restent disponibles. Le nombre de lignes est plafonné et l'enregistrement dans Domenia.log est identique dans les deux profils.

- Garde-fous : Les doublons techniques (zone Technique) n'apparaissent pas dans la vue lisible. Les annonces au lecteur d'écran sont réservées aux avertissements et erreurs. Texte masqué une seule fois ; avertissement que la copie peut contenir des noms.
- Références D1 : `Domenia-Experience.UI.ps1:ConvertTo-DomeniaExperienceLogEntry`, `Domenia-Experience.UI.ps1:Add-DomeniaExperienceLogEntry`, `Domenia-Experience.UI.ps1:Update-DomeniaExperienceLogView`, `LstUiLogReadable`, `TxtUiLog`, `BtnRuntimeHealth`, `Domenia-Core.ps1:Add-DomeniaUiLog`, `Domenia-Core.ps1:Clear-DomeniaUiLog`, `Domenia-Core.ps1:Set-Status`, `Domenia-Core.ps1:Register-DomeniaReliabilityUi`, `Domenia-Main.xaml:TxtUiLog`, `Domenia-Main.xaml:LstUiLogReadable`, `Domenia-Main.xaml:BtnCopyUiLog`, `Domenia-Main.xaml:ChkUiLogCopyMask`, `Domenia-Main.xaml:BtnClearUiLog`, `Domenia-Main.xaml:ChkUiLogFollow`, `Domenia-Main.xaml:ChkUiLogErrorsOnly`, `Domenia-Main.xaml:TxtSuiteLogFind`, `Domenia-Main.xaml:CmbSuiteLogSize`, `XAML:LblStatus`

#### TRV-071 · Journal replié avec dernière ligne et pastille d'erreur

`a-faire` · locale (aucune lecture)

Replié, le journal montre sa dernière ligne colorée et une pastille rouge « N erreurs » non lues. Un clic sur la barre le déplie. La hauteur dépliée (100 à 600) et l'état replié sont mémorisés. Le bouton « Ouvrir le journal » des bannières le déplie.

- Garde-fous : Replier ne coupe pas l'enregistrement. Un repli dû à un écran court reste transitoire.
- Références D1 : `Domenia-Experience.UI.ps1:Set-DomeniaExperienceJournalLayout`, `Domenia-Experience.UI.ps1:Update-DomeniaExperienceLogBadge`, `Domenia-Experience.UI.ps1:Open-DomeniaExperienceJournal`, `Domenia-Experience.UI.ps1:Save-DomeniaExperiencePreferences`, `Domenia-UX.UI.ps1:Switch-DomeniaUxLog`, `BtnUxLogToggle`, `LblUiLogLast`, `UiLogErrorBadge`, `UxLogHeader`, `UxLogRow`, `LogGridSplitter`, `XAML:LblUiLogErrorBadge`

#### TRV-072 · Rechercher dans le journal

`a-faire` · locale (aucune lecture)

Recherche littérale, sans tenir compte de la casse, dans le journal affiché, entrée par entrée en vue lisible. Entrée ou Suivant passe à l'occurrence suivante en boucle et met le suivi automatique en pause ; l'indication « Ligne N · suivi en pause » s'affiche.

- Garde-fous : Aucune expression régulière, aucune requête.
- Références D1 : `Domenia-Experience.UI.ps1:Find-DomeniaExperienceLog`, `Domenia-Experience.Model.ps1:Find-SuiteLiteralText`, `TxtSuiteLogFind`, `BtnSuiteLogNext`, `LblSuiteLogFind`

#### TRV-073 · Copier le journal avec masquage des noms

`a-faire` · locale (aucune lecture)

Copie le journal tel qu'il est affiché (filtre compris), après masquage des secrets. L'option « Masquer les noms » remplace aussi chemins AD, UPN, DOMAINE\compte, adresses IP, noms DNS d'au moins trois labels, domaine, NetBIOS, serveur, compte et nom de l'objet sélectionné. Les noms de fichiers et les versions sont conservés. Le masquage est un « meilleur effort » annoncé comme tel.

- Garde-fous : Protect-DomeniaLogText est toujours appliqué. Le masquage est un meilleur effort, à relire avant envoi.
- Références D1 : `Domenia-Experience.UI.ps1:ConvertTo-DomeniaMaskedLogText`, `Domenia-Experience.UI.ps1:Get-DomeniaExperienceLogCopyText`, `BtnCopyUiLog`, `ChkUiLogCopyMask`, `Protect-DomeniaLogText`

#### TRV-074 · Effacer le journal affiché

`a-faire` · locale (aucune lecture)

Vide la vue lisible et la pastille d'erreurs non lues. Domenia.log n'est pas modifié.

- Garde-fous : Le journal sur disque est conservé.
- Références D1 : `Domenia-Experience.UI.ps1:Clear-DomeniaExperienceLogEntries`, `BtnClearUiLog`

#### TRV-075 · Alerte « Journal indisponible »

`a-faire` · locale (aucune lecture)

Pastille affichée quand Domenia.log n'est pas inscriptible. Son infobulle donne le chemin du journal de secours et la cause.

- Garde-fous : Bascule visible vers le journal de secours.
- Références D1 : `Domenia-Experience.UI.ps1:Update-DomeniaExperienceLogBadge`, `UiLogUnavailableBadge`

#### TRV-076 · Provenance d'une mesure enregistrée

`a-faire` · locale (aucune lecture)

Texte de provenance : dernière réussite, dernière tentative et son erreur, écriture locale, définition du collecteur, dates incohérentes nommées.

- Garde-fous : Rien n'est corrigé.
- Références D1 : `Domenia-Collection.Model.ps1:Format-DomeniaObservationProvenance`

#### TRV-077 · Trace des requêtes de lecture

`a-faire` · locale (aucune lecture)

Chaque requête trace sa publication (lignes transmises) et ses lots SQLite (enregistrement et relecture, durée) en une ligne de synthèse.

- Garde-fous : Défauts de trace comptés, jamais bloquants.
- Références D1 : `Domenia-DirectoryStore.UI.ps1:Invoke-DomeniaDirectoryStoreTick`, `Add-DomeniaRequestTraceEvent`, `Complete-DomeniaRequestTrace`

#### TRV-078 · Trace des erreurs volontairement ignorées

`a-faire` · locale (aucune lecture)

Chaque erreur qu'un bloc catch ne relance pas entre dans un anneau borné en mémoire (heure, catégorie, opération, type, message masqué). Au plus une ligne par minute, catégorie et opération va au journal technique, avec le nombre d'occurrences regroupées. Les règles pures l'utilisent aussi dans les workers.

- Garde-fous : Ne lève jamais d'exception et n'écrit rien dans le pipeline ; les messages échantillonnés sont masqués.
- Références D1 : `Domenia-Common.Model.ps1:Add-DomeniaSwallowedEntry`, `Domenia-Common.Model.ps1:Get-DomeniaSwallowedEntries`, `Domenia-Common.Model.ps1:Write-DomeniaRuleSwallowed`, `Domenia-Core.ps1:Write-DomeniaSwallowed`

#### TRV-079 · Ligne de synthèse par requête dans Domenia.log

`a-faire` · écriture

Une ligne au niveau Trace par requête terminée : référence, références des jobs, phases et total jusqu'à la dernière publication. Elle n'est écrite que lorsque plus aucun job de la requête n'est ouvert et ne contient aucun nom de cible.

- Garde-fous : Le niveau Trace ne va que dans Domenia.log, pas dans le journal de session.
- Références D1 : `Domenia-Observability.UI.ps1:Write-DomeniaTraceSummaryLog`, `Domenia-Engine.UI.ps1:Write-DomeniaTrace`

#### TRV-080 · Journal de connexion

`a-faire` · locale (aucune lecture)

Trace détaillée de chaque tentative de connexion (étapes, candidats, codes), avec chemin d'urgence si le stockage des données est refusé.

- Garde-fous : Aucun mot de passe ni requête sérialisée ; taille bornée.
- Références D1 : `Domenia-Core.ps1:Get-DomeniaFastLoginLogPath`, `Domenia-Core.ps1:Write-DomeniaFastLoginLog`, `Domenia-Core.ps1:Add-DomeniaFastLoginDetail`

#### TRV-081 · Journal technique Domenia.log

`a-faire` · locale (aucune lecture)

File en mémoire écrite toutes les 500 ms et à la fermeture, rotation à 5 Mo (une génération .1), un enregistrement par ligne (CR/LF/TAB échappés, piles en continuation), replis LOCALAPPDATA puis TEMP avec pastille visible, lignes perdues comptées ; vue technique gardant 5 000 lignes.

- Garde-fous : Une valeur d'annuaire contenant un saut de ligne ne peut forger un enregistrement.
- Références D1 : `Domenia-Core.ps1:Write-AppLog`, `Domenia-Core.ps1:Write-DomeniaAppLogFile`, `Domenia-Core.ps1:Flush-DomeniaAppLog`, `Domenia-Core.ps1:Invoke-DomeniaAppLogFlush`, `Domenia-Core.ps1:Invoke-DomeniaAppLogRotation`, `Domenia-Core.ps1:ConvertTo-DomeniaLogFileLines`, `Domenia-Core.ps1:Get-DomeniaAppLogFallbackPaths`, `Domenia-Core.ps1:Set-DomeniaAppLogAvailability`, `Domenia-Core.ps1:Stop-DomeniaAppLogQueue`, `Domenia-Main.xaml:TabLog`, `Domenia-Main.xaml:TxtLog`

#### TRV-082 · Ouvrir le journal

`a-faire` · lecture locale

Ouvre Domenia.log depuis Accueil > Détails de la session.

- Références D1 : `Domenia-Core.ps1:Open-DomeniaAuditLog`, `Domenia-Main.xaml:BtnDashOpenLog`

#### TRV-083 · Codes incident et regroupement des erreurs

`a-faire` · locale (aucune lecture)

Chaque erreur affichée reçoit un code INC-XXXX identique à l'écran, dans Domenia.log et dans l'incident Support ; une même signature (type, message, source) n'écrit qu'une ligne par minute avec un compteur.

- Garde-fous : Mémoire bornée ; deux erreurs différentes ne partagent jamais un code.
- Références D1 : `Domenia-Core.ps1:New-DomeniaIncidentCode`, `Domenia-Core.ps1:Get-DomeniaErrorSignature`, `Domenia-Core.ps1:Register-DomeniaErrorOccurrence`, `Domenia-Core.ps1:Add-DomeniaErrorIncidentCode`, `Domenia-Core.ps1:Show-DomeniaOperationError`

### Livraison

#### TRV-084 · Identité unique de livraison

`a-faire` · locale (aucune lecture)

Un contrat de livraison unique fixe le build (ex. 2026.10.02-DOMENIA-1.0-RC1.11.0-D120), la version, l'étape, les canaux, les composants et l'empreinte du registre des workers. Journal, fenêtre, archive, manifeste et rapport en tirent leur texte, et la cohérence est vérifiée sur chaque surface : un texte qui ressemble seulement à l'identité ou qui nomme un autre build est incohérent.

- Garde-fous : Une étape déjà utilisée par un autre build est refusée. Domenia.exe est gardé octet pour octet, sa version déclarée à part et liée à son SHA-256.
- Références D1 : `Domenia-Release.Model.ps1:Test-DomeniaReleaseContract`, `Domenia-Release.Model.ps1:Get-DomeniaReleaseIdentity`, `Domenia-Release.Model.ps1:Test-DomeniaReleaseConsistency`, `Domenia-Release.Model.ps1:ConvertFrom-DomeniaBuildLabel`, `Domenia-Release.Model.ps1:Get-DomeniaBuildLabelTokens`, `Domenia-Release.Model.ps1:Get-DomeniaWorkerRegistryFingerprint`

#### TRV-085 · PROD autonome et reconstruction reproductible

`a-faire` · locale (aucune lecture)

La PROD se limite à Domenia.exe et wad/ : aucun test, aperçu, fixture, démo, outil, donnée privée ni script de lancement, et chaque fichier ouvert au démarrage est livré. Une reconstruction depuis le commit et l'environnement documentés doit nommer chaque composant (mêmes fichiers, mêmes SHA-256, dépendances binaires épinglées), avec un écart signalé fichier par fichier.

- Garde-fous : Avec le manifeste, la vérification devient une liste positive.
- Références D1 : `Domenia-Release.Model.ps1:Test-DomeniaProdLayout`, `Domenia-Release.Model.ps1:Compare-DomeniaRebuildManifest`, `Domenia-Release.Model.ps1:Test-DomeniaReleaseRelativePath`, `Domenia-Release.Model.ps1:Join-DomeniaReleasePath`, `Domenia-Release.Model.ps1:ConvertTo-DomeniaReleaseCanonicalText`

#### TRV-086 · Installation atomique par version

`a-faire` · locale (aucune lecture)

La nouvelle version est préparée à côté de l'active et vérifiée fichier par fichier. Ensuite, sous verrou exclusif : sauvegarde du code précédent, écriture du marqueur pending, remplacement (manifeste en dernier), contrôle de l'ensemble et retrait du marqueur, qui est le seul point d'activation. Chaque état intermédiaire et chaque interruption ont une version complète à charger.

- Garde-fous : Tout lanceur refuse pendant l'installation ; un mélange de versions est refusé avant toute lecture.
- Références D1 : `Domenia-Release.Model.ps1:Get-DomeniaInstallPlan`, `Domenia-Release.Model.ps1:Get-DomeniaInstallTimeline`, `Domenia-Release.Model.ps1:Test-DomeniaLaunchSet`, `Domenia-Release.Model.ps1:Resolve-DomeniaInstallInterruption`, `Support/INSTALLER-MISE-A-JOUR.ps1`

#### TRV-087 · Avis de schéma de données et retour de version

`a-faire` · locale (aucune lecture)

À la mise à jour, l'installateur compare le schéma de données de la version active et de la nouvelle (DataSchemaVersion) et annonce la migration avant la réponse de l'opérateur. Il ne touche jamais la base : l'application la migre à son premier démarrage, après sauvegarde vérifiée. Une version plus ancienne refuse une base plus récente sans la modifier, et le seul retour possible est la restauration explicite d'une sauvegarde lisible, la base courante étant sauvée d'abord.

- Garde-fous : Abaisser le schéma n'est permis que dans une restauration explicite ; les reçus ne sont jamais une étape.
- Références D1 : `Domenia-Release.Model.ps1:Get-DomeniaDataSchemaTransition`, `Domenia-Release.Model.ps1:Get-DomeniaSchemaRestorePlan`, `Domenia-Release.Model.ps1:ConvertFrom-DomeniaSchemaLabel`, `Domenia-Release.Model.ps1:Test-DomeniaSchemaStepSafety`

#### TRV-088 · Désinstallation sûre

`a-faire` · locale (aucune lecture)

Seuls les fichiers de code qui portent encore leur hash de manifeste sont retirés ; un fichier modifié depuis l'installation est gardé et nommé, et son dossier reste. Préférences, wad\data et sauvegardes du code ne partent que sur le choix LocalData=Supprimer, les données du profil communes aux copies que sur ProfileData=Supprimer. Le verrou de cycle de vie est retiré en dernier.

- Garde-fous : Un arbre DEV ou une mise à jour inachevée ne sont jamais retirés ; les comptes du coffre Windows ne sont pas supprimés.
- Références D1 : `Domenia-Release.Model.ps1:Get-DomeniaUninstallPlan`

#### TRV-089 · Intégrité et confiance de l'éditeur séparées

`a-faire` · locale (aucune lecture)

L'intégrité (chaque fichier est celui que liste le manifeste) et la confiance de l'éditeur (statut Authenticode valide et certificat signataire parmi les empreintes épinglées) sont deux réponses distinctes. Une distribution modifiée ne garde jamais un statut de signature valide, même si un fichier substitué porte sa propre signature valide.

- Garde-fous : Un nom ou un sujet seul ne prouve rien ; ne propose jamais d'affaiblir une protection Windows.
- Références D1 : `Domenia-Release.Model.ps1:ConvertTo-DomeniaPublisherPin`, `Domenia-Release.Model.ps1:Test-DomeniaSignerTrust`, `Domenia-Release.Model.ps1:Get-DomeniaSignatureVerdict`, `Domenia-Release.Model.ps1:ConvertTo-DomeniaSha256Text`

### Migrations

#### TRV-090 · Lecture tolérante du magasin de vues

`a-faire` · locale (aucune lecture)

Aplatit les tableaux imbriqués des anciennes versions, garde telles quelles les entrées illisibles ou d'autres domaines (comptées), écrit sous forme bornée.

- Garde-fous : Rien n'est perdu ni réparé silencieusement.
- Références D1 : `Domenia-SearchWorkspace.Model.ps1:ConvertFrom-DomeniaSearchWorkspaceStore`, `Domenia-SearchWorkspace.Model.ps1:ConvertTo-DomeniaSearchWorkspaceStoreText`

#### TRV-091 · Dates de relation en UTC

`a-faire` · locale (aucune lecture)

Dates stockées en ISO 8601 UTC ; les anciennes dates sans décalage sont lues en heure locale ; affichage « 08/10 09:15 » (année si différente), tri sur l'instant, mémo de session (50 000).

- Garde-fous : Date illisible triée la plus ancienne.
- Références D1 : `Domenia-Relations.Model.ps1:ConvertTo-DomeniaRelationUtcDate`, `Domenia-Relations.Model.ps1:Get-DomeniaRelationWhenTicks`, `Domenia-Relations.Model.ps1:ConvertTo-DomeniaRelationWhenText`, `Domenia-Relations.Model.ps1:Format-DomeniaRelationWhen`, `Domenia-Relations.Model.ps1:Get-DomeniaRelationWhenSortKey`

### Mise en page

#### TRV-092 · Disposition réservée avec menu de débordement

`fait` · locale (aucune lecture)

La taille des emplacements dépend de l'échelle (1 à 4) et de la largeur, jamais du nombre de tâches. Si la largeur manque, les actions passent dans un menu de débordement et le message est tronqué avec points de suspension et infobulle complète. Une largeur minimale est calculée. L'indication de la barre de recherche est alignée sur le texte saisi.

- Garde-fous : Clipped est signalé sous la largeur minimale.
- Références D1 : `Domenia-Shell.Model.ps1:Get-DomeniaReservedLayout`

#### TRV-093 · Position de l'interrupteur selon la largeur

`ameliore` · locale (aucune lecture)

Quand la zone principale fait moins de 1000 unités, l'interrupteur lecture seule passe de l'en-tête de page à la barre du haut, pour laisser la place au titre sans ajouter de ligne.

- Garde-fous : L'interrupteur lui-même n'est pas modifié.
- Références D1 : `Domenia-UX.UI.ps1:Set-DomeniaUxHeaderLayout`, `UxReadOnlyHost`, `UxHeaderTools`

#### TRV-094 · Mise en page écran court ou étroit

`fait` · locale (aucune lecture)

Sous 940 unités de hauteur : légendes des filtres masquées (infobulles conservées), journal replié temporairement, aide fermée, badge de session à côté du titre. Sous 700 : espacements réduits. Sous 560 : options de requête compactes, panneaux optionnels repliés. Le menu se replie sous 1280 de largeur. Rien de tout cela ne modifie les préférences enregistrées.

- Garde-fous : Toutes les commandes restent atteignables. L'état transitoire n'est jamais enregistré.
- Références D1 : `Domenia-UX.UI.ps1:Get-DomeniaUxHeightPlan`, `Domenia-UX.UI.ps1:Set-DomeniaUxShortLayout`, `Domenia-UX.UI.ps1:Set-DomeniaSearchQueryOptionsLayout`, `Domenia-UX.UI.ps1:Get-DomeniaUxAvailableSize`, `Domenia-UX.UI.ps1:Update-DomeniaUxLayout`, `BtnSearchQueryOptions`, `UxSearchFilterCard`, `UxResultBar`

#### TRV-095 · Panneaux redimensionnables

`ameliore` · locale (aucune lecture)

Séparateurs glissants entre l'arbre des OU et la liste, entre la liste et l'aperçu latéral, et entre les panneaux de l'inventaire, de l'explorateur WMI et de la référence des commandes ; la largeur de l'arbre et la hauteur du journal sont mémorisées dans les préférences (valeurs bornées).

- Garde-fous : Redimensionner ne lance aucune lecture ni aucun calcul ; tailles bornées à la lecture des préférences.
- Références D1 : `XAML:SearchOuSplitter`, `XAML:SearchPreviewSplitter`, `XAML:UxSplitter0`, `XAML:UxSplitter2`, `XAML:UxSplitter3`, `XAML:UxSplitter4`, `XAML:UxSplitter5`, `Domenia-Experience.Model.ps1:ConvertTo-DomeniaExperienceSettings`

### Moteur

#### TRV-096 · Classification structurée des erreurs

`a-faire` · locale (aucune lecture)

Lit toute la chaîne d'exceptions (HRESULT, code natif, sous-code « data 52e/775… », messages serveur) et le marqueur [DOMENIA:Kind;natif;0xcode] pour classer : CredentialPaused, AccountLocked, AccountUnavailable, LogonFailure, AccessDenied, Unavailable (réessayable), Uncertain, ModuleUnavailable, Unknown ; indique si un autre compte peut être proposé.

- Garde-fous : Un délai dépassé n'implique jamais de mauvais identifiants ; définition autonome copiée dans chaque runspace worker. Un délai ou un module absent ne propose jamais un autre compte ; issue inconnue = aucun rejeu.
- Références D1 : `modules/Domenia-Guard.Model.ps1:Get-DomeniaStructuredError`, `Domenia-Access.Model.ps1:Get-DomeniaErrorDecision`, `Domenia-Access.UI.ps1:Get-DomeniaAccessFailureKind`, `Domenia-Access.UI.ps1:ConvertTo-DomeniaAccessCategory`, `Get-DomeniaStructuredError`

#### TRV-097 · Estimation d'impact avant une opération

`a-faire` · locale (aucune lecture)

Résume l'estimation en une phrase (« Environ 2 min · 238 objets lus dans l'annuaire · aucun poste contacté ») et détaille pour l'Expert : éléments, volume réseau, débits moyen et de pointe, parallélisme, lectures AD par seconde, replis par tâches planifiées et appels au Planificateur, charge estimée du contrôleur, fiabilité calibrée sur N exécutions réelles, historique ms/élément et taux de réussite.

- Garde-fous : Aucun vocabulaire moteur dans la phrase ; mesures enregistrées dans Domenia.db pour affiner les estimations. L'opération ne part qu'une fois, depuis la confirmation.
- Opérations : `IndexBuild`, `LogonHarvest`, `ParkSweep`, `UserComputerProbe`
- Références D1 : `modules/Domenia-Confirmation.UI.ps1:Format-DomeniaOperationImpact`, `modules/Domenia-Confirmation.UI.ps1:Format-DomeniaByteEstimate`, `Domenia-Core.ps1 l.14301, l.20422`, `Domenia-Core.ps1:Get-DomeniaOperationImpactEstimate`, `Domenia-Core.ps1:Request-DomeniaOperationImpact`

#### TRV-098 · Classification de l'effet d'une opération

`a-faire` · locale (aucune lecture)

Tout identifiant Write&lt;Nom> est une écriture AD ; les autres effets (action distante, écriture locale, lecture) viennent de la table des opérations ; un identifiant inconnu n'est jamais traité comme une lecture.

- Garde-fous : Fail closed : inconnu = Unknown = traité comme modification (reçu exigé, verrou d'écriture).
- Références D1 : `modules/Domenia-Safety.Model.ps1:Get-DomeniaOperationEffect`, `modules/Domenia-Engine.Model.ps1:Get-DomeniaOperationTable`

#### TRV-099 · Réinitialisation des protections au changement de session

`a-faire` · locale (aucune lecture)

Quand l'époque de session change, les reçus sont relus, l'autorisation d'intervention et le brouillon de fiche sont effacés ; un job de reçus sorti sans rappel ne bloque pas les écritures pour le reste de la session.

- Garde-fous : Aucun consentement ne survit à une autre session.
- Opérations : `ReceiptStore`
- Références D1 : `modules/Domenia-Guard.UI.ps1:Initialize-DomeniaGuard`, `modules/Domenia-Guard.UI.ps1:Start-DomeniaReceiptRefresh`

#### TRV-100 · Lectures isolées hors processus

`a-faire` · lecture réseau

Si Features.IsolatedReads est actif (désactivé par défaut), une lecture revue pour l'isolement (drapeau Isolable), à charge utile simple et sans compte explicite peut tourner dans un processus auxiliaire borné. Le corps vérifié et les données passent par le tube privé, jamais par la ligne de commande.

- Garde-fous : Aucun compte explicite ne traverse la frontière du processus ; jamais pour une écriture ; interface et écritures non concernées par l'arrêt ; rien sur la ligne de commande. Jamais pour une écriture, jamais en démonstration ; aucun identifiant ne franchit la frontière du processus.
- Opérations : `IsolatedRead`, `ComputerDiagnostics`, `ComputerInventory`, `ComputerPing`, `SoftwareInventory`, `TreeChildren`, `WmiClasses`, `WmiNamespaces`, `WmiQuery`
- Références D1 : `modules/Domenia-Isolation.Worker.ps1:Get-DomeniaIsolatedReadWorkerCode`, `modules/Domenia-Engine.UI.ps1 l.301`, `Get-DomeniaIsolationDecision`, `Domenia-Engine.Model.ps1:Get-DomeniaIsolationDecision`, `Domenia-Engine.UI.ps1:Get-DomeniaDispatchIsolation`, `Domenia-Engine.UI.ps1:New-DomeniaIsolatedReadPayload`

#### TRV-101 · Budget de collecte par widget

`a-faire` · locale (aucune lecture)

Un widget ajouté collecte directement jusqu'à 200 postes ; au-delà, ou pour une actualisation/reprise, le nombre est confirmé ; plafond « Plafond des widgets » (0 = aucun par défaut).

- Garde-fous : Raison affichée en barre d'état ; 0 = pas de plafond mais confirmation conservée. Compté sur les postes restant à lire ; limite 1 à 2 000.
- Références D1 : `Domenia-WidgetCollect.Model.ps1:Get-DomeniaWidgetCollectAdmission`, `Domenia-Park.UI.ps1:Get-DomeniaWidgetMaxTargets`, `Domenia-WidgetCollect.Model.ps1:Get-DomeniaWidgetCollectSlot`

#### TRV-102 · Identité des demandes préparées (session, génération, DN)

`a-faire` · locale (aucune lecture)

Chaque action préparée garde l'époque de session, la génération de la sélection et le DN. Une réponse tardive ou une confirmation ne s'applique que si ces trois éléments sont inchangés.

- Garde-fous : Une réponse obsolète est ignorée.
- Références D1 : `Domenia-Assist.UI.ps1:New-DomeniaAssistRequest`, `Domenia-Assist.UI.ps1:Test-DomeniaAssistRequestCurrent`, `Domenia-Assist.UI.ps1:Test-DomeniaComputerServicesCurrent`

#### TRV-103 · Budget des vérifications sur sélection

`a-faire` · locale (aucune lecture)

Au plus Streaming.MaxUserProbes (1 à 3, défaut 2) vérifications simultanées, deux places du moteur réservées aux actions interactives, rien en démonstration ni pendant une écriture ou une purge.

- Garde-fous : Politique de repos C1 ; lecture CIM désactivable (Remote.UseCim).
- Opérations : `LiveConsole`, `LiveSelectedPing`
- Références D1 : `Domenia-Live.UI.ps1:Start-DomeniaLiveBackgroundWork`, `Domenia-Live.UI.ps1:Get-DomeniaLiveWorkerCount`, `Domenia-Live.UI.ps1:Test-DomeniaLiveBackgroundAllowed`

#### TRV-104 · Isolement et limites d'exécution des sondes

`a-faire` · locale (aucune lecture)

Budgets appliqués par le collecteur (2 000 instances, 256 Kio de détails, requête ≥ 10 s, tâche 30 s + 12 s par sonde jusqu'à 300 s) et plan d'isolement (processus auxiliaire borné si IsolatedReads, sinon moteur hors interface), avec ce qui n'est pas garanti.

- Garde-fous : Aucun bac à sable promis : la protection repose sur l'absence de code.
- Opérations : `LiveConsole`, `IsolatedRead`
- Références D1 : `Domenia-ProbeContract.Model.ps1:Get-DomeniaProbeExecutionLimits`, `Domenia-ProbeContract.Model.ps1:Get-DomeniaProbeIsolationPlan`

#### TRV-105 · Collecteur unifié ping, console, inventaire, sondes

`a-faire` · lecture réseau

Corps épinglé unique : ping IPv4 d'abord, puis une session CIM DCOM (impersonation LogonUser ou compte), console Win32_ComputerSystem.UserName, inventaire léger (OS, build, démarrage, modèle, RAM, C:), sondes du catalogue, contrôleur détecté par ProductType, validation AD du compte console (même domaine, comptes système exclus, réutilisée 5 min).

- Garde-fous : Ni WinRM ni SMB ; noms de classe et propriétés validés ; classe absente du catalogue refusée ; ping obligatoire optionnel ; échecs indépendants par consommateur.
- Opérations : `LiveConsole`, `LiveSelectedPing`
- Références D1 : `Domenia-Live.Model.ps1:Get-DomeniaLiveProbeCode`, `Domenia-Live.Model.ps1:Invoke-WSharedRead`, `Domenia-Live.Model.ps1:Get-NativeCode`, `Domenia-Live.Model.ps1:Step-WReadProgress`

#### TRV-106 · Regroupement des requêtes CIM

`a-faire` · locale (aucune lecture)

Console, inventaire et sondes d'une même classe et d'un même filtre partagent une seule requête ; le nombre de requêtes évitées est mesuré et affiché.

- Garde-fous : Filtres comparés octet par octet ; requête jointe refusée → repli sur la lecture de base.
- Opérations : `LiveConsole`
- Références D1 : `Domenia-Collection.Model.ps1:Get-DomeniaCimGroupKey`, `Domenia-Collection.Model.ps1:Measure-DomeniaCimQueryPlan`, `Domenia-Live.Model.ps1:Get-WCimGroupKey`, `Domenia-Live.Model.ps1:Invoke-WSharedRead`

#### TRV-107 · Budgets par sous-réseau présumé

`a-faire` · locale (aucune lecture)

Chaque contrôleur ou sous-réseau /24 présumé a son budget de lectures simultanées : hausse additive, baisse de moitié sur lenteur ou échec, suspension doublée et bornée puis reprise progressive ; dernière adresse vue par poste mémorisée (20 000 noms).

- Garde-fous : Jamais au-delà du plafond choisi ; poste éteint, refus ou compte rejeté ne pénalisent pas le site ; postes sans adresse sur un budget qui ne suspend jamais ; le budget ne décide jamais une mesure.
- Opérations : `ParkPing`, `LiveConsole`
- Références D1 : `Domenia-Collection.Model.ps1:New-DomeniaSourcePolicy`, `Domenia-Collection.Model.ps1:Register-DomeniaSourceOutcome`, `Domenia-Collection.Model.ps1:Test-DomeniaSourceAdmission`, `Domenia-Collection.Model.ps1:Get-DomeniaSourceOpenSeconds`, `Domenia-Collection.Model.ps1:Get-DomeniaReadStepLatencyMs`, `Domenia-Collection.Model.ps1:Get-DomeniaSubnetKey`, `Domenia-Collection.Model.ps1:Get-DomeniaCollectionSourceKey`, `Domenia-Collection.Model.ps1:New-DomeniaCampaignSources`, `Domenia-Collection.Model.ps1:Get-DomeniaCampaignSourceSummary`, `Domenia-Collection.UI.ps1:Register-DomeniaTargetAddress`, `Domenia-Collection.UI.ps1:Get-DomeniaKnownTargetGroup`, `Domenia-Park.UI.ps1:Register-DomeniaParkPingOutcome`, `Domenia-Park.UI.ps1:Register-DomeniaParkMeasurement`

#### TRV-108 · Classification avant nouvel essai

`a-faire` · locale (aucune lecture)

Classe chaque échec (transitoire, hors ligne, injoignable, WMI inaccessible, refus, identifiants) ; seul un incident transitoire d'un poste prouvé joignable est relu, à 30 s puis ×4 jusqu'à 5 min, 3 essais au plus.

- Garde-fous : Jamais pour une écriture, un compte rejeté, un droit refusé, un poste hors ligne ou une classe absente.
- Opérations : `LiveConsole`
- Références D1 : `Domenia-Collection.Model.ps1:ConvertTo-DomeniaCollectionFailure`, `Domenia-Collection.Model.ps1:Get-DomeniaCollectionRetryDecision`

#### TRV-109 · Progression mesurée d'une campagne

`a-faire` · locale (aucune lecture)

Chaque ping ou requête CIM terminé est un pas : distingue un poste lent qui avance d'un poste bloqué ; temps total, temps depuis le dernier résultat validé et attente réelle avec places libres.

- Garde-fous : Résultats validés = relus après COMMIT.
- Opérations : `LiveConsole`
- Références D1 : `Domenia-Collection.Model.ps1:Get-DomeniaCampaignProgressState`, `Domenia-Park.UI.ps1:Get-DomeniaParkReadProgressSnapshot`, `Domenia-Live.Model.ps1:Step-WReadProgress`

#### TRV-110 · États d'une mesure

`a-faire` · locale (aucune lecture)

Vocabulaire unique pour toutes les familles : Connue, Jamais relevée, Non lue, Refusée, Expirée, Incomplète, Erreur ; compteurs et texte « 1 jamais relevé, 2 en erreur ».

- Garde-fous : Une absence ne devient jamais zéro, valeur saine ou date fraîche ; présence et console inconnues après une tentative plus récente en échec.
- Références D1 : `Domenia-Collection.Model.ps1:Get-DomeniaMeasureStateKeys`, `Domenia-Collection.Model.ps1:Get-DomeniaMeasureStateLabel`, `Domenia-Collection.Model.ps1:Get-DomeniaMeasureState`, `Domenia-Collection.Model.ps1:Measure-DomeniaMeasureStates`, `Domenia-Collection.Model.ps1:Format-DomeniaMeasureStates`, `Domenia-Collection.Model.ps1:Test-DomeniaMeasureRefusal`

#### TRV-111 · Populations comparables

`a-faire` · locale (aucune lecture)

Décrit ce qu'un chiffre, widget, liste ou export compte (domaine, périmètre, profondeur, types, critères, instantané) et nomme chaque différence entre deux populations.

- Garde-fous : Description absente jamais présumée identique.
- Références D1 : `Domenia-Collection.Model.ps1:New-DomeniaPopulationDescriptor`, `Domenia-Collection.Model.ps1:Compare-DomeniaPopulation`

#### TRV-112 · Clés d'état de présence

`a-faire` · locale (aucune lecture)

Clés stables Online, NoReply, Error, Pending, Unknown, None lues par couleurs, pastilles, filtres et compteurs, avec conversion des anciens libellés stockés.

- Garde-fous : Un libellé peut changer sans changer le sens.
- Références D1 : `Domenia-Live.Model.ps1:Get-DomeniaPresenceStateKeys`, `Domenia-Live.Model.ps1:ConvertTo-DomeniaPresenceStateKey`, `Domenia-Live.Model.ps1:Get-DomeniaPresenceStateLabel`

#### TRV-113 · Un relevé par portée

`a-faire` · locale (aucune lecture)

Deux portées indépendantes, « Liste » (recherche, sélection, OU, tableau, requête) et « Poste » (poste ouvert), chacune avec son minuteur, son état et son arrêt.

- Garde-fous : Un relevé d'une portée ne bloque jamais l'autre ; minuteur protégé qui tourne aussi fenêtre réduite.
- Références D1 : `Domenia-Park.UI.ps1:Get-DomeniaParkRuns`, `Domenia-Park.UI.ps1:Get-DomeniaParkRun`, `Domenia-Park.UI.ps1:Get-DomeniaParkRunById`, `Domenia-Park.UI.ps1:Test-DomeniaParkRunActive`, `Domenia-Park.UI.ps1:Test-DomeniaParkRunCurrent`, `Domenia-Park.UI.ps1:Start-DomeniaParkRunTimer`, `Domenia-Park.Model.ps1:Get-DomeniaParkRunSlot`

#### TRV-114 · Minuteur de la recherche progressive

`a-faire` · locale (aucune lecture)

Minuteur protégé de 80 ms quand il y a du travail (20 ms sur un arriéré), 1 s au repos ; tranches de 12 lignes en 6 ms ou 400 lignes en 30 ms pour les grandes listes.

- Garde-fous : Relancé par une nouvelle recherche après trois erreurs (FI-05) ; aucun appel réseau dans le tick.
- Références D1 : `Domenia-Live.UI.ps1:Initialize-DomeniaLive`, `Domenia-Live.UI.ps1:Test-DomeniaLiveTickNeeded`, `Domenia-Live.UI.ps1:Invoke-DomeniaLiveTick`, `New-DomeniaTimer`

#### TRV-115 · Échappement RFC 4515 des valeurs LDAP

`a-faire` · locale (aucune lecture)

Échappe NUL, parenthèses, antislash et étoile ; une étoile tapée peut rester joker, les étoiles consécutives sont fusionnées. Même règle générée pour le worker (Escape-WLdap).

- Garde-fous : Comparaison numérique des caractères (évite le piège culturel 5.1 du tiret conditionnel).
- Références D1 : `Domenia-Search.Model.ps1:ConvertTo-DomeniaLdapLiteral`, `tools/sync_worker_ldap_rules.py`

#### TRV-116 · Échappement des barres obliques dans un ADsPath

`a-faire` · locale (aucune lecture)

Dans LDAP://serveur/DN, un « / » d'une valeur RDN est écrit « \/ » sans double échappement ; jumeau généré côté worker.

- Références D1 : `Domenia-Search.Model.ps1:ConvertTo-DomeniaAdsPathDn`

#### TRV-117 · Rafraîchissement limité des pastilles et de la portée

`a-faire` · locale (aucune lecture)

Pastilles, portée et aperçu suivent la liste au plus toutes les 200 ms, réarmé tant que la lecture est en cours ; aucun gestionnaire par ligne.

- Références D1 : `Domenia-SearchWorkspace.UI.ps1:Request-DomeniaSearchWorkspaceRefresh`, `Domenia-SearchWorkspace.UI.ps1:Invoke-DomeniaSearchWorkspaceRefresh`, `Domenia-SearchWorkspace.UI.ps1:Invoke-DomeniaSearchWorkspaceListChanged`, `Domenia-SearchWorkspace.UI.ps1:Initialize-DomeniaSearchWorkspace`

#### TRV-118 · Lecture bornée des imbrications côté worker

`a-faire` · lecture réseau

memberOf lu avec ses plages, groupes d'autres domaines listés non lus, groupe principal résolu par SID, mode Confirm pour une question transitive seule (règle IN_CHAIN), un essai d'authentification à la fois.

- Garde-fous : Bail d'authentification libéré après la première réponse ; refus d'identifiants enregistré pour tous les travaux.
- Opérations : `GroupPathRead`
- Références D1 : `Domenia-Membership.Worker.ps1:Get-DomeniaGroupPathWorkerCode`

#### TRV-119 · Clés et égalité des relations

`a-faire` · locale (aucune lecture)

Une relation = un utilisateur, un poste, une nature de preuve ; GUID décisif des deux côtés, sinon login sans domaine/suffixe et premier label DNS sans $ ; clé de stockage compatible avec les anciennes lignes.

- Garde-fous : Une ligne sans GUID et la même avec GUID ne font pas deux relations.
- Références D1 : `Domenia-Relations.Model.ps1:Get-DomeniaRelationKey`, `Domenia-Relations.Model.ps1:Test-DomeniaSameRelation`, `Domenia-Relations.Model.ps1:ConvertTo-DomeniaRelationLoginKey`, `Domenia-Relations.Model.ps1:ConvertTo-DomeniaRelationComputerKey`, `Domenia-Relations.Model.ps1:Get-DomeniaRelationStorageKey`

#### TRV-120 · Index incrémental des liens par poste et utilisateur

`a-faire` · locale (aucune lecture)

Maintient les index poste → liens et utilisateur → liens sans reconstruire toute la table.

- Références D1 : `Domenia-Relations.UI.ps1:Update-DomeniaRelationLinkIndex`, `Rebuild-UserMachineLinkIndex`

#### TRV-121 · Table déclarative unique des opérations

`a-faire` · locale (aucune lecture)

Une ligne par identifiant d'opération : corps épinglé ou non, fournisseur (Directory, Cim, Wts, Storage, Local, Network), effet (Read, LocalWrite, DirectoryWrite, RemoteMutation, Unknown), classe de planification, comptes transmis, ressource protégée et drapeaux Shared, Pool ou Isolable. La table est lue une fois par session. Un identifiant inconnu est traité comme une lecture annuaire explicite, et un effet Unknown n'est jamais traité comme une lecture.

- Garde-fous : Une ligne illisible, un doublon ou une valeur inconnue fait échouer la lecture de la table. Le rattachement fail-closed est vérifié par tests/rules/Engine.Tests.ps1.
- Opérations : `AccountAliasRead`, `AdConsistencyScan`, `AdHealthRead`, `AdSchemaRead`, `BatchNetworkDiag`, `BitLockerPresence`, `CmdletHelp`, `CmdletInventory`, `ComputerAdminShare`, `ComputerDiagnostics`, `ComputerGpUpdate`, `ComputerInventory`, `ComputerLastUser`, `ComputerPing`, `ComputerRestart`, `ComputerServiceControl`, `DcServicesRead`, `DnsReverseLookup`, `DelegationRead`, `DemoDirectory`, `DirectoryAbsenceCheck`, `DocumentStore`, `DomainOverview`, `EmbeddedDirectoryLookup`, `EmbeddedPathBrowse`, `EngineSelfTest`, `GlobalSearch`, `GpoAppliedRead`, `GpoLinksRead`, `GroupPathRead`, `IndexBuild`, `IndexOuList`, `IsolatedRead`, `LegacyMigration`, `LiveCache`, `LiveConsole`, `LiveDirectoryCheck`, `LiveSelectedPing`, `LocalIndexRead`, `LocalQuery`, `LocalStore`, `LockoutDiagnosis`, `LogonByDcRead`, `LogonHarvest`, `MachineIdentityRead`, `OfflineDossier`, `OpenAdObject`, `OpenLinkedObject`, `ParkPing`, `ParkSharedSync`, `ParkSweep`, `PasswordPolicyRead`, `PermissionAnalysis`, `PresenceScan`, `PruneLinks`, `QueryExport`, `QueryLibrary`, `QueryTransfer`, `ReadBitLocker`, `ReadBitLockerKey`, `ReadBitLockerList`, `ReadLaps`, `ReceiptStore`, `RelationHistoryRead`, `RemoteCredentialCheck`, `RimotteRun`, `ScopeReconcile`, `SelectedPresence`, `SelfCheck`, `SessionsList`, `SoftwareInventory`, `StartupWarmCache`, `StorageBackup`, `StorageIntegrity`, `StorageMaintenance`, `StoragePurge`, `StorageUsage`, `TreeChildren`, `UserComputerProbe`, `WmiClasses`, `WmiNamespaces`, `WmiQuery`, `WriteAccountDisabled`, `WriteAccountOptions`, `WriteAttributes`, `WriteCreateOu`, `WriteDeleteObject`, `WriteExpiration`, `WriteExpirePassword`, `WriteGroupMember`, `WriteMoveObject`, `WriteObjectGroup`, `WriteRenameComputer`, `WriteResetPassword`, `WriteUnlock`, `ComputerEventsRead`, `ComputerQuickDiag`, `ConnectorRead`, `DcCompareRead`, `IndexRefresh`, `JoinStateRead`, `LinkHistoryStore`, `LocalAssistant`, `ObjectChanges`, `QuerySchema`, `WidgetWmiDetail`, `ReconcileScope`, `StartupWarmup`, `StorageRetention`, `UpdateStateRead`, `WakeOnLanSend`
- Références D1 : `Domenia-Engine.Model.ps1:Get-DomeniaOperationTable`, `Domenia-Engine.Model.ps1:Get-DomeniaOperationRow`, `Domenia-Engine.Model.ps1:Get-DomeniaOperationProvider`

#### TRV-122 · Classes et priorités des tâches

`a-faire` · locale (aucune lecture)

Chaque tâche a une classe : Write (priorité 0), Explicit (1), Selection (2) ou Background (3). Selection:object ne vaut que pour la clé de remplacement de l'objet sélectionné. Les fins de tâches et les promotions passent par priorité puis par ordre d'arrivée. Seules Write, Explicit et Selection pilotent Annuler, l'étiquette de progression et la dernière tâche suivie.

- Garde-fous : Une écriture est toujours classée Write, quel que soit l'indice donné par l'appelant.
- Références D1 : `Domenia-Engine.Model.ps1:Get-DomeniaTaskClass`, `Domenia-Engine.Model.ps1:Get-DomeniaTaskPriority`, `Domenia-Engine.Model.ps1:Get-DomeniaTaskOrder`, `Domenia-Engine.Model.ps1:Test-DomeniaForegroundTaskClass`, `Domenia-Engine.UI.ps1:Get-DomeniaNextTaskSequence`

#### TRV-123 · Admission et file d'attente bornée

`a-faire` · locale (aucune lecture)

Une demande démarre, attend ou est refusée selon sa classe. Les lectures s'arrêtent à 12 workers physiques ; une action explicite dispose d'une place réservée en plus, une écriture de deux. Deux places restent réservées au premier plan et la file contient 32 entrées au plus. Une écriture n'est jamais mise en attente silencieusement : moteur saturé, elle est refusée.

- Garde-fous : Un refus lève sa raison en clair (« File d'attente pleine », « Limite physique atteinte »).
- Références D1 : `Domenia-Engine.Model.ps1:Test-DomeniaTaskAdmission`, `Domenia-Engine.UI.ps1:Get-DomeniaUiTaskAdmission`, `Domenia-Engine.UI.ps1:Get-DomeniaEngineLimits`, `Domenia-Engine.UI.ps1:Get-DomeniaEngineLoad`, `Domenia-Engine.UI.ps1:Initialize-DomeniaEngineState`

#### TRV-124 · Vieillissement du travail de fond

`a-faire` · locale (aucune lecture)

Un travail de fond qui attend depuis BackgroundAgingSeconds (30 s par défaut) alors qu'aucun autre travail de fond ne tourne peut prendre une place réservée, et dépasser d'une lecture le budget du fournisseur ou du site, sans jamais franchir une pause. Une longue campagne continue ainsi de progresser sous charge.

- Garde-fous : Jamais au-delà de MaxConcurrent ; jamais sur une source en pause, en reprise ou au compte rejeté.
- Références D1 : `Domenia-Engine.Model.ps1:Test-DomeniaBackgroundAgingDue`, `Domenia-Engine.Model.ps1:Get-DomeniaQueuedSeconds`, `Domenia-Engine.Model.ps1:Select-DomeniaNextQueuedEntry`, `Domenia-Engine.Model.ps1:Select-DomeniaNextQueuedTask`

#### TRV-125 · Retrait des demandes trop anciennes et promotion

`a-faire` · locale (aucune lecture)

Une lecture restée plus de MaxQueueWaitSeconds en file (120 s, 5 s au minimum) est retirée avant tout envoi. Les entrées en attente sont promues par priorité tant que l'admission dit « Start » et que le budget de tick (25 ms) le permet.

- Garde-fous : Retrait sans appel réseau, tracé « Retirée de la file avant envoi ».
- Références D1 : `Domenia-Engine.Model.ps1:Test-DomeniaQueuedTaskExpired`, `Domenia-Engine.UI.ps1:Remove-DomeniaQueuedTask`, `Domenia-Engine.UI.ps1:Invoke-DomeniaQueuedTaskPromotion`

#### TRV-126 · Lectures identiques partagées

`a-faire` · locale (aucune lecture)

Une lecture strictement identique se joint à celle déjà en file ou en cours, au lieu d'ouvrir une seconde lecture LDAP ou une seconde sonde. Identique veut dire même opération marquée Shared, même compte lecteur (nom, identité du processus, génération des comptes), même session, même génération, même charge utile et mêmes exigences (délai, durée totale, protection, classe). Chaque abonné reçoit son propre rappel.

- Garde-fous : Jamais pour une écriture ; jamais si la charge utile porte un objet vivant (identifiant, file) ; jamais entre deux comptes.
- Opérations : `AdConsistencyScan`, `AdHealthRead`, `AdSchemaRead`, `DcServicesRead`, `DelegationRead`, `DirectoryAbsenceCheck`, `EmbeddedDirectoryLookup`, `GpoAppliedRead`, `GpoLinksRead`, `GroupPathRead`, `LockoutDiagnosis`, `LogonByDcRead`, `MachineIdentityRead`, `OpenAdObject`, `PasswordPolicyRead`, `RelationHistoryRead`, `SessionsList`
- Références D1 : `Domenia-Engine.Model.ps1:Get-DomeniaTaskDedupKey`, `Domenia-Engine.Model.ps1:Get-DomeniaPayloadDigest`, `Domenia-Engine.Model.ps1:Get-DomeniaTaskReaderIdentity`, `Domenia-Engine.Model.ps1:Get-DomeniaTaskRequirements`, `Domenia-Engine.UI.ps1:Add-DomeniaTaskSubscriber`, `Domenia-Engine.UI.ps1:Invoke-DomeniaTaskSubscribers`

#### TRV-127 · Budgets par fournisseur, par cible et par site

`a-faire` · locale (aucune lecture)

Chaque fournisseur a sa concurrence, son délai, son seuil de pannes et son backoff : Directory 4/30 s, Cim 3/25 s, Wts 2/20 s, Storage 1/30 s, Network 4/10 s. Des pannes répétées suspendent les seules lectures de fond, avec un backoff exponentiel plafonné. Un contrôleur ou sous-réseau présumé a aussi son budget (MaxPerGroup) et sa pause propre après des délais successifs. La reprise est progressive : une lecture de fond de plus par réponse.

- Garde-fous : Les lectures explicites et de sélection partent toujours. Un refus d'accès n'est pas une panne. Un compte rejeté reste bloqué jusqu'à un changement de compte explicite ou une reconnexion.
- Références D1 : `Domenia-Engine.Model.ps1:Get-DomeniaProviderBudget`, `Domenia-Engine.Model.ps1:New-DomeniaProviderState`, `Domenia-Engine.Model.ps1:Get-DomeniaProviderStateKey`, `Domenia-Engine.Model.ps1:New-DomeniaProviderStateEntry`, `Domenia-Engine.Model.ps1:Register-DomeniaProviderOutcome`, `Domenia-Engine.Model.ps1:Test-DomeniaProviderAdmission`, `Domenia-Engine.Model.ps1:Reset-DomeniaProviderState`, `Domenia-Engine.UI.ps1:Register-DomeniaTaskOutcome`

#### TRV-128 · Aucune nouvelle tentative automatique risquée

`a-faire` · locale (aucune lecture)

Une écriture n'est jamais rejouée. Un compte rejeté, un refus d'accès, une annulation ou un succès ne sont jamais retentés automatiquement. Les autres échecs de lecture ont droit à un seul essai.

- Garde-fous : Protège contre le verrouillage de compte.
- Références D1 : `Domenia-Engine.Model.ps1:Test-DomeniaAutoRetryAllowed`, `Domenia-Engine.Model.ps1:ConvertTo-DomeniaProviderOutcome`

#### TRV-129 · Délais de lecture fondés sur la progression

`a-faire` · locale (aucune lecture)

La recherche globale s'arrête après 120 s sans nouvelle ligne AD reçue, ou à 900 s au total. Une autre lecture qui publie sa progression (étape de campagne) s'arrête après son délai sans étape terminée, et à son plafond total. Sans canal de progression, la règle du temps écoulé s'applique. Le message dit les secondes écoulées, l'inactivité et les lignes reçues ; une recherche garde ses résultats partiels.

- Garde-fous : Jamais appliqué à une écriture, une tâche annulée, remplacée ou en nettoyage ; une horloge invalide n'allonge jamais le délai.
- Opérations : `GlobalSearch`
- Références D1 : `Domenia-Engine.Model.ps1:Get-DomeniaReadTimeoutState`

#### TRV-130 · Propriété et libération des ressources

`a-faire` · locale (aucune lecture)

Un registre attribue un propriétaire à chaque minuterie, pool de runspaces, PowerShell et runspace de job. La libération se fait par propriétaire, par identifiant ou par type, et chaque libération s'exécute même si la précédente a échoué ; à la fermeture, minuteries et pools partent sans détruire un job encore actif. Un résumé par type est disponible.

- Garde-fous : Échecs de libération comptés et nommés.
- Références D1 : `Domenia-Engine.Model.ps1:New-DomeniaResourceRegistry`, `Domenia-Engine.Model.ps1:Register-DomeniaResource`, `Domenia-Engine.Model.ps1:Release-DomeniaResources`, `Domenia-Engine.Model.ps1:Get-DomeniaResourceSummary`, `Domenia-Engine.UI.ps1:Register-DomeniaJobResources`, `Domenia-Engine.UI.ps1:Sync-DomeniaJobResources`, `Domenia-Engine.UI.ps1:Register-DomeniaOwnedTimer`, `Domenia-Engine.UI.ps1:Register-DomeniaWorkerPool`

#### TRV-131 · Minuteries protégées et battement de cœur unique

`a-faire` · locale (aucune lecture)

Une fabrique unique crée les minuteries : chacune a un propriétaire, son tick est protégé, une ligne de journal est écrite par erreur, et la minuterie s'arrête après MaxFailures erreurs ou au changement de session. Elles s'abonnent à un battement unique du Dispatcher qui dort jusqu'au prochain abonné dû, regroupe les réveils proches (un quart d'intervalle, 100 ms au plus) et s'arrête quand rien n'est actif. Le poll du moteur ne tourne que s'il reste une tâche.

- Garde-fous : Un abonné ne tourne jamais deux fois à la fois ; un poll arrêté après trois fautes n'est jamais relancé.
- Références D1 : `Domenia-Engine.UI.ps1:New-DomeniaTimer`, `Domenia-Engine.UI.ps1:Get-DomeniaPulse`, `Domenia-Engine.UI.ps1:Start-DomeniaTimer`, `Domenia-Engine.UI.ps1:Stop-DomeniaTimer`, `Domenia-Engine.UI.ps1:Set-DomeniaTimerInterval`, `Domenia-Engine.UI.ps1:Invoke-DomeniaTimerSoon`, `Domenia-Engine.UI.ps1:Invoke-DomeniaTimerTick`, `Domenia-Engine.UI.ps1:Invoke-DomeniaPulse`, `Domenia-Engine.UI.ps1:Update-DomeniaPulseSchedule`, `Domenia-Engine.UI.ps1:Get-DomeniaPulseState`, `Domenia-Engine.UI.ps1:Resume-DomeniaAsyncPoll`, `Domenia-Engine.Model.ps1:Test-DomeniaPulseDue`, `Domenia-Engine.Model.ps1:Get-DomeniaPulseDelay`

#### TRV-132 · Politique de repos selon l'état de la fenêtre

`a-faire` · locale (aucune lecture)

Fenêtre réduite ou masquée : rafraîchissements et reconstructions de vues suspendus. Fenêtre inactive mais visible : l'affichage reste à jour, les lectures réseau de fond attendent. Une écriture en cours suspend aussi les lectures de fond. Le travail explicite, les reçus et les sauvegardes ne sont jamais suspendus. Les sources qui lisent le réseau d'elles-mêmes respectent en plus la fenêtre de collecte du profil.

- Garde-fous : Une activation de fenêtre ne lance jamais une collecte par elle-même ; un tableau de bord sauté est reconstruit une fois au retour.
- Références D1 : `Domenia-Engine.Model.ps1:Get-DomeniaIdlePolicy`, `Domenia-Engine.Model.ps1:Get-DomeniaIdleActivityForSource`, `Domenia-Engine.Model.ps1:Test-DomeniaIdleAllows`, `Domenia-Engine.UI.ps1:Test-DomeniaIdlePolicyEnabled`, `Domenia-Engine.UI.ps1:Test-DomeniaBackgroundWorkAllowed`, `Domenia-Engine.UI.ps1:Update-DomeniaIdlePolicy`, `Domenia-Engine.UI.ps1:Set-DomeniaWindowSuspended`, `Domenia-Engine.UI.ps1:Initialize-DomeniaIdlePolicy`

#### TRV-133 · Enregistrement d'une collecte remplacée

`a-faire` · écriture

Les données d'une collecte devenue périmée (remplacée par une demande plus récente) sont quand même enregistrées dans le contexte de stockage capturé, pour une liste close de rappels d'ingestion. Jamais pour un rendu ordinaire ni pour une écriture AD.

- Garde-fous : Chaque rappel protège sa publication ultérieure dans l'interface.
- Opérations : `LocalStore`
- Références D1 : `Domenia-Engine.UI.ps1:Save-DomeniaSupersededCollection`

#### TRV-134 · Mesures d'exécution en mémoire

`a-faire` · locale (aucune lecture)

Séries bornées aux 512 dernières valeurs : durées des workers par fournisseur et opération, ouverture de runspace, attente en file, retard du battement. Médiane, 95e centile et maximum par préfixe. La recherche locale et les lectures de tableau de bord sont séparées par action pour ne pas fausser les médianes. Rien n'est écrit sur disque.

- Garde-fous : Rien ne sort du processus.
- Opérations : `LocalIndexRead`, `LocalQuery`
- Références D1 : `Domenia-Engine.UI.ps1:Add-DomeniaRuntimeMetric`, `Domenia-Engine.UI.ps1:Get-DomeniaRuntimeMetricSummary`, `Domenia-Engine.UI.ps1:Add-DomeniaTaskRuntimeMetric`, `Domenia-Engine.UI.ps1:ConvertTo-DomeniaTaskErrorInfo`, `Domenia-Engine.Model.ps1:Get-DomeniaRuntimeMetricOperationKey`

#### TRV-135 · Disponibilité de l'annuaire : hors ligne ou lent

`a-faire` · locale (aucune lecture)

Seule une requête annuaire terminée renseigne sur la disponibilité : une panne réseau met hors ligne, un délai dépassé signale « lent » sans déclarer de panne, un succès rétablit. Le retour du réseau n'efface pas la panne : les fiches en cache demandent toujours une relecture.

- Garde-fous : Une annulation n'est pas une preuve.
- Références D1 : `Domenia-Cache.Model.ps1:Resolve-DomeniaDirectoryReachability`

#### TRV-136 · Projection minimale des attributs de liste

`a-faire` · locale (aucune lecture)

Les attributs demandés dépendent du but : Identity, List (19 attributs dont uSNChanged), Groups, Security ou Presence. Une liste qui demanderait des attributs lourds (member, memberOf, nTSecurityDescriptor, tokenGroups, photos, métadonnées de réplication, certificats, \*) est signalée comme non minimale.

- Garde-fous : Aucune projection vide n'est renvoyée, ce qui ferait refuser la lecture.
- Opérations : `GlobalSearch`, `IndexBuild`, `TreeChildren`
- Références D1 : `Domenia-Cache.Model.ps1:Get-DomeniaProjection`, `Domenia-Cache.Model.ps1:Test-DomeniaProjectionMinimal`

#### TRV-137 · Tampon de pages borné (règle présente)

`a-faire` · locale (aucune lecture)

Ajout de pages de 10 à 5000 lignes avec un maximum en mémoire (2000 par défaut) ; les lignes en trop sont refusées et signalées, jamais gardées en silence. Cette règle n'est appelée par aucun module à l'exécution.

- Garde-fous : Doublons comptés.
- Références D1 : `Domenia-Cache.Model.ps1:New-DomeniaPageBuffer`, `Domenia-Cache.Model.ps1:Add-DomeniaPageRows`

#### TRV-138 · Faits explicables

`a-faire` · locale (aucune lecture)

Format commun d'un constat : fait, valeur, état (Constaté, Estimé, Inconnu, Refusé, Indisponible), source, limite (ce que le fait ne prouve pas), hypothèse, date et compte lecteur. Les modules d'accès, d'audit, d'annuaire, de lectures, de sécurité et de poste s'en servent.

- Garde-fous : Chaque affirmation porte sa limite.
- Références D1 : `Domenia-Common.Model.ps1:New-DomeniaFact`

#### TRV-139 · Lecture sûre des DN et des valeurs AD

`a-faire` · locale (aucune lecture)

Découpe des DN bruts selon les échappements (virgule après un nombre pair de barres obliques), parent immédiat, site ou OU d'appartenance, libellé décodé en UTF-8 pour l'affichage. Conversions GUID (octets ou texte), SID, grands entiers ADSI, FILETIME ou ISO vers UTC (0 et max valent « jamais »), lecture tolérante des membres et texte aplati borné à 240 caractères.

- Garde-fous : Un libellé décodé ne sert jamais de délimiteur de périmètre ; un octet invalide reste visible tel quel. Une valeur non lue n'est jamais zéro. Rien n'est inventé pour une valeur absente.
- Références D1 : `Domenia-Common.Model.ps1:Split-DomeniaRawDn`, `Domenia-Common.Model.ps1:Get-DomeniaRawDnParent`, `Domenia-Common.Model.ps1:ConvertFrom-DomeniaDnLabel`, `Domenia-Common.Model.ps1:Get-DomeniaDnSite`, `Domenia-Common.Model.ps1:ConvertTo-DomeniaGuidText`, `Domenia-Common.Model.ps1:Test-DomeniaGuidText`, `Domenia-Common.Model.ps1:ConvertTo-DomeniaSidText`, `Domenia-Common.Model.ps1:ConvertFrom-DomeniaLargeInteger`, `Domenia-Common.Model.ps1:ConvertTo-DomeniaUtcDate`, `Domenia-Common.Model.ps1:ConvertTo-DomeniaFlatText`, `Domenia-Common.Model.ps1:Get-DomeniaMember`, `Domenia-Common.Model.ps1:Get-DomeniaMemberValue`, `Domenia-Common.Model.ps1:Test-DomeniaDictionaryKey`, `Domenia-Common.Model.ps1:Get-DomeniaCollectionItems`, `Domenia-Common.Model.ps1:Get-DomeniaTextHash`, `Domenia-Directory.Model.ps1:Get-DomeniaAttr`, `Domenia-Directory.Model.ps1:Get-DomeniaAttrAll`, `Domenia-Directory.Model.ps1:ConvertTo-DomeniaAdInt64`, `Domenia-Directory.Model.ps1:ConvertTo-DomeniaAdDate`, `Domenia-Directory.Model.ps1:Get-DomeniaAdIntervalState`, `Domenia-Directory.Model.ps1:ConvertFrom-DomeniaAdInterval`, `Domenia-Core.ps1:Convert-DomainToDn`, `Domenia-Core.ps1:Convert-ADLargeIntegerToInt64`, `Domenia-Core.ps1:Convert-FileTimeLabel`, `Domenia-Core.ps1:Convert-DateLabel`, `Domenia-Core.ps1:Convert-GuidLabel`, `Domenia-Core.ps1:Get-DomeniaGridDateShortText`

#### TRV-140 · Source du module Active Directory épinglée

`a-faire` · locale (aucune lecture)

Choisit RSAT système ou les deux DLL Microsoft livrées à côté de Domenia (Microsoft.ActiveDirectory.Management.dll et ActiveDirectoryPowerShellResources.dll), vérifiées par SHA-256, nom, version 10.0.0.0 et jeton de clé publique ; sinon repli LDAP/ADSI.

- Garde-fous : Processus 64 bits exigé ; empreintes figées dans le code ; 22 cmdlets requises sinon voie ADSI.
- Références D1 : `Domenia-Core.ps1:Get-DomeniaAdModuleSources`, `Domenia-Core.ps1:Assert-DomeniaAdBinarySource`, `Domenia-Core.ps1:Get-DomeniaRequiredAdCommands`, `Domenia-Core.ps1:Test-DomeniaAdCommandsAvailable`, `Domenia-Core.ps1:Import-WAdModule`, `Domenia-Core.ps1:Get-WWriteBackend`

#### TRV-141 · Moteur asynchrone de tâches

`a-faire` · locale (aucune lecture)

Chaque lecture ou écriture part dans un runspace (pools préparés pour les lectures fréquentes), file bornée à priorités (écriture, explicite, sélection, arrière-plan), 2 places réservées aux gestes, lectures identiques partagées, budgets par fournisseur, contrôleur et sous-réseau, budget de 25 ms par tick d'interface.

- Garde-fous : Pannes répétées d'un fournisseur mettent en pause ses lectures de fond, jamais les explicites ; une écriture n'utilise jamais un pool.
- Références D1 : `Domenia-Core.ps1:Start-UiTask`, `Domenia-Core.ps1:Complete-UiTasks`, `Domenia-Core.ps1:Initialize-AsyncEngine`, `Domenia-Core.ps1:New-DomeniaWorkerRunspace`, `Domenia-Core.ps1:Invoke-DomeniaJobSuccessUi`, `Domenia-Core.ps1:Invoke-DomeniaJobErrorUi`, `Domenia-Core.ps1:Dispose-AsyncEngine`

#### TRV-142 · Annuler une tâche

`a-faire` · locale (aucune lecture)

« Annuler » vise la tâche de premier plan la plus récente annulable ; une entrée en file est retirée, une lecture native qui ignore l'annulation est détachée (plus de résultat, appel encore compté) ; une écriture n'est jamais annulée.

- Garde-fous : Une demande d'arrêt n'est jamais présentée comme une annulation terminée.
- Références D1 : `Domenia-Core.ps1:Stop-LatestUiTask`, `Domenia-Core.ps1:Request-UiTaskStop`, `Domenia-Core.ps1:Stop-UiTask`, `Domenia-Core.ps1:Detach-DomeniaReadUiTask`, `Domenia-Core.ps1:Complete-DomeniaDetachedReadJobs`, `Domenia-Main.xaml:BtnCancelTask`

#### TRV-143 · Progression des tâches

`a-faire` · locale (aucune lecture)

Barre, libellé et « Annuler » suivent les tâches de premier plan ; une entrée en file est montrée en attente, une lecture détachée en nettoyage ; le badge Opérations compte toutes les tâches.

- Références D1 : `Domenia-Core.ps1:Update-TaskUi`, `Domenia-Core.ps1:Set-ControlsBusy`, `Domenia-Core.ps1:Test-DomeniaControlIsBusy`, `Domenia-Main.xaml:BtnSuiteActivity`, `Domenia-Main.xaml:LblTaskElapsed`

#### TRV-144 · Arrêt contrôlé du moteur en panne

`a-faire` · locale (aucune lecture)

Si la boucle du moteur échoue, l'erreur est écrite une fois par minute et, après trois échecs consécutifs, le minuteur s'arrête avec un message clair.

- Garde-fous : Fermeture possible après confirmation si une écriture était en cours.
- Références D1 : `Domenia-Core.ps1:Register-DomeniaAsyncEngineFault`

#### TRV-145 · Garde des réponses obsolètes

`a-faire` · locale (aucune lecture)

Générations de sélection, de recherche et de session : une réponse arrivée après un changement d'objet, de texte ou de périmètre est ignorée et ne repeuple jamais la vue.

- Références D1 : `Domenia-Core.ps1:Test-DomeniaObjectCallbackIsCurrent`, `Domenia-Core.ps1:Clear-DomeniaCurrentObjectRequest`, `Domenia-Core.ps1:Test-DomeniaSearchStateCurrent`, `Domenia-Core.ps1:Invalidate-DomeniaSearchResults`, `Domenia-Core.ps1:Reset-DomeniaSelectionBoundViews`, `Domenia-Core.ps1:Clear-ObjectDetails`, `Domenia-Core.ps1:Test-DomeniaSecretCallbackCurrent`

#### TRV-146 · Accès LDAP du thread d'interface

`a-faire` · lecture réseau

Construction des chemins LDAP (échappement « / » dans un RDN), DirectoryEntry avec l'identité réellement liée au login, chercheur paginé (MaxPageSize 300, 20 s serveur, 25 s client), règles d'échappement RFC 4515 générées depuis le modèle Recherche.

- Garde-fous : Une seule règle d'échappement pour toute l'interface.
- Références D1 : `Domenia-Core.ps1:Get-LdapPath`, `Domenia-Core.ps1:Get-LdapEntry`, `Domenia-Core.ps1:New-LdapSearcher`, `Domenia-Core.ps1:Get-DomeniaDirectoryBindUser`, `Domenia-Core.ps1:Escape-LdapValue`, `Domenia-Core.ps1:Escape-WLdap`, `Domenia-Core.ps1:ConvertTo-WAdsPathDn`, `Domenia-Core.ps1:New-WSearcher`

### Moteur de requêtes

#### TRV-147 · Compilation typée et contrat versionné des requêtes

`a-faire` · locale (aucune lecture)

Compile chaque recette avec le moteur partagé M4D.Admin.Common.Query (Domenia.Query/1 sous-ensemble de /2), en logique à trois états Vrai/Faux/Inconnu où une valeur absente, expirée, en erreur ou incomplète donne Inconnu, jamais zéro.

- Garde-fous : Version plus récente refusée ; champs et opérateurs fermés ; 64 conditions ; cache des définitions de champs.
- Opérations : `LocalQuery`
- Références D1 : `Domenia-Query.Model.ps1:ConvertTo-DomeniaCompiledQuery`, `Domenia-Query.Model.ps1:New-DomeniaQueryRecipe`, `Assert-DomeniaContractFormat`

#### TRV-148 · Projection des données du parc en enregistrements

`a-faire` · locale (aucune lecture)

Construit pour chaque poste les valeurs AD (et dérivées : libellé OS, version, famille, cycle de vie, Windows 10) et les observations rattachées par GUID, chacune datée et qualifiée (Expiré, Erreur de lecture, Lecture incomplète…).

- Garde-fous : Observation jamais rattachée par DN seul (compte recréé) ; durée de vie 30 jours par défaut ; tolérance horloge +5 min ; un ping ne renouvelle ni console, ni inventaire, ni sonde.
- Opérations : `LocalQuery`
- Références D1 : `Domenia-Query.Model.ps1:ConvertTo-DomeniaQueryRecords`, `Domenia-Query.Model.ps1:Get-DomeniaQueryCollectionRequirements`

#### TRV-149 · Sélection figée par GUID

`a-faire` · locale (aucune lecture)

Une recette peut porter une liste explicite de GUID de postes (issue d'un widget ou d'un point d'attention), enregistrable et identifiée par une empreinte.

- Garde-fous : 20 000 GUID max ; GUID vide ou invalide refusé ; vide ne veut jamais dire « tous ».
- Références D1 : `Domenia-Query.Model.ps1:Get-DomeniaQueryIdentitySelection`, `Domenia-Query.Model.ps1:Get-DomeniaQueryObjectIdSet`, `Domenia-Query.UI.ps1:Show-DomeniaAttentionInWorkshop`

#### TRV-150 · Empreinte canonique et comparaison de définitions

`a-faire` · locale (aucune lecture)

Calcule un SHA-256 canonique de ce qu'une définition évalue et produit un différentiel lisible (conditions, segments, paramètres, répartition, cohérence, sélection, SELECT mémorisé).

- Garde-fous : Ordre des clés, échelle des nombres, ordre des GUID sans effet ; une différence invisible est quand même signalée.
- Références D1 : `Domenia-Query.Model.ps1:Get-DomeniaQueryDefinitionFingerprint`, `Domenia-Query.Model.ps1:ConvertTo-DomeniaQueryCanonicalText`, `Domenia-Query.Model.ps1:Compare-DomeniaQueryRecipeDefinitions`, `Domenia-Query.Model.ps1:Get-DomeniaQueryDefinitionSummary`, `Domenia-Query.Model.ps1:Get-DomeniaQueryClauseLabel`

#### TRV-151 · Liaison d'une requête à sa révision stockée

`a-faire` · locale (aucune lecture)

Détermine si ce qui est évalué est la révision enregistrée, un brouillon modifié, un brouillon non enregistré, une révision archivée ou un modèle livré.

- Garde-fous : Sans lecture confirmée de la bibliothèque, révision « non déterminée ».
- Références D1 : `Domenia-QueryLibrary.Model.ps1:Get-DomeniaQueryDefinitionBinding`, `Domenia-Query.UI.ps1:Get-DomeniaQueryRecipeBinding`

#### TRV-152 · Caches de calcul et anti-rejeu

`a-faire` · locale (aucune lecture)

Réutilise les enregistrements de moins d'une minute et les comptes des widgets si la bibliothèque n'a pas changé ; seuls les widgets visibles et non en pause sont évalués ; chaque rappel vérifie session, génération, instantané et périmètre.

- Garde-fous : Résultat tardif ignoré ; clé de remplacement query:local.
- Opérations : `LocalQuery`
- Références D1 : `Domenia-Query.UI.ps1:Get-DomeniaQueryWidgetRecipes`, `Domenia-Query.UI.ps1:Start-DomeniaQueryEvaluation`, `Domenia-Query.UI.ps1:Request-DomeniaQueryEvaluation`

### Moteur · cache et fraîcheur

#### TRV-153 · Cache du fournisseur logiciels

`a-faire` · locale (aucune lecture)

Garde le dernier calcul de synthèse logiciels tant que les lignes, le jour, les couleurs, la culture, la base et le poste sont identiques (empreinte de contenu).

- Garde-fous : Formes inconnues ou trop grandes non mises en cache ; empreinte détecte une mutation en place.
- Références D1 : `Domenia-Dashboard.UI.ps1:Get-DomeniaCachedSoftwareBoardData`

#### TRV-154 · Caches de plan et de rendu des widgets

`a-faire` · locale (aucune lecture)

Réutilise le plan et l'élément dessiné d'un widget tant que l'empreinte de ses dépendances (données, contexte, thème, largeur, dates) est identique ; index des requêtes enregistrées compilé une fois par bibliothèque.

- Garde-fous : Empreinte SHA-256 de données bornées (4096 nœuds, 256 Ko) ; objets WPF, actions, travaux en attente et formes inconnues jamais mis en cache ; entrées des widgets retirés purgées ; requête ambiguë (Id en double) = absente.
- Références D1 : `Domenia-Widgets.UI.ps1:Get-DomeniaCachedBoardWidgetPlan`, `Domenia-Widgets.UI.ps1:Get-DomeniaWidgetPlanDependencyKey`, `Domenia-Widgets.UI.ps1:Get-DomeniaWidgetRenderKey`, `Domenia-Widgets.UI.ps1:ConvertTo-DomeniaWidgetDependencyStamp`, `Domenia-Widgets.UI.ps1:Get-DomeniaWidgetRecipeIndex`, `Domenia-Widgets.UI.ps1:Get-DomeniaWidgetRecipe`

#### TRV-155 · Âge et validité des observations

`a-faire` · lecture locale

Une observation est fraîche, ancienne (grisée au-delà de 7 jours) ou expirée (écartée au-delà de la durée de conservation, 30 j par défaut) ; durée réglable (Dashboard.ObservationMaxAgeDays, 1 à 3650).

- Garde-fous : Date illisible ou à plus de 5 min dans le futur = expirée.
- Références D1 : `Domenia-Boards.Model.ps1:Test-DomeniaObservationAge`, `Domenia-Boards.Model.ps1:ConvertFrom-DomeniaUtcText`, `Domenia-Dashboard.UI.ps1:Get-DomeniaObservationMaxAgeDays`

#### TRV-156 · Mémoire des capacités des postes

`a-faire` · locale (aucune lecture)

Retient pour un temps limité qu'une classe est absente (7 jours, invalidé par un nouveau build), que WMI est inaccessible (15 min) ou refusé (1 h, invalidé par un changement de compte), et retire ces lectures du plan suivant.

- Garde-fous : Une réussite oublie le fait aussitôt ; une lecture forcée ignore la mémoire ; mémoire par session.
- Références D1 : `Domenia-Collection.Model.ps1:New-DomeniaCapabilityMemory`, `Domenia-Collection.Model.ps1:Get-DomeniaCapabilityTtlSeconds`, `Domenia-Collection.Model.ps1:Register-DomeniaCapabilityFact`, `Domenia-Collection.Model.ps1:Clear-DomeniaCapabilityFact`, `Domenia-Collection.Model.ps1:Test-DomeniaCapabilityFact`, `Domenia-Collection.Model.ps1:Get-DomeniaCapabilityPlan`, `Domenia-Collection.Model.ps1:Test-DomeniaWmiClassAbsentText`, `Domenia-Collection.UI.ps1:Get-DomeniaCapabilityMemory`, `Domenia-Collection.UI.ps1:Register-DomeniaCollectionCapabilities`

#### TRV-157 · Cache progressif des recherches et observations

`a-faire` · écriture

Base SQLite du domaine : 20 dernières requêtes par périmètre et 20 000 observations, conservées 30 jours, relues pour l'aperçu ; en mémoire, 20 requêtes et 20 000 lignes au plus ; projection fixe des colonnes.

- Garde-fous : Schéma différent = aucune écriture ; périmètre haché ; 32 Mio par requête, 16 Kio par observation ; aucun secret dans la projection ; un seul écrivain, nouvel essai après 10 s.
- Opérations : `LiveCache`
- Références D1 : `Domenia-Live.Model.ps1:Get-DomeniaLiveCacheCode`, `Domenia-Live.Model.ps1:Assert-DomeniaLiveCacheSchema`, `Domenia-Live.Model.ps1:Add-DomeniaLiveMemoryQuery`, `Domenia-Live.Model.ps1:ConvertTo-DomeniaLiveSnapshot`, `Domenia-Live.UI.ps1:Complete-DomeniaLiveCache`, `Domenia-Live.UI.ps1:Fail-DomeniaLiveCache`, `Domenia-Live.UI.ps1:Get-DomeniaLiveDatabasePath`

#### TRV-158 · Cache négatif des échecs récents

`a-faire` · locale (aucune lecture)

Une cible qui vient d'échouer n'est pas resondée par un rafraîchissement visuel : 120 s pour injoignable ou délai, 600 s pour accès refusé ou prérequis manquant, 24 h pour identifiants rejetés, 60 s sinon. La dernière donnée valide reste affichée et une nouvelle tentative volontaire passe toujours, sauf identifiants rejetés.

- Garde-fous : Un geste manuel passe, sauf après un refus d'identifiants. Identifiants rejetés : « changez de compte avant un nouvel essai ».
- Opérations : `LiveConsole`, `LiveSelectedPing`, `SelectedPresence`
- Références D1 : `Domenia-Live.UI.ps1:Complete-DomeniaLiveStored`, `Domenia-Live.UI.ps1:Start-DomeniaLiveBackgroundWork`, `Register-DomeniaFailure`, `Test-DomeniaNegativeCache`, `Domenia-Cache.Model.ps1:New-DomeniaNegativeCache`, `Domenia-Cache.Model.ps1:Get-DomeniaNegativeTtlSeconds`, `Domenia-Cache.Model.ps1:Register-DomeniaFailure`, `Domenia-Cache.Model.ps1:Clear-DomeniaFailure`, `Domenia-Cache.Model.ps1:Test-DomeniaNegativeCache`, `Domenia-Live.UI.ps1`

#### TRV-159 · Empreinte de définition des sondes

`a-faire` · locale (aucune lecture)

Chaque sonde envoyée porte un hachage de sa définition ; une mesure n'est réutilisée que si la définition est la même.

- Opérations : `LiveConsole`
- Références D1 : `Domenia-Park.Model.ps1:Add-DomeniaRemoteProbeDefinitionHash`

#### TRV-160 · Cache de fiche par GUID et lecteur

`a-faire` · locale (aucune lecture)

Une clé de cache contient le GUID, le domaine et un hash du nom du lecteur, jamais un mot de passe ni un jeton. La validation d'une entrée refuse un même DN pour un autre GUID, un autre domaine, un autre compte lecteur, et un USN venant d'une autre instance de contrôleur ou d'une autre version. La validation (Test-DomeniaCacheEntryValid) n'est pas branchée.

- Garde-fous : Le DN n'entre pas dans la clé. Aucun secret dans les clés.
- Opérations : `OpenAdObject`
- Références D1 : `Domenia-Selection.UI.ps1:Get-DomeniaObjectCacheKey`, `Get-DomeniaCacheKey`, `Domenia-Cache.Model.ps1:Get-DomeniaCacheKey`, `Domenia-Cache.Model.ps1:Test-DomeniaCacheEntryValid`, `Domenia-Selection.UI.ps1`

#### TRV-161 · Politique de fraîcheur avant modification

`a-faire` · lecture locale

Avec un instantané dont l'identité est confirmée, la consultation et la copie restent possibles hors ligne, avec le motif affiché : « Consultation historique hors ligne », « Données en cache, relecture nécessaire », « Opération à vérifier ». La modification exige une lecture AD fraîche confirmée, l'annuaire joignable et aucune écriture incertaine.

- Garde-fous : Raison affichée dans l'info-bulle ; contrôles recalculés à chaque phase. Jamais d'édition sur des données en cache ; pas de nouvelle tentative automatique hors ligne.
- Références D1 : `Domenia-Selection.UI.ps1:Get-DomeniaSelectionCachePolicy`, `Get-DomeniaCacheReadPolicy`, `Get-DomeniaRecordFreshness`, `Domenia-Cache.Model.ps1:Get-DomeniaCacheReadPolicy`, `Domenia-Selection.UI.ps1`

#### TRV-162 · Cache de visite borné

`a-faire` · locale (aucune lecture)

Cache mémoire des lectures (TTL 90 s, objets 45 s, 400 entrées, expirées évincées d'abord), compteurs de hits et évictions, bouton « Vider le cache » sans effet sur AD ; un objet sans GUID n'est pas mis en cache.

- Références D1 : `Domenia-Core.ps1:Get-VisitCacheValue`, `Domenia-Core.ps1:Set-VisitCacheValue`, `Domenia-Core.ps1:Clear-VisitCache`, `Domenia-Main.xaml:BtnDashClearCache`

#### TRV-163 · Calcul différé des onglets lourds

`a-faire` · locale (aucune lecture)

Attributs bruts et droits sont marqués périmés à chaque changement d'objet et calculés une seule fois quand leur onglet devient visible ; les pages cachées ou fenêtres réduites ne sont pas recalculées.

- Références D1 : `Domenia-Core.ps1:Reset-DomeniaDeferredViews`, `Domenia-Core.ps1:Ensure-DomeniaRawAttributes`, `Domenia-Core.ps1:Ensure-DomeniaPermissions`, `Domenia-Core.ps1:Register-DomeniaDeferredViewHandlers`, `Domenia-Core.ps1:Request-DomeniaDashboardRefresh`

### Moteur · noms et valeurs AD

#### TRV-164 · Désambiguïsation des OU homonymes

`a-faire` · locale (aucune lecture)

Deux OU de même nom sont distinguées par leurs parents les plus proches (« Postes (Lyon) », « Postes (Paris) »), jusqu'au chemin complet si nécessaire ; 500 DN max.

- Garde-fous : Affichage seulement : le DN exact reste l'identité.
- Références D1 : `Domenia-Search.Model.ps1:Get-DomeniaOuDistinctLabels`, `Domenia-Search.Model.ps1:Get-DomeniaOuPathNames`

#### TRV-165 · Chemins d'OU lisibles et décodage des DN

`a-faire` · locale (aucune lecture)

Découpe les DN en RDN (virgules échappées, guillemets), décode les paires hexadécimales UTF-8, donne le parent et le chemin « domaine / OU / sous-OU ».

- Références D1 : `Domenia-Search.Model.ps1:Split-DomeniaDn`, `Domenia-Search.Model.ps1:ConvertFrom-DomeniaDnValue`, `Domenia-Search.Model.ps1:Get-DomeniaDnParent`, `Domenia-Search.Model.ps1:Get-DomeniaOuDisplayPath`, `Domenia-Directory.Model.ps1:Get-DomeniaDnDisplayName`, `Domenia-Directory.Model.ps1:Get-DomeniaCnFromDn`, `Domenia-DirectorySync.Model.ps1:Get-DomeniaDnParts`, `Domenia-DirectorySync.Model.ps1:Get-DomeniaDnRdnValue`

### Navigation

#### TRV-166 · Bouton de route « Assistance poste > Intervenir » dans les messages

`ameliore` · locale (aucune lecture)

Un message qui envoie l'opérateur vers Assistance poste > Intervenir (intervention ou lecture autorisée) reçoit dans son bandeau un bouton qui ouvre cette vue.

- Garde-fous : La route ouvre la vue, elle n'autorise ni ne lance rien.
- Références D1 : `modules/Domenia-Accounts.Model.ps1:Get-DomeniaMessageRoute`

#### TRV-167 · Vue Expert ponctuelle depuis Essentiel

`fait` · locale (aucune lecture)

Un raccourci, un menu ou la palette peut montrer une vue Expert pour cette seule consultation, sans changer le profil enregistré. La demande est refusée, avec sa raison, si Expert est masqué par l'administrateur ou si la vue ne s'applique pas (pas de fiche, pas un poste, vue retirée).

- Garde-fous : Le profil n'est jamais modifié.
- Références D1 : `Domenia-Shell.Model.ps1:Get-DomeniaExpertTabDecision`

#### TRV-168 · Menu de navigation latéral

`ameliore` · locale (aucune lecture)

Huit rubriques (Accueil, Rechercher, Fiche, Poste, Utilisateurs et postes, Atelier support, Comptes, Outils) avec icône et libellé. La rubrique active est annoncée « Page actuelle ». Une page indisponible est grisée avec son motif. Seules les destinations listées sont autorisées ; Rechercher met le focus dans la barre.

- Garde-fous : Une route hors liste est refusée. L'état actif ne touche à aucun droit.
- Références D1 : `Domenia-UX.UI.ps1:Get-DomeniaUxRouteNames`, `Domenia-UX.UI.ps1:Invoke-DomeniaUxRoute`, `Domenia-UX.UI.ps1:Get-DomeniaUxNavButtons`, `Domenia-UX.UI.ps1:Sync-DomeniaUxNavigation`, `BtnUxNavHome`, `BtnUxNavSearch`, `BtnUxNavObject`, `BtnUxNavComputer`, `BtnUxNavRelations`, `BtnUxNavSupport`, `BtnUxNavAccounts`, `BtnUxNavTools`, `LblUxSelected`, `Domenia-Main.xaml:UxHeader`, `XAML:UxNavLabelAccounts`, `XAML:UxNavLabelTools`, `XAML:UxNavLabelHome`, `XAML:UxNavLabelSearch`, `XAML:UxNavLabelObject`, `XAML:UxNavLabelComputer`, `XAML:UxNavLabelRelations`, `XAML:UxNavLabelSupport`, `XAML:UxNavIconAccounts`, `XAML:UxNavIconTools`, `XAML:UxNavIconHome`, `XAML:UxNavIconSearch`, `XAML:UxNavIconObject`, `XAML:UxNavIconComputer`, `XAML:UxNavIconRelations`, `XAML:UxNavIconSupport`

#### TRV-169 · Seules Rechercher et Parcourir choisissent le sujet

`fait` · locale (aucune lecture)

Règle : seules Rechercher et Parcourir changent le sujet global. Relations peut chercher une cible d'association sans changer le sujet. Les autres pages affichent la sélection globale.

- Garde-fous : Évite qu'un second sélecteur crée un sujet incohérent.
- Références D1 : `Domenia-Shell.Model.ps1:Get-DomeniaShellPages`, `Domenia-Shell.Model.ps1:Test-DomeniaSelectorAllowed`

#### TRV-170 · Changements de page enregistrés dans l'historique

`fait` · locale (aucune lecture)

Chaque changement d'onglet principal et chaque recherche deviennent des étapes ; la page quittée est capturée dans son état réel.

- Références D1 : `Domenia-Search.UI.ps1:Register-DomeniaNavLocation`, `Domenia-Search.UI.ps1:Enter-DomeniaNavSearch`, `Domenia-Search.UI.ps1:Exit-DomeniaNavSearch`, `Domenia-Search.UI.ps1:Get-DomeniaVisiblePageName`

#### TRV-171 · Effacement de la sélection partout

`fait` · locale (aucune lecture)

Quand la liste ne contient plus la ligne choisie, plus rien de l'ancien objet ne reste affiché (barre, fiche, Assistance poste, Relations).

- Garde-fous : Lectures de fiche arrêtées ; secrets effacés.
- Références D1 : `Domenia-Selection.UI.ps1:Clear-DomeniaSelectionEverywhere`, `Domenia-Selection.UI.ps1:Clear-DomeniaPreloadSelection`, `Clear-Secrets`, `Reset-DomeniaSelectionBoundViews`

### Notifications

#### TRV-172 · Bannières d'information et d'erreur dans la page

`ameliore` · locale (aucune lecture)

Les messages deviennent des bannières dans la page, plus jamais des fenêtres. Information et Succès se ferment après 5 s, sauf avec un détail ou plusieurs paragraphes, et restent sous le pointeur. Attention et Erreur restent jusqu'à fermeture. Trois bannières au plus, la plus ancienne part. Un même message met sa bannière à jour (×N ou heure de mise à jour). Le code INC-XXXX est extrait.

- Garde-fous : Le texte reste dans le journal de session après fermeture. Une erreur reste lisible au-dessus d'une feuille ouverte. Aucune fenêtre métier clandestine après affichage du shell ; un délai n'est jamais présenté comme un refus.
- Références D1 : `Domenia-Embedded.UI.ps1:Get-DomeniaBannerPlan`, `Domenia-Embedded.UI.ps1:Show-DomeniaBanner`, `Domenia-Embedded.UI.ps1:New-DomeniaBannerButton`, `Domenia-Embedded.UI.ps1:Update-DomeniaBannerOccurrence`, `Domenia-Embedded.UI.ps1:Close-DomeniaBanner`, `DomeniaBannerHost`, `Domenia-Core.ps1:Show-ErrorBox`, `Domenia-Core.ps1:Show-InfoBox`, `Domenia-Core.ps1:Show-WarningBox`, `Domenia-Core.ps1:Show-DomeniaPageBanner`, `Domenia-Core.ps1:ConvertTo-DomeniaErrorInfo`, `Domenia-Core.ps1:Test-DomeniaOperatorMessage`, `Domenia-Core.ps1:Test-DomeniaInternalFault`, `Domenia-Core.ps1:Show-DomeniaDialog`, `Domenia-Core.ps1:Show-DomeniaFormDialog`, `Domenia-Core.ps1:Invoke-DomeniaHostWindow`

#### TRV-173 · Actions des bannières

`fait` · locale (aucune lecture)

Boutons possibles : « Copier pour le support » (code, date, occurrences, message, détail, chemin du journal, secrets masqués), « Ouvrir le journal », « Voir/Masquer le détail » (épingle la bannière), « Ouvrir le dossier » dans l'Explorateur, « Aller à » vers l'endroit de l'action, déduit du texte d'un refus si besoin.

- Garde-fous : Une route ne fait que naviguer, rien n'est autorisé ni lancé. La copie support passe par Protect-DomeniaLogText.
- Références D1 : `Domenia-Embedded.UI.ps1:Invoke-DomeniaBannerCommand`, `Domenia-Embedded.UI.ps1:Get-DomeniaBannerSupportText`, `Get-DomeniaMessageRoute`, `Resolve-DomeniaCapabilityRoute`, `Invoke-DomeniaCapabilityRoute`

#### TRV-174 · Avis avec bouton de destination

`fait` · locale (aucune lecture)

Message d'état dont la destination est un bouton (route) et non un chemin écrit. Sans fenêtre principale, la ligne d'état porte seule le message et le nom de l'action.

- Garde-fous : Navigation seulement.
- Références D1 : `Domenia-Embedded.UI.ps1:Show-DomeniaRouteNotice`

### Palette

#### TRV-175 · Catalogue des commandes et règles de disponibilité

`fait` · locale (aucune lecture)

Catalogue fermé de 44 commandes (navigation : recherche, accueil, opérations, journal, index, requêtes, comptes, relations, outils ; local : raccourcis, thème, annuler présentation, copier résumé, diagnostic ; lectures : relire l'objet, auto-vérification, arborescence, diagnostic réseau des postes sélectionnés, ping, sessions, diagnostic, inventaire, logiciels, dernier utilisateur, verrouillages 4740, permissions ; lectures protégées : LAPS, BitLocker ; écritures préparées : modifier fiche, déverrouiller, réinitialiser le mot de passe, activer/désactiver, déplacer, ajouter à un groupe, ajouter/retirer un membre, fiche poste, activer/désactiver/déplacer le poste, gpupdate, redémarrer). Chaque commande est jugée selon la connexion, la sélection, le type d'objet, le mode lecture seule, la démonstration et l'état réel de son bouton (affiché, activé, infobulle).

- Garde-fous : Une commande dont le bouton est grisé reprend sa raison ; écritures préparées indisponibles en démonstration et en lecture seule.
- Références D1 : `modules/Domenia-Commands.Model.ps1:Get-DomeniaCommandCatalogue`, `modules/Domenia-Commands.Model.ps1:Get-DomeniaPaletteEntries`, `modules/Domenia-Commands.Model.ps1:Get-DomeniaCommandEffectText`, `modules/Domenia-Commands.UI.ps1:Get-DomeniaPaletteContext`, `modules/Domenia-Commands.UI.ps1:Get-DomeniaControlReach`, `modules/Domenia-Commands.UI.ps1:Invoke-DomeniaPaletteCommand`

#### TRV-176 · Décision de la palette : jamais d'écriture

`fait` · locale (aucune lecture)

Pour une écriture préparée ou une lecture protégée, la palette amène seulement le bouton à l'écran (ouvre l'espace, les onglets et les expandeurs, donne le focus) sans cliquer ; pour une lecture, elle clique le bouton après avoir revérifié qu'il est activé ; les actions du shell sont exécutées directement.

- Garde-fous : Bouton inaccessible ou devenu indisponible = rien n'est lancé et message ; action indisponible = palette reste ouverte et annonce la raison ; profils et règles Expert respectés par Select-DomeniaWorkspace.
- Références D1 : `modules/Domenia-Commands.Model.ps1:Get-DomeniaPaletteDecision`, `modules/Domenia-Commands.UI.ps1:Invoke-DomeniaPaletteDecision`, `modules/Domenia-Commands.UI.ps1:Invoke-DomeniaCommandPaletteEntry`, `modules/Domenia-Commands.UI.ps1:Show-DomeniaControlInPage`

#### TRV-177 · Palette de commandes (Ctrl+K)

`ameliore` · locale (aucune lecture)

Panneau d'actions filtré par la fiche ouverte, la sélection et les droits. La recherche ignore accents et majuscules et exige que tous les mots soient présents. Les actions disponibles viennent d'abord, puis le rang de correspondance et l'ordre du catalogue (40 au plus). Chaque action affiche son glyphe, son raccourci et, si elle est indisponible, sa raison (celle de l'infobulle du bouton). Flèches pour choisir, Entrée pour exécuter, Échap pour fermer.

- Garde-fous : Une écriture n'est jamais lancée : l'entrée PrepareWrite ou Sensitive amène seulement son bouton au premier plan. Seule une lecture d'un bouton actif est cliquée. En lecture seule ou en démonstration, les écritures sont indisponibles avec leur motif. Ouverture refusée si une feuille attend une réponse ; focus restauré à la fermeture ; zones d'état annoncées aux lecteurs d'écran ; position adaptée à la taille de fenêtre (RDP, zoom). Logique dans Commands.
- Opérations : `BatchNetworkDiag`
- Références D1 : `Domenia-CommandPalette.xaml`, `CommandPalettePanel`, `TxtPaletteSearch`, `LstPaletteCommands`, `LblPaletteDetail`, `LblPaletteStatus`, `BtnPaletteClose`, `BtnCommandPalette`, `Domenia-Commands.Model.ps1:Get-DomeniaPaletteEntries`, `Domenia-Commands.Model.ps1:Select-DomeniaPaletteEntries`, `modules/Domenia-Commands.UI.ps1:Initialize-DomeniaCommandPalette`, `modules/Domenia-Commands.UI.ps1:Show-DomeniaCommandPaletteView`, `modules/Domenia-Commands.UI.ps1:Hide-DomeniaCommandPalette`, `modules/Domenia-Commands.UI.ps1:Update-DomeniaCommandPaletteList`, `modules/Domenia-Commands.UI.ps1:Update-DomeniaCommandPaletteDetail`, `modules/Domenia-Commands.UI.ps1:Invoke-DomeniaCommandPaletteKey`, `modules/Domenia-Commands.UI.ps1:Set-DomeniaCommandPalettePosition`, `modules/Domenia-Commands.UI.ps1:Get-DomeniaPaletteGlyph`, `modules/Domenia-Commands.Model.ps1:Select-DomeniaPaletteEntries`, `modules/Domenia-Commands.Model.ps1:ConvertTo-DomeniaCommandSearchKey`, `Domenia-Core.ps1:Show-DomeniaCommandPalette`, `Domenia-Main.xaml:BtnCommandPalette`

### Raccourcis

#### TRV-178 · Raccourcis clavier

`ameliore` · locale (aucune lecture)

Ctrl+K palette, Ctrl+F recherche, Ctrl+D accueil, Ctrl+L journal de session, Ctrl+I index local, Ctrl+T thème, Ctrl+Maj+C copier le résumé de l'objet, F5 actualiser l'arborescence, F1 outils et aide, Échap fermer le panneau ou effacer la saisie, Ctrl+Z (dans la liste) annuler la présentation ; la liste complète est consultable dans la palette (« Afficher les raccourcis clavier »).

- Garde-fous : Ctrl+Z dans un champ texte reste l'annulation de la frappe. Aucun raccourci ne change le profil.
- Références D1 : `modules/Domenia-Commands.Model.ps1:Get-DomeniaKeyboardShortcuts`, `modules/Domenia-Commands.Model.ps1:Get-DomeniaShortcutListText`, `Register-DomeniaShortcuts (Core)`, `palette:shortcuts`, `Domenia-Core.ps1:Register-DomeniaShortcuts`

#### TRV-179 · Raccourcis clavier des tableaux

`ameliore` · locale (aucune lecture)

Widget focalisable (Tab) : F5 actualiser, Ctrl+C copier, Maj+F10 menu ; en personnalisation Alt+flèches et Alt+Début/Fin déplacer, Alt+Maj+flèches taille, Suppr retirer ; Ctrl+Z annuler ; focus rendu au bon contrôle après redessin.

- Garde-fous : Gestes de disposition seulement en personnalisation ; F5 ignoré sur widget suspendu ; champs texte gardent leurs touches.
- Références D1 : `Domenia-Boards.Model.ps1:Get-DomeniaBoardKeyGesture`, `Domenia-Widgets.UI.ps1:New-DomeniaBoardWidget (PreviewKeyDown)`, `Domenia-Widgets.UI.ps1:Restore-DomeniaBoardFocus`

#### TRV-180 · Raccourci Ctrl+L vers le journal

`fait` · locale (aucune lecture)

Ctrl+L ne change jamais le profil. En Expert (si autorisé), il ouvre Outils > Journal. En Essentiel, il déplie le journal de session et lui donne le focus.

- Garde-fous : Le raccourci respecte UI.AllowExpertProfile.
- Références D1 : `Domenia-UX.UI.ps1:Invoke-DomeniaJournalShortcut`

### Sécurité

#### TRV-181 · Rattachement des observations par GUID

`a-faire` · locale (aucune lecture)

Les observations utilisées par les widgets sont rattachées par GUID aux postes actifs de l'OU ou au poste sélectionné ; un poste déplacé, supprimé ou recréé sous le même DN n'hérite jamais de l'ancienne observation.

- Garde-fous : Sur le parc, observation sans GUID ignorée.
- Références D1 : `Domenia-Widgets.UI.ps1:Get-DomeniaWidgetObservations`, `Domenia-Widgets.UI.ps1:ConvertTo-DomeniaWidgetGuid`, `Domenia-Widgets.UI.ps1:Get-DomeniaWidgetProbeObservations`, `Domenia-Widgets.UI.ps1:Get-DomeniaWidgetCoverage`

#### TRV-182 · Exclusion des secrets dans les exports de diagnostic

`a-faire` · locale (aucune lecture)

Retire récursivement tout champ dont le nom évoque un secret (mot de passe, jeton, LAPS, clé BitLocker…) et liste les chemins exclus dans l'export.

- Garde-fous : Profondeur 32 ; pwdLastSet conservé (date) ; charge illisible ou trop grosse (256 Kio) non reprise.
- Références D1 : `Domenia-Automation.Model.ps1:Test-DomeniaDiagnosticSecretName`, `Domenia-Automation.Model.ps1:Protect-DomeniaDiagnosticValue`

#### TRV-183 · Blocage des écritures distantes

`a-faire` · locale (aucune lecture)

Règle commune aux panneaux distants : écriture interdite en lecture seule, en démonstration, pendant une écriture AD en cours ou dont l'état est inconnu, et quand la sélection n'est connue que par la base locale (hors ligne). Les boutons suivent la même règle que GPUpdate et Redémarrer.

- Garde-fous : Échec fermé. Remote.UseWinRM est respecté partout (repli CIM, diagnostic, GPUpdate, redémarrage différé).
- Références D1 : `Domenia-Assist.UI.ps1:Test-DomeniaAssistWriteBlocked`, `Domenia-Assist.UI.ps1:Test-DomeniaAssistWinRmAllowed`, `Domenia-Assist.UI.ps1:Update-DomeniaComputerAssistPermissions`, `Assert-DomeniaRemoteWriteAllowed`, `Assert-WriteAllowed`, `Get-DomeniaSelectionCachePolicy`

#### TRV-184 · Contrat de validation des recettes

`fait` · locale (aucune lecture)

Avant d'afficher la vue, le contrat des recettes est vérifié : identifiants uniques, symptôme présent, champs Titre, Lit, Pourquoi et Coût remplis, action autorisée et cohérente, effet de l'opération égal à « Read ». Une recette invalide bloque l'ouverture de la vue.

- Garde-fous : Échec fermé : une recette fautive empêche l'ouverture de la vue.
- Références D1 : `Domenia-Assistance.Model.ps1:Test-DomeniaAssistanceRecipes`, `Domenia-Assistance.UI.ps1:Initialize-DomeniaAssistanceView`, `Get-DomeniaOperationEffect`

#### TRV-185 · Isolation de l'atelier par session

`fait` · locale (aucune lecture)

L'état de l'atelier est indexé par l'époque de session, la BaseDn et le compte de liaison. Une reconnexion, même avec le même compte, vide l'atelier. Une minuterie d'une seconde rafraîchit la vue quand elle est visible et s'arrête seule en cas d'erreur.

- Garde-fous : Aucune donnée ne passe d'une connexion à une autre. Dégradation inerte.
- Références D1 : `Domenia-Support.UI.ps1:Get-DomeniaSupportSessionKey`, `Domenia-Support.UI.ps1:Sync-DomeniaSupportSession`, `Domenia-Support.UI.ps1:Update-DomeniaSupportView`, `Domenia-Support.UI.ps1:Stop-DomeniaSupportUi`

#### TRV-186 · Mode écriture confirmé et retour automatique en lecture seule

`a-faire` · locale (aucune lecture)

L'interrupteur Lecture seule demande une confirmation dans la page (« Autoriser les modifications ? », risque Danger) avant d'autoriser les écritures. En mode écriture, son libellé affiche « Écriture active · N min ». Le retour automatique en lecture seule se fait après Security.ReadOnlyReturnMinutes (15 par défaut, borné de 5 à 120) sans écriture, compté depuis l'activation ou la dernière écriture, et attend la fin d'une écriture en cours. Le bouton « Repasser en lecture seule » est immédiat.

- Garde-fous : Le passage est refusé en démonstration. La lecture seule s'applique tant que « Autoriser » n'est pas confirmé. Une date inconnue ne raccourcit jamais le délai. Minuterie de 15 s protégée, qui tourne même fenêtre masquée. Le passage en écriture est journalisé (zone Sécurité). Retour en lecture immédiat sans question ; écriture en cours jamais interrompue ; démo verrouillée.
- Références D1 : `Domenia-Shell.Model.ps1:Get-DomeniaReadOnlyReturnPlan`, `Domenia-UX.UI.ps1:Get-DomeniaUxReadOnlyDelay`, `Domenia-UX.UI.ps1:Request-DomeniaWriteMode`, `Domenia-UX.UI.ps1:Enable-DomeniaWriteMode`, `Domenia-UX.UI.ps1:Enter-DomeniaReadOnlyMode`, `Domenia-UX.UI.ps1:Exit-DomeniaWriteMode`, `Domenia-UX.UI.ps1:Update-DomeniaReadOnlySwitch`, `Domenia-UX.UI.ps1:Get-DomeniaUxReadOnlyPlan`, `Domenia-UX.UI.ps1:Invoke-DomeniaReadOnlyReturnTick`, `Domenia-UX.UI.ps1:Start-DomeniaReadOnlyReturnTimer`, `Domenia-UX.UI.ps1:Stop-DomeniaReadOnlyReturnTimer`, `ChkReadOnlyMode`, `BtnReadOnlyResume`, `UxLockClosed`, `UxLockOpen`, `Domenia-Core.ps1:Wire-Events (ChkReadOnlyMode)`, `Domenia-Core.ps1:Update-DomeniaWriteModeVisual`, `Domenia-Core.ps1:Assert-WriteAllowed`, `Domenia-Main.xaml:ChkReadOnlyMode`, `Domenia-Main.xaml:WriteModeBanner`, `Domenia-Main.xaml:BtnReadOnlyResume`, `XAML:LblWriteMode`, `XAML:UxReadOnlyText`

#### TRV-187 · Compte choisi par ressource et par cible

`a-faire` · locale (aucune lecture)

Juste avant le départ d'un worker, applique le compte Secrets aux lectures LAPS/BitLocker et ne remet un compte local lié à un poste qu'aux opérations dont la ressource est ce poste, avec bail vivant.

- Garde-fous : D051 : jamais un compte local vers LDAP/LAPS/BitLocker ni vers un autre poste ; D054 : bail expiré → compte retiré.
- Opérations : `ReadLaps`, `ReadBitLocker`, `ReadBitLockerKey`, `ReadBitLockerList`
- Références D1 : `Domenia-Sessions.UI.ps1:Set-DomeniaTargetCredentialContext`

#### TRV-188 · Garde anti-Windows Installer

`a-faire` · locale (aucune lecture)

Analyse statique (AST) du code d'inventaire : refuse toute classe servie par MSIProv ou qui y mène (Win32_Product, CIM_Product, ~90 classes), en classe, requête WQL ou chemin WMI, et tout msiexec /f, y compris dans les here-strings des workers.

- Garde-fous : Une comparaison qui ne sert qu'à refuser la classe est admise ; code illisible = inventaire refusé.
- Références D1 : `Domenia-Workstation.Model.ps1:Get-DomeniaMsiProviderClassNames`, `Domenia-Workstation.Model.ps1:Test-DomeniaMsiProviderClass`, `Domenia-Workstation.Model.ps1:Get-DomeniaInventoryCodeFindings`, `Domenia-Workstation.Model.ps1:Test-DomeniaInventoryGuardNode`, `Domenia-Workstation.Model.ps1:Test-DomeniaInventoryCodeSafe`

#### TRV-189 · Vérification du poste qui répond

`a-faire` · locale (aucune lecture)

Chaque lecture CIM compare le DNSHostName/Name renvoyé au nom demandé (forme NetBIOS 15 caractères incluse) ; un autre poste qui répond rend la lecture entièrement non attribuée et l'état d'identité « Incohérente ».

- Garde-fous : Comparaison impossible (adresse IP) = non vérifiée, pas refusée ; le ping reste un fait de l'adresse.
- Opérations : `LiveConsole`, `LiveSelectedPing`
- Références D1 : `Domenia-Live.Model.ps1:Get-LiveHostIdentityCheck`, `Domenia-Live.Model.ps1:Set-LiveIdentityMismatch`, `Domenia-Live.Model.ps1:Get-DomeniaLiveObservationView`

#### TRV-190 · Contrat de sonde Domenia.ProbeContract/1

`a-faire` · locale (aucune lecture)

Chaque sonde est une donnée vérifiée : lecture CIM seulement, classes et espaces de noms refusés (Win32_Product, RSoP, subscription, LDAP…), comptes/groupes locaux seulement, propriétés et filtre bornés, jetons {SINCE_24H}/{SINCE_7D}, types déclarés, privilège, coût, sources Microsoft, tests attendus.

- Garde-fous : Aucune écriture, aucun code, aucune méthode WMI ; coût lourd exige la collecte explicite.
- Références D1 : `Domenia-ProbeContract.Model.ps1:ConvertTo-DomeniaProbeContract`, `Domenia-ProbeContract.Model.ps1:Test-DomeniaProbeContract`, `Domenia-ProbeContract.Model.ps1:Get-DomeniaProbeContract`, `Domenia-ProbeContract.Model.ps1:Test-DomeniaProbeCatalogContracts`, `Domenia-ProbeContract.Model.ps1:Get-DomeniaProbeDeniedClasses`, `Domenia-ProbeContract.Model.ps1:Get-DomeniaProbeDeniedNamespaces`, `Domenia-ProbeContract.Model.ps1:Get-DomeniaProbePrivilege`, `Domenia-ProbeContract.Model.ps1:Get-DomeniaProbeCost`, `Domenia-ProbeContract.Model.ps1:Get-DomeniaProbeExpectedTests`, `Domenia-ProbeContract.Model.ps1:Get-DomeniaProbeBehavior`

#### TRV-191 · Sondes personnalisées déclaratives

`a-faire` · locale (aucune lecture)

Une sonde d'origine « Personnalisée » doit déclarer comportement (lecture CIM, sans écriture, sans code, sans méthode), privilèges, coût, cible, collecte explicite et exclusion des contrôleurs.

- Garde-fous : Rien n'est déduit pour elle ; refus au chargement du catalogue.
- Références D1 : `Domenia-ProbeCatalog.Model.ps1:Assert-DomeniaCustomProbeDeclaration`

#### TRV-192 · Identité de consultation et invalidation

`a-faire` · locale (aucune lecture)

La clé d'identité (session, base, comptes AD et distant, comptes temporaires) est surveillée ; un changement arrête la recherche et les vérifications, vide les observations et marque les lignes « Compte changé · à revérifier ».

- Garde-fous : Les anciens retours portent l'ancienne identité et ne repeuplent jamais le nouveau périmètre.
- Références D1 : `Domenia-Live.UI.ps1:Get-DomeniaLiveIdentityKey`, `Domenia-Live.UI.ps1:Get-DomeniaLiveIdentitySignal`, `Domenia-Live.UI.ps1:Reset-DomeniaLiveIdentity`, `Domenia-Live.Model.ps1:Test-DomeniaLiveIdentity`, `Domenia-Live.Model.ps1:Get-DomeniaLiveHash`

#### TRV-193 · Identité immuable de sélection

`a-faire` · locale (aucune lecture)

Fiche, Relations et Assistance capturent l'objet sélectionné sous une identité immuable : domaine, GUID, SID, type, DN, nom, login, lecteur, époque de session et génération. Un résultat ou une opération préparée ne s'applique que si l'identité capturée correspond encore à la sélection courante (SameContext).

- Garde-fous : Identité du lecteur sans secret (empreinte de référence du compte). Une ligne sans GUID ni type ne donne pas d'identité, donc aucune action.
- Références D1 : `Domenia-Identity.Types.cs:SelectionIdentity`, `Domenia-Selection.UI.ps1:Get-DomeniaRowSelectionIdentity`, `Domenia-Selection.UI.ps1:Get-DomeniaCurrentSelectionIdentity`, `Domenia-Selection.UI.ps1:Test-DomeniaSameSelectionContext`, `Domenia-Selection.UI.ps1:Get-DomeniaObjectReadIdentity`, `New-DomeniaSelectionIdentity`, `Test-DomeniaIdentityCurrent`, `Domenia-Engine.Model.ps1:New-DomeniaSelectionIdentity`, `Domenia-Engine.Model.ps1:Test-DomeniaIdentityCurrent`, `Domenia-Identity.Types.cs:Domenia.SelectionIdentity`

#### TRV-194 · Filtrage des attributs secrets avant stockage

`a-faire` · locale (aucune lecture)

Liste noire côté worker (unicodePwd, historiques, LAPS, BitLocker, gMSA, msDS-KeyCredentialLink…) et liste blanche côté UI avant tout stockage local.

- Garde-fous : Observation sans GUID, DN ou date refusée ; type non pris en charge refusé.
- Opérations : `LocalStore`
- Références D1 : `Domenia-DirectoryStore.Model.ps1:Get-DomeniaDirectoryStoreWorkerPrelude`, `Domenia-DirectoryStore.Model.ps1:ConvertTo-DomeniaDirectoryStoreChange`, `Get-DomeniaSafeObjectPropertyNames`, `Test-DomeniaSensitiveAttributeName`

#### TRV-195 · Reconnaissance des groupes à privilèges

`a-faire` · locale (aucune lecture)

adminCount, SID intégrés 544/548/549/550/551, RID 512/516/517/518/519/520/526/527, noms français et anglais (Admins du domaine, Opérateurs de compte, DnsAdmins…).

- Références D1 : `Domenia-Directory.Model.ps1:Test-DomeniaPrivilegedGroup`

#### TRV-196 · Un compte par ressource protégée

`a-faire` · locale (aucune lecture)

Les comptes temporaires sont rangés par ressource (Annuaire par opération, LAPS, BitLocker, Poste par machine, Présence, Fichier local) et injectés dans le contexte du worker.

- Garde-fous : Changer une ressource ne touche pas les autres ; compte d'une autre session ignoré.
- Références D1 : `Domenia-Access.Model.ps1:Get-DomeniaOperationResource`, `Domenia-Access.UI.ps1:Get-DomeniaAccessScope`, `Domenia-Access.UI.ps1:Get-DomeniaRetryScopeKey`, `Domenia-Access.UI.ps1:Get-DomeniaRetryCredential`, `Domenia-Access.UI.ps1:Set-DomeniaRetryWorkerContext`, `Domenia-Engine.Model.ps1:Get-DomeniaOperationTable`

#### TRV-197 · Une demande par ressource malgré des refus en rafale

`a-faire` · locale (aucune lecture)

Vingt refus simultanés pour une ressource donnent une seule demande (fenêtre 60 s) ; les refus en arrière-plan sont listés sans interrompre l'opérateur.

- Garde-fous : Annuler conserve le compte précédent et gèle les demandes un moment.
- Références D1 : `Domenia-Access.Model.ps1:New-DomeniaDenialCoalescer`, `Domenia-Access.Model.ps1:Add-DomeniaAccessDenial`, `Domenia-Access.Model.ps1:Complete-DomeniaAccessPrompt`, `Domenia-Access.UI.ps1:Add-DomeniaAccessDenialUi`, `Domenia-Access.UI.ps1:Complete-DomeniaAccessPromptUi`, `Domenia-Access.UI.ps1:Get-DomeniaAccessCoalescer`

#### TRV-198 · Un seul rejeu de lecture, jamais d'écriture

`a-faire` · locale (aucune lecture)

Après acceptation d'un autre compte, une lecture peut être relancée une fois (LAPS, BitLocker) ; une écriture ne l'est jamais et l'opérateur relance volontairement.

- Garde-fous : Pas de rejeu si le compte reste en pause.
- Opérations : `ReadLaps`, `ReadBitLocker`
- Références D1 : `Domenia-Access.Model.ps1:Get-DomeniaReauthPlan`, `Domenia-Access.UI.ps1:Invoke-DomeniaAccessRecovery`, `Start-LoadComputerSecrets`

#### TRV-199 · Famille d'échec et droit requis cité

`a-faire` · locale (aucune lecture)

Ajoute à une erreur : refus d'accès (droit requis), compte rejeté (compte concerné), ressource indisponible (accès réseau nécessaire) ; rien sans code.

- Références D1 : `Domenia-Access.Model.ps1:Get-DomeniaFailureFamily`, `Domenia-Access.Model.ps1:Get-DomeniaOperationFailureGuidance`

#### TRV-200 · Aucun repli intrusif pour une lecture

`a-faire` · locale (aucune lecture)

ADMIN$, Planificateur, PsExec ne servent jamais de repli silencieux à une lecture ; une lecture exige un consentement distinct ; une intervention exige l'autorisation explicite du poste.

- Garde-fous : Décision réelle du chemin de repli.
- Opérations : `ComputerLastUser`, `RimotteRun`
- Références D1 : `Domenia-Access.Model.ps1:Test-DomeniaTransportFallbackAllowed`

#### TRV-201 · Contrôle statique anti-affaiblissement de Windows

`a-faire` · locale (aucune lecture)

Refuse en campagne de tests le code qui neutralise la validation de certificat, active WinRM, modifie antivirus, pare-feu ou stratégie d'exécution.

- Références D1 : `Domenia-Access.Model.ps1:Test-DomeniaTransportCodeSafety`

#### TRV-202 · Masquage des secrets dans journaux, traces et exports

`a-faire` · locale (aucune lecture)

Masque clés BitLocker (8×6 chiffres), Bearer/Basic, membres JSON password/token/secret (charge LAPS), formes clé=valeur FR/EN et options -p/-password ; test rapide préalable pour les gros volumes.

- Garde-fous : Campagne de marqueurs secrets. Défense en profondeur, autonome avant chargement des modules.
- Références D1 : `Domenia-Access.Model.ps1:Protect-DomeniaSecretText`, `Domenia-Access.Model.ps1:Get-DomeniaSecretTextHint`, `Domenia-Access.Model.ps1:Test-DomeniaTextHasSecret`, `Domenia-Core.ps1:Protect-DomeniaLogText`

#### TRV-203 · Exports sans secret

`a-faire` · locale (aucune lecture)

Une colonne nommée d'après un attribut secret est retenue (« valeur secrète non exportée ») et chaque texte passe la règle de masquage ; projection par liste blanche disponible (non raccordée).

- Garde-fous : Nombre de valeurs masquées et colonnes retenues retournés.
- Références D1 : `Domenia-Access.Model.ps1:Protect-DomeniaExportRows`, `Domenia-Access.Model.ps1:Select-DomeniaAllowedFields`, `Test-DomeniaSecretAttribute`

#### TRV-204 · Détection d'un refus dans le résultat d'un worker

`a-faire` · locale (aucune lecture)

Inspecte seulement les champs d'état ou d'erreur (64 enregistrements) d'un résultat pour proposer la reprise d'accès.

- Garde-fous : Jamais les valeurs de données ni les secrets ; ignore LiveCache et opérations secrets.
- Références D1 : `Domenia-Access.UI.ps1:Inspect-DomeniaAccessResult`

#### TRV-205 · Comptes purgés au changement de session ou de domaine

`a-faire` · locale (aucune lecture)

Le minuteur d'accès (500 ms en attente, 1 s au repos) oublie tous les comptes temporaires et leurs baux quand la session ou le domaine change, et à la fermeture.

- Garde-fous : Session d'authentification en cours terminée à la fermeture.
- Références D1 : `Domenia-Access.UI.ps1:Initialize-DomeniaAccess`, `Domenia-Access.UI.ps1:New-DomeniaAccessState`, `Domenia-Access.UI.ps1:Test-DomeniaAccessSessionCurrent`

#### TRV-206 · Garde « écriture active ou incertaine »

`a-faire` · locale (aucune lecture)

Tant qu'une écriture tourne ou que son issue est inconnue, navigation de l'historique, requêtes, changement de compte, suppressions de relations et préchargements sont refusés.

- Références D1 : `Domenia-Access.UI.ps1:Test-DomeniaAccessBusyWrite`

#### TRV-207 · Comptes transmis selon l'opération

`a-faire` · locale (aucune lecture)

Pour chaque opération, la table décide quels comptes le worker reçoit (annuaire, distant, machine, Bind), si la ressource est un secret (LAPS, BitLocker) et si un refus d'ouverture de session peut suspendre le canal annuaire. Le compte réellement porté par le contexte est identifié, session Windows implicite comprise ; un identifiant retapé est un nouveau compte.

- Garde-fous : Une lecture distante ne se lie jamais à l'annuaire, sauf ComputerLastUser et LiveConsole. LiveSelectedPing sans identifiants.
- Références D1 : `Domenia-Engine.Model.ps1:Get-DomeniaOperationCredentialNeeds`, `Domenia-Engine.UI.ps1:Get-DomeniaContextCredentialIdentity`, `Domenia-Core.ps1:Get-WorkerContext`, `Domenia-Core.ps1:Initialize-DomeniaWorkerContextCache`, `Domenia-Core.ps1:Get-WAdCredential`, `Domenia-Core.ps1:Get-WRemoteAdminCredential`, `Domenia-Core.ps1:Get-WMachineCredential`

#### TRV-208 · Corps de workers épinglés

`a-faire` · locale (aucune lecture)

Chaque opération épinglée a son corps (texte du worker, couche SQLite et bail compris) fixé par SHA-256 dans un registre fermé (tools/operation-contracts.json). L'empreinte du registre (lignes « Opération=HASH » triées) figure dans le contrat de livraison.

- Garde-fous : Toute modification d'un corps change son hash et doit être revue puis réépinglée. Corps refusé avant mise en file.
- Opérations : `StorageBackup`, `StorageUsage`, `StoragePurge`, `StorageMaintenance`, `StorageRetention`, `StorageIntegrity`, `LocalStore`, `LocalIndexRead`, `DnsReverseLookup`, `ParkSharedSync`, `LegacyMigration`
- Références D1 : `Domenia-Release.Model.ps1:Get-DomeniaWorkerRegistryFingerprint`, `Domenia-Storage.Worker.ps1`, `Domenia-Engine.Worker.ps1`, `Domenia-Migration.Worker.ps1`, `Domenia-Core.ps1:Get-DomeniaWorkerOperationHashes`, `Domenia-Core.ps1:Assert-DomeniaWorkerRegistry`, `Domenia-Core.ps1:Assert-DomeniaWorkerOperationCode`, `Domenia-Core.ps1:ConvertTo-DomeniaCanonicalWorkerCode`, `Domenia-Core.ps1:Get-DomeniaWorkerCodeHash`

#### TRV-209 · Démarrage toujours en lecture seule sur Accueil

`fait` · locale (aucune lecture)

Chaque lancement repart en lecture seule et sur la page Accueil, quel que soit l'état de la session précédente ; aucune lecture longue (vue d'ensemble, balayage, journal DC) n'est lancée au démarrage.

- Garde-fous : Lecture seule non persistée ; Startup.AutoLongOperations=false.
- Opérations : `StartupWarmCache`
- Références D1 : `Domenia-Core.ps1:Initialize-Window`, `Domenia-Core.ps1:Request-DomeniaParkSweepAtStartup`, `Domenia-Core.ps1:Invoke-DomeniaStartupCacheWarmup`, `Domenia-Main.xaml:ChkReadOnlyMode`

#### TRV-210 · Garde de fermeture de la fenêtre

`a-faire` · locale (aucune lecture)

Refuse la fermeture tant qu'une écriture AD attend la confirmation du DC ; si le moteur est arrêté ou les tâches illisibles, demande une confirmation explicite en rappelant que le reçu sera à vérifier. À la fermeture : géométrie, réglages, index, validation de compte, moteur et presse-papiers secret sont nettoyés.

- Garde-fous : Écriture en cours jamais interrompue silencieusement ; reçu durable conservé.
- Références D1 : `Domenia-Core.ps1:Initialize-Window (Add_Closing)`, `Domenia-Core.ps1:Dispose-AsyncEngine`, `Domenia-Core.ps1:Clear-DomeniaSecretClipboard`, `Domenia-Core.ps1:Flush-DomeniaIndex`

#### TRV-211 · État des boutons selon droits et lecture seule

`a-faire` · locale (aucune lecture)

Chaque contrôle d'écriture est classé lecture/écriture et grisé selon la lecture seule, la capacité estimée ou un refus réel mémorisé par capacité, l'objet protégé ou le DN illisible ; « AD injoignable depuis HH:MM » s'affiche tant que l'annuaire ne répond pas.

- Garde-fous : Gardes fermées par défaut (état illisible = lecture seule / protégé).
- Références D1 : `Domenia-Core.ps1:Apply-CurrentPermissionUi`, `Domenia-Core.ps1:Get-WriteControlMap`, `Domenia-Core.ps1:Get-AllWriteControlNames`, `Domenia-Core.ps1:Assert-DomeniaReadWriteControlClassification`, `Domenia-Core.ps1:Set-DomeniaActualCapabilityDenied`, `Domenia-Core.ps1:Test-DomeniaActualCapabilityDenied`, `Domenia-Core.ps1:Assert-DomeniaCapability`, `XAML:LblPrivilegeTop`

#### TRV-212 · Contrôle de fraîcheur avant écriture

`a-faire` · lecture réseau

Le worker relit l'objet sur le DC : il doit exister au même DN, garder son objectGUID, uSNChanged et whenChanged ; un objet protégé (adminCount=1 ou isCriticalSystemObject) est refusé sauf autorisation configurée.

- Garde-fous : Conflit de concurrence = rien n'est écrit, rechargement demandé.
- Opérations : `WriteAttributes`, `WriteAccountDisabled`, `WriteUnlock`, `WriteResetPassword`, `WriteAccountOptions`, `WriteExpiration`, `WriteExpirePassword`, `WriteMoveObject`, `WriteObjectGroup`, `WriteGroupMember`, `WriteRenameComputer`, `WriteDeleteObject`
- Références D1 : `Domenia-Core.ps1:Assert-WObjectFresh`, `Domenia-Core.ps1:Get-WObjectSnapshot`, `Domenia-Core.ps1:Test-WProtectedSnapshot`, `Domenia-Core.ps1:Get-DomeniaSafetyDescriptor`

#### TRV-213 · Plan d'écriture et confirmation en page

`a-faire` · locale (aucune lecture)

Chaque écriture AD construit un plan (cible GUID/DN, changements, contrôleur, compte, empreinte) confirmé par un panneau de la page avec les changements en clair et le détail technique replié ; le plan est revérifié contre la sélection au moment de l'envoi.

- Garde-fous : Aucun plan confirmé = rien n'est envoyé ; empreinte explicite différente refusée.
- Références D1 : `Domenia-Core.ps1:New-DomeniaSelectionWritePlan`, `Domenia-Core.ps1:Request-DomeniaWriteConfirmation`, `Domenia-Core.ps1:Test-DomeniaPlanDispatch`, `Domenia-Core.ps1:Get-DomeniaWriteRoute`, `Domenia-Core.ps1:Confirm-TextAction`

#### TRV-214 · Canal d'écriture unique, verrous et admission

`a-faire` · écriture

Une écriture à la fois par le canal « domenia-write-channel », verrous par cible et classe d'action, admission refusée si le même plan est déjà soumis ou si un reçu reste à vérifier ; délais doux 90 s et dur 300 s ; contrôles de navigation gelés pendant l'écriture.

- Garde-fous : Capacité vérifiée, Assert-WriteAllowed (démo, reçus, lecture seule).
- Opérations : `WriteAttributes`, `WriteDeleteObject`
- Références D1 : `Domenia-Core.ps1:Start-DomeniaWriteTask`, `Domenia-Core.ps1:Get-DomeniaWriteLocks`, `Domenia-Core.ps1:Set-DomeniaWriteTaskOutcome`

#### TRV-215 · Résultat d'écriture, postcondition et compensation

`a-faire` · lecture réseau

Une écriture vérifiée est confirmée dans la page ; la règle de compensation indique, depuis les valeurs relues, si un changement inverse pourrait être préparé (jamais envoyé seul) ; la fiche et l'arbre sont relus ensuite.

- Garde-fous : Drapeau partiel illisible jamais lu comme succès complet.
- Opérations : `OpenAdObject`
- Références D1 : `Domenia-Core.ps1:Complete-DomeniaWriteTaskUi`, `Domenia-Core.ps1:Fail-DomeniaWriteTaskUi`, `Domenia-Core.ps1:Get-DomeniaWritePostcondition`, `Domenia-Core.ps1:Get-DomeniaWriteCompensationText`, `Domenia-Core.ps1:Invoke-DomeniaWritePostAction`, `Domenia-Core.ps1:Invoke-DomeniaPostWriteRefresh`

#### TRV-216 · Postcondition des actions distantes

`a-faire` · locale (aucune lecture)

Pour gpupdate, redémarrage, exécution : la livraison n'est pas l'effet ; sans relecture du poste l'état reste « À vérifier » avec la vérification à faire.

- Garde-fous : Interrupteur de lecture seule illisible bloque l'action distante.
- Opérations : `ComputerGpUpdate`, `ComputerRestart`, `RimotteRun`
- Références D1 : `Domenia-Core.ps1:Get-DomeniaRemotePostconditionText`, `Domenia-Core.ps1:Assert-DomeniaRemoteWriteAllowed`

#### TRV-217 · Mots de passe en SecureString

`a-faire` · locale (aucune lecture)

Les mots de passe viennent de PasswordBox.SecurePassword ou du coffre, sont copiés scellés pour le worker et ne deviennent une chaîne qu'au dernier moment pour l'API Windows ; jamais journalisés, affichés ou passés en argument de processus.

- Garde-fous : Aucun fichier IPC de mot de passe ni processus PowerShell enfant.
- Références D1 : `Domenia-Core.ps1:ConvertTo-DomeniaSecureString`, `Domenia-Core.ps1:Get-LdapEntry`, `Domenia-Core.ps1:New-WEntry`, `Domenia-Core.ps1:New-WRootDse`, `Domenia-Core.ps1:Reset-UserPassword`

#### TRV-218 · Validation des cibles de poste

`a-faire` · locale (aucune lecture)

Un poste visé doit être un nom NetBIOS ou DNS valide issu d'AD (253 caractères max) ; jokers, listes, chemins et options natives refusés ; l'étiquette d'un contrôle ne fournit jamais une cible.

- Références D1 : `Domenia-Core.ps1:Assert-DomeniaComputerTarget`, `Domenia-Core.ps1:Get-SelectedComputerTarget`, `Domenia-Core.ps1:Get-WRemoteComputerName`, `Domenia-Core.ps1:Get-CurrentSelectedComputerName`

### Sécurité · comptes et authentification

#### TRV-219 · Affichage temporaire d'un mot de passe saisi (œil, 5 s)

`a-faire` · locale (aucune lecture)

Montre le mot de passe tapé pendant quelques secondes (5 s par défaut, 1 à 30) dans un calque en lecture seule posé sur la PasswordBox, puis le masque ; un second clic, une frappe, un formulaire occupé ou la fermeture du panneau le masquent aussitôt. Utilisé à la connexion et dans le panneau Compte poste.

- Garde-fous : Aucune copie dans un champ éditable, un historique d'annulation ou le presse-papiers ; minuterie protégée qui masque même fenêtre réduite ; texte effacé à la fermeture.
- Références D1 : `modules/Domenia-Accounts.UI.ps1:Show-DomeniaSecretPeek`, `modules/Domenia-Accounts.UI.ps1:Hide-DomeniaSecretPeek`, `LblLoginPasswordPeek`, `BtnRevealMachineAdmin`, `MachineAdminPeek`, `LblMachineAdminPeek`, `XAML:BtnRevealLogin`

#### TRV-220 · Coffre natif : cible protégée et bornes

`a-faire` · lecture locale

Les entrées du Gestionnaire d'identification Windows sont nommées « Domenia:v1:&lt;SHA-256> » d'un texte à composants préfixés par leur longueur (domaine, usage, compte), sans serveur ni chemin de base ; un usage RemoteLocal exige le compte exact du poste et un compte .\x exige un usage RemoteLocal. Lecture, écriture et suppression via CredRead/CredWrite/CredDelete, secret ≤ 2560 octets, identifiant ≤ 256 caractères.

- Garde-fous : Chaque appel natif exige -Enabled ; caractères de contrôle refusés ; collisions de délimiteurs impossibles ; aucun alias d'autorité déduit ; blob natif effacé après lecture ; Windows seulement.
- Références D1 : `modules/Domenia-CredentialVault.Model.ps1:Get-DomeniaCredentialVaultTarget`, `modules/Domenia-CredentialVault.Model.ps1:Initialize-DomeniaCredentialVault`, `modules/Domenia-CredentialVault.Model.ps1:Get-DomeniaCredentialVaultCredential`, `modules/Domenia-CredentialVault.Model.ps1:Save-DomeniaCredentialVaultCredential`, `modules/Domenia-CredentialVault.Model.ps1:Remove-DomeniaCredentialVaultCredential`, `modules/Domenia-CredentialVault.Native.cs:Domenia.Security.CredentialVault`

#### TRV-221 · Correction centralisée d'un compte sans reconnexion (anti-verrouillage)

`a-faire` · locale (aucune lecture)

Chemin unique de toute validation en place (connexion, poste, secrets, temporaire) : la génération de compte avance, ce compte seul et ses alias confirmés sortent de la protection, les lectures parties avec l'ancien mot de passe sont arrêtées et ne peuvent plus s'authentifier, les lectures en file partiront avec le compte validé. Si une autre copie stockée envoie encore ce compte avec un mot de passe non revalidé depuis le refus, la pause reste et l'opérateur est informé.

- Garde-fous : Une écriture n'est jamais arrêtée ni rejouée et garde son compte jusqu'au bout ; opérations suspendues sans compte identifié restent arrêtées jusqu'à la reconnexion ; références faibles (32 max) aux identifiants validés ; défauts levés conservés pour le diagnostic des verrouillages ; demandes d'accès de la ressource closes. Écriture ni interrompue ni rejouée. Aucun essai entre-temps.
- Références D1 : `modules/Domenia-Accounts.Async.ps1:Complete-DomeniaAccountCorrection`, `modules/Domenia-Accounts.Async.ps1:Get-DomeniaAccountCredentialHolders`, `modules/Domenia-Accounts.Async.ps1:Register-DomeniaCredentialValidation`, `modules/Domenia-Accounts.Async.ps1:Get-DomeniaAccountCorrectionJobs`, `modules/Domenia-Access.Model.ps1:Get-DomeniaAccountReleaseDecision`, `modules/Domenia-Access.Model.ps1:Get-DomeniaAccountCorrectionPlan`, `modules/Domenia-Guard.Model.ps1:Clear-DomeniaCredentialGuardFault`, `Domenia-Access.Model.ps1:Get-DomeniaAccountCorrectionPlan`, `Complete-DomeniaAccountCorrection`, `Show-DomeniaDirectoryCorrection`, `Domenia-Access.Model.ps1:Get-DomeniaAccountReleaseDecision`

#### TRV-222 · Rapprochement des noms d'un compte par SID

`a-faire` · lecture réseau

Après chaque identité validée, une seule recherche exacte (sAMAccountName ou UPN, objectCategory=person) lit le SID et les autres noms du compte ; les noms d'un même SID partagent ensuite une seule pause et un seul verrou d'authentification. Comptes locaux ou d'un autre domaine non recherchés.

- Garde-fous : Une fois par session et par identité, file de 8, une lecture à la fois, 3 résultats max (Résolu/Ambigu/Introuvable), délai 30 s, classe Background ; aucune association supposée en cas d'échec ; un nom lié à un autre SID n'est jamais déplacé (conflit journalisé) ; 64 groupes et 16 noms max ; pause existante propagée aux alias ; SID jamais affiché ; jamais en démonstration. Hors démonstration ; une seule lecture.
- Opérations : `AccountAliasRead`
- Références D1 : `modules/Domenia-Accounts.Async.ps1:Request-DomeniaAccountAliasRead`, `modules/Domenia-Accounts.Async.ps1:Invoke-DomeniaAccountAliasQueue`, `modules/Domenia-Accounts.Async.ps1:Complete-DomeniaAccountAliasRead`, `modules/Domenia-Accounts.Async.ps1:Fail-DomeniaAccountAliasRead`, `modules/Domenia-Accounts.Async.ps1:Get-DomeniaAccountAliasSummary`, `modules/Domenia-Accounts.Worker.ps1:Get-DomeniaAccountAliasWorkerCode`, `modules/Domenia-Guard.Model.ps1:ConvertTo-DomeniaAccountLookup`, `modules/Domenia-Guard.Model.ps1:Get-DomeniaCredentialAliasKeys`, `modules/Domenia-Guard.Model.ps1:Register-DomeniaCredentialAliases`, `modules/Domenia-Guard.Model.ps1:Get-DomeniaCredentialGroupKeys`, `Domenia-Access.UI.ps1:Initialize-DomeniaAccess`, `Request-DomeniaAccountAliasRead`

#### TRV-223 · Garde d'authentification partagée des workers

`a-faire` · locale (aucune lecture)

Un disjoncteur par compte couvre toutes ses utilisations, quels que soient la cible et le fournisseur. Au premier refus d'authentification, les lectures en attente sont retirées et les collectes suspendues, avec le message « Compte protégé… Corrigez ce compte dans Comptes ou reconnectez-vous ; la base locale reste consultable ». L'onglet Comptes montre l'usage en pause, et les 64 derniers refus de la session servent au diagnostic de verrouillage.

- Garde-fous : Verrous pris en ordre ordinal (pas d'interblocage), attente locale ≤ 120 s sans envoi d'identifiant ; marqueur stable [DOMENIA:CredentialPaused] ; refus sans provenance sur plusieurs comptes = opération suspendue (pas d'accusation de tous les comptes) ; une écriture garde son compte, mais un compte refusé à ce job n'est plus renvoyé ; seuls des diagnostics en liste blanche conservés, jamais l'exception ni l'identifiant. Une lecture réussie sans rapport n'efface jamais un refus. Une origine ambiguë suspend sans déclarer les autres comptes invalides. Une lecture partie avant la correction d'un mot de passe est ignorée. Une écriture garde son compte jusqu'à sa fin. Aucune variante d'identité ni nouvel essai automatique ; une reconnexion explicite réarme.
- Opérations : `LockoutDiagnosis`
- Références D1 : `modules/Domenia-Guard.Model.ps1:Assert-WCredentialAllowed`, `modules/Domenia-Guard.Model.ps1:Enter-WCredentialAttempt`, `modules/Domenia-Guard.Model.ps1:Exit-WCredentialAttempt`, `modules/Domenia-Guard.Model.ps1:Register-WCredentialFailure`, `modules/Domenia-Guard.Model.ps1:Set-WCredentialAttemptIdentity`, `modules/Domenia-Guard.Model.ps1:Get-WCredentialGuardKeys`, `Domenia-Engine.UI.ps1:Initialize-DomeniaCredentialGuard`, `Domenia-Engine.UI.ps1:Set-DomeniaCredentialGuardContext`, `Domenia-Engine.UI.ps1:Sync-DomeniaCredentialGuardUi`, `Domenia-Engine.UI.ps1:Get-DomeniaCredentialGuardFailures`, `Domenia-Engine.UI.ps1:Add-DomeniaCredentialFailureHistory`, `Domenia-Engine.UI.ps1:Get-DomeniaCredentialFailureHistory`, `Domenia-Core.ps1:Complete-UiTasks`, `Domenia-Core.ps1:Complete-DomeniaFastLoginSuccess`

#### TRV-224 · Clé de compte normalisée

`a-faire` · locale (aucune lecture)

Ramène les écritures d'un même compte à une clé unique : NETBIOS\x et DNS\x deviennent x@dns, x seul devient x@dns, .\x avec un poste cible devient poste\x ; seuls les alias du domaine connu sont fusionnés, sans résolution réseau.

- Garde-fous : Aucun mot de passe ni empreinte d'identifiant ; pas de résolution DNS/LDAP.
- Références D1 : `modules/Domenia-Guard.Model.ps1:Get-DomeniaCredentialAccountKey`, `modules/Domenia-Lockout.UI.ps1:Get-DomeniaLockoutAccountKeys`

### Sécurité · écritures

#### TRV-225 · Détails techniques d'un plan d'intervention

`a-faire` · locale (aucune lecture)

Texte replié de la confirmation : cible (type, nom, DN), domaine, GUID, destinataire (contrôleur ou poste), compte, chaque changement « attribut (type) : [avant] -> [après] », effets annoncés et 12 premiers caractères de l'empreinte du plan.

- Garde-fous : Retours à la ligne aplatis ; secrets absents du plan.
- Références D1 : `modules/Domenia-Confirmation.UI.ps1:Format-DomeniaPlanConfirmation`, `Domenia-Core.ps1 l.22954`

#### TRV-226 · Changements d'un plan en mots clairs

`a-faire` · locale (aucune lecture)

Chaque changement devient « Libellé : avant → après » : libellés français (Prénom, Service, Responsable…), options du compte oui/non, actif/désactivé, verrouillé → déverrouillé, changement de mot de passe imposé, emplacement par chemin d'OU, ajout/retrait de groupes et de membres, « (vide) » ; DN montrés par leur nom lisible, GUID renvoyés aux détails.

- Garde-fous : Un mot de passe ou secret n'est jamais affiché (« remplacé par la nouvelle valeur saisie, ni affichée ni conservée »).
- Références D1 : `modules/Domenia-Safety.Model.ps1:Get-DomeniaPlanChangeText`, `modules/Domenia-Safety.Model.ps1:ConvertTo-DomeniaDnDisplayName`

#### TRV-227 · Plan d'intervention immuable

`a-faire` · écriture

Avant l'écran de confirmation, fige l'opération, la cible exacte (domaine et GUID), le contrôleur ou poste destinataire, le compte, la liste ordonnée des changements (Replace, Clear, Add, Remove, Move, Reset) et les effets, avec une empreinte.

- Garde-fous : Refus sans identité exacte, sans destinataire (hors lecture), sans compte ou plan vide ; type de changement inconnu refusé ; valeur secrète hors plan et hors empreinte, avec la mention que la confirmer ne la fige pas. Rien ne peut changer après l'écran de confirmation.
- Opérations : `WriteAttributes`, `WriteAccountDisabled`, `WriteMoveObject`
- Références D1 : `modules/Domenia-Safety.Model.ps1:New-DomeniaInterventionPlan`, `modules/Domenia-Safety.Model.ps1:ConvertTo-DomeniaPlanChanges`, `modules/Domenia-Safety.Model.ps1:Test-DomeniaPlanHasSecret`, `modules/Domenia-Safety.Model.ps1:Get-DomeniaPlanSecretLimit`, `Domenia-Identity.Types.cs:InterventionPlan`, `Domenia-Identity.Types.cs:PlanChange`

#### TRV-228 · Revalidation du plan au moment de l'envoi

`a-faire` · écriture

Juste avant l'envoi, compare ce qui part au plan confirmé : même objet, même session, DN inchangé (ni déplacé ni renommé), même destinataire, même compte, même opération, même empreinte des valeurs, plan de moins de 15 min ; toute différence n'envoie rien et dit pourquoi.

- Garde-fous : Plan de simulation jamais exécutable ; horloge absente ou incohérente = rien n'est exécuté ; âge réglable 0–1440 min (0 désactive explicitement).
- Références D1 : `modules/Domenia-Safety.Model.ps1:Test-DomeniaPlanStillValid`

#### TRV-229 · Aperçu exact d'une opération collective

> Reste à faire : Fait pour les comptes : aperçu exact scellé par le moteur, nombre revérifié, un plan par cible scellée, cibles décochables, copie en CSV. Reste aux écrans Postes : diagnostic réseau d’une liste, relevé du parc.

`partiel` · écriture

Avant une opération sur plusieurs objets, liste exacte des cibles avec ce que chacune reçoit, les exclusions motivées (type hors périmètre, DN ou GUID absent, doublon, au-delà de la limite de 20 000), l'impact, et une confirmation proportionnée au risque : saisir le nombre de cibles pour une écriture ou action distante dès 2 cibles, ou pour une lecture au-delà de 200.

- Garde-fous : Chaque cible garde sa position pour n'exécuter que sur elle ; 12 lignes visibles, liste complète en détail, 100 noms au-delà de la limite puis comptage ; opération inconnue traitée comme risquée.
- Opérations : `BatchNetworkDiag`, `ParkSweep`
- Références D1 : `modules/Domenia-Safety.Model.ps1:New-DomeniaCollectivePreview`, `Domenia-Core.ps1 l.11688 (BatchNetworkDiag)`, `modules/Domenia-Park.UI.ps1 (ParkSweep)`

#### TRV-230 · Reçus en attente : blocage et verrous par cible

`a-faire` · écriture

Tout reçu non terminal (y compris étape inconnue ou altérée) bloque les nouvelles écritures ; les reçus incertains d'une exécution précédente verrouillent leur propre cible (GUID et DN) comme une écriture, pas toute l'application.

- Garde-fous : Comparaison brute de l'étape (fail closed) ; lectures toujours possibles pour vérifier.
- Références D1 : `modules/Domenia-Safety.Model.ps1:Get-DomeniaReceiptStageView`, `modules/Domenia-Safety.Model.ps1:Get-DomeniaReceiptLocks`

#### TRV-231 · Reprise après redémarrage sans rejeu

`a-faire` · écriture

Interprète un reçu trouvé au démarrage : préparé = non envoyé, envoyé ou inconnu = incertain et bloquant, livré = terminé sans preuve d'effet ; rien n'est jamais renvoyé automatiquement.

- Garde-fous : Replay toujours faux ; étape illisible = incertaine.
- Références D1 : `modules/Domenia-Safety.Model.ps1:Get-DomeniaReceiptResumeState`

#### TRV-232 · Idempotence et refus du double envoi

`a-faire` · écriture

La clé d'idempotence est l'empreinte du plan : un plan confirmé ne part qu'une fois, aucune demande identique ne part tant qu'une autre est réservée, envoyée ou incertaine, et le second clic d'un double-clic est refusé ; le registre est amorcé au démarrage à partir des reçus et tient compte des jobs actifs.

- Garde-fous : Origines Démarrage, Reprise, Nouvel essai, Minuterie et Reconnexion refusées (geste explicite requis) ; -CheckOnly pour griser un bouton sans réserver ; registre absent = refus ; lectures toujours relançables.
- Références D1 : `modules/Domenia-Safety.Model.ps1:New-DomeniaWriteRegistry`, `modules/Domenia-Safety.Model.ps1:Test-DomeniaWriteAdmission`

#### TRV-233 · Issue d'une écriture (machine à états)

`a-faire` · écriture

Enregistre ce qu'il advient d'une demande : Réservée → Envoyée/Non envoyée/Échec/Incertaine/Vérifiée/Livrée ; une demande envoyée ne redevient jamais « non envoyée », et « Échec » après envoi n'est accepté qu'avec un refus prouvé du contrôleur (code LDAP 1 à 80).

- Garde-fous : Une incertitude n'est résolue que par vérification ou revue ; erreur de processus, délai ou connexion perdue après envoi = à vérifier.
- Références D1 : `modules/Domenia-Safety.Model.ps1:Set-DomeniaWriteOutcome`

#### TRV-234 · Écriture conditionnelle et détection d'écriture concurrente

`a-faire` · écriture

Pour un attribut texte monovalué, l'ancienne valeur est supprimée et la nouvelle ajoutée dans la même requête LDAP, si bien que le contrôleur refuse si quelqu'un l'a changée (codes 16, 19, 20 = conflit, rien d'écrasé) ; sinon relecture avant/après et version de l'attribut via les métadonnées de réplication (écriture concurrente soupçonnée si version +2).

- Garde-fous : Aucune transaction promise ; pas de réponse ou code client (&lt;0 ou >80) = issue inconnue ; aucun nouvel essai automatique ; attribut secret = opération dédiée. Précondition relue juste avant l'envoi ; rien n'est retenté.
- Opérations : `WriteAttributes`
- Références D1 : `modules/Domenia-Safety.Model.ps1:Get-DomeniaAtomicStrategy`, `modules/Domenia-Safety.Model.ps1:Resolve-DomeniaConditionalWrite`, `Domenia-Core.ps1 l.23393, l.23505`, `Domenia-Core.ps1:Invoke-WConditionalModify`, `Domenia-Core.ps1:Get-DomeniaWorkerRulesCommon`, `Domenia-Core.ps1:Start-DomeniaAttributeWrite`

#### TRV-235 · Préconditions relues juste avant l'envoi

`a-faire` · écriture

Relit sur le contrôleur prévu chaque valeur « avant » du plan : si l'une a changé depuis l'aperçu ou n'a pas été relue, rien n'est envoyé ni écrasé et l'opérateur doit relire puis préparer un nouveau plan.

- Garde-fous : Attribut absent de la relecture ≠ attribut vide ; secrets exclus de la comparaison ; DN comparés normalisés.
- Opérations : `WriteAttributes`
- Références D1 : `modules/Domenia-Safety.Model.ps1:Test-DomeniaPreconditionCurrent`, `Domenia-Core.ps1 l.23459`

#### TRV-236 · Verrous par cible et classe d'action

`a-faire` · écriture

Une écriture AD ou une action distante en cours ou incertaine sur une cible fait attendre toute autre mutation et l'édition de cette cible ; les écritures AD partent une par une ; les lectures ne sont jamais bloquées (avec une note si la valeur lue peut précéder la fin d'une modification).

- Garde-fous : Opération inconnue = écriture ; cible manquante ou non reconnue = verrou sur toutes les cibles ; un DN sans GUID n'est pas distinguable (attente) ; classe ou état inattendu lu comme le plus restrictif.
- Références D1 : `modules/Domenia-Safety.Model.ps1:Get-DomeniaLockClass`, `modules/Domenia-Safety.Model.ps1:New-DomeniaOperationLock`, `modules/Domenia-Safety.Model.ps1:Test-DomeniaOperationAllowed`, `modules/Domenia-Safety.Model.ps1:Resolve-DomeniaTargetKeys`, `modules/Domenia-Safety.Model.ps1:ConvertTo-DomeniaDnKey`, `modules/Domenia-Safety.Model.ps1:ConvertTo-DomeniaComparableValue`

#### TRV-237 · Mode lecture seule fermé par défaut

`a-faire` · écriture

Les gardes d'écriture lisent la case de mode lecture seule ; avant la fenêtre principale, le dernier mode connu s'applique, et une case illisible ou indéterminée compte comme lecture seule.

- Garde-fous : Une garde n'ouvre jamais sur une erreur ; erreur rendue pour la trace.
- Références D1 : `modules/Domenia-Safety.Model.ps1:Get-DomeniaReadOnlyState`, `ChkReadOnlyMode`, `Assert-WriteAllowed (Core)`, `Assert-DomeniaRemoteWriteAllowed (Core)`

#### TRV-238 · Objets protégés et DN illisible

`a-faire` · écriture

Un objet avec adminCount=1 ou isCriticalSystemObject est protégé ; un DN illisible bloque toute écriture sur lui et des marqueurs de protection illisibles comptent comme protégés.

- Garde-fous : Fail closed ; erreurs conservées pour la trace.
- Références D1 : `modules/Domenia-Safety.Model.ps1:Get-DomeniaWriteGuardSubject`, `Assert-DomeniaCapability (Core)`

#### TRV-239 · Cible d'écriture saisie à la main (DN)

`a-faire` · écriture

Un DN tapé comme cible (groupe, membre, destination) n'est accepté que s'il est bien formé, dans le domaine connecté (suffixe comparé nom par nom) et hors des partitions Configuration, DomainDnsZones et ForestDnsZones ; la réponse nomme la cible par son nom lisible.

- Garde-fous : Domaine inconnu = aucune cible acceptée ; DN brut seulement dans les détails techniques. Rien n'est envoyé si une étape échoue.
- Références D1 : `modules/Domenia-Safety.Model.ps1:Test-DomeniaWriteTargetDn`, `Domenia-Core.ps1:Resolve-WDirectoryIdentityDn`, `Domenia-Core.ps1:Resolve-WGroupDn`, `Domenia-Core.ps1:Resolve-WObjectDn`, `Domenia-Core.ps1:Escape-WRdn`

### Sécurité · secrets

#### TRV-240 · Attributs secrets jamais conservés

`a-faire` · locale (aucune lecture)

Liste des attributs porteurs de secret (unicodePwd, userPassword, supplementalCredentials, historiques, LAPS ms-Mcs-AdmPwd et msLAPS-\*, msFVE-RecoveryPassword/KeyPackage, msDS-ManagedPassword\*, msDS-KeyCredentialLink…) dont la valeur n'entre jamais dans un plan, un reçu, un résumé ou une compensation.

- Garde-fous : Liste dupliquée pour fonctionner sans le cœur (tests).
- Références D1 : `modules/Domenia-Safety.Model.ps1:Test-DomeniaSecretAttribute`, `Test-DomeniaSensitiveAttributeName (Core)`, `Domenia-Core.ps1:Test-DomeniaSensitiveAttributeName`, `Domenia-Core.ps1:Remove-DomeniaSensitiveProperties`, `Domenia-Core.ps1:$script:RawAttributeBlockList`, `Domenia-Core.ps1:Get-WAllProperties`

#### TRV-241 · Presse-papiers protégé

`a-faire` · locale (aucune lecture)

Copie une valeur bornée (8192 caractères, 1024 pour une clé BitLocker) avec un écrivain natif qui l'exclut de l'historique du presse-papiers Windows et de la synchronisation cloud, puis programme son effacement automatique.

- Garde-fous : Valeur vide ou hors limite refusée ; limite des gestionnaires tiers affichée à l'opérateur. Fenêtre propriétaire obligatoire. Les gestionnaires de presse-papiers tiers restent hors de contrôle (annoncé).
- Références D1 : `modules/Domenia-Guard.UI.ps1:Set-DomeniaProtectedClipboard`, `Domenia-Clipboard.Native.cs`, `Start-SecretClipboardAutoClear (Core)`, `Domenia-Clipboard.Native.cs:ClipboardWriter.Set`, `Domenia-Guard.UI.ps1:Set-DomeniaProtectedClipboard`, `Set-ClipboardSafe`

### Sélecteurs

#### TRV-242 · Sélecteur d'OU arborescent partagé

`fait` · lecture réseau

Sélecteur d'OU unique pour le tableau de bord, l'Atelier, les Outils et la fiche. L'arbre se lit à l'expansion (1000 enfants par niveau, tri par nom côté serveur). Il offre une recherche d'OU par nom (100 résultats) avec branches parentes de contexte, les favoris de Rechercher, l'affichage d'une OU (favori ou choix courant) en lisant les parents un par un, et la portée « Inclure les sous-OU » imposée ou au choix. Une ligne de confirmation décrit l'effet et le chemin complet est copiable. Seules les OU avec GUID se choisissent ; les conteneurs servent à naviguer.

- Garde-fous : Choisir revérifie le DN et le GUID (lecture Base). Branches hors domaine refusées. Délais serveur 8 s, client 10 s, tâche 18 s. Lecture remplaçable (ReplaceKey). Une lecture annulée ne repeuple pas l'arbre. Refus si la connexion change.
- Opérations : `EmbeddedDirectoryLookup`
- Références D1 : `Domenia-Embedded.UI.ps1:Show-DomeniaOuTreePicker`, `Domenia-Embedded.UI.ps1:New-DomeniaOuPickerNode`, `Domenia-Embedded.UI.ps1:Start-DomeniaOuPickerRead`, `Domenia-Embedded.UI.ps1:Stop-DomeniaOuPickerRead`, `Domenia-Embedded.UI.ps1:Complete-DomeniaOuPickerRead`, `Domenia-Embedded.UI.ps1:Fail-DomeniaOuPickerRead`, `Domenia-Embedded.UI.ps1:Show-DomeniaOuPickerNavigation`, `Domenia-Embedded.UI.ps1:Get-DomeniaOuPickerFavourites`, `Domenia-Embedded.UI.ps1:Update-DomeniaOuPickerSummary`, `Domenia-Embedded.UI.ps1:Start-DomeniaOuPickerReveal`, `Domenia-Embedded.UI.ps1:Continue-DomeniaOuPickerReveal`, `Domenia-Embedded.UI.ps1:Get-DomeniaEmbeddedLookupCode`, `EmbeddedObjectTerm`, `EmbeddedObjectResults`, `EmbeddedOuPath`, `EmbeddedOuSubtree`, `EmbeddedOuFavourites`, `EmbeddedObjectAccept`, `Domenia-Core.ps1:Search-DomeniaPickerObjects`, `Domenia-Core.ps1:Show-DomeniaObjectPicker`, `Domenia-Core.ps1:Get-DomeniaParentDn`

#### TRV-243 · Sélecteur d'objet intégré (utilisateur, poste, OU)

`fait` · lecture réseau

Recherche d'un utilisateur, d'un poste ou d'une OU sur tout le domaine, indépendamment des filtres de la page principale : au moins 2 caractères (sauf OU), 160 au plus, 100 résultats. La correspondance porte sur le nom, sAMAccountName, displayName, givenName, sn, mail, UPN et le DNS. Le choix est revérifié avant d'être transmis au formulaire.

- Garde-fous : Valeur LDAP échappée, types fermés, GUID obligatoire. Revérification DN et GUID (« objet déplacé, recréé ou inaccessible »). Une association ou un déplacement demande encore sa propre confirmation.
- Opérations : `EmbeddedDirectoryLookup`
- Références D1 : `Domenia-Embedded.UI.ps1:Show-DomeniaInlinePicker`, `Domenia-Embedded.UI.ps1:Complete-DomeniaEmbeddedLookup`, `Domenia-Embedded.UI.ps1:Fail-DomeniaEmbeddedLookup`, `Domenia-Embedded.UI.ps1:Get-DomeniaEmbeddedLookupCode`, `EmbeddedObjectStatus`

#### TRV-244 · Sélecteur de fichier intégré

`ameliore` · lecture locale

Choix d'un fichier à ouvrir ou d'un emplacement d'enregistrement dans la page. Le dossier est parcouru en arrière-plan (500 entrées au plus), avec Parent, double-clic sur un dossier et saisie directe d'un chemin complet. Un fichier existant demande un clic explicite sur « Remplacer », aucun dossier n'est créé, et un partage réseau n'est interrogé qu'à la demande.

- Garde-fous : Chemin complet exigé. Le remplacement est lié à la signature du fichier. Délai de 15 s.
- Opérations : `EmbeddedPathBrowse`
- Références D1 : `Domenia-Embedded.UI.ps1:New-DomeniaFileRequest`, `Domenia-Embedded.UI.ps1:Get-DomeniaEmbeddedPathCode`, `Domenia-Embedded.UI.ps1:Complete-DomeniaEmbeddedPath`, `Domenia-Embedded.UI.ps1:Fail-DomeniaEmbeddedPath`, `Domenia-Embedded.UI.ps1:Show-DomeniaInlineFilePicker`, `EmbeddedFolder`, `EmbeddedBrowse`, `EmbeddedFileName`, `EmbeddedFileAccept`

#### TRV-245 · Favoris proposés dans les sélecteurs d'OU

`fait` · locale (aucune lecture)

Tout sélecteur d'OU propose les favoris du domaine de session (jamais la racine), dans leur ordre, avec chemin complet et libellé désambiguïsé.

- Garde-fous : Favori hors domaine écarté.
- Références D1 : `Domenia-Search.Model.ps1:Get-DomeniaOuFavouriteChoices`

#### TRV-246 · Résumé du choix d'OU avant validation

`fait` · locale (aucune lecture)

Le sélecteur partagé affiche le chemin lisible, la portée (imposée ou choisie, avec ou sans sous-OU), l'effet de la page appelante et rappelle que l'OU est revérifiée avant application.

- Garde-fous : OU hors domaine non choisissable ; revérification annuaire avant application.
- Opérations : `EmbeddedDirectoryLookup`
- Références D1 : `Domenia-Search.Model.ps1:Get-DomeniaOuChoiceSummary`, `Domenia-Embedded.UI.ps1`

### Stockage

#### TRV-247 · Écriture et lecture sûres de documents locaux

`a-faire` · écriture

Worker épinglé qui lit ou écrit un document local (.json, .html, .txt) : chemin absolu, écriture atomique par fichier temporaire puis remplacement, UTF-8 sans BOM, reçu Saved/Path.

- Garde-fous : Points de réanalyse (liens, jonctions) refusés sur tout le chemin ; 1 Mo max en lecture et écriture ; extension contrôlée ; temporaire supprimé en cas d'échec.
- Opérations : `DocumentStore`
- Références D1 : `Domenia-Dossier.Model.ps1:Get-DomeniaDocumentWorkerCode`

#### TRV-248 · Réglages d'expérience bornés et clés étendues

`a-faire` · locale (aucune lecture)

Les préférences sont normalisées : booléens, choix fermés (densité, thème, profil, construction de l'index, type de recherche) et nombres bornés (taille et position de fenêtre, largeur d'arbre, hauteur du journal, limites de recherche et WMI, zoom, concurrence, cache et nouvelles tentatives de collecte). Les clés supplémentaires ne passent que si elles suivent un motif fermé lié au domaine ou au magasin (SHA-256), comme la politique de stockage, les sauvegardes, Fleet.LastView ou Directory.RootOu : 256 au plus, 1 MiB chacune.

- Garde-fous : Une valeur invalide reprend la valeur par défaut. Aucune clé libre persistée. PresenceFilter n'est plus une préférence.
- Références D1 : `Domenia-Experience.Model.ps1:ConvertTo-DomeniaExperienceSettings`, `Domenia-Experience.Model.ps1:Test-DomeniaScopedSettingName`, `Domenia-Experience.Model.ps1:ConvertTo-SuiteFlag`, `Domenia-Experience.Model.ps1:ConvertTo-SuiteNumber`

#### TRV-249 · Plan durable de campagne

`a-faire` · écriture

À l'approbation d'un relevé de la liste ou d'un périmètre, écrit le plan (postes compressés, empreinte, version) et un avancement par bits dans le dossier de préférences, mis à jour toutes les 10 s et à l'arrêt ou la fermeture.

- Garde-fous : Lecture seule uniquement : ni compte, ni écriture AD, ni requête libre ; un plan à la fois ; liste trop longue (> 900 Ko) signalée, jamais tronquée ; plan d'une version plus récente refusé ; plan complet supprimé.
- Références D1 : `Domenia-Collection.Model.ps1:New-DomeniaCampaignPlan`, `Domenia-Collection.Model.ps1:ConvertTo-DomeniaCampaignPlanText`, `Domenia-Collection.Model.ps1:ConvertFrom-DomeniaCampaignPlanText`, `Domenia-Collection.Model.ps1:New-DomeniaCampaignProgress`, `Domenia-Collection.Model.ps1:Set-DomeniaCampaignTargetDone`, `Domenia-Collection.Model.ps1:ConvertFrom-DomeniaCampaignProgressText`, `Domenia-Collection.Model.ps1:Get-DomeniaCampaignRemainingTargets`, `Domenia-Collection.Model.ps1:Get-DomeniaCampaignResumeState`, `Domenia-Collection.Model.ps1:Test-DomeniaCampaignRunDurable`, `Domenia-Collection.UI.ps1:Save-DomeniaCampaignPlan`, `Domenia-Collection.UI.ps1:Save-DomeniaCampaignProgress`, `Domenia-Collection.UI.ps1:Complete-DomeniaCampaignPlan`, `Domenia-Collection.UI.ps1:Register-DomeniaCampaignCloseHook`, `Domenia-Park.UI.ps1:Close-DomeniaParkCampaign`, `Domenia-Park.UI.ps1:Set-DomeniaParkStopReason`

#### TRV-250 · Projection bornée des détails de sonde

`a-faire` · locale (aucune lecture)

Convertit les instances CIM en valeurs typées détachées (dates UTC, tableaux ≤ 256, textes ≤ 16 Kio) sous budget (96 Kio par défaut, 2 000 instances), avec motif de limite et pages de 100 à 500 lignes.

- Garde-fous : Valeur non conservée entièrement dite comme telle ; nombre total distinct du nombre mémorisé.
- Opérations : `LiveConsole`
- Références D1 : `Domenia-ProbeDetails.Model.ps1:ConvertTo-DomeniaProbeDetailValue`, `Domenia-ProbeDetails.Model.ps1:ConvertTo-DomeniaProbeDetailInstance`, `Domenia-ProbeDetails.Model.ps1:New-DomeniaProbeDetailProjection`, `Domenia-ProbeDetails.Model.ps1:Get-DomeniaProbeDetailPage`, `Domenia-ProbeDetails.Model.ps1:Get-DomeniaProbeDetailWorkerPrelude`

#### TRV-251 · Publication des mesures après COMMIT

`a-faire` · écriture

Chaque résultat distant devient des changements datés par famille (Presence, Console, Inventory, Probe:&lt;id>) gelés en lots, remis au stockage (8 lots par appel) puis relus avant toute publication à l'écran.

- Garde-fous : Seuls les champs datés par la source ; résultat d'une autre cible refusé ; contexte (session, base, domaine, génération de comptes, StoreId, RequestId) vérifié ; un lot refusé bloque la file au lieu d'être perdu.
- Opérations : `LocalStore`
- Références D1 : `Domenia-Park.Model.ps1:ConvertTo-DomeniaRemoteObservationChanges`, `Domenia-Park.Model.ps1:Test-DomeniaRemoteStoreContext`, `Domenia-Park.UI.ps1:Initialize-DomeniaRemoteStoreState`, `Domenia-Park.UI.ps1:Submit-DomeniaRemoteObservations`, `Domenia-Park.UI.ps1:Submit-DomeniaRemoteChanges`, `Domenia-Park.UI.ps1:Invoke-DomeniaRemoteStoreQueue`, `Domenia-Park.UI.ps1:Complete-DomeniaRemoteStoreBatch`, `Domenia-Park.UI.ps1:Get-DomeniaCommittedObservation`, `Domenia-Park.UI.ps1:Test-DomeniaRemoteStoreBlocked`, `Domenia-Park.UI.ps1:Close-DomeniaParkStoreBacklog`, `Domenia-Live.UI.ps1:Complete-DomeniaLiveStored`

#### TRV-252 · Stockage durable des lectures détaillées

`a-faire` · écriture

Inventaire, logiciels, services, sessions, diagnostic et explorateur WMI sont enregistrés avant affichage, avec liste blanche de champs et lignes dont la propriété évoque un secret (password, token, recoverykey, productkey…) retirées et comptées.

- Garde-fous : Un échec enregistre la tentative datée sans effacer la dernière réussite ; identité du poste vérifiée.
- Opérations : `LocalStore`
- Références D1 : `Domenia-Park.UI.ps1:New-DomeniaClassicCollectionState`, `Domenia-Park.UI.ps1:ConvertTo-DomeniaClassicStoreData`, `Domenia-Park.UI.ps1:Complete-DomeniaClassicCollected`, `Domenia-Park.UI.ps1:Fail-DomeniaClassicCollected`, `Domenia-Park.UI.ps1:Submit-DomeniaRemoteDetail`, `Domenia-Park.UI.ps1:Complete-DomeniaRemoteDetailStored`, `Domenia-Park.UI.ps1:Complete-DomeniaLastUserCollected`

#### TRV-253 · Dernière valeur connue préservée

`a-faire` · locale (aucune lecture)

Un contrôle en échec n'efface jamais le dernier utilisateur, l'inventaire ou les sondes connus : la tentative et son erreur sont gardées à part, les sondes fusionnées par identifiant.

- Garde-fous : GUID différent = objet recréé, historique non repris ; observation précédente décodée seulement au départ du poste.
- Références D1 : `Domenia-Park.Model.ps1:ConvertTo-DomeniaParkSession`, `Domenia-Live.Model.ps1:ConvertTo-DomeniaLiveObservation`, `Domenia-Park.Model.ps1:Expand-DomeniaParkPrevious`, `Domenia-Park.Model.ps1:Clear-DomeniaParkTargetBuffers`

#### TRV-254 · Garde-fous de départ d'un relevé

`a-faire` · locale (aucune lecture)

Aucun relevé ne part pendant une maintenance de base, un écrivain suspendu, des conflits d'écriture ou un disque presque plein ; les travaux déjà partis finissent et sont enregistrés.

- Garde-fous : Indisponible en démonstration.
- Références D1 : `Domenia-Park.UI.ps1:Start-DomeniaOnlinePark`, `Domenia-Park.UI.ps1:Start-DomeniaParkPingJob`, `Get-DomeniaStorageCollectionRefusal`, `Get-DomeniaPersistenceState`

#### TRV-255 · Pipeline AD vers SQLite avant affichage

`a-faire` · écriture

Chaque lecture AD (liste, fiche, arbre) est enregistrée en lots (100 changements, 3,5 Mo, groupement 160 ms, admission 250 ms) puis relue ; rien n'est publié sans COMMIT et relecture.

- Garde-fous : Reçu SQLite vérifié (Saved, DataSource, BatchId, StoreId) ; un ancien contexte n'affiche plus mais conserve ses valeurs ; échec = lecture arrêtée et erreur publiée.
- Opérations : `LocalStore`
- Références D1 : `Domenia-DirectoryStore.UI.ps1:New-DomeniaDirectoryReadPipe`, `Domenia-DirectoryStore.UI.ps1:Invoke-DomeniaDirectoryStoreTick`, `Domenia-DirectoryStore.UI.ps1:Complete-DomeniaDirectoryStoreBatch`, `Domenia-DirectoryStore.UI.ps1:Fail-DomeniaDirectoryStoreBatch`, `Domenia-DirectoryStore.UI.ps1:Complete-DomeniaDirectoryReadPipe`, `Domenia-DirectoryStore.UI.ps1:Initialize-DomeniaDirectoryStore`, `Submit-DomeniaStoreBatch`

#### TRV-256 · Faits poste enregistrés

`a-faire` · locale (aucune lecture)

Pour un poste : version du système, création, dernier changement du mot de passe machine, type et expiration LAPS (Windows ou historique).

- Garde-fous : Aucune valeur de mot de passe.
- Opérations : `LocalStore`
- Références D1 : `Domenia-DirectoryStore.Model.ps1:ConvertTo-DomeniaDirectoryStoreChange`

#### TRV-257 · Mise à jour partielle sans effacer les champs non lus

`a-faire` · locale (aucune lecture)

Seuls les champs présents dans la lecture sont mis à jour ; le résumé composé (service/fonction, système/lieu) n'est écrit que si ses deux moitiés ont été lues.

- Opérations : `LocalStore`
- Références D1 : `Domenia-DirectoryStore.Model.ps1:ConvertTo-DomeniaDirectoryStoreChange`

#### TRV-258 · Emplacements de données par catégorie et mode de stockage

`a-faire` · lecture locale

Chaque catégorie a un emplacement explicite : Configuration (wad\Domenia.config.json, lecture seule), Préférences, Cache et base active, Reçus (toujours dans le profil local). Modes : UserLocal (profil, DACL protégée), Portable (wad\data) ou Compatible (déduit des données portables existantes, et annoncé). Le cache se répartit en zones Logs, Backups, Diagnostics, Exports, Legacy et Domains. Un emplacement réseau ou non inscriptible est une erreur explicite, sans bascule silencieuse.

- Garde-fous : Pas de redirection automatique ; le chemin demandé reste dans la réponse ; base active toujours locale. Aucun repli silencieux ; préférences non inscriptibles annoncées.
- Références D1 : `Domenia-Release.Model.ps1:Get-DomeniaStorageLayout`, `Domenia-Core.ps1 ($script:StorageLayout)`, `Domenia-Core.ps1:Initialize-DomeniaDataStore`, `Domenia-Core.ps1:Get-DomeniaStoreBackupDirectory`

#### TRV-259 · Catalogue des formats versionnés

`a-faire` · locale (aucune lecture)

Liste close des formats échangés ou gardés sur disque : Domenia.Query/2, QueryLibrary, QueryPack/2, QueryImportPlan/2, QueryExport, WmiRead, CollectionRun, CampaignPlan, ProbeContract, Automation, OfflineDossier, Capture, Diagnostic.2, Ticket, SuiteContract, CompatibilityMatrix, ReleaseContract, etc. Chaque format déclare sa version courante, ses versions lisibles et ses migrations. Une version plus récente est refusée, jamais devinée ; les vocabulaires d'issue et de fournisseur sont fermés.

- Garde-fous : Décisions Lire, Migrer, Illisible, Inattendu, Inconnu, PlusRecent ou TropAncien, avec message en français.
- Références D1 : `Domenia-Common.Model.ps1:Get-DomeniaContractCatalog`, `Domenia-Common.Model.ps1:Get-DomeniaContract`, `Domenia-Common.Model.ps1:ConvertFrom-DomeniaContractFormat`, `Domenia-Common.Model.ps1:Resolve-DomeniaContractFormat`, `Domenia-Common.Model.ps1:Assert-DomeniaContractFormat`, `Domenia-Common.Model.ps1:Test-DomeniaContractValue`, `Domenia-Common.Model.ps1:Test-DomeniaContractCatalog`

#### TRV-260 · Une base SQLite locale par domaine

`a-faire` · lecture locale

La base active est un fichier .db local par domaine, mémorisé dans la préférence Storage.Database.&lt;hash du domaine>, et identifié par StoreId (hash du chemin et du domaine) et par la ligne domenia_store_state. Sont refusés : chemin UNC ou lecteur réseau, lien, dossier ou annexe SQLite (-wal, -shm, -journal) redirigés, et base d'un autre domaine.

- Garde-fous : « Une base active doit rester sur un disque local » ; « Base appartenant à un autre contexte ». Jamais de fusion de deux domaines ; disque choisi disparu = échec visible.
- Opérations : `LocalStore`
- Références D1 : `Domenia-Storage.UI.ps1:Get-DomeniaLocalDatabasePath`, `Domenia-StorageContext.UI.ps1:Get-DomeniaDatabasePreferenceKey`, `Domenia-Store.Model.ps1:Get-DomeniaStoreId`, `Domenia-Store.Model.ps1:Get-DomeniaStoreHash`, `Domenia-Store.Model.ps1:Get-DomeniaStoreValue`, `Domenia-Core.ps1:Get-DomeniaDatabasePath`, `Domenia-Core.ps1:Get-DomeniaScopeKey`

#### TRV-261 · Écrivain unique et file d'enregistrement

`a-faire` · écriture

Toutes les écritures de la base passent par une file ordonnée (premier entré, premier écrit, 256 éléments au plus). Une minuterie protégée, qui tourne aussi fenêtre réduite, la vide : 1 s, ou 20 ms pour un lot canonique. Un lot compte 64 éléments au plus et l'écrivain est suspendu après trois échecs. Les types gérés sont Index, Link, Presence, UserScan, Park, ParkSession, ParkReset, SecretMeta, Sample, IndexBulk, LegacyImport, FleetSnapshot, DirectoryAbsence, DirectorySnapshot et StoreBatch.

- Garde-fous : File pleine : « les données restent visibles mais non enregistrées ». Les lots plus anciens sont retentés en premier, pour ne jamais rejouer une vieille reconstruction après une mise à jour d'OU plus récente.
- Opérations : `LocalStore`
- Références D1 : `Domenia-Storage.UI.ps1:Initialize-DomeniaPersistence`, `Domenia-Storage.UI.ps1:Add-DomeniaIndexPersistence`, `Domenia-Storage.UI.ps1:Request-DomeniaStorageWork`, `Domenia-Storage.UI.ps1:Test-DomeniaStorageWorkPending`, `Domenia-Storage.UI.ps1:Start-DomeniaStorageWork`, `Domenia-Storage.UI.ps1:Complete-DomeniaStorageWork`, `Domenia-Storage.UI.ps1:Fail-DomeniaStorageWork`, `Domenia-Storage.UI.ps1:Queue-DomeniaMetadata`, `Domenia-Storage.Worker.ps1:Get-DomeniaStorageWorkerCode`

#### TRV-262 · Lots canoniques validés avant écriture

`a-faire` · écriture

Un lot contient de 1 à 250 changements, pèse 4 Mio au plus et porte un GUID de lot, une séquence et le contexte (StoreId, domaine, époque, requête). Les types sont fermés : objet AD, observation, résultat détaillé, préférence de compte, recette, dépendance, migration de recettes, horloge de collecte. Les champs AD doivent être projetés, chaque DN doit appartenir au domaine et un succès ne peut pas être postérieur à sa tentative. Toute clé ressemblant à un secret (password, unicodePwd, ms-Mcs-AdmPwd, msFVE-RecoveryPassword…) est refusée.

- Garde-fous : « Secret interdit dans le stockage de collecte » ; une recette est revalidée par le vrai compilateur ; une horloge de collecte d'un Domenia plus récent est refusée.
- Opérations : `LocalStore`
- Références D1 : `Domenia-Store.Model.ps1:ConvertTo-DomeniaStoreBatch`, `Domenia-Store.Model.ps1:Assert-DomeniaStoreSafeData`, `Domenia-Store.Model.ps1:ConvertTo-DomeniaStoreQueryChange`, `Domenia-Store.Model.ps1:ConvertTo-DomeniaStoreCollectionRun`, `Domenia-Store.Model.ps1:ConvertTo-DomeniaStoreUtc`, `Domenia-Storage.UI.ps1:New-DomeniaStoreContext`, `Domenia-Storage.UI.ps1:Submit-DomeniaStoreBatch`

#### TRV-263 · Reçus de lot et idempotence des enregistrements

`a-faire` · écriture

Chaque lot validé incrémente la révision de la base et laisse un reçu dans domenia_store_batches : identifiant, hash du contenu, requête, séquence, révision, date. Un lot rejoué est reconnu (Already) et un même identifiant avec un autre contenu est refusé. Les lignes sont relues dans une seconde transaction en lecture seule, après le commit. Les descriptions anciennes sont compactées, jamais la clé ni le hash.

- Garde-fous : Empreinte SHA-256 et taille vérifiées dans le worker ; compactage par passes de 512 lots, toutes les 256 révisions, au-delà de 2048 révisions et 30 jours.
- Opérations : `LocalStore`, `LocalIndexRead`
- Références D1 : `Domenia-Storage.Worker.ps1:Invoke-StoreWBatch`, `Domenia-Storage.Worker.ps1:Read-StoreWCommitted`, `Domenia-Storage.UI.ps1:Request-DomeniaStoreRead`

#### TRV-264 · Bail d'écriture inter-processus

`a-faire` · écriture

Un mutex global nommé d'après le hash du chemin de la base (Global\Domenia.SQLite.&lt;sha>) sérialise les écritures et les maintenances de toutes les instances de Domenia sur la même base, avec une attente de 1 s (5 s au plus). Une base marquée redirigée après une bascule (domenia_store_redirect) refuse toute écriture et nomme la base vérifiée à reprendre.

- Garde-fous : StorageBusy : « autre écriture ou maintenance locale en cours » ; StorageRedirected.
- Opérations : `LocalStore`, `StorageBackup`, `StoragePurge`, `StorageMaintenance`, `StorageRetention`, `LegacyMigration`
- Références D1 : `Domenia-StorageLease.Model.ps1:Get-StoreWLeaseName`, `Domenia-StorageLease.Model.ps1:Enter-StoreWDatabaseLease`, `Domenia-StorageLease.Model.ps1:Exit-StoreWDatabaseLease`, `Domenia-StorageLease.Model.ps1:Read-StoreWLeaseScalar`, `Domenia-StorageLease.Model.ps1:Assert-StoreWDatabaseWritable`, `Domenia-Storage.Worker.ps1:Get-DomeniaStorageLeaseWorkerCode`

#### TRV-265 · Schéma 11/1 en avance seule

`a-faire` · écriture

La version lit et écrit uniquement schema_version 11 et domenia_schema 1. Les tables additives (park_session_cache, ad_computer_facts, fleet_snapshots, ad_absences, ad_census_gaps, ad_snapshots, ad_snapshot_rows…) sont créées une fois par session de worker. Une base plus ancienne n'est migrée qu'après une sauvegarde vérifiée, une base plus récente est refusée sans modification, et une migration interrompue attend une reprise ou une restauration explicite.

- Garde-fous : Aucune étape ne supprime ni ne recrée une base, et les reçus ne sont jamais visés. Retour arrière de toute l'étape si une table/colonne manque ; aucun quick_check bloquant au lancement.
- Opérations : `LocalStore`, `StorageIntegrity`, `LegacyMigration`
- Références D1 : `Domenia-Storage.Worker.ps1:Get-DomeniaSqliteSchemaTarget`, `Domenia-Storage.Worker.ps1:Test-DomeniaSqliteSchemaRows`, `Domenia-Storage.Worker.ps1:Get-StoreWAdditiveTables`, `Domenia-Storage.Worker.ps1:Assert-StoreWSession`, `Domenia-Release.Model.ps1:Test-DomeniaSchemaCompatibility`, `Domenia-Release.Model.ps1:Test-DomeniaSchemaStepSafety`, `Domenia-Store.Model.ps1:Get-DomeniaStorageSchemaExpectation`, `Domenia-Store.Model.ps1:Get-DomeniaStorageSchemaGaps`, `Domenia-Core.ps1:Initialize-DomeniaDatabase`, `Domenia-Core.ps1:Get-DomeniaSqliteSchemaText`, `Domenia-Core.ps1:Invoke-DomeniaDatabaseMaintenance`, `Domenia-Core.ps1:Import-DomeniaLegacyStoreIfNeeded`

#### TRV-266 · Couche SQLite unique des workers

`a-faire` · lecture locale

Tous les workers de la base partagent une seule couche d'accès : appels natifs winsqlite3 via [Domenia.WinSqliteNative], conversions UTF-8, ouverture avec bail et attente de verrou, exécution et requête, valeurs liées et instructions préparées réutilisées. Chaque lecture est mesurée et signale SQLITE_BUSY. Le texte de cette couche entre dans le hash épinglé de chaque opération.

- Garde-fous : Toute copie de ces fonctions ailleurs est refusée (tools/check_sqlite_layer.py). Rien de saisi concaténé dans le SQL des workers.
- Opérations : `LocalStore`, `LocalIndexRead`, `StorageUsage`, `StorageIntegrity`, `StorageBackup`, `StoragePurge`, `StorageMaintenance`, `StorageRetention`, `LegacyMigration`, `LocalQuery`
- Références D1 : `Domenia-Storage.Worker.ps1:Get-DomeniaSqliteWorkerCommon`, `Domenia-Storage.Worker.ps1:Open-DomeniaDatabase`, `Domenia-Storage.Worker.ps1:Invoke-DomeniaSqliteRead`, `Domenia-Storage.Worker.ps1:Invoke-DomeniaDbExec`, `Domenia-Storage.Worker.ps1:Invoke-DomeniaDbQuery`, `Domenia-Storage.Worker.ps1:New-StoreWStatement`, `Domenia-Core.ps1:Initialize-DomeniaWinSqliteNative`, `Domenia-Core.ps1:Open-DomeniaDatabase`, `Domenia-Core.ps1:Close-DomeniaDatabase`, `Domenia-Core.ps1:Invoke-DomeniaDbExec`, `Domenia-Core.ps1:Invoke-DomeniaDbQuery`, `Domenia-Core.ps1:ConvertTo-DomeniaSqlLiteral`, `Domenia-Core.ps1:ConvertTo-DomeniaSqlLikeText`, `Domenia-Core.ps1:New-DomeniaUtf8Ptr`

#### TRV-267 · Lectures locales hors du fil d'interface

`a-faire` · lecture locale

Le worker LocalIndexRead sert en lecture seule une liste close d'actions : Search, AddressSearch, ParkState, ParkTargets, FleetStats, ResolveNames, StoreRead, IndexMetadata, UserMachineLinks, SecretIndexEntry, OperationStats, CollectionRuns, DirectorySync, SnapshotCompare. Une base verrouillée répond Busy, jamais un résultat vide. Les textes saisis sont liés (?N), jamais insérés dans le SQL, et une demande plus récente ou un changement de base écarte une réponse tardive.

- Garde-fous : Action hors liste refusée (« Lecture locale non autorisée ») ; base absente lue comme vide, réponse refusée jamais présentée vide.
- Opérations : `LocalIndexRead`
- Références D1 : `Domenia-Engine.Worker.ps1:Get-DomeniaLocalIndexReadWorkerCode`, `Domenia-Engine.UI.ps1:Start-DomeniaLocalRead`, `Domenia-Engine.UI.ps1:Test-DomeniaLocalReadCurrent`, `Domenia-Engine.UI.ps1:Get-DomeniaLocalDatabasePathForRead`

#### TRV-268 · Résultat d'enregistrement perdu traité comme un échec

`a-faire` · écriture

Un enregistrement sorti du moteur sans rappel libère sa place, mais le lot exact est conservé et l'écrivain passe en échec : « Résultat de sauvegarde non reçu ; vérifiez la base puis reprenez les sauvegardes ». Une reprise d'anciennes données dont la fin est inconnue n'est jamais rejouée.

- Garde-fous : Une fin inconnue n'est pas la preuve d'un commit ; une lecture détachée encore active garde le verrou.
- Opérations : `LocalStore`
- Références D1 : `Domenia-Storage.UI.ps1:Start-DomeniaStorageWork`, `Domenia-Storage.UI.ps1:Fail-DomeniaStorageWork`

#### TRV-269 · Bascule du contexte de base

`a-faire` · écriture

Quand une autre base vérifiée entre en service, la préférence du domaine est enregistrée et l'époque de session incrémentée. Toutes les générations, caches (visites, présence, parc, index, liens, inventaire, requêtes), grilles, historique de navigation, secrets affichés et arbre sont remis à zéro. Les chiffres, associations, bibliothèque de requêtes et tableau de bord sont ensuite relus par worker.

- Garde-fous : La bascule exige une maintenance exclusive confirmée et le contexte attendu. La préférence est restaurée si son enregistrement échoue, et une base qui ne s'ouvre pas ne montre jamais les compteurs de l'ancienne.
- Opérations : `StorageMaintenance`, `LocalIndexRead`
- Références D1 : `Domenia-StorageContext.UI.ps1:Switch-DomeniaDatabaseContext`, `Domenia-StorageContext.UI.ps1:Resume-DomeniaDatabaseViews`, `LblTreeStatus`, `TvDirectory`

#### TRV-270 · Données en file destinées à une autre base

`a-faire` · locale (aucune lecture)

Après une bascule, les données collectées encore en file pour l'ancienne base sont abandonnées, comptées et signalées à leurs demandeurs, jamais rejouées dans la nouvelle. Les changements de l'opérateur n'arrivent jamais là : ils ont été refusés au moment où il les a faits.

- Garde-fous : Ces données n'ont jamais fait partie de la copie vérifiée.
- Références D1 : `Domenia-Storage.UI.ps1:Clear-DomeniaStoragePendingForOtherBase`

#### TRV-271 · Refus des modifications pendant une maintenance

`a-faire` · locale (aucune lecture)

Tant qu'une maintenance tient la base (copie, bascule à finir, base illisible, assistant en attente de confirmation pendant 10 min au plus), une association, une requête enregistrée ou une reprise d'anciennes données sont refusées là où elles sont faites, avec le message. Les opérations LocalStore, LinkHistoryStore, LiveCache, IndexBuild, IndexRefresh, StoragePurge et StorageBackup attendent, et les nouvelles collectes ne démarrent pas.

- Garde-fous : Le journal des reçus et les documents choisis par l'opérateur restent autorisés, sinon toute écriture AD serait bloquée.
- Opérations : `LocalStore`, `LinkHistoryStore`, `LiveCache`, `IndexBuild`, `IndexRefresh`, `StoragePurge`, `StorageBackup`
- Références D1 : `Domenia-Store.Model.ps1:Get-DomeniaStorageInputRefusal`, `Domenia-Store.Model.ps1:Test-DomeniaStorageLockedWriter`, `Domenia-Storage.UI.ps1:Test-DomeniaStorageMaintenanceHold`, `Domenia-Storage.UI.ps1:Get-DomeniaStorageCollectionRefusal`

#### TRV-272 · Sauvegarde vérifiée avant un geste qui modifie la base

`a-faire` · écriture

Avant une mise à jour d'OU, un import CSV d'associations, le retrait des associations orphelines ou l'oubli des relevés du parc, une sauvegarde vérifiée est faite dans la série Geste-\*.db, dont la rotation est séparée. Une copie vérifiée de moins de 30 min sert de point de retour. Le geste ne part que du rappel de succès.

- Garde-fous : Si la copie échoue, le geste n'est pas lancé : réessayer ou « Continuer sans sauvegarde », choix journalisé et limité à la session et à la base demandées. Refus sous maintenance ; une copie déjà en cours est signalée.
- Opérations : `StorageBackup`, `IndexBuild`, `LocalStore`, `PruneLinks`
- Références D1 : `Domenia-Storage.UI.ps1:Get-DomeniaGestureBackupState`, `Domenia-Storage.UI.ps1:Invoke-DomeniaGestureBackup`, `Domenia-Storage.UI.ps1:Complete-DomeniaGestureBackup`, `Domenia-Storage.UI.ps1:Fail-DomeniaGestureBackup`, `Domenia-Storage.UI.ps1:Show-DomeniaGestureBackupFailure`, `Domenia-Storage.UI.ps1:Resume-DomeniaGestureWithoutBackup`, `Domenia-Cache.Model.ps1:Get-DomeniaGestureBackupLabel`, `Domenia-Cache.Model.ps1:Get-DomeniaGestureBackupDecision`, `Domenia-Cache.Model.ps1:Get-DomeniaGestureBackupNotice`

#### TRV-273 · Rafraîchissement des vues après purge ou conservation

`a-faire` · lecture locale

Après une purge ou une conservation, les vues d'observations (tableaux de bord, parc, recherche) sont invalidées et relues depuis la base. Seule une lecture locale (StoreRead) est planifiée, jamais une sonde réseau.

- Garde-fous : Aucun ancien flux ne peut repeupler un cache purgé.
- Opérations : `LocalIndexRead`
- Références D1 : `Domenia-Storage.UI.ps1:Reset-DomeniaStorageObservationViews`

#### TRV-274 · Plan de migration ADCC vers Domenia

`a-faire` · locale (aucune lecture)

Plan explicite et rejouable à vide : les préférences wad\ADCC.\* sont copiées vers wad\Domenia.\* seulement si absentes, ADCC.db est adoptée sur place après sauvegarde (schema_version 11, même domaine, ajout de la révision domenia_schema), et les magasins TSV remplissent des tables vides avec des liens canoniques. Un second passage doit n'avoir rien à écrire, et un plan refusé n'écrit rien.

- Garde-fous : Aucun poste avec deux liens, aucun lien perdu, aucune configuration Domenia existante écrasée.
- Opérations : `LegacyMigration`
- Références D1 : `Domenia-Release.Model.ps1:Get-DomeniaMigrationPlan`, `Domenia-Release.Model.ps1:Get-DomeniaMigratedState`, `Domenia-Release.Model.ps1:Test-DomeniaMigrationIdempotent`, `Domenia-Release.Model.ps1:ConvertTo-DomeniaMigrationDomain`, `Domenia-Release.Model.ps1:ConvertTo-DomeniaMigrationComputerKey`, `Domenia-Release.Model.ps1:ConvertTo-DomeniaMigrationUserLogin`

#### TRV-275 · Sauvegarde avant migration de schéma

`a-faire` · écriture

La copie faite avant une migration du schéma est autonome et vérifiée (quick_check), et elle reste hors de la rotation normale : elle n'est jamais supprimée par la sauvegarde planifiée.

- Garde-fous : Copie interrompue après son budget de temps ; original intact.
- Opérations : `LegacyMigration`
- Références D1 : `Domenia-Migration.Worker.ps1:Get-DomeniaMigrationWorkerCode`, `Domenia-DataPolicy.Model.ps1:Get-DomeniaLocalDataPolicy`

#### TRV-276 · Écriture atomique de fichiers

`a-faire` · locale (aucune lecture)

Fichier temporaire dans le même dossier, flush, puis remplacement (avec .bak optionnel) sans jamais supprimer la destination valide d'abord.

- Références D1 : `Domenia-Core.ps1:Write-DomeniaAtomicText`

### Stockage · bibliothèque de requêtes

#### TRV-277 · Bibliothèque SQLite par domaine

`a-faire` · lecture locale

Tables des recettes, révisions, provenance par révision, dépendances (widgets liés à une révision) et marqueurs de migration, avec recherche par nom sans accents.

- Garde-fous : Contexte de base vérifié (version, StoreId, domaine, chemin absolu).
- Opérations : `LocalStore`, `LocalIndexRead`
- Références D1 : `Domenia-QueryLibrary.Model.ps1:Get-DomeniaQueryLibrarySchema`, `Domenia-QueryLibrary.Model.ps1:ConvertTo-DomeniaQuerySearchKey`, `Domenia-QueryLibrary.Model.ps1:New-DomeniaQueryLibraryRead`

#### TRV-278 · Lecture confirmée et paginée de la bibliothèque

`a-faire` · lecture locale

Lit toutes les recettes (archives incluses) et leurs liens par pages de 250 sur une révision cohérente de la base, puis publie le cache utilisé par l'atelier, les widgets et Recherche.

- Garde-fous : 20 000 définitions max ; source SQLite exigée ; redémarrage (3 max) si la base change ; identité répétée ou pagination sans progrès refusées ; définitions recompilées.
- Opérations : `LocalIndexRead`
- Références D1 : `Domenia-QueryLibrary.Store.UI.ps1:Initialize-DomeniaQueryLibraryStore`, `Domenia-QueryLibrary.Store.UI.ps1:Request-DomeniaQueryLibraryStorePage`, `Domenia-QueryLibrary.Store.UI.ps1:Complete-DomeniaQueryLibraryStoreRead`, `Domenia-QueryLibrary.Store.UI.ps1:Publish-DomeniaQueryLibraryStoreCache`

#### TRV-279 · Migration de l'ancienne bibliothèque JSON

`a-faire` · écriture

Importe une fois dans SQLite les recettes de l'ancien réglage Query.Library, avec les liens des widgets existants et un marqueur durable par empreinte.

- Garde-fous : Lots de 50 recettes / 2,5 Mo ; reçu SQLite et marqueur exigés ; JSON original conservé ; différée pendant la maintenance ; 5 000 recettes, 16 Mio, identifiants réservés refusés.
- Opérations : `LocalStore`
- Références D1 : `Domenia-QueryLibrary.Store.UI.ps1:Complete-DomeniaQueryLibraryMigrationRead`, `Domenia-QueryLibrary.Store.UI.ps1:Submit-DomeniaQueryLibraryMigrationBatch`, `Domenia-QueryLibrary.Store.UI.ps1:Complete-DomeniaQueryLibraryMigrationBatch`, `Domenia-Query.Model.ps1:ConvertFrom-DomeniaQueryLibrary`

#### TRV-280 · Validation des définitions côté écrivain

`a-faire` · locale (aucune lecture)

Le worker d'écriture revalide chaque définition avec le code de confiance des modèles (format, identité, liste blanche, compilation) avant de la stocker.

- Garde-fous : 1 Mio max ; aucune recette concaténée dans du code exécutable.
- Opérations : `LocalStore`
- Références D1 : `Domenia-QueryLibrary.Model.ps1:Get-DomeniaQueryLibraryDefinitionValidationCode`, `Assert-WQueryLibraryDefinition`

### Stockage · reçus d'écriture

#### TRV-281 · Reçu durable écrit avant tout envoi

`a-faire` · écriture

Toute écriture AD, action distante ou opération non classée écrit un reçu « Prepared » puis « Sent » sur disque avant que la demande parte ; le reçu garde l'opération, le domaine, le contrôleur, l'identité, le DN, le GUID, l'empreinte du plan, l'heure d'envoi et les valeurs attendues sous forme d'empreintes SHA-256 (attributs secrets exclus), ou l'état à relire (point 49).

- Garde-fous : Échec d'écriture du reçu = pas d'envoi (fail closed) ; écriture atomique (fichier temporaire, flush, Replace) ; 64 Ko max ; identifiant 32 hex ; reçu redirigé refusé ; aucune valeur secrète ; jamais de rejeu à la reprise.
- Opérations : `ReceiptStore`
- Références D1 : `modules/Domenia-Receipts.Worker.ps1:New-WReceipt`, `modules/Domenia-Receipts.Worker.ps1:Write-WReceipt`, `modules/Domenia-Receipts.Worker.ps1:Set-WReceiptStage`, `modules/Domenia-Receipts.Worker.ps1:Get-WReceiptHash`, `modules/Domenia-Safety.Model.ps1:Get-DomeniaReceiptRequirement`, `modules/Domenia-Safety.Model.ps1:ConvertTo-DomeniaReceiptRecord`, `modules/Domenia-Safety.Model.ps1:Get-DomeniaReceiptExpectation`

#### TRV-282 · Dossier des reçus local et protégé

`a-faire` · locale (aucune lecture)

Le dossier des reçus doit être local (pas de chemin UNC), sans point d'analyse sur tout son chemin, et sa DACL est réécrite pour l'utilisateur, SYSTEM et Administrateurs seulement.

- Garde-fous : Erreur DOMENIA_RECEIPT_DACL si la protection échoue ; propriétaire, groupe et audit inchangés.
- Opérations : `ReceiptStore`
- Références D1 : `modules/Domenia-Receipts.Worker.ps1:Get-WReceiptRoot`

#### TRV-283 · Compaction et archivage des reçus

`a-faire` · locale (aucune lecture)

Au-delà de 384 reçus, les reçus terminés (Vérifié, Non envoyé, Revue, Livré) les plus anciens passent dans archive\ pour en garder 256 ; les reçus non résolus restent en place.

- Garde-fous : Sous verrou writer.lock ; plus de 4096 fichiers ou plus de 512 reçus non résolus = vérification manuelle requise ; fichiers illisibles ou redirigés laissés en place.
- Opérations : `ReceiptStore`
- Références D1 : `modules/Domenia-Receipts.Worker.ps1:Invoke-WReceiptCompaction`, `modules/Domenia-Receipts.Worker.ps1:Get-DomeniaReceiptWorkerCode`

### Tableaux · accessibilité

#### TRV-284 · Accessibilité des tableaux

`ameliore` · locale (aucune lecture)

Noms et aides d'automatisation sur widgets, boutons, listes et sections, éléments de catalogue lus par ToString (nom, section, déjà affiché, interroge le poste), contrastes 4,5:1 des marques et 3:1 des contours.

- Références D1 : `Domenia-Widgets.UI.ps1:New-DomeniaBoardWidget`, `Domenia-Widgets.UI.ps1:Get-DomeniaBoardSources`, `Domenia-Charts.UI.ps1:Get-DomeniaChartEdgePalette`

### Tableaux · catalogue

#### TRV-285 · Catalogue de widgets intégré

`fait` · locale (aucune lecture)

Catalogue figé par tableau (parc, poste, logiciels) : clé, section, titre, type de donnée, représentation, taille, description, présence dans la disposition livrée ; lu par l'éditeur et le dessin.

- Garde-fous : Copies renvoyées (le cache n'est jamais modifié) ; jamais de données vivantes en cache.
- Références D1 : `Domenia-Boards.Model.ps1:$DomeniaBoardCatalogText`, `Domenia-Boards.Model.ps1:Get-DomeniaBoardCatalog`, `Domenia-Boards.Model.ps1:Get-DomeniaBoardCatalogItem`, `Domenia-Boards.Model.ps1:Get-DomeniaBoardCatalogCache`, `Domenia-Boards.Model.ps1:Get-DomeniaBoardCategoryLabel`

#### TRV-286 · Représentations autorisées par type de donnée

`fait` · locale (aucune lecture)

Douze représentations (chiffre clé, jauge, anneau, barres, histogramme, courbe, liste, liste de points, score et points, score, fiche, liste d'état) proposées selon le type ; la courbe seulement pour des valeurs datées ; une représentation enregistrée devenue invalide est corrigée.

- Références D1 : `Domenia-Boards.Model.ps1:Get-DomeniaBoardVisuals`, `Domenia-Boards.Model.ps1:Resolve-DomeniaBoardVisual`, `Domenia-Boards.Model.ps1:Get-DomeniaBoardVisualNames`

#### TRV-287 · Sources proposées comme widgets

`a-faire` · locale (aucune lecture)

Liste les informations du tableau, les sondes WMI prêtes (description, limites, compatibilité, résumé du contrat : droits, coût, comportement ; classe WMI en info-bulle ; requête lente signalée) et « Mes requêtes » enregistrées.

- Garde-fous : Sonde non conforme à Domenia.ProbeContract/1 jamais proposée, refus journalisé ; libellés lisibles par lecteur d'écran.
- Références D1 : `Domenia-Widgets.UI.ps1:Get-DomeniaBoardSources`

### Tableaux · collecte par widget

#### TRV-288 · Suspendre / reprendre la mesure d'un widget

`fait` · écriture

Le widget garde sa place, sa taille et son titre, s'affiche « suspendu » et sort de toutes les collectes et calculs ; le texte explique ce qui reste lu pour les autres (inventaire, copie AD, ping, WMI de la santé) ; reprendre collecte ce qui manque.

- Garde-fous : Relevé lancé seulement pour des widgets désormais suspendus arrêté ; retiré de la file ; annulable. Aucune économie promise qui n'existe pas.
- Références D1 : `Domenia-Widgets.UI.ps1:Set-DomeniaBoardItemPaused`, `Domenia-Boards.Model.ps1:Test-DomeniaBoardItemPaused`, `Domenia-Boards.Model.ps1:Select-DomeniaActiveBoardItems`, `Domenia-WidgetCollect.Model.ps1:Get-DomeniaWidgetPauseText`

#### TRV-289 · Actualiser un seul widget

`fait` · lecture réseau

Bouton rond du pied, menu ou F5 : relit seulement ce que le widget affiche pour sa population (poste sélectionné ou postes actifs de l'OU) : relevé ping/console/inventaire/sondes, inventaire du poste, liste des logiciels, relecture de fiche, lecture AD de l'OU, présence BitLocker ou recalcul local.

- Garde-fous : Jamais le domaine entier ; widget suspendu refusé ; inventaire déjà suffisant non relancé ; info-bulle dit ce qui sera lu ; source inconnue = rien lancé ; ping avant WMI. Relevé WMI personnalisé seulement depuis la définition enregistrée (clé 64 hex, empreinte vérifiée)
- Opérations : `LiveConsole`, `ParkPing`, `ParkSweep`, `ComputerInventory`, `SoftwareInventory`, `IndexBuild`, `BitLockerPresence`, `LocalIndexRead`, `WidgetWmiDetail`
- Références D1 : `Domenia-Widgets.UI.ps1:Start-DomeniaWidgetRefresh`, `Domenia-Widgets.UI.ps1:Start-DomeniaWidgetRemoteCollect`, `Domenia-Widgets.UI.ps1:Get-DomeniaWidgetNeed`, `Domenia-WidgetCollect.Model.ps1:Get-DomeniaWidgetCollectionNeed`, `Domenia-WidgetCollect.Model.ps1:Get-DomeniaWidgetFieldNeeds`, `Domenia-WidgetCollect.Model.ps1:Get-DomeniaWidgetNeedText`, `Domenia-Widgets.UI.ps1:Get-DomeniaWidgetPopulation`, `Domenia-WidgetCollect.Model.ps1:Get-DomeniaWidgetSourceFamilies`

#### TRV-290 · Collecte immédiate à l'ajout d'un widget

`a-faire` · lecture réseau

Ajouter un widget est le geste explicite : il collecte aussitôt ce qui lui manque (seulement les postes sans mesure récente), sans confirmation jusqu'à 200 postes ; Actualiser et Reprendre confirment le nombre.

- Garde-fous : Réutilisation des mesures de moins de MaxAge jours ; plafond SE-05 des relevés appliqué.
- Opérations : `LiveConsole`, `ParkSweep`
- Références D1 : `Domenia-Widgets.UI.ps1:Invoke-DomeniaBoardAction (Add)`, `Domenia-WidgetCollect.Model.ps1:Get-DomeniaWidgetCollectAdmission`

#### TRV-291 · File d'attente des collectes de widgets

`a-faire` · locale (aucune lecture)

Un seul relevé par portée (poste ouvert / listes et OU) : un widget ajouté ou actualisé pendant un relevé ou un recalcul de l'OU attend en file (20 max), puis démarre une fois les écritures locales confirmées et le nouvel instantané dessiné.

- Garde-fous : Collecte abandonnée et annoncée si le poste ou l'OU affichés ont changé ; jamais deux fois le même widget ; autre session expirée.
- Références D1 : `Domenia-Widgets.UI.ps1:Add-DomeniaWidgetCollectQueue`, `Domenia-Widgets.UI.ps1:Start-DomeniaQueuedWidgetCollect`, `Domenia-Widgets.UI.ps1:Get-DomeniaQueuedWidgetState`, `Domenia-WidgetCollect.Model.ps1:Get-DomeniaWidgetCollectSlot`

#### TRV-292 · Progression de collecte sur le widget

`a-faire` · locale (aucune lecture)

Ligne de progression mise à jour chaque seconde (en file, recherche des mesures manquantes N/M, confirmation, collecte N/M avec déjà frais et échecs, inventaire, lecture AD, BitLocker, logiciels, recalcul, WMI mémorisé) ; le chiffre affiché reste le dernier lu ; tableau redessiné à la fin.

- Garde-fous : Progression montrée seulement sur le tableau du poste ou de l'OU de la demande ; minuterie protégée liée à la session, arrêtée quand rien n'est suivi. Le chiffre affiché reste le dernier réellement lu.
- Références D1 : `Domenia-Widgets.UI.ps1:Register-DomeniaWidgetCollect`, `Domenia-Widgets.UI.ps1:Get-DomeniaWidgetActivityText`, `Domenia-Widgets.UI.ps1:Update-DomeniaWidgetCollectProgress`, `Domenia-Widgets.UI.ps1:Get-DomeniaWidgetPopulationKey`, `Domenia-Widgets.UI.ps1:Test-DomeniaWidgetPopulationCurrent`, `Domenia-WidgetCollect.Model.ps1:Format-DomeniaWidgetCollectProgress`

### Tableaux · copie

#### TRV-293 · Copier un widget en texte

`fait` · locale (aucune lecture)

Menu Copier ou Ctrl+C : titre et valeur, sous-titre, détail, badge, lignes (points, fiche, parts avec %), date des données, en texte brut pour un ticket.

- Garde-fous : Secrets masqués avant le presse-papiers ; texte jamais journalisé ; widget suspendu ou vide = rien copié ; 20 lignes max puis « et N autres ».
- Références D1 : `Domenia-Widgets.UI.ps1:Copy-DomeniaBoardWidget`, `Domenia-Widgets.UI.ps1:Copy-DomeniaBoardText`, `Domenia-Widgets.UI.ps1:Get-DomeniaBoardDataMoment`, `Domenia-Boards.Model.ps1:ConvertTo-DomeniaWidgetText`, `Domenia-Boards.Model.ps1:ConvertTo-DomeniaBoardItemLines`, `Domenia-Boards.Model.ps1:Format-DomeniaBoardTextNumber`

#### TRV-294 · Copier le résumé du tableau

`ameliore` · locale (aucune lecture)

Bouton de barre d'outils : objet ou OU et date (inventaire, calcul, liste), santé avec score, verdict, badge et points, puis faits principaux (fiches poste ; comptes et sécurité de l'OU ; synthèse logiciels).

- Garde-fous : OU des chiffres affichés, jamais l'OU choisie depuis ; secrets masqués.
- Références D1 : `Domenia-Widgets.UI.ps1:Copy-DomeniaBoardSummary`, `Domenia-Boards.Model.ps1:ConvertTo-DomeniaBoardSummaryText`, `Domenia-Boards.Model.ps1:Get-DomeniaBoardScopeName`, `Domenia-Boards.Model.ps1:Get-DomeniaBoardName`

### Tableaux · explication

#### TRV-295 · Comprendre ce chiffre

`fait` · locale (aucune lecture)

Explication d'un widget sans rien relire : valeur affichée, formule, périmètre, critères, exclusions, couverture, dates, postes du total, ce que relit son actualisation ; table documentée d'environ 90 widgets intégrés et description dérivée pour les widgets de sonde.

- Garde-fous : Aucune lecture pour expliquer ; Afficher les postes refusé si le calcul a été remplacé (point 73). Relevés de plus de 30 jours ignorés annoncés ; un recalcul ne rajeunit jamais une mesure. Formule non documentée dite telle quelle.
- Références D1 : `Domenia-Widgets.UI.ps1:Show-DomeniaWidgetExplanation`, `Domenia-Widgets.UI.ps1:Get-DomeniaWidgetExplanationData`, `Domenia-WidgetCollect.Model.ps1:Get-DomeniaWidgetExplanation`, `Domenia-WidgetCollect.Model.ps1:Get-DomeniaProbeWidgetSource`, `Domenia-WidgetCollect.Model.ps1:Get-DomeniaWidgetSourceTable`, `Domenia-WidgetCollect.Model.ps1:Get-DomeniaWidgetSource`, `Domenia-WidgetCollect.Model.ps1:$DomeniaWidgetSourceText`

#### TRV-296 · Dates des données en pied de widget

`fait` · locale (aucune lecture)

Chaque widget affiche, par source (AD, AD · BitLocker, Ping, WMI · console, WMI · inventaire, WMI / registre, Registre · logiciels, WMI · sonde, requête mémorisée), la date ou l'intervalle des données et le nombre non lus ; pendant un relevé des listes, « Relevé en cours · partiel · N/M ».

- Garde-fous : Seules les horloges de succès ; une tentative échouée ou un redessin ne rajeunit jamais ; date future = « non daté ». Date future ou absente = « non daté » ; une tentative en échec ne remplace pas une date.
- Références D1 : `Domenia-Widgets.UI.ps1:Get-DomeniaWidgetDataDates`, `Domenia-Widgets.UI.ps1:Get-DomeniaWidgetSurveyPartialText`, `Domenia-WidgetCollect.Model.ps1:Format-DomeniaWidgetDataDates`, `Domenia-WidgetCollect.Model.ps1:Get-DomeniaWidgetSourceFamilies`, `Domenia-WidgetCollect.Model.ps1:Get-DomeniaWidgetDetailClocks`

### Tableaux · graphiques

#### TRV-297 · Animations d'entrée respectueuses du réglage Windows

`ameliore` · locale (aucune lecture)

Cartes qui apparaissent l'une après l'autre, anneaux et barres qui se dessinent, chiffres qui comptent ; désactivées si les animations Windows sont coupées (accessibilité, session distante).

- Garde-fous : Minuterie protégée de priorité normale, arrêtée à la fin.
- Références D1 : `Domenia-Charts.UI.ps1:Test-DomeniaMotion`, `Domenia-Charts.UI.ps1:Invoke-DomeniaDashboardEntrance`, `Domenia-Charts.UI.ps1:Register-DomeniaCountUp`, `Domenia-Charts.UI.ps1:Start-DomeniaCountTimer`, `Domenia-Charts.UI.ps1:Start-DomeniaTween`

#### TRV-298 · Graphiques natifs des tableaux

`fait` · locale (aucune lecture)

Anneau (8 parts max + Autres, survol lié légende/segment, légende cliquable), jauge trois-quarts colorée par l'état, barres horizontales (12 lignes), histogramme (valeurs sur colonnes jusqu'à 12), courbe avec aire et dernier point, tuile chiffre clé (27 px chiffre, 18 px texte), carte score, carte Santé score + points (empilée sous 520 px), fiche, liste d'état, liste de valeurs, carte vide.

- Garde-fous : Partie cliquable seulement si elle porte un critère ; une série = une couleur ; couleurs de sens seulement quand elles ont un sens.
- Références D1 : `Domenia-Charts.UI.ps1:New-DomeniaDonutChart`, `Domenia-Charts.UI.ps1:New-DomeniaGauge`, `Domenia-Charts.UI.ps1:New-DomeniaBarChart`, `Domenia-Charts.UI.ps1:New-DomeniaColumnChart`, `Domenia-Charts.UI.ps1:New-DomeniaLineChart`, `Domenia-Charts.UI.ps1:New-DomeniaKpiTile`, `Domenia-Charts.UI.ps1:New-DomeniaHealthCard`, `Domenia-Charts.UI.ps1:New-DomeniaHealthSummaryCard`, `Domenia-Charts.UI.ps1:New-DomeniaSheetCard`, `Domenia-Charts.UI.ps1:New-DomeniaListCard`, `Domenia-Charts.UI.ps1:New-DomeniaAttentionCard`, `Domenia-Charts.UI.ps1:New-DomeniaChartEmpty`, `Domenia-Widgets.UI.ps1:New-DomeniaWidgetVisual`

#### TRV-299 · Graduations, nombres et durées lisibles

`fait` · locale (aucune lecture)

Graduations arrondies 1/2/5×10^n (pas entiers pour les comptes), nombres à la française, tailles en Mo/Go/To, âges « il y a N min/h/j », couverture « N postes analysés sur M, le jj/MM ».

- Garde-fous : Jamais un demi-poste sur un axe.
- Références D1 : `Domenia-Boards.Model.ps1:Get-DomeniaChartTicks`, `Domenia-Boards.Model.ps1:Format-DomeniaDashboardSize`, `Domenia-Boards.Model.ps1:Format-DomeniaAge`, `Domenia-Boards.Model.ps1:Get-DomeniaCoverageText`, `Domenia-Boards.Model.ps1:Test-DomeniaBoardNumberText`, `Domenia-Charts.UI.ps1:Format-DomeniaChartNumber`

#### TRV-300 · Regroupement « Autres » sans perte de sélection

`fait` · locale (aucune lecture)

Limite les catégories dessinées et regroupe le reste en « Autres (N catégories) » qui conserve les postes et critères de chaque catégorie regroupée.

- Garde-fous : Aucune catégorie supprimée.
- Références D1 : `Domenia-Boards.Model.ps1:Get-DomeniaChartCategoryGroups`, `Domenia-Widgets.UI.ps1:Set-DomeniaBoardSegmentSelection`

### Tableaux · moteur

#### TRV-301 · Table des fins de service livrée

`fait` · lecture locale

Table livrée des fins de service par build et famille (Pro, Entreprise, LTSC, IoT, Serveur ; 45 entrées, revue 2026-10-08) utilisée par les règles et widgets de fin de service.

- Garde-fous : Format contrôlé (Resolve-DomeniaContractFormat : version plus récente nommée) ; absente, vide ou illisible = dates inconnues, journal WARN. Jamais téléchargée : mise à jour par livraison uniquement ; format versionné.
- Références D1 : `Domenia-Dashboard.UI.ps1:Get-DomeniaWindowsLifecycleTable`, `Domenia-WindowsLifecycle.json`

#### TRV-302 · Seuils et politique de santé appliqués aux tableaux

`fait` · locale (aucune lecture)

Une seule table de seuils pour dessin, tuile et point (disque libre critique/à surveiller, mémoire utilisée, batterie, jours de mot de passe, d'inactivité, de redémarrage), lue dans la politique de santé, éventuellement par OU (livre de politiques), avec règles personnalisées (mesures et requêtes).

- Garde-fous : Règle de requête sans données = information « données insuffisantes » et badge, jamais conforme.
- Références D1 : `Domenia-Boards.Model.ps1:Get-DomeniaBoardThresholds`, `Domenia-Boards.Model.ps1:Get-DomeniaThresholdState`, `Domenia-Dashboard.UI.ps1:Start-DomeniaFleetDashboard (Resolve-DomeniaHealthPolicy)`, `Domenia-BoardComputer.UI.ps1:Get-DomeniaComputerBoardData (QueryHealthEvidence)`

#### TRV-303 · Rendu différé des tableaux cachés

`fait` · locale (aucune lecture)

Un tableau mis à jour pendant qu'il est caché se dessine à sa prochaine apparition, seulement si la session, l'objet ou l'OU sont restés les mêmes ; sinon il est vidé.

- Garde-fous : Jamais d'affichage fugitif de l'OU ou de l'objet précédent.
- Références D1 : `Domenia-Widgets.UI.ps1:Show-DomeniaBoard (DeferIfHidden)`, `Domenia-Widgets.UI.ps1:Resume-DomeniaBoardRender`, `Domenia-Widgets.UI.ps1:Get-DomeniaBoardRenderContext`

#### TRV-304 · Redessin au changement de thème

`fait` · locale (aucune lecture)

Clair, sombre, automatique ou contraste élevé : tous les tableaux déjà dessinés sont redessinés depuis leurs données, sans animation ni lecture ; focus clavier conservé.

- Garde-fous : Couleurs uniquement depuis SupportSuite.UI.json ; jaune, vert et rouge réservés aux états.
- Références D1 : `Domenia-Widgets.UI.ps1:Update-DomeniaBoardsTheme`, `Domenia-Charts.UI.ps1:Get-DomeniaChartPalette`, `Domenia-Charts.UI.ps1:ConvertTo-DomeniaChartBrush`

#### TRV-305 · Contrat de données des widgets

`fait` · locale (aucune lecture)

Format commun fournisseur → rendu : entrée (Value, Number, Distribution, Measure, Series, List, Health, Timeline, Sheet, Checklist) avec état, unité, sous-titre, badge et action optionnelle ; données de tableau avec points, points supprimés, indications et actions de section.

- Garde-fous : Une action n'est jamais exécutée par une règle, seulement par l'interface au clic.
- Références D1 : `Domenia-Boards.Model.ps1:New-DomeniaBoardEntry`, `Domenia-Boards.Model.ps1:New-DomeniaBoardData`, `Domenia-Boards.Model.ps1:Add-DomeniaBoardEntry`, `Domenia-Boards.Model.ps1:Get-DomeniaBoardColor`

### Tableaux · personnalisation

#### TRV-306 · Mode Personnaliser

`fait` · locale (aucune lecture)

Bascule Personnaliser/Terminer : boutons ronds toujours visibles, tuile « Ajouter ici » en fin de section, Monter/Descendre une section entière, aide clavier dans la barre, dispositions prêtes, Par défaut, Exporter, Importer.

- Garde-fous : Déplacement de section annulable ; changement sans effet ignoré.
- Références D1 : `Domenia-Widgets.UI.ps1:New-DomeniaBoardToolbar`, `Domenia-Widgets.UI.ps1:New-DomeniaBoardAddTile`, `Domenia-Widgets.UI.ps1:Add-DomeniaBoardSectionMoves`, `Domenia-Boards.Model.ps1:Move-DomeniaBoardGroup`, `Domenia-Boards.Model.ps1:Get-DomeniaBoardGroups`

#### TRV-307 · Ajouter ou modifier un widget

`fait` · locale (aucune lecture)

Panneau dans la page : recherche sans accents avec synonymes (RAM, SSD, Defender, reboot, IP, uptime, MAJ…), filtres par origine et catégorie, badges « Déjà affiché » et « Interroge le poste », vignettes de représentation, titre, taille, section ou nouvelle section, aperçu en direct (vraies données ou exemple) ; Annuler / Ajouter ou Enregistrer.

- Garde-fous : Ajout annulable ; avertissement de lecture du poste (parc : confirmation au-delà de 200 postes) ; Échap ferme sans changement.
- Références D1 : `Domenia-Widgets.UI.ps1:Show-DomeniaBoardEditor`, `Domenia-Widgets.UI.ps1:New-DomeniaBoardVisualPicker`, `Domenia-Widgets.UI.ps1:New-DomeniaBoardChip`, `Domenia-Widgets.UI.ps1:Get-DomeniaBoardPreviewEntry`, `Domenia-Boards.Model.ps1:New-DomeniaBoardSample`, `Domenia-Boards.Model.ps1:Get-DomeniaBoardSearchTerms`, `Domenia-Boards.Model.ps1:Test-DomeniaBoardSourceMatch`, `Domenia-Boards.Model.ps1:ConvertTo-DomeniaSearchText`

#### TRV-308 · Déplacer, redimensionner, changer de représentation, retirer

`fait` · écriture

Glisser-déposer d'un widget sur un autre ou dans une section (défilement auto près des bords), menu Déplacer (début, gauche, droite, fin), Taille, Représentation, Retirer du tableau de bord.

- Garde-fous : Glisser seulement en personnalisation ; boutons ronds gardent leur clic ; chaque geste annulable ; retrait suspend les collectes associées.
- Références D1 : `Domenia-Boards.Model.ps1:Move-DomeniaBoardItem`, `Domenia-Boards.Model.ps1:Update-DomeniaBoardItem`, `Domenia-Boards.Model.ps1:Remove-DomeniaBoardItem`, `Domenia-Boards.Model.ps1:Add-DomeniaBoardItem`, `Domenia-Boards.Model.ps1:Get-DomeniaBoardNextSize`, `Domenia-Widgets.UI.ps1:Request-DomeniaBoardDrop`, `Domenia-Widgets.UI.ps1:Complete-DomeniaBoardDrop`, `Domenia-Widgets.UI.ps1:Invoke-DomeniaBoardAutoScroll`, `Domenia-Widgets.UI.ps1:Invoke-DomeniaBoardAction`

#### TRV-309 · Annuler les changements de disposition

`ameliore` · locale (aucune lecture)

Pile des 10 derniers changements par tableau avec bouton Annuler et libellé du changement ; Ctrl+Z sur le tableau (hors champ texte).

- Garde-fous : Nouvelles données ne vident jamais la pile ; changement sans effet ni enregistré ni empilé.
- Références D1 : `Domenia-Widgets.UI.ps1:Set-DomeniaBoardLayout`, `Domenia-Widgets.UI.ps1:Sync-DomeniaBoardUndo`, `Domenia-Widgets.UI.ps1:Clear-DomeniaBoardUndo`, `Domenia-Widgets.UI.ps1:Show-DomeniaBoard (PreviewKeyDown Ctrl+Z)`

#### TRV-310 · Dispositions prêtes Support, Inventaire, Santé

`fait` · écriture

Place en tête les informations utiles au cas d'usage en ajoutant les widgets manquants, sans retirer les widgets personnalisés ni changer leurs tailles.

- Garde-fous : Annulable ; aucune collecte.
- Références D1 : `Domenia-Boards.Model.ps1:Get-DomeniaBoardPresetLayout`

#### TRV-311 · Revenir à la disposition par défaut ou d'équipe

`fait` · lecture locale

« Par défaut » applique la disposition d'équipe définie par l'administrateur (clé Dashboard.DefaultLayout&lt;Board> de Domenia.config.json) si elle contient au moins un widget connu, sinon la disposition livrée.

- Garde-fous : Disposition d'équipe illisible ou vide ne vide jamais un tableau ; requêtes personnelles exclues d'une disposition d'équipe ; annulable.
- Références D1 : `Domenia-Widgets.UI.ps1:Get-DomeniaBoardDefaultLayoutFor`, `Domenia-Widgets.UI.ps1:Get-DomeniaBoardTeamLayoutText`, `Domenia-Boards.Model.ps1:Get-DomeniaBoardDefaultLayout`, `Domenia-Boards.Model.ps1:Get-DomeniaBoardTeamLayout`, `Domenia-Boards.Model.ps1:Get-DomeniaBoardCatalogLayout`

#### TRV-312 · Exporter / importer une disposition JSON

`fait` · écriture

Exporte la disposition du tableau (Format Domenia.BoardLayout.1, horodatée, nom Domenia-disposition-&lt;poste|accueil|logiciels>-AAAAMMJJ-HHmm.json) dans le dossier des exports avec bannière « Ouvrir le dossier » ; importe un fichier choisi dans le sélecteur intégré, vérifié puis appliqué en un changement annulable.

- Garde-fous : Jamais d'écrasement (suffixe -2, -3…) ; .json seulement, 1 Mo max, chemins redirigés refusés ; disposition d'un autre tableau refusée ; widgets inconnus et requêtes absentes ignorés et comptés ; un document à la fois ; message de refus traduit, brut au journal.
- Opérations : `DocumentStore`
- Références D1 : `Domenia-Widgets.UI.ps1:Export-DomeniaBoardLayout`, `Domenia-Widgets.UI.ps1:Import-DomeniaBoardLayout`, `Domenia-Widgets.UI.ps1:Start-DomeniaBoardDocumentTask`, `Domenia-Widgets.UI.ps1:Complete-DomeniaBoardDocument`, `Domenia-Widgets.UI.ps1:Fail-DomeniaBoardDocument`, `Domenia-Boards.Model.ps1:ConvertTo-DomeniaBoardLayoutDocument`, `Domenia-Boards.Model.ps1:ConvertFrom-DomeniaBoardLayoutDocument`, `Domenia-Boards.Model.ps1:Get-DomeniaBoardLayoutFileName`, `Domenia-Boards.Model.ps1:Get-DomeniaBoardDocumentMessage`

#### TRV-313 · Persistance et migration des dispositions

> Reste à faire : Disposition par tableau enregistrée dans les préférences du moteur (shell.boards) avec ses cinq versions restaurables et une copie de secours dans le profil WebView2, lue avant toute sauvegarde (écran monté avant la réponse du moteur : disposition enregistrée adoptée tant que rien n’a changé), liste simple de la version 1 reprise, clés de widgets de Domenia 1 traduites (legacyKeys) ; reste la reprise des clés Dashboard.<Board>.Layout et Widgets.<Board> de la base SQLite de Domenia 1, quand Domenia.Store lira le schéma 11.

`partiel` · écriture

Enregistre la disposition par tableau (Dashboard.&lt;Board>.Layout) ; reprend les widgets de la première version (Widgets.&lt;Board>) ; remplace une disposition livrée antérieure restée inchangée (RC1.13.0, paire score/points, poste complet avant et après W11) ; nettoie widgets inconnus, représentations, tailles et identifiants déterministes.

- Garde-fous : Liste vide « [] » = tableau vidé volontairement, reste vide ; disposition modifiée par l'opérateur jamais remplacée ; Paused écrit seulement si vrai ; widget enregistré sans donnée annoncé.
- Références D1 : `Domenia-Widgets.UI.ps1:Get-DomeniaBoardLayout`, `Domenia-Widgets.UI.ps1:Get-DomeniaWidgetList`, `Domenia-Widgets.UI.ps1:Set-DomeniaBoardLayout`, `Domenia-Boards.Model.ps1:ConvertTo-DomeniaBoardLayout`, `Domenia-Boards.Model.ps1:ConvertTo-DomeniaBoardCleanLayout`, `Domenia-Boards.Model.ps1:Test-DomeniaBoardLegacyLayout`, `Domenia-Boards.Model.ps1:Test-DomeniaBoardLayoutText`, `Domenia-Boards.Model.ps1:ConvertTo-DomeniaBoardLayoutJson`, `Domenia-Boards.Model.ps1:Get-DomeniaBoardLayoutRows`

### Tableaux · widgets

#### TRV-314 · Places compactes des widgets sans chiffre

`fait` · locale (aucune lecture)

Un widget sans valeur garde une petite place qui dit pourquoi (suspendu, en collecte, lu par l'inventaire complet seulement, absent du dernier relevé, pas encore collecté ou calculé) avec le bouton Collecter, Relire, Recalculer ou Reprendre la mesure.

- Garde-fous : Jamais une mesure fictive. Jamais une mesure inventée.
- Références D1 : `Domenia-WidgetCollect.Model.ps1:Get-DomeniaWidgetPlaceholder`, `Domenia-Widgets.UI.ps1:New-DomeniaWidgetStateCard`, `Domenia-WidgetCollect.Model.ps1:Test-DomeniaComputerInventoryDeep`

#### TRV-315 · Grille adaptative et tailles des widgets

`fait` · locale (aucune lecture)

Grille de 4, 3, 2 ou 1 colonnes selon la largeur (1100/780/440 px, hystérésis 24 px), widgets Compacte/Moyenne/Large sur 1/2/3 colonnes, tuiles compactes empilées par deux à côté d'une carte haute, hauteurs alignées par rangée, redessin groupé 300 ms après redimensionnement, réduction d'échelle (≥0,6) si trop étroit, arrondi de mise en page en DPI fractionnaire.

- Garde-fous : Redimensionner ne relit ni ne recalcule rien ; focus clavier rendu au widget.
- Références D1 : `Domenia-Boards.Model.ps1:Get-DomeniaBoardColumnCount`, `Domenia-Boards.Model.ps1:Get-DomeniaBoardGridPlacement`, `Domenia-Boards.Model.ps1:Get-DomeniaBoardSpan`, `Domenia-Boards.Model.ps1:Get-DomeniaBoardSize`, `Domenia-Boards.Model.ps1:Get-DomeniaBoardFitScale`, `Domenia-Boards.Model.ps1:Test-DomeniaBoardRedrawNeeded`, `Domenia-Widgets.UI.ps1:Set-DomeniaBoardSectionGrid`, `Domenia-Widgets.UI.ps1:Update-DomeniaBoardGrid`, `Domenia-Widgets.UI.ps1:Request-DomeniaBoardRelayout`, `Domenia-Widgets.UI.ps1:Update-DomeniaBoardFit`

#### TRV-316 · Menu contextuel du widget

`fait` · locale (aucune lecture)

Clic droit ou Maj+F10 : Actualiser ce widget, Comprendre ce chiffre / le score, Copier, Suspendre/Reprendre la mesure, Modifier…, Représentation, Taille, Déplacer, Retirer ; boutons ronds équivalents au survol ou au focus.

- Références D1 : `Domenia-Widgets.UI.ps1:New-DomeniaBoardMenu`, `Domenia-Widgets.UI.ps1:New-DomeniaBoardChromeButton`, `Domenia-Widgets.UI.ps1:New-DomeniaBoardWidget`

## Nouveautés Domenia 2

### Décisions de David

| Décision (21 octobre 2026) | Où en est Domenia 2 |
|---|---|
| Interface WebView2 très animée (« master site », « web 4.0 »), sans rien perdre | En cours : coquille, navigation, palette, thèmes et Accueil faits (`web/`, `web/css/motion.css`, réglage « Animations riches, réduites, suivre Windows ») ; les autres écrans affichent la liste des fonctions à reprendre. |
| Pack autonome à dézipper, rien à installer | Fait : `tools/build-vm.ps1 -Publish -Zip` produit le dossier autonome (.NET 10 et WebView2 version fixe embarqués) et `Domenia.zip` ; mesuré le 21/10 (781 Mo, archive de 341 Mo). La publication en release GitHub reste à faire en fin de chantier. |
| Mode simulation sans AD | Fait : `src/Domenia.Core/Startup/ModeResolver.cs` (option `--simulation`, variable `DOMENIA_SIMULATION`, poste non joint) et annuaire fictif `example.local` (`src/Domenia.Simulation`), lecture seule, sans réseau ni disque. |
| « Mesure active » mémorisée par widget | À faire : la bascule existe (`dashboard.widget.setEnabled`), mais l'état n'est gardé qu'en mémoire ; il doit aller dans les préférences locales (classe d'opération `LocalWrite`, jamais d'écriture AD), avec un fichier séparé en simulation. |
| OU de travail globale, choisie dans un panneau d'arborescence avec recherche, mémorisée, défaut des sections sans choix propre | À faire : le bouton « Choisir l'OU » de l'Accueil est encore informatif. Fonctions de Domenia 1 à reprendre : PAR-047, PAR-048, RCH-005, TRV-242. |
| Interrupteur `Auth.DemoProvider` repris (`true` démarre aussi en simulation, raison « configuration ») | À faire : `ModeResolver` ne lit pas encore la configuration (TRV-020). |
| Widgets actualisables et désactivables sans quitter le tableau | Fait : `web/js/pages/accueil.js` et `dashboard.widget.refresh` / `dashboard.widget.setEnabled` (TRV-289 ; la mémorisation relève de la ligne « Mesure active »). |
| Fin de support de Windows | Non retenue par David. Les fonctions de Domenia 1 sur les fins de service (ACC-064, TRV-301) restent `a-faire` tant qu'aucune décision écrite ne les retire. |

### Écarts de Domenia 1 à corriger en passant

- La relecture « Vérifier par relecture » n'est offerte que pour `WriteAttributes`, alors que le worker des reçus sait vérifier déverrouillage, activation, mot de passe, expiration, déplacement, renommage, groupes, OU et suppression (`CanTryVerify`, `CanVerify`). (OPE-023)
- `Get-DomeniaVaultLoginReason` est définie mais jamais appelée : le bouton du coffre grisé n'explique pas pourquoi. (TRV-015)
- `logonCount` est lu sur chaque contrôleur mais jamais affiché. (FIC-042)
- L'opération `RimotteRun` est mal orthographiée partout (table, reçus, postconditions) : la renommer `RemoteRun` avec un alias pour relire les anciens reçus. (PST-016)
- `Get-DomeniaOperationDisplayName` n'a pas de libellé pour `ComputerServiceControl`, qui exige pourtant un reçu. (OPE-022)
- Plusieurs messages sont en ASCII sans accents (« Verification d ecriture en cours ») dans `Accounts.Async`, `Accounts.Store`, `Accounts.Vault`, `Receipts.Worker` et dans les textes d'annulation du moteur. (OPE-018)
- La revérification des recherches transmet un `HighestUsn` vide au point de reprise incrémental : seule la paire contrôleur et `invocationId` est vérifiée. (RCH-047)
- La lecture des verrouillages a une fenêtre fixe de 168 h dans l'interface, alors que le worker accepte de 1 à 720 h. (FIC-040)
- `BtnIndexBuild`, `BtnIndexRefresh` et `BtnFleetScopeReset` sont câblés dans le cœur mais absents du XAML (câblage mort).
- `Start-DomeniaResultPresenceScan` n'a plus d'appelant : ne pas la reprendre telle quelle. (RCH-085)
- Les clés `ParkSweep.HarvestDays`, `ParkSweep.HarvestMaxEvents`, `ParkSweep.SharedPath`, `Inventory.PreferWinrm` et `Async.ComputerTimeoutSeconds` sont lues mais absentes de `New-DefaultConfig`. (PAR-042)
- Le paramètre `-Diagnostic` de `Domenia-Start.ps1` est déclaré mais inutilisé. (TRV-029)

### Règles écrites mais non raccordées dans Domenia 1 (à raccorder ou non, sur décision)

Comparaison simple de deux utilisateurs (FIC-004), Modification des groupes en delta (FIC-022), Plans de cycle de vie (OPE-011), Comparaison entre contrôleurs (AUD-008), Nom de favori et vue enregistrée (RCH-137), Projection d'export par liste blanche (TRV-203), Diagnostic rapide du poste (PST-004), Préréglages d'événements (PST-031), Analyse de dsregcmd (PST-033), Faits de mise à jour par fournisseur (PST-034), Wake-on-LAN (PST-019), Lancement de Pesto ou FILPRO avec contrat (PST-020), Sources de l'inventaire logiciel (PST-045), Garde anti-Windows Installer (TRV-188), Relations rattachées au GUID (REL-005), Compte rendu de ticket pseudonymisé (ASS-002), Tampon de pages borné (TRV-137), Validation d'une entrée de cache (TRV-160), Catalogue du cache (PAR-030), File d'écriture des associations (REL-012), Inventaire des composants livrés (PAR-002), Connecteurs WAPT (PST-001). Les règles de livraison de `Release.Model` ne servent aujourd'hui qu'à l'outillage et aux tests.

### Améliorations proposées par les lecteurs, regroupées

Chaque ligne renvoie à la fonction concernée. Ces améliorations s'ajoutent après la parité de chaque écran (ordre de réalisation d'`ARCHITECTURE.md`).

#### Raccorder les règles écrites mais non branchées dans Domenia 1 (10)

- FIC-022 · Modification des groupes en delta (règle non raccordée) : Brancher sur l'édition multi-groupes de la fiche avec reçu par groupe.
- REL-005 · Relations rattachées au GUID du poste : Raccorder en D2 pour l'affichage des associations du poste.
- PST-001 · Connecteurs en lecture seule (WAPT) : Brancher réellement ce plan en D2 (règles écrites mais non appelées par l'interface D1) et l'étendre à GLPI et osquery en lecture.
- PST-004 · Diagnostic rapide borné (5 contrôles) : Le raccorder en D2 comme « Lire » rapide de l'en-tête du poste.
- PST-031 · Préréglages d'événements bornés : Raccorder en D2 avec sélection de préréglage et de fenêtre sur l'onglet Diagnostic.
- ASS-002 · Compte rendu de ticket pseudonymisé (modèle) : Câbler enfin ce rapport dans l'interface (aucun appelant hors tests en D1) avec aperçu et export.
- ASS-003 · Atelier support : comprendre la fiche (constats) : Brancher ces constats sur la fiche elle-même (bandeau) et ajouter des règles machines (LAPS expiré, BitLocker absent).
- AUD-008 · Comparaison d'un objet entre contrôleurs (règle non raccordée) : Brancher dans Audit AD > Contrôleurs.
- OPE-023 · Vérifier un reçu par relecture : En D1 l'interface n'offre la relecture que pour WriteAttributes alors que le worker sait vérifier les attentes du point 49 (déverrouillage, activation, mot de passe, déplacement, renommage, groupes, OU, suppression) : les exposer en Domenia 2.
- TRV-015 · Coffre Windows à la connexion : Câbler réellement Get-DomeniaVaultLoginReason (non appelée en D1) en infobulle du bouton grisé, et lister les comptes mémorisés sur ce PC pour choix rapide.

#### Socle Domenia 2 : C#, WebView2, accessibilité, compilation (36)

- RCH-006 · Arbre des OU virtualisé à chargement paresseux : Arbre virtuel natif côté WebView2 avec pagination des gros conteneurs.
- CPT-017 · Coffre Windows pour les comptes Postes et Secrets : Indiquer dans la page quels usages ont un mot de passe mémorisé (sans le lire) et la date d'enregistrement. Décider de l'activer en D2 (Credential Manager natif).
- REQ-055 · Exporter une requête en script PowerShell : Export C#/JSON pour Domenia 2 et pour l'interface automatisable.
- PAR-001 · Compatibilité du poste dans À propos : Refaire la matrice pour D2 (Windows, .NET, WebView2 Evergreen ou Fixed).
- PAR-008 · Thème clair, sombre ou automatique : prefers-color-scheme natif de WebView2.
- TRV-002 · Annonces au lecteur d'écran : Utiliser aria-live dans D2 avec le même contrat.
- TRV-003 · Noms accessibles des contrôles dynamiques : Conserver ces noms en ARIA côté WebView2.
- TRV-005 · Chapitre du guide et ouverture du PDF : Intégrer le guide en HTML dans D2 (WebView2), ouvert directement à la bonne ancre.
- TRV-009 · Palette unique validée et contraste WCAG : Exporter les jetons en variables CSS pour D2 et tester le contraste dans la CI.
- TRV-024 · Lanceur limité à Windows PowerShell 5.1 x64 STA : En D2, regrouper au même point la vérification du runtime .NET/WebView2 et de la signature de l'exécutable.
- TRV-025 · Contrôle d'intégrité du paquet à chaque lancement : Signer le manifeste et vérifier en C# natif, en parallèle, pour réduire le temps de démarrage. Signature Authenticode du paquet Domenia 2 et vérification au lancement de l'hôte C#.
- TRV-029 · Autotest sans lancement (-CheckOnly) : Exposer l'équivalent en D2 (domenia.exe --check) pour le support et l'installation.
- TRV-032 · Plan de modules fermé, phasé et ordonné : En C#, remplacer par l'injection de dépendances, avec un test de graphe au build.
- TRV-035 · Provenance déclarée de la bibliothèque commune M4D : En D2, référencer la brique commune en paquet NuGet interne épinglé.
- TRV-038 · Paramètres de lancement du cœur : Exposer ces options en arguments de ligne de commande documentés de Domenia 2 (--server, --base, --selftest).
- TRV-046 · Auto-test intégré en ligne de commande : Commande --selftest de l'hôte Domenia 2 utilisable en CI.
- TRV-060 · Contrôle statique des gestionnaires (pas de fenêtre modale) : Reprendre l'idée en analyseur Roslyn pour D2 (interdiction des dialogues natifs hors liste).
- TRV-063 · Kit d'interface partagé de la suite : En D2, générer des variables CSS depuis ce même JSON pour garder la cohérence avec Pesto et FILPRO. Faire de ces règles des tests d'architecture dans D2.
- TRV-067 · Interface automatisable locale (ligne de commande) : Même contrat exposé par Domenia 2 (CLI .NET) avec sortie JSON stable. API locale nommée (named pipe) ou export planifié pour SIEM.
- TRV-086 · Installation atomique par version : En D2, mise à jour MSIX ou installeur avec bascule de dossier versionné et retour arrière en un clic.
- TRV-100 · Lectures isolées hors processus : En Domenia 2 (C#), utiliser des processus de travail dédiés avec annulation coopérative et kill garanti. En D2, isoler par défaut les appels CIM/WMI lents (out-of-proc), ce qui permet de les tuer proprement.
- TRV-115 · Échappement RFC 4515 des valeurs LDAP : Une seule implémentation C# partagée UI/worker en Domenia 2.
- TRV-121 · Table déclarative unique des opérations : En D2, en faire un enum ou des attributs C# avec génération du registre des corps et test d'égalité au build.
- TRV-140 · Source du module Active Directory épinglée : En C#, utiliser System.DirectoryServices.Protocols directement et supprimer la dépendance au module PowerShell AD.
- TRV-141 · Moteur asynchrone de tâches : Task/Channel C# avec annulation coopérative réelle.
- TRV-165 · Chemins d'OU lisibles et décodage des DN : Bibliothèque C# unique de DN (System.DirectoryServices.Protocols).
- TRV-188 · Garde anti-Windows Installer : En D2 (C#), appliquer la même liste noire aux requêtes WMI construites côté moteur.
- TRV-193 · Identité immuable de sélection : Type record immuable C# partagé par toutes les pages.
- TRV-201 · Contrôle statique anti-affaiblissement de Windows : Intégrer en analyseur de build C# D2.
- TRV-217 · Mots de passe en SecureString : Utiliser des handles de credentials Windows (CredUI/LSA) côté C#.
- TRV-220 · Coffre natif : cible protégée et bornes : Porter tel quel en C# (DPAPI/Credential Manager) en gardant le même format de cible pour reprendre les entrées existantes de Domenia 1.
- TRV-266 · Couche SQLite unique des workers : En D2, Microsoft.Data.Sqlite avec paramètres et WAL, qui remplace ce P/Invoke manuel. Microsoft.Data.Sqlite côté C#.
- TRV-295 · Comprendre ce chiffre : Rendre l'explication exportable dans le résumé du ticket. Générer cette table depuis les métadonnées C# pour qu'elle ne diverge jamais du code.
- TRV-297 · Animations d'entrée respectueuses du réglage Windows : Respecter prefers-reduced-motion en WebView2.
- TRV-305 · Contrat de données des widgets : Schéma JSON typé partagé C#/JS.
- TRV-315 · Grille adaptative et tailles des widgets : CSS grid natif en WebView2 avec container queries.

#### Automatisation sûre et reprises (22)

- ACC-001 · Actualiser le périmètre depuis l'accueil (Objets AD, Ping, WMI, Tout) : Estimer la durée et le nombre de postes avant lancement ; reprise d'une collecte interrompue.
- ACC-009 · Analyser la vue : comparer deux relevés : Exporter la comparaison en rapport et la proposer automatiquement après une campagne.
- ACC-057 · Présence des clés BitLocker des postes d'une OU : Lister les postes sans aucune clé (écart avec l'inventaire de l'OU) et exporter. Afficher la date de la dernière lecture BitLocker directement sur la tuile et proposer une relecture planifiée.
- RCH-137 · Nom de favori et vue enregistrée en liste blanche (règles non raccordées) : Réutiliser ces règles pour nommer automatiquement les vues personnelles et valider les vues importées.
- CPT-008 · Corriger le mot de passe du compte de connexion sans reconnecter : Détecter automatiquement un « mot de passe expiré/changé » et proposer la correction en place dès le premier refus, avec l'âge du mot de passe (pwdLastSet).
- CPT-013 · Compte Postes (compte secondaire des opérations distantes) : Enchaîner automatiquement un « Essayer sur le poste sélectionné » facultatif après activation.
- REL-024 · Enregistrement des consoles confirmées : Stockage de plusieurs relations par poste (lever la limite d'une ligne par poste).
- REL-037 · Confirmer l'import : Lever la limite de 64 par lots successifs automatiques.
- PST-013 · Redémarrage du poste préparé dans la page : Proposer un choix de délai (5, 15, 30, 60 min) et l'annulation d'un redémarrage programmé (shutdown /a). Annuler un redémarrage différé (shutdown /a).
- PST-014 · Sessions lues avant le redémarrage : Lire automatiquement les sessions à l'ouverture du panneau Redémarrer.
- PST-016 · Exécuter un programme sur le poste : Ajouter une bibliothèque de commandes approuvées (signées par empreinte) et récupérer le code de sortie de la tâche. Récupérer le code retour et la sortie du programme.
- PST-019 · Wake-on-LAN volontaire : Enchaîner un ping de vérification après 60 s et l'afficher.
- REQ-069 · Recette locale depuis un SELECT testé : Planifier explicitement ce SELECT sur une OU avec confirmation et budget.
- SYN-022 · Enregistrer un relevé daté du périmètre : Relevés programmés (ex. hebdomadaire) à la demande de l'opérateur.
- OPE-009 · Postconditions : preuve par relecture de chaque opération : Relecture automatique programmée quelques secondes après l'envoi, visible dans Opérations.
- PAR-010 · Reprendre les sauvegardes locales : Reprise automatique avec backoff et bouton manuel conservé.
- PAR-031 · Simuler puis purger des données locales : Proposer en D2 une sauvegarde vérifiée automatique avant purge, comme pour la conservation.
- PAR-045 · Réglages de sécurité configurables : Verrouiller ces clés par stratégie d'entreprise pour qu'un opérateur ne puisse pas les assouplir.
- TRV-013 · Connexion « Continuer en tant que DOMAINE\nom » (session Windows d'abord) : Mémoriser le dernier choix (Windows ou autre compte) par poste et proposer une connexion automatique optionnelle avec la session Windows.
- TRV-237 · Mode lecture seule fermé par défaut : Bascule lecture/écriture avec expiration automatique (retour en lecture seule après N minutes d'inactivité).
- TRV-241 · Presse-papiers protégé : Compte à rebours visible de l'effacement du presse-papiers. Effacer automatiquement le presse-papiers après N secondes pour les secrets, comme les gestionnaires de mots de passe.
- TRV-265 · Schéma 11/1 en avance seule : En D2, migrations numérotées (une classe par étape) avec sauvegarde automatique vérifiée.

#### Exports, copies et partage (46)

- ACC-010 · Analyser la vue : tableaux croisés : Choix libre des deux dimensions et export CSV de la matrice. Export CSV de la matrice.
- RCH-003 · Favoris d'OU épinglés au-dessus de l'arborescence : Réordonner les favoris par glisser-déposer et les partager/exporter. Glisser-déposer pour ordonner les favoris.
- RCH-004 · Reprise unique des anciennes recherches enregistrées : Importer aussi les favoris de Domenia 1 au premier lancement de Domenia 2.
- RCH-054 · Choix des colonnes affichées : Permettre des jeux de colonnes nommés, partageables entre opérateurs.
- RCH-069 · Exporter la liste en CSV : Export XLSX/JSON en plus du CSV. Export XLSX natif.
- RCH-075 · Grille de résultats : Choix et ordre des colonnes par glisser-déposer, profils de colonnes partagés.
- RCH-123 · Export CSV avec colonnes d'association détaillées : Ajouter les exports XLSX et JSON et le choix du séparateur.
- RCH-125 · Copier la sélection pour un ticket : Proposer un format Markdown ou tableau pour les outils de ticket. Modèles de ticket configurables (GLPI, ServiceNow).
- RCH-131 · Diagnostic réseau groupé : Résultats par poste dans la grille plutôt qu'un rapport copié.
- RCH-132 · Enregistrer une vue personnelle : Partage de vues entre opérateurs (export/import).
- FIC-014 · Réinitialiser le mot de passe : Envoi du mot de passe temporaire par canal sécurisé (SMS/QR) plutôt que dictée.
- FIC-040 · Lire les verrouillages du compte (événements 4740) : Fenêtre de jours réglable, lecture des 4625/4771 du poste d'origine en option, et export du rapport.
- CPT-006 · Carte Annuaire en lecture seule : Ajouter l'heure de connexion, le site AD du contrôleur et un bouton « Copier l'identité ».
- CPT-019 · Droits, comptes et ports requis par opération : Page de référence consultable et exportable pour les équipes de délégation.
- PST-002 · Verdict du diagnostic du poste : Afficher le verdict en tête avec un lien « copier pour un collègue » qui inclut les codes bruts.
- PST-006 · Explorateur WMI en lecture seule : Requêtes WMI favorites partagées avec l'Atelier.
- PST-009 · Actions rapides de l'en-tête (RDP, C$, ping, utilisateur) : Afficher à côté du bouton C$ le compte qui sera utilisé, et permettre de copier le chemin UNC.
- PST-048 · Cinq vues du poste et anciennes routes : Faire des routes profondes des URL internes (poste/intervenir#services) partagées par la palette, les liens et l'historique.
- PST-057 · Révélation d'une seule valeur à la fois : Copie hors historique (ExcludeClipboardContentFromMonitorProcessing) et saisie directe dans la session RDP.
- PST-067 · Lire les services du poste : Afficher le compte de service, le PID et les dépendances, et proposer l'export CSV.
- PST-095 · Fiche identité du poste : Bouton copier par ligne (numéro de série, IP).
- ASS-008 · Dossier support et ticket : Ajouter des gabarits de ticket (GLPI, ServiceNow) et une option d'anonymisation.
- ASS-009 · Export HTML autonome du dossier support : Ajouter un export PDF et une empreinte SHA-256 du dossier.
- REQ-019 · Liste locale des postes du périmètre : Colonnes triables + export CSV + ouverture de fiche par double-clic.
- REQ-028 · Copier le chemin AD : Menu contextuel de copie (nom, GUID, DN) sur toute ligne.
- REQ-031 · Exporter tous les résultats en CSV : Choix du format (XLSX, JSON) et des colonnes.
- REQ-045 · Catalogue de modèles livrés : Modèles d'équipe partagés et notés.
- REQ-054 · Exporter la bibliothèque en pack versionné : Exporter une sélection ou une catégorie.
- AUD-001 · Copier la vue d'audit pour un ticket : Export Markdown/PDF signé de l'audit.
- SYN-025 · Comparer deux relevés : Export du rapport de comparaison.
- SYN-029 · Relevé partagé du parc entre consoles : Partage via un service Domenia central plutôt qu'un fichier UNC.
- OPE-022 · Liste des reçus d'opérations : Filtres par étape, opération et date, et export CSV des reçus.
- PAR-028 · Reprendre les anciennes données : Importateur Domenia 1 → Domenia 2 (base SQLite, favoris, préférences de comptes, reçus) avec rapport.
- PAR-036 · Sauvegarde automatique planifiée : En D2, proposer aussi une copie vers un dossier secondaire local ou un partage, sans cloud.
- PAR-050 · Préférences utilisateur persistées : Export/import des préférences et profils d'équipe.
- TRV-012 · Message de refus de connexion en clair : Afficher le code AD dans un volet repliable « Détail technique » avec bouton copier, et un lien direct vers la correction du mot de passe quand le cas est « expiré » ou « à changer ».
- TRV-073 · Copier le journal avec masquage des noms : Afficher un aperçu du texte masqué avant la copie.
- TRV-175 · Catalogue des commandes et règles de disponibilité : Catalogue extensible déclaratif (JSON) partagé avec l'aide et les raccourcis.
- TRV-178 · Raccourcis clavier : Raccourcis personnalisables et aide-mémoire imprimable. Raccourcis personnalisables et aide Shift+?.
- TRV-221 · Correction centralisée d'un compte sans reconnexion (anti-verrouillage) : Afficher dans Comptes la liste des copies qui bloquent la levée, avec un bouton par copie pour la corriger ou l'oublier.
- TRV-229 · Aperçu exact d'une opération collective : Permettre de décocher des cibles dans l'aperçu (recalcul du nombre à saisir) et exporter la liste en CSV.
- TRV-244 · Sélecteur de fichier intégré : Mémoriser les derniers dossiers d'export par type de document.
- TRV-274 · Plan de migration ADCC vers Domenia : En D2, importer la base Domenia 1 (schéma 11/1) avec le même principe : simulation, sauvegarde, idempotence.
- TRV-279 · Migration de l'ancienne bibliothèque JSON : Importer aussi la bibliothèque Domenia 1 au premier lancement de Domenia 2.
- TRV-294 · Copier le résumé du tableau : Choix du format (texte, Markdown, HTML) et des sections.
- TRV-312 · Exporter / importer une disposition JSON : Partage d'une disposition par lien dans la bibliothèque d'équipe.

#### Visualisation et lisibilité (52)

- ACC-020 · Libellé périmètre et fraîcheur AD : Badge coloré de fraîcheur (vert/orange/rouge) selon l'âge de la lecture AD.
- ACC-021 · Trois horloges de provenance des mesures : Panneau dépliable « Provenance » plutôt qu'une info-bulle, avec lien vers chaque collecte.
- ACC-032 · Recalculer la vue d'ensemble depuis la base locale : Afficher un horodatage « calcul en cours depuis » et une barre de progression du worker ; conserver l'historique des 5 derniers calculs pour comparer.
- ACC-041 · Évolution sur 90 jours : Annoter la courbe avec les collectes et changements de règles.
- ACC-052 · Santé du parc (score et points) : Afficher la tendance du score (flèche vs veille) directement dans la carte.
- RCH-022 · Barre de recherche : récents et suggestions locales : Afficher type et icône dans la suggestion et ouvrir directement la fiche par Ctrl+Entrée (lecture explicite).
- RCH-043 · Précédent / Suivant : Liste déroulante des étapes (historique visuel).
- RCH-048 · Application des changements détectés par la revérification : Surligner brièvement les lignes modifiées et lister les changements dans un panneau « Quoi de neuf ».
- RCH-064 · Repérage des comptes d'administration : Badge visuel dédié dans la grille.
- FIC-007 · Comparer les saisies d'une fiche (brouillon protégé) : Fusion champ par champ (garder ma saisie / prendre la nouvelle lecture) et surlignage des champs modifiés dans la fiche.
- FIC-026 · Groupes imbriqués à la demande : Vue graphe des imbrications.
- FIC-036 · Fraîcheur par nature de donnée : En D2, une pastille de fraîcheur uniforme sur chaque bloc de fiche.
- FIC-041 · Activité de connexion approximative expliquée (utilisateur) : Badge « inactif depuis N jours » cohérent avec les requêtes de comptes inactifs.
- CPT-002 · Utiliser un autre compte après un refus : Panneau intégré à la page au lieu d'une fenêtre.
- CPT-011 · Comptes gardés en mémoire et « Oublier » : « Tout oublier » en un geste et rappel visuel (pastille) quand des comptes temporaires sont en mémoire.
- CPT-021 · Validation asynchrone d'un compte (une à la fois) : Afficher une barre de progression avec étape et bouton Annuler, et le contrôleur ayant validé.
- PST-003 · Diagnostic par couche réseau : Représenter les 4 couches en frise avec l'étape bloquante surlignée.
- PST-017 · État de l'autorisation d'intervention dans le panneau d'exécution : Afficher un compte à rebours en direct dans le panneau.
- PST-054 · Retrouver une clé par son identifiant de récupération : Saisie tolérante (tirets, espaces) et rappel visuel du format XXXXXXXX-…
- PST-056 · Carte de la clé BitLocker (8 blocs, compte à rebours) : Mode « dictée » qui surligne un bloc à la fois avec lecture vocale optionnelle.
- PST-074 · Détails d'une sonde du poste : En faire un panneau latéral de la page Poste plutôt qu'une fenêtre.
- PST-077 · Volumes et prévision de saturation : Afficher la courbe d'historique et la droite de prévision.
- PST-080 · BIOS et référence approuvée par modèle : Vue « conformité BIOS par modèle » sur le parc.
- PST-106 · Certificats machine : Liste détaillée (sujet, émetteur, échéance) dépliable.
- PST-115 · Ligne d'association d'un poste : Ajouter une chronologie des associations (qui, quand, quelle source) dépliable.
- MAC-001 · Ordre de choix du compte des opérations poste : Schéma visuel de la cascade avec la ligne active surlignée.
- MAC-002 · Pastille « Compte poste : … ▾ » d'Assistance poste : Couleur/glyphe distinct si le compte est en pause après refus.
- MAC-003 · Panneau latéral Compte poste : Bouton « Valider ce compte sur ce poste » intégré au panneau (essai FO-19) avant de l'utiliser.
- REQ-008 · Arbre de conditions ET / OU / NON : Glisser-déposer des nœuds et édition visuelle en blocs.
- REQ-015 · Dates de chaque source : Frise temporelle graphique des sources.
- REQ-053 · Parcours en trois étapes : Créer, Aperçu, Enregistrer : Indicateur d'étape (frise) avec l'état de chaque étape : critères valides, aperçu à jour, requête enregistrée.
- REQ-066 · Analyse locale d'un SELECT WQL : Coloration syntaxique et complétion des propriétés.
- AUD-012 · Groupes imbriqués et cycles : Graphe visuel des imbrications.
- AUD-018 · Identité du poste (AD, DNS, poste) : Badge d'identité dans l'en-tête de la page Poste.
- AUD-020 · Historique enregistré des associations : Frise chronologique et filtre par source.
- SCH-006 · Analyse locale du coût d'un filtre LDAP : Coloration syntaxique et réécriture suggérée du filtre.
- OPE-003 · Pourquoi une action est indisponible ? : Afficher le bilan dans un panneau de la page plutôt qu'une boîte de dialogue, avec un bouton de route par ligne.
- OPE-005 · Santé du moteur : Graphiques de tendance. Ajouter des graphiques (sparklines) des latences par catégorie. En D2, une page de santé avec courbes glissantes sur la session.
- OPE-030 · Mesures de réactivité de l'interface : Graphique temporel des latences et seuil d'alerte.
- OPE-031 · Temps de réponse par catégorie : Ajouter un petit histogramme par catégorie en D2.
- PAR-004 · Densité des résultats : Appliquer la densité à toutes les grilles, pas seulement aux résultats.
- PAR-025 · Mesurer le stockage local : Graphique de répartition par catégorie en D2.
- PAR-040 · Fenêtre de collecte : Éditeur visuel hebdomadaire.
- TRV-031 · Chronométrage du démarrage (R40) : Afficher ces jalons dans le panneau Opérations > Santé de D2.
- TRV-043 · Moniteur de démarrage : Écran de chargement intégré à la page web avec étapes réelles.
- TRV-107 · Budgets par sous-réseau présumé : Vue « sites lents » dans Opérations.
- TRV-123 · Admission et file d'attente bornée : Afficher en D2 la jauge de charge (en cours, en attente, réservées) dans le panneau Opérations.
- TRV-226 · Changements d'un plan en mots clairs : Vue diff colorée avant/après avec icônes, accessible lecteur d'écran.
- TRV-238 · Objets protégés et DN illisible : Bandeau visible sur la fiche d'un objet protégé expliquant pourquoi les écritures sont limitées.
- TRV-284 · Accessibilité des tableaux : Tableau de données alternatif (table HTML) pour chaque graphique.
- TRV-291 · File d'attente des collectes de widgets : Panneau listant la file avec possibilité de retirer un élément.
- TRV-298 · Graphiques natifs des tableaux : Info-bulles de valeur au survol de chaque barre/point.

#### Sécurité et protection des comptes (12)

- ACC-035 · Dernière vue enregistrée au démarrage (cache d'abord) : Afficher aussi les tuiles en gris avec les derniers chiffres plutôt qu'un seul texte.
- PST-020 · Ouvrir Pesto ou FILPRO avec le contexte : Bouton contextuel sur la page Poste et la fiche utilisateur. Vérification de signature Authenticode en plus de l'empreinte, et assistant pour enregistrer l'empreinte d'une nouvelle version.
- ASS-001 · Captures historiques A/B : enregistrer et charger : Chiffrer optionnellement la capture avec une phrase de passe.
- ASS-012 · Dossier de diagnostic hors ligne : Archive ZIP chiffrée en option. Chiffrer le dossier en option (mot de passe ou certificat) pour le transport sur clé USB.
- ASS-015 · Lancer une étape de recette : Lancer les étapes non privilégiées en lot avec un budget global affiché et confirmé.
- AUD-010 · Cible de l'audit = objet de la fiche : Audit lançable directement depuis la fiche (onglet Sécurité).
- PAR-044 · Politique centrale des éléments d'interface : Fichier de politique signé ou GPO (ADMX) pour masquer des fonctions par profil.
- TRV-016 · Connexion explicite à tentative unique : Afficher l'état du compte (verrouillé, expiré) avant de proposer un nouvel essai.
- TRV-019 · Écran de connexion : thème, Verr. Maj, annulation : Windows Hello / WebAuthn pour déverrouiller le coffre.
- TRV-058 · Confirmation dans la page (demande avec suite) : Afficher un résumé d'impact chiffré (nombre d'objets) et garder l'historique des confirmations dans le reçu.
- TRV-070 · Journal de session lisible (Essentiel) ou brut (Expert) : Filtrer par zone (Poste, Recherche, Sécurité) et par opération.
- TRV-186 · Mode écriture confirmé et retour automatique en lecture seule : Permettre un mode écriture limité à une page ou à un objet, et exiger une saisie typée pour les comptes privilégiés. Élévation par écriture unique (just-in-time) plutôt qu'un mode global.

#### Historique, journal et traçabilité (29)

- ACC-064 · Versions de Windows et fin de service : Lien vers la liste exacte des postes à migrer, groupée par version.
- RCH-023 · Mémoire des recherches et fiches récentes : Proposer « effacer l'historique » et l'épinglage d'une recherche récente.
- RCH-035 · Recherche par adresse IP ou MAC dans les relevés locaux : Indiquer aussi l'historique des adresses d'un poste.
- REL-010 · Journal local des relations : Consultation du journal dans la page.
- PST-008 · Pastille de présence avec heure et état mémorisé : Ajouter l'âge relatif (« il y a 3 min ») mis à jour en direct, et l'historique des derniers tests au survol.
- PST-010 · Autoriser une intervention sur ce poste (5 min) : Durée réglable (1–15 min) et journal des autorisations accordées/retirées.
- PST-091 · Historique borné des volumes et des écrans : Étendre l'historique à la mémoire et aux batteries.
- ASS-005 · Comparer deux captures A et B : Comparer aussi les groupes imbriqués et un objet avec sa version de la base locale à une date choisie.
- ASS-006 · Incidents expliqués de la session : Relier chaque incident à l'opération (référence de trace) qui l'a produit et proposer « ouvrir l'opération ».
- REQ-017 · Collecter seulement les données manquantes : Estimer la durée d'après l'historique chronométré des relevés.
- REQ-034 · Enregistrer la requête (révision SQLite) : Historique des révisions consultable et restauration d'une révision précise.
- AUD-005 · Diagnostic des contrôleurs choisis : Seuils réglables et historique des diagnostics.
- OPE-008 · Export du diagnostic ZIP : Option d'anonymisation des noms dans l'archive.
- OPE-010 · Compensation limitée et honnête : Historique des opérations compensables avec bouton « Préparer l'annulation » depuis chaque reçu vérifié.
- OPE-012 · Dernières opérations et leurs étapes : Historique persistant filtrable entre sessions. En D2, filtres par état et par type, et recherche par référence.
- OPE-015 · Panneau des opérations en cours : Ajouter un historique filtrable et persistant (opérations des 7 derniers jours) avec leurs reçus.
- OPE-026 · Opérations à vérifier (reçus d'écriture) : Afficher au survol l'objet et l'opération du reçu le plus ancien.
- TRV-014 · Mode diagnostic de la connexion : Horodater chaque étape (DNS, LDAP bind, RootDSE, lecture du compte) avec sa durée pour repérer l'étape lente.
- TRV-048 · Worker de démonstration : Rejouer des scénarios enregistrés (traces anonymisées) pour la démonstration et les tests.
- TRV-081 · Journal technique Domenia.log : Journal structuré JSON consultable et filtrable.
- TRV-084 · Identité unique de livraison : En D2, injecter la version au build (AssemblyInformationalVersion) et l'afficher dans À propos.
- TRV-098 · Classification de l'effet d'une opération : Renommer l'opération « RimotteRun » (orthographe héritée) en RemoteRun avec alias de compatibilité pour les anciens reçus.
- TRV-177 · Palette de commandes (Ctrl+K) : Ajouter des commandes paramétrées (« ouvrir poste PC-… ») et la recherche d'objets dans la palette. Historique des commandes récentes en tête et recherche d'objets AD (nom, poste) directement depuis la palette.
- TRV-248 · Réglages d'expérience bornés et clés étendues : Versionner le schéma des préférences et migrer explicitement dans D2.
- TRV-249 · Plan durable de campagne : Stocker le plan dans la base locale avec reçu plutôt qu'en fichier de préférence.
- TRV-259 · Catalogue des formats versionnés : En D2, schémas JSON versionnés et testés, avec migrations déclarées.
- TRV-283 · Compaction et archivage des reçus : Consultation et recherche dans l'archive des reçus depuis la page Opérations.
- TRV-301 · Table des fins de service livrée : Afficher la version et la date de la table dans Paramètres avec alerte si elle a plus d'un an. Afficher la date de revue de la table dans l'explication des widgets.
- TRV-313 · Persistance et migration des dispositions : Versionner le schéma de disposition et garder les 5 dernières versions restaurables.

#### Ergonomie, navigation et panneaux dans la page (36)

- ACC-011 · Choisir l'OU du tableau de bord (périmètre propre) : Permettre plusieurs périmètres favoris nommés commutables en un clic.
- ACC-024 · Éditeur des règles de santé : En faire une page Paramètres > Santé plutôt qu'une fenêtre.
- ACC-031 · Ouvrir les postes de l'OU dans Rechercher : Proposer aussi « Ouvrir dans un nouvel onglet de résultats » pour ne pas écraser la liste courante.
- ACC-050 · Révision évaluée affichée sur le widget : Bouton « Confirmer la nouvelle révision » directement sur le widget.
- ACC-054 · Déplier les postes d'un point d'attention : Actions groupées directes (pinger, ouvrir dans Rechercher) depuis la liste dépliée.
- RCH-027 · Syntaxe explicite optionnelle par préfixes : Proposer l'autocomplétion des préfixes dans la barre.
- RCH-047 · Revérification du périmètre consulté en arrière-plan : Indicateur « relu il y a N s » sur la liste et bouton « Revérifier maintenant ».
- RCH-049 · Annuler la présentation de la liste de résultats : Rétablir (Ctrl+Y) et vues nommées enregistrables.
- RCH-133 · Ouvrir une vue personnelle : Option « ouvrir et actualiser ».
- FIC-019 · Ajouter ou retirer d'un groupe : Sélecteur de groupe avec autocomplétion locale.
- CPT-010 · « En ce moment » : compte utilisé par chaque ressource : Ajouter par ligne un bouton d'action direct (« Corriger », « Essayer ») vers l'endroit unique où l'état se règle.
- CPT-014 · Compte Secrets (LAPS et BitLocker) : Bouton « Tester sur le poste ouvert » qui lit seulement la présence d'un attribut LAPS/BitLocker sans révéler de valeur.
- REL-012 · Conflits d'associations entre consoles : Ajouter en D2 un vrai bouton « Recharger les associations » et un écran de résolution du conflit (garder la mienne ou la leur).
- PST-007 · En-tête fixe du poste : Afficher aussi l'heure de la dernière lecture AD de la fiche et un lien vers l'inventaire.
- PST-015 · Actualisation des stratégies (GPUpdate) confirmée dans la page : Afficher ensuite le résultat RSoP (GpoAppliedRead) en un clic.
- PST-022 · Outils Windows ouverts sur le poste : Lien RDP avec compte pré-sélectionné et fichier .rdp généré.
- PST-071 · Lecture des sessions Windows (WTS) : Ajouter un filtre RDP/console et une colonne « adresse client » si WTS la fournit.
- PST-094 · Points d'attention du poste avec lien vers l'action utile : Bouton d'action direct (Redémarrer, Nettoyer C:) avec confirmation depuis le point.
- PST-099 · Activité : services, processus, journal Système : Lien direct vers le détail de l'événement et vers l'arrêt/démarrage du service.
- PST-107 · Tuiles de comptage de l'inventaire : Ouvrir la liste complète de la catégorie au clic.
- REQ-001 · Recherche d'une information à filtrer : Recherche floue et suggestions récentes.
- REQ-050 · Ouvrir l'atelier de requêtes avec retour à l'origine : Route profonde (URL interne) vers un onglet de l'atelier et une recette précise.
- AUD-009 · Analyse des identités d'une OU : Ouvrir directement les objets d'un constat.
- PAR-009 · Zoom de l'interface : Ajouter les raccourcis Ctrl+molette, Ctrl+plus et Ctrl+moins.
- PAR-029 · Politique des données locales : Ajouter en D2 des boutons « Ouvrir le dossier » par ligne.
- TRV-004 · Catalogue d'aide des contrôles : Rendre le catalogue traduisible et cherchable dans l'aide (index plein texte), avec des liens vers le guide.
- TRV-027 · Blocage d'une mise à jour interrompue : En D2, proposer la restauration par un bouton dans la fenêtre d'erreur, avec confirmation.
- TRV-095 · Panneaux redimensionnables : Séparateurs utilisables au clavier (flèches) et double-clic pour revenir à la taille par défaut.
- TRV-097 · Estimation d'impact avant une opération : Comparer après exécution l'estimé et le réel dans la page Opérations.
- TRV-166 · Bouton de route « Assistance poste > Intervenir » dans les messages : Généraliser : toute consigne d'interface citant une page reçoit son bouton de route.
- TRV-179 · Raccourcis clavier des tableaux : Afficher l'aide des raccourcis dans la palette de commandes.
- TRV-215 · Résultat d'écriture, postcondition et compensation : Bouton « Préparer l'annulation » ouvrant le plan inverse pré-rempli.
- TRV-223 · Garde d'authentification partagée des workers : Afficher en temps réel dans Opérations les comptes en pause et le nombre d'essais évités. En D2, notifier le refus dans une bannière persistante avec bouton « Corriger le compte ». Afficher le compte en pause et le lien de correction dans un centre de notifications.
- TRV-239 · Cible d'écriture saisie à la main (DN) : Sélecteur d'objet avec recherche plutôt que saisie de DN.
- TRV-307 · Ajouter ou modifier un widget : Glisser un élément du catalogue directement dans la grille.
- TRV-309 · Annuler les changements de disposition : Ajouter Rétablir (Ctrl+Y).

#### Recherche, filtres, colonnes et tri (16)

- ACC-060 · Catalogue des sondes WMI : Recherche plein texte dans le catalogue depuis l'éditeur de widget.
- RCH-009 · Filtre local de l'arbre des OU : Option de recherche d'OU par nom dans l'annuaire (lecture explicite).
- RCH-024 · Recherche globale de la barre du haut : Afficher le filtre LDAP effectivement envoyé dans un détail repliable. Recherche fédérée locale+AD avec classement unique.
- RCH-036 · Date du relevé sur les postes trouvés par adresse : Colonne dédiée « Relevé le » plutôt que la Description.
- RCH-050 · Filtre local de la liste de résultats : Ajouter des filtres par colonne et des opérateurs (champ:valeur).
- RCH-059 · Charger la suite / jusqu'à 1 000, 5 000, 20 000 : Pagination infinie virtualisée.
- FIC-042 · Lire la connexion exacte sur chaque contrôleur (utilisateur) : Afficher logonCount (lu mais jamais montré en D1) et présenter le résultat en tableau triable par contrôleur.
- PST-042 · Filtrer la liste des logiciels par clic sur un graphique : Étendre le filtre par clic aux tableaux parc (part → liste des postes).
- REQ-010 · Paramètres réutilisables de requête : Invite de paramètres au lancement depuis Recherche ou un widget.
- REQ-020 · Aperçu local de la requête : Résultats virtualisés défilants plutôt que pages de 200.
- REQ-022 · Colonnes, tri et pagination des résultats : Colonnes choisies par l'opérateur (une par information interrogée).
- SCH-005 · Ajouter l'attribut choisi au filtre : Envoyer le filtre vers l'atelier de requêtes.
- SYN-001 · Recherche dans l'index local : Fusionner en D2 cette recherche locale avec la page Rechercher (source « base locale »).
- OPE-028 · Derniers relevés par OU : Filtre par OU et par type.
- TRV-062 · Disposition des colonnes mémorisée : En D2, ajouter « Réinitialiser les colonnes » et le choix des colonnes visibles par grille.
- TRV-137 · Tampon de pages borné (règle présente) : En D2, virtualiser les grilles côté WebView avec pagination serveur explicite.

#### Transparence des données : dates, sources, état (21)

- ACC-040 · Instantané quotidien local du parc : Permettre un instantané manuel daté (avant/après campagne) en plus du quotidien.
- FIC-001 · Écriture brute d'un attribut : Afficher la liste de blocage active et la syntaxe/monovaluation de l'attribut (schéma) avant saisie. Éditeur d'attributs typé selon le schéma.
- FIC-003 · Estimation des droits effectifs : Afficher l'ACE précise qui accorde ou refuse chaque capacité.
- FIC-030 · Aperçu local d'une fiche : Afficher clairement « valeurs du JJ/MM HH:mm, relecture en cours » dans l'en-tête de la fiche.
- CPT-016 · Mémoriser l'identifiant (nom seulement) dans la base locale : Afficher la date de dernière utilisation de chaque identifiant mémorisé et permettre de l'oublier depuis la page.
- PST-012 · Carte du compte AD du poste (activer ou désactiver) : Afficher aussi la date du dernier changement de mot de passe machine (pwdLastSet) pour juger d'un compte orphelin.
- PST-045 · Sources et couverture de l'inventaire logiciel : Afficher la phrase « Non couvert : … » sous la grille.
- PST-114 · Activité de connexion du compte ordinateur (approx. et par contrôleur) : Rapprocher avec la dernière présence réseau mesurée du poste.
- ASS-014 · Grille des étapes de recette : Afficher le résultat résumé de chaque lecture directement dans la ligne.
- REQ-051 · Périmètre de l'atelier = OU du tableau de bord : Afficher la date de la base de l'OU à côté du périmètre.
- SCH-007 · Lecture du schéma AD sur geste explicite : Cache disque du schéma par domaine avec date.
- PAR-030 · Catalogue du cache par périmètre (règle non raccordée) : L'afficher dans Paramètres > Données locales pour savoir ce que la base garde, depuis quand et à quoi cela peut servir.
- PAR-042 · Configuration livrée et réglages avancés : En D2, un écran admin en lecture qui montre la valeur effective et sa provenance (défaut ou config). Écran Paramètres avancés affichant la valeur effective et sa source (défaut, fichier, GPO).
- TRV-138 · Faits explicables : En D2, un composant UI « fait » uniforme avec infobulle source et limite.
- TRV-155 · Âge et validité des observations : Exposer la durée de conservation dans Paramètres avec explication.
- TRV-183 · Blocage des écritures distantes : Afficher au même endroit toutes les raisons actives du blocage.
- TRV-219 · Affichage temporaire d'un mot de passe saisi (œil, 5 s) : Appuyer-maintenir pour afficher (relâcher masque) en plus du clic, et indicateur Verr. Maj.
- TRV-236 · Verrous par cible et classe d'action : Afficher dans Opérations la file des mutations en attente d'un verrou, avec la raison.
- TRV-242 · Sélecteur d'OU arborescent partagé : Mettre l'arbre en cache dans la base locale et l'afficher immédiatement, avec relecture à la demande.
- TRV-252 · Stockage durable des lectures détaillées : Afficher le nombre de lignes expurgées dans l'interface.
- TRV-258 · Emplacements de données par catégorie et mode de stockage : Afficher l'état de chaque catégorie (Prêt, Non inscriptible, Distant refusé) dans Paramètres > Données locales.

#### Comparaisons, références et conformité (6)

- FIC-004 · Comparaison simple de deux utilisateurs (règle non raccordée) : Fusionner avec Droits comparés en ajoutant les attributs d'organisation.
- PST-037 · Inventaire rapide ou complet du poste : Inventaire différentiel (ce qui a changé depuis le dernier).
- PST-040 · Synthèse des logiciels du poste : Comparer la liste à une référence (logiciels attendus/interdits).
- PST-047 · Vues et filtres des logiciels : Comparaison des logiciels entre deux postes.
- AUD-021 · Lecture des délégations (ACE) : Comparer les ACL de deux objets ou à une référence.
- AUD-023 · Vue du domaine : Score de santé et comparaison avec la vue précédente.

#### Réglages et seuils configurables (7)

- ACC-046 · Inventaire léger des postes (modèles, versions, mémoire, disque, redémarrage) : Seuils de tranches de mémoire réglables.
- RCH-104 · Requête : comptes expirant sous 30 jours : Seuil de jours réglable.
- RCH-108 · Requête : comptes actifs sans connexion depuis 90 jours : Seuil réglable.
- PAR-005 · Profil Essentiel ou Expert : Permettre à l'administrateur de définir des profils personnalisés par vue.
- PAR-041 · Parallélisme, réutilisation et plafond des relevés : Rendre Park.MaxTargets réglable dans l'interface.
- TRV-191 · Sondes personnalisées déclaratives : Éditeur de sonde personnalisée guidé en D2.
- TRV-195 · Reconnaissance des groupes à privilèges : Liste configurable de groupes sensibles locaux.

#### Nouvelles capacités proposées (31)

- ACC-015 · Premiers pas de l'accueil : Rendre la carte rappelable depuis l'aide et ajouter une étape « compte des postes ». Ajouter une étape facultative « vérifier les droits » (autodiagnostic) et une check-list d'installation.
- ACC-033 · Recalcul automatique quand les données changent : Événement de bus « données modifiées » typé par famille (AD, ping, WMI) pour ne recalculer que les widgets concernés.
- ACC-053 · Points d'attention du parc : Permettre d'acquitter/masquer temporairement un point avec motif (suspension rapide).
- RCH-002 · Comparer deux à huit postes : Étendre aux utilisateurs.
- FIC-005 · Droits comparés de deux utilisateurs : Proposer « ajouter les groupes manquants » en plan d'écriture confirmé.
- FIC-008 · Supprimer l'objet : Proposer la corbeille AD et la restauration quand elle est active.
- FIC-018 · Déplacer un objet vers une OU : Déplacement en lot avec aperçu.
- CPT-007 · Changer de compte sans fermer Domenia : Proposer les derniers comptes utilisés (noms seulement) dans une liste. Sessions multiples côte à côte (deux domaines).
- CPT-015 · Essayer le compte poste sur le poste sélectionné : Tester aussi l'accès C$ et WinRM en option, chacun avec son verdict séparé.
- REL-009 · Restaurer la dernière suppression : Liste de toutes les suppressions restaurables.
- REL-021 · Sonde des consoles bornée avec compteurs : Lire aussi les sessions RDP (option annoncée non disponible).
- REL-035 · Import d'associations avec aperçu : Connecteurs directs GLPI/Intune/SCCM en lecture.
- PST-005 · Diagnostic du poste : Diagnostic guidé avec remédiation proposée par contrôle.
- PST-018 · Copier la commande PowerShell à distance : Proposer aussi les variantes Invoke-Command et mstsc /v.
- PST-023 · Replis distants PsExec puis tâche planifiée : Abandonner PsExec au profit d'un agent ou de WinRM HTTPS.
- PST-024 · Compte ordinateur dans AD : Renommage coordonné AD + poste (Rename-Computer) avec confirmation.
- PST-033 · Analyse de dsregcmd /status : Zone de collage dans Assistance avec choix « collecté par l'utilisateur / par un admin ».
- PST-069 · Démarrer ou redémarrer un service : Ajouter Arrêter (avec confirmation renforcée) et l'affichage des services dépendants avant un redémarrage.
- PST-092 · Tableau de bord du poste depuis l'inventaire : Historiser les inventaires du poste et proposer un diff avec le précédent.
- ASS-007 · Repères de session (fiches épinglées) : Retrouver par GUID un objet déplacé depuis l'épinglage.
- ASS-013 · Recettes d'assistance guidées : Rendre les recettes déclaratives (JSON signé) et ajouter des recettes (imprimante, lecteur réseau, VPN).
- REQ-005 · Ajouter ou retirer un critère simple : Édition en place d'une condition existante.
- REQ-059 · Référence des cmdlets AD et LAPS (onglet masqué) : Générer la commande PowerShell équivalente à chaque action Domenia (transparence et script).
- SYN-007 · Vérifier les disparitions : Proposer la restauration depuis la corbeille AD (écriture confirmée).
- SYN-015 · Mise à jour incrémentielle du domaine : Synchronisation DirSync/ChangeNotify côté serveur Domenia.
- OPE-011 · Plans de cycle de vie d'un compte (règle non raccordée) : Assistant guidé avec modèles par service.
- OPE-024 · Consigner une revue manuelle d'un reçu : Modèles de motifs fréquents (« Vérifié dans ADUC sur DC01 », etc.).
- PAR-002 · Inventaire des composants livrés : Exposer cet inventaire dans À propos de D2 (règle aujourd'hui utilisée par l'outillage seulement).
- TRV-020 · Mode démonstration : Ajouter un jeu de démonstration plus riche (centaines de postes, incidents scénarisés) pour la formation. Jeu de données de démonstration chargeable pour formation.
- TRV-051 · Badge de session AD : Ajouter un clic vers les détails de la connexion (DC, site, latence, Kerberos).
- TRV-172 · Bannières d'information et d'erreur dans la page : Ajouter un centre de notifications qui garde les bannières fermées de la session.

#### Autres améliorations (12)

- RCH-085 · Présence de liste héritée non appelée : Ne pas réimplémenter ; garder la vérification explicite.
- REL-022 · Indices Kerberos du contrôleur (7 jours) : Résolution DNS inverse explicite des IP indices.
- PST-030 · Détection inventaire rapide ou complet : Faire porter le mode dans le résultat plutôt que de le déduire.
- PST-032 · Bruit des erreurs système du tableau du poste : Rendre la table éditable dans Paramètres avec retour aux valeurs livrées.
- TRV-041 · Préflight et compatibilité XAML : Équivalent Domenia 2 : test de chargement du bundle web et vérification des identifiants d'éléments au build.
- TRV-044 · Étapes différées après l'affichage d'Accueil : Chargement paresseux par page dans Domenia 2.
- TRV-066 · Navigation entre espaces et onglets : URL par page (routage) dans Domenia 2.
- TRV-089 · Intégrité et confiance de l'éditeur séparées : Signer les binaires D2 et vérifier l'empreinte épinglée au démarrage.
- TRV-096 · Classification structurée des erreurs : Catalogue d'erreurs documenté avec une fiche d'aide par catégorie.
- TRV-184 · Contrat de validation des recettes : Faire passer le même contrat dans les tests unitaires de D2.
- TRV-261 · Écrivain unique et file d'enregistrement : En D2, un service d'écriture unique (Channel) avec persistance de la file en cas de fermeture.
- TRV-310 · Dispositions prêtes Support, Inventaire, Santé : Dispositions prêtes définies par l'équipe.

## Contrôle de complétude

| Référence | Couverts | Total | Taux |
|---|---:|---:|---:|
| Contrôles WPF de `PARITE.json` | 1 157 | 1 164 | 99,4 % |
| … dont contrôles porteurs d'une action (boutons, cases, listes, champs, grilles, onglets, séparateurs) | 853 | 854 | 99,9 % |
| Opérations de `Get-DomeniaOperationTable` | 111 | 111 | 100,0 % |
| Sujets de `Domenia-UX.help.json` | 820 | 820 | 100,0 % |
| Fiches des lecteurs reprises (fusionnées ou réparties) | 1 181 | 1 181 | 100,0 % |

Un contrôle ou un sujet est couvert quand son nom figure dans les références D1 d'au moins une fonction ; une opération l'est quand elle figure dans les opérations d'au moins une fonction.

### Ce qui reste non couvert

| Élément | Type | Où | Raison |
|---|---|---|---|
| `UxComboToggle` | ToggleButton | Fenêtre principale | Élément de gabarit visuel (modèle de liste déroulante, d'onglet ou de barre de défilement) sans action propre : il n'est pas une fonction. |
| `PART_Popup` | Popup | Fenêtre principale | Élément de gabarit visuel (modèle de liste déroulante, d'onglet ou de barre de défilement) sans action propre : il n'est pas une fonction. |
| `PART_SelectedContentHost` | ContentPresenter | Fenêtre principale | Élément de gabarit visuel (modèle de liste déroulante, d'onglet ou de barre de défilement) sans action propre : il n'est pas une fonction. |
| `TabHeader` | ContentPresenter | Fenêtre principale | Élément de gabarit visuel (modèle de liste déroulante, d'onglet ou de barre de défilement) sans action propre : il n'est pas une fonction. |
| `PART_Track` | Track | Fenêtre principale | Élément de gabarit visuel (modèle de liste déroulante, d'onglet ou de barre de défilement) sans action propre : il n'est pas une fonction. |
| `PART_Track` | Track | Fenêtre principale | Élément de gabarit visuel (modèle de liste déroulante, d'onglet ou de barre de défilement) sans action propre : il n'est pas une fonction. |
| `PART_SelectedContentHost` | ContentPresenter | Fenêtre principale | Élément de gabarit visuel (modèle de liste déroulante, d'onglet ou de barre de défilement) sans action propre : il n'est pas une fonction. |

### Correspondance des opérations

| Opération | Effet | Fonctions |
|---|---|---|
| `AccountAliasRead` | Read | TRV-121, TRV-222 |
| `AdConsistencyScan` | Read | AUD-009, TRV-121, TRV-126 |
| `AdHealthRead` | Read | AUD-004, AUD-005, AUD-006, TRV-121, TRV-126 |
| `AdSchemaRead` | Read | SCH-007, TRV-121, TRV-126 |
| `BatchNetworkDiag` | Read | RCH-131, CPT-019, TRV-121, TRV-177, TRV-229 |
| `BitLockerPresence` | Read | ACC-057, CPT-019, PST-066, TRV-121, TRV-289 |
| `CmdletHelp` | Read | REQ-059, TRV-121 |
| `CmdletInventory` | Read | REQ-059, TRV-121 |
| `ComputerAdminShare` | Read | CPT-019, PST-022, TRV-121 |
| `ComputerDiagnostics` | Read | PST-002, PST-003, PST-005, PST-023, ASS-015, TRV-100, TRV-121 |
| `ComputerGpUpdate` | RemoteMutation | CPT-019, PST-015, OPE-009, TRV-121, TRV-216 |
| `ComputerInventory` | Read | REL-029, PST-023, PST-025, PST-026, PST-027, PST-028, PST-030, PST-032, PST-035, PST-037, PST-070, PST-092, PST-103, PST-104, PST-106, ASS-015, TRV-100, TRV-121, TRV-289 |
| `ComputerLastUser` | Read | PST-023, PST-117, TRV-121, TRV-200 |
| `ComputerPing` | Read | PST-009, PST-050, REQ-017, TRV-100, TRV-121 |
| `ComputerRestart` | RemoteMutation | CPT-019, PST-013, OPE-009, TRV-121, TRV-216 |
| `ComputerServiceControl` | RemoteMutation | CPT-019, PST-069, OPE-009, TRV-121 |
| `DcServicesRead` | Read | AUD-007, TRV-121, TRV-126 |
| `DnsReverseLookup` | Read | RCH-035, RCH-037, TRV-121, TRV-208 |
| `DelegationRead` | Read | AUD-015, AUD-021, TRV-121, TRV-126 |
| `DemoDirectory` | Read | TRV-020, TRV-046, TRV-047, TRV-048, TRV-121 |
| `DirectoryAbsenceCheck` | Read | SYN-007, SYN-021, SYN-027, TRV-121, TRV-126 |
| `DocumentStore` | LocalWrite | ASS-001, ASS-009, OPE-004, TRV-048, TRV-121, TRV-247, TRV-312 |
| `DomainOverview` | Read | AUD-023, TRV-121 |
| `EmbeddedDirectoryLookup` | Read | FIC-011, REL-001, REL-002, TRV-121, TRV-126, TRV-242, TRV-243, TRV-246 |
| `EmbeddedPathBrowse` | Read | TRV-048, TRV-121, TRV-244 |
| `EngineSelfTest` | Read | TRV-046, TRV-048, TRV-121 |
| `GlobalSearch` | Read | RCH-003, RCH-010, RCH-012, RCH-016, RCH-017, RCH-018, RCH-019, RCH-024, RCH-027, RCH-028, RCH-030, RCH-034, RCH-037, RCH-038, RCH-039, RCH-041, RCH-046, RCH-055, RCH-057, RCH-059, RCH-068, RCH-104, RCH-105, RCH-106, RCH-107, RCH-108, RCH-109, RCH-110, RCH-111, RCH-112, RCH-113, RCH-114, RCH-115, RCH-116, RCH-121, FIC-028, TRV-121, TRV-129, TRV-136 |
| `GpoAppliedRead` | Read | ASS-015, AUD-017, TRV-121, TRV-126 |
| `GpoLinksRead` | Read | ASS-015, AUD-016, TRV-121, TRV-126 |
| `GroupPathRead` | Read | FIC-005, FIC-021, FIC-026, FIC-027, FIC-028, ASS-015, AUD-012, AUD-013, TRV-118, TRV-121, TRV-126 |
| `IndexBuild` | LocalWrite | ACC-001, ACC-003, ACC-006, SYN-013, SYN-014, SYN-015, SYN-016, SYN-018, SYN-020, TRV-097, TRV-121, TRV-136, TRV-271, TRV-272, TRV-289 |
| `IndexOuList` | Read | SYN-015, TRV-121 |
| `IsolatedRead` | Unknown | PAR-043, TRV-100, TRV-104, TRV-121 |
| `LegacyMigration` | LocalWrite | PAR-028, TRV-121, TRV-208, TRV-264, TRV-265, TRV-266, TRV-274, TRV-275 |
| `LiveCache` | LocalWrite | TRV-048, TRV-121, TRV-157, TRV-271 |
| `LiveConsole` | Read | ACC-001, ACC-004, ACC-005, RCH-078, RCH-079, RCH-082, RCH-086, RCH-087, RCH-088, RCH-089, RCH-093, RCH-097, CPT-015, PST-051, PST-052, PST-076, PST-077, PST-078, PST-079, PST-081, PST-082, PST-083, PST-084, PST-085, PST-086, PST-087, PST-088, PST-089, PST-090, PST-110, OPE-029, TRV-103, TRV-104, TRV-105, TRV-106, TRV-107, TRV-108, TRV-109, TRV-121, TRV-158, TRV-159, TRV-189, TRV-250, TRV-289, TRV-290 |
| `LiveDirectoryCheck` | Read | RCH-073, TRV-121 |
| `LiveSelectedPing` | Read | RCH-076, RCH-078, RCH-079, PST-050, PST-051, OPE-017, TRV-103, TRV-105, TRV-121, TRV-158, TRV-189 |
| `LocalIndexRead` | Read | ACC-001, ACC-006, ACC-014, ACC-016, ACC-022, ACC-023, ACC-032, ACC-033, ACC-034, ACC-037, ACC-038, RCH-001, RCH-002, RCH-022, RCH-035, RCH-046, RCH-055, RCH-083, RCH-086, RCH-091, RCH-102, RCH-122, FIC-005, FIC-024, FIC-038, CPT-007, CPT-016, REL-013, REL-031, REL-036, PST-029, PST-065, PST-074, PST-109, REQ-020, REQ-049, REQ-061, REQ-062, REQ-063, REQ-064, AUD-009, AUD-022, SYN-001, SYN-002, SYN-003, SYN-004, SYN-006, SYN-010, SYN-011, SYN-012, SYN-023, SYN-025, SYN-027, SYN-028, SYN-030, OPE-002, OPE-028, OPE-032, TRV-048, TRV-121, TRV-134, TRV-208, TRV-263, TRV-266, TRV-267, TRV-269, TRV-273, TRV-277, TRV-278, TRV-289 |
| `LocalQuery` | Read | ACC-029, ACC-039, ACC-049, ACC-051, ACC-062, RCH-035, RCH-046, RCH-102, RCH-122, REQ-009, REQ-014, REQ-015, REQ-017, REQ-020, REQ-021, REQ-022, REQ-029, REQ-030, REQ-049, TRV-121, TRV-134, TRV-147, TRV-148, TRV-152, TRV-266 |
| `LocalStore` | LocalWrite | ACC-022, ACC-040, ACC-057, RCH-007, RCH-055, RCH-073, RCH-092, FIC-030, FIC-035, CPT-016, REL-012, REL-014, REL-016, REL-017, REL-018, REL-034, REL-035, PST-050, PST-066, PST-071, PST-091, REQ-034, REQ-037, REQ-038, REQ-039, REQ-044, REQ-057, REQ-058, REQ-067, REQ-068, SYN-007, SYN-009, SYN-010, SYN-013, SYN-021, SYN-022, SYN-024, SYN-027, OPE-002, OPE-032, PAR-010, PAR-011, PAR-028, TRV-048, TRV-121, TRV-133, TRV-194, TRV-208, TRV-251, TRV-252, TRV-255, TRV-256, TRV-257, TRV-260, TRV-261, TRV-262, TRV-263, TRV-264, TRV-265, TRV-266, TRV-268, TRV-271, TRV-272, TRV-277, TRV-279, TRV-280 |
| `LockoutDiagnosis` | Read | FIC-040, FIC-045, FIC-048, CPT-019, ASS-015, TRV-121, TRV-126, TRV-223 |
| `LogonByDcRead` | Read | FIC-042, FIC-047, PST-114, TRV-121, TRV-126 |
| `LogonHarvest` | Read | CPT-019, REL-030, TRV-097, TRV-121 |
| `MachineIdentityRead` | Read | ASS-015, AUD-018, TRV-121, TRV-126 |
| `OfflineDossier` | LocalWrite | ASS-012, TRV-068, TRV-121 |
| `OpenAdObject` | Read | RCH-129, FIC-029, FIC-033, FIC-034, FIC-035, FIC-038, FIC-039, FIC-044, FIC-047, REL-026, REL-051, PST-116, ASS-007, REQ-026, SYN-005, TRV-121, TRV-126, TRV-160, TRV-215 |
| `OpenLinkedObject` | Read | REL-015, REL-051, PST-073, TRV-121 |
| `ParkPing` | Read | ACC-001, ACC-002, ACC-004, ACC-005, RCH-086, RCH-087, RCH-088, RCH-089, RCH-092, RCH-097, OPE-017, OPE-029, TRV-107, TRV-121, TRV-289 |
| `ParkSharedSync` | RemoteMutation | CPT-019, SYN-029, TRV-121, TRV-208 |
| `ParkSweep` | Read | ACC-001, ACC-002, RCH-091, REL-031, PST-110, REQ-017, REQ-027, REQ-039, TRV-097, TRV-121, TRV-229, TRV-289, TRV-290 |
| `PasswordPolicyRead` | Read | ASS-015, AUD-011, TRV-121, TRV-126 |
| `PermissionAnalysis` | Read | RCH-021, FIC-003, CPT-019, AUD-021, TRV-121 |
| `PresenceScan` | Read | RCH-085, TRV-121 |
| `PruneLinks` | Read | REL-043, REL-052, TRV-121, TRV-272 |
| `QueryExport` | LocalWrite | REQ-031, SYN-005, TRV-121 |
| `QueryLibrary` | Read | RCH-103, RCH-118, REQ-041, REQ-045, TRV-121 |
| `QueryTransfer` | LocalWrite | REQ-054, REQ-055, REQ-056, REQ-058, TRV-121 |
| `ReadBitLocker` | Read | CPT-019, PST-059, PST-062, PST-066, TRV-121, TRV-187, TRV-198 |
| `ReadBitLockerKey` | Read | CPT-019, PST-055, PST-056, PST-058, PST-064, TRV-121, TRV-187 |
| `ReadBitLockerList` | Read | PST-053, PST-060, TRV-121, TRV-187 |
| `ReadLaps` | Read | CPT-019, PST-059, PST-060, PST-062, PST-063, PST-066, TRV-121, TRV-187, TRV-198 |
| `ReceiptStore` | LocalWrite | CPT-019, OPE-022, OPE-023, OPE-024, OPE-025, OPE-026, TRV-099, TRV-121, TRV-281, TRV-282, TRV-283 |
| `RelationHistoryRead` | Read | AUD-020, OPE-032, TRV-121, TRV-126 |
| `RemoteCredentialCheck` | Read | CPT-002, CPT-015, CPT-018, CPT-019, TRV-121 |
| `RimotteRun` | RemoteMutation | CPT-019, PST-010, PST-016, OPE-009, TRV-121, TRV-200, TRV-216 |
| `ScopeReconcile` | Read | RCH-047, RCH-048, SYN-015, TRV-121 |
| `SelectedPresence` | Read | FIC-046, TRV-121, TRV-158 |
| `SelfCheck` | Read | OPE-007, TRV-121 |
| `SessionsList` | Read | CPT-019, PST-013, PST-014, PST-071, ASS-015, TRV-121, TRV-126 |
| `SoftwareInventory` | Read | PST-023, PST-040, PST-044, PST-045, PST-046, ASS-015, TRV-100, TRV-121, TRV-289 |
| `StartupWarmCache` | Read | TRV-121, TRV-209 |
| `StorageBackup` | LocalWrite | ACC-001, ACC-003, REL-037, REL-052, SYN-009, PAR-033, PAR-034, PAR-035, PAR-036, TRV-121, TRV-208, TRV-264, TRV-266, TRV-271, TRV-272 |
| `StorageIntegrity` | Read | PAR-026, TRV-121, TRV-208, TRV-265, TRV-266 |
| `StorageMaintenance` | LocalWrite | PAR-012, PAR-016, PAR-017, PAR-018, PAR-019, PAR-021, PAR-034, TRV-121, TRV-208, TRV-264, TRV-266, TRV-269 |
| `StoragePurge` | LocalWrite | REL-043, PAR-031, PAR-032, TRV-121, TRV-208, TRV-264, TRV-266, TRV-271 |
| `StorageUsage` | Read | PAR-011, PAR-025, TRV-121, TRV-208, TRV-266 |
| `TreeChildren` | Read | RCH-006, RCH-007, RCH-015, RCH-019, RCH-020, TRV-100, TRV-121, TRV-136 |
| `UserComputerProbe` | Read | CPT-019, REL-019, REL-021, REL-022, REL-023, REL-028, REL-029, TRV-097, TRV-121 |
| `WmiClasses` | Read | PST-006, TRV-100, TRV-121 |
| `WmiNamespaces` | Read | PST-006, TRV-100, TRV-121 |
| `WmiQuery` | Read | PST-006, PST-067, TRV-100, TRV-121 |
| `WriteAccountDisabled` | DirectoryWrite | FIC-013, CPT-019, PST-024, OPE-009, OPE-010, OPE-011, TRV-121, TRV-212, TRV-227 |
| `WriteAccountOptions` | DirectoryWrite | FIC-015, CPT-019, OPE-009, OPE-010, TRV-121, TRV-212 |
| `WriteAttributes` | DirectoryWrite | FIC-001, FIC-010, FIC-029, FIC-049, CPT-019, PST-021, OPE-009, OPE-010, OPE-011, TRV-121, TRV-212, TRV-214, TRV-227, TRV-234, TRV-235 |
| `WriteCreateOu` | DirectoryWrite | FIC-020, CPT-019, OPE-009, TRV-121 |
| `WriteDeleteObject` | DirectoryWrite | FIC-008, CPT-019, OPE-009, TRV-121, TRV-212, TRV-214 |
| `WriteExpiration` | DirectoryWrite | FIC-016, CPT-019, OPE-009, OPE-010, TRV-121, TRV-212 |
| `WriteExpirePassword` | DirectoryWrite | FIC-017, CPT-019, OPE-009, TRV-121, TRV-212 |
| `WriteGroupMember` | DirectoryWrite | FIC-022, FIC-029, CPT-019, OPE-009, OPE-010, TRV-121, TRV-212 |
| `WriteMoveObject` | DirectoryWrite | FIC-018, CPT-019, PST-024, OPE-009, OPE-010, OPE-011, TRV-121, TRV-212, TRV-227 |
| `WriteObjectGroup` | DirectoryWrite | FIC-019, FIC-022, CPT-019, PST-024, OPE-009, OPE-010, OPE-011, TRV-121, TRV-212 |
| `WriteRenameComputer` | DirectoryWrite | CPT-019, PST-024, OPE-009, TRV-121, TRV-212 |
| `WriteResetPassword` | DirectoryWrite | FIC-014, CPT-019, OPE-009, TRV-121, TRV-212 |
| `WriteUnlock` | DirectoryWrite | FIC-012, CPT-019, OPE-009, TRV-121, TRV-212 |
| `ComputerEventsRead` | Read | PST-031, TRV-121 |
| `ComputerQuickDiag` | Read | PST-004, TRV-121 |
| `ConnectorRead` | Read | CPT-019, PST-001, TRV-121 |
| `DcCompareRead` | Read | AUD-008, TRV-121 |
| `IndexRefresh` | LocalWrite | SYN-015, TRV-121, TRV-271 |
| `JoinStateRead` | Read | PST-033, TRV-121 |
| `LinkHistoryStore` | LocalWrite | REL-002, REL-008, REL-009, REL-010, REL-014, REL-024, REL-037, REL-038, REL-052, TRV-121, TRV-271 |
| `LocalAssistant` | Unknown | PAR-043, TRV-121 |
| `ObjectChanges` | Read | RCH-073, TRV-121 |
| `QuerySchema` | Read | REQ-061, REQ-062, REQ-063, REQ-064, REQ-067, REQ-068, TRV-121 |
| `WidgetWmiDetail` | Read | REQ-060, TRV-121, TRV-289 |
| `ReconcileScope` | Read | TRV-121 |
| `StartupWarmup` | Read | TRV-121 |
| `StorageRetention` | LocalWrite | REL-043, PAR-023, PAR-024, TRV-121, TRV-208, TRV-264, TRV-266 |
| `UpdateStateRead` | Read | PST-034, TRV-121 |
| `WakeOnLanSend` | RemoteMutation | CPT-019, PST-019, OPE-009, PAR-043, TRV-121 |

### Lectures partielles signalées par les lecteurs

Les lecteurs ont lu entièrement leurs fichiers, sauf les zones suivantes, parcourues par signatures, commentaires et refus : corps des gros workers du cœur (inventaire, recherche globale, sonde d'authentification, index), boucle du relevé de `Domenia-Park.UI.ps1`, corps réseau de `Domenia-Readings.Model.ps1`, calcul du score par OU, éditeur de widgets (`Show-DomeniaBoardEditor`), dimensions de `Domenia-Charts.UI.ps1`, gros fichiers de stockage, de livraison et du moteur (`Storage.Worker`, `Storage.UI`, `Release.Model`, `Engine.UI`, `Engine.Worker`, `Migration.Worker`), corps de `Domenia-Automate.ps1`, signatures natives de `Domenia-CredentialVault.Native.cs`, et le binaire `M4D.Admin.Common.Query.dll` (manifeste et empreinte seulement). Les fonctions de ces zones sont au catalogue ; des cas limites de validation peuvent y manquer et seront relus au moment de leur portage.

