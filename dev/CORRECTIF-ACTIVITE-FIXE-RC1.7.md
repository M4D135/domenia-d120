# Domenia 1.0 RC1.7 : emplacement fixe de l’activité

Build : `2026.10.01-DOMENIA-1.0-RC1.7-FIXEDACTIVITY`.
Base : archives PROD/DEV RC1.6 fournies dans cette conversation.

## Défaut trouvé

Dans le XAML principal de RC1.6, la deuxième ligne de `UxPageHeader` avait une hauteur `Auto`. Elle contenait un `WrapPanel` : le nom de tâche disparaissait lorsque son texte était vide, et `PbTop` / `BtnCancelTask` passaient de `Collapsed` à `Visible`. Au lancement d’une opération, cette ligne prenait de la hauteur et pouvait se replier lorsque le texte ou l’espace changeait. Le contenu placé en dessous était alors réarrangé. Les dimensions fixes des boutons Opérations et Accès ne corrigeaient pas cette autre cause.

## Correction dans le formulaire principal

- Une ligne de **44 unités WPF** est réservée sous le titre, au repos comme pendant une tâche. Sa hauteur minimale et maximale sont identiques.
- Une grille remplace le panneau qui se repliait. Ses emplacements sont indépendants : avertissement du mode écriture, texte d’activité, barre et Annuler.
- La barre occupe un emplacement de 130 × 8 unités ; Annuler conserve 96 × 32 unités.
- Les indicateurs passent à `Hidden` au repos : ils ne se voient pas et ne reçoivent pas de clic, mais leur place reste réservée. Le conteneur et sa ligne ne sont jamais retirés.
- Le texte d’activité est sur une seule ligne, de hauteur bornée, avec des points de suspension. Le texte complet reste consultable au survol. Un long nom de tâche ou plusieurs chiffres de durée ne demandent plus de hauteur supplémentaire.
- L’animation indéterminée est activée seulement pendant une opération. Elle n’est pas un pourcentage d’avancement.
- L’avertissement rouge du mode écriture garde son propre emplacement. Il n’est ni supprimé ni utilisé pour autoriser une action.

Une petite bande reste donc réservée même au repos : c’est volontaire. Redimensionner la fenêtre, réduire le menu ou ouvrir l’aide reste un changement de disposition demandé par l’opérateur. Ce correctif vise les déplacements provoqués par l’activité, pas l’interdiction de redimensionner l’application.

## Ce qui ne change pas

Le login FILPRO sans mini-journal, sa carte d’attente et la fenêtre de chargement après connexion sont identiques à RC1.6. Le correctif porte sur `PbTop` du **formulaire principal**.

Les 577 fonctions principales restent présentes. Seuls `Get-MainXaml`, `Update-TaskUi` et le libellé de build dans `Initialize-DomeniaPresentation` changent. Les 574 autres fonctions, les modules PowerShell et le chargeur, les 55 opérations et leurs empreintes, le planificateur, les droits, l’annulation, les moteurs AD/CIM, les préférences et les schémas de cache restent conservés.

Le catalogue d’aide ajuste seulement le texte d’Annuler pour préciser qu’il s’agit d’une demande d’arrêt de lecture, pas d’une interruption forcée. Les EXE/DLL sont inchangés ; le lanceur n’a pas été recompilé. Le build du moteur est RC1.7, indépendamment des anciennes ressources de version de l’EXE.

## Distribution et mise à jour

Les dossiers des archives sont `prod` et `dev`. À la racine PROD : **Domenia.exe + wad seulement**. `DEBLOQUER_TOUT.cmd` reste dans `wad/Support`, sans dépendance à un fichier de démonstration ou de test.

Terminer les opérations actives et fermer Domenia. Extraire DEV dans un dossier distinct, puis exécuter depuis ce dossier :

```powershell
# Adapter au dossier qui contient actuellement Domenia.exe et wad.
.\INSTALLER-MISE-A-JOUR.ps1 -Destination 'C:\Outils\Domenia' -WhatIf
.\INSTALLER-MISE-A-JOUR.ps1 -Destination 'C:\Outils\Domenia'
```

Ne pas supprimer l’installation, les configurations, la base ou les reçus. L’installateur conserve les données et configurations existantes ; il sauvegarde le code remplacé, utilise le verrou de cycle de vie existant et installe les fichiers avec leur manifeste. Il ne remplace pas `%LOCALAPPDATA%\Domenia\Data`. Aucune donnée personnelle n’est fournie dans les ZIP.

La nouvelle suite de disposition est exécutée avant toute copie, puis les suites précédentes restent en place. Une erreur ou un résultat incomplet arrête la mise à jour. Le mécanisme existant `-RestoreBackup` reste disponible avec le chemin de sauvegarde indiqué par l’installateur.

## Aperçu et tests

**APERCU-ACTIVITE.cmd** charge le vrai XAML et fait varier des tâches entièrement fictives toutes les deux secondes. Les boutons métier sont désactivés, aucune fonction d’authentification, de recherche AD, de cache ou de sonde n’est exécutée. Annuler arrête seulement la simulation. La fenêtre peut être redimensionnée pour examiner la disposition.

**TESTER-ACTIVITE.cmd** fournit 52 scénarios Windows PowerShell 5.1 x64 STA avec WPF. Ils incluent :

- contrôle de l’hôte et extraction AST des vraies fonctions, sans exécuter le bootstrap ;
- reproduction du saut dans le fragment XAML original RC1.6 ;
- mesures des tailles et positions réelles du bandeau, des résultats, de l’arbre et du journal avant/après des cycles d’activité ;
- clair/sombre, trois tailles de fenêtre et un rail de navigation réduit ;
- 0, 1, 9, 10, 100 opérations, noms longs, grande durée, progressions et retour au repos ;
- conservation de la grille et de sa sélection, avertissement d’écriture et limites du bouton Annuler.

Les compteurs utilisent leurs vrais helpers de présentation sur des données factices. La page de détail des opérations n’est pas exercée par cette suite ; les scénarios RC1.6 restent fournis séparément. Ce n’est ni une mesure de charge réseau ni un test de droits AD.

## Vérifications effectuées dans cette préparation

Exécuté sous Linux : **209 contrôles portables généraux** (dont les essais SQLite existants via Python) et **142 contrôles ciblés** de source, XML, délimiteurs approximatifs et empreintes. Les opérations restent au nombre de 55, avec le même contrat et la même empreinte globale. Les résultats figurent dans `wad/docs/AUDIT-GENERAL-RC1.7.json` et `wad/docs/AUDIT-ACTIVITE-RC1.7.json`.

**Non exécutés : PowerShell, Windows PowerShell 5.1, WPF, le lanceur Windows et le domaine.** L’hôte n’a pas PowerShell ; la tentative d’accès au dépôt Microsoft pour récupérer un parseur Linux a échoué à la résolution réseau. Aucun test PowerShell n’est donc présenté comme passé. Les 52 scénarios ci-dessus sont fournis pour Windows, non annoncés comme déjà exécutés. Les contrôles XML ne prouvent pas la position finale des pixels.

Le rapport de livraison séparé donne les CRC, tailles et SHA-256 des archives, la vérification des manifestes et l’égalité du runtime entre PROD et DEV. Les audits antérieurs restent historiques ; leurs assertions spécifiques à un ancien diff ne valident pas cette révision.

Références de conception Microsoft : `System.Windows.Visibility` (Hidden conserve l’espace, Collapsed le retire) et modèle de layout WPF (`Grid`, mesure et arrangement). Elles justifient le choix des emplacements réservés, pas une exécution Windows réalisée ici.

## Recette après installation

Vérifier le build RC1.7 dans le journal. Lancer une recherche, cliquer une machine pour sa seule vérification, attendre la fin puis refaire une recherche. Le contenu principal doit garder sa position lors de l’apparition/disparition de l’activité. Tester les deux thèmes, un nom long et une fenêtre réduite. Le compteur Opérations doit continuer de fonctionner sans changer de largeur, et le login doit rester celui de RC1.6.
