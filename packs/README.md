# Packs Windows Domenia 2.1.1

Une seule édition est publiée : **PROD-LIGHT**. 2.1.1 corrige 2.1.0 pour les comptes qui ne sont pas membres de Domain Admins. Mesurer les postes en ligne ne demande plus de compte d’administration. Les lectures distantes faites avec l’identité de la session Windows sont tentées, et le poste accepte ou refuse.

Source : [`7627bd1e`](https://github.com/M4D135/domenia-d120/commit/7627bd1e50d9b72a255f98b8d980f4496cb59397). [Release v2.1.1](https://github.com/M4D135/domenia-d120/releases/tag/v2.1.1).

| Pack | Archive | Octets | SHA256 |
| --- | --- | ---: | --- |
| **PROD-LIGHT** | [Domenia_2.1.1_PROD-LIGHT_Windows-x64.zip](https://github.com/M4D135/domenia-d120/releases/download/v2.1.1/Domenia_2.1.1_PROD-LIGHT_Windows-x64.zip) | 84266401 | `85d795d75b332a9008de14c235ca81b788d44a4006e510e86c7f6c568689f8b2` |

[SHA256SUMS.txt](https://github.com/M4D135/domenia-d120/releases/download/v2.1.1/SHA256SUMS.txt) : copie identique dans `packs/SHA256SUMS`. [`manifest.json`](manifest.json) décrit la provenance et les limites.

PROD-LIGHT utilise WebView2 Evergreen x64 (140.0.3485.54 ou ultérieur) déjà installé sur le poste. À défaut, il utilise le [pack WebView2 du Socle](https://github.com/M4D135/socle-windows/releases/tag/webview2-156.0.4314.42) extrait dans `wad`. Le runtime .NET est inclus.

[Recette manuelle](../v2/docs/RECETTE-MANUELLE-V2.1.1.md). La [release v2.1.0](https://github.com/M4D135/domenia-d120/releases/tag/v2.1.0) reste disponible.

Les packs 2.0.x ne sont plus publiés : le dépôt a été recréé le 09/11/2026.
