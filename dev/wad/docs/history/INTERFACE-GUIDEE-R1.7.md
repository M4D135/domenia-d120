# ADCC 1.0 R1.7 : interface guidée

**Build : `2026.09.21-R1.7-SIDEBAR`**

Cette révision reprend la composition de la référence visuelle GP fournie : barre latérale, bandeau de recherche, cartes claires arrondies, accents bleus, panneau d'aide à droite et journal en bas. L'application reste ADCC, avec ses fonctions d'annuaire et d'assistance. Ce n'est ni une image, ni une nouvelle application web.

## Ce qui change à l'écran

### Navigation latérale

Les espaces principaux deviennent des destinations de la barre de gauche : Accueil, Rechercher, Annuaire, Fiche, Relations, Assistance poste, Atelier, Comptes et Outils. L'espace sélectionné est surligné. Les sous-onglets utiles à une fiche restent disponibles à l'intérieur de celle-ci.

L'arborescence complète est conservée dans **Annuaire**. Elle ne consomme plus une grande colonne sur tous les écrans. **Fiche** est indisponible tant qu'aucun objet n'est chargé ; **Assistance poste** demande une machine. Les boutons de navigation n'attribuent aucun droit supplémentaire.

### Accueil et recherche

L'accueil propose quatre entrées : rechercher, parcourir l'annuaire, préparer un dossier, gérer les comptes. Le détail de la session reste dans une section dépliable.

Le vrai champ de recherche d'ADCC est déplacé dans le bandeau permanent. Il conserve ses événements, son bouton et les raccourcis existants. Les filtres et résultats sont regroupés dans Rechercher. La recherche et les sondes éventuelles continuent de suivre la configuration existante : cette révision ne change pas la politique de recherche à la frappe, de présence ou d'accès distant.

### Comptes et formulaires

Les trois contextes de compte restent distincts : annuaire, postes et secrets. Les cartes sont verticales, les champs ont des libellés visibles et les boutons gardent une hauteur normale. Les lignes se replient lorsque la largeur manque.

Le moteur de validation des comptes, les mots de passe en mémoire et les contextes transmis aux opérations ne sont pas réécrits. Les champs sont les mêmes contrôles nommés qu'en R1.6, raccordés aux mêmes événements métier.

### Aide à droite et infobulles

Le panneau montre le contexte de la fiche et trois raccourcis de navigation : Trouver, Consulter, Préparer. Ce sont des étapes d'orientation, pas un assistant qui exécute ou valide une opération AD à votre place.

Au survol ou à la prise de focus clavier, une fiche d'aide explique le contrôle. L'aide reste affichée lorsque le pointeur le quitte, pour pouvoir la lire. Les motifs de désactivation fournis par les contrôles de sécurité sont conservés.

Le catalogue local contient **403 descriptions nommées** pour les écrans principaux, les fenêtres de connexion/chargement et l'Atelier. Le XAML principal compte **345 contrôles interactifs nommés** avec une infobulle, un nom accessible et un texte d'aide accessible. Les lignes de tableaux, en-têtes, menus et éléments d'arborescence utilisent aussi des aides de style. Les conteneurs purement décoratifs ne reçoivent pas une bulle pour chaque pixel.

Les textes ne sont pas générés à partir de la valeur des champs. En particulier, **le mot de passe révélé, les secrets et le contenu saisi ne sont pas recopiés dans le panneau d'aide**. Cette correction supprime la réflexion de `.Text` et `.Content` présente dans l'ancien helper de R1.6.

Le bouton **?** affiche ou masque le panneau. En dessous de 1360 unités WPF de largeur de fenêtre, le panneau n'impose plus sa colonne : il s'ouvre en superposition sur demande. Les infobulles restent disponibles quand le panneau est fermé.

### Essentiel, Expert et lecture seule

Essentiel conserve les vues quotidiennes ; Expert ajoute les attributs bruts, permissions, WMI et outils techniques. L'ouverture d'un autre type d'objet réapplique désormais ce choix : une machine n'affiche pas WMI en Essentiel et un utilisateur ne récupère pas WMI en Expert.

Un raccourci existant qui demande explicitement une vue technique peut passer l'interface en Expert pour rendre cette vue accessible. **Expert ne désactive pas la lecture seule et ne modifie pas les autorisations.** Les règles d'écriture, confirmations et contrôles AD restent ceux de R1.6.

### Apparence et journal

Les cartes, champs, listes déroulantes, onglets internes et sélections utilisent des ressources de thème communes. Les thèmes clair et sombre restent disponibles, avec le mécanisme existant de mémorisation. Les combobox ont un modèle de popup adapté au thème.

Le journal reste en bas et redimensionnable. **Réduire / Agrandir** change sa place à l'écran sans le vider et sans arrêter l'enregistrement. Aucun historique fictif de tâches ni résultat inventé n'est ajouté.

## Ce qui n'a pas été ajouté

La référence GP est un choix visuel, pas une spécification des opérations d'ADCC. Cette révision n'ajoute pas de renommage Windows, de déplacement automatique d'OU selon un site, de file d'opérations GP ou de faux aperçu avant exécution. Le bouton de renommage existant est explicitement libellé **Renommer dans AD**.

Les correctifs R1.1 à R1.5 restent dans le paquet. Les fonctions d'authentification, le worker distant et les modules de l'Atelier conservent leur code. Le schéma de la base n'est pas modifié. Aucun scan supplémentaire n'est lancé par l'ouverture d'un espace de navigation.

## Installation

1. Fermer ADCC après la fin des opérations en cours.
2. Extraire ce ZIP dans un **autre dossier**, distinct de l'installation actuelle.
3. Depuis le nouveau dossier ADCC, ouvrir Windows PowerShell et exécuter :

```powershell
# Adapter ce chemin au dossier contenant votre installation actuelle.
.\INSTALLER-MISE-A-JOUR.ps1 -Destination 'C:\Outils\ADCC' -WhatIf
.\INSTALLER-MISE-A-JOUR.ps1 -Destination 'C:\Outils\ADCC'
```

**Ne pas supprimer l'ancien dossier.** Le ZIP neuf ne contient ni votre base personnelle, ni vos journaux, ni vos préférences enregistrées. L'installateur conserve `wad\data` et les fichiers de configuration existants, puis sauvegarde le code remplacé.

Le nouveau module `wad\modules\ADCC-UX.UI.ps1` et son catalogue `ADCC-UX.help.json` sont nécessaires. **Remplacer seulement ADCC-Core.ps1 ne suffit pas.**

Avant de copier le code, l'installateur vérifie les empreintes, la syntaxe native de tous les scripts, les anciennes suites isolées, puis lance les tests WPF locaux dans un processus Windows PowerShell STA. Une fenêtre de démonstration peut apparaître brièvement. Un échec arrête la mise à jour avant le remplacement du code et indique le rapport temporaire à consulter.

Le mécanisme existant de retour arrière reste disponible :

```powershell
# Chemin exact du dossier de sauvegarde indiqué par l'installateur.
.\INSTALLER-MISE-A-JOUR.ps1 `
  -RestoreBackup 'C:\Outils\ADCC\wad\maintenance\backups\DOSSIER_DE_SAUVEGARDE'
```

L'installateur vérifie les empreintes avant restauration. Une modification ultérieure du code peut faire refuser le retour arrière pour éviter de l'écraser.

## Voir l'interface sans se connecter au domaine

Sous **Windows PowerShell 5.1**, lancer **APERCU-INTERFACE.cmd**. Le script charge le **XAML réel de cette révision**, pas une maquette HTML. Il extrait uniquement une liste fixe de fonctions de présentation ; il ne lance pas le démarrage d'ADCC, ne lit pas votre cache et ne valide aucun compte.

L'écran est marqué **APERÇU LOCAL · Données fictives · Sans accès AD**. La navigation, l'aide, le profil et le thème peuvent être examinés. La recherche montre deux objets fictifs. Les actions métier sont désactivées. Les contrôles et ressources sont réels, mais l'aperçu ne prouve pas qu'une opération fonctionnera sur le domaine.

Pour réaliser sur votre poste des images PNG du rendu WPF local :

```powershell
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass `
  -File .\wad\maintenance\Preview-AdccUi.ps1 `
  -CaptureDirectory "$env:TEMP\ADCC-Apercu-R1.7"
```

Cette commande produit un aperçu clair et un aperçu sombre avec les mentions de démonstration. **Aucune capture WPF n'a été produite ou vérifiée sous Windows pendant la préparation de ce paquet.**

## Tests et limites

**Hôte de préparation : Linux.** Les contrôles effectués ici comprennent la comparaison des sources, les empreintes, la structure XML, des contrôles lexicaux approximatifs et le calcul de contrastes. Ce ne sont pas une exécution PowerShell, un rendu WPF, une certification d'accessibilité, ni une validation sur votre AD.

`wad\docs\AUDIT-UI-R1.7.json` expose les résultats du contrôle ciblé. Les rapports R1.7 des audits antérieurs sont également joints. Deux gardes d'audit ont été adaptés avec leurs assertions conservées : les noms WPF sont vérifiés par portée de modèle et la liste des fonctions UI modifiables compare désormais la version exacte R1.6 aux 13 points d'intégration R1.7.

**TESTER-INTERFACE.cmd** fournit **25 scénarios natifs** portant sur le chargement réel des modèles, la navigation, les deux profils, l'aide clavier, les contrôles désactivés, une sentinelle de mot de passe, les deux thèmes, le journal, les petites fenêtres et les doublons de noms XAML. Ils restent à exécuter sur Windows ; l'installateur les impose avant la copie. Un passage réussi ne remplace pas une recette métier en préproduction.

Les interfaces de certaines vues avancées restent denses. Sur une petite fenêtre, utiliser le défilement prévu et masquer l'aide avec ?. Le rendu doit être contrôlé sur vos écrans et à vos réglages de mise à l'échelle, notamment 125 %, 150 % et 200 %.

## Fichiers principaux de la révision

- `wad\ADCC-Core.ps1` : XAML et raccordements de présentation.
- `wad\modules\ADCC-UX.UI.ps1` : navigation, aide, profil visuel, adaptation à la largeur et palette.
- `wad\modules\ADCC-UX.help.json` : catalogue statique d'aide.
- `wad\maintenance\Preview-AdccUi.ps1` : aperçu WPF isolé et capture locale facultative.
- `wad\tests\Test-ADCCInterface.ps1` : lanceur des tests natifs.
- `wad\tests\audit_ui.py` et `ui-baseline-r16.json` : audit de source et référence de non-régression.

Les EXE, DLL et icônes binaires existants n'ont pas été recompilés ni remplacés par de nouveaux binaires.
