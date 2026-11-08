# Domenia 1.0

Administration Active Directory, inventaire local et tableaux de bord pour Windows.
Cible : Windows PowerShell 5.1 x64, WPF et .NET Framework 4.7.2 ou ultérieur.
Lancez `Domenia.exe` après avoir extrait entièrement le pack dans un dossier local.

Guides dans la livraison : `DOC/Domenia-1.0-Guide-technicien` et
`DOC/Domenia-1.0-Guide-administrateur`, chacun en DOCX et PDF.

## Les deux packs

- **PROD** : `Domenia.exe` et le dossier `wad`, avec les composants nécessaires à l'application.
- **DEV** : le même runtime, les sources, les outils de fabrication, les tests et la documentation technique.

Le dossier `wad` reste un dossier ordinaire. Gardez ensemble le lanceur, ce dossier, ses modules
et son manifeste. Si Windows bloque les fichiers téléchargés, utilisez
`wad\Support\DEBLOQUER_TOUT.cmd` après avoir vérifié leur provenance.

## Recherche, base et tableaux de bord

La base locale conserve les objets recensés dans le périmètre choisi. La recherche, la consultation
de la base et les tableaux de bord disposent de leur sélection de périmètre : contrôlez l'OU affichée
avant de comparer des compteurs. Un poste désactivé reste recensé ; la collecte du périmètre dans
l'Atelier retient ses comptes actifs. Les actions sur une liste ou un poste annoncent leurs propres cibles.

Les tableaux de bord présentent les mesures disponibles, leur fraîcheur et leur couverture. La petite
icône près du crayon d'un indicateur ouvre ses postes dans une page dédiée de l'atelier de requêtes.
Les clics sur les cartes et les segments laissent le tableau affiché. L'atelier sert à filtrer les données
locales, enregistrer des requêtes et alimenter des widgets dans le tableau général ou celui du poste.
Sa bibliothèque propose 152 modèles dans 14 catégories et ses 105 champs sont décrits dans le catalogue.
La même recette peut aussi filtrer Rechercher. Les résultats sont paginés :
le nombre total concerne le filtre complet, même si une page n'affiche qu'une partie des objets.

La mise à jour de l'index et la collecte des postes sont distinctes. L'index lit les objets de l'annuaire ;
la collecte récupère les observations distantes. La progression précise le périmètre, la phase, les éléments
traités et les erreurs. Une collecte partielle ne doit pas être interprétée comme un inventaire complet.
Une donnée absente ou périmée reste signalée comme telle.

Dans **Outils > Base autonome**, choisissez une OU, puis **Mise à jour > Mettre à jour lʼOU choisie** :
l’OU et ses sous-OU sont relues, les autres branches sont conservées. Sans OU choisie, le sélecteur
s’ouvre. Le sélecteur présente un arbre des OU classées par nom, avec un champ de recherche. **Données** affiche les objets de ce périmètre ; **Stockage**
regroupe l’emplacement, les sauvegardes, la mesure et la purge volontaire de la base entière. La fraîcheur distingue la
lecture complète qui couvre l’OU des tentatives partielles. Ces lectures ne modifient pas Active Directory.

Le **Zoom**, en bas de la fenêtre, règle l’interface de 80 à 150 %. Cliquez sur le pourcentage pour
revenir à 100 % ; le choix est conservé au prochain démarrage.

Dans **Rechercher**, les actions **Pinger la liste**, **Détecter la liste** et **Analyser la liste**
portent sur la sélection annoncée au clic. Vérifiez la confirmation avant lancement. La détection concerne
l'utilisateur de la console, pas les sessions RDP. Une absence de réponse n'efface pas le dernier utilisateur
connu ; les associations manuelles et importées restent protégées.

## Refaire un PROD après modification

Le DEV contient un outil autonome de fabrication. Il utilise Windows PowerShell 5.1 déjà présent
sur Windows ; aucun Python, téléchargement ou compilateur n'est requis.

1. Modifiez les sources dans le dossier `wad` du DEV. Si vous modifiez du C#, compilez d'abord la DLL
   correspondante : cet outil assemble des composants déjà construits.
2. Double-cliquez sur **`FABRIQUER_PROD.cmd`**. Un dossier `prod-AAAAMMJJ-HHMMSS-identifiant` est créé
   à côté du DEV. Le chemin complet est affiché à la fin.
3. Contrôlez le fonctionnement de vos modifications sur le poste Windows prévu avant diffusion.

Pour choisir les chemins :

```powershell
.\tools\Fabriquer-Prod.ps1 -SourceWad 'D:\Sources\wad' -OutputDirectory 'D:\Livraisons\prod'
```

Le dossier source doit être un `wad` complet, comprenant les scripts de démarrage, modules, DLL,
ressources, configuration et dossier `Support`. `-LauncherPath` permet de choisir le `Domenia.exe`
à placer dans la livraison ; par défaut, celui du DEV est utilisé.
Un module PowerShell ajouté dans `wad/modules` doit être déclaré dans
`Get-DomeniaRuntimeModulePlan` de `Domenia-Modules.ps1` ; les fichiers voisins ne sont jamais chargés automatiquement.

La préparation se fait dans une copie temporaire. Elle régénère le worker de migration, les exports
chargés par module, les empreintes des DLL et des opérations worker, le registre des opérations et les
manifestes. Les scripts de l'application sont analysés sans être exécutés. Les tests, bases locales,
sauvegardes et journaux sont exclus de PROD. Les sources ne sont pas modifiées.

Un dossier de sortie existant est refusé. En cas d'erreur, aucun PROD partiel n'est publié et la copie
temporaire est supprimée. Le mode démonstration, les fichiers manquants, les scripts ou JSON invalides,
les chemins redirigés et les noms ambigus bloquent la fabrication. Une source signée doit être reconstruite
à partir de sa version non signée, puis la distribution peut être signée après fabrication.

La vérification du pack prouve sa cohérence et ses empreintes ; elle ne remplace pas la validation
fonctionnelle Windows de vos modifications. La livraison fabriquée porte le statut de build local à valider.

## Installer ou mettre à jour

Fermez Domenia après la fin des opérations et conservez une sauvegarde de ses données. Extrayez le pack
dans un dossier distinct, puis lancez l'installateur livré dans `wad\Support` :

```powershell
.\wad\Support\INSTALLER-MISE-A-JOUR.ps1 -Destination 'C:\Domenia' -WhatIf
.\wad\Support\INSTALLER-MISE-A-JOUR.ps1 -Destination 'C:\Domenia'
```

L'installateur vérifie la livraison et prépare une copie, contrôle son démarrage avec `-CheckOnly`,
présente les fichiers à installer et demande confirmation. Il sauvegarde le code, verrouille le lancement,
remplace les composants et contrôle le résultat avant activation. Les données et préférences existantes
sont conservées. Il ne lance aucune suite de tests sur le poste.

Pour une première installation :

```powershell
.\wad\Support\INSTALLER-MISE-A-JOUR.ps1 -Install -Destination 'C:\Domenia'
```

Les raccourcis Bureau et menu Démarrer sont proposés. Les codes de sortie sont : `0`, opération réussie
ou aperçu `-WhatIf` ; `1`, erreur ; `2`, installation non effectuée. Pour une installation sans question,
utilisez `-Confirm:$false` et choisissez explicitement `-Shortcuts Oui` ou `-Shortcuts Non`.

Les chemins relatifs sont résolus depuis le dossier courant de PowerShell. Un rapport de qualification
peut être fourni avec `-Package` et `-QualificationReport`. Un rapport fourni mais refusé arrête
l'installation. `-RequireQualification` exige une preuve valable liée aux archives.

## Restaurer le code

En cas d'interruption, le lancement reste verrouillé et le contrôle de démarrage indique la commande
de restauration. La dernière sauvegarde de code peut être restaurée ainsi :

```powershell
.\wad\Support\INSTALLER-MISE-A-JOUR.ps1 -RestoreLatest -Destination 'C:\Domenia'
.\wad\Support\INSTALLER-MISE-A-JOUR.ps1 -RestoreBackup 'C:\Domenia\wad\maintenance\backups\DOSSIER'
```

La restauration vérifie les empreintes et refuse d'écraser un fichier modifié indépendamment.
Elle ne restaure pas les données métier : conservez aussi leurs sauvegardes. L'installateur garde
les cinq dernières sauvegardes complètes de code.

## Vérifier et signer

Dans le DEV, `VERIFIER-PACK.cmd` contrôle les fichiers et empreintes du manifeste. La vérification
de signature distingue l'intégrité des fichiers et l'identité de l'éditeur ; elle est hors ligne,
sans accès réseau ni contrôle de révocation.

La signature des scripts est disponible avec `tools\Signer-Distribution.ps1` sur une copie préparée.
Les composants tiers et le lanceur sont contrôlés selon leurs empreintes épinglées. Les JSON, XAML,
fichiers de configuration et autres formats non signables par Authenticode peuvent être couverts par
un catalogue signé du manifeste. `-RequireSignature` et `-RequireSignedManifest` permettent d'exiger
ces protections lors du contrôle. Consultez le guide administrateur pour la procédure complète.

## Portée des contrôles

Les contrôles de fabrication vérifient la syntaxe, les contrats internes, les manifestes, les empreintes
et le contenu des packs. La qualification de l'interface WPF, des permissions et des opérations AD réelles
sur Windows reste distincte. Un rapport valide doit désigner les fichiers exacts de la livraison examinée.
