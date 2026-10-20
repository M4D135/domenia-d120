# Point 8 — TvDirectory : données séparées et conteneurs virtualisés

Le code du point 8 est implémenté au codegate du 20 octobre 2026 ; sa qualification Windows reste en attente. Le détail de l’architecture, des nouveaux fichiers et des tests se trouve dans [Point8-Virtualisation.md](Point8-Virtualisation.md). Le présent document remplace le constat intermédiaire « virtualisation mémoire partielle », formulé avant cette refonte.

`New-TreeItem`, les groupes système, les états de chargement et les erreurs créent désormais des données `DomeniaTreeItem`, sans conserver de `TreeViewItem`. Le template hiérarchique et le panneau virtuel génèrent et recyclent les conteneurs au fil du viewport. Les propriétés nécessaires aux favoris, au filtre, à la sélection et à la restauration restent portées par les données. La compilation des types WPF est différée au premier usage de l’arbre.

Le correctif de rendu précédent est conservé : quota global `TreeRenderBatchSize` plafonné à 64, tranche coopérative de 8 ms, rotation entre jobs et enfants système comptés dans ce même quota. Le job parent reste propriétaire des groupes ; `Loaded=false` et `RenderId` sont maintenus jusqu’au dernier enfant. Annulation, remplacement et erreur isolée ne doivent pas arrêter les autres branches.

La virtualisation porte sur les conteneurs visuels. Elle ne plafonne pas la mémoire des données déjà lues : lignes, DTO et métadonnées restent conservés. Les lectures LDAP restent limitées aux actions autorisées ; réalisation différée, filtre et restauration d’historique ne doivent pas introduire une lecture implicite. La tranche de 8 ms ne rend pas préemptible une opération native WPF.

`Test-DomeniaTreeRendering.ps1` couvre le quota et les groupes avec les types de données réels, sans fenêtre ni Dispatcher réel. `Test-DomeniaTreeVirtualization.ps1` ajoute huit cas dans une vraie fenêtre WPF bornée, sur 10 000 données synthétiques : génération bornée des conteneurs, défilements répétés, favori, filtre, groupe, sélection sans lecture et annulation. Les bancs favoris, navigation et raccordement ont été adaptés. Aucun de ces nouveaux tests n’a été exécuté par l’agent de ce lot ; le delta Windows de root doit qualifier le candidat construit.

État : **IMPLEMENTE_A_VALIDER_WINDOWS**. Aucun gain mémoire chiffré, succès AD à grande échelle ou résultat de test Windows n’est déduit des seuls contrôles statiques.
