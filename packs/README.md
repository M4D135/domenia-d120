# Packs Windows Domenia 2.1.4

Une seule édition est publiée : **PROD-LIGHT**. 2.1.4 lit l’inventaire en DCOM d’abord en mode Automatique, isole les sources lentes, ne coupe plus un inventaire au délai distant, affiche les codes d’erreur CIM, et corrige la zone de recherche et le titre de fenêtre. Le schéma des données reste inchangé.

Source : [`6d8dbfd7`](https://github.com/M4D135/domenia-d120/commit/6d8dbfd75141d3cdb6f4ffda4464c3ae868c1b80). [Release v2.1.4](https://github.com/M4D135/domenia-d120/releases/tag/v2.1.4), publiée le 11 novembre 2026.

| Pack | Archive | Octets | SHA256 |
| --- | --- | ---: | --- |
| **PROD-LIGHT** | [Domenia_2.1.4_PROD-LIGHT_Windows-x64.zip](https://github.com/M4D135/domenia-d120/releases/download/v2.1.4/Domenia_2.1.4_PROD-LIGHT_Windows-x64.zip) | 84280069 | `21ef429327e063bd15d80baf4257d810617c8b3a3da79dca68b6a031e8c2385a` |

[SHA256SUMS.txt](https://github.com/M4D135/domenia-d120/releases/download/v2.1.4/SHA256SUMS.txt) : copie identique dans `packs/SHA256SUMS`. [`manifest.json`](manifest.json) décrit la provenance et les limites. Le ZIP a été retéléchargé sans compte avec la même empreinte.

PROD-LIGHT utilise WebView2 Evergreen x64 (140.0.3485.54 ou ultérieur) déjà installé sur le poste. À défaut, il utilise le [pack WebView2 du Socle](https://github.com/M4D135/socle-windows/releases/tag/webview2-156.0.4314.42) extrait dans `wad`. Le runtime .NET est inclus.

[Qualification CI](https://github.com/M4D135/domenia-d120/actions/runs/43023042342) : 3 065 tests C# complets, 1 644 critiques, 222 contrôles navigateur, 7 simulations et parcours natif hors connexion réussis. Banc du 11 novembre sur des kits de la même source produit : inventaire Automatique par DCOM 19/27 avant le plafond de 55 s ; « CIM / WinRM » en échec 0x80070057 sur chaque source (limite connue). La [recette manuelle](../v2/docs/RECETTE-MANUELLE-V2.1.4.md) complète reste à effectuer.

Les releases [v2.1.3](https://github.com/M4D135/domenia-d120/releases/tag/v2.1.3), [v2.1.2](https://github.com/M4D135/domenia-d120/releases/tag/v2.1.2), [v2.1.1](https://github.com/M4D135/domenia-d120/releases/tag/v2.1.1) et [v2.1.0](https://github.com/M4D135/domenia-d120/releases/tag/v2.1.0) restent disponibles. Les packs 2.0.x ne sont plus publiés : le dépôt a été recréé le 09/11/2026.
