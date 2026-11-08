# SPARK-READY-013-FIX2 — un seul test remplacé, aucune production touchée

FIX1 a terminé naturellement (READY, reason=stop, sans erreur publique). Les deux fichiers récupérés ont été comparés au manifeste `codex-team-067-manifest.json` avant édition et trouvés identiques. Ce lot ne change que le test faux positif signalé par la revue, plus le présent rapport.

## Périmètre réellement touché par FIX2
- `v2/tests/Domenia.Tests/BridgeSchedulingTests.cs` — une seule méthode `[Test]` remplacée (`The_capture_delegate_is_invoked_outside_the_gate_that_protects_the_queue`), aucune autre méthode touchée, le fichier reste à 26 méthodes `[Test]`.
- `v2/docs/reprise/SPARK-READY-013-FIX2.md` (ce rapport)

Aucune modification de production : `v2/src/Domenia.Bridge/BridgeAdmission.cs` vérifié au SHA067 `7b82929f69d55f2e3addd490be06a914e1dbfea28dd1f158a4b14aabeb0464eb` avant et après ce lot. Aucun autre fichier, aucune fixture, aucune garde de production, aucun autre WIP. Aucun build, aucun test, aucune exécution de mutation, aucun téléchargement, aucun service/runtime/réseau, aucun commit, push, reset ou clean. `dev/` est resté en lecture seule.

## Correction d'une affirmation du rapport FIX1 (archive non réécrite)
`SPARK-READY-013-FIX1.md` affirmait qu’un appel depuis l’intérieur du délégué « se auto-bloquait sur le `Lock` non réentrant ». **Cette affirmation est incorrecte** et n'est pas corrigée dans l'archive, qui reste telle quelle.

Source primaire : `https://learn.microsoft.com/en-us/dotnet/api/system.threading.lock?view=net-10.0` — `System.Threading.Lock` autorise explicitement les entrées récursives depuis le même thread. Le test FIX1 appelait `Load` et `CancelQueued` sur le thread même du fournisseur : il passait donc aussi avec l’ancien appel sous gate, par simple réentrance. Il ne démontrait rien malgré son titre ; c'était un faux positif de couverture.

## Nouveau test : interleaving réellement discriminant entre threads
`The_capture_delegate_is_invoked_outside_the_gate_that_protects_the_queue` (BridgeSchedulingTests.cs:524-582) :

- huit places réseau sont d'abord réellement tenues (`Hold(admission, 8)`), donc rien ne peut être admis ;
- `pending` est mis en file sur le thread du test (empreinte rendue immédiatement, sa promotion ne suspend pas) ;
- `blocked` est entré sur un **thread dédié** (`Task.Run`) : sa capture individuelle est la troisième, et son préambule se parque sur ce thread (`releasePreamble.Task.Wait(10 s)`, attente bornée servant de garde de panne, jamais un sommeil) ;
- **barrière 1** : `insidePreamble` est signalé depuis l'intérieur du préambule, ce qui prouve que le préambule tourne bien sur son thread dédié et que `blocked` est déjà en file ;
- **barrière 2** : un **autre thread** (`Task.Run`) lit `Load.Queued`, appelle `CancelQueued("pending")`, relit `Load.Network`, le tout attendu par `WaitAsync(5 s)` ;
- les trois valeurs sont capturées **avant** toute libération du préambule, et `Check.False(releasePreamble.Task.IsCompleted, ...)` le vérifie explicitement ;
- motifs vérifiés : `seen.Queued == 2`, `seen.Withdrawn == true`, `seen.Network == 8`, file réduite à 1 côté test, `pending` rend `OperationCanceledException` dont le `CancellationToken` est **celui de cette seule lecture** (retrait local, pas une annulation générique), `handlerCalls == 0` ;
- `finally` : le préambule est **toujours** libéré (`releasePreamble.TrySetResult()`), les deux lectures encore en file sont retirées (`CancelQueued`, idempotent, jamais un départ déjà parti), les deux tâches sont attendues et leurs exceptions observées (`Task.WhenAll(...).ContinueWith(..., TaskScheduler.Default)`), puis les huit places sont relâchées. Aucune tâche, aucun thread et aucune demande ne survivent, y compris si une assertion échoue ou si la garde bornée déclenche.

### Pourquoi ce scénario discrimine
- **Ancien code** (`qualifying++ ; captureSession(...)` dans le `lock (gate)`) : le thread dédié tient la porte en se parquant ; le thread interferent se bloque sur `Load`/`CancelQueued`, la garde de 5 s expire, `TimeoutException` est convertie en `TestFailureException` avec le motif précis → **le test échoue**.
- **FIX1** (réservation sous gate, invocation hors gate) : le thread interferent lit la file et retire `pending` immédiatement, avant toute libération du préambule → **le test réussit**.
- La garde bornée garantit qu'une régression échoue au lieu de suspendre la suite ; le `finally` libère le préambule dans les deux cas, donc aucun thread n'est laissé bloqué derrière la porte.

Les trois autres tests ajoutés par FIX1 et les 22 tests antérieurs sont conservés sans modification.

## Tests : état réel
Aucun test exécuté ici, aucune mutation tentée : la validation d'exécution reste finale en VM, selon la consigne de David. Le journal `build-codex-team-067.log` (Debug et Release verts, 0 warning, 0 erreur) correspond aux sources FIX1 et ne couvre pas ce remplacement.

## SHA
Avant FIX2 (manifeste `codex-team-067-manifest.json`, vérifiés identiques avant édition) :
- `v2/src/Domenia.Bridge/BridgeAdmission.cs` : `7b82929f69d55f2e3addd490be06a914e1dbfea28dd1f158a4b14aabeb0464eb` (inchangé)
- `v2/tests/Domenia.Tests/BridgeSchedulingTests.cs` : `378044fcb6bd9c2842dfb85d93ad06de8ecdaf2847a3f48dba2188337667a567`

Après FIX2 :
- `v2/src/Domenia.Bridge/BridgeAdmission.cs` : `7b82929f69d55f2e3addd490be06a914e1dbfea28dd1f158a4b14aabeb0464eb` (inchangé, non recompilé nécessaire)
- `v2/tests/Domenia.Tests/BridgeSchedulingTests.cs` : `d764b2c9bc30856f11138f2d644196a1de45a856917dd379870df2a1992b6fa6`

## Limites assumées
- Le nouveau test n'a jamais tourné : sa stabilité d'exécution (deux threads, garde de 5 s, minuteur réel de 250 ms de l'admission) reste à confirmer en VM.
- La minuteur réel de l'admission peut occasionnellement consommer l'appel de capture n°3 sur son propre thread ; le scénario garde alors les mêmes assertions et le même verdict (échec avec l'appel sous gate, succès avec FIX1), mais ce n'est pas vérifié par exécution ici.
- La production n'est pas revalidée par ce lot : elle reste celle de FIX1, compilée067.
- Les tests du lot013 restent tous non exécutés ; aucune couverture n'est affirmée comme obtenue.
- Le raccordement UI et les workers natifs restent hors de ce périmètre ; les autres WIP SharedPark et dispositions restent conservés, hors de cette correction.

## Prochaine étape, hors de cette réponse
Codex récupère ce seul fichier de tests, ne compile068 que parce qu'il y a un changement, exécute la suite en VM, puis rend le diagnostic dans cette même session. Ce lot013-FIX2 s'arrête ici.
