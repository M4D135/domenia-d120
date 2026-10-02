# ADCC 1.0 R1.10 : interface compacte et connexion simplifiée

Build : `2026.09.30-R1.10-COMPACT`.
Base : le pack complet R1.9 présent dans cette conversation, qui intègre le `dev.zip` et le filtre OU.

## Les changements visibles

### Menu gauche repliable

Le bouton **Réduire le menu**, sous le logo, remplace la barre de 204 unités WPF par un rail de 68 unités. Les icônes sont centrées ; les libellés et le pied de menu sont masqués sans supprimer les destinations. Le même bouton redéploie le menu. Les aides au survol, les noms accessibles, la sélection courante et les indisponibilités restent en place.

Le repli ne sélectionne pas une autre rubrique, ne relance pas une recherche et ne change aucun droit. Le choix est enregistré dans les préférences existantes, avec une sauvegarde immédiate.

### Aide droite rétractable

Un bouton **›** figure dans l’en-tête de l’aide. Il ferme le panneau et libère sa colonne ainsi que la marge qui la séparait du contenu. Le bouton **?** du bandeau permet de le rouvrir.

En largeur suffisante, l’aide utilise une colonne de 300 unités ; sur une fenêtre étroite, elle s’ouvre en superposition sans imposer cette largeur aux résultats. Un choix volontaire de fermeture s’applique aux deux dispositions : redimensionner la fenêtre ne doit pas le défaire. Les préférences du panneau et du rail sont désormais présentes dans la liste des réglages effectivement rechargés au démarrage.

Les infobulles continuent de fonctionner quand l’aide est fermée. Si le focus clavier était dans l’aide à sa fermeture, il revient au bouton du bandeau.

### Filtre OU plus lisible

La carte de gauche présente un encadré **PÉRIMÈTRE SÉLECTIONNÉ** : nom de la branche, puis chemin simplifié. Le chemin entier reste disponible au survol.

Le DN exact n’est plus coincé dans une zone de 54 unités de hauteur sous la case à cocher. **Voir le chemin LDAP** le déplie dans une zone alignée en haut, à hauteur adaptative avec défilement si nécessaire, et propose **Copier le chemin**. Déplier ou copier ce texte ne lance aucune recherche.

L’arbre conserve son espace propre. Son état de chargement est déplacé sous l’arbre, au lieu de se mêler au périmètre sélectionné. La séparation arbre/résultats reste redimensionnable.

La ligne au-dessus des résultats indique le nom court de l’OU et la profondeur. Le DN de la requête reste inchangé : le chemin lisible est uniquement une présentation, jamais une reconstruction utilisée comme racine LDAP.

### Répartition de l’espace

La recherche du bandeau est alignée avec le contenu et utilise la largeur disponible. Le titre, le domaine et les réglages de protection sont réunis sur une zone plus compacte. Un message d’activité vide ne réserve plus une ligne supplémentaire.

Les filtres gardent des libellés visibles ; leur hauteur et la ligne des actions sont harmonisées. Les zones qui ont besoin de lecture, notamment la sélection OU et les descriptions, disposent d’espacements réguliers.

### Connexion inspirée de la référence RBP

Le login standard reprend une disposition courte : titre à gauche avec un petit bloc AD, **Compte Windows**, **Mot de passe**, mémorisation du seul identifiant, **Annuler / Se connecter**, puis **Utiliser mon compte Windows** sur une ligne complète.

Le grand bandeau bleu d’avertissement et la grande zone de diagnostic vide ne sont plus affichés. Les diagnostics existent toujours sous **Aide à la connexion**, replié par défaut. Les messages de progression et d’erreur apparaissent quand ils sont utiles ; les textes longs restent défilables, pas coupés dans une ligne fixe.

La fenêtre standard ne peut pas être maximisée. Elle adapte sa hauteur à son contenu, avec une limite liée à la zone de travail de l’écran. Les champs et boutons suivent les ressources des thèmes clair et sombre. Le mode de connexion Debug reste disponible et son XAML n’a pas été remplacé.

## Ce qui est conservé

Les contrôles nommés de la fenêtre principale et du login restent présents. Seules cinq fonctions existantes du cœur changent : le XAML principal, le XAML du login standard, la liste des préférences, le rendu du périmètre et un raccordement de présentation de la fenêtre de connexion. Les 568 autres fonctions de R1.9 restent identiques après normalisation des fins de ligne.

Le moteur de validation, les identifiants transmis aux workers, la recherche LDAP, ses 45 opérations vérifiées par empreinte, le rejet des résultats tardifs, les écritures AD, les confirmations, les modules métier de l’Atelier et les binaires restent conservés. Cette livraison ne prétend pas corriger ou valider un accès AD par une simple modification du login.

## Installation sans perdre les données

Fermer ADCC après la fin de ses opérations. Extraire le nouveau ZIP dans un dossier distinct, puis ouvrir Windows PowerShell dans ce nouveau dossier ADCC :

```powershell
# Remplacer le chemin par votre dossier ADCC actuel.
.\INSTALLER-MISE-A-JOUR.ps1 -Destination 'C:\Outils\ADCC' -WhatIf
.\INSTALLER-MISE-A-JOUR.ps1 -Destination 'C:\Outils\ADCC'
```

Ne pas supprimer l’ancien dossier. Ce paquet ne contient pas votre base personnelle. L’installateur conserve `wad\data` et les configurations existantes, et sauvegarde le code remplacé. Les modules et le manifeste doivent être copiés avec le cœur : ne pas remplacer seulement `ADCC-Core.ps1`.

Les suites natives et l’intégrité sont vérifiées avant la copie. Une validation native en échec arrête l’installation ; le rapport temporaire indiqué doit alors être conservé pour analyse. Le retour arrière existant reste accessible par `-RestoreBackup` avec le chemin exact de la sauvegarde indiqué par l’installateur.

Pour une installation neuve : extraire tout le dossier, garder `wad` à côté des lanceurs, puis lancer `LANCER-ADCC.cmd`.

## Aperçus locaux et tests

- **APERCU-INTERFACE.cmd** : vrai XAML principal avec données fictives, sans accès AD.
- **APERCU-CONNEXION.cmd** : vrai XAML du login standard, marqué aperçu local ; aucune authentification n’est lancée.
- **TESTER-INTERFACE.cmd** : recette WPF, complétée par neuf contrôles du rail, de l’aide et du périmètre OU.
- **TESTER-ERGONOMIE.cmd** : 22 scénarios isolés de présentation, de chemins avec caractères échappés et de préférences.

Les 18 contrôles WPF du nouveau login, neuf en clair et neuf en sombre, peuvent être lancés explicitement :

```powershell
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass `
  -File .\wad\maintenance\Preview-AdccLogin.ps1 -Verify
```

Pour enregistrer les rendus locaux du principal ouvert/replié et du login :

```powershell
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass `
  -File .\wad\maintenance\Preview-AdccUi.ps1 `
  -CaptureDirectory "$env:TEMP\ADCC-R1.10-Apercus"

powershell.exe -NoProfile -STA -ExecutionPolicy Bypass `
  -File .\wad\maintenance\Preview-AdccLogin.ps1 `
  -CaptureDirectory "$env:TEMP\ADCC-R1.10-Apercus"
```

Ces images sont des rendus WPF locaux de démonstration, pas des données de votre domaine. Aucune capture WPF n’a été produite dans l’environnement de préparation.

## Vérification effectuée ici et limites

L’audit `wad\docs\AUDIT-ERGONOMIE-R1.10.json` consigne les vérifications réalisées sous Linux/Python : XML, noms et ressources, contrôles conservés, différences de fonctions, empreintes des binaires et des workers, présence des aides, chargement des préférences et contrastes calculés. Les analyses lexicales approximatives ne remplacent pas le parseur natif PowerShell.

**Non exécutés ici : PowerShell, Windows PowerShell 5.1, rendu WPF et accès réel au domaine.** Les 22 tests isolés et 27 nouveaux contrôles WPF sont fournis pour une validation Windows, non annoncés comme réussis. Les rapports des versions précédentes restent historiques ; ils ne constituent pas une validation de cette livraison.

Avant usage normal, vérifier en clair et sombre : replier/redéployer les deux panneaux, fermer et relancer pour contrôler les préférences, sélectionner une OU au nom long, déplier son DN, puis vérifier une connexion normale avec les identifiants habituels. Les références Microsoft utilisées pour le comportement de disposition sont `System.Windows.Visibility` et `Window.SizeToContent` ; elles ne remplacent pas un test visuel sur le poste.
