# Domenia 2.0.6 — recette VM, clavier et interface

Correctif du 29 octobre 2026, issu des recettes des packs 2.0.5 et 2.0.6 sur la VM du domaine de test. La préparation et les contrôles CI ne constituent pas une recette utilisateur ; la validation visuelle native et la recette utilisateur restent en attente.

Extraire le nouveau pack dans un dossier distinct et vérifier son SHA256 avec `SHA256SUMS.txt`. La disposition reste celle de 2.0.5 : `Domenia.exe` et `wad` à la racine. Le format des données ne change pas (schéma 11, révision native 2) : une base migrée par 2.0.5 s’ouvre telle quelle. Conserver les versions précédentes.

## À observer

- Modifier un attribut par le circuit des écritures, confirmer, puis appuyer sur Échap dans le panneau du reçu : le panneau se ferme et la fiche suit l’objet (déplacement compris).
- Dans « Compte poste », charger un compte ponctuel, revenir au compte de connexion puis appuyer sur Échap : le panneau se ferme.
- Provoquer un avertissement qui reste affiché (par exemple un contrôle d’intégrité en défaut), puis ouvrir un dialogue : ses boutons restent visibles et cliquables, la notification reste lisible et se ferme par sa croix.
- Ouvrir « Restaurer une sauvegarde » depuis le contrôle d’intégrité en défaut, dans une fenêtre de taille courante : « Préparer la restauration » reste entièrement cliquable.
- Comptes, en simulation, depuis une OU de travail sans comptes : choisir l’OU « Utilisateurs » ouvre le détail du compte verrouillé le plus urgent.
- En contraste élevé, Paramètres › Apparence : l’option choisie des contrôles segmentés est encadrée et lisible.
- Rechercher : après une recherche, cliquer dans la barre fine puis fermer les suggestions par Échap : le plan appliqué et son filtre LDAP s’affichent sous le champ.
- Poste, inventaire complet : « Arrêter » apparaît à gauche des boutons d’inventaire, qui ne bougent pas.
- Les autres points de la [recette 2.0.5](RECETTE-MANUELLE-V2.0.5.md) restent applicables.

Ne noter comme réussies que les étapes effectivement exercées sur ce pack. Ce guide ne demande aucune écriture AD hors de l’OU de test, aucune modification du système ni redémarrage.
