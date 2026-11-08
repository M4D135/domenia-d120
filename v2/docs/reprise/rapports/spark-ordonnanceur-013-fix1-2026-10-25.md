# SPARK-READY-013-FIX1 — deux défauts de cycle de qualification corrigés

Session reprise après saturation confirmée de `ses_e9074edf9ffeImziG5oGXdLtHx` (ContextOverflowError au lancement du lot013-FIX1, avant toute édition). Aucune source n'avait été touchée : les six fichiers013 ont été relus identiques au manifeste `codex-team-066-manifest.json` avant édition. Aucun moteur, service, réseau ou fournisseur modifié. Aucun ancien gros bundle n'a été relu.

## Périmètre réellement touché par FIX1
- `v2/src/Domenia.Bridge/BridgeAdmission.cs`
- `v2/tests/Domenia.Tests/BridgeSchedulingTests.cs`
- `v2/docs/reprise/SPARK-READY-013-FIX1.md` (ce rapport)

Aucune erreur compilateur ne remontait d'un des six fichiers013 : les quatre autres fichiers (`BridgeDispatcher.cs`, `OperationRegistry.cs`, `OperationModules.cs`, `BridgeScheduling.cs`) ne sont pas modifiés. Aucun build, aucun test, aucun téléchargement, aucun service/runtime/réseau, aucun commit, push, reset ou clean n'a été exécuté ici. `dev/` est resté en lecture seule.

## Défaut 1 — retrait observable pendant un refresh partagé suspendu
`PrepareAndWaitAsync` faisait `await RefreshAsync()` avant d'attendre `entry.Completion.Task` : quand la qualification individuelle réussissait puis que la capture globale du refresh se suspendait, l'appelant restait bloqué dans le refresh alors que l'expiration périodique avait déjà retiré son entrée.

Correction (BridgeAdmission.cs:108-114) : le refresh partagé est **démarré, jamais attendu jusqu'à sa fin**.

- `var promotion = RefreshAsync();` puis course `Task.WhenAny(promotion, entry.Completion.Task)` ;
- si le retrait de l'entrée gagne, l'appelant retourne immédiatement son propre motif (expiration, remplacement, changement de session, annulation) sans attendre la capture globale ;
- si le refresh gagne, `await promotion` est quand même exécuté : les erreurs du refresh restent observées par l'appelant ;
- une continuation `OnlyOnFaulted` observe l'exception de `promotion` quand l'appelant s'en détache, donc aucune exception non observée ;
- le refresh abandonné garde sa propre garde single-flight (`refreshing`) et sa borne de 25 ms de promotion sous gate : rien n'est élargi, aucune place n'est inventée, `queuedNotice()` n'est publié que si l'entrée attend encore réellement.

Le chemin `queuedNotice()` reste synchrone quand le refresh se termine sans suspendre, donc le `event` publié par le dispatcher est toujours émis avant le retour de `HandleAsync`.

## Défaut 2 — délégué de capture appelé sous gate, hors try de nettoyage
`qualifying++ ; capture = captureSession(qualification.Token)` était exécuté dans le verrou, avant le bloc `try` : un délégué levant synchroniquement fuyait à la fois la réservation `qualifying` et l'entrée, jusqu'au blocage permanent après 32 refus ; un préambule synchrone lent tenait aussi le verrou qui protège annulation et expiration.

Correction (BridgeAdmission.cs:64-82, 124-136) :

- la réservation est prise **sous gate** (`qualifying++`, `started = true`) ;
- le fournisseur est invoqué **hors gate**, dans une section garantie : `try { running = captureSession(qualification.Token); } catch { qualification.Cancel(); Abandon(entry, true); throw; }` ;
- la continuation `qualifying--` n'est attachée qu'à une tâche réellement rendue : un throw synchrone rend la réservation **une seule fois** (via `Abandon(entry, true)`), jamais deux ;
- une capture réellement rendue garde sa réservation jusqu'à sa fin réelle, y compris si le fournisseur ignore l'annulation ; aucun slot n'est rendu pour une tâche encore pendante ;
- `Abandon` retire **exactement son entrée** (`entries` + `queued`, sous gate, uniquement si elle n'a pas démarré et est toujours courante) et n'invente aucun succès : un lease déjà remis est disposé plutôt que fabriqué ;
- le bloc `catch` existant réutilise `Abandon(entry, false)` : comportement inchangé, sans double restitution.

## Commentaire corrigé
`RefreshAsync` n'est plus présenté comme une lecture « Memory-only » (BridgeAdmission.cs:138-140) : la qualification est une lecture locale qui charge la session de la source et la portée de travail effective (`LoadLocalAsync`, `WorkingScope`). La précision single-flight / 32 candidats / 25 ms / balayage d'expiration avant la garde est conservée.

## Tests ajoutés (quatre méthodes `[Test]`, fichier porté de 22 à 26 méthodes)
1. `A_withdrawal_reaches_the_caller_while_the_shared_refresh_is_suspended` — première capture immédiate, seconde capture (refresh partagé) suspendue ; après 120 s, l'appelant reçoit `operation.queueExpired` **avant** toute résolution de la seconde capture, qui est encore incomplète à l'assertion ; file à 0, huit places réseau conservées, aucun handler lancé.
2. `A_local_cancellation_reaches_the_caller_while_the_shared_refresh_is_suspended` — même interleaving, annulation locale sur ce chemin : `OperationCanceledException` observable sans résoudre la capture globale, aucune résolution fabriquée, file à 0, huit places réseau conservées.
3. `A_capture_throwing_synchronously_returns_its_reservation_and_removes_only_its_entry` — 64 captures levant synchroniquement (plus de 32), avec le **même identifiant** réutilisé à chaque tour : le motif réel de l'appelant remonte (jamais une exception générique), la file revient à 0 à chaque tour, aucune place réseau mensongère, puis admission réelle réussie après libération d'une place — preuve que les réservations ont toutes été rendues.
4. `The_capture_delegate_is_invoked_outside_the_gate_that_protects_the_queue` — interleaving réellement atteint : pendant l'invocation du fournisseur, l'admission répond encore à `Load.Queued` (2) et accepte `CancelQueued("pending")` sur une autre lecture. Sous l'ancien code, cet appel depuis l'intérieur du délégué se auto-bloquait sur le `Lock` non réentrant ; la lecture dont la capture est terminée reste retirable avant départ, sans place fabriquée.

Les tests existants sont conservés sans modification, y compris `A_suspended_qualification_still_expires_a_queued_read_at_120_seconds_without_a_handler` (qualification individuelle suspendue) et `A_provider_that_ignores_cancellation_cannot_grow_unbounded_pending_qualifications` (borne des qualifications pendantes).

## Tests : état réel
Les 26 méthodes `[Test]` de `BridgeSchedulingTests.cs` sont **écrites, non exécutées**. Aucun test n'a été lancé ici, ni ancienne ni nouvelle suite. La compilation066 jointe (`build-codex-team-066.log`, Debug et Release verts, 0 warning, 0 erreur) est antérieure à ce delta et ne couvre pas ces éditions.

## SHA
Avant FIX1 (manifeste `codex-team-066-manifest.json`, vérifiés identiques avant édition) :
- `v2/src/Domenia.Bridge/BridgeAdmission.cs` : `896839742e7c409926b1c5c2ca3be7c1e2d044c4ed65f4a4d74aed60d93219c2`
- `v2/tests/Domenia.Tests/BridgeSchedulingTests.cs` : `8a4e39de3fc0f083348f74764d538853946f64a7fcd2cfbb317ad9c85cc29480`

Après FIX1 (à compiler en067) :
- `v2/src/Domenia.Bridge/BridgeAdmission.cs` : `7b82929f69d55f2e3addd490be06a914e1dbfea28dd1f158a4b14aabeb0464eb`
- `v2/tests/Domenia.Tests/BridgeSchedulingTests.cs` : `378044fcb6bd9c2842dfb85d93ad06de8ecdaf2847a3f48dba2188337667a567`

Inchangés et revérifiés sur le manifeste066 :
- `v2/src/Domenia.Bridge/BridgeDispatcher.cs` : `ac6683ff97441e62af381799dd4610bf7be8f043feb283da503d7eb2e324e04a`
- `v2/src/Domenia.Bridge/OperationRegistry.cs` : `04f1413e2cc2f5ab9c65bc717c9fe393335f48c690212ff7514bd968a3e1e70e`
- `v2/src/Domenia.Bridge/OperationModules.cs` : `f6fd9f298a88be3d327c93ceebcb6da506a813fa3ed485f6566315c95598e8a1`
- `v2/src/Domenia.Bridge/BridgeScheduling.cs` : `3b46256792999a55c9dd2053adef086842bc010d0be8340de9346d0fb53d92b4`

## Bornes et invariants conservés
Aucun élargissement : `NetworkLimit` 8, `OrdinaryLimit` 48, `ControlLimit` 4, `QueueLimit` 32, `ReservedForeground` 2, `MaxProviderStates` 256, `MaxPendingQualifications` = une file, aging 30 s, expiration 120 s, tous inchangés. Priorité au vrai motif de retrait (la complétion de l'entrée prime sur l'annulation de la qualification), requalification au départ réel (`RevalidateAsync`), places conservées jusqu'à fin réelle du handler, aucune écriture ni credential en file, aucun rejeu automatique, aucune publication ni livraison déclarée.

## Limites assumées
- Les tests ne sont pas exécutés ici : les quatre nouveaux cas n'ont jamais tourné, et leur validité d'exécution reste à confirmer en VM.
- La compilation067 n'existe pas encore : les deux SHA « après » ne sont pas compilés.
- Le désaccord éventuel entre l'attente d'un test et le comportement réel du `Lock` non réentrant (test 4) ne sera tranché que par l'exécution VM.
- Le raccordement UI et les workers natifs ne sont pas touchés par cette correction, hors du périmètre demandé.
- Les autres WIP SharedPark et les dispositions restent conservés, hors de cette correction.

## Prochaine étape, hors de cette réponse
Codex récupère ces deux fichiers, compile067 dans la VM (Debug et Release), exécute la suite, puis renvoie le diagnostic dans cette session. Ce lot013-FIX1 s'arrête ici.
