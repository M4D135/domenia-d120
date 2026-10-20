# Point 8 — rendu d'arbre corrigé, virtualisation mémoire partielle

Le brouillon OpenCode GLM gratuit low a été corrigé par le superviseur après un edit refusé et des défauts de sous-jobs. Le résultat effectif modifie trois fonctions du Core, sans attribut XAML cosmétique :

- `New-DomeniaTreeSystemGroup` (`Domenia-Core.ps1:4482`) retourne une coque vide sur `-DeferChildren`. Le helper synchrone garde son comportement pour ses petits appels explicites ; le chemin de production passe par la file.
- `Initialize-DomeniaTreeRenderTimer` (`:4557`) utilise un quota commun (configuration `TreeRenderBatchSize`, plafonnée à 64), une tranche coopérative de 8 ms et une rotation entre les jobs. Au moins une unité est tentée même si le tri initial consomme le budget ; le statut progressif est mis à jour une fois par tranche. Une création WPF n'est pas préemptible : ce n'est pas une garantie temps réel. Les enfants du groupe système consomment le même quota que les OU ordinaires.
- `Queue-DomeniaTreeRowsToNode` (`:4658`) garde `GroupNode/GroupRows/GroupIndex` dans le job parent. Aucun sous-job autonome ne peut survivre à son annulation. Chaque unité contrôle le `RenderId` courant. Le parent conserve `Loaded=false` et son `RenderId` jusqu'au dernier enfant système ; une erreur laisse `Loaded=false`, trace l'échec et retire le job sans arrêter les autres branches.

Le chargement LDAP reste limité au niveau déplié (`Load-TreeChildren`, `:7818`), et les rendus attendent le readback SQLite. Le code conserve toutefois toutes les lignes d'une branche reçue puis tous ses `TreeViewItem` créés. Le quota par tick n'est donc pas un plafond global de nœuds, de données ou de mémoire.

Une virtualisation mémoire effective demanderait de revoir les conteneurs ajoutés directement, leur modèle de données et leurs templates, en préservant DN, état chargé, sélection, expansion, favoris et défilement. Les seuls attributs `IsVirtualizing/Recycling` ne prouvent pas ce résultat. [Limites décrites par Microsoft](https://learn.microsoft.com/en-us/dotnet/desktop/wpf/advanced/optimizing-performance-controls). Cette refonte n'a pas été introduite pendant les tests finaux.

`tests/Test-DomeniaTreeRendering.ps1` contient quatre cas utilisant de vrais conteneurs WPF et les fonctions Core importées par AST : quota/équité avec dictionnaire ordonné puis Hashtable, attente de tous les enfants système, annulation/remplacement et erreur isolée. Timer, configuration, regroupement des données et présentation des feuilles sont des doubles explicites ; aucun AD ni Dispatcher réel dans ce banc. Le regroupement lui-même garde les assertions existantes de WiringRecherche. Aucune mesure mémoire ou limite murale de 8 ms n'est revendiquée. Le banc est remis à root pour le delta Windows ; ce sous-lot ne l'a pas exécuté.

État du point 8 : **PARTIEL**. Correction du blocage de création en masse appliquée ; virtualisation mémoire intégrale et qualification à grande échelle ouvertes.
