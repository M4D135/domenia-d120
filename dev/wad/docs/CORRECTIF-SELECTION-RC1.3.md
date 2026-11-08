# Domenia 1.0 RC1.3 : sélection, restauration OU et en-têtes

Build : `2026.10.01-DOMENIA-1.0-RC1.3-SELECTION`.
Base : packs Domenia RC1.2 de cette conversation. Correctifs ACL et chargement des modules conservés.

## Utilisation

La liste se charge progressivement et conserve l'affichage du cache, la relecture LDAP et ses limites de résultats. **Recevoir une liste n'ajoute plus toutes ses machines à une file de sondes.** Le filtrage de présence n'exécute plus de ping collectif. Les contrôles distants de diagnostic explicitement demandés restent disponibles.

Un clic sélectionne une ligne. S'il s'agit d'une seule machine, avec **Vérifier le poste sélectionné** coché, son compte console est vérifié en arrière-plan. Aucun formulaire n'est ouvert ni vidé par la simple sélection. Un **double-clic sur une ligne**, ou **Entrée**, ouvre la fiche par le parcours existant. Un double-clic sur un en-tête ou une barre de défilement n'ouvre pas la dernière fiche sélectionnée.

**Revérifier ce poste** demande un nouvel essai sur cette seule machine, même si la case est décochée. Ce bouton ne lance pas de sonde de groupe. Une multisélection ne déclenche aucune vérification automatique. La sélection par les flèches du clavier suit la même règle que le clic.

Les événements intermédiaires produits par l'affichage, le tri, les filtres et la restauration de sélection ne doivent pas être assimilés à une nouvelle sélection volontaire. Le flux LDAP ne crée jamais de demande de sonde : il peut seulement confirmer la cible d'une demande déjà créée par l'opérateur.

## Ordonnancement et cache

Une seule demande non envoyée est conservée. Changer rapidement de machine remplace cette demande avant son envoi. Un court délai de 180 ms permet de regrouper les événements rapprochés. Les appels déjà démarrés restent comptés dans leur limite physique, y compris pendant un nettoyage ; le programme ne prétend pas pouvoir les interrompre instantanément.

Un appel en cours sur la même cible et le même GUID peut être partagé lors du double-clic. Son achèvement, une actualisation ou un timeout ne provoquent pas une relance automatique. Un nouvel essai est demandé avec le bouton ou une nouvelle sélection. Une ancienne sonde sur un objet recréé au même DN n'est pas partagée comme s'il s'agissait de la même machine.

Les observations sont toujours enregistrées par le cache existant. Pour les machines non sélectionnées, une ancienne observation demeure historique et conserve sa date. Une lecture refusée ou expirée ne rajeunit pas cette date et n'efface pas le dernier utilisateur connu. Un résultat reçu pour la machine A alors que B est sélectionnée ne remplit pas B avec l'utilisateur de A.

La vérification automatique reste celle de la **console Windows**, via CIM/DCOM, pas l'inventaire de toutes les sessions RDP. La vue Sessions dédiée reste disponible à la demande.

Le nouveau réglage `Streaming.VerifyUserOnSelection` vaut `true` par défaut. L'ancien `AutoDetectLoggedUser` n'active plus la vérification de toute la liste, même dans une configuration conservée lors de la mise à jour.

Les erreurs de sondes mémorisent leur cible propre, distincte de la dernière fiche ouverte. Une proposition de compte local ne déduit donc plus la machine cible de cette ancienne fiche. Les moteurs d'authentification et les règles de non-rejeu des écritures ne changent pas.

## Restauration de l'OU

Le défaut RC1.2 venait d'une sélection restaurée sous `SuppressBranchAutoLoad`, sans recherche de contenu ensuite. RC1.3 rétablit d'abord l'OU et la profondeur, puis programme **une seule recherche fraîche** de ce périmètre. Le cache peut précéder les retours LDAP, comme pour une recherche manuelle. Cela ne sonde pas les postes renvoyés.

Le chargement du contenu n'attend pas la fin de l'ouverture d'autres branches mémorisées. Une demande est consommée avant le lancement pour éviter les doublons entre ticks et événements d'affichage. Le domaine, le compte, la génération, le texte, le type et la profondeur sont contrôlés de nouveau au moment de lancer.

Le choix manuel d'une autre OU ou d'autres filtres a priorité. Un verrou d'écriture reporte le chargement. Une OU mémorisée absente ou introuvable dans le délai ne provoque **aucune recherche de substitution sur tout le domaine**. L'opérateur choisit alors une branche. Le chargement conserve l'espace de travail actuel au lieu d'imposer un changement de page.

## Colonnes

- **Utilisateur connecté (console)** : observation de console, ou dernier compte connu clairement indiqué en cache.
- **Association mémorisée** : lien utilisateur/poste historique ou manuel. Ce n'est pas une preuve de connexion actuelle.

La colonne d'association située après UPN/DNS possède désormais un en-tête texte explicite, au lieu d'un élément visuel imbriqué. Source lien et Confiance utilisent la même construction, avec leurs infobulles de colonne. Les 18 colonnes et leurs clés de liaison sont conservées : **aucune réinitialisation des largeurs ou de l'ordre n'est nécessaire**.

## Installation

Les deux ZIP contiennent le même runtime : `prod/Domenia.exe` et `prod/wad`, ou le dossier `dev` avec les outils en plus. Le déblocage reste dans `wad/Support/DEBLOQUER_TOUT.cmd` ; les tests et aperçus ne sont pas requis au lancement PROD.

Fermer Domenia après la fin des opérations. Extraire DEV dans un dossier distinct, puis ouvrir Windows PowerShell depuis ce dossier :

```powershell
# Adapter la destination au dossier qui contient Domenia.exe et wad.
.\INSTALLER-MISE-A-JOUR.ps1 -Destination 'C:\Outils\Domenia' -WhatIf
.\INSTALLER-MISE-A-JOUR.ps1 -Destination 'C:\Outils\Domenia'
```

L'installateur conserve les configurations et `wad/data`, et ne remplace pas les données de `%LOCALAPPDATA%\Domenia\Data`. Il sauvegarde le code remplacé. Ne supprimer ni l'installation ni le cache. Ne copier ni le cœur ni un module seul, car le contrat de modules et les empreintes changent aussi.

Après mise à jour, vérifier le build RC1.3 dans le journal. Le lanceur EXE et les DLL restent ceux de RC1.2. Les nouvelles archives ne contiennent aucune base personnelle.

## Validation et limites

Exécuté sur l'hôte Linux : audit général source/XML/SQLite/empreintes, audit ciblé de la sélection et de la restauration, correspondance des 54 contrats d'opérations, cohérence du chargeur et de ses 213 fonctions, vérification indépendante des deux archives et de leur runtime commun.

**Non exécuté ici : PowerShell, Windows PowerShell 5.1, rendu WPF, exécutable Windows, LDAP ou CIM sur un domaine.** Les tests de source ne démontrent pas une absence de latence sur votre parc et ne remplacent pas la recette ci-dessous. L'absence de réponse native dans un délai ne signifie pas que Windows a effectivement interrompu l'appel.

`TESTER-SELECTION.cmd` fournit **46 scénarios Windows isolés**, dont un contrôle WPF des en-têtes réellement matérialisés. Les dépendances réseau sont remplacées par des doubles explicites. Ils couvrent les listes sans sondes, les clics rapides, la cible unique, les résultats tardifs, les caches et GUID, les générations, la restauration unique et les changements de filtre. L'installateur exécute cette suite avant la copie et refuse un test ignoré ou un rapport incomplet. Les anciens rapports sont historiques et ne valent pas validation de cette version.

`APERCU-PROGRESSIF.cmd` suit le nouveau fonctionnement sur des données fictives : aucune simulation d'utilisateur n'apparaît avant la sélection d'une machine. Les autres aperçus ouvrent également la fiche au double-clic, pas au premier clic.

### Recette réelle

1. Choisir une OU, fermer normalement, relancer : son filtre et ses résultats doivent revenir sans quitter la branche.
2. Attendre l'affichage de la liste : aucune file de dizaines de vérifications utilisateur ne doit démarrer.
3. Cliquer une machine : rester dans la recherche ; seule cette machine est vérifiée. Double-cliquer pour ouvrir sa fiche.
4. Cliquer plusieurs machines très vite, puis filtrer ou changer d'OU : aucun rattrapage de toutes les anciennes sélections ; les appels déjà partis peuvent finir, mais leurs cibles restent distinctes.
5. Relancer sur une machine arrêtée : conserver le dernier compte connu comme historique, avec sa vraie date.
6. Vérifier les en-têtes et leurs infobulles, puis les largeurs et positions de colonnes après redémarrage.
