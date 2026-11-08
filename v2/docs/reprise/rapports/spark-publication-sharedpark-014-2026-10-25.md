# SPARK-READY-014 — quatre brouillons SharedPark achevés, tests écrits, rien d'exécuté

Le lot013/FIX1–FIX3 est clos et compilé069 (Debug/Release 0 avertissement / 0 erreur, 44 s, journal `build-codex-team-069.log`). Ce lot014 reprend **uniquement** les quatre brouillons non compilés du protocole SharedPark déjà présents dans le dépôt, sur les sources jointes (`FULLSPARK014-SOURCES.txt`) et les références ciblées du dépôt. Aucun inventaire général, aucun socle 006–012B réécrit, aucun build, aucun test exécuté, aucun téléchargement, aucun service/runtime/réseau, aucun accès AD ni partage réel, `dev/` en lecture seule, WAPT exclu, aucun autre agent/modèle/fournisseur, aucun `commit`/`push`/`reset`/`clean`.

## Fichiers réellement touchés (les quatre du périmètre, plus ce rapport)

Après édition (SHA-256) :

| Fichier | SHA-256 | Lignes |
|---|---|---|
| `v2/src/Domenia.Store/Sqlite/DomeniaDatabase.SharedPark.Apply.cs` | `41af1a976987851016a5e1dee50831aebd940bdc31a6346a3066307814eef5b1` | 244 |
| `v2/src/Domenia.Store/Sqlite/DomeniaDatabase.SharedPark.Verify.cs` | `b604031abbdb0700d9a649280ac0655abe9f09b54841e6cf16d9259e1db03ef3` | 153 |
| `v2/src/Domenia.Store/Sqlite/SharedParkPublicationFile.cs` | `f0a947932d33623b04aba9e5b9baea7f397d6ff09b25cfac49f6f786af53937d` | 284 |
| `v2/tests/Domenia.Tests/SharedParkApplyTests.cs` | `0a27d234dee6e4a483ee596c967d1dea2de5c9a4f443218aaf38c746a5dfd3e7` | 373 |
| `v2/docs/reprise/SPARK-READY-014.md` (ce rapport) | — | — |

Aucun autre fichier n'a été ouvert en écriture. Le wrapper `CompatibleDirectoryCache.SharedPark.cs`, les WIP natifs, les dispositions Poste/Logiciels et l'ordonnanceur sont **intacts** (vérifiés non modifiés). Le baseline complet reste la référence de Codex (`fullspark014-baseline.json`, hors dépôt).

## 1. Formulation trompeuse corrigée dans `DraftSharedPark` (demande explicite du mandat)

L'état attesté à tort est supprimé. Le brouillon annonçait, dès l'aperçu, `SyncStoreChange.BackedUp("Copies initiales vérifiées et intention durable conservées.")` — or à l'aperçu **aucune copie n'existe et aucune intention n'est écrite**. Trois corrections :

- **Réversibilité** (`Apply.cs:35-36`) : plus aucun `BackedUp(...)` (dont le libellé partagé « Point de retour : sauvegarde vérifiée » affirmait une sauvegarde déjà vérifiée). Un `WriteReversibility` explicite annonce désormais le **protocole prévu** : « Rien n'est encore créé à l'aperçu : l'exécution confirmée écrira d'abord les copies physiques vérifiées du fichier partagé et de la base, puis l'intention durable relue à l'identique, avant toute tentative de publication. Le reçu SQLite ne sera commis que dans la même transaction que les relevés locaux. » Le `Label` dit « copies et intention que le protocole **s'engage à créer** ».
- **Autres états trompeurs vérifiés dans les quatre brouillons** :
  - `WriteChange[0]` « Aperçu confirmé » → « Lot d'aperçu lié » : l'aperçu n'est pas confirmé, c'est le plan qui le sera ;
  - `WriteChange[1]` affichait le chemin du TSV comme **valeur avant** (`Before = batch.Path`) alors que le fichier peut être absent → `Before` vaut `batch.Path` seulement si `batch.RemoteExists`, sinon `null` ;
  - `WriteChange[2]` « Contenu lié à l'aperçu » → « Contenu relu du spool de l'aperçu » (le spool est bien relu et revérifié à l'exécution) ;
  - **troisième risque ajouté** : « Le verrou partagé n'écarte que les consoles coopérantes : un écrivain qui l'ignore reste possible. Toute ambiguïté après la tentative est annoncée incertaine, jamais comme un succès. » — le mandat exige de ne pas prétendre empêcher universellement un écrivain hors verrou ;
  - le `Summary` dit maintenant que les observations externes sont conservées « à part, sous leur propre clé » (cohérent avec `shared:<poste>`).
  - Ces trois champs (`Label`, `Before`, `After`) sont **hors empreinte** : `WritePlans.ComputeFingerprint` ne couvre que `attribute/kind/beforeValue/afterValue/referenceGuid`. Les plans déjà scellés et `ValidateSharedParkPlan` (qui ne teste que `AfterValue`/`BeforeValue`/`Kind`/`ReferenceGuid`) restent valides : **aucun plan existant n'est invalidé**.
  - Vérifiés et reconnus exacts, donc laissés tels quels : les deux messages `Applied`/`Unknown` de l'apply, les quatre messages de `VerifySharedParkConfirmedAsync`, tous les messages d'exception de `SharedParkPublicationFile`.

## 2. Contrats réellement composés (lecture des quatre fichiers ensemble)

- **Confirmation explicite liée** : `DraftSharedPark` lie le plan au lot (`head.Id`, `head.Sha256 = SharedParkIdentity.Fingerprint(batch)` qui couvre session, époque, chemins, SHA distant/proposé, compteurs), au spool (`PayloadBytes` + `ProposedSha256` dans l'empreinte du lot), au magasin/domaine (`Target.Dn = SyncLocalIdentity.Target(StoreId, DomainDn)`), aux chemins (`Changes[1].AfterValue`) et à l'expiration (`plan.ExpiresAt`, revérifiée `current: true` à trois frontières). Le `Reason` de confirmation nomme explicitement ces liens.
- **Caller sous verrou de source, `validateSource` réellement rappelé** : sept appels effectifs (`Apply.cs:65, 83, 85, 104, 112, 115, 139`) aux transitions réelles, plus `ValidateSharedParkPlan(current: true)` à quatre d'entre elles. Un `Action` vide ne prouve rien : le test `A_source_gate_change_after_intention_prevents_publication` le vérifie en la faisant échouer, et `A_confirmed_publication…` exige `SourceChecks >= 5`.
- **Sauvegardes physiques vérifiées puis intention durable relue AVANT toute publication** : `CreateSharedParkBackupsAsync` (012B) → `OpenSharedParkEvidence` (relit `initial.db` et `initial.tsv` sous DACL privée, compare longueur + SHA) → `journal.CreateAsync` → **relecture** `journal.ReadAsync(...) != intent` refusée → seulement ensuite `SharedParkFile.LockAsync` (D1).
- **Verrou D1 + identité physique SQLite + transaction** : `SharedParkFile.LockAsync` (12 essais, jamais un verrou périmé volé), `SharedParkBackupFiles.Open` + `PinSqliteSource` (inœud et ancêtres tenus), `new SqliteDatabase(Path, false)` puis `db.Begin()` (`BEGIN IMMEDIATE`) et `PRAGMA synchronous=FULL`.
- **CAS local logique, y compris changements D1 sans révision** : `MatchSharedParkBackupLocal` compare `Exists/Legacy/StoreId/DomainDn/Revision/Generation/RowsFingerprint/LocalFingerprint` (la génération de réinitialisation est donc comparée **même sans incrément de révision**), puis `StorageWriteSnapshot.Read(db) != copies.SqliteLogicalFingerprint`. Deuxième relecture locale juste avant publication (`Apply.cs:105`).
- **CAS TSV du contenu effectivement observé + second contrôle juste avant publication** : `MatchSharedParkBackupRemote` (chemin, `Exists`, SHA) à deux reprises (`Apply.cs:96` et `106`), puis `SharedParkPublicationFile.CheckBefore` à l'entrée du constructeur **et** à l'entrée de `Publish` : identité physique `(volume, index high/low)` + SHA relu, `Links == 1`, reparse/répertoire refusés.
- **Temporaire frère privé/exclusif, Flush puis remplacement atomique** : `FileMode.CreateNew` + `FileShare.None` + `FileOptions.WriteThrough`, `output.Flush(flushToDisk: true)`, relecture du temporaire (SHA et longueur) avant `File.Replace(stage, target, previous)` ou `File.Move(stage, target, overwrite: false)`.
- **Ancien fichier effectivement déplacé conservé et comparé** : `previous.tsv` dans le dossier de preuve créé **exclusivement** sous DACL privée (`CreatePrivateDirectory` + `RequirePrivate` revérifié avant et après), réouvert après le remplacement et comparé à l'identité et au SHA confirmés ; le contenu publié est relu (`published.Identity == staged.Identity && published.Sha256 == proposedSha`).
- **SMB + SQLite jamais une transaction** : `Attempted = true` est posé **avant** le remplacement ; toute exception après tentative tombe dans `catch (Exception) when (publication?.Attempted == true)` → `WriteResult.Unknown`, intention, copies, temporaire et fichier déplacé **conservés**. Aucune compensation, aucune restauration, aucun rejeu automatique nulle part dans les quatre fichiers.
- **Observations externes = observations, jamais des identités** : `PrepareSharedParkUpdates` refuse toute clé `shared:<poste>` déjà occupée par une ligne portant un GUID ou un DN, ou dont le statut n'a pas le préfixe `PARTAGE_` ; `VerifySharedParkUpdates` exige `ComputerGuid is null && ComputerDn is null` après écriture ; les lignes natives sont comparées par `StorageFingerprint` et les lignes remplacées par `PreservedFingerprint`. Aucun GUID/DN/identité AD n'est déduit d'un nom SMB ; les liens natifs ne sont ni lus ni réécrits.
- **Modifications locales et reçu dans la même transaction** : INSERT/UPDATE de `park_state`, `UPDATE domenia_store_state ... WHERE id=1 AND revision=?2` (CAS de révision), `INSERT` du reçu, puis relecture du reçu **et** contrôle du delta `total_changes() == updates.Length + 2` avant `db.Commit()`. Le reçu est relu côté froid (`VerifySharedParkConfirmedAsync`) avec le contexte attendu.
- **Vérification à froid** : relit intention privée, **les deux copies physiques**, reçu SQLite, snapshot local réel et TSV courant ; fonctionne spool et plan expirés (`ValidateSharedParkPlan(current: false)`, codec en `allowExpired`) ; ne crée rien, ne publie ni ne réapplique jamais. `intention sans reçu commis` → `Unknown`, **même si le TSV égale par hasard la proposition**.
- **Reçu/manifeste bornés, stricts, vérifiés** : 128 reçus maximum (`admission` refuse à 128, aucun nettoyage implicite), 16 Kio par payload, `MaxDepth = 8`, `UnmappedMemberHandling.Disallow`, SHA-256 du payload revérifié, `LIMIT 2` pour refuser un doublon, schéma `PRAGMA table_info` comparé colonne par colonne, `CommittedAt` en UTC borné entre l'intention et l'horloge.
- **Refus de rejeu et absence de nettoyage silencieux** : intention existante → refus avant sauvegardes ; reçu existant → refus ; quota de 32 publications/128 intentions/32 lots → refus **preuves laissées en place** ; aucune suppression, aucune réparation de DACL, aucune rotation automatique.

## 3. Renforts apportés pendant l'achèvement (hors formulation)

1. `Apply.cs:104-113` — le point de contrôle `BeforePublication` est déplacé **juste avant** `publication.Publish(...)`, après la seconde relecture logique du TSV, et la construction de la publication est déplacée après cette relecture. Conséquence utile : une interférence injectée à cette frontière n'est plus attrapée par le seul contrôle logique mais bien par le **CAS physique** de `Publish`, ce qui le rend testable ; et aucun dossier de preuve n'est plus créé pour un plan refusé au contrôle logique.
2. `Apply.cs:196-197` — `PrepareSharedParkUpdates` refuse désormais explicitement deux gagnants distants qui viseraient la même clé locale (`InvalidDataException`), au lieu de laisser `ToDictionary` lever un `ArgumentException` non qualifié plus tard.
3. `Apply.cs:216-217` — `VerifySharedParkUpdates` refuse des clés locales dupliquées à la relecture avant de bâtir son dictionnaire de référence (même motif).
4. `SharedParkPublicationFile.cs:39-42` — `ValidatePaths` qualifie maintenant **les quatre** chemins que la publication crée elle-même (cible, `.tmp`, dossier `.evidence`, `previous.tsv`) ; le dossier de preuve lui-même n'était pas qualifié.
5. `Verify.cs:58-61` — le jeton est interrogé une dernière fois **après** `db.Commit()` et **avant** de renvoyer `Verified`, pour qu'une annulation déjà accordée ne puisse jamais sortir de la vérification sur un verdict `Verified`.
6. `Apply.cs:43-45` et `57-59` — le refus de SQLite **absent/hérité** est documenté sur la méthode et sur place comme un manque assumé (voir limites), pas comme un cas traité.

Aucun de ces renforts n'élargit le protocole : aucun nouvel appel système, aucune nouvelle dépendance, aucun nouveau fichier.

## 4. Dépendance indispensable manquante — signalée précisément, volontairement non corrigée

`v2/src/Domenia.Store/Sqlite/CompatibleDirectoryCache.SharedPark.cs` (wrapper d'un lot précédent, **interdit de modification par le mandat**) appelle quatre membres de `DomeniaDatabase` qui **n'existent nulle part** dans le dépôt :

- ligne 20 : `DomeniaDatabase.ReadSharedParkAsync(string, CancellationToken)` ;
- ligne 25 : `DomeniaDatabase.CheckSharedParkAsync(SharedParkBatch, CancellationToken)` ;
- ligne 31 : `DomeniaDatabase.ApplySharedParkAsync(SharedParkBatch, WritePlan, CancellationToken)` ;
- ligne 34 : `DomeniaDatabase.VerifySharedParkAsync(WritePlan, CancellationToken)`.

`rg` sur tout le dépôt ne trouve ces quatre signatures nulle part (seules les interfaces `ISharedParkStore`/`ISyncReader` et les lecteurs AD/simulation les déclarent). **Le projet `Domenia.Store` ne peut donc pas compiler tant que ces quatre adaptateurs ne sont pas écrits** : ce n'est pas un défaut des quatre brouillons de ce lot, et le build069 réussi ne le couvrait pas (le lot013 ne touchait que `BridgeSchedulingTests.cs`).

Ces adaptateurs ne sont **pas** ajoutés ici, et ce n'est pas un oubli : ils constitueraient la route d'exécution publique que le contrat de `DraftSharedPark` interdit (« this internal Store API provides no alternate UI or public execution route »), ils devraient inventer `backupRoot`, `journalRoot`, `configFiles`, `protectedDirectories` et le `validateSource` du caller — c'est exactement le poste **« cache/annuaire/executor »** déjà listé comme restant. Le signaler ici est la seule action conforme au mandat ; la décision d'écrire ces quatre méthodes (et avec quel gate de source) appartient à Codex, dans le lot dédié.

## 5. Tests : 20 méthodes écrites, **0 exécuté**

`v2/tests/Domenia.Tests/SharedParkApplyTests.cs` — 15 méthodes préexistantes revues, **5 ajoutées**, fixtures Windows locales uniquement (SQLite + TSV temporaires, DACL privée posée par la fixture, horloge UTC fixe), aucun AD, aucun SMB réel, aucune réflexion, aucun test n'avale une exception pour réussir.

Ajouts de ce lot :

1. `Cancellation_before_publication_publishes_nothing_and_keeps_every_proof` — annulation à la frontière `BeforePublication` : `OperationCanceledException` propagée (publication non tentée), TSV intact, aucune ligne externe, révision à 0, intention et copies conservées, `previous.tsv` absent, vérification à froid `Unknown`.
2. `A_TSV_replaced_between_the_last_reread_and_the_rename_is_refused_by_the_physical_CAS` — l'écrivain concurrent renomme puis recrée le TSV entre la dernière relecture et le renommage : le **CAS physique** de `Publish` refuse (« CAS physique »), l'écriture concurrente est laissée, rien n'est déplacé, intention conservée, `Unknown`.
3. `The_durable_receipt_reports_the_exact_committed_state_on_a_cold_reread` — exactitude du reçu relu à froid depuis la base, **sans passer par le code du reçu** : SHA stocké = SHA des octets du payload, empreinte de colonne = empreinte du plan, payload ≤ 16 Kio, puis les quatorze champs (`Version`, `PlanId`, `PlanFingerprint`, `BatchId`, `BatchFingerprint` **recalculé**, `StoreId`, `DomainDn`, `Path`, `RemoteSha256` = SHA publié et non celui de l'ancien fichier, `RowsFingerprint` relu dans la base, `Revision` = `batch.Revision + 1` = révision relue, `Generation` non incrémentée, `Updated` = `Added + Replaced`, `CommittedAt` en UTC).
4. `A_corrupted_intention_is_an_explicit_mismatch_and_blocks_any_replay` — intention remplacée par un document illisible : `Mismatch` (jamais une absence ni un succès), rejeu refusé, TSV et révision inchangés.
5. `A_corrupted_receipt_is_an_explicit_mismatch_and_blocks_any_replay` — payload du reçu altéré en base : `Mismatch` (jamais relu `Verified`), rejeu refusé par l'intention existante avant toute écriture, TSV et révision inchangés.

Corrections de fixtures (mandat : « pas de test qui échoue sur une fixture invalide avant le scénario visé ») : le message d'assertion du test « TSV absent » contredisait son attente (1 ligne = la ligne native, aucune ligne externe) ; il dit maintenant ce qui est réellement vérifié. Aucune assertion n'a été affaiblie.

Vérification statique locale : équilibre accolades/parenthèses/crochets des quatre fichiers, et existence de chaque symbole appelé (vérifiée dans le dépôt : `SharedParkIntentJournal`, `SharedParkIntentDocument.DocumentVersion`, `SharedParkBackupFiles.Open/PinSqliteSource/MaxSqliteBytes`, `SharedParkRemoteReader.Validate/ReadAsync`, `SharedParkFile.LockAsync/Hash/Encode/MaxBytes/MaxRows`, `SharedParkMerge.Preview`, `StorageWriteSnapshot.Read`, `SyncStoreChange.Head/HeadValue/ParkTarget/ParkStoreGuid`, `SyncLocalIdentity.Target`, `SharedParkIdentity.*`, `SyncPark.Key/SharedPrefix`, `WritePlans.IsPlanId/IsIntact`, `AppInfoBuilder.DirectoryModeText`, `FrenchText.Colon`, `CompatibleDirectoryCache.ValidateLocalPath`, `SqliteStoreException`, `Stamp`, `Table`, `CheckIdentity`, `LocalBaseAbsent`, `RelationSweepRecord.PreservedFingerprint`).

**Aucun de ces 20 tests n'a été exécuté**, et aucun des suites existantes non plus. Leur validité d'exécution (notamment les deux tests qui renomment le TSV sous le lease partagé `READ|DELETE` tenu par la publication, et la stabilité des horodatages `DateTimeOffset` après aller-retour JSON du reçu) n'est pas prouvée ici : c'est la VM qui tranchera.

## 6. Limites restantes (ce lot n'achève pas SharedPark)

- **SQLite absent/hérité** : refus explicite avant toute écriture (`Apply.cs:59`) ; initialisation et héritage restent à raccorder, avec leurs propres sauvegardes et reçus.
- **Cache / annuaire / executor / simulation / UI** : non faits ; c'est notamment là que vivent les quatre adaptateurs du §4 et le `validateSource` réel du caller.
- **Recette réelle** : aucune exécution, aucun partage SMB réel, aucun AD, aucune VM contactée depuis Spark.
- **DACL du fichier déplacé** : `File.Replace` déplace l'ancien fichier **avec son propre descripteur de sécurité** ; le dossier `.evidence` est créé privé et sa DACL est revérifiée avant et après, mais le `previous.tsv` déplacé peut conserver une DACL héritée du partage. Aucun contrôle ni réparation n'a été ajouté ici (une réparation eut été une mutation non demandée ; un contrôle eut rendu `Unknown` un cas légitime). À trancher avec la recette réelle.
- **Le verrou D1 n'est pas un CAS universel** : c'est un contrat entre consoles coopérantes ; le fichier réellement déplacé est conservé et comparé, et l'ambiguïté reste `Unknown`.
- **Le pin de l'inœud SQLite n'est pas une preuve CAS** : `PinSqliteSource` tient l'inœud et les ancêtres, mais `SqliteDatabase` ouvre ensuite **par nom** ; la protection effective contre un autre écrivain SQLite est `BEGIN IMMEDIATE` + le CAS logique `StorageWriteSnapshot`, comme en 012B.
- **`SharedParkPublicationFile` duplique les déclarations P/Invoke** (`CreateFileW`, `CreateDirectoryW`, `GetFileInformationByHandle`, `SecurityAttributes`, `Information`) déjà présentes dans `SharedParkBackupFiles.Native`. Facteur de dérive, pas un blocage : aucune factorisation tentée ici (hors périmètre, et toute factorisation aurait modifié un fichier du lot 012B).

## 7. Suite, hors de cette réponse

Codex récupère ces quatre fichiers, relit, compile070 **exclusivement via `vm.sh`** en VM Windows et rend le diagnostic complet dans cette même session. Attendre en priorité : (a) les erreurs attendues du wrapper du §4, (b) les 20 tests de `SharedParkApplyTests` qui n'ont jamais tourné. Ce lot014 s'arrête ici.
