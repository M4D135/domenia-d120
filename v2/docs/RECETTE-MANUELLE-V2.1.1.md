# Domenia 2.1.1 — présence et lectures sans Domain Admins

Version du 9 novembre 2026, après le retour de David en production. La préparation et les contrôles CI ne constituent pas une recette utilisateur.

Un seul ZIP est publié : `Domenia_2.1.1_PROD-LIGHT_Windows-x64.zip`. L’extraire dans un dossier distinct et vérifier son SHA256 avec `SHA256SUMS.txt`. La disposition et le moteur WebView2 sont ceux de 2.1.0. Le schéma de données ne change pas : une base de 2.0.5 à 2.1.0 s’ouvre telle quelle.

## Contenu

Mesurer les postes en ligne ne demande plus de compte d’administration. En 2.1.0, avec un compte hors Domain Admins, « Mesurer maintenant » sur la présence affichait « Lecture de l’annuaire disponible. Pour les fonctions distantes, validez explicitement ce compte… » puis proposait « Utiliser un autre compte », validé sur le premier poste de l’OU. Le ping et le DNS n’envoient aucun identifiant au poste : le relevé de présence de l’Accueil, le ping de la fiche, celui du poste et l’écho de Rechercher partent maintenant avec n’importe quel compte connecté. L’inventaire WMI et les autres lectures distantes faites avec l’identité de la session Windows sont tentées sans contrôle préalable de Domain Admins : le poste accepte si le compte y est administrateur, sinon le refus est compté pour ce poste et la campagne continue. Aucun mot de passe n’est manipulé. Un compte saisi et toute écriture distante gardent leur validation.

## À observer

- Connecté avec un compte qui n’est pas membre de Domain Admins : sur l’Accueil, « Mesurer maintenant » du widget de présence relève les postes de l’OU, sans message d’erreur ni fenêtre « Utiliser un autre compte ».
- Fiche d’un poste, puis Rechercher : le ping d’un poste aboutit avec le même compte.
- Même compte, connecté avec la session Windows : « Mesurer maintenant » sur les alertes disque lit les postes en ligne où ce compte est administrateur local ; un poste qui refuse est compté comme refusé, sans arrêter le relevé ni ouvrir « Utiliser un autre compte » avant le premier essai.
- Les points de la [recette 2.1.0](RECETTE-MANUELLE-V2.1.0.md) restent applicables.

Ne noter comme réussies que les étapes effectivement exercées sur ce pack. Ce guide ne demande aucune écriture AD, aucune modification du système ni redémarrage.
