# Domenia propositions d’amélioration

État du travail et propositions au 13 octobre 2026. Objectif : un outil Windows fiable, explicable et confortable pour un parc d’au moins 10 000 postes, avec une base locale et des collectes maîtrisées sur réseau lent.

**160 pistes**, regroupées en quinze thèmes, huit compléments du moteur de requêtes et deux compléments de collecte. Elles mêlent qualification des changements en cours, renforcement de fonctions existantes et extensions à étudier. David a autorisé leur mise en œuvre complète le 13 octobre 2026. Les points restent à suivre avec leurs preuves de validation : cette liste ne signifie pas qu’ils sont déjà réalisés ou publiés.

Les priorités sont :

- **P0** : exactitude, compte administrateur, intégrité, complétude et qualification de livraison.
- **P1** : gain quotidien pour l’utilisateur et réduction du trafic.
- **P2** : extensions avancées après mesure de leur utilité et de leur coût.

La cible a été portée par David à **10 000 postes minimum**, avec une qualification recommandée à **20 000 postes**. Les mesures antérieures sur 5 000 postes ne valident pas ce nouveau seuil. Les 10 000 objets doivent rester consultables et exportables en totalité, même lorsque l’interface ne charge qu’une page.

## État de départ

Le travail courant contient notamment le circuit collecte → SQLite → relecture → GUI, les trois actualisations AD/Ping/WMI, les états inconnus distincts, une protection d’authentification partagée, un coffre Windows facultatif, des règles de santé configurables, un atelier en trois étapes et 515 modèles. Plusieurs lots restent à raccorder et à qualifier sous Windows ; ils ne sont pas encore le paquet publié.

La pagination, le zoom, les sondes groupées, les caches par sonde, une revalidation AD différentielle et le moteur de requêtes commun existent déjà. Les points correspondants ci-dessous sont des renforcements.

### Limites directement constatées

- **Export Atelier** : le code exporte la page affichée, dont la navigation avance par 200 lignes. Ajouter un export complet reste nécessaire. Source : [Query.UI](../../../wad/modules/Domenia-Query.UI.ps1).
- **Détails des sondes** : le collecteur compte le flux complet mais garde vingt éléments de détail. Source : [Live.Model](../../../wad/modules/Domenia-Live.Model.ps1).
- **Requêtes personnelles** : import limité à 100 recettes et à 1 Mio de JSON. Source : [Query.Model](../../../wad/modules/Domenia-Query.Model.ps1).
- **Agrégations volumineuses** : `CountBy` refuse plus de 10 000 catégories distinctes. Le seuil concerne les regroupements, pas une limite universelle de la base ; la recherche locale sait déjà demander deux pages pour atteindre 20 000 lignes. Sources : [moteur commun](../../../vendor/m4d-admin-common/src/Query/QueryEngine.cs), [worker de requêtes](../../../wad/modules/Domenia-Query.Worker.ps1).
- **Première préparation du catalogue** : environ 248 ms pour les modèles et 214 ms pour leurs plans sur le Mac de travail. Ce résultat de 462 ms ne mesure pas le rendu WPF sous Windows.
- **Projection de présence dans les requêtes** : un chemin de `Query.Model` utilise encore la date générale `CheckedUtc` et classe une erreur comme « Sans réponse ». Il doit rejoindre la date `PresenceCheckedUtc` et le traitement « Non vérifié » du dashboard avant livraison. Source : [Query.Model](../../../wad/modules/Domenia-Query.Model.ps1).

## Comparaison des approches

### Vérification complémentaire pour 10 000 postes minimum

Ces constats viennent d’une lecture du code. Les coûts en durée et en mémoire restent à mesurer sous Windows.

| Constat | Amélioration à appliquer |
|---|---|
| Recherche réglable jusqu’à 20 000 objets ; « Charger la suite » relit depuis le début avec une limite doublée. | Prévoir une continuation réelle et séparer taille de page, population totale et budget de collecte. [Recherche](../../../wad/modules/Domenia-Search.Model.ps1) |
| Une lecture qui atteint exactement sa limite est marquée limitée sans vérifier l’existence d’un résultat suivant. | Qualifier les frontières 9 999 / 10 000 / 10 001 et 19 999 / 20 000 / 20 001 ; annoncer correctement la complétude. [Core](../../../wad/Domenia-Core.ps1) |
| Certaines sélections et collectes plafonnent à 20 000 cibles. | Conserver des lots et budgets bornés, avec continuation explicite ; ne pas traiter le plafond comme une capacité infinie. [Worker](../../../wad/modules/Domenia-Engine.Worker.ps1) |
| Les graphiques en barres conservent seulement les premières catégories selon la place disponible. | Annoncer les catégories non visibles, proposer « Autres » et ouvrir l’ensemble des détails. [Graphiques](../../../wad/modules/Domenia-Charts.UI.ps1) |
| L’import des associations examine les mille premières lignes et applique au plus 64 associations par import. | Remplacer les réimports manuels par un traitement paginé de tout le fichier, avec progression, rejets et reprise. [Import](../../../wad/modules/Domenia-Relations.UI.ps1), [règles](../../../wad/modules/Domenia-Relations.Model.ps1) |
| L’admission d’un lot sérialise chaque changement, le désérialise, puis sérialise et hache l’enveloppe sur le fil appelant. | Mesurer la durée et les allocations, préparer les données hors du fil UI lorsque nécessaire, garder les objets détachés et l’idempotence. [Store](../../../wad/modules/Domenia-Store.Model.ps1), [admission](../../../wad/modules/Domenia-Storage.UI.ps1) |
| Un changement de présence peut reconstruire une projection contenant aussi des observations WMI. | Limiter les lectures et réécritures aux familles touchées, tout en conservant la validation puis la relecture canonique. [Writer](../../../wad/modules/Domenia-Storage.Worker.ps1) |
| Chaque page StoreRead recalcule un total et utilise OFFSET ; le filtre de famille est également appliqué après une lecture plus large. | Examiner les plans SQL ; sélectionner les familles utiles dès SQL et utiliser une continuation par clé liée à une révision stable quand elle convient. [StoreRead](../../../wad/modules/Domenia-Engine.Worker.ps1) |
| Le dashboard matérialise encore des populations et des graphes d’observations complets malgré la virtualisation des contrôles. | Mesurer mémoire maximale et allocations avec de gros inventaires ; charger les détails à leur ouverture et calculer les agrégats sans copier tout le parc à chaque vue. [Lecteur natif](../../../native/ObservationReader.cs), [FleetStats](../../../wad/modules/Domenia-Engine.Worker.ps1) |

La file de stockage est déjà bornée à 4 096 changements ou 32 Mio, et les lots à 250 changements ou 4 Mio. Ces limites régulent le flux ; elles ne plafonnent pas le parc. La qualification doit vérifier la mise en attente et la reprise lorsque la file est pleine, sans perte ni gonflement incontrôlé de la mémoire.

### Projets consultés

| Projet ou documentation | Principe intéressant pour Domenia |
|---|---|
| [PDQ Inventory](https://www.pdq.com/blog/advanced-collections-and-filtering-in-pdq-inventory/) | Collections dynamiques et bibliothèque de filtres réutilisables. |
| [Lansweeper](https://docs.lansweeper.com/classic/docs/manage-scanned-item-intervals) | Fréquences différentes selon l’information ; une collecte n’a pas besoin de tout relire. |
| [osquery sur GitHub](https://github.com/osquery/osquery/blob/master/docs/wiki/deployment/configuration.md) | Recettes organisées en packs, résultats différentiels, instantanés et budgets d’exécution. |
| [Fleet](https://fleetdm.com/releases/fleet-4-5-0) | Compatibilité et coût des requêtes visibles dans l’interface. Cette publication décrit des principes, pas la version actuelle comparée. |
| [Velociraptor](https://docs.velociraptor.app/docs/artifacts/) | Collectes documentées, paramétrées, réutilisables et munies de préconditions. |
| [AD Explorer](https://learn.microsoft.com/en-us/sysinternals/downloads/adexplorer) | Consultation hors ligne et comparaison de relevés d’annuaire. |
| [Apache Directory Studio](https://directory.apache.org/studio/) | Navigation LDAP et outils de consultation du schéma. |
| [GLPI Agent sur GitHub](https://github.com/glpi-project/glpi-agent) | Inventaire structuré pouvant inspirer des adaptateurs d’échange explicites. |
| [PDQ PowerShell Scanners sur GitHub](https://github.com/pdqcom/PowerShell-Scanners) | Recettes spécialisées, descriptions et indications de compatibilité. |
| [WMI Explorer sur GitHub](https://github.com/vinaypamnani/wmie) | Exploration des classes, propriétés et associations réellement exposées, éditeur WQL et génération de scripts. |
| [Apple HIG](https://developer.apple.com/design/human-interface-guidelines/search-fields) | Recherche située près du contenu, portée lisible et filtres faciles à manipuler. |

La recherche sur X n’a pas fourni de publications exploitables ; l’accès direct testé à Fleet a renvoyé un refus. Aucun témoignage X n’est utilisé comme preuve. Le [retour d’ingénierie de X sur les contraintes d’opérations](https://blog.x.com/engineering/en_us/topics/infrastructure/2023/constraint-management-for-cluster-operation-safety-and-reliability-at-twitter) donne en revanche un exemple primaire de limites par cible et par groupe.

## Ordre conseillé

1. Terminer et qualifier le lot en cours : base, authentification, dates, populations, santé et navigation par favori.
2. Corriger les limites de complétude : export total, détails au-delà de vingt éléments, bibliothèque personnelle paginée.
3. Ajouter les explications : pourquoi un poste correspond, couverture d’une requête, preuve d’un compteur ou d’une alerte.
4. Optimiser la collecte : mesures manquantes seulement, mutualisation entre vues, priorités et concurrence adaptée.
5. Développer les profils par OU, les comparaisons temporelles et les nouveaux catalogues de sondes.
6. Qualifier et documenter chaque pack avant publication.

### Découpage recommandé pour les évolutions suivantes

| Lot | Résultat concret attendu | Exemples de points |
|---|---|---|
| Exactitude et protection des données | Un chiffre explicable, des dates correctes, aucun résultat perdu ou remplacé par une erreur ; contrôle des comptes. | 1–10, 21–24, 35–36, 41–49, 128 |
| Usage quotidien | Navigation par favori, listes complètes, interface allégée, ouverture rapide de l’atelier. | 51–61, 68, 111–120 |
| Collecte efficace | Requêtes regroupées, champs manquants seulement, charge maîtrisée, campagne reprenable. | 11–20, 63–64, 122–127 |
| Atelier et tableaux de bord | Recettes explicables, conditions avancées, politiques par OU et comparaisons. | 62, 65–70, 75–79, 151–158 |
| Catalogue et produit | Nouvelles familles de sondes qualifiées, contrats communs, packs et documentation cohérents. | 81–110, 131–150 |

Ce découpage est une recommandation de livraison progressive. Les points de qualification et de protection des données s’appliquent à chaque lot ; ils ne sont pas reportés à une phase finale. Il ne donne pas de délais avant mesure du travail d’intégration restant.

### Parcours utilisateur cible

Dans l’OU choisie, trois commandes lisibles : **Actualiser les objets AD**, **Tester la présence réseau**, **Actualiser l’inventaire**. Chacune collecte, enregistre puis publie les données relues dans la base. **Recalculer la vue** utilise seulement ce qui est enregistré et ne modifie aucune date de collecte. Le menu de maintenance de la base sert à la sauvegarde, la restauration et la conservation, pas à obliger l’utilisateur à enregistrer manuellement une recherche.

Avant une collecte longue, afficher ce qui est déjà connu, ce qui manque, combien de postes sont concernés et pourquoi les informations seront relues. Pendant la collecte, indiquer les données réellement enregistrées, les cibles restantes et les erreurs. Un clic sur un chiffre ouvre la population exacte, avec ses filtres et sa date.


## Exactitude et cohérence des données

Priorité : **P0**.

1. **Achever le circuit collecte vers base vers interface** — *En cours*. Vérifier chaque chemin AD, ping, WMI et détail ; l’interface publie les données relues après validation SQLite.
2. **Unifier les populations comparées** — *Renforcement*. Même domaine, OU, profondeur, types, critères et instantané pour les résultats, compteurs, widgets et exports.
3. **Séparer les états inconnus** — *En cours*. Différencier absent, non lu, refusé, périmé, incomplet et erreur ; aucun de ces états ne devient implicitement zéro ou sain.
4. **Garder trois horloges de collecte** — *En cours*. AD, ping et WMI ont leurs dates ; recalculer une vue ne rajeunit aucune observation.
5. **Conserver la dernière réussite** — *En cours*. Afficher aussi la dernière tentative et son erreur, sans effacer une bonne mesure par un échec.
6. **Expliquer chaque chiffre** — *Extension*. Un panneau donne formule, périmètre, critères, exclusions, couverture, date et postes qui composent le total.
7. **Rendre les détails des sondes complets** — *Limite vérifiée*. Remplacer l’échantillon de vingt lignes par des détails paginés ou un stockage borné explicitement ; le compte total reste distinct.
8. **Exporter tous les résultats** — *Limite vérifiée*. Proposer page, sélection ou totalité ; parcourir un instantané stable, avec les filtres et dates dans l’export.
9. **Préserver l’identité lors des changements** — *Renforcement*. GUID AD et domaine restent la référence après renommage ou déplacement ; un nom recyclé ne récupère pas l’ancien historique.
10. **Qualifier la fraîcheur des sources** — *Extension*. Conserver contrôleur, fournisseur, heure observée, heure enregistrée et version de collecte ; signaler les dates incohérentes.

## Collecte adaptée aux réseaux lents

Priorité : **P0 puis P1**.

11. **Configurer les durées de fraîcheur par profil** — *Renforcement*. Des TTL différenciés existent déjà ; ajouter des réglages compréhensibles par famille de données et profil d’usage.
12. **Mutualiser les demandes simultanées** — *Extension*. Une même lecture demandée par plusieurs vues est exécutée une fois si cible, compte, contexte et exigences correspondent.
13. **Étendre le regroupement WMI déjà présent** — *Renforcement*. Réutiliser session et classe compatibles, réunir les propriétés nécessaires et mesurer le nombre de requêtes évitées.
14. **Adapter la concurrence à la latence** — *Extension*. Ralentir quand erreurs ou latences montent, puis augmenter progressivement dans les limites choisies.
15. **Limiter la charge par site et fournisseur** — *Extension*. Budgets distincts pour contrôleur AD, sous-réseau et fournisseur WMI afin qu’un site lent ne bloque pas les autres.
16. **Qualifier la priorité du travail visible** — *Renforcement*. La priorité explicite existe ; mesurer son effet sous charge et garantir qu’une longue campagne de fond progresse encore.
17. **Adapter les délais à la progression** — *Renforcement*. Distinguer absence de progrès et durée totale ; montrer les résultats validés et le temps d’attente réel.
18. **Classer les erreurs avant toute reprise** — *Renforcement*. Reprises bornées et espacées pour incidents transitoires ; aucune relance automatique après rejet d’identifiants.
19. **Mémoriser les capacités des postes** — *Extension*. Classe absente, protocole inaccessible ou droit refusé restent connus un temps limité, avec invalidation après changement pertinent.
20. **Enregistrer les campagnes pour reprise** — *Extension*. Pause, fermeture et incident laissent un plan durable ; reprendre les cibles restantes sans doublons ni renvoi d’écriture AD.

## Synchronisation Active Directory

Priorité : **P0 puis P1**.

21. **Fiabiliser le suivi différentiel existant** — *Renforcement*. Points de reprise par contrôleur et invocationID, validés avec les données ; aucune extrapolation d’un USN à un autre DC.
22. **Conserver un recensement complet de l’OU** — *Renforcement*. Réconcilier périodiquement le périmètre choisi pour détecter ce qu’une lecture différentielle seule peut manquer.
23. **Traiter les déplacements entre OU** — *Renforcement*. Corriger appartenance au périmètre et fil d’Ariane sans dédoubler l’objet ni perdre son identité.
24. **Distinguer disparition et suppression** — *Renforcement*. Une lecture partielle, un filtre ou une baisse de droits ne suffit pas pour conclure qu’un objet a été supprimé.
25. **Lire les grands groupes sans troncature** — *À étudier*. Prendre en charge les attributs multivalués renvoyés par plages et exposer toute lecture incomplète.
26. **Afficher le contrôleur effectivement interrogé** — *Extension*. Conserver l’affinité d’une opération ; tout basculement de DC est explicite et invalide les repères incompatibles.
27. **Expliquer les données de connexion AD** — *Renforcement*. Présenter l’activité approximative et, sur demande, les lectures de lastLogon par DC avec leur couverture.
28. **Parcourir le schéma en lecture seule** — *À étudier*. Types, descriptions, cardinalité et attributs disponibles aident à créer des requêtes sans modifier le schéma.
29. **Optimiser les filtres LDAP** — *Renforcement*. Limiter les attributs, vérifier les index pertinents et paginer ; éviter les recherches larges déclenchées par une saisie locale.
30. **Comparer deux relevés d’annuaire** — *Extension*. Voir ajouts, déplacements et valeurs modifiées, avec preuve de couverture ; un relevé n’est pas une sauvegarde restaurable de l’AD.

## Base locale et conservation

Priorité : **P0 puis P1**.

31. **Choisir l’emplacement local de la base** — *À étudier*. Afficher taille et espace disponible ; valider les accès avant changement et conserver un retour arrière.
32. **Déplacer la base avec un assistant** — *Extension*. Suspendre proprement les écritures, copier, vérifier et basculer les chemins ; garder l’original jusqu’à validation.
33. **Automatiser les sauvegardes cohérentes** — *Extension*. La sauvegarde manuelle avec rotation existe ; ajouter fréquence, déclenchement et dernier succès visibles, avec contrôle du fichier produit.
34. **Restaurer depuis l’interface** — *Extension*. Prévisualiser domaine, date et contenu ; tester la copie puis restaurer sans écraser l’unique exemplaire sain.
35. **Détecter l’espace disque insuffisant** — *Renforcement*. Suspendre les nouvelles collectes avant saturation et afficher ce qui reste non enregistré.
36. **Contrôler l’intégrité et les migrations** — *Renforcement*. Vérifications ciblées, migration transactionnelle, sauvegarde préalable et récupération en cas d’échec.
37. **Régler la rétention par famille** — *Extension*. Garder longtemps les changements utiles ; agréger les séries volumineuses et annoncer la perte de détail avant purge.
38. **Compacter les reçus sans casser la reprise** — *Extension*. Archiver le journal des lots tout en conservant la preuve nécessaire à l’idempotence des opérations.
39. **Accélérer les lectures SQL mesurées** — *Renforcement*. Index composites, requêtes préparées et filtrage SQL pour les cas compatibles, avec parité du moteur existant.
40. **Rendre les limites de stockage visibles** — *Renforcement*. Budget RAM, taille disque, files, rétention et collections volumineuses ; aucune promesse de stockage infini.

## Comptes et opérations sûres

Priorité : **P0**.

41. **Qualifier la protection contre les refus d’authentification** — *En cours*. Vérifier sérialisation, attribution au bon compte, arrêt des tentatives et maintien de la consultation locale.
42. **Simplifier les comptes secondaires** — *En cours*. Compte de connexion par défaut ; compte spécifique facultatif, usage visible et nom mémorisé.
43. **Qualifier le coffre Windows optionnel** — *En cours*. Consentement explicite, utilisation et oubli ciblés ; aucune donnée secrète dans SQLite, exports ou journaux.
44. **Corriger un compte sans reconnecter toute l’application** — *Renforcement / en cours*. Le changement de génération existe pour certains comptes secondaires ; harmoniser tous les usages, l’arrêt des anciens travaux et leur reprise avec les identifiants validés.
45. **Rapprocher les alias depuis une identité validée** — *Extension*. Associer UPN et domaine\utilisateur à un SID déjà confirmé sans nouvelle tentative d’authentification après refus.
46. **Expliquer les droits nécessaires** — *Extension*. Chaque opération indique le droit ou accès requis et distingue refus d’accès, compte rejeté et indisponibilité réseau.
47. **Diagnostiquer les verrouillages avec des preuves** — *Extension*. Lecture autorisée de l’événement 4740 et rapprochement chronologique avec les tentatives de Domenia.
48. **Prévisualiser les opérations collectives** — *Renforcement*. Liste exacte des cibles, changements avant/après, exclusions, impact et confirmation proportionnée.
49. **Confirmer le résultat des écritures** — *Renforcement*. Relire l’état effectif ; une issue incertaine reste à vérifier et ne déclenche jamais un renvoi automatique.
50. **Protéger les informations sensibles** — *Renforcement*. Masquage, copie explicite, effacement contrôlé du presse-papiers, exports expurgés et permissions du stockage local.

## Recherche et navigation dans les OU

Priorité : **P0 puis P1**.

51. **Ouvrir l’arbre depuis un favori** — *Demandé*. Déployer les ancêtres, sélectionner l’OU et la rendre visible, sans double lancement de recherche.
52. **Afficher un fil d’Ariane navigable** — *Extension*. Remonter une branche ou copier son chemin ; distinguer clairement les OU de même nom.
53. **Filtrer l’arbre en conservant le chemin** — *Renforcement*. Montrer les ancêtres nécessaires aux correspondances avec tri alphabétique et défilement vertical.
54. **Unifier les sélecteurs d’OU** — *Renforcement*. Même arbre, recherche, favoris, profondeur et confirmation dans Recherche, Dashboard, Atelier et Outils.
55. **Revenir exactement à la vue précédente** — *Renforcement*. Restaurer filtre, tri, page, sélection, branches ouvertes et position de défilement.
56. **Composer des filtres visibles** — *Extension*. Critères sous forme de pastilles retirables ; leur combinaison et leur portée restent lisibles.
57. **Enregistrer des vues personnelles** — *Renforcement*. Conserver colonnes, largeur, tri, filtres et OU dans des vues nommées faciles à retrouver.
58. **Comparer plusieurs postes** — *Extension*. Afficher côte à côte propriétés et dates ; surligner les différences sans mélanger les mesures.
59. **Ouvrir un aperçu latéral** — *Extension*. Consulter une fiche sans quitter les résultats ni perdre la sélection de travail.
60. **Rendre les sélections collectives explicites** — *Renforcement*. Distinguer page visible, lignes sélectionnées et tous les résultats filtrés avant export ou action.

## Atelier et bibliothèque de requêtes

Priorité : **P0 puis P1**.

61. **Charger la bibliothèque progressivement** — *Limite mesurée*. Préparer les 515 modèles hors du fil UI ou à l’ouverture de Bibliothèque ; mesurer le gain sur Windows.
62. **Expliquer chaque correspondance** — *Extension*. Montrer, pour un poste, la valeur et le verdict de chaque condition : vrai, faux ou inconnu.
63. **Afficher la couverture avant exécution** — *Extension*. Indiquer combien de postes possèdent les champs nécessaires, combien sont périmés et combien restent non lus.
64. **Collecter seulement les informations manquantes** — *Extension*. Calculer les sondes et cibles nécessaires à la requête, avec coût estimé et lancement explicite.
65. **Ajouter des modèles paramétrés** — *Extension*. Une recette reçoit seuil, logiciel, version, OU et période via un formulaire typé.
66. **Composer des conditions imbriquées** — *Extension*. Éditer visuellement les groupes ET, OU et NON avec le même sens dans Recherche et les dashboards.
67. **Accepter les unités usuelles** — *Extension*. Saisir Go, Mo, pourcentage, heures ou jours ; contrôler les conversions et conserver les valeurs typées.
68. **Faire évoluer les requêtes personnelles** — *Limite vérifiée*. Remplacer la limite de cent recettes et le gros JSON par une bibliothèque paginée, organisée et recherchable.
69. **Partager des packs de recettes versionnés** — *Extension*. Import avec provenance, aperçu des changements, conflits et retour arrière ; aucune exécution au simple import.
70. **Transformer une requête en collection ou widget** — *Renforcement*. Partager une définition versionnée entre liste dynamique, indicateur, règle de santé et rapport.

## Dashboards et alertes

Priorité : **P0 puis P1**.

71. **Séparer activation AD et activité réelle** — *En cours*. Widgets distincts pour comptes machines activés, désactivés, état inconnu et activité selon période.
72. **Séparer présence ping et réponse WMI** — *Renforcement*. Un ping sans réponse ne classe pas automatiquement le poste éteint ou impossible à interroger.
73. **Conserver la liste exacte derrière chaque widget** — *En cours*. Le clic utilise les GUID et l’instantané qui ont produit le chiffre ; les limites d’affichage sont visibles.
74. **Afficher la couverture à côté de la santé** — *En cours*. Un parc peu renseigné ne reçoit pas une note rassurante ; les inconnus restent comptés séparément.
75. **Expliquer le score de santé** — *Extension*. Afficher contributions des règles, population éligible et conséquences des règles désactivées.
76. **Définir des politiques par OU** — *Extension*. Seuils et règles héritables, origine de la politique et exceptions locales visibles.
77. **Suspendre temporairement une alerte** — *Extension*. Motif, échéance et réactivation ; supprimer une règle personnalisée reste différent de masquer un incident.
78. **Comparer la santé entre deux dates** — *Extension*. Distinguer changement réel, évolution du périmètre et amélioration de la couverture.
79. **Créer des tableaux croisés** — *Extension*. OU × version Windows, modèle × RAM, site × couverture ; totaux cohérents et cellules ouvrant leurs postes.
80. **Qualifier l’organisation des widgets** — *Renforcement*. L’ajout, le déplacement, le redimensionnement, la réinitialisation et l’annulation existent ; améliorer leur ergonomie, leur découvrabilité et leur comportement au clavier et à différents DPI.

## Catalogue matériel et réseau

Priorité : **P1 puis P2**.

81. **Capacité et occupation mémoire** — *Catalogue à étendre*. RAM installée, barrettes, emplacements et utilisation datée ; distinguer capacité matérielle et mesure instantanée.
82. **Disques et prévision de saturation** — *Catalogue à étendre*. Volumes, espace libre et tendance issue de relevés suffisants ; aucune prévision chiffrée sans historique.
83. **Santé du stockage** — *Catalogue à étendre*. État fourni par les pilotes ou SMART lorsqu’il existe ; fournisseur absent et état sain restent distincts.
84. **Batteries des portables** — *Catalogue à étendre*. Capacité, usure et cycles selon support matériel, avec disponibilité et date de chaque valeur.
85. **BIOS et micrologiciels** — *Catalogue à étendre*. Version et date, regroupement par modèle, comparaison avec une référence approuvée.
86. **Processeurs et virtualisation** — *Catalogue à étendre*. Architecture, cœurs, capacités et usage daté ; différencier machine physique, VM et informations non exposées.
87. **Écrans et stations d’accueil** — *Catalogue à étendre*. EDID, modèles et numéros utiles lorsqu’ils sont disponibles ; changements entre relevés.
88. **Interfaces réseau** — *Catalogue à étendre*. IP, MAC, DNS, passerelle, DHCP, vitesse et état ; cartes virtuelles identifiées séparément.
89. **Imprimantes et périphériques en erreur** — *Catalogue à étendre*. Inventaire, pilote et état rapporté ; signaler les lectures partielles ou limitées à une session.
90. **Diagnostic réseau par couche** — *Catalogue à étendre*. Résolution DNS, réponse ICMP et accès au protocole utile ; expliquer à quelle étape la connexion échoue.

## Catalogue Windows et logiciels

Priorité : **P1 puis P2**.

91. **Logiciels installés sans effets de bord MSI** — *Catalogue à étendre*. Sources registre et paquets adaptées ; distinguer machine et utilisateur, architecture et doublons.
92. **État des mises à jour** — *Catalogue à étendre*. Version, correctifs lus et source ; ne pas déduire la conformité totale de Win32_QuickFixEngineering seul.
93. **Redémarrage en attente** — *Catalogue à étendre*. Présenter chaque indice et sa source ; distinguer obligation confirmée et indicateurs partiels.
94. **Services et dépendances** — *Catalogue à étendre*. État, mode de démarrage et écarts par rapport au profil attendu, avec actions séparées de l’inventaire.
95. **Processus et charge ponctuelle** — *Catalogue à étendre*. Lecture à la demande sur une durée bornée ; tri des consommations avec date et intervalle.
96. **Tâches planifiées et démarrage automatique** — *Catalogue à étendre*. Inventaire, éditeur, dernière exécution et erreurs ; éviter les secrets contenus dans les paramètres.
97. **Defender ou antivirus présent** — *Catalogue à étendre*. Moteur, signatures, protection rapportée et couverture ; ne pas supposer un fournisseur universel.
98. **Pare-feu effectif** — *Catalogue à étendre*. Profils applicables, origine locale ou stratégie et état réellement utilisé.
99. **BitLocker et démarrage sécurisé** — *Catalogue à étendre*. Protection, suspension, TPM et Secure Boot selon support ; ne pas confondre chiffrement et protection active.
100. **Certificats et expiration** — *Catalogue à étendre*. Certificats utiles, échéance et magasin, sans exporter de clé privée ni élargir la collecte inutilement.

## Catalogue annuaire et assistance

Priorité : **P1 puis P2**.

101. **Comptes utilisateurs à vérifier** — *Catalogue à étendre*. Expiration, désactivation, verrouillage et absence d’activité selon critères distincts.
102. **Hygiène des mots de passe** — *Catalogue à étendre*. Âge et politiques applicables, sans lire de mot de passe ni qualifier arbitrairement un compte de compromis.
103. **Groupes imbriqués et cycles** — *Catalogue à étendre*. Expliquer les chemins d’appartenance et indiquer les groupes non lus.
104. **Délégations et droits sur les objets** — *Catalogue à étendre*. Distinguer droits explicites et hérités ; calcul d’accès effectif présenté avec ses limites.
105. **Liens GPO et résultat appliqué** — *Catalogue à étendre*. Séparer GPO liée, héritage et résultat effectivement observé sur un poste.
106. **État de Windows LAPS** — *Catalogue à étendre*. Schéma, expiration et capacité de lecture ; lecture du secret uniquement à la demande et avec le droit adapté.
107. **Relation poste et utilisateur** — *Renforcement*. Séparer affectation déclarée, dernière session observée et historique ; origine et date visibles.
108. **Santé AD et réplication** — *Catalogue à étendre*. Diagnostics ciblés DNS, contrôleur, réplication et temps ; sondes privilégiées uniquement sur demande.
109. **Cohérence des noms et identités** — *Catalogue à étendre*. Repérer noms recyclés, adresses ambiguës et incohérences entre AD et inventaire, sans fusion automatique.
110. **Recettes d’assistance** — *Extension*. Parcours panne de connexion, machine lente, manque d’espace ou logiciel absent, avec collecte minimale expliquée.

## Interface et accessibilité

Priorité : **P0 puis P1**.

111. **Alléger les écrans principaux** — *Renforcement*. Une action principale claire, commandes secondaires contextuelles et options avancées repliées.
112. **Uniformiser les composants** — *Renforcement*. Espacements, typographie, icônes, états, boutons et formulaires partagés dans toute l’application.
113. **Adapter le contenu à la fenêtre** — *Renforcement*. Aucun bouton essentiel hors écran ; zones qui défilent clairement, y compris en RDP.
114. **Qualifier le zoom et les changements de DPI** — *Renforcement*. Tester 100 à 200 %, multi-écrans et changement à chaud, sans perte de saisie ou focus.
115. **Rendre le clavier suffisant** — *Renforcement*. Ordre de tabulation, flèches dans l’arbre, raccourcis découvrables, Échap cohérent et focus visible.
116. **Qualifier lecteur d’écran et contrastes** — *Renforcement*. Noms et annonces accessibles ; états exprimés par texte et symbole en plus de la couleur.
117. **Améliorer la palette de commandes** — *Renforcement*. Recherche des actions selon la sélection et les droits ; aucune écriture déclenchée sans étape explicite.
118. **Regrouper opérations et notifications** — *Extension*. Progression, erreurs, reprise et journal dans un panneau stable, sans rafales de fenêtres.
119. **Rendre les écrans vides utiles** — *Renforcement*. Expliquer absence de données, filtre trop strict ou droit manquant et proposer la prochaine action adaptée.
120. **Étendre l’annulation des présentations** — *Renforcement*. La disposition des widgets a déjà son annulation ; harmoniser le retour arrière des colonnes et filtres sans promettre l’annulation universelle des opérations AD.

## Observabilité et qualification

Priorité : **P0**.

121. **Attribuer les lenteurs à une opération** — *Renforcement*. Nom du callback, durée, volume et phase permettent d’expliquer les messages de lenteur.
122. **Mesurer les percentiles de réponse** — *Extension*. Temps médian et 95e percentile pour recherche locale, rendu, SQLite et collecte, par scénario reproductible.
123. **Relier les événements d’une opération** — *Renforcement*. Identifiant commun de la demande à la collecte, validation, lecture SQL et publication GUI.
124. **Produire un diagnostic expurgé** — *Renforcement*. Versions, métriques et erreurs utiles ; aperçu des données avant export et aucun secret.
125. **Tester charge et stabilité longues** — *Renforcement*. 10 000 postes minimum, qualification à 20 000 postes, cycles répétés, mémoire stabilisée et files bornées. Couvrir démarrage à froid, cache chaud, historique volumineux et postes comportant beaucoup de logiciels ou de sondes ; le nombre de postes seul ne décrit pas la charge.
126. **Injecter les pannes de stockage** — *Renforcement*. Disque plein, base occupée, arrêt entre commit et reçu, migration interrompue et reprise vérifiée.
127. **Injecter les pannes réseau** — *Renforcement*. Latence, DNS erroné, refus, pages partielles, déconnexion et réponses arrivant dans le désordre.
128. **Vérifier les invariants automatiquement** — *Renforcement*. Compte widget = GUID détaillés ; rendu daté ; résultat inconnu conservé ; aucune réponse d’une ancienne sélection.
129. **Qualifier les parcours graphiques natifs** — *Restant*. Clics, clavier, défilement, fenêtres et captures 1080p sans infobulles ; séparer événements simulés et parcours humain.
130. **Distinguer laboratoire et domaine réel** — *Restant*. Publier une matrice de validation par système, protocole et droit ; aucun test synthétique présenté comme preuve du réseau cible.

## Architecture et échanges avec les autres outils

Priorité : **P1 puis P2**.

131. **Extraire progressivement le cœur monolithique** — *Renforcement*. Séparer collecteurs, orchestration, stockage, requêtes et WPF avec des interfaces limitées et testables.
132. **Compiler seulement les points chauds mesurés** — *Renforcement*. C# pour traitement CPU, parsing ou sérialisation coûteux ; conserver l’orchestration PowerShell lorsqu’elle suffit.
133. **Versionner les contrats entre modules** — *Extension*. Schémas d’observation, erreurs et capacités explicites, avec migrations et compatibilité testées.
134. **Partager les briques avec Pesto et FilPro** — *Renforcement*. Étendre la bibliothèque commune pour requêtes, identité, coffre, journal et composants GUI après revue des besoins réels.
135. **Définir un contrat de sonde extensible** — *Extension*. Entrées, types, privilèges, coût, limites, source et tests attendus pour chaque nouvelle sonde.
136. **Isoler les sondes avancées** — *À étudier*. Une sonde personnalisée doit déclarer son comportement ; l’isolation et les droits sont conçus sans promettre un sandbox PowerShell magique.
137. **Importer des inventaires existants** — *À étudier*. Adaptateurs explicites vers GLPI, osquery ou CSV, avec correspondance d’identité, dates et priorité des sources.
138. **Prévisualiser et annuler un import local** — *Renforcement*. Valides, conflits et rejets avant application ; provenance imposée à l’import et lot de retour arrière.
139. **Produire un dossier de diagnostic hors ligne** — *Extension*. État local daté, requêtes et observations nécessaires à une intervention ; secrets exclus et périmètre choisi.
140. **Proposer une interface automatisable locale** — *À étudier*. Commandes versionnées pour export et lecture ; aucun serveur réseau ou service permanent nécessaire.

## Produit distribuable et maintenance

Priorité : **P0 avant vente puis P1**.

141. **Signer les exécutables et distributions** — *À étudier*. Signature vérifiable et identité d’éditeur ; empreintes du code et des archives livrées.
142. **Construire les deux packs de façon reproductible** — *Renforcement*. DEV et PROD issus du même runtime, dépendances épinglées et manifeste complet.
143. **Sécuriser la mise à jour de l’application** — *Extension*. Vérifier le paquet, sauvegarder les réglages et migrer la base avec possibilité de revenir à la version précédente compatible.
144. **Tester installation et désinstallation** — *Renforcement*. Parcours utilisateur standard, droits minimums, choix explicite de conservation des données locales.
145. **Tenir une matrice de compatibilité** — *Extension*. Windows, PowerShell, .NET, SQLite, LDAP/CIM et fournisseurs réellement qualifiés.
146. **Inventorier licences et dépendances** — *Renforcement*. Vérifier les conditions de redistribution de chaque composant ; une source GitHub accessible ne suffit pas.
147. **Définir une politique de données locale** — *Extension*. Ce qui est collecté, durée de conservation, export et suppression ; réglages compréhensibles et sans collecte cloud implicite.
148. **Guider le premier démarrage** — *Extension*. Connexion, OU de travail, première lecture et découverte du dashboard ; options rares reportées à leur usage.
149. **Synchroniser aide et documentation v1.0** — *Restant*. Guides DOCX/PDF, aide contextuelle et captures correspondent exactement au pack livré.
150. **Formaliser une recette de livraison** — *Renforcement*. Critères de fiabilité mesurables, incidents non résolus visibles, support et moyens de retour arrière documentés.

## Compléments du moteur de requêtes

Priorité : **P0 pour la justesse, P1 pour l’édition**.

151. **Contrôler la cohérence temporelle des conditions** — *Extension*. Signaler que les valeurs AD, CPU et inventaire ne décrivent pas la même période ; proposer une fenêtre commune lorsque la question l’exige.
152. **Interroger correctement les collections** — *Extension*. Exprimer « au moins un », « tous » et « aucun » ; deux critères sur un disque ou un logiciel doivent pouvoir viser le même élément.
153. **Prévisualiser l’impact d’une recette modifiée** — *Extension*. Lister widgets, alertes et vues dépendants avant modification ou suppression, avec migration ou conservation explicite de l’ancienne version.
154. **Explorer les champs WMI disponibles** — *Extension*. Parcourir les espaces de noms, classes et propriétés d’un poste choisi, avec types et descriptions ; mettre les métadonnées en cache sans lancer une exploration récursive du parc.
155. **Proposer un éditeur WQL avancé** — *À étudier*. Afficher la requête, ses propriétés demandées, ses préconditions et limites ; tester explicitement sur une cible avant d’en faire une recette. La validation syntaxique seule ne garantit pas qu’un fournisseur est sans effet de bord.
156. **Parcourir les associations WMI** — *Extension*. Relier disque physique, partition et volume, ou processus et service lorsque le fournisseur le permet ; conserver les identités des instances au lieu de rapprocher seulement leurs noms.
157. **Exporter une recette en script lisible** — *Extension*. Générer un PowerShell commenté avec paramètres, sources, limites et sortie structurée ; aucun identifiant secret dans le script, aucune exécution automatique à l’export.

158. **Agréger plus de 10 000 valeurs distinctes** — *Limite vérifiée*. `CountBy` plafonne à 10 000 catégories et lève une erreur au-delà. Prévoir des agrégats exacts avec stockage ou mémoire bornés et détails paginés, pour que les regroupements par nom ou identité fonctionnent sur 20 000 postes. Une vue limitée aux principales catégories doit conserver un total exact et un détail accessible.

Les points 154 à 157 s’inspirent des capacités documentées de [WMI Explorer](https://github.com/vinaypamnani/wmie). Ils demandent une adaptation au circuit central de Domenia et une revue des licences avant toute réutilisation de code.

## Choix techniques à respecter

- **AD différentiel par OU** : le mécanisme existant mérite une qualification complète. DirSync opère à l’échelle d’une partition ; uSNChanged impose notamment l’affinité DC, l’invocationID et la réconciliation des déplacements et suppressions. [Microsoft DirSync](https://learn.microsoft.com/windows/win32/ad/polling-for-changes-using-the-dirsync-control), [Microsoft uSNChanged](https://learn.microsoft.com/en-us/windows/win32/ad/polling-for-changes-using-usnchanged).
- **Activité AD** : lastLogon est propre à chaque DC ; lastLogonTimestamp est répliqué avec une actualisation espacée. L’un ne remplace pas une observation de présence réseau. [Microsoft attributs AD](https://learn.microsoft.com/en-us/windows/win32/ad/attributes), [Microsoft lastLogonTimestamp](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-adls/ba6d87f9-7023-4ccd-9d0e-dd7b53865db5).
- **Inventaire logiciel** : une interrogation Win32_Product peut provoquer des contrôles et réparations MSI. Ce fournisseur ne doit pas devenir la source générale d’un inventaire passif. [Microsoft Win32_Product](https://learn.microsoft.com/en-us/previous-versions/windows/desktop/msiprov/win32-product).
- **Correctifs** : Win32_QuickFixEngineering ne fournit pas un inventaire exhaustif de toutes les mises à jour. [Microsoft QFE](https://learn.microsoft.com/en-us/windows/win32/cimwin32prov/win32-quickfixengineering).
- **SQLite** : sauvegarde cohérente par une méthode adaptée ; WAL exige que les processus accédant à la base soient sur la même machine. Un partage réseau ne devient pas une base multiutilisateur fiable en déplaçant simplement le fichier. [SQLite Backup](https://sqlite.org/backup.html), [SQLite WAL](https://sqlite.org/wal.html).
- **Version SQLite réellement chargée** : relever le moteur utilisé sous Windows et vérifier les correctifs applicables, notamment le défaut WAL-reset documenté comme corrigé dans 3.51.3, 3.44.6 et 3.50.7. La version du Mac ne prouve pas celle du poste Windows. [SQLite WAL-reset](https://sqlite.org/wal.html).
- **WPF** : virtualiser les contrôles ne suffit pas à éviter de charger toutes les données ; conserver pagination et budgets de mémoire. [Microsoft WPF](https://learn.microsoft.com/en-us/dotnet/desktop/wpf/advanced/optimizing-performance-controls).
- **Comptes** : la protection de Domenia ne peut pas garantir qu’un autre processus ne verrouillera jamais le compte. L’événement 4740 aide à établir l’origine des tentatives. [Microsoft 4740](https://learn.microsoft.com/previous-versions/windows/it-pro/windows-10/security/threat-protection/auditing/event-4740).
- **Commercialisation** : chaque réutilisation de code nécessite une revue de sa licence. PingCastle indique des conditions spécifiques pour l’intégration dans une offre commerciale. [PingCastle](https://www.pingcastle.com/download/).

Les décisions actuelles conservent une base locale, les packs DEV/PROD classiques et une OU choisie comme périmètre normal. Le serveur SQL distant et le format WAD ont été annulés. Les catalogues de sondes sont des familles à enrichir selon les capacités et droits observés, pas des promesses que WMI peut tout lire partout.

## Critères de réussite proposés

Ces critères sont des objectifs de qualification, pas des performances déjà garanties.

| Sujet | Critère |
|---|---|
| Cohérence | À périmètre, critères et instantané identiques, total du widget égal au nombre de GUID de son détail. |
| Complétude | Une requête à 10 000 correspondances permet un export exact de 10 000 lignes, indépendamment de la pagination visible. |
| Détails | Une sonde de 300 éléments permet leur consultation ou annonce explicitement le budget et la portion non conservée. |
| Fraîcheur | Un recalcul local ne change aucune date de collecte AD, ping ou WMI. |
| Authentification | Aucun nouvel essai automatique avec des identifiants déclarés refusés ; contexte précis conservé dans le diagnostic. |
| Reprise | Un arrêt après commit puis avant reçu ne provoque ni doublon, ni publication incohérente. |
| UI | Objectif à mesurer : réaction visuelle en moins de 100 ms et recherche locale courante sous 500 ms au 95e percentile, sur machine et jeu de données documentés. |
| Réseau | Chaque scénario de regroupement mesure les requêtes réellement évitées et conserve exactement les mêmes informations nécessaires. |
| Charge | Parc synthétique de 10 000 postes minimum, qualification à 20 000, campagne longue et mémoire qui se stabilise ; recette réseau réelle séparée. |
| Volume utile | Mesurer aussi observations, logiciels, historiques et taille de base ; qualifier lectures paginées, filtres et export complet sur les mêmes données. |
| Livraison | Pack testé identique au pack publié, restauration vérifiée et guides correspondant aux écrans. |

## Consultation du Spark

Avis de conception reçu via le client local KBZA, modèle déclaré `spark-local`. Les propositions utiles et leurs limites sont reprises ci-dessous. Il a reçu le contexte d’architecture et les incidents, pas les fichiers de code ; il déclare n’avoir ni testé ni consulté le web. Son avis est une contribution de conception, pas une validation indépendante du logiciel.

La consultation avait commencé avec la cible de 5 000 postes. La demande suivante de David porte la cible à **10 000 postes minimum** ; la feuille de route applique cette cible et recommande une qualification à 20 000. Les seuils de performance et fréquences proposés dans l’avis original restent des hypothèses à mesurer et adapter.

### Propositions retenues après rapprochement

| Avis du Spark | Intégration dans la feuille de route |
|---|---|
| Définir précisément la population de chaque vue et fournir un diagnostic des écarts | Points 2, 6, 73, 124 et 128. L’outil doit pouvoir montrer les GUID manquants ou supplémentaires et les exclusions. |
| Montrer source, dernière réussite et dernière tentative pour chaque information | Points 3–5, 10 et 151. La fraîcheur ne doit pas être un unique état global du poste. |
| Expliquer la présence à partir de signaux distincts | Points 72 et 90. Une réponse de protocole doit être datée et rattachée à la bonne cible ; plusieurs échecs ne prouvent toujours pas qu’un ordinateur est éteint. |
| Proposer des missions guidées avec coût et droits nécessaires | Points 63–65 et 110. Les recettes existantes restent la base commune. |
| Donner un état de santé du moteur et des sources | Points 118 et 121–124 : files, latences, erreurs, identité suspendue et écritures en attente. |
| Prévoir des fenêtres de collecte et suspendre les sources en échec répété | Compléments 159 et 160 ci-dessous. |

### Adaptations nécessaires avant implémentation

- Une résolution DNS et une ancienne activité AD ne prouvent pas une présence actuelle. Pas de balayage automatique de nombreux ports pour produire un état rassurant.
- La mutualisation d’une validation initiale des identifiants ne signifie pas une unique authentification réseau pour toutes les machines et tous les protocoles.
- Les exemples de durée de fraîcheur du Spark ne sont pas des valeurs par défaut validées pour ce parc.
- La référence AD attendue d’un diagnostic doit provenir d’une lecture complète, datée et comparable ; si elle manque, le diagnostic l’annonce.
- `whenChanged` seul n’est pas adopté comme mécanisme universel de synchronisation. Les contraintes de DC, de droits, de reprise et de suppression restent celles des sources Microsoft citées plus haut.

## Compléments issus de la revue Spark

159. **Définir des fenêtres de collecte par profil** — *Extension*. Limiter les campagnes de fond aux périodes choisies lorsque Domenia fonctionne ; une action explicite reste possible avec son périmètre affiché. Aucun service permanent ajouté implicitement.
160. **Suspendre une source en échec répété** — *Renforcement*. Bloquer temporairement les nouvelles demandes vers le DC, site ou fournisseur concerné, sans déclarer tout l’annuaire inaccessible. Reprise progressive pour les incidents transitoires ; rejet d’identifiants traité par la protection du compte avec reprise explicite.
