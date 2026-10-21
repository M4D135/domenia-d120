# Tests à faire à la main sous Windows — RC1.17.39

Liste tirée de `dev/engineering/d120/programme-2026-10-20/Suivi_60.json` (21 octobre 2026). Pour chaque point : ce qui a déjà été vérifié sous Windows PowerShell 5.1, puis ce qu'il reste à voir. Les suites citées sont dans `dev/wad/tests/` (lancement : `powershell -NoProfile -STA -ExecutionPolicy Bypass -File dev\wad\tests\<Suite>.ps1`).

## 1. Jamais exécutés sous Windows (17)

- **4. Priorité à la sélection**
  - Déjà vu : Aucun reçu ciblé de latence sous saturation dans cette passe.
  - À vérifier : La sélection reste derrière les écritures et certaines demandes explicites.
- **10. Mesures réseau/local/traitement/rendu**
  - Déjà vu : Aucun reçu de mesure bout en bout dans cette passe.
  - À vérifier : Séparation complète des temps, dont rendu, et coût d’instrumentation à mesurer.
- **11. Vues lourdes chargées à la demande**
  - Déjà vu : Aucun parcours ciblé de toutes les vues lourdes exécuté.
  - À vérifier : Raccordement relu ; couverture de toutes les vues non démontrée.
- **16. Minuteries sobres au repos**
  - Déjà vu : Aucune mesure CPU/réveils au repos dans cette passe.
  - À vérifier : La cadence Live active n’est pas une mesure de repos.
- **17. Stabilité mémoire et tâches en navigation**
  - Déjà vu : Aucun test d’endurance de navigation exécuté.
  - À vérifier : Mémoire, handles et tâches résiduelles restent non qualifiés (point 59).
- **21. Parallélisme adapté et borné**
  - Déjà vu : Cas Collection/ParkDetection écrits mais absents des reçus de cette passe.
  - À vérifier : Parallélisme 1–8 borné par opérateur/moteur ; pas de preuve en charge multi-source.
- **24. Fraîcheur sélective et forçage prioritaire**
  - Déjà vu : Nouveau P60-24 Park écrit, pas de reçu d’exécution.
  - À vérifier : Forçage relit volontairement ; dates de source jamais remplacées par date du clic.
- **26. Pause arrêt reprise sans perte**
  - Déjà vu : ParkDetection et CollectionWiring non exécutés dans cette passe.
  - À vérifier : Aucune preuve de pause/arrêt/reprise durable produite par le seul lot WMI réel.
- **29. Étude lecture AD incrémentale**
  - Déjà vu : Cas Cache/DirectorySync dont P60-29 écrits, pas de reçu dans cette passe.
  - À vérifier : Aucun nouveau DirSync ; AD réel du scénario WMI ne qualifie pas une synchronisation incrémentale ni son débit.
- **31. Classement exact préfixe approximatif**
  - Déjà vu : Navigation Programme 31 et règles Search sans reçu de cette passe.
  - À vérifier : Classement des résultats obtenus ; pas de correction orthographique ou recherche floue supplémentaire.
- **33. Recherches récentes et favorites**
  - Déjà vu : Navigation P54/P57 et règles récents sans reçu.
  - À vérifier : Ouvrir un favori ou une vue ne lance pas de collecte.
- **35. Cohérence boutons menus raccourcis**
  - Déjà vu : Boards clavier/représentation/presets non exécuté.
  - À vérifier : Cohérence de l’ensemble des gestes WPF non qualifiée.
- **37. Local actualiser modifier distincts**
  - Déjà vu : Boards Programme 47 sans reçu.
  - À vérifier : Pas de recette utilisateur des libellés et du clic sur le candidat.
- **39. Dernière vue pendant recalcul**
  - Déjà vu : Cas Boards accueil non recalculable et dashboard masqué sans reçu.
  - À vérifier : Pas de validation du dashboard pendant calcul dans cette passe.
- **42. Dispositions support inventaire santé**
  - Déjà vu : Boards Programme 41/42 écrit (idempotence/undo), sans reçu.
  - À vérifier : Aucune collecte et aucun changement du périmètre de données.
- **43. Comparaison OU et état précédent**
  - Déjà vu : HealthRules comparaisons et BoardFleet BF-019 sans reçu.
  - À vérifier : Comparaison limitée aux données réellement historiques et mêmes critères ; pas de stockage parallèle.
- **44. Évolution appuyée sur historique**
  - Déjà vu : BF-019 enrichi écrit, non exécuté.
  - À vérifier : Jours manquants restent absents ; aucune fausse histoire ni preuve de UI produite.

## 2. Hors du périmètre de la passe critique (1)

- **59. Échelle endurance réseau DPI accessibilité**
  - Déjà vu : Aucune campagne échelle/endurance/réseau/DPI/accessibilité de cette passe.
  - À vérifier : Les cas synthétiques 5 000 objets et quelques pannes injectées ne constituent pas cette qualification.

## 3. Réussis en partie : compléter (38)

- **1. Fiche mémoire immédiate puis AD**
  - Déjà vu : LocalPreview 19/19 : aperçu objet local, identité/epoch et visite expirée.
  - À vérifier : Pas de mesure du délai cache vers AD sur toute la navigation.
- **2. Aperçu SQLite avant réseau**
  - Déjà vu : LocalPreview 19/19 sur SQLite natif ; préfixes littéraux, portée et callbacks obsolètes.
  - À vérifier : Les recherches complexes ne reçoivent pas de substitut local élargi.
- **3. Conserver données connues sur échec**
  - Déjà vu : 19/19 LocalPreview et 16/16 LiveSearchView ; conservation sur échec AD/SQL et rejet du cache après succès final.
  - À vérifier : LiveSearchView utilise le vrai Dispatcher avec données synthétiques ; pas de panne réseau réelle dans cette suite.
- **5. Annuler recherches remplacées**
  - Déjà vu : LocalPreview : ancien callback interdit dans la nouvelle recherche.
  - À vérifier : Le rejet d’un résultat périmé ne prouve pas l’arrêt instantané d’une API native.
- **6. Actualiser les champs modifiés**
  - Déjà vu : R2 LocalPreview 21/21 : inclut les deux cas Programme 6, delta limité et vrai callback, générations/panneau/lecture explicite, réévaluation droits, Fill/Clear, dates/secrets. SQLite native et projections synthétiques ; les reçus antérieurs sont conservés.
  - À vérifier : Changements de sécurité, identité, membres, manager ou forme inconnue reprennent volontairement le remplissage complet. Résumés dépendant du temps et protections restent actualisés. Les 21 cas LocalPreview réussis sont des scénarios locaux ciblés, sans qualification générale de navigation ni gain de latence établi.
- **7. Grandes listes progressives rapides**
  - Déjà vu : 16/16 ; arrivées sur plusieurs ticks, 5 000 machines filtrables et continuation conservant les lignes.
  - À vérifier : Données synthétiques ; gain de latence chiffré non qualifié et coût de l’arbre traité séparément au point 8.
- **8. Virtualisation des grilles et arbres**
  - Déjà vu : D023 reçu pour les grilles. R2 : compilation, TreeRendering 4/4 (vrais types, pas de qualification du rendu WPF), Navigation Programme 8 5/5 (contrôles WPF, dépendances doublées). R4 : TreeVirtualization 8/8, révélation lointaine, recyclage/favori, groupe, filtre, feuille non lue et annulation epoch ; compteurs de lecture restent nuls sur les chemins programmés. Les trois échecs de révélation R2/R3 restent conservés ; trigger du thème/panneau enfant corrigé. WiringRecherche R4, lancé sans filtre : 47/53, dont les dix cas précédemment ciblés réussis ; les six échecs ont ensuite passé leurs retests (cinq en R5, D028 en R6). Bilan cumulé : 47 R4 + 5 R5 + 1 R6 ; les 53 cas ne sont pas rejoués ensemble.
  - À vérifier : R4 TreeVirtualization 8/8 sous WPF réel sur 10 000 DTO synthétiques ; 40 conteneurs au premier relevé, maximum 61 sur neuf cibles. SyntheticOnly=true : aucun AD/réseau réel ni benchmark de mémoire du processus. Navigation Programme 8 5/5 est un sous-ensemble (Complete=false). ; La virtualisation limite les conteneurs visuels réalisés, pas la mémoire des données déjà lues : les DTO, métadonnées et lignes chargées restent conservés. Aucun benchmark de mémoire du processus ou qualification AD à grande échelle n’est revendiqué. ; Le quota commun et la tranche coopérative de 8 ms ne sont pas une garantie temps réel ; une opération WPF native ne peut pas être préemptée.
- **9. Index SQLite adaptés aux recherches**
  - Déjà vu : StorageMaintenance : index composite présent et plans de lectures exposés.
  - À vérifier : Ne qualifie pas les plans/coûts de toutes les recherches sur volume représentatif.
- **12. Accueil utilisable avant travaux secondaires**
  - Déjà vu : StartupIntegrity réussi ; StartupLogin 48/48 sans AD ni données de production.
  - À vérifier : Pas de mesure de temps avant première interaction ni de l’ensemble des travaux différés.
- **13. Réutiliser les vues déjà ouvertes**
  - Déjà vu : LocalPreview : présentation conservée seulement à identité et lecteur identiques.
  - À vérifier : Réutilisation des cartes non exécutée par Boards dans cette passe ; pas un cache de toutes les vues.
- **14. Conserver sélection défilement filtres**
  - Déjà vu : LiveSearchView : rafraîchissement conserve sélection GUID ; continuation conserve lignes/filtres. R2 Navigation Programme 8 5/5 : sous-ensemble Complete=false, vrais contrôles WPF mais annuaire/postes/base/fenêtres doublés ; pas une preuve du défilement final hors écran.
  - À vérifier : Navigation rapide, défilement et arbre avec données modifiées non qualifiés ici.
- **15. Pas de recalcul des pages masquées**
  - Déjà vu : LiveSearchView : grille désactivée reporte ApplySearch/ClearSearch au prochain vrai tick.
  - À vérifier : Le test ne couvre pas toutes les pages masquées ni tous les recalculs.
- **18. Timeout poste poursuit et clôt le lot**
  - Déjà vu : AD/WMI/SQLite réels sans mocks : premier endpoint timeout moteur ramené de 25 à 2 s, DC01 suivant Success SQL ; lot 2/2, 1 échec, aucun reçu en attente.
  - À vérifier : Scénario contrôlé de 2 cibles, pas qualification de tous les délais natifs ni des reprises.
- **19. Mutualiser lectures inter-widget**
  - Déjà vu : RemoteStore 34/34 : 3 consommateurs, contrôle identité et appel fournisseur partagés, appels évités comptés.
  - À vérifier : Groupes même poste/namespace/classe/filtre ; dépendances réseau simulées dans ce banc.
- **20. Réutiliser les sessions de relevé**
  - Déjà vu : RemoteStore : session unique et libération même sur refus/échec.
  - À vérifier : Aucun cache de session global ni preuve de durée sur réseau dégradé étendu.
- **22. Délais par sonde et plafond poste**
  - Déjà vu : RemoteStore : groupes 10/15/20/1 s ; WMI réel : expiration de la première cible puis poursuite.
  - À vérifier : Le test réel raccourcit seulement le premier idle timeout ; il ne mesure pas chaque fournisseur lent.
- **23. Sondes rapides avant coûteuses explicites**
  - Déjà vu : Groupe mixte et son délai maximal couverts par RemoteStore.
  - À vérifier : Nouveau test d’ordre/exclusion P60-23 Park non exécuté ; pas de scan implicite.
- **25. Relancer uniquement les échecs**
  - Déjà vu : WMI réel confirme clôture malgré un échec et stockage séparé Error/Success.
  - À vérifier : La relance des seuls échecs n’a pas été exécutée dans ce scénario ; P60-25 ParkDetection reste sans reçu.
- **27. Panne poste distincte des identifiants**
  - Déjà vu : RemoteStore : refus auth arrête les appels CIM ; mauvaise identité refusée avant écriture.
  - À vérifier : Scénarios de banc ; pas de changement de compte réel ni de panne globale en laboratoire.
- **28. Progression globale et motifs**
  - Déjà vu : RemoteStore : chaque requête/étape alimente le progrès ; WMI réel termine 2/2 avec files et reçus vides.
  - À vérifier : Nouveau texte P60-28 ParkDetection non exécuté ; pas de pourcentage déduit du temps.
- **30. Cas limites Premiers pas**
  - Déjà vu : Boards Programme 30 écrit, non exécuté dans cette passe. UI critique réelle : parcours OU/index AD puis ouverture fiche/poste/santé réussi ; ne couvre pas tous les nouveaux cas.
  - À vérifier : Aucune lecture déclenchée par l’affichage.
- **32. Expliquer résultats absents**
  - Déjà vu : LiveSearchView UX-03 réussi : filtre masquant toutes les lignes expliqué et effaçable sans requête.
  - À vérifier : Nouveaux cas Navigation Programme 32 et UxQualification non exécutés ; aucune absence globale inférée.
- **34. Accès fiche poste relations diagnostic**
  - Déjà vu : Nouveau clic Boards Programme 47 écrit mais non exécuté. UI critique réelle : parcours OU/index AD puis ouverture fiche/poste/santé réussi ; ne couvre pas tous les nouveaux cas.
  - À vérifier : Une navigation ne lance aucune collecte.
- **36. Avertissements discrets regroupés**
  - Déjà vu : HealthRules 23/23 dont Programme 46 et cas couverture/score.
  - À vérifier : WpfExecuted=false ; aucune recette visuelle du regroupement.
- **38. Recalcul des widgets affectés**
  - Déjà vu : R2 Boards Programme 38 4/4 : plans, compteurs de constructions WPF, changements isolés/date/largeur/palette/contexte et fournisseur logiciel avant agrégation. Sélection complète, suite complète non exécutée (Complete=false). QueryTargets 39/39 : vrais records/DLL, dépendances AD/lifecycle/observations projetées localement, qualité/dates/identité et fallback des filtres de sonde cachés.
  - À vérifier : Fallback de sûreté : collecte/calcul en attente, Action, forme opaque/cyclique/trop grande, pause, sonde DaysSince, champs de requête probe/instance/detail et sélection de sonde contournent le cache. Le calcul complet et les demandes nécessaires restent exécutés ; les cartes spécialisées sont reconstruites. ; Le record canonique du poste est reprojeté pour vérifier les valeurs temporelles et la fraîcheur ; seules les dépendances évaluées invalident le plan. Le fournisseur Computer conserve sa réévaluation conservatrice sans contrat global de révision/horloge. Le fournisseur Fleet utilise son résultat déjà publié. Aucune promesse d’incrémental champ par champ pour ces fournisseurs ; aucun gain mesuré. ; R2 : Boards Programme 38 4/4, SelectionComplete=true mais Complete=false (filtre, pas les 73 cas) ; QueryTargets 39/39. Données locales/synthétiques et contrôles WPF ciblés, sans AD/réseau ni gain global chiffré.
- **40. Raisons des widgets vides**
  - Déjà vu : HealthRules Programme 46 réussi pour données santé manquantes.
  - À vérifier : Boards widgets/BF-019 non exécutés ; toutes raisons visuelles non couvertes.
- **41. Persistance tailles et ordre**
  - Déjà vu : StoragePreferences : layouts et choix requêtes survivent snapshot/restauration, rollback réussi sur échec.
  - À vérifier : Ne couvre pas le drag/resize WPF ni le nouveau cas Boards Programme 41/42.
- **45. Alertes santé explicables**
  - Déjà vu : HealthRules Programme 45 réussi ; seuil/source/date et cibles exactes. UI critique réelle : parcours OU/index AD puis ouverture fiche/poste/santé réussi ; ne couvre pas tous les nouveaux cas.
  - À vérifier : Modèle sans WPF ; date de calcul ne remplace jamais une collecte.
- **46. Sain problème inconnu distincts**
  - Déjà vu : HealthRules Programme 45/46/48 et couverture : 23/23 au total. UI critique réelle : parcours OU/index AD puis ouverture fiche/poste/santé réussi ; ne couvre pas tous les nouveaux cas.
  - À vérifier : WpfExecuted=false ; colonne et gestes UI non exécutés.
- **47. Collecter les données manquantes**
  - Déjà vu : HealthRules Programme 46 confirme la donnée manquante et la cible explicite. UI critique réelle : parcours OU/index AD puis ouverture fiche/poste/santé réussi ; ne couvre pas tous les nouveaux cas.
  - À vérifier : Vrai clic WPF et compte StartCalls/ParkCalls du cas Boards Programme 47 non exécutés.
- **48. Exceptions motivées et bornées**
  - Déjà vu : HealthRules Programme 48 : exception motivée datée masque sans effacer la preuve.
  - À vérifier : Éditeur WPF et ensemble des cas d’expiration/héritage des règles non exécutés ici.
- **49. Rotations et échéances sauvegardes**
  - Déjà vu : Maintenance 33/33 : échéancier borné et archive migration conservée après rotation ; préférences 9/9.
  - À vérifier : Échéances/rotation longue période et volumes représentatifs non qualifiés ; aucun banc BackupQualification supplémentaire produit.
- **50. Restauration données et réglages**
  - Déjà vu : Restauration données/requêtes/snapshot complet, hash/profondeur/annexe altérée refusés ; layouts/choix et rollback disque réussis.
  - À vérifier : Retour UI et redémarrage après restauration complète/ancienne copie non qualifiés. ; Le StoreId est lié au chemin complet et au domaine : copier manuellement un profil vers un autre chemin ne migre pas son identité. Utiliser Déplacer/Restaurer ; le premier contrôle visuel sur profil déplacé a été refusé ; VisualCompact réussit ensuite au chemin original conservé, sans modification de cette protection.
- **51. Disque plein destination inaccessible verrou**
  - Déjà vu : StorageFaults 8/8, 42 assertions : verrous réels, SQLITE_FULL via max_page_count et Process.Kill.
  - À vérifier : Rapport Qualifying=false : aucun volume physiquement plein ; destination inaccessible et publication seconde copie à qualifier.
- **52. Coût des écritures et rétention**
  - Déjà vu : Maintenance : zéro candidat sans backup/révision et compaction d’un grand parc réussis.
  - À vérifier : Pas de métriques d’écriture/endurance sur domaine représentatif.
- **53. Retour arrière après migration**
  - Déjà vu : Maintenance : schéma/données et archive de migration conservés ; Faults : migration interrompue puis reprise.
  - À vérifier : Ne qualifie pas tout le coordinateur de migration ni une exécution avec un ancien runtime.
- **54. Diagnostic expurgé**
  - Déjà vu : R1 DiagnosticExport 4/4, 12 assertions : fichier JSON exporté identique à l’aperçu expurgé, refus, annulation et destination verrouillée sans document partiel. Règles Observability 17/17 ; rapports historiques conservés.
  - À vérifier : Export local ciblé sans réseau ni préférences de production ; ne qualifie pas tous les incidents de disque ni une session de production.
- **55. Découpage progressif du cœur**
  - Déjà vu : R1 AssociationRows 5/5 : identité/ordre des lignes, enrichissement utilisateur, erreur facultative, GUID machine et meilleur lien. Le reçu statique initial reste non qualifiant Windows ; le reçu R1 atteste les cinq exécutions.
  - À vérifier : Extraction ciblée, pas découpage complet du cœur ; banc local, sans parcours AD réel.

## 4. Cas ciblés réussis : élargir si besoin (3)

- **56. Bancs cohérents sans assertions affaiblies**
  - Déjà vu : R1 acquis conservés. R2 : LocalPreview 21/21, QueryTargets 39/39, Boards Programme 38 4/4 (SelectionComplete=true, Complete=false), TreeRendering 4/4, Navigation Programme 8 5/5 (Complete=false), règles Park 14/14. R4 : TreeVirtualization 8/8 WPF réel/synthétique après trois échecs de révélation R2/R3 ; WiringRecherche R4 sans filtre : 47/53, les dix cas ciblés antérieurement passent ; les six échecs passent ensuite : cinq en R5, D028 en R6. Bilan cumulé 47 + 5 + 1 ; suite complète non rejouée.
  - À vérifier : Contrôles critiques seulement. WiringRecherche : 47 succès R4, cinq retests réussis R5 et D028 réussi R6 ; aucun échec connu restant dans ces cas, sans réexécution intégrale des 53 cas. Rapports historiques en échec conservés.
- **57. Recette courte représentative**
  - Déjà vu : R1 acquis conservés. R2 : LocalPreview 21/21, QueryTargets 39/39, Boards Programme 38 4/4 (SelectionComplete=true, Complete=false), TreeRendering 4/4, Navigation Programme 8 5/5 (Complete=false), règles Park 14/14. R4 : TreeVirtualization 8/8 WPF réel/synthétique après trois échecs de révélation R2/R3 ; WiringRecherche R4 sans filtre : 47/53, les dix cas ciblés antérieurement passent ; les six échecs passent ensuite : cinq en R5, D028 en R6. Bilan cumulé 47 + 5 + 1 ; suite complète non rejouée.
  - À vérifier : Contrôles critiques seulement. WiringRecherche : 47 succès R4, cinq retests réussis R5 et D028 réussi R6 ; aucun échec connu restant dans ces cas, sans réexécution intégrale des 53 cas. Rapports historiques en échec conservés.
- **58. Preuves liées au pack et parité DEV PROD**
  - Déjà vu : PROD SHA256 27244218D38B6924F7F0F5BD246C613458C328CE3472DE963FD6E75651B7B7A9 ; ZIP/manifeste/guard PASS. FinalCompactIntegrity exit 0. VisualCompact : état vide défilable, action visible, dashboard peuplé, aucun nouvel ERROR ; Core inchangé par le dernier correctif Main.xaml. Compact montre encore le chargement de l’arbre ; VisualRetest précédent montre 11 branches déclarées et sept éléments UIA avec le même runtime d’arbre.
  - À vérifier : Qualification critique ciblée seulement. Le reçu du générateur reste WindowsQualification NOT_EVALUATED et Publishable=false ; aucune qualification générale ni publication acquise par ce seul reçu. Dernière reconstruction DEV documentaire doit préserver les 176 fichiers runtime et le PROD exact.

## 5. Documentation vérifiée (1)

- **60. Suivi courant et guides cohérents**
  - Déjà vu : guide-qa-sync passed=true : tous feuillets en planches et pages modifiées agrandies ; doc_sync PASS.
  - À vérifier : Pas d’exécution native Word ; captures RC20 conservées et explicitement historiques, pas preuve visuelle runtime RC39.


## 6. Lots R40 du 21 octobre : jamais exécutés sous Windows (4)

Écrits et contrôlés hors Windows (contrôles Python du dépôt). Aucun test PowerShell 5.1 n’a été lancé.

- **R40-startup. Démarrage plus rapide**
  - À vérifier :
    - temps jusqu’à la fenêtre et jusqu’à l’Accueil, mesurés dans `Domenia-startup.log` ;
    - l’arbre et la base locale se chargent après l’affichage ;
    - l’application rouvre sur la dernière vue (Accueil par défaut) ;
    - suite `Test-DomeniaRules.ps1` sans régression par rapport à la ligne de base.
- **R40-ipmac. Recherche par adresse IP ou MAC**
  - À vérifier :
    - une IP, une MAC (formats `aa:bb…`, `aa-bb…` et `aabb…`) ou un préfixe trouve le poste dans la base locale (`AddressSearch`) ;
    - la résolution DNS inverse (`DnsReverseLookup`, nouvelle opération épinglée) ne part qu’au geste de l’opérateur.
- **R40-userdiff. Comparer les groupes de deux utilisateurs**
  - À vérifier :
    - groupes communs, groupes propres à chacun et groupes hérités via `GroupPathRead` ;
    - deux comptes identiques, puis un compte sans groupe.
- **R40-callsheet. Fiche d’appel support**
  - Points d’entrée : bouton `BtnUserCallSheet` et menu contextuel d’un utilisateur dans Rechercher.
  - À vérifier :
    - aucune requête réseau à l’ouverture : seule la lecture locale `LocalIndexRead` part ;
    - plages `logonHours` décodées et message « hors des heures autorisées » ;
    - `userWorkstations` ;
    - verrouillages des 7 jours (4740) et échéance du mot de passe, au clic seulement ;
    - postes habituels et leurs trois actions ;
    - groupes privilégiés en tête ;
    - les 10 derniers reçus ;
    - « Trier la lenteur du poste » ;
    - « Copier pour le ticket » : secrets masqués, et modèle `CallSheet.TicketTemplate`.
  - Suites : `tests/rules/CallSheet.Tests.ps1` (23 cas) et `tests/Test-DomeniaCallSheet.ps1` (8 cas).
