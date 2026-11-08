# SPARK-READY-013-FIX3 — test inter-thread corrigé, aucune production

FIX2 a terminé normalement (stop + READY, sans erreur publique). Le fichier de tests récupéré a été comparé au manifeste `codex-team-068-manifest.json` avant édition et trouvé identique. Debug068 est en échec sur une seule CS0029 (`BridgeSchedulingTests.cs:540`, `bool` vers `CancellationToken`), 0 avertissement, Release non tenté (journal `build-codex-team-068.log`). Ce lot ne corrige que ce fichier de tests, plus le présent rapport.

## Périmètre réellement touché par FIX3
- `v2/tests/Domenia.Tests/BridgeSchedulingTests.cs` — une seule méthode `[Test]` modifiée (`The_capture_delegate_is_invoked_outside_the_gate_that_protects_the_queue`, lignes 524-594), les 25 autres tests du fichier et tous les autres fichiers sont intacts ; le fichier reste à 26 méthodes `[Test]`.
- `v2/docs/reprise/SPARK-READY-013-FIX3.md` (ce rapport)

Aucune production touchée : `v2/src/Domenia.Bridge/BridgeAdmission.cs` vérifié au SHA `7b82929f69d55f2e3addd490be06a914e1dbfea28dd1f158a4b14aabeb0464eb` avant et après ce lot (identique aux manifestes 067 et 068). Aucun autre WIP (SharedPark, dispositions) n'a été ouvert. Aucun build, aucun test, aucune mutation, aucun téléchargement, aucun service/runtime/réseau, aucun commit, push, reset ou clean. `dev/` est resté en lecture seule.

## 1. CS0029 corrigée et résultat d'attente réellement traité
Dans le lambda `_ => { ... }`, `_` n'était pas une discard mais le **paramètre `CancellationToken`** du délégué `Func<CancellationToken, Task<BridgeSessionStamp>>` : `_ = releasePreamble.Task.Wait(...)` tentait donc d'affecter un `bool` à un `CancellationToken`.

- le paramètre est nommé `captureToken` (BridgeSchedulingTests.cs:535) : plus aucune affectation ambiguë ;
- le résultat de l'attente est traité : `if (!releasePreamble.Task.Wait(TimeSpan.FromSeconds(10))) { preambleFailure = "…"; }` (ligne 541), puis `Check.True(preambleFailure is null, preambleFailure ?? …)` (ligne 584) — un délai expiré devient un **échec explicite** de la suite, pas une reprise silencieuse.

## 2. Préambule sélectionné sans ambiguïté, indépendamment des captures périodiques
`TestClock.Fixed()` fournit de **vrais** timers (`TestSupport.cs`) : le compteur global de captures `== 3` pouvait donc désigner une capture `RefreshAsync` de minuterie — déjà appelée hors gate — au lieu de la capture individuelle de `blocked`. Le rapport FIX2 affirmait à tort le même verdict pour l'ancien code dans ce cas : c'est corrigé ici.

Sélection par identité de thread (aucune temporisation, aucun numéro global d'appel comme preuve) :
- la tâche dédiée enregistre son `Environment.CurrentManagedThreadId` **juste avant** d'appeler `Enter(admission, "blocked", read)` (ligne 551) ;
- le délégué ne parque que si `Environment.CurrentManagedThreadId == Volatile.Read(ref blockedThread)` **et** si un drapeau atomique `Interlocked.CompareExchange(ref parked, 1, 0)` n'a pas encore été consommé (ligne 538) ;
- les captures périodiques de minuterie, sur d'autres threads, court-circuitent la condition et restent immédiates ; la seconde capture du même thread (promotion partagée) trouve le drapeau déjà pris et reste immédiate ;
- `Check.Equal(1, parked, …)` (ligne 586) atteste qu'une seule capture a été ciblée.

Préambule encore parqué quand l'interférent termine : un TCS `preambleLeft` est signalé au sortir de l'attente bornée, et `Check.False(preambleLeft.Task.IsCompleted, …)` (ligne 564) est vérifié **après** le retour du thread interférent ; `Check.True(preambleLeft.Task.IsCompleted, …)` (ligne 585) vérifie ensuite qu'il a bien quitté son thread.

## 3. Interleaving entre threads conservé et discriminant
- huit places réseau réellement tenues (`Hold(admission, 8)`), donc rien d'admissible ;
- `pending` en file sur le thread du test, `blocked` entré sur son thread dédié ;
- **barrière 1** `insidePreamble` (le préambule ciblé tourne) puis **barrière 2** : un **autre thread** lit `Load.Queued`, appelle `CancelQueued("pending")`, relit `Load.Network`, attendu par `WaitAsync(5 s)` — garde de panne bornée, jamais un sommeil ;
- assertions : `seen.Queued == 2`, `seen.Withdrawn`, `seen.Network == 8`, file réduite à 1, huit places actives conservées, `pending` rend `OperationCanceledException` dont le `CancellationToken` est celui de cette seule lecture, `handlerCalls == 0` ;
- `finally` : libération garantie du préambule (`releasePreamble.TrySetResult()`), retrait des deux lectures encore en file (`CancelQueued`, idempotent, jamais un départ déjà parti), observation des **trois** tâches créées (`blocked`, `interferer`, `pending`) via `Task.WhenAll(...).ContinueWith(…, TaskScheduler.Default)`, puis `admission.Dispose()` — la fermeture de fenêtre retire toute lecture encore en file, donc aucune tâche `Enter` ne peut survivre, y compris si le thread dédié avait démarré après le premier retrait — et enfin `Release(held)`. Aucun thread bloqué, aucune demande et aucune tâche non observée ne survivent, même sur échec d'assertion ou sur expiration d'une garde.
- Verdict attendu : avec l'ancien appel **sous gate**, le thread interférent se bloque sur la porte, la garde de 5 s expire et `TestFailureException` est levée avec le motif précis → le test **échoue** ; avec FIX1 (réservation sous gate, invocation hors gate), il **réussit**. Aucune mutation ni exécution n'a été tentée ici.

## Tests : état réel
Aucun test exécuté. Le Debug068 est en échec de compilation (CS0029) et le Release n'a pas été tenté : le contenu FIX2 n'a jamais été compilé, et le contenu FIX3 n'est pas encore compilé. Les 25 autres tests du fichier et les suites existantes restent non exécutés ; aucune couverture n'est affirmée comme obtenue.

## SHA
Avant FIX3 (manifeste `codex-team-068-manifest.json`, vérifié identique avant édition) :
- `v2/tests/Domenia.Tests/BridgeSchedulingTests.cs` : `d764b2c9bc30856f11138f2d644196a1de45a856917dd379870df2a1992b6fa6`
- `v2/src/Domenia.Bridge/BridgeAdmission.cs` : `7b82929f69d55f2e3addd490be06a914e1dbfea28dd1f158a4b14aabeb0464eb` (hors périmètre, inchangé)

Après FIX3 :
- `v2/tests/Domenia.Tests/BridgeSchedulingTests.cs` : `d0c7197c4c77c80594e2c91b8c9bb6c2afad588c42829acc8003241fcad54509`
- `v2/src/Domenia.Bridge/BridgeAdmission.cs` : `7b82929f69d55f2e3addd490be06a914e1dbfea28dd1f158a4b14aabeb0464eb` (inchangé)

## Limites assumées
- La validation d'exécution reste entièrement VM : ce test n'a jamais tourné, et sa stabilité (deux threads, gardes de 5 s et 10 s, minuteur réel de 250 ms de l'admission) n'est pas prouvée ici.
- Le test s'appuie sur l'identité de thread managé et un drapeau atomique ; la réutilisation d'un identifiant de thread par la minuterie après la fin du thread dédié est couverte par le drapeau à usage unique, mais ce n'est pas vérifié par exécution.
- La production reste celle de FIX1 compilée067 : elle n'est ni revalidée ni modifiée par ce lot.
- Les deux défauts de cycle de qualification restent validés par lecture et compilation seulement, pas par exécution.
- La release et SharedPark restent non terminés ; raccordement UI et workers natifs hors périmètre.

## Prochaine étape, hors de cette réponse
Codex récupère ce seul fichier de tests, compile069 (uniquement parce qu'il y a un changement), exécute la suite en VM, puis rend le diagnostic dans cette même session native. Ce lot013-FIX3 s'arrête ici.
