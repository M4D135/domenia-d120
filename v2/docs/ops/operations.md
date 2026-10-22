# Écran Opérations — contrat, comportement et mode annuaire

Écran `#/operations` (« Opérations », section Outils) : le journal des opérations de la session. Il rassemble les **reçus
d’écriture** du circuit (avec leur relecture et leur revue manuelle), les **tâches** en cours et terminées (avec leurs étapes,
leur fin et le conseil qui suit), le **journal** de la session, la **santé du moteur**, les **statistiques**, les **relevés** des
postes et le **diagnostic**. Lecture seule par défaut ; chaque écriture laisse un reçu écrit avant l’envoi puis relu ; **rien
n’est jamais rejoué automatiquement**.

- Module du pont : `src/Domenia.Bridge/Operations/OperationsOperations.cs` (écran `operations`), documents :
  `OperationsExports.cs`, suivi de toutes les opérations : `src/Domenia.Bridge/OperationTracking.cs`.
- Règles pures et modèles : `src/Domenia.Core/Screens/Operations/` (`ActivityRules`, `OperationActivity`, `ReceiptReviews`,
  `WriteKindRules`, `LifecyclePlans`, `OperationsDiagnostics`, `IOperationsReader`, modèles).
- Simulation : `src/Domenia.Simulation/Screens/Operations/SimulatedOperationsReader.cs`.
- Page : `web/js/pages/operations.js` et `web/js/pages/operations/*.js`, styles `web/css/pages/operations.css`.
- Tests écrits (exécutés à la fin, décision du 21/10) : `tests/Domenia.Tests/OperationsRulesTests.cs`,
  `OperationsOperationsTests.cs`, `PlatformTests.cs` (registre) ; scénarios E2E : `tests/e2e/operations/*.json`.

## 1. Fonctions de Domenia 1 couvertes

| Id | Fonction | Dans Domenia 2 |
|---|---|---|
| OPE-001 | Indicateurs de collecte | `operations.health.collection` : file d’attente (aucune pour les lectures, attente mesurée du canal d’écriture), sources en reprise, profil de collecte de la source ; files par classe, lectures partagées et WMI évitées attendent l’ordonnanceur (§ 11) |
| OPE-002 | Statistiques des opérations | `operations.stats` : une ligne par opération du pont (mesures de la session et des sessions précédentes), durée moyenne, médiane, 95e centile, par élément, réussite, dernière ; export CSV |
| OPE-003 | Pourquoi une action est indisponible ? | `operations.blockers` : faits de la session, un bouton de route par ligne, transports ; rien n’est testé (amélioration demandée : panneau dans la page) |
| OPE-004 | Diagnostic expurgé | `operations.diagnostic.preview` puis `.save` : format `Domenia.Diagnostic.3` sur liste blanche, aperçu de ce qu’il contient et ne contient jamais, confirmation, aucun envoi |
| OPE-005 | Santé du moteur | onglet Santé : mémoire, réactivité de la page en courbe glissante, temps de réponse par catégorie avec histogramme, lenteurs, enregistrement local, sources (amélioration demandée : graphiques) |
| OPE-006 | État du moteur | `operations.engine` : versions, .NET, système, mémoire, mode, lecture seule, état d’écriture, reçus, préférences, tâches actives en une phrase chacune avec leur référence |
| OPE-007 | Vérification de l’application | `operations.check.run` (rapide, complète) + contrôles de la page ; copie et export du rapport |
| OPE-008 | Export du diagnostic ZIP | `operations.dossier.save` : `runtime.json`, `configuration-expurgee.json`, `verification.csv`, `LISEZMOI.txt`, sans journaux bruts ; option pseudonymes (amélioration demandée) |
| OPE-009 | Postconditions | `WriteKindRules` : la relecture qui prouve chaque type d’écriture, affichée dans le détail du reçu et dans « Règles du circuit » ; la relecture suit chaque écriture (amélioration demandée, déjà faite par le circuit) |
| OPE-010 | Compensation limitée et honnête | `WriteKindRules.Assess` : proposée seulement pour un type compensable, appliqué et vérifié ; changements lus à l’envers, préparation dans la fiche comme une nouvelle écriture |
| OPE-011 | Plans de cycle de vie | `LifecyclePlans` : Arrivée, Changement de service, Suspension ; une étape incertaine bloque la suite, jamais rejouée ; disponibilité de chaque étape dans ce mode |
| OPE-012 | Dernières opérations | grille « Dernières opérations » : 64 tâches, demandes de l’opérateur et lectures automatiques qui finissent mal, filtres par état et type, recherche par référence (amélioration demandée) |
| OPE-013 | Copier le détail | copie masquée, avec l’avertissement « le nom d’une cible peut y figurer » |
| OPE-014 | Ouvrir le journal | onglet Journal : journal de la session et journal de la source, filtres, copie, export |
| OPE-015 | Panneau des opérations en cours | section « En cours » : type, état, durée vivante, détail, accès requis, 64 au plus |
| OPE-016 | Arrêter une lecture | bouton « Arrêter » et touche Suppr ; droit revérifié sur la vraie tâche (`operations.task.stop`) ; jamais une écriture |
| OPE-017 | Lots de collecte visibles | lot du relevé repris : phase, progression, compteurs |
| OPE-018 | États exacts d’annulation | En cours, Arrêt demandé, Terminée ; textes fixes (« La lecture est encore active », « non annulable après envoi ») |
| OPE-019 | Étapes détaillées | panneau d’une tâche : demande, attente du canal d’écriture, étapes publiées (relecture, envoi, relecture), traitement, fin ; cascade dessinée à l’échelle |
| OPE-020 | Conseil après la fin | `ActivityRules.Advice` : jamais de relance automatique, référence du journal technique |
| OPE-021 | Résumé des tâches et ressources | « 2 en cours · 1 arrêt demandé », jetons d’arrêt détenus |
| OPE-022 | Liste des reçus | onglet Reçus : à vérifier d’abord, phrase de synthèse, actualisation automatique (15 s) et à la demande, filtres par état, export CSV (amélioration demandée) |
| OPE-023 | Vérifier un reçu par relecture | « Relire l’objet… » après confirmation : `write.receipts.verify`, seule une lecture part ; proposée pour tout type dont l’exécuteur est servi (amélioration demandée) |
| OPE-024 | Revue manuelle | `operations.receipts.review` : motif de 12 à 240 caractères, jamais un secret, compteur et motifs fréquents (amélioration demandée) ; « Revue manuelle », jamais un succès |
| OPE-025 | Levée de l’incertitude | un reçu à vérifier bloque sa cible jusqu’à une relecture conclusive ou une revue ; jamais levée par le temps ; carte « Circuit d’écriture » de l’en-tête |
| OPE-026 | Opérations à vérifier | pastille « N opérations à vérifier » (jamais « 0 opération ») dans l’en-tête de l’écran, la tuile et l’onglet ; la pastille de la barre supérieure attend l’écran shell (§ 11) |
| OPE-027 | Relevé en cours | carte « Relevé en cours » avec son arrêt |
| OPE-028 | Derniers relevés par OU | grille : date, OU, type, état, postes lus, dernière réussite, motif ; filtres par type et état (amélioration demandée) |
| OPE-029 | Reprise d’un relevé interrompu | bandeau en tête de l’écran jusqu’à « Plus tard » (proposé une fois par session), et toujours dans Relevés : Reprendre après confirmation, Abandonner, Plus tard |
| OPE-030 | Réactivité de l’interface | battement d’une seconde de la page : p50, p95, maximum, courbe et seuil (amélioration demandée) |
| OPE-031 | Temps de réponse par catégorie | cinq catégories par classe d’opération, 512 mesures, 95e centile à partir de 20, histogramme (amélioration demandée) |
| OPE-032 | Attente de verrou SQLite | règle et phrase portées (`SqliteBusyTimeout`, `SqliteBusySummary`) ; la base locale n’existe pas encore (§ 11) |
| OPE-033 | Enregistrement local en une phrase | `PersistenceLabel` : reçus et préférences, échecs de la session, dernière écriture locale |
| OPE-034 | Lenteurs expliquées | 16 dernières opérations de plus de 5 s, phase dominante, volume |
| OPE-035 | Blocages attribués | battement en retard de 400 ms ou plus expliqué par le travail de l’écran qui le chevauche (une fois toutes les 5 s), sinon « non attribué » |
| OPE-036 | Sources suspendues | `ProviderLines` : postes regroupés par fournisseur et état, sites et fournisseurs entiers ; les sources saines ne sont pas listées |

## 2. Récapitulatif des opérations

| Opération | Classe | Arguments | Résultat |
|---|---|---|---|
| `operations.overview` | `LocalRead` | aucun | tête de l’écran : reçus, pastille, tâches, mesures de la session, écritures servies |
| `operations.activity` | `Local` | aucun | tâches en cours, 64 dernières, résumé (§ 3) |
| `operations.task.stop` | `Local` | `{ id }` (32 hexadécimaux, ou `batch:<lot>`) | la tâche après la demande (arrêt demandé) |
| `operations.receipts.detail` | `LocalRead` | `{ id }` | `{ receipt, rule, compensation, actions, executorAvailable }` |
| `operations.receipts.review` | `LocalWrite` | `{ id, reason }` | même forme, reçu « Revue manuelle » |
| `operations.rules` | `Local` | aucun | `{ kinds, lifecycles, note }` |
| `operations.health` | `LocalRead` | aucun | santé du moteur (§ 6) |
| `operations.engine` | `Local` | aucun | état du moteur |
| `operations.stats` | `LocalRead` | aucun | statistiques par opération |
| `operations.journal` | `LocalRead` | aucun | journal de la session et de la source |
| `operations.runs` | `LocalRead` | aucun | relevés, lot en cours, relevé interrompu |
| `operations.survey.resume` | `NetworkRead` (servie en simulation) | `{ remaining }` (1 à 100 000) | le lot repris |
| `operations.survey.stop` | `Local` | aucun | le lot après la demande d’arrêt, ou `null` |
| `operations.survey.forget` | `LocalWrite` | aucun | l’offre après abandon |
| `operations.survey.postpone` | `Local` | aucun | l’offre, marquée proposée pour la session |
| `operations.blockers` | `LocalRead` | aucun | `{ at, lines, transports, note }` |
| `operations.check.run` | `NetworkRead` (servie en simulation) | `{ full }` | rapport de vérification |
| `operations.diagnostic.preview` | `Local` | `{ webView?, theme?, interfaceP50Ms?, interfaceP95Ms?, interfaceSamples? }` | `{ format, json, preview, bytes, sha256, at }` |
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
`durationMs`, `durationText`, `measured`, `detail`, `outcome`), `progress` (lot : `done`, `total`, `failed`, `phase`, `header`,
`counters`).

## 3. Suivi des opérations

Toutes les opérations du registre sont suivies, une fois, à la construction du registre (`OperationTracking.Track`, appelé par
`OperationModules.CreateRegistry`) : même gestionnaire, mêmes arguments, même réponse, mêmes exceptions. Le suivi ne garde que le
nom de l’opération, sa classe, ses étapes, sa durée, son volume (compté sans rien énumérer) et sa fin.

- **Arrêt** : une lecture (`Local`, `LocalRead`, `NetworkRead`) reçoit une annulation propre, liée à la durée de vie de
  l’application ; « Arrêter » la lève. L’état devient « Arrêt demandé » jusqu’à la fin réelle (« Arrêtée » si elle finit par
  annulation). Une écriture (`LocalWrite`, `Write`) garde la durée de vie de l’application : jamais arrêtée.
- **Fin** : réponse → « Terminée » ; un reçu (`write.execute`) dit la vraie fin : à vérifier → « Résultat inconnu », non
  appliquée → « Échec », écart → « Résultat inconnu », sinon « Terminée ». `DomeniaOperationException` → « Refusée avant
  envoi » (ou « Échec » pour un code `…Failed`), `arguments.invalid` → « Refusée », annulation → « Arrêtée », toute autre
  exception → « Échec » (`operation.failed`).
- **Étapes** : les événements publiés par l’opération (les trois étapes de `write.execute`) sont enregistrés puis transmis à la
  page sans changement. Le temps entre la demande et la première étape d’une écriture est l’attente du canal d’écriture et les
  contrôles du plan.
- **Liste** : demandes de l’opérateur (lecture réseau, écritures, plans) toujours ; lectures automatiques seulement si elles
  finissent mal (délai, refus, échec, inconnu). 64 tâches au plus ; un anneau plein retire d’abord les lectures automatiques
  terminées, puis les demandes terminées, une tâche ouverte en dernier recours.
- **Journal technique** : une fin non réussie écrit `Opération <nom> [<référence>] : <issue> (<code>).` ; un arrêt et une
  lenteur sont tracés de même. Jamais d’argument, de résultat, de nom ni de message.
- Les lectures `Local` et `LocalRead` de l’écran Opérations ne sont pas suivies (elles le rafraîchissent toutes les quelques
  secondes) ; ses écritures locales et ses lectures réseau le sont.
- Rafraîchissements de la page : activité toutes les 2 s, tête et reçus toutes les 15 s, santé toutes les 5 s (onglet ouvert),
  relevés toutes les 10 s ou 1,5 s pendant un lot. Ces lectures de fond passent par le pont sans le compteur de la page (ni
  ligne d’activité clignotante, ni signal de capture retenu) ; les premières lectures, elles, sont comptées.

## 4. Reçus d’écriture

- Liste : `write.receipts.list` (à vérifier d’abord, puis du plus récent au plus ancien). Grille du kit (état, opération,
  objet, dernière version ; compte, contrôleur, résultat, relecture, mode, DN et reçu dans « Colonnes »), filtres par état,
  détail à côté (vue maître-détail redimensionnable), export CSV.
- `?recu=<id>` (lien du toast du circuit, `web/js/write-flow.js`) ouvre ce reçu ; `?filtre=a-verifier` ne montre que les reçus à
  vérifier.
- Détail (`operations.receipts.detail`) : médaille au ton du reçu, résultat, relecture, phrase, erreur, **preuve attendue**
  (`rule`), changements du plan, étapes du reçu, faits, **compensation** (`compensation`), plan exécuté replié.
- **Relire l’objet** : confirmation (« Seule une lecture part : l’écriture n’est jamais renvoyée »), puis
  `write.receipts.verify`. Proposée quand l’exécuteur du type est servi dans ce mode.
- **Revue manuelle** (`operations.receipts.review`, `WriteCircuit.ReviewAsync`) : seulement pour un reçu à vérifier ; motif de
  12 à 240 caractères une fois rogné, refusé s’il ressemble à un secret (`ReceiptReviews.Mask` : clé de récupération
  BitLocker, `Bearer`/`Basic`, membres JSON et formes `clé=valeur` ou `clé : valeur` de mots de passe, secrets, jetons, clés,
  commutateurs `-p`, `/p`) ; nouvelle version du reçu, `verification` = `reviewed` (« Revue manuelle », ton `info`, jamais un
  succès), motif cité dans les détails avec le compte de la session, journal des opérations ; le motif ne va jamais au journal
  technique. Une relecture ultérieure qui ne prouve rien garde la revue ; une relecture conclusive la remplace. Erreurs :
  `receipt.reviewInvalid` (« Motif de la revue : … »), `receipt.resolved` (« Ce reçu est déjà résolu : il ne bloque plus aucune
  écriture et n’est pas modifié. »), `receipt.unknown`, `receipt.unavailable`.
- **Compensation** : jamais pour mot de passe, suppression, création d’OU, déverrouillage, renommage ni action à distance ;
  refusée tant que l’issue n’est pas vérifiée par relecture, après une revue manuelle, sans changement appliqué ou après un
  écart. Sinon proposée : les changements du plan lus à l’envers, préparés depuis la fiche de l’objet comme une nouvelle
  écriture (plan relu sur le contrôleur, confirmation, reçu, relecture). Jamais automatique.
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
- Dossier ZIP : `runtime.json`, `configuration-expurgee.json`, `verification.csv` (dernière vérification de la session),
  `LISEZMOI.txt` ; pseudonymes stables (`compte-1`, `domaine-1`, `controleur-1`, `poste-1`…) dans tous les fichiers si demandé.

## 6. Santé et diagnostic

- Catégories (`OperationActivity.Categories`) : calcul local, lectures locales, lectures de l’annuaire (et des postes), écritures
  locales, écritures dans l’annuaire. Une mesure n’est jamais comptée deux fois. Histogramme : ≤ 10, 50, 100, 250, 500 ms, 1 s,
  5 s, au-delà.
- Réactivité (page) : battement d’une seconde, 240 échantillons ; `PerformanceObserver` des tâches longues du navigateur.
- Enregistrement local : stockage indisponible (capture, E2E) → « En mémoire uniquement » ; échecs comptés dans le journal des
  opérations (« Préférences non enregistrées », « Reçu d’écriture non enregistré ») ; dernière écriture locale réussie.
- « Pourquoi une action est indisponible ? » : mode, lecture seule, reçus illisibles, reçus à vérifier (route vers le filtre),
  écriture en cours, reçus en mémoire, OU de travail absente (route vers le choix de l’OU), LAPS et BitLocker non servis ;
  transports utilisés ou laissés éteints.
- Vérification : moteur (.NET, 64 bits, mémoire, opérations du registre), sécurité (une seule écriture déclarée :
  `write.execute`, gardes d’admission, vérification non destructive), stockage (reçus, préférences, dossier des documents sans y
  écrire), exécuteurs du mode, annuaire (lecteur de l’écran), outils Windows (`mstsc.exe`, `eventvwr.exe`, `compmgmt.msc`),
  WAPT ; la page ajoute sa politique de sécurité du contenu, sa structure, ses animations et la version du moteur web.

## 7. Simulation

Données dérivées du monde généré (sous-flux `screen/operations`), sans réseau ni disque :

- Relevés : lecture des objets de `OU=Postes` (−12 min), ping et WMI des cinq sites, aux dates et effectifs du journal fictif
  quand il les cite (Paris 158/186, Lyon 74/82, Marseille sondes refusées pour 3 postes…), postes actifs réels de chaque OU.
- Relevé interrompu : inventaire WMI de l’OU Bordeaux (21 postes lus sur 36, interrompu il y a 2 h 10). « Reprendre » lit les
  15 postes restants en mémoire (350 à 900 ms par poste, un poste sans réponse WMI), avec préparation, enregistrement et arrêt ;
  un arrêt garde les mesures et repropose le reste.
- Sources : les trois sondes toujours en erreur du modèle de présence, en reprise progressive WMI.
- Statistiques : 14 jours ouvrés d’historique fictif par opération du pont.
- Vérification : session, lecture de la base, recherches utilisateur, machine et groupe, arborescence (annuaire fictif) ;
  droits non simulés ; recherches répétées en vérification complète.
- Délais : `latency/screen/operations/<lecture>` (20 à 260 ms), aucun avec `SimulationLatency.None`.

## 8. Mode annuaire

Sans `Domenia.Ad`, `IOperationsReader` n’a pas de lecteur : relevés, sources, historique et contrôles d’annuaire disent « non
branché dans cette version (vague 3) » ; reçus, tâches, journal, santé, statistiques de la session, documents et diagnostic
fonctionnent. La vague 3 fournira `AdOperationsReader(<source AD>)`, trouvé tout seul.

| Lecture | Source | Détail |
|---|---|---|
| `RunsAsync` | base locale SQLite (`domenia_domain_metadata`, comme Domenia 1) | une ligne par famille (`Directory`, `Presence`, `Inventory`) et `RequestKey` (`subtree:<dn>`, `<dn>`) : `LastAttemptAtUtc`, `Status`, `Error` (200 caractères), `LastSuccessAtUtc`, `Data`/`AttemptData` (`Done`, `Targets`, `Failed`, `ScopeDn`) ; enregistrement sans date lisible écarté ; `SQLITE_BUSY` compté (OPE-032) |
| `CurrentSurvey`, `StopSurvey` | campagne de `Domenia.Inventory` en mémoire | compteurs scalaires seulement (jamais la liste des cibles) |
| `ResumeSurveyAsync` | fichier de plan de campagne du domaine et de la base (comme `Read-DomeniaCampaignProgressFile`) | même domaine, même base, aucune autre campagne ; confirmation du nombre exact (`operations.surveyChanged` sinon) ; lit seulement les postes restants, par l’ordonnanceur (budgets de `Domenia.Inventory` : ping puis WMI DCOM `Win32_OperatingSystem`, `Win32_LogicalDisk` `DriveType=3`, `Win32_ComputerSystem`, 5 s par poste, 8 en parallèle au plus) |
| `ForgetSurveyAsync` | même fichier | supprimé atomiquement ; mesures validées gardées |
| `ProviderStatesAsync` | ordonnanceur de `Domenia.Engine` | par fournisseur (`Directory`, `Cim`, `Wts`, `Network`, `Storage`) et cible (`group:<site>` ou poste) : bloqué (identifiants rejetés), en pause (`BackoffUntilUtc`), reprise progressive (`RecoveryLimit`) |
| `HistoryAsync` | base locale (`OperationStats`, rétention 365 jours) | échantillons `(opération, date, durée, éléments, réussite)` |
| `CheckDirectoryAsync` | contrôleur de la session, compte de la session | voir ci-dessous |

Contrôles de l’annuaire (OPE-007), en lecture seule, sur le contrôleur de la session, sans nouvelle tentative, 10 s par lecture :

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

Plus les codes communs (`arguments.invalid`, `source.unavailable`, `receipt.unknown`, `receipt.unavailable`).

## 10. Page

- En-tête : titre, phrase, puces (mode, reçus sur le disque ou en mémoire, écritures servies, tâches en direct), actions
  (« Actualiser », « Pourquoi une action est indisponible ? », « Vérifier l’application »), carte « Circuit d’écriture » (au repos,
  à vérifier, bloqué) avec ses cinq temps.
- Bandeau du relevé interrompu (jusqu’à « Plus tard », une fois par session), quatre tuiles (reçus à vérifier, tâches en cours, opérations de la
  session, réactivité), onglets (choix mémorisé et gardé dans l’adresse).
- Paramètres : `onglet`, `recu`, `filtre=a-verifier`, `tache`, `exemple=1` (données locales d’exemple pour les captures et
  l’aperçu : rien n’est lu ni envoyé), `ouvrir=revue|tache|apercu|verification` (états ouverts des captures ; la vérification
  ne part qu’en simulation).
- Animations : entrées en cascade, médaille et orbite du circuit, barres et histogrammes qui montent, courbe vivante, cascade des
  étapes ; transform, opacity et filter seulement ; boucles arrêtées en animations réduites ; cadres en contraste élevé.

## 11. Reste à faire

- Pastille « opérations à vérifier » de la barre supérieure et bouton du centre des opérations : `app.js` (écran shell) ; l’écran
  expose `operations.overview.pill` pour elle (demande au kit et au shell).
- Files d’attente par classe, lectures partagées et requêtes WMI évitées (OPE-001), attentes de verrou SQLite (OPE-032) : avec
  l’ordonnanceur (`Domenia.Engine`), la collecte (`Domenia.Inventory`) et la base locale (`Domenia.Store`), vague 3.
- Compensation pré-remplie dans la fiche (paramètre de route à convenir avec l’écran Fiche) ; séquences de cycle de vie
  exécutées étape par étape quand leurs écritures (groupes, attributs, déplacement, activation) seront servies.
- Lecteur `AdOperationsReader` (vague 3) selon le § 8.
