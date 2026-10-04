# Domenia 1.0 RC1.11.0 — livraison du 5 octobre 2026

Build : `2026.10.05-DOMENIA-1.0-RC1.11.0-D120`.
Cible : Windows PowerShell 5.1 x64, interface WPF. Lancer `Domenia.exe`.

## Les deux packs

- **PROD** : `Domenia.exe` et `wad`, uniquement les composants nécessaires à l'application.
- **DEV** : le même runtime à l'octet, l'installateur, les sources, les outils, les tests et le suivi D001-D120.

Extraire le ZIP entièrement dans un dossier local. Si Windows bloque les fichiers, utiliser
`wad/Support/DEBLOQUER_TOUT.cmd`. Ne pas déplacer le cœur sans les modules et leur manifeste.

## Détection utilisateur / poste

La détection est déclenchée manuellement :

- dans **Rechercher**, **Détecter la liste** traite seulement les postes des résultats chargés après filtrage ; le périmètre est figé au clic ;
- dans **Relations**, **Détecter sur tout le parc** traite tous les postes actifs de l'index local.

Une confirmation indique le périmètre. Aucun scan ne part au démarrage. Les postes hors ligne sont ignorés.
Le relevé concerne l'utilisateur de la console, pas les sessions RDP. Chaque demande vérifie légèrement la console
pour constater un changement ; l'identité LDAP en cache est réutilisée lorsqu'elle reste valide.
Le cache persiste entre les lancements. Les associations automatiques sont actualisées avec leur historique ;
les associations manuelles et importées restent protégées. Une absence de réponse n'efface pas le dernier utilisateur connu.

## Mise à jour et restauration

Fermer Domenia après la fin des opérations. Conserver une sauvegarde de ses données. Extraire **DEV** dans
un dossier distinct, puis lancer dans Windows PowerShell 5.1 :

```powershell
.\INSTALLER-MISE-A-JOUR.ps1 -Destination 'C:\Domenia'
```

L'installateur vérifie et prépare la livraison complète, sauvegarde le code précédent, verrouille le lancement,
remplace les fichiers puis contrôle l'ensemble avant activation. Les données et les préférences existantes sont conservées.
Une copie de Domenia ouverte dans un autre dossier n'empêche pas cette mise à jour.
Les versions déjà actives ne sont pas réinstallées. Le build daté distingue cette livraison des candidats précédents.

En cas d'interruption, le lancement reste bloqué jusqu'à restauration. Utiliser le chemin de sauvegarde indiqué
par l'installateur ou dans `wad/Support/.update.pending` :

```powershell
.\INSTALLER-MISE-A-JOUR.ps1 -RestoreBackup 'C:\Domenia\wad\maintenance\backups\DOSSIER'
```

La restauration contrôle les empreintes et refuse d'écraser un fichier modifié indépendamment. Elle ne touche pas aux données.

## État de validation

La campagne d'intégration Windows PowerShell 5.1 du commit `64e6b69` totalise **2 365 tests réussis, zéro échec**,
avec un arbre propre lié à 423 fichiers et aucune régression par rapport à la campagne précédente.
Elle couvre la détection manuelle, le cache, l'historique et les identités de sélection communes.
L'installateur est vérifié séparément sur six scénarios ciblés réussis : installation, restauration, interruption, verrouillage,
corruption et modifications concurrentes. Les empreintes du code testé sont contrôlées. Les premiers échecs et leurs corrections
restent consignés dans le suivi ; aucune nouvelle campagne complète n'a été relancée.

Les contrôles de construction vérifient les manifestes, les empreintes, le contenu des ZIP et l'identité du runtime DEV/PROD.
Aucun accès AD réel n'a été testé. Les archives restent des **candidates** : la qualification formelle liée aux SHA-256
des deux ZIP n'est pas acquise. Le suivi D001-D120 conserve explicitement ses points restants ; cette livraison ne prétend
pas les clôturer tous. Le lanceur natif est conservé à l'octet et reste non signé.
