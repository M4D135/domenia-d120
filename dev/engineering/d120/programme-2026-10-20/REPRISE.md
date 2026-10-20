# Reprise RC1.17.39 — programme des 60 points

## État au 21 octobre 2026 : qualification critique ciblée réussie

**Contrôles critiques ciblés réussis, aucun échec connu restant dans ce périmètre.** Le dernier checkpoint local connu est `4d90115b0ab7a71c7559ed343fcd4890a897c204` sur `codex/rc39-60points-checkpoint`. La publication finale est gérée par root ; ne pas déduire un push master de ce document.

PROD qualifié : SHA256 `27244218D38B6924F7F0F5BD246C613458C328CE3472DE963FD6E75651B7B7A9`. 177 fichiers déployés avec manifeste, 176 fichiers runtime. `FinalCompactIntegrity` termine avec le code 0 ; `VisualCompact` confirme l’état vide défilable, son action visible et le dashboard peuplé, sans nouvel ERROR. L’arbre est encore en chargement sur cette capture ; les 11 branches déclarées/sept éléments UIA sont attestés par le retest précédent au runtime d’arbre identique. Le correctif final Main.xaml conserve Core inchangé. Préserver ce PROD exact lors du dernier rebuild DEV documentaire.

Instruction active : finaliser les documents et le pack DEV, conserver la parité runtime, puis commit/push et vérifier la publication. VM et preuves conservées ; aucune nouvelle campagne. Le point 59 et la qualification étendue restent hors de cette passe. `acceptance_passed=false` ; aucune qualification 60/60 annoncée.

## Code intégré et résultats acquis

Les lots collectes 18–29, parcours/dashboard 30–48, stockage 49–54, aperçu mémoire/SQLite, découpage AssociationRows et documentation sont intégrés. Détail et limites dans `Suivi_60.json`, `Lot-*.md`, `Revue-Spark.md`.

- **6** : delta des champs simples et protections intégrés ; R2 LocalPreview **21/21**, y compris génération du panneau de connexions, invalidation des droits, fraîcheur/secrets. Les formes sensibles/inconnues gardent le remplissage complet.
- **38** : caches de plans/cartes, record Query Computer exact et fournisseur logiciel intégrés. R2 QueryTargets **39/39**, Boards Programme 38 **4/4** ; `SelectionComplete=true`, `Complete=false` (pas les 73 cas). Aucun gain global chiffré.
- **8** : modèle observable et virtualisation des conteneurs intégrés. R2 compilation, TreeRendering **4/4**, Navigation Programme 8 **5/5** (sous-ensemble). Après les trois échecs R2/R3 et correction du trigger de thème imposant un panneau standard, R4 TreeVirtualization **8/8** : WPF réel, 10 000 DTO synthétiques, 40 conteneurs au premier relevé, maximum 61 sur neuf cibles. Aucun AD/réseau réel ni benchmark mémoire du processus. Aucun OpenCode actif.
- **WiringRecherche** : **47 succès R4 + 5 retests réussis R5 + D028 réussi R6**. Aucun échec connu restant parmi ces cas ; les 53 cas ne sont pas rejoués ensemble. Les anciens échecs et retests filtrés `Complete=false` restent conservés.

Registres, manifeste et runtime final sont figés et vérifiés. Le rebuild DEV documentaire doit préserver les 176 fichiers runtime et le PROD qualifié exact. Ne pas relancer le runner 34 suites `Verify-60.ps1` abandonné.

## Preuves déjà conservées

Dossier `validation/2026-10-20/rc39-critical/`, candidat initial avant les derniers changements 6/8/38 :

- Démarrage/intégrité natifs, PS5.1 (342 fichiers sans erreur), StartupLogin 48/48.
- StoragePreferences 9/9, Maintenance 33/33, Faults 8/8 (SQLITE_FULL simulé par quota, pas disque physique rempli).
- RemoteStore 34/34, CollectCircuit 7/7 (AST), HealthRules 23/23.
- Après réparations des imports réels de fixtures : LocalPreview 19/19, LiveSearchView 16/16, WiringCache D024 1/1.
- AD/WMI/SQLite réels : cible expirée puis DC01 réussi, lot 2/2 dont 1 échec attendu, pas d'arrêt global. Premier délai réduit à 2 s pour le scénario.
- UIA : connexion, Premiers pas/OU sans collecte implicite, AD confirmé, dashboard, recherche, fiche, poste/santé, fermeture. Session verrouillée pendant cette passe : aucune preuve pixels. Session ensuite déverrouillée avec reçu LogonUI absent et capture bureau locale.

Guides sources RC39 et quatre DOCX/PDF régénérés, QA visuelle et synchronisation SHA réussies (`Guide-QA.json`, `DocSync.json`). Captures RC20 explicitement historiques. Pas de gain global de performance chiffré établi.

## Finalisation restante

1. Conserver les preuves : WiringRecherche 47 R4 + 5 R5 + 1 R6, sans réexécution groupée des 53 cas ; VisualCompact réussi et anciens échecs conservés.
2. Reconstituer uniquement le DEV documentaire, contrôler sa parité avec les 176 fichiers runtime et préserver le PROD SHA256 indiqué ci-dessus.
3. Root finalise README/packs/manifestes de livraison, commit/push et vérification du SHA distant. Le garde général Publishable=false reste distinct de cette recette critique ciblée.

## Commandes et accès

Dépôt : `work/opencode-supervision-rc14/isolated-checkout`. Livraison : `https://github.com/M4D135/domenia-d120.git`. **Ne pas pousser origin**, qui est un ancien bundle local. Préserver les modifications concurrentes.

```sh
python3 dev/tools/integrate_lots.py --refresh-functions --apply
python3 dev/tools/update_migration_worker.py --apply
python3 dev/tools/update_worker_contracts.py --apply
python3 dev/tools/release_contract.py --stamp
python3 dev/tools/validate_powershell_static.py
python3 dev/tools/build_packages.py --output ../../rc39-local-first/packs
```

VM conservée `DOMENIA-FIRSTRUN-20261020`, UUID `bc2f1ac0-9545-49bd-a0f5-cb89d352cf61`, hôte `degun@192.168.1.173`, 1 vCPU/4 Go. Helper `../../rc38-final/lab.py`, guestcontrol par fichier opaque existant (ne pas lire son contenu). Récupération fraîche : `../../rc39-local-first/get.py`, ou depuis le workspace `work/rc35-qualification/pull.py`. Aucun secret dans scripts/journaux/Git. Keep-Console borné 45 min ; vérifier session avant le parcours final, sans changer de politique de verrouillage.

## Historique : code stabilisé et delta Windows lancé (21:19 UTC)

Codegates 6/8/38 reçus, revue indépendante sans défaut concret restant. Aucun OpenCode actif. Registre fermé, contrats97, release et contrôle lexical350 passent ; preload réépinglé avec décision de revue explicite. Packs candidats DEV `FCBB2FBC1FFEABA22482D26A0A7DD84F9F379DDC28260C8082795333DE574E4D`, PROD `9035B033D16C4E88DD545EA1741AC668BFB19EE858FA797F37508695FE233A8C`, 176 fichiers applicatifs identiques. Copies initiales conservées dans `../../rc39-local-first/packs-initial-critical`.

Déployés dans `RC39-final/dev` et `RC39-final-ui/prod`, empreintes contrôlées, profil isolé du candidat initial recopié application fermée. Session déverrouillée, LogonUI absent. `Verify-DeltaFinal.ps1` lancé ; sorties `rc39-final-delta`. Ne pas lancer de second runner. Chaque banc est borné à240s. Restent verdicts/corrections, pixels du pack PROD et publication master.

## Historique : Delta1 terminé ; corrections et relance ciblée

Checkpoint code stable vérifié `81ac0cb66a246bce9061d5fa9ffd030f7fd0017a`. Résultats delta1 dans `validation/2026-10-20/rc39-critical/rc39-final-delta` : modules 185/185, QueryTargets 39/39, favoris 20/20, associations 5/5, diagnostic 4/4, D024 1/1 et quatre fichiers de règles passent. Échecs corrigés : référence System.Xaml/System.Core (runtime arbre), vraie vérification de type PSCustomObject (runtime cache), fixtures UTC/Filter dupliqué/import réel Park. Aucun OpenCode actif. Relance `Verify-DeltaRetest.ps1`, sorties `rc39-final-retest`, à lancer après patch des candidats. Ancien harnais ExitCode=null ; nouveau harnais Process .NET conserve les vrais codes. Archives delta1 conservées dans `packs-final-r1`, originales critiques dans `packs-initial-critical`.

## Historique R2/R4 : six cas WiringRecherche encore en correction à ce jalon

R2 dans `validation/2026-10-20/rc39-critical/rc39-final-retest` : LocalPreview 21/21, QueryTargets 39/39, Boards Programme 38 4/4 (`SelectionComplete=true`, `Complete=false`), TreeRendering 4/4, Navigation Programme 8 5/5 (`Complete=false`), règles pures Park 14/14. Les autres succès R1 restent inchangés : modules 185, favoris 20, associations 5, diagnostic 4, D024 1 et règles BoardFleet 26/Collection 49/DirectorySync 11/Observability 17.

R4 `rc39-tree-r4/TreeVirtualization.json` : 8/8 sous WPF réel, 10 000 données synthétiques, maximum 61 conteneurs sur neuf cibles (premier relevé 40). Les échecs R2/R3 restent conservés ; le panneau standard imposé par le trigger hérité a été corrigé. Ce résultat ne mesure pas la mémoire du processus et ne qualifie pas un parc AD réel. WiringRecherche R4 a été lancé sans filtre : 47/53 ; les dix cas visés en R2 passent, six autres échecs sont en correction/retest chez parcours. Voir le README des preuves pour les liens et limites exactes. Point 59 hors passe ; `acceptance_passed=false` et qualification générale ouverte.

## Historique visuel : profil corrigé avant le retest

Le profil copié de `RC39-critical-ui` vers `RC39-final-ui` conserve l’identité SQLite de l’ancien chemin. Le premier lancement final a donc signalé huit erreurs, dont les refus de contexte LocalIndexRead/LocalStore. Vérification du code : `Store.Model.ps1:Get-DomeniaStoreId` lie l’identité au chemin complet normalisé et au domaine ; les gardes restent actives. Le Diagnostic.json classe ce premier passage NOT_ACCEPTED_DESPITE_UIA_NAVIGATION_PASS : le Passed=true du script de navigation ne vaut pas validation visuelle.

Décision : conserver le `data` original et installer le runtime final en place dans `C:\DomeniaLab\RC35-qualification\RC39-critical-ui\prod`, 177 fichiers vérifiés après l’upgrade en place (archive SHA256 82752528…), puis reprendre le parcours visuel avec arbre peuplé et aucun nouvel ERROR. Résultat final et revue des pixels encore attendus à ce jalon historique ; le reçu Compact ultérieur conclut la passe ciblée. Archives initiales et preuves conservées ; aucun DDL ni StoreId forcé. Un déplacement réel vers un autre chemin passe par la maintenance Déplacer/Restaurer, qui vérifie et réidentifie une copie avant bascule. La copie manuelle du profil ne réalise pas cette migration.

## Clôture des échecs WiringRecherche connus

Les reçus `rc39-final-close/WiringRecherche.json` (R5 : cinq succès, D028 encore en échec) et `rc39-wiring-final/WiringRecherche.json` (R6 : D028 1/1, ExitCode 0) ferment les six échecs du passage R4. Bilan cumulé 47 + 5 + 1 ; les 53 cas ne sont pas rejoués ensemble. Les jalons antérieurs ci-dessus conservent leur état historique. Aucun verdict global des 60 points ni acceptance_passed=true. Le reçu VisualCompact ultérieur conclut le contrôle critique ciblé.

## Verdict final ciblé Compact

`validation/2026-10-20/rc39-critical/rc39-visual-compact/VisualCompact-Result.json` : Passed=true, TreeItems=2, EmptyStateScrollable=true, EmptyActionVisible=true, LogErrors vide. `BuildQualifiedCompact.json` lie le PROD exact au SHA256 27244218D38B6924F7F0F5BD246C613458C328CE3472DE963FD6E75651B7B7A9. Le ScrollViewer ajouté à l’état vide évite sa coupe dans 68 px ; Core inchangé. Intégrité native exit 0, 177 fichiers déployés pour 176 runtime. Revue des pixels réussie dans VisualReview.json : action atteignable et dashboard peuplé. L’arbre Compact est encore en chargement (TreeItems=2 avec placeholder) ; VisualRetest précédent au runtime d’arbre identique rapporte 11 branches et sept éléments UIA. Plus de qualification critique restante ; les limites étendues de Suivi_60 et le point 59 demeurent. Quatre tâches de labo retirées par CleanupOwnTasks ; VM running et données conservées.
