# Domenia 1.0 RC1.13.0 — livraison du 8 octobre 2026

Build : `2026.10.08-DOMENIA-1.0-RC1.13.0-D120`.
Guides : `DOC/Domenia-1.0-Guide-technicien` et `DOC/Domenia-1.0-Guide-administrateur` (.docx et .pdf) dans la livraison.
Cible : Windows PowerShell 5.1 x64, interface WPF. Lancer `Domenia.exe`.

## Les deux packs

- **PROD** : `Domenia.exe` et `wad`, uniquement les composants nécessaires à l'application.
- **DEV** : le même runtime à l'octet, l'installateur, les sources, les outils, les tests et le suivi D001-D120.

Extraire le ZIP entièrement dans un dossier local. Si Windows bloque les fichiers, utiliser
`wad/Support/DEBLOQUER_TOUT.cmd`. Ne pas déplacer le cœur sans les modules et leur manifeste.

## Détection utilisateur / poste

La détection est déclenchée manuellement :

- dans **Rechercher**, **Pinger la liste**, **Détecter la liste** et **Analyser la liste** traitent seulement les postes des résultats chargés après filtrage ; le périmètre est figé au clic ;
- **Analyser la liste** ajoute le relevé WMI léger et les requêtes WMI des widgets des tableaux de bord ;
- la vue d'ensemble du parc de l'**Accueil** suit l'OU choisie dans Rechercher et ne lance aucune analyse ; jamais le domaine entier.

Une confirmation indique le périmètre. Aucun scan ne part au démarrage. Les postes hors ligne sont ignorés.
Le relevé concerne l'utilisateur de la console, pas les sessions RDP. Chaque demande vérifie légèrement la console
pour constater un changement ; l'identité LDAP en cache est réutilisée lorsqu'elle reste valide.
Le cache persiste entre les lancements. Les associations automatiques sont actualisées avec leur historique ;
les associations manuelles et importées restent protégées. Une absence de réponse n'efface pas le dernier utilisateur connu.

## Mise à jour et restauration

Fermer Domenia après la fin des opérations. Conserver une sauvegarde de ses données. Extraire **PROD** (ou DEV) dans
un dossier distinct, puis lancer dans Windows PowerShell 5.1 l'installateur livré dans `wad\Support` (dans DEV,
`.\INSTALLER-MISE-A-JOUR.ps1` à la racine appelle le même script) :

```powershell
.\wad\Support\INSTALLER-MISE-A-JOUR.ps1 -Destination 'C:\Domenia' -WhatIf
.\wad\Support\INSTALLER-MISE-A-JOUR.ps1 -Destination 'C:\Domenia'
```

L'installateur vérifie et prépare la livraison complète, contrôle la version préparée avec `Domenia-Start.ps1 -CheckOnly`,
demande « Installer ces N fichiers ? (O/N) », sauvegarde le code précédent, verrouille le lancement, remplace les fichiers
puis contrôle l'ensemble avant activation. Il ne lance aucune suite de tests sur le poste. Les données et les préférences
existantes sont conservées. Le résumé final donne la version avant et après ; la copie préparée est supprimée et seules
les cinq dernières sauvegardes complètes sont gardées. Une copie de Domenia ouverte dans un autre dossier n'empêche pas
cette mise à jour. Les versions déjà actives ne sont pas réinstallées.

Rapport de qualification : `-Package <ZIP livré> -QualificationReport <rapport>` vérifie hors ligne que le rapport
Windows PowerShell 5.1 est lié à l'empreinte de ce ZIP. Sans rapport, un avertissement s'affiche et l'installation continue ;
`-RequireQualification` refuse alors toute modification.

Première installation dans un dossier vide : `-Install -Destination 'C:\Domenia'` copie les fichiers contrôlés par
empreintes, les débloque et lance le contrôle de démarrage. Les raccourcis Bureau et menu Démarrer sont proposés et ne sont
jamais créés sans réponse (`-Shortcuts Oui` ou `Non` pour répondre d'avance).

En cas d'interruption, le lancement reste bloqué jusqu'à restauration. La dernière sauvegarde (ou celle de l'installation
interrompue) se restaure sans chercher son chemin :

```powershell
.\wad\Support\INSTALLER-MISE-A-JOUR.ps1 -RestoreLatest -Destination 'C:\Domenia'
.\wad\Support\INSTALLER-MISE-A-JOUR.ps1 -RestoreBackup 'C:\Domenia\wad\maintenance\backups\DOSSIER'
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
