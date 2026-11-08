# SPARK-READY-014-FIX1 — requalification d'expiration avant publication, test écrit, rien d'exécuté

Le micro-correctif 014-FIX1 reprend **uniquement** les deux fichiers autorisés par le mandat, à partir des sources jointes `FULLSPARK014-FIX1-SOURCES.txt` et du dépôt courant. Aucun inventaire général, aucune relecture des anciens bundles, aucun build, aucun test exécuté, aucun téléchargement, aucun service/runtime/réseau, aucun accès AD ni partage réel, `dev/` en lecture seule, WAPT exclu, aucun autre agent/modèle/fournisseur, aucun `commit`/`push`/`reset`/`clean`.

## Fichiers réellement touchés par ce micro-correctif

Après édition (SHA-256) :

| Fichier | SHA-256 | Lignes |
|---|---|---|
| `v2/src/Domenia.Store/Sqlite/DomeniaDatabase.SharedPark.Apply.cs` | `53f7fd6ea6689c3db4bb1aeb1d507acc294e11aa4aeb69d8c20ec99f7b4ae5a7` | 248 |
| `v2/tests/Domenia.Tests/SharedParkApplyTests.cs` | `8e35c3756f0a739c9896be58eba78365bc1c62dea7faf41854fd3b6741635fba` | 406 |
| `v2/docs/reprise/SPARK-READY-014-FIX1.md` (ce rapport) | — | — |

Baseline avant correction, identique au manifeste 070 :

- `DomeniaDatabase.SharedPark.Apply.cs` : `41af1a976987851016a5e1dee50831aebd940bdc31a6346a3066307814eef5b1`
- `SharedParkApplyTests.cs` : `0a27d234dee6e4a483ee596c967d1dea2de5c9a4f443218aaf38c746a5dfd3e7`

Aucun autre fichier n'a été ouvert en écriture pendant ce micro-correctif. `DomeniaDatabase.SharedPark.Verify.cs`, `SharedParkPublicationFile.cs`, le wrapper `CompatibleDirectoryCache.SharedPark.cs`, les WIP existants et les protections temporaires/preuve restantes ne sont pas modifiés.

## 1. Correction demandée : expiration requalifiée après le checkpoint `BeforePublication`

Le point de contrôle `BeforePublication` est exécuté après la construction de `SharedParkPublicationFile`, donc après préparation du temporaire frère et du dossier de preuve. Avant ce correctif, la dernière validation temporelle `ValidateSharedParkPlan(plan, batch, current: true)` était antérieure à cette construction et au checkpoint.

La garde ajoutée est placée **après** `checkpoint?.Invoke(SharedParkApplyStage.BeforePublication)` et **avant** `publication.Publish(...)` :

```csharp
checkpoint?.Invoke(SharedParkApplyStage.BeforePublication);
token.ThrowIfCancellationRequested(); validateSource();
ValidateSharedParkPlan(plan, batch, current: true);
publication.Publish(token, () => checkpoint?.Invoke(SharedParkApplyStage.NativeReplaceWindow));
```

Position exacte : `v2/src/Domenia.Store/Sqlite/DomeniaDatabase.SharedPark.Apply.cs:116`.

Ce `ValidateSharedParkPlan(..., current: true)` requalifie bien les deux bornes :

1. `ValidateSharedParkBackupBatch(batch)` vérifie `batch.CreatedAt <= now < batch.ExpiresAt` ;
2. la clause finale de `ValidateSharedParkPlan` vérifie `plan.CreatedAt <= now < plan.ExpiresAt`.

Le refus intervient avant tout `Publish`, donc `Attempted` reste `false`, le CAS et le chemin `Unknown` ne sont ni déplacés ni affaiblis. La vérification à froid des intentions expirées reste inchangée.

## 2. Test précis ajouté, horloge réellement injectée

Le fichier de tests expose maintenant l'horloge réellement passée à `DomeniaDatabase` :

```csharp
internal FixedTimeProvider Clock { get; }
private Setup() { Clock = TestClock.Fixed(); Db = new(Folder.File("store.db"), Fixtures.Root, Clock); }
```

Position : `v2/tests/Domenia.Tests/SharedParkApplyTests.cs:25-28`.

Nouveau test : `An_expiration_reached_during_the_publication_preparation_is_refused_before_any_rename`, lignes `321-349`.

Il avance l'horloge réellement utilisée par le Store au checkpoint `BeforePublication`, donc après construction du temporaire et du dossier de preuve, mais avant `Publish`. Deux avances discriminent les deux bornes :

- `7` minutes : le plan de 5 minutes est expiré, le message attendu contient `Plan de partage` ;
- `20` minutes : le lot de 10 minutes est expiré, le message attendu contient `Lot de sauvegarde`.

Dans les deux cas, le test vérifie :

- la frontière `BeforePublication` est réellement atteinte ;
- l'exception est `InvalidDataException` et contient `expiré` ;
- la borne exactement atteinte est distinguée (`Plan de partage` ou `Lot de sauvegarde`) ;
- le TSV reste octet pour octet identique à l'état avant `Apply` ;
- aucune observation externe n'est écrite : `Sweeps.Rows.Length == 1` ;
- aucune révision locale n'est engagée : `Revision == 0` ;
- aucune table de reçus n'est créée : comptage `sqlite_master` sur `domenia_v2_shared_park_receipts` égal à `0` ;
- l'intention durable est conservée, donc les copies initiales ne sont pas nettoyées silencieusement ;
- aucun `previous.tsv` n'existe, puisqu'aucun remplacement n'a été tenté ;
- `VerifySharedParkConfirmedAsync` renvoie `Unknown`, même avec l'horloge avancée, car l'intention existe sans reçu commis.

## 3. Vérifications statiques locales, sans exécution

- `SharedParkApplyStage.BeforePublication` existe et est bien la frontière immédiatement avant `Publish`.
- `ValidateSharedParkPlan` appelle `ValidateSharedParkBackupBatch` quand `current: true`, puis teste l'expiration du plan.
- `WritePlans.Lifetime` est bien de 5 minutes et `PreviewLifetime` de 10 minutes, d'où les avances 7/20 minutes.
- `FixedTimeProvider.Advance` existe et l'instance est bien celle injectée dans `DomeniaDatabase`.
- `Check.Contains`, `Check.ThrowsAsync`, `SqliteDatabase(path, readOnly)`, `SqliteDatabase.Scalar`, `ReadSharedParkLocalAsync`, `VerificationState.Unknown` et `SharedParkApplyStage` existent avec les signatures utilisées.
- Le nombre de méthodes `[Test]` dans `SharedParkApplyTests.cs` passe de 20 à 21.

## 4. Ce qui n'a pas été fait

- Aucun build, aucune compilation, aucune exécution de tests, aucune exécution de la suite existante.
- Aucun test n'a été lancé, y compris le nouveau test d'expiration.
- Aucun adaptateur manquant du wrapper `CompatibleDirectoryCache.SharedPark.cs` n'a été ajouté ou simulé.
- Aucune protection temporaire/preuve supplémentaire n'a été codée : elle reste un lot suivant.
- Aucune mutation de dépôt, aucun service, aucun runtime, aucun réseau, aucun AD, aucun SMB réel, aucun inventaire.
- Aucun `commit`, `push`, `reset` ou `clean`.

## 5. Suite hors de cette réponse

Codex relit les deux fichiers, puis compile071 via le canal VM autorisé. Le point à surveiller en priorité est le nouveau test d'expiration à la frontière `BeforePublication`, jamais exécuté ici. Ce micro-correctif s'arrête ici.
