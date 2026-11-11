# Packs Windows Domenia 2.1.5

Une seule édition est publiée : **PROD-LIGHT**. 2.1.5 rouvre les lectures « CIM / WinRM » (fin du 0x80070057), rend un poste sans WinRM « Injoignable » avec son code sans source « Interrompu », lit de nouveau les logiciels installés, et arrête les animations en boucle quand l’affichage se fait sans accélération graphique. Le schéma des données reste inchangé.

Source : [`9282893d`](https://github.com/M4D135/domenia-d120/commit/9282893d6e5bc4409ca2f4e369c57f37a7f5bfb7). [Release v2.1.5](https://github.com/M4D135/domenia-d120/releases/tag/v2.1.5), publiée le 12 novembre 2026.

| Pack | Archive | Octets | SHA256 |
| --- | --- | ---: | --- |
| **PROD-LIGHT** | [Domenia_2.1.5_PROD-LIGHT_Windows-x64.zip](https://github.com/M4D135/domenia-d120/releases/download/v2.1.5/Domenia_2.1.5_PROD-LIGHT_Windows-x64.zip) | 84285266 | `d435e21033ca144bf5ba31c43aa5ce76caa538fa8f9cc19faa1d70a925541a9a` |

[SHA256SUMS.txt](https://github.com/M4D135/domenia-d120/releases/download/v2.1.5/SHA256SUMS.txt) : copie identique dans `packs/SHA256SUMS`. [`manifest.json`](manifest.json) décrit la provenance et les limites. Le ZIP a été retéléchargé sans compte avec la même empreinte.

PROD-LIGHT utilise WebView2 Evergreen x64 (140.0.3485.54 ou ultérieur) déjà installé sur le poste. À défaut, il utilise le [pack WebView2 du Socle](https://github.com/M4D135/socle-windows/releases/tag/webview2-156.0.4314.42) extrait dans `wad`. Le runtime .NET est inclus.

[Qualification CI](https://github.com/M4D135/domenia-d120/actions/runs/43116714568) : 3 075 tests C# complets, 1 647 critiques, 225 contrôles navigateur, 7 simulations et parcours natif hors connexion réussis. Banc du 11 novembre sur un kit de la même source produit : inventaire Automatique par DCOM 27/27 en 26,4 s, logiciels installés lus ; « CIM / WinRM » sur un poste sans écouteur 0/27 en 5,6 s, sans source « Interrompu ». Lecture WinRM réussie non observée sur le banc (limite connue). La [recette manuelle](../v2/docs/RECETTE-MANUELLE-V2.1.5.md) complète reste à effectuer.

Les releases [v2.1.4](https://github.com/M4D135/domenia-d120/releases/tag/v2.1.4), [v2.1.3](https://github.com/M4D135/domenia-d120/releases/tag/v2.1.3), [v2.1.2](https://github.com/M4D135/domenia-d120/releases/tag/v2.1.2), [v2.1.1](https://github.com/M4D135/domenia-d120/releases/tag/v2.1.1) et [v2.1.0](https://github.com/M4D135/domenia-d120/releases/tag/v2.1.0) restent disponibles. Les packs 2.0.x ne sont plus publiés : le dépôt a été recréé le 09/11/2026.
