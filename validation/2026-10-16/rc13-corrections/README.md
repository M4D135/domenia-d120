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

Le worker **StorageMaintenance** est modifié (deux propriétés de réponse en lecture seule) et doit être ré-épinglé après revue. La géométrie est mesurée sur une surface WPF synthétique : ce n'est pas une recette humaine à deux écrans/DPI.

## Qualification encore ouverte

Pas de campagne générale VM, de nouvelle collecte réelle, de signature avec certificat de l'organisation ni de validation juridique de redistribution. Les points de qualification humaine, domaine réel, incidents disque, charge 10k/20k, installation/désinstallation sur profil jetable et renouvellement des captures historiques restent ouverts. Les guides Word/PDF régénérés en RC1.17.12 sont conservés. Aucun statut `acceptance_passed` n'est fabriqué.
