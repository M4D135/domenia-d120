# READY 012A-FIX3 — deux fixtures isolées, puis terminaison

Micro-tâche FIX3 terminée côté OpenCode. Édition du **seul** fichier
`v2/tests/Domenia.Tests/SharedParkIntentDocumentTests.cs` + ce rapport. Aucun changement de code
production (les sources finales restent exactement celles de060, compilées Debug/Release VM zéro
avertissement/erreur en51s). Aucun autre fichier touché. Périmètre pur conservé : aucune I/O, aucune
compilation ni exécution de test ici. Codex compile061 sous Windows.

## Deux fixtures rendues réellement isolées

`Missing_sqlite_backup_key_is_refused` et `Missing_tsv_backup_key_is_refused` construisaient un batch
aux **deux** drapeaux `false` mais fournissaient une référence **non nulle** pour l’autre sauvegarde
(`tsv: BackupNode(Tsv())` / `sqlite: BackupNode(Sqlite())`). Le refus pouvait donc venir d’une
incohérence drapeau/référence plutôt que de la garde de présence de clé : faux positif possible si
cette garde régressait.

Chaque test est réécrit pour isoler la seule variable testée :

- batch absent cohérent `MakeBatch(localExists: false, remoteExists: false)` ;
- `IntentNode(batch, sqlite: null, tsv: null)` — les deux références en `null` explicites, `batchFingerprint`
  recalculé depuis **ce même** batch ;
- **lecture positive préalable** `Dec(Wrap(node))` du document complet (le test échoue si elle lève), avec
  vérification que la référence visée est bien `null` ;
- retrait d’**une seule** clé (`node.Remove("sqliteBackup")` / `node.Remove("tsvBackup")`) puis refus
  `InvalidDataException` sur `Dec(Wrap(node))` — l’enveloppe est **recalculée après suppression** (digest
  refait sur le nœud modifié).

Le document accepté et le document refusé ne diffèrent plus que par la présence de la clé visée : le refus
est imputable à la seule garde de présence. Aucun autre remaniement, aucun test ajouté ni retiré.

## Tests écrits (40), exécutés : 0

40 méthodes `[Test]` dans `SharedParkIntentDocumentTests` (inchangé en nombre). Refus précis
(`ArgumentException` / `InvalidDataException` / `OperationCanceledException`), jamais d’avale-tout. Les
cas structurels sont fabriqués avec digest recalculé pour que seul le défaut testé se déclenche.

## Attente Codex

Aucun build/test lancé ici (ni Spark ni Mac). Compilation Windows, revue et intégration à la charge de
Codex (retour061). Aucune dépendance/service/runtime/réseau/agent/fournisseur ajouté ; dev/ en lecture
seule, WAPT exclu ; aucun `git commit/push/reset/clean`. Les suites ne sont pas encore exécutées ; aucune
persistance ni publication validée. `SharedParkIntentJournal` (012B) et la suite restent à faire.
