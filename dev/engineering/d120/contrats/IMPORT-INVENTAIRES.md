# Import d’inventaires existants (points 137 et 138)

État au 15 octobre 2026. Règles pures et raccordement écrits ; aucune exécution Windows PowerShell 5.1 n’a eu lieu.

## Ce qui est importé

Domenia importe des **associations utilisateur ↔ poste** depuis un inventaire existant, dans Relations › Toutes les
associations. L’import n’écrit rien dans Active Directory et ne remplace jamais une association déjà stockée.

| Format choisi (« Format de l’import ») | Source imposée | Colonnes lues | Date |
|---|---|---|---|
| CSV générique | `Import CSV` | `UserLogin`/`User`/`Username`/`LastUser`/`SamAccountName`, `Computer`/`ComputerName`/`Hostname`/`Host`/`Machine`/`Name`, `When` | ISO seulement |
| Export GLPI (CSV) | `Import GLPI` | `Nom`/`Name`, `Usager`/`Alternate username`/`Login`, à défaut `Utilisateur`/`User` sans espace, date du dernier inventaire puis de dernière modification, numéro de série, entité | ISO seulement |
| Résultats osquery (JSON) | `Import osquery` | table `logged_in_users` : journal de résultats osqueryd (événements `columns`, instantanés `snapshot`) ou tableau `osqueryi --json` avec `hostname` | secondes Unix (`time`, sinon `unixTime`) |

Le format est un choix explicite de l’opérateur ; la colonne `Source` d’un fichier n’est jamais reprise.
Code : `wad/modules/Domenia-InventoryImport.Model.ps1` (règles pures), `Show-DomeniaLinkImportPreview` et
`New-DomeniaLinkImportPlan` (`Domenia-Relations.UI.ps1`), `Import-LinksCsv` (cœur).

## Correspondance d’identité

`Test-DomeniaInventoryIdentity` refuse au lieu de tronquer :
- `DOMAINE\compte` dont l’autorité n’est ni le NetBIOS, ni le premier libellé DNS, ni le nom DNS du domaine courant ;
- `compte@suffixe` dont le suffixe n’est pas le nom DNS du domaine (un suffixe UPN alternatif n’est pas vérifiable) ;
- un nom DNS complet de poste hors du domaine, une adresse IP ;
- tout nom qualifié quand le domaine courant n’est pas connu.

Les comptes système (SYSTEM, services, `DWM-*`…) et les comptes machine restent écartés par `Normalize-LinkUser`.
Les comptes et postes retenus sont ensuite cherchés dans l’index local (`LocalIndexRead`, `ResolveNames`), sans réseau.

## Dates et priorité des sources

- Dates ISO : un décalage ou `Z` l’emporte, sinon heure locale du poste, comme toutes les dates d’association.
- `08/10/2026` reste ambigu : la date de l’import est retenue et le détail le dit.
- Une date future (au-delà d’une heure) est ignorée : elle gagnerait la priorité du fichier.
- Dans un fichier, par poste : la date la plus récente l’emporte, une date l’emporte sur une absence de date ;
  le même compte répété est un doublon ; deux comptes sans date pour les départager sont **en conflit** et aucun n’est importé.
- Avec le stockage : une association importée ne remplace jamais une association existante (déclarée, observée ou importée) ;
  les sources `Import CSV`, `Import GLPI` et `Import osquery` sont protégées des retraits automatiques (orphelines) et
  leur historique est conservé par la purge « Historique », comme celui des associations déclarées.
- osquery : seules les observations les plus récentes de chaque poste atteignent l’aperçu ; les plus anciennes sont comptées.
  Les sessions sans personne (utilisateur vide de la session des services Windows, SYSTEM, `DWM-*`, `UMFD-*`, pseudo-comptes
  `LOGIN` ou `reboot`) sont ignorées et comptées : datées de l’instantané, elles masqueraient le compte réel du poste.
  Un enregistrement rejeté ne départage jamais un poste.

## Aperçu et retour arrière

Avant « Importer », chaque enregistrement porte une catégorie : **Valide**, **Conflit**, **Rejet**, **Doublon**,
**Déjà connue**, **Inconnue** (absente de l’index local) ou **Reportée** (au-delà de 64 par import). Le résumé compte chaque
catégorie, nomme la source imposée et le lot de retour arrière.

Chaque association importée commence ses détails par `Lot dʼimport AAAAMMJJTHHMMSSmmmZ-xxxxxxxx.` (heure UTC de l’aperçu
à la milliseconde : l’ordre des lots est celui des imports, même dans la même minute). « Annuler l’import »
retire le lot de la session, ou après un redémarrage le lot le plus récent encore présent dans le stockage local
(`Get-DomeniaImportBatches`), après une confirmation qui donne le nombre, le fichier et la date. Chaque retrait est
journalisé et restaurable. Les associations importées avant cette version n’ont pas de lot : elles ne sont annulables
que pendant leur session.

## Limites explicites

| Limite | Valeur |
|---|---|
| CSV lu sur le fil d’interface | 8 Mio |
| JSON osquery lu sur le fil d’interface | 2 Mio |
| Enregistrements osquery analysés | 20 000 |
| Enregistrements montrés dans l’aperçu | 1 000 |
| Associations écrites par import | 64 |

## Tests

- Règles : `wad/tests/rules/InventoryImport.Tests.ps1` (`IMP-001` à `IMP-010`).
- Raccordement : `Test-DomeniaWiringRelations.ps1`, cas « Points 137-138 ».
- Aucun de ces tests n’a été exécuté sous Windows PowerShell 5.1 à cette date.
