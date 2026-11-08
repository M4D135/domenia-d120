# SPARK-READY-006-FIX2 — corrections demandées après la compilation VM042

Micro-mandat `SPARK-MICRO-006-FIX2.md`. OpenCode natif Spark, modèle `kbza/spark-local`, même session que le lot006.
État de départ : snapshot042 compilé **Debug et Release dans la VM Windows, 0 avertissement, 0 erreur, 62 s** (`build-codex-team-042.log`),
SHA vérifiés contre le baseline, WIP concurrents conservés, **aucune suite exécutée**. Les trois défauts ci-dessous venaient de la lecture,
pas du compilateur ; ils sont corrigés directement, sans réinventaire.

**codec seulement ; aucune publication ni synchronisation native validée.**

## Défaut 1 — le test « un BOM initial » n'écrivait aucun BOM (corrigé)

`new UTF8Encoding(encoderShouldEmitUTF8Identifier: true).GetBytes(text)` ne préfixe **pas** le préambule : cet identifiant n'est émis
que par les écrivains de flux (`StreamWriter`), jamais par `GetBytes`. Le helper `Write` livrait donc les octets tels quels : le test
passait sans exercer le BOM.

- helper retiré (`WithMark`) et paramètre `encoding` devenu inutile retiré de `Write` ;
- nouveau helper `Prefixed(string text, int marks)` qui **fabrique réellement** les octets `EF BB BF` avant le corps UTF-8 strict ;
- assertions indépendantes sur les octets du fichier, avant toute lecture : `Convert.ToHexString` des trois premiers octets vaut `EFBBBF`
  pour le cas valide, et les six premiers valent `EFBBBFEFBBBF` pour le cas refusé ;
- le contenu au-delà du préambule est comparé octet pour octet à la ligne attendue (`SequenceEqual`), puis la lecture est vérifiée
  (valeur lue sans caractère caché résiduel) ;
- le test du second BOM garde sa comparaison des octets source après le refus. Aucun des deux cas ne repose plus sur un encodage qui ne préfixait rien.

## Défaut 2 — le cas « sept colonnes » n'en avait que six (corrigé)

`Line(..., probedBy: null)` produit cinq colonnes ; `+ "\textra"` n'en faisait donc que six : le refus attendu aurait été un faux échec
dans la suite finale.

- les trois cas sont maintenant construits explicitement et **vérifiés avant l'appel** : `four.Split('\t').Length == 4`,
  `six.Split('\t').Length == 6`, `seven.Split('\t').Length == 7` ;
- le cas valide à **six colonnes** est conservé dans ce test et doit être accepté (une ligne lue), en plus du test dédié
  `Six_column_lines_keep_the_console_that_probed` ;
- le refus des sept colonnes vérifie le message (`Ligne TSV partagée invalide`) et la conservation des octets source.

## Défaut 3 — U+FEFF accepté dans les valeurs (corrigé, et rapport006 rectifié par le présent document)

Le rapport006 historique affirmait qu'un BOM en cours de fichier restait refusé par `Validate` : c'était **faux**, `char.IsControl('\uFEFF')`
valant `false`. Le caractère caché était donc accepté dans le statut, l'utilisateur et la console.

- `SharedParkFile.Validate` refuse désormais `U+FEFF` dans `Status`, `User` et `ProbedBy`, en **lecture comme à l'encodage** (même règle,
  un seul point de contrôle) ; le nom de poste était déjà couvert par la règle ASCII stricte ;
- le contrat annoncé « au plus un BOM, au tout début » est ainsi réellement appliqué : le préambule unique est retiré par `Decode` avant
  `Validate`, tout autre `U+FEFF` est refusé, **sans remplacement silencieux** et sans réécriture du fichier ;
- nouveau test `A_hidden_byte_order_mark_inside_a_value_is_refused_on_reading_and_on_writing` : les trois champs sont exercés
  (`LU\uFEFF`, `\uFEFFalm`, `console\uFEFFatelier`), avec comparaison des octets source avant/après la lecture refusée, un refus à l'écriture
  pour chacun, et un cas témoin prouvant que les mêmes champs sans `U+FEFF` restent valides ;
- le BOM initial valide reste accepté (défaut 1 corrigé, test renforcé en conséquence).

## Fichiers réellement modifiés dans ce tour

1. `v2/src/Domenia.Store/Sqlite/SharedParkFile.cs` — `Validate` durci sur `U+FEFF` (statut, utilisateur, console) ; commentaire et
   `summary` de `Decode` mis en conformité avec le contrat réellement appliqué. Aucune autre méthode touchée : bornes 16 Mio / 50 000 /
   4 096, refus des doublons de casse et des dates sentinelles à l'encodage, UTF-8 strict, lecture D1 à 5 ou 6 champs, verrou sans vol
   et sans rejeu automatique restent tels que compilés en 042.
2. `v2/tests/Domenia.Tests/SharedParkFileTests.cs` — 23 tests (22 + le nouveau cas `U+FEFF` dans les valeurs) : fabrication réelle des
   préambules, assertions sur les octets du fichier, recomptage des colonnes 4/6/7, cas `U+FEFF` par champ.
3. `v2/docs/reprise/SPARK-READY-006-FIX2.md` — le présent rapport. `SPARK-READY-006.md` n'a **pas** été modifié (rapport historique).

Contrat Core (`ISharedParkStore.cs`) inchangé : aucune erreur de compilation ne le demandait.

## Tests écrits, non exécutés

Les 23 tests sont écrits, ni exécutés ni compilés ici. Toujours aucun réseau, aucune base SQLite, aucun LDAP, aucune attente réelle de
3 secondes (verrou occupé exercé par annulation). Découverte par réflexion, API `Check` existante, `InternalsVisibleTo` déjà en place.

## Limites (à ne pas déclarer faites)

- Codec seulement : **aucune publication SMB, aucune synchronisation native validée**, aucun SHA relu, aucun double CAS, aucune intention
  locale durable, aucune sauvegarde vérifiée, aucun contrôle de chemin/reparse point, aucun reçu ni état incertain durable.
- `v2/src/Domenia.Store/Sqlite/CompatibleDirectoryCache.SharedPark.cs` reste intact et **hors compilation** : il appelle encore quatre
  méthodes absentes de `DomeniaDatabase`. Aucun stub, aucun faux raccordement.
- Le TSV ne porte ni domaine ni GUID : un nom partagé n'est jamais une identité AD ; l'observation externe `shared:<poste>` sans GUID
  n'est pas implémentée.
- Suites de tests non exécutées (phase finale) ; aucune recette domaine, aucune UI, aucune E2E simulation, aucune livraison PROD/DEV.
  Ce document n'affirme aucune compilation réussie pour ce FIX2 : c'est à Codex de recompiler Debug et Release dans la VM et de renvoyer
  les diagnostics complets à cette même session.
- Aucun build, test ou exécution du produit sur Spark ou Mac ; aucun téléchargement, service, runtime ou réseau modifié ; aucun
  sous-agent, autre fournisseur, commit, push, reset ou clean ; `dev/` non touché ; aucune écriture AD dans ce tour.
