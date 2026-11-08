# ADCC 1.0 R1.11 : expérience support harmonisée

Build : `2026.09.30-R1.11-SUITE`.
Base : pack complet ADCC R1.10 de cette conversation. Les décisions retrouvées et les guides de GP 17.0-RC14 et RBP 2.3.0 ont servi de références d'usage, pas de nouvelles dépendances.

## Ce qui est livré

L'application ADCC complète, ses modules, ses lanceurs existants, les aperçus hors domaine, le nouvel audit et les tests Windows. Le pack ne contient pas votre base personnelle, vos journaux ou vos préférences de session. GP et RBP ne sont pas modifiés par ce ZIP.

La disposition R1.10 est conservée : menu gauche réduit en icônes, aide droite rétractable, arbre OU et résultats sur la même page, chemin LDAP dépliable, login compact. Les réglages de domaine et les comptes ne sont pas remplacés par ceux de GP ou RBP.

## Les améliorations utilisables

### Suivi des opérations

Le bouton **Opérations** du bandeau ouvre une vue dans **Outils > Opérations**. Elle présente les tâches réellement présentes dans le moteur : nom, lecture ou écriture, durée, état et explication. Les lectures détachées qui attendent leur nettoyage restent visibles.

**Arrêter la lecture** ne fonctionne que pour une lecture annulable de la session courante. La vérification porte de nouveau sur la tâche réelle au moment du clic, pas seulement sur le bouton ou le tableau. Une écriture ou une tâche protégée n'est pas arrêtée par ce bouton. Aucun arrêt forcé, aucune relance automatique.

Les termes ont un sens précis : **En cours**, **Arrêt demandé**, **Nettoyage**, **À vérifier**. Une tâche retirée du moteur ne devient pas une réussite inventée dans cette vue. Les résultats terminés restent dans le journal existant. Cette vue n'est ni un historique transactionnel nouveau ni une file d'écritures.

Le compteur réutilise le rafraîchissement borné existant. La projection est limitée à 64 lignes ; le tableau n'est pas régénéré périodiquement lorsqu'il n'est pas consulté. Les données de travail, sorties brutes et credentials ne sont pas copiés dans ses lignes.

### Recherche : affiner sans redemander à l'annuaire

Le nouveau champ **Filtrer les lignes chargées** agit seulement sur les résultats déjà en mémoire. Plusieurs mots doivent tous être présents dans les colonnes prises en charge : type, nom, login, UPN/DNS, association et présence. Les caractères `*`, `[` ou `]` restent littéraux ; ce n'est pas un filtre LDAP ou une expression régulière.

L'OU, la profondeur et le texte de la recherche AD ne changent pas. Le filtre de présence continue de s'appliquer. Ce filtrage n'étend pas le nombre de résultats obtenu : une requête limitée à 100 lignes reste limitée à 100 lignes, même si le filtre local n'en laisse qu'une. Le champ est borné à 120 caractères et différé de 180 ms. Aucun accès réseau supplémentaire n'est lancé.

Le champ et son bouton suivent le verrouillage de la grille pendant une écriture. Une application différée du filtre vérifie également ce verrou. Le filtre est temporaire, non enregistré. **Effacer le filtre** restaure les lignes chargées correspondant à la présence ; le bouton **Effacer** de la recherche efface aussi ce filtre local.

### Export conforme à l'écran

Sans sélection, **Exporter CSV** exporte les lignes visibles dans la grille, et non le tableau source complet avant filtrage. Avec une sélection, seules les lignes sélectionnées encore visibles sont exportées, dans l'ordre de la grille. Une sélection devenue obsolète ne réintroduit pas une ligne masquée. Les protections CSV existantes sont conservées.

C'est un correctif concret : en R1.10, l'absence de sélection repliait l'export sur `BranchObjects`, même si le filtre de présence cachait des lignes. Les noms et informations AD restent internes ; un export n'est pas anonymisé.

### Journal plus facile à lire

Le journal propose une recherche littérale avec **Suivant**, un retour automatique à la ligne et une taille de texte réglable de 10 à 18. Une recherche réussie sélectionne l'occurrence et suspend **Suivre**, uniquement pour maintenir le texte à l'écran. L'enregistrement des événements continue. Réactiver **Suivre** reprend le défilement.

Réduire le journal masque son texte et sa barre d'outils, sans vider les messages. Son état ouvert/replié, sa hauteur ouverte et les préférences de lecture sont conservés. La hauteur et la taille des caractères sont bornées. Le texte recherché n'est pas mémorisé.

### Apparence et connexion

**Confort / Compact**, dans la nouvelle vue Opérations, ajuste uniquement la hauteur des lignes de la grille de résultats. Cela n'altère ni les données ni les filtres.

La connexion compacte gagne un bouton clair/sombre et un avertissement **Verr. Maj**. Le bouton change les ressources de couleur sans recréer la fenêtre, envoyer les identifiants ou lire le mot de passe. La mémorisation du thème est demandée au clic. En cas d'échec d'enregistrement, un message l'indique explicitement ; le thème visible n'est pas présenté comme durable à tort.

La connexion, le chargement et l'application lisent maintenant la même palette locale `wad/modules/SupportSuite.UI.json`. Les cartes, couleurs et principaux libellés constituent une base réutilisable pour les autres outils. **Seule ADCC est branchée sur ce fichier dans cette livraison.** Les métriques de ce contrat documentent une cible de conception, elles ne redimensionnent pas automatiquement tous les contrôles existants de trois logiciels.

L'étape surlignée du panneau d'aide suit la navigation au lieu de montrer toujours la première étape en bleu. Les textes des étapes indisponibles ne sont plus atténués jusqu'à devenir difficiles à lire. Les nouvelles commandes possèdent une aide statique et des noms accessibles.

### Compte utilisé et préférences

La section dépliable **Comptes utilisés** dans le contexte de travail affiche les identités AD, poste et secrets configurées. Ce rappel ne constitue pas un test de droits. Aucun mot de passe, jeton ou clé n'y est recopié.

Un défaut de priorité du profil est corrigé : un choix valide Essentiel/Expert du JSON prime sur l'ancien fichier `ADCC.ui-profile.cfg`. Le fichier historique sert seulement à migrer un choix absent ou invalide. Les booléens textuels sont correctement interprétés et les dimensions invalides ou infinies sont rejetées ou bornées. Aucune préférence ajoutée ne restaure le mode écriture, une cible d'opération ou une confirmation.

## Vérification du paquet

**VERIFIER-PACK.cmd** contrôle la cohérence entre fichiers et manifeste ainsi que la syntaxe avec le parseur Windows PowerShell, sans ouvrir ADCC ni contacter le domaine. Les configurations existantes peuvent différer de celles du paquet. `-StrictConfig` impose leurs empreintes pour une copie neuve.

Les chemins hors paquet et les liens de redirection sont refusés. Un manifeste livré avec le code permet de déceler des fichiers manquants ou un mélange de versions ; ce n'est ni une signature Authenticode ni une garantie de provenance. Les EXE et DLL sont inchangés. Les règles de sécurité de l'organisation restent applicables.

## Installation sans perdre la base

Fermer ADCC seulement après la fin des opérations. Extraire ce pack dans un dossier distinct. Depuis ce nouveau dossier ADCC :

```powershell
# Adapter la destination à l'installation existante.
.\INSTALLER-MISE-A-JOUR.ps1 -Destination 'C:\Outils\ADCC' -WhatIf
.\INSTALLER-MISE-A-JOUR.ps1 -Destination 'C:\Outils\ADCC'
```

Ne pas supprimer l'ancien dossier. L'installateur conserve `wad/data` et les configurations existantes, sauvegarde les fichiers remplacés, vérifie le manifeste et exécute les suites natives avant la copie. Un test en échec arrête l'installation. Conserver le rapport affiché, ne pas supprimer les contrôles pour forcer la mise à jour.

Le retour arrière du code reste disponible avec `-RestoreBackup` et le chemin exact indiqué par l'installateur. Il ne remplace pas la base personnelle. Pour une installation neuve, conserver tout le dossier `ADCC`, puis lancer `LANCER-ADCC.cmd` ; `ADCC.exe` reste le lanceur existant, avec `wad` à côté.

Ne pas copier uniquement `ADCC-Core.ps1` : les deux nouveaux modules Experience et `SupportSuite.UI.json` sont nécessaires.

## Vérifications : ce qui a réellement été fait

**Exécuté ici : 98 contrôles Python de source, XML, contrastes calculés et empreintes, sans échec.** Le rapport détaillé est `wad/docs/AUDIT-EXPERIENCE-R1.11.json`. Les 573 fonctions principales de R1.10 restent présentes ; 13 changent et 560 conservent leur corps après normalisation des fins de ligne. Le code commun des workers et les 45 opérations à empreintes restent identiques. Les binaires, configurations livrées et modules métier de l'Atelier sont inchangés.

**Non exécutés ici : PowerShell, Windows PowerShell 5.1, WPF, authentification, LDAP et accès réel aux postes.** Les contrôles lexicaux ne remplacent pas le parseur natif. Les contrastes calculés sur les paires de couleurs retenues ne constituent pas un audit d'accessibilité complet.

**Fournis pour Windows :** 48 nouveaux scénarios isolés dans `TESTER-EXPERIENCE.cmd`, 13 scénarios WPF supplémentaires dans les aperçus, et les suites préexistantes. Ces nombres désignent des tests écrits, pas des tests déclarés réussis sous Windows. La suite historique du thème est adaptée pour vérifier la palette réellement chargée, et non les couleurs de base désormais surchargées.

Les rapports historiques décrivent leurs versions respectives. Ils ne certifient pas cette livraison.

## Recette conseillée sur Windows

1. Lancer `VERIFIER-PACK.cmd`, puis `TESTER-EXPERIENCE.cmd` sur le pack extrait.
2. Ouvrir `APERCU-INTERFACE.cmd` et `APERCU-CONNEXION.cmd`. Ce sont les vrais contrôles WPF avec données fictives, pas des captures vérifiées ici.
3. Tester clair/sombre, repli des panneaux, densité, recherche dans le journal et persistance après fermeture normale.
4. Sur une OU de test, comparer la grille visible avec l'export après filtrage de présence et filtrage local.
5. Examiner une lecture dans Opérations. Vérifier que son arrêt reste « demandé » pendant le nettoyage, et qu'aucune écriture ne peut être arrêtée par le nouveau bouton.
6. Vérifier une connexion normale avec les identifiants habituels. La nouvelle présentation n'est pas une correction supplémentaire de l'authentification.
