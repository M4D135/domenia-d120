# Correctifs des contrats après le premier passage critique Windows — 25/10/2026

## Preuve de départ

Le passage GitHub Actions [40220607341](https://github.com/M4D135/domenia-d120/actions/runs/40220607341), sur la révision `27d7fccd`, a réellement compilé Debug et Release avec zéro erreur et zéro avertissement, puis exécuté la sélection critique : **524 réussites, 44 échecs, 568 cas exécutés**. Ce rapport décrit les six échecs confiés au lot de contrats ; les autres corrections sont suivies par les rapports d’intégration.

Ces résultats appartiennent à la révision testée avant les corrections ci-dessous. Les correctifs étaient **écrits, non exécutés** lors de la rédaction initiale ; leur passage Windows suivant est consigné séparément plus bas. Aucun résultat du passage initial n’est transformé en réussite par relecture du code.

## Causes établies et corrections

| Échec observé | Cause vérifiée dans le code | Correction |
| --- | --- | --- |
| `QueryPersonalProbeTests.Profile_admission_and_library_import_preserve_revisions_without_importing_a_probe_or_collecting` : collection vide | `ExaminePackAsync` propose volontairement `DefaultAction = "ignore"`. La fixture appliquait ce choix puis exigeait une recette importée. | Le test vérifie d’abord que ce choix ne crée rien, examine à nouveau le pack, choisit explicitement `create`, puis contrôle la clé **et le document complet** de la sonde, les révisions et l’absence d’import automatique dans le profil. Le consentement de production reste inchangé. |
| `QueryReferencePatchTests.Reference_demo_refuses_direct_bridge_and_service_calls_before_real_storage_access` : mot « démonstration » absent | Les deux lectures du dossier de diffusion sont des `NetworkRead` non servies en simulation. Le répartiteur les refuse déjà avec `simulation.unavailable`, avant la garde du service. | Le test exige ce code et son message exacts pour ces deux routes, conserve le refus du moteur pour les packs, et appelle directement les deux méthodes du service pour vérifier aussi la garde de démonstration sans répartiteur. Aucune garde de production n’est assouplie. |
| `PlatformTests.Modules_of_the_bridge_are_found_without_any_central_list` | L’attente ne contenait pas les sept modules intégrés supplémentaires. La liste des opérations omettait aussi 31 routes et répétait trois routes Recherche déjà présentes dans la liste du module. | Liste fermée des 31 modules et des routes mise à jour, doublons retirés. Le contrôle compare les noms exacts, signale les manquants et les inattendus, puis vérifie la classe de chaque opération. La découverte en production reste inchangée. |
| `PlatformTests.Screen_read_interfaces_have_no_write_method` : `IAccountsCredentialVault.Write` | L’interface déclarée comme lecteur d’écran exposait aussi `Write` et `Delete`. Il s’agit d’une contradiction de contrat, pas d’un faux positif à exempter. | `IAccountsCredentialVault` ne porte plus que `Available` et `Read`. `IAccountsCredentialVaultMutations`, sans `IScreenReader`, porte les deux mutations locales. Le même coffre Windows implémente les deux capacités ; seules les routes `accounts.vault.save/delete`, toujours `LocalWrite`, exigent la seconde. Un lecteur sans cette capacité reçoit un refus explicite avant session ou secret. Les gardes de disponibilité, la preuve à usage unique et les contrôles natifs restent appliqués. |
| `PortableConfigurationTests.Export_selected_allowlist_including_working_OU_and_valid_interface_roundtrips_without_local_identity` : JSON compact différent du JSON indenté | L’export est volontairement lisible et indenté ; le test comparait les caractères produits par `GetRawText`, au lieu de comparer le DN et le booléen conservés. | Comparaison structurelle complète avec `JsonElement.DeepEquals`. Les contrôles de liste fermée, d’exclusions, de données locales absentes et de SHA-256 du texte exact restent inchangés. |
| `SimulationIsolationTests.Simulation_references_only_core_and_the_base_library` : `System.Net.Primitives` | Core emploie `IPAddress` pour analyser des littéraux et regrouper des adresses déjà observées, `AddressFamily` comme enum, et `WebUtility.HtmlEncode` pour échapper du HTML. Aucun de ces usages ne contacte le réseau. | L’exception porte uniquement sur l’assemblage exact, avec inspection des métadonnées de **chaque type et membre référencé**. Types admis : `IPAddress`, `AddressFamily`, `WebUtility`. Membres admis : `TryParse`, `GetAddressBytes`, `get_AddressFamily`, `ToString`, `HtmlEncode`, sur leurs types précis. DNS, sockets, HTTP, ping et tous les autres assemblages `System.Net.*` restent interdits. |

## Vérifications complémentaires écrites

`CredentialVaultTests` vérifie la découverte réelle du lecteur Windows, l’absence d’enregistrement de la capacité mutante comme lecteur, le refus natif en simulation via chacune des deux interfaces et le refus des deux gestionnaires réels lorsqu’un lecteur ne possède pas la capacité de mutation. La fixture de ce dernier cas échoue si une session ou un secret est lu ; elle ne contacte aucun système. Cette classe rejoint la sélection critique.

La relecture statique des interfaces d’écran ne trouve plus de méthode commençant par un verbe d’écriture dans un contrat `IScreenReader`. La comparaison statique des déclarations et la vérification de format des différences ont été effectuées ; ce ne sont pas des exécutions de tests.

## Limites

Chaque résultat doit être attaché au SHA poussé contenant les corrections concernées. GitHub Actions ne démontre ni la recette UI/native ni les deux VM Windows du domaine. Ces validations restent non vérifiées ici ; aucune publication PROD/DEV v2.0.0 n’est autorisée par ce lot.

## Deuxième passage réel et complément de l’inventaire

Le passage [40221973309](https://github.com/M4D135/domenia-d120/actions/runs/40221973309), job `121255294635`, au SHA `ac56d748`, compile Debug et Release avec zéro erreur et zéro avertissement. Il exécute **583 cas : 562 réussites et 21 échecs**. Le journal confirme la réussite des cinq autres cas corrigés dans ce rapport ainsi que des **10 cas `CredentialVaultTests`**, y compris le refus réel d’une capacité mutante absente. La sélection globale reste en échec.

`PlatformTests.Modules_of_the_bridge_are_found_without_any_central_list` signale précisément trois opérations inattendues et aucune opération manquante. Les trois déclarations de `FicheWorkflowOperations.CreateOperations` calculent leur classe selon le mode ; elles n’avaient pas été couvertes par la comparaison statique des déclarations à classe littérale :

| Opération | Classe en simulation, attendue par cet inventaire | Classe en mode annuaire | Comportement déclaré |
| --- | --- | --- | --- |
| `fiche.lifecycle.create` | `LocalRead` | `NetworkRead` | Prépare une séquence bornée sans envoyer d’écriture. |
| `fiche.lifecycle.prepare` | `LocalRead` | `NetworkRead` | Relit et prépare une seule étape avant confirmation. |
| `fiche.compensation.plan` | `LocalRead` | `NetworkRead` | Prépare un inverse après relecture des valeurs du reçu. |

Ces trois attentes exactes sont ajoutées à `PlatformTests.SimulationOperations`, qui contient ainsi **497 opérations distinctes**. La comparaison complète des noms et la vérification de chaque classe restent inchangées ; aucun filtre, aucune déduction depuis le registre testé et aucune réduction de l’assertion. Le code de production n’est pas modifié par ce complément.

Ce complément est **écrit, non exécuté** ; il attend le prochain commit/push et passage critique Windows. Aucun test ou build local n’a été lancé.

## Confirmation du complément sur Windows

Le [run 40222981005](https://github.com/M4D135/domenia-d120/actions/runs/40222981005), job `121258369692`, au SHA
`bc4ff640fcdfb1e026e34c7e647412da70580dcb`, confirme la réussite de l'inventaire complet des 497 opérations et des
dix autres cas `PlatformTests`. Debug/Release : zéro erreur et zéro avertissement. Le résultat global reste en échec,
avec 565 réussites et 20 échecs sur 585 tests critiques ; les 20 échecs concernent le parc partagé. Cette preuve ne
constitue toujours pas la recette des deux VM ni la validation UI/native.
