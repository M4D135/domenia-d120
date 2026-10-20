# Point 8 — données et conteneurs de TvDirectory

État : **code implémenté ; qualification Windows ciblée réussie**. Le banc `TreeVirtualization` R4, exécuté par root sous Windows PowerShell 5.1, passe **8/8**. Rapport relu : `validation/2026-10-20/rc39-critical/rc39-tree-r4/TreeVirtualization.json`. `TreeRendering` R2 passe 4/4 et Navigation ciblée 5/5. Le build final et le lien des preuves au ZIP restent du ressort de la livraison ; ils ne sont pas déduits de ce seul banc.

Le modèle conserve des `DomeniaTreeItem` observables et leurs enfants, sans conserver de `TreeViewItem`. Un template hiérarchique et un panneau dérivé de `VirtualizingStackPanel` laissent WPF générer et recycler les conteneurs. Les vues enfants filtrées sont créées à la demande ; le filtre parcourt les données et rafraîchit chaque vue existante après ses enfants. Sélection, expansion et favori restent portés par les données. Les marqueurs durables distinguent une réalisation programmée d’un nouveau geste et empêchent qu’elle relance une lecture.

La révélation réalise les seuls indices du chemin cible, par ticks, et s’annule sur remplacement de racine, session, contexte ou génération. Son niveau courant persiste entre les ticks ; chaque conteneur parent est recherché de nouveau pour tenir compte du recyclage. Une unité au moins est traitée par tick, dans une tranche coopérative de 8 ms. Les favoris et restaurations demandent explicitement leurs lectures de chemin ; filtre et historique n’en demandent aucune. Les branches non lues conservent un placeholder de données pour leur chevron. Erreurs et chargements sont également des données.

Le quota global de rendu (plafonné à 64), l’équité entre jobs, les enfants des groupes dans le job parent, le maintien de `Loaded=false`/`RenderId` jusqu’à leur fin et l’annulation sont conservés. La tranche de 8 ms ne rend pas une opération native préemptible.

Fichiers principaux : `Domenia-DirectoryTree.Types.cs`, `Domenia-DirectoryTree.UI.ps1`, fonctions arbre du cœur, `Search.UI`, `Continuity.UI`, `Guard.UI` et `Domenia-Main.xaml`. Le chargeur fermé déclare 15 fonctions et 4 types différés ; la compilation WPF intervient au premier usage de l’arbre. Les registres C# et licences couvrent ce code interne. Les contrats LDAP et SQLite ne sont pas modifiés.

## Preuves et limites

Le banc R4 utilise une vraie fenêtre WPF bornée, avec 10 000 données synthétiques et un groupe système. Il vérifie la génération bornée, les sélections hors écran répétées, le favori après recyclage, le descendant de groupe à deux niveaux, le filtre avant génération, la sélection d’une feuille non lue sans lecture, l’annulation de session et les références faibles des anciens conteneurs.

Les neuf relevés après sélection donnent **40 à 61 conteneurs générés**, y compris les cibles d’indices 5 000, 9 999 et 8 000. La borne de moins de 300 n’a pas été relâchée. La première case vérifie aussi le panneau enfant réellement utilisé. Ce résultat qualifie les conteneurs sur ce banc ; ce n’est ni un accès AD, ni un benchmark de mémoire du processus. Les DTO, métadonnées et lignes déjà lus restent conservés : la virtualisation ne plafonne pas leur mémoire.

`TreeRendering` couvre le quota et les groupes avec les vrais types de données, sans fenêtre ni Dispatcher réel. `FavouriteReveal` garde une réalisation visuelle explicitement doublée, distincte du banc WPF. Navigation et WiringRecherche emploient les fixtures de données et déclarent honnêtement les sous-ensembles (`Subset=true`, `Complete=false`). Les résultats détaillés des autres bancs restent ceux du dossier de qualification de root.

## Corrections issues des retours Windows

Le premier chargement a révélé la référence de compilation manquante à `System.Xaml` ; les références explicites incluent désormais `System.Xaml` et `System.Core`. Le banc WPF importe `Common.Model` réel pour le découpage des DN. Le diagnostic natif après R3 a identifié un panneau enfant WPF standard : `ValueSource=StyleTrigger`, déclencheur hérité `IsVirtualizing=true` de profondeur 1. `ItemsPresenter.ApplyTemplate` ne changeait pas ce résultat. Le style dérivé déclare désormais son propre trigger qui fixe le panneau personnalisé et prime sur celui du style de base. Ces corrections passent ensemble dans R4, sans hausse des délais ni génération de tous les conteneurs.

Hash du module UI qualifié R4 : `beb4efea536e574093d4826957bd790f813dc8bb03ccbb0b464c2b252715ec89`. Hash du banc : `d1cdedb15329181d52bed0ead2d4b7df68b6e2a3352ae4daef48b07cf26c7aa6`. Le C# reste `8bf412290a145c6f7b2e4fc3ccbcec08dcff3c5c353d1676fe5fc49f39448d09`.

Une passe OpenCode gratuite `opencode/glm-5.3-flash-free`, variante `low`, a produit le brouillon ; elle a été arrêtée pour la finition supervisée. Les types et le module UI ont reçu une relecture indépendante par l’agent stockage. Contrôles statiques locaux passés ; tests Windows exécutés uniquement par root. Aucun commit, push ou test VM par l’agent de ce lot.
