# Domenia 2.0.7 — finitions de l’interface, 29 octobre 2026

Finitions de l’interface relevées par la vérification des captures de la recette 2.0.6 : la loupe des champs de recherche reste visible dans les panneaux latéraux, les dialogues et les filtres de grille (une infobulle ne positionne plus un champ), le cadre de sélection des contrôles segmentés de Schéma et de l’Atelier est sous son bouton, chaque exemple de la carte Syntaxe de Rechercher tient sur une ligne, et le pied du menu de gauche garde sa hauteur menu déplié ou replié, sa poignée de largeur se saisissant de nouveau à la souris. Même format de données que 2.0.5 et 2.0.6 ; look et animations conservés.

Source compilée : `c6b226f5838fc3621d066535210d94d8ed9993a5`. [Release v2.0.7](https://github.com/M4D135/domenia-d120/releases/tag/v2.0.7), publiée à `2026-10-29T16:52:57Z`, identifiant `428145520`.

## Vérifications

[Compilation Windows Debug/Release](https://github.com/M4D135/domenia-d120/actions/runs/40901090549) et [fabrication des packs](https://github.com/M4D135/domenia-d120/actions/runs/40901090541) réussies sur le commit indiqué. Résultats exacts : {"csharp_full_passed": 2582, "csharp_critical_passed": 931, "harness_self_tests": 26, "release_guard_tests": 15, "manual_package_verifier_tests": 11, "browser_evidence_verifier_tests": 11, "web_critical": 110, "simulation_scenarios": 7}.

Recette sur la VM `DOMENIA-FIRSTRUN-20261020` (domaine de test, session de bureau), avec le ZIP PROD publié (SHA256 `7435c22cd1ba83115bc63aa762de6a06e9fab7bf935f752cc4d907858145f2ec`) : annuaire : 5 réussis, 0 en échec, 132 ignorés (réservés à la simulation) ; simulation : 135 réussis, 1 en échec, 1 ignoré (réservé au mode annuaire) ; relance ciblée de parametres/copie-destination : 3 réussis, 0 en échec, 0 ignoré ; 113 captures en thèmes clair, sombre et contraste élevé, 0 en échec.

Intégrité des ZIP et manifestes vérifiée localement ; sources DEV comparées aux blobs Git du commit. PROD et DEV partagent le même exécutable : `dc12c665f3f143f1c7353f773dfa64a1d5eec41f9c67802a60815818f7c81d65`. SHA256 GitHub concordants avec les fichiers locaux, sans reconstruction pour publier. 8 releases antérieures et 24 assets conservés.

| Pack | Archive | Octets | SHA256 |
| --- | --- | ---: | --- |
| **PROD** | [Domenia_2.0.7_PROD_Windows-x64.zip](https://github.com/M4D135/domenia-d120/releases/download/v2.0.7/Domenia_2.0.7_PROD_Windows-x64.zip) | 485733505 | `7435c22cd1ba83115bc63aa762de6a06e9fab7bf935f752cc4d907858145f2ec` |
| **DEV** | [Domenia_2.0.7_DEV_Windows-x64.zip](https://github.com/M4D135/domenia-d120/releases/download/v2.0.7/Domenia_2.0.7_DEV_Windows-x64.zip) | 507367125 | `0b3e1ee5f46d135298531d69a6b7348af2b24d6914e14392bc82caa09aab4d9f` |

## Corrections

- Loupe des champs de recherche : `[data-tip]` ne positionne plus `input`, `textarea` ni `select` (`:where` garde la spécificité) ; un champ positionné peignait par-dessus la loupe dessinée avant lui dans les panneaux et dialogues, dont les champs reçoivent l’infobulle des feuilles. Les loupes de tête exposées gardent `z-index: 1`, y compris pendant la secousse d’erreur. Un test web vérifie chaque structure dans un panneau et un dialogue, dans les trois thèmes.
- Contrôles segmentés : le cadre de Schéma (Classes / Attributs) et de l’Atelier (Toutes / Au moins une) était décalé de 3 px vers la gauche ; celui de l’Atelier est aussi mesuré de nouveau quand il réapparaît.
- Rechercher : colonnes de 200 px au moins dans la carte « Syntaxe facultative » ; chaque exemple tient sur une ligne, menu déplié ou replié.
- Menu de gauche : la poignée de largeur portait une infobulle et restait donc dans le flux (0 px de haut, un écart de plus sous le pied du menu déplié) ; elle en sort, le pied garde sa hauteur dans les deux modes et la poignée se saisit de nouveau à la souris. Elle est masquée quand le menu est replié d’office.

## Portée

Recette exécutée sur une VM Windows 11 jointe au domaine de test (identité intégrée de la session, aucun mot de passe saisi par l’outil) ; ce n’est pas une recette utilisateur ni une validation sur le domaine de production. Les tests de 3 500 et 100 000 postes restent simulés. La revue visuelle native et la recette utilisateur restent en attente. L’échec intermittent de parametres/copie-destination (clic perdu, réussi 3 fois sur 3 en relance ciblée, écran non modifié par 2.0.7) reste à analyser. [Recette à effectuer](../../RECETTE-MANUELLE-V2.0.7.md).

## Addendum du 29/10/2026 — échec intermittent expliqué

L’échec de `parametres/copie-destination` dans la simulation complète venait du harnais de recette, pas de Domenia. La carte « Sauvegarder » est sous la ligne de flottaison et attend son entrée (`.reveal`, décalée de 18 px). Le harnais faisait défiler jusqu’au bouton, le mesurait dans cette position d’avant l’entrée et le jugeait immobile après 60 ms ; sur la VM chargée, aucune image n’avait encore lancé l’animation. La carte est ensuite remontée de 17,6 px et le clic est tombé 2,6 px sous le bouton, sur la carte : l’écran ignore à raison un clic hors de son action (position du pointeur retrouvée par la lueur de survol, défilement décalé de 18 px). Sur le même pack, 23 autres exécutions de ce scénario avaient réussi.

Corrections, sans changement de Domenia (2.0.7 reste la version publiée) :

- harnais E2E (`cb80261a`) : après le défilement, la cible laisse la page dessiner trois images, vérifie l’immobilité sur 60 ms et une image, et reste « en mouvement » tant qu’une animation finie de position anime l’élément ou un parent, ou si la page ne dessine aucune image pendant 500 ms ;
- `tools/desktop-run.ps1` : un suivi dont la tâche planifiée a été retirée de l’extérieur s’arrête après 3 s au lieu d’interroger le Planificateur jusqu’à son délai ; ces suivis orphelins avaient surchargé la VM pendant les recettes.

Vérifications : CI Windows du commit `cb80261a` (26 auto-tests du harnais, 7 scénarios critiques, 110 tests web critiques) ; simulation complète sur la VM avec le ZIP PROD 2.0.7 publié et le harnais corrigé : 136 réussis, 0 en échec, 1 ignoré (réservé au mode annuaire), en 57 min ; le scénario 7 fois sur 7 avec la moitié du processeur occupée (trois exécutions non lancées, la VM chargée ne répondant plus en SSH) ; un suivi dont la tâche est retirée s’arrête de lui-même.
