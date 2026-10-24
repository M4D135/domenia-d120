# SPARK-READY-007-FIX1 — correctifs du lot007 après la compilation VM044

Micro-mandat `SPARK-MICRO-007-FIX1.md`. OpenCode natif Spark, modèle `kbza/spark-local`, même session que les lots006, 006-FIX2 et 007.
État de départ : snapshot044 — **Debug en échec, 5 × CS1061 sur `string.Repeat`** (lignes 55 deux occurrences, 146, 260, 262),
0 avertissement, Release non tenté, **aucun test exécuté** (`build-codex-team-044.log`). Les deux défauts de lecture confirmés sont
corrigés dans les mêmes deux fichiers. Aucun inventaire, aucun build, aucun test, aucune exécution sur Spark ou Mac.

**lecture locale seulement ; aucune publication ni synchronisation native validée.**

## 1. Diagnostics du compilateur (CS1061) corrigés

`string` n’a pas de méthode `Repeat` et aucun helper correspondant n’existe dans `TestRunner`/`TestSupport`. Les cinq occurrences
(`"A".Repeat(64)`, `"B".Repeat(64)`, `"0".Repeat(64)`) utilisent maintenant une construction C# existante :

- `new string('A', 64)` et `new string('B', 64)` dans le helper `Row` (empreintes de conservation factices) ;
- `new string('A', 64)` dans l’assertion « l’empreinte exhaustive des lignes lie l’empreinte » ;
- `private static readonly string OtherStore = new('0', 64);` (target-typed `new`), réutilisé pour le `store_id` étranger et pour
  l’assertion « le store lie l’empreinte ».

Aucune dépendance ajoutée, aucun helper nouveau dans `TestSupport` (fichier non touché), aucun `using` superflu.

## 2. Fixtures SQL rendues compatibles avec le schéma 11 réel

`park_state` est créé par `schema-11.sql` avec **six colonnes** : `computer_key,computer,last_probe,status,user_login,attempts`.
Le helper unique à huit colonnes faisait échouer la plupart des cas avant leur assertion. Les insertions sont maintenant séparées :

- `Insert(...)` — **six colonnes**, le vrai cas D1 (aucune colonne native requise) ;
- `InsertGuid(...)` — sept colonnes, requiert `computer_guid` ;
- `InsertIdentified(...)` — huit colonnes, requiert `computer_guid` **et** `computer_dn` ;
- `AddGuidColumn(db)` et `AddIdentityColumns(db)` — les `ALTER TABLE` ne sont exécutés **que** dans les fixtures qui en ont besoin.

Appels vérifiés un par un :

| cas | insertion | colonnes ajoutées |
|---|---|---|
| héritée sans table d’état, native (store/domaine/révision/génération), jamais migratrice, domaine/store étranger, révision illisible, date absente, sentinelle, futur, statut vide, nom avec espace, compteur négatif, annulation préalable, extension D1 | `Insert` | aucune (six colonnes réelles) |
| lignes illisibles (GUID non parsable) | `InsertGuid` | `AddGuidColumn` (une seule colonne) |
| deux homonymes | `InsertIdentified` pour la ligne prouvée, `Insert` pour `shared:PC1` | `AddIdentityColumns`, **une seule fois** (pas d’ALTER en double) |

Le cas `Rejected_rows…` n’ajoute plus que `computer_guid`, comme son contenu l’exige. Le cas natif ajoute en outre une assertion
explicite `Check.Equal("computer_key|computer|last_probe|status|user_login|attempts", Columns(db), …)` : la fixture D1 reste bien à six
colonnes. **Le schéma du produit n’a pas été modifié** pour faire passer les fixtures, et la lecture ne crée aucune colonne (déjà
vérifié par le test « jamais migratrice »).

## 3. Annulation suivie jusqu’à la qualification

`ReadRelationSweeps` vérifie le jeton par page, mais la qualification parcourait ensuite jusqu’à 50 000 lignes sans le recevoir.

- `internal SharedParkLocalRead QualifySharedParkLocal(RelationSweepCacheSnapshot sweeps, long revision, bool legacy, CancellationToken token = default)` ;
- `token.ThrowIfCancellationRequested()` à l’entrée, **à chaque ligne** du parcours, et **avant** le calcul de l’empreinte et le retour ;
- `ReadSharedParkLocalAsync` transmet son propre jeton à la qualification, puis le revérifie **avant `db.Commit()` et le retour** ;
- le paramètre reste optionnel, donc les cas synthétiques existants (sans base) l’utilisent sans changement d’écriture ;
- nouveau test `A_pre_cancelled_qualification_refuses_before_inspecting_any_row` : jeton déjà annulé → `OperationCanceledException`,
  y compris sur un instantané contenant une valeur pourtant refusée (prouve que l’annulation est vérifiée **avant** d’inspecter les
  lignes), et aucune base créée. Aucune minuterie, aucune attente, aucune suite lancée.

## Fichiers réellement modifiés dans ce tour

1. `v2/src/Domenia.Store/Sqlite/DomeniaDatabase.SharedPark.Read.cs` — signature et vérifications d’annulation de `QualifySharedParkLocal`,
   jeton transmis et revérifié dans `ReadSharedParkLocalAsync`. Règles de refus, empreinte liée, transaction de lecture unique et
   primitives réutilisées inchangées.
2. `v2/tests/Domenia.Tests/SharedParkLocalReadTests.cs` — 15 tests (14 + la qualification préannulée) : constructions `new string(...)`
   à la place de `Repeat`, helpers d’insertion 6/7/8 colonnes, `ALTER` ciblés.
3. `v2/docs/reprise/SPARK-READY-007-FIX1.md` — le présent rapport. `SPARK-READY-007.md` n’a pas été modifié (rapport historique).

## Limites (à ne pas déclarer faites)

- Ces 15 tests sont **écrits, non exécutés et non compilés ici**. Ce document n’affirme aucune compilation réussie : Debug a échoué en
  VM044 sur les cinq CS1061, Release n’a jamais été tenté. C’est à Codex de recompiler **Debug et Release** et de renvoyer les diagnostics.
- Les suites restent à la fin, dans la VM Windows. Aucune E2E simulation, aucune recette domaine, aucune UI, aucune livraison PROD/DEV.
- Rien n’a été raccordé : `CompatibleDirectoryCache.SharedPark.cs` reste intact et hors compilation (quatre méthodes absentes de
  `DomeniaDatabase`), aucun stub. Pas de fusion par nom/date, pas d’aperçu lié aux SHA, pas de contrôle de chemin/reparse point, pas de
  sauvegarde, pas d’intention durable ni de publication SMB, pas de double CAS, pas de SHA relu ni de reçu, pas d’état incertain durable,
  aucun branchement natif/simulation/UI.
- Aucun produit exécuté, aucun téléchargement, service, runtime ou réseau modifié, aucun sous-agent, autre fournisseur,
  commit/push/reset/clean ; `dev/` en lecture seule, WAPT exclu ; aucune écriture AD dans ce tour.
