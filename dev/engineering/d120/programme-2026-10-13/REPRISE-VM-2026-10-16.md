# Reprise Domenia — tests Windows et corrections du 16 octobre 2026

> Cette passation conserve l’état initial et l’incident. Pour l’état actuel du
> candidat RC1.17.9, les preuves, les opérations ré-épinglées et le reste à faire,
> lire `validation/2026-10-16/windows-recovery/README.md` depuis la racine du dépôt.
> Les anciennes indications « non testé », « packaging bloqué » et processus en
> cours ci-dessous ne décrivent plus nécessairement l’état présent.

## Mission et consignes actuelles de David

Continuer jusqu’aux corrections, essais VM, captures ≥ 1080p sans infobulles, documentation DOCX/PDF v1.0, packs DEV/PROD ordinaires et commit/push master. WAD abandonné. Ne pas annoncer une qualification sans preuves. Le logiciel doit être fiable, exact et adapté à 10 000 postes, avec collecte → SQLite → GUI.

Dernière consigne : **économie maximale de tokens ; Spark en priorité et OpenCode DeepSeek Free**. Codex cadre, intègre et vérifie. Pas de rafale d’agents Codex. Une demande Spark est déjà en cours : attendre son résultat avant une nouvelle. OpenCode est installé mais aucun appel n’a encore été lancé par cette reprise.

Lire `CLAUDE.md`, le relais `RELAIS-CODEX-2026-10-16.md` et les consignes KBZA. Le présent document remplace les informations d’accès VM périmées de `SUIVI-2026-10-16.md`.

## Dépôt et travaux à préserver

Dépôt `/Users/david/Documents/Projets/Domenia-D120`, branche master, HEAD/origin `f21aab6d16fa7a37db1b6ebd3a4c4c24744890e6`. Environ 39 fichiers modifiés localement : **aucune des corrections Windows ci-dessous n’a encore été commitée ni poussée**. Ne rien réinitialiser. Le chat précédent cesse les modifications lors de la création de la nouvelle tâche ; seuls les processus de tests et l’appel Spark déjà lancés continuent.

Les packs `Domenia-livraisons/2026-10-16-RC1.17.8/` restent les anciens candidats, non qualifiés et connus défectueux. Refaire une nouvelle révision après corrections ; ne pas écraser les anciennes preuves. Le registre EXECUTION.json a 151 implémentations et 9 qualifications restantes (41,43,106,114,116,125,126,129,130) : aucune clôture sans preuves liées aux ZIP finaux.

## Accès labo fonctionnel

- SSH `degun@192.168.1.173`, socket `/tmp/domenia-lab-codex-20261016.sock` (ControlPersist 1800).
- Hôte DESKTOP-285EKHU, relais uniquement. Tests exclusivement dans **CNAMTS-W11-01**, UUID `c7f3cf04-5c23-45b5-ae3e-ed94193c99a0`, ordinateur invité W11-01, domaine cnamts.local.
- PS 5.1.26100.6584 x64 STA ; OS 10.0.26200.0. Session console 1 CNAMTS\Administrateur ouverte par David, confirmée par quser et capture.
- David autorise explicitement Windows UI Automation / SendInput et clavier VirtualBox pour tester Domenia : CUA Windows App échouait. Aucun besoin de redemander. Ne pas toucher aux VM Pesto/Filpro/DC.
- **Interdiction de lire le fichier de mot de passe labo**. vmctl utilise son chemin via `--passwordfile`, aucun secret ne doit être affiché, copié ni mis dans un script/argument.
- Depuis le dépôt : `DOMENIA_LAB_SOCK=/tmp/domenia-lab-codex-20261016.sock LAB_DIR=NOM bash dev/engineering/d120/lab/lab.sh ps 'commande'`, ou `file /tmp/script.ps1`, `get out /chemin/local`, `sync`.
- `sync` remplace son LAB_DIR : employer un NOUVEAU dossier, jamais un dossier de campagne active. Les processus guestcontrol sont session 0, pas une preuve d’interaction visuelle.
- Helper hôte `/tmp/domenia-host-ps.py` : lit un script PS sur stdin et le transmet encodé via SSH. Ne s’en servir que comme relais VBox/UIA, jamais pour exécuter les tests sur l’hôte.

### Processus encore en cours à laisser finir

1. Campagne baseline immuable `C:\DomeniaLab\d120-rc1178\out\campaign` (lancée env,suites vers 07:49). Processus initié dans ancien chat, exec session 90251 ; le nouveau chat peut inspecter les fichiers/processus invité. Beaucoup de suites déjà terminées, certaines échouent, Installer a atteint 600s. Ne pas relancer toute la campagne sans raison.
2. Batch fix7 dans `C:\DomeniaLab\d120-rc1178-fix7\out` : EngineResilience, Boards, DnScopes, IndexSorting, IndexPersistence, ObservationProjections, ObservationReaderBudget, Freshness, Interface, LoadStability. Exécution lancée dans ancien chat, session 27594 ; dernière étape LoadStability en cours lors du relais. **fix7 précède le correctif Dictionary**.
3. Spark analyse géométrie : prompt complet `/tmp/domenia-spark-geometry-patch.txt`, réponse `/tmp/domenia-spark-geometry-patch-response.txt`, progression `/tmp/domenia-spark-geometry-patch-progress.txt` (session 56626). Appel `~/bin/kbza ask --prompt-file ... --no-memory --max-tokens 0 --reasoning-mode direct`. Première réponse `/tmp/domenia-spark-geometry-response.txt` trop vague, non intégrée. Ne pas reprendre aveuglément ses seuils ou MinHeight.

## Essais GUI et résolution — à terminer

Démonstration/preview seule pour le moment ; aucun parcours GUI réussi. La console est maintenant visible mais **1710×948**, zone utile 1710×900. Le harnais refuse correctement les captures < 1920×1080 utiles. VBox setvideomodehint et setscreenlayout 1920×1200 n’ont pas changé le mode. `GUI/AutoresizeGuest=false` a été écrit sur cette VM uniquement ; pas de réglage global.

Essai d’EnumDisplaySettings / ChangeDisplaySettingsEx dans la session interactive : 1920×1200×32 absent des modes exposés. La tâche échoue donc proprement avant changement. Scripts temporaires : `/tmp/domenia-display.ps1`, `/tmp/domenia-launch-journey.ps1`, `/tmp/domenia-launch-journey-hd.ps1`. Dernière preuve console : invité `fix7\out\gui\console.txt`. Prochaine piste : menu Affichage VirtualBox, désactiver le redimensionnement automatique dans la console active puis sélectionner une définition >=1920×1200 / mode adapté. Ne pas affaiblir le test de taille. Vérifier état visuel actuel avant clic.

Harnais versionné `dev/engineering/d120/lab/Invoke-DomeniaGuiJourney.ps1` : UIA + SendInput, preview fictive hors réseau ou application déjà connectée. Il distingue SimulatedEvents et HumanJourney : ne pas fabriquer un relevé humain. Peut faire des parcours automatisés puis une inspection visuelle par l’agent ; ne pas certifier un test AD réel avec le preview.

Tâches temporaires créées, à nettoyer seulement après utilisation :
- Hôte `Domenia-Codex-OpenConsole-20261016`, ouvre la console séparée de la bonne VM ; ne pas arrêter la VM lors du nettoyage.
- Hôte `Domenia-Codex-Observe-20261016`, capture écran hôte et fenêtres UIA dans `C:\Users\degun\domenia-lab\vmstage\domenia-host-screen.png` et `domenia-host-windows.json`. Script local `/tmp/domenia-host-observe.ps1`. Redémarrer la tâche pour état frais.
- Invité `Domenia-Codex-Gui-20261016`, principal Interactive CNAMTS\Administrateur, script `fix7\out\gui\run.ps1`. Dernier résultat 1 (résolution insuffisante). Ne pas lancer deux pilotes GUI à la fois.

## Corrections runtime locales

- Support.UI : TabItem.Add_Selected invalide en WPF ; utilisation de Selector.AddSelectedHandler, OriginalSource et désabonnement. **Support 54/0 natif**.
- Core GetStoredTheme : switch `$Preference` et variable `$preference` collision PS insensible à casse, renommée. **Theme 32/0**.
- Automate : paramètre `$Sections` et dictionnaire `$sections` collision, renommée. **7/0**.
- Core fermeture : registre AsyncJobs non-IDictionary refusé avant Values, ne pas considérer illisible comme vide. Core selftest suit les nouveaux événements DirectoryRead. **Main 388/0**.
- Collection.UI : valider famille fraîcheur avant sérialisation qui éliminait une clé inconnue. **CollectionWiring réussi**.
- **Dernier correctif non encore testé** : BoardFleet.Model utilisait IDictionary.Contains sur Dictionary générique, échoue en PS5.1, reproduit nativement ligne 843. Six lectures passent par Test-DomeniaDictionaryKey. Common.Model évite l’exception systématique : Hashtable/OrderedDictionary.Contains, autres ContainsKey puis repli. Tests ajoutés rules/Common.Tests et Freshness (dates/probe refusé/seuil historique). Lire le diff et exécuter sur nouvelle snapshot fix8.
- Contrats repinnés après revue : **LocalStore** et RegistryFingerprint uniquement, modification Common/BoardFleet composée. audit_preload rebaseliné avec décision explicite, 251/0.
- **Packaging encore bloqué** : update_migration_worker.py constate que sa composition contient aussi Common modifié. Examiner le diff de la composition, régénérer après revue, repinner les opérations correspondantes puis audits. Les manifestes sont actuellement périmés : build_packages --manifest-only n’a PAS abouti. Ne pas prétendre que le lanceur actuel démarrera.

## Tests et fixtures corrigés

Les nombreuses modifications de tests rétablissent les dépendances/extractions après découpage du cœur et la sémantique centrale SQLite. Ne pas effacer un échec en affaiblissant une assertion.

- Invoke-LabRun lit les paramètres du SCRIPT via AST ; ancien regex détectait Quiet d’une fonction interne. BoardRefresh/DashboardState repassent.
- CommandPalette imports réels + expression ScriptBlock parenthésée + JSON PS5 : **14/0**.
- CompactUi extraction breadcrumb : **22/0**. AdAudit regex exact attribut secret + JSON **17/0**.
- Faults fabrique composée réelle et null-array corrigée **25/0**. EmbeddedUi **101/0**. EngineLoad **4/0**. DashboardScale réussi (220s, environnement chargé). NetworkFaults/StorageFaults réussis.
- DirectoryReads byte[] retourné non déroulé et Count fixture : **réussi**. Aucune modification worker AD faite sur la suggestion erronée du Spark.
- ObservationFamilies **8/0** ; ObservationProjections **6/0** ; ObservationReaderBudget **3/0**, 40 016 assertions et 20 000 observations décodées (896ms dans un essai). Cela ne qualifie pas un parc réel de 20k.
- Preview imports Continuity/Park/Search et garde réelle TestClassicResultCurrent : **Interface 51/1** restant (« Intervenir : quatre cartes… »).
- EngineResilience réécrit les vieux tests LiveCache/metadata selon commit→lecture SQLite ; **47/5** maintenant. Restes : 4 cas CIM (Rows/count/troncature/First ; examiner limites et tableaux retournés), un cas ParkFailed compteur (fixture ObservationRows brute versus projection réellement lue). Ne pas faire de stubs de sécurité. Script de réécriture local `/tmp/domenia-fix-resilience.py` déjà appliqué.
- Boards **54/6**, rapports détaillés à lire. DnScopes et IndexSorting sortent 1 sans rapport ; lire stderr. IndexPersistence 1. Freshness 20/21 ; lire erreur SQLite. Derniers imports Common/Probes/QueryLibrary ne suffisent pas encore.
- LoadStability : collision `$privateMb`/`$script:PrivateMB` corrigée, mais generic Dictionary bug confirmé bloque encore la snapshot fix7.
- Geometry baseline **62/17** : grille résultats hauteur 0–5, arbre OU 23/75 à certains zooms/petits écrans ; 1px alignement DS06. Spark travaille au diagnostic précis XAML + UX, pas encore corrigé.
- Autres baseline : LastUser 13/8, Navigation 18/2, Installer timeout600s. Recueillir fin de campagne pour liste exhaustive.

## Preuves et chemins

Racine `/Users/david/Documents/Projets/Domenia-lab/runs/` :
- `20261016-rc1178-first/out` preflight natif compat/parser/StartCheckOnly OK et WorkerComposition12/0.
- `20261016-rc1178-campaign-progress/campaign/suites` baseline partielle, à rafraîchir.
- `20261016-rc1178-fix1/support` Support ; `fix2/out` Theme/Automation ; `fix3-final/out` Main/AdAudit/etc ; `fix4-progress/out` ; `fix5-final/out` Collection/Directory ; `fix6-progress/out` ; `fix7-progress/out` dernier lot partiel.

Lire aussi les tableaux `Results`/`Cases`, pas seulement `Tests`/`Checks` ; schémas de rapports différents. Certaines suites écrivent un booléen Passed, d’autres un compte. `_summary.json` donne exit/timeout/ReportWritten. Préserver les preuves hors dépôt ; ajouter une synthèse honnête versionnée.

## Outils de délégation

- Spark CLI avec prompt-file complet, sans plafonner sa sortie. Vérification indépendante obligatoire. Ne pas lancer spark crew.
- `/opt/homebrew/bin/opencode` installé. Relais indique `opencode/deepseek-v4.1-flash-free`, à vérifier par `opencode models`. Le 15 modèle saturé et partagé avec FILPRO. `opencode run --help` vérifié : `--model`, `--file`, `--dir`, `--format json`, `--auto`. Éviter un agent modifiant le même clone pendant intégration ; tâches de lecture/brouillon avec fichiers ciblés ou copie isolée. Ne pas exposer secrets/journaux privés. Aucun modèle OpenCode Go entraînant sur requêtes autorisé par le relais ; David demande maintenant DeepSeek Free, pas un basculement implicite vers d’autres modèles.
- Ne pas relire tout le projet ni tout relancer : déléguer les gros fichiers/rapports, tester les changements ciblés puis campagne finale liée aux nouveaux ZIP.

## Suite recommandée

1. Récupérer résultats Spark et campagnes en cours ; déléguer diagnostics mécaniques à OpenCode Free/Spark.
2. Terminer corrections natives et packaging composé (Migration/Common), nouvelle snapshot fix8, tests ciblés Dictionary/Freshness/LoadStability/WorkerComposition/parser.
3. Corriger layout et obtenir résolution utile >=1080p ; parcours GUI/captures réelles sans infobulles.
4. Rapport final/registre, version RC distincte, nouveaux packs DEV/PROD, preuves liées aux ZIP ; guides DOCX/PDF v1.0.
5. Commit/push master propres, noter KBZA avec ID stable et reçu. Ne pas annoncer tout fini tant que les qualifications manquent.

## Reprise du 16/10 après incident VM

- David demande de limiter les dépenses de tokens pour les essais VM : terminer le test de stabilité déjà lancé et vérifier uniquement les corrections indispensables; ne pas relancer la campagne entière.
- David a nettoyé le disque plein du PC de labo. Le disque virtuel de CNAMTS-W11-01 est présent et lisible. Après arrêt propre de Windows, le démarrage échouait sur `VBox.log` (`VERR_ALREADY_EXISTS`). Restart Manager a identifié le détenteur exclusif : ancien backend `VBoxHeadless` PID 9800 de cette VM, alors que VirtualBox indiquait `aborted`.
- Ce seul processus orphelin a été arrêté. Journal conservé dans `Logs/VBox.log.before-recovery-20261016-0941`, avec copie dans `vmstage/domenia-vbox-before-recovery.log`. Redémarrage GUI normal réussi à 09:41; Windows répond, 43,46 Gio libres dans son C:, console vérifiée à 09:43 et session ouverte par David.
- Attention : la VM utilise maintenant `SessionName="GUI/Qt"`. Son processus `VirtualBoxVM` porte la VM entière; ne plus le traiter comme une ancienne console détachable `--separate`.
- Résultats antérieurs récupérés sur Mac sous `Domenia-lab/runs/20261016-rc1178-recovered`, `20261016-rc1178-fix9-final` et `20261016-rc1178-fix10-recovered`. Les essais interrompus ne sont pas qualifiés. Résultats explicites : Interface 52/0, IndexSorting 545/0, IndexPersistence exit 0, Common 2/0, HealthRules 10/0, P-CD-09 10/0, WorkerComposition exit 0, compatibilité PS5.1 330 fichiers sans erreur, parser natif PASS.
- Deux brouillons Spark concernant EngineResilience ont été rejetés : limites 20 lignes/200 caractères obsolètes et assertions incorrectes sur le mode First. Les corrections retenues vérifient le contrat actuel de projection typée, le comptage complet malgré un budget de détails atteint, la conservation des tableaux et le seuil de chaîne 16 384. La fixture Park doit déclarer `InventoryAttempted=$true` pour exercer réellement une erreur d'inventaire.
- Le générateur des guides doit extraire `Write-DomeniaSwallowed`, comme l'aperçu UI. Les captures sont des illustrations natives WPF hors écran avec valeurs fictives; elles ne qualifient pas les parcours interactifs ni l'accès au domaine.
- Note KBZA reçue et poussée : `domenia-vm-recovery-20261016-0943`, commit mémoire `c6bb569fdfa877045a80a013eb0f33f79e2096f1` (distinct du dépôt Domenia).
