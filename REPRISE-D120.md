# Reprise du lot D001-D120 de Domenia — prompt de passation

Complément du 19/10/2026, fin (RC1.17.25) : `Complete-DomeniaOpenObjectUi` accepte une clé de cache vide (relecture forcée sans GUID après une écriture, D025) ; un échec d’affichage d’une fiche relue libère la demande en cours et relance `Apply-CurrentPermissionUi` (boutons d’écriture restés grisés) ; bannière de succès après toute écriture vérifiée (`Complete-DomeniaWriteTaskUi`). Rien d’exécuté sous Windows PowerShell 5.1.

Complément du 19/10/2026, suite (RC1.17.24, décisions de David) : bouton Accueil « Tout actualiser » = mode `Both` (objets AD puis ping + WMI ; depuis l’Accueil seulement, un échec ou une lecture AD partielle n’arrête plus la collecte, qui part sur la base locale ; Rechercher garde l’ancien arrêt). Le relevé crée les associations depuis la console observée (`Register-DomeniaParkConsoleLink`, règle du clic, compte avec `UserDn`, poste déjà associé au même compte laissé tel quel), enregistrées par lots (`Request-DomeniaLinkPersistence`) pendant et à la fin du relevé. Vue d’ensemble recalculée toutes les 15 s pendant un relevé de liste (`Invoke-DomeniaParkLiveUpdates`), pied des widgets « Relevé en cours · partiel · N/M postes lus ». Horloge d’un relevé arrêté sans réussite : « relevé partiel le … ; les postes lus sont exploitables » (`Format-DomeniaCollectionClock`, test COL-005b). Nouveaux cas Windows à jouer : deux cas « Tout actualiser » dans `Test-DomeniaOuRefresh.ps1`. Rien d’exécuté sous Windows PowerShell 5.1.

Complément du 19/10/2026 (RC1.17.23, demande de David) : le plafond des collectes de widgets n’est plus `Park.MaxTargets`. Réglage « Plafond des widgets » (`Collection.WidgetMaxTargets`, **sans plafond par défaut**, sinon 500 à 5000) dans Outils > Relevés ; au-delà de 200 postes le nombre reste confirmé avant toute lecture. Les relevés de liste gardent `Park.MaxTargets`. Nouveaux essais WMI après incident transitoire réglables : `Collection.WmiRetries` (0 à 4, 2 par défaut) et `Collection.WmiRetryDelaySeconds` (10 s à 2 min, 30 s par défaut, puis ×4 jusqu’à 5 min). Contrôles hors Windows uniquement (pwsh 7 Linux : règles WidgetCollect 16/16 et Collection 46/46, compatibilité 5.1, audits Python, fabrication des packs) ; **aucune exécution Windows PowerShell 5.1 ni WPF de ce build**. Suites Windows à rejouer : `Test-DomeniaWiringRecherche.ps1`, `Test-DomeniaWidgetDetailRefresh.ps1`, `Test-DomeniaUxRefinements.ps1`, `Test-DomeniaQuery.ps1`.

Complément du 18/10/2026 : **périmètre personnel retenu par David, limites documentées**. Les contrôles d’identifiants (30), d’alignement (68), d’accès (63), de relations WPF (59), LAPS (5), de rétention 400 000 lignes et de volume NTFS plein (10 assertions) passent. RC21 : trois bancs corrigés et sélecteurs actualisés. RC22 : modèle des onglets corrigé, nouveaux packs autonomes, défilement natif 7/7 et démarrage du pack réussis. [Preuves détaillées](validation/2026-10-18/rc21-completion/README.md).

La grande échelle reste non qualifiée : premières vues sur 20 000 postes générés en 128 à 142 s, campagne d’endurance arrêtée. Multi-écrans/DPI, écoute Narrateur, relevé humain, variantes LAPS absentes et matrice cible restent des limites déclarées, pas des succès. Les anciens champs de recette générale ne doivent pas être confondus avec ce périmètre. RC1.17.22 corrige le contenu des pages absent de l’arbre UI Automation : 28/28 étapes natives, cinq captures et démarrage CheckOnly du pack réussis ; relevé humain distinct. Preuves committées et push vérifié avant suppression de DOMENIA-RC21-FINAL ; sept VM préexistantes conservées, dont le serveur AD toujours démarré. Aucune VM cliente nécessaire pour le périmètre personnel accepté.

## État précédent conservé

Clôture du 18/10/2026 : pack personnel RC1.17.21 conservé avec toutes les dépendances embarquées. VM `CNAMTS-W11-01` supprimée à la demande de David après sauvegarde et push des preuves ; serveur `CNAMTS-DC01` conservé et démarré. Les indications historiques de démarrage du client ci-dessous sont obsolètes. Voir [le reçu de clôture](validation/2026-10-18/rc21-closeout/README.md).

> **RC1.17.15 — 18 octobre** : [correctif de la suite santé](validation/2026-10-18/health-suspension-utc/README.md).
> Relecture des dates UTC corrigée, 45 cas santé réussis sous PowerShell 7.4.6 natif macOS.
> Contrôles de source et packs DEV/PROD actualisés ; aucun test VM. Qualification Windows toujours ouverte.
> Le lot RC1.17.14 ci-dessous a été livré et poussé dans `4a4fb412` ; ses mentions « reste » sont historiques.

> **RC1.17.14 — 17 octobre** : [cinq corrections restantes (points 4, 78, 9, 10, 127)](dev/engineering/d120/programme-2026-10-13/SUIVI-2026-10-17.md),
> bancs dédiés et rapports dans `validation/2026-10-17/rc14-corrections/` (pwsh7 Linux, non qualifiants). Revue indépendante
> session OpenCode distincte : cinq points acceptés, aucune correction de code retenue (`REVIEW-INDEPENDENT.md`). Reste :
> ré-épinglage des contrats worker (`--apply`), packs RC1.17.14, commit, bundle et `DELIVERY.json` ; qualification Windows 5.1
> toujours due pour tout le lot. Full Spark via OpenCode, aucun test VM (décision David du 17/10).

> **RC1.17.13 — 16 octobre** : [corrections restantes](validation/2026-10-16/rc13-corrections/README.md), builds DLL déterministes. Contrôles ciblés uniquement ; qualification générale non clôturée.

> **RC1.17.12 — 16 octobre** : [corrections finales](validation/2026-10-16/final-corrections/README.md). Assistant en haut, diagnostics de lenteur discrets, guides Word/PDF actualisés. Qualification générale toujours distincte des contrôles ciblés.

> **RC1.17.11 — 16 octobre** : voir [dashboard et lots](validation/2026-10-16/dashboard-batch/README.md).
> Accueil, sections, tailles et bandeau des lots corrigés ; saturation après timeout WMI reproduite puis corrigée.
> Contrôles ciblés seulement ; la grande liste reste à 151 points intégrés et 9 de qualification seule.

> **État du 16 octobre 2026** : lire le [bilan de reprise Windows](validation/2026-10-16/windows-recovery/README.md).
> David demande de limiter les essais VM aux corrections indispensables ; aucune nouvelle campagne générale.
> Les sections plus anciennes ci-dessous restent historiques.

> **État du 13 octobre 2026** : consulter d’abord le [bilan des améliorations et contrôles](validation/2026-10-13/README.md)
> et le [README Domenia 1.0](README.md). La suite de ce fichier conserve la passation antérieure.
> Le travail courant utilise Codex, des packs DEV/PROD classiques et le moteur Query commun épinglé.
> Les contrôles Windows avec données fictives et la qualification complète sur AD restent deux preuves distinctes.

> **Relais du 2026-10-04** : l'état courant, la procédure exacte par étape, le labo et le reste à faire sont dans
> `RELAIS-D120-2026-10-04.md` (prompt de prise de relais complet). Lis-le en premier.

> **Mise à jour du 2026-10-02 (session cloud, branche `claude/epic-newton-j5ir1w`)** : les neuf branches `lot/*` sont
> fusionnées et raccordées sur cette branche ; `master` est inchangé. L'état exact, les défauts trouvés et la reprise
> dans la VM sont dans `dev/engineering/d120/ETAT-2026-10-02.md` (dernière section) ; le suivi point par point est à
> jour (`RACCORDE_NON_EXECUTE` = branché, tests écrits, rien exécuté sous 5.1). Les sections 4 et 7 ci-dessous décrivent
> l'état antérieur à cette intégration.

Tu reprends un chantier en cours. Lis ce fichier en entier, puis `CLAUDE.md`, puis
`dev/engineering/d120/Suivi_D001_D120.json`. Tout ce qui est décrit ici comme « fait » est dans le dépôt et vérifiable ;
tout ce qui est décrit comme « à faire » ne l'est pas.

---

## 1. Mission

Demande de l'utilisateur, mot pour mot : « reprend ce projet, termine tous les points restants et améliore-le encore tant que possible »,
puis « attention, on reste sur PowerShell 5.1, pas de 7 dans mon SI », puis « go tout terminer ».

Concrètement : mener les 120 points de `Suivi_D001_D120.json` jusqu'à un moteur **RC1.11.0** raccordé, testé sous
Windows PowerShell 5.1 réel, reconstruit en archives DEV et PROD, avec un suivi honnête point par point.

L'utilisateur (Frère) est informaticien en environnement Windows/AD, écrit en français bref et informel, et veut de l'action
plutôt que des questions. Il applique son « Protocole Sboube » : niveaux de confiance explicites, désaccord assumé, aucune
flatterie, rien d'inventé. Il a levé l'interview par « go » : les décisions ci-dessous sont verrouillées. Ne rouvre une
décision que si tu rencontres un point réellement nouveau ; dans ce cas pose **une** question avec ta recommandation.

## 2. Décisions verrouillées

| Id | Décision | Confiance |
|---|---|---|
| F1 | Cible unique Windows PowerShell 5.1 x64 STA. Garde-fou `tools/Test-DomeniaPs51Compat.ps1` à 0 erreur. | élevée |
| F2 | « Terminé » = `RACCORDE_A_VALIDER_WINDOWS`. `acceptance_passed` ne passe à vrai que sur preuve 5.1 liée au hash du ZIP final. | élevée |
| F3 | La preuve Windows vient d'une exécution réelle (poste de labo), via la campagne de qualification à écrire. | élevée |
| F4 | Le moteur RC1.10.7 sera modifié (obligatoire pour raccorder). Nouvelle version **RC1.11.0**. Contrats worker modifiés ré-épinglés et listés. | élevée |
| F5 | Nouveaux comportements actifs par défaut ; interrupteurs `Features.<Nom>` dans `wad/Domenia.config.json` pour ceux qui remplacent un parcours existant (lecture par `Get-DomeniaFeatureFlag`). | modérée |
| F6 | Ordre P0, puis P1, puis P2 ; état reconstructible à chaque palier. | modérée |
| F7 | Encodage existant conservé : `.ps1` UTF-8 BOM + LF, `.cmd` CRLF. | modérée |
| F8 | `Domenia.exe` conservé à l'octet (SHA-256 `3535A6CB…E7AC`). Sa version de composant est déclarée à part (le critère D010 l'autorise). | modérée |
| F9 | Schéma SQLite : évolution en avant, sauvegarde préalable, refus de retour arrière silencieux. | modérée |
| F10 | Points dépendant d'éléments absents : D119 et D080 côté Domenia seulement (pas de sources Pesto/FILPRO) ; D120 = socle de connecteurs + WAPT en lecture seule ; D109 désactivé par défaut ; D116 = outillage sans certificat. Ils resteront `PARTIEL`. | élevée |

## 3. Ce qu'est le projet

- Application : `dev/Domenia.exe` (lanceur C de 26 Ko) → `wad/Domenia-Start.ps1` (manifeste, empreintes SHA-256 de chaque fichier
  runtime, verrou de cycle de vie) → `wad/Domenia-Core.ps1`.
- `Domenia-Core.ps1` : 23 775 lignes, 598 fonctions. Contient le XAML principal (`Get-MainXaml`, 2 620 lignes, 562 contrôles nommés),
  le moteur de tâches (`Start-UiTask`, `Complete-UiTasks`, `New-DomeniaWorkerRunspace`), le code commun des workers
  (`$script:WorkerCommon`, here-string à la ligne ~7895), SQLite via `winsqlite3` (lignes ~19282-19736), le login, les écritures AD.
- 21 modules dans `wad/modules`, chargés par la liste fermée de `wad/Domenia-Modules.ps1` qui vérifie l'origine de chaque fonction.
- 57 opérations worker épinglées par SHA-256 (`Get-DomeniaWorkerOperationHashes` dans le cœur, `tools/operation-contracts.json`).
- Build déterministe : `tools/build_packages.py` (contrôle statique, audit de sélection, contrats worker, manifestes, ZIP DEV et PROD).
- Onglets de la fenêtre principale : `TabDashboard` Accueil, `WsSearch` Rechercher, `WsObject` Fiche (`TabGeneric`, `TabUser`,
  `TabUserContact`, `TabUserAdmin`, `TabGroup`, `TabContainer`, `TabMemberOf`, `TabRaw`, `TabPermissions`), `TabAccounts` Comptes,
  `TabRelations` Relations (`TabLinksSelected`, `TabLinksAssociate` avec `TabRelationDetect` et `TabRelationSearch`, `TabLinksAll`,
  `TabLinksAttempts`), `WsComputer` Assistance poste (`TabComputer`, `TabComputerAdmin`, `TabSessions`, `TabComputerHealth`,
  `TabInventory`, `TabSoftware`, `TabWmi`, `TabSecurity`), `TabApplicationTools` Outils (`TabGuard` Fiabilité, `TabExperience`,
  `TabSelfCheck`, `TabIndex`, `TabOperationStats`, `TabDomain`, `TabCmdlets`, `TabLog`), plus `TabSupport` Atelier chargé depuis
  `Domenia-Support.xaml`.
- Historique : le plan précédent M01-M42 (`wad/docs/M01-M42-COUVERTURE.md`) a déjà raccordé une partie de ce que D001-D120 demande.
  Estimation personnelle : environ la moitié des points « non clôturés » ont du code partiel dans RC1.10.7 (confiance modérée).
  Vérifie l'existant avant d'ajouter : beaucoup de points se terminent en complétant, pas en créant.

## 4. Ce qui a été fait dans la session précédente

Trois commits dans le dépôt git joint : `1f5d79a` (archive reçue), `0a6b928` (socle), `4a492d9` (modèles), plus le commit de passation.
`git diff 1f5d79a` montre tout ce qui a été ajouté. **Le runtime est inchangé** : aucun fichier existant de `wad/` n'a été
modifié et les nouveaux modules ne sont pas déclarés dans le chargeur.

### 4.1 Outillage

| Fichier | Rôle |
|---|---|
| `dev/tools/Test-DomeniaPs51Compat.ps1` | Garde-fou statique 5.1 par AST : syntaxe 6/7, commandes et paramètres absents de 5.1, API .NET modernes, fichier non ASCII sans BOM. Tourne sous 5.1 et sous 7. |
| `dev/wad/tests/Test-DomeniaRules.ps1` | Lanceur des tests de règles pures. Charge les 12 `*.Model.ps1` et `wad/tests/rules/*.Tests.ps1`. Rapport JSON avec `NativeWindowsPowerShell51`. |
| `dev/engineering/d120/lab/Invoke-LabRun.ps1` | Lance chaque `wad/tests/Test-*.ps1` dans son propre `powershell.exe -STA`, collecte rapports et codes de sortie. |
| `dev/engineering/d120/lab/baseline-5.1-r1-summary.json` | Ligne de base réelle des suites existantes avant raccordement, avec le détail des 79 échecs. |
| `dev/engineering/d120/PLAN-EXECUTION-D120.md` | Décisions et architecture, version courte. |

### 4.2 Règles pures écrites et testées (57 points, 132 tests)

| Module | Points | Contenu |
|---|---|---|
| `Domenia-Common.Model.ps1` | transversal | `Get-DomeniaMember`, `ConvertTo-DomeniaGuidText`, `ConvertTo-DomeniaSidText`, `Get-DomeniaTextHash`, `ConvertTo-DomeniaUtcDate`, `Get-DomeniaFeatureFlag`, `New-DomeniaFact`, `ConvertTo-DomeniaFlatText` |
| `Domenia-Identity.Types.cs` | D012, D091 | Types immuables C# 5 : `Domenia.SelectionIdentity`, `Domenia.PlanChange`, `Domenia.InterventionPlan` (empreinte SHA-256) |
| `Domenia-Engine.Model.ps1` | D011, D012, D015, D017-D020 | Plan de démarrage et cycles, identité de sélection, classes et clé de partage des tâches, admission et file, états d'annulation, budgets par fournisseur, registre de ressources, politique de repos |
| `Domenia-Cache.Model.ps1` | D021-D030 | Projections, plan de mise à jour par cellule, tampon de pages, fraîcheur par nature, clé de cache v3, synchronisation incrémentale, cache d'échecs, file d'écriture unique, rétention, politique hors ligne |
| `Domenia-Search.Model.ps1` | D031-D040 | Littéraux LDAP, syntaxe à jetons, filtre multi-mots, requête globale, état rechercher/parcourir, classement, identifiants collés, continuation, vues de travail, chemins d'OU, historique de navigation |
| `Domenia-Relations.Model.ps1` | D041-D050 | Direction symétrique, double identité, natures de relation, badges sans pourcentage, automate d'association, fusion de candidats, plan de périmètre, compteurs, identité exacte de compte, historique et conflits |
| `Domenia-Access.Model.ps1` | D051-D060 | Portée de compte par ressource et cible, décision d'erreur par code, regroupement des refus, bail de compte, besoin d'authentification, explication de capacité, vue LAPS, liste de clés BitLocker, masquage de secrets, politique de transport |
| `Domenia-Directory.Model.ps1` | D061-D070 | Résumé support, politique de mot de passe effective, diagnostic de verrouillage, chemin d'appartenance, comparaison d'utilisateurs, delta de groupes, vue des ACE, cycle de vie, incohérences, comparaison entre contrôleurs |

Fichiers vides marqués « A ECRIRE » : `Domenia-Workstation.Model.ps1`, `Domenia-Shell.Model.ps1`, `Domenia-Safety.Model.ps1`,
`Domenia-Insight.Model.ps1`, `Domenia-Release.Model.ps1`. Le lanceur de tests exige leur présence.

L'ancien `engineering/d120/rules/Domenia.ReadRules.psm1` et son test sont remplacés par ces modules, sauf
`Get-DomeniaCounterText` et `Get-DomeniaResultColumns` qui doivent être repris dans `Domenia-Shell.Model.ps1`. Supprime le
`.psm1` et `Test-ReadRules.ps1` quand c'est fait.

### 4.3 Résultats réellement obtenus

Poste de labo, Windows 11 (10.0.26200), **Windows PowerShell 5.1.26100.9549**, session SSH non interactive (session 0), le 2026-10-02 :

| Vérification | Résultat |
|---|---|
| `Test-DomeniaRules.ps1` | 132 réussis, 0 échec, `NativeWindowsPowerShell51 = true` |
| `Test-NativeParser.ps1 -RequireWindows51` | PASS, 86 fichiers, `Windows51Qualification = true` |
| `Test-DomeniaPs51Compat.ps1` | PASS, 86 fichiers, 0 erreur |
| `Add-Type` sur `Domenia-Identity.Types.cs` | compilé par le compilateur C# 5 intégré |
| 24 suites existantes de RC1.10.7 | 1215 réussis, **79 en échec** (antérieurs au lot) |

WPF fonctionne dans la session SSH : `Test-DomeniaCandidate` 151/151, `Test-DomeniaEmbeddedUi` 72/72, `Test-DomeniaPreload` 86/86.
Ces exécutions ne sont liées à aucun ZIP de livraison : ce n'est pas une qualification de publication.

### 4.4 Les 79 échecs de la ligne de base

Détail complet dans `baseline-5.1-r1-summary.json`. Tri fait à la lecture des messages (confiance modérée, à confirmer suite par suite) :

**Suites historiques désynchronisées** (elles extraient par AST des fonctions qui ont depuis migré du cœur vers un module, ou
attendent un ancien nombre d'opérations) : `Test-DomeniaAccounts` (20 : `Start-DomeniaAccountValidation` introuvable),
`Test-DomeniaRelease` (20 : « registre de 48 opérations », `Get-DomeniaStructuredError` introuvable), `Test-DomeniaRemote`
(une partie des 14 : `Assert-WRemoteArtifactPermission`, `Get-DomeniaRetryCredential` introuvables), `Test-DomeniaLastUser` (2),
`Test-DomeniaStartupLogin` (3), `Test-DomeniaStreaming` (2 : « 48 opérations »), `Test-Domenia` (« 47 corps »),
`Test-DomeniaSearchScope` (1), `Test-DomeniaModules` (s'arrête à la ligne 105 sans rapport). À remettre à niveau ou à archiver
dans `wad/docs/history/` avec le motif ; ne jamais les annoncer réussies sans les avoir corrigées.

**Défauts réels probables à corriger dans le code** :

- `Test-DomeniaTheme` (3) : dans les trois XAML de login en thème sombre, `ChkRemember` a un texte `#EDF4FF` sur fond `#FFFFFF`,
  contraste 1,1:1. Relève de D090.
- `Test-DomeniaSearchPresence` (1) : « A global user was hidden by a local filter » — en mode global un filtre local de présence
  masque un utilisateur. Relève de D031.
- `Test-DomeniaRelationsAlignment` (9) dont « Compte console autre utilisateur non associé ». Relève de D042/D049.
- `Test-Domenia` : « CSV : formules, séparateurs, textes et nombres » — à examiner sous culture fr-FR.
- `Test-DomeniaRemote` : « Cible unique valide : TESTPC » refusée par la validation du nom de poste.
- `Test-DomeniaSelection` (1) et `Test-DomeniaInterface` (1) : tests de géométrie qui échouent sous 5.1 réel
  (« Association header was not realized », « Panneau latéral en grande largeur »). Peut dépendre de la session 0 ; à rejouer
  dans une session interactive avant de conclure.

## 5. Environnement de test

- **Poste Windows du labo** : `DESKTOP-285EKHU`, utilisateur local `degun` (administrateur), hors domaine (WORKGROUP), joignable en SSH
  à `192.168.1.173`. Stratégie d'exécution LocalMachine = Unrestricted. L'accès est fourni par l'utilisateur : **ne jamais écrire
  de mot de passe dans le dépôt, un script ou un rapport**.
- **VirtualBox sur ce poste** : `CNAMTS-DC01` (contrôleur de domaine) et `CNAMTS-W11-01` (client Windows 11 joint au domaine).
  Elles étaient éteintes le 2026-10-02. Elles servent aussi aux sessions Pesto et FILPRO : ne les modifie pas, ne les arrête pas
  si quelqu'un les utilise. L'utilisateur autorise la création d'une VM dédiée si besoin.
- Dossier de travail déjà créé sur le poste : `C:\Users\degun\domenia-lab` (`in`, `work`, `out`, `jobs`).
- Si tu tournes **directement sur ce poste**, lance les commandes de `CLAUDE.md` telles quelles : c'est la boucle la plus courte.
- Pour les tests sur le domaine il faut une session sur une machine jointe, sous un compte du domaine ouvert par l'utilisateur.
  Lectures seules par défaut. Avant tout test d'écriture, crée une OU de test dédiée et préviens l'utilisateur.
- Pas de pilotage du bureau ouvert (session console de `degun`) sans le demander.
- La session précédente tournait dans un bac à sable Linux et passait par un relais de fichiers sur le Mac de l'utilisateur
  (`~/Downloads/Domenia-lab/relais.sh`). Tu n'en as pas besoin si tu es sur le poste Windows ou sur le Mac avec SSH direct.

## 6. Conventions d'architecture à respecter

- Méthode de test existante : extraire par AST les vraies fonctions du cœur (`FunctionDefinitionAst`), remplacer les dépendances
  réseau par des doubles, exercer les vrais gestionnaires sur de vrais contrôles WPF. Modèle : `wad/tests/Test-DomeniaPreload.ps1`.
- Une lecture à la demande = une fonction `Get-Domenia<X>WorkerCode` qui renvoie une here-string **à guillemets simples**, déclarée
  dans `Get-DomeniaWorkerOperationHashes` et dans `tools/operation-contracts.json`. Le worker reçoit `$Context` et `$Payload`
  et dispose de `New-WSearcher`, `New-WEntry`, `New-WRootDse`, `Get-WPropFirst`, `Get-WPropAll`, `Convert-WGuid`, `Convert-WSid`,
  `Convert-WFileTime`, `Escape-WLdap`, `Get-WAllProperties`, `New-WDomeniaCimSession`, `Get-WMachineCredential`.
- `Get-WorkerContext` (cœur ~20679) contient des listes d'opérations codées en dur (`$remoteOperations`,
  `$machineCredentialOperations`, `$nonDirectoryOperations`). Toute nouvelle opération doit y être classée ; le mieux est de les
  remplacer par `Get-DomeniaOperationResource` / `Get-DomeniaOperationProvider`.
- Tout constat affiché suit `New-DomeniaFact` : Fait, Valeur, État (`Constate`, `Estime`, `Inconnu`, `Refuse`, `Indisponible`),
  Source, Limite, Hypothèse, Date, Lecteur. Un refus de lecture ne produit jamais un verdict.
- Vues à la demande : prévoir un cadre unique (titre, coût annoncé, bouton « Lire », état, grille de faits) alimenté par un
  registre déclaratif, hébergé dans des onglets existants. Ne pas ajouter de destination de premier niveau (D081).

## 7. Reste à faire

### 7.1 Finir les règles pures

Écrire les cinq modules vides et leurs tests `wad/tests/rules/<Domaine>.Tests.ps1`, dans le même style que les six existants.

**`Domenia-Workstation.Model.ps1` (D071-D080)**

- D071 `Get-DomeniaQuickDiagPlan` : cinq contrôles bornés (système, dernier démarrage, disque C:, ports 135/445/5985, services de
  gestion) avec coût annoncé (« 5 contrôles, 20 s au plus ») ; `ConvertTo-DomeniaQuickDiagFacts` transforme le retour brut en faits.
- D072 `ConvertTo-DomeniaSessionView` : session, utilisateur, état, protocole, source ; `Get-DomeniaSessionEmptyText` (« console vide
  ne signifie pas absence de session RDP »). Aucune action de déconnexion.
- D073 `Get-DomeniaSoftwareSources` : clés de désinstallation 64 et 32 bits, catégories non couvertes (installations par utilisateur,
  Appx/MSIX) ; `Test-DomeniaInventoryCodeSafe` refuse `Win32_Product` dans un code d'inventaire.
- D074 `Get-DomeniaEventPresets` (démarrage/arrêt 6005, 6006, 6008, 41, 1074 ; plantages 1000, 1001 ; disque 7, 11, 51, 153 ;
  stratégie 1085, 1125, 7016 ; mises à jour 19, 20, 43) avec fenêtre et volume bornés ; `ConvertTo-DomeniaEventFacts`
  (un refus de lecture n'est pas un constat sain).
- D075 `Resolve-DomeniaGpoView` : liens lus dans AD (`gPLink`, blocage d'héritage) distincts du résultat appliqué (RSoP par CIM,
  `root\rsop\computer`) ; une GPO liée n'est pas annoncée appliquée sans preuve.
- D076 `ConvertFrom-DomeniaDsregStatus` (analyse d'un texte `dsregcmd /status` collé) et `Get-DomeniaJoinStateFacts` ; l'état SSO de
  l'utilisateur final est déclaré non évaluable sous un compte d'administration.
- D077 `ConvertTo-DomeniaUpdateFacts` : date, source, résultat des dernières informations de mise à jour et de l'agent WAPT ;
  donnée ancienne marquée ancienne ; fournisseur absent = `Indisponible`, pas « en panne ».
- D078 `Test-DomeniaMachineIdentityCoherence` : nom AD (`dNSHostName`), résolution DNS, identité renvoyée par le poste ; une IP
  réattribuée ne reçoit pas les relations de l'ancien poste. Voir `Test-DomeniaLiveIdentity` dans `Domenia-Live.Model.ps1`.
- D079 `New-DomeniaWakePacket` (6 × FF puis 16 × MAC), `Test-DomeniaMacAddress`, `Get-DomeniaBroadcastAddress`,
  `Test-DomeniaWakeAllowed` (MAC et réseau connus, périmètre autorisé, action explicite, désactivé par défaut) ; état rendu
  « Demande envoyée », jamais « Poste allumé ».
- D080 `Test-DomeniaSuiteContract` : l'outil cible déclare `suite-contract.json` (schéma `DomeniaSuiteContract/1`, champs de contexte
  acceptés) ; sans contrat reconnu, lancement sans argument comme aujourd'hui (`Open-DomeniaSuiteTool` dans `Domenia-Guard.UI.ps1`).
  Jamais de commande shell, jamais de credential.

**`Domenia-Shell.Model.ps1` (D081-D090)**

- D081 `Get-DomeniaPageTitle` : toujours la page active et la cible (« Fiche · Jean Dupont »).
- D082 `Get-DomeniaReservedLayout` : dimensions réservées pour activité, compteurs et actions ; `Get-DomeniaCounterText` (0 → vide,
  plus de 99 → « 99+ »).
- D083 `New-DomeniaInlineRequest` : demande de confirmation dans la page avec continuation, sans fenêtre.
- D084 `Get-DomeniaResultColumns` (profils `Utilisateur`, `Machine`, `Mixte`), `Test-DomeniaProfileChangeAllowed` (jamais pendant
  une saisie ou l'arrivée d'un lot).
- D085 `Get-DomeniaSelectionPreview` : résumé de la sélection affiché dans Rechercher, même contrat pour utilisateur et poste.
- D086 `Get-DomeniaOperationSummary` : les valeurs qui influencent une opération apparaissent dans le résumé même si les options
  sont repliées.
- D087 `Get-DomeniaEmptyState` : `NoResult`, `LocalFilterEmpty`, `NoSource`, `NothingQueried`, `Refused`, `Partial`, chacun avec
  son texte et sa prochaine action ; jamais « n'existe pas ».
- D088 `Get-DomeniaDisabledHelp` : motif court pour tout contrôle grisé, sans contenu sensible.
- D089 `Get-DomeniaActivationDecision` : activation au lancement explicite et au passage login → principal uniquement, une seule
  tentative, pas de `Topmost` permanent, jamais après la fin d'une tâche.
- D090 `Get-DomeniaContrastRatio` (formule WCAG), `Test-DomeniaPaletteContrast`, `Get-DomeniaBoundedWindowRect` (restauration
  multi-écrans bornée), `Get-DomeniaStatusGlyph` (un statut ne repose pas seulement sur une couleur).

**`Domenia-Safety.Model.ps1` (D091-D100)**

- D091 `New-DomeniaInterventionPlan` (crée `Domenia.InterventionPlan`), `Test-DomeniaPlanStillValid` (l'empreinte recalculée à
  l'exécution doit être identique ; un champ modifié ou une cible changée invalide le plan).
- D092 `Get-DomeniaDryRunPolicy` : la simulation exécute les lectures préalables et produit le plan, sans jamais appeler un
  fournisseur d'écriture.
- D093 `Get-DomeniaPostconditionRule` par opération (appartenance, déplacement, attribut, état) et `Resolve-DomeniaPostcondition`
  → `Verifie`, `Partiel`, `A verifier` avec la preuve précise.
- D094 `Get-DomeniaReceiptRequirement` : quelles opérations exigent un reçu écrit avant l'envoi (écritures AD, GPUpdate,
  redémarrage, exécution distante, réveil).
- D095 `Test-DomeniaWriteAdmission` : clé d'idempotence = empreinte du plan ; un double-clic ne lance qu'une demande ; au
  redémarrage aucune.
- D096 `Get-DomeniaAtomicStrategy` : remplacement conditionnel (retirer l'ancienne valeur et ajouter la nouvelle dans la même
  requête) pour les attributs mono-valués texte ; sinon relecture avant et après, et limite exposée.
- D097 `Test-DomeniaOperationAllowed` : verrou par cible et par classe d'action ; une écriture incertaine bloque les écritures et
  l'édition de sa cible, pas les lectures des autres cibles. Aujourd'hui `Test-DomeniaAccessBusyWrite` bloque tout.
- D098 `Get-DomeniaSessionEndPlan` : expirer les comptes pour les nouveaux appels, garder le suivi des opérations parties,
  avertir des sauvegardes en attente ; aucun texte n'annonce une annulation distante non confirmée.
- D099 `New-DomeniaBatchPlan`, `Step-DomeniaBatch`, `Get-DomeniaBatchReport` : sélection explicite, aperçu par objet, exécution
  séquentielle bornée, politique d'arrêt ; un échec ne rend pas le lot « réussi » et n'entraîne aucun rejeu des éléments incertains.
- D100 `Get-DomeniaCompensation` : compensation proposée seulement si ses préconditions restent vérifiables ; jamais pour un mot
  de passe ou une suppression ; distinguer retour arrière du code, du cache et d'une modification AD.

**`Domenia-Insight.Model.ps1` (D101-D110)**

- D101 s'appuie sur `New-DomeniaFact`. Ajouter `Test-DomeniaVerdictAllowed` : pas de verdict de santé ou d'absence sur un refus.
- D102 `Get-DomeniaNextAction` : une seule étape sûre selon le blocage (fournir un périmètre, choisir une source, changer de
  compte, relire) ; ne l'exécute jamais.
- D103 `Get-DomeniaTimeline` : observations et changements réellement constatés pour un GUID, événements du poste et actions de
  Domenia séparés, sans secret, sans passé reconstruit.
- D104 `New-DomeniaTicketReport` : tenté, confirmé, refusé, non testé ; rubriques sélectionnables ;
  `ConvertTo-DomeniaPseudonym` (pseudonymes stables et contrôlables). S'appuyer sur `Domenia-Support.Model.ps1`.
- D105 `Group-DomeniaIncidents` : regroupement par fournisseur, code et contexte ; deux cibles différentes ne deviennent pas un
  faux succès commun ; le détail individuel reste consultable.
- D106 `Add-DomeniaMetricSample`, `Get-DomeniaMetricSummary` : séries séparées par provenance (cache, LDAP, CIM, SQLite, file
  d'attente, Dispatcher), percentiles locaux ; un temps de cache ne sert pas de mesure LDAP. Voir `Get-DomeniaPercentile`.
- D107 `New-DomeniaTrace`, `Add-DomeniaTraceEvent` (liste blanche de champs via `Select-DomeniaAllowedFields`),
  `Export-DomeniaTraceRows` : tampon circulaire borné, activable.
- D108 `New-DomeniaReproFixture` : séquence d'intentions d'interface et formes de résultats, valeurs pseudonymisées, aucune
  commande exécutable issue d'un journal.
- D109 `New-DomeniaAssistantRequest` : dossier nettoyé uniquement, descriptions AD et journaux encadrés comme données non fiables,
  point d'accès local (127.0.0.1) seulement, aucun outil, désactivé par défaut.
- D110 `Get-DomeniaTroubleshootingJourneys` : « Compte inaccessible », « Poste non joignable », « LAPS refusé » ; suite de lectures
  explicites avec coût et arrêt visibles ; choisir un parcours ne déclenche rien.

**`Domenia-Release.Model.ps1` (D010, D111-D120, côté runtime)**

- D010 `Get-DomeniaReleaseIdentity` : identité unique lue d'un contrat de release (voir 7.4).
- D118 `Get-DomeniaStorageLayout` : chemins et droits par catégorie (configuration, préférence, cache, reçu), mode local ou
  portable explicite ; un dossier non inscriptible produit une erreur explicite, pas une bascule silencieuse.
- D115 `Test-DomeniaSchemaCompatibility` : base ancienne, courante, future ; refus d'un retour arrière.
- D113 `Test-DomeniaMigrationIdempotent` : une migration répétée ne duplique pas les liens et n'écrase pas une configuration Domenia.
- D120 `Get-DomeniaConnectorCatalog`, `Test-DomeniaConnectorAvailable`, `ConvertFrom-DomeniaWaptHost` : connecteur absent ou
  refusé = masqué, ne bloque pas AD, ne collecte rien automatiquement.
- D119 `Get-DomeniaSuiteKitManifest` : jetons de thème, vocabulaire, version du kit (voir `SupportSuite.UI.json` et
  `Get-SuitePalette` dans `Domenia-Experience.Model.ps1`).

**Règles manquantes pour A et B** : D013 (extraction du XAML principal et de `$script:WorkerCommon` vers des fichiers, vérifier
d'abord que `Get-MainXaml` renvoie une here-string sans interpolation), D014 (audit par AST des appels bloquants atteignables
depuis les gestionnaires d'événements : `WaitOne`, `.Wait()`, `Start-Sleep`, `Invoke-DomeniaDbExec`, `Get-FileHash`,
`FindAll`, `New-CimSession`…), D016 (processus auxiliaire borné, désactivé par défaut, sans secret en argument), D004 (bibliothèque
de fixtures fidèles aux types AD), D005 (une reproduction par régression), D006 (géométrie), D007 (injection de pannes),
D008 (séquences générées A/B/C).

### 7.2 Mode démonstration et banc d'essai de l'application entière

Indispensable pour D002 et D003, et pour vérifier le raccordement sans domaine. Idée : `Auth.DemoProvider = true` dans
`wad/Domenia.config.json` (fichier préservé, non haché) fait démarrer le moteur sur un annuaire fictif en mémoire, bandeau
« DÉMONSTRATION — aucune connexion AD », écritures désactivées. Le login accepte une identité de démonstration sans contacter AD.
`Start-UiTask` remplace alors l'opération demandée par une opération épinglée `DemoDirectory` qui renvoie des résultats de même
forme pour au moins `TreeChildren`, `GlobalSearch`, `OpenAdObject`, et « non disponible en démonstration » pour le reste.
À lire avant d'écrire : `Show-LoginWindow` (~23401), `Complete-DomeniaFastLoginSuccess` (~22789), `Initialize-Window` (~22496),
`Invoke-DomeniaSelfTest` (~23531), `wad/maintenance/Preview-DomeniaUi.ps1`.

### 7.3 Raccordement

Pour chaque module de règles : le déclarer dans `Domenia-Modules.ps1` avec toutes ses fonctions (ajouter `Phase` et `Requires`,
puis valider le plan avec `Test-DomeniaStartupPlan` avant le premier import), brancher, écrire un test d'intégration qui échoue
si l'on débranche, relancer toutes les suites, comparer à la ligne de base.

| Domaine | Où brancher |
|---|---|
| Moteur (D015, D017, D018) | `Start-UiTask` (~20285) lève une exception quand la limite est atteinte : remplacer par `Test-DomeniaTaskAdmission` et une entrée `State='Queued'` dans `$script:AsyncJobs`. `Complete-UiTasks` (~20467) démarre les tâches en attente avec `Select-DomeniaNextQueuedTask` et enregistre les issues avec `Register-DomeniaProviderOutcome`. `Request-UiTaskStop` (~20385) et `Update-TaskUi` (~8879) affichent `Get-DomeniaTaskStateSummary`. Attention : les appelants testent `$script:AsyncJobs[$id]` pour savoir si leur tâche vit encore. Interrupteur `Features.Scheduler`. |
| Ressources et repos (D019, D020) | `Dispose-AsyncEngine` (~20614) arrête une liste de minuteurs codée en dur : passer par le registre de ressources. Gestionnaires `Activated`, `Deactivated`, `StateChanged` de la fenêtre → `Get-DomeniaIdlePolicy` ; les ticks (`Invoke-DomeniaLiveTick`, `Invoke-DomeniaReconcileTick`, tableau de bord) consultent `Test-DomeniaIdleAllows`. |
| Sélection (D012) | `Get-DomeniaSelectionContext` dans `Domenia-Selection.UI.ps1` renvoie déjà DN, type, GUID, session, génération : lui faire produire `Domenia.SelectionIdentity` et faire consommer cette identité par Fiche, Relations et Assistance. |
| Recherche (D031-D037) | `Invoke-GlobalSearch` (~9449, worker épinglé `GlobalSearch`), `Complete-DomeniaGlobalSearchUi` (~9283), `Get-DomeniaSearchScope` (~6606), `Invoke-DomeniaSearchFilterChanged` (~6682), `Get-SearchLdapFilter` (~6726). Corriger d'abord le défaut révélé par `Test-DomeniaSearchPresence`. Jetons et indice d'identifiant sous `TxtGlobalSearch` ; bouton « Charger la suite ». |
| Vues, OU, historique (D038-D040) | Favoris dans `Domenia-Guard.UI.ps1` (`Save-DomeniaFavouriteSearch`), restauration d'OU dans `Domenia-Continuity.UI.ps1` (`Invoke-DomeniaTreeBookmarkRestore`), affichage d'OU dans `Domenia-UX.UI.ps1` (`Get-DomeniaUxOuDisplay`), navigation dans `Select-DomeniaWorkspace` (~9055). |
| Cache (D021-D030) | Clé de visite `Get-DomeniaObjectCacheKey` (`Domenia-Selection.UI.ps1`, préfixe `object-v2`), présence dans `Domenia-Live.Model.ps1` et `Domenia-Live.UI.ps1`, file d'écriture dans `Domenia-Storage.UI.ps1` et `Domenia-Storage.Worker.ps1`, réconciliation dans `Domenia-Reconcile.UI.ps1`, base dans `Initialize-DomeniaDatabase` (~19548, `schema_version` = 11). |
| Relations (D041-D050) | `Domenia-Relations.UI.ps1` : tout est conditionné par `$isUser` (`Update-DomeniaRelationsActions`) ; `Start-DomeniaRelationsSearch` change de périmètre en silence (bloc « Candidates → OU → Loaded ») : le remplacer par `Get-DomeniaDetectionScopePlan` et une étape de confirmation ; `Save-DomeniaRelationConfirmations` écrit `Confidence=97` et remplace le lien existant du poste : passer à `Resolve-DomeniaRelationUpsert`. Côté poste, la détection est `Start-ComputerUserLinkProbe` (~15779). Stockage : `Add-UserMachineLinkIfMissing` (~17996), `ConvertTo-DomeniaCanonicalLinks` (~19917). Colonnes des grilles `DgLinks`, `DgAllLinks`, `DgRelationCandidates` : badge à la place du score. |
| Accès et secrets (D051-D060) | `Domenia-Access.UI.ps1` (`Get-DomeniaAccessScope`, `Request-DomeniaAccessRecovery`, expiration absolue de 30 min à rendre glissante), `Get-DomeniaStructuredError` dans `Domenia-Guard.Model.ps1` (aussi injecté dans chaque worker), `Start-LoadComputerSecrets` (~10406), `Complete-DomeniaSecretLoadUi` (~10323), `Update-DomeniaSecretActionUi` (~21188), `Protect-DomeniaLogText` (~180), `Show-DomeniaUnavailableReasons` (`Domenia-Guard.UI.ps1`). BitLocker : lecture en deux temps, métadonnées puis une seule clé (nouvelle opération `ReadBitLockerKey`). |
| Annuaire (D061-D070) | Fiche : `Fill-UserObject` (~6955), onglets `TabUser`, `TabMemberOf`, `TabPermissions`. Écritures : `Start-DomeniaWriteTask` (~21667), `AddOrRemoveObjectGroup` (~22057), `Start-PermissionAnalysis` (~9926). Nouvelles opérations à épingler : `PasswordPolicyRead`, `LockoutDiagnosis`, `GroupPathRead`, `AdConsistencyScan`, `DcCompareRead`. |

Champ `Features.*` prévu : `Scheduler`, `ScopedLocks`, `RelationsSymmetry`, `DetectionPreview`, `SearchSyntax`, `ColumnProfiles`,
`InlineConfirm`, `IsolatedReads` (désactivé par défaut), `WakeOnLan` (désactivé par défaut), `LocalAssistant` (désactivé par défaut).

### 7.4 Distribution et qualification

- D010 : contrat unique `tools/release-contract.json`. Aujourd'hui la version est écrite à quatre endroits du cœur
  (`$script:MasterBuild` ligne ~18867, `$script:DomeniaBuild` ~22607, texte du pied de navigation dans le XAML ~4042, journal
  « prêt » ~21477) et dans `tools/build_packages.py` (ligne 6 et nom des archives ligne 63). Le build doit vérifier et estampiller.
  Build cible : `2026.10.02-DOMENIA-1.0-RC1.11.0-D120`.
- D001, D002, D003, D009 : `wad/tests/Invoke-DomeniaQualification.ps1` et `QUALIFIER-WINDOWS.cmd` à la racine DEV. Dix scénarios
  requis par `engineering/d120/release_guard.py` : `parser.ps51`, `runtime.modules`, `worker.contracts`,
  `startup.exe_login_main`, `ui.actual_events`, `ui.layout_profiles`, `data.sqlite`, `security.secret_markers`,
  `race.selection`, `prod.standalone`. Chaque scénario : `Id`, `Status`, `Executed`, `StartedUtc`, `EndedUtc`, `EvidenceSHA256`.
  Rapport lié à `ArchiveSHA256`. Le test part du ZIP final extrait, sans fonction préchargée.
- D111-D117 : installation atomique dans `INSTALLER-MISE-A-JOUR.ps1`, migration `Import-DomeniaLegacyStoreIfNeeded` (~19639),
  inventaire des composants livrés avec versions lues dans les fichiers, `tools/Signer-Distribution.ps1`, brancher
  `release_guard.py` en fin de `build_packages.py`.
- Après toute modification du cœur : mettre à jour les références des audits de build (`tools/preload-baseline.json`,
  `tools/audit_preload.py`) qui comparent les fonctions du cœur à une liste autorisée.
- Mettre à jour `.github/workflows/windows.yml` pour qu'il lance la campagne complète.

### 7.5 Clôture

Mettre à jour `Suivi_D001_D120.json` point par point (fichiers, tests, reste), rédiger les notes de version RC1.11.0 en français,
reconstruire DEV et PROD par `build_packages.py`, passer `release_guard.py`, puis rendre un rapport delta : construit contre
prévu, écarts et raisons, registre de risques restant.

## 8. Pièges déjà rencontrés

- `A -or B -and C` s'évalue de gauche à droite : parenthèses obligatoires.
- `return $bytes` déroule un tableau d'octets : écrire `return ,$bytes`.
- `Start-Process -PassThru` : lire `$process.Handle` avant `WaitForExit()`, sinon `ExitCode` est vide sous 5.1.
- En C#, une propriété nommée `Guid` masque le type `System.Guid` à l'intérieur de sa classe : écrire `System.Guid`.
- `Split-Path -Leaf` est valide en 5.1 ; `-LeafBase` ne l'est pas.
- `0x80070005L` vaut bien 2147942405 sous 5.1 (vérifié sur le poste réel) ; sans le `L` c'est un entier négatif.
- Un fichier `.ps1` contenant des accents sans BOM est lu en ANSI par 5.1.
- Le cœur utilise une variable locale `$isWindows` (~22795) : sans effet sous 5.1, mais bloquant sous PowerShell 7 où ce nom
  est une variable automatique en lecture seule. Ne pas « corriger » pour 7 : la cible est 5.1.
- Les suites historiques exigent Windows PowerShell 5.1 et s'arrêtent sinon ; c'est voulu.
- WPF fonctionne dans une session SSH (session 0), mais les tests de géométrie peuvent y différer d'une session interactive.
- `tools/build_packages.py` **réécrit** `tools/prod-manifest.json` et `wad/package-manifest.json`, et embarque comme runtime
  tout fichier `.ps1`, `.json`, `.cs` ou `.xaml` présent dans `wad/modules`. Tant que les nouveaux modules ne sont pas raccordés,
  un build livrerait dans PROD des modules non chargés et cinq fichiers vides. Le build passe aujourd'hui (57 fichiers runtime
  au lieu de 45), mais ne livre rien avant le raccordement, et restaure les deux manifestes après un build d'essai
  (`git checkout -- dev/tools/prod-manifest.json dev/wad/package-manifest.json`).
- Les manifestes du dépôt sont ceux de RC1.10.7 : `Domenia-Start.ps1` ne vérifie que les fichiers runtime qu'ils déclarent,
  donc l'application de cet arbre démarre encore comme RC1.10.7.

## 9. Première action attendue

1. Vérifier l'état : lancer les quatre commandes PowerShell de `CLAUDE.md` et confirmer 132 règles réussies et 0 erreur de compatibilité.
2. Écrire les cinq modules de règles manquants avec leurs tests (7.1), palier par palier, en relançant les tests à chaque module.
3. Construire le mode démonstration (7.2), puis raccorder (7.3) en commençant par les points P0.
4. Tenir `Suivi_D001_D120.json` et `PLAN-EXECUTION-D120.md` à jour à chaque palier, et committer.
