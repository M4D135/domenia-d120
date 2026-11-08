# Effets des opérations — revue du 16 octobre 2026

Brouillon Spark, vérifié dans les générateurs et dans les consommateurs de `Get-DomeniaOperationEffect` avant intégration. Les règles de reprise et les comptes affectés restent ceux de la table.

| Opération | Effet retenu | Motif |
|---|---|---|
| `BitLockerPresence` | `Read` | Lecture LDAP pure (schema + objets msFVE-RecoveryInformation) sans écriture. |
| `IndexOuList` | `Read` | Lecture LDAP OneLevel des OU et conteneurs sous la racine. |
| `IsolatedRead` | `Unknown` | Exécute un script arbitraire ($Payload.Script) dans un runspace isolé. L'effet dépend du code fourni, non vérifiable statiquement. |
| `LegacyMigration` | `LocalWrite` | Adopte une base SQLite existante (ajout de schéma) et importe des données historiques dans les tables locales. |
| `LocalIndexRead` | `Read` | Accès SQLite en mode ReadOnly avec timeout de verrouillage. Aucune écriture. |
| `LocalQuery` | `Read` | Lecture de modules versionnés et calculs locaux, sans mutation des objets. |
| `ParkSharedSync` | `RemoteMutation` | Lit et écrit un fichier partagé (souvent UNC) avec verrouillage. Mutation de ressource distante. |
| `QueryExport` | `LocalWrite` | Écrit un fichier CSV et un fichier JSON de métadonnées sur le disque local. |
| `QueryLibrary` | `Read` | Lecture de modules versionnés et calculs locaux, sans mutation des objets. |
| `QueryTransfer` | `LocalWrite` | Écrit des fichiers de pack JSON, scripts PS1 ou met à jour le journal d'imports local. |
| `ReadBitLockerList` | `Read` | Lecture LDAP OneLevel des objets de récupération BitLocker sous un DN donné. |

Dix effets sont maintenant explicites. `IsolatedRead` conserve `Unknown` : son enveloppe exécute le corps reçu, donc son nom ne suffit pas à autoriser la catégorie lecture. `ParkSharedSync` écrit une ressource qui peut être partagée ; sa classification conserve les protections des mutations distantes.

Les corps épinglés ne sont pas modifiés par cette classification. Tests ajoutés : table Python et règles Engine sous PowerShell ; la qualification Windows reste à faire.
