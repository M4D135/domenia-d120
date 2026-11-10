# Packs Windows Domenia 2.1.2

Une seule édition est publiée : **PROD-LIGHT**. 2.1.2 clôture les derniers points de parité, renforce les comparaisons de populations et les contrôles des contrats de sondes. Le schéma des données reste inchangé.

Source : [`c2e5edb1`](https://github.com/M4D135/domenia-d120/commit/c2e5edb1fe1841821a02e27e2014a6774015c82e). [Release v2.1.2](https://github.com/M4D135/domenia-d120/releases/tag/v2.1.2), publiée le 10 novembre 2026.

| Pack | Archive | Octets | SHA256 |
| --- | --- | ---: | --- |
| **PROD-LIGHT** | [Domenia_2.1.2_PROD-LIGHT_Windows-x64.zip](https://github.com/M4D135/domenia-d120/releases/download/v2.1.2/Domenia_2.1.2_PROD-LIGHT_Windows-x64.zip) | 84267433 | `b4fd5a59f571db88ae60a4fe612e44bf58230b28c1c1e0302cc79a88b5082a2f` |

[SHA256SUMS.txt](https://github.com/M4D135/domenia-d120/releases/download/v2.1.2/SHA256SUMS.txt) : copie identique dans `packs/SHA256SUMS`. [`manifest.json`](manifest.json) décrit la provenance et les limites. Le ZIP a été retéléchargé sans compte avec la même empreinte.

PROD-LIGHT utilise WebView2 Evergreen x64 (140.0.3485.54 ou ultérieur) déjà installé sur le poste. À défaut, il utilise le [pack WebView2 du Socle](https://github.com/M4D135/socle-windows/releases/tag/webview2-156.0.4314.42) extrait dans `wad`. Le runtime .NET est inclus.

[Qualification CI](https://github.com/M4D135/domenia-d120/actions/runs/42701363001) : 3 043 tests C# complets, 1 601 critiques, 218 contrôles navigateur, 7 simulations et parcours natif hors connexion réussis. La [recette manuelle](../v2/docs/RECETTE-MANUELLE-V2.1.2.md) sur domaine réel reste à effectuer ; aucune ancienne preuve de banc n’est appliquée à ce ZIP.

Les releases [v2.1.1](https://github.com/M4D135/domenia-d120/releases/tag/v2.1.1) et [v2.1.0](https://github.com/M4D135/domenia-d120/releases/tag/v2.1.0) restent disponibles. Les packs 2.0.x ne sont plus publiés : le dépôt a été recréé le 09/11/2026.
