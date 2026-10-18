# État courant — 18 octobre 2026

Voir [SUIVI-2026-10-18.md](SUIVI-2026-10-18.md) et EXECUTION.json. Corrections RC1.17.16 intégrées ; qualification Windows critique réussie (démarrage, reprise WMI après timeout injecté, santé, sauvegarde/restauration ; 96 cas natifs sans échec et connexion réellement affichée). Qualification générale, AD/WMI distants réels et décisions externes 134/146 restent ouverts. Preuve : [rc16-windows-critical](../../../../validation/2026-10-18/rc16-windows-critical/README.md). La pause ci-dessous est historique et ne décrit plus le dépôt courant.

---

# Reprise après pause demandée

Relais complet : [RELAIS-PROJET.md](RELAIS-PROJET.md). Les fichiers techniques temporaires utiles sont copiés dans `relais-technique/`.

Développement interrompu le 13 octobre 2026 à la demande de David pour économiser les tokens. Les changements sont locaux et non validés. Aucun nouveau test ni simulation depuis la consigne de tester à la fin du développement. Ne pas publier le logiciel avant intégration et validation complète.

## Travaux du dernier passage

- Core : menu sauvegarde automatique/conservation, reprise de redirection au démarrage, schéma extrait vers Get-DomeniaSqliteSchemaText ; colonnes summary_payload/attempt_summary dans observations et détails, table domenia_domain_metadata.
- ProbeDetails : conservation typée bornée, pagination, ancienne représentation Rows lisible sans inventer de colonnes/types ; total incomplet explicite. Widget Détails raccordé par agent.
- SearchWorkspace.Model/UI créés : vues personnelles, aperçu SQLite, comparaison, sélection export explicite. ATTENTION : intégration XAML/registre et appel Initialize-DomeniaSearchWorkspace non faits ; tentative patch Core interrompue avant écriture (Results anchor missing). Ne pas les considérer utilisables. Ancre réelle : </Grid></StackPanel><Grid Grid.Row="1"> puis ligne vide puis DgObjects.
- Stockage : nouveaux exports à intégrer depuis /tmp/domenia-storage-exports.json. Agent engine_audit interrompu pendant raccord stockage / DomainMetadata / projection SQL / suppression SQLite synchrone StorageContext.UI ; vérifier fichiers réels.
- Agent health/progress_timeout_policy : catalogue documenté, projection Native ReadProbe, résumé Fleet/Park, nouveaux diagnostics AD en cours. Préparé mais non testé.
- Agent query/search_engine_deadlines : Query/2, bibliothèque SQLite, QuerySchema et QueryDetails en cours. Modules, opérations et DLL à intégrer/reconstruire.

## Défauts relevés à reprendre en priorité

- Deux anciennes lectures Get-WinEvent dans Core contournent la garde de compte : Get-DomeniaLogonHarvestWorkerCode (vers16737 avant déplacements) sans Enter/Exit-WCredentialAttempt, catch sans Register-WCredentialFailure ; diagnostic Security4624 (vers19053). Corriger avant validation.
- Stockage : agent devait déplacer les SELECT synchrones et InitializeDatabase de StorageContext.UI vers worker Maintenance avec reçu SchemaReady/TargetWritable.
- Factory schéma contient interpolation Get-DomeniaQueryLibrarySchema ; génération migration doit inclure les deux fonctions.
- /tmp/domenia-family-projection-helpers.ps1 : source courante des helpers convert/read/projection. ObservationProjection Summary doit être raccordée Fleet/Park, Full réservé détails.
- Tous hashes workers, export module registry, manifests/packs et DLL Native/Query sont potentiellement périmés. Ne pas lancer application tant que développement/integration non achevés.
- EXECUTION.json reste un suivi incomplet des 160 points, aucun achèvement global revendiqué.

Roadmap seule déjà poussée : 42e87e6e7753a69c2cfe4eef9aafeb3aa6861abe sur master. Les agents actifs ont été interrompus lors de la pause.
