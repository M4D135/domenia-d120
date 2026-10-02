# Domenia 1.0 RC1.5 : démarrage et connexion FILPRO

Build du moteur : `2026.10.01-DOMENIA-1.0-RC1.5-BOOTLOGIN`.
Base de travail : les packs originaux Domenia RC1.4 fournis dans cette conversation. Cette correction ne remplace pas les fonctions de recherche, de sélection ou d’authentification par celles de FILPRO.

## 1. Erreur « Registre worker incomplet : 55/54 »

Le registre de RC1.4 contient 55 opérations, comme son contrat de développement. L’opération supplémentaire par rapport à RC1.3 est `LiveSelectedPing`, utilisée pour le ping à la sélection. Le corps `Initialize-AsyncEngine` continuait à exiger un nombre égal à 54, puis affichait un message fixe mentionnant 54. La capture correspond exactement à cette incohérence. Ce blocage interne n’est pas un refus de compte AD ou de permission Windows.

La correction conserve les 55 noms et les 55 empreintes des opérations de RC1.4. Elle ne retire ni le nouveau ping, ni les contrôles d’intégrité. Le démarrage appelle maintenant `Assert-DomeniaWorkerRegistry` :

- registre non nul et non vide ;
- identifiants et empreintes SHA-256 de forme valide ;
- tri ordinal des couples identifiant/empreinte ;
- comparaison de l’empreinte de l’ensemble avec la valeur épinglée pour cette livraison.

Retirer une opération, ajouter une entrée, remplacer un nom en conservant le même nombre ou modifier une empreinte fait échouer ce contrôle. L’ordre de déclaration n’a pas d’effet. Le message de démarrage affiche le nombre réellement validé, non un autre nombre recopié à la main.

La vérification du corps exact de chaque opération au moment de son envoi est conservée. Le contrôle local d’empreintes ne constitue toujours pas une signature d’éditeur et ne remplace pas les protections du dossier ou les politiques de sécurité de l’organisation.

L’outil DEV `tools/update_worker_contracts.py` vérifie désormais aussi cette empreinte globale. Seul son mode explicite `--apply`, destiné à une modification de code revue, la régénère. L’application n’apprend pas automatiquement de nouvelles empreintes. Le constructeur des packs appelle ce contrôle avant de créer les manifestes.

## 2. Connexion reprise de FILPRO

La référence utilisée est l’archive **FILPRO_2.5.0_RC1_DEV.zip**, retrouvée dans la bibliothèque, et ses deux vrais fichiers :

- `DEV/wad/ui/Login.xaml` ;
- `DEV/wad/ui/Controls.xaml`.

La fenêtre est adaptée depuis ce XAML, plutôt que redessinée à partir d’une capture. Douze styles du dictionnaire sont repris, avec remplacement des noms des ressources de couleur par les ressources de thème déjà utilisées par Domenia. Ils sont limités à la fenêtre de connexion et n’altèrent pas le style de la fenêtre principale.

La présentation conserve la largeur de 480 unités WPF, le badge de 42 unités, la carte avec marge de 16 et remplissage de 20, les champs d’au moins 40 unités, le titre à gauche, la mémorisation du seul identifiant, Annuler et Se connecter côte à côte, puis Utiliser mon compte Windows sur la largeur. La case à cocher et les boutons reprennent également leurs modèles FILPRO. La fenêtre ne peut pas être maximisée.

Le titre devient **Connexion à Domenia**, le badge **D**, et le sous-titre indique le compte Active Directory. Les aides décrivent les actions réelles de Domenia : l’écran n’annonce pas les opérations de profils ou l’UAC de FILPRO.

La zone des champs est défilante séparément des boutons. Les erreurs/progressions sont bornées en hauteur. Les commandes Ouvrir le journal et Copier le diagnostic restent dans « Aide à la connexion », replié par défaut et masqué lorsque la connexion n’affiche aucun message ni activité. Le contrôle de mot de passe visible historique reste masqué dans le login standard.

Le choix clair/sombre, Verr. Maj et la mémorisation des réglages utilisent les fonctions Domenia existantes. Les palettes du login restent cohérentes avec le chargement et la fenêtre principale. **Aucun moteur d’authentification, relais UAC, identifiant ou préférence FILPRO n’est importé.** Le changement du thème ne demande pas une nouvelle validation de compte.

Les références et leur empreinte sont conservées dans le dossier DEV `wad/docs/reference-filpro` et `RC1.5-FILPRO-reference.json`. Ces fichiers ne sont pas requis et ne sont pas livrés en production.

## 3. Périmètre exact

Quatre fonctions existantes du cœur changent : `Initialize-AsyncEngine`, `Get-DomeniaStandardLoginXaml`, le libellé de version de `Initialize-DomeniaPresentation`, et le message de compteur de `Invoke-DomeniaSelfTest`. Une fonction de contrôle du registre est ajoutée. Les 572 autres fonctions principales de RC1.4 restent identiques après normalisation des fins de ligne.

Dans les modules, seule la fonction de disposition de la connexion est ajustée pour limiter aussi la largeur à l’espace de travail. Le nombre et la liste des fonctions à importer ne changent pas. Le chargeur de modules et les correctifs ACL restent conservés.

Le login métier `Show-LoginWindow`, la validation des comptes, les écritures, les 55 opérations, la recherche globale, le filtre OU, le ping uniquement à la sélection, le double-clic pour ouvrir une fiche, les observations en cache, les colonnes et la restauration OU sont conservés.

Le lanceur `Domenia.exe`, les DLL et les configurations livrées ont les mêmes octets que RC1.4. La version des ressources de l’ancien lanceur ne remplace pas la version RC1.5 annoncée par le moteur dans ses journaux. L’exécutable reste non signé.

## 4. Livraisons et installation

```text
prod/
├── Domenia.exe
└── wad/
    ├── [moteur et composants nécessaires]
    └── Support/
        └── DEBLOQUER_TOUT.cmd

dev/
├── Domenia.exe
├── INSTALLER-MISE-A-JOUR.ps1
├── TESTER-DEMARRAGE-LOGIN.cmd
├── [autres outils DEV]
└── wad/
    ├── [même runtime que PROD]
    ├── Support/DEBLOQUER_TOUT.cmd
    └── [tests et documentation]
```

Aucun test, document ou aperçu DEV n’est requis au lancement de PROD. Le script de déblocage conserve son fonctionnement et ne neutralise aucune protection Windows.

### Installation existante

Fermer Domenia après la fin des opérations. Extraire DEV dans un dossier distinct, non imbriqué dans l’installation, puis exécuter depuis ce nouveau dossier `dev` :

```powershell
# Adapter la destination au dossier contenant réellement Domenia.exe et wad.
.\INSTALLER-MISE-A-JOUR.ps1 -Destination 'C:\Outils\Domenia' -WhatIf
.\INSTALLER-MISE-A-JOUR.ps1 -Destination 'C:\Outils\Domenia'
```

Ne pas supprimer l’installation ni sa base. L’installateur conserve les configurations et `wad/data`, ne remplace pas `%LOCALAPPDATA%\Domenia\Data`, sauvegarde le code remplacé et garde son verrou de cycle de vie. Le nouveau moteur et les empreintes des manifestes doivent rester ensemble : ne pas modifier manuellement 54 en 55 dans un fichier déjà installé.

L’installateur lance la nouvelle suite native avant les suites existantes et avant la copie. Un résultat incomplet ou en échec bloque l’installation ; conserver son rapport plutôt que supprimer le contrôle. Le retour arrière existant reste disponible avec `-RestoreBackup` et le chemin exact de la sauvegarde indiqué par l’installateur.

### Installation neuve ou aperçu

Extraire entièrement PROD pour obtenir `Domenia.exe` et `wad`. Aucune base personnelle n’est fournie.

DEV contient `APERCU-CONNEXION.cmd`, qui ouvre les vrais contrôles du nouveau login sans authentifier un compte. Les données sont fictives et les actions métier ne sont pas branchées. Cet aperçu ne valide pas la connexion au domaine.

## 5. Vérifications réalisées et limites

**Exécuté dans cet environnement Linux :** 209 contrôles portables généraux, et 200 contrôles ciblés de source, structure XML, comparaison aux modèles FILPRO et empreintes. Les essais SQL de l’audit général utilisent réellement SQLite via Python. Les scripts Python de construction et d’audit ont aussi été compilés syntaxiquement.

La nouvelle vérification comprend la cause numérique de l’ancienne condition, l’empreinte réelle du registre, des modifications contrôlées de la recette de calcul en Python, la conservation de chaque corps d’opération, l’absence du compteur obsolète dans l’initialiseur et l’égalité structurelle des douze styles importés.

**Cela n’est pas une exécution de PowerShell ou de WPF.** Les vérifications lexicales ne valent pas le parseur natif. La compilation C du lanceur n’a pas été refaite puisqu’il ne change pas. Aucun compte, poste ou domaine réel n’a été interrogé. Le rendu de la connexion n’a pas été exécuté ni photographié sous Windows ici.

**Fourni pour Windows :** `TESTER-DEMARRAGE-LOGIN.cmd` lance 44 scénarios avec Windows PowerShell 5.1 x64 STA. Le test extrait les vraies fonctions par AST, vérifie tous les corps d’opération sans les exécuter, reproduit l’ancien initialiseur 55/54, appelle l’initialiseur corrigé avec un vrai DispatcherTimer et des services doublés en mémoire, puis charge le vrai XAML clair et sombre. Il vérifie également les hôtes de saisie, le thème, les champs conservés, les messages longs, les boutons hors de la zone de défilement et une hauteur contrainte.

Ces 44 scénarios sont **écrits mais non exécutés dans cet environnement**. Le rapport doit contenir 44 résultats, aucun échec ni scénario ignoré. Les anciennes suites et rapports restent historiques, avec leurs versions respectives.

Les deux archives sont contrôlées après création : CRC, chemins Windows uniques, taille et SHA-256 de chaque fichier déclaré, correspondance exacte entre contenu et manifeste, structure PROD minimale et runtime identique entre PROD/DEV. Le rapport de livraison fournit les résultats et les SHA-256 des ZIP.

### Recette sur le poste

Lancer le nouveau test sur DEV, puis examiner `APERCU-CONNEXION.cmd`. Après mise à jour, faire une connexion normale et vérifier dans le journal : moteur RC1.5, registre de **55 opérations vérifiées**, puis ouverture du principal. Contrôler les deux thèmes, un refus volontaire de connexion sur un compte de test, l’accès au diagnostic et les échelles d’affichage du poste. Une erreur ultérieure distincte doit être analysée à partir de sa propre trace, pas assimilée à l’ancienne condition 55/54.
