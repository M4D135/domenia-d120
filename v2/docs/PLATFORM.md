# Domenia 2 — plateforme du moteur : modules, contexte, lecteurs d’écran, VM partagée

Ce document dit comment un écran s’ajoute côté C# sans toucher au reste : les opérations du pont sont regroupées en
**modules déclarés et découverts dans un plan compilé fermé**, chaque module reçoit un **contexte de services**, les lectures de chaque écran passent par
une **interface de lecture** propre à l’écran, servie par la simulation aujourd’hui et par `Domenia.Ad` demain. Il
décrit aussi la compilation par lot dans la VM partagée (§ 6). Le contrat des opérations reste dans
[`OPERATIONS.md`](OPERATIONS.md), la simulation dans [`SIMULATION.md`](SIMULATION.md).

Mis en place le 21 octobre 2026 ; `DashboardOperations` (Accueil), `SessionOperations` (session et OU de travail),
`DirectoryTreeOperations` (arborescence des OU) et `HostOperations` (`app.info`) suivent ce modèle.

## 1. Vue d’ensemble

```text
Domenia.App      Composition : charge les assemblages Domenia.*, trouve lecteurs et modules, construit le registre
Domenia.Bridge   IOperationModule, OperationModules (découverte, registre), un module par écran (Operations/*.cs)
Domenia.Core     EngineContext, IPreferenceStore, ITechnicalJournal, IScreenReader + une interface par écran,
                 services partagés (DashboardService, WorkingScope, WriteCircuit), règles pures (OrganizationalUnitTree…),
                 circuit des écritures (Writes/ : plan, jeton, IWriteExecutor + une interface par type d’écriture, reçus)
Domenia.Simulation  une implémentation par écran (Screens/Simulated<Écran>Reader.cs) et par écriture
                 (Writes/Simulated<Verbe>Executor.cs), sur SimulatedDirectorySource et sa surcouche en mémoire
Domenia.Store    FilePreferenceStore (préférences locales), FileReceiptStore (reçus d’écriture),
                 LegacyConfigurationFile (Domenia.config.json)
Domenia.Ad       plus tard : les mêmes interfaces de lecture et d’écriture, sur la source Active Directory
```

Au démarrage, après vérification du paquet, `Composition.Create` :

1. charge uniquement les huit assemblages de `RuntimeLibraryPlan` déclarés dans la liste de confiance de l’hôte ;
   compare chemin, version, identité de construction, MVID et contexte réel de chargement aux fichiers attendus ;
2. exécute le même précontrôle approfondi que `--check-only`, puis valide `RuntimeModulePlan` **avant tout constructeur
   de module** : types, phases Foundation/Screens/Host, dépendances, cycles et exports uniques ;
3. prépare la source du mode (`SimulatedDirectorySource` ou `AdDirectorySource`) et les préférences ; découvre les
   lecteurs et exécuteurs compatibles avec cette source, puis construit `EngineContext` ;
4. instancie les modules dans l’ordre du plan et compare les exports de leurs factories aux déclarations compilées,
   avec contrôle de provenance des handlers ; ne publie le registre fermé que si l’ensemble est cohérent ;
5. trace les phases et le nombre réel de modules et d’opérations. Aucune authentification ni opération métier n’est
   exécutée pour valider le plan.

Depuis L18 (01/11/2026), chaque module ajoute sa déclaration dans `RuntimeModuleDeclarations.cs` de **son propre
assemblage** : type, écran, phase, dépendances et noms exacts des opérations. Il n’est pas nécessaire de modifier la
composition ou le registre. L’inventaire est comparé aux vraies factories en CI Windows ; une opération oubliée ou
ajoutée sans déclaration refuse le démarrage. Les fixtures de test peuvent toujours composer explicitement un registre.

Voir [L18](reprise/LOTS-CODEX-20261101/L18.md) pour les adaptations D1/V2 et la qualification encore en attente.

## 2. Ajouter un écran côté C#

Exemple : l’écran « Comptes » (`comptes` dans `web/js/app.js`), avec une opération `accounts.locked`.

1. **Contrat.** Écrire l’opération dans `OPERATIONS.md` (classe, arguments, résultat exact, erreurs) avant le code.
2. **Interface de lecture** dans `Domenia.Core`, un fichier par écran, par exemple
   `src/Domenia.Core/Accounts/IAccountsReader.cs` :

   ```csharp
   public interface IAccountsReader : IScreenReader
   {
       Task<LockedAccounts> LockedAsync(ScopeSelection scope, CancellationToken cancellationToken);
   }
   ```

   Lecture seule par construction : aucun nom en `Write`, `Set`, `Delete`, `Move`, `Reset`, `Unlock`, `Enable`,
   `Disable`, `Add`, `Remove`, `Create`, `Update` (un test le vérifie pour toutes les interfaces dérivées de
   `IScreenReader`). Les modèles du résultat (records) vont à côté, dans Core.
3. **Implémentation simulée** dans `Domenia.Simulation/Screens/SimulatedAccountsReader.cs` : classe **publique**, non
   abstraite, avec **un seul constructeur public** qui prend `SimulatedDirectorySource`. Le constructeur ne lit rien
   (il garde la source, prépare des `Lazy`) ; les données viennent de `source.World` au premier appel, hors du fil de
   l’interface. Voir § 4 pour les données dérivées.
4. **Module** dans `Domenia.Bridge/Operations/AccountsOperations.cs` :

   ```csharp
   public sealed class AccountsOperations : IOperationModule
   {
       public string Screen => "accounts";

       public IEnumerable<OperationDefinition> CreateOperations(EngineContext context)
       {
           var readers = context.Readers;
           var scope = WorkingScope.From(context);
           return
           [
               new OperationDefinition("accounts.locked", OperationClass.LocalRead, async (args, _, cancellationToken) =>
               {
                   BridgeArguments.RequireNone(args);
                   var session = await context.Directory.GetSessionAsync(cancellationToken).ConfigureAwait(false);
                   var current = await scope.CurrentAsync(session, cancellationToken).ConfigureAwait(false);
                   return await readers.Require<IAccountsReader>().LockedAsync(current!, cancellationToken).ConfigureAwait(false);
               }, "Comptes verrouillés de l’OU de travail."),
           ];
       }
   }
   ```

   Classe **publique**, non abstraite, avec un constructeur public sans paramètre. `CreateOperations` s’exécute une
   fois, au démarrage, sur le fil de l’interface : il ne lit rien, il garde les services pour les gestionnaires (qui
   tournent sur le pool de threads). Les gestionnaires ne font que valider les arguments (`BridgeArguments`) et déléguer.
5. **Tests** dans `tests/Domenia.Tests/<Écran>Tests.cs` : formes JSON exactes, erreurs, admission en simulation, avec le
   pont réel (`SimulatedBridge`, qui compose comme l’application).
6. **Page** : `web/js/pages/<écran>.js` et `web/js/mock.js` (aperçu dans un navigateur) suivent le contrat.

Sans lecteur pour la source du mode (mode annuaire tant que `Domenia.Ad` n’existe pas), `Readers.Require<T>()` refuse
l’opération avec `source.unavailable`, comme `dashboard.summary`.

## 3. Conventions

### 3.1 Noms des opérations : `<écran>.<verbe>`

- Le premier segment est l’écran du module (`IOperationModule.Screen`) : un seul segment ASCII en camelCase minuscule
  initial (`dashboard`, `session`, `directory`, `accounts`). La composition **refuse de démarrer** si une opération ne
  commence pas par `<écran>.` ou si le nom d’écran est invalide ; un nom en double arrête aussi le démarrage.
- La suite est un verbe ou un objet puis un verbe, en camelCase : `dashboard.summary`, `dashboard.widget.refresh`,
  `session.setScope`, `directory.ou.children`. 64 caractères au plus, segments `[a-z][A-Za-z0-9]*`
  (`OperationRegistry.IsValidName`).
- Un événement poussé par une opération porte `<opération>:<nom>` (`BridgeContext.Publish`).

### 3.2 Classes d’opération

| Classe | Usage | Simulation |
|---|---|---|
| `Local` | état en mémoire ; ouvrir ou montrer un document déjà écrit (association de Windows, Explorateur) | admise |
| `LocalRead` | base locale, fichiers de l’application, annuaire fictif en mémoire | admise |
| `NetworkRead` | annuaire, WMI, DNS, ping, après un geste explicite, borné à une OU | admise seulement si `ServedInSimulation` |
| `LocalWrite` | **données locales de l’application seulement** (`%LOCALAPPDATA%\Domenia`) : préférences, reçus, documents demandés par l’opérateur (`Documents`, § 3.3), fichiers propres d’un écran déclarés dans son contrat, comme la bibliothèque et les exports de l’atelier de requêtes ([`ops/requetes.md`](ops/requetes.md)) ; jamais l’annuaire ni un poste | admise |
| `Write` | écriture AD ou action distante, **seulement `write.execute`** : plan, confirmation, reçu, relecture ([`WRITES.md`](WRITES.md)) | admise pour `write.execute` seulement, sur la surcouche en mémoire (décision du 21/10) |

La classe déclarée est celle du mode le plus exigeant ; elle peut dépendre du mode (`directory.ou.children` est
`LocalRead` en simulation, `NetworkRead` en mode annuaire : le module lit `context.Mode`). Chaque mode a sa garde, évaluée
par le dispatcher avant tout gestionnaire : `AdmissionGuards.ReadOnlySimulation` en simulation, et en mode annuaire
`AdmissionGuards.ReadOnlyDirectory`. Les deux n’admettent la classe `Write` que pour `write.execute`, la porte unique du
circuit d’écriture (`AdmissionGuards.IsWriteCircuit`, [`WRITES.md`](WRITES.md)) : toute autre opération `Write` est refusée
(`simulation.readOnly`, `write.unavailable`). Un écran qui écrit déclare un **plan** (une lecture,
`<écran>.<verbe>.plan`), jamais une écriture. Les deux gardes refusent par défaut toute classe qu’elles ne connaissent
pas : un module découvert automatiquement ne peut donc pas brancher une écriture à l’insu de cette garde.

### 3.3 Contexte de services (`EngineContext`)

| Membre | Rôle |
|---|---|
| `Decision`, `Mode` | décision de démarrage (mode, raison, bannière) |
| `Directory` | source d’annuaire du mode (`IDirectorySource`, lecture seule) |
| `Preferences` | préférences locales du mode (`IPreferenceStore`, § 5) |
| `Clock` | horloge (`TimeProvider`) ; les tests injectent une horloge fixe |
| `Log` | journal technique (`ITechnicalJournal`) : codes, nombres, types d’erreur ; jamais une saisie de la page, une donnée d’annuaire en masse ni un secret |
| `Readers` | lecteurs d’écran servis par la source du mode (`Find<T>()`, `Require<T>()`) |
| `Journal` | journal des opérations de la session, affiché par l’Accueil (« Dernières opérations ») |
| `Writers` | exécuteurs d’écriture servis par la source du mode (`Find<T>()`, `Require<T>()`, `ForKind(type)`), lancés par `WriteCircuit` seulement |
| `Receipts` | reçus d’écriture du mode (`IReceiptStore` : `receipts.jsonl`, `receipts-simulation.jsonl`, mémoire en capture et en E2E) |
| `Documents` | documents demandés par l’opérateur (`IDocumentStore` : `Exports`, `Exports-simulation` ; mémoire en capture, en E2E ou sans dossier de données). Chaque document est neuf et daté par l’écran (un nom pris reçoit `-2`, `-3`…), écrit atomiquement (fichier ou dossier temporaire renommé), un dossier lien est refusé ; `RevealAsync` montre un document dans l’Explorateur. Implémentation `FileDocumentStore` (`Domenia.Store`), chemin donné par `AppPaths.Exports` |
| `Shared<T>(fabrique)` | service partagé du contexte, créé au premier usage, libéré avec le contexte |

Un service partagé expose **un seul** accès statique qui passe sa propre fabrique : `DashboardService.From(context)`,
`WorkingScope.From(context)`. Deux modules obtiennent donc la même instance (l’Accueil et la session partagent le même
état des widgets et la même OU de travail).

### 3.3 bis Génération de session

`SessionSnapshot.Epoch` est la génération de connexion : elle change à chaque connexion de la session, même avec le même
compte et le même domaine (Domenia 1 `$script:DomeniaSessionEpoch`). Un service qui garde des données de session (l’atelier
de l’Assistance, TRV-185) les indexe sur domaine, compte **et** génération, et ignore la réponse d’une lecture commencée
dans une autre génération. La source simulée et la source indisponible gardent 0 pour toute la vie du processus ;
`Domenia.Ad` l’incrémentera à chaque connexion.

### 3.4 OU de travail

`WorkingScope` est l’OU de travail globale (décision du 21/10) : défaut de toutes les sections sans choix propre.
Un module lit `await WorkingScope.From(context).CurrentAsync(session, ct)` (ou `ApplyAsync(session, ct)` pour une
session complète). Elle est mémorisée **par domaine** et restaurée seulement pour son domaine et si l’OU existe encore
(`OPERATIONS.md` § 11).

## 4. Données de simulation d’un écran

Le générateur central (`SimulatedWorldGenerator`) ne change pas pour un nouvel écran. Les données propres à l’écran sont
**dérivées** du monde généré, dans le fichier de l’écran (`Screens/Simulated<Écran>Reader.cs`) :

1. ce qui existe déjà dans `source.World` (relevés, historique, session) se lit tel quel ; l’**annuaire** se lit par
   `source.CurrentDirectory`, qui applique les écritures de la session (surcouche en mémoire, [`WRITES.md`](WRITES.md)
   § 5), jamais par `source.World.Directory` ;
2. ce qui manque se tire d’un **sous-flux SplitMix64 nommé**, propre à l’écran :
   `var random = source.ScreenStream("accounts");` (graine de la session, puis `Fork("screen/accounts")`). Une
   sous-suite par sujet si besoin : `random.Fork("lockouts")`. Ajouter des tirages à un écran ne déplace donc ni
   l’annuaire, ni les autres écrans ;
3. les données dépendent seulement de la graine, de la date de référence et du fuseau (`source.World.Reference`,
   `source.World.TimeZone`) : jamais de `DateTime.Now`, de `System.Random` ni de la culture du poste ;
4. les effectifs sont exacts (mélange de Fisher-Yates parmi des candidats, jamais des tirages indépendants) et loin
   des seuils, comme dans `SIMULATION.md` § 4.1 ;
5. calcul une fois (`Lazy<…>` en `ExecutionAndPublication`) si l’annuaire ne change pas pendant la session ;
6. délai réaliste et annulable par `source.SimulateScreenLatencyAsync("<écran>", min, max, ct)` : sous-suite
   `latency/screen/<écran>/n`, séparée des délais de l’Accueil (qui gardent leur suite) ; aucun délai avec
   `SimulationLatency.None` (tests).

Exemple réel : `SimulatedDirectoryTreeReader` construit l’arbre une fois (`OrganizationalUnitTree.Build`, règle pure de
Core réutilisable avec la base locale), attend 60 à 160 ms par lecture du panneau (`latency/screen/tree`) et répond
tout de suite à `FindLocalAsync` (vérification d’un choix). Il sert deux interfaces : `IDirectoryTreeReader` (lectures du
panneau, réseau en mode annuaire, après un geste) et `IOrganizationalUnitIndex` (index local des OU, jamais le réseau),
seule interface que `WorkingScope` connaît : vérifier l’OU de travail au chargement de la page ne peut donc jamais lire
l’annuaire.

## 5. Préférences locales (`LocalWrite`)

- `IPreferenceStore` (Core) : document clé/valeur JSON. Les clés sont des noms pointés, le premier segment est l’écran
  propriétaire (`dashboard.disabledWidgets`, `session.workingScope.<SHA-256>`), 128 caractères au plus. Chaque écran ne
  lit et n’écrit que ses clés : aucune liste centrale.
- `FilePreferenceStore` (Store) : `%LOCALAPPDATA%\Domenia\preferences.json` en mode annuaire,
  `preferences-simulation.json` en simulation (jamais partagés). Lu au premier usage (hors du fil de l’interface) et gardé ;
  une lecture qui échoue (fichier verrouillé par un antivirus ou une sauvegarde, accès refusé) n’est **pas** gardée :
  valeurs par défaut pour l’instant, relecture au prochain usage, tracé une fois.
- Écriture : la valeur vaut d’abord en mémoire pour la session ; puis, sous un **verrou commun à tous les processus
  Domenia de la machine** (mutex nommé `Global\Domenia.Preferences.<empreinte du chemin>`, 5 s d’attente au plus), le
  document est **relu**, les changements de la session lui sont appliqués et il est réécrit **atomiquement** : fichier
  `preferences.json.<pid>.tmp` du même dossier, écrit en `WriteThrough` et vidé sur le disque, puis déplacé sur le
  document (`File.Move(..., overwrite: true)`). Deux instances ne s’effacent donc jamais leurs valeurs. Un document qu’on
  ne peut pas relire n’est **jamais remplacé** : l’écriture échoue (IOException), les changements restent en attente et
  partent avec l’écriture suivante.
  Format : `{ "format": "domenia.preferences", "version": 1, "values": { … } }`, clés triées, indenté.
- Document illisible (JSON invalide, format ou version inconnus, plus de 1 Mo) : rien n’est bloqué, c’est tracé, les
  valeurs partent vides et l’ancien document est **mis de côté** (`preferences.json.illisible`) avant d’être remplacé.
  Les clés inconnues mais bien formées sont conservées ; une clé mal formée du document (« .x ») est écartée sans
  erreur.
- Une écriture qui échoue (disque plein, droits) ne fait **jamais** échouer l’opération : la valeur vaut pour la session,
  le journal technique trace le type d’erreur et le journal des opérations affiche « Préférences non enregistrées : … »
  (ton `warn`).
- Mode capture : préférences en mémoire seulement (`MemoryPreferenceStore`) ; sans dossier `%LOCALAPPDATA%` absolu,
  idem.

## 6. VM partagée : compilation par lot

La VM Domenia (4 vCPU, 8 Go) sert toute l’équipe : chaque lot de travail a son dossier, et un seul lot à la fois
utilise la VM.

| Élément | Emplacement |
|---|---|
| Sources du lot | `C:\DomeniaDev\src\<lot>\v2` (miroir exact du dossier `v2/` qui contient le script, worktree compris ; `bin`, `obj`, `.vs` et `Domenia.sln` y restent) |
| Pack publié | `C:\DomeniaDev\out\<lot>\Domenia` (et `Domenia.zip` avec `--zip`) |
| Captures | `C:\DomeniaDev\captures\<lot>` |
| Rapports E2E | `C:\DomeniaDev\e2e\<lot>` ([`E2E.md`](E2E.md) § 7) |
| Historique (sans lot) | `C:\DomeniaDev\src\v2`, `C:\DomeniaDev\out\Domenia`, `C:\DomeniaDev\captures` |

Un **lot** est un nom en minuscules, chiffres et tirets (40 caractères au plus) : `accueil`, `plateforme`, `comptes-2`.
`cache` est réservé à `sync-vm.sh cache` ; `v2` et `domenia` sont réservés eux aussi, car ils se mêleraient aux dossiers
historiques (`C:\DomeniaDev\src\v2`, `C:\DomeniaDev\out\Domenia`, NTFS ignorant la casse) : `vm.sh`, `sync-vm.sh`,
`build-vm.ps1` et `capture-vm.ps1` les refusent.

**Toujours passer par `tools/vm.sh`** :

```bash
tools/vm.sh plateforme build                      # synchronisation + compilation Debug
tools/vm.sh plateforme build --config both        # Debug puis Release
tools/vm.sh plateforme publish --zip              # pack Release dans C:\DomeniaDev\out\plateforme
tools/vm.sh accueil capture --routes accueil,parametres --themes dark,light,contrast --out ~/captures/accueil
tools/vm.sh accueil capture --pack --out ~/captures/accueil-pack   # capture depuis le pack publié
tools/vm.sh accueil e2e --out ~/e2e/accueil      # scénarios E2E dans la session de bureau visible (E2E.md § 7)
tools/vm.sh plateforme test                       # tests : seulement à la toute fin (décision du 21/10)
```

- `vm.sh` prend un **verrou exclusif côté Mac** **avant** toute synchronisation et le rend à la sortie, même sur erreur
  ou interruption : un lien symbolique `/tmp/domenia-vm.lock` créé d’un seul geste avec son propriétaire pour cible
  (pid, machine, heure, lot, commande). Prendre le verrou et nommer son propriétaire sont donc une seule opération
  atomique. Un autre lot attend (message toutes les minutes, 1 h au plus par défaut) puis s’exécute ; un dossier du
  verrou absent ou non inscriptible est refusé tout de suite (jamais de boucle).
- Verrou mort : si le processus propriétaire n’existe plus sur ce Mac, ou si le verrou a plus de 2 h (60 s pour un
  propriétaire illisible, ancien format en dossier compris), il est retiré sous un second verrou de reprise
  (`/tmp/domenia-vm.lock.takeover`, même forme) après relecture : un seul des lots en attente le retire, un verrou vivant
  n’est jamais renommé ni retiré, et un retrait impossible retombe sur l’attente bornée.
- `capture` : synchronisation, compilation Release (ou publication avec `--pack`), capture en simulation avec
  l’exécutable qui vient d’être produit (`capture-vm.ps1 -Exe … -Clean`, dossier du lot vidé de ses anciennes images),
  puis copie des images et de `capture.log` dans `--out` s’il est donné.
- `e2e` : synchronisation, compilation (Release par défaut, ou pack avec `--pack`), scénarios de `tests/e2e`
  (`--scenarios motif`, `--mode simulation|annuaire`), puis copie du rapport dans `--out` s’il est donné
  ([`E2E.md`](E2E.md) § 7).
- `capture` et `e2e` s’exécutent dans la session de bureau du compte quand elle est ouverte (tâche planifiée ponctuelle
  de `tools/desktop-run.ps1`, retirée à la fin ; la session n’est jamais fermée), sinon directement par SSH
  (`CAPTURE.md` § 11) ; `DOMENIA_VM_SESSION=auto|direct|desktop` force le choix.
- Les commandes PowerShell partent en `-EncodedCommand` : aucune interprétation par `cmd.exe`, code de sortie conservé.
- `--no-sync` saute la synchronisation ; `DOMENIA_VM_DRY_RUN=1` prend le verrou et affiche les commandes sans rien
  envoyer (tests du verrou : `tests/tools/vm-lock-test.sh`).
- Variables : `DOMENIA_VM_HOST`, `DOMENIA_VM_LOCK`, `DOMENIA_VM_LOCK_WAIT`, `DOMENIA_VM_LOCK_STALE`,
  `DOMENIA_VM_SESSION`, `DOMENIA_VM_E2E_TIMEOUT`.

`tools/sync-vm.sh <lot>`, `tools/build-vm.ps1` et `tools/capture-vm.ps1` restent utilisables seuls (ils déduisent le
lot du dossier qui les contient), mais sans verrou : à réserver aux interventions manuelles.

Vérifié le 21 octobre 2026 dans la VM : deux lots différents (`plateforme`, puis un lot d’essai neuf) compilés l’un après
l’autre en Debug et en Release, 0 erreur et 0 avertissement chacun ; puis les deux lancés en même temps : le second a
affiché « VM occupée (… plateforme build), attente… » et n’a commencé qu’à la fin du premier. Un fichier présent
seulement dans la VM a disparu à la synchronisation suivante, `bin` et `Domenia.sln` sont restés. Publication du pack du
lot dans `C:\DomeniaDev\out\plateforme\Domenia` et captures rapatriées sur le Mac (`CAPTURE.md` § 11).

## 7. Cohérence du pack et contrôle avant lancement

La publication inscrit `DomeniaPackageManifest=required` dans l’assemblage et produit
`package-manifest.json` après la copie du runtime WebView2 local. Le manifeste contient les chemins relatifs,
tailles et SHA-256 de tous les fichiers livrés, y compris les runtimes .NET et WebView2. Il est borné à 2 Mio
et 4 096 fichiers (D2 embarque ses runtimes), sans chemin ambigu, redirection ni doublon. Une différence
d’octets est refusée, y compris les fins de ligne ; le pack ZIP ne nécessite aucune conversion de texte.
Une compilation de développement ordinaire reste identifiable et peut fonctionner sans manifeste ;
supprimer celui d’un exécutable publié ne désactive pas la vérification.

Avant toute composition de session, le programme refuse un marqueur `.update.pending` ou
`Support/.update.pending`, vérifie les fichiers et les composants indispensables, puis garde ouverts en
lecture partagée `.lifecycle.lock` et les fichiers contrôlés jusqu’à sa fermeture. Un outil de mise à jour
doit prendre ce verrou en exclusif avant de modifier le dossier. Les fichiers runtime supplémentaires
sont refusés ; seule la configuration opérateur `Domenia.config.json` reste modifiable. Préférences,
reçus et profils restent dans les emplacements de données prévus, hors du paquet.

`Domenia.exe --check-only` (alias `-CheckOnly`, option seule) vérifie un paquet sans fenêtre, profil ni
session annuaire ; sortie 0 si conforme, 2 sinon, diagnostic UTF-8 sur la sortie d’erreur. La publication
exécute ce contrôle local avant de créer le ZIP. Les échecs au démarrage normal sont également journalisés.
Ce contrôle établit la cohérence des fichiers ; le manifeste n’est pas signé et ne prouve pas l’identité
de l’éditeur. Les tests de refus et de verrouillage sont écrits ; leur qualification et celle du pack
réel restent dans la phase finale de validation en VM.

## 8. Livraison portable, reprise et désinstallation

Le parcours `Domenia.exe livraison` s’exécute depuis un **autre paquet vérifié**, indépendant de la cible. Il n’ouvre ni
fenêtre, profil, session annuaire ou base. La cible est un dossier local existant : vide pour une première installation,
ou contenant un paquet avec manifeste. DEV, chemins ambigus, liens et redirections sont refusés. Exemples PowerShell :

```powershell
& 'C:\Livraison\Domenia\Domenia.exe' livraison apercu 'C:\Applications\Domenia'
& 'C:\Livraison\Domenia\Domenia.exe' livraison appliquer 'C:\Applications\Domenia' '<Confirmation exacte de l’aperçu>'
```

L’aperçu JSON décrit fichiers remplacés, retirés, conservés, identités et avis de schéma. `Confirmation` est son SHA-256 ;
le moteur refait l’aperçu avant mutation et sous verrou exclusif. L’installateur prépare une copie et une sauvegarde du
code dans `.<nom-cible>.domenia-lifecycle`, dossier frère privé, puis relit leurs fichiers. Il conserve au plus quatre
transactions ; aucun effacement automatique des anciennes preuves. Le code est borné à 8 Gio, 4 096 composants,
manifeste de 2 Mio et profondeur 32. Le nom et les octets des outils PsExec facultatifs restent soumis à la politique
existante : les outils hors manifeste déjà installés sont conservés, ceux hors manifeste de la source ne sont pas copiés.

Sous `.lifecycle.lock` exclusif, le moteur écrit un journal durable puis `.update.pending`. Chaque copie neuve est relue,
l’ancien objet est retiré par son handle après comparaison, puis la copie est publiée sans écraser une entrée apparue
entre-temps. Un chemin peut être brièvement absent pendant cette phase ; le verrou et le marqueur interdisent tout
lancement. Le manifeste est remplacé en dernier. La vérification finale tient les fichiers jusqu’au retrait du marqueur,
seul point d’activation. Une interruption conserve préparation, sauvegarde, journal, copies temporaires et marqueur.

La reprise est une nouvelle demande explicite, depuis un paquet externe vérifié. L’identifiant de transaction est le nom
du sous-dossier conservé, également rendu dans le résultat. Une copie temporaire et un marqueur endommagé ne sont réparés
ou retirés que si leurs taille et empreinte correspondent au nouvel aperçu confirmé. Les octets étrangers restent en place.

```powershell
& 'C:\Livraison\Domenia\Domenia.exe' livraison apercu-reprise 'C:\Applications\Domenia' '<transaction>'
& 'C:\Livraison\Domenia\Domenia.exe' livraison reprendre 'C:\Applications\Domenia' '<transaction>' '<Confirmation>'
& 'C:\Livraison\Domenia\Domenia.exe' livraison apercu-restauration 'C:\Applications\Domenia' '<transaction>'
& 'C:\Livraison\Domenia\Domenia.exe' livraison restaurer 'C:\Applications\Domenia' '<transaction>' '<Confirmation>'
```

La restauration porte exclusivement sur le code sauvegardé, y compris après une mise à jour terminée. Avant le journal
et le marqueur, une interruption peut laisser une préparation partielle mais la version active n’a pas changé : conserver
ou archiver explicitement ce dossier de preuve, sans le présenter comme une sauvegarde complète. Aucun journal incomplet
ne déclenche une reprise. Le marqueur historique `Support/.update.pending` n’est jamais effacé par ce parcours v2.

La désinstallation emploie `apercu-desinstallation <cible>`, puis `desinstaller <cible> <Confirmation>`. Elle ne retire que
les objets ouverts dont les octets correspondent encore au manifeste. Fichiers modifiés, configuration, données, profils,
coffre Windows et sauvegardes sont conservés. Aucun répertoire n’est supprimé récursivement. `.lifecycle.lock` reste comme
métadonnée annoncée : le supprimer par chemin après fermeture risquerait de retirer une autre entrée. Une désinstallation
interrompue utilise `apercu-reprise`/`reprendre` ; elle ne propose pas de restauration automatique d’un code modifié.

La publication injecte une identité déterministe issue des sources `src/`, `web/`, propriétés de build, version du SDK
local et octets du runtime WebView2 sélectionné. Plusieurs runtimes dans le cache font refuser la publication. Cette même
identité alimente le titre, les journaux, À propos et les rapports via `ProductInfo.Version` ; le développement conserve
`2.0.0-dev`. `package-release.json` contient version, build et schéma déclaré, est inclus au manifeste, et son identité est
comparée à celle compilée avant lancement. Un même build avec d’autres octets est refusé à la mise à jour. Le tri ordinal
et le mappage des chemins de compilation évitent les dépendances à la locale et au nom du dossier de capture.

Le manifeste reste au format 1. Les anciens paquets sans métadonnées ont un schéma **inconnu**, sans avis de migration
supposé. Une augmentation annoncée ne fait qu’avertir : l’application garde la responsabilité de sauvegarder et migrer
ses données au démarrage. Un schéma déclaré inférieur est refusé hors restauration explicite. Le parcours de livraison
ne lit ni ne modifie SQLite. Le rapport `Domenia.delivery.json` lie identité, SHA du manifeste et SHA du ZIP publié.

Ces contrôles établissent l’intégrité et la cohérence. Aucune empreinte de certificat éditeur n’est provisionnée dans ce
lot : la confiance Authenticode reste **non établie**, distincte des SHA-256. Aucun service, installateur système,
association Windows ou téléchargement n’est ajouté. La compilation, la publication et la recette du parcours restent
des validations distinctes ; les tests de ce parcours sont écrits, leur exécution appartient à la campagne finale VM.

### Reprise L19 — disponibilité et cycle de vie (01/11/2026)

Le routeur vérifie les modules déclarés et leurs styles avant usage, puis signale le premier rendu terminé et calme.
Les imports locaux des autres pages se suivent après ce jalon ; aucun provider n’est invoqué. L’inventaire DOM critique
précède les interactions. Le suivi après intégrité est réglable dans Startup, sans fenêtre blanche derrière le login.
La fermeture clôt les nouveaux envois avant sa relecture et conserve la propriété des services jusqu’à la fin réelle des
handlers, reprises détachées et baux physiques ; elle borne seulement son attente. Voir [L19](reprise/LOTS-CODEX-20261101/L19.md).
