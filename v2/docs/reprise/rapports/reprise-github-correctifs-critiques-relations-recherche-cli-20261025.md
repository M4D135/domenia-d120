# Correctifs après le premier passage critique — relations, Recherche et CLI

## Preuve de départ

Le passage Windows GitHub Actions `40220607341`, sur `27d7fccd`, compile Debug et Release sans erreur ni avertissement puis exécute les tests critiques. Son journal signale les échecs examinés ici : sept dans `AdRelationProbeTests`, sept dans `AdSearchCheckpointTests`, un dans la sortie locale de `AutomationCommandTests`. Ces échecs ne sont pas annoncés corrigés par une nouvelle exécution dans ce rapport.

## Causes et changements

- **Sondes de relation : fixture sans compte distant.** Le transport LDAP d’enregistrement ne porte aucun secret Windows natif. L’admission `AdWorkstationReadAccess` appelait donc `CopySessionCredential`, qui refusait correctement ce transport. Les scénarios fournissent maintenant un `EngineContext` et un compte distant fictif possédé par `MachineAccountService`, conservant la cascade, ses générations, les contrôles LDAP/CIM et la libération du secret. Le test déjà arrêté utilise le même contexte sans contact. Le scénario occupé observe également une éventuelle faute d’admission avant d’attendre sa barrière de ping, pour ne plus masquer cette faute par un timeout.
- **Reprises de Recherche : identités LDAP incomplètes.** Les entrées d’ordinateur n’avaient pas `objectSid` ; `AdDirectoryMapper.Computer` les refusait donc. Elles utilisent maintenant le constructeur de fixture AD existant avec SID distinct, GUID attendu, DNS, SAM et date de création. Le scénario `SearchService` établit explicitement sa session sur le transport d’enregistrement avant la recherche ; son API ne connecte pas implicitement une session sans domaine chargé. Les assertions de continuité, plafonnement, interruption, changement d’instance et conservation des lignes restent inchangées.
- **CLI : défaut de classement d’exception en production.** `Destination` refuse notamment un chemin UNC par `InvalidDataException`. Les deux filtres d’erreurs de destination/sortie omettaient ce type, qui tombait dans le refus global code `3`. Ils conservent désormais le code de sortie `5` prévu par le contrat. Le test conserve son assertion `5` et vérifie aussi le code et le motif précis du JSON de refus. Aucun partage n’est ouvert et aucun repli de sortie n’est ajouté.

## Fichiers

- `v2/src/Domenia.App/AutomationHostCommand.cs`
- `v2/tests/Domenia.Tests/AdRelationProbeTests.cs`
- `v2/tests/Domenia.Tests/AdSearchCheckpointTests.cs`
- `v2/tests/Domenia.Tests/AutomationCommandTests.cs`
- Le présent rapport.

## Validation et limites

Relecture statique et `git diff --check` uniquement pour ce correctif. Aucune compilation ni suite locale, aucun runtime ni dépendance téléchargé. La prochaine exécution critique Windows après commit/push doit confirmer ces changements. Les validations UI/native dans deux VM et la publication PROD/DEV v2.0.0 restent distinctes et non attestées ici.
