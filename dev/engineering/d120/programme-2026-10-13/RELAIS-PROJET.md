# Domenia relais du projet

Passation du 13 octobre 2026, préparée par Codex pour le prochain intervenant. **Le développement est en pause à la demande de David pour économiser les tokens. Les 160 points ne sont pas terminés. Le code local est en cours d’intégration, sans validation globale ni nouvelle livraison.**

## Point de départ

- Clone à préserver : `/Users/david/Documents/Projets/Domenia-D120`.
- Dépôt : https://github.com/M4D135/domenia-d120 ; branche `master`.
- HEAD local vérifié : `42e87e6e7753a69c2cfe4eef9aafeb3aa6861abe`, publication de la feuille de route uniquement. Ce commit avait été poussé et vérifié lors de sa publication ; la référence distante n’a pas été recontrôlée pour cette passation.
- **Les modifications applicatives restent locales, avec de nombreux fichiers non suivis. Un nouveau clone GitHub ne les récupérera pas.** Ne pas nettoyer, réinitialiser ou remplacer le clone avant sauvegarde et transfert vérifié du travail.
- Source métier : [FEUILLE-DE-ROUTE.md](FEUILLE-DE-ROUTE.md). [EXECUTION.json](EXECUTION.json) reste un suivi partiel, non un certificat d’achèvement. [REPRISE.md](REPRISE.md) conserve les alertes de l’arrêt.
- [Inventaire des fichiers et empreintes](relais-technique/ETAT-FICHIERS.json) : état du travail modifié lors du relais, hors documentation de passation. Ce manifeste ne contient pas le code et ne remplace pas une sauvegarde.

## Décisions de David à conserver

1. Fiabilité et exactitude avant quantité de fonctionnalités. Cible minimale : **10 000 postes** ; qualification prévue à **20 000**.
2. Circuit central : **collecte → transaction SQLite → relecture SQLite → interface**. Une erreur d’écriture interdit d’afficher la collecte comme enregistrée.
3. Trois actions distinctes : actualiser les objets AD, tester la présence ping, actualiser les informations WMI. Recalculer une vue utilise les données enregistrées et ne change aucune date de collecte.
4. Même domaine, OU, profondeur, critères et instantané pour comparer recherche et dashboard. Inconnu, absent, refusé, périmé, incomplet et erreur restent distincts. Conserver dernière réussite ET dernière tentative.
5. Favoriser l’OU choisie. Pas de boutons de collecte de tout le domaine. Un favori doit révéler son emplacement dans l’arbre.
6. Compte de connexion par défaut pour tous les usages ; comptes secondaires facultatifs. Prévenir les verrouillages AD : arrêt après rejet d’identifiants, aucune rafale de nouvelles tentatives. Coffre Windows facultatif et explicite ; jamais de secret dans SQLite, exports ou journaux.
7. Base locale uniquement. Base SQL distante abandonnée. Packs **DEV et PROD classiques**, système WAD abandonné malgré le nom historique du dossier `dev/wad`.
8. Interface sobre, aérée, accessible ; atelier dans Outils, icônes explicites pour éditer, clic sur widget pour ses résultats, arbre OU avec recherche et défilement, zoom.
9. Dernière règle de travail : **terminer le développement avant tests et simulations**. La future campagne comprend tests natifs Windows et parcours graphiques ; captures au moins 1080p, sans infobulles.
10. Publication applicative uniquement après intégration, corrections, validation, guides DOCX/PDF v1.0 et deux packs cohérents. La documentation utilisateur ne présente pas un historique de versions.
11. Dernières instructions : pause pour tokens puis préparation du présent relais. Ne pas relancer une armée d’agents ou un LLM au seul motif de lire ce document.

## Architecture utile

PowerShell 5.1 et WPF, avec bibliothèques C# .NET Framework 4.7.2. Le Core contient encore beaucoup d’interface et de collecteurs. Les fonctions chargées sont déclarées dans `dev/wad/Domenia-Modules.ps1` ; ajouter un fichier ne suffit pas.

Les opérations asynchrones sont fermées et épinglées par empreintes : `dev/tools/operation-contracts.json`, fonctions de registre du Core et générateur `dev/tools/update_worker_contracts.py`. La migration a son propre générateur et `dev/tools/migration-worker.json`. Les factories composées ajoutées pendant ce lot doivent être prises en compte exactement, avec leurs sauts de ligne.

`Store.Model` valide les lots ; `Storage.Worker` écrit et relit après COMMIT ; `Engine.Worker` lit les vues. Les callbacks doivent vérifier domaine, StoreId, chemin, révision, epoch et génération avant publication. Une nouvelle base ou sélection invalide les anciennes réponses.

Le schéma nominal reste 11/1 avec extensions additives. `Get-DomeniaSqliteSchemaText` vient d’être extrait du Core. Il interpole `Get-DomeniaQueryLibrarySchema`. Les colonnes de résumé des observations/détails et une table de métadonnées de domaine ont été ajoutées au schéma ; leur présence ne signifie pas que tous les lecteurs et writers sont raccordés.

## Développements présents et limites

| Lot | Travail présent dans les sources | Ce qui reste à vérifier ou achever |
|---|---|---|
| Base centrale | DirectoryStore, Store, Accounts.Store, sessions et observations passent progressivement par lots et readback ; dernière réussite distincte de la tentative. | Tous les chemins de collecte, migration legacy, files en attente, annulation et reprise doivent être qualifiés ensemble. |
| Comptes | Garde de refus, préférences des comptes, coffre Windows facultatif, génération de compte et nettoyage des secrets. | Deux anciennes lectures d’événements contournent encore la garde ; tests Windows et qualification des alias/SID. |
| Stockage | Lease par chemin, copie SQLite cohérente, déplacement/restauration avec original conservé, redirection de l’ancien fichier, reprise, sauvegardes opt-in, rétention par famille. | Raccords et schéma worker à finir ; StorageContext contient encore des lectures SQLite synchrones. |
| Recherche | Favoris révèlent les ancêtres, fil d’Ariane, filtre incrémental de l’arbre ; détection de limite exacte avec objet de lookahead stocké mais non affiché. | Campagne limite 9 999/10 000/10 001/19 999/20 000/20 001 préparée, non exécutée. |
| Consultation | Nouveaux `SearchWorkspace.Model/UI` : vues personnelles, sélection d’export explicite, aperçu et comparaison depuis la base. | **Non raccordés au XAML ni au registre.** Le patch d’intégration Core a échoué avant écriture. Code à relire et tester, fonctionnalités non livrables en l’état. |
| Atelier | Bibliothèque SQLite versionnée, dépendances, Query/2 avec ET/OU/NON, paramètres, unités, collections ANY/ALL/NONE, cohérence temporelle ; QuerySchema/Details/Transfer présents. | Intégration modules/opérations, bibliothèques C# et derniers raccords incomplets. Les exports et imports doivent être qualifiés. |
| Dashboards | Population exacte, règles par OU, suspension d’alertes, comparaison de relevés, pivots, widgets au clavier, couverture. | Validation native, cohérence avec recherche et projection résumée SQL à terminer. |
| Sondes | 23 nouvelles sondes détaillées documentées, types/unités/limites ; Instances typées et tableaux conservés, pagination et budget explicite. | La présence d’une sonde ne termine pas un thème entier. Voir [CATALOGUE-SONDES.md](CATALOGUE-SONDES.md). |
| Détails | `ProbeDetails` ouvre uniquement la famille enregistrée ; nombre rapporté, nombre stocké et complétude séparés ; anciens Rows lisibles sans inventer leurs colonnes. | Tests préparés, parcours graphique non validé. |
| Native | `ObservationReader.ReadProbe` traite une famille avec bornes ; moteur Query C# étendu. | **DLL présentes potentiellement antérieures aux sources. Rebuild obligatoire après gel.** |

Ne pas annoncer les 160 points réalisés à partir de ce tableau. La collecte adaptative, profils, campagnes durables, certains diagnostics AD, fournisseurs avancés, imports, automatisation locale et livraison nécessitent encore des développements ou une revue de couverture.

## Raccordements prioritaires à reprendre

### Stockage et mémoire

- `ObservationProjection=Summary` doit être demandé par Fleet/Park ; Full reste destiné aux détails ciblés. Le writer stocke des résumés distincts réussite/tentative pour éviter de lire les Instances de milliers de sondes. Le raccord complet dans Engine n’est pas confirmé à l’arrêt.
- Fallback legacy du résumé borné à 16 Kio UTF8 ; au-delà, `SummaryMissing` / `SummaryUnavailable`, jamais zéro ou mesure saine. Les données brutes restent accessibles en lecture explicite.
- `DetailProjection=QuerySummary` limite les lectures WmiQuery aux petites colonnes résumées. Absence de résumé legacy = inconnu. Les requêtes de collection évaluent les pages puis libèrent les Instances ; garder verdict, date et couverture seulement.
- `StorageContext.UI` effectue encore SELECT et initialisation sur le Dispatcher. Travail demandé à l’agent, interrompu : worker Maintenance prépare le schéma sous lease, confirme `SchemaReady` et `TargetWritable`, puis Switch valide le reçu et persiste la préférence avant invalidation des vues. Ne pas annoncer cette correction appliquée.
- `DomainMetadata` demandé pour le schéma AD sans inventer de GUID machine : table Core présente, validation/writer/readback dédiés non constatés lors du relais. Contrat envisagé : DomainDn, Family=AdSchema, RequestKey, Data, statut et dates séparées.

### Sécurité des comptes

Deux sites Core signalés en relecture, sans correction revendiquée :

- `Get-DomeniaLogonHarvestWorkerCode` : `Get-WinEvent` sans `Enter/Exit-WCredentialAttempt` ; catch sans `Register-WCredentialFailure`.
- Ancien diagnostic Security 4624 : accès événements sans chaîne complète d’identité/garde.

Rechercher par fonction et appel plutôt que par anciens numéros de ligne. Les nouveaux diagnostics lastLogon multi-DC, 4740 et schéma AD étaient au stade de conception ; aucun fichier DirectoryDiagnostics trouvé à la passation.

### Interface et contrats

- Raccorder SearchWorkspace : XAML vues/aperçu/comparaison/périmètre export, exports Modules, appel d’initialisation, capture/restauration du tri dans l’historique. Ancre actuelle des résultats : `</Grid></StackPanel><Grid Grid.Row="1">`, puis ligne vide, puis `DgObjects`.
- Vérifier les types/présences réels du XAML et les dictionnaires de données avant de réutiliser les nouveaux modèles.
- Actualiser les exports depuis l’annexe `domenia-storage-exports.json`, plus QuerySchema, QueryDetails et QueryTransfer.
- Ajouter les nouvelles opérations et leurs factories composées au générateur. Le SHA de StorageMaintenance était encore un placeholder. Ne pas contourner les contrôles d’intégrité.
- Regénérer migration, contrats, baselines de préchargement, manifests et limites de distribution après gel des sources ; reconstruire Native et Query et leurs empreintes/provenances.
- La dérivation Domenia de `M4D.Admin.Common.Query` reste distinguée de l’amont 0.1.1. Coordination avec Pesto/FilPro engagée ; aucune promotion en bibliothèque commune validée.

## Validation

Les rapports présents dans `validation/2026-10-13/central-store/` comprennent notamment favoris, sessions, anciens builds Native/Query et charge Query. Ils concernent des états antérieurs aux dernières modifications. **Ils ne valident pas l’arbre courant.** Le work-ledger antérieur conserve encore une cible 5 000 et doit être réconcilié avec la cible 10 000/20 000.

De nombreux tests ont été préparés sans exécution après la consigne de report : stockage, familles/résumés, sondes, bibliothèque, Query/2, santé, limites recherche. Aucun nouveau test ni simulation n’a été lancé pour ce relais.

À la reprise autorisée : achever le développement et l’intégration, puis exécuter parsing et contrats, modèles purs, migrations et scénarios de panne, qualification native PS5.1/net472, charge 10k/20k et parcours graphiques. Corriger les défauts révélés, refaire les contrôles concernés, produire les captures et guides v1.0, construire DEV/PROD, puis commit/push et vérification distante.

La disponibilité actuelle du PC, du Mac graphique et de VirtualBox n’a pas été vérifiée pour la passation. Ne pas réutiliser un ancien résultat de disponibilité comme preuve. Les identifiants ne sont pas recopiés dans ce document.

## Travail Spark et agents interrompus

Les trois agents actifs ont été interrompus : `engine_audit` (stockage/moteur), `progress_timeout_policy` (dashboard/catalogue/AD), `search_engine_deadlines` (atelier/Query).

L’avis de recherche initial est conservé dans `AVIS-SPARK.txt`. Une consultation ultérieure pour un modèle pur de cohérence de populations a été arrêtée ; aucun résultat public n’était présent dans son fichier de sortie. Son prompt complet est conservé en annexe pour éviter de reconstruire la demande. Ne pas confondre cette consultation inachevée avec l’avis initial reçu.

Annexes de développement préservées, **brouillons non exécutables comme preuves** : helpers de projection, liste d’exports stockage, lecteur de bibliothèque et prompt de cohérence. Les fichiers effectivement intégrés au dépôt restent l’autorité pour reprendre le code.

## Mémoire et reprise courte

Note KBZA prévue avec ID stable `domenia-relais-pause-20261013`. Son reçu est conservé dans `relais-technique/KBZA-RECU.json` une fois retourné par le client. Vérifier son état : fichier écrit, commit local et push sont distincts. La synchronisation de la note ne transfère pas le code applicatif et ne prouve pas qu’un autre pair l’a récupérée.

**Premier geste du repreneur :** lire ce relais, la feuille de route et le diff réel du clone ; préserver les fichiers non suivis ; confirmer le périmètre de reprise après la pause. Ne pas relancer de développement, test ou publication par simple lecture de la note.
