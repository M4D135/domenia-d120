# État courant — 18 octobre 2026

RC1.17.20 clôt le dernier contrôle critique : deux démarrages réels, fenêtre et réglages conservés, premier cycle automatique après réouverture, intégrité et contenu de la sauvegarde vérifiés. Le défaut de chargement des préférences RC18 est corrigé ; la recherche LDAP asynchrone révélée en RC19 est corrigée par une page inférieure au quota (ancien échec reproduit, trois lectures natives réussies). Preuves et bases récupérées hors VM, fermeture et nettoyage confirmés. David peut effacer les VM pour ce périmètre ; qualification générale et décisions 134/146 restent ouvertes. [Preuve finale](../../../../validation/2026-10-18/rc20-final-session/README.md).

Historique intermédiaire RC19/RC18 :

RC18 a révélé un défaut supplémentaire d’ordre d’initialisation : politique de stockage appliquée avant le chargement des préférences. RC19 déplace cette étape après la présentation. Dernier contrôle applicatif RC1.17.19 réussi : deux démarrages et connexions Windows, maximisation retrouvée, taille/position normales restaurées, réglages de sauvegarde 48 h / 5 copies conservés et premier cycle automatique réel après réouverture. Reçu, SHA-256, quick_check et contenu vérifiés ; fermeture normale et runtime inchangé. Preuves récupérées hors VM ; aucune VM requise pour le périmètre critique demandé. Qualification générale et décisions externes 134/146 ouvertes. [Preuve](../../../../validation/2026-10-18/rc19-final-session/README.md). Les VM restent présentes ; leur effacement appartient à David.

**RC1.17.18** : état normal/maximisé, taille et position mémorisés ; sept cas natifs WPF réussis, packs reconstruits. Les parcours RC17 de sauvegarde automatique et de restauration par interface après corruption sont qualifiés, preuves et bases de test récupérées sur le Mac. Voir [suivi](SUIVI-2026-10-18.md), [stockage RC17](../../../../validation/2026-10-18/rc17-storage-ui/README.md) et [fenêtre RC18](../../../../validation/2026-10-18/rc18-window-geometry/README.md). Les VM restent démarrées, application isolée et tâches de test fermées ; verrouillage automatique W11-01 désactivé sur demande. Décisions 134/146 et qualification générale ouvertes.

Historique des qualifications précédentes :

Voir [SUIVI-2026-10-18.md](SUIVI-2026-10-18.md) et EXECUTION.json. **RC1.17.17 : défaut réel du timeout WMI corrigé et vérifié.** Lecture AD réelle puis lot WMI/DCOM de deux cibles : timeout moteur sur la première, succès distant de DC01, deux observations SQLite, fin 2/2 sans arrêt. Trois cas de non-régression Windows 5.1 passent ; démarrage contrôlé et intégrité des deux ZIP vérifiée. Preuve : [rc17-live-ad-wmi](../../../../validation/2026-10-18/rc17-live-ad-wmi/README.md).

La qualification critique RC16 (96 cas) reste historique. La requalification ciblée RC17 interface/santé/sauvegarde est maintenant consignée dans [rc17-ui-health-backup](../../../../validation/2026-10-18/rc17-ui-health-backup/README.md) : 37 cas santé, 10 stockage (61 assertions), 63 cas WPF uniques après correction des bancs ; runtime et ZIP inchangés. Consulter la preuve pour le parcours visuel et les limites. Restent la qualification générale, les autres transports/volumes/parcours WPF et les décisions externes 134/146. Les deux VM CNAMTS sont démarrées ; le profil de l’opérateur est préservé. La pause ci-dessous est historique et ne décrit plus le dépôt courant.

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
