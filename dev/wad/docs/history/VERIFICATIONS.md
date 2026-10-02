# AD⚡CC 1.0 — Rapport de livraison et de vérification

**Build : `2026.09.21-R1-RELIABILITY` — 21 septembre 2026**

## Résultat constaté

**40 contrôles réussis, 0 échec dans l’audit exécuté.**

Environnement : Linux / Python 3.13.5 / SQLite 3.46.1. Il ne dispose pas de Windows PowerShell, de WPF, ni d’un accès à l’Active Directory de l’utilisateur.

**Les tests du parseur natif PowerShell, de WPF et des opérations AD réelles n’ont pas été exécutés ici.** Ils ne sont pas comptés dans les contrôles réussis. Le script de tests Windows fourni doit être exécuté en préproduction. Les contrôles lexicaux Python ne constituent pas une preuve de compilation PowerShell.

## Étendue des modifications

Le cœur conserve les **539 fonctions principales d’origine** : 39 sont modifiées et 13 fonctions sont ajoutées. Aucun nom de fonction principale d’origine n’est supprimé. Les helpers internes de processus distants et le code de la requête WMI sont également modifiés. La version publique reste 1.0 ; le build distingue cette révision.

Les fichiers exécutables et DLL fournis sont identiques aux originaux. Le lanceur PowerShell, le cœur, le déblocage, la procédure de mise à jour et les outils de tests/maintenance font partie du paquet. Les différences du cœur sont consultables dans `wad/docs/ADCC-R1.patch` et les noms des fonctions dans `CHANGEMENTS.json`.

## Ce qui a été réellement vérifié

| Vérification | Portée exacte |
|---|---|
| 6 scripts PowerShell | Chaînes, here-strings, commentaires et délimiteurs avec un analyseur lexical Python approximatif. Pas le parseur Microsoft. |
| 4 modèles XAML | Analyse XML réelle, unicité des noms ; tous les contrôles principaux d’origine sont conservés. Pas de rendu WPF sur Linux. |
| 46 opérations de travail | SHA-256 recalculé sur chaque corps exact, concordance avec le registre et différence après altération d’un corps. Contrôle lexical des corps. |
| Fonctions et protections | Conservation des fonctions ; absence de redéfinitions principales ; présence et ordre de plusieurs gardes de sécurité/concurrence. Ce sont des assertions statiques. |
| 12 scénarios SQL | Exécution du modèle SQL extrait du code contre des données synthétiques : UPN complet, caractères spéciaux, apostrophe, Unicode, entrée de type injection, limite et score. Pas d’exécution de la fonction PowerShell complète. |
| API de sauvegarde SQLite | Essais via Python de copie avec WAL engagé, indépendance de la copie, verrouillage BUSY et interruption bornée. Le pont P/Invoke Windows reste à tester sous Windows. |
| Intégrité du paquet | Empreintes des exécutables/DLL/icônes d’origine et des fichiers du manifeste ; absence des données personnelles du parc dans le paquet neuf. |

## Base fournie : contrôle séparé, non inclus dans les 40

La base SQLite de **111,157,248 octets** a été ouverte en lecture seule, avec `PRAGMA quick_check`. Résultat : **OK**. Son empreinte avant/après le contrôle est identique. Aucun enregistrement n’a été modifié et aucune donnée du parc n’a été incorporée au rapport ou au paquet neuf.

Ce contrôle ne garantit ni l’exactitude métier des associations utilisateur/poste, ni la fraîcheur des données, ni l’absence de mélanges historiques entre périmètres. Ce n’est pas un diagnostic de performance sur le poste Windows de l’utilisateur.

## Données et installation

**Le ZIP de livraison est un paquet neuf sans la base de 111 Mo, sans les journaux et sans les paramètres personnels de l’archive source.** La procédure `INSTALLER-MISE-A-JOUR.ps1` est conçue pour mettre à jour le code dans l’installation existante en conservant `wad/data` et les préférences déjà présentes. Elle est fournie avec `-WhatIf`, sauvegarde préalable du code et restauration contrôlée ; ses écritures sur une vraie installation Windows n’ont pas été exécutées ici.

Lire `LIRE-MOI.md` avant remplacement. Ne pas supprimer l’ancienne installation pour la remplacer par le dossier neuf vide en supposant que le parc a été transféré.

## Limites à connaître

Les appels natifs annulés peuvent rester actifs jusqu’à leur retour ou la fin du processus. La limite physique empêche d’en créer indéfiniment, mais ne prétend pas les interrompre de force. L’effacement des références de secrets n’est pas une remise à zéro garantie de la mémoire managée. Un secret copié dans une autre application ou un historique externe n’est pas récupérable par ADCC. Le passage d’identifiants explicites à PsExec avec `-p`, hérité du projet, reste un risque documenté.

Les filtres CSV réduisent le risque de formules, sans garantir le comportement de tous les tableurs ni d’un fichier réenregistré. Les diagnostics ne sont pas anonymisés : noms de machines, comptes, domaines et chemins peuvent subsister. Aucune validation EDR/antivirus, de signature logicielle, de DPI Windows ou de compatibilité avec le domaine réel n’est revendiquée.

## Prochaine validation opérationnelle

Exécuter `TESTER-ADCC.cmd`, examiner le rapport JSON produit dans `wad/data/TestReports`, puis appliquer la recette de `wad/docs/RECETTE-WINDOWS.md`. Tester d’abord le mode lecture seule, l’authentification, la navigation, les annulations, le cache et les comptes séparés. Réserver les actions d’écriture à des objets dédiés dans une OU de test et vérifier les résultats hors ADCC.

## Détail de l’audit exécuté

| Contrôle | Nature | Résultat |
|---|---|---|
| Lexique et delimitateurs : ADCC.ps1 | `StaticLexical` | PASS |
| Lexique et delimitateurs : INSTALLER-MISE-A-JOUR.ps1 | `StaticLexical` | PASS |
| Lexique et delimitateurs : wad/ADCC-Core.ps1 | `StaticLexical` | PASS |
| Lexique et delimitateurs : wad/maintenance/Debloquer-Paquet.ps1 | `StaticLexical` | PASS |
| Lexique et delimitateurs : wad/maintenance/Sauvegarder-Cache.ps1 | `StaticLexical` | PASS |
| Lexique et delimitateurs : wad/tests/Test-ADCC.ps1 | `StaticLexical` | PASS |
| 539 fonctions originales conservees | `StaticStructure` | PASS |
| Pas de definition principale en double | `StaticStructure` | PASS |
| XML bien forme et noms uniques : Get-LoginXamlLegacy | `XmlParser` | PASS |
| XML bien forme et noms uniques : Get-MainXaml | `XmlParser` | PASS |
| XML bien forme et noms uniques : Get-AdccStandardLoginXaml | `XmlParser` | PASS |
| XML bien forme et noms uniques : Get-AdccDebugLoginXaml | `XmlParser` | PASS |
| 46 empreintes workers exactes, corps equilibres et modification detectee | `StaticIntegrity` | PASS |
| Lexique du code commun execute dans les workers | `StaticLexical` | PASS |
| Binaire original inchange : ADCC.exe | `Sha256` | PASS |
| Binaire original inchange : ADCC.ico | `Sha256` | PASS |
| Binaire original inchange : wad/ADCC.ico | `Sha256` | PASS |
| Binaire original inchange : wad/Microsoft.ActiveDirectory.Management.dll | `Sha256` | PASS |
| Binaire original inchange : wad/ActiveDirectoryPowerShellResources.dll | `Sha256` | PASS |
| Binaire original inchange : wad/PsExec.exe | `Sha256` | PASS |
| Gardes statiques : concurrence, generation et arret non bloquant | `StaticGuards` | PASS |
| Gardes statiques : secret masque, index opaque, expiration et invalidation | `StaticGuards` | PASS |
| Gardes statiques : sauvegarde coherente, ecriture atomique, pas de restauration implicite | `StaticGuards` | PASS |
| Gardes statiques : exports CSV filtres et journaux bruts exclus | `StaticGuards` | PASS |
| SQL reel sur donnees synthetiques : 'sam@a.test' | `SqliteActualQuery` | PASS |
| SQL reel sur donnees synthetiques : 'sam@b.test' | `SqliteActualQuery` | PASS |
| SQL reel sur donnees synthetiques : 'pc_01' | `SqliteActualQuery` | PASS |
| SQL reel sur donnees synthetiques : 'pc%02' | `SqliteActualQuery` | PASS |
| SQL reel sur donnees synthetiques : "O'Neil" | `SqliteActualQuery` | PASS |
| SQL reel sur donnees synthetiques : 'pc!03' | `SqliteActualQuery` | PASS |
| SQL reel sur donnees synthetiques : 'été' | `SqliteActualQuery` | PASS |
| SQL reel sur donnees synthetiques : "zz' OR 1=1 --" | `SqliteActualQuery` | PASS |
| SQL reel sur donnees synthetiques : 'DOM\\sam' | `SqliteActualQuery` | PASS |
| SQL reel sur donnees synthetiques : 'sam' | `SqliteActualQuery` | PASS |
| SQL reel sur donnees synthetiques : 'x' | `SqliteActualQuery` | PASS |
| SQL reel : limite et score exact prioritaire | `SqliteActualQuery` | PASS |
| API SQLite via Python : instantane incluant WAL, copie independante | `SqliteBackupApiNotPowerShell` | PASS |
| API SQLite via Python : verrouillage BUSY et interruption bornee | `SqliteBackupApiNotPowerShell` | PASS |
| Paquet neuf : aucun cache, identifiant enregistre ou journal personnel | `PackagePrivacy` | PASS |
| Manifeste SHA-256 du paquet final | `Sha256` | PASS |

Le fichier `AUDIT-LINUX.json` contient les résultats structurés. Les sources techniques et les précautions complémentaires sont dans `SECURITE-ET-LIMITES.md`.
