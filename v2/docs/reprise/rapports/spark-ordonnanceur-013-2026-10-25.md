# Reprise full Spark — READY lot013 ordonnanceur Bridge

Worker unique OpenCode CLI natif sur Spark (kbza/spark-local). Aucun autre agent, aucun appel LLM direct, aucun build ni exécution de test sur Spark, aucun git commit/push/reset/clean. Dépôt Spark laissé sur son HEAD Git `29ca441a10db9565894c8be41ed096a94cf3aae1` (non réinitialisé) ; les octets ci-dessous font foi, les brouillons restent non compilés.

Étape exécutée : terminer les six fichiers ordonnanceur existants et corriger les cinq points de revue avant READY, en vue de la compilation VM066.

## Fichiers livrés (SHA-256 des octets actuels du dépôt)

Édités dans ce lot :
- `v2/src/Domenia.Bridge/BridgeAdmission.cs` — `896839742e7c409926b1c5c2ca3be7c1e2d044c4ed65f4a4d74aed60d93219c2`
- `v2/src/Domenia.Bridge/BridgeDispatcher.cs` — `ac6683ff97441e62af381799dd4610bf7be8f043feb283da503d7eb2e324e04a`
- `v2/src/Domenia.Bridge/BridgeScheduling.cs` — `3b46256792999a55c9dd2053adef086842bc010d0be8340de9346d0fb53d92b4`
- `v2/tests/Domenia.Tests/BridgeSchedulingTests.cs` — `8a4e39de3fc0f083348f74764d538853946f64a7fcd2cfbb317ad9c85cc29480`

Vérifiés complets et cohérents, non modifiés (déjà conformes aux sources jointes) :
- `v2/src/Domenia.Bridge/OperationRegistry.cs` — `04f1413e2cc2f5ab9c65bc717c9fe393335f48c690212ff7514bd968a3e1e70e`
- `v2/src/Domenia.Bridge/OperationModules.cs` — `f6fd9f298a88be3d327c93ceebcb6da506a813fa3ed485f6566315c95598e8a1`

Non modifié, vérifié compatible (aucune adaptation d'API nécessaire) :
- `v2/tests/Domenia.Tests/BridgeAdmissionTests.cs` — n'utilise que `BridgeDispatcher`, `OperationRegistry(IEnumerable)` et les constantes `BridgeAdmission.NetworkLimit/OrdinaryLimit` ; comportement d'admission immédiate des opérations sans `Scheduling` conservé.

Aucun autre fichier applicatif touché. `PosteLayoutOperations.cs` (nouvelles opérations locales Poste, hors périmètre 013) ne référence aucune API d'ordonnancement : opérations sans métadonnées → admission immédiate, compatible sans modification.

## Changements appliqués (points de revue)

### 1. Expiration jamais bloquée par une qualification suspendue + captures bornées (BridgeAdmission)
- `RefreshAsync` appelle désormais `ExpireQueued()` **avant** la garde single-flight (`refreshing`). Une capture de session suspendue (ex. `AdDirectorySource.GetSessionAsync → LoadLocalAsync`, jamais une simple lecture mémoire) ne peut plus faire sortir les ticks avant `RemoveExpired` : l'expiration 120 s et le retrait des annulations s'exécutent à chaque tick sous le gate, indépendamment du refresh en cours.
- Chaque entrée en file possède une **qualification propre** (`CancellationTokenSource` local à `PrepareAndWaitAsync`). Au retrait (expiration, supersession, changement de contexte, annulation), le chemin « préférence à `Completion` » appelle `qualification.Cancel()` : la qualification d'une entrée retirée est annulée proprement (un fournisseur qui ignore l'annulation ne peut pas forcer le succès).
- Le wait préfère `entry.Completion.Task` (`== Completion || Completion.IsCompleted`) pour remonter le **vrai** motif de retrait (jamais l'annulation de la qualification).
- **Borne des captures réellement pendantes** : compteur `qualifying` incrémenté au départ de chaque capture, décrémenté uniquement quand la tâche de capture se termine **réellement** (continuation sur la tâche brute). `MaxPendingQualifications = QueueLimit` (32). Un fournisseur qui ignore l'annulation ne peut pas faire croître les captures orphelines au-delà d'une file : au-delà de la borne, une nouvelle qualification est refusée (`operation.busy`) et l'entrée est retirée de la file. Aucune capture orpheline illimitée après rotations de file.
- Aucun timer arbitraire ajouté sur `captureSession` : le timer périodique 250 ms reste le contrat des lectures de l'application (promotion/expiration), pas un délai appliqué au fournisseur.

### 2. Test déterministe de l'interleaving visé (BridgeSchedulingTests)
- `A_suspended_qualification_still_expires_a_queued_read_at_120_seconds_without_a_handler` : qualification partagée suspendue (TCS jamais résolu), horloge avancée à 120 s, un tick (`RefreshAsync`) retire la lecture en file **sans handler**, sans libération mensongère des 8 handlers actifs (`Network == 8`), et le motif exact `operation.queueExpired` est asserté (pas d'exception générique tolérée avant l'interleaving).

### 3. Empreinte sur l'OU de travail effective (BridgeScheduling.Capture)
- `Capture` qualifie désormais via `WorkingScope.From(context).CurrentAsync(session, token)` et intègre l'OU de travail **effective** (`working ?? session.Scope`) dans l'empreinte, et non plus seulement `session.Scope` du fournisseur. Une sélection d'OU locale (`session.setScope`) qui ne bouge pas l'epoch source change bien l'empreinte → les lectures en file sont retirées (`operation.contextChanged`) si l'OU de travail change avant le départ.
- Revalidation au départ réel inchangée dans son contrat : `RevalidateAsync` recapture (désormais avec l'OU de travail) et compare ; les arguments d'une lecture attendue ne sont jamais modifiés en silence (le handler valide son propre schéma au départ).
- Test : `The_stamp_follows_the_working_ou_even_when_the_source_epoch_is_unchanged` (deux OU de travail → deux empreintes distinctes, epoch source inchangée).

### 4. Annulation bornée du dispatcher (BridgeAdmission + BridgeDispatcher)
- `BridgeAdmission.CancelQueued(string id)` : retrait local borné, limité à ses propres entrées ; retourne `true` **seulement** pour un retrait avant départ (`!Running && queued.Contains`). Après départ, ne prétend jamais au succès (le handler et son jeton décident) ; entrée inconnue → `false`.
- `BridgeDispatcher.CancelQueued(string requestId)` (public) délègue à son admission. Raccordement UI/panneau d'activité = lot ultérieur (MainForm passe encore le lifetime de fenêtre).
- Test : `Dispatcher_cancels_only_a_queued_read_before_its_real_start` (vrai avant départ, publié `operation.cancelled` ; `false` pour un handler déjà parti et pour une demande absente ; les 8 handlers actifs gardent leur place).

### 5. Complément de couverture, sans toucher aux 18 tests existants
- Les 18 tests déjà écrits sont relus et conservés tels quels. Ajout de 4 tests pour les comportements manquants (items 1 à 4) :
  1. `A_suspended_qualification_still_expires_a_queued_read_at_120_seconds_without_a_handler`
  2. `A_provider_that_ignores_cancellation_cannot_grow_unbounded_pending_qualifications`
  3. `Dispatcher_cancels_only_a_queued_read_before_its_real_start`
  4. `The_stamp_follows_the_working_ou_even_when_the_source_epoch_is_unchanged`
- Métadonnées optionnelles compatibles avec tous les modules : `BridgeScheduling.Declare` renvoie `null` pour toute opération non listée (dont les nouvelles opérations locales Poste) → admission immédiate ; `OperationRegistry.Validate` n'exige des métadonnées que si `Scheduling` est posée. Aucune signature publique/internal d'ordonnancement modifiée.

## Tests écrits, NON exécutés ici
Aucune suite n'a été lancée sur Spark (mandat). Les 4 nouveaux tests ci-dessus sont écrits pour la phase finale VM. Les tests existants (18 de `BridgeSchedulingTests` + 4 de `BridgeAdmissionTests`) sont conservés inchangés.

## Limites et ce qui reste ouvert (hors 013)
- Ce sont des limites de **requêtes Bridge**, pas une preuve de workers natifs. Isolation native et budgets physiques = lot ultérieur.
- Raccordement UI de l'annulation (bouton + panneau activité) non effectif : MainForm passe encore le lifetime de fenêtre.
- `SharedPark.Apply/Verify/PublicationFile/ApplyTests` et la migration Poste/Logiciels (PosteBoardLayouts, PosteLayoutOperations, board-layout.js, deltas Legacy) restent des brouillons non compilés, hors périmètre 013, conservés sans modification.
- `CompatibleDirectoryCache.SharedPark.cs` incomplet et les quatre WIP recette native préservés, non inclus dans un build.

## Points de reprise (Codex / VM066)
1. Reprendre les sources ci-dessus et compiler **Debug + Release VM066** : objectif 0 avertissement / 0 erreur (`TreatWarningsAsErrors`, `AnalysisLevel latest`).
2. Exécuter les suites en phase finale (jamais ici) : `BridgeSchedulingTests` (22 tests) et `BridgeAdmissionTests` (4 tests).
3. Vérifier en priorité les 4 nouveaux tests (interleaving de la qualification suspendue, borne des captures, annulation dispatcher, empreinte OU de travail).
4. Puis lots suivants : publication SharedPark, consommateurs Poste/Logiciels, raccordements cache/annuaire/simulation/UI, isolation native, tout PROMPT-CODEX/catalogue.
5. Validation finale : Debug/Release 0 warning, 100 % C#, ≥137 E2E simulation, vraie recette domaine et VM Domenia depuis bureau interactif, AD writes seulement OU=Domenia-Tests, DC=cnamts, DC=local, aucun reboot/logoff. Release PROD/DEV v2.0.0+SHA256 seulement tout vert.

Worker terminé proprement après ce rapport. Aucune compilation, aucune exécution de test, aucune opération Git effectuées sur Spark.
