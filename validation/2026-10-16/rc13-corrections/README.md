# RC1.17.13 — corrections restantes, 16 octobre 2026

Travail demandé par David : terminer les corrections avec OpenCode `opencode/glm-5.3-flash-free`, sans grande campagne VM, puis commit et push. Le code proposé par GLM a été relu et corrigé avant intégration.

## Corrections vérifiées

- **Fabrication native** : les deux outils acceptent le compilateur `csc.exe` Roslyn explicitement fourni, sans charger ses dépendances dans PowerShell 5.1. Compilation C# 5 déterministe, références .NET Framework 4.7.2, chemins normalisés et métadonnées de provenance. Deux constructions séparées donnent les mêmes DLL. Empreintes du chargeur, du contrat de release et du composant Query mises à jour.
- **Bascule de base** : la lecture SQLite de confirmation se déroule dans le worker `StorageMaintenance`, action `ReadRedirect`. La réponse transporte l'identité et la révision réellement lues. Le callback contrôle chemin, domaine, identité, révision, absence de redirection, époque et maintenance active avant de changer le contexte. Échec ou annulation : ancienne base et verrou de reprise conservés. La revue a rétabli le contrôle de révision qui manquait dans la première proposition GLM.
- **Fenêtres très basses** : actions de liste et commandes de mise à jour OU repliables. Elles se replient seulement à l'entrée dans le mode très bas ; un dépliage volontaire survit aux mises à jour de disposition. Les listes gardent leur hauteur ; les commandes restent accessibles. Aucune préférence de disposition persistante modifiée.
- **Atelier / tests dashboard** : une valeur numérique conserve son type décimal dans la recette et affiche son unité dans la grille (`20 %`). L'assertion attend maintenant ce libellé. Le scénario des emplacements d'inventaire isole sa disposition des sondes ajoutées par les scénarios précédents.

## Preuves ciblées

Toutes les exécutions Windows ci-dessous ont lieu dans **CNAMTS-W11-01**, Windows PowerShell **5.1.26100.6584**, sans lecture AD/WMI réelle.

| Vérification | Résultat | Preuve |
| --- | --- | --- |
| Deux builds Native et Query | DLL identiques à l'octet | `deterministic.json`, `native-build.json`, `query-build.json`, `compiler-provenance.json` |
| Assertions sur DLL compilées | Native 1568, Query 93, toutes réussies | `compiled-smoke.json` |
| Bascule asynchrone, SQLite temporaire et callbacks | 27 assertions, 2 cas réussis | `Storage-switch.json` |
| Géométrie 960×516 et 1024×768, dépliage explicite | 5 cas réussis | `Geometry-focused.json`, `Test-Rc13GeometryFocused.ps1` |
| Sept anciens cas dashboard sélectionnés | 6 réussis, 1 assertion de libellé corrigée puis réussie | `Boards-seven-before.json`, `Boards-atelier.json` |

Le worker **StorageMaintenance** est modifié (deux propriétés de réponse en lecture seule) ; ré-épinglé le 2026-10-17 après relecture explicite du diff (une ligne, `StoreId`/`Revision` typés dans `ReadRedirect`) via `update_worker_contracts.py --apply`, puis `audit_preload.py --rebaseline` (251 réussis, 0 en échec, `ChangedCoreFunctions` vide). La géométrie est mesurée sur une surface WPF synthétique : ce n'est pas une recette humaine à deux écrans/DPI.

## Refresh `detail:*` des widgets Query (développement Spark local, 16-17 octobre 2026)

Le mini refresh des widgets Query à champs `detail:*` relit désormais la requête WMI mémorisée de la recette enregistrée au lieu de renvoyer « relancez depuis l'atelier » : modèle de collecte (`Kind` `WmiDetail`, `DetailKeys`/`DetailBroken`, validation de la `ReadDefinition` par `Assert-DomeniaQueryReadDefinition` et égalité de `RequestKey`, refus nommés), intégration UI (`Start-DomeniaWidgetDetailCollect` et ses callbacks, pipeline worker QuerySchema `ResultKind` `WmiQuery`, gardes contexte/révision/époque/annulation, admission et confirmation, file si campagne en cours, commit base locale avant affichage, valeurs antérieures conservées sur échec ou délai, source et date réelles annoncées après commit, enchaînement Remote + Detail sans source ignorée), dates réelles du relevé mémorisé au pied de page (`Get-DomeniaWidgetDetailClocks`), lignes de source `fleet.wmi`/`fleet.reach`. Détail par lot : `work/rc13-opencode/RESULT-WIDGET.md` (racine de mission).

## Contrôles hors VM (aucun test VM, décision David du 16 octobre)

Exécutés le 2026-10-17 sur le Spark (pwsh 7.4.6 linux, non qualifiant 5.1) et audits Python :

| Contrôle | Résultat |
| --- | --- |
| Suite de règles complète | 1009 réussis, 66 en échec — 66 échecs structurels hors Windows (COM/ACL/SecurityIdentifier), identiques à la base, aucune régression |
| `Test-DomeniaWidgetDetailRefresh.ps1` (doubles/callbacks, sans réseau) | 42 réussis, 0 en échec (WDR-001 à 009) |
| `Test-DomeniaPs51Compat.ps1` | 334 fichiers, 0 erreur |
| `validate_powershell_static.py` | PASS |
| `update_worker_contracts.py` (après revue) | `ReviewedChangesRequired` vide |
| `audit_preload.py` (après rebaseline relu) | 251 réussis, 0 en échec |
| `doc_sync.py --check`, `licence_inventory.py --check` | PASS (`Publishable: false` : captures et licences NonEtablie, connu) |
| `release_contract.py --stamp` puis `--check` | PASS (empreintes DLL RC13 et provenance cohérentes avec `Domenia-Modules.ps1`) |
| Packs RC13 `build_packages.py` (PROD+DEV) | ReleaseGuard PASS, deux builds aux SHA-256 identiques (déterminisme vérifié), `Publishable: false` faute de rapport Windows lié aux ZIP |
| Revue indépendante locale (session Spark distincte, gateway) | VERDICT ok-avec-réserves ; constat majeur retenu et corrigé (la date `ObservedAtUtc` du board Software écrasait les horloges `WmiDetail` au pied de page — garde ajouté, cas WDR-009) ; garde `try/catch` ajouté sur l'indexation `Widgets` ; deux constats vérifiés sans objet dans le code réel. Avis complet : `work/rc13-opencode/REVIEW-INDEPENDENT-2026-10-17.md` |

Suites **non exécutées** (aucune preuve inventée) : suites Windows complètes sous PowerShell 5.1 sur ces packs (`Test-DomeniaRules`, `Test-DomeniaBoards`, `Test-DomeniaStorageMaintenance`, `Test-NativeParser`, `Invoke-LabRun`) — tests VM interdits par la consigne ; `release_guard.py --require-windows` sans objet hors Windows. Les packs RC13 ne sont donc pas `acceptance_passed`.

## Qualification encore ouverte

Pas de campagne générale VM, de nouvelle collecte réelle, de signature avec certificat de l'organisation ni de validation juridique de redistribution. Les points de qualification humaine, domaine réel, incidents disque, charge 10k/20k, installation/désinstallation sur profil jetable et renouvellement des captures historiques restent ouverts. Les guides Word/PDF régénérés en RC1.17.12 sont conservés. Aucun statut `acceptance_passed` n'est fabriqué.
