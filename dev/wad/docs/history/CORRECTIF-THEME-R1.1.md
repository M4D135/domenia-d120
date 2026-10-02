# AD⚡CC 1.0 · Correctif thème R1.1

Build : `2026.09.21-R1.1-THEME`  
Base : paquet `2026.09.21-R1-RELIABILITY` fourni dans cette conversation.

## Corrections

**Le login était sombre, mais la fenêtre principale redevenait claire.**
`Load-AdccSettings` relisait systématiquement `ADCC.theme.cfg` après le JSON et
remplaçait le choix enregistré par le `Light` historique livré avec le programme.
La résolution est maintenant commune au login, au chargement et à la fenêtre
principale : un `Theme` JSON valide est prioritaire, qu'il soit `Dark` ou `Light`.
Le fichier historique sert uniquement de repli en l'absence d'un choix valide.
Le mécanisme existant de lecture d'un JSON `.bak` valide reste conservé.

**Les textes du chargement étaient noirs sur fond sombre.**
L'ancien convertisseur remplaçait seulement certaines couleurs d'attributs XAML.
Il ne corrigeait ni les couleurs des `Setter`, ni les champs sans couleur
explicite, ni les couleurs changées par les messages d'authentification.
Les quatre fenêtres d'amorçage utilisent maintenant des ressources nommées pour
les fonds, textes, champs, bordures, boutons et états. Les styles de champs
précisent aussi la couleur du curseur. Le modèle des boutons d'amorçage évite de
reprendre un fond système clair au survol. Les messages d'erreur, d'annulation et
de réussite ont une couleur adaptée au thème actif.

Le thème de la principale est appliqué dès sa construction, avant son affichage.
Une bascule utilisateur met immédiatement à jour le choix en mémoire et le
fichier de réglages, sans attendre le délai de sauvegarde différée de 1,5 seconde.
La simple restauration au démarrage n'enregistre pas un nouveau choix.

## Installation sur ton dossier existant

Extraire le nouveau paquet dans un **autre** dossier que l'installation actuelle.
Fermer ADCC une fois les opérations actives terminées. Depuis le nouveau dossier,
ouvrir Windows PowerShell et adapter le chemin de destination :

```powershell
.\INSTALLER-MISE-A-JOUR.ps1 -Destination 'C:\Outils\ADCC' -WhatIf
.\INSTALLER-MISE-A-JOUR.ps1 -Destination 'C:\Outils\ADCC'
```

L'installateur existant sauvegarde les fichiers de code remplacés, vérifie le
manifeste et conserve les configurations présentes et `wad\data`.
**Ne pas supprimer ta base, ton dossier `wad\data` ou tes réglages.**
Le nouveau paquet n'embarque aucune base ou journal personnel.

L'ancienne version peut avoir déjà réenregistré `Light` à la fermeture. Dans ce
cas, sélectionner une fois le thème sombre après la mise à jour, puis fermer et
relancer l'application. Le correctif conserve le choix présent, sans forcer le
sombre à tout le monde.

## Vérification rapide sur le poste Windows

1. Choisir le sombre dans la fenêtre principale, fermer puis relancer : login,
   chargement et principale doivent tous être sombres.
2. Pendant le chargement, vérifier le nom de l'étape, le détail, le temps écoulé
   et les deux boutons. Vérifier aussi le survol des boutons.
3. Refaire la même séquence en clair. Un ancien fichier `.cfg` sombre ne doit pas
   réactiver le sombre contre le choix clair enregistré.

`TESTER-THEMES.cmd` lance les tests isolés de préférences et de WPF. Ils ne lancent
ni authentification, ni requête AD. Les préférences de test sont temporaires et le
rapport est écrit dans `%TEMP%`. Les fenêtres de test sont construites sans être
affichées. Le script contrôle les couleurs effectives, les contrastes des
contrôles ciblés et la bascule de la principale avec son vrai XAML.

## Vérifications effectuées ici et limites

Les contrôles exécutés ici sont des contrôles **Linux/Python de source, de XML,
d'intégrité et de contraste calculé**. Ils ne constituent pas une exécution de
Windows PowerShell 5.1 ou un rendu WPF sous Windows.

- Les contrôles propres au thème couvrent les deux palettes, les quatre XAML
  d'amorçage composés avec leurs ressources, les héritages de styles, les noms
  uniques et la présence des corrections dans le code.
- Le contraste calculé minimal des neuf éléments textuels/champs/boutons analysés
  dans le chargement sombre est de **9,84:1**. Dans les fenêtres de connexion
  sombres, le minimum des éléments analysés est de **6,70:1**. Ces valeurs portent
  sur les couleurs définies, pas sur une capture du rendu Windows, les contrôles
  désactivés, l'anticrénelage ou les préférences d'accessibilité du système.
- Les noms, dimensions de fenêtre et attributs de placement/contenu des contrôles
  d'amorçage existants ont été comparés à R1 et conservés.
- Les 46 empreintes des opérations workers et les binaires fournis sont inchangés.

Les tests PowerShell/WPF natifs sont **fournis mais non exécutés ici**, car cet
environnement ne dispose ni du moteur Windows PowerShell ni de WPF. Les rapports
JSON livrés l'indiquent explicitement.

Rapports actuels : `wad\docs\AUDIT-THEME-R1.1.json` et
`wad\docs\AUDIT-R1.1.json`. Le diff R1 vers R1.1 est
`wad\docs\ADCC-R1.1-THEME.patch`. Les documents et rapports portant seulement
« R1 » restent l'historique de la version précédente, pas un nouveau test Windows.

## Périmètre

16 fonctions existantes modifiées, 4 fonctions ajoutées, aucune supprimée par
rapport à R1. La version publique reste 1.0. Les fonctions métier AD, les workers,
la base et les règles de sécurité de R1 ne sont pas modifiés par ce correctif.
Ce correctif vise les fenêtres d'amorçage et la restauration de la palette de la
principale ; il ne prétend pas redessiner toutes les boîtes de dialogue de Windows.

### Référence technique

Microsoft Learn, « Dependency property value precedence » : les valeurs de styles
et les styles système WPF peuvent primer sur l'héritage d'une couleur du parent.
Une couleur de fenêtre seule ne suffit donc pas pour tous les champs et boutons.
Source : https://learn.microsoft.com/en-us/dotnet/desktop/wpf/properties/dependency-property-value-precedence
