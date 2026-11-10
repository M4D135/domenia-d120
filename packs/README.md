# Packs Windows Domenia 2.1.3

Une seule édition est publiée : **PROD-LIGHT**. 2.1.3 corrige le clignotement des étapes, la consultation du stockage, la largeur des encadrés de mise à jour et l’affichage de la version. Le schéma des données reste inchangé.

Source : [`65daf42f`](https://github.com/M4D135/domenia-d120/commit/65daf42f3637eeea2f60e0a2ba150bef686a37a3). [Release v2.1.3](https://github.com/M4D135/domenia-d120/releases/tag/v2.1.3), publiée le 10 novembre 2026.

| Pack | Archive | Octets | SHA256 |
| --- | --- | ---: | --- |
| **PROD-LIGHT** | [Domenia_2.1.3_PROD-LIGHT_Windows-x64.zip](https://github.com/M4D135/domenia-d120/releases/download/v2.1.3/Domenia_2.1.3_PROD-LIGHT_Windows-x64.zip) | 84268232 | `583f1de66d0b2e2385291224472b9bd784180ba781302390683bd38a20e6a74c` |

[SHA256SUMS.txt](https://github.com/M4D135/domenia-d120/releases/download/v2.1.3/SHA256SUMS.txt) : copie identique dans `packs/SHA256SUMS`. [`manifest.json`](manifest.json) décrit la provenance et les limites. Le ZIP a été retéléchargé sans compte avec la même empreinte.

PROD-LIGHT utilise WebView2 Evergreen x64 (140.0.3485.54 ou ultérieur) déjà installé sur le poste. À défaut, il utilise le [pack WebView2 du Socle](https://github.com/M4D135/socle-windows/releases/tag/webview2-156.0.4314.42) extrait dans `wad`. Le runtime .NET est inclus.

[Qualification CI](https://github.com/M4D135/domenia-d120/actions/runs/42772371612) : 3 046 tests C# complets, 1 610 critiques, 221 contrôles navigateur, 7 simulations et parcours natif hors connexion réussis. La [recette manuelle](../v2/docs/RECETTE-MANUELLE-V2.1.3.md) sur domaine réel reste à effectuer ; aucune ancienne preuve de banc n’est appliquée à ce ZIP.

Les releases [v2.1.2](https://github.com/M4D135/domenia-d120/releases/tag/v2.1.2), [v2.1.1](https://github.com/M4D135/domenia-d120/releases/tag/v2.1.1) et [v2.1.0](https://github.com/M4D135/domenia-d120/releases/tag/v2.1.0) restent disponibles. Les packs 2.0.x ne sont plus publiés : le dépôt a été recréé le 09/11/2026.
