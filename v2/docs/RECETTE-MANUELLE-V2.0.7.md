# Domenia 2.0.7 — finitions de l’interface

Correctif du 29 octobre 2026, issu de la vérification des captures de la recette 2.0.6. La préparation et les contrôles CI ne constituent pas une recette utilisateur ; la validation visuelle native et la recette utilisateur restent en attente.

Extraire le nouveau pack dans un dossier distinct et vérifier son SHA256 avec `SHA256SUMS.txt`. La disposition reste celle de 2.0.6 : `Domenia.exe` et `wad` à la racine. Le format des données ne change pas (schéma 11, révision native 2) : une base de 2.0.5 ou 2.0.6 s’ouvre telle quelle. Conserver les versions précédentes.

## À observer

- Utilisateurs et postes › « Ajouter une association » : la loupe est visible dans le champ de recherche du panneau, comme dans les filtres de grille des panneaux et des dialogues.
- En contraste élevé, Schéma de l’annuaire › Classes / Attributs : le cadre de l’option choisie est à 3 px du bord du contrôle, comme dans Paramètres.
- Rechercher, menu replié : dans la carte « Syntaxe facultative », « utilisateur: martin » et « groupe: GG‑Support » tiennent chacun sur une ligne.
- Replier puis déplier le menu de gauche : « Replier le menu » reste à la même hauteur ; la largeur du menu se règle en tirant son bord droit à la souris.
- Les points de la [recette 2.0.6](RECETTE-MANUELLE-V2.0.6.md) restent applicables.

Ne noter comme réussies que les étapes effectivement exercées sur ce pack. Ce guide ne demande aucune écriture AD hors de l’OU de test, aucune modification du système ni redémarrage.
