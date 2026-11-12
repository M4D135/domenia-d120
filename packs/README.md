# Packs Windows Domenia 2.1.6

Une seule édition est publiée : **PROD-LIGHT**. 2.1.6 écrit la configuration par défaut sur place, dans `wad/Domenia.settings.seed.json` du dossier ouvert, hors manifeste, comme GLPI Pilot : le ZIP officiel, le manifeste et les binaires restent intacts. Les correctifs de 2.1.5 sont conservés. Le schéma des données reste inchangé.

Source : [`3869e60f`](https://github.com/M4D135/domenia-d120/commit/3869e60ffca2512c056567545863ae146595e410). [Release v2.1.6](https://github.com/M4D135/domenia-d120/releases/tag/v2.1.6), publiée le 12 novembre 2026.

| Pack | Archive | Octets | SHA256 |
| --- | --- | ---: | --- |
| **PROD-LIGHT** | [Domenia_2.1.6_PROD-LIGHT_Windows-x64.zip](https://github.com/M4D135/domenia-d120/releases/download/v2.1.6/Domenia_2.1.6_PROD-LIGHT_Windows-x64.zip) | 84286590 | `3d5ec57e326123a60c46042cffc52c006dac630a9839d505e5f5d8c8b0709b13` |

[SHA256SUMS.txt](https://github.com/M4D135/domenia-d120/releases/download/v2.1.6/SHA256SUMS.txt) : copie identique dans `packs/SHA256SUMS`. [`manifest.json`](manifest.json) décrit la provenance et les limites. Le ZIP a été retéléchargé sans compte avec la même empreinte.

PROD-LIGHT utilise WebView2 Evergreen x64 (140.0.3485.54 ou ultérieur) déjà installé sur le poste. À défaut, il utilise le [pack WebView2 du Socle](https://github.com/M4D135/socle-windows/releases/tag/webview2-156.0.4314.42) extrait dans `wad`. Le runtime .NET est inclus.

[Qualification CI](https://github.com/M4D135/domenia-d120/actions/runs/43213255629) : 3 078 tests C# complets, 1 650 critiques, 227 contrôles navigateur, 7 simulations et parcours natif hors connexion réussis. Banc du 12 novembre sur un kit de la même source produit avant les seules retouches de documentation : écriture sur place, quatre réécritures de suite (« déjà en place » à l’octet, remplacements sauvegardés), redémarrage sans refus ni proposition ; profil vierge servi sans question au premier passage. Aucune écriture AD. Recette utilisateur complète à faire.

La [release v2.1.5](https://github.com/M4D135/domenia-d120/releases/tag/v2.1.5) reste disponible ; v2.1.0 à v2.1.4 ont été retirées le 12/11/2026. Les packs 2.0.x ne sont plus publiés : le dépôt a été recréé le 09/11/2026.
