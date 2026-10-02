# Domenia 1.0 RC1.6 : connexion sans mini-journal et compteurs stables

Build : `2026.10.01-DOMENIA-1.0-RC1.6-STABLEUI`.
Base : les archives originales Domenia RC1.5 PROD/DEV de cette conversation.

## 1. Le défaut était dans la fenêtre de connexion

Le formulaire reprenait les styles FILPRO, mais ses événements de connexion continuaient à alimenter `LblLoginStage` avec les détails du worker et le temps écoulé. La zone de retour d'information et l'accès au journal intégré devenaient visibles pendant une validation. Un résultat de succès pouvait aussi remplir ces contrôles juste avant la fermeture. Le formulaire au repos ne suffisait donc pas pour vérifier ce parcours.

La RC1.6 corrige **la fenêtre de connexion elle-même**, pas une autre fenêtre de démarrage :

- Les deux champs, la mémorisation du seul identifiant, les actions, le thème et Verr. Maj conservent leur présentation FILPRO.
- Pendant la validation, une carte d'attente apparaît **dans la même fenêtre**, avec une seule phrase : « Vérification du compte… », une animation et « Annuler la connexion ».
- Les dimensions extérieures sont conservées pendant cette attente. Les détails longs et les timestamps ne participent plus à la disposition.
- Le transcript et le libellé technique sont maintenus dans un sous-arbre toujours masqué, sans expander. Ils restent disponibles pour les actions de diagnostic existantes, mais ne sont jamais affichés dans le formulaire standard.
- En cas d'échec, le formulaire revient avec le message borné et les boutons « Ouvrir le journal » / « Copier le diagnostic ». Le journal n'est ouvert que sur demande, en dehors du formulaire ; une copie ne déplie pas un mini-log.
- Un nouvel essai masque le retour du précédent. Un message de succès reçu pendant l'attente ne déplie aucune zone de diagnostic.
- Le bouton d'annulation de l'attente et Échap rejoignent le gestionnaire d'annulation existant. Il n'y a pas de deuxième moteur de validation, de nouvel essai automatique ou d'arrêt natif forcé.

Les journaux sur disque sont conservés. Le mode Debug explicitement choisi garde sa présentation technique. Les fonctions de la fenêtre de chargement **suivante** sont identiques à RC1.5 : elles ne sont pas l'objet de ce correctif.

## 2. Le bandeau ne change plus de largeur au gré du compteur

Auparavant, le contenu du bouton était remplacé par « Opérations (N) ». Son voisin pouvait passer de « Comptes temporaires » à « Accès à revoir (N) ». Le parent calculait alors de nouvelles largeurs.

Les deux boutons possèdent désormais un contenu permanent : libellé fixe et badge séparé.

| Contrôle | Présentation |
|---|---|
| Opérations | Largeur fixe de 144 unités WPF, hauteur de 40 ; libellé « Opérations » et emplacement de badge de 30 unités. |
| Accès | Largeur fixe de 108 unités WPF, hauteur de 40 ; libellé « Accès » et emplacement de badge de 30 unités. |
| Zéro | Badge invisible, mais son emplacement reste réservé. |
| 1 à 99 | Nombre affiché dans le badge, sans remplacer le contenu du bouton. |
| Au-delà de 99 | « 99+ » dans le badge ; nombre exact dans l'infobulle et le suivi. |

Le comptage des opérations actives et des lectures encore en nettoyage est conservé. Les destinations et les règles d'annulation des boutons ne changent pas. Le compteur ne lance aucune requête supplémentaire. Il ne force ni `UpdateLayout`, ni la reconstruction du bandeau.

Cela fixe les déplacements provoqués par **ces compteurs** ; la fenêtre reste normalement redimensionnable et d'autres changements volontaires de disposition peuvent toujours modifier ses dimensions.

## 3. Périmètre du correctif

Quatre fonctions du cœur changent : `Get-MainXaml`, `Get-DomeniaStandardLoginXaml`, `Set-DomeniaFastLoginBusy` et le libellé de version dans `Initialize-DomeniaPresentation`. Les 573 autres fonctions principales de RC1.5 sont conservées.

Trois fonctions de présentation changent dans les modules : mise à jour du bouton Opérations, mise à jour du bouton Accès et raccordement de l'annulation dans le login. Aucun nouveau nom de fonction de module n'est ajouté ; le chargeur reste identique.

Les 55 opérations et leurs empreintes sont inchangées, ainsi que le moteur de connexion, les méthodes d'accès distant, les vérifications des droits et les données persistantes. La recherche globale, le filtre OU, le ping et l'utilisateur uniquement à la sélection, les colonnes et l'arbre mémorisés sont conservés.

Les binaires et configurations fournis sont inchangés. Le moteur annonce RC1.6 ; les anciennes ressources de version de l'EXE ne sont pas utilisées pour prétendre que le lanceur aurait été recompilé. Il reste non signé.

## 4. Installation

Les archives conservent les dossiers `prod` et `dev`. La racine PROD contient uniquement `Domenia.exe` et `wad`. Le déblocage reste dans `wad/Support/DEBLOQUER_TOUT.cmd`, sans dépendance aux tests ou aux démos en production.

Pour mettre à jour, fermer Domenia après la fin des opérations. Extraire DEV dans un dossier distinct, puis depuis ce dossier :

```powershell
# Adapter la destination au dossier contenant actuellement Domenia.exe et wad.
.\INSTALLER-MISE-A-JOUR.ps1 -Destination 'C:\Outils\Domenia' -WhatIf
.\INSTALLER-MISE-A-JOUR.ps1 -Destination 'C:\Outils\Domenia'
```

Ne pas supprimer l'installation, la base, les reçus ou les configurations. L'installateur conserve les données et les configurations existantes, sauvegarde le code remplacé et copie uniquement le runtime. Installer le cœur, les modules et le manifeste ensemble ; une modification manuelle isolée ferait échouer leur cohérence.

Les données personnelles ne figurent dans aucun ZIP. La mise à jour ne remplace pas les données de `%LOCALAPPDATA%\Domenia\Data`.

## 5. Vérifications exécutées et limites

Exécuté sous Linux : **209 contrôles généraux** et **188 contrôles ciblés** de source, XML, comparaison des styles FILPRO, empreintes et contrats. L'audit général comporte aussi ses essais SQLite via Python. Les contrôles ciblés confirment que la fenêtre de chargement après login n'a pas changé et que les contrôles techniques du login standard ne peuvent plus être rendus par leur arbre XAML.

Les deux ZIP sont contrôlés après leur construction : CRC, absence de doublons de chemins Windows, exactitude des tailles et SHA-256, contenu correspondant au manifeste, racine PROD minimale et octets runtime identiques entre éditions.

**Non exécuté ici : PowerShell, Windows PowerShell 5.1, WPF, lanceur Windows, authentification ou accès au domaine.** Les contrôles lexicaux et XML ne sont ni un parseur PowerShell natif ni une mesure du rendu. Aucune capture WPF ou promesse de fluidité mesurée n'est produite dans cet environnement.

DEV fournit `TESTER-INTERFACE-STABLE.cmd`, soit **52 scénarios Windows PowerShell 5.1 x64 STA/WPF**, non annoncés comme déjà réussis. Ils appellent les vrais helpers de présentation, avec des dépendances réseau et de stockage remplacées par des doubles en mémoire. Ils examinent clair/sombre, validation prolongée, message de succès avant fermeture, échec, nouvel essai, annulation/Échap, erreurs longues, petits écrans et variations 0/1/9/10/99/100 du compteur. Les positions et tailles des voisins sont mesurées par WPF lors de ces tests.

L'installateur exécute cette suite avant la copie, puis les suites existantes adaptées. Un rapport incomplet, ignoré ou en échec arrête l'installation. Les anciens audits restent historiques ; leurs assertions imposant l'ancien mini-log ne constituent pas la recette RC1.6.

`APERCU-CONNEXION.cmd` permet maintenant de cliquer « Simuler une connexion » dans l'aperçu : attente fictive de trois secondes, retour d'information et nouvel essai, sans contacter AD ni utiliser les préférences réelles. Aucun vrai mot de passe n'est nécessaire. La recherche et les opérations réelles restent déconnectées de cet aperçu.

## Références de disposition

Microsoft, `System.Windows.Visibility` : Hidden conserve l'emplacement, Collapsed le retire. Microsoft, modèle de layout WPF : la taille et le contenu des contrôles influent sur la mesure/position des voisins. Ces références justifient la disposition choisie, pas l'exécution du programme sur le poste.

- https://learn.microsoft.com/en-us/dotnet/api/system.windows.visibility
- https://learn.microsoft.com/dotnet/desktop/wpf/advanced/layout
