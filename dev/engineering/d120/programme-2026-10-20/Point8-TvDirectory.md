# Point 8 — TvDirectory : données séparées et conteneurs virtualisés

**Code implémenté, banc Windows de virtualisation R4 réussi : 8/8.** Le présent état remplace le constat intermédiaire de virtualisation partielle, formulé avant la séparation données/conteneurs. Voir [Point8-Virtualisation.md](Point8-Virtualisation.md) pour les preuves, l’architecture et les limites.

L’arbre conserve désormais des données observables `DomeniaTreeItem`. Les `TreeViewItem` sont générés et recyclés par WPF au moyen d’un template hiérarchique et d’un panneau virtuel à chaque niveau. Les favoris, le filtre, la sélection et la restauration restent liés aux données. Une révélation du seul chemin cible avance par ticks sans nouvelle lecture implicite. Le trigger du style dérivé garantit le panneau personnalisé malgré le trigger du thème hérité.

Les contraintes du rendu progressif restent conservées : quota global plafonné à 64, tranche coopérative de 8 ms, rotation des jobs, enfants système dans le job parent, annulation et isolement des erreurs. La compilation des quatre types WPF est différée au premier usage de l’arbre.

Dans la vraie fenêtre WPF du banc R4, 10 000 données synthétiques conduisent à **40 à 61 conteneurs générés** sur neuf relevés après sélection. Les huit cas passent : cibles lointaines, groupe à deux niveaux, recyclage/favori, filtre, feuille non lue et annulation. Le test de rendu passe séparément 4/4 et Navigation ciblée 5/5. Rapport principal relu : `validation/2026-10-20/rc39-critical/rc39-tree-r4/TreeVirtualization.json`, exécuté par root ; preuve intégrée au dépôt.

La virtualisation porte sur les conteneurs visuels. Les données déjà lues restent en mémoire ; aucun plafond global de données, benchmark de mémoire du processus ou résultat AD à grande échelle n’est revendiqué. Le rattachement au ZIP final demeure une étape de livraison distincte.
