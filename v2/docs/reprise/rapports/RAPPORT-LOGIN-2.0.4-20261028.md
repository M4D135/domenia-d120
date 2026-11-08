# Domenia 2.0.4 — connexion et pack portable, 28 octobre 2026

Le nom de compte simple est complété avec le domaine connu de la session. Les identifiants qualifiés restent acceptés. La fenêtre principale reste invisible pendant le login et apparaît après chargement du document local ; les dialogues natifs restent accessibles. Le pack retrouve sa structure portable : `Domenia.exe` et `wad` à la racine.

Source compilée : `648749200f066cb3aad7764e7ab6faa40fc1764f`. [Release v2.0.4](https://github.com/M4D135/domenia-d120/releases/tag/v2.0.4), publiée à `2026-10-28T08:35:27Z`, identifiant `426420117`.

## Vérifications

[Compilation Windows Debug/Release](https://github.com/M4D135/domenia-d120/actions/runs/40655506707) et [fabrication des packs](https://github.com/M4D135/domenia-d120/actions/runs/40655506754) réussies sur ce commit. Résultats : **759 tests C# critiques**, 25 autocontrôles E2E, 35 contrôles Python (15 + 10 + 10), 93 tests Web critiques et 7 scénarios de simulation. Les tests ajoutés couvrent la disposition EXE + wad, la reprise et restauration après interruption, la diffusion des réglages, puis le nom simple dans le domaine courant, le DNS joint avant connexion, les formes qualifiées, les entrées invalides, l’absence de domaine et l’ouverture du compte en simulation.

Les lancements PROD et DEV quittent avec le code 0. Deux démarrages en simulation confirment le chargement de .NET et WebView2 depuis `wad/runtime`, avec fermeture normale. Une copie privée de test sans runtime refuse de démarrer malgré le runtime global du runner. Ce contrôle reste distinct du login en domaine réel.

Intégrité des ZIP et de leurs manifestes vérifiée localement ; les 1 683 sources DEV correspondent aux blobs Git du commit. PROD et DEV partagent le même exécutable : `1c65b3335ba09e8fef3b8c6445adf8a1a1fe9104274a10e2a71377e8a99e6c84`. Les SHA256 GitHub concordent avec les trois fichiers locaux ; aucun binaire reconstruit pour la publication. Les cinq releases précédentes et leurs quinze assets sont conservés.

| Pack | Archive | Octets | SHA256 |
| --- | --- | ---: | --- |
| **PROD** | [Domenia_2.0.4_PROD_Windows-x64.zip](https://github.com/M4D135/domenia-d120/releases/download/v2.0.4/Domenia_2.0.4_PROD_Windows-x64.zip) | 483449915 | `da85d36b1e903338fc26dd9c13434e80e0e6eb661da4978be5ce67469e6619d8` |
| **DEV** | [Domenia_2.0.4_DEV_Windows-x64.zip](https://github.com/M4D135/domenia-d120/releases/download/v2.0.4/Domenia_2.0.4_DEV_Windows-x64.zip) | 503246061 | `1015274da8c216eacccf086238ef9dcabb0a5e5709ae15da5c3452c5d745a9d6` |

## Installation

Extraire dans un nouveau dossier : la racine contient uniquement `Domenia.exe` et `wad`. Ne pas superposer cette version aux anciens packs plats. Le profil utilisateur est conservé ; une configuration portable locale se place dans `wad/Domenia.config.json`. Les sources DEV sont dans `wad/developer`. Le changement de disposition en place est refusé explicitement ; les anciennes transactions restent à reprendre depuis leur ancien pack.

## Portée

Aucune VM, authentification AD réelle ou revue visuelle native exécutée pour cette version. La recette utilisateur reste en attente ; les validations des packs précédents ne sont pas réattribuées à ces octets.

Le masquage du fond blanc est implémenté avant le premier affichage du propriétaire WinForms ; le document chargé ou l’erreur d’affichage le rend visible. Ce contrôle de code n’est pas une observation native sur un poste réel. [Recette à effectuer](../../RECETTE-MANUELLE-V2.0.4.md).
