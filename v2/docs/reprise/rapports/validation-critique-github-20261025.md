# Validation critique Windows via GitHub — 25 octobre 2026

## Dernier résultat attesté : CI critique verte

Commit testé : `1e877d650df71b37716b0b0840726238f632db7d`, branche `codex/v2-validation-critique-20261025`.
[Run 40224745081, job 121263620296](https://github.com/M4D135/domenia-d120/actions/runs/40224745081/job/121263620296) : **succès**.

| Contrôle | Résultat lu dans les journaux Windows |
| --- | --- |
| Debug | Réussi, zéro erreur et avertissement ; fin 19:11:34 UTC |
| Release | Réussi, zéro erreur et avertissement ; fin 19:12:10 UTC |
| C# critique | **587 réussis, zéro échec**, fin 19:13:15 UTC ; 1 792 tests hors sélection non exécutés |
| Garde de publication | **15 tests réussis**, code de sortie 0 ; fin 19:13:16 UTC |
| Deux VM du laboratoire | **Non exécuté / non vérifié** |
| Recette UI/native, AD/SMB réels | **Non exécuté / non vérifié** |
| Publication PROD/DEV v2.0.0 | **Non effectuée** |

Le `result.json` du job porte `debug`, `release`, `critical` et `releaseGuardCritical` à `passed`, les deux codes
de sortie à 0, `state` à `completed`, `portablePackage` à `false`, ainsi que `domainAcceptance`, `uiAcceptance`
et `twoVmAcceptance` à `not-run`. Windows : `win25-vs2026 / 20261021.278.1`, SDK préinstallé `10.0.402`,
Python préinstallé `3.12.10`. Aucune dépendance téléchargée. SHA256 de l'assemblage de tests exécuté :
`ca7cd8e6b6e055320a1e489cee1a856047b8f7f21fbc99902012619ee1325b2e`.

L'archive GitHub d'origine, artefact `12610717594`, est conservée sans modification dans
[`preuves-ci-20261025-1e877d65.zip`](preuves-ci-20261025-1e877d65.zip) : **26 539 octets**, SHA256
`6700b277f97fd1e73083c557f102b5c613b4ee7f7e42da82426a0482dfbf36cd`, identique au digest fourni par GitHub.
Elle contient les douze fichiers bruts du job : journaux Debug/Release, C# et Python, contexte SDK,
inventaire NuGet, restauration hors ligne, préparation de solution et `result.json`.
Les journaux PowerShell sont conservés dans leur encodage UTF-16 d'origine ; aucune ligne n'est retirée.
Cette archive est une preuve de CI, **pas un paquet PROD/DEV ni un dossier de recette des deux VM**.

La branche de validation reste au SHA testé. La mise à jour documentaire suivante ne modifie ni source,
test, réglage de compilation ni workflow ; elle conserve les preuves sans relancer les suites critiques.

## Préparation initiale et historique conservé

Le développement ciblé et le dossier de reprise ont été poussés sur `codex/v2-finalisation-20261025` au commit
`180b97c4b70a2bf0105e551500cd0a5d61d87c79`. L'arbre de travail est propre. Les corrections de compilation des
nouveaux tests sont incluses ; aucun test n'a encore été exécuté à l'écriture de cette demande.

La branche `codex/v2-validation-critique-20261025` a été créée depuis ce SHA. La création de référence seule
n'a pas lancé de workflow observable. Le push de cette demande documentaire sur la branche de validation
déclenche donc explicitement le workflow existant, après développement et push, sans changement applicatif.

Sélection demandée : compilation Windows Debug/Release, `Domenia.Tests.exe --critical`, puis les quinze tests
locaux de refus de `test_release_guard.py`. Les résultats devront être lus dans les journaux du SHA exécuté.
Aucun succès n'est présumé par la présente demande.

SDK et Python préinstallés, cinq paquets NuGet versionnés seulement ; aucune dépendance téléchargée et aucun
changement de service, runtime ou réseau. Aucune commande d'acceptation AD/native n'est lancée par ce workflow.
Deux VM du laboratoire et UI/native restent **NON VÉRIFIÉS**. Aucune publication PROD/DEV v2.0.0 ni SHA256 de
livraison finale n'est autorisée par cette exécution CI locale.

## Premier passage : sélection refusée avant toute exécution

SHA `ae1a5a1e4a1bdc64a5062e6952514d61b1e17800`, [run 40220222310](https://github.com/M4D135/domenia-d120/actions/runs/40220222310), job `121249987141`.
Journaux lus : Debug à 18:14:39 UTC et Release à 18:15:11 UTC, zéro erreur et zéro avertissement. Le harnais a ensuite
refusé la sélection avant tout test : une classe critique attendue était absente. Les quinze contrôles Python n'ont
donc pas été exécutés non plus.

Cause prouvée : `ReceiptStoreProtectionTests` était un nom de fichier ; ce fichier déclare la classe partielle
`ReceiptStoreTests`, avec les tests du magasin et de ses archives. Le sélecteur utilise désormais
la classe réelle `ReceiptStoreTests` sous forme de chaîne explicite, également relue par la garde de livraison : les
seize tests de la famille sont conservés. Le harnais affiche maintenant les noms
manquants et garde son refus avec code 2. Le script CI capture stderr sans interrompre la collecte des diagnostics,
conserve le code de sortie et distingue `selection-refused`, `failed` et `passed` dans son résultat. Aucun garde
n'est supprimé et aucun test n'est réputé réussi par ce correctif ; une nouvelle exécution critique est requise.

## Deuxième passage : première sélection réellement exécutée

SHA `27d7fccd456ea117dbc2a68a638e3a2e1bee6d03`, [run 40220607341](https://github.com/M4D135/domenia-d120/actions/runs/40220607341), job `121251158693`.
Journaux lus : Debug à 18:20:05 UTC, Release à 18:20:51 UTC, **0 erreur et 0 avertissement**. Le harnais a exécuté
**568 tests critiques sur 2 369 découverts** : **524 réussis, 44 en échec** à 18:22:11 UTC ; 1 801 tests non exécutés.
Code de sortie C# : 1. La garde Python n'a pas été exécutée après cet échec.

| Classe | Échecs observés |
| --- | ---: |
| `AdRelationProbeTests` | 7 |
| `AdSearchCheckpointTests` | 7 |
| `AutomationCommandTests` | 1 |
| `BoardLayoutHistoryTests` | 1 |
| `ConfigurationSeedTests` | 1 |
| `NativeSharedParkIntegrationTests` | 3 |
| `NativeStorageBackupTests` | 1 |
| `PlatformTests` | 2 |
| `PortableConfigurationTests` | 1 |
| `QueryPersonalProbeTests` | 1 |
| `QueryReferencePatchTests` | 1 |
| `ReferencePatchScopeTests` | 1 |
| `SharedParkApplyTests` | 16 |
| `SimulationIsolationTests` | 1 |

Les causes et corrections sont suivies dans les rapports `reprise-github-correctifs-critiques-*-20261025.md`.
Les assertions métier, protections d'identité, annulations, inconnus et absence de reprise automatique restent exigées.
Le coffre ayant une correction de production, sa famille `CredentialVaultTests` est ajoutée à la sélection critique.
Les corrections restent à recompiler et exécuter sur Windows après commit/push ; aucun échec de ce passage n'est effacé
ou requalifié en réussite. Les deux VM et la recette UI/native restent non vérifiées.

## Troisième passage : correctifs compilés, 21 échecs encore présents

SHA `ac56d748434c085ba2c8f5cf0c093d1f593f2002`, [run 40221973309](https://github.com/M4D135/domenia-d120/actions/runs/40221973309), job `121255294635`.
Journaux lus : Debug à 18:37:24 UTC et Release à 18:38:13 UTC, **0 erreur et 0 avertissement**.
La sélection critique a exécuté **583 tests sur 2 375 découverts** : **562 réussis, 21 en échec** à 18:39:37 UTC ;
1 792 tests hors sélection non exécutés. Code C# : 1 ; les quinze contrôles Python n'ont pas démarré.

Les échecs restants sont les 16 `SharedParkApplyTests`, les 3 `NativeSharedParkIntegrationTests`,
`NativeStorageBackupTests.Exported_backup_round_trip_recovers_its_exact_plan_named_preferences_annex` (SQLite code 14)
et `PlatformTests.Modules_of_the_bridge_are_found_without_any_central_list` (trois routes de Fiche absentes de l'attente).
Les diagnostics internes des 16 publications indiquent cette fois précisément un refus de conservation des droits de la
cible existante, avant le point `Published`. Les onze tests directs ACL sont verts, dont les nouveaux cas d'héritage et de
détention des répertoires : ils ne suffisent donc pas à clore le défaut du parcours complet.

Les familles AD Relations/Recherche, CLI, coffre, préférences atomiques, configuration portable, références et isolation
simulation corrigées passent dans cette sélection. L'historique des 44 échecs précédents reste conservé. Les nouvelles
corrections nécessitent à leur tour un commit/push puis un passage critique ; aucun paquet final ni validation des deux VM
ou de l'UI/native n'est déduit de ces résultats.

## Quatrième passage : sauvegardes et inventaire verts, ACL ancienne mesurée

SHA `bc4ff640fcdfb1e026e34c7e647412da70580dcb`, [run 40222981005](https://github.com/M4D135/domenia-d120/actions/runs/40222981005), job `121258369692`.
Journaux lus : Debug à 18:49:48 UTC et Release à 18:50:26 UTC, **0 erreur et 0 avertissement**.
La sélection critique a exécuté **585 tests sur 2 377 découverts** : **565 réussis, 20 en échec** à 18:51:47 UTC ;
1 792 tests hors sélection non exécutés. Code C# : 1 ; les quinze contrôles Python n'ont pas démarré.

Les huit cas `NativeStorageBackupTests` passent, y compris le parcours de restauration et le cas limite de longueur avec
refus avant création. L'inventaire complet des 497 opérations de Bridge passe également.

Les 20 échecs restent dans le parc partagé : 16 Apply, 3 intégrations et le nouveau cas conservant le parent Windows natif.
Le diagnostic distingue maintenant le changement réel : l'ancien descripteur `D:` contenant trois ACE héritées devient
`D:AI`, avec trois copies explicites de ces ACE ajoutées devant les trois héritées. Il ne s'agit donc pas seulement d'un
drapeau de descripteur. Aucune de ces ACE supplémentaires n'est acceptée par le contrôle courant. La conservation exacte
de la politique initiale nécessite un correctif puis un nouveau passage Windows ; les preuves précédentes restent intactes.

Recette critique sur les deux VM, UI/native et publication PROD/DEV v2.0.0 : **non validées**.

## Cinquième passage : les 587 tests C# critiques passent, lancement Python refusé

SHA `11eeab84068d079b4fd7c373e2308c3593182c5d`, [run 40224038422](https://github.com/M4D135/domenia-d120/actions/runs/40224038422), job `121261526049`.
Journaux lus : Debug à 19:03:22 UTC et Release à 19:04:06 UTC, **0 erreur et 0 avertissement**.
La sélection critique a exécuté **587 tests sur 2 379 découverts** : **587 réussis, 0 en échec** à 19:05:35 UTC ;
1 792 tests hors sélection non exécutés. Les vingt échecs du parc partagé du passage précédent sont résolus dans
cette sélection, y compris la conservation exacte de l'ACL sous le parent temporaire Windows natif.

Le job global reste en échec : immédiatement après les tests C#, `Get-Command python` trouve à la fois le Python
préinstallé et l'alias WindowsApps. Le script transmet leurs deux chemins à l'opérateur d'appel, qui refuse ce nom
concaténé avant tout test Python. Les quinze contrôles de garde sont donc **non exécutés**, pas en échec métier.
Le script sélectionne désormais le premier exécutable selon l'ordre du PATH, pour Python comme pour dotnet,
sans installer ni télécharger quoi que ce soit. Ce correctif requiert commit/push puis un nouveau passage critique.

Ce succès C# ne valide ni les deux VM du laboratoire, ni les parcours UI/native, ni une livraison finale.

## Sixième passage : lancement Python corrigé, CI complète réussie

Le commit `1e877d650df71b37716b0b0840726238f632db7d` sélectionne un exécutable scalaire dans l'ordre du PATH.
Les deux compilations, les 587 tests C# et les quinze tests Python passent dans le run `40224745081`, détaillé
en tête de ce rapport. Les assertions ne sont pas affaiblies pour contourner les échecs précédents.
Le Python retenu est `C:\hostedtoolcache\windows\Python\3.12.10\x64\python.exe` ; aucun alias WindowsApps
n'est lancé. Les échecs historiques restent documentés et ne sont pas réécrits en réussites.

Le développement ciblé et ses corrections critiques sont poussés. La livraison reste bloquée sur les preuves
critiques de `CNAMTS-DC01` et `DOMENIA-FIRSTRUN-20261020`, avec recette UI/native réellement revue.
