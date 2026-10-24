# Revue du journal d’intention 012B — capture 062

Le worker OpenCode natif a terminé normalement avec `stop`, sans erreur publique, avec deux fichiers et READY012B. Sources finales récupérées à l’identique, delta applicatif limité à ces deux fichiers, aucune suppression. Le rapport original est conservé ; ses déclarations ne constituent pas une validation.

Compilation dans la VM Windows seulement : Debug échoue sur deux CS1501, `File.Open` à six arguments (lignes 183 et 187), zéro avertissement. Release non tenté. Vingt tests écrits, aucun exécuté. Journal intégral `build-codex-team-062.log` et manifeste `codex-team-062-manifest.json`.

## Défauts confirmés à corriger

- `EnsureRootPhysical` et `QualifyAncestors` utilisent `Directory.Exists`/`parent.Exists` : un fichier à la place du root ou d’un parent et des erreurs d’accès peuvent être assimilés à une absence. Qualifier avec `File.GetAttributes` depuis les ancêtres, distinguer absence réelle, erreur et reparse. Qualifier le fichier avant de l’ouvrir, puis revérifier ; `Read` ouvre actuellement un lien avant de le refuser.
- `EnsureRootPrivate` crée d’abord le dossier sans protection explicite puis applique systématiquement `SetAccessControl`, même à un dossier existant. Le contrat exige de refuser une DACL existante incompatible sans mutation. Créer le nouveau dossier avec DACL dès la création, puis relire. `Read` doit aussi vérifier la DACL du root et du fichier tenu ; ce contrôle est absent.
- `AcquireLock` adopte un fichier existant avec `Open` et `DeleteOnClose`. Cela peut supprimer un verrou étranger/orphelin. Créer exclusivement son propre verrou, ne jamais voler/nettoyer un fichier existant, attente bornée/cancellable ; ne pas masquer toute IOException comme contention.
- `CountIntentions` refuse seulement lorsque le nombre existant dépasse 128 : la 129e création est donc admise. Refuser une nouvelle admission dès 128. Vérifier type, reparse et nom exact/ID de chaque entrée ; un dossier ou nom arbitraire avec la bonne extension est actuellement compté comme intention.
- `QualifiedRoot` ne rejette pas tous les composants Windows ambigus (noms DOS, espaces/points finaux, caractères interdits). Maintenir constructeur sans I/O et qualification stricte.
- Annulation et contexte : valider les attentes avant I/O, revérifier le token avant retour d’absence et aux étapes ; revalider la fenêtre temporelle après l’attente du verrou avant création. Une intention partielle reste conservée, jamais supprimée ni rejouée.
- Fixtures : `RecordedAt = T0 + 1 minute` tandis que toutes les horloges sont à `T0`. Les créations supposées positives échouent dans le codec avant d’exercer le journal. Corriger la chronologie des fixtures sans affaiblir la garde du codec.
- Le test d’un autre PlanId syntaxiquement valide mais absent attend une exception, alors que le contrat retourne `null`. Séparer absence et contexte/empreinte incompatible. Initialiser les tests d’entrée parasite depuis un vrai root privé pour ne pas échouer sur l’ACL avant le contrôle visé. Utiliser un chemin de sauvegarde inexistant unique au test.

API vérifiée dans la [source .NET 10](https://raw.githubusercontent.com/dotnet/runtime/v10.0.0/src/libraries/System.IO.FileSystem.AccessControl/src/System/IO/FileSystemAclExtensions.cs), lignes 88–100 : `FileSystemAclExtensions.Create(DirectoryInfo, DirectorySecurity)` fournit la protection à la création et laisse inchangé le dossier déjà présent. Les surcharges fichier et `GetAccessControl(FileStream)` figurent dans cette même source.

## Renfort autorisé

David a demandé le 24 octobre 2026 « donne un coup de boost avec tes agents ». Trois agents Codex aux fichiers distincts prennent respectivement production012B, tests012B et sauvegardes physiques du lot suivant. Aucun nouveau worker Spark lancé en concurrence. Le relais natif, son historique et ses sources sont conservés. Root assure revue, captures, compilation VM et intégration. Capture suivante 063 après correction ; sauvegardes dans une capture distincte. Aucun commit/publication du lot062 en échec.

## Correction Codex et compilation 063

Les deux agents ont corrigé les défauts ci-dessus dans les deux seuls fichiers du journal et de ses tests. Le verrou est créé exclusivement ; un verrou présent est attendu sans ouverture ni suppression. Les collisions 32/80/183 sont bornées ; les erreurs d’accès restent propagées. La qualification avant/après ne prétend pas éliminer atomiquement toute substitution hostile des ancêtres. Les sauvegardes physiques restent un lot distinct.

Snapshot063 compilé dans la VM Windows, Debug et Release : zéro avertissement, zéro erreur, 72 secondes. Vingt-neuf tests comportementaux écrits et compilés ; aucun exécuté. Les preuves062/063 conservent aussi l’échec initial. Aucun catalogue promu sur la seule compilation ; aucun succès de publication ou de recette déduit du journal.

SHA des deux sources compilées :
- v2/src/Domenia.Store/Sqlite/SharedParkIntentJournal.cs : `bd3610e02d990456a3be906c8d58468230fbc90a2b6305464ebfe797e44e1ba5`
- v2/tests/Domenia.Tests/SharedParkIntentJournalTests.cs : `d7407e496269472aed9017d95272204a151772b15545a7895e2cb6aa880b16be`
