# Domenia 2.1.0 — PROD-LIGHT seul et 22 lots de parité

Version du 8 novembre 2026, décidée par David. La préparation et les contrôles CI ne constituent pas une recette utilisateur ; la validation visuelle native et la recette utilisateur restent en attente.

Un seul ZIP est publié : `Domenia_2.1.0_PROD-LIGHT_Windows-x64.zip`. L’extraire dans un dossier distinct et vérifier son SHA256 avec `SHA256SUMS.txt`. La disposition reste celle de 2.0.8 : `Domenia.exe` et `wad` à la racine. Le moteur WebView2 n’est plus embarqué : Domenia prend WebView2 Evergreen installé (140.0.3485.54 ou ultérieur), sinon le pack WebView2 du Socle extrait dans `wad`, comme décrit dans [MISES-A-JOUR.md](MISES-A-JOUR.md). Le format des données ne change pas (schéma 11, révision native 2) : une base de 2.0.5 à 2.0.8 s’ouvre telle quelle. Un poste en PROD 2.0.8 ne change pas d’édition par mise à jour : y extraire le ZIP à la main. Conserver la version précédente.

## Contenu

Les 22 lots de l’audit de parité du 31 octobre : écritures AD (idempotence, verrous, relectures) ; opérations à distance et transport ; gardes locales des opérations ; connexion, comptes et secrets ; contrats de sondes, ordonnancement, noms et valeurs AD, cache et fraîcheur du moteur ; ateliers de requêtes ; stockage, sauvegardes, purge et migrations ; paramètres de la base locale, assistant et diagnostic ; réglages de collecte et widgets ; journal technique ; démarrage, intégrité et fenêtre ; livraison des paquets ; tableau de bord, opérations et tableaux ; Rechercher (arbre, liste, export). S’y ajoutent l’édition PROD-LIGHT seule et la fermeture sur un poste hors domaine.

## À observer

- Démarrage avec Evergreen installé : Domenia s’ouvre sans dossier `wad\runtime\webview2`.
- La fenêtre « Domenia — Connexion » propose la connexion et « Continuer hors connexion ». Hors connexion, l’Accueil s’ouvre.
- Connexion avec le compte de la session Windows : elle aboutit sans mot de passe saisi et sans message d’échec dans la fenêtre de connexion.
- Fermer Domenia depuis l’Accueil, connecté ou hors connexion : la fenêtre se ferme sans boîte « Fermeture incomplète ». Sur un poste qui n’est membre d’aucun domaine, la fermeture hors connexion se fait aussi sans avertissement.
- Rechercher, action sur plus de 12 postes : la confirmation liste les « Postes concernés » ; « Voir les … postes » les parcourt par pages de 100 avec « Précédent » et « Suivant ».
- Les points de la [recette 2.0.8](RECETTE-MANUELLE-V2.0.8.md) restent applicables.

## Si l’occasion se présente

Ne pas provoquer ces cas en désinstallant un composant ou en modifiant le poste.

- Poste sans Evergreen, pack du Socle extrait dans `wad` : Domenia démarre avec le moteur du Socle. Un fichier ajouté, retiré ou modifié dans `wad\runtime\webview2` bloque le démarrage avec le nom du fichier.
- Poste sans Evergreen ni pack du Socle : le message `DOMENIA_WEBVIEW2_ABSENT` propose les deux solutions avec le lien du Socle ; rien n’est téléchargé.

Ne noter comme réussies que les étapes effectivement exercées sur ce pack. Ce guide ne demande aucune écriture AD hors de l’OU de test, aucune modification du système ni redémarrage.
