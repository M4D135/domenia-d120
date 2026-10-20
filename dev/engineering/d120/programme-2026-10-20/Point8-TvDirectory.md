# Point 8 — Virtualisation du TreeView `TvDirectory` : état PARTIEL, proposition documentée

Rédigé par le relecteur (OpenCode GLM-5.3-Flash low, relecture superviseur Codex), 20 octobre 2026.
**Décision root : aucun patch XAML appliqué ni proposé** — un patch cosmétique est potentiellement inefficace et aucune qualification temps réel n'existe. Statut du point 8 : **PARTIEL** ; ce rapport documente l'ampleur du reste et le contrôle futur nécessaire. Aucun banc exécuté, aucun PASS.

## 1. État réel du code

- `dev/wad/Domenia-Main.xaml:1458` : `<TreeView x:Name="TvDirectory" …>` — aucun attribut `VirtualizingPanel.*`, ni `IsVirtualizing`, ni `VirtualizationMode`.
- Style `<Style TargetType="TreeView">` : seulement `BorderThickness="0"` et `Background="Transparent"`. Le style `TreeViewItem` ne porte que des réglages de tooltip/police. Rien de ces réglages n'active la virtualisation.
- Les grilles `Main.xaml:331–334` et `:1676` sont explicitement virtualisées : la virtualisation est prouvée pour les grilles, pas pour l'arbre principal.

## 2. Profondeur lazy et rendu progressif (limites exactes)

- Profondeur **lazy** : `New-TreeItem` `Core:4456` crée un `TreeViewItem` avec `Tag = {Name, DN, Kind, Loaded=$false, RenderId, Loading}`, un enfant fictif « Chargement... » (chevron visible), `Add_Expanded → Load-TreeChildren` : seuls les enfants d'un nœud déplié sont lus (`Load-TreeChildren` `Core:7799`, refuse une 2e lecture si `Tag.Loaded` ou `RenderId` actif ou `Loading` récent ∈ 30 s + 15 s).
- Nuance : `New-DomeniaTreeSystemGroup` `Core:4482` construit ses enfants immédiatement (groupe replié, petits volumes) ; ce conteneur système reste un ajout direct.
- Rendu par lots avec timer : `Queue-DomeniaTreeRowsToNode` `Core:4634` met les lignes en job (`TreeRenderJobs`, `BatchSize = Get-CfgValue "UI" "TreeRenderBatchSize" 24`) ; `Initialize-DomeniaTreeRenderTimer` `Core:4556` ajoute par tranche (minimum 5, `IntervalMs = Get-CfgValue "UI" "TreeRenderIntervalMs" 18`), **tree timer protégé FI-05, arrêté dès qu'aucun job**.
- Valeurs configurées réelles : `Core:19230–19231` déclarent `TreeRenderBatchSize=16`, `TreeRenderIntervalMs=20` (source superviseur). Constat : **divergence entre la valeur configurée (16/20) et la valeur de repli du code (24/18)** dans `Queue-DomeniaTreeRowsToNode`/`Initialize-DomeniaTreeRenderTimer` ; la valeur configurée gagne à l'exécution. Déclaré ici sans changement.
- **Limites : limite par tranche (5 minimum, `BatchSize`) ≠ limite globale.** Aucun plafond de nœuds n'existe dans ces fonctions : une branche qui renvoie N lignes finit par créer N `TreeViewItem`s ; ` job.Added` n'articule qu'une progression d'affichage. Le statut `LblTreeStatus` « affichage progressif X/Y » est un jalon de blocage UI, pas une maîtrise de la mémoire totale.

## 3. Pourquoi les 3 attributs XAML ne prouvent pas un gain

- `WPF` virtualise un `ItemsControl` via son panneau hôte ; la doc Microsoft (optimized performance of controls ; how to improve TreeView performance) indique que **l'ajout direct de conteneurs (ici des `TreeViewItem` construits en code et insérés dans `Items`) peut désactiver l'UI virtualization**, et qu'un vrai gain TreeView demande `IsVirtualizing=true` + `VirtualizationMode=Recycling` avec un modèle de données/templates qui laisse WPF générer les conteneurs.
- Dans l'état actuel (conteneurs créés par `New-TreeItem`/`New-DomeniaTreeRowItem`, `Header` assigné en code, templates via `Get-DomeniaTreeHeaderTemplate`), trois attributs ajoutés au XAML ne prouvent donc pas de gain : les conteneurs sont déjà réalisés au moment de l'ajout.

## 4. Ampleur du reste si un recyclage réel était un jour visé (pas maintenant)

Un vrai recyclage demanderait une migration vers un modèle de données d'arbre (hiérarchie de données + `HierarchicalDataTemplate`) générant les conteneurs par WPF. Impact à maîtriser, sans prétendre que cette migration existe :

- `Tag` par nœud (`Name/DN/Kind/Loaded/RenderId/Loading`, plus `LoadingAt`, `DirectoryReadId` ajoutés dynamiquement) : doit migré sur l'objet modèle, car un conteneur recyclé change de cible.
- `Loaded`, `RenderId`, `Loading` : pilotés par le timer d'affichage et `Load-TreeChildren` ; à relier au modèle pour rester corrects au recyclage.
- Sélection (`Add_Selected → Set-SelectedBranch`), `Expanded → Load-TreeChildren`, dépliage restitué (`Restore-DomeniaTreeNavState`, signets `Save-DomeniaTreeBookmark`), favoris (`AutomationProperties.ItemStatus 'Favori'`), `SuppressBranchAutoLoad`, restauration de sélection/défilement : tous s'accrochent aujourd'hui au `TreeViewItem` ; sous recyclage, les callbacks doivent suivre l'événement source/`DataContext`, sinon états faux au fil du scroll.
- Filtre OU (`Update-DomeniaOuTreeFilter -OnlyWhenActive`) et statuts (`LblTreeStatus`) : appliqués au repère du nœud ; à relier au modèle.

## 5. Validation future ciblée (aucune exécutée)

1. Propriétés attachées (`ItemContainerVirtualizationMode`/`VirtualizingPanel.IsVirtualizing` sur l'hôte) lues à l'exécution sous Windows.
2. Nombre de conteneurs réellement réalisés sous scroll (comptage des `ItemContainerGenerator` / containers réalisés vs nombre d'items).
3. États et navigation préservés (sélection, dépliado, favoris, signet restauration) après lecture longue d'une branche et restutions.
4. Empreinte mémoire (working set avant/après lecture d'une grande branche, mesure distincte de la qualification étendue).

Aucun banc nouveau n'a été lancé ni validé par ce rapport ; s'aligner sur le lot critique en cours puis la qualification étendue pour la mesure.
