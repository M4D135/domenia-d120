# Packs Windows Domenia 2.1.7

Une seule édition est publiée : **PROD-LIGHT**. 2.1.7 rend de nouveau les mises à jour possibles : le contrôle de santé du nouveau code annulait sa propre page de vérification et chaque mise à jour revenait aux anciens binaires. Elle rétablit aussi les commandes `livraison`. Elle refuse une restauration vers une version antérieure à 2.1.6 tant qu’une configuration est écrite sur place. Enfin, `--check-settings-seed` rend le code 2 pour un fichier invalide. La configuration par défaut écrite sur place de 2.1.6 et les correctifs de 2.1.5 sont conservés. Le schéma des données reste inchangé.

Source : [`e2a7ed46`](https://github.com/M4D135/domenia-d120/commit/e2a7ed467141a933e784c97ff747e72b729b5aaf). [Release v2.1.7](https://github.com/M4D135/domenia-d120/releases/tag/v2.1.7), publiée le 12 novembre 2026.

| Pack | Archive | Octets | SHA256 |
| --- | --- | ---: | --- |
| **PROD-LIGHT** | [Domenia_2.1.7_PROD-LIGHT_Windows-x64.zip](https://github.com/M4D135/domenia-d120/releases/download/v2.1.7/Domenia_2.1.7_PROD-LIGHT_Windows-x64.zip) | 84287376 | `ec8a8d2f6f03eb197a16cde4e6c5d8ff27e3fce157bde63bbf1439c797340ca2` |

[SHA256SUMS.txt](https://github.com/M4D135/domenia-d120/releases/download/v2.1.7/SHA256SUMS.txt) : copie identique dans `packs/SHA256SUMS`. [`manifest.json`](manifest.json) décrit la provenance et les limites. Le ZIP a été retéléchargé sans compte avec la même empreinte.

PROD-LIGHT utilise WebView2 Evergreen x64 (140.0.3485.54 ou ultérieur) déjà installé sur le poste. À défaut, il utilise le [pack WebView2 du Socle](https://github.com/M4D135/socle-windows/releases/tag/webview2-156.0.4314.42) extrait dans `wad`. Le runtime .NET est inclus.

[Qualification CI](https://github.com/M4D135/domenia-d120/actions/runs/43231233101) : 3 081 tests C# complets, 1 653 critiques, 227 contrôles navigateur, 7 simulations et parcours natif hors connexion réussis. [Recette des binaires](https://github.com/M4D135/domenia-d120/actions/runs/43241745675) sur un runner hébergé jetable, avec ce ZIP exact et les ZIP 2.1.5 et 2.1.6 des releases : 21 étapes, aucun échec. Les mises à jour 2.1.5 → 2.1.7 et 2.1.6 → 2.1.7 sont confirmées par le vrai contrôle de santé, avec la configuration gardée à l’octet. La restauration vers 2.1.5 est refusée avec le fichier sur place, puis aboutit après son déplacement ; la restauration vers 2.1.6 garde le fichier. Pas de banc administrateur pour 2.1.7 ; la mise à jour depuis Paramètres n’a pas été cliquée. Aucune écriture AD. Recette utilisateur complète à faire.

Les releases [v2.1.6](https://github.com/M4D135/domenia-d120/releases/tag/v2.1.6) et [v2.1.5](https://github.com/M4D135/domenia-d120/releases/tag/v2.1.5) restent disponibles ; v2.1.0 à v2.1.4 ont été retirées le 12/11/2026. Les packs 2.0.x ne sont plus publiés : le dépôt a été recréé le 09/11/2026.
