# Domenia 2.0.6 — recette VM, clavier et interface, 29 octobre 2026

Correctif issu des recettes VM de la 2.0.5 et de la 2.0.6 : Échap ferme de nouveau le panneau ou le dialogue du dessus quand son bouton focalisé disparaît, les notifications qui restent ne couvrent plus les boutons d’un dialogue quelle que soit sa hauteur, un écran n’est signalé prêt qu’à la fin de sa transition, Comptes ouvre le compte urgent après une OU vide, une passe de recette de l’interface corrige 117 défauts visuels relevés sur les 137 scénarios de simulation, puis 30 autres relevés sur les captures des trois thèmes, et l’Assistance résiste à une forte charge. Le compte de session et « Replier le menu » restent visibles en bas du menu. Même format de données que 2.0.5 ; look et animations conservés.

Source compilée : `6d33175eea8788e0f50be3f0d5b5838c31d1f905`. [Release v2.0.6](https://github.com/M4D135/domenia-d120/releases/tag/v2.0.6), publiée à `2026-10-29T13:30:11Z`, identifiant `427902995`.

## Vérifications

[Compilation Windows Debug/Release](https://github.com/M4D135/domenia-d120/actions/runs/40867514479) et [fabrication des packs](https://github.com/M4D135/domenia-d120/actions/runs/40867514448) réussies sur le commit indiqué. Résultats exacts : {"csharp_full_passed": 2582, "csharp_critical_passed": 931, "harness_self_tests": 26, "release_guard_tests": 15, "manual_package_verifier_tests": 11, "browser_evidence_verifier_tests": 11, "web_critical": 107, "simulation_scenarios": 7}.

Recette sur la VM `DOMENIA-FIRSTRUN-20261020` (domaine de test, session de bureau), avec le ZIP PROD publié (SHA256 `6ac60bf0c12c534340cfa6b24b2e1c795659a927ae4d5eb6716970e3c6dc08cb`) : annuaire : 5 réussis, 0 en échec, 132 ignorés (réservés à la simulation) ; simulation : 136 réussis, 0 en échec, 1 ignoré (réservé au mode annuaire) ; 113 captures en thèmes clair, sombre et contraste élevé, sans échec.

Intégrité des ZIP et manifestes vérifiée localement ; sources DEV comparées aux blobs Git du commit. PROD et DEV partagent le même exécutable : `74396733891b2feaf7d66dd1c37ea93b098f81137dde37ac554033091b68d552`. SHA256 GitHub concordants avec les fichiers locaux, sans reconstruction pour publier. 7 releases antérieures et 21 assets conservés.

| Pack | Archive | Octets | SHA256 |
| --- | --- | ---: | --- |
| **PROD** | [Domenia_2.0.6_PROD_Windows-x64.zip](https://github.com/M4D135/domenia-d120/releases/download/v2.0.6/Domenia_2.0.6_PROD_Windows-x64.zip) | 485733483 | `6ac60bf0c12c534340cfa6b24b2e1c795659a927ae4d5eb6716970e3c6dc08cb` |
| **DEV** | [Domenia_2.0.6_DEV_Windows-x64.zip](https://github.com/M4D135/domenia-d120/releases/download/v2.0.6/Domenia_2.0.6_DEV_Windows-x64.zip) | 507361518 | `f1700e0deb1151c1b18eec4e4512a7c9c517e9c896a6584a58ab33d309d7af17` |

## Corrections

- Clavier : le circuit d’écriture rend le focus au panneau du reçu quand son pied est remplacé ; le kit ferme le panneau ou le dialogue modal du dessus sur Échap si l’élément focalisé a disparu. Corrige le reçu après confirmation, le déplacement d’objet (la fiche suit l’objet à la fermeture) et le retour au compte de connexion.
- Notifications : un avertissement ou une alerte qui reste affiché reste sous un dialogue quand la place le permet, sinon au-dessus de son pied mesuré ; le dialogue ne bouge pas.
- Disponibilité : `data-ready` n’est posé qu’à la fin de la transition de l’écran ; le harnais attend aussi la fin d’une transition avant de cliquer.
- Comptes : en simulation, quitter une OU vide pour une OU avec des comptes ouvre le détail du compte le plus urgent.
- Interface : passe de recette sur les 1 766 captures de la simulation ; 118 défauts relevés et vérifiés dans le code, 117 corrigés (barre du tableau du parc, en-tête qui défilait sur lui-même, tableaux qui élargissaient leur panneau, pastilles coupées, chevauchements, retours d’état, typographie). Reste ouvert : la loupe de certains champs de recherche dans les panneaux latéraux.
- Menu de gauche : pied collant avec le compte de session et « Replier le menu » (convention commune PESTO, GLPI, FILPRO).
- Thèmes : revue des 113 captures clair, sombre et contraste élevé ; 30 défauts corrigés (sélection des contrôles segmentés et boutons principaux grisés en contraste élevé, loupe des filtres de grille, pastille réseau sur les boutons principaux, noms coupés à leur trait d’union, bouton d’aide de l’Accueil).
- Robustesse : masquage des secrets de l’Assistance sans échec sous charge (nouvel essai puis masquage complet), plan de la barre fine de Rechercher de nouveau accessible, « Arrêter » de l’inventaire placé pour qu’un clic tardif ne relance rien, mesure de démarrage de la CI qui attend ses deux jalons.
- Harnais E2E : reconnaissance des classes WinForms .NET (`Edit`, `Button`) de la fenêtre native « Charger le compte poste » ; diagnostic sans valeur en cas d’échec.
- Scénarios de simulation réalignés sur l’interface actuelle, sans affaiblir leurs vérifications.

## Portée

Recette exécutée sur une VM Windows 11 jointe au domaine de test (identité intégrée de la session, aucun mot de passe saisi par l’outil) ; ce n’est pas une recette utilisateur ni une validation sur le domaine de production. Les tests de 3 500 et 100 000 postes restent simulés. La revue visuelle native et la recette utilisateur restent en attente. Restent à reprendre, relevés par la vérification des captures finales et sans effet sur l’usage : la loupe de certains champs de recherche des panneaux latéraux, un décalage de 3 px du cadre de sélection du contrôle segmenté de l’écran Schéma en contraste élevé, le renvoi à la ligne de « utilisateur: martin » dans la carte Syntaxe de Rechercher quand le menu est replié, et 4 px d’écart vertical du pied du menu entre menu replié et déplié. [Recette à effectuer](../../RECETTE-MANUELLE-V2.0.6.md).
