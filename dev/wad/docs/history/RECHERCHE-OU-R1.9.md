# ADCC 1.0 R1.9 : recherche et filtre OU réunis

Build : `2026.09.30-R1.9-OUSEARCH`.
Base de travail : **dev.zip fourni dans cette conversation**, et non une ancienne archive du projet.

## Utilisation

L'espace **Rechercher** contient désormais l'arbre des OU et des conteneurs à gauche, un séparateur redimensionnable au centre, et les filtres/résultats à droite. Le champ de recherche reste accessible dans le bandeau supérieur.

Un clic sur une OU conserve le texte saisi et relance la recherche dans cette branche. Il n'ouvre plus un espace Annuaire distinct. Déplier une flèche charge seulement les sous-branches de l'arbre, sans sélectionner une nouvelle OU.

- **Inclure les sous-OU**, coché au démarrage : recherche dans la branche sélectionnée et ses sous-branches. Décoché : seulement les enfants directs.
- **Tout le domaine** : retire la restriction à une OU, réactive les sous-OU et relance la recherche en conservant son texte et le filtre de type.
- **Rechercher / Entrée**, avec un champ vide : affiche le contenu du périmètre dans la limite demandée. Les termes non vides conservent la règle minimale de caractères de l'application.
- **Actualiser** : relit les résultats du périmètre actuel. Une sélection réellement effectuée peut être conservée si sa ligne est toujours présente ; aucune première ligne n'est sélectionnée automatiquement.
- **Effacer** : efface le texte et la liste, mais garde le filtre OU. Une nouvelle recherche vide permet de revoir le contenu de cette OU.

Le type d'objet se combine avec l'OU : Tous, Utilisateurs, Machines, Groupes, OU et conteneurs. **Tous inclut maintenant aussi les groupes, OU et conteneurs**, pour préserver la fonction d'explorateur de l'ancien Annuaire. Un changement de type relance la recherche. La présence réseau conserve son fonctionnement existant.

Le périmètre est affiché au-dessus des résultats et son DN complet est lisible dans la colonne de gauche. La limite de résultats reste comprise entre 1 et 500 ; atteindre cette limite affiche un avertissement pour affiner la recherche. Les résultats ne constituent pas un export exhaustif du domaine.

Cliquer un résultat conserve le parcours existant vers sa fiche. Revenir dans Rechercher permet de retrouver l'arbre et les filtres. Les anciens raccourcis internes vers Annuaire redirigent vers cette page commune.

## Filtrage réel, cache et résultats tardifs

L'OU choisie est transmise au worker comme **racine LDAP**, avec la portée explicite. Ce n'est pas un masquage de lignes après une recherche limitée sur tout le domaine. La même racine et la même portée sont conservées lorsque le mécanisme existant essaie son contexte de serveur de secours.

Un changement de filtre invalide les recherches en cours et retire les anciennes lignes. Les callbacks vérifient la génération, le DN, la profondeur, le texte et le type avant d'afficher un retour. Une ancienne recherche ne doit pas repeupler la liste d'une autre OU.

Les clés du cache de visite comprennent l'OU et la profondeur. L'aperçu de l'index local à l'échelle du domaine est désactivé pour les recherches restreintes à une OU ou aux enfants directs, afin de ne pas afficher provisoirement des lignes hors périmètre. La lecture LDAP reste obligatoire.

Le démarrage et la restauration des réglages ne lancent pas une recherche de contenu automatiquement. Sélectionner volontairement une OU le fait désormais, indépendamment de l'ancien réglage `AutoLoadBranchOnSelect`. Les contrôles de présence existants après réception des résultats sont conservés.

Les nouveaux contrôles de filtrage rejoignent le verrouillage d'interface utilisé pendant une écriture AD. Cette révision n'ajoute aucune opération d'écriture, aucun contournement des droits et aucun changement de credential.

## Périmètre du code

19 fonctions existantes changent, 6 helpers de recherche sont ajoutés ; **548 fonctions principales du dev.zip restent identiques après normalisation des fins de ligne**. Aucune fonction d'origine n'est supprimée. Les changements comprennent le XAML, les événements, la recherche et son rendu, le registre d'opérations, son compteur de démarrage, la liste de contrôles verrouillés et les libellés de build.

Les corps de connexion/authentification, le code commun des workers distants, les binaires, les configurations livrées et les modules métier de l'Atelier sont conservés. L'ancienne opération distincte `BranchObjects` n'est plus planifiée : les actions de branche utilisent le moteur de recherche commun. Son entrée est retirée du registre fermé, qui contient maintenant **45 opérations avec empreintes vérifiées**. Les anciens callbacks sont conservés pour compatibilité mais refusent les états sans périmètre valide.

## Installer

Fermer ADCC après la fin des opérations. Extraire le ZIP dans un dossier distinct de l'installation actuelle. Depuis le nouveau dossier ADCC :

```powershell
.\INSTALLER-MISE-A-JOUR.ps1 -Destination 'C:\Outils\ADCC' -WhatIf
.\INSTALLER-MISE-A-JOUR.ps1 -Destination 'C:\Outils\ADCC'
```

Adapter la destination. Ne pas supprimer l'ancien dossier : **le pack ne contient pas votre base personnelle**. L'installateur garde `wad\data` et les configurations existantes ; il sauvegarde le code remplacé et conserve son mécanisme de retour arrière. Les modules et le manifeste doivent être installés avec le cœur, pas seulement `ADCC-Core.ps1`.

Pour une installation neuve, extraire tout le dossier ADCC puis utiliser `LANCER-ADCC.cmd`.

## Vérifications et limites

Les rapports R1.9 précisent les contrôles réellement exécutés sous Linux/Python. Le nouvel audit vérifie la structure XML, les noms et ressources, les raccordements de filtre, la transmission du périmètre dans le source, les gardes des callbacks, les empreintes et la conservation du code non concerné. Il ne constitue pas une exécution PowerShell ou une preuve de fonctionnement sur votre domaine.

**Non exécutés dans l'environnement de préparation : Windows PowerShell 5.1, WPF et LDAP/AD réel.**

`TESTER-RECHERCHE.cmd` fournit **42 scénarios PowerShell isolés** : requêtes vides, OU, profondeur, changements de filtre, cache, annulation, conservation du texte, suppression des anciens résultats, passage des paramètres au worker et erreurs simulées. Ils emploient des doubles en mémoire ; ils ne testent pas les permissions ou la disponibilité réelle d'un contrôleur. L'installateur les lance avant la copie et s'arrête si la suite échoue ou reste incomplète.

`APERCU-INTERFACE.cmd` charge le vrai XAML avec un arbre et des lignes fictifs. On peut y examiner le partage gauche/droite et filtrer les exemples. Aucun accès AD n'est effectué. `TESTER-INTERFACE.cmd` ajoute à la recette WPF existante les vérifications de la page commune, des colonnes, des exemples par OU et du retour au domaine. Cet aperçu ne remplace pas la validation sur un poste connecté au domaine.

Les anciens rapports restent historiques. L'audit comptes R1.4 contient une assertion « moteur identique à R1.3 » déjà en échec sur le dev.zip fourni, après les correctifs de connexion ultérieurs. Cette assertion n'a pas été supprimée pour fabriquer un résultat vert. La conservation du moteur de connexion est vérifiée par comparaison avec **le dev.zip actuel** dans le nouvel audit.

## Recette sur Windows

1. Lancer l'aperçu et vérifier que l'arbre est à gauche de la même grille de résultats en thème clair et sombre.
2. Dans l'application réelle, sélectionner une OU avec un mot déjà saisi, puis une autre : seul le périmètre doit changer.
3. Décocher les sous-OU et vérifier sur des objets connus que seuls les enfants directs reviennent. Recocher pour inclure les descendants.
4. Tester Tout le domaine, Effacer, Groupes et Actualiser ; vérifier le DN affiché et le texte conservé.
5. Changer rapidement d'OU pendant une recherche puis attendre : les retours tardifs ne doivent pas remplacer ceux du dernier filtre.

Références de conception Microsoft : `DirectorySearcher.SearchRoot` et `System.DirectoryServices.SearchScope` (OneLevel / Subtree). La première définit le nœud de départ de la recherche ; la seconde sa profondeur. Le mode Subtree inclut également l'objet de base lorsqu'il correspond au filtre. Les tests locaux de cette révision ne simulent pas un annuaire exhaustif.
