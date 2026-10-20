# Point 8 — données et conteneurs de TvDirectory

État au codegate du 20 octobre 2026 : implémenté, contrôles statiques locaux passés ; tests Windows non exécutés par cet agent. La qualification WPF réelle appartient au delta final de root. Aucun gain mémoire chiffré n’est revendiqué avant cette qualification.

Le modèle conserve des `DomeniaTreeItem` observables et leurs enfants, jamais des `TreeViewItem`. Un template hiérarchique et un panneau dérivé de `VirtualizingStackPanel` laissent WPF générer/recycler les conteneurs. Les vues enfants filtrées sont créées à la demande ; le filtre parcourt les données et rafraîchit chaque vue existante une fois après ses enfants. Les propriétés de sélection, expansion et favori restent sur les données. Les marqueurs durables distinguent une réalisation programmée d’un nouveau geste ; une réalisation différée ne doit pas relancer une lecture.

La révélation réalise les seuls indices du chemin cible, par ticks, et s’annule sur remplacement de racine, session, contexte ou génération. Les favoris et restaurations demandent explicitement leurs lectures de chemin ; filtre et historique ne le font pas. Les branches non lues conservent un placeholder de données pour leur chevron. Les erreurs et chargements sont également des données. Les contraintes globales du timer de rendu (quota, temps, équité, enfants des groupes, état Loaded du parent, annulation) sont conservées.

Fichiers principaux : `Domenia-DirectoryTree.Types.cs`, `Domenia-DirectoryTree.UI.ps1`, fonctions arbre du cœur, `Search.UI`, `Continuity.UI`, `Guard.UI`, `Domenia-Main.xaml`. Le chargeur fermé déclare 15 fonctions et 4 types différés ; la compilation WPF intervient au premier usage de l’arbre. Le registre C# et l’inventaire des licences couvrent le nouveau code interne. Les contrats LDAP et SQLite ne sont pas modifiés.

Tests ajoutés/adaptés, non exécutés ici :

- `Test-DomeniaTreeVirtualization.ps1` : huit cas, vraie fenêtre WPF bornée avec données synthétiques. 10 000 enfants, défilements répétés et cible hors écran, état favori après recyclage, groupe à deux niveaux, filtre avant génération, feuille non lue sélectionnable sans lecture, annulation de session, comptage des conteneurs et références faibles. Borne de moins de 300 conteneurs pour la fenêtre de 360 pixels. Ce n’est ni un test AD ni un benchmark de mémoire du processus.
- `Test-DomeniaTreeRendering.ps1` : quota global, équité, construction progressive des groupes, remplacement/annulation, erreur d’un groupe sans bloquer l’autre branche ; types de données réels.
- `Test-DomeniaFavouriteReveal.ps1` : machine d’état et lectures de chemin conservées ; réalisation visuelle explicitement doublée, couverte par le banc WPF séparé.
- `Test-DomeniaNavigation.ps1` : cas concernés préfixés « Programme 8 », modèles réels ; filtre, favoris et historique. `Test-DomeniaWiringRecherche.ps1` : fixtures de données et filtre regex optionnel. Les sous-ensembles portent `Subset=true`, `Complete=false`.
- `Test-DomeniaModules.ps1` : distingue les types immédiats des types différés ; la compilation de ces derniers est exercée au début du banc de virtualisation.

Contrôles locaux effectués : analyse statique des 13 scripts touchés sans erreur, XML principal valide, correspondance exacte des 15 exports, registres C# et licences PASS structurel. Les restrictions de redistribution historiques restent inchangées. Reçu détaillé hors dépôt : `work/opencode-supervision-rc14/tree-virtualization-20261020/static-gate.json`.

Une passe OpenCode gratuite `opencode/glm-5.3-flash-free`, variante `low`, a produit le brouillon. Elle a été interrompue après production des fichiers pour la finition supervisée. Les erreurs de template/événements WPF, de lecture des propriétés PowerShell par réflexion, de sélection différée, de placeholders et de rafraîchissement du filtre ont été corrigées localement. Relecture indépendante des types et du module UI par l’agent stockage. Aucun commit, push, test VM ou appel de modèle supplémentaire par cet agent.

Premier retour du delta Windows : compilation arrêtée faute de référence explicite à `System.Xaml` (`IQueryAmbient`). Le chargement différé et les références de compilation incluent désormais `System.Xaml` et `System.Core`. Analyse statique ciblée passée ; nouveau hash UI `865c98f8ccdfd49552f3b5e8b2bde08fe2405f89f815f3370b8af7d5fec70ec6`. Le retest Windows reste attendu ; l’échec initial ne constitue pas une validation des comportements WPF.
