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

Rapport de qualification : `-Package <ZIP livré> -QualificationReport <rapport>` vérifie hors ligne le rapport avec les règles
de `release_guard` : Windows PowerShell 5.1, campagne réussie, même build, scénarios requis exécutés et liés aux archives,
ZIP dont chaque fichier porte l'empreinte de son manifeste. Un rapport fourni mais refusé arrête l'installation avant toute
écriture, avec la raison du refus. Sans rapport, un avertissement s'affiche et l'installation continue ;
`-RequireQualification` refuse alors toute modification.

Codes de sortie : 0 installation faite (ou `-WhatIf`), 1 erreur, 2 rien n'a été installé (réponse N ou aucune réponse).
`-Confirm:$false` supprime toutes les questions, y compris celle des raccourcis : `-Shortcuts Oui` ou `Non` donne alors
la réponse. Les chemins relatifs (`-Destination`, `-Package`, `-QualificationReport`) partent du dossier courant de
PowerShell.

Première installation dans un dossier vide : `-Install -Destination 'C:\Domenia'` copie les fichiers contrôlés par
empreintes, les débloque et lance le contrôle de démarrage. Les raccourcis Bureau et menu Démarrer sont proposés et ne sont
jamais créés sans réponse (`-Shortcuts Oui` ou `Non` pour répondre d'avance).

En cas d'interruption, le lancement reste bloqué jusqu'à restauration. `Domenia-Start.ps1` donne alors la commande complète :
le script `RESTAURER-CODE.ps1` de la sauvegarde concernée, ou l'installateur avec `-RestoreLatest -Destination`. Le lanceur
`Domenia.exe`, conservé à l'octet (F8), affiche encore « Utiliser l installateur DEV » : il s'agit de
`wad\Support\INSTALLER-MISE-A-JOUR.ps1`, livré dans PROD et DEV. La dernière sauvegarde (ou celle de l'installation
interrompue) se restaure sans chercher son chemin :

```powershell
.\wad\Support\INSTALLER-MISE-A-JOUR.ps1 -RestoreLatest -Destination 'C:\Domenia'
.\wad\Support\INSTALLER-MISE-A-JOUR.ps1 -RestoreBackup 'C:\Domenia\wad\maintenance\backups\DOSSIER'
```

La restauration contrôle les empreintes et refuse d'écraser un fichier modifié indépendamment. Elle ne touche pas aux données.

## Signature et vérification hors ligne

`VERIFIER-PACK.cmd` contrôle les empreintes du manifeste, puis lance `tools\Test-DomeniaSignature.ps1` pris dans l'arbre du
vérificateur (jamais dans la copie examinée) et seulement si aucun fichier n'est en erreur. Le rapport sépare l'intégrité et
l'éditeur, sans accès réseau ni contrôle de révocation :

- les scripts PowerShell sont signés par `tools\Signer-Distribution.ps1` sur la copie préparée (`build_packages.py
  --stage-dir`) et acceptés pour le seul certificat épinglé (`-PublisherThumbprint`) ;
- `Domenia.exe` (jamais re-signé, F8) et les composants tiers sont acceptés pour leur empreinte SHA-256 épinglée dans
  `tools\release-contract.json` ;
- les fichiers que Authenticode ne sait pas signer (`.json`, `.xaml`, `.cs`, `.cmd`, `.ico`, verrou) ne sont couverts que
  par un catalogue signé du manifeste (`Signer-Distribution.ps1 -ManifestCatalog wad\package-manifest.json`, qui produit
  `wad\package-manifest.cat`). Sans ce catalogue, le rapport les liste à part et l'éditeur vaut « Editeur verifie,
  manifeste non signe ».

La signature reste facultative tant qu'aucun certificat n'est fourni. `-RequireSignature` exige les scripts signés et les
binaires épinglés ; `-RequireSignedManifest` exige en plus le catalogue signé. À côté d'un manifeste PROD (copie installée,
ou copie DEV mise à jour avec un paquet PROD), les fichiers de code laissés par une version précédente ne sont jamais
chargés : ils sont signalés à part et ne rendent pas la copie « modifiée ». Les outils du labo et l'historique, absents du
ZIP DEV, sont ignorés de la même façon.

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
