# Contrat de sonde `Domenia.ProbeContract/1` (points 135 et 136)

État au 15 octobre 2026. Règles écrites et testées en règles pures ; aucune exécution Windows PowerShell 5.1 n’a eu lieu.

## Ce qu’une sonde déclare

Une sonde est une donnée, jamais du code. Son contrat est construit par `ConvertTo-DomeniaProbeContract`
(`wad/modules/Domenia-ProbeContract.Model.ps1`) et vérifié par `Test-DomeniaProbeContract`.

| Section | Contenu | Règle |
|---|---|---|
| Entrées | fournisseur `CIM`, espace de noms, classe, propriétés (1 à 64), filtre, mode `First`/`All`/`Count` | espaces de noms et classes refusés (`root\subscription`, `root\directory\LDAP`, `root\RSOP*`, `root\default`, `root\security`, `Win32_Product`, `CIM_Product`, `Win32_SoftwareFeature`, `Win32_SoftwareElement`, `Win32_ReliabilityRecords`) ; filtre de 512 caractères au plus, caractères `A-Z a-z 0-9 _ espace = ' < > ( ) . : { } -`, jetons `{SINCE_24H}` et `{SINCE_7D}` seulement ; comptes et groupes limités aux comptes locaux ou exclus des contrôleurs |
| Types | un champ par propriété : type CIM, nature (`Text`, `Number`, `Boolean`, `Timestamp`), unité | une propriété sans type est refusée ; un type CIM non documenté reste du texte et produit un avertissement |
| Privilèges | `LectureDistanteWmi` ou `AdministrateurLocal`, avec texte | les espaces `root\cimv2\Security\*`, `root\SecurityCenter2`, `Win32_EncryptableVolume` et `Win32_Tpm` exigent l’administrateur local |
| Coût | `Léger`, `Modéré` ou `Lourd`, motif | `Lourd` exige l’indicateur `Slow` (collecte explicite) |
| Limites | texte des limites, sens d’un résultat inconnu, budgets du collecteur | budgets réels : 2 000 instances détaillées et 256 Kio par lecture de classe, délai de requête d’au moins 10 s, délai de tâche plafonné à 150 s |
| Sources | références primaires Microsoft (`learn.microsoft.com`, `github.com/microsoft`, `github.com/MicrosoftDocs`) | obligatoires hors catalogue historique ; leur absence y produit un avertissement |
| Tests attendus | `Projection`, `Inconnu`, `Refus`, `Troncature` (hors `Count`), `Controleur` (`SkipOnDc`), `Fenetre` (jetons), `Correspondance` (`Map:`) | les règles pures exécutent chacun de ces tests sur chaque sonde du catalogue (`ProbeContract.Tests.ps1`, `PCT-002`) |
| Comportement | `Reads=CIM`, `Writes=false`, `Code=Aucun`, aucune méthode, cible | tout autre comportement est refusé |

Les limites du contrat sont comparées au texte du collecteur (`PCT-003`) : un changement de budget dans
`Domenia-Live.Model.ps1` ou `Domenia-Park.UI.ps1` sans mise à jour du contrat fait échouer les règles.

## Ajouter une sonde

1. Ajouter l’entrée dans `wad/modules/Domenia-ProbeCatalog.json` avec sa documentation complète (description,
   droits, compatibilité, sens de l’inconnu, limites, références, champs typés).
2. Lancer `wad\tests\Test-DomeniaRules.ps1` : `PCT-001` refuse un contrat invalide, `PCT-002` exécute les tests attendus.
3. Qualifier le fournisseur sous Windows : `ProviderQualification` reste « À qualifier sous Windows » tant que ce n’est pas fait.

## Sondes ajoutées le 15 octobre 2026 (lots W10 et W11)

Les neuf entrées ajoutées au catalogue détaillé (32 projections au lieu de 23) : huit par le lot W11 pour
l’inventaire du poste, `soft.installed` par le lot W10 pour le point 152. Elles satisfont
`Domenia.ProbeContract/1` sans déclaration manuelle : origine « Catalogue détaillé », contrat dérivé de leur
documentation (champs typés, droits, limites, références Microsoft). `PCT-007` fige ce contrat et exécute leurs tests attendus.

| Sonde | Classe (espace de noms) | Privilège | Coût | Tests en plus du socle |
|---|---|---|---|---|
| `soft.installed` | `Win32_InstalledWin32Program` (`root\cimv2`) | `LectureDistanteWmi` | Modéré | `Controleur` (exclue des contrôleurs) |
| `hw.memoryusage` | `Win32_OperatingSystem` (`root\cimv2`) | `LectureDistanteWmi` | Léger | — |
| `hw.computersystem` | `Win32_ComputerSystem` (`root\cimv2`) | `LectureDistanteWmi` | Léger | — |
| `hw.batterystatic` | `BatteryStaticData` (`root\wmi`) | `LectureDistanteWmi` | Modéré | — |
| `hw.batteryfullcharge` | `BatteryFullChargedCapacity` (`root\wmi`) | `LectureDistanteWmi` | Modéré | — |
| `hw.batterycycles` | `BatteryCycleCount` (`root\wmi`) | `LectureDistanteWmi` | Modéré | — |
| `hw.monitorconnections` | `WmiMonitorConnectionParams` (`root\wmi`) | `LectureDistanteWmi` | Modéré | `Correspondance` (table des sorties vidéo) |
| `net.connectionprofiles` | `MSFT_NetConnectionProfile` (`root\StandardCimv2`) | `LectureDistanteWmi` | Modéré | `Correspondance` (catégorie réseau) |
| `sec.avproducts` | `AntiVirusProduct` (`root\SecurityCenter2`) | `AdministrateurLocal` | Modéré | — |

Le socle commun est `Projection`, `Inconnu`, `Refus` et `Troncature`. Aucune de ces sondes n’est marquée `Slow` ;
le coût « Modéré » vient de l’énumération de toutes les instances de la classe. « Comprendre ce chiffre »
(`Get-DomeniaProbeWidgetSource`) reprend leurs limites documentées, et le sélecteur de widgets n’en propose une
que si son contrat est valide.

## Sonde personnalisée (point 136)

Une entrée marquée `"Origin": "Personnalisée"` ne reçoit aucune valeur dérivée. Elle doit déclarer :

```json
"Behavior": { "Reads": "CIM", "Writes": false, "Code": "Aucun", "Methods": [], "Target": "Poste choisi ou liste affichée" },
"Privilege": { "Level": "LectureDistanteWmi", "Text": "…" },
"Cost": { "Level": "Lourd", "Reason": "…" },
"Slow": true,
"SkipOnDc": true
```

Le chargeur du catalogue (`Assert-DomeniaCustomProbeDeclaration`) refuse le catalogue entier si l’une de ces
déclarations manque ou si le comportement n’est pas une lecture CIM sans code ni méthode. Le sélecteur de widgets
ne propose jamais une sonde dont le contrat est refusé et journalise le motif.

## Isolement : ce qui est garanti et ce qui ne l’est pas

`Get-DomeniaProbeIsolationPlan` l’affiche dans « Détails de la sonde ».

Garanti :
- aucun code fourni par la sonde : le collecteur construit une lecture `SELECT` à partir de noms validés ;
- aucune écriture, aucune méthode WMI ;
- lecture hors du fil d’interface, délais et budgets bornés, limite atteinte signalée ;
- contrôleurs de domaine exclus quand la sonde le déclare (type de système lu avant la requête).

Non garanti :
- le fournisseur WMI du poste exécute la requête avec les droits du compte utilisé ; Domenia ne contrôle pas son
  comportement côté poste ;
- aucun bac à sable PowerShell n’est promis : la protection repose sur l’absence de code dans la définition ;
- la collecte `LiveConsole` n’est pas retenue pour le processus auxiliaire de `Features.IsolatedReads` (décision
  `Get-DomeniaIsolationDecision`) : un fournisseur bloqué retient sa tâche jusqu’au délai.

## Reste à faire

- Exécuter `Test-DomeniaRules.ps1` sous Windows PowerShell 5.1 (VM `CNAMTS-W11-01`).
- Qualifier les fournisseurs du catalogue détaillé sous Windows.
