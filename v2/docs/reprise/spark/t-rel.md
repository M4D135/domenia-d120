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

Tests en échec (écran « Utilisateurs et postes », simulation) :
1. `RelationsTests.Import_preview_plan_and_undo` : « trois lignes valides (attendu 3, obtenu 0) ».
2. `RelationsTests.Session_observations_are_saved_by_batches_of_64` : « la moisson apporte plus de 64 nouveaux couples
   (postes sans association) : 7 ».
Piste : les deux tests cherchent des postes « libres » (sans association) dans le monde simulé ; vérifie ce que renvoie
`relations.list` (lignes de toutes les relations, observations de session comprises ?) et ce que la graine
(`SimulatedRelationSeed`) associe, et si le test ou la simulation doit changer pour qu'il existe des postes libres
(le parc simulé compte plusieurs centaines de postes). Fichiers : extrait des tests, lecteur simulé, graine, état, règles d'import.
