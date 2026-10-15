# Z06 — revue des retraits, 16 octobre 2026

Revue Codex du WIP `0692289`. Base commune : `d32432dd5ed1360e7026cbdf28fa2f16cd7fe6d7` ; master examiné : `fc9e00ae934c0a495f0722dca982fd338e9b144a`.

**56 fonctions retirées : 48 dans le cœur et 8 dans les modules.** Les huit déclarations du chargeur sont retirées ; `integrate_lots.py --refresh-functions` a été exécuté. Le WIP retirait aussi `Get-DomeniaProbeVisuals` : cette fonction et sa déclaration sont restaurées, car toutes les fonctions de `Domenia-Probes.Model.ps1` entrent dans le corps composé de LocalStore. Le retrait supplémentaire sûr est `Fail-DomeniaParkSweepUi`, sans référence de code.

Les candidats passent de **267 à 211** (3694 à 3638 fonctions). Les **208 fonctions `tests-only` sont exactement les mêmes** ; aucun nouveau candidat créé. Les trois candidats `dead` conservés sont `Get-DomeniaSelectedPresenceWorkerCode`, `Get-DomeniaParkSweepWorkerCode` (workers épinglés) et `Get-DomeniaProbeVisuals` (composition de LocalStore).

## Preuve par retrait

Recherche de chaque nom dans tout `dev` suivi par Git sur master : `git grep -I -n -i -F -e NOM master -- dev` (56 recherches, 821 occurrences). Relecture des appels, chaînes de handlers, `Get-Command`, événements `Add_*`, `${function:...}`, corps de workers et résolutions par variables. Comparaison du graphe `audit_dead_functions.analyse` sur base, master et branche. Les noms reconstitués à l'exécution exigent cette revue manuelle ; l'auditeur seul n'est pas une preuve.

Les emplacements ci-dessous sont ceux de la base commune ; classifications et appelants identiques sur le master examiné. Aucun retrait n'a de test dédié actuel.

- **R0** : aucune référence de code extérieure à la définition, à sa récursion ou à sa propre trace de diagnostic. Les listes `Functions` sont déclaratives.
- **R1** : seuls les appelants indiqués référencent la fonction ; ils sont retirés dans ce lot.
- **R2** : branchement de `Wire-Events` sur `BtnIndexWalk`, absent de tous les XAML et sans création dynamique trouvée ; `Test-DomeniaUxRefinements.ps1` exige son absence. Branchement également retiré.

| Fonction retirée | Source dans `dev/wad` | Preuve |
|---|---|---|
| `Merge-ConfigObject` | `Domenia-Core.ps1:1455` | R0 |
| `Normalize-AdLogin` | `Domenia-Core.ps1:1564` | R0 |
| `Get-AdCredential` | `Domenia-Core.ps1:1658` | R1 : `Get-AdCmdletParams` |
| `Register-DomeniaAdTypeData` | `Domenia-Core.ps1:1702` | R1 : `Ensure-AdModule`, `Import-DomeniaAdModuleSource` |
| `Import-DomeniaAdModuleSource` | `Domenia-Core.ps1:1782` | R1 : `Ensure-AdModule` |
| `Ensure-AdModule` | `Domenia-Core.ps1:1799` | R1 : `Invoke-AdModuleAction` |
| `Get-AdCmdletParams` | `Domenia-Core.ps1:1823` | R0 |
| `Set-UacFlagValue` | `Domenia-Core.ps1:1835` | R0 |
| `Get-ObjectTypeFromProps` | `Domenia-Core.ps1:1980` | R1 : `Result-ToBranchRow` |
| `Get-DomeniaProfilePath` | `Domenia-Core.ps1:3038` | R0 |
| `Get-DomeniaPingState` | `Domenia-Core.ps1:3077` | R0 |
| `Get-DomeniaBootThemeMap` | `Domenia-Core.ps1:4003` | R0 |
| `Get-DomeniaThemePath` | `Domenia-Core.ps1:4183` | R0 |
| `Set-DomeniaResourceColor` | `Domenia-Core.ps1:4216` | R0 |
| `Get-SelectedObjectFilter` | `Domenia-Core.ps1:9218` | R0 |
| `Result-ToBranchRow` | `Domenia-Core.ps1:9247` | R0 |
| `Set-DeStringProperty` | `Domenia-Core.ps1:9828` | R0 |
| `Find-GroupDn` | `Domenia-Core.ps1:9855` | R0 |
| `Fail-DomeniaBranchObjectsUi` | `Domenia-Core.ps1:12284` | R0 |
| `Get-DomeniaContextRow` | `Domenia-Core.ps1:15896` | R0 |
| `Copy-DomeniaSelectedObjectNames` | `Domenia-Core.ps1:15929` | R0 |
| `Copy-DomeniaSelectedObjectDns` | `Domenia-Core.ps1:15942` | R0 |
| `Get-DomeniaScanRecordPath` | `Domenia-Core.ps1:17298` | R0 |
| `Get-DomeniaUserScanRecord` | `Domenia-Core.ps1:17303` | R1 : `Get-DomeniaUserScanSummary` |
| `Save-DomeniaUserScanRecord` | `Domenia-Core.ps1:17320` | R0 |
| `Get-DomeniaUserScanSummary` | `Domenia-Core.ps1:17326` | R0 |
| `Get-DomeniaUserComputersWorkerCode` | `Domenia-Core.ps1:17347` | R0 |
| `Update-DomeniaIndexLookupEntry` | `Domenia-Core.ps1:17413` | R0 |
| `Get-DomeniaIndexPath` | `Domenia-Core.ps1:17472` | R0 |
| `Load-DomeniaIndex` | `Domenia-Core.ps1:17493` | R0 |
| `Get-DomeniaEditDistance` | `Domenia-Core.ps1:17589` | R1 : `Find-DomeniaIndexMatches` |
| `Find-DomeniaIndexMatches` | `Domenia-Core.ps1:17621` | R0 |
| `Upsert-DomeniaIndexEntryRow` | `Domenia-Core.ps1:17946` | R0 |
| `Request-DomeniaIndexFlush` | `Domenia-Core.ps1:17977` | R0 |
| `Read-DomeniaParkFile` | `Domenia-Core.ps1:18060` | R0 |
| `Get-DomeniaParkStatePath` | `Domenia-Core.ps1:18293` | R0 |
| `Fail-DomeniaParkSweepUi` | `Domenia-Core.ps1:18433` | R0 |
| `Start-DomeniaIndexWalk` | `Domenia-Core.ps1:18765` | R2 : `BtnIndexWalk` |
| `Complete-DomeniaIndexWalkPlanUi` | `Domenia-Core.ps1:18797` | R1 : `Start-DomeniaIndexWalk` |
| `Get-DomeniaIndexSuggestionText` | `Domenia-Core.ps1:19127` | R0 |
| `Get-DomeniaSecretIndexPath` | `Domenia-Core.ps1:19583` | R0 |
| `Invoke-AdModuleAction` | `Domenia-Core.ps1:20645` | R0 |
| `Clear-DomeniaLoginAuthReferences` | `Domenia-Core.ps1:22304` | R0 |
| `Add-AssociationsToRows` | `Domenia-Core.ps1:22393` | R0 |
| `Update-SelectedAssociationFields` | `Domenia-Core.ps1:22437` | R0 |
| `Invoke-WithDOMENIADataLock` | `Domenia-Core.ps1:24442` | R0 |
| `Complete-DomeniaStartupWarmupUi` | `Domenia-Core.ps1:29384` | R0 |
| `Fail-DomeniaStartupWarmupUi` | `Domenia-Core.ps1:29404` | R0 |
| `Get-DomeniaDemoUnavailableText` | `Domenia-Demo.Model.ps1:49` | R0 |
| `Get-DomeniaFunctionProviderMap` | `Domenia-Engine.Model.ps1:10` | R0 |
| `Get-DomeniaPulseNow` | `Domenia-Engine.UI.ps1:518` | R0 |
| `Test-DomeniaParkLinkChanged` | `Domenia-Park.Model.ps1:53` | R0 |
| `Set-DomeniaOuTreeNodeFilter` | `Domenia-Search.UI.ps1:1073` | R0 |
| `Get-DomeniaSearchWorkspaces` | `Domenia-SearchWorkspace.UI.ps1:40` | R0 |
| `Get-DomeniaBootContrastPairs` | `Domenia-Shell.Model.ps1:1126` | R0 |
| `Test-DomeniaWorkstationMember` | `Domenia-Workstation.Model.ps1:20` | R0 |

Occurrences résiduelles : `Find-DomeniaIndexMatches` apparaît dans un commentaire du worker `Get-DomeniaLocalIndexReadWorkerCode`, inchangé. `Get-DomeniaUserComputersWorkerCode` était un simple renvoi vers `Get-DomeniaRelationsWorkerCode`, conservé ; un audit historique le mentionne encore. Un autre audit historique mentionne `Upsert-DomeniaIndexEntryRow` pour exiger son absence du chemin de persistance. Les anciennes empreintes, notes et patches restent archivés.

## État associé et éléments conservés

- `AdModuleLoaded`, `AdModulePath`, `AdModuleMessage` et `StartupWorkerThreadId` : lus uniquement par les fonctions retirées ; initialisations retirées.
- `IndexPositionByDn` et `IndexPositionByGuid` : construits par `Rebuild-DomeniaIndexLookup`, consommés uniquement par `Update-DomeniaIndexLookupEntry`, retiré. Tables et compteurs retirés ; les autres index restent construits.
- `IndexFlushTimer` : créé uniquement par `Request-DomeniaIndexFlush`, retiré. Initialisation, arrêt dans `Flush-DomeniaIndex` et entrée de secours dans `Dispose-AsyncEngine` retirés.
- `DataMutexName` et son calcul `rootHash` : utilisés uniquement par `Invoke-WithDOMENIADataLock`, retiré ; mécanismes de verrouillage actuels conservés.
- `Get-DomeniaSelectedMachineRows` conservé : appelé par `Get-DomeniaPaletteContext` (`Domenia-Commands.UI.ps1:69`).
- Atelier support conservé : initialisation et branche `tests-only`, tandis que `Add-DomeniaSupportIncidentFromLog` et `Set-DomeniaSupportObjectSource` ont des appelants actifs. Les accès cachés `BtnUxNavSupport`, `BtnUxHomeSupport`, `BtnUxStep3` participent encore au routage générique via `Uid=TabSupport` et au catalogue d'aide. Aucun retrait global de la vue ou de ses tests.
- Autres chemins ParkSweep/PresenceScan couverts seulement par des tests conservés. Aucune clé de configuration retirée sur la seule absence d'un appel direct : lectures via contexte et workers possibles.

## Contrôles exécutés

| Contrôle depuis `dev` | Résultat |
|---|---|
| `python3 tools/validate_powershell_static.py` | PASS, 328 fichiers |
| `python3 tools/audit_wording.py` | PASS, 26 entrées contre 27, aucune nouvelle |
| `python3 tools/strip_xaml_help.py` | PASS, 817 contrôles catalogués |
| `python3 -m unittest discover -s tools/tests -p 'test_audit_dead_functions.py' -v` | PASS, 18 tests |
| `python3 tools/update_worker_contracts.py` (lecture seule) | PASS, 94 opérations, aucun changement requis ni appliqué |
| Comparaison des here-strings par lexer base/branche | 143 littéraux identiques ; aucun corps de worker changé |
| BOM et fins de lignes des 10 `.ps1` du lot | UTF-8 BOM et LF, aucun CR |
| `git diff --check` | PASS |
| `python3 tools/audit_preload.py` | 253 réussites, 1 échec attendu : `Every original core function retained`, pour les 48 retraits du cœur ; aucune rebaseline |
| `python3 tools/audit_dead_functions.py --update` | Refus : 30 noms `tests-only` absents de la baseline de 259 entrées, tous déjà concernés avant le WIP. Base : 31 noms nouveaux, dont `Get-DomeniaSearchWorkspaces` maintenant retiré. Baseline inchangée |

Fonctions vivantes modifiées : `Rebuild-DomeniaIndexLookup`, `Flush-DomeniaIndex`, `Wire-Events`, `Dispose-AsyncEngine`, uniquement pour retirer l'état et les branchements cités. Aucun fichier généré, manifeste, contrat ou exécutable modifié. Build et mise à jour des références laissés à l'intégrateur. Aucune exécution Windows, VM, WPF ou AD : ces contrôles Python ne qualifient pas Windows PowerShell 5.1.
