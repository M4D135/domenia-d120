# Écran Opérations — contrat, comportement et mode annuaire

Écran `#/operations` (« Opérations », section Outils) : le journal des opérations de la session. Il rassemble les **reçus
d’écriture** du circuit (avec leur relecture et leur revue manuelle), les **tâches** en cours et terminées (avec leurs étapes,
leur fin et la suite possible), le **journal** de la session, la **santé du moteur**, les **statistiques**, les **relevés** des
postes et le **diagnostic**. Lecture seule par défaut ; chaque écriture laisse un reçu écrit avant l’envoi puis relu ; **tant
qu’un reçu attend sa vérification ou sa revue, toutes les nouvelles écritures restent bloquées** (Domenia 1
`Assert-WriteAllowed`, OPE-025, OPE-026) ; **rien n’est jamais rejoué automatiquement**.

- Module du pont : `src/Domenia.Bridge/Operations/OperationsOperations.cs` (écran `operations`), documents :
  `OperationsExports.cs` (dossier injecté, `DefaultFolder` pour l’application), suivi de toutes les opérations :
  `src/Domenia.Bridge/OperationTracking.cs`.
- Contrôles de l’annuaire en mode annuaire : `src/Domenia.Ad/Checks/AdDirectoryChecks.cs` (`IDirectoryChecks`, § 8).
- Règles pures et modèles : `src/Domenia.Core/Screens/Operations/` (`ActivityRules`, `OperationActivity`, `ReceiptReviews`,
  `WriteKindRules`, `LifecyclePlans`, `OperationsDiagnostics`, `IOperationsReader`, modèles).
- Simulation : `src/Domenia.Simulation/Screens/Operations/SimulatedOperationsReader.cs`.
- Page : `web/js/pages/operations.js` et `web/js/pages/operations/*.js` (dont `pulse.js`, battement de toute l’interface),
  styles `web/css/pages/operations.css` ; aperçu dans un navigateur : `web/js/mock-operations.js` (branché par `mock.js`).
- Tests écrits (exécutés à la fin, décision du 21/10) : `tests/Domenia.Tests/OperationsRulesTests.cs`,
  `OperationsOperationsTests.cs`, `PlatformTests.cs` (registre) ; scénarios E2E : `tests/e2e/operations/*.json`.

## 1. Fonctions de Domenia 1 couvertes

| Id | Fonction | Dans Domenia 2 |
|---|---|---|
| OPE-001 | Indicateurs de collecte | `operations.health.collection` : par classe de demande (actions explicites, lectures automatiques, écritures, sélection, promotions), départ immédiat sans file pour les lectures, attente mesurée du canal d’écriture, sources en reprise, profil de collecte ; lectures partagées et WMI évitées attendent l’ordonnanceur (§ 11) |
| OPE-002 | Statistiques des opérations | `operations.stats` : une ligne par opération du pont (session et sessions précédentes), moyenne, médiane, 95e centile, par élément, **réseau estimé** (taille des réponses des lectures distantes et des écritures), **débit**, **% de repli**, **tentatives distantes**, réussite, dernière ; export CSV |
| OPE-003 | Pourquoi une action est indisponible ? | `operations.blockers` : lecture seule, reçus non confirmés, reçus à vérifier (blocage global), écriture en cours, sans sélection, boutons clés, boutons LAPS et BitLocker, identité des lectures de secrets, OU de travail, transports ; une route par ligne ; rien n’est testé |
| OPE-004 | Diagnostic expurgé | `operations.diagnostic.preview` puis `.save` : format `Domenia.Diagnostic.3` sur liste blanche, aperçu de ce qu’il contient et ne contient jamais, confirmation, aucun envoi |
| OPE-005 | Santé du moteur | onglet Santé : mémoire, réactivité de la page en courbe glissante, temps de réponse par catégorie avec histogramme, lenteurs, enregistrement local, sources (amélioration demandée : graphiques) |
| OPE-006 | État du moteur | `operations.engine` : versions, .NET, système, mémoire, mode, lecture seule, état d’écriture, reçus, préférences, tâches actives en une phrase chacune avec leur référence |
| OPE-007 | Vérification de l’application | `operations.check.run` (rapide, complète) : moteur, sécurité, stockage, exécuteurs, annuaire (simulation : annuaire fictif ; mode annuaire : `AdDirectoryChecks`, § 8), outils Windows et **contrôles de la page écrits par le moteur** (mêmes chiffres partout) ; copie et export du rapport |
| OPE-008 | Export du diagnostic ZIP | `operations.dossier.save` : `runtime.json`, `configuration-expurgee.json`, `verification.csv`, `LISEZMOI.txt`, sans journaux bruts ; pseudonymes de **tous** les noms (identité et nom d’utilisateur Windows, poste, compte, domaine, contrôleur), dossiers du profil écrits `%USERPROFILE%` et `%LOCALAPPDATA%`, exemples d’objets de l’annuaire omis |
| OPE-009 | Postconditions | `WriteKindRules` : la relecture qui prouve chaque type d’écriture, affichée dans le détail du reçu et dans « Règles du circuit » ; la relecture suit chaque écriture (amélioration demandée, déjà faite par le circuit) |
| OPE-010 | Compensation limitée et honnête | `WriteKindRules.Assess` : proposée seulement pour un type compensable, appliqué et vérifié ; changements lus à l’envers et confirmés, puis fiche ouverte avec `compenser=<reçu>` (nouvelle écriture : plan relu, confirmation, reçu, relecture) |
| OPE-011 | Plans de cycle de vie | `LifecyclePlans` : Arrivée, Changement de service, Suspension ; une étape incertaine bloque la suite, jamais rejouée ; disponibilité de chaque étape dans ce mode |
| OPE-012 | Dernières opérations | grille « Dernières opérations » : 64 tâches, demandes de l’opérateur et lectures automatiques qui finissent mal ; une lecture qui rend un reçu reste une lecture ; filtres par état et type, recherche par référence (amélioration demandée) |
| OPE-013 | Copier le détail | copie masquée, avec l’avertissement « le nom d’une cible peut y figurer » |
| OPE-014 | Ouvrir le journal | onglet Journal (`onglet=journal`) : journal de la session et journal de la source, filtres, copie, export ; Ctrl L et le centre des opérations relèvent de l’écran shell (§ 11) |
| OPE-015 | Panneau des opérations en cours | section « En cours » (type, état, durée vivante, phases et compteurs d’un lot, détail, accès requis, 64 au plus) et `operations.center` pour le panneau déroulant de la barre supérieure (écran shell, § 11) |
| OPE-016 | Arrêter une lecture | bouton « Arrêter » et touche Suppr ; droit revérifié sur la vraie tâche (`operations.task.stop`) ; jamais une écriture |
| OPE-017 | Lots de collecte visibles | phases du lot (Préparation, Lecture AD, À confirmer, En cours, Enregistrement) et compteurs (non confirmés, erreurs de ping, en cours, enregistrements en attente, non relus faute de capacité) dans la tâche et dans Relevés |
| OPE-018 | États exacts d’annulation | En cours, Arrêt demandé, Terminée ; textes fixes (« La lecture est encore active », « non annulable après envoi ») |
| OPE-019 | Étapes détaillées | panneau d’une tâche : demande, attente du canal d’écriture, étapes publiées (ou traitement dans le moteur), publication dans l’interface (dite non mesurée), fin ; total, volume et étape dominante à part ; suite possible ; mis à jour en place |
| OPE-020 | Conseil après la fin | `ActivityRules.Advice` : jamais de relance automatique, référence du journal technique |
| OPE-021 | Résumé des tâches et ressources | « 2 en cours · 1 arrêt demandé », jetons d’arrêt détenus |
| OPE-022 | Liste des reçus | onglet Reçus : à vérifier d’abord, phrase de synthèse, actualisation automatique (15 s) et à la demande, filtres par état, export CSV (amélioration demandée) |
| OPE-023 | Vérifier un reçu par relecture | « Relire l’objet… » après confirmation : `write.receipts.verify`, seule une lecture part ; proposée pour tout type dont l’exécuteur est servi (amélioration demandée) |
| OPE-024 | Revue manuelle | `operations.receipts.review` : motif de 12 à 240 caractères, jamais un secret, compteur et motifs fréquents (amélioration demandée) ; « Revue manuelle », jamais un succès |
| OPE-025 | Levée de l’incertitude | un reçu à vérifier bloque **toutes** les nouvelles écritures (`write.receiptsPending`, sa propre cible : `write.targetPending`) jusqu’à une relecture conclusive ou une revue ; jamais levée par le temps ; levée tracée en WARN et dans le journal ; carte « Circuit d’écriture » |
| OPE-026 | Opérations à vérifier | pastille « N opérations à vérifier » (jamais « 0 opération »), aide de Domenia 1, reçu le plus ancien au survol (`pill.oldest`) dans l’en-tête de l’écran, la tuile, l’onglet et `operations.center` ; la pastille de la barre supérieure relève de l’écran shell (§ 11) |
| OPE-027 | Relevé en cours | carte « Relevé en cours » avec son arrêt |
| OPE-028 | Derniers relevés par OU | grille : date, OU, type, état, postes lus, dernière réussite, motif ; filtres par type et état (amélioration demandée) |
| OPE-029 | Reprise d’un relevé interrompu | bandeau en tête de l’écran jusqu’à « Plus tard » (proposé une fois par session), et toujours dans Relevés : Reprendre après confirmation, Abandonner, Plus tard |
| OPE-030 | Réactivité de l’interface | battement d’une seconde de **toute l’interface**, continu une fois démarré (`pulse.js`) : p50, p95, maximum, courbe graduée et seuil (amélioration demandée) |
| OPE-031 | Temps de réponse par catégorie | **six catégories** de Domenia 1 (recherche locale, traitement des résultats dans l’interface, autres lectures et écritures locales, annuaire, collecte sur les postes, écritures), 512 mesures, 95e centile à partir de 20, recalcul seulement si une série a bougé, histogramme gradué (amélioration demandée) |
| OPE-032 | Attente de verrou SQLite | règle, phrase et compteur (`OperationActivity.RecordSqliteBusy`, nombre et heure de la dernière) ; la base locale n’existe pas encore (§ 11) |
| OPE-033 | Enregistrement local en une phrase | `PersistenceLabel` : reçus et préférences, échecs de la session, dernière écriture locale |
| OPE-034 | Lenteurs expliquées | 16 dernières : opérations de plus de 5 s (phase dominante, volume) et traitements de l’interface de plus de 120 ms |
| OPE-035 | Blocages attribués | battement en retard de 400 ms ou plus attribué au travail suivi de l’interface qui le chevauche (affichage d’un écran, d’un onglet, d’une liste, d’un panneau), sinon « non attribué » ; une tâche longue du navigateur n’est jamais une cause ; une ligne dans Domenia.log toutes les 5 s au plus |
| OPE-036 | Sources suspendues | `ProviderLines` : postes regroupés par fournisseur et état, sites et fournisseurs entiers ; les sources saines ne sont pas listées |

## 2. Récapitulatif des opérations

| Opération | Classe | Arguments | Résultat |
|---|---|---|---|
| `operations.overview` | `LocalRead` | aucun | tête de l’écran : reçus, pastille (avec le reçu le plus ancien), tâches, mesures de la session comptées comme la grille par défaut (`hiddenAutomatic` à part), écritures servies |
| `operations.receipts` | `LocalRead` | aucun | la liste du circuit (`write.receipts.list`) pour l’écran, **jamais suivie** (actualisations de fond) |
| `operations.center` | `LocalRead` | aucun | `{ at, pill, receiptsReadable, writeState, writeTone, summary, open, attention, note }` : pour le panneau de la barre supérieure (écran shell) |
| `operations.interface.report` | `Local` | `{ renders: [{ work, ms }] (64 au plus), stall: { lateMs, work, workMs, longTaskMs } \| null }` ; `work` ∈ `ecran`, `onglet`, `actualisation`, `liste`, `panneau` | `{ kept, logged }` |
| `operations.activity` | `Local` | aucun | tâches en cours, 64 dernières, résumé (§ 3) |
| `operations.task.stop` | `Local` | `{ id }` (32 hexadécimaux, ou `batch:<lot>`) | la tâche après la demande (arrêt demandé) |
| `operations.receipts.detail` | `LocalRead` | `{ id }` | `{ receipt, rule, compensation, actions, executorAvailable }` |
| `operations.receipts.review` | `LocalWrite` | `{ id, reason }` | même forme, reçu « Revue manuelle » |
| `operations.rules` | `Local` | aucun | `{ kinds, lifecycles, note }` |
| `operations.health` | `LocalRead` | aucun | santé du moteur (§ 6) |
| `operations.engine` | `LocalRead` | aucun | état du moteur (lit les reçus et la session) |
| `operations.stats` | `LocalRead` | aucun | statistiques par opération |
| `operations.journal` | `LocalRead` | aucun | journal de la session et de la source |
| `operations.runs` | `LocalRead` | aucun | relevés, lot en cours, relevé interrompu |
| `operations.survey.resume` | `NetworkRead` (servie en simulation) | `{ remaining }` (1 à 100 000) | le lot repris |
| `operations.survey.stop` | `Local` | aucun | le lot après la demande d’arrêt, ou `null` |
| `operations.survey.forget` | `LocalWrite` | aucun | l’offre après abandon |
| `operations.survey.postpone` | `Local` | aucun | l’offre, marquée proposée pour la session |
| `operations.blockers` | `LocalRead` | aucun | `{ at, lines, transports, note }` |
| `operations.check.run` | `NetworkRead` (servie en simulation) | `{ full, page? }`, `page` = `{ strictPolicy, structure, structureTotal, motion, webView }` (valeurs fermées) | rapport de vérification, contrôles de la page compris |
| `operations.diagnostic.preview` | `LocalRead` | `{ webView?, theme?, interfaceP50Ms?, interfaceP95Ms?, interfaceSamples? }` | `{ format, json, preview, bytes, sha256, at }` |
| `operations.diagnostic.save` | `LocalWrite` | mêmes arguments | `ExportResult` |
| `operations.dossier.save` | `LocalWrite` | `{ anonymize, webView? }` | `ExportResult` |
| `operations.export.save` | `LocalWrite` | `{ subject, csv }` (`recus`, `operations`, `statistiques`, `releves`, `verification`, `journal`) | `ExportResult` |

Aucune opération de classe `Write` : la seule porte d’écriture reste `write.execute`. Les lectures de reçus restent celles du
circuit (`write.receipts.list`, `write.receipts.get`, `write.receipts.verify`, `OPERATIONS.md` § 12).

Champs nuls toujours écrits ; dates ISO UTC à la seconde ; durées en millisecondes (nombres) accompagnées de leur texte
français (`durationText`) ; tons `ok|warn|alert|info|off`.

### 2.1 Tâche (`ActivityRow`)

`id` (32 hexadécimaux, ou `batch:<lot>`), `reference` (8 caractères, cherchés dans le journal technique), `operation`, `screen`,
`label` (libellé court), `kind` (`local|localRead|networkRead|localWrite|write|batch`), `kindLabel`, `foreground`, `listed`,
`state` (`running|stopRequested|completed`), `stateLabel`, `tone`, `icon`, `outcome` (`succeeded|superseded|withdrawn|stopped|
timedOut|refused|failed|unknown` ou `null` tant qu’elle tourne), `outcomeLabel`, `startedAt`, `endedAt`, `durationMs`,
`durationText`, `dominantLabel`, `dominantMs`, `volume`, `volumeText`, `canStop`, `stopReason`, `detail`, `access`, `advice`,
`category` (code de fin, jamais un message), `text` (chaîne des étapes), `dropped`, `phases` (`phase`, `label`, `atMs`,
`durationMs`, `durationText`, `measured`, `detail`, `outcome`) dans l’ordre `request`, `queue`, `step`… (ou `work` sans étapes
publiées), `publish` (non mesurée), `end` — le total est `durationMs`, jamais une phase —, `next` (suite possible), `progress`
(lot : `done`, `total`, `failed`, `phase`, `header`, `counters`, `pingErrors`, `inFlight`, `pendingSaves`, `skipped`, `steps` :
`{ phase, label, state }` avec `state` = `done|current|todo`).

## 3. Suivi des opérations

Toutes les opérations du registre sont suivies, une fois, à la construction du registre (`OperationTracking.Track`, appelé par
`OperationModules.CreateRegistry`) : même gestionnaire, mêmes arguments, même réponse, mêmes exceptions. Le suivi ne garde que le
nom de l’opération, sa classe, ses étapes, sa durée, son volume (compté sans rien énumérer) et sa fin.

- **Arrêt** : une lecture (`Local`, `LocalRead`, `NetworkRead`) reçoit une annulation propre, liée à la durée de vie de
  l’application ; « Arrêter » la lève. L’état devient « Arrêt demandé » jusqu’à la fin réelle (« Arrêtée » si elle finit par
  annulation). Une écriture (`LocalWrite`, `Write`) garde la durée de vie de l’application : jamais arrêtée.
- **Fin** : réponse → « Terminée » ; seul le reçu de `write.execute` dit la vraie fin d’une écriture : à vérifier → « Résultat
  inconnu », non appliquée → « Échec », écart → « Résultat inconnu », sinon « Terminée ». Une lecture qui rend un reçu
  (`write.receipts.get`, `write.receipts.verify`, même sur un reçu encore à vérifier) reste une lecture terminée, avec son libellé. `DomeniaOperationException` → « Refusée avant
  envoi » (ou « Échec » pour un code `…Failed`), `arguments.invalid` → « Refusée », annulation → « Arrêtée », toute autre
  exception → « Échec » (`operation.failed`).
- **Étapes** : les événements publiés par l’opération (les trois étapes de `write.execute`) sont enregistrés puis transmis à la
  page sans changement. Le temps entre la demande et la première étape d’une écriture est l’attente du canal d’écriture et les
  contrôles du plan (compté une seule fois dans les lenteurs).
- **Mesures** : chaque fin non arrêtée ajoute une mesure à la catégorie de l’opération (`ActivityRules.CategoryOf`) et à sa
  classe (demande de l’opérateur ou lecture automatique) ; une lecture distante ou une écriture garde aussi le volume reçu estimé
  (taille de sa réponse dans le JSON du contrat, comptée sans garder le texte) et une tentative distante en mode annuaire (jamais
  de nouvelle tentative, aucun transport de repli dans Domenia 2 ; aucune en simulation).
- **Liste** : demandes de l’opérateur (lecture réseau, écritures, plans) toujours ; lectures automatiques seulement si elles
  finissent mal (délai, refus, échec, inconnu). 64 tâches au plus ; un anneau plein retire d’abord les lectures automatiques
  terminées, puis les demandes terminées, une tâche ouverte en dernier recours.
- **Journal technique** : une fin non réussie écrit `Opération <nom> [<référence>] : <issue> (<code>).` ; un arrêt et une
  lenteur sont tracés de même. Jamais d’argument, de résultat, de nom ni de message.
- Les lectures `Local` et `LocalRead` de l’écran Opérations ne sont pas suivies (elles le rafraîchissent toutes les quelques
  secondes) : c’est pourquoi l’écran lit ses reçus par `operations.receipts`, jamais par `write.receipts.list` ; ses écritures
  locales et ses lectures réseau le sont.
- Rafraîchissements de la page : activité toutes les 2 s, tête et reçus toutes les 15 s, santé toutes les 5 s (onglet ouvert),
  relevés toutes les 10 s ou 1,5 s pendant un lot. Ces lectures de fond passent par le pont sans le compteur de la page (ni
  ligne d’activité clignotante, ni signal de capture retenu) ; les premières lectures, elles, sont comptées.

## 4. Reçus d’écriture

- **Blocage global** (Domenia 1 `Assert-WriteAllowed`, `Get-DomeniaReceiptSummary` : « a pending receipt holds every new write
  of the domain back ») : tant qu’un reçu est à vérifier, `WriteCircuit` refuse tout nouveau plan et toute exécution
  (`write.receiptsPending` ; `write.targetPending` pour sa propre cible) ; la relecture et la revue restent possibles. La dernière
  incertitude levée écrit « Incertitude levée uniquement après vérification ou revue explicite des reçus durables » (WARN) et
  « Écritures de nouveau admises » dans le journal des opérations.
- Liste : `operations.receipts` (à vérifier d’abord, puis du plus récent au plus ancien). Grille du kit (état, opération,
  objet, dernière version ; compte, contrôleur, résultat, relecture, mode, DN et reçu dans « Colonnes »), filtres par état,
  détail à côté (vue maître-détail redimensionnable ; la grille garde sa hauteur, le détail sa hauteur naturelle : un seul
  défilement, celui de la page), export CSV. « Relire l’objet… » du menu est grisé, avec sa raison, quand le type n’est pas servi.
- `?recu=<id>` (lien du toast du circuit, `web/js/write-flow.js`) ouvre ce reçu ; `?filtre=a-verifier` (ou `verifier`, lien du
  shell) ne montre que les reçus à vérifier.
- Détail (`operations.receipts.detail`) : médaille au ton du reçu, résultat, relecture, phrase (dite une fois : l’erreur d’un
  reçu à vérifier n’est pas répétée, son code va dans les faits ; un refus garde sa raison, au ton du reçu), **preuve attendue**
  (`rule`), changements du plan, étapes du reçu, faits, **compensation** (`compensation`), plan exécuté replié.
- **Relire l’objet** : confirmation (« Seule une lecture part : l’écriture n’est jamais renvoyée »), puis
  `write.receipts.verify`. Proposée quand l’exécuteur du type est servi dans ce mode.
- **Revue manuelle** (`operations.receipts.review`, `WriteCircuit.ReviewAsync`) : seulement pour un reçu à vérifier, dont le
  détail est relu d’abord (les motifs fréquents nomment son contrôleur, jamais un exemple) ; motif de
  12 à 240 caractères une fois rogné, refusé s’il ressemble à un secret (`ReceiptReviews.Mask` : clé de récupération
  BitLocker, `Bearer`/`Basic`, membres JSON et formes `clé=valeur` ou `clé : valeur` de mots de passe, secrets, jetons, clés,
  commutateurs `-p`, `/p`) ; nouvelle version du reçu, `verification` = `reviewed` (« Revue manuelle », ton `info`, jamais un
  succès), motif cité dans les détails avec le compte de la session, journal des opérations ; le motif ne va jamais au journal
  technique. Une relecture ultérieure qui ne prouve rien garde la revue ; une relecture conclusive la remplace. Erreurs :
  `receipt.reviewInvalid` (« Motif de la revue : … »), `receipt.resolved` (« Ce reçu est déjà résolu : il ne bloque plus aucune
  écriture et n’est pas modifié. »), `receipt.unknown`, `receipt.unavailable`.
- **Compensation** : jamais pour mot de passe, suppression, création d’OU, déverrouillage, renommage ni action à distance ;
  refusée tant que l’issue n’est pas vérifiée par relecture, après une revue manuelle, sans changement appliqué ou après un
  écart. Sinon proposée : les changements du plan lus à l’envers, confirmés, puis la fiche s’ouvre avec `compenser=<reçu>` pour
  préparer la nouvelle écriture (plan relu sur le contrôleur, confirmation, reçu, relecture). Jamais automatique.
- **Règles du circuit** (`operations.rules`) : la relecture de chaque type d’écriture (servi ou à venir), les compensations,
  les séquences de cycle de vie (Arrivée, Changement de service, Suspension) avec la disponibilité de chaque étape.

## 5. Documents

- Dossier `%LOCALAPPDATA%\Domenia\Exports` (`Exports-simulation` en simulation, jamais partagés), seulement quand les reçus du
  mode sont sur le disque ; en mode capture, E2E ou sans dossier de données, rien n’est écrit (« Document préparé, non écrit ») et
  l’empreinte est rendue.
- Noms datés jamais remplacés : `Domenia-<Sujet>-AAAAMMJJ-HHmmss.csv` (UTF-8 avec BOM, cellules neutralisées par la grille,
  texte masqué une fois de plus), `Domenia-Diagnostic-…json`, `Domenia-Dossier-…zip` ; un nom pris reçoit `-2`, `-3`… Fichier
  temporaire du même dossier écrit en `WriteThrough` puis renommé ; un lien à la place du dossier est refusé. 4 Mo au plus.
- Diagnostic `Domenia.Diagnostic.3` : versions (forme de version seulement), compteurs (nombres, booléens), mesures par
  opération **du registre**, codes d’erreur (forme `a.b`), 64 traces par référence courte, 16 lenteurs. Jamais : nom, message,
  DN, adresse, chemin, contenu de journal, secret.
- Dossier ZIP : `runtime.json`, `configuration-expurgee.json`, `verification.csv` (dernière vérification de la session, contrôles
  de la page compris), `LISEZMOI.txt`. Avec les pseudonymes : identité du processus et nom d’utilisateur Windows (`identite-1`…),
  poste (`poste-1`), compte, seul ou avec son domaine (`compte-1`), domaine, NetBIOS, racine, contrôleur, remplacés en mots
  entiers dans tous les fichiers ; dossiers du profil écrits `%USERPROFILE%` et `%LOCALAPPDATA%` ; détails libres des contrôles de
  l’annuaire (exemples d’utilisateur, de poste, de groupe) omis et la mention le dit (`OperationsDiagnostics.Dossier`, `LocalIdentity`).

## 6. Santé et diagnostic

- Catégories (`OperationActivity.Categories`, Domenia 1 `Get-DomeniaResponseTimeCategories`) : recherche locale, traitement des
  résultats dans l’interface (mesures de la page), autres lectures et écritures locales, lectures de l’annuaire, collecte sur les
  postes (relevés, ping, WMI, écran Poste), écritures dans l’annuaire et actions sur les postes. Une mesure n’est jamais comptée
  deux fois ; les résumés ne sont recalculés que si une série a bougé. Histogramme gradué : ≤ 10, 50, 100, 250, 500 ms, 1 s, 5 s,
  au-delà, avec le nombre de mesures au-dessus de chaque barre.
- Réactivité (`pulse.js`) : battement d’une seconde de toute l’interface, continu dès le premier affichage d’Opérations (ou dès
  le démarrage si le shell le lance), 240 échantillons ; courbe avec son échelle (0, moitié, haut arrondi), l’axe du temps et le
  seuil de 400 ms nommé sur sa ligne ; une phrase sous la courbe pendant qu’elle se remplit, jamais une boîte vide.
- Travail suivi de l’interface : affichage d’un écran (changement d’adresse jusqu’à la première image après le changement du
  contenu), d’un onglet, actualisation, rendu d’une liste, ouverture d’un panneau ; envoyé au moteur toutes les 5 s
  (`operations.interface.report`, codes fermés) : catégorie « Traitement des résultats dans l’interface », lenteur au-delà de
  120 ms, attribution d’un blocage, une ligne dans Domenia.log toutes les 5 s au plus. Une tâche longue vue par le navigateur
  est comptée et dite, jamais prise pour une cause.
- Enregistrement local : stockage indisponible (capture, E2E) → « En mémoire uniquement » ; échecs comptés dans le journal des
  opérations (« Préférences non enregistrées », « Reçu d’écriture non enregistré ») ; dernière écriture locale réussie. Base
  locale : compteur des attentes de verrou SQLite dépassées (nombre, heure de la dernière, délai borné de 100 à 5 000 ms).
- « Pourquoi une action est indisponible ? » : mode, lecture seule, reçus non confirmés, reçus à vérifier (toutes les écritures
  bloquées, route vers le filtre), écriture en cours, reçus en mémoire, OU de travail absente (route vers le choix de l’OU), actions
  d’un objet sans sélection (route vers Rechercher), boutons clés dont l’écriture n’est pas servie, boutons LAPS et BitLocker,
  identité des lectures de secrets (compte de la session) ; transports utilisés ou laissés éteints.
- Vérification : moteur (.NET, 64 bits, mémoire, opérations du registre), sécurité (une seule écriture déclarée :
  `write.execute`, gardes d’admission, vérification non destructive), stockage (reçus, préférences, dossier des documents sans y
  écrire), exécuteurs du mode, annuaire (lecteur de l’écran en simulation, `AdDirectoryChecks` en mode annuaire), outils Windows
  (`mstsc.exe`, `eventvwr.exe`, `compmgmt.msc`) et page (politique de sécurité du contenu, structure, animations, moteur web),
  ces dernières lignes écrites par le moteur à partir des faits fermés que la page transmet : rapport, toast, journal et dossier
  comptent les mêmes lignes. WAPT est abandonné (décision du 22/10, PST-001).
- Rapport : en pleine largeur sous les cartes, groupes en colonnes, aucun défilement imbriqué ; les cartes du diagnostic sont
  alignées en haut.

## 7. Simulation

Données dérivées du monde généré (sous-flux `screen/operations`), sans réseau ni disque :

- Relevés : lecture des objets de `OU=Postes` (−12 min), ping et WMI des cinq sites, aux dates et effectifs du journal fictif
  quand il les cite (Paris 158/186, Lyon 74/82, Marseille sondes refusées pour 3 postes…), postes actifs réels de chaque OU.
- Relevé interrompu : inventaire WMI de l’OU Bordeaux (21 postes lus sur 36, interrompu il y a 2 h 10). « Reprendre » lit les
  15 postes restants en mémoire : préparation (600 ms), lecture AD (450 ms), puis 350 à 900 ms par poste, un poste sans réponse
  WMI et un poste sans réponse au ping (comptés à part), enregistrement, arrêt possible ; aucun poste n’est laissé faute de
  capacité. Un arrêt garde les mesures et repropose le reste.
- Sources : les trois sondes toujours en erreur du modèle de présence, en reprise progressive WMI.
- Statistiques : 14 jours ouvrés d’historique fictif par opération du pont ; taille des réponses des lectures distantes et des
  écritures tirée d’un sous-flux à part (`sizes`) ; aucune tentative distante en simulation.
- Vérification : session, lecture de la base, recherches utilisateur, machine et groupe, arborescence (annuaire fictif) ;
  droits non simulés ; recherches répétées en vérification complète.
- Délais : `latency/screen/operations/<lecture>` (20 à 260 ms), aucun avec `SimulationLatency.None`.

## 8. Mode annuaire

Sans lecteur `IOperationsReader` pour la source réelle, relevés, sources et historique disent « non branché dans cette version
(vague 3) » ; reçus, tâches, journal, santé, statistiques de la session, documents et diagnostic fonctionnent. Les **contrôles de
l’annuaire** de la vérification sont servis dès maintenant par `AdDirectoryChecks` (`Domenia.Ad`, interface `IDirectoryChecks`,
trouvé tout seul pour une source `ActiveDirectory`) selon le tableau ci-dessous ; un `AdOperationsReader` à venir passera devant.

| Lecture | Source | Détail |
|---|---|---|
| `RunsAsync` | base locale SQLite (`domenia_domain_metadata`, comme Domenia 1) | une ligne par famille (`Directory`, `Presence`, `Inventory`) et `RequestKey` (`subtree:<dn>`, `<dn>`) : `LastAttemptAtUtc`, `Status`, `Error` (200 caractères), `LastSuccessAtUtc`, `Data`/`AttemptData` (`Done`, `Targets`, `Failed`, `ScopeDn`) ; enregistrement sans date lisible écarté ; `SQLITE_BUSY` compté (OPE-032) |
| `CurrentSurvey`, `StopSurvey` | campagne de `Domenia.Inventory` en mémoire | compteurs scalaires seulement (jamais la liste des cibles) |
| `ResumeSurveyAsync` | fichier de plan de campagne du domaine et de la base (comme `Read-DomeniaCampaignProgressFile`) | même domaine, même base, aucune autre campagne ; confirmation du nombre exact (`operations.surveyChanged` sinon) ; lit seulement les postes restants, par l’ordonnanceur (budgets de `Domenia.Inventory` : ping puis WMI DCOM `Win32_OperatingSystem`, `Win32_LogicalDisk` `DriveType=3`, `Win32_ComputerSystem`, 5 s par poste, 8 en parallèle au plus) |
| `ForgetSurveyAsync` | même fichier | supprimé atomiquement ; mesures validées gardées |
| `ProviderStatesAsync` | ordonnanceur de `Domenia.Engine` | par fournisseur (`Directory`, `Cim`, `Wts`, `Network`, `Storage`) et cible (`group:<site>` ou poste) : bloqué (identifiants rejetés), en pause (`BackoffUntilUtc`), reprise progressive (`RecoveryLimit`) |
| `HistoryAsync` | base locale (`OperationStats`, rétention 365 jours) | échantillons `(opération, date, durée, éléments, réussite)` |
| `CheckDirectoryAsync` | contrôleur de la session, compte de la session | voir ci-dessous |

Contrôles de l’annuaire (OPE-007, `AdDirectoryChecks`), en lecture seule, sur le contrôleur de la session (ou celui que donne le
localisateur du domaine), avec la session Windows (Kerberos signé et chiffré), sans nouvelle tentative, 10 s par lecture, hors du
fil de l’interface ; aucun nom d’objet n’est écrit dans le rapport (seulement des nombres, le contrôleur et la base) ; une erreur
est dite par une raison fixe selon son code (serveur injoignable, identifiants refusés, accès refusé, objet ou domaine
introuvable), jamais par le message du système :

| Test | Requête |
|---|---|
| Liaison RootDSE | `LDAP://<dc>/RootDSE`, attribut `defaultNamingContext` (vide = erreur) |
| Lecture de la base | base `<defaultNamingContext>`, portée `Base`, attributs `distinguishedName`, `objectClass` |
| Recherche utilisateur | `(&(objectCategory=person)(objectClass=user))`, `Subtree`, attribut `name`, `SizeLimit` 1 |
| Recherche machine | `(objectCategory=computer)`, `Subtree`, `name`, `SizeLimit` 1 |
| Recherche groupe | `(objectCategory=group)`, `Subtree`, `name`, `SizeLimit` 1 |
| Arborescence | `(|(objectClass=organizationalUnit)(objectClass=container))`, `OneLevel`, `name`, `SizeLimit` 5 |
| Droits de la base | `nTSecurityDescriptor` de la base avec `SecurityMasks = Dacl` (contrôle LDAP SD flags), nombre d’ACE |
| Recherches répétées (complète) | 3 × `(|(&(objectCategory=person)(objectClass=user))(objectCategory=computer))`, `Subtree`, `name`, `SizeLimit` 25, durée de chacune |

Relecture d’un reçu (`write.receipts.verify`) : la `VerifyAsync` de l’exécuteur du type, sur le contrôleur qui a reçu
l’écriture, attributs de la table de `WriteKindRules` (`lockoutTime`, `userAccountControl`, `pwdLastSet` comparé à l’heure
d’envoi avec 120 s de marge, `accountExpires`, parent relu par `objectGUID`, `member` direct, présence ou absence par GUID) ; un
attribut absent de la réponse est « non relu », jamais « vide » ; un refus de lecture ne prouve rien ; relecture sur un autre
contrôleur signalée (réplication).

Budgets : ces lectures partent seulement après un geste (bouton, confirmation), une à la fois par objet, jamais tout le domaine ;
aucune donnée d’annuaire n’entre dans le journal technique.

## 9. Codes d’erreur propres

| Code | Message |
|---|---|
| `operations.taskUnknown` | Tâche introuvable ou déjà terminée : rien n’a été arrêté. |
| `operations.taskNotStoppable` | Texte fixe de l’annulation (« Écriture « … » : non annulable après envoi. Attente de la relecture de vérification. ») |
| `operations.surveyBusy` | Un relevé est déjà en cours : la reprise attendra sa fin. Rien n’a été lu. |
| `operations.surveyNone` | Aucun relevé interrompu à reprendre : rien n’a été lu. |
| `operations.surveyChanged` | Le relevé interrompu a changé depuis son affichage : relisez-le avant de le reprendre. Rien n’a été lu. |
| `operations.exportFailed` | Document non enregistré : <raison>. Rien n’a été remplacé. |
| `operations.exportTooLarge` | Document trop volumineux (plus de 4 Mo) : rien n’a été écrit. |
| `receipt.reviewInvalid` | Motif de la revue : <raison>. |
| `receipt.resolved` | Ce reçu est déjà résolu : il ne bloque plus aucune écriture et n’est pas modifié. |

Plus les codes communs (`arguments.invalid`, `source.unavailable`, `receipt.unknown`, `receipt.unavailable`) et ceux du circuit
que l’écran explique (`write.receiptsPending` : une opération reste à vérifier, toutes les nouvelles écritures sont bloquées ;
`write.targetPending`).

## 10. Page

- En-tête complet au premier affichage de la session : titre, phrase, puces (mode, reçus sur le disque ou en mémoire, écritures
  servies, tâches en direct), actions (« Actualiser », « Pourquoi une action est indisponible ? », « Vérifier l’application »),
  carte « Circuit d’écriture » (au repos, écritures bloquées, reçus illisibles) avec l’aide de Domenia 1, le reçu le plus ancien
  et les cinq temps. **En-tête compact** (environ 150 px) aux affichages suivants, quand l’adresse vise un onglet, ou dès qu’un
  onglet ou une tuile est utilisé ; bouton pour le déplier ou le replier, choix gardé pour la session (`sessionStorage`).
- Bandeau du relevé interrompu (jusqu’à « Plus tard », une fois par session), quatre tuiles (reçus à vérifier, tâches en cours,
  opérations de la session comptées comme la grille par défaut, réactivité de toute l’interface), plus serrées avec l’en-tête
  compact ; onglets (choix mémorisé et gardé dans l’adresse ; la pastille de l’onglet des reçus n’affiche jamais « 0 »).
- Paramètres : `onglet`, `recu`, `filtre=a-verifier` (ou `verifier`), `tache`, `exemple=1` (données locales d’exemple pour les
  captures et l’aperçu : rien n’est lu ni envoyé), `ouvrir=revue|tache|apercu|verification` (états ouverts des captures ; la
  vérification ne part qu’en simulation).
- Tâches : le panneau d’une tâche est mis à jour en place (redessiné seulement si la tâche change, sans rejouer ses entrées, focus
  et défilement gardés ; la durée d’une tâche en cours avance seule) ; textes longs des grilles sur deux lignes, texte entier en
  infobulle.
- Animations : entrées en cascade, médaille et orbite du circuit, barres et histogrammes qui montent, courbe vivante, cascade des
  étapes, phases d’un lot ; transform, opacity et filter seulement ; boucles arrêtées en animations réduites ; cadres en
  contraste élevé (bouton grisé lisible : fond noir, texte blanc, cadre en tirets).

## 11. Reste à faire

- **Écran shell** (`app.js`, seul à le modifier) : brancher la pastille « opérations à vérifier » de la barre supérieure et le
  panneau déroulant des opérations en cours sur `operations.center` (pastille, aide, reçu le plus ancien au survol, tâches en
  cours avec durée vivante, arrêt d’une lecture par `operations.task.stop`, Échap et clic à côté pour fermer) ; envoyer Ctrl L
  vers `operations?onglet=journal` (profil expert) ; démarrer le battement de toute l’interface au démarrage
  (`import { startPulse } from './pages/operations/pulse.js'; startPulse();`) ; le lien « Vérifier les reçus » du panneau peut
  garder `filtre=verifier` (accepté).
- **Écran Fiche** : lire `compenser=<reçu>` (`operations.receipts.detail` puis `compensation.changes`) pour pré-remplir le plan
  inverse ; jusque-là la fiche s’ouvre sur l’objet et la confirmation d’Opérations rappelle les changements inverses.
- Lectures identiques partagées et requêtes WMI évitées (OPE-001), compteur SQLite alimenté (OPE-032) : avec l’ordonnanceur
  (`Domenia.Engine`), la collecte (`Domenia.Inventory`) et la base locale (`Domenia.Store`, qui appellera
  `OperationActivity.RecordSqliteBusy`), vague 3.
- Publication dans l’interface mesurée par tâche (OPE-019) : demande un point d’accroche dans `bridge.js` (fichier partagé) ;
  dite « non mesurée » d’ici là.
- Séquences de cycle de vie exécutées étape par étape quand leurs écritures (groupes, attributs, déplacement, activation) seront
  servies ; lecteur `AdOperationsReader` (vague 3) selon le § 8.
