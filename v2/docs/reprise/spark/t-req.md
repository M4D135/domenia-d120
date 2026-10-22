Des tests C# de Domenia 2 échouent après l'intégration de branches développées en parallèle (chaque écran avait été écrit
sans lancer les tests). Pour CHAQUE test cité : lis le test, son message d'échec et le code fourni, trouve la cause exacte,
puis décide ce qui doit changer :
- le CODE quand le test exprime le comportement voulu (commentaires du test, documentation XML, règles de Domenia 1) ;
- le TEST quand son attente est périmée (libellé ou donnée de simulation changés depuis, valeur fixée par une autre branche).
Propose le correctif MINIMAL, sans réécrire ce qui marche, sans toucher aux autres tests.

FORMAT DE RÉPONSE (remplace le format FILE des règles communes) : uniquement des blocs PATCH, puis NOTES :

=== PATCH: v2/chemin/du/Fichier.cs ===
<<<<<<< SEARCH
<extrait EXACT et UNIQUE du fichier fourni, lignes complètes, indentation comprise>
=======
<remplacement>
>>>>>>> REPLACE
=== END PATCH ===

Plusieurs blocs SEARCH/REPLACE par fichier sont permis. N'invente aucune ligne du SEARCH : copie-la du fichier fourni.
NOTES : une ligne par test : « Nom du test : cause → correctif (code ou test) ».

Tests en échec (atelier de requêtes, collecte bornée à une OU, simulation) :
1. `RequetesOperationsTests.Collection_needs_a_plan_bounded_to_an_OU_and_runs_it_once` : « compte rendu du relevé
   (« Relevé » absent de « Aucun poste à relire : toutes les mesures demandées sont à jour. ») ».
2. `RequetesRound2Tests.The_collection_plan_rereads_the_saved_SELECT_and_counts_its_cost` : « SELECT mémorisé relu sur
   les postes du plan ».
Piste : la fraîcheur des mesures vient des réglages de collecte (Paramètres, `CollectionSettingsRules`, valeurs par défaut
fournies) ; vérifie si le plan de collecte retient des postes à relire dans l'OU choisie par le test, ou si toutes les
mesures simulées sont jugées fraîches (durées par défaut, horloge fixe des tests : 21/10/2026 16:26 UTC).
