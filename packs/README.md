# Packs Windows Domenia 2.1.0

Une seule édition est publiée : **PROD-LIGHT**. Elle contient les 22 lots de l’audit de parité, une fermeture propre sur un poste hors domaine, et des mises à jour lues seulement depuis un dossier de diffusion ou un ZIP local.

Source : [`94851344`](https://github.com/M4D135/domenia-d120/commit/948513449f014a132d610456356d1c7b708d925b). [Release v2.1.0](https://github.com/M4D135/domenia-d120/releases/tag/v2.1.0).

| Pack | Archive | Octets | SHA256 |
| --- | --- | ---: | --- |
| **PROD-LIGHT** | [Domenia_2.1.0_PROD-LIGHT_Windows-x64.zip](https://github.com/M4D135/domenia-d120/releases/download/v2.1.0/Domenia_2.1.0_PROD-LIGHT_Windows-x64.zip) | 84266912 | `53f6a967d72879e5b284f9e29bfa097774c35523e5c4d3c52b123efc38a488a3` |

[SHA256SUMS.txt](https://github.com/M4D135/domenia-d120/releases/download/v2.1.0/SHA256SUMS.txt) : copie identique dans `packs/SHA256SUMS`. [`manifest.json`](manifest.json) décrit la provenance et les limites.

PROD-LIGHT utilise WebView2 Evergreen x64 (140.0.3485.54 ou ultérieur) déjà installé sur le poste. À défaut, il utilise le [pack WebView2 du Socle](https://github.com/M4D135/socle-windows/releases/tag/webview2-156.0.4314.42) extrait dans `wad`. Le runtime .NET est inclus.

[Recette manuelle](../v2/docs/RECETTE-MANUELLE-V2.1.0.md).

Les packs 2.0.x ne sont plus publiés : le dépôt a été recréé le 09/11/2026 avec sa seule dernière version.
