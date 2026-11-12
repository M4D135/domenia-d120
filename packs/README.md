# Packs Windows Domenia 2.1.8

Une seule édition est publiée : **PROD-LIGHT**. 2.1.8 corrige le relevé de présence : un compte ordinateur sans nom DNS cohérent (pré-créé, renommé) ou modifié depuis la préparation du relevé n’interrompt plus « Tout actualiser » pour toute l’OU. Le premier reçoit une réponse définitive « Nom de poste invalide » sans être contacté, le second est écarté seul et compté. Les correctifs de 2.1.7 et la configuration par défaut écrite sur place de 2.1.6 sont conservés. Le schéma des données reste inchangé.

Source : [`a50e8752`](https://github.com/M4D135/domenia-d120/commit/a50e8752fa0a816870f54b8c4abf8d895473880f). [Release v2.1.8](https://github.com/M4D135/domenia-d120/releases/tag/v2.1.8), publiée le 12 novembre 2026.

| Pack | Archive | Octets | SHA256 |
| --- | --- | ---: | --- |
| **PROD-LIGHT** | [Domenia_2.1.8_PROD-LIGHT_Windows-x64.zip](https://github.com/M4D135/domenia-d120/releases/download/v2.1.8/Domenia_2.1.8_PROD-LIGHT_Windows-x64.zip) | 84288037 | `32b3a1acc2c273d8f808d35f9096d3cc07b047970fae7378ecdfa690ac5bbd68` |

[SHA256SUMS.txt](https://github.com/M4D135/domenia-d120/releases/download/v2.1.8/SHA256SUMS.txt) : copie identique dans `packs/SHA256SUMS`. [`manifest.json`](manifest.json) décrit la provenance et les limites. Le ZIP a été retéléchargé sans compte avec la même empreinte.

PROD-LIGHT utilise WebView2 Evergreen x64 (140.0.3485.54 ou ultérieur) déjà installé sur le poste. À défaut, il utilise le [pack WebView2 du Socle](https://github.com/M4D135/socle-windows/releases/tag/webview2-156.0.4314.42) extrait dans `wad`. Le runtime .NET est inclus.

[Qualification CI](https://github.com/M4D135/domenia-d120/actions/runs/43256107229) : 3 082 tests C# complets, 1 654 critiques, 227 contrôles navigateur, 7 simulations et parcours natif hors connexion réussis. [Recette des binaires](https://github.com/M4D135/domenia-d120/actions/runs/43261204475) sur un runner hébergé jetable, avec ce ZIP exact et le ZIP 2.1.7 de sa release : 13 étapes, aucun échec. La mise à jour 2.1.7 → 2.1.8 est confirmée par le vrai contrôle de santé, avec la configuration gardée à l’octet ; la restauration vers 2.1.7 garde le fichier. Correction non observée sur un vrai domaine ; pas de banc administrateur pour 2.1.8 ; la mise à jour depuis Paramètres n’a pas été cliquée. Aucune écriture AD. Recette utilisateur complète à faire.

Seule la dernière version est publiée : les releases v2.1.0 à v2.1.6 ont été retirées le 12/11/2026, leurs sources restent dans l’historique de `master` ; v2.1.7 reste en ligne jusqu’à décision. Les packs 2.0.x ne sont plus publiés : le dépôt a été recréé le 09/11/2026.
