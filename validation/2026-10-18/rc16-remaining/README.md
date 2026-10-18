# RC1.17.16 — corrections restantes et contrôles du 18 octobre 2026

Base de travail : `0fd32e76c5e2d8c9ebd6eb72ff6be72774384072` (RC1.17.15). Corrections directes dans le checkout isolé, sans délégation ni VM. Le clone de travail initial avec ses changements concurrents est resté intact.

## Corrections

- Opérations StorageRetention, QuerySchema et WidgetWmiDetail enregistrées ; 97 contrats synchronisés. Le contrôle ne tolère plus d’opération manquante et valide les corps générés des trois opérations avec la garde réelle.
- Provenance des imports enregistrée en SQLite par recette et révision (origine déclarée, pack/version, identifiant source, empreinte), préservée lors d’une édition et restaurée lors d’une annulation. Les anciennes bases sans cette table restent lisibles ; le schéma additif est créé au démarrage/à la première écriture.
- Alertes de santé basées sur une recette enregistrée : définition et révision figées, évolution explicite, règles par OU, données inconnues distinctes d’un résultat faux, couverture par règle et état incomplet du poste. La liste des recettes se recharge à son ouverture après la lecture asynchrone de la bibliothèque.
- Comparaison des recettes corrigée (variables PowerShell insensibles à la casse), identifiants de migration désimbriqués, dates UTC typées normalisées ; vrais callbacks SQLite rétablis dans les bancs QueryTargets/QueryAdvanced.
- Sauvegardes de conservation et manuelles autonomes : fermeture du mode WAL dans la copie, puis relecture du fichier publié. La suppression attend une copie vérifiée. Le contrôle initial avait reproduit une erreur SQLite 14 en relecture de la copie ; le fichier conservait un mode WAL. Le scénario et l’export passent après correction.
- Métadonnées de démarrage automatique : les commandes sans guillemets ne conservent que le premier mot. Un chemin ambigu peut apparaître tronqué ; les arguments ne sont plus devinés comme partie du chemin.
- Suivi consolidé, pause historique levée, dettes d’épinglage retirées et décisions externes explicites.

## Vérifications exécutées

PowerShell **7.4.6 natif macOS arm64**, bibliothèque SQLite système, DLL Query/Native réellement chargées. Données temporaires/fictives uniquement. Les cmdlets WMI sont simulées : aucun accès AD, poste, WMI réel ou WPF. Les options CIM de descriptions localisées ne sont pas implémentées sur macOS ; le test vérifie le repli explicite, la voie Windows reste à qualifier.

| Rapport | Résultat |
|---|---|
| query-targets.json | 38 cas, 0 échec ; adaptateurs réels, enregistrement confirmé avant création du widget/collecte |
| QueryWorkshopFeatures.json | 141 assertions réussies ; import/annulation et classification des recettes |
| QueryAdvanced.json | 161 assertions réussies ; requêtes, dépendances, WQL et explorateur CIM simulé |
| QueryLibraryStore.json | 17 cas, 66 assertions, 0 échec ; SQLite réel, révisions et provenance |
| HealthRules.json | 20 cas, 0 échec |
| HealthPolicies.json | 9 cas, 0 échec |
| HealthAdvanced.json | 17 cas, 0 échec ; recettes, révisions, couverture, inconnus, désactivation et exceptions d’OU |
| StorageMaintenance.json | 6 scénarios ciblés, 36 assertions, 0 échec ; conservation, refus, intégrité et export autonome |
| WorkstationRules.json | 9 cas D096, 0 échec ; modèle et copie worker, masquage des arguments |
| CollectCircuit.json | 7 contrôles, 0 échec ; appels épinglés et garde réelle des trois opérations |
| WorkerComposition.json | 13 corps générés identiques entre construction PowerShell réelle et fabrication PROD |
| Ps51Compat.json | 337 scripts, 0 erreur/avertissement ; compatibilité statique, pas exécution Windows 5.1 |
| Preload.json | Audit sources/XML et registres réussi après revue des seules empreintes modifiées |
| DocSync.json | Contrôle de synchronisation réussi ; 56 figures historiques toujours signalées |

La fabrication exécute également les contrôles de licences, sources compilées, noms, libellés, typographie, syntaxe, couche SQLite, composition et contrats workers. Les ZIP sont comparés fichier par fichier aux sources, avec un manifeste distinct PROD/DEV et un runtime identique. `packs/manifest.json` et `packs/SHA256SUMS` portent les empreintes finales. Le journal de fabrication est `build.log` ; la comparaison indépendante est `Archives.json`.

## Limites et décisions externes

**Aucune qualification Windows complète revendiquée, aucun acceptance_passed modifié.** Parcours WPF/AD/transports réels, charge 10 000–20 000 postes, désinstallation du profil sur compte jetable et 56 captures restent à qualifier. Les guides Word/PDF RC12 ne sont pas régénérés ; le complément RC16 est livré dans `wad/docs/GUIDE-DOMENIA-RC1.md`.

**Point 134 :** confirmation des besoins et de la version/API par les mainteneurs Pesto/FilPro ; acceptation de QueryEngine.cs dans m4d-admin-common. Dossier versionné dans `dev/engineering/d120/contrats/BRIQUES-COMMUNES.md`. Aucun autre dépôt ni destinataire externe contacté.

**Point 146 :** preuve/autorisation de redistribution de M4D.Admin.Common, DLL AD/RSAT et PsExec, ou choix de leurs alternatives documentées. L’inventaire reste bloquant ; les packs sont candidats et `Publishable=false`. La mise à disposition des sources/packs du dépôt n’est pas présentée comme une validation juridique ou une qualification de production.
