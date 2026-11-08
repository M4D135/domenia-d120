# Domenia 1.0 RC1.2 : correction des imports au démarrage

**Build : `2026.10.01-DOMENIA-1.0-RC1.2-MODULES`**  
Base : archives PROD et DEV Domenia RC1.1 de cette conversation.

## Défaut identifié

La capture affiche une `CommandNotFoundException` pour `Initialize-DomeniaReconcile` pendant l'initialisation de la fenêtre principale. Dans le pack RC1.1, cette fonction est bien définie dans `wad/modules/Domenia-Reconcile.UI.ps1`, mais ce fichier n'est pas chargé par le point d'entrée de `Domenia-Core.ps1` avant l'appel.

Le même examen du graphe des imports montre deux autres fichiers livrés sans être chargés : `Domenia-Dossier.Model.ps1` et `Domenia-Dossier.UI.ps1`. Leurs fonctions sont utilisées par les captures et le dossier technique. Ces oublis constituent des défauts du pack fourni, pas la preuve d'un mauvais mot de passe ou d'un refus de droits AD.

La présence d'un script sur le disque et sa conformité au manifeste ne rendent pas ses fonctions disponibles dans la session. Les anciens contrôles de syntaxe et d'empreinte n'exerçaient pas ce raccordement. Aucun des anciens journaux ACL n'est utilisé comme preuve de cette nouvelle panne.

## Correction

- Ajout du point d'entrée de définitions `wad/Domenia-Modules.ps1`, partagé par le démarrage normal et le contrôle `Domenia.exe --check`.
- Liste fermée de **20 modules PowerShell**, dont 18 chargés directement et les deux dépendances Experience déjà chargées par UX. Pas de recherche automatique de plugins, pas de double import de ces dépendances.
- Les trois imports oubliés sont raccordés. La liste déclare les **209 fonctions** attendues, vérifie leur présence et leur fichier d'origine après le chargement. Une ancienne fonction homonyme dans une portée parente ne doit pas cacher un oubli.
- Avant tout import, tous les fichiers déclarés doivent exister et passer le parseur PowerShell. Un fichier manquant, une erreur de syntaxe, un import en échec ou une fonction absente produit un message ciblant le module.
- Chargement par dot-sourcing dans la portée du programme, pas par une invocation dans une portée enfant qui perdrait les définitions à son retour.
- L'état du chargement progressif Live est initialisé avant le timer de réconciliation.
- Le contrôle de paquet reste autonome en PROD. Il importe réellement les définitions dans une portée temporaire, sans ouvrir la connexion, créer de fenêtre ou timer, contacter AD ou accéder au cache utilisateur.

La réconciliation n'est pas supprimée ou remplacée par une fonction vide pour laisser démarrer l'application. Les 20 modules existants, leurs fonctions et les 54 contrats d'opérations sont conservés byte pour byte. Seule la fonction de présentation du cœur change d'ordre d'initialisation ; les modifications du bloc principal raccordent le nouveau chargeur et actualisent le build.

## Périmètre préservé

Le correctif DACL de RC1.1 reste présent : ni audit/SACL, ni élévation automatique ajoutés. Les fonctions de connexion, la recherche LDAP, le cache, les secrets et les opérations distantes ne sont pas réécrits. `Domenia.exe`, les DLL, les C# natifs, la configuration fournie et le script de déblocage gardent leurs octets RC1.1. Les ressources de version du lanceur peuvent donc encore indiquer RC1 ; le build du moteur et le manifeste indiquent RC1.2.

Les limites fonctionnelles RC1/RC1.1 et le suivi M01–M42 restent applicables. Ce correctif de chargement ne certifie pas tous les parcours AD, toutes les mutations ou les performances sur le domaine.

## Installer

### Mise à jour d'une installation existante

Fermer Domenia après la fin des opérations actives. Extraire **DEV RC1.2 dans un dossier distinct**, puis exécuter depuis ce nouveau dossier :

```powershell
.\INSTALLER-MISE-A-JOUR.ps1 -Destination 'C:\Outils\Domenia' -WhatIf
.\INSTALLER-MISE-A-JOUR.ps1 -Destination 'C:\Outils\Domenia'
```

Adapter la destination au dossier qui contient `Domenia.exe` et `wad`. Ne pas lancer l'installateur depuis la destination ni imbriquer la source dedans. L'installateur utilise le manifeste PROD, sauvegarde le code remplacé et conserve les configurations existantes et `wad/data`. Il ne parcourt ni ne remplace les données `%LOCALAPPDATA%\Domenia\Data`.

Le fichier **Domenia-Modules.ps1 et le manifeste doivent être copiés avec le cœur**. Ne pas remplacer seulement `Domenia-Core.ps1` et ne pas modifier une empreinte manuellement pour contourner un refus d'intégrité.

Les tests natifs de modules, le cycle de vie WPF isolé, puis les suites Candidate et ACL sont lancés avant copie. Une suite en échec ou incomplète arrête la mise à jour. Conserver son rapport pour analyse, sans supprimer le contrôle. La restauration du code reste disponible avec `-RestoreBackup` et le chemin exact annoncé par l'installateur.

### Installation neuve / distribution

```text
prod/
  Domenia.exe
  wad/
    Domenia-Core.ps1
    Domenia-Start.ps1
    Domenia-Modules.ps1
    modules/...
    Support/DEBLOQUER_TOUT.cmd
    ...
```

Aucun fichier de démo ou de test n'est exigé en production. Le déblocage reste sous `wad/Support`. Il ne change pas les protections d'entreprise ni les droits AD. Les deux packs contiennent le même runtime de **41 fichiers**.

## Vérifications exécutées et limites

**Exécuté ici sous Linux/Python :** audit général actualisé, audit ciblé du graphe des imports, comparaison des fonctions et des modules avec le ZIP RC1.1, vérification des contrats des workers, essais SQLite préexistants et vérification indépendante des deux archives/manifeste.

L'audit statique confirme que les trois fichiers sont omis de l'ancien graphe et présents dans le nouveau. Il contrôle aussi que toutes les fonctions déclarées par le chargeur correspondent au source. Cela ne remplace pas l'exécution PowerShell de ces scripts.

**Non exécuté ici : PowerShell, Windows PowerShell 5.1, WPF, binaire Windows, authentification, LDAP, CIM et accès au domaine.** Aucune capture WPF ni succès d'authentification n'est revendiqué. Les analyses lexicales approximatives ne sont pas le parseur PowerShell natif.

## Nouvelle régression native à exécuter sous Windows

Lancer `TESTER-MODULES.cmd` dans DEV. La suite `wad/tests/Test-DomeniaModules.ps1` :

- utilise de nouvelles sessions PowerShell pour ne pas hériter de fonctions chargées par un test précédent ;
- reproduit l'ancien point d'entrée RC1.1 dans une copie temporaire sans la fonction Reconcile, puis teste le nouveau chargeur avec les mêmes modules ;
- teste les trois fichiers oubliés, l'absence d'une dépendance UX, la syntaxe, une fonction supprimée, une origine homonyme incorrecte, le mauvais opérateur d'invocation et un script supplémentaire non déclaré ;
- contrôle les fonctions des dossiers, les contrats de la réconciliation et des documents, et l'absence d'initialisation des composants actifs à l'import ;
- sous Windows/WPF, initialise le vrai timer Reconcile avec aucune recherche active, vérifie l'idempotence et l'arrêt lors de la fermeture d'une fenêtre temporaire. Aucune opération AD n'est autorisée dans ce scénario.

Une exécution sans WPF marque cette partie **Skipped**, jamais Passed. L'installateur Windows refuse un tel rapport incomplet. Le workflow Windows dans DEV lance également la suite ; aucun run de ce workflow n'a été déclenché dans cette livraison.

Après installation, vérifier `Domenia 1.0 RC1.2` dans les traces. Tester un lancement habituel, puis une petite OU connue. Les captures A/B et l'export technique ont maintenant leurs fonctions raccordées ; leur accès réel aux documents choisis reste à vérifier sur le poste de recette.

## Référence de langage

Microsoft PowerShell 5.1, *about_Scripts*, section « Script scope and dot sourcing » :
https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_scripts?view=powershell-5.1

Cette référence décrit la portée des fonctions. La cause concrète ci-dessus provient de la comparaison avec le pack RC1.1 fourni.
