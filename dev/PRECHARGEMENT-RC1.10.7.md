# Domenia 1.0 RC1.10.7 : sélection et fiche préchargée

Build du moteur : `2026.10.01-DOMENIA-1.0-RC1.10.7-SELECTION`.
Base de travail : les fichiers réels du pack DEV RC1.10.6 livré dans cette conversation.

## Ce que corrige cette version

Le helper de préchargement existait dans RC1.10.6, mais le gestionnaire réel de sélection de `DgObjects` ne l'appelait pas. Le clic ne déclenchait que le circuit de console utilisateur, qui ignorait les lignes de type Utilisateur. La simple présence du helper ne rendait donc pas le préchargement fonctionnel.

Autre défaut : le double-clic demandait encore `-Force`, donc une nouvelle lecture. Enfin, la fonction d'affichage naviguait vers la fiche avant de tenter de revenir à la page précédente. Cela pouvait provoquer des changements de page et des événements inutiles.

Cette version raccorde les événements réels au nouveau parcours. Le module de sélection est déclaré dans le chargeur fermé et livré avec le moteur, pas seulement ajouté au dossier.

## Comportement

| Geste | Résultat |
|---|---|
| Un clic sur un utilisateur | Fixe le contexte, rend Fiche accessible, programme une lecture AD après le court délai de sélection. La page Recherche reste ouverte. Aucune machine associée n'est sondée automatiquement. |
| Un clic sur un poste | Rend Fiche et Assistance poste accessibles, programme sa lecture AD. Le ping et la lecture console restent le circuit séparé, limité au seul poste sélectionné. |
| Double-clic / Entrée | Ouvre Fiche immédiatement. Partage la lecture en cours ou les données déjà chargées ; ce geste n'est plus une actualisation forcée. |
| Navigation vers Fiche avant la fin | Affiche une zone de chargement intégrée à la page, sans données de l'objet précédent et sans fenêtre supplémentaire. |
| Changement rapide A, B, C | Une seule demande AD non envoyée est conservée, celle de C. Un ancien worker déjà parti peut finir, mais ne peut pas remplacer la fiche de C. |
| Erreur / annulation de lecture | État explicite et bouton Réessayer la lecture dans la fiche. Ce bouton relit AD seulement, sans ping, CIM ni écriture AD supplémentaire. |
| Sélection multiple ou vide | Aucun préchargement individuel en lot ; les vues qui dépendaient de la sélection unique sont retirées. |

Le délai par défaut est de 180 ms, borné de 80 à 500 ms via `Browser.SelectionDebounceMs`. Ce regroupement évite d'expédier une lecture à chaque étape d'un déplacement rapide dans la liste. Ce n'est pas un délai garanti pour le contrôleur ou le réseau.

La sélection au clavier suit le même parcours. Les événements produits pendant un rafraîchissement programmatique restent ignorés lorsque le drapeau de suppression existant est actif.

## Cache et données fiables

Une fiche présente dans le cache de visite peut être affichée rapidement, mais elle porte l'indication de cache et ses commandes restent désactivées pendant la relecture. Une erreur ne la transforme pas en fiche fraîchement validée. Les anciennes entrées du cache de visite utilisent une autre clé et ne sont pas déclarées valides arbitrairement.

Les nouvelles clés de visite distinguent la session, le serveur, le domaine, l'identité de lecture, le DN et le GUID lorsqu'il est connu. Aucun mot de passe n'entre dans cette clé. Un cache dont le GUID est invalide est ignoré ; la lecture AD est tout de même envoyée.

Les callbacks revérifient l'identité, l'époque de session, la génération de recherche, la sélection et le token de requête. Le GUID reçu doit correspondre à celui de la ligne lorsqu'elle en possède un. Une fiche d'un objet recréé au même nom n'est pas acceptée à la place de l'ancien.

Les données d'un formulaire modifié ne sont pas abandonnées avant la décision existante de l'opérateur. Un refus de changement de fiche restaure la sélection précédente avant toute nouvelle sonde ou changement du contexte Relations.

La base locale, ses observations datées et ses schémas ne sont pas migrés par ce correctif. L'index n'est plus synchronisé deux fois lors du rendu d'un poste : le parcours conserve une seule mise à jour ciblée après lecture fraîche. Les opérations historiques de maintenance ne sont pas refondues ici.

## Ce qui reste inchangé

La recherche du bandeau reste globale, indépendante de l'OU. La navigation OU, les positions des colonnes et les panneaux rétractables sont conservés. La page Relations et ses méthodes Détecter/Rechercher ne sont pas réécrites dans cette livraison.

Aucun ping collectif ou scan utilisateur n'est réintroduit. Les 57 corps d'opérations épinglés restent identiques. Le login, le moteur d'authentification, les primitives de démarrage corrigées, les DLL et le lanceur EXE sont conservés. Le lanceur n'a pas été recompilé ni signé ; le moteur et le manifeste annoncent RC1.10.7.

Le changement est centré sur la sélection et la disponibilité des fiches. Il ne clôture pas les autres points encore partiels de l'audit M01-M42, ne certifie pas la recherche inverse sur le domaine et n'ajoute pas un correctif de premier plan Windows.

## Distribution

```
prod/
  Domenia.exe
  wad/
    Domenia-Core.ps1
    Domenia-Modules.ps1
    modules/Domenia-Selection.UI.ps1
    ... autres composants nécessaires ...
    Support/DEBLOQUER_TOUT.cmd

dev/
  Domenia.exe
  INSTALLER-MISE-A-JOUR.ps1
  TESTER-PRECHARGEMENT.cmd
  ... outils et tests ...
  wad/  (même runtime que PROD)
```

PROD n'utilise ni les tests ni les aperçus DEV au lancement. Le script de déblocage reste dans `wad/Support`, et ne désactive aucune politique Windows.

## Installation existante

Terminer les opérations en cours et fermer Domenia. Extraire DEV dans un dossier distinct, non imbriqué dans l'installation. Depuis le nouveau dossier `dev` :

```powershell
# Adapter au dossier qui contient actuellement Domenia.exe et wad.
.\INSTALLER-MISE-A-JOUR.ps1 -Destination 'C:\Outils\Domenia' -WhatIf
.\INSTALLER-MISE-A-JOUR.ps1 -Destination 'C:\Outils\Domenia'
```

L'installateur garde les configurations et `wad/data`, ne remplace pas `%LOCALAPPDATA%\Domenia\Data`, sauvegarde le code remplacé et utilise le verrou de cycle de vie existant. Le retour arrière du code reste disponible avec `-RestoreBackup` et le chemin de sauvegarde affiché. Les données ne sont pas supprimées ou remplacées lors de cette restauration.

Installer le module, le chargeur, le cœur et le manifeste ensemble. Ne pas modifier un PS1 isolé dans une distribution dont l'intégrité est contrôlée.

## Contrôles : bien distinguer les niveaux

**Effectivement exécuté sur l'hôte Linux** : vérifications de source et de raccordement des événements ; comparaison des fonctions sensibles et des opérations avec RC1.10.6 ; validation XML du XAML ; conformité entre les exports du chargeur et les fonctions des modules ; contrôle lexical approximatif des PS1 ; relecture indépendante des ZIP, CRC et SHA-256 ; comparaison binaire de PROD/DEV.

Le vérificateur portable détecte le défaut de branchement précédent et refuse une construction sans le module de sélection ou avec des contrats worker désynchronisés. Ce n'est ni le parseur natif de PowerShell, ni une exécution de WPF ou du domaine.

**Fourni mais non exécuté ici** : `TESTER-PRECHARGEMENT.cmd`. Il demande Windows PowerShell 5.1 x64/STA, parse tous les scripts de fonctionnement, importe le véritable chargeur dans une session vierge, parse les corps de workers, charge le vrai XAML clair/sombre et exerce les règles de sélection sur des fixtures. Les appels AD/CIM y sont remplacés par des doubles. Le véritable gestionnaire SelectionChanged est récupéré par AST et exercé sur une DataGrid WPF. Les wrappers de Fiche/Assistance sont également testés sur les vrais contrôles.

L'installateur exécute cette suite **avant le remplacement**. Un rapport incomplet, ignoré ou en échec bloque l'installation. Les suites historiques restent dans DEV, mais certaines imposent l'ancienne navigation et ne sont plus le critère de publication de cette interface. Elles ne sont ni supprimées ni annoncées réussies ; le nouveau contrôle couvre le parseur runtime, le chargeur, les contrats worker et le parcours de sélection courant. Il ne remplace pas une recette de toutes les opérations métier.

**Non exécuté ici** : Windows PowerShell 5.1, WPF, EXE Windows, authentification, lectures AD/CIM, mesure de latence sur le parc. La récupération du parseur PowerShell depuis les dépôts Microsoft a échoué par manque de résolution réseau dans l'environnement de préparation. Aucun temps de réponse chiffré ou test Windows réussi n'est annoncé.

## Recette à réaliser sur un poste autorisé

1. Exécuter `TESTER-PRECHARGEMENT.cmd`, conserver le chemin du rapport qu'il affiche.
2. Rechercher un utilisateur et faire un seul clic : rester dans Recherche, ouvrir Fiche depuis le menu, vérifier que le nom reçu correspond à la sélection.
3. Faire de même avec une machine : Fiche et Assistance poste doivent être disponibles sans double-clic. Aucune autre machine de la liste ne doit être sondée.
4. Double-cliquer pendant une lecture lente puis après sa fin : une seule demande `OpenAdObject` doit figurer pour cette sélection, hors actualisation volontaire.
5. Cliquer A puis B rapidement, changer de page pendant la lecture, essayer une machine sans droits : pas de retour automatique dans Fiche, pas de données de A dans B, erreur explicite et relance volontaire seulement.
6. Tester sélection multiple, brouillon non enregistré, cache ancien et lecture interrompue. Les modifications AD restent soumises à lecture fraîche, droits, confirmations et vérifications existantes.
