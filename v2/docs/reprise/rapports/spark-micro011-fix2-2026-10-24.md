# SPARK-READY-011-FIX2 — assertion SQLite précisée, puis rapport

## Périmètre réellement touché par FIX2
- `v2/tests/Domenia.Tests/SharedParkPreviewTests.cs`
- `v2/docs/reprise/SPARK-READY-011-FIX2.md`

Aucun autre fichier applicatif, aucune fixture, aucune garde de production et aucun autre test n’ont été modifiés dans ce FIX2. Aucun build, aucun test, aucun téléchargement, aucun service/runtime/réseau, aucun commit, push, reset ou clean n’a été exécuté ici. `dev/` est resté en lecture seule et WAPT est exclu.

## Delta FIX2
Dans la seule méthode `A_non_sqlite_base_is_refused_and_no_reservation_is_retained` :

- remplacement de `Check.ThrowsAsync<Exception>` par `Check.ThrowsAsync<SqliteStoreException>` ;
- suppression des exclusions devenues inutiles `ex is TestFailureException` et `ex is OperationCanceledException` ;
- ajout de la vérification du code primaire SQLite :
  `Check.Equal(26, ex.SqliteCode & 255, "le refus vient du code primaire SQLite SQLITE_NOTADB");`
- conservation des vérifications déjà présentes :
  - SHA du fichier corrompu avant/après l’aperçu ;
  - absence de répertoire de spool ;
  - compteurs globaux `SharedParkPreviewFile.ActiveLeases` et `SharedParkPreviewFile.ReservedBytes` avant/après.

La source primaire vérifiée pour cette assertion est `https://www.sqlite.org/rescode.html#notadb`, qui définit `SQLITE_NOTADB` comme la valeur primaire `26`. Le fichier complet `v2/src/Domenia.Store/Sqlite/SqliteDatabase.cs` joint montre que `SqliteStoreException` est publique, expose `SqliteCode`, et que `Check` transmet le code natif SQLite.

## État des gardes MICRO011-FIX1 récupérées
Les deux corrections FIX1 sont présentes et inchangées dans les sources de production :

1. `v2/src/Domenia.Store/Sqlite/DomeniaDatabase.SharedPark.Read.cs`
   - `LocalBaseAbsent` qualifie d’abord la racine réelle ;
   - les composants du chemin sont ensuite qualifiés dans l’ordre ;
   - une absence réelle n’est admise que pour un terminal manquant ou un composant manquant sous des parents déjà qualifiés ;
   - une racine indisponible, un reparse, un composant non répertoire, une erreur d’accès ou une erreur IO refusent la lecture sans la transformer en absence ;
   - rien n’est créé sur ce chemin.

2. `v2/src/Domenia.Store/Sqlite/DomeniaDatabase.SharedPark.Preview.cs`
   - `SharedParkPreviewSpool` est construit et qualifié avant `SharedParkRemoteReader.Validate`, la lecture locale et la lecture distante ;
   - le constructeur du spool ne crée aucun fichier ;
   - les protections utilisent `spool.Root` canonique ;
   - un spool local invalide est donc refusé avant toute lecture du TSV ;
   - aucune création de spool n’intervient avant la validation du TSV.

Le Core compact `v2/src/Domenia.Core/Screens/Sync/ISharedParkStore.cs` reste inchangé.

## Tests
- `v2/tests/Domenia.Tests/SharedParkPreviewTests.cs` contient 20 méthodes `[Test]`.
- Ces 20 tests sont écrits et compilés dans la VM055, mais aucun n’a été exécuté ici.
- La compilation VM055 est antérieure à la dernière assertion FIX2 sur `SqliteStoreException.SqliteCode`.

## Preuve VM055 antérieure à cette assertion
Le journal `v2/docs/reprise/build-codex-team-055.log` montre :

- lot `spark-native`, build en VM Windows ;
- Debug réussi ;
- Release réussi ;
- `0 Warning(s)` ;
- `0 Error(s)` ;
- durée totale annoncée : 33 secondes.

Le manifeste `v2/docs/reprise/codex-team-055-manifest.json` a compilé les trois sources FIX1 avec ces SHA :

- `v2/src/Domenia.Store/Sqlite/DomeniaDatabase.SharedPark.Read.cs` : `79cb72334b6d116e864a286476397b2dc0bc5a7342f3b6cff241c31a9a4c5226`
- `v2/src/Domenia.Store/Sqlite/DomeniaDatabase.SharedPark.Preview.cs` : `896e5826cc1a8badc61cba6ab154af4004e46916e93cceacfda85fa6e6663e4f`
- `v2/tests/Domenia.Tests/SharedParkPreviewTests.cs` : `079f8bcad33d85cdf49fd19fbb205e269e29ecdc1fc515c561262fd63714a8b9`

Après la présente édition FIX2, les SHA locaux sont :

- `v2/src/Domenia.Core/Screens/Sync/ISharedParkStore.cs` : `6cab8d275d74436d031f9b9b6aefdad1293c5ca5d24d6eaf1f7b5ed0925ca7ec`
- `v2/src/Domenia.Store/Sqlite/DomeniaDatabase.SharedPark.Read.cs` : `79cb72334b6d116e864a286476397b2dc0bc5a7342f3b6cff241c31a9a4c5226`
- `v2/src/Domenia.Store/Sqlite/DomeniaDatabase.SharedPark.Preview.cs` : `896e5826cc1a8badc61cba6ab154af4004e46916e93cceacfda85fa6e6663e4f`
- `v2/tests/Domenia.Tests/SharedParkPreviewTests.cs` : `b3ab26ad3644c9aa24ea8abbf3a3ec0a219c354c5c7e4f254e96eb8922947e08`

Le nouveau SHA du fichier de tests n’est donc pas encore compilé : il attend le retour VM056 de Codex.

## Limites assumées
- Ce rapport ne fabrique aucun historique `SPARK-READY-011` ou `SPARK-READY-011-FIX1` qui n’aurait pas été réellement produit.
- La compilation VM055 ne prouve pas la compilation de la dernière assertion FIX2 ; elle prouve seulement l’état candidat FIX1 récupéré.
- Les tests ne sont pas exécutés ici.
- La publication durable n’est pas encore implémentée.
- Le raccordement cache/annuaire/simulation/UI n’est pas encore fait.
- La recette finale des deux VM n’est pas encore validée.
- Aucun accès AD, aucune ouverture de partage, aucun réseau et aucune simulation ne sont engagés par ces tests d’aperçu.

## Prochaine étape, hors de cette réponse
Codex doit compiler ce delta FIX2 en VM056, puis poursuivre le protocole durable et le reste de Domenia jusqu’à la validation des deux VM. Ce lot FIX2 s’arrête ici.
